-- booking_34_talous_followups (17.10.2026): CSV-sarakkeet (Koodarin pyyntö), refunds negatiivisina raportissa, maksurivien net/vat_eur RPC:ssä, order_page_path. Vain create or replace + asetus. Rollback: booking_34_ROLLBACK.sql
create or replace function booking._report_json(p_from date, p_to date, p_receipts boolean, p_days boolean) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_res jsonb;
begin
  with rc as (
    select r.id, r.receipt_no, r.kind, r.issued_at, (r.issued_at at time zone 'Europe/Helsinki')::date as d, r.snapshot s, o.order_no,
           r.snapshot -> 'payment' ->> 'method' as method, coalesce(r.snapshot -> 'payment' ->> 'method_label', r.snapshot -> 'payment' ->> 'method') as mlabel,
           r.total_gross as gross, (r.snapshot ->> 'total_net')::numeric as net, (r.snapshot ->> 'total_vat')::numeric as vat, coalesce((r.snapshot ->> 'rounding')::numeric, 0) as rnd
      from booking.receipts r join booking.orders o on o.id = r.order_id
     where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to
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
  ), op as (
    select jsonb_build_object('orders', count(*), 'unpaid', coalesce(sum(u), 0)) j from (
      select o.id, greatest(o.total_gross - coalesce((select sum(p.amount - p.refunded_amount) from booking.payments p where p.order_id = o.id and p.status in ('paid','partially_refunded','refunded')), 0), 0) u
        from booking.orders o where o.external_source is null and o.status = 'confirmed'
         and (select min(r.starts_at at time zone 'Europe/Helsinki')::date from booking.reservations r where r.order_id = o.id and r.status = 'confirmed') between p_from and p_to) y where u > 0
  ), ur as (
    select jsonb_build_object('payments', count(*), 'amount', coalesce(sum(p.amount), 0)) j from booking.payments p
     where p.external_source is null and p.status in ('paid','partially_refunded','refunded') and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to
       and not exists (select 1 from booking.receipts r where r.payment_id = p.id and r.kind = 'receipt')
  )
  select jsonb_build_object('period', jsonb_build_object('from', p_from, 'to', p_to, 'tz', 'Europe/Helsinki'), 'generated_at', now(), 'basis', 'cash (kuitin antamispäivä)',
         'totals', tot.j, 'by_method', bm.j, 'by_vat', bv.j, 'by_method_vat', bmv.j, 'by_category', bc.j, 'open', op.j, 'unreceipted', ur.j)
         || case when p_receipts then jsonb_build_object('receipts', rl.j) else '{}'::jsonb end
         || case when p_days then jsonb_build_object('by_day', bd.j) else '{}'::jsonb end
    into v_res from tot, bm, bv, bmv, bc, rl, bd, op, ur;
  return v_res;
end $$;


create or replace function booking.admin_report_csv(p_from date, p_to date, p_kind text default 'lines') returns jsonb language plpgsql stable security definer set search_path = '' as $$
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
     where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to;
  else
    v_hdr := 'pvm;kuitti;tilaus;tyyppi;maksutapa;alv_prosentti;netto;alv_eur;brutto';
    select coalesce(string_agg(concat_ws(';', to_char(r.issued_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY'), r.receipt_no, o.order_no::text, case when r.kind = 'receipt' then 'kuitti' else 'hyvitys' end,
             booking._csv(r.snapshot -> 'payment' ->> 'method_label'), booking._csvnum((v.e ->> 'rate')::numeric), booking._csvmoney((v.e ->> 'net')::numeric),
             booking._csvmoney((v.e ->> 'vat')::numeric), booking._csvmoney((v.e ->> 'gross')::numeric)), v_cr order by r.issued_at, r.id, v.n), '') into v_body
      from booking.receipts r join booking.orders o on o.id = r.order_id, jsonb_array_elements(r.snapshot -> 'vat') with ordinality as v(e, n)
     where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to;
  end if;
  return jsonb_build_object('filename', format('kuitit_%s_%s_%s.csv', p_kind, p_from, p_to), 'mime', 'text/csv;charset=utf-8',
                            'content', chr(65279) || v_hdr || v_cr || v_body || case when v_body <> '' then v_cr else '' end);
end $$;


CREATE OR REPLACE FUNCTION booking._link_json(p_payment_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object('payment_id', p.id, 'link_token', p.link_token,
           'link_path', booking._setting('payment_link_path', to_jsonb('/maksa/'::text)) #>> '{}' || '?p=' || p.link_token,
           'amount', p.amount, 'expires_at', p.link_expires_at,
           'lines', coalesce((select jsonb_agg(jsonb_build_object('id', pl.id, 'order_item_id', pl.order_item_id, 'description', pl.description,
                        'quantity', pl.quantity, 'amount_gross', pl.amount_gross, 'vat_rate', pl.vat_rate, 'net', pl.line_net, 'vat_eur', pl.amount_gross - pl.line_net) order by pl.id)
                     from booking.payment_lines pl where pl.payment_id = p.id), '[]'::jsonb))
    from booking.payments p where p.id = p_payment_id
$function$;

CREATE OR REPLACE FUNCTION booking.admin_get_order(p_order_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; c booking.customers; v_end timestamptz; v_site text; v_op text; v_pp text;
begin
  perform booking._require_staff();
  select * into o from booking.orders where id = p_order_id;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  select * into c from booking.customers where id = o.customer_id;
  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  v_site := coalesce(booking._setting('site_base_url') #>> '{}', ''); v_op := coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/');
  v_pp := coalesce(booking._setting('payment_link_path') #>> '{}', '/maksa/');
  return jsonb_build_object(
    'order_id', o.id, 'order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'total', o.total_gross,
    'source_channel', o.source_channel, 'created_at', o.created_at, 'customer_note', o.customer_note, 'internal_note', o.internal_note,
    'customer_kind', o.customer_kind, 'billing', o.billing, 'invoice_reference', o.invoice_reference,
    'customer', case when c.id is null then null else jsonb_build_object('id', c.id, 'name', c.name, 'email', c.email, 'phone', c.phone,
        'company', c.company, 'customer_kind', c.customer_kind, 'business_id', c.business_id) end,
    'reservations', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status, 'product_name', it.product_name, 'mode', r.mode,
        'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'notes', r.notes, 'item_total', it.line_total_gross, 'item_id', r.order_item_id,
        'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', ai.addon_id, 'name', ai.product_name, 'quantity', ai.quantity,
                     'unit_price', ai.unit_price_gross, 'line_total', ai.line_total_gross, 'vat_rate', ai.vat_rate) order by ai.id)
                   from booking.order_items ai where ai.parent_item_id = r.order_item_id and ai.kind = 'addon'), '[]'::jsonb)) order by r.starts_at)
        from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id), '[]'::jsonb),
    'public_token', o.public_token, 'order_page_path', v_site || v_op || '?t=' || o.public_token, 'is_native', o.external_source is null,
    'balance', booking._order_balance(o.id),
    'can_add', o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now(), 'add_until', v_end,
    'staff_can_add', o.external_source is null and o.status in ('confirmed','completed'),
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
        'handled_at', q.handled_at, 'note', q.note) order by q.id) from booking.order_requests q where q.order_id = o.id), '[]'::jsonb));
end $function$;

insert into booking.settings(key, value, description, is_public) values ('order_page_path', to_jsonb('/tilaus/'::text), 'Asiakkaan tilaussivun polku (linkki: site_base_url + polku + ?t=<orders.public_token>). Päätetty 17.10.2026: /tilaus/ (lyhyt; /varaa/tilaus/ ohjataan sivustolla tälle)', false)
on conflict (key) do update set value = excluded.value, description = excluded.description;
