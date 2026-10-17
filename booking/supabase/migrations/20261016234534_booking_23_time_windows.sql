-- =====================================================================
-- booking_23_time_windows (17.10.2026): hoitojen/saunotusten varausaikaikkuna + rituaalien sallitut alkuajat.
-- Joonaksen päätös 17.10.:
--  * Koskee hoitoja JA saunotuksia: kb 10, 16–22, 24 (hoidot) sekä 11–15, 23 (saunotukset). Luokka 'therapy'.
--    Ma–pe: ensimmäinen alkaa aikaisintaan 16:00, päätyttävä viimeistään 20:30. La–su: aikaisintaan 13:00, päätyttävä 20:30 (Europe/Helsinki). Varaus ei saa ylittää keskiyötä.
--  * Saunarituaalit Raunissa (kb 8) ja paketti kb 7: alkuaika vain 16:00, 16:30 tai 17:00 (ei muita). Luokka 'ritual'.
--  * Ohitus: reservations.override_reason (asetetaan vain polussa, joka vaatii oikeuden bookings.override = admin/manager; _admin_create_legs ja admin_* ).
--  * Järjestelmäkirjoitukset (Johku-tuonti/delta, service_role/postgres ilman JWT-roolia) ja external_source-rivit eivät kaadu ikkunaan (Johku on totuus;
--    tuodussa historiassa on poikkeamia). Ylläpitäjän (authenticated) muutokset tuotuihin riveihin validoidaan.
--  * Päivitys ei validoi, jos aikaa/tuotetta ei muuteta (esim. perumisen/valmiiksi merkinnän yhteydessä).
-- Toteutus: erillinen BEFORE INSERT/UPDATE -trigger (ei kosketa reservations_validate/_plan_legs). Virhekoodit: time_window, ritual_start (BK001).
-- Konfiguraatio: product_config.time_window_class + taulu time_window_rules (muokattavissa ilman koodimuutosta).
-- =====================================================================
set local search_path = booking, extensions, public;

alter table booking.product_config add column if not exists time_window_class text;
alter table booking.product_config drop constraint if exists product_config_time_window_class_ok;
alter table booking.product_config add constraint product_config_time_window_class_ok check (time_window_class is null or time_window_class in ('therapy', 'ritual'));

create table if not exists booking.time_window_rules (
  class text not null check (class in ('therapy', 'ritual')),
  day_type text not null check (day_type in ('weekday', 'weekend')),
  earliest_start time,
  latest_end time,
  allowed_starts time[],
  primary key (class, day_type)
);
insert into booking.time_window_rules(class, day_type, earliest_start, latest_end, allowed_starts) values
  ('therapy', 'weekday', '16:00', '20:30', null),
  ('therapy', 'weekend', '13:00', '20:30', null),
  ('ritual',  'weekday', null, null, array['16:00', '16:30', '17:00']::time[]),
  ('ritual',  'weekend', null, null, array['16:00', '16:30', '17:00']::time[])
on conflict (class, day_type) do nothing;
alter table booking.time_window_rules enable row level security;
revoke all on booking.time_window_rules from public, anon, authenticated;
grant all on booking.time_window_rules to service_role;

update booking.product_config set time_window_class = 'therapy' where product_id in (10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24);
update booking.product_config set time_window_class = 'ritual' where product_id in (7, 8);

create or replace function booking.reservations_time_window() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_class text; w booking.time_window_rules; ls timestamp; le timestamp; v_dt text;
begin
  if new.status not in ('pending', 'confirmed') then return new; end if;
  if new.override_reason is not null then return new; end if;
  if new.external_source is not null and coalesce(booking._jwt_role(), 'service_role') = 'service_role' then return new; end if;
  if tg_op = 'UPDATE' and old.product_id is not distinct from new.product_id and old.starts_at = new.starts_at and old.ends_at = new.ends_at
     and booking._res_active(old.status, old.hold_expires_at) then return new; end if;
  select pc.time_window_class into v_class from booking.product_config pc where pc.product_id = new.product_id;
  if v_class is null then return new; end if;
  ls := new.starts_at at time zone booking._tz();
  le := new.ends_at at time zone booking._tz();
  v_dt := case when extract(isodow from ls) >= 6 then 'weekend' else 'weekday' end;
  select * into w from booking.time_window_rules where class = v_class and day_type = v_dt;
  if not found then return new; end if;
  if w.allowed_starts is not null and not (date_trunc('minute', ls)::time = any (w.allowed_starts)) then
    perform booking._err('ritual_start', 'Rituaalin alkuaika voi olla vain ' || (select string_agg(to_char(t, 'HH24:MI'), ', ' order by t) from unnest(w.allowed_starts) t));
  end if;
  if w.earliest_start is not null and ls::time < w.earliest_start
     or w.latest_end is not null and (le::time > w.latest_end or le::date <> ls::date) then
    perform booking._err('time_window', 'Hoitojen ja saunotusten aika: ' || case v_dt when 'weekday' then 'ma–pe' else 'la–su' end || ' alkaa aikaisintaan '
                         || to_char(w.earliest_start, 'HH24:MI') || ' ja päättyy viimeistään ' || to_char(w.latest_end, 'HH24:MI'));
  end if;
  return new;
end $$;
revoke all on function booking.reservations_time_window() from public, anon, authenticated;
grant execute on function booking.reservations_time_window() to service_role;

drop trigger if exists reservations_time_window on booking.reservations;
create trigger reservations_time_window before insert or update of starts_at, ends_at, product_id, status on booking.reservations
  for each row execute function booking.reservations_time_window();
