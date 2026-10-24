-- booking_153/155: vuorotarjousmoottorin tick-ajastus (pg_cron + pg_net → edge-funktio shift-offer-engine).
-- ÄLÄ AJA NYT. Ajetaan käsin VAIN, kun Joonas kytkee moottorin päälle. Migraatio EI tee tätä.
--
-- Miten tick kutsutaan: edge-funktio shift-offer-engine, POST ilman tokenia, header x-sync-secret = edgen env SYNC_CRON_SECRET.
-- Edge kutsuu rpc:n public.shift_offer_tick (booking_153:n säännöt ajetaan sen sisällä) ja sen jälkeen lähettäjän (deliverQueued),
-- jos sender_enabled. SQL-funktiota ei ajasta suoraan, koska viestien lähetys (WhatsApp) tapahtuu vain edgessä.
-- Väli: 5 min (*/5). Aikakatkaisu 50 s.
-- Edellytys: edgen SYNC_CRON_SECRET = vault-salaisuus calendar_sync_cron_secret (sama kuin calendar-sync-ajoissa).
-- Ennen ajoa: select jobid, jobname from cron.job where jobname = 'shift-offer-engine-5m';  -- pitää olla tyhjä
-- Tuotannossa ei ole tätä ajastusta (tarkistettu 24.10.2026).

select cron.schedule(
  'shift-offer-engine-5m',
  '*/5 * * * *',
  $cron$
  select net.http_post(
    url := 'https://sxbofnuisemspgquoxyv.supabase.co/functions/v1/shift-offer-engine',
    body := '{}'::jsonb,
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-sync-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'calendar_sync_cron_secret')
    ),
    timeout_milliseconds := 50000
  );
  $cron$
);

-- Peruminen (moottori pois):
-- select cron.unschedule('shift-offer-engine-5m');
