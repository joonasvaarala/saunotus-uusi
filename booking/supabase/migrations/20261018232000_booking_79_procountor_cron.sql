-- booking_79_procountor_cron (18.10.2026)
-- Päivittäinen Procountor-ajo. Ajastus on olemassa, mutta funktio ei lähetä mitään
-- ennen kuin integration_config.procountor.mode <> 'off' ja settings.daily_enabled = true.
-- Tunnuksia ei ole tässä. Kutsu on sama malli kuin send-emails: x-sync-secret vaultista.
-- Rollback: rollbacks/20261018232000_booking_79_ROLLBACK.sql

create function booking.procountor_daily_dispatch()
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_mode text;
  v_enabled boolean;
  v_secret text;
  v_url text;
begin
  select c.mode, coalesce(c.settings ->> 'daily_enabled', 'false') = 'true'
    into v_mode, v_enabled
    from booking.integration_config c
   where c.key = 'procountor';
  if coalesce(v_mode, 'off') = 'off' or not coalesce(v_enabled, false) then
    return;
  end if;
  select s.decrypted_secret into v_secret
    from vault.decrypted_secrets s
   where s.name = 'calendar_sync_cron_secret';
  if v_secret is null or v_secret = '' then
    raise notice 'procountor: calendar_sync_cron_secret puuttuu, ajo ohitetaan';
    return;
  end if;
  v_url := rtrim(coalesce(booking._setting('functions_base_url') #>> '{}', ''), '/') || '/procountor-sync';
  if v_url = '/procountor-sync' then
    raise notice 'procountor: functions_base_url puuttuu, ajo ohitetaan';
    return;
  end if;
  perform net.http_post(
    url := v_url,
    body := '{"action":"daily"}'::jsonb,
    headers := jsonb_build_object('content-type', 'application/json', 'x-sync-secret', v_secret),
    timeout_milliseconds := 50000);
end $function$;

comment on function booking.procountor_daily_dispatch() is 'pg_cron: kutsuu procountor-syncia vain kun mode ei ole off ja daily_enabled on true.';

revoke all on function booking.procountor_daily_dispatch() from public, anon, authenticated;
grant execute on function booking.procountor_daily_dispatch() to service_role;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and not exists (select 1 from cron.job where jobname = 'booking_procountor_daily') then
    perform cron.schedule('booking_procountor_daily', '20 4 * * *', 'select booking.procountor_daily_dispatch()');
  end if;
exception when others then
  raise notice 'pg_cron-ajastus ohitettu: %', sqlerrm;
end $$;
