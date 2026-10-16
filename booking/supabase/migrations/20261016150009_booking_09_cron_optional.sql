-- =====================================================================
-- booking 09 (VALINNAINEN): ajasta pitojen vanheneminen pg_cronilla minuutin välein.
-- Ei ole pakollinen: kaikki lukukyselyt ja varaustarkistukset ohittavat vanhentuneet pidot jo itse, tämä vain
-- siivoaa tilat (status 'expired') ja vanhat rate limit -rivit. Ohitetaan hiljaa jos pg_cron ei ole käytössä.
-- =====================================================================
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.unschedule('booking_expire_holds');
    exception when others then null;
    end;
    perform cron.schedule('booking_expire_holds', '* * * * *', 'select booking.expire_holds()');
  end if;
end $$;
