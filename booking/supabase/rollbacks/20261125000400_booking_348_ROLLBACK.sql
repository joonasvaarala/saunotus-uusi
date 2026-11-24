-- booking_348 ROLLBACK. Funktiot tavu-identtisinä takaisin; uudet funktiot, trigger ja rajoitteet pois.
-- HUOM: jos oikaisukuitteja (kind = 'correction') on jo luotu, rajoitteen palautus epäonnistuu – kuitteja ei saa poistaa (säilytysvelvollisuus); ratkaise ennen rollbackia.
drop trigger if exists receipts_refund_cap on booking.receipts;
drop function if exists booking._receipts_refund_cap_trg();
drop function if exists booking.admin_issue_correction_receipt(bigint, integer[], jsonb, text, boolean);
drop function if exists booking.svc_issue_correction_receipt(bigint, integer[], jsonb, text, text, boolean);
drop function if exists booking._issue_correction_receipt(bigint, integer[], jsonb, text, text, boolean);
CREATE OR REPLACE FUNCTION booking._receipt_text(s jsonb)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
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
    if l ->> 'starts_at' is not null and l ->> 'ends_at' is not null
       and ((l ->> 'starts_at')::timestamptz at time zone 'Europe/Helsinki')::date
           is distinct from ((l ->> 'ends_at')::timestamptz at time zone 'Europe/Helsinki')::date then
      d := d || ' (' || booking._when_range((l ->> 'starts_at')::timestamptz, (l ->> 'ends_at')::timestamptz, loc, (l ->> 'starts_at')::timestamptz) || ')';
    elsif l ->> 'starts_at' is not null then
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
end $function$;

CREATE OR REPLACE FUNCTION booking._issue_refund_receipt(p_refund_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare f booking.refunds; pay booking.payments; o booking.orders; pm booking.payment_methods; orig booking.receipts; v_lines jsonb; v_vat jsonb; v_gross numeric; v_vatsum numeric; v_buyer jsonb;
        v_seq int; v_year int; v_no text; v_ts timestamptz; v_snap jsonb; v_id bigint; v_series text; v_rnd numeric := 0; v_flines jsonb; v_receipted numeric; v_cover bigint;
begin
  select * into f from booking.refunds where id = p_refund_id;
  if not found or f.status <> 'done' then return null; end if;
  select id into v_id from booking.receipts where refund_id = f.id;
  if found then return v_id; end if;
  select * into pay from booking.payments where id = f.payment_id;
  if booking._acct_excluded(pay.order_id, pay.id) then return null; end if;
  -- booking_343: hyvitys on jo katettu aiemmalla hyvityskuitilla (covered_by_receipt_id) → ei uutta kuittia eikä viestiä
  if f.covered_by_receipt_id is not null then return null; end if;
  -- booking_343: jos maksun hyvityskuitit kattavat jo hyvitetyn summan, kuittia ei luoda; hyvitykseen kirjataan kattava kuitti
  select -coalesce(sum(r.total_gross), 0), max(r.id) into v_receipted, v_cover
    from booking.receipts r where r.payment_id = pay.id and r.kind = 'refund_receipt';
  if v_cover is not null and v_receipted >= pay.refunded_amount - 0.004 then
    update booking.refunds set covered_by_receipt_id = v_cover, updated_at = now() where id = f.id;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (auth.uid(), booking._jwt_role(), 'refunds', f.id::text, 'REFUND_RECEIPT_COVERED',
            jsonb_build_object('covered_by_receipt_id', v_cover, 'payment_id', pay.id, 'refunded_amount', pay.refunded_amount, 'receipted', v_receipted, 'amount', f.amount));
    return null;
  end if;
  select * into o from booking.orders where id = f.order_id;
  select * into pm from booking.payment_methods where code = pay.method;
  select * into orig from booking.receipts where payment_id = pay.id and kind = 'receipt';
  -- booking_343: kuitin summa = refunds.amount. Rivit skaalataan summaan, jos ne poikkeavat.
  v_flines := booking._refund_scaled_lines(f.lines, f.amount);
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
    from jsonb_array_elements(v_flines) x
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
  -- booking_343: saman maksun hyvityskuittien summa ei saa ylittää maksun hyvitettyä summaa (osittain katettu → käsin)
  if v_receipted - v_gross > pay.refunded_amount + 0.004 then
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (auth.uid(), booking._jwt_role(), 'refunds', f.id::text, 'REFUND_RECEIPT_BLOCKED',
            jsonb_build_object('reason', 'receipts_exceed_refunded', 'payment_id', pay.id, 'refunded_amount', pay.refunded_amount, 'receipted', v_receipted, 'new', -v_gross));
    return null;
  end if;
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
end $function$;

CREATE OR REPLACE FUNCTION booking._report_json(p_from date, p_to date, p_receipts boolean, p_days boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_res jsonb; v_open jsonb; v_gc_sale numeric; v_gc_ref numeric; v_gc_sale_vat numeric; v_gc_ref_vat numeric; v_gc_red numeric; v_inv numeric; v_money numeric; v_expected numeric; v_gc_lines jsonb;
begin
  v_open := booking._report_open_rows(p_to);
  with jx as (
    select o.payment_status st, coalesce(o.external_meta -> 'johku' ->> 'payment_method', 'unknown') m,
           case when (o.external_meta -> 'johku' ->> 'amount') ~ '^-?\d+(\.\d+)?$' then (o.external_meta -> 'johku' ->> 'amount')::numeric else o.total_gross end amt
      from booking.orders o
     where (o.external_source = 'johku' or o.johku_order_no is not null or o.source_channel = 'johku_import')
       and o.payment_status in ('paid','partially_refunded','refunded')
       and left(o.external_meta -> 'johku' ->> 'paid_at', 10) between to_char(p_from - 1, 'YYYY-MM-DD') and to_char(p_to + 1, 'YYYY-MM-DD')
       and (booking._try_ts(o.external_meta -> 'johku' ->> 'paid_at') at time zone 'Europe/Helsinki')::date between p_from and p_to
  ), rc as (
    select r.id, r.receipt_no, r.kind, r.issued_at, (r.issued_at at time zone 'Europe/Helsinki')::date as d, r.snapshot s, o.order_no,
           r.snapshot -> 'payment' ->> 'method' as method, coalesce(r.snapshot -> 'payment' ->> 'method_label', r.snapshot -> 'payment' ->> 'method') as mlabel,
           r.total_gross as gross, (r.snapshot ->> 'total_net')::numeric as net, (r.snapshot ->> 'total_vat')::numeric as vat, coalesce((r.snapshot ->> 'rounding')::numeric, 0) as rnd
      from booking.receipts r join booking.orders o on o.id = r.order_id
     where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to
       and not booking._acct_excluded(r.order_id, r.payment_id)
       and coalesce(r.snapshot -> 'payment' ->> 'method', '') is distinct from 'invoice'
       and coalesce((r.snapshot ->> 'informational')::boolean, false) = false
  ), tot as (
    select jsonb_build_object('receipts', count(*) filter (where kind = 'receipt'), 'refund_receipts', count(*) filter (where kind = 'refund_receipt'),
             'gross', coalesce(sum(gross) filter (where kind = 'receipt'), 0), 'net', coalesce(sum(net) filter (where kind = 'receipt'), 0), 'vat', coalesce(sum(vat) filter (where kind = 'receipt'), 0),
             'refunds_gross', coalesce(sum(gross) filter (where kind = 'refund_receipt'), 0), 'net_after_refunds', coalesce(sum(gross), 0),
             'vat_after_refunds', coalesce(sum(vat), 0), 'net_ex_vat_after_refunds', coalesce(sum(net), 0), 'rounding', coalesce(sum(rnd), 0)) j from rc
  ), bm as (
    select coalesce(jsonb_agg(jsonb_build_object('method', method, 'label', label, 'payments', pc, 'gross', g, 'refunds', rf, 'rounding', rn) order by method), '[]'::jsonb) j from (
      select method, max(mlabel) label, count(*) filter (where kind = 'receipt') pc, coalesce(sum(gross) filter (where kind = 'receipt'), 0) g,
             coalesce(sum(gross) filter (where kind = 'refund_receipt'), 0) rf, coalesce(sum(rnd), 0) rn from rc group by method) x
  ), vat_rows as (
    select rc.kind, (e ->> 'rate')::numeric as rate, (e ->> 'net')::numeric as net, (e ->> 'vat')::numeric as vat, (e ->> 'gross')::numeric as gross
      from rc, jsonb_array_elements(coalesce(rc.s -> 'vat', '[]'::jsonb)) e
  ), bv as (
    select coalesce(jsonb_agg(jsonb_build_object('rate', rate, 'net', n, 'vat', v, 'gross', g) order by rate), '[]'::jsonb) j from (
      select rate, sum(net) n, sum(vat) v, sum(gross) g from vat_rows group by rate) x
  ), bvs as (
    select coalesce(jsonb_agg(jsonb_build_object('rate', rate, 'net', n, 'vat', v, 'gross', g) order by rate), '[]'::jsonb) j from (
      select rate, sum(net) n, sum(vat) v, sum(gross) g from vat_rows where kind = 'receipt' group by rate) x
  ), bvr as (
    select coalesce(jsonb_agg(jsonb_build_object('rate', rate, 'net', n, 'vat', v, 'gross', g) order by rate), '[]'::jsonb) j from (
      select rate, sum(abs(net)) n, sum(abs(vat)) v, sum(abs(gross)) g from vat_rows where kind = 'refund_receipt' group by rate) x
  ), bmv as (
    select coalesce(jsonb_agg(jsonb_build_object('method', method, 'rate', rate, 'net', n, 'vat', v, 'gross', g) order by method, rate), '[]'::jsonb) j from (
      select method, (e ->> 'rate')::numeric rate, sum((e ->> 'net')::numeric) n, sum((e ->> 'vat')::numeric) v, sum((e ->> 'gross')::numeric) g from rc, jsonb_array_elements(rc.s -> 'vat') e group by 1, 2) x
  ), bc as (
    select coalesce(jsonb_agg(jsonb_build_object('category', cat, 'label', booking._category_label(cat), 'rate', rate, 'quantity', q, 'gross', g, 'net', n, 'vat', g - n) order by cat, rate), '[]'::jsonb) j from (
      select l ->> 'category' cat, (l ->> 'vat_rate')::numeric rate, sum((l ->> 'quantity')::int * case when rc.kind = 'refund_receipt' then -1 else 1 end) q,
             sum((l ->> 'line_gross')::numeric) g, sum(booking._snap_line_net(l)) n from rc, jsonb_array_elements(rc.s -> 'lines') l group by 1, 2) x
  ), ln as (
    select rc.kind, coalesce(l ->> 'kind', '') as line_kind, coalesce(l ->> 'description', '') as product, coalesce((l ->> 'vat_rate')::numeric, 0) as rate,
           coalesce((l ->> 'quantity')::numeric, 0) as qty, booking._snap_line_net(l) as net, coalesce((l ->> 'line_gross')::numeric, 0) as gross
      from rc, jsonb_array_elements(coalesce(rc.s -> 'lines', '[]'::jsonb)) l
  ), bp as (
    select coalesce(jsonb_agg(jsonb_build_object('product', product, 'rate', rate, 'quantity', quantity, 'net', net, 'vat', gross - net, 'gross', gross) order by product, rate), '[]'::jsonb) j,
           coalesce(sum(gross), 0) sales_gross, coalesce(sum(gross - net), 0) sales_vat
      from (select product, rate, sum(qty) quantity, sum(net) net, sum(gross) gross from ln where kind = 'receipt' and line_kind <> 'gift_card' group by product, rate) x
  ), brp as (
    select coalesce(jsonb_agg(jsonb_build_object('product', product, 'rate', rate, 'quantity', quantity, 'net', net, 'vat', gross - net, 'gross', gross) order by product, rate), '[]'::jsonb) j,
           coalesce(sum(gross), 0) refunds_gross, coalesce(sum(gross - net), 0) refunds_vat
      from (select product, rate, sum(abs(qty)) quantity, sum(abs(net)) net, sum(abs(gross)) gross from ln where kind = 'refund_receipt' and line_kind <> 'gift_card' group by product, rate) x
  ), rl as (
    select case when p_receipts then coalesce(jsonb_agg(jsonb_build_object('receipt_no', receipt_no, 'kind', kind, 'issued_at', issued_at, 'order_no', order_no, 'method', method, 'gross', gross, 'net', net, 'vat', vat) order by issued_at, id), '[]'::jsonb) end j from rc
  ), bd as (
    select case when p_days then coalesce(jsonb_agg(jsonb_build_object('date', d, 'receipts', c, 'gross', g, 'vat', v, 'refunds', rf) order by d), '[]'::jsonb) end j from (
      select d, count(*) filter (where kind = 'receipt') c, coalesce(sum(gross) filter (where kind = 'receipt'), 0) g, coalesce(sum(vat), 0) v, coalesce(sum(gross) filter (where kind = 'refund_receipt'), 0) rf from rc group by d) x
  ), js as (
    select jsonb_build_object('label', 'Johku (ei kirjanpitoon)', 'accounting', false, 'basis', 'johku_paid_at',
             'orders', coalesce(count(*) filter (where st in ('paid','partially_refunded')), 0),
             'gross', coalesce(sum(amt) filter (where st in ('paid','partially_refunded')), 0),
             'refunded_orders', coalesce(count(*) filter (where st = 'refunded'), 0),
             'refunded_gross', coalesce(sum(amt) filter (where st = 'refunded'), 0),
             'by_method', coalesce((select jsonb_agg(jsonb_build_object('method', m, 'orders', c, 'gross', g) order by m)
                                      from (select m2.m, count(*) c, sum(m2.amt) g from jx m2 where m2.st in ('paid','partially_refunded') group by m2.m) mm), '[]'::jsonb)) j
      from jx
  ), gc as (
    select jsonb_build_object('label', 'Lahjakortit', 'accounting', 'Ennakkoon maksetun oman kortin lunastus ei ole myyntiä: ALV on kirjattu myynnissä. Maksuttoman kortin lunastus ei luo myyntiä eikä veroa. redeemed_accounted on vanha at_redemption-polku.',
      'redeemed_accounted', (select jsonb_build_object('payments', count(*), 'gross', coalesce(sum(p.amount), 0), 'refunded', coalesce(sum(p.refunded_amount), 0))
          from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id where p.status in ('paid', 'partially_refunded', 'refunded') and g.accounting_origin = 'native' and g.vat_treatment = 'at_redemption'
           and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to),
      'redeemed_prepaid_at_sale', (select jsonb_build_object('payments', count(*), 'gross', coalesce(sum(p.amount), 0), 'refunded', coalesce(sum(p.refunded_amount), 0))
          from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id where p.status in ('paid', 'partially_refunded', 'refunded') and g.accounting_origin = 'native' and g.source is distinct from 'johku' and g.vat_treatment = 'at_sale' and g.complimentary = false
           and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to),
      'redeemed_complimentary', (select jsonb_build_object('payments', count(*), 'gross', coalesce(sum(p.amount), 0), 'refunded', coalesce(sum(p.refunded_amount), 0))
          from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id where p.status in ('paid', 'partially_refunded', 'refunded') and g.accounting_origin = 'native' and g.complimentary
           and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to),
      'redeemed_johku', (select jsonb_build_object('payments', count(*), 'gross', coalesce(sum(p.amount), 0), 'refunded', coalesce(sum(p.refunded_amount), 0))
          from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id where p.status in ('paid', 'partially_refunded', 'refunded') and g.accounting_origin = 'johku'
           and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to),
      'sold', (select jsonb_build_object('cards', count(*), 'gross', coalesce(sum(g.initial_amount), 0),
                 'at_sale_gross', coalesce(sum(g.initial_amount) filter (where g.vat_treatment = 'at_sale'), 0), 'at_redemption_gross', coalesce(sum(g.initial_amount) filter (where g.vat_treatment = 'at_redemption'), 0))
          from booking.gift_cards g where g.source = 'native' and g.purchase_order_id is not null and g.activated_at is not null and (g.activated_at at time zone 'Europe/Helsinki')::date between p_from and p_to),
      'outstanding', (select coalesce(jsonb_agg(jsonb_build_object('accounting_origin', k.ao, 'vat_treatment', k.vt, 'cards', k.c, 'balance', k.b) order by k.ao, k.vt), '[]'::jsonb)
          from (select g.accounting_origin ao, g.vat_treatment vt, count(*) c, coalesce(sum(g.balance), 0) b from booking.gift_cards g
                 where g.status = 'active' and (g.valid_to is null or g.valid_to >= (now() at time zone 'Europe/Helsinki')::date) group by 1, 2) k)) j
  ), op as (
    select jsonb_build_object(
             'orders', coalesce((select count(distinct x ->> 'voucher') from jsonb_array_elements(v_open) x), 0),
             'unpaid', coalesce((select round(coalesce(sum((x ->> 'gross')::numeric), 0), 2) from jsonb_array_elements(v_open) x), 0),
             'rows', v_open) j
  ), ur as (
    select jsonb_build_object('payments', count(*), 'amount', coalesce(sum(p.amount), 0)) j from booking.payments p
     where not booking._acct_excluded(p.order_id, p.id) and p.status in ('paid','partially_refunded','refunded') and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to
       and p.amount > 0
       and not exists (select 1 from booking.receipts r where r.payment_id = p.id and r.kind = 'receipt')
  ), px as (
    select pl.description as product, pl.vat_rate as rate, pl.quantity as qty, pl.line_net as net, pl.amount_gross as gross
      from booking.payments p
      join booking.gift_cards g on g.id = p.gift_card_id
      join booking.payment_lines pl on pl.payment_id = p.id
     where p.method = 'gift_card' and p.status in ('paid', 'partially_refunded', 'refunded')
       and g.accounting_origin = 'native' and g.source is distinct from 'johku' and g.complimentary
       and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to
       and not exists (select 1 from booking.receipts rr where rr.payment_id = p.id and rr.kind = 'receipt' and coalesce((rr.snapshot ->> 'accounting')::boolean, true))
  ), pr as (
    select jsonb_build_object(
      'accounting', false,
      'payments', (select count(*) from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id
                    where p.method = 'gift_card' and p.status in ('paid', 'partially_refunded', 'refunded')
                      and g.accounting_origin = 'native' and g.source is distinct from 'johku' and g.complimentary
                      and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to
                      and not exists (select 1 from booking.receipts rr where rr.payment_id = p.id and rr.kind = 'receipt' and coalesce((rr.snapshot ->> 'accounting')::boolean, true))),
      'gross', coalesce(sum(gross), 0),
      'net', coalesce(sum(net), 0),
      'vat', coalesce(sum(gross - net), 0),
      'lines', coalesce((select jsonb_agg(jsonb_build_object('product', product, 'rate', rate, 'quantity', quantity, 'net', net, 'vat', gross - net, 'gross', gross) order by product, rate)
                           from (select product, rate, sum(qty) quantity, sum(net) net, sum(gross) gross from px group by product, rate) z), '[]'::jsonb),
      'by_vat', coalesce((select jsonb_agg(jsonb_build_object('rate', rate, 'quantity', quantity, 'net', net, 'vat', gross - net, 'gross', gross) order by rate)
                            from (select rate, sum(qty) quantity, sum(net) net, sum(gross) gross from px group by rate) z), '[]'::jsonb)) j
      from px
  ), vs as (
    select coalesce((select jsonb_agg(jsonb_build_object('rate', rate, 'net', net, 'vat', vat, 'gross', gross) order by rate)
                       from (select rate, sum(net) net, sum(gross - net) vat, sum(gross) gross from ln group by rate) z), '[]'::jsonb) j
  ), gcp as (
    select jsonb_build_object(
      'sold', jsonb_build_object(
        'count', coalesce((select sum(qty) from ln where kind = 'receipt' and line_kind = 'gift_card'), 0),
        'net', coalesce((select sum(net) from ln where kind = 'receipt' and line_kind = 'gift_card'), 0),
        'vat', coalesce((select sum(gross - net) from ln where kind = 'receipt' and line_kind = 'gift_card'), 0),
        'gross', coalesce((select sum(gross) from ln where kind = 'receipt' and line_kind = 'gift_card'), 0),
        'lines', coalesce((select jsonb_agg(jsonb_build_object('product', product, 'rate', rate, 'quantity', quantity, 'net', net, 'vat', gross - net, 'gross', gross) order by product, rate)
                             from (select product, rate, sum(qty) quantity, sum(net) net, sum(gross) gross from ln where kind = 'receipt' and line_kind = 'gift_card' group by product, rate) z), '[]'::jsonb),
        'by_vat', coalesce((select jsonb_agg(jsonb_build_object('rate', rate, 'quantity', quantity, 'net', net, 'vat', gross - net, 'gross', gross) order by rate)
                              from (select rate, sum(qty) quantity, sum(net) net, sum(gross) gross from ln where kind = 'receipt' and line_kind = 'gift_card' group by rate) z), '[]'::jsonb)),
      'complimentary', jsonb_build_object(
        'issued_count', coalesce((select count(*) from booking.gift_cards g where g.complimentary and g.accounting_origin = 'native' and g.source is distinct from 'johku'
                                    and (coalesce(g.activated_at, g.created_at) at time zone 'Europe/Helsinki')::date between p_from and p_to), 0),
        'issued_gross', coalesce((select sum(g.initial_amount) from booking.gift_cards g where g.complimentary and g.accounting_origin = 'native' and g.source is distinct from 'johku'
                                    and (coalesce(g.activated_at, g.created_at) at time zone 'Europe/Helsinki')::date between p_from and p_to), 0),
        'redeemed_count', coalesce((select count(*) from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id
                                     where p.method = 'gift_card' and p.status in ('paid', 'partially_refunded', 'refunded') and g.complimentary
                                       and g.accounting_origin = 'native' and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to), 0),
        'redeemed_gross', coalesce((select sum(p.amount) from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id
                                     where p.method = 'gift_card' and p.status in ('paid', 'partially_refunded', 'refunded') and g.complimentary
                                       and g.accounting_origin = 'native' and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to), 0))) j
  )
  select jsonb_build_object('period', jsonb_build_object('from', p_from, 'to', p_to, 'tz', 'Europe/Helsinki'), 'generated_at', now(), 'basis', 'payment (kuitin antamispäivä)',
         'totals', tot.j, 'by_method', bm.j, 'by_vat', bv.j, 'by_vat_sales', bvs.j, 'by_vat_refunds', bvr.j, 'by_method_vat', bmv.j, 'by_category', bc.j,
         'by_product', bp.j, 'refunds_by_product', brp.j, 'vat_summary', vs.j,
         'gift_card_period', gcp.j || jsonb_build_object('open', booking._gc_period_balance(p_from, p_to)),
         'reconciliation', jsonb_build_object(
           'sales_gross', bp.sales_gross,
           'refunds_gross', brp.refunds_gross,
           'product_gross', bp.sales_gross - brp.refunds_gross,
           'payments_gross', (tot.j ->> 'net_after_refunds')::numeric,
           'difference', (tot.j ->> 'net_after_refunds')::numeric - (bp.sales_gross - brp.refunds_gross),
           'methods_net', coalesce((select sum(coalesce((x ->> 'gross')::numeric, 0) + coalesce((x ->> 'refunds')::numeric, 0)) from jsonb_array_elements(bm.j) x), 0),
           'methods_difference', coalesce((select sum(coalesce((x ->> 'gross')::numeric, 0) + coalesce((x ->> 'refunds')::numeric, 0)) from jsonb_array_elements(bm.j) x), 0) - (tot.j ->> 'net_after_refunds')::numeric,
           'line_vat', bp.sales_vat - brp.refunds_vat,
           'receipt_vat', (tot.j ->> 'vat_after_refunds')::numeric,
           'vat_rounding', (tot.j ->> 'vat_after_refunds')::numeric - (bp.sales_vat - brp.refunds_vat),
           'cash_rounding', (tot.j ->> 'rounding')::numeric,
           'rounding_code', case when abs((tot.j ->> 'vat_after_refunds')::numeric - (bp.sales_vat - brp.refunds_vat)) >= 0.005 then 'line_vs_receipt_vat' else null end),
         'open', op.j, 'unreceipted', ur.j, 'prepaid_redemptions', pr.j, 'statistics', jsonb_build_object('johku', js.j, 'gift_cards', gc.j))
         || case when p_receipts then jsonb_build_object('receipts', rl.j) else '{}'::jsonb end
         || case when p_days then jsonb_build_object('by_day', bd.j) else '{}'::jsonb end
    into v_res from tot, bm, bv, bvs, bvr, bmv, bc, rl, bd, op, ur, pr, vs, gcp, js, gc, bp, brp;

  -- Lahjakortin myynti on velka (ei ALV-myyntiä). Lasku ei ole kassakuitti.
  select coalesce(sum((l ->> 'line_gross')::numeric) filter (where r.kind = 'receipt'), 0),
         coalesce(sum((l ->> 'line_gross')::numeric) filter (where r.kind = 'refund_receipt'), 0),
         coalesce(sum(((l ->> 'line_gross')::numeric - booking._snap_line_net(l)) ) filter (where r.kind = 'receipt'), 0),
         coalesce(sum(((l ->> 'line_gross')::numeric - booking._snap_line_net(l)) ) filter (where r.kind = 'refund_receipt'), 0)
    into v_gc_sale, v_gc_ref, v_gc_sale_vat, v_gc_ref_vat
    from booking.receipts r
    cross join lateral jsonb_array_elements(coalesce(r.snapshot -> 'lines', '[]'::jsonb)) l
   where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to
     and not booking._acct_excluded(r.order_id, r.payment_id)
     and coalesce(r.snapshot -> 'payment' ->> 'method', '') is distinct from 'invoice'
     and coalesce((r.snapshot ->> 'informational')::boolean, false) = false
     and coalesce(l ->> 'kind', '') = 'gift_card';
  v_gc_sale := coalesce(v_gc_sale, 0); v_gc_ref := coalesce(v_gc_ref, 0);
  v_gc_sale_vat := coalesce(v_gc_sale_vat, 0); v_gc_ref_vat := coalesce(v_gc_ref_vat, 0);
  v_res := jsonb_set(v_res, '{totals,gross}', to_jsonb(round(coalesce((v_res #>> '{totals,gross}')::numeric, 0) - v_gc_sale, 2)));
  v_res := jsonb_set(v_res, '{totals,net}', to_jsonb(round(coalesce((v_res #>> '{totals,net}')::numeric, 0) - (v_gc_sale - v_gc_sale_vat), 2)));
  v_res := jsonb_set(v_res, '{totals,vat}', to_jsonb(round(coalesce((v_res #>> '{totals,vat}')::numeric, 0) - v_gc_sale_vat, 2)));
  v_res := jsonb_set(v_res, '{totals,refunds_gross}', to_jsonb(round(coalesce((v_res #>> '{totals,refunds_gross}')::numeric, 0) - v_gc_ref, 2)));
  v_res := jsonb_set(v_res, '{totals,net_after_refunds}', to_jsonb(round(coalesce((v_res #>> '{totals,net_after_refunds}')::numeric, 0) - v_gc_sale - v_gc_ref, 2)));
  v_res := jsonb_set(v_res, '{totals,gross_after_refunds}', to_jsonb(round(coalesce((v_res #>> '{totals,net_after_refunds}')::numeric, 0), 2)));
  v_res := jsonb_set(v_res, '{totals,vat_after_refunds}', to_jsonb(round(coalesce((v_res #>> '{totals,vat_after_refunds}')::numeric, 0) - v_gc_sale_vat - v_gc_ref_vat, 2)));
  v_res := jsonb_set(v_res, '{totals,net_ex_vat_after_refunds}', to_jsonb(round(coalesce((v_res #>> '{totals,net_after_refunds}')::numeric, 0) - coalesce((v_res #>> '{totals,vat_after_refunds}')::numeric, 0), 2)));
  select coalesce(round(sum(coalesce((e ->> 'gross')::numeric, 0) + coalesce((e ->> 'refunds')::numeric, 0)) filter (where e ->> 'method' = 'gift_card'), 0), 0)
    into v_gc_red
    from jsonb_array_elements(coalesce(v_res -> 'by_method', '[]'::jsonb)) e;
  select coalesce(round(sum(i.total_gross), 2), 0) into v_inv
    from booking.invoices i
   where i.status not in ('draft', 'voided')
     and i.invoice_date between p_from and p_to;
  v_money := round(coalesce((v_res #>> '{reconciliation,methods_net}')::numeric, 0) - v_gc_red, 2);
  v_expected := round(coalesce((v_res #>> '{totals,net_after_refunds}')::numeric, 0) - v_gc_red + (v_gc_sale + v_gc_ref), 2);
  v_res := jsonb_set(v_res, '{reconciliation,payments_gross}', to_jsonb(round(coalesce((v_res #>> '{totals,net_after_refunds}')::numeric, 0), 2)));
  v_res := jsonb_set(v_res, '{reconciliation,difference}', to_jsonb(round(coalesce((v_res #>> '{totals,net_after_refunds}')::numeric, 0) - coalesce((v_res #>> '{reconciliation,product_gross}')::numeric, 0), 2)));
  v_res := jsonb_set(v_res, '{reconciliation,receipt_vat}', to_jsonb(round(coalesce((v_res #>> '{totals,vat_after_refunds}')::numeric, 0), 2)));
  v_res := jsonb_set(v_res, '{reconciliation,vat_rounding}', to_jsonb(round(coalesce((v_res #>> '{totals,vat_after_refunds}')::numeric, 0) - coalesce((v_res #>> '{reconciliation,line_vat}')::numeric, 0), 2)));
  v_res := jsonb_set(v_res, '{reconciliation,gift_card_sales}', to_jsonb(round(v_gc_sale + v_gc_ref, 2)));
  v_res := jsonb_set(v_res, '{reconciliation,gift_card_redemptions}', to_jsonb(v_gc_red));
  v_res := jsonb_set(v_res, '{reconciliation,invoiced}', to_jsonb(coalesce(v_inv, 0)));
  v_res := jsonb_set(v_res, '{reconciliation,money_received}', to_jsonb(v_money));
  v_res := jsonb_set(v_res, '{reconciliation,expected}', to_jsonb(v_expected));
  v_res := jsonb_set(v_res, '{reconciliation,methods_difference}', to_jsonb(round(v_money - v_expected, 2)));
  select coalesce(jsonb_agg(jsonb_build_object(
           'method', method, 'day', d, 'kind', kind, 'rate', rate, 'net', net, 'vat', vat, 'gross', gross)), '[]'::jsonb)
    into v_gc_lines
    from (
      select coalesce(r.snapshot -> 'payment' ->> 'method', '') as method,
             to_char((r.issued_at at time zone 'Europe/Helsinki')::date, 'YYYY-MM-DD') as d,
             r.kind,
             coalesce((l ->> 'vat_rate')::numeric, 0) as rate,
             sum(booking._snap_line_net(l)) as net,
             sum(coalesce((l ->> 'line_gross')::numeric, 0) - booking._snap_line_net(l)) as vat,
             sum(coalesce((l ->> 'line_gross')::numeric, 0)) as gross
        from booking.receipts r
        cross join lateral jsonb_array_elements(coalesce(r.snapshot -> 'lines', '[]'::jsonb)) l
       where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to
         and not booking._acct_excluded(r.order_id, r.payment_id)
         and coalesce(r.snapshot -> 'payment' ->> 'method', '') is distinct from 'invoice'
         and coalesce((r.snapshot ->> 'informational')::boolean, false) = false
         and coalesce(l ->> 'kind', '') = 'gift_card'
       group by 1, 2, 3, 4
    ) g;
  v_res := jsonb_set(v_res, '{by_vat}', (
    select coalesce(jsonb_agg(jsonb_build_object('rate', rate, 'net', round(net, 2), 'vat', round(vat, 2), 'gross', round(gross, 2)) order by rate), '[]'::jsonb)
      from (
        select rate, sum(net) as net, sum(vat) as vat, sum(gross) as gross
          from (
            select (e ->> 'rate')::numeric as rate, (e ->> 'net')::numeric as net, (e ->> 'vat')::numeric as vat, (e ->> 'gross')::numeric as gross
              from jsonb_array_elements(coalesce(v_res -> 'by_vat', '[]'::jsonb)) e
            union all
            select (e ->> 'rate')::numeric, -(e ->> 'net')::numeric, -(e ->> 'vat')::numeric, -(e ->> 'gross')::numeric
              from jsonb_array_elements(v_gc_lines) e
          ) z
         group by rate
      ) s
     where abs(net) >= 0.005 or abs(vat) >= 0.005 or abs(gross) >= 0.005));
  v_res := jsonb_set(v_res, '{by_vat_sales}', (
    select coalesce(jsonb_agg(jsonb_build_object('rate', rate, 'net', round(net, 2), 'vat', round(vat, 2), 'gross', round(gross, 2)) order by rate), '[]'::jsonb)
      from (
        select rate, sum(net) as net, sum(vat) as vat, sum(gross) as gross
          from (
            select (e ->> 'rate')::numeric as rate, (e ->> 'net')::numeric as net, (e ->> 'vat')::numeric as vat, (e ->> 'gross')::numeric as gross
              from jsonb_array_elements(coalesce(v_res -> 'by_vat_sales', '[]'::jsonb)) e
            union all
            select (e ->> 'rate')::numeric, -(e ->> 'net')::numeric, -(e ->> 'vat')::numeric, -(e ->> 'gross')::numeric
              from jsonb_array_elements(v_gc_lines) e
             where e ->> 'kind' = 'receipt'
          ) z
         group by rate
      ) s
     where abs(net) >= 0.005 or abs(gross) >= 0.005));
  v_res := jsonb_set(v_res, '{by_vat_refunds}', (
    select coalesce(jsonb_agg(jsonb_build_object('rate', rate, 'net', round(net, 2), 'vat', round(vat, 2), 'gross', round(gross, 2)) order by rate), '[]'::jsonb)
      from (
        select rate, sum(net) as net, sum(vat) as vat, sum(gross) as gross
          from (
            select (e ->> 'rate')::numeric as rate, (e ->> 'net')::numeric as net, (e ->> 'vat')::numeric as vat, (e ->> 'gross')::numeric as gross
              from jsonb_array_elements(coalesce(v_res -> 'by_vat_refunds', '[]'::jsonb)) e
            union all
            select (e ->> 'rate')::numeric, -abs((e ->> 'net')::numeric), -abs((e ->> 'vat')::numeric), -abs((e ->> 'gross')::numeric)
              from jsonb_array_elements(v_gc_lines) e
             where e ->> 'kind' = 'refund_receipt'
          ) z
         group by rate
      ) s
     where abs(net) >= 0.005 or abs(gross) >= 0.005));
  v_res := jsonb_set(v_res, '{by_method_vat}', (
    select coalesce(jsonb_agg(jsonb_build_object('method', method, 'rate', rate, 'net', round(net, 2), 'vat', round(vat, 2), 'gross', round(gross, 2)) order by method, rate), '[]'::jsonb)
      from (
        select method, rate, sum(net) as net, sum(vat) as vat, sum(gross) as gross
          from (
            select e ->> 'method' as method, (e ->> 'rate')::numeric as rate, (e ->> 'net')::numeric as net, (e ->> 'vat')::numeric as vat, (e ->> 'gross')::numeric as gross
              from jsonb_array_elements(coalesce(v_res -> 'by_method_vat', '[]'::jsonb)) e
            union all
            select e ->> 'method', (e ->> 'rate')::numeric, -(e ->> 'net')::numeric, -(e ->> 'vat')::numeric, -(e ->> 'gross')::numeric
              from jsonb_array_elements(v_gc_lines) e
          ) z
         group by method, rate
      ) s
     where abs(net) >= 0.005 or abs(gross) >= 0.005));
  if v_res ? 'by_day' then
    v_res := jsonb_set(v_res, '{by_day}', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'date', b.date, 'receipts', b.receipts,
               'gross', round(b.gross - coalesce(g.sg, 0), 2),
               'vat', round(b.vat - coalesce(g.sv, 0), 2),
               'refunds', round(b.refunds - coalesce(g.rg, 0), 2)) order by b.date), '[]'::jsonb)
        from jsonb_to_recordset(v_res -> 'by_day') as b(date date, receipts int, gross numeric, vat numeric, refunds numeric)
        left join (
          select (e ->> 'day')::date as date,
                 sum((e ->> 'gross')::numeric) filter (where e ->> 'kind' = 'receipt') as sg,
                 sum((e ->> 'vat')::numeric) as sv,
                 sum((e ->> 'gross')::numeric) filter (where e ->> 'kind' = 'refund_receipt') as rg
            from jsonb_array_elements(v_gc_lines) e
           group by 1
        ) g on g.date = b.date));
  end if;
  return v_res;
end $function$;

CREATE OR REPLACE FUNCTION booking._accrual_json(p_from date, p_to date, p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb;
begin
  with raw as (
    select r.id as receipt_id, r.kind, r.issued_at, r.order_id, r.original_receipt_id,
           coalesce(l.elem ->> 'description', '') as product,
           coalesce(l.elem ->> 'kind', '') as line_kind,
           coalesce((l.elem ->> 'vat_rate')::numeric, 0) as rate,
           coalesce((l.elem ->> 'quantity')::numeric, 0) as qty,
           booking._snap_line_net(l.elem) as net,
           coalesce((l.elem ->> 'line_gross')::numeric, 0) as gross,
           (r.issued_at at time zone 'Europe/Helsinki')::date as issued_on,
           case
             when coalesce(l.elem ->> 'starts_at', '') ~ '^\d{4}-\d{2}-\d{2}'
               then ((l.elem ->> 'starts_at')::timestamptz at time zone 'Europe/Helsinki')::date
           end as line_day
      from booking.receipts r
      cross join lateral jsonb_array_elements(coalesce(r.snapshot -> 'lines', '[]'::jsonb)) as l(elem)
     where not booking._acct_excluded(r.order_id, r.payment_id)
  ), lined as (
    select raw.*,
           coalesce(
             raw.line_day,
             case when raw.kind = 'refund_receipt' then (
               select ((ol.elem ->> 'starts_at')::timestamptz at time zone 'Europe/Helsinki')::date
                 from booking.receipts orig
                 cross join lateral jsonb_array_elements(coalesce(orig.snapshot -> 'lines', '[]'::jsonb)) ol(elem)
                where orig.id = raw.original_receipt_id
                  and coalesce(ol.elem ->> 'starts_at', '') ~ '^\d{4}-\d{2}-\d{2}'
                  and coalesce(ol.elem ->> 'description', '') = raw.product
                limit 1
             ) end,
             (select min((rr.starts_at at time zone 'Europe/Helsinki')::date)
                from booking.reservations rr
               where rr.order_id = raw.order_id),
             raw.issued_on
           ) as service_on
      from raw
  ), svc as (
    select * from lined where line_kind is distinct from 'gift_card'
  ), sales as (
    select product, rate,
           sum(qty) as quantity,
           sum(net) as net,
           sum(gross - net) as vat,
           sum(gross) as gross
      from svc
     where kind = 'receipt' and service_on between p_from and p_to
     group by product, rate
  ), refs as (
    select product, rate,
           sum(abs(qty)) as quantity,
           sum(abs(net)) as net,
           sum(abs(gross - net)) as vat,
           sum(abs(gross)) as gross
      from svc
     where kind = 'refund_receipt' and service_on between p_from and p_to
     group by product, rate
  ), sales_vat as (
    select rate, sum(quantity) as quantity, sum(net) as net, sum(vat) as vat, sum(gross) as gross
      from sales group by rate
  ), refs_vat as (
    select rate, sum(quantity) as quantity, sum(net) as net, sum(vat) as vat, sum(gross) as gross
      from refs group by rate
  ), adv as (
    select rate,
           sum(net) as net,
           sum(gross - net) as vat,
           sum(gross) as gross,
           count(*) filter (where kind = 'receipt') as sale_lines
      from svc
     where issued_on <= p_as_of and service_on > p_as_of
     group by rate
  ), gc_raw as (
        select coalesce((
                 select sum(l.delta)
                   from booking.gift_card_ledger l
                  where l.gift_card_id = g.id
                    and (l.at at time zone 'Europe/Helsinki')::date <= p_as_of
               ), 0) as bal, g.sale_vat_rate as rate
          from booking.gift_cards g
         where g.accounting_origin is distinct from 'johku'
           and g.source is distinct from 'johku'
           and g.external_source is distinct from 'johku'
           and coalesce(g.complimentary, false) = false
           and g.vat_treatment = 'at_sale'
           and (g.valid_to is null or g.valid_to >= p_as_of)
           and (coalesce(g.activated_at, g.created_at) at time zone 'Europe/Helsinki')::date <= p_as_of
  ), gc as (
    -- booking_347 (K10): ALV kortin omasta myyntikannasta (gift_cards.sale_vat_rate), ei kiinteää 25,5 %:a
    select count(*) filter (where bal > 0.004)::int as cards,
           coalesce(sum(bal) filter (where bal > 0.004), 0) as gross,
           coalesce(sum(round(bal * rate / (100 + rate), 2)) filter (where bal > 0.004 and rate is not null), 0) as vat,
           count(*) filter (where bal > 0.004 and rate is null)::int as no_rate_cards,
           coalesce(jsonb_agg(distinct rate) filter (where bal > 0.004 and rate is not null), '[]'::jsonb) as rates,
           coalesce((select jsonb_agg(jsonb_build_object('rate', q.rate, 'count', q.n, 'gross', q.gross, 'vat', q.vat, 'net', q.gross - q.vat) order by q.rate)
                       from (select z.rate, count(*)::int as n, sum(z.bal) as gross, sum(round(z.bal * z.rate / (100 + z.rate), 2)) as vat
                               from gc_raw z where z.bal > 0.004 and z.rate is not null group by z.rate) q), '[]'::jsonb) as by_rate
      from gc_raw
  )
  select jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to, 'tz', 'Europe/Helsinki',
                                 'kind', case when p_from = p_to then 'day' else 'range' end),
    'generated_at', now(),
    'basis', 'service (palvelupäivä, Europe/Helsinki)',
    'as_of', p_as_of,
    'sales_by_product', coalesce((
      select jsonb_agg(jsonb_build_object('product', product, 'rate', rate, 'quantity', quantity, 'net', net, 'vat', vat, 'gross', gross) order by product, rate)
        from sales), '[]'::jsonb),
    'sales_by_vat', coalesce((
      select jsonb_agg(jsonb_build_object('rate', rate, 'quantity', quantity, 'net', net, 'vat', vat, 'gross', gross) order by rate)
        from sales_vat), '[]'::jsonb),
    'refunds_by_product', coalesce((
      select jsonb_agg(jsonb_build_object('product', product, 'rate', rate, 'quantity', quantity, 'net', net, 'vat', vat, 'gross', gross) order by product, rate)
        from refs), '[]'::jsonb),
    'refunds_by_vat', coalesce((
      select jsonb_agg(jsonb_build_object('rate', rate, 'quantity', quantity, 'net', net, 'vat', vat, 'gross', gross) order by rate)
        from refs_vat), '[]'::jsonb),
    'totals', jsonb_build_object(
      'sales_net', coalesce((select sum(net) from sales), 0),
      'sales_vat', coalesce((select sum(vat) from sales), 0),
      'sales_gross', coalesce((select sum(gross) from sales), 0),
      'refunds_net', coalesce((select sum(net) from refs), 0),
      'refunds_vat', coalesce((select sum(vat) from refs), 0),
      'refunds_gross', coalesce((select sum(gross) from refs), 0),
      'net', coalesce((select sum(net) from sales), 0) - coalesce((select sum(net) from refs), 0),
      'vat', coalesce((select sum(vat) from sales), 0) - coalesce((select sum(vat) from refs), 0),
      'gross', coalesce((select sum(gross) from sales), 0) - coalesce((select sum(gross) from refs), 0)
    ),
    'advances', jsonb_build_object(
      'as_of', p_as_of,
      'services', jsonb_build_object(
        'net', coalesce((select sum(net) from adv), 0),
        'vat', coalesce((select sum(vat) from adv), 0),
        'gross', coalesce((select sum(gross) from adv), 0),
        'lines', coalesce((select sum(sale_lines) from adv), 0),
        'by_vat', coalesce((
          select jsonb_agg(jsonb_build_object('rate', rate, 'net', net, 'vat', vat, 'gross', gross) order by rate)
            from adv), '[]'::jsonb)
      ),
      'gift_cards_unused', jsonb_build_object(
        'count', (select cards from gc),
        'gross', (select gross from gc),
        'vat', (select vat from gc),
        'net', (select gross from gc) - (select vat from gc),
        'rate', (select case when jsonb_array_length(rates) = 1 then (rates ->> 0)::numeric end from gc),
        'by_rate', (select by_rate from gc),
        'cards_without_rate', (select no_rate_cards from gc),
        'vat_at_sale', true
      ),
      'total_gross', coalesce((select sum(gross) from adv), 0) + (select gross from gc)
    )
  ) into v;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION booking._report_tx(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(x.obj order by x.sort_at, x.sort_id, x.sort_n), '[]'::jsonb)
    from (
      select r.issued_at as sort_at, r.id as sort_id, l.n as sort_n,
             jsonb_build_object(
               'voucher', r.receipt_no,
               'date', to_char((r.issued_at at time zone 'Europe/Helsinki')::date, 'YYYY-MM-DD'),
               'customer', coalesce(nullif(btrim(c.name), ''), nullif(r.snapshot -> 'buyer' ->> 'company', ''), nullif(r.snapshot -> 'buyer' ->> 'name', ''), ''),
               'product', coalesce(l.e ->> 'description', ''),
               'quantity', coalesce((l.e ->> 'quantity')::numeric, 1) * case when r.kind = 'refund_receipt' then -1 else 1 end,
               'net', booking._snap_line_net(l.e),
               'vat_rate', coalesce((l.e ->> 'vat_rate')::numeric, 0),
               'vat', coalesce((l.e ->> 'line_gross')::numeric, 0) - booking._snap_line_net(l.e),
               'gross', coalesce((l.e ->> 'line_gross')::numeric, 0),
               'method', coalesce(r.snapshot -> 'payment' ->> 'method', ''),
               'method_label', coalesce(r.snapshot -> 'payment' ->> 'method_label', r.snapshot -> 'payment' ->> 'method', ''),
               'status', 'paid',
               'kind', case when r.kind = 'refund_receipt' then 'refund' else 'sale' end) as obj
        from booking.receipts r
        join booking.orders o on o.id = r.order_id
        left join booking.customers c on c.id = o.customer_id,
             jsonb_array_elements(coalesce(r.snapshot -> 'lines', '[]'::jsonb)) with ordinality as l(e, n)
       where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to
         and not booking._acct_excluded(r.order_id, r.payment_id)
         and coalesce(r.snapshot -> 'payment' ->> 'method', '') is distinct from 'invoice'
         and coalesce((r.snapshot ->> 'informational')::boolean, false) = false
         and coalesce(l.e ->> 'kind', '') is distinct from 'gift_card'
      union all
      select r.issued_at, r.id, l.n,
             jsonb_build_object(
               'voucher', r.receipt_no,
               'date', to_char((r.issued_at at time zone 'Europe/Helsinki')::date, 'YYYY-MM-DD'),
               'customer', coalesce(nullif(btrim(c.name), ''), nullif(r.snapshot -> 'buyer' ->> 'company', ''), nullif(r.snapshot -> 'buyer' ->> 'name', ''), ''),
               'product', coalesce(l.e ->> 'description', ''),
               'quantity', coalesce((l.e ->> 'quantity')::numeric, 1),
               'net', booking._snap_line_net(l.e),
               'vat_rate', coalesce((l.e ->> 'vat_rate')::numeric, 0),
               'vat', coalesce((l.e ->> 'line_gross')::numeric, 0) - booking._snap_line_net(l.e),
               'gross', coalesce((l.e ->> 'line_gross')::numeric, 0),
               'method', coalesce(r.snapshot -> 'payment' ->> 'method', ''),
               'method_label', coalesce(r.snapshot -> 'payment' ->> 'method_label', r.snapshot -> 'payment' ->> 'method', ''),
               'status', 'paid',
               'kind', 'redemption')
        from booking.receipts r
        join booking.orders o on o.id = r.order_id
        join booking.payments p on p.id = r.payment_id
        join booking.gift_cards g on g.id = p.gift_card_id
        left join booking.customers c on c.id = o.customer_id,
             jsonb_array_elements(coalesce(r.snapshot -> 'lines', '[]'::jsonb)) with ordinality as l(e, n)
       where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to
         and coalesce((r.snapshot ->> 'informational')::boolean, false)
         and g.accounting_origin = 'native' and g.source is distinct from 'johku'
         and g.vat_treatment = 'at_sale' and g.complimentary = false
      union all
      select coalesce(o.confirmed_at, o.created_at), o.id, coalesce((x ->> 'item_id')::bigint, 0),
             (x - 'order_id' - 'item_id')
        from jsonb_array_elements(booking._report_open_rows(p_to)) x
        join booking.orders o on o.id = (x ->> 'order_id')::bigint
    ) x
$function$;

CREATE OR REPLACE FUNCTION booking.admin_report_csv(p_from date, p_to date, p_kind text DEFAULT 'lines'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_body text := ''; v_hdr text; v_cr text := E'\r\n'; rep jsonb; el jsonb; rec jsonb; fn text;
begin
  perform booking._report_check(true);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then perform booking._err('invalid_param', 'Virheellinen aikaväli (enintään 366 päivää)'); end if;
  if p_kind is null or p_kind not in ('lines', 'transactions', 'summary', 'vat', 'methods', 'johku_refunds') then perform booking._err('invalid_param', 'p_kind: lines|transactions|summary|vat|methods|johku_refunds'); end if;
  if p_kind in ('lines', 'transactions') then
    v_hdr := 'tosite;pvm;asiakas;tuote;maara;netto;alv_%;alv_eur;brutto;maksutapa;tila;laji';
    fn := format('tapahtumat_%s_%s.csv', p_from, p_to);
    select coalesce(string_agg(concat_ws(';',
             booking._csv(t.x ->> 'voucher'),
             to_char((t.x ->> 'date')::date, 'DD.MM.YYYY'),
             booking._csv(t.x ->> 'customer'),
             booking._csv(t.x ->> 'product'),
             booking._csvnum(coalesce((t.x ->> 'quantity')::numeric, 0)),
             booking._csvmoney(coalesce((t.x ->> 'net')::numeric, 0)),
             booking._csvnum(coalesce((t.x ->> 'vat_rate')::numeric, 0)),
             booking._csvmoney(coalesce((t.x ->> 'vat')::numeric, 0)),
             booking._csvmoney(coalesce((t.x ->> 'gross')::numeric, 0)),
             booking._csv(coalesce(nullif(t.x ->> 'method_label', ''), t.x ->> 'method')),
             case t.x ->> 'status' when 'open' then 'avoin' else 'maksettu' end,
             case t.x ->> 'kind' when 'refund' then 'hyvitys' when 'redemption' then 'lunastus' else 'myynti' end), v_cr order by t.n), '')
      into v_body
      from jsonb_array_elements(booking._report_tx(p_from, p_to)) with ordinality as t(x, n);
  elsif p_kind = 'summary' then
    v_hdr := 'osio;nimi;alv_%;maara;netto;alv_eur;brutto';
    fn := case when p_from = p_to then format('myynti_%s.csv', p_from) else format('myynti_%s_%s.csv', p_from, p_to) end;
    rep := booking._report_json(p_from, p_to, false, false);
    for el in select * from jsonb_array_elements(rep -> 'by_product') loop
      v_body := v_body || concat_ws(';', 'myynti', booking._csv(el ->> 'product'), booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), booking._csvnum(coalesce((el ->> 'quantity')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'refunds_by_product') loop
      v_body := v_body || concat_ws(';', 'hyvitys', booking._csv(el ->> 'product'), booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), booking._csvnum(coalesce((el ->> 'quantity')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'prepaid_redemptions' -> 'lines') loop
      v_body := v_body || concat_ws(';', 'lunastus', booking._csv(el ->> 'product'), booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), booking._csvnum(coalesce((el ->> 'quantity')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'by_vat_sales') loop
      v_body := v_body || concat_ws(';', 'alv_myynti', '', booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), '',
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'by_vat_refunds') loop
      v_body := v_body || concat_ws(';', 'alv_hyvitys', '', booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), '',
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'by_vat') loop
      v_body := v_body || concat_ws(';', 'alv', '', booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), '',
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'gift_card_period' -> 'sold' -> 'by_vat') loop
      v_body := v_body || concat_ws(';', 'lahjakortti_myyty', '', booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), booking._csvnum(coalesce((el ->> 'quantity')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'prepaid_redemptions' -> 'by_vat') loop
      v_body := v_body || concat_ws(';', 'lahjakortti_lunastus', '', booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)), booking._csvnum(coalesce((el ->> 'quantity')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
    rec := rep -> 'reconciliation';
    v_body := v_body || concat_ws(';', 'tasmaytys', 'myynti_brutto', '', '', '', '', booking._csvmoney((rec ->> 'sales_gross')::numeric)) || v_cr;
    v_body := v_body || concat_ws(';', 'tasmaytys', 'hyvitykset_brutto', '', '', '', '', booking._csvmoney((rec ->> 'refunds_gross')::numeric)) || v_cr;
    v_body := v_body || concat_ws(';', 'tasmaytys', 'tuotteet', '', '', '', '', booking._csvmoney((rec ->> 'product_gross')::numeric)) || v_cr;
    v_body := v_body || concat_ws(';', 'tasmaytys', 'alv_rivi', '', '', '', booking._csvmoney((rec ->> 'line_vat')::numeric), '') || v_cr;
    v_body := v_body || concat_ws(';', 'tasmaytys', 'alv_myynti', '', '', '', booking._csvmoney((rec ->> 'receipt_vat')::numeric), '') || v_cr;
    v_body := v_body || concat_ws(';', 'tasmaytys', coalesce(rec ->> 'rounding_code', 'alv_pyoristys'), '', '', '', booking._csvmoney((rec ->> 'vat_rounding')::numeric), '') || v_cr;
    if abs(coalesce((rec ->> 'cash_rounding')::numeric, 0)) >= 0.005 then
      v_body := v_body || concat_ws(';', 'tasmaytys', 'kateispyoristys', '', '', '', '', booking._csvmoney((rec ->> 'cash_rounding')::numeric)) || v_cr;
    end if;
    v_body := v_body || concat_ws(';', 'lahjakortti_avoin', 'oma_alkusaldo', '', '', '', '', booking._csvmoney(coalesce((rep #>> '{gift_card_period,open,native_paid,opening}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'lahjakortti_avoin', 'oma_loppusaldo', '', '', '', '', booking._csvmoney(coalesce((rep #>> '{gift_card_period,open,native_paid,closing}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'lahjakortti_vanhentunut', 'oma', '', '', '', '', booking._csvmoney(coalesce((rep #>> '{gift_card_period,open,native_paid,expired}')::numeric, 0))) || v_cr;
  elsif p_kind = 'methods' then
    v_hdr := 'maksutapa;maksuja;myynti_brutto;hyvitykset;netto';
    fn := case when p_from = p_to then format('maksutavat_%s.csv', p_from) else format('maksutavat_%s_%s.csv', p_from, p_to) end;
    rep := booking._report_json(p_from, p_to, false, false);
    for el in select * from jsonb_array_elements(rep -> 'by_method') loop
      v_body := v_body || concat_ws(';', booking._csv(coalesce(el ->> 'label', el ->> 'method')),
        booking._csvnum(coalesce((el ->> 'payments')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'refunds')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0) + coalesce((el ->> 'refunds')::numeric, 0))) || v_cr;
    end loop;
    v_body := v_body || concat_ws(';', 'tasmaytys', '', '', '', booking._csvmoney(coalesce((rep #>> '{reconciliation,money_received}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'myynti_hyvitysten_jalkeen', '', '', '', booking._csvmoney(coalesce((rep #>> '{totals,net_after_refunds}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'lahjakortti_lunastus', '', '', '', booking._csvmoney(coalesce((rep #>> '{reconciliation,gift_card_redemptions}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'lahjakortti_myyty', '', '', '', booking._csvmoney(coalesce((rep #>> '{reconciliation,gift_card_sales}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'laskutettu', '', '', '', booking._csvmoney(coalesce((rep #>> '{reconciliation,invoiced}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'erotus', '', '', '', booking._csvmoney(coalesce((rep #>> '{reconciliation,methods_difference}')::numeric, 0))) || v_cr;
    for el in select * from jsonb_array_elements(coalesce(rep -> 'open' -> 'rows', '[]'::jsonb)) loop
      v_body := v_body || concat_ws(';', 'avoin', booking._csv(el ->> 'voucher'), booking._csv(el ->> 'product'),
        booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0)), booking._csv(el ->> 'customer')) || v_cr;
    end loop;
    for el in select * from jsonb_array_elements(rep -> 'by_method_vat') loop
      v_body := v_body || concat_ws(';', 'alv_' || booking._csv(el ->> 'method'), booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
  elsif p_kind = 'johku_refunds' then
    v_hdr := 'hyvityspvm;johku_tilaus;tilaus;asiakas;summa;alkuperainen_maksutapa;hyvitystapa;selite';
    fn := case when p_from = p_to then format('johku_hyvitykset_%s.csv', p_from) else format('johku_hyvitykset_%s_%s.csv', p_from, p_to) end;
    rep := booking._report_johku_refunds(p_from, p_to);
    for el in select * from jsonb_array_elements(rep -> 'rows') loop
      v_body := v_body || concat_ws(';', to_char((el ->> 'refund_date')::date, 'DD.MM.YYYY'), booking._csv(el ->> 'johku_order_no'), booking._csv(el ->> 'order_no'),
        booking._csv(el ->> 'customer_name'), booking._csvmoney((el ->> 'amount')::numeric), booking._csv(el ->> 'original_payment_method'),
        booking._csv(el ->> 'refund_method'), booking._csv(el ->> 'note')) || v_cr;
    end loop;
    v_body := v_body || concat_ws(';', 'yhteensa', '', '', '', booking._csvmoney(coalesce((rep ->> 'total')::numeric, 0)), '', '', '') || v_cr;
  else
    v_hdr := 'pvm;tosite;tilaus;tyyppi;maksutapa;alv_prosentti;netto;alv_eur;brutto';
    fn := format('myynti_vat_%s_%s.csv', p_from, p_to);
    select coalesce(string_agg(concat_ws(';', to_char(r.issued_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY'), r.receipt_no, o.order_no::text, case when r.kind = 'receipt' then 'myynti' else 'hyvitys' end,
             booking._csv(r.snapshot -> 'payment' ->> 'method_label'), booking._csvnum((v.e ->> 'rate')::numeric), booking._csvmoney((v.e ->> 'net')::numeric),
             booking._csvmoney((v.e ->> 'vat')::numeric), booking._csvmoney((v.e ->> 'gross')::numeric)), v_cr order by r.issued_at, r.id, v.n), '') into v_body
      from booking.receipts r join booking.orders o on o.id = r.order_id, jsonb_array_elements(r.snapshot -> 'vat') with ordinality as v(e, n)
     where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to
       and not booking._acct_excluded(r.order_id, r.payment_id)
       and coalesce(r.snapshot -> 'payment' ->> 'method', '') is distinct from 'invoice'
       and coalesce((r.snapshot ->> 'informational')::boolean, false) = false;
  end if;
  return jsonb_build_object('filename', fn, 'mime', 'text/csv;charset=utf-8',
                            'content', chr(65279) || v_hdr || v_cr || v_body || case when v_body <> '' then v_cr else '' end);
end $function$;

CREATE OR REPLACE FUNCTION booking._procountor_daily_build(p_date date, p_report jsonb, p_settings jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_receipts int := coalesce((p_report #>> '{totals,receipts}')::int, 0);
  v_refunds int := coalesce((p_report #>> '{totals,refund_receipts}')::int, 0);
  v_rounding numeric := round(coalesce((p_report #>> '{totals,rounding}')::numeric, 0), 2);
  v_unreceipted int := coalesce((p_report #>> '{unreceipted,payments}')::int, 0);
  v_vat_sum numeric := 0;
  v_method_sum numeric := 0;
  v_gc numeric := round(coalesce((p_report #>> '{reconciliation,gift_card_sales}')::numeric, 0), 2);
  v_missing text[] := '{}';
  v_tx jsonb := '[]'::jsonb;
  v_first boolean := true;
  v_status int;
  v_acct text;
  v_method text;
  r record;
  v_vat_round numeric := 0;
  v_first_no text; v_last_no text; v_first_ref text; v_last_ref text; v_range text; v_name text;
begin
  if v_receipts = 0 and v_refunds = 0 and v_gc = 0 then
    if v_unreceipted > 0 then
      return jsonb_build_object('empty', false, 'ready', false, 'missing', jsonb_build_array('unreceipted'), 'request', null);
    end if;
    return jsonb_build_object('empty', true, 'ready', true, 'missing', '[]'::jsonb, 'request', null);
  end if;
  select coalesce(round(sum((e ->> 'gross')::numeric), 2), 0) into v_vat_sum
    from jsonb_array_elements(coalesce(p_report -> 'by_vat', '[]'::jsonb)) e;
  select coalesce(round(sum(coalesce((e ->> 'gross')::numeric, 0) + coalesce((e ->> 'refunds')::numeric, 0)), 2), 0) into v_method_sum
    from jsonb_array_elements(coalesce(p_report -> 'by_method', '[]'::jsonb)) e;
  if abs(v_vat_sum + v_gc - v_method_sum) > 0.05 then
    v_missing := array_append(v_missing, 'imbalance');
  end if;
  if v_unreceipted > 0 then v_missing := array_append(v_missing, 'unreceipted'); end if;
  if coalesce(p_settings ->> 'vat_status', '') ~ '^[0-9]{1,4}$' then v_status := (p_settings ->> 'vat_status')::int;
  else v_missing := array_append(v_missing, 'vat_status'); end if;
  for r in
    select coalesce(e ->> 'method', '') as method,
           round(coalesce((e ->> 'gross')::numeric, 0) + coalesce((e ->> 'refunds')::numeric, 0), 2) as net_gross
      from jsonb_array_elements(coalesce(p_report -> 'by_method', '[]'::jsonb)) e
     order by 1
  loop
    if r.net_gross = 0 then continue; end if;
    v_method := nullif(r.method, '');
    v_acct := nullif(btrim(coalesce(p_settings #>> array['accounts', 'clearing_by_method', coalesce(v_method, '')], '')), '');
    if v_acct is null and booking._is_partner_method(v_method) then
      v_acct := nullif(btrim(coalesce(p_settings #>> array['accounts', 'clearing_by_method', 'partner_voucher'], '')), '');
    end if;
    if v_acct is null or v_acct !~ '^[0-9A-Za-z]{1,20}$' then
      v_missing := array_append(v_missing, 'clearing:' || coalesce(v_method, 'null'));
      v_acct := null;
    end if;
    v_tx := v_tx || jsonb_build_array(jsonb_build_object(
      'transactionType', case when v_first then 'REVERSING_ENTRY' else 'ENTRY' end,
      'account', v_acct, 'accountingValue', r.net_gross, 'vatPercent', 0,
      'description', 'Maksutapa ' || coalesce(v_method, '?')));
    v_first := false;
  end loop;
  if v_gc <> 0 then
    v_acct := nullif(btrim(coalesce(p_settings ->> 'gift_card_liability', '')), '');
    if v_acct is null or v_acct !~ '^[0-9A-Za-z]{1,20}$' then
      v_missing := array_append(v_missing, 'gift_card_liability');
      v_acct := null;
    end if;
    v_tx := v_tx || jsonb_build_array(jsonb_build_object(
      'transactionType', 'ENTRY', 'account', v_acct, 'accountingValue', round(-v_gc, 2), 'vatPercent', 0,
      'description', 'Lahjakortti, monikäyttöinen arvoseteli'));
  end if;
  if v_rounding <> 0 then
    v_acct := nullif(btrim(coalesce(p_settings #>> '{accounts,rounding}', '')), '');
    if v_acct is null or v_acct !~ '^[0-9A-Za-z]{1,20}$' then v_missing := array_append(v_missing, 'rounding'); v_acct := null; end if;
    v_tx := v_tx || jsonb_build_array(jsonb_build_object(
      'transactionType', case when v_first then 'REVERSING_ENTRY' else 'ENTRY' end,
      'account', v_acct, 'accountingValue', round(-v_rounding, 2), 'vatPercent', 0, 'description', 'Käteispyöristys'));
    v_first := false;
  end if;
  for r in
    select (e ->> 'rate')::numeric as rate, round((e ->> 'net')::numeric, 2) as net
      from jsonb_array_elements(coalesce(p_report -> 'by_vat', '[]'::jsonb)) e
     where round(coalesce((e ->> 'net')::numeric, 0), 2) <> 0
     order by 1
  loop
    v_acct := nullif(btrim(coalesce(p_settings #>> array['accounts', 'sales_by_vat', trim_scale(r.rate)::text], '')), '');
    if v_acct is null or v_acct !~ '^[0-9A-Za-z]{1,20}$' then
      v_missing := array_append(v_missing, 'sales:' || trim_scale(r.rate)::text);
      v_acct := null;
    end if;
    v_tx := v_tx || jsonb_build_array(jsonb_build_object(
      'transactionType', 'ENTRY', 'account', v_acct, 'accountingValue', round(-r.net, 2),
      'vatPercent', r.rate, 'description', 'Myynti ALV ' || trim_scale(r.rate)::text));
  end loop;
  -- booking_347 (K5): ALV-pyöristys. Procountor laskee ALV:n nettosummasta kannoittain; raportin ALV on kuittikohtaisten ALV-summien summa
  -- (kuitin snapshotin vat-ryhmät kannoittain, jokainen kuitti pyöristetty erikseen).
  -- Erotus kirjataan tilille accounts.vat_rounding (puuttuu → missing 'vat_rounding').
  select coalesce(round(sum(round(coalesce((e ->> 'vat')::numeric, 0), 2) - round(round(coalesce((e ->> 'net')::numeric, 0), 2) * (e ->> 'rate')::numeric / 100, 2)), 2), 0)
    into v_vat_round
    from jsonb_array_elements(coalesce(p_report -> 'by_vat', '[]'::jsonb)) e
   where coalesce(e ->> 'rate', '') ~ '^[0-9]+([.][0-9]+)?$';
  if v_vat_round <> 0 then
    v_acct := nullif(btrim(coalesce(p_settings #>> '{accounts,vat_rounding}', '')), '');
    if v_acct is null or v_acct !~ '^[0-9A-Za-z]{1,20}$' then v_missing := array_append(v_missing, 'vat_rounding'); v_acct := null; end if;
    v_tx := v_tx || jsonb_build_array(jsonb_build_object(
      'transactionType', 'ENTRY', 'account', v_acct, 'accountingValue', round(-v_vat_round, 2), 'vatPercent', 0, 'description', 'ALV-pyöristys, päivätosite ' || to_char(p_date, 'DD.MM.')));
  end if;
  if jsonb_array_length(v_tx) = 0 then v_missing := array_append(v_missing, 'no_lines'); end if;
  -- booking_347 (K5): kuittinumerot selitteeseen (myyntikuitit ja hyvityskuitit päivältä)
  select min(x.receipt_no) filter (where x.kind = 'receipt'), max(x.receipt_no) filter (where x.kind = 'receipt'),
         min(x.receipt_no) filter (where x.kind = 'refund_receipt'), max(x.receipt_no) filter (where x.kind = 'refund_receipt')
    into v_first_no, v_last_no, v_first_ref, v_last_ref
    from booking.receipts x
   where (x.issued_at at time zone 'Europe/Helsinki')::date = p_date and x.kind in ('receipt', 'refund_receipt');
  v_range := concat_ws(', ',
    case when v_first_no is not null then 'kuitit ' || v_first_no || case when v_last_no <> v_first_no then '–' || v_last_no else '' end end,
    case when v_first_ref is not null then 'hyvitykset ' || v_first_ref || case when v_last_ref <> v_first_ref then '–' || v_last_ref else '' end end);
  v_name := left('Saunotus ' || to_char(p_date, 'YYYY-MM-DD') || case when nullif(v_range, '') is not null then ' (' || v_range || ')' else '' end, 200);
  return jsonb_build_object('empty', false, 'ready', cardinality(v_missing) = 0, 'missing', to_jsonb(v_missing),
    'receipt_range', jsonb_build_object('receipts_from', v_first_no, 'receipts_to', v_last_no, 'refunds_from', v_first_ref, 'refunds_to', v_last_ref),
    'vat_rounding', v_vat_round,
    'attachments', jsonb_build_array(jsonb_build_object('kind', 'daily_report_pdf', 'report', 'sales', 'date', to_char(p_date, 'YYYY-MM-DD'),
                                                        'name', 'Saunotus-paivaraportti-' || to_char(p_date, 'YYYY-MM-DD') || '.pdf')),
    'request', jsonb_build_object('type', 'JOURNAL', 'status', 'UNFINISHED', 'name', v_name,
      'receiptDate', to_char(p_date, 'YYYY-MM-DD'), 'vatType', 'SALES', 'vatStatus', v_status, 'transactions', v_tx));
end $function$;

drop function if exists booking._receipt_class(text, jsonb);
drop index if exists booking.receipts_original_receipt_idx;
alter table booking.receipts drop constraint receipts_check;
alter table booking.receipts add constraint receipts_check check (((kind = 'receipt'::text) and (refund_id is null)) or ((kind = 'refund_receipt'::text) and (refund_id is not null)));
alter table booking.receipts drop constraint receipts_kind_check;
alter table booking.receipts add constraint receipts_kind_check check (kind = any (array['receipt'::text, 'refund_receipt'::text]));
