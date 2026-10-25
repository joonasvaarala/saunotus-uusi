-- HISTORY-SYNC: applied in production, do not rerun. Tuotannon versio 20261021212547 (staff_bot_access), Supabase sxbofnuisemspgquoxyv.
-- Lähde: tuotannon supabase_migrations.schema_migrations.statements[1] (md5 7a1e532543da41afe5244e7a327e709a, 8235 merkkiä).
-- Runko on tuotannon lause sanatarkasti rivien "execute $hs_20261021212547$" ja "$hs_20261021212547$;" välissä.
-- Vartija: jos taulu public.staff_bot_accounts on olemassa, migraatio on jo ajettu ja koko tiedosto ohitetaan (uudelleenajo = no-op, ei katalogimuutoksia).
-- Myöhemmin: 20261021213138 korvaa staff_bot_add/cancel/my_unavailability ja 20261025160701 (calendar_guard) laajentaa
-- staff_unavailability_source_checkiä (otto_bot). Siksi tätä ei saa ajaa uudelleen sellaisenaan:
-- vartija ohittaa koko tiedoston, jos migraatio on jo ajettu.
do $hs$
begin
  if to_regclass('public.staff_bot_accounts') is not null then
    raise notice 'history-sync 20261021212547: jo ajettu, ohitetaan';
    return;
  end if;
  execute $hs_20261021212547$
-- staff_bot_access: henkilökohtaisten työntekijäbottien rajattu pääsy (omat vuorot + omat esteet).
-- Malli: booking.text_bots (botti = oma Supabase Auth -käyttäjä, ei booking.staff-riviä, pääsy vain SECURITY DEFINER -RPC:iden kautta).

-- 1) Bottitilit
create table public.staff_bot_accounts (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  staff_id     uuid not null references public.staff(id) on delete cascade,
  scopes       text[] not null default array['shifts.read','unavailability.read','unavailability.write']::text[],
  label        text,
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);
comment on table public.staff_bot_accounts is
  'Työntekijän henkilökohtaisen botin Auth-käyttäjä -> staff. Ei suoria policyjä; käyttö vain public.staff_bot_* -RPC:iden kautta. Scopet: shifts.read, unavailability.read, unavailability.write (myöhemmin offers.read, offers.respond).';
create index staff_bot_accounts_staff_id_idx on public.staff_bot_accounts (staff_id);
alter table public.staff_bot_accounts enable row level security;
revoke all on table public.staff_bot_accounts from public, anon, authenticated;

-- 2) Uusi lähde staff_unavailability-tauluun
alter table public.staff_unavailability drop constraint staff_unavailability_source_check;
alter table public.staff_unavailability add constraint staff_unavailability_source_check
  check (source = any (array['personal_calendar','sauna_calendar','email','whatsapp','hallinta','staff_bot']::text[]));

-- 3) Sisäinen apufunktio: kutsujan staff_id + scope-tarkistus (ei suoraan kutsuttavissa API:sta)
create or replace function public._staff_bot_staff_id(p_scope text)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_staff uuid;
begin
  if v_uid is null then
    raise exception 'Kirjautuminen puuttuu' using errcode = '42501';
  end if;
  select a.staff_id into v_staff
    from public.staff_bot_accounts a
    join public.staff s on s.id = a.staff_id and s.active
   where a.auth_user_id = v_uid
     and a.active
     and p_scope = any (a.scopes);
  if v_staff is null then
    raise exception 'Tällä käyttäjällä ei ole työntekijäbotin oikeutta (%)', p_scope using errcode = '42501';
  end if;
  return v_staff;
end $$;
revoke all on function public._staff_bot_staff_id(text) from public, anon, authenticated;

-- 4a) Omat vuorot
create or replace function public.staff_bot_my_shifts(p_from date default null, p_to date default null)
returns table (
  shift_id   uuid,
  role_type  text,
  shift_date date,
  starts_at  timestamptz,
  ends_at    timestamptz,
  starts_local text,
  ends_local   text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_staff uuid := public._staff_bot_staff_id('shifts.read');
  v_from  date := coalesce(p_from, (now() at time zone 'Europe/Helsinki')::date);
  v_to    date := coalesce(p_to, coalesce(p_from, (now() at time zone 'Europe/Helsinki')::date) + 90);
begin
  if v_to < v_from then
    raise exception 'p_to ennen p_from' using errcode = '22023';
  end if;
  if v_to - v_from > 400 then
    raise exception 'Aikaväli enintään 400 päivää' using errcode = '22023';
  end if;
  return query
    select w.id, w.role_type,
           (w.starts_at at time zone 'Europe/Helsinki')::date,
           w.starts_at, w.ends_at,
           to_char(w.starts_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
           to_char(w.ends_at   at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI')
      from public.shift_assignments sa
      join public.work_shifts w on w.id = sa.shift_id
     where sa.staff_id = v_staff
       and sa.status = 'assigned'
       and w.status = 'active'
       and w.starts_at >= (v_from::timestamp at time zone 'Europe/Helsinki')
       and w.starts_at <  ((v_to + 1)::timestamp at time zone 'Europe/Helsinki')
     order by w.starts_at;
end $$;

-- 4b) Lisää este
create or replace function public.staff_bot_add_unavailability(p_starts timestamptz, p_ends timestamptz, p_note_ref text default null)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_staff uuid := public._staff_bot_staff_id('unavailability.write');
  v_ref   text := nullif(btrim(p_note_ref), '');
  v_id    uuid;
begin
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
    values (v_staff, p_starts, p_ends, 'staff_bot', null, 'staff_bot')
    returning id into v_id;
    return v_id;
  end if;

  -- Idempotentti (source, external_ref): sama viite päivittää oman rivin ajat
  insert into public.staff_unavailability (staff_id, starts_at, ends_at, source, external_ref, created_by)
  values (v_staff, p_starts, p_ends, 'staff_bot', v_ref, 'staff_bot')
  on conflict (source, external_ref) where external_ref is not null
  do update set starts_at = excluded.starts_at,
                ends_at   = excluded.ends_at,
                updated_at = now()
          where public.staff_unavailability.staff_id = excluded.staff_id
  returning id into v_id;

  if v_id is null then
    raise exception 'Viite on jo käytössä, käytä toista viitettä' using errcode = '23505';
  end if;
  return v_id;
end $$;

-- 4c) Peru oma bottikirjaus
create or replace function public.staff_bot_cancel_unavailability(p_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_staff uuid := public._staff_bot_staff_id('unavailability.write');
  v_n     int;
begin
  delete from public.staff_unavailability u
   where u.id = p_id
     and u.staff_id = v_staff
     and u.source = 'staff_bot';
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'Estettä ei löytynyt tai sitä ei ole kirjattu tällä botilla' using errcode = 'P0002';
  end if;
  return true;
end $$;

-- 4d) Omat esteet (ei päättyneitä)
create or replace function public.staff_bot_my_unavailability()
returns table (
  id uuid,
  starts_at timestamptz,
  ends_at timestamptz,
  starts_local text,
  ends_local text,
  source text,
  external_ref text,
  can_cancel boolean
)
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
           (u.source = 'staff_bot')
      from public.staff_unavailability u
     where u.staff_id = v_staff
       and u.ends_at > now()
     order by u.starts_at;
end $$;

-- 5) Oikeudet: vain authenticated
revoke all on function public.staff_bot_my_shifts(date, date) from public, anon;
revoke all on function public.staff_bot_add_unavailability(timestamptz, timestamptz, text) from public, anon;
revoke all on function public.staff_bot_cancel_unavailability(uuid) from public, anon;
revoke all on function public.staff_bot_my_unavailability() from public, anon;
grant execute on function public.staff_bot_my_shifts(date, date) to authenticated;
grant execute on function public.staff_bot_add_unavailability(timestamptz, timestamptz, text) to authenticated;
grant execute on function public.staff_bot_cancel_unavailability(uuid) to authenticated;
grant execute on function public.staff_bot_my_unavailability() to authenticated;

$hs_20261021212547$;
end $hs$;
