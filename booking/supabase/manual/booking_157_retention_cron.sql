-- booking_157: tietosuojan säilytysajon kuukausiajastus (pg_cron).
-- ÄLÄ AJA NYT. Ajetaan käsin VAIN, kun Joonas on hyväksynyt kuivaharjoituksen luvut. Migraatio EI ajasta mitään.
--
-- Järjestys:
--   1) Kuivaharjoitus (ei kirjoita):   select booking.privacy_retention_report();
--      (tai ennen migraatiota: manual/booking_157_retention_report_readonly.sql, pelkkä SELECT)
--   2) Ajo päälle:                     update booking.settings set value = 'true' where key = 'privacy_retention.enabled';
--   3) Ensimmäinen ajo käsin:          select booking.privacy_retention_run();
--      Tulos: select * from booking.privacy_retention_runs order by id desc limit 5;
--   4) Ajastus (alla): kuun 5. päivä klo 03.43 UTC (06.43 / 05.43 Helsingin aikaa). Ajo on idempotentti.
-- Ennen ajastusta: select jobid, jobname from cron.job where jobname = 'booking_privacy_retention';  -- pitää olla tyhjä
-- Kävijämittauksen kuukausikooste ei tarvitse uutta ajastusta: olemassa oleva booking_analytics_cleanup ('17 3 * * *')
-- kutsuu booking.analytics_cleanup():ia, joka booking_157:n jälkeen koostaa ennen poistoa.

select cron.schedule('booking_privacy_retention', '43 3 5 * *', $cron$select booking.privacy_retention_run()$cron$);

-- Peruminen:
-- select cron.unschedule('booking_privacy_retention');
-- update booking.settings set value = 'false' where key = 'privacy_retention.enabled';
