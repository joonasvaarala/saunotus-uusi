-- ROLLBACK booking_83_counter_expire. Poistaa kassatilausten vanhenemisajon.
-- booking.expire_holds / _expire_holds jätetään ennalleen.

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('booking_expire_counter_orders');
  end if;
exception when others then
  raise notice 'pg_cron-poisto ohitettu: %', sqlerrm;
end $$;

drop function if exists booking.expire_counter_orders();
