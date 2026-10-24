-- booking_160: tietosuojan säilytysajon käyttöönotto turvallisessa järjestyksessä (korvaa booking_157_retention_cron.sql:n ohjeen).
-- ÄLÄ AJA NYT. Ajetaan käsin VAIN, kun Joonas on hyväksynyt kuivaharjoituksen luvut. Migraatiot EIVÄT ajasta mitään eivätkä kytke ajoa päälle.
-- Oletustila booking_160:n jälkeen: privacy_retention.enabled = false, privacy_retention.dry_run = true, ei cron-ajoja.
--
-- Järjestys:
--   0) Ennen migraatiota (pelkkä SELECT, tuotanto): manual/booking_160_retention_report_readonly.sql → määrät luokittain ja estosyittäin.
--   1) Migraatio 20261024330000_booking_160_retention_fixes.sql. Tarkista:
--        select key, value from booking.settings where key like 'privacy_retention.%' order by 1;   -- enabled=false, dry_run=true, email_outbox_months=36
--        (sähköpostijonon rivejä ei koskaan poisteta; henkilötiedot tyhjennetään 3 v lähetyksestä)
--   2) Kuivaharjoitus funktiolla (ei kirjoita):  select booking.privacy_retention_report();
--   3) Ajo päälle KUIVANA (kirjaa vain määrät, status 'dry_run'):
--        update booking.settings set value = 'true' where key = 'privacy_retention.enabled';
--        select booking.privacy_retention_run();
--        select id, status, counts from booking.privacy_retention_runs order by id desc limit 3;
--   4) Joonaksen hyväksynnän jälkeen oikea ajo käsin:
--        update booking.settings set value = 'false' where key = 'privacy_retention.dry_run';
--        select booking.privacy_retention_run();
--        select id, status, counts, errors from booking.privacy_retention_runs order by id desc limit 3;      -- status ok
--        select skipped_reason, count(*), count(deleted_at) from booking.privacy_auth_deletions group by 1;  -- henkilökunta = skipped
--   5) Storage-tiedostot (PDF:t) Storage-API:lla, ensin kuivana:
--        select booking.privacy_storage_due(50);   -- lista {bucket, path}
--        Edge Function privacy-storage-cleanup: POST {"dry_run": true} + x-sync-secret → määrät; sitten POST {} → poisto.
--        (SQL-poisto storage.objects-riveistä EI poista tiedostoja — älä tee sitä.)
--   6) Ajastukset (alla): tietosuoja-ajo kuun 5. päivä 03.43 UTC, Storage-siivous samana päivänä 04.13 UTC.
-- Ennen ajastusta: select jobid, jobname from cron.job where jobname in ('booking_privacy_retention', 'booking_privacy_storage_cleanup');  -- tyhjä
-- Edellytys Storage-siivoukselle: Edge Function privacy-storage-cleanup on deployattu (verify_jwt = false, config.toml) ja
-- edgen SYNC_CRON_SECRET = vault-salaisuus calendar_sync_cron_secret (sama kuin send-emails-ajossa).

select cron.schedule('booking_privacy_retention', '43 3 5 * *', $cron$select booking.privacy_retention_run()$cron$);

select cron.schedule('booking_privacy_storage_cleanup', '13 4 5 * *', $cron$
  select net.http_post(
    url := 'https://sxbofnuisemspgquoxyv.supabase.co/functions/v1/privacy-storage-cleanup',
    body := '{}'::jsonb,
    headers := jsonb_build_object('content-type', 'application/json',
      'x-sync-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'calendar_sync_cron_secret')),
    timeout_milliseconds := 50000);
$cron$);

-- Peruminen:
-- select cron.unschedule('booking_privacy_storage_cleanup');
-- select cron.unschedule('booking_privacy_retention');
-- update booking.settings set value = 'true' where key = 'privacy_retention.dry_run';
-- update booking.settings set value = 'false' where key = 'privacy_retention.enabled';
