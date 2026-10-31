-- booking_222 rollback. Palauttaa raporttifunktiot booking_217/219/216/118-määrittelyihin.
set local lock_timeout = '5s';

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

create or replace function booking._report_tx(p_from date, p_to date)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
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
      select coalesce(o.confirmed_at, o.created_at), o.id, u.item_id,
             jsonb_build_object(
               'voucher', o.order_no::text,
               'date', to_char((coalesce(o.confirmed_at, o.created_at) at time zone 'Europe/Helsinki')::date, 'YYYY-MM-DD'),
               'customer', coalesce(c.name, ''),
               'product', coalesce(u.description, ''),
               'quantity', case when abs(u.remaining - i.line_total_gross) < 0.005 then u.quantity else 1 end,
               'net', u.remaining - round(u.remaining * coalesce(u.vat_rate, 0) / nullif(100 + coalesce(u.vat_rate, 0), 0), 2),
               'vat_rate', coalesce(u.vat_rate, 0),
               'vat', round(u.remaining * coalesce(u.vat_rate, 0) / nullif(100 + coalesce(u.vat_rate, 0), 0), 2),
               'gross', u.remaining,
               'method', '',
               'method_label', '',
               'status', 'open',
               'kind', 'sale')
        from booking.orders o
        left join booking.customers c on c.id = o.customer_id
        cross join lateral booking._order_uncovered(o.id, false) u
        join booking.order_items i on i.id = u.item_id
       where o.status = 'confirmed'
         and not booking._acct_excluded(o.id, null)
         and (coalesce(o.confirmed_at, o.created_at) at time zone 'Europe/Helsinki')::date between p_from and p_to
         and u.remaining > 0.004
    ) x
$$;

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

create or replace function booking.admin_report_provider_fees(p_from date, p_to date, p_format text default 'json')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rep jsonb; v_body text := ''; v_cr text := E'\r\n';
begin
  perform booking._require_permission('reports.view');
  if p_from is null or p_to is null or p_to < p_from or (p_to - p_from) > 366 then
    perform booking._err('invalid_param', 'Virheellinen aikaväli (enintään 366 päivää)');
  end if;
  if coalesce(p_format, 'json') not in ('json', 'csv') then
    perform booking._err('invalid_param', 'Tuntematon muoto');
  end if;

  with lines as (
    select 'sale'::text as direction, p.provider, p.method, pm.label as method_label, p.amount as gross,
           case when p.provider_fee is not null then 'actual' when rule.id is not null then 'estimated' else 'missing' end as basis,
           case when p.provider_fee is not null then round(p.provider_fee, 2)
                when rule.id is not null then round(rule.fixed_eur + p.amount * rule.percent / 100, 2)
                else null end as fee
      from booking.payments p
      left join booking.payment_methods pm on pm.code = p.method
      left join lateral (
        select f.id, f.fixed_eur, f.percent
          from booking.payment_fee_rules f
         where f.active and f.provider = p.provider and (f.method = p.method or f.method = '*')
         order by case when f.method = p.method then 0 else 1 end, f.id
         limit 1
      ) rule on true
     where p.status in ('paid', 'partially_refunded', 'refunded')
       and p.paid_at is not null
       and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to
    union all
    select 'refund', p.provider, p.method, pm.label, f.amount,
           case when f.provider_fee is not null then 'actual' when rule.id is not null then 'estimated' else 'missing' end,
           case when f.provider_fee is not null then round(f.provider_fee, 2)
                when rule.id is not null then round(rule.fixed_eur + f.amount * rule.percent / 100, 2)
                else null end
      from booking.refunds f
      join booking.payments p on p.id = f.payment_id
      left join booking.payment_methods pm on pm.code = p.method
      left join lateral (
        select r.id, r.fixed_eur, r.percent
          from booking.payment_fee_rules r
         where r.active and r.provider = p.provider and (r.method = p.method or r.method = '*')
         order by case when r.method = p.method then 0 else 1 end, r.id
         limit 1
      ) rule on true
     where f.status = 'done' and f.done_at is not null
       and (f.done_at at time zone 'Europe/Helsinki')::date between p_from and p_to
  ),
  agg as (
    select direction, provider, method, max(method_label) as method_label, basis,
           count(*)::int as n,
           round(sum(gross), 2) as gross,
           case when bool_or(fee is null) then null else round(sum(fee), 2) end as fee
      from lines
     group by direction, provider, method, basis
  ),
  tot as (
    select
      count(*) filter (where direction = 'sale')::int as sales_count,
      coalesce(round(sum(gross) filter (where direction = 'sale'), 2), 0) as sales_gross,
      count(*) filter (where direction = 'sale' and fee is null)::int as sales_missing,
      coalesce(round(sum(fee) filter (where direction = 'sale'), 2), 0) as sales_fee_sum,
      count(*) filter (where direction = 'refund')::int as refund_count,
      coalesce(round(sum(gross) filter (where direction = 'refund'), 2), 0) as refund_gross,
      count(*) filter (where direction = 'refund' and fee is null)::int as refund_missing,
      coalesce(round(sum(fee) filter (where direction = 'refund'), 2), 0) as refund_fee_sum
    from lines
  )
  select jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to, 'kind', 'range'),
    'timezone', 'Europe/Helsinki',
    'basis', 'paid_at',
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'provider', a.provider,
               'provider_label', booking._provider_admin_label(a.provider),
               'method', a.method,
               'method_label', coalesce(a.method_label, a.method),
               'direction', a.direction,
               'basis', a.basis,
               'count', a.n,
               'gross', a.gross,
               'fee', a.fee,
               'net', case when a.fee is null then null
                           when a.direction = 'sale' then round(a.gross - a.fee, 2)
                           else round(-(a.gross + a.fee), 2) end)
             order by case a.direction when 'sale' then 0 else 1 end, a.provider, a.method,
                      case a.basis when 'actual' then 0 when 'estimated' then 1 else 2 end)
        from agg a), '[]'::jsonb),
    'totals', (
      select jsonb_build_object(
        'sales_count', t.sales_count,
        'sales_gross', t.sales_gross,
        'sales_fee', case when t.sales_missing > 0 then null else t.sales_fee_sum end,
        'sales_net', case when t.sales_missing > 0 then null else round(t.sales_gross - t.sales_fee_sum, 2) end,
        'refund_count', t.refund_count,
        'refund_gross', t.refund_gross,
        'refund_fee', case when t.refund_missing > 0 then null else t.refund_fee_sum end,
        'refund_net', case when t.refund_missing > 0 then null else round(-(t.refund_gross + t.refund_fee_sum), 2) end,
        'settlement', case when t.sales_missing > 0 or t.refund_missing > 0 then null
                           else round((t.sales_gross - t.sales_fee_sum) - (t.refund_gross + t.refund_fee_sum), 2) end,
        'missing', t.sales_missing + t.refund_missing)
      from tot t)
  ) into v_rep;

  if p_format = 'json' then return v_rep; end if;

  select coalesce((
    select string_agg(concat_ws(';',
             booking._csv(x ->> 'provider_label'),
             booking._csv(x ->> 'method_label'),
             case x ->> 'direction' when 'refund' then 'hyvitys' else 'maksu' end,
             case x ->> 'basis' when 'actual' then 'toteutunut' when 'estimated' then 'arvio' else 'puuttuu' end,
             coalesce(x ->> 'count', '0'),
             booking._csvmoney(coalesce((x ->> 'gross')::numeric, 0)),
             case when x ->> 'fee' is null then '' else booking._csvmoney((x ->> 'fee')::numeric) end,
             case when x ->> 'net' is null then '' else booking._csvmoney((x ->> 'net')::numeric) end),
           v_cr order by t.n) || v_cr
      from jsonb_array_elements(v_rep -> 'rows') with ordinality as t(x, n)
  ), '') into v_body;
  return jsonb_build_object(
    'filename', format('provisio_%s_%s.csv', p_from, p_to),
    'mime', 'text/csv;charset=utf-8',
    'content', chr(65279) || 'palvelu;maksutapa;laji;lahde;kpl;brutto;provisio;netto' || v_cr || v_body);
end $$;

create or replace function booking.admin_report_accrual_csv(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_body text := '';
  v_cr text := E'\r\n';
  rep jsonb;
  el jsonb;
  g jsonb;
begin
  perform booking._report_check(true);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    perform booking._err('invalid_param', 'Virheellinen aikaväli (enintään 366 päivää)');
  end if;
  rep := booking._accrual_json(p_from, p_to, p_to);
  for el in select value from jsonb_array_elements(rep -> 'sales_by_product') loop
    v_body := v_body || concat_ws(';', 'myynti', booking._csv(el ->> 'product'), booking._csvnum((el ->> 'rate')::numeric),
      booking._csvnum((el ->> 'quantity')::numeric), booking._csvmoney((el ->> 'net')::numeric),
      booking._csvmoney((el ->> 'vat')::numeric), booking._csvmoney((el ->> 'gross')::numeric)) || v_cr;
  end loop;
  for el in select value from jsonb_array_elements(rep -> 'refunds_by_product') loop
    v_body := v_body || concat_ws(';', 'hyvitys', booking._csv(el ->> 'product'), booking._csvnum((el ->> 'rate')::numeric),
      booking._csvnum((el ->> 'quantity')::numeric), booking._csvmoney((el ->> 'net')::numeric),
      booking._csvmoney((el ->> 'vat')::numeric), booking._csvmoney((el ->> 'gross')::numeric)) || v_cr;
  end loop;
  for el in select value from jsonb_array_elements(rep -> 'sales_by_vat') loop
    v_body := v_body || concat_ws(';', 'alv_myynti', '', booking._csvnum((el ->> 'rate')::numeric),
      booking._csvnum((el ->> 'quantity')::numeric), booking._csvmoney((el ->> 'net')::numeric),
      booking._csvmoney((el ->> 'vat')::numeric), booking._csvmoney((el ->> 'gross')::numeric)) || v_cr;
  end loop;
  for el in select value from jsonb_array_elements(rep -> 'refunds_by_vat') loop
    v_body := v_body || concat_ws(';', 'alv_hyvitys', '', booking._csvnum((el ->> 'rate')::numeric),
      booking._csvnum((el ->> 'quantity')::numeric), booking._csvmoney((el ->> 'net')::numeric),
      booking._csvmoney((el ->> 'vat')::numeric), booking._csvmoney((el ->> 'gross')::numeric)) || v_cr;
  end loop;
  for el in select value from jsonb_array_elements(rep -> 'advances' -> 'services' -> 'by_vat') loop
    v_body := v_body || concat_ws(';', 'ennakko', 'Saadut ennakot', booking._csvnum((el ->> 'rate')::numeric), '',
      booking._csvmoney((el ->> 'net')::numeric), booking._csvmoney((el ->> 'vat')::numeric),
      booking._csvmoney((el ->> 'gross')::numeric)) || v_cr;
  end loop;
  g := rep -> 'advances' -> 'gift_cards_unused';
  v_body := v_body || concat_ws(';', 'ennakko', 'Lahjakortit kayttamatta', booking._csvnum(25.5),
    booking._csvnum(coalesce((g ->> 'count')::numeric, 0)),
    booking._csvmoney(coalesce((g ->> 'net')::numeric, 0)),
    booking._csvmoney(coalesce((g ->> 'vat')::numeric, 0)),
    booking._csvmoney(coalesce((g ->> 'gross')::numeric, 0))) || v_cr;
  v_body := v_body || concat_ws(';', 'ennakko', 'Saadut ennakot yhteensa', '', '', '', '',
    booking._csvmoney(coalesce((rep #>> '{advances,total_gross}')::numeric, 0))) || v_cr;
  return jsonb_build_object(
    'filename', format('suorite_%s_%s.csv', p_from, p_to),
    'mime', 'text/csv;charset=utf-8',
    'content', chr(65279) || 'osio;tuote;alv_%;maara;netto;alv_eur;brutto' || v_cr || v_body
  );
end $$;


drop function if exists booking.admin_report_gift_cards(text, text, date, date);
drop function if exists booking._report_open_rows(date);
drop function if exists booking._order_open_lines(bigint);
drop function if exists booking._order_open_amount(bigint);

create or replace function booking.admin_report_gift_cards(p_filter text, p_format text default 'json')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare rep jsonb; v_body text := ''; v_cr text := E'\r\n'; el jsonb; bucket text; b jsonb;
begin
  perform booking._report_check(true);
  if p_filter is null or p_filter not in ('open', 'used', 'all') then perform booking._err('invalid_param', 'p_filter: open|used|all'); end if;
  if coalesce(p_format, 'json') not in ('json', 'csv') then perform booking._err('invalid_param', 'p_format: json|csv'); end if;
  rep := booking._gc_stock_report(p_filter);
  if p_format is distinct from 'csv' then return rep; end if;
  for el in select * from jsonb_array_elements(rep -> 'own' -> 'rows') loop
    v_body := v_body || concat_ws(';', 'oma', booking._csv(el ->> 'code_masked'), booking._csv(el ->> 'buyer'), booking._csv(el ->> 'package'),
      booking._csvmoney(coalesce((el ->> 'initial')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'balance')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)),
      booking._csvnum(coalesce((el ->> 'vat_rate')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0)),
      booking._csv(el ->> 'sold_on'), booking._csv(el ->> 'valid_to'), booking._csv(el ->> 'status'), booking._csv(el ->> 'vat_treatment')) || v_cr;
  end loop;
  for el in select * from jsonb_array_elements(rep -> 'johku' -> 'rows') loop
    v_body := v_body || concat_ws(';', 'johku', booking._csv(el ->> 'code_masked'), booking._csv(el ->> 'buyer'), booking._csv(el ->> 'package'),
      booking._csvmoney(coalesce((el ->> 'initial')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'balance')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'net')::numeric, 0)),
      booking._csvnum(coalesce((el ->> 'vat_rate')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'vat')::numeric, 0)), booking._csvmoney(coalesce((el ->> 'gross')::numeric, 0)),
      booking._csv(el ->> 'sold_on'), booking._csv(el ->> 'valid_to'), booking._csv(el ->> 'status'), booking._csv(el ->> 'vat_treatment')) || v_cr;
  end loop;
  foreach bucket in array array['oma_myynnissa', 'oma_maksuton', 'johku'] loop
    b := case bucket when 'oma_myynnissa' then rep -> 'own' -> 'at_sale' when 'oma_maksuton' then rep -> 'own' -> 'complimentary' else rep -> 'johku' -> 'totals' end;
    v_body := v_body || concat_ws(';', 'yhteenveto', bucket, b ->> 'count', '',
      booking._csvmoney((b ->> 'initial')::numeric), booking._csvmoney((b ->> 'balance')::numeric), booking._csvmoney((b ->> 'net')::numeric),
      '', booking._csvmoney((b ->> 'vat')::numeric), booking._csvmoney((b ->> 'gross')::numeric), '', '', '', '') || v_cr;
  end loop;
  return jsonb_build_object('filename', format('lahjakortit_%s.csv', p_filter), 'mime', 'text/csv;charset=utf-8',
                            'content', chr(65279) || 'osio;koodi;ostaja;paketti;alkuperainen;saldo;netto;alv_%;alv_eur;brutto;myyntipaiva;voimassa;tila;alv_kasittely' || v_cr || v_body);
end $$;

revoke all on function booking.admin_report_gift_cards(text, text) from public, anon, authenticated;
grant execute on function booking.admin_report_gift_cards(text, text) to service_role, authenticated;
comment on function booking.admin_report_gift_cards(text, text) is 'Lahjakorttivarasto (open|used|all). Maksettu oma kortti, maksuton ja Johku erillään. Johku ei ole oman myynnin ALV-summissa. booking_118.';
comment on function booking.admin_report_csv(date, date, text) is 'CSV: lines ja transactions = tapahtumat, summary = yhteenveto, vat = ALV-erittely, methods = maksutavat. Vain reports.view. booking_217.';
comment on function booking.admin_report_provider_fees(date, date, text) is 'booking_216: provisioraportti palveluittain ja maksutavoittain. Vain reports.view. JSON tai CSV (puolipiste, suomalainen desimaali). Hyvitykset erikseen.';
comment on function booking.admin_report_accrual_csv(date, date) is 'booking_219: suorite-CSV, sama erotin, BOM ja rivinvaihto kuin admin_report_csv. Vain reports.view.';
