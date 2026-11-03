CREATE OR REPLACE FUNCTION booking.public_create_training_signup(p_rule_id bigint, p_date date, p_name text, p_email text, p_phone text, p_country text, p_language text, p_locale text, p_note text, p_marketing_consent boolean, p_privacy_consent boolean, p_addons text[] DEFAULT '{}'::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_ip text := booking._client_ip();
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_name text := btrim(coalesce(p_name, ''));
  v_phone text := btrim(coalesce(p_phone, ''));
  v_country text := upper(btrim(coalesce(p_country, 'FI')));
  v_locale text := case when lower(btrim(coalesce(p_locale, 'fi'))) = 'en' then 'en' else 'fi' end;
  v_lang text := lower(btrim(coalesce(nullif(p_language, ''), v_locale)));
  v_codes text[]; v_bad text; v_offer_n int; v_addons numeric := 0; v_addon_json jsonb := '[]'::jsonb;
  v_deposit numeric; v_course numeric; v_total numeric; v_remaining numeric;
  v_cust bigint; v_res jsonb; v_order bigint; v_resid bigint; v_detail text; v_msg text; v_hold int;
  v_seg jsonb; v_hold_at timestamptz; v_sid bigint;
begin
  if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
    return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
  end if;
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if p_privacy_consent is not true then
    return jsonb_build_object('ok', false, 'code', 'privacy_required', 'message', 'Tietosuojasuostumus puuttuu');
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', 'Anna nimi');
  end if;
  if not booking._valid_email(v_email) then
    return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite');
  end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero');
  end if;
  if v_country !~ '^[A-Z]{2}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_country', 'message', 'Tarkista maa');
  end if;
  if v_lang not in ('fi', 'en', 'sv') then
    return jsonb_build_object('ok', false, 'code', 'invalid_language', 'message', 'Tarkista kieli');
  end if;
  if p_note is not null and char_length(p_note) > 1000 then
    return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä');
  end if;
  if p_date is null or p_date < (now() at time zone booking._tz())::date
     or p_date > (now() at time zone booking._tz())::date + 400 then
    return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
  end if;
  if not booking._checkout_online_available() then
    return jsonb_build_object('ok', false, 'code', 'online_payment_unavailable', 'message', 'Verkkomaksu ei ole tilapäisesti käytettävissä – ilmoittautumista ei voi tehdä juuri nyt');
  end if;
  if (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id
       where lower(c.email) = v_email and o.status = 'pending' and o.created_at > now() - interval '1 hour') >= 3 then
    return jsonb_build_object('ok', false, 'code', 'too_many_pending', 'message', 'Sinulla on jo useita keskeneräisiä varauksia');
  end if;
  if not exists (
    select 1 from booking.schedule_rules sr
    join kb.products kp on kp.id = sr.product_id and kp.category = 'training' and kp.active
    join booking.product_config cfg on cfg.product_id = kp.id and cfg.bookable and cfg.lifecycle = 'current'
    where sr.id = p_rule_id and sr.kind = 'event' and sr.active and not sr.training_segment_only
  ) then
    return jsonb_build_object('ok', false, 'code', 'not_training', 'message', 'Ilmoittautuminen koskee vain koulutusta');
  end if;

  select coalesce(array_agg(distinct lower(btrim(c)) order by lower(btrim(c))), '{}'::text[])
    into v_codes
    from unnest(coalesce(p_addons, '{}'::text[])) c
   where btrim(coalesce(c, '')) <> '';
  select c into v_bad from unnest(v_codes) c where c not in ('single_room', 'internship') limit 1;
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'code', 'invalid_addon', 'message', 'Lisävalinta ei kelpaa');
  end if;

  select count(*)::int, coalesce(sum(o.price), 0),
         coalesce(jsonb_agg(jsonb_build_object('code', o.code, 'price', o.price) order by o.code), '[]'::jsonb)
    into v_offer_n, v_addons, v_addon_json
    from booking.training_addon_offers o
    join booking.schedule_rules sr on sr.id = p_rule_id
   where o.product_id = sr.product_id and o.active and o.code = any (v_codes);
  if v_offer_n is distinct from coalesce(cardinality(v_codes), 0) then
    return jsonb_build_object('ok', false, 'code', 'addon_not_offered', 'message', 'Lisävalinta ei ole tällä kurssilla');
  end if;

  select coalesce(pc.deposit_amount, case when kp.price_type = 'deposit' then kp.price end, 200), pc.course_price
    into v_deposit, v_course
    from booking.schedule_rules sr
    join kb.products kp on kp.id = sr.product_id
    join booking.product_config pc on pc.product_id = kp.id
   where sr.id = p_rule_id;
  if v_deposit is null or v_deposit <= 0 then
    return jsonb_build_object('ok', false, 'code', 'invalid_price', 'message', 'Varausmaksu puuttuu');
  end if;
  v_total := case when v_course is null then null else round(v_course + v_addons, 2) end;
  v_remaining := case when v_total is null then null else round(v_total - v_deposit, 2) end;
  v_hold := booking._checkout_hold_minutes();
  v_seg := booking._training_segment_json(p_rule_id);

  begin
    perform r.id from booking.schedule_rules r
     where r.id = p_rule_id or r.id in (select booking._training_segment_ids(p_rule_id))
     order by r.id
     for update;
    perform res.id from booking.resources res
     where res.id in (
       select rp.pool_id from booking.schedule_rule_pools rp
        where rp.rule_id = p_rule_id or rp.rule_id in (select booking._training_segment_ids(p_rule_id)))
     order by res.id
     for update;
    if 'single_room' = any (v_codes) and exists (
      select 1 from booking.schedule_rules r
       where r.id in (select booking._training_single_room_pools(p_rule_id))
         and booking._training_single_rooms_used(r.id) >= r.single_room_max
    ) then
      return jsonb_build_object('ok', false, 'code', 'single_room_full', 'message', 'Yhden hengen huoneet ovat täynnä');
    end if;
    v_cust := booking._upsert_customer(v_name, v_email, v_phone, coalesce(p_marketing_consent, false), 'web_booking', v_locale,
                                       (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    update booking.customers set country = v_country, language = v_lang where id = v_cust;
    v_res := booking._create_booking_core(p_rule_id, p_date, 1, v_cust, 'web', null, v_locale, nullif(btrim(coalesce(p_note, '')), ''),
                                          'pending', v_hold, true, null, null, v_deposit);
    v_order := (v_res ->> 'order_id')::bigint;
    v_resid := (v_res ->> 'reservation_id')::bigint;
    v_hold_at := (v_res ->> 'hold_expires_at')::timestamptz;
    for v_sid in
      select s.rule_id from booking._training_segments_of(p_rule_id) s
       where s.rule_id is distinct from p_rule_id
       order by s.rule_id
    loop
      perform booking._training_hold_segment(v_order, v_sid, v_hold_at);
    end loop;
    update booking.orders set payment_status = 'unpaid', hold_kind = 'checkout' where id = v_order;
    update booking.order_items set price_breakdown = coalesce(price_breakdown, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
        'deposit', true, 'deposit_amount', v_deposit, 'course_price', v_course,
        'addons_total', v_addons, 'total', v_total, 'remaining', v_remaining, 'addons', v_addon_json, 'segments', v_seg))
     where order_id = v_order and kind = 'reservation';
    insert into booking.training_participants(
      reservation_id, order_id, name, email, phone, country, language, privacy_consent_at, marketing_consent,
      single_room, addons, course_price, addons_total, total, deposit_paid, remaining, segments)
    values (
      v_resid, v_order, v_name, v_email, v_phone, v_country, v_lang, now(), coalesce(p_marketing_consent, false),
      'single_room' = any (v_codes), v_addon_json, v_course, v_addons, v_total, v_deposit, v_remaining, v_seg);
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;

  return jsonb_build_object(
      'ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token',
      'status', 'pending', 'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at',
      'total', v_deposit, 'hold_expires_at', v_res -> 'hold_expires_at',
      'payment_mode', 'hold_until_paid', 'payment_url', null, 'product_name', v_res -> 'product_name', 'customer_kind', 'private',
      'training', jsonb_strip_nulls(jsonb_build_object(
        'course_price', v_course, 'addons_total', v_addons, 'total', v_total,
        'deposit_paid', v_deposit, 'remaining', v_remaining, 'addons', v_addon_json, 'segments', v_seg)))
    || booking._checkout_state_json(v_order);
end $function$
;
