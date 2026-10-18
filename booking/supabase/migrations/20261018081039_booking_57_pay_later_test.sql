-- ============================================================
-- booking_57_pay_later_test: "Maksa myöhemmin" (TESTI) kassan pitotilassa
-- Koodarin sopimus (18.10.2026). RPC booking.public_confirm_pay_later(p_order_token uuid): odottava (pending/awaiting_payment) tilaus
-- vahvistetaan maksamattomana: pito poistuu, paikka säilyy, lahjakorttiosuus säilyy käytettynä, normaali vahvistussähköposti jonoon.
-- Toimii VAIN kun booking.settings 'pay_later_test_enabled' = true (oletus false; tämä migraatio EI laita päälle).
-- Lisäksi public_checkout_payment_options() ja public_payment_options() listaavat {code:'pay_later', test:true, enabled:true} vain kun lippu päällä.
-- Sopimus: docs/KOODARI_talous_A_D_fi.md §17.10. Rollback: rollbacks/CHECKOUT_booking_57_ROLLBACK.sql
-- ============================================================
set local lock_timeout = '5s';

insert into booking.settings(key, value, description, is_public) values
  ('pay_later_test_enabled', 'false'::jsonb, 'TESTI: salli kassassa "maksa myöhemmin" (public_confirm_pay_later): odottava varaus vahvistetaan maksamattomana. Oletus false', false)
on conflict (key) do nothing;

create or replace function booking._pay_later_test_enabled() returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(booking._setting('pay_later_test_enabled', 'false'::jsonb) = 'true'::jsonb, false)
$$;
create or replace function booking._pay_later_method_json() returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object('code', 'pay_later', 'kind', 'later', 'provider', 'manual', 'label', 'Maksa myöhemmin (testi)', 'label_en', 'Pay later (test)',
                            'test', true, 'enabled', true, 'confirm_rpc', 'public_confirm_pay_later')
$$;

-- huom: ok:false-virheet palautetaan kuten muissa public_*-RPC:issä ({ok:false, code, message}); virhekoodit:
-- pay_later_unavailable | not_found | rate_limited | payment_in_progress | order_expired | order_cancelled
create or replace function booking.public_confirm_pay_later(p_order_token uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o booking.orders; v_st jsonb; v_state text; v_net numeric; n int; v_old jsonb; v_new booking.orders;
begin
  if not booking._pay_later_test_enabled() then
    return jsonb_build_object('ok', false, 'code', 'pay_later_unavailable', 'message', 'Maksa myöhemmin -vaihtoehto ei ole käytössä');
  end if;
  if p_order_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._order_rl('plater', p_order_token, 30, 10) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select * into o from booking.orders where public_token = p_order_token for update;   -- lukitus: ei kilpaa cronin (_expire_holds) kanssa
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if o.external_source is not null then return jsonb_build_object('ok', false, 'code', 'pay_later_unavailable', 'message', 'Maksa myöhemmin -vaihtoehto ei ole käytössä'); end if;
  v_st := booking._checkout_state_json(o.id);
  v_state := v_st ->> 'checkout_state';
  if v_state in ('confirmed', 'confirmed_unpaid') then   -- idempotentti: ei uutta kirjausta eikä sähköpostia
    return v_st || jsonb_build_object('ok', true, 'pay_later', v_state = 'confirmed_unpaid', 'idempotent', true, 'order_id', o.id, 'order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status);
  end if;
  if v_state in ('processing_payment', 'preliminary') then
    return jsonb_build_object('ok', false, 'code', 'payment_in_progress', 'message', case when v_state = 'preliminary' then 'Alustava varaus: vahvistus tehdään erikseen' else 'Maksu on kesken – odota hetki ja yritä uudelleen' end) || v_st;
  end if;
  if v_state = 'expired' then return jsonb_build_object('ok', false, 'code', 'order_expired', 'message', 'Varauksen pito on päättynyt') || v_st; end if;
  if v_state = 'cancelled' then return jsonb_build_object('ok', false, 'code', 'order_cancelled', 'message', 'Varaus on peruttu') || v_st; end if;
  if v_state <> 'awaiting_payment' then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  -- awaiting_payment: vahvista varaukset (vain voimassa oleva pito) ja tilaus maksamattomana
  v_old := to_jsonb(o);
  update booking.reservations set status = 'confirmed', hold_expires_at = null
   where order_id = o.id and status = 'pending' and hold_expires_at > now();
  get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('ok', false, 'code', 'order_expired', 'message', 'Varauksen pito on päättynyt'); end if;
  select coalesce(sum(p.amount) filter (where p.status in ('paid', 'partially_refunded', 'refunded')), 0) - coalesce(sum(p.refunded_amount), 0)
    into v_net from booking.payments p where p.order_id = o.id;
  -- status ja payment_status samalla lauseella: orders_confirmed_upd-trigger jonottaa normaalin order_confirmation-viestin (+ viivästetyt lahjakorttikuitit)
  update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()),
         payment_status = case when v_net > 0.004 then 'partially_paid' else 'unpaid' end
   where id = o.id and status = 'pending' returning * into v_new;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'orders', o.id::text, 'pay_later_confirmed',
          jsonb_build_object('status', o.status, 'payment_status', o.payment_status, 'hold_kind', o.hold_kind),
          jsonb_build_object('status', v_new.status, 'payment_status', v_new.payment_status, 'net_paid', v_net, 'total_gross', v_new.total_gross, 'reservations_confirmed', n));
  return booking._checkout_state_json(o.id) || jsonb_build_object('ok', true, 'pay_later', true, 'idempotent', false, 'order_id', o.id, 'order_no', o.order_no, 'status', v_new.status, 'payment_status', v_new.payment_status);
end $$;

-- (public_checkout_payment_options / public_payment_options: booking_52/53/49-versiot + pay_later-lisäys)
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
  if p_token is null and booking._pay_later_test_enabled() then v_methods := v_methods || jsonb_build_array(booking._pay_later_method_json()); end if;   -- booking_57
  if p_token is not null then
    if not booking._order_rl('popt', p_token, 120, 60) then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
    select * into o from booking.orders where public_token = p_token;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    v_can := v_mode <> 'off' and o.external_source is null and o.status in ('pending', 'confirmed', 'completed', 'expired') and o.currency = 'EUR' and v_unpaid > 0.004 and not (o.status = 'pending' and o.hold_kind = 'preliminary');
    v_pending := exists (select 1 from booking.payments where order_id = o.id and provider = 'mobilepay' and status = 'pending' and (link_expires_at is null or link_expires_at > now()));
    v_order := jsonb_build_object('order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'unpaid', v_unpaid, 'can_pay_online', v_can, 'mobilepay_pending', v_pending) || booking._checkout_state_json(o.id);
    if not v_can then v_methods := '[]'::jsonb; end if;
    -- booking_57: 'maksa myöhemmin' (testi) vain kun lippu päällä, tilaus ei ole ulkoinen ja odottaa maksua (pito käynnissä, ei maksu kesken)
    if booking._pay_later_test_enabled() and o.external_source is null and v_order ->> 'checkout_state' = 'awaiting_payment' then
      v_methods := v_methods || jsonb_build_array(booking._pay_later_method_json());
    end if;
  end if;
  return jsonb_build_object('ok', true, 'online_enabled', v_mode <> 'off', 'methods', v_methods, 'order', v_order);
end $function$;

revoke all on function booking._pay_later_test_enabled(), booking._pay_later_method_json() from public, anon, authenticated;
revoke all on function booking.public_confirm_pay_later(uuid) from public;
grant execute on function booking.public_confirm_pay_later(uuid) to anon, authenticated, service_role;
