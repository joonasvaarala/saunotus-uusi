CREATE OR REPLACE FUNCTION booking.public_drinks_checkout(p_device text, p_items jsonb, p_email text DEFAULT NULL::text, p_locale text DEFAULT 'fi'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_ip text := coalesce(booking._client_ip(), 'unknown');
  v_code text := nullif(lower(btrim(coalesce(p_device, ''))), '');
  q booking.product_qr;
begin
  if not booking._rate_limit('drinks-pay:' || v_ip, 8, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_code is not null and not booking._rate_limit('drinks-dev:' || v_code, 30, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  begin
    if v_code is null or v_code !~ '^[a-f0-9]{32}$' then
      return jsonb_build_object('ok', false, 'code', 'unknown_device', 'message', 'QR-koodia ei löydy');
    end if;
    select * into q from booking.product_qr where code = v_code and active;
    if not found then
      return jsonb_build_object('ok', false, 'code', 'unknown_device', 'message', 'QR-koodia ei löydy');
    end if;
    if jsonb_typeof(p_items) = 'array' and exists (
      select 1 from jsonb_array_elements(p_items) e
      where coalesce(e ->> 'product_id', '') is distinct from q.product_id::text
    ) then
      return jsonb_build_object('ok', false, 'code', 'not_counter_product', 'message', 'QR-linkki myy vain tämän tuotteen');
    end if;
    return booking._counter_checkout('kylmalaite', p_items, p_locale, p_email, q.code);
  exception when others then
    declare d text; m text; s text;
    begin
      get stacked diagnostics d = pg_exception_detail, m = message_text, s = returned_sqlstate;
      if s = 'BK001' then return jsonb_build_object('ok', false, 'code', d, 'message', m); end if;
      raise;
    end;
  end;
end $function$
;
