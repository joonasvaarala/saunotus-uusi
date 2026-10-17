-- booking_38_addon_merge_hide (17.10.2026): piilota yhdistetyt Johku-varausrivit (7 kpl, kb 45). Edellyttää booking_37:n addon-rivit (tarkistetaan).
-- Piilotus: status='cancelled' (saatavuus, _res_active, admin_day_view, _sessions, v_claims ohittavat; rivit olivat space 15 'ei_resurssia', ei legejä -> ei kapasiteettivaikutusta)
-- + hidden_at/hidden_reason (ei poistoa). Listaukset (admin_get_order, public_get_order, admin_list_reservations, admin_list_orders, admin_get_customer) suodattavat hidden_at is null.
-- Tilausten tila/summa/maksutila EI muutu (ei admin_set_reservation_status -polkua). Rollback: booking_37_38_ROLLBACK.sql.
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
        from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id and r.hidden_at is null), '[]'::jsonb),
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
end $function$
;

CREATE OR REPLACE FUNCTION booking.public_get_order(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; v_cust text; v_bal jsonb; v_end timestamptz; v_conf_n int; v_conf_start timestamptz; v_kind text; v_hours int;
  v_items jsonb; v_res jsonb; v_pay jsonb; v_rec jsonb; v_creq jsonb; v_ups_a jsonb; v_ups_t jsonb; v_can_add boolean; v_pl text; v_open boolean; v_status text; v_online boolean;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._order_rl('get', p_token, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  v_hours := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  select split_part(c.name, ' ', 1) into v_cust from booking.customers c where c.id = o.customer_id;
  v_bal := booking._order_balance(o.id);
  v_status := case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) then 'expired' else o.status end;
  v_online := exists (select 1 from booking.integration_config where key = 'vismapay' and mode = 'live');
  v_pl := booking._setting('payment_link_path', to_jsonb('/maksa/'::text)) #>> '{}';

  select coalesce(jsonb_agg(jsonb_build_object('name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate, 'kind', it.kind) order by it.id), '[]'::jsonb)
    into v_items from booking.order_items it where it.order_id = o.id;
  select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'product_id', r.product_id, 'product_name', oi.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons,
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() then 'expired' else r.status end,
           'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', a.addon_id, 'name', a.product_name, 'quantity', a.quantity, 'line_total', a.line_total_gross) order by a.id)
                                 from booking.order_items a where a.parent_item_id = r.order_item_id and a.kind = 'addon'), '[]'::jsonb)) order by r.starts_at), '[]'::jsonb)
    into v_res from booking.reservations r left join booking.order_items oi on oi.id = r.order_item_id where r.order_id = o.id and r.hidden_at is null;
  select coalesce(jsonb_agg(jsonb_build_object('status', p.status, 'amount', p.amount, 'paid_at', p.paid_at, 'method_label', coalesce(pm.label, p.method),
           'link_token', case when p.status = 'pending' and p.provider = 'visma_pay' and (p.link_expires_at is null or p.link_expires_at > now()) then p.link_token end,
           'link_path', case when p.status = 'pending' and p.provider = 'visma_pay' and (p.link_expires_at is null or p.link_expires_at > now()) then v_pl || '?p=' || p.link_token end,
           'refunded', p.refunded_amount) order by p.created_at, p.id), '[]'::jsonb)
    into v_pay from booking.payments p left join booking.payment_methods pm on pm.code = p.method
   where p.order_id = o.id and p.status <> 'cancelled'
     and not (p.provider = 'manual' and p.status = 'pending' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id));
  select coalesce(jsonb_agg(jsonb_build_object('receipt_no', x.receipt_no, 'kind', x.kind, 'issued_at', x.issued_at, 'token', x.public_token, 'total', x.total_gross) order by x.issued_at, x.id), '[]'::jsonb)
    into v_rec from booking.receipts x where x.order_id = o.id;
  select jsonb_build_object('status', q.status, 'created_at', q.created_at) into v_creq from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' order by q.created_at desc, q.id desc limit 1;

  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  v_can_add := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now();
  v_open := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not exists (select 1 from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' and q.status = 'open');
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;

  if v_can_add then
    select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'name_en', a.name_en, 'description', a.description, 'description_en', a.description_en, 'price', a.price_gross, 'vat_rate', a.vat_rate,
             'max', x.lim, 'reservation_ids', x.rids) order by a.sort_order, a.id), '[]'::jsonb) into v_ups_a
      from booking.addons a
      join lateral (select max(booking._addon_limit(a.max_per_person, r.persons)) lim, jsonb_agg(r.id order by r.id) rids
                      from booking.reservations r left join booking.product_config pc on pc.product_id = r.product_id left join kb.products p on p.id = r.product_id
                     where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at) and r.ends_at > now()
                       and coalesce(case when pc.sale_kind = 'other' and pc.resource_class = 'resourced' then case when p.category = 'event' then 'event' else 'resource' end else r.mode end, r.mode) = any (a.applies_modes)) x on x.rids is not null
     where a.active;
    select coalesce(jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'name_en', p.name_en, 'price', p.price, 'duration_minutes', coalesce(pc.duration_minutes, p.duration_minutes),
             'description', p.description, 'description_en', p.description_en, 'category', p.category) order by pc.sort_order, p.id), '[]'::jsonb) into v_ups_t
      from booking.product_config pc join kb.products p on p.id = pc.product_id
     where pc.public_slots and pc.bookable and pc.shop_visible and pc.lifecycle = 'current' and p.active and p.price is not null;
  end if;

  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status', v_status, 'payment_status', o.payment_status, 'currency', o.currency, 'locale', coalesce(o.locale, 'fi'),
    'created_at', o.created_at, 'first_name', v_cust, 'customer_kind', o.customer_kind,
    'total', v_bal -> 'total', 'paid', v_bal -> 'net_paid', 'refunded', v_bal -> 'refunded', 'unpaid', v_bal -> 'unpaid',
    'items', v_items, 'reservations', v_res, 'payments', v_pay, 'receipts', v_rec,
    'can_add', v_can_add, 'add_until', case when v_can_add then v_end end,
    'can_change', (o.status = 'confirmed' and o.external_source is null and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_kind in ('rules', 'slots')),
    'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end, 'change_hours_before', v_hours,
    'change_via', case v_kind when 'slots' then 'public_change_order_time' when 'rules' then 'public_change_order_time' end, 'booking_kind', v_kind,
    'can_request_cancel', v_open, 'cancel_request', v_creq, 'online_payment_enabled', v_online,
    'upsell', jsonb_build_object('addons', coalesce(v_ups_a, '[]'::jsonb), 'treatments', coalesce(v_ups_t, '[]'::jsonb)));
end $function$
;

CREATE OR REPLACE FUNCTION booking.admin_list_reservations(p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_product_id bigint DEFAULT NULL::bigint, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_source text DEFAULT NULL::text)
 RETURNS TABLE(reservation_id bigint, order_id bigint, order_no bigint, status text, order_status text, payment_status text, product_id bigint, product_name text, mode text, starts_at timestamp with time zone, ends_at timestamp with time zone, persons integer, total_gross numeric, customer_id bigint, customer_name text, customer_email text, customer_phone text, source_channel text, created_at timestamp with time zone, hold_expires_at timestamp with time zone, notes text, annual_card_id bigint, total_count bigint, source text, external_id text, lifecycle text, space_code text, legs jsonb, parent_reservation_id bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform booking._require_staff();
  return query
    select r.id, o.id, o.order_no,
           case when r.status = 'pending' and r.hold_expires_at <= now() then 'expired' else r.status end,
           o.status, o.payment_status, r.product_id, coalesce(it.product_name, p.name), r.mode, r.starts_at, r.ends_at, r.persons,
           o.total_gross, c.id, c.name, c.email, c.phone, o.source_channel, o.created_at, r.hold_expires_at, r.notes, r.annual_card_id,
           count(*) over (), coalesce(r.external_source, 'native'), r.external_id,
           pcf.lifecycle, sp.code,
           coalesce((select jsonb_agg(jsonb_build_object('role', l.role, 'resource_code', lr.code, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'persons', l.persons, 'skill', l.skill)
                                      order by l.starts_at, l.id)
                       from booking.reservation_legs l join booking.resources lr on lr.id = l.resource_id where l.reservation_id = r.id), '[]'::jsonb),
           r.parent_reservation_id
      from booking.reservations r
      join booking.orders o on o.id = r.order_id
      join booking.resources sp on sp.id = r.space_id
      left join booking.order_items it on it.id = r.order_item_id
      left join kb.products p on p.id = r.product_id
      left join booking.product_config pcf on pcf.product_id = r.product_id
      left join booking.customers c on c.id = o.customer_id
     where r.hidden_at is null and (p_from is null or r.starts_at >= p_from) and (p_to is null or r.starts_at < p_to)
       and (p_product_id is null or r.product_id = p_product_id)
       and (p_source is null or coalesce(r.external_source, 'native') = p_source)
       and (p_status is null
            or (p_status = 'active' and booking._res_active(r.status, r.hold_expires_at))
            or (p_status = 'expired' and r.status = 'pending' and r.hold_expires_at <= now()) or r.status = p_status)
       and (q is null or c.name ilike '%' || q || '%' or c.email ilike '%' || q || '%' or c.phone ilike '%' || q || '%'
            or o.order_no::text = q or c.company ilike '%' || q || '%')
     order by r.starts_at desc, r.id desc
     limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0);
end $function$
;

CREATE OR REPLACE FUNCTION booking.admin_list_orders(p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_payment_status text DEFAULT NULL::text, p_source text DEFAULT NULL::text, p_native boolean DEFAULT NULL::boolean, p_date_field text DEFAULT 'created'::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_sort text DEFAULT 'created_desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_s text := nullif(btrim(coalesce(p_search, '')), ''); v_num bigint; v_like text; v_total int; v_rows jsonb; v_lim int := coalesce(p_limit, 50); v_off int := greatest(coalesce(p_offset, 0), 0);
begin
  perform booking._require_staff();
  if p_sort is null or p_sort not in ('created_desc','created_asc','order_no_desc','order_no_asc','total_desc','total_asc','start_desc','start_asc','paid_desc','paid_asc','unpaid_desc') then
    perform booking._err('invalid_sort', 'Tuntematon lajittelu'); end if;
  if v_lim < 1 or v_lim > 200 then perform booking._err('invalid_param', 'p_limit 1–200'); end if;
  if coalesce(p_date_field, 'created') not in ('created','start') then perform booking._err('invalid_param', 'p_date_field: created|start'); end if;
  if v_s ~ '^\d{1,12}$' then v_num := v_s::bigint; end if;
  if v_s is not null then v_like := '%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  with base as (
    select o.id, o.order_no, o.johku_order_no, o.created_at, o.status, o.payment_status, o.source_channel, (o.external_source is null) as is_native, o.total_gross,
           pp.paid, pp.refunded, pp.pc, pp.lp, rr.fs, rr.le, rr.cnt, rcc.rc,
           case when o.status in ('cancelled','expired','draft') then 0 else greatest(o.total_gross - (pp.paid - pp.refunded), 0) end as unpaid,
           c.id as cid, c.name as cname, c.company as ccompany, o.customer_kind
      from booking.orders o
      left join booking.customers c on c.id = o.customer_id
      left join lateral (select min(r.starts_at) fs, max(r.ends_at) le, count(*) cnt from booking.reservations r where r.order_id = o.id and r.hidden_at is null) rr on true
      left join lateral (select coalesce(sum(p.amount) filter (where p.status in ('paid','partially_refunded','refunded')), 0) paid, coalesce(sum(p.refunded_amount), 0) refunded,
                                count(*) filter (where p.status in ('paid','partially_refunded','refunded')) pc, max(p.paid_at) lp
                           from booking.payments p where p.order_id = o.id) pp on true
      left join lateral (select count(*) rc from booking.receipts x where x.order_id = o.id) rcc on true
     where (p_status is null or o.status = p_status)
       and (p_payment_status is null or o.payment_status = p_payment_status)
       and (p_source is null or o.source_channel = p_source)
       and (p_native is null or (o.external_source is null) = p_native)
       and (v_s is null or (v_num is not null and (o.order_no = v_num or o.johku_order_no = v_num))
            or (v_num is null and (c.name ilike v_like or c.email ilike v_like or c.phone ilike v_like or c.company ilike v_like)))
       and (p_from is null or case when coalesce(p_date_field, 'created') = 'created' then (o.created_at at time zone 'Europe/Helsinki')::date else (rr.fs at time zone 'Europe/Helsinki')::date end >= p_from)
       and (p_to   is null or case when coalesce(p_date_field, 'created') = 'created' then (o.created_at at time zone 'Europe/Helsinki')::date else (rr.fs at time zone 'Europe/Helsinki')::date end <= p_to)
  ), page as (
    select b.*, row_number() over (order by
        case when p_sort = 'created_asc' then b.created_at end asc, case when p_sort = 'created_desc' then b.created_at end desc,
        case when p_sort = 'order_no_asc' then b.order_no end asc, case when p_sort = 'order_no_desc' then b.order_no end desc,
        case when p_sort = 'total_asc' then b.total_gross end asc, case when p_sort = 'total_desc' then b.total_gross end desc,
        case when p_sort = 'start_asc' then b.fs end asc nulls last, case when p_sort = 'start_desc' then b.fs end desc nulls last,
        case when p_sort = 'paid_asc' then b.lp end asc nulls last, case when p_sort = 'paid_desc' then b.lp end desc nulls last,
        case when p_sort = 'unpaid_desc' then b.unpaid end desc, b.id desc) as rn
      from base b
  )
  select (select count(*) from base),
         coalesce(jsonb_agg(jsonb_build_object('order_id', p.id, 'order_no', p.order_no, 'johku_order_no', p.johku_order_no, 'created_at', p.created_at, 'status', p.status,
           'payment_status', p.payment_status, 'source_channel', p.source_channel, 'is_native', p.is_native, 'total', p.total_gross, 'paid', p.paid, 'refunded', p.refunded,
           'unpaid', p.unpaid, 'customer_id', p.cid, 'customer_name', p.cname, 'customer_company', p.ccompany, 'customer_kind', p.customer_kind, 'first_start', p.fs, 'last_end', p.le,
           'reservation_count', p.cnt, 'payment_count', p.pc, 'last_paid_at', p.lp, 'receipt_count', p.rc) order by p.rn), '[]'::jsonb)
    into v_total, v_rows from page p where p.rn > v_off and p.rn <= v_off + v_lim;
  return jsonb_build_object('total', v_total, 'rows', v_rows);
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
      order by o.created_at desc) from booking.orders o where o.customer_id = c.id), '[]'::jsonb));
end $function$
;

do $$
declare m record; n int;
begin
  for m in select * from (values
    (13679,11596,10223,13678,2,30),
    (13686,11602,10228,13685,2,30),
    (13386,11369,10238,13384,5,75),
    (13691,11606,10263,13690,2,30),
    (13573,11510,10297,13572,1,15),
    (13674,11593,10363,13673,5,75),
    (13641,11569,10382,13640,2,30)
  ) as t(item_id, order_id, res_id, parent_item_id, qty, line_total) loop
    if not exists (select 1 from booking.order_items a where a.id = m.item_id and a.kind = 'addon' and a.addon_id = 1 and a.parent_item_id = m.parent_item_id and a.order_id = m.order_id) then
      raise exception 'addon-rivi % puuttuu, ei piiloteta varausta %', m.item_id, m.res_id;
    end if;
    update booking.reservations r set
        status = 'cancelled', cancelled_at = now(), cancel_reason = 'merged_into_addon',
        hidden_at = now(), hidden_reason = 'merged_into_addon:order_item=' || m.item_id,
        external_meta = coalesce(r.external_meta, '{}'::jsonb) || jsonb_build_object('merged_into', jsonb_build_object('addon_order_item_id', m.item_id, 'parent_order_item_id', m.parent_item_id, 'migration', 'booking_38'))
      where r.id = m.res_id and r.order_id = m.order_id and r.order_item_id = m.item_id and r.product_id = 45 and r.status = 'confirmed' and r.external_source = 'johku' and r.hidden_at is null;
    get diagnostics n = row_count;
    if n <> 1 then raise exception 'varaus % ei vastannut odotettua (rows=%)', m.res_id, n; end if;
    if exists (select 1 from booking.reservation_legs l where l.reservation_id = m.res_id) then raise exception 'varauksella % on legejä', m.res_id; end if;
  end loop;
end $$;
