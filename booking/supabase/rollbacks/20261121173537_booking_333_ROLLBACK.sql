-- booking_333 ROLLBACK: palauttaa funktiot booking_332-tilaan, rajaustekstit ennalleen ja poistaa sarakkeet.
set local lock_timeout = '5s';
CREATE OR REPLACE FUNCTION booking._gc_redeem_rules(p_order_id bigint, p_card_id bigint)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g booking.gift_cards; pk booking.gift_card_packages; it booking.order_items; v_pb jsonb; v_base numeric; v_amt numeric;
        v_iid bigint; v_persons int; v_used int; v_left_uses int; v_n int; v_unit numeric; v_cov numeric; v_card_amt numeric;  -- booking_332
begin
  select * into g from booking.gift_cards where id = p_card_id;
  if g.package_code is null then return 0; end if;
  select * into pk from booking.gift_card_packages where code = g.package_code;
  if pk.code is null or (pk.redeem_product_ids is null and pk.redeem_weekdays is null) then return 0; end if;
  select oi.id, r.persons into v_iid, v_persons
    from booking.order_items oi
    join booking.reservations r on r.order_item_id = oi.id and r.order_id = oi.order_id
   where oi.order_id = p_order_id and oi.kind = 'reservation'
     and r.status in ('pending', 'confirmed', 'completed')
     and (pk.redeem_product_ids is null or oi.product_id = any (pk.redeem_product_ids))
     and (pk.redeem_weekdays is null or extract(isodow from (r.starts_at at time zone booking._tz()))::int = any (pk.redeem_weekdays))
   order by (coalesce(oi.price_breakdown, '{}'::jsonb) ? 'gift_cover'),
            -- booking_332: henkilöpääsykortit – ensin rivi, jolla on vielä kattamattomia henkilöitä
            (coalesce((select sum((x ->> 'uses')::int) from jsonb_array_elements(coalesce(oi.price_breakdown -> 'gift_covers', '[]'::jsonb)) x), 0) >= coalesce(r.persons, 0)),
            oi.id
   limit 1
   for update of oi;
  if v_iid is not null then select * into it from booking.order_items where id = v_iid; end if;
  if it.id is null then
    perform booking._err('gift_card_not_applicable', coalesce(nullif(btrim(pk.redeem_note), ''), 'Lahjakortti ei käy tähän varaukseen'));
  end if;
  -- booking_332: henkilöpääsykortti (redeem_unit_value = yhden pääsyn osuus kortin arvosta, esim. 50 € / 2 = 25 €).
  -- Kortti kattaa enintään floor(saldo / unit_value) henkilöä tältä riviltä; henkilöhinta lasketaan katon
  -- (redeem_cover_max / hlö) mukaan unit_valueen. Lisähenkilöt ja katon ylittävä osa maksetaan itse.
  if pk.redeem_unit_value is not null and pk.redeem_covers_base then
    if it.discount_code_id is not null then
      perform booking._err('gift_card_not_applicable', 'Tätä lahjakorttia ei voi käyttää yhdessä alennuskoodin kanssa');
    end if;
    v_pb := coalesce(it.price_breakdown, '{}'::jsonb);
    v_persons := greatest(coalesce(v_persons, nullif(v_pb ->> 'persons', '')::int, it.quantity, 1), 1);
    v_used := coalesce((select sum((x ->> 'uses')::int) from jsonb_array_elements(coalesce(v_pb -> 'gift_covers', '[]'::jsonb)) x), 0);
    v_left_uses := floor((g.balance + 0.004) / pk.redeem_unit_value)::int;
    if v_left_uses < 1 then perform booking._err('gift_card_empty', 'Kortin pääsyt on jo käytetty'); end if;
    v_n := least(greatest(v_persons - v_used, 0), v_left_uses);
    if v_n < 1 then perform booking._err('gift_card_not_applicable', 'Varauksen kaikki henkilöt on jo katettu lahjakortilla'); end if;
    v_unit := case when coalesce(v_pb ->> 'unit_price', '') ~ '^\d+(\.\d+)?$' then (v_pb ->> 'unit_price')::numeric else it.line_total_gross / v_persons end;
    v_unit := least(v_unit, it.line_total_gross / v_persons);
    v_cov := least(v_unit, coalesce(pk.redeem_cover_max, v_unit));
    v_card_amt := round(v_n * least(v_cov, pk.redeem_unit_value), 2);
    v_amt := round(v_n * greatest(v_cov - pk.redeem_unit_value, 0), 2);
    update booking.order_items
       set line_total_gross = line_total_gross - v_amt, discount_amount = coalesce(discount_amount, 0) + v_amt,
           price_breakdown = v_pb || jsonb_build_object('gift_covers', coalesce(v_pb -> 'gift_covers', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
             'gift_card_id', g.id, 'package', pk.code, 'uses', v_n, 'unit', v_unit, 'cover_max', pk.redeem_cover_max, 'unit_value', pk.redeem_unit_value,
             'amount', v_amt, 'card_amount', v_card_amt, 'at', now())))
     where id = it.id;
    if v_amt > 0 then update booking.orders set total_gross = total_gross - v_amt where id = p_order_id; end if;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), booking._jwt_role(), 'booking.order_items', it.id::text, 'GIFT_CARD_COVER',
            jsonb_build_object('line_total_gross', it.line_total_gross, 'discount_amount', it.discount_amount),
            jsonb_build_object('order_id', p_order_id, 'gift_card_id', g.id, 'package', pk.code, 'uses', v_n, 'unit', v_unit,
                               'cover_max', pk.redeem_cover_max, 'unit_value', pk.redeem_unit_value, 'amount', v_amt, 'card_amount', v_card_amt));
    return v_amt;
  end if;
  if not pk.redeem_covers_base or coalesce(it.price_breakdown, '{}'::jsonb) ? 'gift_cover' then return 0; end if;
  if it.discount_code_id is not null then
    perform booking._err('gift_card_not_applicable', 'Tätä lahjakorttia ei voi käyttää yhdessä alennuskoodin kanssa');
  end if;
  v_pb := coalesce(it.price_breakdown, '{}'::jsonb);
  v_base := case when v_pb ->> 'mode' = 'fixed_plus_extra' and coalesce(v_pb ->> 'base', '') ~ '^\d+(\.\d+)?$'
                 then (v_pb ->> 'base')::numeric - coalesce(nullif(v_pb #>> '{quiet,amount}', '')::numeric, 0)
                 else it.line_total_gross end;
  v_base := least(greatest(v_base, 0), coalesce(it.line_total_gross, 0));
  -- booking_331: katto (esim. ma–to 2 h 180 €). Kalliimmassa vuorossa (joulu 24.–30.12.) asiakas maksaa erotuksen.
  v_amt := round(greatest(least(v_base, coalesce(pk.redeem_cover_max, v_base)) - g.initial_amount, 0), 2);
  if v_amt <= 0 then return 0; end if;
  update booking.order_items
     set line_total_gross = line_total_gross - v_amt, discount_amount = coalesce(discount_amount, 0) + v_amt,
         price_breakdown = v_pb || jsonb_build_object('gift_cover', jsonb_build_object('gift_card_id', g.id, 'package', pk.code,
           'base', v_base, 'cover_max', pk.redeem_cover_max, 'card_value', g.initial_amount, 'amount', v_amt, 'at', now()))
   where id = it.id;
  update booking.orders set total_gross = total_gross - v_amt where id = p_order_id;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'booking.order_items', it.id::text, 'GIFT_CARD_COVER',
          jsonb_build_object('line_total_gross', it.line_total_gross, 'discount_amount', it.discount_amount),
          jsonb_build_object('order_id', p_order_id, 'gift_card_id', g.id, 'package', pk.code, 'base', v_base, 'cover_max', pk.redeem_cover_max, 'card_value', g.initial_amount, 'amount', v_amt));
  return v_amt;
end $function$
;
CREATE OR REPLACE FUNCTION booking._gc_rules_json(p_code text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case when p.redeem_product_ids is null and p.redeem_weekdays is null then null else
    jsonb_build_object('product_ids', to_jsonb(p.redeem_product_ids), 'weekdays', to_jsonb(p.redeem_weekdays),
      'covers_base', p.redeem_covers_base, 'cover_max', p.redeem_cover_max, 'unit_value', p.redeem_unit_value, 'note', p.redeem_note, 'note_en', p.redeem_note_en,
      'products', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'slug', k.slug, 'name', k.name, 'name_en', k.name_en) order by k.id), '[]'::jsonb)
                     from kb.products k where k.id = any (p.redeem_product_ids))) end
    from booking.gift_card_packages p where p.code = p_code
$function$
;
CREATE OR REPLACE FUNCTION booking._public_buy_gift_card_impl(p_items jsonb, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_recipient_name text DEFAULT NULL::text, p_recipient_email text DEFAULT NULL::text, p_greeting text DEFAULT NULL::text, p_delivery_to text DEFAULT NULL::text, p_cover_message text DEFAULT NULL::text, p_deliver_on text DEFAULT NULL::text, p_deliver_time text DEFAULT NULL::text)
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
  -- booking_316: paketin kaikkien tuotteiden on oltava Lahjakorttikauppa-kanavassa (sama vastaus kuin passiivisella paketilla)
  if jsonb_typeof(p_items) = 'array' and exists (select 1 from jsonb_array_elements(p_items) it316
      join booking.gift_card_packages g316 on g316.code = it316 ->> 'package'
     where jsonb_typeof(it316) = 'object' and not booking._gc_package_in_shop(g316.code)) then
    return jsonb_build_object('ok', false, 'code', 'package_inactive', 'message', 'Paketti ei ole myynnissä');
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
CREATE OR REPLACE FUNCTION booking.public_gift_card_package(p_code text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((select jsonb_build_object('ok', true, 'sale_enabled', booking._gc_flag('gift_cards.sale_enabled'), 'redeem_enabled', booking._gc_flag('gift_cards.redeem_enabled'),
      'max_cards_per_order', (booking._setting('gift_cards.max_cards_per_order', '10'::jsonb) #>> '{}')::int, 'currency', 'EUR',
      'package', jsonb_build_object('code', p.code, 'name', p.name, 'name_en', p.name_en, 'description', p.description, 'description_en', p.description_en,
        'kind', p.kind, 'is_open', p.is_open, 'price', p.price, 'min_amount', p.min_amount, 'max_amount', p.max_amount, 'persons', p.persons,
        'min_persons', p.min_persons, 'max_persons', p.max_persons,
        'unit_price', case when not p.is_open and p.items is not null and not exists (
            select 1 from jsonb_array_elements(p.items) it where coalesce(it ->> 'price_type', 'per_person') <> 'per_person' or it ->> 'unit_price' is null)
          then booking._gc_package_amount(p.items, 1) end,
        'vat_rate', p.vat_rate, 'valid_months', p.valid_months, 'items', p.items, 'listed', p.listed,
        'restrictions', booking._gc_rules_json(p.code)))
      from booking.gift_card_packages p
     where p.code = p_code and p.active and booking._gc_package_in_shop(p.code)),
    jsonb_build_object('ok', false, 'code', 'package_inactive', 'message', 'Paketti ei ole myynnissä'))
$function$
;
CREATE OR REPLACE FUNCTION booking.public_gift_card_packages()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object('ok', true, 'sale_enabled', booking._gc_flag('gift_cards.sale_enabled'), 'redeem_enabled', booking._gc_flag('gift_cards.redeem_enabled'),
    'max_cards_per_order', (booking._setting('gift_cards.max_cards_per_order', '10'::jsonb) #>> '{}')::int, 'currency', 'EUR',
    'packages', coalesce((select jsonb_agg(jsonb_build_object('code', p.code, 'name', p.name, 'name_en', p.name_en, 'description', p.description, 'description_en', p.description_en,
        'kind', p.kind, 'is_open', p.is_open, 'price', p.price, 'min_amount', p.min_amount, 'max_amount', p.max_amount, 'persons', p.persons,
        'min_persons', p.min_persons, 'max_persons', p.max_persons,
        'unit_price', case when not p.is_open and p.items is not null and not exists (
            select 1 from jsonb_array_elements(p.items) it where coalesce(it ->> 'price_type', 'per_person') <> 'per_person' or it ->> 'unit_price' is null)
          then booking._gc_package_amount(p.items, 1) end,
        'vat_rate', p.vat_rate, 'valid_months', p.valid_months, 'items', p.items) order by p.sort_order, p.code)
      from booking.gift_card_packages p where p.active and p.listed and booking._gc_package_in_shop(p.code)), '[]'::jsonb))  -- booking_330: listed=false → vain suoralla linkillä  -- booking_316: Lahjakorttikauppa-kanava
$function$
;
drop function if exists booking._gc_date_excluded(jsonb, date);
update booking.gift_card_packages set redeem_note = case code
    when 'bf_jalkiloylyt_mato' then 'Voimassa 6 kk, ma–to.'
    else 'Voimassa 6 kk, ma–to. 2 henkeä, voi käyttää kahdessa osassa.' end
 where code in ('bf_jalkiloylyt_mato', 'mv_yleiset_mato');
alter table booking.gift_card_packages drop constraint if exists gift_card_packages_redeem_excluded_ranges_check;
alter table booking.gift_card_packages drop column if exists redeem_excluded_ranges, drop column if exists sale_ends_at;
notify pgrst, 'reload schema';
