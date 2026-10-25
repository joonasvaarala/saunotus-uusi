-- HISTORY-SYNC: applied in production, do not rerun. Tuotannon versio 20261021213138 (staff_bot_unavailability_write_all), Supabase sxbofnuisemspgquoxyv.
-- Lähde: tuotannon supabase_migrations.schema_migrations.statements[1] (md5 475f81bac0615ea6b0dcb54b221bb51b, 6359 merkkiä).
-- Runko on tuotannon lause sanatarkasti rivien "execute $hs_20261021213138$" ja "$hs_20261021213138$;" välissä.
-- Vartija: jos funktio public.staff_bot_all_unavailability on olemassa, migraatio on jo ajettu ja koko tiedosto ohitetaan (uudelleenajo = no-op, ei katalogimuutoksia).
-- Pudottaa ja luo uudelleen staff_bot_add_unavailability-funktion (uusi allekirjoitus), joten uudelleenajo sellaisenaan ei olisi no-op.
do $hs$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'staff_bot_all_unavailability') then
    raise notice 'history-sync 20261021213138: jo ajettu, ohitetaan';
    return;
  end if;
  execute $hs_20261021213138$
-- staff_bot_unavailability_write_all: botti voi kirjata/perua esteitä myös muille (scope unavailability.write_all)
-- ja nähdä kaikkien esteet (scope shifts.read_all). Kirjaaja tallennetaan: created_by = 'staff_bot:<botin staff_id>'.

drop function public.staff_bot_add_unavailability(timestamptz, timestamptz, text);

create function public.staff_bot_add_unavailability(
  p_starts timestamptz, p_ends timestamptz, p_note_ref text default null, p_staff_id uuid default null)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_own    uuid := public._staff_bot_staff_id('unavailability.write');
  v_target uuid := coalesce(p_staff_id, v_own);
  v_by     text := 'staff_bot:' || v_own::text;
  v_ref    text := nullif(btrim(p_note_ref), '');
  v_id     uuid;
begin
  if v_target <> v_own then
    perform public._staff_bot_staff_id('unavailability.write_all');
    if not exists (select 1 from public.staff s where s.id = v_target and s.active) then
      raise exception 'Henkilöä ei löytynyt tai hän ei ole aktiivinen' using errcode = '22023';
    end if;
  end if;
  if p_starts is null or p_ends is null then
    raise exception 'Alku ja loppu vaaditaan' using errcode = '22023';
  end if;
  if p_ends <= p_starts then
    raise exception 'Lopun pitää olla alun jälkeen' using errcode = '22023';
  end if;
  if p_ends <= now() then
    raise exception 'Este on kokonaan menneisyydessä' using errcode = '22023';
  end if;
  if p_ends > now() + interval '400 days' then
    raise exception 'Este voi olla enintään 400 päivän päähän' using errcode = '22023';
  end if;
  if v_ref is not null and length(v_ref) > 200 then
    raise exception 'Viite enintään 200 merkkiä' using errcode = '22023';
  end if;

  if v_ref is null then
    insert into public.staff_unavailability (staff_id, starts_at, ends_at, source, external_ref, created_by)
    values (v_target, p_starts, p_ends, 'staff_bot', null, v_by)
    returning id into v_id;
    return v_id;
  end if;

  -- Idempotentti (source, external_ref): sama viite päivittää saman kirjaajan saman henkilön rivin
  insert into public.staff_unavailability (staff_id, starts_at, ends_at, source, external_ref, created_by)
  values (v_target, p_starts, p_ends, 'staff_bot', v_ref, v_by)
  on conflict (source, external_ref) where external_ref is not null
  do update set starts_at = excluded.starts_at, ends_at = excluded.ends_at, updated_at = now()
          where public.staff_unavailability.staff_id = excluded.staff_id
            and public.staff_unavailability.created_by = excluded.created_by
  returning id into v_id;

  if v_id is null then
    raise exception 'Viite on jo käytössä, käytä toista viitettä' using errcode = '23505';
  end if;
  return v_id;
end $$;

create or replace function public.staff_bot_cancel_unavailability(p_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_own uuid := public._staff_bot_staff_id('unavailability.write');
  v_n   int;
begin
  delete from public.staff_unavailability u
   where u.id = p_id
     and u.source = 'staff_bot'
     and (u.created_by = 'staff_bot:' || v_own::text
          or (u.staff_id = v_own and u.created_by = 'staff_bot'));
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'Estettä ei löytynyt tai sitä ei ole kirjattu tällä botilla' using errcode = 'P0002';
  end if;
  return true;
end $$;

create or replace function public.staff_bot_my_unavailability()
returns table (
  id uuid, starts_at timestamptz, ends_at timestamptz, starts_local text, ends_local text,
  source text, external_ref text, can_cancel boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_staff uuid := public._staff_bot_staff_id('unavailability.read');
begin
  return query
    select u.id, u.starts_at, u.ends_at,
           to_char(u.starts_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
           to_char(u.ends_at   at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
           u.source,
           case when u.source = 'staff_bot' then u.external_ref end,
           (u.source = 'staff_bot' and (u.created_by = 'staff_bot:' || v_staff::text or u.created_by = 'staff_bot'))
      from public.staff_unavailability u
     where u.staff_id = v_staff
       and u.ends_at > now()
     order by u.starts_at;
end $$;

create or replace function public.staff_bot_all_unavailability(p_from date default null, p_to date default null)
returns table (
  id uuid, staff_id uuid, staff_name text, starts_at timestamptz, ends_at timestamptz,
  starts_local text, ends_local text, source text, can_cancel boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_own   uuid := public._staff_bot_staff_id('shifts.read_all');
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
  return query
    select u.id, u.staff_id, s.name, u.starts_at, u.ends_at,
           to_char(u.starts_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
           to_char(u.ends_at   at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
           u.source,
           (u.source = 'staff_bot' and (u.created_by = 'staff_bot:' || v_own::text
                                        or (u.staff_id = v_own and u.created_by = 'staff_bot')))
      from public.staff_unavailability u
      join public.staff s on s.id = u.staff_id
     where u.ends_at   >  (v_from::timestamp at time zone 'Europe/Helsinki')
       and u.starts_at <  ((v_to + 1)::timestamp at time zone 'Europe/Helsinki')
     order by u.starts_at, s.name;
end $$;

revoke all on function public.staff_bot_add_unavailability(timestamptz, timestamptz, text, uuid) from public, anon;
revoke all on function public.staff_bot_all_unavailability(date, date) from public, anon;
grant execute on function public.staff_bot_add_unavailability(timestamptz, timestamptz, text, uuid) to authenticated;
grant execute on function public.staff_bot_all_unavailability(date, date) to authenticated;

$hs_20261021213138$;
end $hs$;
