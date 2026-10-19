-- ROLLBACK booking_114_calendar_export.
-- Poistaa varauskalenterin ajastuksen, taulut ja funktiot. Sulkukalenterit ja muut integraatiot jäävät.
-- booking_calendar-rivi poistetaan ennen avainrajoitteen palautusta.

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from cron.job where jobname = 'booking_calendar_export') then
    perform cron.unschedule('booking_calendar_export');
  end if;
exception when others then
  raise notice 'pg_cron-poisto ohitettu: %', sqlerrm;
end $$;

drop trigger if exists booking_calendar_nudge_res on booking.reservations;
drop trigger if exists booking_calendar_nudge_ord on booking.orders;

drop function if exists booking.booking_calendar_nudge();
drop function if exists booking.booking_calendar_dispatch();
drop function if exists booking._booking_calendar_should_nudge();
drop function if exists booking.admin_booking_calendar_preview();
drop function if exists booking.admin_set_booking_calendar(jsonb);
drop function if exists booking.admin_get_booking_calendar();
drop function if exists booking.booking_calendar_export_finish(jsonb);
drop function if exists booking.booking_calendar_export_plan();
drop function if exists booking._booking_calendar_desired();
drop function if exists booking._booking_calendar_admin_base(jsonb);
drop function if exists booking._booking_calendar_target(text, jsonb);
drop function if exists booking._calendar_span(timestamptz, timestamptz, text);
drop function if exists booking._calendar_hm(timestamptz, text);
drop function if exists booking._calendar_id_ok(text);
drop function if exists booking._calendar_scrub(text);

drop table if exists booking.booking_calendar_events;
drop table if exists booking.booking_calendar_state;

delete from booking.integration_config where key = 'booking_calendar';

alter table booking.integration_config drop constraint if exists integration_config_key_check;
alter table booking.integration_config add constraint integration_config_key_check
  check (key in ('resend', 'vismapay', 'procountor', 'mobilepay'));
