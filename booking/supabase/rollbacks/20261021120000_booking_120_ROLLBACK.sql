-- booking_120 rollback: Visma Pay takaisin dry_run/off-runkoon.
-- Aja vain jos booking_120 on käytössä. Kytkee test/live-tilan pois ennen vanhaa check-rajoitetta.
-- Palauttaa vismapay_payment_prepare(uuid), julkiset maksutavat ja public_get_orderin booking_53/92-muotoon.

set local lock_timeout = '5s';

update booking.integration_config set mode = 'off' where key = 'vismapay' and mode in ('test', 'live');

drop trigger if exists integration_config_vismapay_guard on booking.integration_config;
drop function if exists booking._vismapay_guard_trg();
drop function if exists booking.admin_set_vismapay_mode(text, text);
drop function if exists booking.admin_get_vismapay_status();
drop function if exists booking.vismapay_refund_lookup(text);
drop function if exists booking.vismapay_refund_fail(bigint, jsonb);
drop function if exists booking.vismapay_refund_complete(bigint, text, jsonb);
drop function if exists booking.vismapay_refund_stamp(bigint, text, text, jsonb);
drop function if exists booking.vismapay_refund_claim(bigint, integer);
drop function if exists booking.vismapay_order_refs(uuid);
drop function if exists booking.vismapay_payment_apply(text, text, numeric, jsonb);
drop function if exists booking.vismapay_payment_lookup(text);
drop function if exists booking.vismapay_payment_event(text, text, text, text, jsonb);
drop function if exists booking.vismapay_payment_prepare(uuid, uuid);
drop function if exists booking._vismapay_online();
drop function if exists booking._vismapay_mode();

alter table booking.integration_config drop constraint if exists integration_config_test_only_online;
alter table booking.integration_config add constraint integration_config_test_only_mobilepay check (mode <> 'test' or key = 'mobilepay');

create function booking.vismapay_payment_prepare(p_order_token uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_mode text := coalesce((select mode from booking.integration_config where key = 'vismapay'), 'off');
  o booking.orders; v_tot numeric; v_unpaid numeric; pay booking.payments;
begin
  if p_order_token is null then return jsonb_build_object('ok', false, 'code', 'invalid_param', 'message', 'order_token puuttuu'); end if;
  if not booking._rate_limit('vpstart:' || p_order_token::text, 12, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_mode = 'live' then
    return jsonb_build_object('ok', false, 'code', 'vismapay_live_not_implemented', 'mode', v_mode, 'message', 'Visma Payn tuotantomaksu ei ole vielä toteutettu');
  end if;
  if v_mode <> 'dry_run' then
    return jsonb_build_object('ok', false, 'code', 'vismapay_off', 'mode', v_mode, 'message', 'Verkkomaksu ei ole käytössä');
  end if;
  select * into o from booking.orders where public_token = p_order_token for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy'); end if;
  if o.external_source is not null or o.status not in ('pending', 'confirmed') or o.currency <> 'EUR' then
    return jsonb_build_object('ok', false, 'code', 'order_not_payable', 'message', 'Tilausta ei voi maksaa');
  end if;
  select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
  v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
  v_tot := least(v_tot, v_unpaid);
  if v_tot <= 0.004 then
    if exists (select 1 from booking.payments where order_id = o.id and status in ('paid', 'partially_refunded', 'refunded')) then
      return jsonb_build_object('ok', false, 'code', 'already_paid', 'message', 'Tilaus on jo maksettu');
    end if;
    return jsonb_build_object('ok', false, 'code', 'nothing_to_pay', 'message', 'Ei maksettavaa');
  end if;
  select * into pay from booking.payments
   where order_id = o.id and status = 'pending' and provider = 'visma_pay' and amount = v_tot and provider_ref like 'dryrun-%'
   order by id desc limit 1 for update;
  if not found then
    insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, note)
    values (o.id, 'visma_pay', 'visma_pay', 'pending', v_tot, o.currency, now() + interval '30 minutes', 'Visma Pay dry_run, ei veloitusta')
    returning * into pay;
    update booking.payments set provider_ref = 'dryrun-' || pay.id, provider_status = 'dry_run' where id = pay.id returning * into pay;
    insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
    select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
    update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) - v_tot)
     where id = (select id from booking.payment_lines where payment_id = pay.id order by amount_gross desc, id limit 1)
       and (select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) > v_tot;
    perform booking._refresh_order_payment(o.id);
  end if;
  return jsonb_build_object('ok', true, 'mode', 'dry_run', 'dry_run', true, 'implemented', false,
    'payment_id', pay.id, 'provider_ref', pay.provider_ref, 'amount', pay.amount, 'currency', pay.currency,
    'order_no', o.order_no, 'order_token', o.public_token, 'status', pay.status,
    'message', 'Testitila: maksua ei veloiteta eikä kuittia synny.');
end $$;

create or replace function booking.public_payment_options(p_token uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_mode text := booking._mobilepay_mode(); o booking.orders; v_unpaid numeric; v_can boolean := false; v_methods jsonb := '[]'::jsonb; v_order jsonb := null; v_pending boolean := false;
begin
  if v_mode <> 'off' then
    v_methods := jsonb_build_array(jsonb_build_object('code', 'mobilepay', 'provider', 'vipps_mobilepay', 'label', 'MobilePay', 'label_en', 'MobilePay', 'test', v_mode = 'test',
      'start', jsonb_build_object('function', 'mobilepay-start', 'method', 'POST', 'body', case when p_token is not null then jsonb_build_object('order_token', p_token) else '{}'::jsonb end)));
  end if;
  if p_token is null and booking._pay_later_test_enabled() then v_methods := v_methods || jsonb_build_array(booking._pay_later_method_json()); end if;
  if p_token is not null then
    if not booking._order_rl('popt', p_token, 120, 60) then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
    select * into o from booking.orders where public_token = p_token;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    v_can := v_mode <> 'off' and o.external_source is null and o.status in ('pending', 'confirmed', 'completed', 'expired') and o.currency = 'EUR' and v_unpaid > 0.004
      and not (o.status = 'pending' and o.hold_kind = 'preliminary')
      and o.payment_status is distinct from 'invoiced' and o.customer_kind is distinct from 'company';
    v_pending := exists (select 1 from booking.payments where order_id = o.id and provider = 'mobilepay' and status = 'pending' and (link_expires_at is null or link_expires_at > now()));
    v_order := jsonb_build_object('order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'unpaid', v_unpaid, 'can_pay_online', v_can, 'mobilepay_pending', v_pending) || booking._checkout_state_json(o.id);
    if not v_can then v_methods := '[]'::jsonb; end if;
    if booking._pay_later_test_enabled() and o.external_source is null and v_order ->> 'checkout_state' = 'awaiting_payment'
       and o.payment_status is distinct from 'invoiced' and o.customer_kind is distinct from 'company' then
      v_methods := v_methods || jsonb_build_array(booking._pay_later_method_json());
    end if;
  end if;
  return jsonb_build_object('ok', true, 'online_enabled', v_mode <> 'off', 'methods', v_methods, 'order', v_order);
end $$;

CREATE OR REPLACE FUNCTION booking.public_checkout_payment_options()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_mp text := booking._mobilepay_mode(); v_gc boolean := coalesce((booking._setting('gift_cards.redeem_enabled', 'false'::jsonb) #>> '{}')::boolean, false); v_m jsonb := '[]'::jsonb;
begin
  if v_mp <> 'off' then
    v_m := v_m || jsonb_build_array(jsonb_build_object('code', 'mobilepay', 'kind', 'online', 'provider', 'vipps_mobilepay', 'label', 'MobilePay', 'label_en', 'MobilePay', 'test', v_mp = 'test',
      'start', jsonb_build_object('function', 'mobilepay-start', 'method', 'POST', 'body', jsonb_build_object('order_token', '<tilauksen public_token>'))));
  end if;
  if v_gc then
    v_m := v_m || jsonb_build_array(jsonb_build_object('code', 'gift_card', 'kind', 'redeem', 'provider', 'gift_card', 'label', 'Lahjakortti', 'label_en', 'Gift card', 'test', false,
      'check_rpc', 'public_check_gift_card', 'apply_rpc', 'public_apply_gift_card'));
  end if;
  if booking._pay_later_test_enabled() then v_m := v_m || jsonb_build_array(booking._pay_later_method_json()); end if;   -- booking_57: testimaksutapa (vain kun pay_later_test_enabled = true)
  return jsonb_build_object('ok', true, 'methods', v_m, 'mobilepay_enabled', v_mp <> 'off', 'gift_card_redeem_enabled', v_gc, 'pay_later_test_enabled', booking._pay_later_test_enabled(),
    'hold_until_paid', (booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}') <> 'pay_later', 'hold_minutes', booking._checkout_hold_minutes(),
    'group_threshold_persons', booking._checkout_cfg_int('checkout_group_threshold_persons', 0, 0, 1000), 'group_hold_days', booking._checkout_cfg_int('checkout_group_hold_days', 7, 1, 60));
end $function$;

create or replace function booking.admin_create_payment_link(p_order_id bigint, p_send_email boolean default false, p_expires_days integer default 14, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_pid bigint; v_mail boolean := false; v_mode text;
begin
  perform booking._require_permission('payments.manage');
  v := booking._create_link_payment(p_order_id, p_expires_days, p_note);
  v_pid := (v ->> 'payment_id')::bigint;
  if p_send_email then v_mail := booking._enqueue_email('payment_link', p_order_id, null, v_pid, 'payment_link:' || v_pid || ':' || to_char(now(), 'YYYYMMDDHH24MI')); end if;
  select mode into v_mode from booking.integration_config where key = 'vismapay';
  return jsonb_build_object('ok', true) || (booking._link_json(v_pid)) || jsonb_build_object('online_payment_enabled', coalesce(v_mode, 'off') = 'live', 'email_queued', v_mail);
end $$;

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
  v_status := case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end;
  v_online := exists (select 1 from booking.integration_config where key = 'vismapay' and mode = 'live');
  v_pl := booking._setting('payment_link_path', to_jsonb('/maksa/'::text)) #>> '{}';

  select coalesce(jsonb_agg(jsonb_build_object('name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate, 'kind', it.kind) order by it.id), '[]'::jsonb)
    into v_items from booking.order_items it where it.order_id = o.id;
  select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'product_id', r.product_id, 'product_name', oi.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons,
           'option', booking._option_json(r.product_option_id),
           'option_label', booking._option_label(r.product_id, o.locale), 'option_label_fi', booking._option_label(r.product_id, 'fi'), 'option_label_en', booking._option_label(r.product_id, 'en'), 'option_choices', booking._product_options_json(r.product_id),
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() and not booking._order_mp_inflight(r.order_id) then 'expired' else r.status end,
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
    'upsell', jsonb_build_object('addons', coalesce(v_ups_a, '[]'::jsonb), 'treatments', coalesce(v_ups_t, '[]'::jsonb)))
    || booking._checkout_state_json(o.id);
end $function$;

revoke all on function booking.vismapay_payment_prepare(uuid) from public, anon, authenticated;
grant execute on function booking.vismapay_payment_prepare(uuid) to service_role;
