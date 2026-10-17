-- booking_41_johku_ei_kirjanpitoon (17.10.2026)
-- Päätös (Joonas): Johku pysyy omanaan; Johku-lähtöiset myynnit/maksut eivät saa näkyä uuden järjestelmän kirjanpidossa eivätkä lähteä kirjanpitäjälle,
-- mutta näkyvät kokonaisstatistiikassa (admin_list_orders, dashboard ennallaan).
-- Lähtötilanne (tuotanto 17.10.): Johku-tilauksilla (external_source='johku', source_channel='johku_import', johku_order_no) EI ole payments/payment_lines/receipts/accounting_outbox-rivejä;
--   Johku-maksutieto on vain orders.payment_status + orders.external_meta.johku{paid,amount,paid_at,payment_method}. Suojaus perustui vain payments.external_source-tarkistukseen
--   (kuitti/triggeri) ja raportin open/unreceipted-suodattimeen. Tämä migraatio tekee suojasta tilaus- ja maksutasoisen sekä lisää raporttien/CSV:n/outboxin kovat suodattimet.
-- Muutokset (additiivinen; ei skeemamuutoksia tauluihin, ei datamuutoksia):
--   1) booking._acct_excluded(order_id, payment_id) = Johku-lähtöinen (tilaus: external_source / johku_order_no / source_channel='johku_import'; maksu: external_source) – vain service_role
--   2) booking._try_ts(text) turvallinen aikaleimaparsinta (tilastolohko)
--   3) _issue_receipt, _issue_refund_receipt, payments_paid_trg: ohita Johku-lähtöinen (myös kun vain tilaus on Johku)
--   4) triggerit: receipts BEFORE INSERT (estää Johku-kuitin, BK001 johku_not_accounted), accounting_outbox BEFORE INSERT (Johku-rivi hylätään hiljaa, RETURN NULL)
--   5) _report_json (-> admin_report_daily/month): suodatus + uusi avain statistics.johku; admin_report_csv: suodatus; report-pdf käyttää RPC:tä => Johku ei PDF:ssä
--   6) admin_list_payments: rivillä source ('johku'|'native') + is_johku; ylätasolla sum_paid_ex_johku, sum_refunded_ex_johku, johku_rows (vanhat avaimet ennallaan)
-- Rollback: booking_41_ROLLBACK.sql

create or replace function booking._acct_excluded(p_order_id bigint, p_payment_id bigint default null)
 returns boolean language sql stable security definer set search_path to ''
as $$
  select coalesce((select true from booking.orders o
                    where o.id = coalesce(p_order_id, (select p.order_id from booking.payments p where p.id = p_payment_id))
                      and (o.external_source is not null or o.johku_order_no is not null or o.source_channel = 'johku_import')), false)
      or coalesce((select true from booking.payments p where p.id = p_payment_id and p.external_source is not null), false)
$$;
comment on function booking._acct_excluded(bigint, bigint) is 'true = Johku-lähtöinen tilaus/maksu: ei kuitteihin, kirjanpitoraportteihin eikä accounting_outboxiin (booking_41)';

create or replace function booking._try_ts(p_txt text) returns timestamptz language plpgsql stable set search_path to ''
as $$ begin return p_txt::timestamptz; exception when others then return null; end $$;

CREATE OR REPLACE FUNCTION booking._issue_receipt(p_payment_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments; o booking.orders; pm booking.payment_methods; v_lines jsonb; v_vat jsonb; v_gross numeric; v_vatsum numeric; v_buyer jsonb; v_seq int; v_year int; v_no text;
        v_ts timestamptz := now(); v_snap jsonb; v_id bigint; v_series text;
begin
  select * into pay from booking.payments where id = p_payment_id;
  if not found or pay.amount <= 0 or booking._acct_excluded(pay.order_id, pay.id) then return null; end if;   -- Johku-lähtöinen (tilaus tai maksu) ei kuittiin/kirjanpitoon
  select id into v_id from booking.receipts where payment_id = pay.id and kind = 'receipt';
  if found then return v_id; end if;
  select * into o from booking.orders where id = pay.order_id;
  select * into pm from booking.payment_methods where code = pay.method;
  select jsonb_agg(jsonb_build_object('description', pl.description, 'quantity', pl.quantity, 'unit_gross', round(pl.amount_gross / greatest(pl.quantity, 1), 2),
           'unit_net', round(pl.line_net / greatest(pl.quantity, 1), 2), 'line_gross', pl.amount_gross, 'line_net', pl.line_net, 'vat_rate', pl.vat_rate, 'kind', pl.kind,
           'category', coalesce(case when oi.kind = 'addon' then 'addon' end, prod.category, pl.kind), 'starts_at', r.starts_at, 'ends_at', r.ends_at) order by pl.id)
    into v_lines
    from booking.payment_lines pl left join booking.order_items oi on oi.id = pl.order_item_id left join kb.products prod on prod.id = oi.product_id
    left join booking.reservations r on r.order_item_id = coalesce(oi.parent_item_id, oi.id)
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
     'payment', jsonb_build_object('id', pay.id, 'method', pay.method, 'method_label', coalesce(pm.label, pay.method), 'paid_at', pay.paid_at),
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
end $function$
;

CREATE OR REPLACE FUNCTION booking._issue_refund_receipt(p_refund_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare f booking.refunds; pay booking.payments; o booking.orders; pm booking.payment_methods; orig booking.receipts; v_lines jsonb; v_vat jsonb; v_gross numeric; v_vatsum numeric; v_buyer jsonb;
        v_seq int; v_year int; v_no text; v_ts timestamptz := now(); v_snap jsonb; v_id bigint; v_series text; v_rnd numeric := 0;
begin
  select * into f from booking.refunds where id = p_refund_id;
  if not found or f.status <> 'done' then return null; end if;
  select id into v_id from booking.receipts where refund_id = f.id;
  if found then return v_id; end if;
  select * into pay from booking.payments where id = f.payment_id;
  if booking._acct_excluded(pay.order_id, pay.id) then return null; end if;   -- Johku-lähtöinen ei hyvityskuittiin/kirjanpitoon
  select * into o from booking.orders where id = f.order_id;
  select * into pm from booking.payment_methods where code = pay.method;
  select * into orig from booking.receipts where payment_id = pay.id and kind = 'receipt';
  select jsonb_agg(jsonb_build_object('description', pl.description, 'quantity', 1, 'unit_gross', -(x ->> 'amount')::numeric,
           'unit_net', -((x ->> 'amount')::numeric - round((x ->> 'amount')::numeric * pl.vat_rate / (100 + pl.vat_rate), 2)),
           'line_gross', -(x ->> 'amount')::numeric, 'line_net', -((x ->> 'amount')::numeric - round((x ->> 'amount')::numeric * pl.vat_rate / (100 + pl.vat_rate), 2)),
           'vat_rate', pl.vat_rate, 'kind', pl.kind, 'category', coalesce(case when oi.kind = 'addon' then 'addon' end, prod.category, pl.kind), 'starts_at', null, 'ends_at', null) order by pl.id)
    into v_lines
    from jsonb_array_elements(f.lines) x join booking.payment_lines pl on pl.id = (x ->> 'payment_line_id')::bigint
    left join booking.order_items oi on oi.id = pl.order_item_id left join kb.products prod on prod.id = oi.product_id;
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
     'payment', jsonb_build_object('id', pay.id, 'method', pay.method, 'method_label', coalesce(pm.label, pay.method), 'paid_at', pay.paid_at),
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
end $function$
;

CREATE OR REPLACE FUNCTION booking.payments_paid_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if booking._acct_excluded(new.order_id, new.id) then return null; end if;   -- Johku-historia (tilaus tai maksu) ei kuittiin
  perform booking._alloc_payment_lines(new.id);
  if new.method = 'cash' and new.rounding = 0 then
    update booking.payments set rounding = booking._cash_rounding(new.amount) where id = new.id;
  end if;
  perform booking._on_payment_paid(new.id);
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION booking._report_json(p_from date, p_to date, p_receipts boolean, p_days boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_res jsonb;
begin
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
       and not booking._acct_excluded(r.order_id, r.payment_id)   -- Johku ei kirjanpitoraporttiin
  ), tot as (
    select jsonb_build_object('receipts', count(*) filter (where kind = 'receipt'), 'refund_receipts', count(*) filter (where kind = 'refund_receipt'),
             'gross', coalesce(sum(gross) filter (where kind = 'receipt'), 0), 'net', coalesce(sum(net) filter (where kind = 'receipt'), 0), 'vat', coalesce(sum(vat) filter (where kind = 'receipt'), 0),
             'refunds_gross', coalesce(sum(gross) filter (where kind = 'refund_receipt'), 0), 'net_after_refunds', coalesce(sum(gross), 0),
             'vat_after_refunds', coalesce(sum(vat), 0), 'net_ex_vat_after_refunds', coalesce(sum(net), 0), 'rounding', coalesce(sum(rnd), 0)) j from rc
  ), bm as (
    select coalesce(jsonb_agg(jsonb_build_object('method', method, 'label', label, 'payments', pc, 'gross', g, 'refunds', rf, 'rounding', rn) order by method), '[]'::jsonb) j from (
      select method, max(mlabel) label, count(*) filter (where kind = 'receipt') pc, coalesce(sum(gross) filter (where kind = 'receipt'), 0) g,
             coalesce(sum(gross) filter (where kind = 'refund_receipt'), 0) rf, coalesce(sum(rnd), 0) rn from rc group by method) x
  ), bv as (
    select coalesce(jsonb_agg(jsonb_build_object('rate', rate, 'net', n, 'vat', v, 'gross', g) order by rate), '[]'::jsonb) j from (
      select (e ->> 'rate')::numeric rate, sum((e ->> 'net')::numeric) n, sum((e ->> 'vat')::numeric) v, sum((e ->> 'gross')::numeric) g from rc, jsonb_array_elements(rc.s -> 'vat') e group by 1) x
  ), bmv as (
    select coalesce(jsonb_agg(jsonb_build_object('method', method, 'rate', rate, 'net', n, 'vat', v, 'gross', g) order by method, rate), '[]'::jsonb) j from (
      select method, (e ->> 'rate')::numeric rate, sum((e ->> 'net')::numeric) n, sum((e ->> 'vat')::numeric) v, sum((e ->> 'gross')::numeric) g from rc, jsonb_array_elements(rc.s -> 'vat') e group by 1, 2) x
  ), bc as (
    select coalesce(jsonb_agg(jsonb_build_object('category', cat, 'label', booking._category_label(cat), 'rate', rate, 'quantity', q, 'gross', g, 'net', n, 'vat', g - n) order by cat, rate), '[]'::jsonb) j from (
      select l ->> 'category' cat, (l ->> 'vat_rate')::numeric rate, sum((l ->> 'quantity')::int * case when rc.kind = 'refund_receipt' then -1 else 1 end) q,
             sum((l ->> 'line_gross')::numeric) g, sum((l ->> 'line_net')::numeric) n from rc, jsonb_array_elements(rc.s -> 'lines') l group by 1, 2) x
  ), rl as (
    select case when p_receipts then coalesce(jsonb_agg(jsonb_build_object('receipt_no', receipt_no, 'kind', kind, 'issued_at', issued_at, 'order_no', order_no, 'method', method, 'gross', gross, 'net', net, 'vat', vat) order by issued_at, id), '[]'::jsonb) end j from rc
  ), bd as (
    select case when p_days then coalesce(jsonb_agg(jsonb_build_object('date', d, 'receipts', c, 'gross', g, 'vat', v, 'refunds', rf) order by d), '[]'::jsonb) end j from (
      select d, count(*) filter (where kind = 'receipt') c, coalesce(sum(gross) filter (where kind = 'receipt'), 0) g, coalesce(sum(vat), 0) v, coalesce(sum(gross) filter (where kind = 'refund_receipt'), 0) rf from rc group by d) x
  ), js as (
    -- Tilastolohko (EI kirjanpitoon): Johku-tilaukset, joiden Johku-maksupäivä (external_meta.johku.paid_at, Helsingin päivä) osuu jaksolle. Ei kosketa totals/by_*-avaimia.
    select jsonb_build_object('label', 'Johku (ei kirjanpitoon)', 'accounting', false, 'basis', 'johku_paid_at',
             'orders', coalesce(count(*) filter (where st in ('paid','partially_refunded')), 0),
             'gross', coalesce(sum(amt) filter (where st in ('paid','partially_refunded')), 0),
             'refunded_orders', coalesce(count(*) filter (where st = 'refunded'), 0),
             'refunded_gross', coalesce(sum(amt) filter (where st = 'refunded'), 0),
             'by_method', coalesce((select jsonb_agg(jsonb_build_object('method', m, 'orders', c, 'gross', g) order by m)
                                      from (select m2.m, count(*) c, sum(m2.amt) g from jx m2 where m2.st in ('paid','partially_refunded') group by m2.m) mm), '[]'::jsonb)) j
      from jx
  ), op as (
    select jsonb_build_object('orders', count(*), 'unpaid', coalesce(sum(u), 0)) j from (
      select o.id, greatest(o.total_gross - coalesce((select sum(p.amount - p.refunded_amount) from booking.payments p where p.order_id = o.id and p.status in ('paid','partially_refunded','refunded')), 0), 0) u
        from booking.orders o where not booking._acct_excluded(o.id, null) and o.status = 'confirmed'
         and (select min(r.starts_at at time zone 'Europe/Helsinki')::date from booking.reservations r where r.order_id = o.id and r.status = 'confirmed') between p_from and p_to) y where u > 0
  ), ur as (
    select jsonb_build_object('payments', count(*), 'amount', coalesce(sum(p.amount), 0)) j from booking.payments p
     where not booking._acct_excluded(p.order_id, p.id) and p.status in ('paid','partially_refunded','refunded') and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to
       and not exists (select 1 from booking.receipts r where r.payment_id = p.id and r.kind = 'receipt')
  )
  select jsonb_build_object('period', jsonb_build_object('from', p_from, 'to', p_to, 'tz', 'Europe/Helsinki'), 'generated_at', now(), 'basis', 'cash (kuitin antamispäivä)',
         'totals', tot.j, 'by_method', bm.j, 'by_vat', bv.j, 'by_method_vat', bmv.j, 'by_category', bc.j, 'open', op.j, 'unreceipted', ur.j, 'statistics', jsonb_build_object('johku', js.j))
         || case when p_receipts then jsonb_build_object('receipts', rl.j) else '{}'::jsonb end
         || case when p_days then jsonb_build_object('by_day', bd.j) else '{}'::jsonb end
    into v_res from tot, bm, bv, bmv, bc, rl, bd, op, ur, js;
  return v_res;
end $function$
;

CREATE OR REPLACE FUNCTION booking.admin_report_csv(p_from date, p_to date, p_kind text DEFAULT 'lines'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_body text; v_hdr text; v_cr text := E'\r\n';
begin
  perform booking._report_check(true);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then perform booking._err('invalid_param', 'Virheellinen aikaväli (enintään 366 päivää)'); end if;
  if p_kind not in ('lines','vat') then perform booking._err('invalid_param', 'p_kind: lines|vat'); end if;
  if p_kind = 'lines' then
    v_hdr := 'pvm;kuitti_no;tilaus_no;maksutapa;tuoteryhmä;tuote;määrä;brutto;alv_%;alv_€;netto;hyvitys';
    select coalesce(string_agg(concat_ws(';', to_char(r.issued_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY'), r.receipt_no, o.order_no::text,
             booking._csv(r.snapshot -> 'payment' ->> 'method_label'), booking._csv(booking._category_label(l.e ->> 'category')),
             booking._csv(l.e ->> 'description'), ((l.e ->> 'quantity')::int * case when r.kind = 'refund_receipt' then -1 else 1 end)::text, booking._csvmoney((l.e ->> 'line_gross')::numeric),
             booking._csvnum((l.e ->> 'vat_rate')::numeric), booking._csvmoney((l.e ->> 'line_gross')::numeric - (l.e ->> 'line_net')::numeric), booking._csvmoney((l.e ->> 'line_net')::numeric),
             case when r.kind = 'refund_receipt' then 'kyllä' else 'ei' end),
             v_cr order by r.issued_at, r.id, l.n), '') into v_body
      from booking.receipts r join booking.orders o on o.id = r.order_id, jsonb_array_elements(r.snapshot -> 'lines') with ordinality as l(e, n)
     where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to
       and not booking._acct_excluded(r.order_id, r.payment_id);   -- Johku ei kirjanpito-CSV:hen
  else
    v_hdr := 'pvm;kuitti;tilaus;tyyppi;maksutapa;alv_prosentti;netto;alv_eur;brutto';
    select coalesce(string_agg(concat_ws(';', to_char(r.issued_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY'), r.receipt_no, o.order_no::text, case when r.kind = 'receipt' then 'kuitti' else 'hyvitys' end,
             booking._csv(r.snapshot -> 'payment' ->> 'method_label'), booking._csvnum((v.e ->> 'rate')::numeric), booking._csvmoney((v.e ->> 'net')::numeric),
             booking._csvmoney((v.e ->> 'vat')::numeric), booking._csvmoney((v.e ->> 'gross')::numeric)), v_cr order by r.issued_at, r.id, v.n), '') into v_body
      from booking.receipts r join booking.orders o on o.id = r.order_id, jsonb_array_elements(r.snapshot -> 'vat') with ordinality as v(e, n)
     where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to
       and not booking._acct_excluded(r.order_id, r.payment_id);   -- Johku ei kirjanpito-CSV:hen
  end if;
  return jsonb_build_object('filename', format('kuitit_%s_%s_%s.csv', p_kind, p_from, p_to), 'mime', 'text/csv;charset=utf-8',
                            'content', chr(65279) || v_hdr || v_cr || v_body || case when v_body <> '' then v_cr else '' end);
end $function$
;

CREATE OR REPLACE FUNCTION booking.admin_list_payments(p_search text DEFAULT NULL::text, p_method text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_sort text DEFAULT 'paid_desc'::text, p_include_placeholders boolean DEFAULT false, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_s text := nullif(btrim(coalesce(p_search, '')), ''); v_num bigint; v_like text; v_total int; v_rows jsonb; v_sp numeric; v_sr numeric; v_spx numeric; v_srx numeric; v_jn int; v_lim int := coalesce(p_limit, 50); v_off int := greatest(coalesce(p_offset, 0), 0);
begin
  perform booking._require_staff();
  if p_sort is null or p_sort not in ('paid_desc','paid_asc','amount_desc','amount_asc','order_no_desc','order_no_asc') then perform booking._err('invalid_sort', 'Tuntematon lajittelu'); end if;
  if v_lim < 1 or v_lim > 200 then perform booking._err('invalid_param', 'p_limit 1–200'); end if;
  if v_s ~ '^\d{1,12}$' then v_num := v_s::bigint; end if;
  if v_s is not null then v_like := '%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  with base as (
    select p.id, p.order_id, o.order_no, p.method, pm.label as mlabel, p.provider, p.status, p.amount, p.refunded_amount, p.rounding, p.paid_at, p.created_at,
           c.name as cname, (select count(*) from booking.payment_lines pl where pl.payment_id = p.id) as lc,
           rc.receipt_no, rc.public_token as rtoken, coalesce(p.paid_at, p.created_at) as ts, booking._acct_excluded(p.order_id, p.id) as jk
      from booking.payments p join booking.orders o on o.id = p.order_id
      left join booking.customers c on c.id = o.customer_id left join booking.payment_methods pm on pm.code = p.method
      left join lateral (select x.receipt_no, x.public_token from booking.receipts x where x.payment_id = p.id and x.kind = 'receipt' limit 1) rc on true
     where (p_method is null or p.method = p_method) and (p_status is null or p.status = p_status)
       and (p_include_placeholders or not (p.provider = 'manual' and p.status = 'pending' and p.external_source is null
                                           and not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id)))
       and (p_from is null or (coalesce(p.paid_at, p.created_at) at time zone 'Europe/Helsinki')::date >= p_from)
       and (p_to is null or (coalesce(p.paid_at, p.created_at) at time zone 'Europe/Helsinki')::date <= p_to)
       and (v_s is null or (v_num is not null and (o.order_no = v_num or p.id = v_num)) or rc.receipt_no ilike v_like or (v_num is null and (c.name ilike v_like or c.email ilike v_like)))
  ), page as (
    select b.*, row_number() over (order by
       case when p_sort = 'paid_asc' then b.ts end asc, case when p_sort = 'paid_desc' then b.ts end desc,
       case when p_sort = 'amount_asc' then b.amount end asc, case when p_sort = 'amount_desc' then b.amount end desc,
       case when p_sort = 'order_no_asc' then b.order_no end asc, case when p_sort = 'order_no_desc' then b.order_no end desc, b.id desc) rn from base b)
  select (select count(*) from base),
         (select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded')), 0) from base),
         (select coalesce(sum(refunded_amount), 0) from base),
         (select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded') and not jk), 0) from base),
         (select coalesce(sum(refunded_amount) filter (where not jk), 0) from base),
         (select count(*) from base where jk),
         coalesce(jsonb_agg(jsonb_build_object('payment_id', p.id, 'order_id', p.order_id, 'order_no', p.order_no, 'method', p.method, 'method_label', p.mlabel, 'provider', p.provider,
           'status', p.status, 'amount', p.amount, 'refunded_amount', p.refunded_amount, 'rounding', p.rounding, 'paid_at', p.paid_at, 'created_at', p.created_at,
           'customer_name', p.cname, 'line_count', p.lc, 'receipt_no', p.receipt_no, 'receipt_token', p.rtoken,
           'source', case when p.jk then 'johku' else 'native' end, 'is_johku', p.jk) order by p.rn), '[]'::jsonb)
    into v_total, v_sp, v_sr, v_spx, v_srx, v_jn, v_rows from page p where p.rn > v_off and p.rn <= v_off + v_lim;
  return jsonb_build_object('total', v_total, 'sum_paid', v_sp, 'sum_refunded', v_sr, 'sum_paid_ex_johku', v_spx, 'sum_refunded_ex_johku', v_srx, 'johku_rows', v_jn, 'rows', v_rows);
end $function$
;


create or replace function booking.receipts_no_johku_trg() returns trigger language plpgsql security definer set search_path to ''
as $$
begin
  if booking._acct_excluded(new.order_id, new.payment_id) then perform booking._err('johku_not_accounted', 'Johku-lähtöiselle tilaukselle/maksulle ei anneta kuittia'); end if;
  return new;
end $$;
drop trigger if exists receipts_no_johku on booking.receipts;
create trigger receipts_no_johku before insert on booking.receipts for each row execute function booking.receipts_no_johku_trg();

create or replace function booking.accounting_outbox_no_johku_trg() returns trigger language plpgsql security definer set search_path to ''
as $$
declare v_order bigint := new.order_id;
begin
  if v_order is null and new.receipt_id is not null then select r.order_id into v_order from booking.receipts r where r.id = new.receipt_id; end if;
  if booking._acct_excluded(v_order, new.payment_id) then return null; end if;   -- Johku-lähtöinen rivi ei jonoon (ei virhettä)
  return new;
end $$;
drop trigger if exists accounting_outbox_no_johku on booking.accounting_outbox;
create trigger accounting_outbox_no_johku before insert on booking.accounting_outbox for each row execute function booking.accounting_outbox_no_johku_trg();

do $$ declare f text; begin
  foreach f in array array['booking._acct_excluded(bigint,bigint)','booking._try_ts(text)','booking.receipts_no_johku_trg()','booking.accounting_outbox_no_johku_trg()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
