-- Rollback booking_57_pay_later_test: palauttaa maksuvaihtoehtofunktiot booking_53/49-versioihin ja poistaa pay_later-RPC:n ja lipun.
-- (Jo vahvistetut pay_later-tilaukset jäävät vahvistetuiksi: tämä on tavallinen vahvistettu maksamaton tilaus.)
set local lock_timeout = '5s';
drop function if exists booking.public_confirm_pay_later(uuid);
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
  return jsonb_build_object('ok', true, 'methods', v_m, 'mobilepay_enabled', v_mp <> 'off', 'gift_card_redeem_enabled', v_gc,
    'hold_until_paid', (booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}') <> 'pay_later', 'hold_minutes', booking._checkout_hold_minutes(),
    'group_threshold_persons', booking._checkout_cfg_int('checkout_group_threshold_persons', 0, 0, 1000), 'group_hold_days', booking._checkout_cfg_int('checkout_group_hold_days', 7, 1, 60));
end $function$;

CREATE OR REPLACE FUNCTION booking.public_payment_options(p_token uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_mode text := booking._mobilepay_mode(); o booking.orders; v_unpaid numeric; v_can boolean := false; v_methods jsonb := '[]'::jsonb; v_order jsonb := null; v_pending boolean := false;
begin
  if v_mode <> 'off' then
    v_methods := jsonb_build_array(jsonb_build_object('code', 'mobilepay', 'provider', 'vipps_mobilepay', 'label', 'MobilePay', 'label_en', 'MobilePay', 'test', v_mode = 'test',
      'start', jsonb_build_object('function', 'mobilepay-start', 'method', 'POST', 'body', case when p_token is not null then jsonb_build_object('order_token', p_token) else '{}'::jsonb end)));
  end if;
  if p_token is not null then
    if not booking._order_rl('popt', p_token, 120, 60) then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
    select * into o from booking.orders where public_token = p_token;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    v_can := v_mode <> 'off' and o.external_source is null and o.status in ('pending', 'confirmed', 'completed', 'expired') and o.currency = 'EUR' and v_unpaid > 0.004 and not (o.status = 'pending' and o.hold_kind = 'preliminary');
    v_pending := exists (select 1 from booking.payments where order_id = o.id and provider = 'mobilepay' and status = 'pending' and (link_expires_at is null or link_expires_at > now()));
    v_order := jsonb_build_object('order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'unpaid', v_unpaid, 'can_pay_online', v_can, 'mobilepay_pending', v_pending) || booking._checkout_state_json(o.id);
    if not v_can then v_methods := '[]'::jsonb; end if;
  end if;
  return jsonb_build_object('ok', true, 'online_enabled', v_mode <> 'off', 'methods', v_methods, 'order', v_order);
end $function$;

drop function if exists booking._pay_later_method_json();
drop function if exists booking._pay_later_test_enabled();
delete from booking.settings where key = 'pay_later_test_enabled';
