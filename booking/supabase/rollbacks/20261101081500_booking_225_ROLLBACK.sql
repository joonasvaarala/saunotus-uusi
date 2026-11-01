-- booking_225 rollback: asetussivun yhteenveto palauttaa taas vismapay- ja mobilepay-tilat, ei montoniota.
-- integration_config-rivejä ei muuteta.

set local lock_timeout = '5s';

create or replace function booking.admin_settings_bundle()
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

comment on function booking.admin_settings_bundle() is 'Asetussivu: asetukset ja yhteyksien tila ilman salaisuuksia. settings.edit näkee kaiken, pelkkä pos.use vain QR-lipun. Ei vaihda tilaa.';

revoke all on function booking.admin_settings_bundle() from public, anon;
grant execute on function booking.admin_settings_bundle() to authenticated, service_role;
