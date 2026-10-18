-- ROLLBACK booking_53_checkout_hold: palauttaa funktiot booking_52-tilaan ja poistaa pitomallin apufunktiot, asetukset ja orders.hold_kind
-- Huom: ajaa vasta kun ei ole avoimia pitotilauksia (status='pending' AND hold_kind='checkout'); ne jäisivät muuten ilman pitotietoa (vanheneminen toimii silti).
set local lock_timeout = '5s';

CREATE OR REPLACE FUNCTION booking._create_legs_booking(p_lifecycle text, p_product_id bigint, p_start timestamp with time zone, p_end timestamp with time zone, p_persons integer, p_customer_id bigint, p_channel text, p_created_by uuid, p_note text, p_price numeric, p_space_id bigint, p_override boolean, p_override_reason text, p_quota_exempt boolean, p_parent_reservation_id bigint, p_order_id bigint DEFAULT NULL::bigint, p_option_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  p kb.products; pc booking.product_config; v_end timestamptz; v_total numeric; v_order booking.orders; v_item bigint; v_res booking.reservations;
  v_plan booking.leg_plan[] := '{}'; lp booking.leg_plan; v_prim booking.leg_plan; v_parent bigint; v_pools bigint[]; v_off integer; v_cmin integer; v_n integer := 0; v_missing boolean := false; v_ecode text; v_opt bigint;
begin
  select * into p from kb.products where id = p_product_id;
  if not found then perform booking._err('product_not_found', 'Tuotetta ei löydy'); end if;
  select * into pc from booking.product_config where product_id = p_product_id;
  if not found then perform booking._err('not_bookable', 'Tuotetta ei voi varata'); end if;
  if p_lifecycle is not null and pc.lifecycle <> p_lifecycle then
    perform booking._err('wrong_lifecycle', case p_lifecycle when 'old' then 'Valitse vanha tuote (current-tuotteet: Uusi varaus)' else 'Valitse nykyinen tuote' end);
  end if;
  if p.vat_rate is null then perform booking._err('vat_missing', 'Tuotteelta puuttuu ALV-kanta'); end if;
  v_opt := booking._resolve_product_option(p_product_id, p_option_code, true);     -- booking_50: tuotevalinta (pakollinen jos product_config.option_required ja aktiivisia vaihtoehtoja)
  v_end := coalesce(p_end, p_start + make_interval(mins => coalesce(pc.duration_minutes, p.duration_minutes)));
  if p_start is null or v_end is null or v_end <= p_start then perform booking._err('bad_time', 'Virheellinen aika'); end if;
  if p_override and (p_override_reason is null or length(btrim(p_override_reason)) < 3) then perform booking._err('override_reason_required', 'Ylitys vaatii perustelun'); end if;

  -- lisäpalvelu (kb 27/28): vaatii kattavan vanhempivarauksen (jälkilöyly / oma vuoro)
  if cardinality(pc.requires_parent_product_ids) > 0 then
    select r.id into v_parent
      from booking.reservations r join booking.orders o on o.id = r.order_id
     where r.product_id = any (pc.requires_parent_product_ids) and booking._res_active(r.status, r.hold_expires_at)
       and r.starts_at <= p_start and r.ends_at >= v_end
       and (p_parent_reservation_id is null or r.id = p_parent_reservation_id)
     order by (o.customer_id is not distinct from p_customer_id) desc, r.starts_at limit 1;
    if v_parent is null and not p_override then
      perform booking._err('parent_required', 'Lisäpalvelu vaatii jälkilöyly-/yksityisvuorovarauksen samalle ajalle');
    end if;
  end if;

  begin
    for lp in select * from booking._plan_legs(p_product_id, p_start, v_end, p_persons, p_space_id, p_override) loop v_plan := array_append(v_plan, lp); end loop;
  exception when sqlstate 'BK001' then
    -- booking_22: ei vapaata saunottajaa -> varaus syntyy ilman saunottajalegiä (therapist_missing), kaikki muut virheet nousevat ennallaan
    get stacked diagnostics v_ecode = pg_exception_detail;
    if v_ecode is distinct from 'no_therapist' then raise; end if;
    v_plan := '{}'; v_missing := true;
    for lp in select * from booking._plan_legs(p_product_id, p_start, v_end, p_persons, p_space_id, p_override, null, true) loop v_plan := array_append(v_plan, lp); end loop;
  end;
  select * into v_prim from unnest(v_plan) u where u.leg_no = 1 and u.role = 'space';
  if v_prim.resource_id is null then perform booking._err('no_primary_leg', 'Tuotteelta puuttuu ensisijainen tila (product_space_rules leg 1)'); end if;
  v_off := (extract(epoch from (v_prim.claim_start - p_start)) / 60)::int;
  v_cmin := case when v_prim.claim_end >= v_end then null else (extract(epoch from (v_prim.claim_end - v_prim.claim_start)) / 60)::int end;
  if v_prim.mode = 'exclusive' and (v_off <> 0 or v_cmin is not null) then perform booking._err('bad_rule', 'Yksinoikeusvarauksen claim-ikkuna on aina koko varaus'); end if;
  v_pools := case when v_prim.pool_id is null then '{}'::bigint[] else array[v_prim.pool_id] end;

  v_total := coalesce(p_price, coalesce(p.price, 0) + coalesce(p.extra_person_price, 0) * greatest(p_persons - coalesce(p.included_persons, p_persons), 0));
  if p_order_id is null then
    insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_note, created_by, confirmed_at)
    values (p_customer_id, 'confirmed', 'unpaid', v_total, p_channel, 'fi', p_note, p_created_by, now()) returning * into v_order;
  else   -- lisäys olemassa olevaan tilaukseen (booking_30): ei uutta tilausnumeroa
    select * into v_order from booking.orders where id = p_order_id for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
    update booking.orders set total_gross = total_gross + v_total where id = p_order_id;
  end if;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
  values (v_order.id, p.id, p.name, 'reservation', 1, v_total, v_total, p.vat_rate,
          jsonb_build_object('model', 'legs_v2', 'lifecycle', pc.lifecycle, 'persons', p_persons)) returning id into v_item;

  insert into booking.reservations(order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status,
                                   quota_exempt, claim_offset_min, claim_minutes, parent_reservation_id, override_reason, created_by, therapist_missing, product_option_id)
  values (v_order.id, v_item, p.id, v_prim.resource_id, v_prim.mode, p_start, v_end, p_persons, v_pools, 'confirmed',
          p_quota_exempt, v_off, v_cmin, v_parent, case when p_override then btrim(p_override_reason) end, p_created_by, v_missing, v_opt)
  returning * into v_res;                                    -- trigger validoi ensisijaisen claimin

  for lp in select * from unnest(v_plan) u where not (u.leg_no = 1 and u.role = 'space') order by u.leg_no loop
    insert into booking.reservation_legs(reservation_id, resource_id, role, mode, starts_at, ends_at, offset_min, minutes, persons, pool_ids, skill, session_key,
                                         quota_exempt, override_reason, rule_id)
    values (v_res.id, lp.resource_id, lp.role, lp.mode, lp.claim_start, lp.claim_end, lp.offset_min, lp.minutes, lp.persons,
            case when lp.pool_id is null then '{}'::bigint[] else array[lp.pool_id] end, lp.skill, lp.session_key,
            p_quota_exempt, case when p_override then btrim(p_override_reason) end, lp.rule_id);   -- trigger validoi legin
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no, 'reservation_id', v_res.id, 'total', v_total,
                            'starts_at', v_res.starts_at, 'ends_at', v_res.ends_at, 'legs', v_n, 'space_id', v_res.space_id,
                            'product_name', p.name, 'parent_reservation_id', v_parent,
                            'therapist_missing', v_missing, 'warning', case when v_missing then 'therapist_missing' end,
                            'option', booking._option_json(v_opt));
end $function$;

CREATE OR REPLACE FUNCTION booking.public_create_booking(p_rule_id bigint, p_date date, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_addons jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}';
  v_ip text := booking._client_ip();
  v_cust bigint; v_res jsonb; v_status text; v_pay_method text; v_pay_provider text;
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_detail text; v_msg text;
  v_hold int := (booking._setting('hold_minutes', '15'::jsonb) #>> '{}')::int;
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private'))); v_is_company boolean; v_company jsonb; v_add numeric; v_total numeric;
begin
  if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
    return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
  end if;

  -- rate limit (kirjataan myös estetyt yritykset)
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;

  -- syötteiden validointi
  select k.is_company into v_is_company from booking.customer_kinds k where k.code = v_kind and k.active;
  if v_is_company is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_customer_kind', 'message', 'Valitse asiakastyyppi (yksityinen / yritys)');
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', case when v_is_company then 'Anna yhteyshenkilön nimi' else 'Anna nimi' end);
  end if;
  if not booking._valid_email(v_email) then
    return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite');
  end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero');
  end if;
  if p_persons is null or p_persons < 1 or p_persons > 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_persons', 'message', 'Tarkista henkilömäärä');
  end if;
  if p_note is not null and char_length(p_note) > 1000 then
    return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä');
  end if;
  if p_date is null or p_date < (now() at time zone booking._tz())::date
     or p_date > (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int then
    return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
  end if;
  -- rajoita samanaikaisia maksamattomia pitoja / sähköposti
  if (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id
       where lower(c.email) = v_email and o.status = 'pending' and o.created_at > now() - interval '1 hour') >= 3 then
    return jsonb_build_object('ok', false, 'code', 'too_many_pending', 'message', 'Sinulla on jo useita keskeneräisiä varauksia');
  end if;

  v_status := case when v_mode = 'pay_later' then 'confirmed' else 'pending' end;
  v_pay_method := case when v_mode = 'pay_later' then case when v_is_company then 'invoice' else 'pay_later' end else 'visma_pay' end;
  v_pay_provider := case when v_mode = 'pay_later' then 'manual' else 'visma_pay' end;

  begin  -- alitransaktio: virhe kumoaa asiakkaan/tilauksen/varauksen luonnin mutta rate limit -kirjaus säilyy
    if v_is_company then v_company := booking._clean_company(p_company); end if;
    if v_is_company then
      v_cust := booking._upsert_company_customer(v_kind, v_name, v_email, v_phone, v_company, p_marketing_consent, 'web_booking', p_locale,
                                                 (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    else
      v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale,
                                         (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    end if;
    v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, 'web', null, p_locale, p_note,
                                          v_status, v_hold, true);
    perform booking._stamp_order_billing((v_res ->> 'order_id')::bigint, v_cust, v_company);
    v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);
    v_total := (v_res ->> 'total')::numeric + v_add;
    insert into booking.payments(order_id, method, provider, status, amount)
    values ((v_res ->> 'order_id')::bigint, v_pay_method, v_pay_provider, 'pending', v_total);
    update booking.orders set payment_status = case when v_mode = 'pay_later' then 'unpaid' else 'pending' end
     where id = (v_res ->> 'order_id')::bigint;
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;

  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token',
                            'status', v_status, 'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at',
                            'total', v_total, 'addons_total', v_add, 'hold_expires_at', v_res -> 'hold_expires_at',
                            'payment_mode', v_mode, 'payment_url', null, 'product_name', v_res -> 'product_name', 'customer_kind', v_kind);
end $function$;

CREATE OR REPLACE FUNCTION booking.public_create_treatment_booking(p_product_id bigint, p_start timestamp with time zone, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_option_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '3s'
AS $function$
declare
  v_ip text := booking._client_ip();
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private'))); v_is_company boolean; v_company jsonb;
  v_cust bigint; v_res jsonb; v_end timestamptz; v_total numeric; v_token uuid; v_detail text; v_msg text; v_pay_method text; v_order bigint; v_opt bigint;
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
  select k.is_company into v_is_company from booking.customer_kinds k where k.code = v_kind and k.active;
  if v_is_company is null then return jsonb_build_object('ok', false, 'code', 'invalid_customer_kind', 'message', 'Valitse asiakastyyppi (yksityinen / yritys)'); end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', case when v_is_company then 'Anna yhteyshenkilön nimi' else 'Anna nimi' end);
  end if;
  if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
  if p_note is not null and char_length(p_note) > 1000 then return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä'); end if;
  -- suojakatkaisimet: pay_later ei vaadi maksua -> rajataan väärinkäyttö (sähköposti / kokonaismäärä)
  if (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id join booking.reservations r on r.order_id = o.id
        join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots
       where lower(c.email) = v_email and o.source_channel = 'web' and o.status = 'confirmed' and r.status = 'confirmed' and r.starts_at > now()
         and o.payment_status = 'unpaid') >= coalesce((booking._setting('public_treatment_max_open_per_email', '5'::jsonb) #>> '{}')::int, 5) then
    return jsonb_build_object('ok', false, 'code', 'too_many_open', 'message', 'Sinulla on jo useita tulevia varauksia – ota yhteyttä sähköpostitse');
  end if;
  if (select count(*) from booking.orders o join booking.reservations r on r.order_id = o.id join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots
       where o.source_channel = 'web' and o.created_at > now() - interval '1 hour') >= coalesce((booking._setting('public_treatment_global_per_hour', '30'::jsonb) #>> '{}')::int, 30) then
    return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'Verkkovarauksia tehdään nyt poikkeuksellisen paljon – yritä myöhemmin uudelleen');
  end if;

  begin  -- alitransaktio: virhe kumoaa asiakkaan/tilauksen/varauksen luonnin mutta rate limit -kirjaus säilyy
    v_end := booking._treatment_slot_check(p_product_id, p_start, p_persons, true);       -- uudelleenvalidointi luontihetkellä (päivä, aikaikkuna, ruudukko, henkilömäärä)
    v_opt := booking._resolve_product_option(p_product_id, p_option_code, true);          -- booking_50: tuotevalinta (option_required / invalid_option)
    if v_is_company then v_company := booking._clean_company(p_company); end if;
    if v_is_company then
      v_cust := booking._upsert_company_customer(v_kind, v_name, v_email, v_phone, v_company, p_marketing_consent, 'web_booking', p_locale, (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    else
      v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale, (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    end if;
    v_total := booking._treatment_price(p_product_id, p_persons);
    -- ei override-polkua; ei vapaata saunottajaa -> therapist_missing (booking_22) ellei päivä ole suljettu (therapist_closed nousee virheenä)
    v_res := booking._create_legs_booking('current', p_product_id, p_start, v_end, p_persons, v_cust, 'web', null, p_note, v_total, null, false, null, false, null, null, p_option_code);
    v_order := (v_res ->> 'order_id')::bigint;
    perform booking._stamp_order_billing(v_order, v_cust, v_company);
    v_pay_method := case when v_is_company then 'invoice' else 'pay_later' end;
    insert into booking.payments(order_id, method, provider, status, amount) values (v_order, v_pay_method, 'manual', 'pending', v_total);
    update booking.orders set payment_status = 'unpaid' where id = v_order returning public_token into v_token;
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return booking._public_slot_error(v_detail, v_msg);
    when exclusion_violation then
      return booking._public_slot_error('slot_unavailable', null);
    when lock_not_available then
      return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'Järjestelmä on hetkellä kiireinen, yritä hetken kuluttua uudelleen');
  end;

  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_token, 'status', 'confirmed', 'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at',
                            'persons', p_persons, 'total', v_total, 'payment_mode', 'pay_later', 'payment_url', null, 'hold_expires_at', null,
                            'product_name', v_res -> 'product_name', 'customer_kind', v_kind, 'booking_kind', 'slots', 'option', booking._option_json(v_opt));
end $function$;

CREATE OR REPLACE FUNCTION booking._gc_redeem(p_order_id bigint, p_card_id bigint, p_amount numeric, p_note text, p_public boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; g booking.gift_cards; v_unpaid numeric; v_amt numeric; v_id bigint; rc record; v_excl boolean; v_left numeric; v_card booking.gift_cards;
begin
  if not booking._gc_flag('gift_cards.redeem_enabled') then perform booking._err('redeem_disabled', 'Lahjakorttien lunastus ei ole vielä käytössä'); end if;
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if o.external_source is not null or o.status not in ('pending', 'confirmed', 'completed') or (p_public and o.status = 'completed') then
    perform booking._err('order_not_editable', 'Tilaukselle ei voi kirjata maksua');
  end if;
  if exists (select 1 from booking.order_items oi where oi.order_id = o.id and oi.kind = 'gift_card') then
    perform booking._err('gift_card_not_allowed', 'Lahjakortilla ei voi ostaa lahjakorttia');
  end if;
  select * into g from booking.gift_cards where id = p_card_id for update;
  if not found then perform booking._err('gift_card_not_found', 'Korttia ei löydy'); end if;
  if g.source = 'johku' and not booking._gc_flag('gift_cards.johku_cards_redeemable') then
    perform booking._err('johku_cards_closed', 'Johku-lähtöisten korttien lunastus ei ole vielä käytössä (kortit lunastetaan toistaiseksi Johkussa)');
  end if;
  if g.status in ('cancelled', 'pending_payment', 'pending_verification') then perform booking._err('gift_card_inactive', 'Kortti ei ole käytettävissä'); end if;
  if g.status = 'expired' or (g.valid_to is not null and g.valid_to < booking._gc_today()) then perform booking._err('gift_card_expired', 'Kortin voimassaolo on päättynyt'); end if;
  if g.status = 'used' or g.balance <= 0 then perform booking._err('gift_card_empty', 'Kortin saldo on käytetty'); end if;
  if not g.balance_verified then perform booking._err('gift_card_inactive', 'Kortin saldoa ei ole vahvistettu'); end if;
  v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
  if v_unpaid <= 0 then perform booking._err('nothing_to_pay', 'Tilauksella ei ole maksettavaa'); end if;
  v_amt := coalesce(p_amount, least(g.balance, v_unpaid));
  if v_amt is null or v_amt <= 0 or v_amt <> round(v_amt, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  if v_amt > g.balance + 0.004 then perform booking._err('insufficient_balance', format('Kortin saldo on %s €', g.balance)); end if;
  if v_amt > v_unpaid + 0.004 then perform booking._err('amount_exceeds_unpaid', format('Summa ylittää maksamattoman osuuden (%s €)', v_unpaid)); end if;
  -- rivittömät paikkaajat ja avoimet linkit peruutetaan (kuten admin_record_payment); linkki luodaan tarvittaessa uudelleen jäännökselle
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu lahjakorttimaksulla')
   where order_id = o.id and status = 'pending' and external_source is null
     and ((provider = 'manual' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id)) or provider <> 'manual');
  insert into booking.payments(order_id, method, provider, status, amount, gift_card_id, note, created_by)
  values (o.id, 'gift_card', 'manual', 'pending', v_amt, g.id, nullif(concat_ws(' | ', 'Lahjakortti …' || right(g.code, 4), p_note), ''), auth.uid()) returning id into v_id;
  perform booking._alloc_payment_lines(v_id);
  update booking.payments set status = 'paid', paid_at = now() where id = v_id;       -- trigger: kuitti vain jos ALV kirjautuu lunastuksessa (ks. _acct_excluded)
  perform booking._gc_apply(g.id, -v_amt, 'redemption', o.id, v_id, p_note);
  select * into v_card from booking.gift_cards where id = g.id;
  if v_card.single_order and v_card.balance > 0 then
    perform booking._gc_apply(g.id, -v_card.balance, 'single_order_forfeit', o.id, v_id, 'Kertakäyttökortti: jäännös ei käytettävissä');
    select * into v_card from booking.gift_cards where id = g.id;
  end if;
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o.id and status = 'pending';
  update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = o.id and status = 'pending';
  v_excl := booking._acct_excluded(o.id, v_id);
  select receipt_no, id into rc from booking.receipts where payment_id = v_id and kind = 'receipt';
  return jsonb_build_object('ok', true, 'payment_id', v_id, 'amount', v_amt, 'order_id', o.id, 'balance', booking._order_balance(o.id),
    'gift_card', jsonb_build_object('id', v_card.id, 'code_last4', right(v_card.code, 4), 'balance', v_card.balance, 'status', v_card.status, 'valid_to', v_card.valid_to),
    'receipt_id', rc.id, 'receipt_no', rc.receipt_no, 'accounted', not v_excl);
end $function$;

CREATE OR REPLACE FUNCTION booking.public_apply_gift_card(p_token uuid, p_code text, p_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; g booking.gift_cards; v_norm text := booking.gift_code_norm(p_code); v_res jsonb; v_detail text; v_msg text;
begin
  if booking._gc_rl_blocked() then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then
    perform booking._gc_log('invalid');
    return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy');
  end if;
  select * into g from booking.gift_cards where code = v_norm and v_norm ~ '^[A-Z0-9]{12}$';
  if not found or g.status in ('cancelled', 'pending_payment') then
    perform booking._gc_log('invalid');
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', 'Koodia ei löydy tai se ei ole käytettävissä');
  end if;
  begin
    v_res := booking._gc_redeem(o.id, g.id, p_amount, 'Verkkokauppa', true);
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    perform booking._gc_log('ok');
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  perform booking._gc_log('ok');
  return jsonb_build_object('ok', true, 'amount', v_res -> 'amount', 'balance', v_res -> 'balance', 'gift_card', (v_res -> 'gift_card') - 'id', 'payment_id', v_res -> 'payment_id');
end $function$;

CREATE OR REPLACE FUNCTION booking.payments_paid_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if booking._acct_excluded(new.order_id, new.id) then return null; end if;   -- Johku-historia (tilaus tai maksu) ei kuittiin
  perform booking._alloc_payment_lines(new.id);
  if new.method = 'cash' and new.rounding = 0 then
    update booking.payments set rounding = booking._cash_rounding(new.amount) where id = new.id;
  end if;
  perform booking._on_payment_paid(new.id);
  return null;
end $function$;

CREATE OR REPLACE FUNCTION booking.orders_confirmed_mail_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.external_source is not null then return null; end if;
  if booking._enqueue_email('order_confirmation', new.id, null, null, 'order_confirmation:' || new.id) then
    update booking.email_outbox set next_attempt_at = now() + interval '45 seconds' where dedupe_key = 'order_confirmation:' || new.id;
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION booking.payment_mark_paid(p_provider text, p_provider_ref text, p_amount numeric, p_raw jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments;
begin
  select * into pay from booking.payments where provider = p_provider and provider_ref = p_provider_ref for update;
  if not found then perform booking._err('payment_not_found', 'Maksua ei löydy'); end if;
  if pay.status = 'paid' then return jsonb_build_object('ok', true, 'already', true); end if;
  if p_amount is not null and p_amount <> pay.amount then perform booking._err('amount_mismatch', 'Summa ei täsmää'); end if;
  update booking.payments set status = 'paid', paid_at = now(), provider_status = 'paid', raw = coalesce(p_raw, raw) where id = pay.id;
  perform booking._refresh_order_payment(pay.order_id);
  -- vahvista pitovaraukset; jos pito ehti vanhentua ja aika on mennyt, trigger estää → tilaus jää tarkistettavaksi
  begin
    update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = pay.order_id and status in ('pending','expired');
    update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = pay.order_id;
  exception when sqlstate 'BK001' then
    update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || 'MAKSETTU MUTTA AIKA EI ENÄÄ VAPAA – tarkista käsin / palauta maksu' where id = pay.order_id;
    return jsonb_build_object('ok', true, 'needs_manual_review', true);
  end;
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION booking.mobilepay_payment_confirmable(p_reference text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments; o booking.orders;
begin
  select * into pay from booking.payments where provider = 'mobilepay' and provider_ref = p_reference for update;
  if not found then return jsonb_build_object('confirmable', false, 'reason', 'payment_not_found'); end if;
  if pay.status = 'paid' then return jsonb_build_object('confirmable', true, 'reason', 'already_paid'); end if;
  if pay.status <> 'pending' then return jsonb_build_object('confirmable', false, 'reason', 'payment_' || pay.status); end if;
  select * into o from booking.orders where id = pay.order_id for update;
  if o.status in ('cancelled', 'draft') then return jsonb_build_object('confirmable', false, 'reason', 'order_' || o.status); end if;
  begin
    update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = pay.order_id and status in ('pending', 'expired');
    update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = pay.order_id;
    raise exception 'mobilepay_probe' using errcode = 'P0001';
  exception
    when sqlstate 'BK001' then return jsonb_build_object('confirmable', false, 'reason', 'slot_lost');
    when exclusion_violation then return jsonb_build_object('confirmable', false, 'reason', 'slot_lost');
    when sqlstate 'P0001' then
      if sqlerrm = 'mobilepay_probe' then return jsonb_build_object('confirmable', true, 'reason', 'ok'); end if;
      raise;
  end;
end $function$;

CREATE OR REPLACE FUNCTION booking.mobilepay_payment_prepare(p_order_token uuid DEFAULT NULL::uuid, p_link_token uuid DEFAULT NULL::uuid, p_expires_minutes integer DEFAULT 120)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._mobilepay_mode(); o booking.orders; pay booking.payments; v_tot numeric; v_unpaid numeric; v_open booking.payments;
  v_super jsonb := '[]'::jsonb; v_raw jsonb; v_mp jsonb; v_att int; v_ref text; v_id bigint; v_exp timestamptz; r record; v_started timestamptz;
begin
  if v_mode = 'off' then perform booking._err('mobilepay_off', 'MobilePay-verkkomaksu ei ole käytössä'); end if;
  if (p_order_token is null) = (p_link_token is null) then perform booking._err('invalid_param', 'Anna joko p_order_token tai p_link_token'); end if;
  if p_expires_minutes is null or p_expires_minutes < 15 or p_expires_minutes > 1440 then perform booking._err('invalid_param', 'Voimassaolo 15–1440 min'); end if;
  if not booking._rate_limit('mpstart:' || coalesce(p_order_token, p_link_token)::text, 12, interval '10 minutes') then perform booking._err('rate_limited', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;

  if p_link_token is not null then
    select * into pay from booking.payments where link_token = p_link_token for update;
    if not found then perform booking._err('not_found', 'Maksulinkkiä ei löydy'); end if;
    select * into o from booking.orders where id = pay.order_id for update;
  else
    select * into o from booking.orders where public_token = p_order_token for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  end if;
  if o.external_source is not null then perform booking._err('order_not_payable', 'Tilausta ei voi maksaa verkossa'); end if;       -- Johku-eristys
  if o.status not in ('pending', 'confirmed', 'completed', 'expired') then perform booking._err('order_not_payable', 'Tilausta ei voi maksaa verkossa'); end if;
  if o.currency <> 'EUR' then perform booking._err('unsupported_currency', 'Vain EUR tuettu'); end if;
  v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;

  if p_link_token is not null then
    if pay.status = 'paid' then perform booking._err('already_paid', 'Maksu on jo maksettu'); end if;
    if pay.status <> 'pending' then perform booking._err('payment_not_pending', 'Maksulinkki ei ole enää voimassa'); end if;
    if pay.provider not in ('visma_pay', 'mobilepay') then perform booking._err('payment_not_online', 'Ei verkkomaksu'); end if;
    if pay.provider = 'visma_pay' and pay.provider_ref is not null then perform booking._err('other_provider_started', 'Maksu on aloitettu toisella maksutavalla'); end if;
    if pay.link_expires_at is not null and pay.link_expires_at < now() then perform booking._err('link_expired', 'Maksulinkki on vanhentunut'); end if;
    if pay.amount > v_unpaid + 0.004 then perform booking._err('link_stale', 'Maksulinkin summa ei vastaa enää maksamatonta osuutta – pyydä uusi linkki'); end if;
    if pay.provider = 'visma_pay' then   -- asiakas valitsi MobilePayn maksulinkin sivulla: siirretään maksu MobilePaylle
      update booking.payments set provider = 'mobilepay', method = 'mobilepay', note = concat_ws(' | ', note, 'vaihdettu MobilePaylle') where id = pay.id returning * into pay;
    end if;
  else
    select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
    v_tot := least(v_tot, v_unpaid);
    if v_tot <= 0.004 then
      if exists (select 1 from booking.payments where order_id = o.id and status in ('paid', 'partially_refunded', 'refunded')) then perform booking._err('already_paid', 'Tilaus on jo maksettu'); end if;
      perform booking._err('nothing_to_pay', 'Ei maksettavaa');
    end if;
    if exists (select 1 from booking.payments where order_id = o.id and status = 'pending' and provider = 'visma_pay' and provider_ref is not null and (link_expires_at is null or link_expires_at > now())) then
      perform booking._err('other_provider_started', 'Maksu on aloitettu toisella maksutavalla');
    end if;
    select * into v_open from booking.payments where order_id = o.id and status = 'pending' and provider = 'mobilepay' and (link_expires_at is null or link_expires_at > now()) and amount = v_tot
      order by id desc limit 1 for update;
    if found then
      pay := v_open;
    else
      for r in select id, provider_ref, raw from booking.payments where order_id = o.id and status = 'pending' and provider in ('mobilepay', 'visma_pay') for update loop
        if r.provider_ref is not null and coalesce(r.raw -> 'mobilepay' ->> 'last_state', 'CREATED') = 'CREATED' then
          v_super := v_super || jsonb_build_array(r.provider_ref);
        end if;
        update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu uudella MobilePay-maksulla') where id = r.id;
      end loop;
      v_exp := now() + make_interval(mins => p_expires_minutes);
      insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, note)
      values (o.id, 'mobilepay', 'mobilepay', 'pending', v_tot, o.currency, v_exp, 'MobilePay-verkkomaksu') returning * into pay;
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
      update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) - v_tot)
       where id = (select id from booking.payment_lines where payment_id = pay.id order by amount_gross desc, id limit 1)
         and (select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) > v_tot;
    end if;
  end if;

  v_raw := coalesce(pay.raw, '{}'::jsonb); v_mp := coalesce(v_raw -> 'mobilepay', '{}'::jsonb);
  v_started := nullif(v_mp ->> 'attempt_started_at', '')::timestamptz;
  -- sama yritys vielä kesken (alle 8 min, Vipps-maksu luotu, ei lopputilaa): käytetään samaa ohjausosoitetta
  if pay.provider_ref is not null and pay.link_url is not null and coalesce(v_mp ->> 'last_state', 'CREATED') = 'CREATED' and v_started is not null and v_started > now() - interval '8 minutes' then
    return jsonb_build_object('ok', true, 'reuse', true, 'payment_id', pay.id, 'reference', pay.provider_ref, 'redirect_url', pay.link_url, 'order_no', o.order_no, 'order_token', o.public_token, 'mode', v_mode);
  end if;
  if pay.provider_ref is not null and coalesce(v_mp ->> 'last_state', 'CREATED') = 'CREATED' then
    v_super := v_super || jsonb_build_array(pay.provider_ref);   -- edellinen keskeneräinen yritys perutaan Vippsissä
  end if;
  v_att := coalesce((v_mp ->> 'attempts')::int, 0) + 1;
  v_ref := 'sauna-o' || o.order_no || '-p' || pay.id || '-a' || v_att;
  v_mp := v_mp || jsonb_build_object('attempts', v_att, 'attempt_started_at', now(), 'last_state', null, 'env', v_mode,
                                     'refs', coalesce(v_mp -> 'refs', '[]'::jsonb) || to_jsonb(v_ref));
  update booking.payments set provider_ref = v_ref, provider_status = 'initiating', link_url = null, raw = jsonb_set(v_raw, '{mobilepay}', v_mp, true) where id = pay.id;
  perform booking._refresh_order_payment(o.id);
  return jsonb_build_object('ok', true, 'reuse', false, 'payment_id', pay.id, 'reference', v_ref, 'attempt', v_att, 'amount', pay.amount, 'amount_minor', round(pay.amount * 100)::bigint,
    'currency', pay.currency, 'order_id', o.id, 'order_no', o.order_no, 'order_token', o.public_token, 'locale', o.locale, 'mode', v_mode, 'superseded', v_super,
    'description', left('Sipoonjoen perinnesauna – tilaus ' || o.order_no, 100),
    'site_base_url', booking._setting('site_base_url', null) #>> '{}', 'order_page_path', booking._setting('order_page_path', to_jsonb('/tilaus/'::text)) #>> '{}');
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
    v_can := v_mode <> 'off' and o.external_source is null and o.status in ('pending', 'confirmed', 'completed', 'expired') and o.currency = 'EUR' and v_unpaid > 0.004;
    v_pending := exists (select 1 from booking.payments where order_id = o.id and provider = 'mobilepay' and status = 'pending' and (link_expires_at is null or link_expires_at > now()));
    v_order := jsonb_build_object('order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'unpaid', v_unpaid, 'can_pay_online', v_can, 'mobilepay_pending', v_pending);
    if not v_can then v_methods := '[]'::jsonb; end if;
  end if;
  return jsonb_build_object('ok', true, 'online_enabled', v_mode <> 'off', 'methods', v_methods, 'order', v_order);
end $function$;

CREATE OR REPLACE FUNCTION booking.public_get_booking(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; res jsonb; adds jsonb; cust text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_conf_n integer; v_conf_start timestamptz; v_kind text; v_supported boolean;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select split_part(c.name, ' ', 1) into cust from booking.customers c where c.id = o.customer_id;
  select jsonb_agg(jsonb_build_object(
           'product_name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'product_id', r.product_id, 'rule_id', r.rule_id,
           'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'mode', r.mode, 'option', booking._option_json(r.product_option_id),
           'option_label', booking._option_label(r.product_id, o.locale), 'option_label_fi', booking._option_label(r.product_id, 'fi'), 'option_label_en', booking._option_label(r.product_id, 'en'),
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() then 'expired' else r.status end,
           'hold_expires_at', r.hold_expires_at) order by r.starts_at)
    into res
    from booking.order_items it left join booking.reservations r on r.order_item_id = it.id
   where it.order_id = o.id and it.kind = 'reservation';
  select jsonb_agg(jsonb_build_object('addon_id', it.addon_id, 'name', it.product_name, 'name_en', it.price_breakdown ->> 'name_en',
           'quantity', it.quantity, 'unit_price', it.unit_price_gross, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'max_per_person', ad.max_per_person) order by it.id)
    into adds from booking.order_items it left join booking.addons ad on ad.id = it.addon_id where it.order_id = o.id and it.kind = 'addon';
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  -- booking_25: varaustyyppi. 'rules' = sääntöpohjainen (muutettavissa public_change_booking), 'slots' = verkossa tehty hoitovaraus (public_change_treatment_booking), 'other' = ei muutettavissa verkossa (tuonti/ylläpito)
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;
  v_supported := v_kind in ('rules', 'slots');
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status',
           case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) then 'expired' else o.status end,
           'payment_status', o.payment_status, 'total', o.total_gross, 'currency', o.currency, 'created_at', o.created_at,
           'first_name', cust, 'customer_kind', o.customer_kind, 'items', coalesce(res, '[]'::jsonb), 'addons', coalesce(adds, '[]'::jsonb),
           'payment_methods', (select coalesce(jsonb_agg(p.method), '[]'::jsonb) from booking.payments p where p.order_id = o.id),
           'can_change', (o.status = 'confirmed' and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_supported),
           'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end,
           'change_hours_before', v_hours,
           'booking_kind', v_kind, 'change_via', case v_kind when 'slots' then 'public_change_treatment_booking' when 'rules' then 'public_change_booking' end);
end $function$;

CREATE OR REPLACE FUNCTION booking.public_get_order(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; v_cust text; v_bal jsonb; v_end timestamptz; v_conf_n int; v_conf_start timestamptz; v_kind text; v_hours int;
  v_items jsonb; v_res jsonb; v_pay jsonb; v_rec jsonb; v_creq jsonb; v_ups_a jsonb; v_ups_t jsonb; v_can_add boolean; v_pl text; v_open boolean; v_status text; v_online boolean;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._order_rl('get', p_token, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  v_hours := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  select split_part(c.name, ' ', 1) into v_cust from booking.customers c where c.id = o.customer_id;
  v_bal := booking._order_balance(o.id);
  v_status := case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) then 'expired' else o.status end;
  v_online := exists (select 1 from booking.integration_config where key = 'vismapay' and mode = 'live');
  v_pl := booking._setting('payment_link_path', to_jsonb('/maksa/'::text)) #>> '{}';

  select coalesce(jsonb_agg(jsonb_build_object('name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate, 'kind', it.kind) order by it.id), '[]'::jsonb)
    into v_items from booking.order_items it where it.order_id = o.id;
  select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'product_id', r.product_id, 'product_name', oi.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons,
           'option', booking._option_json(r.product_option_id),
           'option_label', booking._option_label(r.product_id, o.locale), 'option_label_fi', booking._option_label(r.product_id, 'fi'), 'option_label_en', booking._option_label(r.product_id, 'en'), 'option_choices', booking._product_options_json(r.product_id),
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() then 'expired' else r.status end,
           'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', a.addon_id, 'name', a.product_name, 'quantity', a.quantity, 'line_total', a.line_total_gross) order by a.id)
                                 from booking.order_items a where a.parent_item_id = r.order_item_id and a.kind = 'addon'), '[]'::jsonb)) order by r.starts_at), '[]'::jsonb)
    into v_res from booking.reservations r left join booking.order_items oi on oi.id = r.order_item_id where r.order_id = o.id and r.hidden_at is null;
  select coalesce(jsonb_agg(jsonb_build_object('status', p.status, 'amount', p.amount, 'paid_at', p.paid_at, 'method_label', coalesce(pm.label, p.method),
           'link_token', case when p.status = 'pending' and p.provider = 'visma_pay' and (p.link_expires_at is null or p.link_expires_at > now()) then p.link_token end,
           'link_path', case when p.status = 'pending' and p.provider = 'visma_pay' and (p.link_expires_at is null or p.link_expires_at > now()) then v_pl || '?p=' || p.link_token end,
           'refunded', p.refunded_amount) order by p.created_at, p.id), '[]'::jsonb)
    into v_pay from booking.payments p left join booking.payment_methods pm on pm.code = p.method
   where p.order_id = o.id and p.status <> 'cancelled'
     and not (p.provider = 'manual' and p.status = 'pending' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id));
  select coalesce(jsonb_agg(jsonb_build_object('receipt_no', x.receipt_no, 'kind', x.kind, 'issued_at', x.issued_at, 'token', x.public_token, 'total', x.total_gross) order by x.issued_at, x.id), '[]'::jsonb)
    into v_rec from booking.receipts x where x.order_id = o.id;
  select jsonb_build_object('status', q.status, 'created_at', q.created_at) into v_creq from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' order by q.created_at desc, q.id desc limit 1;

  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  v_can_add := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now();
  v_open := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not exists (select 1 from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' and q.status = 'open');
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;

  if v_can_add then
    select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'name_en', a.name_en, 'description', a.description, 'description_en', a.description_en, 'price', a.price_gross, 'vat_rate', a.vat_rate,
             'max', x.lim, 'reservation_ids', x.rids) order by a.sort_order, a.id), '[]'::jsonb) into v_ups_a
      from booking.addons a
      join lateral (select max(booking._addon_limit(a.max_per_person, r.persons)) lim, jsonb_agg(r.id order by r.id) rids
                      from booking.reservations r left join booking.product_config pc on pc.product_id = r.product_id left join kb.products p on p.id = r.product_id
                     where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at) and r.ends_at > now()
                       and coalesce(case when pc.sale_kind = 'other' and pc.resource_class = 'resourced' then case when p.category = 'event' then 'event' else 'resource' end else r.mode end, r.mode) = any (a.applies_modes)) x on x.rids is not null
     where a.active;
    select coalesce(jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'name_en', p.name_en, 'price', p.price, 'duration_minutes', coalesce(pc.duration_minutes, p.duration_minutes),
             'description', p.description, 'description_en', p.description_en, 'category', p.category) order by pc.sort_order, p.id), '[]'::jsonb) into v_ups_t
      from booking.product_config pc join kb.products p on p.id = pc.product_id
     where pc.public_slots and pc.bookable and pc.shop_visible and pc.lifecycle = 'current' and p.active and p.price is not null;
  end if;

  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status', v_status, 'payment_status', o.payment_status, 'currency', o.currency, 'locale', coalesce(o.locale, 'fi'),
    'created_at', o.created_at, 'first_name', v_cust, 'customer_kind', o.customer_kind,
    'total', v_bal -> 'total', 'paid', v_bal -> 'net_paid', 'refunded', v_bal -> 'refunded', 'unpaid', v_bal -> 'unpaid',
    'items', v_items, 'reservations', v_res, 'payments', v_pay, 'receipts', v_rec,
    'can_add', v_can_add, 'add_until', case when v_can_add then v_end end,
    'can_change', (o.status = 'confirmed' and o.external_source is null and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_kind in ('rules', 'slots')),
    'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end, 'change_hours_before', v_hours,
    'change_via', case v_kind when 'slots' then 'public_change_order_time' when 'rules' then 'public_change_order_time' end, 'booking_kind', v_kind,
    'can_request_cancel', v_open, 'cancel_request', v_creq, 'online_payment_enabled', v_online,
    'upsell', jsonb_build_object('addons', coalesce(v_ups_a, '[]'::jsonb), 'treatments', coalesce(v_ups_t, '[]'::jsonb)));
end $function$;

create or replace function booking.public_checkout_payment_options() returns jsonb language plpgsql stable security definer set search_path = '' as $$
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
  return jsonb_build_object('ok', true, 'methods', v_m, 'mobilepay_enabled', v_mp <> 'off', 'gift_card_redeem_enabled', v_gc);
end $$;

CREATE OR REPLACE FUNCTION booking._expire_holds(p_space bigint DEFAULT NULL::bigint, p_except bigint DEFAULT NULL::bigint)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n integer;
begin
  with e as (
    update booking.reservations r
       set status = 'expired', cancelled_at = coalesce(r.cancelled_at, now()), cancel_reason = coalesce(r.cancel_reason, 'hold_expired')
     where r.status = 'pending' and r.hold_expires_at <= now()
       and (p_space is null or r.space_id = p_space)
       and r.id is distinct from p_except
    returning r.order_id
  ), o as (
    update booking.orders o set status = 'expired'
     where o.id in (select order_id from e) and o.status = 'pending' and o.payment_status in ('unpaid','pending')
       and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status in ('pending','confirmed'))
    returning 1
  )
  select count(*) into n from e;
  return n;
end $function$;

drop function if exists booking._checkout_release_gift_cards(bigint[]);
drop function if exists booking._checkout_state_json(bigint);
drop function if exists booking._checkout_extend_hold(bigint);
drop function if exists booking._order_mp_inflight(bigint);
drop function if exists booking._checkout_online_available();
drop function if exists booking._checkout_hold_minutes();
drop function if exists booking._checkout_cfg_int(text, int, int, int);
delete from booking.settings where key in ('checkout_hold_minutes','checkout_mobilepay_grace_minutes','checkout_mobilepay_max_wait_minutes','checkout_group_threshold_persons','checkout_group_hold_days','checkout_company_invoice_enabled');
alter table booking.orders drop constraint if exists orders_hold_kind_check;
alter table booking.orders drop column if exists hold_kind;
