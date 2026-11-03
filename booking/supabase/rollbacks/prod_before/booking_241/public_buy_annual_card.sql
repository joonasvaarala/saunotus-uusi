CREATE OR REPLACE FUNCTION booking.public_buy_annual_card(p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}'; v_ip text := booking._client_ip();
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_locale text := case when p_locale in ('fi', 'en', 'sv') then p_locale else 'fi' end;
  p kb.products := booking._annual_sale_product(); v_cust bigint; v_order booking.orders; v_status text; v_detail text; v_msg text;
begin
  if not coalesce((booking._setting('annual_card_sale_enabled', 'false'::jsonb) #>> '{}')::boolean, false) or p.id is null then
    return jsonb_build_object('ok', false, 'code', 'sale_disabled', 'message', 'Vuosikorttien verkkomyynti ei ole käytössä');
  end if;
  if v_ip is not null and not booking._rate_limit('annualbuy:ip:' || v_ip, 6, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
  end if;
  if v_email <> '' and not booking._rate_limit('annualbuy:email:' || v_email, 4, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', 'Anna nimi'); end if;
  if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
  v_status := case when v_mode = 'pay_later' then 'confirmed' else 'pending' end;
  begin
    v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_annual_card', v_locale,
                                       (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale)
    values (v_cust, v_status, 'unpaid', p.price, 'web', v_locale) returning * into v_order;
    if v_status = 'confirmed' then update booking.orders set confirmed_at = now() where id = v_order.id; end if;
    insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
    values (v_order.id, p.id, p.name, 'product', 1, p.price, p.price, p.vat_rate, jsonb_build_object('annual_card', true, 'name_en', p.name_en));
    insert into booking.payments(order_id, method, provider, status, amount)
    values (v_order.id, case when v_mode = 'pay_later' then 'pay_later' else 'visma_pay' end, case when v_mode = 'pay_later' then 'manual' else 'visma_pay' end,
            'pending', p.price);
    update booking.orders set payment_status = case when v_mode = 'pay_later' then 'unpaid' else 'pending' end where id = v_order.id;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  return jsonb_build_object('ok', true, 'order_no', v_order.order_no, 'token', v_order.public_token, 'status', v_status, 'total', p.price,
                            'payment_mode', v_mode, 'payment_url', null, 'note', 'Vuosikortti ja sen koodi myönnetään kun tilaus on maksettu');
end $function$
;
