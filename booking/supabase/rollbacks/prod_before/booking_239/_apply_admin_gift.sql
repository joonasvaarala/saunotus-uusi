-- PROD-määrittely ennen booking_239:ää (md5 sama DEV/PROD, 3.11.2026)
CREATE OR REPLACE FUNCTION booking._apply_admin_gift(p_order_id bigint, p_code text, p_remainder_method text, p_paid boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  g booking.gift_cards; v_norm text := booking.gift_code_norm(p_code); v_res jsonb; v_rest numeric; v_rm text; v_paid boolean;
  v_total numeric;
begin
  perform booking._require_permission('bookings.manage');
  if v_norm is null or v_norm = '' then
    return jsonb_build_object('gift_card_amount', 0);
  end if;
  if v_norm !~ '^[A-Z0-9]{12}$' then perform booking._err('gift_card_not_found', 'Koodia ei löydy tai se ei ole käytettävissä'); end if;
  select * into g from booking.gift_cards where code = v_norm;
  if not found or g.status in ('cancelled', 'pending_payment') then
    perform booking._err('gift_card_not_found', 'Koodia ei löydy tai se ei ole käytettävissä');
  end if;
  select total_gross into v_total from booking.orders where id = p_order_id;
  if coalesce(v_total, 0) <= 0 then
    return jsonb_build_object('gift_card_amount', 0, 'gift_card_skipped', true, 'remaining', 0, 'total', v_total);
  end if;
  if not exists (select 1 from booking.payments where order_id = p_order_id and status = 'pending') then
    insert into booking.payments(order_id, method, provider, status, amount, created_by)
    values (p_order_id, 'pay_later', 'manual', 'pending', v_total, auth.uid());
  end if;
  v_res := booking._gc_redeem(p_order_id, g.id, null, 'Hallinta', false);
  v_rest := coalesce((v_res ->> 'remaining')::numeric, 0);
  if v_rest > 0.004 then
    v_rm := coalesce(nullif(btrim(coalesce(p_remainder_method, '')), ''), 'pay_later');
    if v_rm = 'gift_card' then v_rm := 'pay_later'; end if;
    if not exists (select 1 from booking.payment_methods where code = v_rm and active) then
      perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä');
    end if;
    v_paid := coalesce(p_paid, false) and v_rm not in ('pay_later', 'invoice', 'bank_transfer');
    insert into booking.payments(order_id, method, provider, status, amount, paid_at, note, created_by)
    values (p_order_id, v_rm, 'manual', case when v_paid then 'paid' else 'pending' end, v_rest,
            case when v_paid then now() end, 'Lahjakortin jälkeen jäljelle jäänyt osuus', auth.uid());
    perform booking._refresh_order_payment(p_order_id);
  end if;
  return jsonb_build_object('gift_card_amount', v_res -> 'amount', 'remaining', v_rest, 'gift_card', v_res -> 'gift_card',
                            'total', (select total_gross from booking.orders where id = p_order_id));
end $function$;
