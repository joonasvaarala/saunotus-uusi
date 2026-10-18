-- ROLLBACK booking_79_procountor_cron.
-- Poistaa ajastuksen booking_procountor_daily ja funktion procountor_daily_dispatch.
-- Ei koske accounting_exports-tauluun eikä Procountor-asetuksiin.

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from cron.job where jobname = 'booking_procountor_daily') then
    perform cron.unschedule('booking_procountor_daily');
  end if;
exception when others then
  raise notice 'pg_cron-poisto ohitettu: %', sqlerrm;
end $$;

drop function if exists booking.procountor_daily_dispatch();
