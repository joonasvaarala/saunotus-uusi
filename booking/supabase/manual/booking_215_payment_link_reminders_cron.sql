-- PROD ONLY. Älä aja DEV-kantaan.
-- booking_215: kytke maksulinkkien automaattiset muistutukset ja 15 minuutin pg_cron-ajo.
-- Aja vasta, kun migraatio 20261029173000_booking_215_payment_link_reminders.sql on kannassa.
-- DEV:ssä tätä ei ajeta: siellä ei saa olla cron-jobia eikä muistutuslähetystä.
-- Sweep ei lähetä, ellei payment_link.reminders_enabled ole true. Tämä tiedosto asettaa sen.
-- Cron luodaan vain, jos cron-skeema on olemassa. Yksi transaktio: jos cron puuttuu, asetuskaan ei jää päälle.

begin;

insert into booking.settings(key, value, description, is_public)
values ('payment_link.reminders_enabled', 'true'::jsonb,
        'Automaattiset maksulinkkimuistutukset. false = sweep ei lähetä (DEV).', false)
on conflict (key) do update set value = 'true'::jsonb, description = excluded.description;

do $$
begin
  if to_regnamespace('cron') is null or to_regprocedure('cron.schedule(text,text,text)') is null then
    raise exception 'booking_215: pg_cron puuttuu, ajastusta ei luotu. Muistutukset on silti kytketty: aja sweep käsin tai asenna cron.';
  end if;
  if exists (select 1 from cron.job where jobname = 'booking_payment_link_reminders') then
    perform cron.unschedule('booking_payment_link_reminders');
  end if;
  perform cron.schedule('booking_payment_link_reminders', '*/15 * * * *', 'select booking.payment_link_reminders_sweep()');
end $$;

commit;
