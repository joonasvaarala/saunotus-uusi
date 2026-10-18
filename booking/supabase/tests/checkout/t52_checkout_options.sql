-- booking_52 testit (rollback-eränä; lopussa tarkoituksellinen poikkeus)
do $$
declare
  _t jsonb := '[]'::jsonb; v_fail int := 0; v_total int := 0; r jsonb; tok uuid; tok2 uuid; mode0 text; pm0 jsonb; gc0 jsonb; e jsonb;
begin
  select value into pm0 from booking.settings where key = 'public_payment_mode';
  select value into gc0 from booking.settings where key = 'gift_cards.redeem_enabled';
  select mode into mode0 from booking.integration_config where key = 'mobilepay';

  -- _option_label
  _t := _t || jsonb_build_object('ok', booking._option_label(10, 'fi') = 'Valitse hoito' and booking._option_label(10, 'en') = 'Choose your treatment', 'n', 'T1a option_label fi/en tuotteelle 10');
  _t := _t || jsonb_build_object('ok', booking._option_label(10, null) = 'Valitse hoito' and booking._option_label(10, 'xx') = 'Valitse hoito', 'n', 'T1b tuntematon/null kieli -> fi');
  update booking.product_config set option_label_en = null where product_id = 10;
  _t := _t || jsonb_build_object('ok', booking._option_label(10, 'en') = 'Valitse hoito', 'n', 'T1c en puuttuu -> fi-otsikko');
  update booking.product_config set option_label = null, option_label_en = null where product_id = 10;
  _t := _t || jsonb_build_object('ok', booking._option_label(10, 'fi') is null and booking._option_label(10, 'en') is null, 'n', 'T1d ei otsikkoa -> null');
  _t := _t || jsonb_build_object('ok', booking._option_label(-1, 'fi') is null, 'n', 'T1e tuntematon tuote -> null');
  update booking.product_config set option_label = 'Valitse hoito', option_label_en = 'Choose your treatment' where product_id = 10;

  -- public_get_order / public_get_booking (olemassa oleva hoitotilaus, ei muuteta dataa)
  select o.public_token into tok from booking.orders o join booking.reservations r on r.order_id = o.id where r.product_id = 10 and r.product_option_id is not null order by o.id desc limit 1;
  if tok is null then select o.public_token into tok from booking.orders o join booking.reservations r on r.order_id = o.id where r.product_id = 10 order by o.id desc limit 1; end if;
  if tok is null then
    _t := _t || jsonb_build_object('ok', true, 'n', 'T2 (ohitettu: kannassa ei hoitotilausta product 10 – testattu vain apufunktio)');
  else
    r := booking.public_get_order(tok);
    e := r -> 'reservations' -> 0;
    _t := _t || jsonb_build_object('ok', r ->> 'ok' = 'true' and e ->> 'option_label' is not null and e ->> 'option_label_fi' = 'Valitse hoito' and e ->> 'option_label_en' = 'Choose your treatment' and e ? 'option' and e ? 'option_choices', 'n', 'T2a public_get_order: reservations[].option_label (+fi/en), option ja option_choices säilyvät');
    _t := _t || jsonb_build_object('ok', r ? 'items' and r ? 'payments' and r ? 'receipts' and r ? 'upsell' and r ? 'online_payment_enabled' and r ? 'unpaid', 'n', 'T2b public_get_order: muut kentät ennallaan');
    r := booking.public_get_booking(tok);
    e := r -> 'items' -> 0;
    _t := _t || jsonb_build_object('ok', r ->> 'ok' = 'true' and e ->> 'option_label' is not null and e ->> 'option_label_fi' = 'Valitse hoito' and e ->> 'option_label_en' = 'Choose your treatment' and e ? 'option', 'n', 'T2c public_get_booking: items[].option_label (+fi/en), option säilyy');
    _t := _t || jsonb_build_object('ok', r ? 'can_change' and r ? 'addons' and r ? 'booking_kind' and r ? 'payment_methods', 'n', 'T2d public_get_booking: muut kentät ennallaan');
    -- kieli tilauksen locale mukaan
    update booking.orders set locale = 'en' where public_token = tok;
    _t := _t || jsonb_build_object('ok', booking.public_get_order(tok) -> 'reservations' -> 0 ->> 'option_label' = 'Choose your treatment' and booking.public_get_booking(tok) -> 'items' -> 0 ->> 'option_label' = 'Choose your treatment', 'n', 'T2e option_label seuraa tilauksen locale-kieltä (en)');
    update booking.orders set locale = 'fi' where public_token = tok;
    _t := _t || jsonb_build_object('ok', booking.public_get_order(tok) -> 'reservations' -> 0 ->> 'option_label' = 'Valitse hoito', 'n', 'T2f locale fi');
  end if;
  -- muu kuin hoitotuote: option_label null (ei kaadu)
  select o.public_token into tok2 from booking.orders o join booking.reservations r on r.order_id = o.id where r.product_id <> 10 order by o.id desc limit 1;
  if tok2 is not null then
    _t := _t || jsonb_build_object('ok', booking.public_get_booking(tok2) ->> 'ok' = 'true' and jsonb_typeof(booking.public_get_booking(tok2) -> 'items' -> 0 -> 'option_label') = 'null', 'n', 'T2g muu tuote: option_label = null');
  end if;

  -- public_checkout_payment_options
  update booking.settings set value = 'true'::jsonb where key = 'gift_cards.redeem_enabled';
  update booking.integration_config set mode = 'test' where key = 'mobilepay';
  r := booking.public_checkout_payment_options();
  _t := _t || jsonb_build_object('ok', r ->> 'ok' = 'true' and jsonb_array_length(r -> 'methods') = 2 and r -> 'methods' -> 0 ->> 'code' = 'mobilepay' and (r -> 'methods' -> 0 ->> 'test')::boolean and r -> 'methods' -> 1 ->> 'code' = 'gift_card'
                                      and r -> 'methods' -> 1 ->> 'apply_rpc' = 'public_apply_gift_card' and (r ->> 'mobilepay_enabled')::boolean and (r ->> 'gift_card_redeem_enabled')::boolean, 'n', 'T3a mobilepay=test + redeem_enabled: molemmat tavat (mobilepay test=true)');
  update booking.integration_config set mode = 'off' where key = 'mobilepay';
  r := booking.public_checkout_payment_options();
  _t := _t || jsonb_build_object('ok', jsonb_array_length(r -> 'methods') = 1 and r -> 'methods' -> 0 ->> 'code' = 'gift_card' and not (r ->> 'mobilepay_enabled')::boolean, 'n', 'T3b mobilepay=off: vain lahjakortti');
  update booking.settings set value = 'false'::jsonb where key = 'gift_cards.redeem_enabled';
  r := booking.public_checkout_payment_options();
  _t := _t || jsonb_build_object('ok', r -> 'methods' = '[]'::jsonb and not (r ->> 'gift_card_redeem_enabled')::boolean, 'n', 'T3c molemmat pois: methods = []');
  update booking.integration_config set mode = 'test' where key = 'mobilepay';
  r := booking.public_checkout_payment_options();
  _t := _t || jsonb_build_object('ok', jsonb_array_length(r -> 'methods') = 1 and r -> 'methods' -> 0 ->> 'code' = 'mobilepay', 'n', 'T3d vain mobilepay kun lahjakortin lunastus pois');
  _t := _t || jsonb_build_object('ok', not (r::text ~* '(secret|client_id|subscription|msn|api[_-]?key)'), 'n', 'T3e vastaus ei sisällä salaisuuksia/avainten nimiä');
  _t := _t || jsonb_build_object('ok', (select value from booking.settings where key = 'public_payment_mode') is not distinct from pm0, 'n', 'T3f public_payment_mode-asetus koskematon');
  _t := _t || jsonb_build_object('ok', has_function_privilege('anon', 'booking.public_checkout_payment_options()', 'execute') and not has_function_privilege('anon', 'booking._option_label(bigint,text)', 'execute'), 'n', 'T3g anon voi kutsua julkista RPC:tä, ei apufunktiota');
  _t := _t || jsonb_build_object('ok', booking.public_payment_options(null) ->> 'ok' = 'true', 'n', 'T3h public_payment_options(null) toimii edelleen');

  for r in select x from jsonb_array_elements(_t) x loop v_total := v_total + 1; if r ->> 'ok' is distinct from 'true' then v_fail := v_fail + 1; end if; end loop;
  raise exception E'CHECKOUT_TESTS fail=% total=%\n%', v_fail, v_total,
    (select string_agg(case when x ->> 'ok' = 'true' then 'ok   ' else 'FAIL ' end || (x ->> 'n'), E'\n') from jsonb_array_elements(_t) x);
end $$;
