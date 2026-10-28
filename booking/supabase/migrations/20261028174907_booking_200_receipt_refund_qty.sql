-- booking_200: hyvityskuitin henkilömäärä ja kertafunktion poisto.
--
-- booking._receipt_refresh_per_person_qty() oli booking_199:n kertakorjaus. Se sammuttaa
-- receipts_guard-triggerin, joten sitä ei jätetä kutsuttavaksi.
--
-- Osahyvitys: yhden henkilön osuus (29 €) kahden henkilön 58 € rivistä näytetään
-- "1 × -29,00 €", ei "2 × -14,50 €". Määrä on hyvitetyt henkilöt, kun se tiedetään
-- (rivin persons-kenttä, tai summa on tasakertainen à-hinta). Muuten 1 × hyvityssumma.
-- Rivin brutto, line_net, ALV ja kuitin loppusumma eivät muutu.
-- Migraatiota ei ajeta tästä commitista.

set local lock_timeout = '5s';

drop function if exists booking._receipt_refresh_per_person_qty();

-- p_amount on rivin etumerkillinen brutto (hyvityksessä negatiivinen).
-- p_unit on alkuperäinen positiivinen à-hinta, p_party alkuperäinen henkilömäärä.
-- p_refunded_persons on hyvitysrivin persons, jos se on annettu.
create or replace function booking._receipt_refund_units(
  p_amount numeric,
  p_unit numeric,
  p_party integer,
  p_refunded_persons integer
) returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when p_amount is null then null
    when p_refunded_persons is not null and p_refunded_persons >= 1
         and p_unit is not null and p_unit <> 0
         and round(abs(p_unit) * p_refunded_persons, 2) = round(abs(p_amount), 2)
      then jsonb_build_object('quantity', p_refunded_persons,
             'unit_gross', case when p_amount < 0 then -abs(round(p_unit, 2)) else abs(round(p_unit, 2)) end)
    when p_unit is not null and p_unit <> 0
         and trunc(abs(p_amount) / abs(p_unit))::integer >= 1
         and (p_party is null or trunc(abs(p_amount) / abs(p_unit))::integer <= greatest(p_party, 1))
         and round(abs(p_unit) * trunc(abs(p_amount) / abs(p_unit))::integer, 2) = round(abs(p_amount), 2)
      then jsonb_build_object(
             'quantity', trunc(abs(p_amount) / abs(p_unit))::integer,
             'unit_gross', case when p_amount < 0 then -abs(round(p_unit, 2)) else abs(round(p_unit, 2)) end)
    else jsonb_build_object('quantity', 1, 'unit_gross', p_amount)
  end
$$;

revoke all on function booking._receipt_refund_units(numeric, numeric, integer, integer) from public, anon, authenticated;
grant execute on function booking._receipt_refund_units(numeric, numeric, integer, integer) to service_role;

create or replace function booking._issue_refund_receipt(p_refund_id bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare f booking.refunds; pay booking.payments; o booking.orders; pm booking.payment_methods; orig booking.receipts; v_lines jsonb; v_vat jsonb; v_gross numeric; v_vatsum numeric; v_buyer jsonb;
        v_seq int; v_year int; v_no text; v_ts timestamptz := now(); v_snap jsonb; v_id bigint; v_series text; v_rnd numeric := 0;
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
           'vat_rate', pl.vat_rate, 'kind', pl.kind, 'category', coalesce(case when oi.kind = 'addon' then 'addon' end, prod.category, pl.kind), 'starts_at', null, 'ends_at', null) order by pl.id)
    into v_lines
    from jsonb_array_elements(f.lines) x
    join booking.payment_lines pl on pl.id = (x ->> 'payment_line_id')::bigint
    left join booking.order_items oi on oi.id = pl.order_item_id
    left join kb.products prod on prod.id = oi.product_id
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

revoke all on function booking._issue_refund_receipt(bigint) from public, anon, authenticated;
grant execute on function booking._issue_refund_receipt(bigint) to service_role;

comment on function booking._receipt_refund_units(numeric, numeric, integer, integer) is
  'booking_200: hyvitysrivin kpl ja à-hinta. Tasakertainen à-hinta tai rivin persons; muuten 1 × summa. Ei muuta bruttoa.';
