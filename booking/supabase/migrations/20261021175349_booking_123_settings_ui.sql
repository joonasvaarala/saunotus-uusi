-- booking_123: asetussivun luku ja korttikohtainen tallennus.
-- Ei uusia booking.settings-avaimia eikä poistoja. Live-tilat, Procountor, vastaanottajarajaus
-- ja polut eivät ole kirjoitettavissa tällä kutsulla. Vanha admin_set_setting jää ennalleen.
-- Rollback: rollbacks/20261021175349_booking_123_ROLLBACK.sql
-- Numerointi 123 (ei 122) ja tekstit pending-import-31, jotta rinnakkainen työ ei osu samaan tiedostoon.

set local lock_timeout = '5s';

create function booking._settings_ui_only(p jsonb, p_allowed text[])
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare k text;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    perform booking._err('invalid_value', 'Tallennus on tyhjä');
  end if;
  for k in select jsonb_object_keys(p) loop
    if not (k = any (p_allowed)) then
      perform booking._err('invalid_value', 'Kenttää ei voi tallentaa tältä sivulta');
    end if;
  end loop;
end $$;

create function booking._settings_ui_int(p_value jsonb, p_min int, p_max int, p_msg text)
returns int
language plpgsql
immutable
set search_path = ''
as $$
declare n numeric;
begin
  if p_value is null or jsonb_typeof(p_value) <> 'number' then
    perform booking._err('invalid_value', p_msg);
  end if;
  n := (p_value #>> '{}')::numeric;
  if n <> trunc(n) or n < p_min or n > p_max then
    perform booking._err('invalid_value', p_msg);
  end if;
  return n::int;
end $$;

create function booking._settings_ui_bool(p_value jsonb, p_msg text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_value is null or jsonb_typeof(p_value) <> 'boolean' then
    perform booking._err('invalid_value', p_msg);
  end if;
  return (p_value #>> '{}')::boolean;
end $$;

create function booking._settings_ui_put(p_key text, p_value jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update booking.settings set value = p_value, updated_by = auth.uid() where key = p_key;
  if not found then perform booking._err('unknown_setting', 'Tuntematon asetus'); end if;
end $$;

create function booking._settings_ui_iban(p text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare s text; moved text; digits text := ''; i int; rem int := 0; ch text;
begin
  s := upper(regexp_replace(coalesce(p, ''), '\s', '', 'g'));
  if s = '' then return ''; end if;
  if s !~ '^FI[0-9]{16}$' then perform booking._err('invalid_value', 'IBAN ei ole suomalainen tilinumero'); end if;
  moved := substr(s, 5) || substr(s, 1, 4);
  for i in 1..char_length(moved) loop
    ch := substr(moved, i, 1);
    if ch ~ '[A-Z]' then digits := digits || (ascii(ch) - 55)::text; else digits := digits || ch; end if;
  end loop;
  for i in 1..char_length(digits) loop
    rem := (rem * 10 + substr(digits, i, 1)::int) % 97;
  end loop;
  if rem <> 1 then perform booking._err('invalid_value', 'IBAN ei ole suomalainen tilinumero'); end if;
  return s;
end $$;

create function booking.admin_settings_bundle()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role text := booking.current_staff_role();
  v_settings jsonb;
  v_methods jsonb;
  v_packages jsonb;
  v_resend booking.integration_config;
  v_vp booking.integration_config;
  v_mp booking.integration_config;
  v_pc booking.integration_config;
  v_cal booking.integration_config;
  v_list jsonb;
  v_on boolean := false;
  v_count int := 0;
begin
  if booking.has_permission('settings.edit') then
    null;
  elsif booking.has_permission('pos.use') then
    return jsonb_build_object('ok', true, 'role', v_role, 'qr_only', true);
  else
    perform booking._err('forbidden', 'Ei oikeutta');
  end if;

  select coalesce(jsonb_object_agg(s.key, s.value), '{}'::jsonb) into v_settings from booking.settings s;
  select coalesce(jsonb_agg(jsonb_build_object('code', m.code, 'label', m.label, 'active', m.active, 'is_manual', m.is_manual) order by m.sort_order, m.code), '[]'::jsonb)
    into v_methods from booking.payment_methods m;
  select coalesce(jsonb_agg(jsonb_build_object('code', g.code, 'name', g.name, 'valid_months', g.valid_months) order by g.sort_order, g.code), '[]'::jsonb)
    into v_packages from booking.gift_card_packages g where g.active;

  select * into v_resend from booking.integration_config where key = 'resend';
  select * into v_vp from booking.integration_config where key = 'vismapay';
  select * into v_mp from booking.integration_config where key = 'mobilepay';
  select * into v_pc from booking.integration_config where key = 'procountor';
  select * into v_cal from booking.integration_config where key = 'booking_calendar';

  v_list := coalesce(v_resend.settings -> 'test_recipients', 'null'::jsonb);
  if jsonb_typeof(v_list) = 'array' then
    select count(*) into v_count
      from jsonb_array_elements_text(v_list) e
     where btrim(e) <> '' and e ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$';
    select exists (
      select 1 from jsonb_array_elements(v_list) x
       where jsonb_typeof(x) <> 'null' and (jsonb_typeof(x) <> 'string' or btrim(x #>> '{}') <> '')
    ) into v_on;
  end if;

  return jsonb_build_object(
    'ok', true,
    'role', v_role,
    'qr_only', false,
    'settings', v_settings,
    'payment_methods', v_methods,
    'gift_packages', coalesce(v_packages, '[]'::jsonb),
    'resend', jsonb_build_object(
      'mode', coalesce(v_resend.mode, 'off'),
      'from', coalesce(v_resend.settings ->> 'from', ''),
      'reply_to', coalesce(v_resend.settings ->> 'reply_to', ''),
      'allowlist_on', coalesce(v_on, false),
      'allowlist_count', coalesce(v_count, 0)),
    'vismapay', jsonb_build_object('mode', coalesce(v_vp.mode, 'off')),
    'mobilepay', jsonb_build_object('mode', coalesce(v_mp.mode, 'off')),
    'procountor', jsonb_build_object(
      'mode', coalesce(v_pc.mode, 'off'),
      'environment', case when v_pc.settings ->> 'environment' = 'prod' then 'prod' else 'pts' end,
      'daily_enabled', coalesce(v_pc.settings ->> 'daily_enabled', 'false') = 'true',
      'accounts_configured', coalesce(v_pc.settings ->> 'vat_status', '') ~ '^[0-9]{1,4}$'),
    'booking_calendar', jsonb_build_object(
      'mode', coalesce(v_cal.mode, 'off'),
      'configured', btrim(coalesce(v_cal.settings ->> 'shared_calendar_id', '')) <> ''));
end $$;

create function booking.admin_save_settings(p_section text, p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_seller jsonb; v_bank jsonb; v_from text; v_addr text; v_name text; v_reply text; v_set jsonb;
  v_business text; v_legal text; v_trade text; v_yt text; v_vat text; v_street text; v_post text; v_city text; v_country text;
  v_phone text; v_email text; v_web text; v_footer text; v_iban text; v_bic text; v_bank_name text;
  v_code text; v_on boolean; k text; n int;
begin
  perform booking._require_permission('settings.edit');
  if p_section is null or p_section not in (
    'pause', 'business', 'booking_window', 'booking_deadlines', 'booking_group', 'payment_hold', 'company_invoice',
    'payment_methods', 'email_sender', 'email_staff', 'gift_own', 'gift_partner', 'invoice', 'technical'
  ) then
    perform booking._err('unknown_section', 'Tätä osiota ei voi tallentaa');
  end if;
  if p_section = 'technical' and booking.current_staff_role() is distinct from 'admin' then
    perform booking._err('forbidden', 'Tekniset rajat vain pääkäyttäjälle');
  end if;

  if p_section = 'pause' then
    perform booking._settings_ui_only(p, array['public_booking_enabled']);
    perform booking._settings_ui_put('public_booking_enabled', to_jsonb(booking._settings_ui_bool(p -> 'public_booking_enabled', 'Verkkovaraus on joko päällä tai pois')));
  elsif p_section = 'business' then
    perform booking._settings_ui_only(p, array['business_name', 'seller']);
    perform booking._settings_ui_only(p -> 'seller', array['name', 'legal_name', 'trade_name', 'business_id', 'vat_id', 'street', 'postal_code', 'city', 'country', 'phone', 'email', 'website', 'footer']);
    v_business := btrim(coalesce(p ->> 'business_name', ''));
    v_legal := btrim(coalesce(p #>> '{seller,legal_name}', ''));
    v_trade := btrim(coalesce(p #>> '{seller,trade_name}', ''));
    v_name := btrim(coalesce(p #>> '{seller,name}', ''));
    v_yt := booking._norm_business_id(p #>> '{seller,business_id}');
    v_vat := upper(regexp_replace(coalesce(p #>> '{seller,vat_id}', ''), '\s', '', 'g'));
    v_street := btrim(coalesce(p #>> '{seller,street}', ''));
    v_post := btrim(coalesce(p #>> '{seller,postal_code}', ''));
    v_city := btrim(coalesce(p #>> '{seller,city}', ''));
    v_country := upper(btrim(coalesce(p #>> '{seller,country}', '')));
    v_phone := btrim(coalesce(p #>> '{seller,phone}', ''));
    v_email := lower(btrim(coalesce(p #>> '{seller,email}', '')));
    v_web := btrim(coalesce(p #>> '{seller,website}', ''));
    v_footer := btrim(coalesce(p #>> '{seller,footer}', ''));
    if char_length(v_business) < 2 or char_length(v_business) > 80
       or char_length(v_name) < 2 or char_length(v_name) > 120
       or char_length(v_legal) < 2 or char_length(v_legal) > 120
       or char_length(v_trade) < 2 or char_length(v_trade) > 120
       or not booking._business_id_ok(v_yt)
       or v_vat !~ '^FI[0-9]{8}$'
       or char_length(v_street) < 1 or char_length(v_street) > 120
       or v_post !~ '^[0-9]{5}$'
       or char_length(v_city) < 1 or char_length(v_city) > 80
       or v_country !~ '^[A-Z]{2}$'
       or v_phone !~ '^[0-9][0-9 +()-]{4,29}$' or char_length(regexp_replace(v_phone, '\D', '', 'g')) < 5
       or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
       or v_web !~ '^https://[^[:space:]]{3,180}$'
       or char_length(v_footer) > 160
    then
      perform booking._err('invalid_value', 'Tarkista yrityksen tiedot: nimi, y-tunnus, ALV-tunnus, osoite, puhelin, sähköposti ja verkkosivu');
    end if;
    select value into v_seller from booking.settings where key = 'seller';
    if jsonb_typeof(v_seller) is distinct from 'object' then v_seller := '{}'::jsonb; end if;
    v_seller := v_seller || jsonb_build_object(
      'name', v_name, 'legal_name', v_legal, 'trade_name', v_trade, 'business_id', v_yt, 'vat_id', v_vat,
      'street', v_street, 'postal_code', v_post, 'city', v_city, 'country', v_country,
      'phone', v_phone, 'email', v_email, 'website', v_web, 'footer', v_footer);
    perform booking._settings_ui_put('business_name', to_jsonb(v_business));
    perform booking._settings_ui_put('seller', v_seller);
  elsif p_section = 'booking_window' then
    perform booking._settings_ui_only(p, array['booking_horizon_days', 'public_treatment_horizon_days']);
    perform booking._settings_ui_put('booking_horizon_days', to_jsonb(booking._settings_ui_int(p -> 'booking_horizon_days', 1, 730, 'Varausikkuna: savusauna 1–730 päivää, hoidot 1–180 päivää')));
    perform booking._settings_ui_put('public_treatment_horizon_days', to_jsonb(booking._settings_ui_int(p -> 'public_treatment_horizon_days', 1, 180, 'Varausikkuna: savusauna 1–730 päivää, hoidot 1–180 päivää')));
  elsif p_section = 'booking_deadlines' then
    perform booking._settings_ui_only(p, array['public_treatment_min_lead_minutes', 'customer_change_hours_before']);
    perform booking._settings_ui_put('public_treatment_min_lead_minutes', to_jsonb(booking._settings_ui_int(p -> 'public_treatment_min_lead_minutes', 0, 1440, 'Hoidon varoaika on 0–1440 minuuttia ja muutosaika 0–720 tuntia')));
    perform booking._settings_ui_put('customer_change_hours_before', to_jsonb(booking._settings_ui_int(p -> 'customer_change_hours_before', 0, 720, 'Hoidon varoaika on 0–1440 minuuttia ja muutosaika 0–720 tuntia')));
  elsif p_section = 'booking_group' then
    perform booking._settings_ui_only(p, array['checkout_group_threshold_persons', 'checkout_group_hold_days', 'annual_card_max_persons']);
    perform booking._settings_ui_put('checkout_group_threshold_persons', to_jsonb(booking._settings_ui_int(p -> 'checkout_group_threshold_persons', 0, 100, 'Ryhmän kynnys on 0–100, pito 1–60 päivää ja vuosikortti 1–20 henkilöä')));
    perform booking._settings_ui_put('checkout_group_hold_days', to_jsonb(booking._settings_ui_int(p -> 'checkout_group_hold_days', 1, 60, 'Ryhmän kynnys on 0–100, pito 1–60 päivää ja vuosikortti 1–20 henkilöä')));
    perform booking._settings_ui_put('annual_card_max_persons', to_jsonb(booking._settings_ui_int(p -> 'annual_card_max_persons', 1, 20, 'Ryhmän kynnys on 0–100, pito 1–60 päivää ja vuosikortti 1–20 henkilöä')));
  elsif p_section = 'payment_hold' then
    perform booking._settings_ui_only(p, array['checkout_hold_minutes', 'checkout_mobilepay_grace_minutes', 'checkout_mobilepay_max_wait_minutes']);
    n := booking._settings_ui_int(p -> 'checkout_hold_minutes', 5, 60, 'Pito on 5–60 min, MobilePayn lisäaika 0–60 min ja katto 0–120 min');
    perform booking._settings_ui_put('checkout_hold_minutes', to_jsonb(n));
    perform booking._settings_ui_put('hold_minutes', to_jsonb(n));
    perform booking._settings_ui_put('checkout_mobilepay_grace_minutes', to_jsonb(booking._settings_ui_int(p -> 'checkout_mobilepay_grace_minutes', 0, 60, 'Pito on 5–60 min, MobilePayn lisäaika 0–60 min ja katto 0–120 min')));
    perform booking._settings_ui_put('checkout_mobilepay_max_wait_minutes', to_jsonb(booking._settings_ui_int(p -> 'checkout_mobilepay_max_wait_minutes', 0, 120, 'Pito on 5–60 min, MobilePayn lisäaika 0–60 min ja katto 0–120 min')));
  elsif p_section = 'company_invoice' then
    perform booking._settings_ui_only(p, array['checkout_company_invoice_enabled']);
    perform booking._settings_ui_put('checkout_company_invoice_enabled', to_jsonb(booking._settings_ui_bool(p -> 'checkout_company_invoice_enabled', 'Yrityslasku on joko päällä tai pois')));
  elsif p_section = 'payment_methods' then
    perform booking._settings_ui_only(p, array['methods']);
    perform booking._settings_ui_only(p -> 'methods', array['pay_later', 'card_terminal', 'bank_transfer', 'invoice', 'partner_voucher', 'other', 'cash']);
    if (p -> 'methods') ? 'cash' and jsonb_typeof(p #> '{methods,cash}') is distinct from 'boolean' then
      perform booking._err('invalid_value', 'Maksutapa on joko käytössä tai pois');
    end if;
    if coalesce((p #>> '{methods,cash}') = 'true', false) then
      perform booking._err('cash_not_accepted', 'Käteistä ei oteta vastaan');
    end if;
    if not exists (select 1 from jsonb_object_keys(p -> 'methods') mk where mk <> 'cash') then
      perform booking._err('invalid_value', 'Valitse maksutavat, jotka tallennetaan');
    end if;
    for v_code, v_on in
      select e.key, booking._settings_ui_bool(e.value, 'Maksutapa on joko käytössä tai pois')
        from jsonb_each(p -> 'methods') e
       where e.key <> 'cash'
    loop
      update booking.payment_methods set active = v_on where code = v_code and is_manual and code <> 'cash';
      if not found then perform booking._err('invalid_value', 'Maksutapaa ei voi muuttaa tältä sivulta'); end if;
    end loop;
  elsif p_section = 'email_sender' then
    perform booking._settings_ui_only(p, array['from_name', 'reply_to']);
    v_name := btrim(coalesce(p ->> 'from_name', ''));
    v_reply := lower(btrim(coalesce(p ->> 'reply_to', '')));
    if char_length(v_name) < 2 or char_length(v_name) > 80 or v_name ~ '[<>]'
       or v_reply !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      perform booking._err('invalid_value', 'Lähettäjän nimi on 2–80 merkkiä ja vastausosoitteen pitää kelvata');
    end if;
    select settings into v_set from booking.integration_config where key = 'resend' for update;
    if not found then perform booking._err('unknown_setting', 'Sähköpostin asetusta ei löydy'); end if;
    v_from := coalesce(v_set ->> 'from', '');
    v_addr := lower(btrim(substring(v_from from '<([^<>]+)>')));
    if v_addr is null or v_addr !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      perform booking._err('invalid_value', 'Lähettävä osoite on lukittu');
    end if;
    update booking.integration_config
       set settings = settings || jsonb_build_object('from', v_name || ' <' || v_addr || '>', 'reply_to', v_reply),
           updated_at = now(), updated_by = auth.uid()
     where key = 'resend';
  elsif p_section = 'email_staff' then
    perform booking._settings_ui_only(p, array['business_quote_notify_email', 'business_quote_notify_name']);
    v_email := lower(btrim(coalesce(p ->> 'business_quote_notify_email', '')));
    v_name := btrim(coalesce(p ->> 'business_quote_notify_name', ''));
    if (v_email <> '' and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
       or char_length(v_name) < 1 or char_length(v_name) > 80 then
      perform booking._err('invalid_value', 'Tarjouspyynnön osoite on tyhjä tai kelvollinen, ja nimi on 1–80 merkkiä');
    end if;
    perform booking._settings_ui_put('business_quote_notify_email', to_jsonb(v_email));
    perform booking._settings_ui_put('business_quote_notify_name', to_jsonb(v_name));
  elsif p_section = 'gift_own' then
    perform booking._settings_ui_only(p, array['sale_enabled', 'redeem_enabled', 'max_cards_per_order']);
    perform booking._settings_ui_put('gift_cards.sale_enabled', to_jsonb(booking._settings_ui_bool(p -> 'sale_enabled', 'Lahjakortin myynti on joko päällä tai pois')));
    perform booking._settings_ui_put('gift_cards.redeem_enabled', to_jsonb(booking._settings_ui_bool(p -> 'redeem_enabled', 'Lahjakortin lunastus on joko päällä tai pois')));
    perform booking._settings_ui_put('gift_cards.max_cards_per_order', to_jsonb(booking._settings_ui_int(p -> 'max_cards_per_order', 1, 30, 'Kortteja yhdessä ostossa on 1–30')));
  elsif p_section = 'gift_partner' then
    perform booking._settings_ui_only(p, array['max_per_order', 'remind_after_hours']);
    perform booking._settings_ui_put('voucher_claims.max_per_order', to_jsonb(booking._settings_ui_int(p -> 'max_per_order', 1, 30, 'Pyyntöjä on 1–30 ja muistutus 1–720 tuntia')));
    perform booking._settings_ui_put('voucher_claims.remind_after_hours', to_jsonb(booking._settings_ui_int(p -> 'remind_after_hours', 1, 720, 'Pyyntöjä on 1–30 ja muistutus 1–720 tuntia')));
  elsif p_section = 'invoice' then
    perform booking._settings_ui_only(p, array['invoice_due_days', 'iban', 'bic', 'name']);
    n := booking._settings_ui_int(p -> 'invoice_due_days', 1, 90, 'Eräpäivä on 1–90 päivää');
    v_iban := booking._settings_ui_iban(p ->> 'iban');
    v_bic := upper(regexp_replace(coalesce(p ->> 'bic', ''), '\s', '', 'g'));
    v_bank_name := btrim(coalesce(p ->> 'name', ''));
    if (v_bic <> '' and v_bic !~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$') or char_length(v_bank_name) > 80 then
      perform booking._err('invalid_value', 'BIC on 8 tai 11 merkkiä tai tyhjä');
    end if;
    select value into v_bank from booking.settings where key = 'invoice_bank';
    if jsonb_typeof(v_bank) is distinct from 'object' then v_bank := '{}'::jsonb; end if;
    v_bank := v_bank || jsonb_build_object('iban', v_iban, 'bic', v_bic, 'name', v_bank_name);
    perform booking._settings_ui_put('invoice_due_days', to_jsonb(n));
    perform booking._settings_ui_put('invoice_bank', v_bank);
  elsif p_section = 'technical' then
    perform booking._settings_ui_only(p, array['limits']);
    perform booking._settings_ui_only(p -> 'limits', array[
      'rl_ip_per_10min', 'rl_email_per_10min', 'rl_change_per_10min', 'rl_avail_per_10min',
      'rl_order_get_per_10min', 'rl_order_add_per_10min', 'rl_order_req_per_10min',
      'public_treatment_global_per_hour', 'public_treatment_max_open_per_email',
      'gift_cards.rl_check_fail_per_10min', 'gift_cards.rl_global_fail_per_10min', 'gift_cards.rl_buy_per_10min',
      'business_quote_rl_ip_per_10min', 'business_quote_rl_email_per_hour',
      'texts_max_proposals_per_day', 'texts_bot_max_approvals_per_day', 'voucher_claims.max_attempts']);
    for k in select jsonb_object_keys(p -> 'limits') loop
      n := case k
        when 'rl_ip_per_10min' then booking._settings_ui_int(p #> array['limits', k], 1, 200, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'rl_email_per_10min' then booking._settings_ui_int(p #> array['limits', k], 1, 100, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'rl_change_per_10min' then booking._settings_ui_int(p #> array['limits', k], 1, 200, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'rl_avail_per_10min' then booking._settings_ui_int(p #> array['limits', k], 1, 500, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'rl_order_get_per_10min' then booking._settings_ui_int(p #> array['limits', k], 1, 500, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'rl_order_add_per_10min' then booking._settings_ui_int(p #> array['limits', k], 1, 200, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'rl_order_req_per_10min' then booking._settings_ui_int(p #> array['limits', k], 1, 60, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'public_treatment_global_per_hour' then booking._settings_ui_int(p #> array['limits', k], 1, 500, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'public_treatment_max_open_per_email' then booking._settings_ui_int(p #> array['limits', k], 1, 50, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'gift_cards.rl_check_fail_per_10min' then booking._settings_ui_int(p #> array['limits', k], 1, 100, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'gift_cards.rl_global_fail_per_10min' then booking._settings_ui_int(p #> array['limits', k], 1, 2000, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'gift_cards.rl_buy_per_10min' then booking._settings_ui_int(p #> array['limits', k], 1, 50, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'business_quote_rl_ip_per_10min' then booking._settings_ui_int(p #> array['limits', k], 1, 50, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'business_quote_rl_email_per_hour' then booking._settings_ui_int(p #> array['limits', k], 1, 30, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'texts_max_proposals_per_day' then booking._settings_ui_int(p #> array['limits', k], 1, 2000, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'texts_bot_max_approvals_per_day' then booking._settings_ui_int(p #> array['limits', k], 1, 1000, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        when 'voucher_claims.max_attempts' then booking._settings_ui_int(p #> array['limits', k], 1, 30, 'Tekninen raja on sallitun vaihteluvälin ulkopuolella')
        else null
      end;
      perform booking._settings_ui_put(k, to_jsonb(n));
    end loop;
  end if;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (auth.uid(), booking._jwt_role(), 'settings', p_section, 'SETTINGS_SECTION', p);
  return jsonb_build_object('ok', true, 'section', p_section);
end $$;

comment on function booking.admin_settings_bundle() is 'Asetussivu: asetukset ja yhteyksien tila ilman salaisuuksia. settings.edit näkee kaiken, pelkkä pos.use vain QR-lipun. Ei vaihda tilaa.';
comment on function booking.admin_save_settings(text, jsonb) is 'Asetussivu: yksi kortti kerrallaan. Ei kirjoita maksun, Procountorin, kalenterin tai sähköpostin live-tilaa eikä vastaanottajarajausta. Tekninen osio vain roolille admin.';

revoke all on function booking._settings_ui_only(jsonb, text[]) from public, anon, authenticated;
revoke all on function booking._settings_ui_int(jsonb, int, int, text) from public, anon, authenticated;
revoke all on function booking._settings_ui_bool(jsonb, text) from public, anon, authenticated;
revoke all on function booking._settings_ui_put(text, jsonb) from public, anon, authenticated;
revoke all on function booking._settings_ui_iban(text) from public, anon, authenticated;
revoke all on function booking.admin_settings_bundle() from public, anon;
revoke all on function booking.admin_save_settings(text, jsonb) from public, anon;
grant execute on function booking.admin_settings_bundle() to authenticated, service_role;
grant execute on function booking.admin_save_settings(text, jsonb) to authenticated, service_role;
