-- booking_176 ROLLBACK: palauttaa tuotannon määrittelyt tavu tavulta (pg_get_functiondef, luettu sxbofnuisemspgquoxyv 25.10.2026), poistaa _vc_redeem, _vc_partner_order ja taulun vc_difference_payments.
-- Aja yhdessä transaktiossa. Jo jonotetut / lähetetyt viestit jäävät ennalleen. Rollbackin jälkeen erotuksen maksusta lähtee taas kuittisähköposti (booking_174:n käytös).
--   booking._on_payment_paid(bigint): 6abd248cb10998be8c97f3373dcb3504 -> de9084871640d213d10527a045157bf2
--   booking.email_outbox_claim(integer): d355fb47a5c19f90bdcb28615fa54b95 -> 2db9a1233a06e6293d0877f17de1ab72
--   booking.orders_confirmed_mail_trg(): de9df39ff7972a951e61684f8f2db87b -> 85e59930421bf098d24d7fcebd50507d
--   booking.public_submit_voucher_claim(uuid,text,text,bigint): d28a31d27147f4cf7bceb12150c9e77c -> de84e5ce9b1062111c4248e7c582fdb8
--   booking.messages_dispatch(integer): 4b1f94601e23d9dc3eec34bcd5b4dc08 -> 11a25a5f1e02fe5e635a92d8fea3a69f
--   booking._vc_notify_problem(bigint): 3414022269f6db113f1085208eb6f040 -> 85f500444e3af880009fc3b6c0e3a402
--   booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text): a4e69cb26eb44b72eacce7c167342884 -> 525d1fa96fd7c37df4d7e502edf1bf71
--   booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text): 673f26a88054b2b31dcbab872557e383 -> ed28a9a7240b2ae62f5abef66885bc5d
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef('booking._on_payment_paid(bigint)'::regprocedure));
  if v not in ('6abd248cb10998be8c97f3373dcb3504', 'de9084871640d213d10527a045157bf2') then ok := false; msg := msg || ' _on_payment_paid=' || v; end if;
  v := md5(pg_get_functiondef('booking.email_outbox_claim(integer)'::regprocedure));
  if v not in ('d355fb47a5c19f90bdcb28615fa54b95', '2db9a1233a06e6293d0877f17de1ab72') then ok := false; msg := msg || ' email_outbox_claim=' || v; end if;
  v := md5(pg_get_functiondef('booking.orders_confirmed_mail_trg()'::regprocedure));
  if v not in ('de9df39ff7972a951e61684f8f2db87b', '85e59930421bf098d24d7fcebd50507d') then ok := false; msg := msg || ' orders_confirmed_mail_trg=' || v; end if;
  v := md5(pg_get_functiondef('booking.public_submit_voucher_claim(uuid,text,text,bigint)'::regprocedure));
  if v not in ('d28a31d27147f4cf7bceb12150c9e77c', 'de84e5ce9b1062111c4248e7c582fdb8') then ok := false; msg := msg || ' public_submit_voucher_claim=' || v; end if;
  v := md5(pg_get_functiondef('booking.messages_dispatch(integer)'::regprocedure));
  if v not in ('4b1f94601e23d9dc3eec34bcd5b4dc08', '11a25a5f1e02fe5e635a92d8fea3a69f') then ok := false; msg := msg || ' messages_dispatch=' || v; end if;
  v := md5(pg_get_functiondef('booking._vc_notify_problem(bigint)'::regprocedure));
  if v not in ('3414022269f6db113f1085208eb6f040', '85f500444e3af880009fc3b6c0e3a402') then ok := false; msg := msg || ' _vc_notify_problem=' || v; end if;
  v := md5(pg_get_functiondef('booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)'::regprocedure));
  if v not in ('a4e69cb26eb44b72eacce7c167342884', '525d1fa96fd7c37df4d7e502edf1bf71') then ok := false; msg := msg || ' admin_mark_voucher_claim_redeemed=' || v; end if;
  v := md5(pg_get_functiondef('booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text)'::regprocedure));
  if v not in ('673f26a88054b2b31dcbab872557e383', 'ed28a9a7240b2ae62f5abef66885bc5d') then ok := false; msg := msg || ' svc_mark_voucher_claim_redeemed=' || v; end if;
  if not ok then raise exception 'booking_176 rollback: md5 ei vastaa booking_176:tta eikä tuotannon alkuperäistä (%); mitään ei muutettu', msg; end if;
end $g$;

CREATE OR REPLACE FUNCTION booking._on_payment_paid(p_payment_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id bigint; v_order bigint; v_method text;
begin
  v_id := booking._issue_receipt(p_payment_id);
  if v_id is not null then
    select order_id, method into v_order, v_method from booking.payments where id = p_payment_id;
    -- booking_174: kumppanilahjakortti → kuitti vain kirjanpitoon, ei kuittisähköpostia
    if booking._is_partner_method(v_method) then return; end if;
    perform booking._enqueue_email('receipt', v_order, v_id, p_payment_id, 'receipt:' || v_id);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(case when z.item->>'kind' = 'annual_card_code'
    then z.item || jsonb_build_object('annual_card', booking._annual_card_mail((z.item->>'id')::bigint))
                || coalesce(booking._annual_card_admin_to((z.item->>'id')::bigint), '{}'::jsonb)
    when z.item->>'kind' = 'payment_link'
    then z.item || coalesce((select jsonb_build_object('voucher_difference', jsonb_build_object('total', e.payload -> 'total', 'voucher_value', e.payload -> 'voucher_value', 'difference', e.payload -> 'difference'))
                               from booking.email_outbox e where e.id = (z.item->>'id')::bigint and e.payload ->> 'variant' = 'voucher_difference'), '{}'::jsonb)
    else z.item end order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(booking.email_outbox_claim_base_146(p_limit)) with ordinality as z(item, ord);
$function$;

CREATE OR REPLACE FUNCTION booking.orders_confirmed_mail_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pid bigint;
begin
  if new.external_source is not null then return null; end if;
  if booking._enqueue_email('order_confirmation', new.id, null, null, 'order_confirmation:' || new.id) then
    update booking.email_outbox set next_attempt_at = now() + interval '45 seconds' where dedupe_key = 'order_confirmation:' || new.id;
  end if;
  for pid in select p.id from booking.payments p
              join booking.gift_cards g on g.id = p.gift_card_id
              where p.order_id = new.id and p.method = 'gift_card' and p.status in ('paid', 'partially_refunded')
                and not exists (select 1 from booking.receipts rc where rc.payment_id = p.id and rc.kind = 'receipt')
                and g.accounting_origin = 'native' and g.source is distinct from 'johku'
                and g.vat_treatment = 'at_sale' and g.complimentary = false
                and not booking._is_johku_row(new.id, p.id)
              order by p.id loop
    perform booking._issue_giftcard_info_receipt(pid);
  end loop;
  for pid in select p.id from booking.payments p
              where p.order_id = new.id and p.method = 'gift_card' and p.status in ('paid', 'partially_refunded')
                and not exists (select 1 from booking.receipts rc where rc.payment_id = p.id and rc.kind = 'receipt')
                and not booking._acct_excluded(new.id, p.id)
              order by p.id loop
    perform booking._on_payment_paid(pid);
  end loop;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION booking.public_submit_voucher_claim(p_token uuid, p_code text, p_source text, p_order_item_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; v_norm text := booking.gift_code_norm(p_code); v_src text := lower(btrim(coalesce(p_source, ''))); c booking.voucher_claims; ex booking.voucher_claims; cu booking.customers;
        v_guess jsonb; v_unpaid numeric; v_n int; v_max int; v_res bigint; v_detail text; v_msg text;
begin
  if booking._gc_rl_blocked() then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
  if not booking._gc_flag('voucher_claims.enabled') then return jsonb_build_object('ok', false, 'code', 'voucher_claims_disabled', 'message', 'Kumppanilahjakorttien lunastus verkossa ei ole vielä käytössä'); end if;
  if p_token is null or not booking._order_rl('vcsub', p_token, 30, 10) then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
  begin
    select * into o from booking.orders where public_token = p_token for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
    if v_src not in ('elamyslahjat', 'kokemuskauppa', 'offerilla') then perform booking._err('invalid_source', 'Valitse lahjakortin myyjä (Kokemuskauppa, Offerilla tai Elämyslahjat)'); end if;
    if v_norm !~ '^[A-Z0-9]{6,24}$' then perform booking._err('invalid_code', 'Tarkista koodi'); end if;
    if o.external_source is not null or o.status not in ('pending', 'confirmed') then perform booking._err('order_not_editable', 'Tilaukselle ei voi kirjata maksua'); end if;
    if o.status = 'pending' and not exists (select 1 from booking.reservations r where r.order_id = o.id and r.status = 'pending' and r.hold_expires_at > now()) then perform booking._err('order_expired', 'Varaus on vanhentunut'); end if;
    if exists (select 1 from booking.order_items oi where oi.order_id = o.id and oi.kind = 'gift_card') then perform booking._err('gift_card_not_allowed', 'Lahjakortilla ei voi ostaa lahjakorttia'); end if;
    if exists (select 1 from booking.gift_cards g where g.code = v_norm and g.status not in ('cancelled', 'pending_payment')) then perform booking._err('use_own_card', 'Koodi on oma lahjakortti: käytä lahjakortin lunastusta'); end if;
    if p_order_item_id is not null and not exists (select 1 from booking.order_items oi where oi.id = p_order_item_id and oi.order_id = o.id) then perform booking._err('invalid_item', 'Tilausriviä ei löydy'); end if;
    v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
    if v_unpaid <= 0 then perform booking._err('nothing_to_pay', 'Tilauksella ei ole maksettavaa'); end if;
    -- sama koodi jo aktiivisena tällä tilauksella -> idempotentti; muulla tilauksella tai jo lunastettu -> virhe
    select * into ex from booking.voucher_claims where code = v_norm and status in ('open', 'processing', 'redeemed') limit 1;
    if found then
      if ex.order_id = o.id and ex.status in ('open', 'processing') then
        perform booking._gc_log('ok');
        return jsonb_build_object('ok', true, 'already', true, 'claim_no', ex.id, 'status', 'open', 'source', ex.source, 'source_label', booking._vc_source_label(ex.source), 'code_masked', booking._vc_mask(ex.code), 'hold_until', null);
      end if;
      perform booking._err('code_already_claimed', 'Tämä koodi on jo käytössä toisella varauksella');
    end if;
    select count(*) into v_n from booking.voucher_claims where order_id = o.id and status in ('open', 'processing', 'problem');
    v_max := coalesce((booking._setting('voucher_claims.max_per_order', '10'::jsonb) #>> '{}')::int, 10);
    if v_n >= v_max then perform booking._err('too_many_claims', 'Liian monta lahjakoodia tilauksella'); end if;
    -- ongelmatilassa oleva pyyntö korvataan uudella koodilla/lähteellä
    update booking.voucher_claims set status = 'cancelled', resolved_at = now(), resolved_by = 'customer', notes = concat_ws(E'\n', notes, to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' customer: korvattu uudella koodilla')
     where order_id = o.id and status = 'problem' and order_item_id is not distinct from p_order_item_id;
    v_guess := booking._vc_guess(v_norm);
    select * into cu from booking.customers where id = o.customer_id;
    select r.id into v_res from booking.reservations r where r.order_id = o.id and r.status in ('pending', 'confirmed') and r.hidden_at is null order by r.starts_at limit 1;
    insert into booking.voucher_claims(order_id, reservation_id, order_item_id, code, source, source_suggested, customer_name, customer_email, customer_phone, locale)
    values (o.id, v_res, p_order_item_id, v_norm, v_src, v_guess ->> 'source', cu.name, cu.email, cu.phone, case when o.locale in ('fi', 'en', 'sv') then o.locale else 'fi' end) returning * into c;
    perform booking._vc_keep_reserved(o.id);   -- booking_48: varaus ei vanhene pyynnön vuoksi (odottava varaus vahvistetaan, maksamaton saldo jää)
    perform booking._enqueue_email('voucher_claim_received', o.id, null, null, 'vcrecv:' || c.id, jsonb_build_object('claim_id', c.id));
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    if v_detail in ('invalid_code', 'invalid_source', 'not_found') then perform booking._gc_log('invalid'); end if;
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  perform booking._gc_log('ok');
  return jsonb_build_object('ok', true, 'claim_no', c.id, 'status', 'open', 'source', c.source, 'source_label', booking._vc_source_label(c.source), 'code_masked', booking._vc_mask(c.code),
    'payment_method', booking._vc_method(c.source), 'payment_method_label', (select pm.label from booking.payment_methods pm where pm.code = booking._vc_method(c.source)),
    'hold_until', null, 'source_mismatch', (c.source_suggested is not null and c.source_suggested <> c.source and coalesce(v_guess ->> 'confidence', '') in ('high', 'medium')));
end $function$;

CREATE OR REPLACE FUNCTION booking.messages_dispatch(p_limit integer DEFAULT 50)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  n integer := 0;
  lim integer := greatest(least(coalesce(p_limit, 50), 200), 1);
  r record;
  v_dedupe text;
  v_action text;
  v_reason text;
  v_ok boolean;
begin
  if booking._setting('messages.timed_enabled', 'false'::jsonb) is distinct from 'true'::jsonb then
    return 0;
  end if;
  for r in
    with pairs as (
      select m.id as message_id, m.category, o.id as order_id, o.customer_id, o.created_at, o.status as order_status, o.payment_status, o.locale,
             coalesce(c.marketing_consent, false) as marketing_consent,
             m.send_amount, m.send_unit, m.send_direction, m.send_anchor,
             (select coalesce(array_agg(rv.starts_at order by rv.starts_at), '{}')
                from booking.reservations rv
                join booking.message_products mp2 on mp2.product_id = rv.product_id and mp2.message_id = m.id
               where rv.order_id = o.id and rv.status in ('confirmed', 'completed') and rv.hidden_at is null) as arrivals
        from booking.messages m
        join booking.orders o on o.status in ('confirmed', 'completed') and o.external_source is null
        left join booking.customers c on c.id = o.customer_id
       where m.active
         and m.delivery_mode = 'scheduled'
         and m.send_amount is not null
         and o.created_at > now() - interval '18 months'
         and exists (
           select 1 from booking.message_products mp
            where mp.message_id = m.id and mp.product_id = any (booking._order_product_ids(o.id)))
         and not exists (
           select 1 from booking.email_outbox e
            where e.dedupe_key = 'product_message:' || m.id::text || ':' || o.id::text)
    ), decided as (
      select p.*, booking._message_decision(p.created_at, p.arrivals, p.send_amount, p.send_unit, p.send_direction, p.send_anchor, now(), p.order_status, p.payment_status, false) as decision
        from pairs p
    )
    select * from decided
     where decision ->> 'action' in ('send', 'skip')
     order by case when decision ->> 'action' = 'send' then 0 else 1 end,
              (decision ->> 'send_at')::timestamptz nulls last, message_id, order_id
     limit lim
  loop
    v_action := r.decision ->> 'action';
    v_reason := coalesce(r.decision ->> 'reason', 'skip');
    v_dedupe := 'product_message:' || r.message_id::text || ':' || r.order_id::text;
    if v_action = 'send' and r.category = 'after_marketing' and r.customer_id is not null and r.marketing_consent is distinct from true then
      insert into booking.email_outbox(kind, order_id, locale, dedupe_key, status, payload, last_error)
      values ('product_message', r.order_id, coalesce(r.locale, 'fi'), v_dedupe, 'skipped', jsonb_build_object('message_id', r.message_id), 'no_consent')
      on conflict (dedupe_key) do nothing;
    elsif v_action = 'send' then
      v_ok := booking._enqueue_email('product_message', r.order_id, null, null, v_dedupe, jsonb_build_object('message_id', r.message_id));
      if not v_ok and not exists (select 1 from booking.email_outbox e where e.dedupe_key = v_dedupe) then
        insert into booking.email_outbox(kind, order_id, locale, dedupe_key, status, payload, last_error)
        values ('product_message', r.order_id, coalesce(r.locale, 'fi'), v_dedupe, 'skipped', jsonb_build_object('message_id', r.message_id), 'no_email');
      end if;
    else
      insert into booking.email_outbox(kind, order_id, locale, dedupe_key, status, payload, last_error)
      values ('product_message', r.order_id, coalesce(r.locale, 'fi'), v_dedupe, 'skipped', jsonb_build_object('message_id', r.message_id), v_reason)
      on conflict (dedupe_key) do nothing;
    end if;
    n := n + 1;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION booking._vc_notify_problem(p_id bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c booking.voucher_claims; v_ok boolean;
begin
  if not booking._gc_flag('voucher_claims.problem_emails_enabled') then return false; end if;
  select * into c from booking.voucher_claims where id = p_id for update;
  if not found or c.status <> 'problem' or c.problem_notified_at is not null or c.problem_code not in ('invalid_code', 'expired_code', 'already_used') then return false; end if;
  v_ok := booking._enqueue_email('voucher_claim_problem', c.order_id, null, null, 'vcprob:' || c.id || ':' || extract(epoch from c.resolved_at)::bigint, jsonb_build_object('claim_id', c.id, 'problem_code', c.problem_code));
  if v_ok then update booking.voucher_claims set problem_notified_at = now() where id = c.id; end if;
  return v_ok;
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_mark_voucher_claim_redeemed(p_id bigint, p_amount numeric DEFAULT NULL::numeric, p_partner_ref text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c booking.voucher_claims; o booking.orders; v jsonb; v_due numeric; v_link jsonb; v_pid bigint; v_diff numeric; v_mail boolean := false;
begin
  perform booking._require_permission('giftcards.manage');
  if p_amount is not null then
    if p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Lahjakortin arvon pitää olla yli 0 € (enintään 2 desimaalia)'); end if;
    select * into c from booking.voucher_claims where id = p_id for update;
    if found and c.status in ('open', 'processing', 'problem') then
      select * into o from booking.orders where id = c.order_id for update;
      if found and o.status in ('pending', 'confirmed') and o.external_source is null then
        v_due := booking._vc_due(o, c);
        if p_amount > v_due then
          perform booking._err('voucher_exceeds_total', format('Lahjakortin arvo %s € ylittää maksettavan summan %s €', p_amount, v_due));
        end if;
      end if;
    end if;
  end if;
  v := booking._vc_mark_redeemed(p_id, p_amount, p_partner_ref, p_note, 'staff');
  -- booking_174: arvo pienempi kuin maksettava → erotus maksulinkkinä asiakkaalle (Visma Pay -linkki, sähköposti payment_link / voucher_difference)
  if v_due is not null and p_amount < v_due and not coalesce((v ->> 'already')::boolean, false) and (v ->> 'payment_id') is not null then
    select * into o from booking.orders where id = o.id;
    v_link := booking._create_link_payment(o.id, 14, 'Kumppanilahjakortin erotus, pyyntö #' || p_id);
    v_pid := (v_link ->> 'payment_id')::bigint;
    v_diff := (v_link ->> 'amount')::numeric;
    v_mail := booking._enqueue_email('payment_link', o.id, null, v_pid, 'payment_link:voucher_difference:' || p_id || ':' || v_pid,
                jsonb_build_object('variant', 'voucher_difference', 'claim_id', p_id, 'voucher_value', (v ->> 'amount')::numeric, 'difference', v_diff,
                                   'total', (v ->> 'amount')::numeric + v_diff));
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), booking._jwt_role(), 'booking.voucher_claims', p_id::text, 'VOUCHER_DIFFERENCE_LINK', null,
            jsonb_build_object('voucher_value', (v ->> 'amount')::numeric, 'due', v_due, 'difference', v_diff, 'link_payment_id', v_pid, 'email_queued', v_mail));
  end if;
  return v || jsonb_build_object('voucher_value', case when (v ->> 'already')::boolean then null else (v ->> 'amount')::numeric end, 'due', v_due,
    'difference', v_diff, 'payment_link', case when v_pid is not null then booking._link_json(v_pid) || jsonb_build_object('online_payment_enabled', booking._vismapay_online()) end,
    'email_queued', v_mail);
end $function$;

CREATE OR REPLACE FUNCTION booking.svc_mark_voucher_claim_redeemed(p_id bigint, p_amount numeric DEFAULT NULL::numeric, p_partner_ref text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return booking._vc_mark_redeemed(p_id, p_amount, p_partner_ref, p_note, 'bot');
end $function$;

drop function if exists booking._vc_partner_order(bigint);
drop function if exists booking._vc_redeem(bigint,numeric,text,text,text);
drop table if exists booking.vc_difference_payments;

do $v$
begin
  if md5(pg_get_functiondef('booking._on_payment_paid(bigint)'::regprocedure)) <> 'de9084871640d213d10527a045157bf2' then raise exception 'booking_176 rollback: _on_payment_paid ei palautunut tuotannon määrittelyyn'; end if;
  if md5(pg_get_functiondef('booking.email_outbox_claim(integer)'::regprocedure)) <> '2db9a1233a06e6293d0877f17de1ab72' then raise exception 'booking_176 rollback: email_outbox_claim ei palautunut tuotannon määrittelyyn'; end if;
  if md5(pg_get_functiondef('booking.orders_confirmed_mail_trg()'::regprocedure)) <> '85e59930421bf098d24d7fcebd50507d' then raise exception 'booking_176 rollback: orders_confirmed_mail_trg ei palautunut tuotannon määrittelyyn'; end if;
  if md5(pg_get_functiondef('booking.public_submit_voucher_claim(uuid,text,text,bigint)'::regprocedure)) <> 'de84e5ce9b1062111c4248e7c582fdb8' then raise exception 'booking_176 rollback: public_submit_voucher_claim ei palautunut tuotannon määrittelyyn'; end if;
  if md5(pg_get_functiondef('booking.messages_dispatch(integer)'::regprocedure)) <> '11a25a5f1e02fe5e635a92d8fea3a69f' then raise exception 'booking_176 rollback: messages_dispatch ei palautunut tuotannon määrittelyyn'; end if;
  if md5(pg_get_functiondef('booking._vc_notify_problem(bigint)'::regprocedure)) <> '85f500444e3af880009fc3b6c0e3a402' then raise exception 'booking_176 rollback: _vc_notify_problem ei palautunut tuotannon määrittelyyn'; end if;
  if md5(pg_get_functiondef('booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)'::regprocedure)) <> '525d1fa96fd7c37df4d7e502edf1bf71' then raise exception 'booking_176 rollback: admin_mark_voucher_claim_redeemed ei palautunut tuotannon määrittelyyn'; end if;
  if md5(pg_get_functiondef('booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text)'::regprocedure)) <> 'ed28a9a7240b2ae62f5abef66885bc5d' then raise exception 'booking_176 rollback: svc_mark_voucher_claim_redeemed ei palautunut tuotannon määrittelyyn'; end if;
  if to_regprocedure('booking._vc_partner_order(bigint)') is not null then raise exception 'booking_176 rollback: _vc_partner_order jäi'; end if;
  if to_regprocedure('booking._vc_redeem(bigint,numeric,text,text,text)') is not null then raise exception 'booking_176 rollback: _vc_redeem jäi'; end if;
  if to_regclass('booking.vc_difference_payments') is not null then raise exception 'booking_176 rollback: vc_difference_payments jäi'; end if;
end $v$;
