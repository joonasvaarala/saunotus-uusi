-- booking_218: jumissa olevien hyvitysten seuranta ja käsin kirjattu hyvitys.
--
-- Automaattinen hyvitys (Montonio ym.) jää joskus tilaan requested / processing / failed,
-- eikä hyvityskuittia synny ennen kuin tila on done (_on_refund_done → _issue_refund_receipt).
-- Hallinta listaa nämä (admin_list_open_refunds). Uudelleenyritys palauttaa rivin jonoon,
-- kun välittäjä tukee automaattista hyvitystä. Jos rahat palautetaan välittäjän portaalissa,
-- admin_record_manual_refund kirjaa saman kirjanpitopolun kuin onnistunut automaattihyvitys:
-- rivien ja maksun hyvityssummat, tilauksen maksutila, lahjakortin palautus tai mitätöinti,
-- hyvityskuitti ja audit-rivi (henkilökunnan käyttäjä).
--
-- Hyvityskuitin antopäivä on hyvityksen done_at (käsinkirjaus: henkilökunnan antama päivä).
-- Rivin starts_at kopioidaan varauksesta, jotta suoriteperuste löytää palvelupäivän.
-- Oikeus: bookings.manage tai rooli admin. Ei cronia, ei tuotantoajoa.
-- Rollback: ../rollbacks/20261030120000_booking_218_ROLLBACK.sql

set local lock_timeout = '5s';

create or replace function booking._require_refund_watch()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not booking.is_staff() then
    perform booking._err('forbidden', 'Ei oikeuksia');
  end if;
  if booking.is_admin() or booking.has_permission('bookings.manage') then
    return;
  end if;
  perform booking._err('forbidden', 'Ei oikeutta tähän toimintoon (bookings.manage tai admin)');
end $$;

revoke all on function booking._require_refund_watch() from public, anon, authenticated;

create or replace function booking.admin_list_open_refunds(p_search text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
  v_rows jsonb;
  v_aging int;
begin
  perform booking._require_refund_watch();
  with f as (
    select rf.id, rf.payment_id, rf.order_id, rf.amount, rf.reason, rf.status, rf.provider,
           rf.provider_refund_id, rf.provider_status, rf.created_at, rf.updated_at,
           o.order_no, o.locale,
           c.name as customer_name,
           p.method, p.paid_at,
           coalesce(rf.updated_at, rf.created_at) as since,
           (rf.status in ('requested', 'processing')
             and coalesce(rf.updated_at, rf.created_at) < now() - interval '24 hours') as aging
      from booking.refunds rf
      join booking.orders o on o.id = rf.order_id
      join booking.payments p on p.id = rf.payment_id
      left join booking.customers c on c.id = o.customer_id
     where rf.status in ('requested', 'processing', 'failed')
       and o.external_source is null
       and o.johku_order_no is null
       and o.source_channel is distinct from 'johku_import'
       and p.external_source is null
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'refund_id', f.id,
           'payment_id', f.payment_id,
           'order_id', f.order_id,
           'order_no', f.order_no,
           'customer_name', f.customer_name,
           'amount', f.amount,
           'reason', f.reason,
           'status', f.status,
           'provider', f.provider,
           'provider_refund_id', f.provider_refund_id,
           'provider_status', f.provider_status,
           'method', f.method,
           'paid_at', f.paid_at,
           'created_at', f.created_at,
           'updated_at', f.updated_at,
           'age_hours', round(extract(epoch from (now() - f.since)) / 3600.0, 1),
           'aging', f.aging,
           'needs_action', f.status = 'failed' or f.aging,
           'can_retry', f.provider in ('montonio', 'visma_pay', 'mobilepay')
         ) order by (f.status = 'failed') desc, f.aging desc, f.since), '[]'::jsonb),
         count(*) filter (where f.aging)::int
    into v_rows, v_aging
    from f
   where v_q is null
      or f.order_no::text = v_q
      or f.id::text = v_q
      or f.customer_name ilike '%' || replace(v_q, '%', '') || '%'
      or coalesce(f.provider_refund_id, '') ilike '%' || replace(v_q, '%', '') || '%';
  return jsonb_build_object('rows', v_rows, 'aging_count', coalesce(v_aging, 0), 'total', jsonb_array_length(v_rows));
end $$;

create or replace function booking.admin_retry_provider_refund(p_refund_id bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare rf booking.refunds;
begin
  perform booking._require_refund_watch();
  if p_refund_id is null then
    perform booking._err('invalid_param', 'Hyvitys puuttuu');
  end if;
  select * into rf from booking.refunds where id = p_refund_id for update;
  if not found then
    perform booking._err('not_found', 'Hyvitystä ei löydy');
  end if;
  if rf.status = 'done' then
    return jsonb_build_object('ok', true, 'already', true, 'status', 'done', 'refund_id', rf.id);
  end if;
  if rf.status not in ('requested', 'processing', 'failed') then
    perform booking._err('refund_not_pending', 'Hyvitystä ei voi yrittää uudelleen');
  end if;
  if rf.provider not in ('montonio', 'visma_pay', 'mobilepay') then
    perform booking._err('provider_no_retry', 'Tätä hyvitystä ei voi lähettää automaattisesti. Kirjaa se käsin.');
  end if;
  if exists (
    select 1 from booking.orders o
     where o.id = rf.order_id
       and (o.external_source is not null or o.johku_order_no is not null or o.source_channel = 'johku_import')
  ) then
    perform booking._err('order_not_editable', 'Johku-historiaa ei hyvitetä tässä');
  end if;
  update booking.refunds
     set status = 'requested',
         provider_status = case when provider_refund_id is not null then 'retry' else null end,
         updated_at = now()
   where id = rf.id;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (auth.uid(), booking._jwt_role(), 'refunds', rf.id::text, 'REFUND_RETRY',
          jsonb_build_object('provider', rf.provider, 'previous_status', rf.status, 'amount', rf.amount, 'staff', auth.uid()));
  return jsonb_build_object('ok', true, 'refund_id', rf.id, 'status', 'requested', 'provider', rf.provider, 'amount', rf.amount);
end $$;

create or replace function booking.admin_record_manual_refund(
  p_refund_id bigint,
  p_amount numeric,
  p_refunded_on date,
  p_provider_ref text,
  p_note text
) returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  rf booking.refunds;
  pay booking.payments;
  v_ref text := nullif(btrim(coalesce(p_provider_ref, '')), '');
  v_note text := btrim(coalesce(p_note, ''));
  v_done timestamptz;
  v_lines jsonb;
  v_left numeric;
  v_n int;
  v_i int := 0;
  v_alloc numeric;
  el jsonb;
  v_full boolean;
  v_gc boolean;
  rc record;
begin
  perform booking._require_refund_watch();
  if p_refund_id is null then
    perform booking._err('invalid_param', 'Hyvitys puuttuu');
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
    perform booking._err('invalid_amount', 'Virheellinen summa');
  end if;
  if p_refunded_on is null or p_refunded_on > (now() at time zone 'Europe/Helsinki')::date then
    perform booking._err('invalid_param', 'Hyvityspäivä puuttuu tai on tulevaisuudessa');
  end if;
  if v_ref is null or char_length(v_ref) > 120 then
    perform booking._err('invalid_param', 'Anna välittäjän viite (1–120 merkkiä)');
  end if;
  if char_length(v_note) < 3 or char_length(v_note) > 500 then
    perform booking._err('invalid_param', 'Anna huomautus (3–500 merkkiä)');
  end if;

  select * into rf from booking.refunds where id = p_refund_id for update;
  if not found then
    perform booking._err('not_found', 'Hyvitystä ei löydy');
  end if;
  if rf.status = 'done' then
    return jsonb_build_object('ok', true, 'already', true, 'refund_id', rf.id, 'status', 'done');
  end if;
  if rf.status not in ('requested', 'processing', 'failed') then
    perform booking._err('refund_not_pending', 'Hyvitys ei ole avoinna');
  end if;
  if exists (
    select 1 from booking.orders o
     where o.id = rf.order_id
       and (o.external_source is not null or o.johku_order_no is not null or o.source_channel = 'johku_import')
  ) then
    perform booking._err('order_not_editable', 'Johku-historiaa ei hyvitetä tässä');
  end if;
  if p_amount > rf.amount + 0.004 then
    perform booking._err('amount_exceeds_refundable', format('Avoin hyvitys on %s €', rf.amount));
  end if;
  if rf.lines is null or jsonb_typeof(rf.lines) <> 'array' or jsonb_array_length(rf.lines) = 0 then
    perform booking._err('invalid_items', 'Hyvityksellä ei ole rivijakoa');
  end if;

  select * into pay from booking.payments where id = rf.payment_id for update;
  if not found or pay.status not in ('paid', 'partially_refunded') then
    perform booking._err('refund_not_allowed', 'Maksu ei ole hyvitettävissä');
  end if;
  if p_refunded_on < (coalesce(pay.paid_at, pay.created_at) at time zone 'Europe/Helsinki')::date then
    perform booking._err('invalid_param', 'Hyvityspäivä on ennen maksua');
  end if;
  if exists (
    select 1 from booking.refunds x
     where x.provider = rf.provider and x.provider_refund_id = v_ref and x.id <> rf.id
  ) then
    perform booking._err('refund_id_conflict', 'Viite on jo toisella hyvityksellä');
  end if;

  v_lines := rf.lines;
  if abs(p_amount - rf.amount) > 0.004 then
    v_left := p_amount;
    v_n := jsonb_array_length(rf.lines);
    v_lines := '[]'::jsonb;
    for el in select value from jsonb_array_elements(rf.lines) loop
      v_i := v_i + 1;
      if v_i = v_n then
        v_alloc := v_left;
      else
        v_alloc := least(round(p_amount * (el ->> 'amount')::numeric / rf.amount, 2), v_left);
      end if;
      if v_alloc < 0 then
        perform booking._err('invalid_items', 'Rivijakoa ei voitu sovittaa summaan');
      end if;
      if v_alloc > 0 then
        v_lines := v_lines || (el || jsonb_build_object('amount', v_alloc));
        v_left := v_left - v_alloc;
      end if;
    end loop;
    if abs(v_left) > 0.004 then
      perform booking._err('invalid_items', 'Rivijakoa ei voitu sovittaa summaan');
    end if;
  end if;

  v_done := least(now(), (p_refunded_on::timestamp + time '12:00') at time zone 'Europe/Helsinki');
  v_full := abs(p_amount - pay.amount) < 0.005 and pay.refunded_amount = 0;
  v_gc := exists (
    select 1 from booking.payment_lines pl
      join booking.order_items oi on oi.id = pl.order_item_id
     where pl.payment_id = pay.id and oi.kind = 'gift_card'
  ) and exists (
    select 1 from booking.gift_cards gc
     where gc.purchase_order_id = pay.order_id and gc.status <> 'cancelled'
  );

  update booking.refunds
     set amount = p_amount,
         lines = v_lines,
         status = 'done',
         provider_status = 'manual_done',
         provider_refund_id = v_ref,
         done_at = v_done,
         raw = coalesce(raw, '{}'::jsonb) || jsonb_build_object(
           'manual', jsonb_build_object(
             'refunded_on', p_refunded_on,
             'provider_ref', v_ref,
             'note', v_note,
             'staff_user', auth.uid(),
             'recorded_at', now()
           )
         ),
         updated_at = now()
   where id = rf.id;
  rf.amount := p_amount;
  rf.lines := v_lines;

  update booking.payment_lines pl
     set refunded_gross = pl.refunded_gross + (x ->> 'amount')::numeric
    from jsonb_array_elements(v_lines) x
   where pl.id = (x ->> 'payment_line_id')::bigint;
  update booking.payments
     set refunded_amount = refunded_amount + p_amount,
         status = case when refunded_amount + p_amount >= amount - 0.004 then 'refunded' else 'partially_refunded' end
   where id = pay.id;
  perform booking._sync_placeholder(pay.order_id);
  perform booking._refresh_order_payment(pay.order_id);
  perform booking._on_refund_done(rf.id);
  if v_gc and v_full then
    perform booking._gc_cancel_order_cards(pay.order_id, 'Ostomaksu hyvitetty käsin (hyvitys #' || rf.id || ')');
  end if;
  if pay.gift_card_id is not null then
    perform booking._gc_apply(pay.gift_card_id, p_amount, 'refund', pay.order_id, pay.id, 'Hyvitys kortille: ' || v_note);
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (auth.uid(), booking._jwt_role(), 'refunds', rf.id::text, 'MANUAL_REFUND',
          jsonb_build_object(
            'amount', p_amount,
            'refunded_on', p_refunded_on,
            'provider_ref', v_ref,
            'note', v_note,
            'provider', rf.provider,
            'staff', auth.uid()
          ));
  select id, receipt_no into rc from booking.receipts where refund_id = rf.id;
  return jsonb_build_object(
    'ok', true,
    'refund_id', rf.id,
    'status', 'done',
    'amount', p_amount,
    'refunded_on', p_refunded_on,
    'provider_ref', v_ref,
    'receipt_id', rc.id,
    'receipt_no', rc.receipt_no,
    'balance', booking._order_balance(pay.order_id)
  );
end $$;

-- Hyvityskuitti: done_at on tositepäivä; palvelupäivä kopioidaan varauksesta.
create or replace function booking._issue_refund_receipt(p_refund_id bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare f booking.refunds; pay booking.payments; o booking.orders; pm booking.payment_methods; orig booking.receipts; v_lines jsonb; v_vat jsonb; v_gross numeric; v_vatsum numeric; v_buyer jsonb;
        v_seq int; v_year int; v_no text; v_ts timestamptz; v_snap jsonb; v_id bigint; v_series text; v_rnd numeric := 0;
begin
  select * into f from booking.refunds where id = p_refund_id;
  if not found or f.status <> 'done' then return null; end if;
  select id into v_id from booking.receipts where refund_id = f.id;
  if found then return v_id; end if;
  select * into pay from booking.payments where id = f.payment_id;
  if booking._acct_excluded(pay.order_id, pay.id) then return null; end if;
  select * into o from booking.orders where id = f.order_id;
  select * into pm from booking.payment_methods where code = pay.method;
  select * into orig from booking.receipts where payment_id = pay.id and kind = 'receipt';
  select jsonb_agg(jsonb_build_object(
           'description', pl.description,
           'quantity', coalesce((pp.u ->> 'quantity')::int, 1),
           'unit_gross', coalesce((pp.u ->> 'unit_gross')::numeric, -(x ->> 'amount')::numeric),
           'unit_net', case when pp.u is not null then round(( -((x ->> 'amount')::numeric - round((x ->> 'amount')::numeric * pl.vat_rate / (100 + pl.vat_rate), 2)) ) / greatest((pp.u ->> 'quantity')::numeric, 1), 2)
                            else -((x ->> 'amount')::numeric - round((x ->> 'amount')::numeric * pl.vat_rate / (100 + pl.vat_rate), 2)) end,
           'line_gross', -(x ->> 'amount')::numeric,
           'line_net', -((x ->> 'amount')::numeric - round((x ->> 'amount')::numeric * pl.vat_rate / (100 + pl.vat_rate), 2)),
           'vat_rate', pl.vat_rate, 'kind', pl.kind, 'category', coalesce(case when oi.kind = 'addon' then 'addon' end, prod.category, pl.kind),
           'starts_at', svc.starts_at, 'ends_at', svc.ends_at) order by pl.id)
    into v_lines
    from jsonb_array_elements(f.lines) x
    join booking.payment_lines pl on pl.id = (x ->> 'payment_line_id')::bigint
    left join booking.order_items oi on oi.id = pl.order_item_id
    left join kb.products prod on prod.id = oi.product_id
    left join lateral (
      select r.starts_at, r.ends_at
        from booking.reservations r
       where r.order_item_id = coalesce(oi.parent_item_id, oi.id)
       order by r.starts_at
       limit 1
    ) svc on true
    left join lateral (
      select booking._receipt_item_persons(oi.id) as party,
             case when booking._receipt_item_persons(oi.id) >= 1
                       and round(round(pl.amount_gross / booking._receipt_item_persons(oi.id), 2) * booking._receipt_item_persons(oi.id), 2) = round(pl.amount_gross, 2)
                  then round(pl.amount_gross / booking._receipt_item_persons(oi.id), 2) end as unit
    ) src on true
    left join lateral (
      select booking._receipt_refund_units(
               -(x ->> 'amount')::numeric,
               src.unit,
               src.party,
               case when coalesce(x ->> 'persons', '') ~ '^\d{1,3}$' then (x ->> 'persons')::integer end) as u
    ) pp on true;
  if v_lines is null then return null; end if;
  v_vat := booking._vat_groups(v_lines);
  select sum((x ->> 'gross')::numeric), sum((x ->> 'vat')::numeric) into v_gross, v_vatsum from jsonb_array_elements(v_vat) x;
  if pay.method = 'cash' then v_rnd := -booking._cash_rounding(-v_gross); end if;
  v_buyer := booking._buyer_json(o.id);
  v_ts := coalesce(f.done_at, now());
  v_year := booking._receipt_year(v_ts);
  v_series := booking._setting('receipt_series', '{"refund_receipt":"H"}'::jsonb) ->> 'refund_receipt';
  v_seq := booking._next_receipt_no(v_series, v_year);
  v_no := format('%s-%s-%s', v_series, v_year, lpad(v_seq::text, 6, '0'));
  v_snap := jsonb_build_object('v', 1, 'document', 'refund_receipt', 'receipt_no', v_no, 'issued_at', v_ts, 'issued_local', to_char(v_ts at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI'),
     'seller', booking._seller(), 'order_no', o.order_no,
     'payment', jsonb_build_object('id', pay.id, 'method', pay.method, 'method_label', case when o.locale = 'en' and pay.method = 'montonio' then 'Pay online' else coalesce(pm.label, pay.method) end, 'paid_at', pay.paid_at),
     'buyer', v_buyer, 'invoice_required', false, 'lines', v_lines, 'vat', v_vat,
     'total_gross', v_gross, 'total_net', v_gross - v_vatsum, 'total_vat', v_vatsum, 'rounding', v_rnd, 'total_paid', v_gross + v_rnd,
     'currency', 'EUR', 'original', case when orig.id is null then null else jsonb_build_object('receipt_no', orig.receipt_no, 'issued_at', orig.issued_at,
         'issued_local', to_char(orig.issued_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI')) end,
     'reason', f.reason, 'locale', case when o.locale = 'en' then 'en' else 'fi' end);
  insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, refund_id, original_receipt_id, issued_at, total_gross, locale, snapshot, text_body, created_by)
  values (v_no, 'refund_receipt', v_series, v_year, v_seq, o.id, pay.id, f.id, orig.id, v_ts, v_gross, v_snap ->> 'locale', v_snap, booking._receipt_text(v_snap), auth.uid()) returning id into v_id;
  if exists (select 1 from booking.integration_config where key = 'procountor' and mode <> 'off') then
    insert into booking.accounting_outbox(kind, order_id, payment_id, receipt_id, dedupe_key, payload, environment)
    values ('refund_receipt', o.id, pay.id, v_id, 'receipt:' || v_id, v_snap, coalesce(booking._setting('procountor_env') #>> '{}', 'pts')) on conflict (dedupe_key) do nothing;
  end if;
  return v_id;
end $$;

revoke all on function booking.admin_list_open_refunds(text) from public, anon, authenticated;
grant execute on function booking.admin_list_open_refunds(text) to authenticated, service_role;
revoke all on function booking.admin_retry_provider_refund(bigint) from public, anon, authenticated;
grant execute on function booking.admin_retry_provider_refund(bigint) to authenticated, service_role;
revoke all on function booking.admin_record_manual_refund(bigint, numeric, date, text, text) from public, anon, authenticated;
grant execute on function booking.admin_record_manual_refund(bigint, numeric, date, text, text) to authenticated, service_role;
revoke all on function booking._issue_refund_receipt(bigint) from public, anon, authenticated;
grant execute on function booking._issue_refund_receipt(bigint) to service_role;

comment on function booking.admin_list_open_refunds(text) is
  'booking_218: avoimet hyvitykset (requested/processing/failed). aging = odottanut yli 24 h. Oikeus bookings.manage tai admin.';
comment on function booking.admin_retry_provider_refund(bigint) is
  'booking_218: palauttaa epäonnistuneen tai jumissa olevan automaattihyvityksen jonoon (requested). Ei liikuta rahaa itse.';
comment on function booking.admin_record_manual_refund(bigint, numeric, date, text, text) is
  'booking_218: käsin portaalissa tehty hyvitys. Sama kirjanpito kuin onnistunut automaattihyvitys (hyvityskuitti, rivit, audit).';
