-- booking_199: henkilöhintaisen tuotteen kuitilla näkyy henkilömäärä ja à-hinta.
-- booking_198 on toisessa muutoksessa; tämä on 199.
--
-- Varausrivi tallennetaan quantity=1 ja unit_price = koko rivin summa (2 hlö × 29 € → 1 × 58 €).
-- Kuitti näytti siksi "1 × 58,00 €". Henkilöhintaisella rivillä (price_breakdown.mode = per_person),
-- kun summa jakautuu tasan henkilöille, kuitin riville tulee quantity = henkilöt ja unit_gross = veloitettu à-hinta.
-- line_gross, line_net, ALV-erittely ja kuitin loppusumma eivät muutu.
-- Jos jako ei ole tasainen (esim. osamaksu), rivi jää entiselleen.
--
-- Jo luodut testikuitit päivitetään samalla säännöllä ja pdf_path tyhjennetään, jotta PDF piirretään uudestaan.
-- Uniikkia numeroa tai loppusummaa ei muuteta. Migraatiota ei ajeta tästä commitista.

set local lock_timeout = '5s';

create or replace function booking._receipt_per_person_units(p_amount numeric, p_persons integer)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when p_amount is null or p_persons is null or p_persons < 1 then null
    when round(round(p_amount / p_persons, 2) * p_persons, 2) is distinct from round(p_amount, 2) then null
    else jsonb_build_object('quantity', p_persons, 'unit_gross', round(p_amount / p_persons, 2))
  end
$$;

create or replace function booking._receipt_item_persons(p_order_item_id bigint)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when oi.id is null or coalesce(oi.price_breakdown ->> 'mode', '') <> 'per_person' then null
    else coalesce(
      nullif(oi.price_breakdown ->> 'persons', '')::numeric::integer,
      case when oi.kind = 'reservation' then (
        select r.persons from booking.reservations r where r.order_item_id = oi.id order by r.id limit 1
      ) end)
  end
  from booking.order_items oi
  where oi.id = p_order_item_id
$$;

revoke all on function booking._receipt_per_person_units(numeric, integer) from public, anon, authenticated;
revoke all on function booking._receipt_item_persons(bigint) from public, anon, authenticated;
grant execute on function booking._receipt_per_person_units(numeric, integer) to service_role;
grant execute on function booking._receipt_item_persons(bigint) to service_role;

-- Tekstikuitti: "2 × 29,00 € = 58,00 €" ja entinen ALV-erittely. Brutto on yhä line_gross.
create or replace function booking._receipt_text(s jsonb) returns text
language plpgsql
stable
set search_path = ''
as $$
declare en boolean := coalesce(s ->> 'locale', 'fi') = 'en'; loc text := case when coalesce(s ->> 'locale', 'fi') = 'en' then 'en' else 'fi' end; t text[] := '{}'; l jsonb; v jsonb;
        sel jsonb := s -> 'seller'; b jsonb := s -> 'buyer'; d text; title text; refund boolean := s ->> 'document' = 'refund_receipt'; rnd numeric := coalesce((s ->> 'rounding')::numeric, 0);
        v_gross numeric; v_net numeric; v_vat numeric; v_rate numeric;
        w_qty text; w_net text; w_vat text; w_gross text;
begin
  w_qty := booking._published_text('email.receipt_pdf.word_qty', loc, case when en then 'pcs' else 'kpl' end);
  w_net := booking._published_text('email.receipt_pdf.word_net', loc, case when en then 'excl. VAT' else 'veroton' end);
  w_vat := booking._published_text('email.receipt_pdf.word_vat', loc, case when en then 'VAT' else 'ALV' end);
  w_gross := booking._published_text('email.receipt_pdf.word_gross', loc, case when en then 'gross' else 'brutto' end);
  title := case when refund then case when en then 'REFUND RECEIPT' else 'HYVITYSKUITTI' end
                when (s ->> 'invoice_required')::boolean then case when en then 'RECEIPT / INVOICE' else 'KUITTI / LASKU' end
                else case when en then 'RECEIPT' else 'KUITTI' end end;
  t := t || (sel ->> 'name');
  t := t || concat_ws(', ', sel ->> 'legal_name', (case when en then 'Business ID ' else 'Y-tunnus ' end) || (sel ->> 'business_id'), (case when en then 'VAT ID ' else 'ALV-tunnus ' end) || (sel ->> 'vat_id'));
  t := t || concat_ws(', ', sel ->> 'address', concat_ws(' ', sel ->> 'zip', sel ->> 'city'));
  t := t || concat_ws(' · ', sel ->> 'email', sel ->> 'phone', sel ->> 'web');
  t := t || ''::text;
  t := t || (title || ' ' || (s ->> 'receipt_no'));
  t := t || ((case when en then 'Date: ' else 'Päivämäärä: ' end) || replace(s ->> 'issued_local', ' ', case when en then ' at ' else ' klo ' end));
  t := t || ((case when en then 'Order: ' else 'Tilaus: ' end) || (s ->> 'order_no'));
  t := t || ((case when en then 'Payment method: ' else 'Maksutapa: ' end) || coalesce(s -> 'payment' ->> 'method_label', s -> 'payment' ->> 'method'));
  if coalesce((s ->> 'informational')::boolean, false) then
    t := t || booking._published_text('email.receipt_pdf.giftcard_info', loc,
      case when en then 'VAT was recorded when the gift card was sold. This breakdown is for information only and is not recorded again.'
           else 'Arvonlisävero on kirjattu lahjakortin myynnissä. Tämä erittely on vain tiedoksi, eikä sitä kirjata uudelleen.' end);
  end if;
  if b is not null and b <> 'null'::jsonb then
    t := t || ((case when en then 'Buyer: ' else 'Ostaja: ' end) || concat_ws(', ', b ->> 'company', b ->> 'name'));
    t := t || concat_ws(', ', (case when en then 'Business ID ' else 'Y-tunnus ' end) || nullif(b ->> 'business_id', ''), b ->> 'address', concat_ws(' ', b ->> 'zip', b ->> 'city'));
    if nullif(b ->> 'reference', '') is not null then t := t || ((case when en then 'Your reference: ' else 'Viitteenne: ' end) || (b ->> 'reference')); end if;
  end if;
  if s -> 'original' is not null and s -> 'original' <> 'null'::jsonb then
    t := t || ((case when en then 'Original receipt: ' else 'Alkuperäinen kuitti: ' end) || (s -> 'original' ->> 'receipt_no') || ' (' || (s -> 'original' ->> 'issued_local') || ')');
  end if;
  if nullif(s ->> 'reason', '') is not null then t := t || ((case when en then 'Reason: ' else 'Hyvityksen syy: ' end) || (s ->> 'reason')); end if;
  t := t || ''::text;
  for l in select * from jsonb_array_elements(s -> 'lines') loop
    d := l ->> 'description';
    if l ->> 'starts_at' is not null then
      d := d || ' (' || to_char((l ->> 'starts_at')::timestamptz at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI') || '–' || to_char((l ->> 'ends_at')::timestamptz at time zone 'Europe/Helsinki', 'HH24:MI') || ')';
    end if;
    v_gross := coalesce((l ->> 'line_gross')::numeric, 0);
    v_rate := coalesce((l ->> 'vat_rate')::numeric, 0);
    v_net := booking._snap_line_net(l);
    v_vat := v_gross - v_net;
    t := t || d;
    t := t || ('   ' || case
                 when nullif(l ->> 'unit_gross', '') is not null then
                   coalesce(l ->> 'quantity', '1') || ' × ' || booking._money((l ->> 'unit_gross')::numeric, loc)
                   || ' = ' || booking._money(v_gross, loc) || ' · '
                 else coalesce(l ->> 'quantity', '1') || ' ' || w_qty || ' · '
               end
               || w_net || ' ' || booking._money(v_net, loc)
               || ' · ' || w_vat || ' ' || booking._rate_txt(v_rate, loc)
               || ' · ' || w_vat || ' ' || booking._money(v_vat, loc)
               || ' · ' || w_gross || ' ' || booking._money(v_gross, loc));
  end loop;
  t := t || ''::text;
  t := t || (case when en then 'VAT breakdown' else 'ALV-erittely' end);
  for v in select * from jsonb_array_elements(s -> 'vat') loop
    t := t || ((case when en then 'VAT ' else 'ALV ' end) || booking._rate_txt((v ->> 'rate')::numeric, loc) || ': ' || (case when en then 'excl. VAT ' else 'veroton ' end) || booking._money((v ->> 'net')::numeric, loc)
               || (case when en then ', VAT ' else ', ALV ' end) || booking._money((v ->> 'vat')::numeric, loc) || (case when en then ', total ' else ', yhteensä ' end) || booking._money((v ->> 'gross')::numeric, loc));
  end loop;
  t := t || ''::text;
  t := t || ((case when en then 'Total (incl. VAT) ' else 'Yhteensä (sis. ALV) ' end) || booking._money((s ->> 'total_gross')::numeric, loc));
  t := t || ((case when en then 'of which VAT ' else 'josta ALV ' end) || booking._money((s ->> 'total_vat')::numeric, loc) || ', ' || (case when en then 'excl. VAT ' else 'veroton ' end) || booking._money((s ->> 'total_net')::numeric, loc));
  if rnd <> 0 then t := t || ((case when en then 'Cash rounding ' else 'Käteispyöristys ' end) || case when rnd > 0 then '+' else '' end || booking._money(rnd, loc)); end if;
  t := t || ((case when refund then (case when en then 'Refunded ' else 'Hyvitetty ' end) else (case when en then 'Paid ' else 'Maksettu ' end) end) || booking._money((s ->> 'total_paid')::numeric, loc));
  if nullif(sel ->> 'footer', '') is not null then t := t || ''::text || (sel ->> 'footer'); end if;
  return array_to_string(t, E'\n') || E'\n';
end $$;

revoke all on function booking._receipt_text(jsonb) from public, anon, authenticated;
grant execute on function booking._receipt_text(jsonb) to service_role;

create or replace function booking._issue_receipt(p_payment_id bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare pay booking.payments; o booking.orders; pm booking.payment_methods; v_lines jsonb; v_vat jsonb; v_gross numeric; v_vatsum numeric; v_buyer jsonb; v_seq int; v_year int; v_no text;
        v_ts timestamptz := now(); v_snap jsonb; v_id bigint; v_series text;
begin
  select * into pay from booking.payments where id = p_payment_id;
  if not found or pay.amount <= 0 or booking._acct_excluded(pay.order_id, pay.id) then return null; end if;
  select id into v_id from booking.receipts where payment_id = pay.id and kind = 'receipt';
  if found then return v_id; end if;
  select * into o from booking.orders where id = pay.order_id;
  select * into pm from booking.payment_methods where code = pay.method;
  select jsonb_agg(jsonb_build_object(
           'description', concat(pl.description, (select ' – ' || case when o.locale = 'en' then coalesce(po.name_en, po.name) else po.name end from booking.reservations rr join booking.product_options po on po.id = rr.product_option_id where rr.order_item_id = oi.id and oi.kind = 'reservation')),
           'quantity', coalesce((pp.u ->> 'quantity')::int, pl.quantity),
           'unit_gross', coalesce((pp.u ->> 'unit_gross')::numeric, round(pl.amount_gross / greatest(pl.quantity, 1), 2)),
           'unit_net', round(pl.line_net / greatest(coalesce((pp.u ->> 'quantity')::int, pl.quantity, 1), 1), 2),
           'line_gross', pl.amount_gross, 'line_net', pl.line_net, 'vat_rate', pl.vat_rate, 'kind', pl.kind,
           'category', coalesce(case when oi.kind = 'addon' then 'addon' end, prod.category, pl.kind), 'starts_at', r.starts_at, 'ends_at', r.ends_at) order by pl.id)
    into v_lines
    from booking.payment_lines pl
    left join booking.order_items oi on oi.id = pl.order_item_id
    left join kb.products prod on prod.id = oi.product_id
    left join booking.reservations r on r.order_item_id = coalesce(oi.parent_item_id, oi.id)
    left join lateral (
      select booking._receipt_per_person_units(pl.amount_gross, booking._receipt_item_persons(oi.id)) as u
    ) pp on true
   where pl.payment_id = pay.id;
  if v_lines is null then return null; end if;
  v_vat := booking._vat_groups(v_lines);
  select sum((x ->> 'gross')::numeric), sum((x ->> 'vat')::numeric) into v_gross, v_vatsum from jsonb_array_elements(v_vat) x;
  v_buyer := booking._buyer_json(o.id);
  v_year := booking._receipt_year(v_ts);
  v_series := booking._setting('receipt_series', '{"receipt":"K"}'::jsonb) ->> 'receipt';
  v_seq := booking._next_receipt_no(v_series, v_year);
  v_no := format('%s-%s-%s', v_series, v_year, lpad(v_seq::text, 6, '0'));
  v_snap := jsonb_build_object('v', 1, 'document', 'receipt', 'receipt_no', v_no, 'issued_at', v_ts, 'issued_local', to_char(v_ts at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI'),
     'seller', booking._seller(), 'order_no', o.order_no,
     'payment', jsonb_build_object('id', pay.id, 'method', pay.method, 'method_label', case when o.locale = 'en' and pay.method = 'montonio' then 'Pay online' else coalesce(pm.label, pay.method) end, 'paid_at', pay.paid_at),
     'buyer', v_buyer, 'invoice_required', v_buyer is not null and v_gross > 400, 'lines', v_lines, 'vat', v_vat,
     'total_gross', v_gross, 'total_net', v_gross - v_vatsum, 'total_vat', v_vatsum, 'rounding', pay.rounding, 'total_paid', v_gross + pay.rounding,
     'currency', 'EUR', 'original', null, 'reason', null, 'locale', case when o.locale = 'en' then 'en' else 'fi' end);
  insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, issued_at, total_gross, locale, snapshot, text_body, created_by)
  values (v_no, 'receipt', v_series, v_year, v_seq, o.id, pay.id, v_ts, v_gross, v_snap ->> 'locale', v_snap, booking._receipt_text(v_snap), auth.uid()) returning id into v_id;
  if exists (select 1 from booking.integration_config where key = 'procountor' and mode <> 'off') then
    insert into booking.accounting_outbox(kind, order_id, payment_id, receipt_id, dedupe_key, payload, environment)
    values ('receipt', o.id, pay.id, v_id, 'receipt:' || v_id, v_snap, coalesce(booking._setting('procountor_env') #>> '{}', 'pts')) on conflict (dedupe_key) do nothing;
  end if;
  return v_id;
end $$;

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
           'unit_net', case when pp.u is not null then round(( -((x ->> 'amount')::numeric - round((x ->> 'amount')::numeric * pl.vat_rate / (100 + pl.vat_rate), 2)) ) / (pp.u ->> 'quantity')::numeric, 2)
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
      select booking._receipt_per_person_units(-(x ->> 'amount')::numeric, booking._receipt_item_persons(oi.id)) as u
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

revoke all on function booking._issue_receipt(bigint) from public, anon, authenticated;
revoke all on function booking._issue_refund_receipt(bigint) from public, anon, authenticated;
grant execute on function booking._issue_receipt(bigint) to service_role;
grant execute on function booking._issue_refund_receipt(bigint) to service_role;

-- Vanha snapshot: vaihda vain henkilöerittely. Loppusumma, ALV ja kuittinumero säilyvät.
create or replace function booking._receipt_refresh_per_person_qty()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  rec booking.receipts;
  v_lines jsonb;
  v_snap jsonb;
  n integer := 0;
begin
  alter table booking.receipts disable trigger receipts_guard;
  begin
    for rec in
      select * from booking.receipts
       where pdf_deleted_at is null
         and jsonb_typeof(snapshot -> 'lines') = 'array'
    loop
      select coalesce(jsonb_agg(
               case when u.unit is not null
                     and ((e.l ->> 'quantity')::numeric is distinct from u.qty
                       or (e.l ->> 'unit_gross')::numeric is distinct from u.unit)
                    then e.l || jsonb_build_object(
                           'quantity', u.qty,
                           'unit_gross', u.unit,
                           'unit_net', case when nullif(e.l ->> 'line_net', '') is not null and u.qty <> 0
                                            then to_jsonb(round((e.l ->> 'line_net')::numeric / u.qty, 2))
                                            else coalesce(e.l -> 'unit_net', 'null'::jsonb) end)
                    else e.l end
               order by e.ord), '[]'::jsonb)
        into v_lines
        from jsonb_array_elements(rec.snapshot -> 'lines') with ordinality as e(l, ord)
        left join lateral (
          select booking._receipt_per_person_units((e.l ->> 'line_gross')::numeric, p.persons) as ujson
            from (
              select booking._receipt_item_persons(pl.order_item_id) as persons
                from booking.payment_lines pl
               where pl.payment_id = rec.payment_id
                 and (pl.amount_gross = (e.l ->> 'line_gross')::numeric
                   or -pl.amount_gross = (e.l ->> 'line_gross')::numeric)
                 and (e.l ->> 'description' = pl.description
                   or strpos(e.l ->> 'description', pl.description || ' – ') = 1)
               order by (booking._receipt_item_persons(pl.order_item_id) is not null) desc, pl.id
               limit 1
            ) p
        ) m on true
        left join lateral (
          select (m.ujson ->> 'quantity')::numeric as qty, (m.ujson ->> 'unit_gross')::numeric as unit
        ) u on true;
      if v_lines is distinct from (rec.snapshot -> 'lines') then
        v_snap := jsonb_set(rec.snapshot, '{lines}', v_lines);
        update booking.receipts
           set snapshot = v_snap,
               text_body = booking._receipt_text(v_snap),
               pdf_path = null,
               pdf_generated_at = null
         where id = rec.id;
        n := n + 1;
      end if;
    end loop;
    alter table booking.receipts enable trigger receipts_guard;
  exception when others then
    alter table booking.receipts enable trigger receipts_guard;
    raise;
  end;
  return n;
end $$;

revoke all on function booking._receipt_refresh_per_person_qty() from public, anon, authenticated;
grant execute on function booking._receipt_refresh_per_person_qty() to service_role;

select booking._receipt_refresh_per_person_qty();

comment on function booking._receipt_per_person_units(numeric, integer) is
  'booking_199: henkilöhintaisen rivin kpl ja à-hinta, kun summa jakautuu tasan. Muuten null. Ei muuta rivin bruttoa.';
