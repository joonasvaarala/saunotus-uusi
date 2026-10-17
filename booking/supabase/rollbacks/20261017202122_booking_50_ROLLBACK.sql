-- ROLLBACK booking_50_product_options: palauttaa tuotannon booking_49-tilan. HUOM: varausten product_option_id-valinnat ja product_options-rivit menetetään.
begin;
CREATE OR REPLACE FUNCTION booking._public_slot_error(p_detail text, p_msg text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case when p_detail in ('not_bookable', 'invalid_persons', 'bad_slot', 'too_soon', 'too_far', 'invalid_date', 'not_offered_day', 'ritual_start', 'time_window',
                                'change_too_late', 'price_change_requires_staff', 'vat_missing')
              then jsonb_build_object('ok', false, 'code', p_detail, 'message', p_msg)
              else jsonb_build_object('ok', false, 'code', 'slot_unavailable', 'message', 'Valittu aika ei ole enää varattavissa – valitse toinen aika') end $function$;

CREATE OR REPLACE FUNCTION booking.admin_day_view(p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_from timestamptz := p_date::timestamp at time zone 'Europe/Helsinki';
        v_to timestamptz := (p_date + 1)::timestamp at time zone 'Europe/Helsinki';
        v_prep jsonb; v_totals jsonb;
begin
  perform booking._require_staff();
  with rs as (
    select r.rule_id, r.starts_at, r.ends_at, r.order_item_id, coalesce(it.product_name, '') as product_name
      from booking.reservations r left join booking.order_items it on it.id = r.order_item_id
     where r.starts_at < v_to and r.ends_at > v_from and booking._res_active(r.status, r.hold_expires_at)),
  per as (
    select rs.rule_id, rs.starts_at, rs.ends_at, rs.product_name, ai.addon_id, min(ad.code) as code, min(ai.product_name) as name, sum(ai.quantity)::int as qty
      from rs join booking.order_items ai on ai.parent_item_id = rs.order_item_id and ai.kind = 'addon'
      left join booking.addons ad on ad.id = ai.addon_id
     group by rs.rule_id, rs.starts_at, rs.ends_at, rs.product_name, ai.addon_id),
  grp as (
    select rule_id, starts_at, ends_at, product_name,
           jsonb_agg(jsonb_build_object('addon_id', addon_id, 'code', code, 'name', name, 'quantity', qty) order by name) as items
      from per group by rule_id, starts_at, ends_at, product_name)
  select (select coalesce(jsonb_agg(jsonb_build_object('rule_id', g.rule_id, 'starts_at', g.starts_at, 'ends_at', g.ends_at,
                    'product_name', g.product_name, 'items', g.items) order by g.starts_at, g.rule_id), '[]'::jsonb) from grp g),
         (select coalesce(jsonb_agg(jsonb_build_object('addon_id', t.addon_id, 'code', t.code, 'name', t.name, 'quantity', t.qty) order by t.name), '[]'::jsonb)
            from (select addon_id, min(code) as code, min(name) as name, sum(qty)::int as qty from per group by addon_id) t)
    into v_prep, v_totals;
  return jsonb_build_object(
    'date', p_date,
    'sessions', coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at, s.rule_id)
                           from booking._sessions(p_date, p_date, null, false) s), '[]'::jsonb),
    'reservations', coalesce((select jsonb_agg(jsonb_build_object(
        'reservation_id', r.id, 'order_id', o.id, 'order_no', o.order_no, 'status', r.status, 'payment_status', o.payment_status,
        'product_name', coalesce(it.product_name, p.name), 'mode', r.mode, 'starts_at', r.starts_at, 'ends_at', r.ends_at,
        'persons', r.persons, 'customer_name', c.name, 'customer_phone', c.phone, 'rule_id', r.rule_id, 'notes', r.notes,
        'annual_card', r.annual_card_id is not null, 'hold_expires_at', r.hold_expires_at,
        'source', coalesce(r.external_source, 'native'), 'external_id', r.external_id,
        'customer_kind', o.customer_kind, 'company', case when o.customer_kind <> 'private' then coalesce(o.billing ->> 'company', c.company) end,
        'space_code', sp.code, 'lifecycle', pcf.lifecycle, 'quota_exempt', r.quota_exempt, 'override_reason', r.override_reason,
        'therapist_missing', r.therapist_missing, 'therapist_exception_at', r.therapist_exception_at, 'therapist_exception_note', r.therapist_exception_note,
        'therapist_missing_open', (r.therapist_missing and r.therapist_exception_at is null and not exists (select 1 from booking.reservation_legs tl where tl.reservation_id = r.id and tl.role = 'therapist')),
        'claim_offset_min', r.claim_offset_min, 'claim_minutes', r.claim_minutes, 'parent_reservation_id', r.parent_reservation_id,
        'legs', coalesce((select jsonb_agg(jsonb_build_object('leg_id', l.id, 'role', l.role, 'resource_code', lr.code, 'starts_at', l.starts_at, 'ends_at', l.ends_at,
                                  'persons', l.persons, 'skill', l.skill) order by l.starts_at, l.id)
                            from booking.reservation_legs l join booking.resources lr on lr.id = l.resource_id where l.reservation_id = r.id), '[]'::jsonb),
        'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', ai.addon_id, 'code', (select a2.code from booking.addons a2 where a2.id = ai.addon_id), 'name', ai.product_name, 'quantity', ai.quantity) order by ai.id)
                              from booking.order_items ai where ai.parent_item_id = r.order_item_id and ai.kind = 'addon'), '[]'::jsonb))
        order by r.starts_at, r.id)
        from booking.reservations r join booking.orders o on o.id = r.order_id join booking.resources sp on sp.id = r.space_id
        left join booking.order_items it on it.id = r.order_item_id left join kb.products p on p.id = r.product_id
        left join booking.product_config pcf on pcf.product_id = r.product_id
        left join booking.customers c on c.id = o.customer_id
        where r.starts_at < v_to and r.ends_at > v_from and booking._res_active(r.status, r.hold_expires_at)), '[]'::jsonb),
    'prep', v_prep, 'addon_totals', v_totals,
    'blocks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'space_id', b.space_id, 'resource_code', br.code, 'closure_event_id', b.closure_event_id, 'starts_at', b.starts_at,
        'ends_at', b.ends_at, 'reason', b.reason) order by b.starts_at)
        from booking.space_blocks b join booking.resources br on br.id = b.space_id where b.active and b.starts_at < v_to and b.ends_at > v_from), '[]'::jsonb));
end $function$;

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
end $function$;

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
end $function$;

CREATE OR REPLACE FUNCTION booking.public_get_booking(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; res jsonb; adds jsonb; cust text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_conf_n integer; v_conf_start timestamptz; v_kind text; v_supported boolean;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select split_part(c.name, ' ', 1) into cust from booking.customers c where c.id = o.customer_id;
  select jsonb_agg(jsonb_build_object(
           'product_name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'product_id', r.product_id, 'rule_id', r.rule_id,
           'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'mode', r.mode,
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() then 'expired' else r.status end,
           'hold_expires_at', r.hold_expires_at) order by r.starts_at)
    into res
    from booking.order_items it left join booking.reservations r on r.order_item_id = it.id
   where it.order_id = o.id and it.kind = 'reservation';
  select jsonb_agg(jsonb_build_object('addon_id', it.addon_id, 'name', it.product_name, 'name_en', it.price_breakdown ->> 'name_en',
           'quantity', it.quantity, 'unit_price', it.unit_price_gross, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'max_per_person', ad.max_per_person) order by it.id)
    into adds from booking.order_items it left join booking.addons ad on ad.id = it.addon_id where it.order_id = o.id and it.kind = 'addon';
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  -- booking_25: varaustyyppi. 'rules' = sääntöpohjainen (muutettavissa public_change_booking), 'slots' = verkossa tehty hoitovaraus (public_change_treatment_booking), 'other' = ei muutettavissa verkossa (tuonti/ylläpito)
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;
  v_supported := v_kind in ('rules', 'slots');
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status',
           case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) then 'expired' else o.status end,
           'payment_status', o.payment_status, 'total', o.total_gross, 'currency', o.currency, 'created_at', o.created_at,
           'first_name', cust, 'customer_kind', o.customer_kind, 'items', coalesce(res, '[]'::jsonb), 'addons', coalesce(adds, '[]'::jsonb),
           'payment_methods', (select coalesce(jsonb_agg(p.method), '[]'::jsonb) from booking.payments p where p.order_id = o.id),
           'can_change', (o.status = 'confirmed' and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_supported),
           'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end,
           'change_hours_before', v_hours,
           'booking_kind', v_kind, 'change_via', case v_kind when 'slots' then 'public_change_treatment_booking' when 'rules' then 'public_change_booking' end);
end $function$;

CREATE OR REPLACE FUNCTION booking.public_catalog()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
      'description', p.description, 'description_en', p.description_en,
      'category', p.category, 'sale_kind', pc.sale_kind,
      'price', p.price, 'price_type', p.price_type, 'price_text', p.price_text,
      'duration_text', p.duration_text, 'duration_minutes', p.duration_minutes,
      'min_persons', pc.min_persons, 'max_persons', case when pc.public_slots then booking._treatment_max_persons(p.id) else pc.max_persons end,
      'booking_kind', case when pc.public_slots then 'slots' else 'rules' end, 'slot_grid_minutes', case when pc.public_slots then 30 end
    ) order by pc.sort_order, p.id), '[]'::jsonb)
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
    and (pc.public_slots or exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active))
$function$;

CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_ids bigint[]; v_site text := coalesce(booking._setting('site_base_url') #>> '{}', ''); v_op text := coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/');
        v_pp text := coalesce(booking._setting('payment_link_path') #>> '{}', '/maksa/'); v_res jsonb;
begin
  update booking.email_outbox set status = 'pending', locked_at = null where status = 'sending' and locked_at < now() - interval '10 minutes';
  select coalesce(array_agg(id), '{}') into v_ids from (
    select id from booking.email_outbox where status in ('pending','failed') and next_attempt_at <= now() order by id limit greatest(least(coalesce(p_limit, 20), 50), 1) for update skip locked) q;
  update booking.email_outbox set status = 'sending', locked_at = now(), attempts = attempts + 1 where id = any (v_ids);
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'kind', e.kind, 'locale', e.locale, 'attempts', e.attempts, 'max_attempts', e.max_attempts, 'to', coalesce(nullif(e.payload ->> 'to_email', ''), c.email), 'to_name', coalesce(nullif(e.payload ->> 'to_name', ''), c.name),
      'order', case when o.id is null or e.kind = 'gift_card_recipient' then null else jsonb_build_object('order_no', o.order_no, 'order_url', v_site || v_op || '?t=' || o.public_token, 'total', o.total_gross, 'status', o.status,
          'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.product_name, 'quantity', i.quantity, 'line_total', i.line_total_gross, 'vat_rate', i.vat_rate, 'kind', i.kind) order by i.id) from booking.order_items i where i.order_id = o.id), '[]'::jsonb),
          'reservations', coalesce((select jsonb_agg(jsonb_build_object('product_name', it.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'status', r.status) order by r.starts_at)
              from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id), '[]'::jsonb)) end,
      'gift_cards', case when e.kind like 'gift_card\_%' then (select coalesce(jsonb_agg(jsonb_build_object('public_token', g.public_token, 'package_code', g.package_code, 'package_name', pk.name, 'package_name_en', pk.name_en,
            'kind', g.kind, 'amount', g.initial_amount, 'valid_to', g.valid_to, 'recipient_name', g.recipient_name, 'greeting', g.greeting, 'buyer_name', g.buyer_name, 'persons', pk.persons,
            'locale', g.locale, 'status', g.status, 'delivery_to', g.delivery_to, 'deliver_on', g.deliver_on, 'deliver_time', to_char(g.deliver_time, 'HH24:MI'),
            'deliver_at', booking._gc_deliver_ts(g.deliver_on, g.deliver_time), 'delivered_at', g.delivered_at,
            'recipient_email', case when e.kind = 'gift_card_buyer' then g.recipient_email end, 'cover_message', case when e.kind = 'gift_card_recipient' then g.cover_message end) order by g.id), '[]'::jsonb)
          from booking.gift_cards g left join booking.gift_card_packages pk on pk.code = g.package_code
         where g.id in (select (x)::bigint from jsonb_array_elements_text(coalesce(e.payload -> 'card_ids', '[]'::jsonb)) x)) end,
      'voucher_claim', case when e.kind like 'voucher\_claim\_%' then (select jsonb_build_object('claim_id', vc.id, 'status', vc.status, 'source', vc.source, 'code_masked', booking._vc_mask(vc.code), 'problem_code', vc.problem_code,
            'hold_until', vc.hold_until, 'created_at', vc.created_at, 'customer_name', vc.customer_name) from booking.voucher_claims vc where vc.id = (e.payload ->> 'claim_id')::bigint) end,
      'receipt', case when rc.id is null then null else jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'text_body', rc.text_body, 'public_token', rc.public_token, 'total', rc.total_gross, 'issued_at', rc.issued_at) end,
      'payment', case when p.id is null then null else jsonb_build_object('id', p.id, 'amount', p.amount, 'link_url', case when p.provider <> 'manual' and p.status = 'pending' then v_site || v_pp || '?p=' || p.link_token end,
          'link_expires_at', p.link_expires_at) end) order by e.id), '[]'::jsonb)
    into v_res
    from booking.email_outbox e left join booking.orders o on o.id = e.order_id left join booking.customers c on c.id = o.customer_id
    left join booking.receipts rc on rc.id = e.receipt_id left join booking.payments p on p.id = e.payment_id
   where e.id = any (v_ids);
  return v_res;
end $function$;

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
end $function$;

CREATE OR REPLACE FUNCTION booking._therapist_missing_payload(r booking.reservations)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object('reservation_id', r.id, 'order_no', o.order_no, 'product_id', r.product_id, 'product_name', coalesce(p.name, ''),
           'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'source', coalesce(r.external_source, 'native'), 'channel', o.source_channel,
           'days_to_start', ((r.starts_at at time zone 'Europe/Helsinki')::date - (now() at time zone 'Europe/Helsinki')::date))
    from booking.orders o left join kb.products p on p.id = r.product_id where o.id = r.order_id $function$;

CREATE OR REPLACE FUNCTION booking._add_to_order(p_order_id bigint, p_items jsonb, p_staff boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; e jsonb; v_type text; v_added jsonb := '[]'::jsonb; v_total0 numeric; v_end timestamptz; v_res booking.reservations; a booking.addons; v_qty int; v_cur int; v_lim int;
  v_item bigint; p kb.products; pc booking.product_config; v_resid bigint; v_n int; v_r jsonb; v_pid bigint; v_start timestamptz; v_en timestamptz; v_line numeric; v_vat numeric; v_amt numeric;
  v_desc text; v_ovr boolean; v_chan text := case when p_staff then 'admin' else 'web' end; v_price numeric; v_add numeric; v_idtxt text; v_code text; v_mode text; v_rid bigint;
begin
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if o.external_source is not null or not (o.status = 'confirmed' or (p_staff and o.status = 'completed')) then perform booking._err('order_not_editable', 'Tilaukseen ei voi lisätä'); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 20 then perform booking._err('invalid_items', 'Anna 1–20 lisättävää riviä'); end if;
  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  if not p_staff and (v_end is null or v_end <= now()) then perform booking._err('order_closed', 'Lisäysaika on päättynyt'); end if;
  v_total0 := o.total_gross;

  for e in select * from jsonb_array_elements(p_items) loop
    if jsonb_typeof(e) <> 'object' then perform booking._err('invalid_items', 'Rivi väärässä muodossa'); end if;
    v_type := e ->> 'type';
    if v_type = 'addon' then
      if coalesce(e ->> 'reservation_id', '') ~ '^\d{1,18}$' then v_resid := (e ->> 'reservation_id')::bigint;
      elsif e ->> 'reservation_id' is not null then perform booking._err('item_not_found', 'Varausta ei löydy');
      else
        select count(*), min(r.id) into v_n, v_resid from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
        if v_n <> 1 then perform booking._err('invalid_items', 'Anna reservation_id'); end if;
      end if;
      select * into v_res from booking.reservations where id = v_resid and order_id = o.id;
      if not found then perform booking._err('item_not_found', 'Varausta ei löydy tilauksesta'); end if;
      if not booking._res_active(v_res.status, v_res.hold_expires_at) then perform booking._err('order_not_editable', 'Varaus ei ole voimassa'); end if;
      if not p_staff and v_res.ends_at <= now() then perform booking._err('order_closed', 'Lisäysaika on päättynyt'); end if;
      v_idtxt := e ->> 'addon_id'; v_code := e ->> 'code';
      if v_idtxt is not null and v_idtxt !~ '^\d{1,18}$' then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
      select * into a from booking.addons where (v_idtxt is not null and id = v_idtxt::bigint) or (v_idtxt is null and v_code is not null and code = v_code);
      if not found then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
      if coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' or (e ->> 'quantity')::int = 0 then perform booking._err('addon_quantity', 'Lisäpalvelun määrän pitää olla kokonaisluku'); end if;
      v_qty := (e ->> 'quantity')::int;
      select coalesce(sum(quantity), 0) into v_cur from booking.order_items where parent_item_id = v_res.order_item_id and addon_id = a.id and kind = 'addon';
      v_lim := booking._addon_limit(a.max_per_person, v_res.persons);
      if v_cur + v_qty > v_lim then perform booking._err('addon_quantity', format('Lisäpalvelua "%s" voi olla enintään %s kpl (nyt %s)', a.name, v_lim, v_cur)); end if;
      perform booking._attach_addons(v_res.id, jsonb_build_array(jsonb_build_object('id', a.id, 'quantity', v_qty)));
      select max(id) into v_item from booking.order_items where parent_item_id = v_res.order_item_id and addon_id = a.id;
      select line_total_gross into v_line from booking.order_items where id = v_item;
      v_added := v_added || jsonb_build_object('item_id', v_item, 'name', a.name, 'line_total', v_line, 'reservation_id', v_res.id);

    elsif v_type = 'reservation' then
      v_add := 0; v_rid := null;
      if e ? 'product_id' then
        if coalesce(e ->> 'product_id', '') !~ '^\d{1,18}$' then perform booking._err('invalid_items', 'product_id virheellinen'); end if;
        v_pid := (e ->> 'product_id')::bigint;
        if coalesce(e ->> 'persons', '') !~ '^\d{1,3}$' then perform booking._err('invalid_items', 'persons virheellinen'); end if;
        v_start := (e ->> 'start')::timestamptz; v_en := nullif(e ->> 'end', '')::timestamptz;
        v_ovr := coalesce((e ->> 'override')::boolean, false);
        if not p_staff then
          select * into pc from booking.product_config where product_id = v_pid;
          if not found or not pc.bookable or not pc.shop_visible or not pc.public_slots or e ? 'price' or e ? 'space_id' or e ? 'parent_reservation_id' or v_ovr then
            perform booking._err('invalid_items', 'Tuotetta ei voi lisätä verkossa');
          end if;
          if v_start is null or v_start < now() then perform booking._err('bad_time', 'Virheellinen aika'); end if;
        elsif v_ovr and not booking.has_permission('bookings.override') then perform booking._err('forbidden', 'Ei oikeutta ylitykseen (bookings.override)');
        end if;
        v_price := case when p_staff and e ? 'price' then (e ->> 'price')::numeric end;
        if v_price is not null and v_price < 0 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
        v_r := booking._create_legs_booking('current', v_pid, v_start, v_en, (e ->> 'persons')::int, o.customer_id, v_chan, auth.uid(), null, v_price,
                 nullif(e ->> 'space_id', '')::bigint, v_ovr, e ->> 'override_reason', false, nullif(e ->> 'parent_reservation_id', '')::bigint, o.id);
      elsif e ? 'rule_id' then
        if coalesce(e ->> 'rule_id', '') !~ '^\d{1,18}$' or coalesce(e ->> 'persons', '') !~ '^\d{1,3}$' then perform booking._err('invalid_items', 'rule_id/persons virheellinen'); end if;
        v_r := booking._create_booking_core((e ->> 'rule_id')::bigint, (e ->> 'date')::date, (e ->> 'persons')::int, o.customer_id, v_chan, auth.uid(), o.locale, null,
                 'confirmed', null, not p_staff, null, null, null, null, o.id);
      else perform booking._err('invalid_items', 'Varausrivillä pitää olla product_id tai rule_id');
      end if;
      v_rid := (v_r ->> 'reservation_id')::bigint;
      if e ? 'addons' then v_add := booking._attach_addons(v_rid, e -> 'addons'); end if;
      select order_item_id into v_item from booking.reservations where id = v_rid;
      v_added := v_added || jsonb_build_object('item_id', v_item, 'name', v_r ->> 'product_name', 'line_total', (v_r ->> 'total')::numeric + v_add, 'reservation_id', v_rid);

    elsif v_type = 'product' then
      if coalesce(e ->> 'product_id', '') !~ '^\d{1,18}$' or coalesce(e ->> 'quantity', '') !~ '^\d{1,2}$' or (e ->> 'quantity')::int = 0 then perform booking._err('invalid_items', 'Tuote/määrä virheellinen'); end if;
      select * into p from kb.products where id = (e ->> 'product_id')::bigint and active;
      if not found or p.category <> 'product_rental' then perform booking._err('item_not_found', 'Tuotetta ei löydy / ei lisättävissä'); end if;
      if p.vat_rate is null then perform booking._err('vat_missing', 'Tuotteelta puuttuu ALV-kanta'); end if;
      if p.price is null then perform booking._err('invalid_items', 'Tuotteella ei ole hintaa'); end if;
      v_qty := (e ->> 'quantity')::int; v_line := p.price * v_qty;
      insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
      values (o.id, p.id, p.name, 'product', v_qty, p.price, v_line, p.vat_rate, jsonb_build_object('model', 'add_to_order')) returning id into v_item;
      update booking.orders set total_gross = total_gross + v_line where id = o.id;
      v_added := v_added || jsonb_build_object('item_id', v_item, 'name', p.name, 'line_total', v_line);

    elsif v_type = 'custom' then
      if not p_staff then perform booking._err('invalid_items', 'Rivityyppi ei ole sallittu'); end if;
      if not booking.has_permission('bookings.override') then perform booking._err('forbidden', 'Vapaa rivi vaatii oikeuden bookings.override'); end if;
      v_desc := btrim(coalesce(e ->> 'description', ''));
      if char_length(v_desc) not between 3 and 120 then perform booking._err('invalid_items', 'Kuvaus 3–120 merkkiä'); end if;
      if coalesce(e ->> 'amount', '') !~ '^-?\d{1,5}(\.\d{1,2})?$' then perform booking._err('invalid_items', 'Summa virheellinen'); end if;
      v_amt := (e ->> 'amount')::numeric;
      if v_amt = 0 then perform booking._err('invalid_items', 'Summa ei voi olla 0'); end if;
      if coalesce(e ->> 'vat_rate', '') !~ '^\d{1,3}(\.\d{1,2})?$' then perform booking._err('invalid_vat', 'ALV-kanta puuttuu'); end if;
      v_vat := (e ->> 'vat_rate')::numeric;
      if not booking._vat_active(v_vat) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu'); end if;
      v_qty := coalesce(nullif(e ->> 'quantity', '')::int, 1);
      if v_qty not between 1 and 99 then perform booking._err('invalid_items', 'Määrä 1–99'); end if;
      v_line := v_amt * v_qty;
      if (select total_gross from booking.orders where id = o.id) + v_line < 0 then perform booking._err('invalid_items', 'Alennus ylittää tilauksen summan'); end if;
      insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
      values (o.id, v_desc, case when v_amt < 0 then 'discount' else 'fee' end, v_qty, v_amt, v_line, v_vat, jsonb_build_object('model', 'custom_line')) returning id into v_item;
      update booking.orders set total_gross = total_gross + v_line where id = o.id;
      v_added := v_added || jsonb_build_object('item_id', v_item, 'name', v_desc, 'line_total', v_line);
    else
      perform booking._err('invalid_items', 'Tuntematon rivityyppi');
    end if;
  end loop;

  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'orders', o.id::text, case when p_staff then 'ADMIN_ADD_TO_ORDER' else 'CUSTOMER_ADD_TO_ORDER' end,
          jsonb_build_object('total', v_total0), jsonb_build_object('items', p_items, 'added', v_added, 'total', (select total_gross from booking.orders where id = o.id)));
  return jsonb_build_object('added', v_added, 'added_total', (select total_gross from booking.orders where id = o.id) - v_total0);
end $function$;

drop function booking.admin_create_old_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text, text);
drop function booking.admin_create_resource_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text, text);
drop function booking._admin_create_legs(text, bigint, timestamptz, timestamptz, integer, bigint, jsonb, text, boolean, text, numeric, bigint, boolean, text, jsonb, bigint, text, boolean, text);
drop function booking._create_legs_booking(text, bigint, timestamptz, timestamptz, integer, bigint, text, uuid, text, numeric, bigint, boolean, text, boolean, bigint, bigint, text);
drop function booking.public_create_treatment_booking(bigint, timestamptz, integer, text, text, text, boolean, text, text, text, jsonb, text);
drop function booking.public_change_order_time(uuid, bigint, timestamptz, bigint, date, integer, text);
drop function booking.public_change_treatment_booking(uuid, timestamptz, integer, text);
drop function booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer, text);
drop function booking.admin_set_reservation_option(bigint, text, boolean);
drop function booking.admin_list_product_options(bigint);
drop function booking.admin_upsert_product_option(bigint, text, text, text, integer, boolean, text, text);
drop function booking.admin_set_product_option_settings(bigint, boolean, text, text);

CREATE OR REPLACE FUNCTION booking._create_legs_booking(p_lifecycle text, p_product_id bigint, p_start timestamp with time zone, p_end timestamp with time zone, p_persons integer, p_customer_id bigint, p_channel text, p_created_by uuid, p_note text, p_price numeric, p_space_id bigint, p_override boolean, p_override_reason text, p_quota_exempt boolean, p_parent_reservation_id bigint, p_order_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  p kb.products; pc booking.product_config; v_end timestamptz; v_total numeric; v_order booking.orders; v_item bigint; v_res booking.reservations;
  v_plan booking.leg_plan[] := '{}'; lp booking.leg_plan; v_prim booking.leg_plan; v_parent bigint; v_pools bigint[]; v_off integer; v_cmin integer; v_n integer := 0; v_missing boolean := false; v_ecode text;
begin
  select * into p from kb.products where id = p_product_id;
  if not found then perform booking._err('product_not_found', 'Tuotetta ei löydy'); end if;
  select * into pc from booking.product_config where product_id = p_product_id;
  if not found then perform booking._err('not_bookable', 'Tuotetta ei voi varata'); end if;
  if p_lifecycle is not null and pc.lifecycle <> p_lifecycle then
    perform booking._err('wrong_lifecycle', case p_lifecycle when 'old' then 'Valitse vanha tuote (current-tuotteet: Uusi varaus)' else 'Valitse nykyinen tuote' end);
  end if;
  if p.vat_rate is null then perform booking._err('vat_missing', 'Tuotteelta puuttuu ALV-kanta'); end if;
  v_end := coalesce(p_end, p_start + make_interval(mins => coalesce(pc.duration_minutes, p.duration_minutes)));
  if p_start is null or v_end is null or v_end <= p_start then perform booking._err('bad_time', 'Virheellinen aika'); end if;
  if p_override and (p_override_reason is null or length(btrim(p_override_reason)) < 3) then perform booking._err('override_reason_required', 'Ylitys vaatii perustelun'); end if;

  -- lisäpalvelu (kb 27/28): vaatii kattavan vanhempivarauksen (jälkilöyly / oma vuoro)
  if cardinality(pc.requires_parent_product_ids) > 0 then
    select r.id into v_parent
      from booking.reservations r join booking.orders o on o.id = r.order_id
     where r.product_id = any (pc.requires_parent_product_ids) and booking._res_active(r.status, r.hold_expires_at)
       and r.starts_at <= p_start and r.ends_at >= v_end
       and (p_parent_reservation_id is null or r.id = p_parent_reservation_id)
     order by (o.customer_id is not distinct from p_customer_id) desc, r.starts_at limit 1;
    if v_parent is null and not p_override then
      perform booking._err('parent_required', 'Lisäpalvelu vaatii jälkilöyly-/yksityisvuorovarauksen samalle ajalle');
    end if;
  end if;

  begin
    for lp in select * from booking._plan_legs(p_product_id, p_start, v_end, p_persons, p_space_id, p_override) loop v_plan := array_append(v_plan, lp); end loop;
  exception when sqlstate 'BK001' then
    -- booking_22: ei vapaata saunottajaa -> varaus syntyy ilman saunottajalegiä (therapist_missing), kaikki muut virheet nousevat ennallaan
    get stacked diagnostics v_ecode = pg_exception_detail;
    if v_ecode is distinct from 'no_therapist' then raise; end if;
    v_plan := '{}'; v_missing := true;
    for lp in select * from booking._plan_legs(p_product_id, p_start, v_end, p_persons, p_space_id, p_override, null, true) loop v_plan := array_append(v_plan, lp); end loop;
  end;
  select * into v_prim from unnest(v_plan) u where u.leg_no = 1 and u.role = 'space';
  if v_prim.resource_id is null then perform booking._err('no_primary_leg', 'Tuotteelta puuttuu ensisijainen tila (product_space_rules leg 1)'); end if;
  v_off := (extract(epoch from (v_prim.claim_start - p_start)) / 60)::int;
  v_cmin := case when v_prim.claim_end >= v_end then null else (extract(epoch from (v_prim.claim_end - v_prim.claim_start)) / 60)::int end;
  if v_prim.mode = 'exclusive' and (v_off <> 0 or v_cmin is not null) then perform booking._err('bad_rule', 'Yksinoikeusvarauksen claim-ikkuna on aina koko varaus'); end if;
  v_pools := case when v_prim.pool_id is null then '{}'::bigint[] else array[v_prim.pool_id] end;

  v_total := coalesce(p_price, coalesce(p.price, 0) + coalesce(p.extra_person_price, 0) * greatest(p_persons - coalesce(p.included_persons, p_persons), 0));
  if p_order_id is null then
    insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_note, created_by, confirmed_at)
    values (p_customer_id, 'confirmed', 'unpaid', v_total, p_channel, 'fi', p_note, p_created_by, now()) returning * into v_order;
  else   -- lisäys olemassa olevaan tilaukseen (booking_30): ei uutta tilausnumeroa
    select * into v_order from booking.orders where id = p_order_id for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
    update booking.orders set total_gross = total_gross + v_total where id = p_order_id;
  end if;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
  values (v_order.id, p.id, p.name, 'reservation', 1, v_total, v_total, p.vat_rate,
          jsonb_build_object('model', 'legs_v2', 'lifecycle', pc.lifecycle, 'persons', p_persons)) returning id into v_item;

  insert into booking.reservations(order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status,
                                   quota_exempt, claim_offset_min, claim_minutes, parent_reservation_id, override_reason, created_by, therapist_missing)
  values (v_order.id, v_item, p.id, v_prim.resource_id, v_prim.mode, p_start, v_end, p_persons, v_pools, 'confirmed',
          p_quota_exempt, v_off, v_cmin, v_parent, case when p_override then btrim(p_override_reason) end, p_created_by, v_missing)
  returning * into v_res;                                    -- trigger validoi ensisijaisen claimin

  for lp in select * from unnest(v_plan) u where not (u.leg_no = 1 and u.role = 'space') order by u.leg_no loop
    insert into booking.reservation_legs(reservation_id, resource_id, role, mode, starts_at, ends_at, offset_min, minutes, persons, pool_ids, skill, session_key,
                                         quota_exempt, override_reason, rule_id)
    values (v_res.id, lp.resource_id, lp.role, lp.mode, lp.claim_start, lp.claim_end, lp.offset_min, lp.minutes, lp.persons,
            case when lp.pool_id is null then '{}'::bigint[] else array[lp.pool_id] end, lp.skill, lp.session_key,
            p_quota_exempt, case when p_override then btrim(p_override_reason) end, lp.rule_id);   -- trigger validoi legin
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no, 'reservation_id', v_res.id, 'total', v_total,
                            'starts_at', v_res.starts_at, 'ends_at', v_res.ends_at, 'legs', v_n, 'space_id', v_res.space_id,
                            'product_name', p.name, 'parent_reservation_id', v_parent,
                            'therapist_missing', v_missing, 'warning', case when v_missing then 'therapist_missing' end);
end $function$;

CREATE OR REPLACE FUNCTION booking._admin_create_legs(p_lifecycle text, p_product_id bigint, p_start timestamp with time zone, p_end timestamp with time zone, p_persons integer, p_customer_id bigint, p_customer jsonb, p_payment_method text, p_paid boolean, p_note text, p_price numeric, p_space_id bigint, p_override boolean, p_override_reason text, p_addons jsonb, p_parent_reservation_id bigint, p_invoice_reference text, p_quota_exempt boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_cust bigint := p_customer_id; v_pm booking.payment_methods; v_res jsonb; v_order bigint; v_add numeric; v_total numeric;
        v_ref text := nullif(btrim(coalesce(p_invoice_reference, '')), '');
begin
  perform booking._require_permission('bookings.manage');
  if p_override then perform booking._require_permission('bookings.override'); end if;
  select * into v_pm from booking.payment_methods where code = p_payment_method and active;
  if not found then perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä'); end if;
  if p_price is not null and p_price < 0 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  if v_ref is not null and char_length(v_ref) > 100 then perform booking._err('invalid_reference', 'Viite on liian pitkä (enintään 100 merkkiä)'); end if;
  if v_cust is null then
    if p_customer is null then perform booking._err('customer_required', 'Valitse asiakas tai anna nimi'); end if;
    v_cust := (booking.admin_create_customer(p_customer) ->> 'id')::bigint;           -- sama polku kuin hallinnan asiakaslomake
  elsif not exists (select 1 from booking.customers where id = v_cust) then
    perform booking._err('customer_not_found', 'Asiakasta ei löydy');
  end if;
  v_res := booking._create_legs_booking(p_lifecycle, p_product_id, p_start, p_end, p_persons, v_cust, 'admin', auth.uid(), p_note, p_price, p_space_id,
                                        p_override, p_override_reason, p_quota_exempt, p_parent_reservation_id);
  v_order := (v_res ->> 'order_id')::bigint;
  perform booking._stamp_order_billing(v_order, v_cust, null);
  if v_ref is not null then update booking.orders set invoice_reference = v_ref where id = v_order and customer_kind <> 'private'; end if;
  v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);
  v_total := (v_res ->> 'total')::numeric + v_add;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at, created_by)
  values (v_order, p_payment_method, 'manual', case when p_paid then 'paid' else 'pending' end, v_total, case when p_paid then now() end, auth.uid());
  update booking.orders set payment_status = case when p_paid then 'paid' else 'unpaid' end where id = v_order;     -- total_gross päivittyy _attach_addons:ssa kuten admin_create_booking:ssa
  return v_res || jsonb_build_object('customer_id', v_cust, 'total', v_total, 'addons_total', v_add);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_create_resource_booking(p_product_id bigint, p_start timestamp with time zone, p_persons integer, p_customer_id bigint DEFAULT NULL::bigint, p_customer jsonb DEFAULT NULL::jsonb, p_end timestamp with time zone DEFAULT NULL::timestamp with time zone, p_space_id bigint DEFAULT NULL::bigint, p_payment_method text DEFAULT 'pay_later'::text, p_paid boolean DEFAULT false, p_note text DEFAULT NULL::text, p_price numeric DEFAULT NULL::numeric, p_override boolean DEFAULT false, p_override_reason text DEFAULT NULL::text, p_addons jsonb DEFAULT NULL::jsonb, p_parent_reservation_id bigint DEFAULT NULL::bigint, p_invoice_reference text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ select booking._admin_create_legs('current', p_product_id, p_start, p_end, p_persons, p_customer_id, p_customer, p_payment_method, p_paid, p_note, p_price,
                                         p_space_id, p_override, p_override_reason, p_addons, p_parent_reservation_id, p_invoice_reference, false) $function$;

CREATE OR REPLACE FUNCTION booking.admin_create_old_booking(p_product_id bigint, p_start timestamp with time zone, p_persons integer, p_customer_id bigint DEFAULT NULL::bigint, p_customer jsonb DEFAULT NULL::jsonb, p_end timestamp with time zone DEFAULT NULL::timestamp with time zone, p_space_id bigint DEFAULT NULL::bigint, p_payment_method text DEFAULT 'pay_later'::text, p_paid boolean DEFAULT false, p_note text DEFAULT NULL::text, p_price numeric DEFAULT NULL::numeric, p_override boolean DEFAULT false, p_override_reason text DEFAULT NULL::text, p_addons jsonb DEFAULT NULL::jsonb, p_parent_reservation_id bigint DEFAULT NULL::bigint, p_invoice_reference text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ select booking._admin_create_legs('old', p_product_id, p_start, p_end, p_persons, p_customer_id, p_customer, p_payment_method, p_paid, p_note, p_price,
                                         p_space_id, p_override, p_override_reason, p_addons, p_parent_reservation_id, p_invoice_reference, false) $function$;

CREATE OR REPLACE FUNCTION booking.public_create_treatment_booking(p_product_id bigint, p_start timestamp with time zone, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '3s'
AS $function$
declare
  v_ip text := booking._client_ip();
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private'))); v_is_company boolean; v_company jsonb;
  v_cust bigint; v_res jsonb; v_end timestamptz; v_total numeric; v_token uuid; v_detail text; v_msg text; v_pay_method text; v_order bigint;
begin
  if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
    return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
  end if;
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select k.is_company into v_is_company from booking.customer_kinds k where k.code = v_kind and k.active;
  if v_is_company is null then return jsonb_build_object('ok', false, 'code', 'invalid_customer_kind', 'message', 'Valitse asiakastyyppi (yksityinen / yritys)'); end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', case when v_is_company then 'Anna yhteyshenkilön nimi' else 'Anna nimi' end);
  end if;
  if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
  if p_note is not null and char_length(p_note) > 1000 then return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä'); end if;
  -- suojakatkaisimet: pay_later ei vaadi maksua -> rajataan väärinkäyttö (sähköposti / kokonaismäärä)
  if (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id join booking.reservations r on r.order_id = o.id
        join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots
       where lower(c.email) = v_email and o.source_channel = 'web' and o.status = 'confirmed' and r.status = 'confirmed' and r.starts_at > now()
         and o.payment_status = 'unpaid') >= coalesce((booking._setting('public_treatment_max_open_per_email', '5'::jsonb) #>> '{}')::int, 5) then
    return jsonb_build_object('ok', false, 'code', 'too_many_open', 'message', 'Sinulla on jo useita tulevia varauksia – ota yhteyttä sähköpostitse');
  end if;
  if (select count(*) from booking.orders o join booking.reservations r on r.order_id = o.id join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots
       where o.source_channel = 'web' and o.created_at > now() - interval '1 hour') >= coalesce((booking._setting('public_treatment_global_per_hour', '30'::jsonb) #>> '{}')::int, 30) then
    return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'Verkkovarauksia tehdään nyt poikkeuksellisen paljon – yritä myöhemmin uudelleen');
  end if;

  begin  -- alitransaktio: virhe kumoaa asiakkaan/tilauksen/varauksen luonnin mutta rate limit -kirjaus säilyy
    v_end := booking._treatment_slot_check(p_product_id, p_start, p_persons, true);       -- uudelleenvalidointi luontihetkellä (päivä, aikaikkuna, ruudukko, henkilömäärä)
    if v_is_company then v_company := booking._clean_company(p_company); end if;
    if v_is_company then
      v_cust := booking._upsert_company_customer(v_kind, v_name, v_email, v_phone, v_company, p_marketing_consent, 'web_booking', p_locale, (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    else
      v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale, (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    end if;
    v_total := booking._treatment_price(p_product_id, p_persons);
    -- ei override-polkua; ei vapaata saunottajaa -> therapist_missing (booking_22) ellei päivä ole suljettu (therapist_closed nousee virheenä)
    v_res := booking._create_legs_booking('current', p_product_id, p_start, v_end, p_persons, v_cust, 'web', null, p_note, v_total, null, false, null, false, null);
    v_order := (v_res ->> 'order_id')::bigint;
    perform booking._stamp_order_billing(v_order, v_cust, v_company);
    v_pay_method := case when v_is_company then 'invoice' else 'pay_later' end;
    insert into booking.payments(order_id, method, provider, status, amount) values (v_order, v_pay_method, 'manual', 'pending', v_total);
    update booking.orders set payment_status = 'unpaid' where id = v_order returning public_token into v_token;
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return booking._public_slot_error(v_detail, v_msg);
    when exclusion_violation then
      return booking._public_slot_error('slot_unavailable', null);
    when lock_not_available then
      return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'Järjestelmä on hetkellä kiireinen, yritä hetken kuluttua uudelleen');
  end;

  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_token, 'status', 'confirmed', 'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at',
                            'persons', p_persons, 'total', v_total, 'payment_mode', 'pay_later', 'payment_url', null, 'hold_expires_at', null,
                            'product_name', v_res -> 'product_name', 'customer_kind', v_kind, 'booking_kind', 'slots');
end $function$;

CREATE OR REPLACE FUNCTION booking.public_change_treatment_booking(p_token uuid, p_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_persons integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '3s'
AS $function$
declare
  v_ip text := booking._client_ip(); o booking.orders; res booking.reservations; v_old booking.reservations; v_n int; v_res_id bigint; v_detail text; v_msg text; v_code text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_start timestamptz; v_end timestamptz; v_persons integer; v_total numeric; v_paid numeric; v_order_total numeric; v_item bigint;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if not booking._rate_limit('chg:' || p_token::text, (booking._setting('rl_change_per_10min', '10'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if p_start is null and p_persons is null then return jsonb_build_object('ok', false, 'code', 'invalid_change', 'message', 'Valitse uusi aika ja/tai henkilömäärä'); end if;
  if p_persons is not null and (p_persons < 1 or p_persons > 50) then return jsonb_build_object('ok', false, 'code', 'invalid_persons', 'message', 'Tarkista henkilömäärä'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select count(*), min(r.id) into v_n, v_res_id from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  if v_n <> 1 or o.status <> 'confirmed' then
    return jsonb_build_object('ok', false, 'code', 'not_changeable', 'message', 'Tätä varausta ei voi muuttaa verkossa – ota yhteyttä sähköpostitse');
  end if;
  begin
    select * into res from booking.reservations where id = v_res_id for update;
    if res.rule_id is not null or o.source_channel <> 'web' or not exists (select 1 from booking.product_config pc where pc.product_id = res.product_id and pc.public_slots) then
      return jsonb_build_object('ok', false, 'code', 'not_changeable', 'message', 'Tätä varausta ei voi muuttaa verkossa – ota yhteyttä sähköpostitse');
    end if;
    v_old := res;
    if res.starts_at - make_interval(hours => v_hours) < now() then
      perform booking._err('change_too_late', format('Varausta voi muuttaa itse viimeistään %s tuntia ennen alkua – ota yhteyttä sähköpostitse', v_hours));
    end if;
    v_start := coalesce(p_start, res.starts_at);
    v_persons := coalesce(p_persons, res.persons);
    if p_start is not null and v_start - make_interval(hours => v_hours) < now() then
      perform booking._err('change_too_late', format('Uuden ajan pitää alkaa vähintään %s tuntia päästä', v_hours));
    end if;
    v_end := booking._treatment_slot_check(res.product_id, v_start, v_persons, false);
    -- sama tila (ei vaihdeta tilaa omatoimisesti): suunnitelma validoi rajat ja päällekkäisyydet (oma varaus jätetään huomiotta); saunottajaa ei vaadita
    perform 1 from booking._plan_legs(res.product_id, v_start, v_end, v_persons, res.space_id, false, res.id, true);
    v_total := booking._treatment_price(res.product_id, v_persons);
    select coalesce(sum(amount) filter (where status in ('paid', 'partially_refunded', 'refunded')), 0) into v_paid from booking.payments where order_id = o.id;
    if v_paid > 0 and v_total is distinct from o.total_gross then perform booking._err('price_change_requires_staff', 'Maksettu varaus, jonka hinta muuttuisi: ota yhteyttä henkilökuntaan'); end if;
    begin
      update booking.reservations set starts_at = v_start, ends_at = v_end, persons = v_persons where id = res.id returning * into res;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_code = pg_exception_detail;
      if v_code is distinct from 'no_therapist' then raise; end if;
      -- uudella ajalla ei vapaata saunottajaa: poistetaan saunottajaleg ja merkitään therapist_missing (ilmoitus Tapiolle triggerillä)
      delete from booking.reservation_legs where reservation_id = res.id and role = 'therapist';
      update booking.reservations set starts_at = v_start, ends_at = v_end, persons = v_persons, therapist_missing = true where id = res.id returning * into res;
    end;
    select id into v_item from booking.order_items where id = res.order_item_id;
    update booking.order_items set unit_price_gross = v_total, line_total_gross = v_total where id = v_item;
    update booking.orders set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = o.id), 0) where id = o.id returning total_gross into v_order_total;
    update booking.payments set amount = v_order_total where order_id = o.id and status = 'pending' and provider = 'manual';
    perform booking._refresh_order_payment(o.id);
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (null, booking._jwt_role(), 'reservations', res.id::text, 'CUSTOMER_CHANGE', to_jsonb(v_old), to_jsonb(res));
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return booking._public_slot_error(v_detail, v_msg);
    when exclusion_violation then
      return booking._public_slot_error('slot_unavailable', null);
    when lock_not_available then
      return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'Järjestelmä on hetkellä kiireinen, yritä hetken kuluttua uudelleen');
  end;
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'starts_at', res.starts_at, 'ends_at', res.ends_at, 'persons', res.persons, 'total', v_order_total);
end $function$;

CREATE OR REPLACE FUNCTION booking.public_change_order_time(p_token uuid, p_reservation_id bigint, p_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_rule_id bigint DEFAULT NULL::bigint, p_date date DEFAULT NULL::date, p_persons integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; r booking.reservations; v jsonb; v_old numeric; v_new numeric; v_diff numeric; v_pay jsonb := null; v_bal jsonb; v_req bigint; v_pl jsonb;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into r from booking.reservations where id = p_reservation_id and order_id = o.id;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  v_old := o.total_gross;
  v_pl := jsonb_build_object('reservation_id', p_reservation_id, 'start', p_start, 'rule_id', p_rule_id, 'date', p_date, 'persons', p_persons);
  if r.rule_id is not null then v := booking.public_change_booking(p_token, p_rule_id, p_date, p_persons);
  else v := booking.public_change_treatment_booking(p_token, p_start, p_persons); end if;
  if coalesce((v ->> 'ok')::boolean, false) is not true then
    if v ->> 'code' = 'price_change_requires_staff' then
      -- maksettu varaus, jonka hinta muuttuisi: ei muuteta itse, vaan jätetään pyyntö henkilökunnalle
      insert into booking.order_requests(order_id, kind, reason, payload) values (o.id, 'change', 'Asiakas pyytää ajan/henkilömäärän muutosta (hinta muuttuu)', v_pl)
        on conflict (order_id, kind) where status = 'open' do update set payload = excluded.payload returning id into v_req;
      perform booking._notify_staff('order_change_request', v_req, jsonb_build_object('request_id', v_req, 'order_id', o.id, 'order_no', o.order_no));
      return v || jsonb_build_object('request_created', true);
    end if;
    return v;
  end if;
  select total_gross into v_new from booking.orders where id = o.id;
  v_diff := v_new - v_old;
  perform booking._sync_placeholder(o.id);
  v_bal := booking._order_balance(o.id);
  if v_diff > 0 and (v_bal ->> 'unpaid')::numeric > 0 then v_pay := booking._public_pay_json(o.id); end if;
  if (v_bal ->> 'net_paid')::numeric > v_new then
    insert into booking.order_requests(order_id, kind, reason, payload) values (o.id, 'refund_due', 'Ajan/henkilömäärän muutos pienensi hintaa', jsonb_build_object('amount', (v_bal ->> 'net_paid')::numeric - v_new, 'new_total', v_new))
      on conflict (order_id, kind) where status = 'open' do update set payload = excluded.payload returning id into v_req;
    perform booking._notify_staff('refund_due', v_req, jsonb_build_object('request_id', v_req, 'order_id', o.id, 'order_no', o.order_no, 'amount', (v_bal ->> 'net_paid')::numeric - v_new));
  end if;
  perform booking._enqueue_email('order_change', o.id, null, null, 'order_change:' || o.id || ':' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'));
  return v || jsonb_build_object('price_diff', v_diff, 'payment', v_pay, 'balance', jsonb_build_object('total', v_bal -> 'total', 'paid', v_bal -> 'net_paid', 'unpaid', v_bal -> 'unpaid'),
                                 'online_payment_enabled', exists (select 1 from booking.integration_config where key = 'vismapay' and mode = 'live'));
end $function$;

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
end $function$;

drop trigger reservations_option_check on booking.reservations;
drop function booking.reservations_option_check();
drop function booking._resolve_product_option(bigint, text, boolean);
drop function booking._product_options_json(bigint, boolean);
drop function booking._option_json(bigint);
alter table booking.reservations drop column product_option_id;
alter table booking.product_config drop column option_required, drop column option_label, drop column option_label_en;
drop table booking.product_options;
revoke all on function booking._create_legs_booking(text, bigint, timestamptz, timestamptz, integer, bigint, text, uuid, text, numeric, bigint, boolean, text, boolean, bigint, bigint) from public, anon, authenticated;
revoke all on function booking._admin_create_legs(text, bigint, timestamptz, timestamptz, integer, bigint, jsonb, text, boolean, text, numeric, bigint, boolean, text, jsonb, bigint, text, boolean) from public, anon, authenticated;
revoke all on function booking.admin_create_old_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text) from public, anon, authenticated;
revoke all on function booking.admin_create_resource_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text) from public, anon, authenticated;
revoke all on function booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer, text) from public, anon, authenticated;
revoke all on function booking.public_create_treatment_booking(bigint, timestamptz, integer, text, text, text, boolean, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function booking.public_change_treatment_booking(uuid, timestamptz, integer) from public, anon, authenticated;
revoke all on function booking.public_change_order_time(uuid, bigint, timestamptz, bigint, date, integer) from public, anon, authenticated;
grant execute on function booking._create_legs_booking(text, bigint, timestamptz, timestamptz, integer, bigint, text, uuid, text, numeric, bigint, boolean, text, boolean, bigint, bigint) to service_role;
grant execute on function booking._admin_create_legs(text, bigint, timestamptz, timestamptz, integer, bigint, jsonb, text, boolean, text, numeric, bigint, boolean, text, jsonb, bigint, text, boolean) to service_role;
grant execute on function booking.admin_create_old_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text) to service_role, authenticated;
grant execute on function booking.admin_create_resource_booking(bigint, timestamptz, integer, bigint, jsonb, timestamptz, bigint, text, boolean, text, numeric, boolean, text, jsonb, bigint, text) to service_role, authenticated;
grant execute on function booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer, text) to service_role, authenticated;
grant execute on function booking.public_create_treatment_booking(bigint, timestamptz, integer, text, text, text, boolean, text, text, text, jsonb) to service_role, anon, authenticated;
grant execute on function booking.public_change_treatment_booking(uuid, timestamptz, integer) to service_role, anon, authenticated;
grant execute on function booking.public_change_order_time(uuid, bigint, timestamptz, bigint, date, integer) to service_role, anon, authenticated;
commit;
