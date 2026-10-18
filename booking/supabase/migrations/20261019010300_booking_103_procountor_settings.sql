-- booking_103_procountor_settings (19.10.2026)
-- Hallinta saa muokata integration_config.procountor-asetuksia (tila, ympäristö, tilit, ALV-tila).
-- Ei salaisuuksia. Ei ulkoista kutsua. Ei muuta olemassa olevaa mode-arvoa.
-- Päiväkirjaus ja laskun välitys ovat booking_77–79. Tämä ei luo toista jonoa.
-- booking_80–83 on varattu pikakassalle (PR #81). Tämä on booking_103.
-- Rollback: rollbacks/20261019010300_booking_103_ROLLBACK.sql
set local lock_timeout = '5s';

create or replace function booking._json_has_secret_key(p jsonb) returns boolean
language plpgsql immutable set search_path = '' as $$
declare k text; v jsonb;
        secret text[] := array['client_id','client_secret','api_key','password','token','refresh_token','access_token','secret','private_key','authorization','redirect_uri'];
begin
  if p is null or jsonb_typeof(p) = 'null' then return false; end if;
  if jsonb_typeof(p) = 'array' then
    for v in select value from jsonb_array_elements(p) loop
      if booking._json_has_secret_key(v) then return true; end if;
    end loop;
    return false;
  end if;
  if jsonb_typeof(p) <> 'object' then return false; end if;
  for k, v in select * from jsonb_each(p) loop
    if lower(k) = any (secret) then return true; end if;
    if booking._json_has_secret_key(v) then return true; end if;
  end loop;
  return false;
end $$;

create or replace function booking.admin_get_procountor_settings() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c booking.integration_config;
begin
  perform booking._require_permission('settings.edit');
  select * into c from booking.integration_config where key = 'procountor';
  return jsonb_build_object(
    'ok', true,
    'mode', coalesce(c.mode, 'off'),
    'environment', case when c.settings->>'environment' = 'prod' then 'prod' else 'pts' end,
    'daily_enabled', coalesce(c.settings->>'daily_enabled', 'false') = 'true',
    'api_prefix', coalesce(nullif(c.settings->>'api_prefix', ''), '/supported/api'),
    'vat_status', coalesce(c.settings->>'vat_status', ''),
    'approved_by', coalesce(c.settings->>'approved_by', ''),
    'bank_account', coalesce(c.settings->>'bank_account', ''),
    'accounts', jsonb_build_object(
      'rounding', coalesce(c.settings#>>'{accounts,rounding}', ''),
      'sales_by_vat', coalesce(c.settings#>'{accounts,sales_by_vat}', '{}'::jsonb),
      'clearing_by_method', coalesce(c.settings#>'{accounts,clearing_by_method}', '{}'::jsonb)));
end $$;

create or replace function booking.admin_set_procountor_settings(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  cur booking.integration_config;
  s jsonb; v_mode text; env text; approved text; vat text; prefix text; iban text;
  accounts jsonb; sales jsonb := '{}'::jsonb; clearing jsonb := '{}'::jsonb; rounding text;
  k text; v text;
  rates text[] := array['25.5','13.5','0','14','24','10'];
  methods text[] := array['cash','card_terminal','mobilepay','bank_transfer','invoice','gift_card','partner_voucher','visma_pay','annual_card','pay_later','other'];
begin
  perform booking._require_permission('settings.edit');
  if p is null or jsonb_typeof(p) <> 'object' then perform booking._err('invalid_setting', 'Asetusten pitää olla objekti'); end if;
  if booking._json_has_secret_key(p) then perform booking._err('secrets_not_allowed', 'Salaisuuksia ei tallenneta asetuksiin'); end if;
  select * into cur from booking.integration_config where key = 'procountor';
  if not found then perform booking._err('not_configured', 'procountor-asetus puuttuu'); end if;
  v_mode := coalesce(nullif(btrim(p->>'mode'), ''), cur.mode);
  if v_mode not in ('off', 'dry_run', 'live') then perform booking._err('invalid_setting', 'Tila on off, dry_run tai live'); end if;
  env := lower(btrim(coalesce(p->>'environment', cur.settings->>'environment', 'pts')));
  if env in ('sandbox', '') then env := 'pts'; end if;
  if env not in ('pts', 'prod') then perform booking._err('invalid_setting', 'Ympäristö on pts tai prod'); end if;
  if p ? 'approved_by' then approved := btrim(coalesce(p->>'approved_by', ''));
  else approved := btrim(coalesce(cur.settings->>'approved_by', '')); end if;
  if approved <> '' and (char_length(approved) < 3 or char_length(approved) > 80 or approved like 'eyJ%') then
    perform booking._err('invalid_setting', 'approved_by on nimi ja päivä, ei tunnusta');
  end if;
  if v_mode = 'live' and approved = '' then perform booking._err('approval_required', 'Yhdistetty tila vaatii approved_by'); end if;
  if p ? 'daily_enabled' and jsonb_typeof(p->'daily_enabled') is distinct from 'boolean' then perform booking._err('invalid_setting', 'daily_enabled on totuusarvo'); end if;
  if p ? 'vat_status' then vat := btrim(coalesce(p->>'vat_status', ''));
  else vat := btrim(coalesce(cur.settings->>'vat_status', '')); end if;
  if vat <> '' and vat !~ '^[0-9]{1,4}$' then perform booking._err('invalid_setting', 'ALV-tila on 1–4 numeroa'); end if;
  prefix := btrim(coalesce(nullif(p->>'api_prefix', ''), cur.settings->>'api_prefix', '/supported/api'));
  if prefix !~ '^/api$|^/latest/api$|^/supported/api$|^/v[0-9]{4}/api$' then perform booking._err('invalid_setting', 'API-etuliite ei kelpaa'); end if;
  if p ? 'bank_account' then iban := upper(regexp_replace(coalesce(p->>'bank_account', ''), '\s', '', 'g'));
  else iban := coalesce(cur.settings->>'bank_account', ''); end if;
  if iban <> '' and iban !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$' then perform booking._err('invalid_setting', 'Tilinumero on IBAN tai tyhjä'); end if;
  accounts := coalesce(p->'accounts', '{}'::jsonb);
  if jsonb_typeof(accounts) <> 'object' then perform booking._err('invalid_setting', 'accounts on objekti'); end if;
  rounding := btrim(coalesce(accounts->>'rounding', ''));
  if rounding <> '' and rounding !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
  if accounts ? 'sales_by_vat' then
    if jsonb_typeof(accounts->'sales_by_vat') <> 'object' then perform booking._err('invalid_setting', 'sales_by_vat on objekti'); end if;
    for k, v in select key, btrim(value) from jsonb_each_text(accounts->'sales_by_vat') loop
      if not (k = any (rates)) then perform booking._err('invalid_setting', 'Tuntematon ALV-kanta: ' || k); end if;
      if v <> '' and v !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
      if v <> '' then sales := sales || jsonb_build_object(k, v); end if;
    end loop;
  end if;
  if accounts ? 'clearing_by_method' then
    if jsonb_typeof(accounts->'clearing_by_method') <> 'object' then perform booking._err('invalid_setting', 'clearing_by_method on objekti'); end if;
    for k, v in select key, btrim(value) from jsonb_each_text(accounts->'clearing_by_method') loop
      if not (k = any (methods)) then perform booking._err('invalid_setting', 'Tuntematon maksutapa: ' || k); end if;
      if v <> '' and v !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
      if v <> '' then clearing := clearing || jsonb_build_object(k, v); end if;
    end loop;
  end if;
  if v_mode = 'live' and (vat !~ '^[0-9]{1,4}$' or sales = '{}'::jsonb or clearing = '{}'::jsonb) then
    perform booking._err('live_incomplete', 'Yhdistetty tila vaatii ALV-tilan, vähintään yhden myyntitilin ja maksutavan tilin');
  end if;
  s := coalesce(cur.settings, '{}'::jsonb)
    || jsonb_build_object(
         'environment', env,
         'daily_enabled', case when p ? 'daily_enabled' then (p->>'daily_enabled')::boolean else coalesce((cur.settings->>'daily_enabled')::boolean, false) end,
         'api_prefix', prefix,
         'vat_status', vat,
         'approved_by', nullif(approved, ''),
         'bank_account', nullif(iban, ''),
         'accounts', jsonb_build_object('rounding', nullif(rounding, ''), 'sales_by_vat', sales, 'clearing_by_method', clearing));
  s := jsonb_strip_nulls(s);
  update booking.integration_config
     set mode = v_mode, settings = s, updated_by = auth.uid()
   where key = 'procountor';
  return booking.admin_get_procountor_settings();
end $$;

create or replace function booking.admin_procountor_preview_daily(p_date date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare cfg jsonb; report jsonb; built jsonb;
begin
  perform booking._require_permission('settings.edit');
  if p_date is null then perform booking._err('invalid_setting', 'Päivä puuttuu'); end if;
  select c.settings into cfg from booking.integration_config c where c.key = 'procountor';
  report := booking._report_json(p_date, p_date, false, false);
  built := booking._procountor_daily_build(p_date, report, coalesce(cfg, '{}'::jsonb));
  return jsonb_build_object(
    'ok', true, 'date', p_date, 'sent', false,
    'ready', coalesce((built->>'ready')::boolean, false),
    'empty', coalesce((built->>'empty')::boolean, false),
    'missing', coalesce(built->'missing', '[]'::jsonb),
    'receipts', coalesce((report #>> '{totals,receipts}')::int, 0),
    'refund_receipts', coalesce((report #>> '{totals,refund_receipts}')::int, 0));
end $$;

comment on function booking.admin_get_procountor_settings() is 'Asetukset: Procountor-lomakkeen kentät. Oikeus settings.edit. Ei salaisuuksia. booking_103.';
comment on function booking.admin_set_procountor_settings(jsonb) is 'Tallentaa tilan ja tilikartan. live vaatii approved_by, vat_status ja tilit (live_incomplete). Puuttuva approved_by, bank_account ja vat_status säilyttää arvon. Ei lähetä. booking_103.';
comment on function booking.admin_procountor_preview_daily(date) is 'Päivän koosteen esikatselu raportista. sent on aina false. Johku jää _report_jsonin ulkopuolelle. booking_103.';

revoke all on function
  booking._json_has_secret_key(jsonb),
  booking.admin_get_procountor_settings(),
  booking.admin_set_procountor_settings(jsonb),
  booking.admin_procountor_preview_daily(date)
from public, anon, authenticated;

grant execute on function booking._json_has_secret_key(jsonb) to service_role;
grant execute on function booking.admin_get_procountor_settings(), booking.admin_set_procountor_settings(jsonb),
  booking.admin_procountor_preview_daily(date) to authenticated, service_role;
