-- booking_308 ROLLBACK: palauttaa 8 funktiota booking_307-tilaan (md5:t tarkistetaan lopuksi) ja poistaa asetuksen customer_move_min_days_private. Ei koske dataan.
set local lock_timeout = '5s';
do $pre$ begin if not exists (select 1 from booking.settings where key = 'customer_move_min_days_private') then raise exception 'booking_308 ROLLBACK: booking_308 ei ole ajettu. Ei muutoksia.'; end if; end $pre$;

CREATE OR REPLACE FUNCTION booking._customer_move_blocked(p_reservation_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id
                  where r.id = p_reservation_id and pc.cancellation_tier = 'general')
     and exists (select 1 from booking.audit_log a
                  where a.table_name = 'reservations' and a.row_pk = p_reservation_id::text and a.action = 'CUSTOMER_CHANGE'
                    and (a.old_data ->> 'starts_at')::timestamptz is distinct from (a.new_data ->> 'starts_at')::timestamptz)
$function$;

CREATE OR REPLACE FUNCTION booking._reduce_eval(p_order_id bigint, p_reservation_id bigint, p_rule_id bigint, p_date date, p_persons integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; res booking.reservations; v_pp jsonb; v_old numeric; v_new numeric; v_net numeric; v_tier text; v_hours int; v_days int; v_refund numeric;
        v_reason text; v_info jsonb; v_cool int; v_today date;
begin
  select * into o from booking.orders where id = p_order_id;
  select * into res from booking.reservations where id = p_reservation_id;
  v_pp := booking._change_price_preview(res.id, p_rule_id, p_persons);
  v_old := (v_pp ->> 'old_total')::numeric; v_new := (v_pp ->> 'new_total')::numeric;
  if v_new >= v_old - 0.004 then
    return jsonb_build_object('mode', 'none', 'old_total', v_old, 'new_total', v_new, 'diff', round(v_new - v_old, 2));
  end if;
  v_info := booking._order_refund_info(o.id);
  v_net := (v_info ->> 'net_paid')::numeric;
  if (booking._order_balance(o.id) ->> 'net_paid')::numeric <= 0.004 and not exists (select 1 from booking.payments x where x.order_id = o.id and x.status in ('paid', 'partially_refunded', 'refunded')) then
    return jsonb_build_object('mode', 'unpaid', 'old_total', v_old, 'new_total', v_new, 'diff', round(v_new - v_old, 2));
  end if;
  v_hours := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_days := coalesce((booking._setting('customer_reduce_full_refund_days_private', '14'::jsonb) #>> '{}')::int, 14);
  v_cool := coalesce((booking._setting('customer_reduce_cooldown_minutes', '60'::jsonb) #>> '{}')::int, 60);
  v_today := (now() at time zone booking._tz())::date;
  v_refund := round(v_old - v_new, 2);
  select pc.cancellation_tier into v_tier from booking.product_config pc where pc.product_id = res.product_id;
  v_reason := case
    when o.external_source is not null then 'not_changeable'
    when booking._order_invoice_locked(o.id) then 'order_invoiced'
    when not (booking._flag_on('customer_auto_partial_refund_enabled') and booking._flag_on('partial_refunds_enabled')) then 'feature_disabled'
    when v_tier is null then 'not_classified'
    when v_tier = 'general' and res.starts_at - make_interval(hours => v_hours) < now() then 'too_late'
    when v_tier = 'private_event' and (res.starts_at - make_interval(days => v_days) < now()
                                       or (p_date is not null and p_date < v_today + v_days)) then 'too_late_private'
    when v_net < v_old - 0.004 then 'partially_paid'
    when exists (select 1 from booking.payments x
                  where x.order_id = o.id and x.status in ('paid', 'partially_refunded')
                    and not (x.provider = 'montonio' and x.gift_card_id is null and x.method not like 'partner\_voucher%' and x.method <> 'gift_card'
                             and coalesce((select c.mode from booking.integration_config c where c.key = 'montonio'), 'off') <> 'off')) then 'payment_method'
    when v_refund < 0.05 then 'refund_too_small'
    when v_net - v_refund < v_new - 0.004 or (v_info ->> 'eligible_cap')::numeric < v_refund - 0.004 then 'already_refunding'
    when exists (select 1 from booking.audit_log a where a.action = 'CUSTOMER_REDUCE_REFUND' and a.row_pk = o.id::text and a.at > now() - make_interval(mins => v_cool)) then 'cooldown'
    else null end;
  return jsonb_build_object('mode', 'reduce', 'allowed', v_reason is null, 'reason', v_reason, 'refund_amount', v_refund,
    'old_total', v_old, 'new_total', v_new, 'diff', round(v_new - v_old, 2), 'tier', v_tier);
end $function$;

CREATE OR REPLACE FUNCTION booking.public_change_preview(p_token uuid, p_rule_id bigint DEFAULT NULL::bigint, p_date date DEFAULT NULL::date, p_persons integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_ip text := booking._client_ip(); o booking.orders; v_res_id bigint; v_n int; v_ev jsonb; v_msg text; v_detail text;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if not booking._rate_limit('chgp:' || p_token::text, (booking._setting('rl_change_per_10min', '10'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if (p_rule_id is null) <> (p_date is null) or (p_rule_id is null and p_persons is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid_change', 'message', 'Valitse uusi vuoro ja/tai henkilömäärä');
  end if;
  if p_persons is not null and (p_persons < 1 or p_persons > 50) then return jsonb_build_object('ok', false, 'code', 'invalid_persons', 'message', 'Tarkista henkilömäärä'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select count(*), min(r.id) into v_n, v_res_id from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  if v_n <> 1 or o.status <> 'confirmed' or exists (select 1 from booking.reservations r where r.id = v_res_id and r.rule_id is null) then
    return jsonb_build_object('ok', false, 'code', 'not_changeable', 'message', 'Tätä varausta ei voi muuttaa verkossa – ota yhteyttä sähköpostitse');
  end if;
  if p_rule_id is not null and (select r.product_id from booking.schedule_rules r where r.id = p_rule_id) is distinct from (select product_id from booking.reservations where id = v_res_id) then
    return jsonb_build_object('ok', false, 'code', 'product_mismatch', 'message', 'Varauksen voi siirtää vain saman tuotteen toiseen vuoroon');
  end if;
  v_ev := booking._reduce_eval(o.id, v_res_id, p_rule_id, p_date, p_persons);
  return jsonb_build_object('ok', true, 'old_total', v_ev -> 'old_total', 'new_total', v_ev -> 'new_total', 'diff', v_ev -> 'diff',
    'price_up', (v_ev ->> 'diff')::numeric > 0.004, 'paid', v_ev ->> 'mode' = 'reduce',
    'auto_refund', case when v_ev ->> 'mode' <> 'reduce' then null else jsonb_build_object(
        'enabled', booking._flag_on('customer_auto_partial_refund_enabled') and booking._flag_on('partial_refunds_enabled'),
        'allowed', (v_ev ->> 'allowed')::boolean, 'reason', v_ev ->> 'reason', 'amount', case when (v_ev ->> 'allowed')::boolean then v_ev -> 'refund_amount' end,
        'eta_bank_days', '1-3') end);
end $function$;

CREATE OR REPLACE FUNCTION booking._change_booking_core(p_reservation_id bigint, p_rule_id bigint, p_date date, p_persons integer, p_enforce_deadline boolean, p_notice_hours integer, p_actor uuid, p_via text, p_allow_paid_decrease boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  res booking.reservations; o booking.orders; rs record; pr record; v_keep boolean := (p_rule_id is null and p_date is null);
  v_persons integer; v_rule bigint; v_total numeric; v_paid numeric; v_old booking.reservations; v_addons numeric; v_order_total numeric;
  v_locked boolean;
begin
  if p_enforce_deadline or p_notice_hours is not null or not coalesce(booking.has_permission('bookings.manage'), false) then
    perform booking._clear_staff_overrides();
  end if;
  if (p_rule_id is null) <> (p_date is null) then perform booking._err('invalid_change', 'Anna sekä uusi vuoro että päivä, tai kumpikaan'); end if;
  select * into res from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  select * into o from booking.orders where id = res.order_id;
  v_locked := booking._order_invoice_locked(o.id);
  if res.status <> 'confirmed' or o.status <> 'confirmed' then
    perform booking._err('not_changeable', 'Vain vahvistettua varausta voi muuttaa');
  end if;
  if v_locked and p_notice_hours is not null and coalesce(p_persons, res.persons) <> res.persons then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  if p_notice_hours is not null and res.starts_at - make_interval(hours => p_notice_hours) < now() then
    perform booking._err('change_too_late', format('Varausta voi muuttaa itse viimeistään %s tuntia ennen vuoron alkua – ota yhteyttä sähköpostitse', p_notice_hours));
  end if;
  v_old := res;
  v_persons := coalesce(p_persons, res.persons);
  v_rule := coalesce(p_rule_id, res.rule_id);

  if v_keep then
    select * into rs from booking._resolve_session(v_rule, null, v_persons, false, res.starts_at, res.ends_at, true);
  else
    select * into rs from booking._resolve_session(v_rule, p_date, v_persons, p_enforce_deadline);
  end if;
  if rs.o_product_id is distinct from res.product_id then
    perform booking._err('product_mismatch', 'Varauksen voi siirtää vain saman tuotteen toiseen vuoroon');
  end if;
  if p_notice_hours is not null and rs.o_starts_at - make_interval(hours => p_notice_hours) < now() then
    perform booking._err('change_too_late', format('Uuden vuoron pitää alkaa vähintään %s tuntia päästä', p_notice_hours));
  end if;
  -- booking_307: yleisen vuoron siirto vain kerran (ehdot: "siirto vain kerran"). Koskee asiakkaan omaa siirtoa (p_notice_hours annettu = asiakaspolku);
  -- henkilökunta (admin_change_booking, p_notice_hours null) saa ohittaa. Siirto = alkuaika muuttuu; pelkkä henkilömäärän muutos ei ole siirto.
  if p_notice_hours is not null and rs.o_starts_at is distinct from res.starts_at and booking._customer_move_blocked(res.id) then
    perform booking._err('already_moved', 'Varauksen voi siirtää verkossa vain kerran – ota yhteyttä sähköpostitse');
  end if;

  if not v_locked then
    select * into pr from booking._rule_price(v_rule, v_persons);
    v_total := case when res.annual_card_id is not null then 0 else pr.total end;
    v_addons := booking._addon_total_after(res.order_item_id, v_persons);
    select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded')), 0) into v_paid from booking.payments where order_id = o.id;
    if p_notice_hours is not null and v_paid > 0 and (v_total + v_addons) is distinct from o.total_gross
       and not (p_allow_paid_decrease and (v_total + v_addons) < o.total_gross) then   -- booking_284: asiakkaan automaattinen pienennys (palvelin on jo tarkistanut ehdot)
      perform booking._err('price_change_requires_staff', 'Maksettu varaus, jonka hinta muuttuisi: ota yhteyttä henkilökuntaan');
    end if;
  end if;

  update booking.reservations set rule_id = v_rule, space_id = rs.o_space_id, mode = rs.o_mode, starts_at = rs.o_starts_at,
         ends_at = rs.o_ends_at, persons = v_persons, pool_ids = rs.o_pool_ids
   where id = res.id returning * into res;

  if not v_locked then
    update booking.order_items set unit_price_gross = v_total, line_total_gross = v_total,
           price_breakdown = pr.breakdown || jsonb_build_object('rule_id', v_rule, 'rule_label', (select label from booking.schedule_rules where id = v_rule))
     where id = res.order_item_id;
    perform booking._clamp_addons(res.order_item_id, v_persons);
    update booking.orders set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = o.id), 0) where id = o.id
      returning total_gross into v_order_total;
    update booking.payments set amount = v_order_total where order_id = o.id and status = 'pending' and provider = 'manual';
    perform booking._refresh_order_payment(o.id);
  else
    v_order_total := o.total_gross;
  end if;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (p_actor, booking._jwt_role(), 'reservations', res.id::text, p_via, to_jsonb(v_old),
          case when v_locked then to_jsonb(res) || jsonb_build_object('invoice_locked', true) else to_jsonb(res) end);

  return jsonb_build_object('reservation_id', res.id, 'order_id', o.id, 'order_no', o.order_no, 'starts_at', res.starts_at, 'ends_at', res.ends_at,
                            'persons', res.persons, 'total', v_order_total, 'rule_id', v_rule, 'product_id', res.product_id,
                            'old_total', o.total_gross, 'overbooked', res.overbooked, 'off_schedule', res.off_schedule)
         || case when v_locked then jsonb_build_object('invoice_locked', true) else '{}'::jsonb end;
end $function$;

CREATE OR REPLACE FUNCTION booking.public_change_booking(p_token uuid, p_rule_id bigint DEFAULT NULL::bigint, p_date date DEFAULT NULL::date, p_persons integer DEFAULT NULL::integer, p_expected_refund numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_ip text := booking._client_ip(); o booking.orders; v_res_id bigint; v_n int; v_out jsonb; v_detail text; v_msg text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_ev jsonb; v_refunds jsonb := '[]'::jsonb; v_old_total numeric; v_days integer;
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
  if exists (select 1 from booking.reservations r where r.id = v_res_id and r.rule_id is null) then   -- booking_25: aikaväli-/legipohjainen varaus -> oma muutosfunktio tai ei muutettavissa
    return jsonb_build_object('ok', false, 'code', case when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.id = v_res_id) then 'use_treatment_change' else 'not_changeable' end,
      'message', 'Tätä varausta ei voi muuttaa tällä toiminnolla – ota yhteyttä sähköpostitse',
      'change_via', case when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.id = v_res_id) then 'public_change_treatment_booking' end);
  end if;

  -- booking_307: yleisen vuoron siirto vain kerran – selkeä vastaus jo ennen ydintä (ydin valvoo lopullisesti alkuajan perusteella)
  if p_rule_id is not null and booking._customer_move_blocked(v_res_id)
     and exists (select 1 from booking.reservations r where r.id = v_res_id
                  and (r.rule_id is distinct from p_rule_id or (r.starts_at at time zone booking._tz())::date is distinct from p_date)) then
    return jsonb_build_object('ok', false, 'code', 'already_moved', 'message', 'Varauksen voi siirtää verkossa vain kerran – ota yhteyttä sähköpostitse');
  end if;

  -- booking_284: tilaus lukitaan ennen arviota (kaksi samanaikaista pyyntöä ei voi hyvittää kahdesti), arvio tuoreesta tilasta
  select * into o from booking.orders where id = o.id for update;
  v_ev := booking._reduce_eval(o.id, v_res_id, p_rule_id, p_date, p_persons);
  if v_ev ->> 'mode' = 'reduce' then
    if not (v_ev ->> 'allowed')::boolean then
      -- sama vastaus kuin ennen (price_change_requires_staff); syy erikseen käyttöliittymälle
      return jsonb_build_object('ok', false, 'code', 'price_change_requires_staff', 'reduce_reason', v_ev ->> 'reason',
                                'message', 'Maksettu varaus, jonka hinta muuttuisi: ota yhteyttä henkilökuntaan');
    end if;
    if p_expected_refund is null or abs(p_expected_refund - (v_ev ->> 'refund_amount')::numeric) > 0.004 then
      return jsonb_build_object('ok', false, 'code', 'refund_confirmation_required', 'refund_amount', v_ev -> 'refund_amount',
                                'message', 'Vahvista hyvitys: hinta tai hyvitys on muuttunut');
    end if;
  end if;

  begin  -- alitransaktio: virhe kumoaa muutoksen kokonaan (vanha varaus säilyy) mutta rate limit -kirjaus säilyy
    v_out := booking._change_booking_core(v_res_id, p_rule_id, p_date, p_persons, true, v_hours, null, 'CUSTOMER_CHANGE', v_ev ->> 'mode' = 'reduce');
    if v_ev ->> 'mode' = 'reduce' then
      v_old_total := (v_out ->> 'old_total')::numeric;
      -- yksityis-/tapahtumavuoro: myös uuden vuoron alkuun ≥ 14 vrk (tarkka aika vasta ytimen jälkeen)
      v_days := coalesce((booking._setting('customer_reduce_full_refund_days_private', '14'::jsonb) #>> '{}')::int, 14);
      if v_ev ->> 'tier' = 'private_event' and (v_out ->> 'starts_at')::timestamptz - make_interval(days => v_days) < now() then
        perform booking._err('change_too_late', 'Uuden vuoron pitää alkaa vähintään ' || v_days || ' vrk päästä – ota yhteyttä henkilökuntaan');
      end if;
      if abs((v_old_total - (v_out ->> 'total')::numeric) - (v_ev ->> 'refund_amount')::numeric) > 0.004 then
        perform booking._err('preview_stale', 'Hinta muuttui, yritä uudelleen');
      end if;
      v_refunds := booking._customer_refund_create(o.id, (v_ev ->> 'refund_amount')::numeric, v_res_id);
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
      values (null, booking._jwt_role(), 'orders', o.id::text, 'CUSTOMER_REDUCE_REFUND', jsonb_build_object('total', v_old_total),
              jsonb_build_object('total', v_out -> 'total', 'refund_amount', v_ev -> 'refund_amount', 'refunds', v_refunds, 'reservation_id', v_res_id));
      perform booking._enqueue_email('order_change', o.id, null, null, 'order_change:' || o.id || ':' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
        jsonb_build_object('source', 'customer_reduce', 'reservation_id', v_res_id, 'refund_ids', (select coalesce(jsonb_agg(e -> 'refund_id'), '[]'::jsonb) from jsonb_array_elements(v_refunds) e),
                           'refund_amount', v_ev -> 'refund_amount'));
    end if;
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  return jsonb_build_object('ok', true, 'order_no', v_out -> 'order_no', 'starts_at', v_out -> 'starts_at', 'ends_at', v_out -> 'ends_at',
                            'persons', v_out -> 'persons', 'total', v_out -> 'total')
         || case when jsonb_array_length(v_refunds) > 0 then jsonb_build_object('refund_amount', v_ev -> 'refund_amount', 'refund_pending', true) else '{}'::jsonb end;
end $function$;

CREATE OR REPLACE FUNCTION booking.svc_move_reservation(p_order_no bigint, p_new_start timestamp with time zone, p_note text, p_actor text DEFAULT 'asiakaspalvelu-bot'::text, p_allow_overbook boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders;
  res booking.reservations;
  rs record;
  lp booking.leg_plan;
  v_prim booking.leg_plan;
  v_plan booking.leg_plan[] := '{}';
  v_actor text;
  v_note text;
  v_today date;
  v_date date;
  v_horizon integer;
  v_n integer;
  v_rule bigint;
  v_sched boolean := false;
  v_start timestamptz;
  v_end timestamptz;
  v_old_start timestamptz;
  v_space bigint;
  v_mode text;
  v_pools bigint[];
  v_off integer;
  v_cmin integer;
  v_missing boolean := false;
  v_persons integer;
  v_total numeric;
  v_price_sig text;
  v_code text;
  v_msg text;
  v_ids bigint[];
  v_ss timestamptz[];
  v_es timestamptz[];
  v_i integer;
  v_cur timestamptz;
  v_allow_ob boolean := coalesce(p_allow_overbook, false);
begin
  perform booking._clear_staff_overrides();
  perform set_config('booking.svc_overbook', 'off', true);
  v_actor := coalesce(nullif(btrim(p_actor), ''), 'asiakaspalvelu-bot');
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  v_today := (now() at time zone booking._tz())::date;
  v_horizon := coalesce((booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int, 120);

  if p_order_no is null then
    perform booking._err('not_found', 'Tilausta ei löydy');
  end if;
  if v_note is null then
    perform booking._err('note_required', 'Anna syy (p_note)');
  end if;
  if p_new_start is null then
    perform booking._err('invalid_time', 'Anna uusi alkuaika');
  end if;
  if p_new_start <= now() then
    perform booking._err('not_in_future', 'Uuden vuoron pitää alkaa tulevaisuudessa');
  end if;
  v_date := (p_new_start at time zone booking._tz())::date;
  if v_date > v_today + v_horizon then
    perform booking._err('beyond_horizon', format('Uuden vuoron pitää olla enintään %s päivän päässä', v_horizon));
  end if;

  -- Lukitusjärjestys kuten hallinnan siirtoytimessä: ensin varaus, sitten tilaus (ei deadlockia).
  select * into o from booking.orders where order_no = p_order_no;
  if not found then
    perform booking._err('not_found', 'Tilausta ei löydy');
  end if;
  if o.status in ('cancelled', 'expired') then
    perform booking._err('order_cancelled', 'Peruttua tilausta ei voi siirtää');
  end if;
  if o.status <> 'confirmed' then
    perform booking._err('not_changeable', 'Vain vahvistetun tilauksen varauksen voi siirtää');
  end if;

  select count(*) into v_n
    from booking.reservations r
   where r.order_id = o.id
     and r.status = 'confirmed'
     and r.parent_reservation_id is null
     and r.hidden_at is null;
  if v_n = 0 then
    perform booking._err('no_reservation', 'Tilauksella ei ole vahvistettua varausta');
  end if;
  if v_n > 1 then
    perform booking._err('ambiguous_reservation', 'Tilauksella on useita vahvistettuja varauksia');
  end if;

  select * into res
    from booking.reservations r
   where r.order_id = o.id
     and r.status = 'confirmed'
     and r.parent_reservation_id is null
     and r.hidden_at is null
   for update;
  select * into o from booking.orders where id = o.id for update;
  if o.status <> 'confirmed' then
    perform booking._err('not_changeable', 'Vain vahvistetun tilauksen varauksen voi siirtää');
  end if;
  if res.checkin_at is not null then
    perform booking._err('already_checked_in', 'Sisäänkirjattua varausta ei voi siirtää');
  end if;
  if res.product_id is null then
    perform booking._err('slot_invalid', 'Varauksella ei ole tuotetta, joten julkaistua vuoroa ei voi ratkaista');
  end if;

  -- booking_245/246: ylibuukkaus vain yhteisvuoroihin; asetetaan ennen kapasiteettitarkistuksia
  if v_allow_ob then
    perform set_config('booking.allow_overbook', 'on', true);
    perform set_config('booking.svc_overbook', 'on', true);
  end if;

  select r.id into v_rule
    from booking.schedule_rules r
    join kb.products p on p.id = r.product_id and p.active
    join booking.product_config pc on pc.product_id = r.product_id
         and pc.bookable and pc.lifecycle = 'current'
   where r.active
     and r.product_id = res.product_id
     and extract(isodow from v_date)::smallint = any (r.weekdays)
     and (r.valid_from is null or v_date >= r.valid_from)
     and (r.valid_to is null or v_date <= r.valid_to)
     and date_trunc('minute', ((v_date + r.start_time) at time zone booking._tz()))
         = date_trunc('minute', p_new_start)
   order by (r.duration_minutes = (extract(epoch from (res.ends_at - res.starts_at)) / 60)::int) desc,
            (r.id is not distinct from res.rule_id) desc, r.sort_order, r.id
   limit 1;

  if v_rule is not null then
    begin
      select * into rs from booking._resolve_session(v_rule, v_date, res.persons, false);
      if rs.o_product_id is distinct from res.product_id then
        perform booking._err('product_mismatch', 'Varauksen voi siirtää vain saman tuotteen vuoroon');
      end if;
      v_sched := true;
      v_start := rs.o_starts_at;
      v_end := rs.o_ends_at;
      v_space := rs.o_space_id;
      v_mode := rs.o_mode;
      v_pools := coalesce(rs.o_pool_ids, '{}'::bigint[]);
      -- Hinta ei muutu siirrossa, joten vuoron kesto ja hinta eivät saa muuttua (esim. 2 h -> 7 h samalla hinnalla).
      if (v_end - v_start) is distinct from (res.ends_at - res.starts_at) then
        perform booking._err('duration_differs', 'Uuden vuoron kesto poikkeaa nykyisestä; siirrä hallinnan kautta');
      end if;
      if res.rule_id is not null and res.rule_id <> v_rule
         and (select pr.total from booking._rule_price(v_rule, res.persons) pr)
             is distinct from (select pr.total from booking._rule_price(res.rule_id, res.persons) pr) then
        perform booking._err('price_differs', 'Uuden vuoron hinta poikkeaa nykyisestä; siirrä hallinnan kautta');
      end if;
      -- Johku-tuonti (rule_id NULL): uuden säännön hinta näille henkilöille = varauksen tilausrivin nykyinen hinta.
      if res.rule_id is null
         and (select pr.total from booking._rule_price(v_rule, res.persons) pr)
             is distinct from (select i.line_total_gross from booking.order_items i where i.id = res.order_item_id) then
        perform booking._err('price_differs', 'Uuden vuoron hinta poikkeaa tilausrivin hinnasta; siirrä hallinnan kautta');
      end if;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_code = pg_exception_detail, v_msg = message_text;
      if v_code = 'no_session' then
        v_rule := null;
      elsif v_code in ('not_bookable', 'product_inactive', 'rule_not_found') then
        perform booking._err('slot_invalid', v_msg);
      else
        raise;
      end if;
    end;
  end if;

  if not v_sched then
    v_rule := null;
    v_start := date_trunc('minute', p_new_start);
    begin
      v_end := booking._treatment_slot_check(res.product_id, v_start, res.persons, false);
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_code = pg_exception_detail, v_msg = message_text;
      if v_code = 'too_far' then
        perform booking._err('beyond_horizon', v_msg);
      elsif v_code in ('bad_slot', 'ritual_start', 'time_window', 'not_offered_day', 'not_bookable', 'invalid_date', 'no_session') then
        perform booking._err('slot_invalid', v_msg);
      else
        raise;
      end if;
    end;
    -- booking_246: _treatment_slot_check → _clear_staff_overrides() nollaa allow_overbook.
    -- Palauta liput ennen _plan_legs / UPDATE (stamp tarvitsee _staff_overbook()).
    if v_allow_ob then
      perform set_config('booking.allow_overbook', 'on', true);
      perform set_config('booking.svc_overbook', 'on', true);
    end if;
    begin
      for lp in select * from booking._plan_legs(res.product_id, v_start, v_end, res.persons, null, false, res.id) loop
        v_plan := array_append(v_plan, lp);
      end loop;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_code = pg_exception_detail, v_msg = message_text;
      if v_code = 'no_therapist' then
        v_missing := true;
        v_plan := '{}';
        for lp in select * from booking._plan_legs(res.product_id, v_start, v_end, res.persons, null, false, res.id, true) loop
          v_plan := array_append(v_plan, lp);
        end loop;
      elsif v_code in ('private_booked', 'public_shift_booked', 'space_busy', 'capacity_exceeded') then
        perform booking._err('slot_taken', v_msg);
      elsif v_code = 'not_resourced' then
        perform booking._err('slot_invalid', v_msg);
      else
        raise;
      end if;
    end;
    select * into v_prim from unnest(v_plan) u where u.leg_no = 1 and u.role = 'space';
    if v_prim.resource_id is null then
      perform booking._err('slot_invalid', 'Tuotteelta puuttuu julkaistu tila tälle ajalle');
    end if;
    v_space := v_prim.resource_id;
    v_mode := v_prim.mode;
    v_pools := case when v_prim.pool_id is null then '{}'::bigint[] else array[v_prim.pool_id] end;
    v_off := (extract(epoch from (v_prim.claim_start - v_start)) / 60)::int;
    v_cmin := case when v_prim.claim_end >= v_end then null else (extract(epoch from (v_prim.claim_end - v_prim.claim_start)) / 60)::int end;
    if v_mode = 'exclusive' and (v_off <> 0 or v_cmin is not null) then
      perform booking._err('slot_invalid', 'Yksinoikeusvarauksen aikaikkuna on koko varaus');
    end if;
  end if;

  if v_start <= now() then
    perform booking._err('not_in_future', 'Uuden vuoron pitää alkaa tulevaisuudessa');
  end if;
  if date_trunc('minute', v_start) = date_trunc('minute', res.starts_at) then
    perform booking._err('no_change', 'Varaus on jo tällä alkamisajalla');
  end if;

  if v_sched then
    if exists (
      select 1 from booking.space_blocks b
       where b.active and b.space_id = v_space
         and b.during && tstzrange(v_start, v_end, '[)')
    ) then
      perform booking._err('space_closed', 'Aika ei ole varattavissa (tila suljettu)');
    end if;
    if exists (
      select 1
        from booking.reservation_legs l
        join booking.space_blocks b on b.active and b.space_id = l.resource_id
         and b.during && tstzrange(
               v_start + make_interval(mins => l.offset_min),
               case when l.minutes is null then v_end else v_start + make_interval(mins => l.offset_min + l.minutes) end,
               '[)')
       where l.reservation_id = res.id and l.role = 'therapist'
    ) then
      perform booking._err('therapist_closed', 'Saunottajat eivät ole saatavilla tälle ajalle (hoidot kiinni)');
    end if;
  end if;

  v_old_start := res.starts_at;
  v_persons := res.persons;
  v_total := o.total_gross;
  select md5(coalesce(string_agg(i.id::text || ':' || i.unit_price_gross::text || ':' || i.line_total_gross::text, ',' order by i.id), ''))
    into v_price_sig
    from booking.order_items i
   where i.order_id = o.id;
  select coalesce(array_agg(c.id order by c.id), '{}'::bigint[]),
         coalesce(array_agg(c.starts_at order by c.id), '{}'::timestamptz[]),
         coalesce(array_agg(c.ends_at order by c.id), '{}'::timestamptz[])
    into v_ids, v_ss, v_es
    from booking.reservations c
   where c.parent_reservation_id = res.id
     and c.status in ('pending', 'confirmed')
     and c.hidden_at is null;

  if not v_sched then
    delete from booking.reservation_legs where reservation_id = res.id;
  end if;

  begin
    -- booking_245: älä nollaa overbooked/overbooked_by/override_reason.
    -- reservations_stamp_overrides asettaa overbooked=true kun _staff_overbook();
    -- jos vanha oli overbooked eikä lippua, arvo säilyy (kuten hallinnan siirto).
    update booking.reservations set
      rule_id = v_rule,
      space_id = v_space,
      mode = v_mode,
      starts_at = v_start,
      ends_at = v_end,
      pool_ids = v_pools,
      claim_offset_min = case when v_sched then claim_offset_min else v_off end,
      claim_minutes = case when v_sched then claim_minutes else v_cmin end,
      therapist_missing = case when v_sched then therapist_missing else v_missing end,
      therapist_exception_at = case when v_sched or v_missing then therapist_exception_at end,
      therapist_exception_by = case when v_sched or v_missing then therapist_exception_by end,
      therapist_exception_note = case when v_sched or v_missing then therapist_exception_note end,
      off_schedule = false,
      off_schedule_by = null
     where id = res.id
    returning * into res;

    if not v_sched then
      for lp in select * from unnest(v_plan) u where not (u.leg_no = 1 and u.role = 'space') order by u.leg_no loop
        insert into booking.reservation_legs(
          reservation_id, resource_id, role, mode, starts_at, ends_at, offset_min, minutes, persons,
          pool_ids, skill, session_key, quota_exempt, rule_id)
        values (
          res.id, lp.resource_id, lp.role, lp.mode, lp.claim_start, lp.claim_end, lp.offset_min, lp.minutes, lp.persons,
          case when lp.pool_id is null then '{}'::bigint[] else array[lp.pool_id] end,
          lp.skill, lp.session_key, res.quota_exempt, lp.rule_id);
      end loop;
    end if;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_code = pg_exception_detail, v_msg = message_text;
    if v_code in ('private_booked', 'public_shift_booked', 'space_busy', 'capacity_exceeded') then
      perform booking._err('slot_taken', v_msg);
    else
      raise;
    end if;
  end;

  perform booking._clear_staff_overrides();
  perform set_config('booking.svc_overbook', 'off', true);

  if v_ids is not null then
    for v_i in 1 .. cardinality(v_ids) loop
      select c.starts_at into v_cur from booking.reservations c where c.id = v_ids[v_i];
      if v_cur is not distinct from v_ss[v_i] then
        update booking.reservations
           set starts_at = v_ss[v_i] + (v_start - v_old_start),
               ends_at = v_es[v_i] + (v_start - v_old_start)
         where id = v_ids[v_i]
           and status in ('pending', 'confirmed')
           and hidden_at is null;
      end if;
    end loop;
  end if;

  if (select x.persons from booking.reservations x where x.id = res.id) is distinct from v_persons
     or (select x.total_gross from booking.orders x where x.id = o.id) is distinct from v_total
     or (select md5(coalesce(string_agg(i.id::text || ':' || i.unit_price_gross::text || ':' || i.line_total_gross::text, ',' order by i.id), ''))
           from booking.order_items i where i.order_id = o.id) is distinct from v_price_sig then
    perform booking._err('price_changed', 'Siirto olisi muuttanut hintaa tai henkilömäärää');
  end if;

  if v_allow_ob then
    update booking.orders
       set internal_note = concat_ws(E'\n', internal_note,
             to_char(now() at time zone booking._tz(), 'YYYY-MM-DD HH24:MI') || ' ' || v_actor || ': ' || v_note
               || ' [YLIBUUKKAUS (Joonaksen pyynnöstä)]')
     where id = o.id;
  end if;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (
    auth.uid(),
    coalesce(booking._jwt_role(), 'service_role'),
    'reservations',
    res.id::text,
    'SVC_MOVE_RESERVATION',
    jsonb_build_object('order_no', o.order_no, 'starts_at', v_old_start, 'persons', v_persons, 'total', v_total),
    jsonb_build_object(
      'order_no', o.order_no, 'starts_at', res.starts_at, 'ends_at', res.ends_at,
      'persons', res.persons, 'total', v_total, 'rule_id', res.rule_id,
      'allow_overbook', v_allow_ob, 'overbooked', res.overbooked,
      'note', v_note, 'actor', v_actor)
  );

  return jsonb_build_object(
    'ok', true,
    'order_no', o.order_no,
    'old_starts_at', v_old_start,
    'new_starts_at', res.starts_at,
    'ends_at', res.ends_at,
    'persons', res.persons,
    'total', v_total,
    'allow_overbook', v_allow_ob,
    'overbooked', res.overbooked
  );
end
$function$;

CREATE OR REPLACE FUNCTION booking.svc_move_reservation_to_rule(p_order_no bigint, p_reservation_id bigint, p_rule_id bigint, p_starts_at timestamp with time zone, p_note text, p_requested_by text, p_actor text DEFAULT 'Asiakaspalvelu'::text, p_preview boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders;
  res booking.reservations;
  rs record;
  v_actor text;
  v_note text;
  v_req text;
  v_preview boolean := coalesce(p_preview, true);
  v_today date;
  v_date date;
  v_horizon integer;
  v_code text;
  v_msg text;
  v_pools bigint[];
  v_sess text;
  v_total numeric;
  v_price_sig text;
  v_item booking.order_items;
  v_old_prod_name text;
  v_new_prod_name text;
  v_old_rule_label text;
  v_new_rule_label text;
  v_target_price numeric;
  v_line text;
  v_old jsonb;
  v_plan jsonb;
begin
  perform booking._clear_staff_overrides();
  perform set_config('booking.svc_overbook', 'off', true);
  v_actor := coalesce(nullif(btrim(p_actor), ''), 'Asiakaspalvelu');
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  v_req := nullif(btrim(coalesce(p_requested_by, '')), '');
  v_today := (now() at time zone booking._tz())::date;
  v_horizon := coalesce((booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int, 120);

  if p_order_no is null then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if p_reservation_id is null then perform booking._err('no_reservation', 'Anna varauksen id (p_reservation_id)'); end if;
  if p_rule_id is null then perform booking._err('rule_not_found', 'Anna kohdesääntö (p_rule_id)'); end if;
  if p_starts_at is null then perform booking._err('invalid_time', 'Anna kohdesession alkuaika (p_starts_at)'); end if;
  if v_note is null then perform booking._err('note_required', 'Anna syy (p_note)'); end if;
  if v_req is null then perform booking._err('requested_by_required', 'Anna pyytäjän/hyväksyjän viite (p_requested_by)'); end if;
  if p_starts_at <= now() then perform booking._err('not_in_future', 'Kohdevuoron pitää alkaa tulevaisuudessa'); end if;
  v_date := (p_starts_at at time zone booking._tz())::date;
  if v_date > v_today + v_horizon then
    perform booking._err('beyond_horizon', format('Kohdevuoron pitää olla enintään %s päivän päässä', v_horizon));
  end if;

  select * into o from booking.orders where order_no = p_order_no;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;

  -- Lukitusjärjestys kuten svc_move_reservation: ensin varaus, sitten tilaus.
  select * into res from booking.reservations r where r.id = p_reservation_id for update;
  if not found or res.order_id is distinct from o.id then
    perform booking._err('reservation_not_in_order', 'Varaus ei kuulu tälle tilaukselle');
  end if;
  select * into o from booking.orders where id = o.id for update;

  if o.status in ('cancelled', 'expired') then
    perform booking._err('order_cancelled', 'Peruttua tilausta ei voi siirtää');
  end if;
  if not (o.status = 'confirmed' or o.payment_status = 'paid') then
    perform booking._err('not_changeable', 'Vain vahvistetun tai maksetun tilauksen varauksen voi siirtää');
  end if;
  if res.status <> 'confirmed' or res.hidden_at is not null then
    perform booking._err('not_changeable', 'Vain vahvistetun (näkyvän) varauksen voi siirtää');
  end if;
  if res.parent_reservation_id is not null then
    perform booking._err('unsupported', 'Lisäpalveluvarausta ei voi siirtää tällä toiminnolla');
  end if;
  if res.checkin_at is not null then
    perform booking._err('already_checked_in', 'Sisäänkirjattua varausta ei voi siirtää');
  end if;
  if res.annual_card_id is not null then
    perform booking._err('unsupported', 'Vuosikorttivarausta ei siirretä tällä toiminnolla (hinta lasketaan säännöstä)');
  end if;
  if res.product_option_id is not null then
    perform booking._err('unsupported', 'Varauksella on tuotevalinta; siirrä hallinnan kautta');
  end if;
  if exists (select 1 from booking.reservation_legs l where l.reservation_id = res.id) then
    perform booking._err('unsupported', 'Varauksella on resurssilegejä (hoito/rituaali); siirrä hallinnan kautta');
  end if;
  if exists (select 1 from booking.reservations c where c.parent_reservation_id = res.id
              and c.status in ('pending', 'confirmed') and c.hidden_at is null) then
    perform booking._err('unsupported', 'Varaukseen liittyy lisäpalveluvarauksia; siirrä hallinnan kautta');
  end if;

  -- Kohdesessio: säännön pitää olla aktiivinen ja p_starts_at oikea session alku (sama logiikka kuin svc_move_reservation).
  begin
    select * into rs from booking._resolve_session(p_rule_id, v_date, res.persons, false);
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_code = pg_exception_detail, v_msg = message_text;
    if v_code in ('no_session', 'not_bookable', 'product_inactive', 'rule_not_found', 'sale_closed') then
      perform booking._err('slot_invalid', v_msg);
    else
      raise;
    end if;
  end;
  if date_trunc('minute', rs.o_starts_at) <> date_trunc('minute', p_starts_at) then
    perform booking._err('slot_invalid', format('Säännön %s sessio alkaa %s, ei %s', p_rule_id,
      to_char(rs.o_starts_at at time zone booking._tz(), 'YYYY-MM-DD HH24:MI'),
      to_char(p_starts_at at time zone booking._tz(), 'YYYY-MM-DD HH24:MI')));
  end if;
  if exists (select 1 from booking.product_space_rules psr where psr.product_id = rs.o_product_id and psr.active and psr.leg_no > 1)
     or exists (select 1 from booking.product_config pc where pc.product_id = rs.o_product_id and pc.required_skill is not null) then
    perform booking._err('unsupported', 'Kohdetuote vaatii lisäresursseja (legit/saunottaja); siirrä hallinnan kautta');
  end if;
  if rs.o_rule_id = res.rule_id and date_trunc('minute', rs.o_starts_at) = date_trunc('minute', res.starts_at) then
    perform booking._err('no_change', 'Varaus on jo tässä sessiossa');
  end if;

  v_pools := coalesce(rs.o_pool_ids, '{}'::bigint[]);
  v_sess := booking._session_key(v_pools, rs.o_mode, rs.o_starts_at);
  v_total := o.total_gross;
  select md5(coalesce(string_agg(i.id::text || ':' || coalesce(i.product_id::text, '') || ':' || coalesce(i.product_name, '') || ':'
                                 || i.unit_price_gross::text || ':' || i.line_total_gross::text || ':' || coalesce(i.vat_rate::text, '')
                                 || ':' || coalesce(i.line_vat::text, ''), ',' order by i.id), ''))
    into v_price_sig from booking.order_items i where i.order_id = o.id;
  select * into v_item from booking.order_items i where i.id = res.order_item_id;
  select p.name into v_old_prod_name from kb.products p where p.id = res.product_id;
  select p.name into v_new_prod_name from kb.products p where p.id = rs.o_product_id;
  select r.label into v_old_rule_label from booking.schedule_rules r where r.id = res.rule_id;
  select r.label into v_new_rule_label from booking.schedule_rules r where r.id = rs.o_rule_id;
  begin
    select pr.total into v_target_price from booking._rule_price(rs.o_rule_id, res.persons) pr;
  exception when others then v_target_price := null;
  end;

  v_old := jsonb_build_object('product_id', res.product_id, 'product_name', v_old_prod_name, 'rule_id', res.rule_id,
            'rule_label', v_old_rule_label, 'space_id', res.space_id, 'mode', res.mode, 'pool_ids', res.pool_ids,
            'starts_at', res.starts_at, 'ends_at', res.ends_at, 'persons', res.persons);
  v_plan := jsonb_build_object(
    'order_no', o.order_no, 'reservation_id', res.id, 'order_status', o.status, 'payment_status', o.payment_status,
    'old', v_old,
    'new', jsonb_build_object('product_id', rs.o_product_id, 'product_name', v_new_prod_name, 'rule_id', rs.o_rule_id,
            'rule_label', v_new_rule_label, 'space_id', rs.o_space_id, 'mode', rs.o_mode, 'pool_ids', v_pools,
            'starts_at', rs.o_starts_at, 'ends_at', rs.o_ends_at, 'persons', res.persons),
    'order_total_unchanged', v_total,
    'order_item', case when v_item.id is null then null else jsonb_build_object('id', v_item.id, 'product_id', v_item.product_id,
            'product_name', v_item.product_name, 'line_total_gross', v_item.line_total_gross, 'action', 'ennallaan (ei muutosta)') end,
    'target_rule_price_info', v_target_price,
    'no_payment_link', true, 'no_refund', true, 'no_customer_message', true,
    'requested_by', v_req, 'note', v_note, 'actor', v_actor);

  -- Sulku, päällekkäisyys ja poolikapasiteetti kohdesessiolle samalla logiikalla kuin reservations_validate.
  begin
    if booking._rule_closure_exempt(rs.o_rule_id, rs.o_space_id) then
      if res.override_reason is null and exists (
           select 1 from booking.space_blocks b where b.active and b.space_id = rs.o_space_id
              and b.during && tstzrange(rs.o_starts_at, rs.o_ends_at, '[)')
              and b.closure_event_id is null and not booking._event_block_is_own(b.event_block_id, res.id, v_pools)) then
        perform booking._err('space_closed', 'Aika ei ole varattavissa (tila suljettu)');
      end if;
    else
      perform booking._check_claim(res.id, null, rs.o_space_id, 'space', rs.o_mode, rs.o_starts_at, rs.o_ends_at, res.persons,
                                   v_pools, null, v_sess, res.quota_exempt, (res.override_reason is not null), 'blocks');
    end if;
    perform booking._check_claim(res.id, null, rs.o_space_id, 'space', rs.o_mode, rs.o_starts_at, rs.o_ends_at, res.persons,
                                 v_pools, null, v_sess, res.quota_exempt, (res.override_reason is not null), 'rest');
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_code = pg_exception_detail, v_msg = message_text;
    if v_preview then
      return jsonb_build_object('ok', false, 'preview', true, 'error_code', v_code, 'message', v_msg, 'plan', v_plan);
    end if;
    if v_code in ('private_booked', 'public_shift_booked', 'space_busy', 'capacity_exceeded') then
      perform booking._err('slot_taken', v_msg);
    end if;
    raise;
  end;

  if v_preview then
    return jsonb_build_object('ok', true, 'preview', true, 'plan', v_plan);
  end if;

  begin
    update booking.reservations set
      product_id = rs.o_product_id,
      rule_id = rs.o_rule_id,
      space_id = rs.o_space_id,
      mode = rs.o_mode,
      starts_at = rs.o_starts_at,
      ends_at = rs.o_ends_at,
      pool_ids = v_pools,
      claim_offset_min = 0,
      claim_minutes = null,
      off_schedule = false,
      off_schedule_by = null
     where id = res.id
    returning * into res;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_code = pg_exception_detail, v_msg = message_text;
    if v_code in ('private_booked', 'public_shift_booked', 'space_busy', 'capacity_exceeded') then
      perform booking._err('slot_taken', v_msg);
    end if;
    raise;
  end;

  perform booking._clear_staff_overrides();
  perform set_config('booking.svc_overbook', 'off', true);

  if (select x.total_gross from booking.orders x where x.id = o.id) is distinct from v_total
     or (select md5(coalesce(string_agg(i.id::text || ':' || coalesce(i.product_id::text, '') || ':' || coalesce(i.product_name, '') || ':'
                                 || i.unit_price_gross::text || ':' || i.line_total_gross::text || ':' || coalesce(i.vat_rate::text, '')
                                 || ':' || coalesce(i.line_vat::text, ''), ',' order by i.id), ''))
           from booking.order_items i where i.order_id = o.id) is distinct from v_price_sig then
    perform booking._err('price_changed', 'Siirto olisi muuttanut tilauksen summaa tai rivejä');
  end if;

  v_line := to_char(now() at time zone booking._tz(), 'YYYY-MM-DD HH24:MI') || ' ' || v_actor
    || ': varaus ' || res.id || ' siirretty ' || coalesce(v_old_prod_name, '?') || ' (sääntö ' || coalesce((v_old->>'rule_id'), '-') || ', '
    || to_char((v_old->>'starts_at')::timestamptz at time zone booking._tz(), 'DD.MM.YYYY HH24:MI') || ') -> '
    || coalesce(v_new_prod_name, '?') || ' (sääntö ' || rs.o_rule_id || ', '
    || to_char(rs.o_starts_at at time zone booking._tz(), 'DD.MM.YYYY HH24:MI') || '–' || to_char(rs.o_ends_at at time zone booking._tz(), 'HH24:MI')
    || '). Hinta ja tilausrivit ennallaan'
    || case when v_item.id is not null then ' (rivi ' || v_item.id || ' "' || coalesce(v_item.product_name, '') || '" jätetty ennalleen)' else '' end
    || '. Pyytäjä: ' || v_req || '. Syy: ' || v_note;
  update booking.orders set internal_note = concat_ws(E'\n', internal_note, v_line) where id = o.id;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), coalesce(booking._jwt_role(), 'service_role'), 'reservations', res.id::text,
          'SVC_MOVE_RESERVATION_TO_RULE',
          v_old || jsonb_build_object('order_no', o.order_no, 'total', v_total),
          jsonb_build_object('order_no', o.order_no, 'product_id', res.product_id, 'rule_id', res.rule_id, 'space_id', res.space_id,
            'mode', res.mode, 'pool_ids', res.pool_ids, 'starts_at', res.starts_at, 'ends_at', res.ends_at, 'persons', res.persons,
            'total', v_total, 'order_item_unchanged', v_item.id, 'requested_by', v_req, 'note', v_note, 'actor', v_actor));

  return jsonb_build_object('ok', true, 'preview', false, 'plan', v_plan,
    'result', jsonb_build_object('product_id', res.product_id, 'rule_id', res.rule_id, 'starts_at', res.starts_at,
      'ends_at', res.ends_at, 'pool_ids', res.pool_ids, 'total', v_total));
end
$function$;

CREATE OR REPLACE FUNCTION booking.admin_cancel_reservation(p_reservation_id bigint, p_reason text DEFAULT NULL::text, p_refund boolean DEFAULT false, p_refund_reason text DEFAULT NULL::text, p_gift_card_keep boolean DEFAULT NULL::boolean, p_notify boolean DEFAULT NULL::boolean, p_refund_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r booking.reservations; v_plan jsonb; x jsonb; v_res jsonb; v_out jsonb := '[]'::jsonb; v_total numeric := 0; v_reason text;
        v_gc jsonb := '[]'::jsonb; v_gc_out jsonb := '[]'::jsonb; g booking.gift_cards; v_rid bigint; v_kept_order boolean; v_partner numeric := 0;
        v_action uuid; v_notified boolean := false;
        v_refund boolean := coalesce(p_refund, false) or p_refund_amount is not null; v_left numeric; v_take numeric; v_rem numeric; v_c numeric; v_tl jsonb; v_ln jsonb; v_amt numeric; v_pid bigint; v_prov text;
begin
  perform booking._require_permission('bookings.manage');
  if v_refund then perform booking._require_permission('payments.refund'); end if;
  if p_refund_amount is not null then   -- booking_283: osittainen hyvitys (Hyvitä osa)
    if not booking._flag_on('partial_refunds_enabled') then perform booking._err('partial_refunds_disabled', 'Osahyvitys ei ole käytössä'); end if;
    if p_refund_amount < 0.05 or p_refund_amount <> round(p_refund_amount, 2) then perform booking._err('invalid_amount', 'Hyvityksen vähimmäissumma on 0,05 €'); end if;
  end if;
  select * into r from booking.reservations where id = p_reservation_id;
  if found then perform 1 from booking.orders where id = r.order_id for update; end if;   -- lukitusjärjestys: tilaus ensin (kuten muut hyvitysreitit)
  select * into r from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if r.status not in ('pending','confirmed') then perform booking._err('invalid_status', 'Vain voimassa olevan varauksen voi perua'); end if;
  if v_refund and booking._order_invoice_locked(r.order_id) then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  v_plan := booking._reservation_refund_plan(r.id);   -- ennen peruutusta (rivit eivät muutu)
  -- booking_280: lahjakorttiosuus (rahaa ei koskaan hyvitetä) → pakollinen valinta "jätetäänkö koodi voimaan"
  select coalesce(jsonb_agg(e), '[]'::jsonb) into v_gc from jsonb_array_elements(coalesce(v_plan -> 'payments', '[]'::jsonb)) e where coalesce((e ->> 'gift_card')::boolean, false);
  select coalesce(sum((e ->> 'amount')::numeric), 0) into v_partner from jsonb_array_elements(coalesce(v_plan -> 'payments', '[]'::jsonb)) e
   where e ->> 'method' = 'partner_voucher' or e ->> 'method' like 'partner\_voucher\_%';
  if jsonb_array_length(v_gc) > 0 and p_gift_card_keep is null then
    perform booking._err('gift_card_keep_required', 'Varaus on maksettu lahjakortilla: valitse, jätetäänkö lahjakorttikoodi voimaan');
  end if;
  if jsonb_array_length(v_gc) > 0 and p_gift_card_keep and booking._order_invoice_locked(r.order_id) then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  if jsonb_array_length(v_gc) > 0 and p_gift_card_keep then
    for x in select * from jsonb_array_elements(v_gc) loop
      select gc.* into g from booking.gift_cards gc join booking.payments p on p.gift_card_id = gc.id where p.id = (x ->> 'payment_id')::bigint;
      if not booking._gc_keep_allowed(g) then
        perform booking._err('gift_card_expired', 'Lahjakortti ei ole enää voimassa: koodia ei voi jättää voimaan');
      end if;
    end loop;
  end if;
  perform booking.admin_set_reservation_status(r.id, 'cancelled', coalesce(nullif(btrim(p_reason), ''), 'henkilökunta'));
  for x in select * from jsonb_array_elements(v_gc) loop
    if p_gift_card_keep then
      v_rid := booking._gc_return_to_card((x ->> 'payment_id')::bigint, (x ->> 'amount')::numeric, x -> 'lines',
                 'Varauksen peruutus, koodi jätetty voimaan (varaus #' || r.id || ')', r.id);
      v_gc_out := v_gc_out || jsonb_build_object('payment_id', (x ->> 'payment_id')::bigint, 'amount', (x ->> 'amount')::numeric, 'action', 'returned', 'refund_id', v_rid);
    else
      perform booking._gc_forfeit_on_cancel((x ->> 'payment_id')::bigint, (x ->> 'amount')::numeric, r.id, 'Varauksen peruutus, koodi ei jäänyt voimaan');
      v_gc_out := v_gc_out || jsonb_build_object('payment_id', (x ->> 'payment_id')::bigint, 'amount', (x ->> 'amount')::numeric, 'action', 'forfeited');
    end if;
  end loop;
  if v_refund then
    v_reason := coalesce(nullif(btrim(p_refund_reason), ''), 'Varauksen peruutus (varaus #' || r.id || ')');
    v_left := p_refund_amount;
    for x in select * from jsonb_array_elements(v_plan -> 'payments') e
              where not coalesce((e ->> 'gift_card')::boolean, false)
                and not (e ->> 'method' = 'partner_voucher' or e ->> 'method' like 'partner\_voucher\_%')
              order by (e ->> 'provider' <> 'manual') desc, (e ->> 'payment_id')::bigint loop
      v_pid := (x ->> 'payment_id')::bigint; v_prov := x ->> 'provider'; v_amt := (x ->> 'amount')::numeric; v_ln := x -> 'lines';
      if p_refund_amount is not null then   -- osasumma: verkkomaksut ensin, rivit leikataan summaan
        exit when v_left <= 0.004;
        v_take := least(v_left, v_amt);
        if v_prov <> 'manual' and v_take < 0.05 then continue; end if;
        v_tl := '[]'::jsonb; v_rem := v_take;
        v_tl := (select coalesce(jsonb_agg(jsonb_build_object('payment_line_id', t.pl, 'amount', t.take) order by t.ord), '[]'::jsonb) from (
                   select l.ord, l.pl, least(l.amt, greatest(v_take - coalesce(sum(l.amt) over (order by l.ord rows between unbounded preceding and 1 preceding), 0), 0)) as take
                     from (select ord, (e2 ->> 'payment_line_id')::bigint as pl, (e2 ->> 'amount')::numeric as amt from jsonb_array_elements(v_ln) with ordinality as w(e2, ord)) l) t where t.take > 0.004);
        v_amt := v_take; v_ln := v_tl; v_left := v_left - v_take;
      end if;
      v_res := booking.admin_refund(v_pid, v_amt, v_reason, v_ln, false);
      v_out := v_out || jsonb_build_object('payment_id', v_pid, 'provider', v_prov, 'amount', v_amt,
        'refund_id', v_res -> 'refund_id', 'status', v_res ->> 'status', 'receipt_no', v_res -> 'receipt_no');
      v_total := v_total + v_amt;
    end loop;
    if p_refund_amount is not null and v_left > 0.004 then
      perform booking._err('amount_exceeds_refundable', format('Hyvitettävissä enintään %s €', p_refund_amount - v_left));
    end if;
  end if;
  v_kept_order := booking._order_voucher_redeemed(r.order_id)
                  and not exists (select 1 from booking.reservations y where y.order_id = r.order_id and y.status in ('pending','confirmed'));
  -- booking_281 (Joonas 11.11.2026 18.12): p_notify = true → yksi reservation_cancelled-viesti HETI (peruutus + "hyvitys käsittelyssä"
  -- + lahjakortin/kumppanilunastuksen tila). Hyvityskuitti lähtee erikseen nykyisellä refund_receipt-polulla, kun hyvitys on vahvistettu
  -- (manuaalinen heti; Montonio montonio_refund_complete → _on_refund_done). p_notify null/false → ei peruutusviestiä.
  if p_notify then
    v_action := gen_random_uuid();
    v_notified := booking._enqueue_reservation_cancelled(r.order_id, v_action, array[r.id], v_out, v_gc_out, v_kept_order);
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'reservations', r.id::text, 'ADMIN_CANCEL_RESERVATION', jsonb_build_object('status', r.status),
          jsonb_build_object('status', 'cancelled', 'refund', v_refund, 'refund_amount', p_refund_amount, 'refunded_total', v_total,
                             'gift_card_keep', p_gift_card_keep, 'gift_card', v_gc_out, 'partner_share', v_partner, 'order_kept_voucher', v_kept_order,
                             'notify', p_notify, 'notified', v_notified, 'action_id', v_action));
  return jsonb_build_object('ok', true, 'cancelled', true, 'order_id', r.order_id, 'refunds', v_out, 'refunded_total', v_total,
    'gift_card', v_gc_out, 'partner_share', v_partner, 'order_kept', v_kept_order,
    'notified', v_notified, 'action_id', v_action,
    'balance', booking._order_balance(r.order_id));
end $function$;

revoke all on function booking._customer_move_blocked(bigint) from public, anon, authenticated;
delete from booking.settings where key = 'customer_move_min_days_private';
do $post$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking._customer_move_blocked(bigint)')));
  if v is distinct from '2fcb4371db01999e785df9600824e843' then raise exception 'booking_308 ROLLBACK: _customer_move_blocked md5 % ei palautunut', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._reduce_eval(bigint,bigint,bigint,date,integer)')));
  if v is distinct from '8ed770ad0468fbecff25fd813c9d8569' then raise exception 'booking_308 ROLLBACK: _reduce_eval md5 % ei palautunut', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_change_preview(uuid,bigint,date,integer)')));
  if v is distinct from '2efbd04181c9bd0636437744ec8f6951' then raise exception 'booking_308 ROLLBACK: public_change_preview md5 % ei palautunut', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._change_booking_core(bigint,bigint,date,integer,boolean,integer,uuid,text,boolean)')));
  if v is distinct from '504c78b9b12347c053d6131d15bc52b9' then raise exception 'booking_308 ROLLBACK: _change_booking_core md5 % ei palautunut', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_change_booking(uuid,bigint,date,integer,numeric)')));
  if v is distinct from '37df9bf5b88f4e2fa49476a8d0181806' then raise exception 'booking_308 ROLLBACK: public_change_booking md5 % ei palautunut', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.svc_move_reservation(bigint,timestamptz,text,text,boolean)')));
  if v is distinct from '158f8fc14c087f78f1a4b04b9933eca4' then raise exception 'booking_308 ROLLBACK: svc_move_reservation md5 % ei palautunut', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.svc_move_reservation_to_rule(bigint,bigint,bigint,timestamptz,text,text,text,boolean)')));
  if v is distinct from '814043d9006bd9c84065f58feaa965c9' then raise exception 'booking_308 ROLLBACK: svc_move_reservation_to_rule md5 % ei palautunut', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_cancel_reservation(bigint,text,boolean,text,boolean,boolean,numeric)')));
  if v is distinct from 'e3f801fef6332eb5bb110a8efb10efd1' then raise exception 'booking_308 ROLLBACK: admin_cancel_reservation md5 % ei palautunut', v; end if;
end $post$;
notify pgrst, 'reload schema';
