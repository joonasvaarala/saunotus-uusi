-- ROLLBACK booking_162 (migraatio 20261024184729_booking_162_quiet_discounts.sql). Uudelleenajettava (toinen ajo ei tee mitään).
-- HUOM: poistaa taulun booking.quiet_discount_rules (säännöt) ja asetuksen quiet_discounts.enabled pysyvästi.
-- Jo tehtyjen varausten lukitut hinnat (order_items.line_total_gross / discount_amount / price_breakdown.quiet) jäävät ennalleen.
-- Ota ennen ajoa talteen: select * from booking.quiet_discount_rules; select * from booking.settings where key = 'quiet_discounts.enabled';
-- Palauttaa funktiot täsmälleen tuotannon muotoon ennen booking_162:ta (pg_get_functiondef-tuloste sellaisenaan). Odotetut md5(pg_get_functiondef) ajon jälkeen:
--   booking.public_create_booking:      f7b15dca769f5fb4abfd9f81090718ac
--   booking.public_create_booking_code: 31a03d52526c7b22d2643be477589b7f
--   booking.public_preview_code:        aaac81dc8ae5704a67b56184e5cd4cd7
-- Tarkistus: select p.proname, md5(pg_get_functiondef(p.oid)) from pg_proc p where p.pronamespace = 'booking'::regnamespace
--   and p.proname in ('public_create_booking','public_create_booking_code','public_preview_code') order by 1;
set local lock_timeout = '5s';

-- ensin vanhat funktiot takaisin (eivät viittaa uusiin objekteihin), sitten uudet objektit pois
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
  v_hold int; v_invoice boolean; v_hold_mode boolean; v_group boolean; v_thr int := booking._checkout_cfg_int('checkout_group_threshold_persons', 0, 0, 1000);
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

  -- booking_53: pitotila (public_payment_mode <> 'pay_later'): varaus odottaa maksua; yritysasiakas laskulle jos checkout_company_invoice_enabled
  v_invoice := v_is_company and coalesce((booking._setting('checkout_company_invoice_enabled', 'true'::jsonb) #>> '{}')::boolean, true);
  v_hold_mode := v_mode <> 'pay_later' and not v_invoice;
  v_group := v_hold_mode and v_thr > 0 and p_persons >= v_thr;
  if v_hold_mode and not v_group and not booking._checkout_online_available() then
    return jsonb_build_object('ok', false, 'code', 'online_payment_unavailable', 'message', 'Verkkomaksu ei ole tilapäisesti käytettävissä – varausta ei voi tehdä juuri nyt');
  end if;
  v_status := case when v_hold_mode then 'pending' else 'confirmed' end;
  v_pay_method := case when v_is_company then 'invoice' else 'pay_later' end;
  v_pay_provider := 'manual';
  v_hold := case when v_group then booking._checkout_cfg_int('checkout_group_hold_days', 7, 1, 60) * 1440 else booking._checkout_hold_minutes() end;

  begin  -- alitransaktio: virhe kumoaa asiakkaan/tilauksen/varauksen luonnin mutta rate limit -kirjaus säilyy
    -- booking_139: jonotuspidon haltija (sama sähköposti, voimassa oleva pito tähän vuoroon) ei kilpaile omaa pitoaan vastaan.
    -- Transaktiokohtainen asetus; virhe kumoaa sen alitransaktion mukana, onnistuneen luonnin jälkeen se nollataan alla.
    perform set_config('booking.waitlist_hold_exempt', coalesce((select w.id::text from booking.waitlist_entries w
      where w.rule_id = p_rule_id and w.session_date = p_date and lower(w.customer_email) = v_email
        and w.status = 'notified' and w.hold_expires_at > now() order by w.id limit 1), ''), true);
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
    if not v_hold_mode then   -- pitotilassa ei luoda paikkaajamaksua: maksu syntyy vasta kun asiakas maksaa (MobilePay / lahjakortti)
      insert into booking.payments(order_id, method, provider, status, amount)
      values ((v_res ->> 'order_id')::bigint, v_pay_method, v_pay_provider, 'pending', v_total);
    end if;
    update booking.orders set payment_status = 'unpaid', hold_kind = case when v_hold_mode then (case when v_group then 'preliminary' else 'checkout' end) end
     where id = (v_res ->> 'order_id')::bigint;
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  perform set_config('booking.waitlist_hold_exempt', '', true);

  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token',
                            'status', v_status, 'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at',
                            'total', v_total, 'addons_total', v_add, 'hold_expires_at', v_res -> 'hold_expires_at',
                            'payment_mode', v_mode, 'payment_url', null, 'product_name', v_res -> 'product_name', 'customer_kind', v_kind)
         || booking._checkout_state_json((v_res ->> 'order_id')::bigint);
end $function$;

CREATE OR REPLACE FUNCTION booking.public_create_booking_code(p_rule_id bigint, p_date date, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_addons jsonb DEFAULT NULL::jsonb, p_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_code text := booking._norm_code(p_code); v_ip text := booking._client_ip();
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private')));
  v_card booking.annual_cards; d booking.discount_codes; v_res jsonb; v_order booking.orders; v_cust bigint; v_err text; v_detail text; v_msg text;
  v_lines jsonb; v_calc jsonb; s jsonb; v_disc numeric; v_total numeric; pr record; v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}';
begin
  if v_code = '' then
    return booking.public_create_booking(p_rule_id, p_date, p_persons, p_name, p_email, p_phone, p_marketing_consent, p_locale, p_note,
                                         p_customer_kind, p_company, p_addons);
  end if;
  if char_length(v_code) > 40 then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  if not booking._code_rate_ok(v_code, v_email, v_phone, v_ip) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
  end if;
  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code for update; end if;
  if v_card.id is null and d.id is null then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  -- booking_143: henkilökohtainen kortti, jonka omistaja ei täsmää → sama vastaus kuin tuntemattomalla koodilla (ennen muita tarkistuksia)
  if v_card.id is not null and not booking._annual_card_owner_ok(v_card, v_email, v_phone) then
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code'));
  end if;

  -- ---- vuosikortti / yhteinen vuosikorttikoodi
  if v_card.id is not null or d.is_annual_card_code then
    if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
      return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
    end if;
    if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
      return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
    end if;
    if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
      return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
    end if;
    if char_length(v_name) < 2 or char_length(v_name) > 120 then return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', 'Anna nimi'); end if;
    if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
    if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
    if p_note is not null and char_length(p_note) > 1000 then return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä'); end if;
    if p_date is null or p_date < (now() at time zone booking._tz())::date
       or p_date > (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int then
      return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
    end if;
    v_err := case
      when v_kind <> 'private' then 'annual_card_private_only'
      when p_addons is not null and jsonb_typeof(p_addons) = 'array' and exists (select 1 from jsonb_array_elements(p_addons) x where coalesce(x ->> 'quantity', '0') <> '0') then 'annual_card_no_addons'
      when p_persons is distinct from booking._annual_max_persons() then 'annual_card_persons'
      else booking._annual_rule_check(p_rule_id, p_date, v_card, d) end;
    if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
    begin
      if v_card.id is not null then v_cust := v_card.customer_id;
      else
        v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale,
                                           (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
      end if;
      perform booking._annual_lock_identity(v_cust, v_email, v_phone);
      if booking._annual_limit(v_cust, v_email, v_phone) then perform booking._err('annual_card_limit', booking._code_msg('annual_card_limit')); end if;
      -- henkilökohtaisen kortin rivin alennus (alkuperäinen hinta) kirjataan triggerissä reservations_annual_discount
      v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, 'web', null, p_locale, p_note, 'confirmed', null, true,
                                            null, null, case when v_card.id is null then 0 end, v_card.id);
      if d.id is not null then
        select * into pr from booking._rule_price(p_rule_id, p_persons);
        update booking.order_items set discount_code_id = d.id, discount_amount = pr.total
         where order_id = (v_res ->> 'order_id')::bigint and kind = 'reservation';
        update booking.orders set discount_code_id = d.id where id = (v_res ->> 'order_id')::bigint;
        update booking.discount_codes set used_count = used_count + 1 where id = d.id;
      end if;
      insert into booking.payments(order_id, method, provider, status, amount, paid_at, note)
      values ((v_res ->> 'order_id')::bigint, 'annual_card', 'manual', 'paid', 0, now(), 'Vuosikorttivaraus verkossa (' || v_code || ')');
      update booking.orders set payment_status = 'paid' where id = (v_res ->> 'order_id')::bigint;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
    end;
    return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token', 'status', 'confirmed',
                              'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at', 'total', 0, 'addons_total', 0,
                              'hold_expires_at', null, 'payment_mode', v_mode, 'payment_url', null, 'product_name', v_res -> 'product_name',
                              'customer_kind', 'private', 'code_type', case when v_card.id is not null then 'annual_card' else 'annual_code' end,
                              'discount', (select coalesce(sum(discount_amount), 0) from booking.order_items where order_id = (v_res ->> 'order_id')::bigint))
           || booking._checkout_state_json((v_res ->> 'order_id')::bigint);
  end if;

  -- ---- alennuskoodi
  v_err := booking._discount_state(d);
  if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
  begin
    v_res := booking.public_create_booking(p_rule_id, p_date, p_persons, p_name, p_email, p_phone, p_marketing_consent, p_locale, p_note,
                                           p_customer_kind, p_company, p_addons);
    if not coalesce((v_res ->> 'ok')::boolean, false) then return v_res; end if;
    select * into v_order from booking.orders where public_token = (v_res ->> 'token')::uuid for update;
    select coalesce(jsonb_agg(jsonb_build_object('key', oi.id, 'product_id', oi.product_id, 'kind', oi.kind, 'gross', oi.line_total_gross) order by oi.id), '[]'::jsonb)
      into v_lines from booking.order_items oi where oi.order_id = v_order.id;
    v_calc := booking._discount_split(d, v_lines);
    v_disc := (v_calc ->> 'discount')::numeric;
    if v_disc <= 0 then perform booking._err('code_not_applicable', booking._code_msg('code_not_applicable')); end if;
    for s in select x from jsonb_array_elements(v_calc -> 'shares') x loop
      update booking.order_items set discount_code_id = d.id, discount_amount = coalesce(discount_amount, 0) + (s ->> 'amount')::numeric,
             line_total_gross = line_total_gross - (s ->> 'amount')::numeric
       where id = (s ->> 'key')::bigint and order_id = v_order.id;
    end loop;
    update booking.orders set discount_code_id = d.id,
           total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = v_order.id), 0)
     where id = v_order.id returning total_gross into v_total;
    update booking.discount_codes set used_count = used_count + 1 where id = d.id;
    if v_total > 0 then
      update booking.payments set amount = v_total where order_id = v_order.id and status = 'pending' and provider = 'manual';
    else   -- 100 % alennus: ei maksettavaa → vahvistetaan heti
      update booking.payments set status = 'cancelled' where order_id = v_order.id and status = 'pending';
      insert into booking.payments(order_id, method, provider, status, amount, paid_at, note)
      values (v_order.id, 'other', 'manual', 'paid', 0, now(), 'Alennuskoodi ' || d.code || ' (100 %)');
      update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = v_order.id and status = 'pending';
      update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()), hold_kind = null where id = v_order.id and status = 'pending';
      update booking.orders set payment_status = 'paid' where id = v_order.id;
    end if;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  select * into v_order from booking.orders where id = v_order.id;
  return v_res || jsonb_build_object('total', v_total, 'status', v_order.status, 'hold_expires_at',
                    (select min(hold_expires_at) from booking.reservations where order_id = v_order.id and status = 'pending'),
                    'discount', v_disc, 'discount_code', d.code, 'code_type', 'discount',
                    'addons_total', (select coalesce(sum(line_total_gross), 0) from booking.order_items where order_id = v_order.id and kind = 'addon'))
                || booking._checkout_state_json(v_order.id);
end $function$;

CREATE OR REPLACE FUNCTION booking.public_preview_code(p_code text, p_rule_id bigint, p_date date, p_persons integer, p_addons jsonb DEFAULT NULL::jsonb, p_email text DEFAULT NULL::text, p_phone text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_code text := booking._norm_code(p_code); v_ip text := booking._client_ip(); v_card booking.annual_cards; d booking.discount_codes;
  r booking.schedule_rules; pr record; v_lines jsonb := '[]'::jsonb; v_sub numeric; v_err text; v_calc jsonb; e jsonb; a booking.addons; v_q int;
begin
  if v_code = '' or char_length(v_code) > 40 then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  select * into r from booking.schedule_rules where id = p_rule_id and active;
  if r.id is null or p_persons is null or p_persons < 1 or p_persons > 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_session', 'message', 'Valitse vuoro ja henkilömäärä');
  end if;
  select * into pr from booking._rule_price(p_rule_id, p_persons);
  v_lines := jsonb_build_array(jsonb_build_object('key', 0, 'product_id', r.product_id, 'kind', 'reservation', 'gross', pr.total));
  v_sub := pr.total;
  if p_addons is not null and jsonb_typeof(p_addons) = 'array' then
    for e in select x from jsonb_array_elements(p_addons) x limit 20 loop
      continue when jsonb_typeof(e) <> 'object' or coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' or coalesce(e ->> 'id', '') !~ '^\d{1,18}$';
      v_q := (e ->> 'quantity')::int; continue when v_q = 0;
      select * into a from booking.addons where id = (e ->> 'id')::bigint and active;
      continue when a.id is null;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('key', a.id, 'product_id', null, 'kind', 'addon', 'gross', a.price_gross * v_q));
      v_sub := v_sub + a.price_gross * v_q;
    end loop;
  end if;

  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code; end if;
  if v_card.id is null and d.id is null then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  -- booking_143: henkilökohtainen kortti + yhteystiedot, jotka eivät ole omistajan → sama vastaus kuin tuntemattomalla koodilla
  if v_card.id is not null and (nullif(btrim(coalesce(p_email, '')), '') is not null or booking._phone_key(p_phone) is not null)
     and not booking._annual_card_owner_ok(v_card, p_email, p_phone) then
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code'));
  end if;

  if v_card.id is not null or d.is_annual_card_code then
    v_err := booking._annual_rule_check(p_rule_id, p_date, v_card, d);
    if v_err is null and (nullif(btrim(coalesce(p_email, '')), '') is not null or booking._phone_key(p_phone) is not null)
       and booking._annual_limit(v_card.customer_id, p_email, p_phone) then v_err := 'annual_card_limit'; end if;
    if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
    select * into pr from booking._rule_price(p_rule_id, booking._annual_max_persons());
    return jsonb_build_object('ok', true, 'type', case when v_card.id is not null then 'annual_card' else 'annual_code' end, 'code', v_code,
      'persons', booking._annual_max_persons(), 'addons_allowed', false, 'subtotal', pr.total, 'discount', pr.total, 'total', 0,
      'valid_to', coalesce(v_card.valid_to, d.valid_to));
  end if;

  v_err := booking._discount_state(d);
  if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
  v_calc := booking._discount_split(d, v_lines);
  if (v_calc ->> 'discount')::numeric <= 0 then
    return jsonb_build_object('ok', false, 'code', 'code_not_applicable', 'message', booking._code_msg('code_not_applicable'));
  end if;
  return jsonb_build_object('ok', true, 'type', 'discount', 'code', v_code, 'kind', d.kind, 'value', d.value, 'subtotal', v_sub,
    'discount', (v_calc ->> 'discount')::numeric, 'total', v_sub - (v_calc ->> 'discount')::numeric, 'addons_allowed', true);
end $function$;

drop trigger if exists order_items_quiet_reset on booking.order_items;
drop function if exists booking._order_items_quiet_reset_trg();
drop function if exists booking.public_quiet_offers(date, date, text);
drop function if exists booking.admin_quiet_preview(date, integer);
drop function if exists booking.admin_quiet_set_enabled(boolean);
drop function if exists booking.admin_quiet_rule_delete(bigint);
drop function if exists booking.admin_quiet_rule_upsert(bigint, jsonb);
drop function if exists booking.admin_quiet_rules_list();
drop function if exists booking._quiet_apply(bigint, jsonb);
drop function if exists booking._quiet_for_rule(bigint, date);
drop function if exists booking._quiet_offers(date, date, bigint, boolean);
do $d$ begin
  if to_regclass('booking.quiet_discount_rules') is not null then
    drop function if exists booking._quiet_rule_json(booking.quiet_discount_rules);
  end if;
end $d$;
drop table if exists booking.quiet_discount_rules;
delete from booking.settings where key = 'quiet_discounts.enabled';

do $c$
declare r record;
begin
  for r in select * from (values
      ('booking.public_create_booking(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb)', 'f7b15dca769f5fb4abfd9f81090718ac'),
      ('booking.public_create_booking_code(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb,text)', '31a03d52526c7b22d2643be477589b7f'),
      ('booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)', 'aaac81dc8ae5704a67b56184e5cd4cd7')
    ) x(sig, md5)
  loop
    if md5(pg_get_functiondef(r.sig::regprocedure)) <> r.md5 then
      raise exception 'booking_162 rollback: % md5 % ≠ tuotannon %', r.sig, md5(pg_get_functiondef(r.sig::regprocedure)), r.md5;
    end if;
  end loop;
end $c$;
