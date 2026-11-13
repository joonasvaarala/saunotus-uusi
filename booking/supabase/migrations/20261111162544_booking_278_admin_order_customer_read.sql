-- booking_278: tilausnäkymän ja asiakasnäkymän lukufunktiot (tilausnäkymä v3, PR 1; määrittely §4 A, H, J).
-- VAIN LUKUA: ei taulumuutoksia, ei datamuutoksia, ei uusia oikeuksia. Kaikki SECURITY DEFINER, search_path '', _require_staff
-- kuten nykyisissä admin-lukufunktioissa. Rungot pohjautuvat PRODin määrittelyihin 11.11.2026
-- (md5 pg_get_functiondef: admin_get_order 588767e4dd1967267df8d12501aa6898, admin_get_customer 5b4d0d7a45c9be9ed3ffd340255d688a).
--
-- A  admin_get_order: vanha vastaus ennallaan + uudet avaimet locale, invoice {id, invoice_no, status, invoice_date, due_date,
--    sent_at, paid_at, dispatch_status, total}, overpaid, refundable_by_payment[] (ei lahjakortti-, kumppani-, vuosikortti-,
--    maksa myöhemmin- eikä laskumaksuja; käsittelyssä olevat hyvitykset vähennetty), voucher_claims[] (koodi maskattuna,
--    tila ja problem_code, esim. already_used = "Koodi jo käytetty") ja reservation_meta[] (tila, sääntö, sisäänkirjaus,
--    peruutus). _order_balance lasketaan nyt kerran (oli kahdesti).
-- H  admin_get_customer: vanha vastaus ennallaan + open_balance, open_orders, stats {orders, first_order_at, visits, last_visit,
--    upcoming, next_at, no_show, last_no_show}, gift_cards {bought[] (maskattu koodi, enintään 50), bought_count,
--    bought_total, redeemed_count}.
-- J  uusi admin_order_history(p_order_id, p_limit): tilauksen, sen varausten, maksujen, hyvitysten, kumppanilunastusten ja
--    laskujen audit_log-rivit. Muuttuneista kentistä palautetaan nimet; arvot vain tila-, summa-, henkilömäärä-, aika- ja
--    syykoodikentille. Ei muistiinpanojen, nimien, yhteystietojen eikä koodien sisältöä. Tekijä = henkilökunnan nimi tai system.
-- +  uusi admin_order_lookup(p_order_no): tilausnumero → order_id (reitti #/tilaukset/<nro>).
-- Rollback: booking/supabase/rollbacks/20261111160000_booking_278_ROLLBACK.sql (palauttaa A:n ja H:n PROD-rungot, poistaa J:n ja lookupin).
-- Testit: booking/supabase/tests/t278_admin_order_customer_read.sql

CREATE OR REPLACE FUNCTION booking.admin_get_order(p_order_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; c booking.customers; v_end timestamptz; v_site text; v_op text; v_pp text;
  v_locked boolean; v_unpaid numeric; v_inv text; v_bal jsonb;
begin
  perform booking._require_staff();
  select * into o from booking.orders where id = p_order_id;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  select * into c from booking.customers where id = o.customer_id;
  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  v_site := coalesce(booking._setting('site_base_url') #>> '{}', ''); v_op := coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/');
  v_pp := coalesce(booking._setting('payment_link_path') #>> '{}', '/maksa/');
  v_locked := booking._order_invoice_locked(o.id);
  v_bal := booking._order_balance(o.id);
  v_unpaid := (v_bal ->> 'unpaid')::numeric;
  select i.invoice_no into v_inv from booking.invoices i
   where i.order_id = o.id and i.kind = 'debit' and i.status in ('sent','paid','overdue','credited')
   order by i.id desc limit 1;
  return jsonb_build_object(
    'order_id', o.id, 'order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'total', o.total_gross,
    'source_channel', o.source_channel, 'created_at', o.created_at, 'customer_note', o.customer_note, 'internal_note', o.internal_note,
    'customer_kind', o.customer_kind, 'billing', o.billing, 'invoice_reference', o.invoice_reference,
    'customer', case when c.id is null then null else jsonb_build_object('id', c.id, 'name', c.name, 'email', c.email, 'phone', c.phone,
        'company', c.company, 'customer_kind', c.customer_kind, 'business_id', c.business_id) end,
    'reservations', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status, 'product_name', it.product_name, 'mode', r.mode,
        'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'notes', r.notes, 'item_total', it.line_total_gross, 'item_id', r.order_item_id,
        'product_id', r.product_id, 'option', booking._option_json(r.product_option_id), 'option_choices', booking._product_options_json(r.product_id),
        'option_missing', (r.product_option_id is null and exists (select 1 from booking.product_options x where x.product_id = r.product_id and x.active)),
        'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', ai.addon_id, 'name', ai.product_name, 'quantity', ai.quantity,
                     'unit_price', ai.unit_price_gross, 'line_total', ai.line_total_gross, 'vat_rate', ai.vat_rate) order by ai.id)
                   from booking.order_items ai where ai.parent_item_id = r.order_item_id and ai.kind = 'addon'), '[]'::jsonb)) order by r.starts_at)
        from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id and r.hidden_at is null), '[]'::jsonb),
    'public_token', o.public_token, 'order_page_path', v_site || v_op || '?t=' || o.public_token, 'is_native', o.external_source is null,
    'balance', v_bal,
    'invoice_locked', v_locked, 'invoice_no', v_inv,
    'can_add', o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not v_locked, 'add_until', v_end,
    'staff_can_add', o.external_source is null and o.status in ('confirmed','completed') and not v_locked,
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'parent_item_id', i.parent_item_id, 'kind', i.kind, 'product_id', i.product_id, 'name', i.product_name,
        'quantity', i.quantity, 'unit_price', i.unit_price_gross, 'line_total', i.line_total_gross, 'vat_rate', i.vat_rate, 'line_vat', i.line_vat, 'line_net', i.line_net,
        'covered', cv.cov, 'remaining', i.line_total_gross - cv.cov) order by i.id)
        from booking.order_items i
        left join lateral (select coalesce(sum(pl.amount_gross - pl.refunded_gross), 0) cov from booking.payment_lines pl join booking.payments p on p.id = pl.payment_id
                            where pl.order_item_id = i.id and p.status in ('paid','partially_refunded','refunded')) cv on true
       where i.order_id = o.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'method', p.method, 'status', p.status, 'amount', p.amount, 'paid_at', p.paid_at,
        'provider', p.provider, 'provider_status', p.provider_status, 'refunded_amount', p.refunded_amount, 'rounding', p.rounding, 'link_token', p.link_token,
        'link_path', case when p.provider <> 'manual' and p.status = 'pending' then v_pp || '?p=' || p.link_token end, 'link_expires_at', p.link_expires_at,
        'link_stale', case when p.status = 'pending' and p.provider <> 'manual' and p.link_token is not null then p.amount > v_unpaid + 0.004 else false end,
        'note', p.note, 'created_at', p.created_at,
        'lines', coalesce((select jsonb_agg(jsonb_build_object('id', pl.id, 'order_item_id', pl.order_item_id, 'description', pl.description, 'quantity', pl.quantity,
                      'amount_gross', pl.amount_gross, 'vat_rate', pl.vat_rate, 'net', pl.line_net, 'vat_eur', pl.amount_gross - pl.line_net, 'refunded_gross', pl.refunded_gross) order by pl.id)
                    from booking.payment_lines pl where pl.payment_id = p.id), '[]'::jsonb),
        'receipts', coalesce((select jsonb_agg(jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'issued_at', rc.issued_at,
                      'public_token', rc.public_token, 'sent_at', rc.sent_at) order by rc.id) from booking.receipts rc where rc.payment_id = p.id), '[]'::jsonb),
        'refunds', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'amount', f.amount, 'status', f.status, 'reason', f.reason, 'created_at', f.created_at,
                      'done_at', f.done_at) order by f.id) from booking.refunds f where f.payment_id = p.id), '[]'::jsonb)) order by p.id)
        from booking.payments p where p.order_id = o.id), '[]'::jsonb),
    'receipts', coalesce((select jsonb_agg(jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'issued_at', rc.issued_at, 'total', rc.total_gross,
        'payment_id', rc.payment_id, 'refund_id', rc.refund_id, 'public_token', rc.public_token, 'sent_at', rc.sent_at) order by rc.id)
        from booking.receipts rc where rc.order_id = o.id), '[]'::jsonb),
    'refunds', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'payment_id', f.payment_id, 'amount', f.amount, 'status', f.status, 'reason', f.reason,
        'created_at', f.created_at, 'done_at', f.done_at) order by f.id) from booking.refunds f where f.order_id = o.id), '[]'::jsonb),
    'emails', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'status', e.status, 'sent_at', e.sent_at, 'created_at', e.created_at) order by e.id)
        from booking.email_outbox e where e.order_id = o.id), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'status', q.status, 'reason', q.reason, 'created_at', q.created_at,
        'handled_at', q.handled_at, 'note', q.note) order by q.id) from booking.order_requests q where q.order_id = o.id), '[]'::jsonb))
  -- booking_278 (A): tilausnäkymän lisäkentät. Vain lukua; ei henkilötietoja lisää (koodit maskattuna).
  || jsonb_build_object(
    'locale', o.locale,
    'invoice', (select jsonb_build_object('id', i.id, 'invoice_no', i.invoice_no, 'status', i.status, 'invoice_date', i.invoice_date,
        'due_date', i.due_date, 'sent_at', i.sent_at, 'paid_at', i.paid_at, 'dispatch_status', i.dispatch_status, 'total', i.total_gross)
        from booking.invoices i where i.order_id = o.id and i.kind = 'debit' and i.status <> 'voided' order by i.id desc limit 1),
    'overpaid', greatest(coalesce((v_bal ->> 'net_paid')::numeric, 0)
        - case when o.status in ('cancelled','expired','draft') then 0 else o.total_gross end, 0),
    'refundable_by_payment', coalesce((select jsonb_agg(jsonb_build_object('payment_id', p.id, 'method', p.method, 'provider', p.provider,
        'refundable', greatest(p.amount - p.refunded_amount - coalesce((select sum(f.amount) from booking.refunds f
                        where f.payment_id = p.id and f.status in ('requested','processing')), 0), 0)) order by p.id)
        from booking.payments p
       where p.order_id = o.id and p.status in ('paid','partially_refunded') and p.gift_card_id is null
         and p.method not like 'partner_voucher%' and p.method not in ('gift_card','annual_card','pay_later','invoice')), '[]'::jsonb),
    'voucher_claims', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'source', v.source, 'status', v.status, 'problem_code', v.problem_code,
        'code_masked', '…' || right(regexp_replace(coalesce(v.code, ''), '[^A-Za-z0-9]', '', 'g'), 4), 'voucher_value', v.voucher_value,
        'amount', v.amount, 'reservation_id', v.reservation_id, 'payment_id', v.payment_id, 'needs_review', v.needs_review) order by v.id)
        from booking.voucher_claims v where v.order_id = o.id), '[]'::jsonb),
    'reservation_meta', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'space_code', s.code, 'rule_id', r.rule_id,
        'checkin_at', r.checkin_at, 'cancelled_at', r.cancelled_at, 'cancel_reason', r.cancel_reason, 'hold_expires_at', r.hold_expires_at,
        'annual_card_id', r.annual_card_id) order by r.starts_at)
        from booking.reservations r left join booking.resources s on s.id = r.space_id
       where r.order_id = o.id and r.hidden_at is null), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION booking.admin_get_customer(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c booking.customers;
begin
  perform booking._require_staff();
  select * into c from booking.customers where id = p_id;
  if not found then perform booking._err('not_found', 'Asiakasta ei löydy'); end if;
  return to_jsonb(c) - 'unsubscribe_token' - 'customer_type_is_staff' || jsonb_build_object(
    'annual_cards', coalesce((select jsonb_agg(to_jsonb(ac) - 'created_by' - 'revoked_by' order by ac.valid_from desc) from booking.annual_cards ac where ac.customer_id = c.id), '[]'::jsonb),
    'orders', coalesce((
    select jsonb_agg(jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status,
        'total', o.total_gross, 'created_at', o.created_at, 'channel', o.source_channel,
        'reservations', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'starts_at', r.starts_at, 'persons', r.persons, 'status', r.status,
              'product_name', coalesce(it.product_name, '')) order by r.starts_at), '[]'::jsonb)
              from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id and r.hidden_at is null))
      order by o.created_at desc) from booking.orders o where o.customer_id = c.id), '[]'::jsonb))
  -- booking_278 (H): asiakasnäkymän tunnusluvut, avoin saldo ja ostetut lahjakortit (koodit maskattuna). Vain lukua.
  || jsonb_build_object(
    'open_balance', coalesce((select sum(b.unpaid) from (select (booking._order_balance(o.id) ->> 'unpaid')::numeric unpaid
        from booking.orders o where o.customer_id = c.id and o.status not in ('cancelled','expired','draft')) b), 0),
    'open_orders', (select count(*) from (select (booking._order_balance(o.id) ->> 'unpaid')::numeric unpaid
        from booking.orders o where o.customer_id = c.id and o.status not in ('cancelled','expired','draft')) b where b.unpaid > 0.004),
    'stats', (select jsonb_build_object(
        'orders', (select count(*) from booking.orders o where o.customer_id = c.id),
        'first_order_at', (select min(o.created_at) from booking.orders o where o.customer_id = c.id),
        'visits', count(*) filter (where r.status = 'completed' or (r.checkin_at is not null and r.status not in ('cancelled','no_show'))),
        'last_visit', max(r.starts_at) filter (where r.status = 'completed' or (r.checkin_at is not null and r.status not in ('cancelled','no_show'))),
        'upcoming', count(*) filter (where r.status in ('pending','confirmed') and r.starts_at > now()),
        'next_at', min(r.starts_at) filter (where r.status in ('pending','confirmed') and r.starts_at > now()),
        'no_show', count(*) filter (where r.status = 'no_show'),
        'last_no_show', max(r.starts_at) filter (where r.status = 'no_show'))
        from booking.reservations r join booking.orders o on o.id = r.order_id
       where o.customer_id = c.id and r.hidden_at is null),
    'gift_cards', jsonb_build_object(
        'bought', coalesce((select jsonb_agg(x.obj order by x.created_at desc) from (
            select g.created_at, jsonb_build_object('id', g.id, 'code_masked', '****-****-' || right(g.code, 4), 'kind', g.kind,
              'initial_amount', g.initial_amount, 'balance', g.balance, 'valid_to', g.valid_to, 'status', g.status, 'created_at', g.created_at) obj
              from booking.gift_cards g where g.buyer_customer_id = c.id order by g.created_at desc limit 50) x), '[]'::jsonb),
        'bought_count', (select count(*) from booking.gift_cards g where g.buyer_customer_id = c.id),
        'bought_total', coalesce((select sum(g.initial_amount) from booking.gift_cards g where g.buyer_customer_id = c.id), 0),
        'redeemed_count', (select count(distinct l.gift_card_id) from booking.gift_card_ledger l join booking.orders o on o.id = l.order_id
                            where o.customer_id = c.id and l.delta < 0)));
end $function$
;

-- J: tilauksen muutoshistoria audit_logista. Vain lukua. Palauttaa toiminnon, ajan, tekijän nimen (henkilökunta) ja
-- muuttuneiden kenttien NIMET; arvot vain sallituille ei-henkilötietokentille (tila, summa, henkilömäärä, aika, syykoodi).
-- Muistiinpanojen, nimien, sähköpostien, puhelinnumeroiden ja koodien sisältöä ei palauteta.
CREATE OR REPLACE FUNCTION booking.admin_order_history(p_order_id bigint, p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_lim int := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_res text[]; v_pay text[]; v_ref text[]; v_vc text[]; v_inv text[];
  v_rows jsonb;
begin
  perform booking._require_staff();
  if not exists (select 1 from booking.orders where id = p_order_id) then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  select coalesce(array_agg(id::text), '{}') into v_res from booking.reservations where order_id = p_order_id;
  select coalesce(array_agg(id::text), '{}') into v_pay from booking.payments where order_id = p_order_id;
  select coalesce(array_agg(id::text), '{}') into v_ref from booking.refunds where order_id = p_order_id;
  select coalesce(array_agg(id::text), '{}') into v_vc from booking.voucher_claims where order_id = p_order_id;
  select coalesce(array_agg(id::text), '{}') into v_inv from booking.invoices where order_id = p_order_id;
  with src as (
    select a.* from booking.audit_log a where a.table_name in ('orders','booking.orders') and a.row_pk = p_order_id::text
    union all select a.* from booking.audit_log a where a.table_name in ('reservations','booking.reservations') and a.row_pk = any (v_res)
    union all select a.* from booking.audit_log a where a.table_name in ('payments','booking.payments') and a.row_pk = any (v_pay)
    union all select a.* from booking.audit_log a where a.table_name in ('refunds','booking.refunds') and a.row_pk = any (v_ref)
    union all select a.* from booking.audit_log a where a.table_name in ('voucher_claims','booking.voucher_claims') and a.row_pk = any (v_vc)
    union all select a.* from booking.audit_log a where a.table_name in ('invoices','booking.invoices') and a.row_pk = any (v_inv)
  ), ev as (
    select a.id, a.at, a.action, regexp_replace(a.table_name, '^booking\.', '') tbl, a.row_pk, a.actor, a.actor_role,
      -- muuttuneet kentät (UPDATE): vanha ja uusi arvo eroavat; tekniset kentät pois
      coalesce((select jsonb_agg(jsonb_build_object('field', k,
              'from', case when k = any (array['status','payment_status','total_gross','persons','starts_at','ends_at','amount','refunded_amount',
                                                 'cancel_reason','problem_code','mode','method','provider','due_date','kind'])
                           then a.old_data -> k end,
              'to', case when k = any (array['status','payment_status','total_gross','persons','starts_at','ends_at','amount','refunded_amount',
                                               'cancel_reason','problem_code','mode','method','provider','due_date','kind'])
                         then a.new_data -> k end) order by k)
         from jsonb_object_keys(a.new_data) k
        where a.old_data is not null and jsonb_typeof(a.old_data) = 'object' and jsonb_typeof(a.new_data) = 'object'
          and a.old_data -> k is distinct from a.new_data -> k
          and k not in ('updated_at','during','raw','external_meta','attribution','analytics_session_key','pool_ids','participant_breakdown',
                        'snapshot','text_body','pdf_path','pdf_generated_at','pdf_deleted_at','link_url','link_token','public_token',
                        'reminders_paused_at','reminders_handled_at','reminders_needs_action','attempts','last_checked_at','locked_at')),
        '[]'::jsonb) changes,
      case when a.action in ('INSERT','DELETE','UPDATE') then null
           when jsonb_typeof(a.new_data) = 'object' then (select jsonb_agg(k order by k) from jsonb_object_keys(a.new_data) k) end detail_keys
    from src a
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', ev.id, 'at', ev.at, 'action', ev.action, 'table', ev.tbl, 'row_id', ev.row_pk,
      'actor_kind', case when ev.actor is not null and st.user_id is not null then 'staff'
                         when ev.actor_role = 'service_role' then 'system'
                         when ev.actor is null then 'system' else 'user' end,
      'actor_name', st.name, 'changes', ev.changes, 'detail_keys', ev.detail_keys) order by ev.at desc, ev.id desc), '[]'::jsonb)
    into v_rows
    from (select * from ev where ev.action <> 'UPDATE' or jsonb_array_length(ev.changes) > 0 order by ev.at desc, ev.id desc limit v_lim) ev
    left join booking.staff st on st.user_id = ev.actor;
  return jsonb_build_object('order_id', p_order_id, 'events', v_rows, 'limit', v_lim);
end $function$;

-- Tilausnumerolla avaus (#/tilaukset/<nro>): palauttaa tilauksen id:n. Vain lukua.
CREATE OR REPLACE FUNCTION booking.admin_order_lookup(p_order_no bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id bigint; v_no bigint;
begin
  perform booking._require_staff();
  select o.id, o.order_no into v_id, v_no from booking.orders o where o.order_no = p_order_no;
  if v_id is null then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  return jsonb_build_object('order_id', v_id, 'order_no', v_no);
end $function$;

revoke all on function booking.admin_get_order(bigint) from public, anon;
grant execute on function booking.admin_get_order(bigint) to authenticated, service_role;
revoke all on function booking.admin_get_customer(bigint) from public, anon;
grant execute on function booking.admin_get_customer(bigint) to authenticated, service_role;
revoke all on function booking.admin_order_history(bigint, integer) from public, anon;
grant execute on function booking.admin_order_history(bigint, integer) to authenticated, service_role;
revoke all on function booking.admin_order_lookup(bigint) from public, anon;
grant execute on function booking.admin_order_lookup(bigint) to authenticated, service_role;

comment on function booking.admin_order_history(bigint, integer) is
  'booking_278: tilauksen muutoshistoria audit_logista (vain luku, ei henkilötietoja). Tilausnäkymä v3.';
comment on function booking.admin_order_lookup(bigint) is
  'booking_278: tilausnumero → order_id hallinnan reitille #/tilaukset/<nro> (vain luku).';
