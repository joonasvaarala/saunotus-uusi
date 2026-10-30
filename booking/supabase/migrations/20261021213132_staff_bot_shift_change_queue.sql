-- HISTORY-SYNC: applied in production, do not rerun. Tuotannon versio 20261021213132 (staff_bot_shift_change_queue), Supabase sxbofnuisemspgquoxyv.
-- Lähde: tuotannon supabase_migrations.schema_migrations.statements[1] (md5 554b3eb4216777294c3a87dfe0598534, 11682 merkkiä).
-- Runko on tuotannon lause sanatarkasti rivien "execute $hs_20261021213132$" ja "$hs_20261021213132$;" välissä.
-- Vartija: jos taulu public.shift_change_requests on olemassa, migraatio on jo ajettu ja koko tiedosto ohitetaan (uudelleenajo = no-op, ei katalogimuutoksia).
-- Myöhemmin: 20261021224952 (shift_db_first_api) korvaa staff_bot_request_shift_change-funktion (DB-first-versio);
-- rollbacks/20261022013900_shift_db_first_DOWN.sql palauttaa tämän tiedoston version.
do $hs$
begin
  if to_regclass('public.shift_change_requests') is not null then
    raise notice 'history-sync 20261021213132: jo ajettu, ohitetaan';
    return;
  end if;
  -- Tyhjä kanta: updated_at-triggerfunktio tulee tuotannon public-skeemasta, ei näistä migraatioista.
  if to_regprocedure('public.set_updated_at()') is null then
    create function public.set_updated_at() returns trigger
    language plpgsql
    as $fn$
    begin
      new.updated_at := now();
      return new;
    end
    $fn$;
  end if;
  execute $hs_20261021213132$
-- staff_bot_shift_change_queue: työntekijäbotin vuoromuutospyynnöt jonoon (scope shifts.manage).
--
-- KÄSITTELYSOPIMUS (Työvuoro-Tapio, service role / MCP SQL):
-- * Google-kalenteri on päälähde. Botti EI muuta work_shifts/shift_assignments-tauluja; se vain jonottaa pyynnön.
-- * Tapio hakee rivit: select ... from public.shift_change_requests where status = 'pending' order by created_at for update skip locked;
-- * Kalenterit: calendar_sources.role_type -> google_calendar_id (heater = Lämmitykset, reception = Vastaanotto, therapist = Hoitaja).
-- * Tapahtuman otsikko = tekijän staff.calendar_name; useampi tekijä " & " -erottimella; '-' tai tyhjä = avoin; '?' = epävarma
--   (public.parse_shift_title). Kuvaukseen lisätään rivi "Muutos: Oton botti (pyyntö <id>)".
-- * assign:      lisää target_staff_id:n calendar_name otsikkoon (avoin '-'/'?' korvataan nimellä, muuten " & " perään).
--                Tekijän vaihto = kaksi pyyntöä: unassign (vanha) + assign (uusi).
--   unassign:    poistaa target_staff_id:n nimen otsikosta; jos ketään ei jää, otsikoksi '-'.
--   change_time: päivittää tapahtuman alun/lopun (toistuvassa sarjassa vain kyseinen esiintymä).
--   create:      uusi tapahtuma roolin kalenteriin (otsikko target_staff_id:n calendar_name tai '-').
--   cancel:      poistaa tapahtuman (sarjassa vain esiintymän).
-- * Onnistui:  update ... set status='applied', calendar_event_id=<Google event id>, processed_by='tyovuoro-tapio', processed_at=now()
-- * Epäonnistui/ristiriita: status='error' (tekninen/ristiriita) tai 'rejected' (Joonas/Tapio hylkäsi), error_reason=<lyhyt suomenkielinen syy>,
--   processed_by, processed_at.
-- * Seuraava calendar-sync (10 min välein) päivittää work_shifts/shift_assignments kalenterin mukaan; audit_log syntyy synkassa.
-- * Ennen soveltamista tarkista, ettei kalenteritapahtumaa ole muutettu pyynnön luomisen jälkeen (work_shifts.google_updated_at
--   vs created_at); jos on, status='error', error_reason='Vuoroa on muutettu pyynnön jälkeen'.

create table public.shift_change_requests (
  id                 uuid primary key default gen_random_uuid(),
  requested_by_auth  uuid references auth.users(id) on delete set null,
  requested_by_staff uuid references public.staff(id) on delete set null,
  action             text not null check (action in ('assign','unassign','change_time','create','cancel')),
  shift_id           uuid references public.work_shifts(id) on delete set null,
  role               text check (role in ('heater','reception','therapist')),
  target_staff_id    uuid references public.staff(id) on delete set null,
  new_starts_at      timestamptz,
  new_ends_at        timestamptz,
  note               text check (note is null or length(note) <= 500),
  status             text not null default 'pending' check (status in ('pending','applied','error','rejected')),
  calendar_event_id  text,
  error_reason       text,
  processed_by       text,
  processed_at       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint shift_change_requests_times_chk check (new_starts_at is null or new_ends_at is null or new_ends_at > new_starts_at)
);
comment on table public.shift_change_requests is
  'Työntekijäbottien vuoromuutospyynnöt. Työvuoro-Tapio kirjaa ne Google-kalenteriin ja merkitsee applied/error/rejected; synkka päivittää work_shifts. Ks. migraation staff_bot_shift_change_queue kommentti.';
create index shift_change_requests_pending_idx on public.shift_change_requests (created_at) where status = 'pending';
create index shift_change_requests_requester_idx on public.shift_change_requests (requested_by_auth, created_at desc);
create index shift_change_requests_shift_idx on public.shift_change_requests (shift_id);
create index shift_change_requests_requested_staff_idx on public.shift_change_requests (requested_by_staff);
create index shift_change_requests_target_staff_idx on public.shift_change_requests (target_staff_id);
alter table public.shift_change_requests enable row level security;
revoke all on table public.shift_change_requests from public, anon, authenticated;
create trigger shift_change_requests_updated_at before update on public.shift_change_requests
  for each row execute function public.set_updated_at();

create or replace function public.staff_bot_request_shift_change(
  p_action text,
  p_shift_id uuid default null,
  p_target_staff_id uuid default null,
  p_role text default null,
  p_new_starts timestamptz default null,
  p_new_ends timestamptz default null,
  p_note text default null)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_own   uuid := public._staff_bot_staff_id('shifts.manage');
  v_shift public.work_shifts%rowtype;
  v_role  text;
  v_note  text := nullif(btrim(p_note), '');
  v_id    uuid;
begin
  if p_action is null or p_action not in ('assign','unassign','change_time','create','cancel') then
    raise exception 'Tuntematon toiminto % (assign, unassign, change_time, create, cancel)', p_action using errcode = '22023';
  end if;
  if v_note is not null and length(v_note) > 500 then
    raise exception 'Huomautus enintään 500 merkkiä' using errcode = '22023';
  end if;

  if p_action = 'create' then
    if p_shift_id is not null then
      raise exception 'create ei ota p_shift_id:tä' using errcode = '22023';
    end if;
    if p_role is null or p_role not in ('heater','reception','therapist') then
      raise exception 'create vaatii roolin (heater, reception, therapist)' using errcode = '22023';
    end if;
    v_role := p_role;
  else
    if p_shift_id is null then
      raise exception '% vaatii p_shift_id:n', p_action using errcode = '22023';
    end if;
    select * into v_shift from public.work_shifts w where w.id = p_shift_id;
    if not found then
      raise exception 'Vuoroa ei löytynyt' using errcode = 'P0002';
    end if;
    if v_shift.status <> 'active' then
      raise exception 'Vuoro on peruttu' using errcode = '22023';
    end if;
    if v_shift.ends_at <= now() then
      raise exception 'Vuoro on jo päättynyt' using errcode = '22023';
    end if;
    if p_role is not null and p_role <> v_shift.role_type then
      raise exception 'Rooli ei vastaa vuoron roolia (%)', v_shift.role_type using errcode = '22023';
    end if;
    v_role := v_shift.role_type;
  end if;

  -- ajat
  if p_action in ('create','change_time') then
    if p_new_starts is null or p_new_ends is null then
      raise exception '% vaatii alun ja lopun', p_action using errcode = '22023';
    end if;
    if p_new_ends <= p_new_starts then
      raise exception 'Lopun pitää olla alun jälkeen' using errcode = '22023';
    end if;
    if p_new_ends - p_new_starts > interval '24 hours' then
      raise exception 'Vuoro voi olla enintään 24 h' using errcode = '22023';
    end if;
    if p_new_starts < now() then
      raise exception 'Alku on menneisyydessä' using errcode = '22023';
    end if;
    if p_new_starts > now() + interval '400 days' then
      raise exception 'Enintään 400 päivää eteenpäin' using errcode = '22023';
    end if;
  elsif p_new_starts is not null or p_new_ends is not null then
    raise exception '% ei ota uusia aikoja', p_action using errcode = '22023';
  end if;

  -- kohdehenkilö
  if p_action in ('assign','unassign') and p_target_staff_id is null then
    raise exception '% vaatii p_target_staff_id:n', p_action using errcode = '22023';
  end if;
  if p_action in ('change_time','cancel') and p_target_staff_id is not null then
    raise exception '% ei ota p_target_staff_id:tä', p_action using errcode = '22023';
  end if;
  if p_target_staff_id is not null and p_action in ('assign','create') then
    if not exists (select 1 from public.staff s where s.id = p_target_staff_id and s.active) then
      raise exception 'Henkilöä ei löytynyt tai hän ei ole aktiivinen' using errcode = '22023';
    end if;
    if not exists (select 1 from public.staff_roles r where r.staff_id = p_target_staff_id and r.role_type = v_role and r.active) then
      raise exception 'Henkilöllä ei ole roolia %', v_role using errcode = '22023';
    end if;
  end if;
  if p_action = 'assign' and exists (select 1 from public.shift_assignments sa
       where sa.shift_id = p_shift_id and sa.staff_id = p_target_staff_id and sa.status = 'assigned') then
    raise exception 'Henkilö on jo tässä vuorossa' using errcode = '22023';
  end if;
  if p_action = 'unassign' and not exists (select 1 from public.shift_assignments sa
       where sa.shift_id = p_shift_id and sa.staff_id = p_target_staff_id and sa.status = 'assigned') then
    raise exception 'Henkilö ei ole tässä vuorossa' using errcode = '22023';
  end if;

  -- sama odottava pyyntö -> palauta olemassa oleva
  select r.id into v_id
    from public.shift_change_requests r
   where r.status = 'pending'
     and r.requested_by_auth = auth.uid()
     and r.action = p_action
     and r.shift_id is not distinct from p_shift_id
     and r.target_staff_id is not distinct from p_target_staff_id
     and r.role is not distinct from v_role
     and r.new_starts_at is not distinct from p_new_starts
     and r.new_ends_at is not distinct from p_new_ends
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.shift_change_requests (requested_by_auth, requested_by_staff, action, shift_id, role, target_staff_id,
                                            new_starts_at, new_ends_at, note)
  values (auth.uid(), v_own, p_action, p_shift_id, v_role, p_target_staff_id, p_new_starts, p_new_ends, v_note)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.staff_bot_my_change_requests(p_status text default null)
returns table (
  id uuid,
  action text,
  status text,
  error_reason text,
  shift_id uuid,
  role text,
  shift_starts_local text,
  shift_ends_local text,
  target_staff_id uuid,
  target_name text,
  new_starts_local text,
  new_ends_local text,
  note text,
  created_at timestamptz,
  processed_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_own uuid := public._staff_bot_staff_id('shifts.manage');
begin
  if p_status is not null and p_status not in ('pending','applied','error','rejected') then
    raise exception 'Tuntematon tila %', p_status using errcode = '22023';
  end if;
  return query
    select r.id, r.action, r.status, r.error_reason, r.shift_id, r.role,
           to_char(w.starts_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
           to_char(w.ends_at   at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
           r.target_staff_id, s.name,
           to_char(r.new_starts_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
           to_char(r.new_ends_at   at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI'),
           r.note, r.created_at, r.processed_at
      from public.shift_change_requests r
      left join public.work_shifts w on w.id = r.shift_id
      left join public.staff s on s.id = r.target_staff_id
     where r.requested_by_auth = auth.uid()
       and (p_status is null or r.status = p_status)
     order by r.created_at desc
     limit 200;
end $$;

revoke all on function public.staff_bot_request_shift_change(text, uuid, uuid, text, timestamptz, timestamptz, text) from public, anon;
revoke all on function public.staff_bot_my_change_requests(text) from public, anon;
grant execute on function public.staff_bot_request_shift_change(text, uuid, uuid, text, timestamptz, timestamptz, text) to authenticated;
grant execute on function public.staff_bot_my_change_requests(text) to authenticated;

$hs_20261021213132$;
end $hs$;
