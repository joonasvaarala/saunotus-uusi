-- booking_33_talous_customer_order (17.10.2026): vaihe C (tietokantapuoli) – asiakkaan tilaussivu, lisäykset, peruutuspyyntö, ajanmuutos, pyyntöjen käsittely. Vaatii booking_31 (+32). Rollback: booking_33_ROLLBACK.sql
insert into booking.settings(key, value) values ('rl_order_get_per_10min', '60'::jsonb), ('rl_order_add_per_10min', '20'::jsonb), ('rl_order_req_per_10min', '6'::jsonb)
on conflict (key) do nothing;

-- ---------- apurit ----------
create function booking._order_rl(p_kind text, p_token uuid, p_ip_max int, p_tok_max int) returns boolean language plpgsql security definer set search_path = '' as $$
declare v_ip text := booking._client_ip();
begin
  if v_ip is not null and not booking._rate_limit('o' || p_kind || 'ip:' || v_ip, p_ip_max, interval '10 minutes') then return false; end if;
  if p_token is not null and not booking._rate_limit('o' || p_kind || 'tk:' || p_token::text, p_tok_max, interval '10 minutes') then return false; end if;
  return true;
end $$;

create function booking._order_err(p_detail text, p_msg text) returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object('ok', false, 'code', coalesce(p_detail, 'error'), 'message', p_msg)
$$;

create function booking._public_pay_json(p_order_id bigint) returns jsonb language plpgsql security definer set search_path = '' as $$
-- luo maksulinkin vain jos verkkomaksu on käytössä (vismapay=live) ja maksettavaa on; muuten null
declare v_pay jsonb; v_pid bigint; v_code text;
begin
  if not exists (select 1 from booking.integration_config where key = 'vismapay' and mode = 'live') then return null; end if;
  begin
    v_pay := booking._create_link_payment(p_order_id, 14, null);
    v_pid := (v_pay ->> 'payment_id')::bigint;
    return booking._link_json(v_pid) - 'lines' - 'payment_id';
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_code = pg_exception_detail;
    if v_code is distinct from 'nothing_to_pay' then raise; end if;
    return null;
  end;
end $$;

create function booking._notify_staff(p_topic text, p_req_id bigint, p_payload jsonb) returns void language sql security definer set search_path = '' as $$
  insert into booking.notifications_outbox(topic, target, ref_table, ref_id, dedupe_key, payload)
  values (p_topic, 'tapio', 'order_requests', p_req_id, p_topic || ':' || p_req_id, coalesce(p_payload, '{}'::jsonb)) on conflict (dedupe_key) do nothing
$$;

-- ---------- public_get_order ----------
create function booking.public_get_order(p_token uuid) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
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
    into v_res from booking.reservations r left join booking.order_items oi on oi.id = r.order_item_id where r.order_id = o.id;
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
end $$;

-- ---------- public_add_to_order ----------
create function booking.public_add_to_order(p_token uuid, p_items jsonb) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o booking.orders; v jsonb; e jsonb; v_detail text; v_msg text; v_pay jsonb; v_bal jsonb;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._order_rl('add', p_token, (booking._setting('rl_order_add_per_10min', '20'::jsonb) #>> '{}')::int, 10) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 10 then return booking._order_err('invalid_items', 'Anna 1–10 lisättävää riviä'); end if;
  for e in select * from jsonb_array_elements(p_items) loop
    if jsonb_typeof(e) <> 'object' or e ->> 'type' is null or e ->> 'type' not in ('addon', 'reservation') then return booking._order_err('invalid_items', 'Vain lisäpalveluja ja hoitovarauksia voi lisätä verkossa'); end if;
  end loop;
  begin
    v := booking._add_to_order(o.id, p_items, false);
    perform booking._sync_placeholder(o.id);
    v_pay := booking._public_pay_json(o.id);
    perform booking._enqueue_email('order_change', o.id, null, null, 'order_change:' || o.id || ':' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'));
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return booking._order_err(v_detail, v_msg);
    when exclusion_violation then
      return booking._order_err('slot_unavailable', 'Valittu aika ei ole enää varattavissa – valitse toinen aika');
    when lock_not_available then
      return booking._order_err('busy', 'Järjestelmä on hetkellä kiireinen, yritä hetken kuluttua uudelleen');
  end;
  v_bal := booking._order_balance(o.id);
  return jsonb_build_object('ok', true, 'added_total', v -> 'added_total',
    'added', coalesce((select jsonb_agg(jsonb_build_object('name', x ->> 'name', 'line_total', x -> 'line_total')) from jsonb_array_elements(v -> 'added') x), '[]'::jsonb),
    'balance', jsonb_build_object('total', v_bal -> 'total', 'paid', v_bal -> 'net_paid', 'unpaid', v_bal -> 'unpaid'),
    'payment', v_pay, 'online_payment_enabled', exists (select 1 from booking.integration_config where key = 'vismapay' and mode = 'live'));
end $$;

-- ---------- public_request_cancel ----------
create function booking.public_request_cancel(p_token uuid, p_reason text default null) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o booking.orders; v_id bigint; v_at timestamptz; v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_first timestamptz; v_bal jsonb;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._order_rl('req', p_token, (booking._setting('rl_order_req_per_10min', '6'::jsonb) #>> '{}')::int * 2, (booking._setting('rl_order_req_per_10min', '6'::jsonb) #>> '{}')::int) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_reason is not null and char_length(v_reason) > 1000 then return booking._order_err('invalid_reason', 'Syy on liian pitkä (enintään 1000 merkkiä)'); end if;
  select * into o from booking.orders where public_token = p_token for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select min(r.starts_at) into v_first from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at) and r.ends_at > now();
  if o.external_source is not null or o.status <> 'confirmed' or v_first is null then
    return booking._order_err('order_closed', 'Tilausta ei voi enää peruuttaa verkossa – ota yhteyttä sähköpostitse');
  end if;
  if exists (select 1 from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' and q.status = 'open') then
    return booking._order_err('request_exists', 'Peruutuspyyntö on jo lähetetty ja odottaa käsittelyä');
  end if;
  insert into booking.order_requests(order_id, kind, reason) values (o.id, 'cancel', v_reason) returning id, created_at into v_id, v_at;
  v_bal := booking._order_balance(o.id);
  perform booking._notify_staff('cancel_request', v_id, jsonb_build_object('request_id', v_id, 'order_id', o.id, 'order_no', o.order_no, 'first_start', v_first, 'total', o.total_gross, 'paid', v_bal -> 'net_paid', 'has_reason', v_reason is not null));
  perform booking._enqueue_email('cancel_request_ack', o.id, null, null, 'cancel_ack:' || v_id);
  return jsonb_build_object('ok', true, 'request', jsonb_build_object('id', v_id, 'status', 'open', 'created_at', v_at));
end $$;

-- ---------- public_change_order_time ----------
create function booking.public_change_order_time(p_token uuid, p_reservation_id bigint, p_start timestamptz default null, p_rule_id bigint default null, p_date date default null, p_persons integer default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
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
end $$;

-- ---------- henkilökunta: pyyntöjen käsittely ----------
create function booking.admin_list_order_requests(p_status text default 'open') returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_rows jsonb;
begin
  perform booking._require_staff();
  if p_status is null or p_status not in ('open', 'handled', 'rejected', 'all') then perform booking._err('invalid_param', 'p_status: open|handled|rejected|all'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'order_id', q.order_id, 'order_no', o.order_no, 'order_status', o.status, 'customer_name', c.name, 'kind', q.kind, 'status', q.status, 'reason', q.reason,
           'payload', q.payload, 'created_at', q.created_at, 'handled_at', q.handled_at, 'note', q.note, 'total', o.total_gross, 'paid', (booking._order_balance(o.id) ->> 'net_paid')::numeric,
           'first_start', (select min(r.starts_at) from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at))) order by q.created_at, q.id), '[]'::jsonb)
    into v_rows from booking.order_requests q join booking.orders o on o.id = q.order_id left join booking.customers c on c.id = o.customer_id
   where p_status = 'all' or q.status = p_status;
  return jsonb_build_object('ok', true, 'requests', v_rows, 'count', jsonb_array_length(v_rows));
end $$;

create function booking.admin_resolve_order_request(p_request_id bigint, p_action text, p_note text default null) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare q booking.order_requests; o booking.orders; r record; v_n int := 0; v_bal jsonb;
begin
  perform booking._require_permission('bookings.manage');
  if p_action is null or p_action not in ('approve', 'reject') then perform booking._err('invalid_param', 'p_action: approve|reject'); end if;
  select * into q from booking.order_requests where id = p_request_id for update;
  if not found then perform booking._err('not_found', 'Pyyntöä ei löydy'); end if;
  if q.status <> 'open' then perform booking._err('request_closed', 'Pyyntö on jo käsitelty'); end if;
  select * into o from booking.orders where id = q.order_id for update;
  if p_action = 'approve' and q.kind = 'cancel' and o.status in ('pending', 'confirmed') then
    for r in select id from booking.reservations where order_id = o.id and status in ('pending', 'confirmed') loop
      perform booking.admin_set_reservation_status(r.id, 'cancelled', 'Asiakkaan peruutuspyyntö #' || q.id);
      v_n := v_n + 1;
    end loop;
    update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'tilaus peruttu') where order_id = o.id and status = 'pending' and provider = 'visma_pay';
    perform booking._sync_placeholder(o.id);
  end if;
  update booking.order_requests set status = case when p_action = 'approve' then 'handled' else 'rejected' end, handled_by = auth.uid(), handled_at = now(), note = nullif(btrim(coalesce(p_note, '')), '') where id = q.id;
  v_bal := booking._order_balance(o.id);
  return jsonb_build_object('ok', true, 'status', case when p_action = 'approve' then 'handled' else 'rejected' end, 'cancelled_reservations', v_n,
    'order_status', (select status from booking.orders where id = o.id), 'balance', v_bal,
    'refund_needed', p_action = 'approve' and q.kind = 'cancel' and (v_bal ->> 'net_paid')::numeric > 0 and (select status from booking.orders where id = o.id) = 'cancelled');
end $$;

-- ---------- oikeudet ----------
do $$ declare r record; begin
  for r in select p.oid::regprocedure as f, p.proname from pg_proc p where p.pronamespace = 'booking'::regnamespace
            and p.proname in ('_order_rl','_order_err','_public_pay_json','_notify_staff','public_get_order','public_add_to_order','public_request_cancel','public_change_order_time','admin_list_order_requests','admin_resolve_order_request') loop
    execute format('revoke all on function %s from public, anon, authenticated', r.f);
    execute format('grant execute on function %s to service_role', r.f);
    if r.proname like 'public\_%' then execute format('grant execute on function %s to anon, authenticated', r.f); end if;
    if r.proname like 'admin\_%' then execute format('grant execute on function %s to authenticated', r.f); end if;
  end loop;
end $$;
