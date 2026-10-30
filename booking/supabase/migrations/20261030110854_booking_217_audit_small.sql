-- booking_217: auditoinnin pienet löydökset (L3–L8, L10, L14–L16).
-- L3 maksutavat omana CSV-tyyppinä (methods) ja täsmäytys myyntiin (methods_net).
-- L4 lahjakortin jakson lopun saldo ja jaksolla vanhentunut saldo (_gc_period_balance).
-- L5 näkyvä ALV on kuittitason by_vat; rivitason erotus jää täsmäytykseen (vat_summary ennallaan).
-- L6 by_vat_sales ja by_vat_refunds (hyvitys hyvityskuitin jaksolla).
-- L7 raportti-CSV: tosite / myynti, ei kuitti.
-- L10 ei 0 €:n paid-maksua (paitsi vuosikortin merkki). L14 montonio active. L15 lahjakortin tiedoksi-kuitti sarja G.
-- Tuotantodataa ei muuteta muuten kuin maksutavan aktiivisuuslipulla ja lahjakortin sarja-asetuksella.
set local lock_timeout = '5s';

create or replace function booking._gc_period_balance(p_from date, p_to date)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with bounds as (
    select (p_from::timestamp at time zone 'Europe/Helsinki') as t0,
           ((p_to + 1)::timestamp at time zone 'Europe/Helsinki') as t1
  ), cards as (
    select g.id,
           case when g.source = 'johku' or g.accounting_origin = 'johku' then 'johku'
                when g.complimentary then 'native_complimentary'
                else 'native_paid' end as bucket,
           g.valid_to
      from booking.gift_cards g
  ), bal as (
    select c.id, c.bucket, c.valid_to,
           coalesce((select l.balance_after from booking.gift_card_ledger l, bounds b
                      where l.gift_card_id = c.id and l.at < b.t0
                      order by l.at desc, l.id desc limit 1), 0) as bal0,
           coalesce((select l.balance_after from booking.gift_card_ledger l, bounds b
                      where l.gift_card_id = c.id and l.at < b.t1
                      order by l.at desc, l.id desc limit 1), 0) as bal1
      from cards c
  ), mov as (
    select l.gift_card_id,
           coalesce(sum(l.delta) filter (where l.reason in ('purchase','manual_issue','johku_purchase','opening_balance') and l.delta > 0), 0) as sold,
           coalesce(sum(-l.delta) filter (where l.reason in ('redemption','johku_usage') and l.delta < 0), 0) as redeemed,
           coalesce(sum(l.delta) filter (where not (
             (l.reason in ('purchase','manual_issue','johku_purchase','opening_balance') and l.delta > 0)
             or (l.reason in ('redemption','johku_usage') and l.delta < 0))), 0) as other
      from booking.gift_card_ledger l, bounds b
     where l.at >= b.t0 and l.at < b.t1
     group by l.gift_card_id
  ), row as (
    select b.bucket,
           case when b.valid_to is null or b.valid_to >= p_from then b.bal0 else 0 end as opening,
           coalesce(m.sold, 0) as sold,
           coalesce(m.redeemed, 0) as redeemed,
           coalesce(m.other, 0) as other,
           case when b.valid_to between p_from and p_to then b.bal1 else 0 end as expired,
           case when b.valid_to is null or b.valid_to > p_to then b.bal1 else 0 end as closing,
           case when (b.valid_to is null or b.valid_to > p_to) and b.bal1 > 0.004 then 1 else 0 end as open_cards
      from bal b
      left join mov m on m.gift_card_id = b.id
  ), agg as (
    select bucket,
           round(coalesce(sum(opening), 0), 2) as opening,
           round(coalesce(sum(sold), 0), 2) as sold,
           round(coalesce(sum(redeemed), 0), 2) as redeemed,
           round(coalesce(sum(other), 0), 2) as other,
           round(coalesce(sum(expired), 0), 2) as expired,
           round(coalesce(sum(closing), 0), 2) as closing,
           coalesce(sum(open_cards), 0) as cards
      from row
     group by bucket
  ), shaped as (
    select bucket,
           jsonb_build_object(
             'opening', opening, 'sold', sold, 'redeemed', redeemed, 'other', other,
             'expired', expired, 'closing', closing, 'cards', cards,
             'accounting', bucket = 'native_paid',
             'difference', round(opening + sold - redeemed + other - expired - closing, 2)) as obj
      from agg
  )
  select jsonb_build_object(
    'native_paid', coalesce((select obj from shaped where bucket = 'native_paid'),
      '{"opening":0,"sold":0,"redeemed":0,"other":0,"expired":0,"closing":0,"cards":0,"accounting":true,"difference":0}'::jsonb),
    'native_complimentary', coalesce((select obj from shaped where bucket = 'native_complimentary'),
      '{"opening":0,"sold":0,"redeemed":0,"other":0,"expired":0,"closing":0,"cards":0,"accounting":false,"difference":0}'::jsonb),
    'johku', coalesce((select obj from shaped where bucket = 'johku'),
      '{"opening":0,"sold":0,"redeemed":0,"other":0,"expired":0,"closing":0,"cards":0,"accounting":false,"difference":0}'::jsonb),
    'johku_accounting', false)
$$;

revoke all on function booking._gc_period_balance(date, date) from public, anon, authenticated;
grant execute on function booking._gc_period_balance(date, date) to service_role;
comment on function booking._gc_period_balance(date, date) is
  'Lahjakortin kirjanpitosaldo jakson lopussa: alkusaldo + myynti − lunastus + muut − vanhentunut = loppusaldo. Johku ei ole velkaa (accounting=false). booking_217.';

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
       and not booking._acct_excluded(r.order_id, r.payment_id)
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
      from (select product, rate, sum(qty) quantity, sum(net) net, sum(gross) gross from ln where kind = 'receipt' group by product, rate) x
  ), brp as (
    select coalesce(jsonb_agg(jsonb_build_object('product', product, 'rate', rate, 'quantity', quantity, 'net', net, 'vat', gross - net, 'gross', gross) order by product, rate), '[]'::jsonb) j,
           coalesce(sum(gross), 0) refunds_gross, coalesce(sum(gross - net), 0) refunds_vat
      from (select product, rate, sum(abs(qty)) quantity, sum(abs(net)) net, sum(abs(gross)) gross from ln where kind = 'refund_receipt' group by product, rate) x
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
    select jsonb_build_object('orders', count(*), 'unpaid', coalesce(sum(u), 0)) j from (
      select o.id, greatest(o.total_gross - coalesce((select sum(p.amount - p.refunded_amount) from booking.payments p where p.order_id = o.id and p.status in ('paid','partially_refunded','refunded')), 0), 0) u
        from booking.orders o where not booking._acct_excluded(o.id, null) and o.status = 'confirmed'
         and (select min(r.starts_at at time zone 'Europe/Helsinki')::date from booking.reservations r where r.order_id = o.id and r.status = 'confirmed') between p_from and p_to) y where u > 0
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
       and g.accounting_origin = 'native' and g.source is distinct from 'johku' and g.vat_treatment = 'at_sale' and g.complimentary = false
       and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to
  ), pr as (
    select jsonb_build_object(
      'accounting', false,
      'payments', (select count(*) from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id
                    where p.method = 'gift_card' and p.status in ('paid', 'partially_refunded', 'refunded')
                      and g.accounting_origin = 'native' and g.source is distinct from 'johku' and g.vat_treatment = 'at_sale' and g.complimentary = false
                      and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to),
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
  return v_res;
end $function$;


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
  if p_kind is null or p_kind not in ('lines', 'transactions', 'summary', 'vat', 'methods') then perform booking._err('invalid_param', 'p_kind: lines|transactions|summary|vat|methods'); end if;
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
    fn := format('yhteenveto_%s_%s.csv', p_from, p_to);
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
    v_body := v_body || concat_ws(';', 'lahjakortti_maksuton', 'myonnetty', '', booking._csvnum(coalesce((rep -> 'gift_card_period' -> 'complimentary' ->> 'issued_count')::numeric, 0)),
      '', '', booking._csvmoney(coalesce((rep -> 'gift_card_period' -> 'complimentary' ->> 'issued_gross')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'lahjakortti_maksuton', 'lunastus', '', booking._csvnum(coalesce((rep -> 'gift_card_period' -> 'complimentary' ->> 'redeemed_count')::numeric, 0)),
      '', '', booking._csvmoney(coalesce((rep -> 'gift_card_period' -> 'complimentary' ->> 'redeemed_gross')::numeric, 0))) || v_cr;
    if p_from < p_to then
      for el in select * from jsonb_array_elements(rep -> 'by_method') loop
        v_body := v_body || concat_ws(';', 'maksutapa', booking._csv(coalesce(el ->> 'label', el ->> 'method')), '', '',
          '', '', booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0) + coalesce((el ->> 'refunds')::numeric, 0))) || v_cr;
      end loop;
    end if;
    rec := rep -> 'reconciliation';
    v_body := v_body || concat_ws(';', 'tasmaytys', 'myynti_brutto', '', '', '', '', booking._csvmoney((rec ->> 'sales_gross')::numeric)) || v_cr;
    v_body := v_body || concat_ws(';', 'tasmaytys', 'hyvitykset_brutto', '', '', '', '', booking._csvmoney((rec ->> 'refunds_gross')::numeric)) || v_cr;
    v_body := v_body || concat_ws(';', 'tasmaytys', 'tuotteet', '', '', '', '', booking._csvmoney((rec ->> 'product_gross')::numeric)) || v_cr;
    if p_from < p_to then
      v_body := v_body || concat_ws(';', 'tasmaytys', 'maksutavat', '', '', '', '', booking._csvmoney((rec ->> 'payments_gross')::numeric)) || v_cr;
      v_body := v_body || concat_ws(';', 'tasmaytys', 'erotus', '', '', '', '', booking._csvmoney((rec ->> 'difference')::numeric)) || v_cr;
    end if;
    v_body := v_body || concat_ws(';', 'tasmaytys', 'alv_rivi', '', '', '', booking._csvmoney((rec ->> 'line_vat')::numeric), '') || v_cr;
    v_body := v_body || concat_ws(';', 'tasmaytys', 'alv_myynti', '', '', '', booking._csvmoney((rec ->> 'receipt_vat')::numeric), '') || v_cr;
    v_body := v_body || concat_ws(';', 'tasmaytys', coalesce(rec ->> 'rounding_code', 'alv_pyoristys'), '', '', '', booking._csvmoney((rec ->> 'vat_rounding')::numeric), '') || v_cr;
    if abs(coalesce((rec ->> 'cash_rounding')::numeric, 0)) >= 0.005 then
      v_body := v_body || concat_ws(';', 'tasmaytys', 'kateispyoristys', '', '', '', '', booking._csvmoney((rec ->> 'cash_rounding')::numeric)) || v_cr;
    end if;
    v_body := v_body || concat_ws(';', 'lahjakortti_avoin', 'oma_alkusaldo', '', '', '', '', booking._csvmoney(coalesce((rep #>> '{gift_card_period,open,native_paid,opening}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'lahjakortti_avoin', 'oma_loppusaldo', '', '', '', '', booking._csvmoney(coalesce((rep #>> '{gift_card_period,open,native_paid,closing}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'lahjakortti_vanhentunut', 'oma', '', '', '', '', booking._csvmoney(coalesce((rep #>> '{gift_card_period,open,native_paid,expired}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'lahjakortti_avoin', 'johku_loppusaldo', '', '', '', '', booking._csvmoney(coalesce((rep #>> '{gift_card_period,open,johku,closing}')::numeric, 0))) || v_cr;
  elsif p_kind = 'methods' then
    v_hdr := 'maksutapa;maksuja;myynti_brutto;hyvitykset;netto';
    fn := format('maksutavat_%s_%s.csv', p_from, p_to);
    rep := booking._report_json(p_from, p_to, false, false);
    for el in select * from jsonb_array_elements(rep -> 'by_method') loop
      v_body := v_body || concat_ws(';', booking._csv(coalesce(el ->> 'label', el ->> 'method')),
        booking._csvnum(coalesce((el ->> 'payments')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'refunds')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0) + coalesce((el ->> 'refunds')::numeric, 0))) || v_cr;
    end loop;
    v_body := v_body || concat_ws(';', 'tasmaytys', '', '', '', booking._csvmoney(coalesce((rep #>> '{reconciliation,methods_net}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'myynti_hyvitysten_jalkeen', '', '', '', booking._csvmoney(coalesce((rep #>> '{reconciliation,payments_gross}')::numeric, 0))) || v_cr;
    v_body := v_body || concat_ws(';', 'erotus', '', '', '', booking._csvmoney(coalesce((rep #>> '{reconciliation,methods_difference}')::numeric, 0))) || v_cr;
    for el in select * from jsonb_array_elements(rep -> 'by_method_vat') loop
      v_body := v_body || concat_ws(';', 'alv_' || booking._csv(el ->> 'method'), booking._csvnum(coalesce((el ->> 'rate')::numeric, 0)),
        booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0))) || v_cr;
    end loop;
  else
    v_hdr := 'pvm;tosite;tilaus;tyyppi;maksutapa;alv_prosentti;netto;alv_eur;brutto';
    fn := format('myynti_vat_%s_%s.csv', p_from, p_to);
    select coalesce(string_agg(concat_ws(';', to_char(r.issued_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY'), r.receipt_no, o.order_no::text, case when r.kind = 'receipt' then 'myynti' else 'hyvitys' end,
             booking._csv(r.snapshot -> 'payment' ->> 'method_label'), booking._csvnum((v.e ->> 'rate')::numeric), booking._csvmoney((v.e ->> 'net')::numeric),
             booking._csvmoney((v.e ->> 'vat')::numeric), booking._csvmoney((v.e ->> 'gross')::numeric)), v_cr order by r.issued_at, r.id, v.n), '') into v_body
      from booking.receipts r join booking.orders o on o.id = r.order_id, jsonb_array_elements(r.snapshot -> 'vat') with ordinality as v(e, n)
     where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to
       and not booking._acct_excluded(r.order_id, r.payment_id);
  end if;
  return jsonb_build_object('filename', fn, 'mime', 'text/csv;charset=utf-8',
                            'content', chr(65279) || v_hdr || v_cr || v_body || case when v_body <> '' then v_cr else '' end);
end $function$;



create or replace function booking._refresh_order_payment(p_order_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare v_total numeric; v_paid numeric; v_refunded numeric; v_pending int;
begin
  select total_gross into v_total from booking.orders where id = p_order_id;
  select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded')), 0),
         coalesce(sum(refunded_amount), 0),
         count(*) filter (where status = 'pending')
    into v_paid, v_refunded, v_pending from booking.payments where order_id = p_order_id;
  update booking.orders set payment_status = case
      when v_paid > 0 and v_refunded >= v_paid then 'refunded'
      when v_refunded > 0 then 'partially_refunded'
      when coalesce(v_total, 0) <= 0.004 then 'paid'
      when v_paid >= v_total and v_total > 0 then 'paid'
      when v_paid > 0 then 'partially_paid'
      when v_pending > 0 and exists (select 1 from booking.payments where order_id = p_order_id and status = 'pending' and provider <> 'manual') then 'pending'
      else 'unpaid' end
   where id = p_order_id;
  update booking.reservations r
     set status = 'confirmed', hold_expires_at = null
    from booking.order_items i
   where i.id = r.order_item_id and i.order_id = p_order_id and r.order_id = p_order_id
     and r.status = 'pending' and i.hold_expires_at is not null and booking._item_paid(i.id);
  update booking.order_items i
     set hold_expires_at = null
   where i.order_id = p_order_id and i.hold_expires_at is not null and booking._item_paid(i.id);
end $$;

create or replace function booking.payments_no_zero_paid_trg() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status in ('paid', 'partially_refunded', 'refunded')
     and coalesce(new.amount, 0) <= 0
     and new.method is distinct from 'annual_card' then
    perform booking._err('invalid_amount', 'Nollasummaista maksettua maksua ei kirjata');
  end if;
  return new;
end $$;

drop trigger if exists payments_no_zero_paid on booking.payments;
create trigger payments_no_zero_paid
  before insert or update of status, amount on booking.payments
  for each row execute function booking.payments_no_zero_paid_trg();

comment on function booking.payments_no_zero_paid_trg() is
  'booking_217: paid-maksun summa on yli 0. Vuosikortin 0 €:n merkkirivi sallitaan. 100 % alennus merkitsee tilauksen maksetuksi ilman maksuriviä.';

-- montonio on verkkomaksun maksutapa. is_manual jää false: sitä ei kirjata käsin.
update booking.payment_methods
   set active = true
 where code = 'montonio' and is_manual = false;

update booking.settings
   set value = jsonb_set(coalesce(value, '{}'::jsonb), '{giftcard_info}', '"G"'::jsonb, true)
 where key = 'receipt_series'
   and coalesce(value ->> 'giftcard_info', 'L') in ('', 'L');

create or replace function booking._apply_admin_discount(p_order_id bigint, p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text := booking._norm_code(p_code);
  v_card booking.annual_cards; d booking.discount_codes; v_err text;
  r booking.reservations; v_day date; v_lines jsonb; v_calc jsonb; s jsonb;
  v_disc numeric := 0; v_total numeric; pr record; v_inserted boolean := false;
begin
  perform booking._require_permission('bookings.manage');
  select total_gross into v_total from booking.orders where id = p_order_id;
  if v_code is null or v_code = '' then
    return jsonb_build_object('total', v_total, 'discount', 0, 'payment_inserted', false);
  end if;
  if char_length(v_code) > 40 then perform booking._err('invalid_code', booking._code_msg('invalid_code')); end if;
  select * into r from booking.reservations where order_id = p_order_id order by id limit 1;
  if r.id is null then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  v_day := (r.starts_at at time zone booking._tz())::date;
  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code for update; end if;
  if v_card.id is null and d.id is null then perform booking._err('invalid_code', booking._code_msg('invalid_code')); end if;

  if v_card.id is not null or coalesce(d.is_annual_card_code, false) then
    if r.persons is distinct from booking._annual_max_persons() then perform booking._err('annual_card_persons', booking._code_msg('annual_card_persons')); end if;
    if exists (select 1 from booking.order_items oi where oi.order_id = p_order_id and oi.kind = 'addon' and oi.quantity > 0) then
      perform booking._err('annual_card_no_addons', booking._code_msg('annual_card_no_addons'));
    end if;
    v_err := booking._annual_rule_check(r.rule_id, v_day, v_card, d);
    if v_err is not null then perform booking._err(v_err, booking._code_msg(v_err)); end if;
    if v_card.id is not null and (select customer_id from booking.orders where id = p_order_id) is distinct from v_card.customer_id then
      perform booking._err('annual_card_customer_mismatch', booking._code_msg('annual_card_customer_mismatch'));
    end if;
    select * into pr from booking._rule_price(r.rule_id, r.persons);
    update booking.order_items set line_total_gross = 0, unit_price_gross = 0,
           discount_amount = case when v_card.id is not null then pr.total else line_total_gross end,
           discount_code_id = d.id
     where order_id = p_order_id and kind = 'reservation';
    update booking.order_items set line_total_gross = 0, discount_amount = line_total_gross where order_id = p_order_id and kind = 'addon';
    update booking.orders set total_gross = 0, discount_code_id = d.id, payment_status = 'paid' where id = p_order_id;
    if d.id is not null then update booking.discount_codes set used_count = used_count + 1 where id = d.id; end if;
    if v_card.id is not null then update booking.reservations set annual_card_id = v_card.id where id = r.id; end if;
    update booking.payments set status = 'cancelled' where order_id = p_order_id and status = 'pending';
    insert into booking.payments(order_id, method, provider, status, amount, paid_at, note, created_by)
    values (p_order_id, 'annual_card', 'manual', 'paid', 0, now(), 'Vuosikortti / koodi ' || v_code, auth.uid());
    return jsonb_build_object('total', 0, 'discount', coalesce(pr.total, v_total), 'discount_code', v_code,
                              'code_type', case when v_card.id is not null then 'annual_card' else 'annual_code' end,
                              'payment_inserted', true);
  end if;

  v_err := booking._discount_state(d);
  if v_err is not null then perform booking._err(v_err, booking._code_msg(v_err)); end if;
  select coalesce(jsonb_agg(jsonb_build_object('key', oi.id, 'product_id', oi.product_id, 'kind', oi.kind, 'gross', oi.line_total_gross) order by oi.id), '[]'::jsonb)
    into v_lines from booking.order_items oi where oi.order_id = p_order_id;
  v_calc := booking._discount_split(d, v_lines);
  v_disc := (v_calc ->> 'discount')::numeric;
  if v_disc <= 0 then perform booking._err('code_not_applicable', booking._code_msg('code_not_applicable')); end if;
  for s in select x from jsonb_array_elements(v_calc -> 'shares') x loop
    update booking.order_items set discount_code_id = d.id, discount_amount = coalesce(discount_amount, 0) + (s ->> 'amount')::numeric,
           line_total_gross = line_total_gross - (s ->> 'amount')::numeric
     where id = (s ->> 'key')::bigint and order_id = p_order_id;
  end loop;
  update booking.orders set discount_code_id = d.id,
         total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = p_order_id), 0)
   where id = p_order_id returning total_gross into v_total;
  update booking.discount_codes set used_count = used_count + 1 where id = d.id;
  if v_total <= 0 then
    update booking.payments set status = 'cancelled' where order_id = p_order_id and status = 'pending';
    -- booking_217: 100 % alennus ei kirjaa 0 €:n paid-maksua (se jäi raporttiin kuittittomana, kun tilauksen summa myöhemmin muuttui).
    update booking.orders set payment_status = 'paid' where id = p_order_id;
    v_inserted := true;
  end if;
  return jsonb_build_object('total', v_total, 'discount', v_disc, 'discount_code', d.code, 'code_type', 'discount', 'payment_inserted', v_inserted);
end $$;

CREATE OR REPLACE FUNCTION booking.public_create_booking_code(p_rule_id bigint, p_date date, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_addons jsonb DEFAULT NULL::jsonb, p_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_code text := booking._norm_code(p_code); v_ip text := booking._client_ip();
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private')));
  v_card booking.annual_cards; d booking.discount_codes; v_res jsonb; v_order booking.orders; v_cust bigint; v_err text; v_detail text; v_msg text;
  v_lines jsonb; v_calc jsonb; s jsonb; v_disc numeric; v_total numeric; pr record; v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}';
  v_qamt numeric := 0; v_qitem bigint;  -- booking_162: hiljaisen ajan ale (ei pinoudu koodin kanssa, suurempi etu voittaa)
begin
  if v_code = '' then
    return booking.public_create_booking(p_rule_id, p_date, p_persons, p_name, p_email, p_phone, p_marketing_consent, p_locale, p_note,
                                         p_customer_kind, p_company, p_addons);
  end if;
  if char_length(v_code) > 40 then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  if not booking._code_rate_ok(v_code, v_email, v_phone, v_ip) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
  end if;
  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code for update; end if;
  if v_card.id is null and d.id is null then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  -- booking_143: henkilökohtainen kortti, jonka omistaja ei täsmää → sama vastaus kuin tuntemattomalla koodilla (ennen muita tarkistuksia)
  if v_card.id is not null and not booking._annual_card_owner_ok(v_card, v_email, v_phone) then
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code'));
  end if;

  -- ---- vuosikortti / yhteinen vuosikorttikoodi
  if v_card.id is not null or d.is_annual_card_code then
    if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
      return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
    end if;
    if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
      return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
    end if;
    if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
      return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
    end if;
    if char_length(v_name) < 2 or char_length(v_name) > 120 then return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', 'Anna nimi'); end if;
    if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
    if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
    if p_note is not null and char_length(p_note) > 1000 then return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä'); end if;
    if p_date is null or p_date < (now() at time zone booking._tz())::date
       or p_date > (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int then
      return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
    end if;
    v_err := case
      when v_kind <> 'private' then 'annual_card_private_only'
      when p_addons is not null and jsonb_typeof(p_addons) = 'array' and exists (select 1 from jsonb_array_elements(p_addons) x where coalesce(x ->> 'quantity', '0') <> '0') then 'annual_card_no_addons'
      when p_persons is distinct from booking._annual_max_persons() then 'annual_card_persons'
      else booking._annual_rule_check(p_rule_id, p_date, v_card, d) end;
    if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
    begin
      if v_card.id is not null then v_cust := v_card.customer_id;
      else
        v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale,
                                           (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
      end if;
      perform booking._annual_lock_identity(v_cust, v_email, v_phone);
      if booking._annual_limit(v_cust, v_email, v_phone) then perform booking._err('annual_card_limit', booking._code_msg('annual_card_limit')); end if;
      -- henkilökohtaisen kortin rivin alennus (alkuperäinen hinta) kirjataan triggerissä reservations_annual_discount
      v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, 'web', null, p_locale, p_note, 'confirmed', null, true,
                                            null, null, case when v_card.id is null then 0 end, v_card.id);
      if d.id is not null then
        select * into pr from booking._rule_price(p_rule_id, p_persons);
        update booking.order_items set discount_code_id = d.id, discount_amount = pr.total
         where order_id = (v_res ->> 'order_id')::bigint and kind = 'reservation';
        update booking.orders set discount_code_id = d.id where id = (v_res ->> 'order_id')::bigint;
        update booking.discount_codes set used_count = used_count + 1 where id = d.id;
      end if;
      insert into booking.payments(order_id, method, provider, status, amount, paid_at, note)
      values ((v_res ->> 'order_id')::bigint, 'annual_card', 'manual', 'paid', 0, now(), 'Vuosikorttivaraus verkossa (' || v_code || ')');
      update booking.orders set payment_status = 'paid' where id = (v_res ->> 'order_id')::bigint;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
    end;
    return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token', 'status', 'confirmed',
                              'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at', 'total', 0, 'addons_total', 0,
                              'hold_expires_at', null, 'payment_mode', v_mode, 'payment_url', null, 'product_name', v_res -> 'product_name',
                              'customer_kind', 'private', 'code_type', case when v_card.id is not null then 'annual_card' else 'annual_code' end,
                              'discount', (select coalesce(sum(discount_amount), 0) from booking.order_items where order_id = (v_res ->> 'order_id')::bigint))
           || booking._checkout_state_json((v_res ->> 'order_id')::bigint);
  end if;

  -- ---- alennuskoodi
  v_err := booking._discount_state(d);
  if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
  begin
    v_res := booking.public_create_booking(p_rule_id, p_date, p_persons, p_name, p_email, p_phone, p_marketing_consent, p_locale, p_note,
                                           p_customer_kind, p_company, p_addons);
    if not coalesce((v_res ->> 'ok')::boolean, false) then return v_res; end if;
    select * into v_order from booking.orders where public_token = (v_res ->> 'token')::uuid for update;
    -- booking_162: koodin alennus lasketaan alennuksettomista riveistä (hiljaisen ajan ale lisätään takaisin)
    select oi.id, coalesce((oi.price_breakdown #>> '{quiet,amount}')::numeric, 0) into v_qitem, v_qamt
      from booking.order_items oi where oi.order_id = v_order.id and oi.kind = 'reservation' and oi.price_breakdown ? 'quiet' order by oi.id limit 1;
    v_qamt := coalesce(v_qamt, 0);
    select coalesce(jsonb_agg(jsonb_build_object('key', oi.id, 'product_id', oi.product_id, 'kind', oi.kind,
             'gross', oi.line_total_gross + case when oi.id = v_qitem then v_qamt else 0 end) order by oi.id), '[]'::jsonb)
      into v_lines from booking.order_items oi where oi.order_id = v_order.id;
    v_calc := booking._discount_split(d, v_lines);
    v_disc := (v_calc ->> 'discount')::numeric;
    if v_disc <= 0 then perform booking._err('code_not_applicable', booking._code_msg('code_not_applicable')); end if;
    if v_qamt > 0 and v_qamt >= v_disc then
      -- hiljaisen ajan ale on vähintään yhtä suuri etu: koodia ei käytetä (käyttökertaa ei kuluteta), varaus jää alennettuun hintaan
      return v_res || jsonb_build_object('code_applied', false, 'discount_source', 'quiet', 'code_discount', v_disc, 'discount_code', null, 'code_type', 'discount');
    end if;
    if v_qamt > 0 then   -- koodi on suurempi etu: hiljaisen ajan ale perutaan riviltä ennen koodin alennusta
      update booking.order_items
         set line_total_gross = line_total_gross + v_qamt, discount_amount = 0,
             price_breakdown = (price_breakdown - 'quiet') || jsonb_build_object('quiet_superseded', (price_breakdown -> 'quiet') || jsonb_build_object('by', 'code'))
       where id = v_qitem;
    end if;
    for s in select x from jsonb_array_elements(v_calc -> 'shares') x loop
      update booking.order_items set discount_code_id = d.id, discount_amount = coalesce(discount_amount, 0) + (s ->> 'amount')::numeric,
             line_total_gross = line_total_gross - (s ->> 'amount')::numeric
       where id = (s ->> 'key')::bigint and order_id = v_order.id;
    end loop;
    update booking.orders set discount_code_id = d.id,
           total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = v_order.id), 0)
     where id = v_order.id returning total_gross into v_total;
    update booking.discount_codes set used_count = used_count + 1 where id = d.id;
    if v_total > 0 then
      update booking.payments set amount = v_total where order_id = v_order.id and status = 'pending' and provider = 'manual';
    else   -- 100 % alennus: ei maksettavaa → vahvistetaan heti, ilman 0 €:n paid-maksua (booking_217)
      update booking.payments set status = 'cancelled' where order_id = v_order.id and status = 'pending';
      update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = v_order.id and status = 'pending';
      update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()), hold_kind = null where id = v_order.id and status = 'pending';
      update booking.orders set payment_status = 'paid' where id = v_order.id;
    end if;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  select * into v_order from booking.orders where id = v_order.id;
  return v_res || jsonb_build_object('total', v_total, 'status', v_order.status, 'hold_expires_at',
                    (select min(hold_expires_at) from booking.reservations where order_id = v_order.id and status = 'pending'),
                    'discount', v_disc, 'discount_code', d.code, 'code_type', 'discount',
                    'addons_total', (select coalesce(sum(line_total_gross), 0) from booking.order_items where order_id = v_order.id and kind = 'addon'))
                || case when v_qamt > 0 then jsonb_build_object('discount_source', 'code', 'quiet', null) else '{}'::jsonb end
                || booking._checkout_state_json(v_order.id);
end $function$;

create or replace function booking.admin_create_booking(
  p_rule_id bigint, p_date date, p_persons integer,
  p_customer_id bigint default null, p_customer jsonb default null,
  p_payment_method text default 'pay_later', p_paid boolean default false,
  p_note text default null, p_start timestamptz default null, p_end timestamptz default null,
  p_price numeric default null, p_channel text default 'admin',
  p_addons jsonb default null, p_invoice_reference text default null,
  p_discount_code text default null, p_gift_card_code text default null,
  p_remainder_method text default null,
  p_allow_overbook boolean default false, p_allow_off_schedule boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_cust bigint := p_customer_id; v_res jsonb; v_email text; v_order bigint; v_pm booking.payment_methods;
  v_kind text; v_is_company boolean; v_company jsonb; v_add numeric; v_total numeric; v_consent boolean; v_ref text := nullif(btrim(coalesce(p_invoice_reference, '')), '');
  v_method text := p_payment_method; v_paid boolean := coalesce(p_paid, false); v_gc text := nullif(btrim(coalesce(p_gift_card_code, '')), '');
  v_extra jsonb := '{}'::jsonb; v_disc jsonb;
begin
  perform booking._require_permission('bookings.manage');
  perform booking._arm_staff_overrides(p_allow_overbook, p_allow_off_schedule, p_start, p_end);
  if v_method = 'gift_card' and v_gc is null then perform booking._err('gift_card_code_required', 'Anna lahjakortin koodi.'); end if;
  if v_gc is not null then v_method := 'pay_later'; v_paid := false; end if;
  select * into v_pm from booking.payment_methods where code = v_method and active;
  if not found then perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä'); end if;
  if p_channel not in ('admin','phone','email','walk_in','other') then perform booking._err('invalid_channel', 'Virheellinen lähdekanava'); end if;
  if p_price is not null and p_price < 0 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  if v_ref is not null and char_length(v_ref) > 100 then perform booking._err('invalid_reference', 'Viite on liian pitkä (enintään 100 merkkiä)'); end if;
  if v_cust is null then
    if p_customer is null or char_length(btrim(coalesce(p_customer ->> 'name', ''))) < 2 then
      perform booking._err('customer_required', 'Valitse asiakas tai anna nimi');
    end if;
    v_kind := lower(btrim(coalesce(nullif(p_customer ->> 'kind', ''), 'private')));
    select ck.is_company into v_is_company from booking.customer_kinds ck where ck.code = v_kind and ck.active;
    if v_is_company is null then perform booking._err('invalid_customer_kind', 'Valitse asiakastyyppi (yksityinen / yritys)'); end if;
    v_email := lower(nullif(btrim(coalesce(p_customer ->> 'email', '')), ''));
    if v_email is not null and not booking._valid_email(v_email) then perform booking._err('invalid_email', 'Tarkista sähköpostiosoite'); end if;
    v_consent := coalesce((p_customer ->> 'marketing_consent')::boolean, false);
    if v_is_company then
      v_company := booking._clean_company(p_customer -> 'company_details');
      v_cust := booking._upsert_company_customer(v_kind, btrim(p_customer ->> 'name'), v_email, nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''),
                  v_company, v_consent, 'admin', coalesce(p_customer ->> 'language', 'fi'));
    elsif v_email is not null then
      v_cust := booking._upsert_customer(btrim(p_customer ->> 'name'), v_email, nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''),
                 v_consent, 'admin', coalesce(p_customer ->> 'language', 'fi'));
    else
      insert into booking.customers(name, phone, company, language, marketing_consent, marketing_consent_at, marketing_consent_source)
      values (btrim(p_customer ->> 'name'), nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''), nullif(btrim(coalesce(p_customer ->> 'company', '')), ''),
              coalesce(p_customer ->> 'language', 'fi'), v_consent,
              case when v_consent then now() end, case when v_consent then 'admin' end)
      returning id into v_cust;
    end if;
  elsif not exists (select 1 from booking.customers where id = v_cust) then
    perform booking._err('customer_not_found', 'Asiakasta ei löydy');
  end if;

  v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, p_channel, auth.uid(), 'fi', p_note,
                                        'confirmed', null, false, p_start, p_end, p_price);
  v_order := (v_res ->> 'order_id')::bigint;
  perform booking._stamp_order_billing(v_order, v_cust, v_company);
  if v_ref is not null then update booking.orders set invoice_reference = v_ref where id = v_order and customer_kind <> 'private'; end if;
  v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);
  v_disc := booking._apply_admin_discount(v_order, p_discount_code);
  v_total := (v_disc ->> 'total')::numeric;
  v_extra := v_disc;
  if coalesce((v_disc ->> 'payment_inserted')::boolean, false) then
    null;
  elsif v_gc is not null then
    v_extra := v_disc || booking._apply_admin_gift(v_order, v_gc, p_remainder_method, p_paid);
    v_total := coalesce((v_extra ->> 'total')::numeric, v_total);
  else
    if v_total > 0.004 then
      insert into booking.payments(order_id, method, provider, status, amount, paid_at, created_by)
      values (v_order, v_method, 'manual', case when v_paid then 'paid' else 'pending' end, v_total,
              case when v_paid then now() end, auth.uid());
    end if;
    update booking.orders set payment_status = case when v_paid or v_total <= 0.004 then 'paid' else 'unpaid' end where id = v_order;
  end if;
  return v_res - 'public_token' || jsonb_build_object('customer_id', v_cust, 'total', v_total, 'addons_total', v_add) || v_extra;
end $$;


create or replace function booking._admin_create_legs(
  p_lifecycle text, p_product_id bigint, p_start timestamptz, p_end timestamptz, p_persons integer,
  p_customer_id bigint, p_customer jsonb, p_payment_method text, p_paid boolean, p_note text, p_price numeric,
  p_space_id bigint, p_override boolean, p_override_reason text, p_addons jsonb, p_parent_reservation_id bigint,
  p_invoice_reference text, p_quota_exempt boolean, p_option_code text default null,
  p_discount_code text default null, p_gift_card_code text default null, p_remainder_method text default null,
  p_allow_overbook boolean default false, p_allow_off_schedule boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_cust bigint := p_customer_id; v_pm booking.payment_methods; v_res jsonb; v_order bigint; v_add numeric; v_total numeric;
  v_ref text := nullif(btrim(coalesce(p_invoice_reference, '')), '');
  v_method text := p_payment_method; v_paid boolean := coalesce(p_paid, false); v_gc text := nullif(btrim(coalesce(p_gift_card_code, '')), '');
  v_disc jsonb; v_extra jsonb;
begin
  perform booking._require_permission('bookings.manage');
  if p_override then perform booking._require_permission('bookings.override'); end if;
  perform booking._arm_staff_overrides(p_allow_overbook, p_allow_off_schedule, null, null);
  if v_method = 'gift_card' and v_gc is null then perform booking._err('gift_card_code_required', 'Anna lahjakortin koodi.'); end if;
  if v_gc is not null then v_method := 'pay_later'; v_paid := false; end if;
  select * into v_pm from booking.payment_methods where code = v_method and active;
  if not found then perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä'); end if;
  if p_price is not null and p_price < 0 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  if v_ref is not null and char_length(v_ref) > 100 then perform booking._err('invalid_reference', 'Viite on liian pitkä (enintään 100 merkkiä)'); end if;
  if v_cust is null then
    if p_customer is null then perform booking._err('customer_required', 'Valitse asiakas tai anna nimi'); end if;
    v_cust := (booking.admin_create_customer(p_customer) ->> 'id')::bigint;
  elsif not exists (select 1 from booking.customers where id = v_cust) then
    perform booking._err('customer_not_found', 'Asiakasta ei löydy');
  end if;
  v_res := booking._create_legs_booking(p_lifecycle, p_product_id, p_start, p_end, p_persons, v_cust, 'admin', auth.uid(), p_note, p_price, p_space_id,
                                        p_override, p_override_reason, p_quota_exempt, p_parent_reservation_id, null, p_option_code);
  v_order := (v_res ->> 'order_id')::bigint;
  perform booking._stamp_order_billing(v_order, v_cust, null);
  if v_ref is not null then update booking.orders set invoice_reference = v_ref where id = v_order and customer_kind <> 'private'; end if;
  v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);
  v_disc := booking._apply_admin_discount(v_order, p_discount_code);
  v_total := (v_disc ->> 'total')::numeric;
  v_extra := v_disc;
  if coalesce((v_disc ->> 'payment_inserted')::boolean, false) then
    null;
  elsif v_gc is not null then
    v_extra := v_disc || booking._apply_admin_gift(v_order, v_gc, p_remainder_method, p_paid);
    v_total := coalesce((v_extra ->> 'total')::numeric, v_total);
  else
    if v_total > 0.004 then
      insert into booking.payments(order_id, method, provider, status, amount, paid_at, created_by)
      values (v_order, v_method, 'manual', case when v_paid then 'paid' else 'pending' end, v_total, case when v_paid then now() end, auth.uid());
    end if;
    update booking.orders set payment_status = case when v_paid or v_total <= 0.004 then 'paid' else 'unpaid' end where id = v_order;
  end if;
  return v_res || jsonb_build_object('customer_id', v_cust, 'total', v_total, 'addons_total', v_add) || v_extra;
end $$;


create or replace function booking._issue_giftcard_info_receipt(p_payment_id bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare pay booking.payments; o booking.orders; g booking.gift_cards; pm booking.payment_methods; v_lines jsonb; v_vat jsonb; v_gross numeric; v_vatsum numeric; v_buyer jsonb;
        v_seq int; v_year int; v_no text; v_ts timestamptz := now(); v_snap jsonb; v_id bigint; v_series text;
begin
  select * into pay from booking.payments where id = p_payment_id;
  if not found or pay.method is distinct from 'gift_card' or pay.amount <= 0 then return null; end if;
  if booking._is_johku_row(pay.order_id, pay.id) then return null; end if;
  select * into g from booking.gift_cards where id = pay.gift_card_id;
  if not found or g.accounting_origin is distinct from 'native' or g.source = 'johku' or g.vat_treatment is distinct from 'at_sale' or g.complimentary then return null; end if;
  select id into v_id from booking.receipts where payment_id = pay.id and kind = 'receipt';
  if found then return v_id; end if;
  select * into o from booking.orders where id = pay.order_id;
  if o.status = 'pending' then return null; end if;
  select * into pm from booking.payment_methods where code = pay.method;
  select jsonb_agg(jsonb_build_object('description', concat(pl.description, (select ' – ' || case when o.locale = 'en' then coalesce(po.name_en, po.name) else po.name end from booking.reservations rr join booking.product_options po on po.id = rr.product_option_id where rr.order_item_id = oi.id and oi.kind = 'reservation')), 'quantity', pl.quantity, 'unit_gross', round(pl.amount_gross / greatest(pl.quantity, 1), 2),
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
  -- Oma sarja (G, lunastus tiedoksi). Ei sama kirjain kuin laskuilla (L). Ei kuluta myyntitositteiden K-laskuria.
  v_series := coalesce(nullif(booking._setting('receipt_series', '{}'::jsonb) ->> 'giftcard_info', ''), 'G');
  v_seq := booking._next_receipt_no(v_series, v_year);
  v_no := format('%s-%s-%s', v_series, v_year, lpad(v_seq::text, 6, '0'));
  v_snap := jsonb_build_object('v', 1, 'document', 'receipt', 'informational', true, 'accounting', false, 'receipt_no', v_no, 'issued_at', v_ts, 'issued_local', to_char(v_ts at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI'),
     'seller', booking._seller(), 'order_no', o.order_no,
     'payment', jsonb_build_object('id', pay.id, 'method', pay.method, 'method_label', coalesce(pm.label, pay.method), 'paid_at', pay.paid_at),
     'buyer', v_buyer, 'invoice_required', false, 'lines', v_lines, 'vat', v_vat,
     'total_gross', v_gross, 'total_net', v_gross - v_vatsum, 'total_vat', v_vatsum, 'rounding', 0, 'total_paid', v_gross,
     'currency', 'EUR', 'original', null, 'reason', null, 'locale', case when o.locale = 'en' then 'en' else 'fi' end);
  insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, issued_at, total_gross, locale, snapshot, text_body, created_by)
  values (v_no, 'receipt', v_series, v_year, v_seq, o.id, pay.id, v_ts, v_gross, v_snap ->> 'locale', v_snap, booking._receipt_text(v_snap), auth.uid()) returning id into v_id;
  perform booking._enqueue_email('receipt', o.id, v_id, pay.id, 'receipt:' || v_id);
  return v_id;
end $$;


comment on function booking._issue_giftcard_info_receipt(bigint) is 'Maksetun oman at_sale-kortin lunastuksen tiedoksi-kuitti sarjassa G (receipt_series.giftcard_info). Laskut jäävät sarjaan L. Ei kuluta K-sarjaa. booking_217.';
comment on function booking.admin_report_csv(date, date, text) is 'CSV: lines ja transactions = tapahtumat, summary = yhteenveto, vat = ALV-erittely, methods = maksutavat. Vain reports.view. booking_217.';
