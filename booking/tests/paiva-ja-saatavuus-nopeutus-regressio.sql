-- Suorita migraation 133 jälkeen psql:llä:
-- psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f booking/tests/paiva-ja-saatavuus-nopeutus-regressio.sql
-- Muuttaa vanhat funktiot vain testitransaktiossa; lopuksi aina ROLLBACK.
\set ON_ERROR_STOP on
begin;

-- Vuorot koko kuukaudelle: sekä eri tuotteet että kaikki tilat.
create temp table new_sessions_133 on commit drop as
  select * from booking._sessions((now() at time zone booking._tz())::date + 2,
                                   (now() at time zone booking._tz())::date + 32, null, true);
create temp table new_sessions_admin_133 on commit drop as
  select * from booking._sessions((now() at time zone booking._tz())::date + 2,
                                   (now() at time zone booking._tz())::date + 32, null, false);

create temp table new_pool_peak_133 on commit drop as
  with probes as (
    select p.id as pool, t.at as starts, t.at + interval '3 hours' as ends
      from booking.resources p
      cross join lateral (select (now() at time zone booking._tz())::date + 2 as d) d
      cross join lateral (select (d.d + tm.hh) at time zone booking._tz() as at
                          from (values (time '09:00'), (time '12:00'), (time '15:00'), (time '18:00')) tm(hh)) t
     where p.kind = 'capacity_pool'
  )
  select p.pool, p.starts, p.ends, booking._pool_peak(p.pool, p.starts, p.ends) as peak
    from probes p;

-- Palautetaan booking_125:n originaalifunktiot transaktion sisällä.
\ir ../supabase/rollbacks/20261024070000_booking_133_ROLLBACK.sql

do $assert$
begin
  if exists (
    (select to_jsonb(n) from new_sessions_133 n
       except all select to_jsonb(o) from booking._sessions(
         (now() at time zone booking._tz())::date + 2, (now() at time zone booking._tz())::date + 32, null, true) o)
    union all
    (select to_jsonb(o) from booking._sessions(
         (now() at time zone booking._tz())::date + 2, (now() at time zone booking._tz())::date + 32, null, true) o
       except all select to_jsonb(n) from new_sessions_133 n)
  ) then raise exception 'booking_133: _sessions(current) does not match booking_125'; end if;

  if exists (
    (select to_jsonb(n) from new_sessions_admin_133 n
       except all select to_jsonb(o) from booking._sessions(
         (now() at time zone booking._tz())::date + 2, (now() at time zone booking._tz())::date + 32, null, false) o)
    union all
    (select to_jsonb(o) from booking._sessions(
         (now() at time zone booking._tz())::date + 2, (now() at time zone booking._tz())::date + 32, null, false) o
       except all select to_jsonb(n) from new_sessions_admin_133 n)
  ) then raise exception 'booking_133: _sessions(admin) does not match booking_125'; end if;

  if exists (select 1 from new_pool_peak_133 p
              where p.peak is distinct from booking._pool_peak(p.pool, p.starts, p.ends)) then
    raise exception 'booking_133: _pool_peak does not match booking_125';
  end if;
end $assert$;

rollback;
\echo 'booking_133 regression comparison PASS (transaction rolled back)'
