-- HISTORY-SYNC: applied in production, do not rerun. Tuotannon versio 20261021213017 (staff_bot_all_shifts), Supabase sxbofnuisemspgquoxyv.
-- Lähde: tuotannon supabase_migrations.schema_migrations.statements[1] (md5 45a208b275647be79e5a8e5260d31b92, 3660 merkkiä).
-- Runko on tuotannon lause sanatarkasti rivien "execute $hs_20261021213017$" ja "$hs_20261021213017$;" välissä.
-- Vartija: jos funktio public.staff_bot_staff_list on olemassa, migraatio on jo ajettu ja koko tiedosto ohitetaan (uudelleenajo = no-op, ei katalogimuutoksia).
-- Päivittää myös public.staff_bot_accounts-taulun kommentin (scope shifts.read_all).
do $hs$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'staff_bot_staff_list') then
    raise notice 'history-sync 20261021213017: jo ajettu, ohitetaan';
    return;
  end if;
  execute $hs_20261021213017$
-- staff_bot_all_shifts: työntekijäbotin luku kaikkiin vuoroihin (scope shifts.read_all).
-- Vain nimi (staff.name = kalenterinimi), ei sähköpostia/puhelinta.

create or replace function public.staff_bot_all_shifts(p_from date default null, p_to date default null, p_role text default null)
returns table (
  shift_id        uuid,
  role_type       text,
  shift_date      date,
  starts_at       timestamptz,
  ends_at         timestamptz,
  starts_local    text,
  ends_local      text,
  status          text,
  staffing_status text,
  is_unassigned   boolean,
  staff_ids       uuid[],
  staff_names     text[]
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_staff uuid := public._staff_bot_staff_id('shifts.read_all');
  v_today date := (now() at time zone 'Europe/Helsinki')::date;
  v_from  date := coalesce(p_from, v_today);
  v_to    date := coalesce(p_to, coalesce(p_from, v_today) + 90);
begin
  if v_to < v_from then
    raise exception 'p_to ennen p_from' using errcode = '22023';
  end if;
  if v_to - v_from > 400 then
    raise exception 'Aikaväli enintään 400 päivää' using errcode = '22023';
  end if;
  if p_role is not null and p_role not in ('heater','reception','therapist') then
    raise exception 'Tuntematon rooli % (heater, reception, therapist)', p_role using errcode = '22023';
  end if;
  return query
    select w.id, w.role_type,
           (w.starts_at at time zone 'Europe/Helsinki')::date,
           w.starts_at, w.ends_at,
           to_char(w.starts_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
           to_char(w.ends_at   at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
           w.status, w.staffing_status,
           (a.ids is null),
           coalesce(a.ids, '{}'::uuid[]),
           coalesce(a.names, '{}'::text[])
      from public.work_shifts w
      left join lateral (
        select array_agg(s.id order by s.name) ids, array_agg(s.name order by s.name) names
          from public.shift_assignments sa
          join public.staff s on s.id = sa.staff_id
         where sa.shift_id = w.id and sa.status = 'assigned'
      ) a on true
     where w.starts_at >= (v_from::timestamp at time zone 'Europe/Helsinki')
       and w.starts_at <  ((v_to + 1)::timestamp at time zone 'Europe/Helsinki')
       and (p_role is null or w.role_type = p_role)
     order by w.starts_at, w.role_type;
end $$;

create or replace function public.staff_bot_staff_list()
returns table (staff_id uuid, name text, roles text[])
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_staff uuid := public._staff_bot_staff_id('shifts.read_all');
begin
  return query
    select s.id, s.name,
           coalesce(array_agg(r.role_type order by r.role_type) filter (where r.role_type is not null), '{}'::text[])
      from public.staff s
      left join public.staff_roles r on r.staff_id = s.id and r.active
     where s.active
     group by s.id, s.name
     order by s.name;
end $$;

revoke all on function public.staff_bot_all_shifts(date, date, text) from public, anon;
revoke all on function public.staff_bot_staff_list() from public, anon;
grant execute on function public.staff_bot_all_shifts(date, date, text) to authenticated;
grant execute on function public.staff_bot_staff_list() to authenticated;

comment on table public.staff_bot_accounts is
  'Työntekijän henkilökohtaisen botin Auth-käyttäjä -> staff. Ei suoria policyjä; käyttö vain public.staff_bot_* -RPC:iden kautta. Scopet: shifts.read, shifts.read_all, shifts.manage, unavailability.read, unavailability.write, unavailability.write_all (myöhemmin offers.read, offers.respond).';

$hs_20261021213017$;
end $hs$;
