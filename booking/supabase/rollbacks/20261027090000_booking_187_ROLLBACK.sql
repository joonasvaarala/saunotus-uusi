-- booking_187 ROLLBACK: palauttaa F1–F10 tuotannon runkoihin (pg_get_functiondef 2026-10-27) ja pudottaa apufunktion.
-- Aja vasta kun booking_187 on kannassa, tai uudelleen (vartija hyväksyy uuden tai vanhan md5:n).
-- Dataa ei muuteta. billing.invoice_method='online' jää tilauksille. Palautuksen jälkeen ne ovat yritys ilman
-- laskutustapaa: vismapay_payment_prepare, public_payment_options ja public_payment_link_info estävät verkkomaksun
-- taas kaikilta customer_kind='company' -tilauksilta. Laskua ei synny jälkikäteen.
-- Apufunktio pudotetaan vasta kun F5–F7 on palautettu (ne eivät enää viittaa siihen).
set local lock_timeout = '5s';

-- booking._clean_company(jsonb): 019579f7b2a615f691c206aeb214195d -> 53fa5a8a98e98aeb4a97000d2f6b37ec
-- booking._stamp_order_billing(bigint,bigint,jsonb): ded4c037a352e2b65b6f5e3100643334 -> 693f24abfe0dddfbf4a2e345e1596e73
-- booking.public_create_booking(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb): 6bf51ffd45c259ef5546aa19f63f5066 -> befba768679c4e414c4f3966ac4aa136
-- booking.public_create_treatment_booking(bigint,timestamptz,integer,text,text,text,boolean,text,text,text,jsonb,text,jsonb): ece168b714a2478bd8a1e5d31f6e6fb7 -> d47cd6e939943cb2cfa385c0767bc2cb
-- booking.vismapay_payment_prepare(uuid,uuid): d1f8df803a45c2b77aa9f8554fc41890 -> cca997c4e900e78b8bb9e2e0c7da25d4
-- booking.public_payment_options(uuid): 46834d95db5127935ad94e8759758ceb -> 07937cf049df18f7951e7c827f495f8e
-- booking.public_payment_link_info(uuid): 1b729ef4d72dc925001169c38bad3315 -> 647c556562046c75b7e7e33703c050a0
-- booking.public_get_booking(uuid): 31b07afa6d8e5b61ed9c044d39e76275 -> 3b9187db7f41c94f5d582fcebb132f23
-- booking.public_get_order(uuid): 5d0a5c1623ed4495be2d3ad0173284f1 -> c993d12037a9a9269265ba1cb809291e
-- booking.orders_invoice_status_trg(): 7f7eced664b101cb2672a78059c90682 -> 9ec5c212604145e284fa07d2fd2686f6

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking._clean_company(jsonb)')));
  if v is null or v not in ('019579f7b2a615f691c206aeb214195d', '53fa5a8a98e98aeb4a97000d2f6b37ec') then ok := false; msg := msg || ' _clean_company=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._stamp_order_billing(bigint,bigint,jsonb)')));
  if v is null or v not in ('ded4c037a352e2b65b6f5e3100643334', '693f24abfe0dddfbf4a2e345e1596e73') then ok := false; msg := msg || ' _stamp_order_billing=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_create_booking(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb)')));
  if v is null or v not in ('6bf51ffd45c259ef5546aa19f63f5066', 'befba768679c4e414c4f3966ac4aa136') then ok := false; msg := msg || ' public_create_booking=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_create_treatment_booking(bigint,timestamptz,integer,text,text,text,boolean,text,text,text,jsonb,text,jsonb)')));
  if v is null or v not in ('ece168b714a2478bd8a1e5d31f6e6fb7', 'd47cd6e939943cb2cfa385c0767bc2cb') then ok := false; msg := msg || ' public_create_treatment_booking=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_prepare(uuid,uuid)')));
  if v is null or v not in ('d1f8df803a45c2b77aa9f8554fc41890', 'cca997c4e900e78b8bb9e2e0c7da25d4') then ok := false; msg := msg || ' vismapay_payment_prepare=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_payment_options(uuid)')));
  if v is null or v not in ('46834d95db5127935ad94e8759758ceb', '07937cf049df18f7951e7c827f495f8e') then ok := false; msg := msg || ' public_payment_options=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_payment_link_info(uuid)')));
  if v is null or v not in ('1b729ef4d72dc925001169c38bad3315', '647c556562046c75b7e7e33703c050a0') then ok := false; msg := msg || ' public_payment_link_info=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_get_booking(uuid)')));
  if v is null or v not in ('31b07afa6d8e5b61ed9c044d39e76275', '3b9187db7f41c94f5d582fcebb132f23') then ok := false; msg := msg || ' public_get_booking=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_get_order(uuid)')));
  if v is null or v not in ('5d0a5c1623ed4495be2d3ad0173284f1', 'c993d12037a9a9269265ba1cb809291e') then ok := false; msg := msg || ' public_get_order=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.orders_invoice_status_trg()')));
  if v is null or v not in ('7f7eced664b101cb2672a78059c90682', '9ec5c212604145e284fa07d2fd2686f6') then ok := false; msg := msg || ' orders_invoice_status_trg=' || coalesce(v, 'puuttuu'); end if;
  if not ok then raise exception 'booking_187 rollback: määrittelyt eivät vastaa odotettua:%. Ei muutoksia.', msg; end if;
end $g$;

-- booking._clean_company(jsonb): 019579f7b2a615f691c206aeb214195d -> 53fa5a8a98e98aeb4a97000d2f6b37ec
CREATE OR REPLACE FUNCTION booking._clean_company(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
  v_name text := btrim(coalesce(p ->> 'company_name', p ->> 'name', ''));
  v_bid text := booking._norm_business_id(p ->> 'business_id');
  v_street text := btrim(coalesce(p ->> 'street', p ->> 'address', ''));
  v_zip text := btrim(coalesce(p ->> 'zip', ''));
  v_city text := btrim(coalesce(p ->> 'city', ''));
  v_country text := upper(btrim(coalesce(nullif(p ->> 'country', ''), 'FI')));
  v_ei text := upper(regexp_replace(coalesce(p ->> 'einvoice_address', ''), '\s', '', 'g'));
  v_op text := upper(regexp_replace(coalesce(p ->> 'einvoice_operator', ''), '\s', '', 'g'));
  v_ref text := btrim(coalesce(p ->> 'reference', ''));
  v_req boolean := coalesce((p ->> 'require_einvoice')::boolean, false);
  v_method text := lower(btrim(coalesce(p ->> 'invoice_method', '')));
begin
  if p is null or jsonb_typeof(p) <> 'object' then perform booking._err('invalid_company', 'Anna yrityksen tiedot'); end if;
  -- booking_175: laskutustapa (verkkokauppa): einvoice = verkkolasku (OVT pakollinen), pdf = PDF-lasku sähköpostiin (OVT-tiedot jätetään pois).
  -- Ilman invoice_methodia: require_einvoice = true → einvoice (vanha kauppa), muuten ennallaan (laskutustapaa ei kirjata, OVT valinnainen; hallinta).
  if v_method = '' then v_method := case when v_req then 'einvoice' end; end if;
  if v_method is not null and v_method not in ('einvoice', 'pdf') then perform booking._err('invalid_invoice_method', 'Valitse laskutustapa: verkkolasku tai PDF'); end if;
  if v_method = 'pdf' then v_req := false; v_ei := ''; v_op := ''; end if;
  if v_method = 'einvoice' then v_req := true; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 200 then perform booking._err('invalid_company_name', 'Anna yrityksen nimi'); end if;
  if v_bid is null or not booking._business_id_ok(v_bid) then perform booking._err('invalid_business_id', 'Tarkista y-tunnus (muoto 1234567-8)'); end if;
  if char_length(v_street) < 2 or char_length(v_street) > 200 then perform booking._err('invalid_address', 'Anna yrityksen katuosoite'); end if;
  if v_country !~ '^[A-Z]{2}$' then perform booking._err('invalid_country', 'Tarkista maa (kaksikirjaiminen koodi, esim. FI)'); end if;
  if (v_country = 'FI' and v_zip !~ '^\d{5}$') or (v_country <> 'FI' and v_zip !~ '^[A-Za-z0-9 -]{2,12}$') then perform booking._err('invalid_zip', 'Tarkista postinumero'); end if;
  if char_length(v_city) < 2 or char_length(v_city) > 100 then perform booking._err('invalid_city', 'Anna postitoimipaikka'); end if;
  if v_ei <> '' and v_ei !~ '^[A-Z0-9]{6,35}$' then perform booking._err('invalid_einvoice_address', 'Tarkista verkkolaskuosoite / OVT-tunnus'); end if;
  if v_op <> '' and v_op !~ '^[A-Z0-9]{3,35}$' then perform booking._err('invalid_einvoice_operator', 'Tarkista verkkolaskuoperaattorin välittäjätunnus'); end if;
  if (v_ei = '') <> (v_op = '') then perform booking._err('einvoice_incomplete', 'Anna sekä verkkolaskuosoite että operaattorin välittäjätunnus (tai kumpikaan)'); end if;
  if v_req and (v_ei = '' or v_op = '') then perform booking._err('einvoice_incomplete', 'Verkkolasku: anna OVT-tunnus ja välittäjätunnus'); end if;
  if v_req and not booking._ovt_ok(v_ei, v_bid) then perform booking._err('invalid_einvoice_address', 'Tarkista verkkolaskuosoite. OVT-tunnus alkaa 0037 ja sisältää y-tunnuksen.'); end if;
  if char_length(v_ref) > 100 then perform booking._err('invalid_reference', 'Viite on liian pitkä (enintään 100 merkkiä)'); end if;
  return jsonb_build_object('company_name', v_name, 'business_id', v_bid, 'street', v_street, 'zip', v_zip, 'city', v_city, 'country', v_country,
                            'einvoice_address', nullif(v_ei, ''), 'einvoice_operator', nullif(v_op, ''), 'reference', nullif(v_ref, ''))
         || case when v_method is not null then jsonb_build_object('invoice_method', v_method) else '{}'::jsonb end;
end $function$;

-- booking._stamp_order_billing(bigint,bigint,jsonb): ded4c037a352e2b65b6f5e3100643334 -> 693f24abfe0dddfbf4a2e345e1596e73
CREATE OR REPLACE FUNCTION booking._stamp_order_billing(p_order_id bigint, p_customer_id bigint, p_company jsonb DEFAULT NULL::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c booking.customers; k booking.customer_kinds;
begin
  select * into c from booking.customers where id = p_customer_id;
  if not found then return; end if;
  select * into k from booking.customer_kinds where code = c.customer_kind;
  update booking.orders set
    customer_kind = c.customer_kind,
    billing = case when k.is_company then jsonb_build_object(
        'company', coalesce(p_company ->> 'company_name', c.company), 'business_id', coalesce(p_company ->> 'business_id', c.business_id),
        'street', coalesce(p_company ->> 'street', c.address), 'zip', coalesce(p_company ->> 'zip', c.zip), 'city', coalesce(p_company ->> 'city', c.city),
        'country', coalesce(p_company ->> 'country', c.country),
        -- booking_175: PDF-laskutapa → tilauksen laskutustiedoissa ei OVT-tietoja (ei asiakasrekisterin vanhoja)
        'einvoice_address', case when p_company ->> 'invoice_method' = 'pdf' then null else coalesce(p_company ->> 'einvoice_address', c.einvoice_address) end,
        'einvoice_operator', case when p_company ->> 'invoice_method' = 'pdf' then null else coalesce(p_company ->> 'einvoice_operator', c.einvoice_operator) end,
        'contact_name', c.name, 'contact_phone', c.phone, 'contact_email', c.email)
        || case when p_company ->> 'invoice_method' in ('einvoice', 'pdf') then jsonb_build_object('invoice_method', p_company ->> 'invoice_method') else '{}'::jsonb end end,
    invoice_reference = case when k.is_company then coalesce(nullif(p_company ->> 'reference', ''), c.invoice_reference) end
   where id = p_order_id;
end $function$;

-- booking.public_create_booking(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb): 6bf51ffd45c259ef5546aa19f63f5066 -> befba768679c4e414c4f3966ac4aa136
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
  v_quiet jsonb; v_qamt numeric := 0;  -- booking_162: hiljaisten aikojen ale
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
    -- booking_162: hiljaisen ajan ale arvioidaan ennen varauksen luontia (tyhjä vuoro); null kun asetus pois tai ei tarjousta
    v_quiet := booking._quiet_for_rule(p_rule_id, p_date);
    v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, 'web', null, p_locale, p_note,
                                          v_status, v_hold, true);
    perform booking._stamp_order_billing((v_res ->> 'order_id')::bigint, v_cust, v_company);
    v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);
    v_qamt := booking._quiet_apply((v_res ->> 'order_id')::bigint, v_quiet);
    v_total := (v_res ->> 'total')::numeric - v_qamt + v_add;
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
         || case when v_qamt > 0 then jsonb_build_object('discount', v_qamt, 'discount_source', 'quiet',
                 'quiet', jsonb_build_object('percent', (v_quiet ->> 'percent')::numeric, 'amount', v_qamt)) else '{}'::jsonb end
         || booking._checkout_state_json((v_res ->> 'order_id')::bigint);
end $function$;

-- booking.public_create_treatment_booking(bigint,timestamptz,integer,text,text,text,boolean,text,text,text,jsonb,text,jsonb): ece168b714a2478bd8a1e5d31f6e6fb7 -> d47cd6e939943cb2cfa385c0767bc2cb
CREATE OR REPLACE FUNCTION booking.public_create_treatment_booking(p_product_id bigint, p_start timestamp with time zone, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_option_code text DEFAULT NULL::text, p_addons jsonb DEFAULT NULL::jsonb)
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
  v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}'; v_invoice boolean; v_hold_mode boolean; v_group boolean; v_hmin int; v_thr int := booking._checkout_cfg_int('checkout_group_threshold_persons', 0, 0, 1000);
  v_cust bigint; v_res jsonb; v_end timestamptz; v_total numeric; v_token uuid; v_detail text; v_msg text; v_pay_method text; v_order bigint; v_opt bigint; v_add numeric := 0;
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
  v_invoice := v_is_company and coalesce((booking._setting('checkout_company_invoice_enabled', 'true'::jsonb) #>> '{}')::boolean, true);
  v_hold_mode := v_mode <> 'pay_later' and not v_invoice;                        -- booking_53: pitotila
  v_group := v_hold_mode and v_thr > 0 and coalesce(p_persons, 0) >= v_thr;
  if v_hold_mode and not v_group and not booking._checkout_online_available() then
    return jsonb_build_object('ok', false, 'code', 'online_payment_unavailable', 'message', 'Verkkomaksu ei ole tilapäisesti käytettävissä – varausta ei voi tehdä juuri nyt');
  end if;
  v_hmin := case when not v_hold_mode then 0 when v_group then booking._checkout_cfg_int('checkout_group_hold_days', 7, 1, 60) * 1440 else booking._checkout_hold_minutes() end;
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
  if v_hold_mode and (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id
       where lower(c.email) = v_email and o.status = 'pending' and o.created_at > now() - interval '1 hour') >= 3 then
    return jsonb_build_object('ok', false, 'code', 'too_many_pending', 'message', 'Sinulla on jo useita keskeneräisiä varauksia');
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
    perform set_config('booking.checkout_hold_minutes', v_hmin::text, true);
    perform set_config('booking.checkout_hold_kind', case when v_group then 'preliminary' else 'checkout' end, true);
    v_res := booking._create_legs_booking('current', p_product_id, p_start, v_end, p_persons, v_cust, 'web', null, p_note, v_total, null, false, null, false, null, null, p_option_code);
    perform set_config('booking.checkout_hold_minutes', '', true);
    perform set_config('booking.checkout_hold_kind', '', true);
    v_order := (v_res ->> 'order_id')::bigint;
    perform booking._stamp_order_billing(v_order, v_cust, v_company);
    v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);      -- booking_61: lisäpalvelut (resurssivaraus: esim. pyyhe); virheet BK001 -> addon_* -koodit
    v_total := v_total + v_add;
    if exists (select 1 from booking.order_items it where it.order_id = v_order and it.kind = 'addon' and it.addon_id is not null
                and it.addon_id not in (select pa.addon_id from booking.product_addon_allow pa where pa.product_id = p_product_id)) then
      perform booking._err('addon_not_allowed', 'Lisäpalvelu ei ole saatavilla tälle tuotteelle');   -- booking_64: tuotekohtainen sallittujen lisäpalvelujen lista
    end if;
    v_pay_method := case when v_is_company then 'invoice' else 'pay_later' end;
    if not v_hold_mode then   -- pitotilassa ei paikkaajamaksua
      insert into booking.payments(order_id, method, provider, status, amount) values (v_order, v_pay_method, 'manual', 'pending', v_total);
    end if;
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

  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_token, 'status', case when v_hold_mode then 'pending' else 'confirmed' end, 'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at',
                            'persons', p_persons, 'total', v_total, 'addons_total', v_add, 'payment_mode', case when v_hold_mode then v_mode else 'pay_later' end, 'payment_url', null, 'hold_expires_at', v_res -> 'hold_expires_at',
                            'product_name', v_res -> 'product_name', 'customer_kind', v_kind, 'booking_kind', 'slots', 'option', booking._option_json(v_opt))
         || booking._checkout_state_json(v_order);
end $function$;

-- booking.vismapay_payment_prepare(uuid,uuid): d1f8df803a45c2b77aa9f8554fc41890 -> cca997c4e900e78b8bb9e2e0c7da25d4
CREATE OR REPLACE FUNCTION booking.vismapay_payment_prepare(p_order_token uuid DEFAULT NULL::uuid, p_link_token uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._vismapay_mode();
  o booking.orders; pay booking.payments; c booking.customers;
  v_tot numeric; v_unpaid numeric; v_att int; v_ref text; v_until bigint; v_reuse boolean := false;
  v_cust jsonb := null; v_first text; v_last text; v_email text;
begin
  if (p_order_token is null) = (p_link_token is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid_param', 'message', 'Anna joko order_token tai link_token');
  end if;
  if not booking._rate_limit('vpstart:' || coalesce(p_order_token, p_link_token)::text, 12, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_mode = 'off' then
    return jsonb_build_object('ok', false, 'code', 'vismapay_off', 'mode', v_mode, 'message', 'Verkkomaksu ei ole käytössä');
  end if;

  if v_mode = 'dry_run' then
    if p_link_token is not null then
      return jsonb_build_object('ok', false, 'code', 'vismapay_off', 'mode', v_mode, 'message', 'Verkkomaksu ei ole käytössä');
    end if;
    select * into o from booking.orders where public_token = p_order_token for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy'); end if;
    if o.external_source is not null or o.status not in ('pending', 'confirmed') or o.currency <> 'EUR' then
      return jsonb_build_object('ok', false, 'code', 'order_not_payable', 'message', 'Tilausta ei voi maksaa');
    end if;
    if booking._order_invoice_locked(o.id) or o.payment_status = 'invoiced' then
      return jsonb_build_object('ok', false, 'code', 'order_not_payable', 'message', 'Tilausta ei voi maksaa');
    end if;
    select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    v_tot := least(v_tot, v_unpaid);
    if v_tot <= 0.004 then
      if exists (select 1 from booking.payments where order_id = o.id and status in ('paid', 'partially_refunded', 'refunded')) then
        return jsonb_build_object('ok', false, 'code', 'already_paid', 'message', 'Tilaus on jo maksettu');
      end if;
      return jsonb_build_object('ok', false, 'code', 'nothing_to_pay', 'message', 'Ei maksettavaa');
    end if;
    select * into pay from booking.payments
     where order_id = o.id and status = 'pending' and provider = 'visma_pay' and amount = v_tot and provider_ref like 'dryrun-%'
     order by id desc limit 1 for update;
    if not found then
      insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, note)
      values (o.id, 'visma_pay', 'visma_pay', 'pending', v_tot, o.currency, now() + interval '30 minutes', 'Visma Pay dry_run, ei veloitusta')
      returning * into pay;
      update booking.payments set provider_ref = 'dryrun-' || pay.id, provider_status = 'dry_run' where id = pay.id returning * into pay;
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
      update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) - v_tot)
       where id = (select id from booking.payment_lines where payment_id = pay.id order by amount_gross desc, id limit 1)
         and (select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) > v_tot;
      perform booking._refresh_order_payment(o.id);
    end if;
    return jsonb_build_object('ok', true, 'mode', 'dry_run', 'dry_run', true, 'implemented', false,
      'payment_id', pay.id, 'provider_ref', pay.provider_ref, 'amount', pay.amount, 'currency', pay.currency,
      'order_no', o.order_no, 'order_token', o.public_token, 'status', pay.status,
      'message', 'Testitila: maksua ei veloiteta eikä kuittia synny.');
  end if;

  if v_mode not in ('test', 'live') then
    return jsonb_build_object('ok', false, 'code', 'vismapay_off', 'mode', v_mode, 'message', 'Verkkomaksu ei ole käytössä');
  end if;

  if p_link_token is not null then
    select * into pay from booking.payments where link_token = p_link_token for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Maksulinkkiä ei löydy'); end if;
    select * into o from booking.orders where id = pay.order_id for update;
    if pay.status = 'paid' then return jsonb_build_object('ok', false, 'code', 'already_paid', 'message', 'Maksu on jo maksettu'); end if;
    if pay.status <> 'pending' then return jsonb_build_object('ok', false, 'code', 'payment_not_pending', 'message', 'Maksulinkki ei ole enää voimassa'); end if;
    if pay.provider = 'mobilepay' and pay.provider_ref is not null then
      return jsonb_build_object('ok', false, 'code', 'other_provider_started', 'message', 'Maksu on aloitettu toisella maksutavalla');
    end if;
    if pay.link_expires_at is not null and pay.link_expires_at < now() then
      return jsonb_build_object('ok', false, 'code', 'link_expired', 'message', 'Maksulinkki on vanhentunut');
    end if;
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    if pay.amount > v_unpaid + 0.004 then
      return jsonb_build_object('ok', false, 'code', 'link_stale', 'message', 'Maksulinkin summa ei vastaa enää maksamatonta osuutta');
    end if;
    v_tot := pay.amount;
  else
    select * into o from booking.orders where public_token = p_order_token for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy'); end if;
    select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    v_tot := least(v_tot, v_unpaid);
    if v_tot <= 0.004 then
      if exists (select 1 from booking.payments where order_id = o.id and status in ('paid', 'partially_refunded', 'refunded')) then
        return jsonb_build_object('ok', false, 'code', 'already_paid', 'message', 'Tilaus on jo maksettu');
      end if;
      return jsonb_build_object('ok', false, 'code', 'nothing_to_pay', 'message', 'Ei maksettavaa');
    end if;
    select * into pay from booking.payments
     where order_id = o.id and status = 'pending' and provider = 'visma_pay' and amount = v_tot
       and coalesce(provider_ref, '') not like 'dryrun-%'
     order by (provider_ref is not null) desc, id desc
     limit 1 for update;
  end if;

  if o.external_source is not null or o.status not in ('pending', 'confirmed', 'completed', 'expired') or o.currency <> 'EUR'
     or o.payment_status = 'invoiced' or booking._order_invoice_locked(o.id) or o.customer_kind = 'company'
     or (o.status = 'pending' and o.hold_kind = 'preliminary') then
    return jsonb_build_object('ok', false, 'code', 'order_not_payable', 'message', 'Tilausta ei voi maksaa verkossa');
  end if;

  v_until := floor(extract(epoch from now() + interval '60 minutes'))::bigint;
  if pay.id is not null
     and coalesce(pay.raw ->> 'last_state', '') = 'CREATED'
     and coalesce(pay.raw ->> 'redirect_url', '') <> ''
     and coalesce(pay.raw ->> 'token', '') <> ''
     and coalesce(pay.raw ->> 'token_valid_until', '') ~ '^\d+$'
     and (pay.raw ->> 'token_valid_until')::bigint > floor(extract(epoch from now()))::bigint
     and pay.provider_ref ~ '^sauna-[a-z0-9_-]+$' then
    v_reuse := true;
  elsif pay.id is not null
     and coalesce(pay.raw ->> 'last_state', '') = 'initiating'
     and pay.updated_at > now() - interval '2 minutes' then
    return jsonb_build_object('ok', false, 'code', 'payment_in_progress', 'message', 'Maksun avaus on jo käynnissä. Odota hetki ja yritä uudelleen.');
  else
    if pay.id is null then
      insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, note)
      values (o.id, 'visma_pay', 'visma_pay', 'pending', v_tot, o.currency, now() + interval '60 minutes', 'Visma Pay')
      returning * into pay;
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
      update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) - v_tot)
       where id = (select id from booking.payment_lines where payment_id = pay.id order by amount_gross desc, id limit 1)
         and (select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) > v_tot;
      v_att := 1;
    else
      v_att := coalesce((pay.raw ->> 'attempt')::int, 0) + 1;
      if v_att < 1 then v_att := 1; end if;
      if not exists (select 1 from booking.payment_lines where payment_id = pay.id) then
        insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
        select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
      end if;
    end if;
    v_ref := 'sauna-o' || o.order_no::text || '-p' || pay.id::text || '-a' || v_att::text;
    update booking.payments
       set method = 'visma_pay', provider = 'visma_pay', provider_ref = v_ref, provider_status = 'initiating',
           raw = coalesce(raw, '{}'::jsonb) || jsonb_build_object('env', v_mode, 'attempt', v_att, 'last_state', 'initiating', 'token_valid_until', v_until::text)
     where id = pay.id
     returning * into pay;
    perform booking._refresh_order_payment(o.id);
  end if;

  if o.customer_id is not null then
    select * into c from booking.customers where id = o.customer_id;
    if found and c.anonymized_at is null then
      v_first := nullif(split_part(btrim(coalesce(c.name, '')), ' ', 1), '');
      v_last := nullif(btrim(substring(btrim(coalesce(c.name, '')) from char_length(split_part(btrim(coalesce(c.name, '')), ' ', 1)) + 1)), '');
      v_email := case when c.email is not null and booking._valid_email(c.email) then lower(btrim(c.email)) end;
      v_cust := jsonb_strip_nulls(jsonb_build_object(
        'firstname', v_first, 'lastname', v_last, 'email', v_email,
        'address_street', nullif(btrim(coalesce(c.address, '')), ''),
        'address_zip', nullif(btrim(coalesce(c.zip, '')), ''),
        'address_city', nullif(btrim(coalesce(c.city, '')), ''),
        'address_country', nullif(upper(btrim(coalesce(c.country, ''))), '')));
    end if;
  end if;

  return jsonb_build_object(
    'ok', true, 'mode', v_mode, 'dry_run', false, 'implemented', true, 'reuse', v_reuse,
    'payment_id', pay.id, 'order_number', pay.provider_ref, 'provider_ref', pay.provider_ref,
    'amount', pay.amount, 'amount_minor', round(pay.amount * 100)::bigint, 'currency', pay.currency,
    'order_no', o.order_no, 'order_token', o.public_token, 'status', pay.status,
    'locale', case when o.locale in ('fi', 'en', 'sv') then o.locale else 'fi' end,
    'description', 'Sipoonjoen Perinnesauna – tilaus ' || o.order_no::text,
    'site_base_url', booking._setting('site_base_url', 'null'::jsonb) #>> '{}',
    'order_page_path', coalesce(booking._setting('order_page_path', to_jsonb('/tilaus/'::text)) #>> '{}', '/tilaus/'),
    'token_valid_until', coalesce(pay.raw ->> 'token_valid_until', v_until::text),
    'redirect_url', case when v_reuse then pay.raw ->> 'redirect_url' end,
    'customer', v_cust, 'env', coalesce(pay.raw ->> 'env', v_mode));
end $function$;

-- booking.public_payment_options(uuid): 46834d95db5127935ad94e8759758ceb -> 07937cf049df18f7951e7c827f495f8e
CREATE OR REPLACE FUNCTION booking.public_payment_options(p_token uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._mobilepay_mode();
  v_vp text := booking._vismapay_mode();
  o booking.orders; v_unpaid numeric; v_can boolean := false; v_methods jsonb := '[]'::jsonb; v_order jsonb := null; v_pending boolean := false;
  v_any boolean;
begin
  v_any := v_mode <> 'off' or v_vp in ('test', 'live');
  if v_mode <> 'off' then
    v_methods := jsonb_build_array(jsonb_build_object('code', 'mobilepay', 'provider', 'vipps_mobilepay', 'label', 'MobilePay', 'label_en', 'MobilePay', 'test', v_mode = 'test',
      'start', jsonb_build_object('function', 'mobilepay-start', 'method', 'POST', 'body', case when p_token is not null then jsonb_build_object('order_token', p_token) else '{}'::jsonb end)));
  end if;
  if v_vp in ('test', 'live') then
    v_methods := v_methods || jsonb_build_array(jsonb_build_object('code', 'visma_pay', 'provider', 'visma_pay', 'label', 'Visma Pay', 'label_en', 'Visma Pay', 'test', v_vp = 'test',
      'start', jsonb_build_object('function', 'vismapay-start', 'method', 'POST', 'body', case when p_token is not null then jsonb_build_object('order_token', p_token) else '{}'::jsonb end)));
  end if;
  if p_token is null and booking._pay_later_test_enabled() then v_methods := v_methods || jsonb_build_array(booking._pay_later_method_json()); end if;
  if p_token is not null then
    if not booking._order_rl('popt', p_token, 120, 60) then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
    select * into o from booking.orders where public_token = p_token;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
    v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
    v_can := v_any and o.external_source is null and o.status in ('pending', 'confirmed', 'completed', 'expired') and o.currency = 'EUR' and v_unpaid > 0.004
      and not (o.status = 'pending' and o.hold_kind = 'preliminary')
      and o.payment_status is distinct from 'invoiced' and o.customer_kind is distinct from 'company';
    v_pending := exists (select 1 from booking.payments where order_id = o.id and provider = 'mobilepay' and status = 'pending' and (link_expires_at is null or link_expires_at > now()));
    v_order := jsonb_build_object('order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'unpaid', v_unpaid, 'can_pay_online', v_can, 'mobilepay_pending', v_pending) || booking._checkout_state_json(o.id);
    if not v_can then v_methods := '[]'::jsonb; end if;
    if booking._pay_later_test_enabled() and o.external_source is null and v_order ->> 'checkout_state' = 'awaiting_payment'
       and o.payment_status is distinct from 'invoiced' and o.customer_kind is distinct from 'company' then
      v_methods := v_methods || jsonb_build_array(booking._pay_later_method_json());
    end if;
  end if;
  return jsonb_build_object('ok', true, 'online_enabled', v_any, 'methods', v_methods, 'order', v_order);
end $function$;

-- booking.public_payment_link_info(uuid): 1b729ef4d72dc925001169c38bad3315 -> 647c556562046c75b7e7e33703c050a0
CREATE OR REPLACE FUNCTION booking.public_payment_link_info(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- booking_177: maksulinkkisivun (/maksa/?p=, /en/pay/?p=) yhteenveto ENNEN maksun aloitusta. Vain luku (ei muuta tilausta eikä maksua; ainoa kirjoitus
-- on yhteinen nopeusrajoitin _order_rl). Palauttaa vain vähimmäistiedot: tila + kieletön syykoodi, summa, valuutta, tilausnumero, rivit (nimi, pvm, klo
-- Europe/Helsinki) ja voimassaolo. EI asiakkaan nimeä, sähköpostia, puhelinta, osoitetta, muistiinpanoja, tilauksen tokenia eikä maksuvälittäjän tunnisteita.
-- Tila seuraa vismapay_payment_prepare-funktion linkkihaaran tarkistuksia (sama järjestys), joten "open" = painike voi käynnistää maksun.
--   open | paid (link_paid, order_paid) | expired (link_expired, payment_cancelled, payment_not_pending) | replaced (replaced, link_stale)
--   not_payable (other_provider_started, order_not_payable, vismapay_off) | not_found (tuntematon tai puuttuva token; ei muita tietoja)
-- booking_178: peruttu/hylätty Visma-yritys ei kuluta maksulinkkiä (vismapay_payment_apply jättää maksun pending-tilaan) → tila on taas "open" ja
-- last_attempt = cancelled | failed kertoo sivulle, että edellinen yritys jäi kesken (muuten null). payment_cancelled jää vain vanhoille (ennen booking_178:aa
-- perutuille) riveille; peruttu + summa ei enää vastaa maksamatonta → replaced (link_stale).
declare
  pay booking.payments; o booking.orders;
  v_ip_max int; v_unpaid numeric; v_paid_any boolean; v_newer boolean; v_mode text;
  v_status text; v_reason text; v_items jsonb;
begin
  v_ip_max := coalesce((booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int, 60);
  if not booking._order_rl('pli', p_token, v_ip_max, v_ip_max) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;
  if p_token is not null then
    select * into pay from booking.payments where link_token = p_token;
  end if;
  if pay.id is null then
    return jsonb_build_object('ok', true, 'status', 'not_found', 'reason', 'not_found', 'can_pay', false);
  end if;
  select * into o from booking.orders where id = pay.order_id;

  v_unpaid := coalesce((booking._order_balance(o.id) ->> 'unpaid')::numeric, 0);
  v_paid_any := exists (select 1 from booking.payments x where x.order_id = o.id and x.status in ('paid', 'partially_refunded', 'refunded'));
  -- korvattu: tilaukselle on kirjattu tämän jälkeen uusi maksu tai maksulinkki (_create_link_payment / admin_record_payment perui tämän)
  v_newer := exists (select 1 from booking.payments x where x.order_id = o.id and x.id > pay.id);
  v_mode := booking._vismapay_mode();

  if pay.status in ('paid', 'partially_refunded', 'refunded') then
    v_status := 'paid'; v_reason := 'link_paid';
  elsif pay.status <> 'pending' then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    elsif v_newer then v_status := 'replaced'; v_reason := 'replaced';
    elsif pay.link_expires_at is not null and pay.link_expires_at < now() then v_status := 'expired'; v_reason := 'link_expired';
    elsif pay.amount > v_unpaid + 0.004 then v_status := 'replaced'; v_reason := 'link_stale';
    elsif pay.provider_status in ('failed', 'cancelled') then v_status := 'expired'; v_reason := 'payment_cancelled';
    else v_status := 'expired'; v_reason := 'payment_not_pending'; end if;
  elsif pay.provider = 'mobilepay' and pay.provider_ref is not null then
    v_status := 'not_payable'; v_reason := 'other_provider_started';
  elsif pay.link_expires_at is not null and pay.link_expires_at < now() then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    elsif v_newer then v_status := 'replaced'; v_reason := 'replaced';
    else v_status := 'expired'; v_reason := 'link_expired'; end if;
  elsif pay.amount > v_unpaid + 0.004 then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    else v_status := 'replaced'; v_reason := 'link_stale'; end if;
  elsif o.external_source is not null or o.status not in ('pending', 'confirmed', 'completed', 'expired') or o.currency <> 'EUR'
     or o.payment_status = 'invoiced' or o.customer_kind = 'company'
     or (o.status = 'pending' and o.hold_kind = 'preliminary') then
    v_status := 'not_payable'; v_reason := 'order_not_payable';
  elsif v_mode is null or v_mode not in ('test', 'live') then
    v_status := 'not_payable'; v_reason := 'vismapay_off';
  else
    v_status := 'open'; v_reason := 'open';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', it.kind,
           'name', it.product_name,
           'name_en', nullif(btrim(coalesce(ad.name_en, kp.name_en, '')), ''),
           'quantity', it.quantity,
           'date', to_char(r.starts_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD'),
           'start', to_char(r.starts_at at time zone 'Europe/Helsinki', 'HH24:MI'),
           'end', to_char(r.ends_at at time zone 'Europe/Helsinki', 'HH24:MI'),
           'end_date', to_char(r.ends_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD'))
         order by coalesce(it.parent_item_id, it.id), it.parent_item_id is not null, r.starts_at nulls last, it.id), '[]'::jsonb)
    into v_items
    from booking.order_items it
    left join kb.products kp on kp.id = it.product_id and it.kind in ('reservation', 'product')
    left join booking.addons ad on ad.id = it.addon_id
    left join booking.reservations r on r.order_item_id = it.id and r.order_id = it.order_id and r.hidden_at is null and r.status <> 'cancelled'
   where it.order_id = o.id and it.kind <> 'discount';

  return jsonb_build_object(
    'ok', true, 'status', v_status, 'reason', v_reason, 'can_pay', v_status = 'open',
    'amount', pay.amount, 'amount_cents', round(pay.amount * 100)::bigint, 'currency', pay.currency,
    'order_no', o.order_no, 'order_total', o.total_gross,
    'expires_at', pay.link_expires_at,
    'expires_date', to_char(pay.link_expires_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD'),
    'expires_time', to_char(pay.link_expires_at at time zone 'Europe/Helsinki', 'HH24:MI'),
    'paid_at', case when v_reason = 'link_paid' then pay.paid_at end,
    'last_attempt', case when v_status = 'open' and pay.provider_status in ('cancelled', 'failed') then pay.provider_status end,
    'items', v_items);
end $function$;

-- booking.public_get_booking(uuid): 31b07afa6d8e5b61ed9c044d39e76275 -> 3b9187db7f41c94f5d582fcebb132f23
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
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() and not booking._order_mp_inflight(r.order_id) then 'expired' else r.status end,
           'hold_expires_at', r.hold_expires_at,
           'ritual_addon', booking._is_ritual_addon_item(it.id))   -- booking_166: vuoron lisäpalveluna varattu saunarituaali (näytetään vuoron jälkeen)
         order by booking._is_ritual_addon_item(it.id), r.starts_at)
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
           case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end,
           'payment_status', o.payment_status, 'total', o.total_gross, 'currency', o.currency, 'created_at', o.created_at,
           'first_name', cust, 'customer_kind', o.customer_kind, 'items', coalesce(res, '[]'::jsonb), 'addons', coalesce(adds, '[]'::jsonb),
           'payment_methods', (select coalesce(jsonb_agg(p.method), '[]'::jsonb) from booking.payments p where p.order_id = o.id),
           'can_change', (o.status = 'confirmed' and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_supported),
           'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end,
           'change_hours_before', v_hours,
           'has_ritual_addon', exists (select 1 from booking.order_items x where x.order_id = o.id and x.kind = 'reservation' and booking._is_ritual_addon_item(x.id)),
           'booking_kind', v_kind, 'change_via', case v_kind when 'slots' then 'public_change_treatment_booking' when 'rules' then 'public_change_booking' end,
           'invoice_locked', booking._order_invoice_locked(o.id))
         || booking._checkout_state_json(o.id);
end $function$;

-- booking.public_get_order(uuid): 5d0a5c1623ed4495be2d3ad0173284f1 -> c993d12037a9a9269265ba1cb809291e
CREATE OR REPLACE FUNCTION booking.public_get_order(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders; v_cust text; v_bal jsonb; v_end timestamptz; v_conf_n int; v_conf_start timestamptz; v_kind text; v_hours int;
  v_items jsonb; v_res jsonb; v_pay jsonb; v_rec jsonb; v_creq jsonb; v_ups_a jsonb; v_ups_t jsonb; v_can_add boolean; v_pl text; v_open boolean; v_status text; v_online boolean;
  v_cancel_dl timestamptz; v_cancel_closed boolean;   -- booking_149: asiakkaan peruutuspyynnön takaraja
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
  v_status := case when o.status = 'pending' and exists (select 1 from booking.reservations r where r.order_id = o.id) and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end;
  v_online := booking._vismapay_online();
  v_pl := booking._setting('payment_link_path', to_jsonb('/maksa/'::text)) #>> '{}';

  select coalesce(jsonb_agg(jsonb_build_object('name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate, 'kind', it.kind) order by it.id), '[]'::jsonb)
    into v_items from booking.order_items it where it.order_id = o.id;
  select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'product_id', r.product_id, 'product_name', oi.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons,
           'option', booking._option_json(r.product_option_id),
           'option_label', booking._option_label(r.product_id, o.locale), 'option_label_fi', booking._option_label(r.product_id, 'fi'), 'option_label_en', booking._option_label(r.product_id, 'en'), 'option_choices', booking._product_options_json(r.product_id),
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() and not booking._order_mp_inflight(r.order_id) then 'expired' else r.status end,
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
  v_can_add := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not booking._order_invoice_locked(o.id);
  v_open := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not exists (select 1 from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' and q.status = 'open');
  -- booking_149: asiakas voi pyytää peruutusta (ja sen hyvitystä) vain, kun ensimmäisen voimassa olevan vuoron alkuun on vähintään customer_change_hours_before tuntia (oletus 48).
  v_cancel_dl := booking._customer_cancel_deadline(o.id);
  v_cancel_closed := v_open and (v_cancel_dl is null or v_cancel_dl < now());
  v_open := v_open and v_cancel_dl is not null and v_cancel_dl >= now();
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
    'invoice_locked', booking._order_invoice_locked(o.id),
    'can_add', v_can_add, 'add_until', case when v_can_add then v_end end,
    'can_change', (o.status = 'confirmed' and o.external_source is null and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_kind in ('rules', 'slots')),
    'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end, 'change_hours_before', v_hours,
    'change_via', case v_kind when 'slots' then 'public_change_order_time' when 'rules' then 'public_change_order_time' end, 'booking_kind', v_kind,
    'can_request_cancel', v_open, 'cancel_request', v_creq,
    'cancel_deadline', v_cancel_dl, 'cancel_hours_before', v_hours, 'cancel_closed', coalesce(v_cancel_closed, false), 'online_payment_enabled', v_online,
    'upsell', jsonb_build_object('addons', coalesce(v_ups_a, '[]'::jsonb), 'treatments', coalesce(v_ups_t, '[]'::jsonb)),
    'instructions', booking._order_full_instructions(o.id, coalesce(o.locale, 'fi')))
    || booking._checkout_state_json(o.id);
end $function$;

-- booking.orders_invoice_status_trg(): 7f7eced664b101cb2672a78059c90682 -> 9ec5c212604145e284fa07d2fd2686f6
CREATE OR REPLACE FUNCTION booking.orders_invoice_status_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.payment_status = 'unpaid' and new.customer_kind = 'company'
     and not exists (select 1 from booking.payments p where p.order_id = new.id and p.status in ('paid','partially_refunded','refunded') and p.amount > 0)
     and exists (select 1 from booking.payments p where p.order_id = new.id and p.method = 'invoice' and p.status = 'pending')
  then
    new.payment_status := 'invoiced';
  end if;
  return new;
end $function$;

drop function if exists booking._order_pays_by_invoice(text, jsonb);
