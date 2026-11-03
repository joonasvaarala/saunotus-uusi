CREATE OR REPLACE FUNCTION booking.public_buy_gift_card(p_items jsonb, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_recipient_name text DEFAULT NULL::text, p_recipient_email text DEFAULT NULL::text, p_greeting text DEFAULT NULL::text, p_delivery_to text DEFAULT NULL::text, p_cover_message text DEFAULT NULL::text, p_deliver_on text DEFAULT NULL::text, p_deliver_time text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}';
  v_ip text := booking._client_ip(); v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_cust bigint; v_res jsonb; v_status text; v_detail text; v_msg text;
begin
  if not booking._gc_flag('gift_cards.sale_enabled') then
    return jsonb_build_object('ok', false, 'code', 'sale_disabled', 'message', 'Lahjakorttien verkkomyynti ei ole vielä käytössä');
  end if;
  if v_ip is not null and not booking._rate_limit('gcbuy:ip:' || v_ip, (booking._setting('gift_cards.rl_buy_per_10min', '6'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_email <> '' and not booking._rate_limit('gcbuy:email:' || v_email, 4, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', 'Anna nimi'); end if;
  if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
  v_status := case when v_mode = 'pay_later' then 'confirmed' else 'pending' end;
  begin
    v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_gift_card', p_locale, (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    v_res := booking._gc_sell(p_items, v_cust, 'web', p_locale, v_name, v_email, v_status, null, null, p_recipient_name, p_recipient_email, p_greeting, p_delivery_to, p_cover_message, p_deliver_on, p_deliver_time);
    insert into booking.payments(order_id, method, provider, status, amount)
    values ((v_res ->> 'order_id')::bigint, case when v_mode = 'pay_later' then 'pay_later' else 'visma_pay' end, case when v_mode = 'pay_later' then 'manual' else 'visma_pay' end,
            'pending', (v_res ->> 'total')::numeric);
    update booking.orders set payment_status = case when v_mode = 'pay_later' then 'unpaid' else 'pending' end where id = (v_res ->> 'order_id')::bigint;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token', 'status', v_status, 'total', v_res -> 'total',
    'payment_mode', v_mode, 'payment_url', null, 'cards', (select coalesce(jsonb_agg(c - 'id'), '[]'::jsonb) from jsonb_array_elements(v_res -> 'cards') c),
    'note', 'Kortit aktivoituvat ja koodit toimitetaan kun tilaus on maksettu');
end $function$
;
