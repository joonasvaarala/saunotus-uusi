-- booking_25 ROLLBACK (17.10.2026): palauttaa public_catalog / public_get_booking / public_change_booking edelliseen tuotantoversioon, poistaa uudet funktiot, triggerit ja ilmoitustaulun.
-- Ajetaan vain jos booking_25 pitää perua. Tietoa ei menetä muualta kuin notifications_outbox (ilmoitusjono) ja product_config.public_slots/public_weekdays.
begin;
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
      'min_persons', pc.min_persons, 'max_persons', pc.max_persons
    ) order by pc.sort_order, p.id), '[]'::jsonb)
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
    and exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active)
$function$;
CREATE OR REPLACE FUNCTION booking.public_change_booking(p_token uuid, p_rule_id bigint DEFAULT NULL::bigint, p_date date DEFAULT NULL::date, p_persons integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_ip text := booking._client_ip(); o booking.orders; v_res_id bigint; v_n int; v_out jsonb; v_detail text; v_msg text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if not booking._rate_limit('chg:' || p_token::text, (booking._setting('rl_change_per_10min', '10'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if (p_rule_id is null) <> (p_date is null) or (p_rule_id is null and p_persons is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid_change', 'message', 'Valitse uusi vuoro ja/tai henkilömäärä');
  end if;
  if p_persons is not null and (p_persons < 1 or p_persons > 50) then
    return jsonb_build_object('ok', false, 'code', 'invalid_persons', 'message', 'Tarkista henkilömäärä');
  end if;
  if p_date is not null and (p_date < (now() at time zone booking._tz())::date
     or p_date > (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int) then
    return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
  end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select count(*), min(r.id) into v_n, v_res_id from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  if v_n <> 1 or o.status <> 'confirmed' then
    return jsonb_build_object('ok', false, 'code', 'not_changeable', 'message', 'Tätä varausta ei voi muuttaa verkossa – ota yhteyttä sähköpostitse');
  end if;

  begin  -- alitransaktio: virhe kumoaa muutoksen kokonaan (vanha varaus säilyy) mutta rate limit -kirjaus säilyy
    v_out := booking._change_booking_core(v_res_id, p_rule_id, p_date, p_persons, true, v_hours, null, 'CUSTOMER_CHANGE');
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  return jsonb_build_object('ok', true, 'order_no', v_out -> 'order_no', 'starts_at', v_out -> 'starts_at', 'ends_at', v_out -> 'ends_at',
                            'persons', v_out -> 'persons', 'total', v_out -> 'total');
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
  v_conf_n integer; v_conf_start timestamptz;
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
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status',
           case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) then 'expired' else o.status end,
           'payment_status', o.payment_status, 'total', o.total_gross, 'currency', o.currency, 'created_at', o.created_at,
           'first_name', cust, 'customer_kind', o.customer_kind, 'items', coalesce(res, '[]'::jsonb), 'addons', coalesce(adds, '[]'::jsonb),
           'payment_methods', (select coalesce(jsonb_agg(p.method), '[]'::jsonb) from booking.payments p where p.order_id = o.id),
           'can_change', (o.status = 'confirmed' and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now()),
           'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end,
           'change_hours_before', v_hours);
end $function$;
drop trigger if exists reservations_notify_ins on booking.reservations;
drop trigger if exists reservations_notify_upd on booking.reservations;
drop function if exists booking.reservations_notify_trg();
drop function if exists booking.admin_treatment_availability(bigint, date, date, integer, boolean, text);
drop function if exists booking.public_change_treatment_booking(uuid, timestamptz, integer);
drop function if exists booking.public_create_treatment_booking(bigint, timestamptz, integer, text, text, text, boolean, text, text, text, jsonb);
drop function if exists booking.public_treatment_availability(bigint, date, date, integer);
drop function if exists booking._treatment_availability_core(bigint, date, date, integer, boolean, boolean);
drop function if exists booking.notifications_pull(text, text, integer);
drop function if exists booking.notifications_ack(bigint[], text);
drop function if exists booking._treatment_plan_ok(bigint, timestamptz, timestamptz, integer);
drop function if exists booking._treatment_plan_status(bigint, timestamptz, timestamptz, integer);
drop function if exists booking._treatment_slot_check(bigint, timestamptz, integer, boolean);
drop function if exists booking._public_slot_error(text, text);
drop function if exists booking._treatment_price(bigint, integer);
drop function if exists booking._treatment_max_persons(bigint);
drop function if exists booking._time_window_violation(bigint, timestamptz, timestamptz);
drop function if exists booking._public_shift_day_open(date);
drop function if exists booking._therapist_missing_payload(booking.reservations);
drop table if exists booking.notifications_outbox;
alter table booking.product_config drop column if exists public_weekdays, drop column if exists public_slots;
delete from booking.settings where key in ('public_treatment_horizon_days','public_treatment_min_lead_minutes','public_treatment_global_per_hour','public_treatment_max_open_per_email','rl_avail_per_10min');
commit;
