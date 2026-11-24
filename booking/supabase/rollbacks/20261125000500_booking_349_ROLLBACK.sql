-- booking_349 ROLLBACK. HUOM: poistaa tuodut tilityserät (settlements, settlement_items). Täytetyt payments/refunds.provider_fee-arvot jäävät; tarkista ne ennen rollbackia: select * from booking.settlement_items where fee_applied in ('set','overwritten').
drop function if exists booking.admin_set_provider_fee_account(text);
drop function if exists booking.admin_get_settlement(bigint);
drop function if exists booking.admin_list_settlements(date, date);
drop function if exists booking.svc_import_settlement_csv(text, text, text, boolean, boolean, text);
drop function if exists booking.admin_import_settlement_csv(text, text, text, boolean, boolean);
drop function if exists booking._settlement_import(text, text, text, boolean, boolean, text);
drop function if exists booking._settlement_parse_csv(text);
drop function if exists booking._settlement_num(text);
drop table if exists booking.settlement_items;
drop table if exists booking.settlements;
CREATE OR REPLACE FUNCTION booking.admin_get_procountor_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      'vat_rounding', coalesce(c.settings#>>'{accounts,vat_rounding}', ''),  -- booking_347 (K5)
      'sales_by_vat', coalesce(c.settings#>'{accounts,sales_by_vat}', '{}'::jsonb),
      'clearing_by_method', coalesce(c.settings#>'{accounts,clearing_by_method}', '{}'::jsonb)));
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_set_procountor_settings(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  cur booking.integration_config;
  s jsonb; v_mode text; env text; approved text; vat text; prefix text; iban text;
  accounts jsonb; sales jsonb := '{}'::jsonb; clearing jsonb := '{}'::jsonb; rounding text; vat_rounding text;
  k text; v text;
  rates text[] := array['25.5','13.5','0','14','24','10'];
  methods text[] := array['cash','card_terminal','mobilepay','bank_transfer','invoice','gift_card','partner_voucher','partner_voucher_kokemuskauppa','partner_voucher_offerilla','partner_voucher_elamyslahjat','visma_pay','montonio','annual_card','pay_later','other'];
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
  -- booking_347 (K5): ALV-pyöristystili
  vat_rounding := btrim(coalesce(accounts->>'vat_rounding', ''));
  if vat_rounding <> '' and vat_rounding !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
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
         'accounts', jsonb_build_object('rounding', nullif(rounding, ''), 'vat_rounding', nullif(vat_rounding, ''), 'sales_by_vat', sales, 'clearing_by_method', clearing));
  s := jsonb_strip_nulls(s);
  update booking.integration_config
     set mode = v_mode, settings = s, updated_by = auth.uid()
   where key = 'procountor';
  return booking.admin_get_procountor_settings();
end $function$;
