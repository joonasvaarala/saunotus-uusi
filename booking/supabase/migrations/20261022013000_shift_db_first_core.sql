-- shift_db_first_core: tietokanta = työvuorojen päälähde (Joonas 22.10.2026).
-- Taulut: shift_sync_settings (kytkimet), shift_change_log (muutosloki), shift_outbox (kalenteriin vienti),
--         shift_sync_conflicts (ristiriidat ilmoitettavaksi), shift_open_events (koukku tarjousmoottorille).
-- work_shifts saa versiot (db_version / pushed_version) + kalenterin peilitilan (calendar_title, cal_starts_at, cal_ends_at, cal_status,
-- google_updated_at, google_etag). Kaikki uusi logiikka on pois päältä kunnes shift_sync_settings.db_first_enabled = true.
--
-- Kontekstimuuttujat (set_config(..., true) = vain transaktion ajan):
--   sipoo.shift_source  calendar | push | staff_bot | bot | hallinta | offer_engine | system   (oletus 'bot' = suora SQL)
--   sipoo.shift_actor, sipoo.shift_actor_staff, sipoo.shift_request_id, sipoo.shift_run_id
-- source 'calendar' (lukusynkka) ja 'push' (viennin kuittaus) eivät kasvata db_versionia eivätkä jonota vientiä -> ei kaikusilmukkaa.

-- ---------- kytkimet ----------
create table public.shift_sync_settings (
  id               boolean primary key default true check (id),
  db_first_enabled boolean not null default false,   -- triggerit + DB-kirjoitus-RPC:t + staff_bot suora kirjoitus
  push_enabled     boolean not null default false,   -- edge-funktio saa kirjoittaa Google-kalentereihin
  push_max_attempts int    not null default 8 check (push_max_attempts between 1 and 50),
  updated_at       timestamptz not null default now(),
  updated_by       text
);
insert into public.shift_sync_settings default values;
alter table public.shift_sync_settings enable row level security;
revoke all on table public.shift_sync_settings from public, anon, authenticated;

-- ---------- work_shifts: versiot + kalenterin peilitila ----------
alter table public.work_shifts
  add column db_version         bigint not null default 0,
  add column pushed_version     bigint not null default 0,
  add column push_pending       boolean generated always as (db_version > pushed_version) stored,
  add column cal_starts_at      timestamptz,
  add column cal_ends_at        timestamptz,
  add column cal_status         text check (cal_status in ('active','cancelled')),
  add column google_etag        text,
  add column last_change_at     timestamptz,
  add column last_change_source text,
  add column last_pushed_at     timestamptz,
  add column push_error         text;
comment on column public.work_shifts.calendar_title is 'Viimeksi tunnettu kalenterin otsikko (peili). DB:n haluama otsikko = public._shift_desired_title(id).';
comment on column public.work_shifts.db_version is 'Kasvaa jokaisesta ei-kalenterilähtöisestä muutoksesta. push_pending = db_version > pushed_version.';

-- peilitilan alustus ilman updated_at-kosketusta
alter table public.work_shifts disable trigger work_shifts_updated_at;
update public.work_shifts set cal_starts_at = starts_at, cal_ends_at = ends_at, cal_status = status;
alter table public.work_shifts enable trigger work_shifts_updated_at;
create index work_shifts_push_pending_idx on public.work_shifts (calendar_source_id) where push_pending;

-- ---------- muutosloki ----------
create table public.shift_change_log (
  id             bigint generated always as identity primary key,
  shift_id       uuid references public.work_shifts(id) on delete set null,
  changed_at     timestamptz not null default now(),
  source         text not null check (source in ('calendar','staff_bot','bot','hallinta','offer_engine','system')),
  actor          text,
  actor_staff_id uuid references public.staff(id) on delete set null,
  action         text not null check (action in ('create','assign','unassign','change_time','cancel','reactivate','staffing_status')),
  staff_id       uuid references public.staff(id) on delete set null,
  old_data       jsonb,
  new_data       jsonb,
  db_version     bigint,
  request_id     uuid,
  run_id         text
);
create index shift_change_log_shift_idx on public.shift_change_log (shift_id, changed_at desc);
create index shift_change_log_changed_idx on public.shift_change_log (changed_at desc);
create index shift_change_log_actor_staff_idx on public.shift_change_log (actor_staff_id);
create index shift_change_log_staff_idx on public.shift_change_log (staff_id);
alter table public.shift_change_log enable row level security;
revoke all on table public.shift_change_log from public, anon, authenticated;

-- ---------- vientijono (sama malli kuin booking.closure_outbox) ----------
create table public.shift_outbox (
  id                 bigint generated always as identity primary key,
  shift_id           uuid not null references public.work_shifts(id) on delete cascade,
  calendar_source_id uuid not null references public.calendar_sources(id),
  op                 text not null check (op in ('upsert','delete')),
  g_op               text check (g_op in ('insert','patch','delete')),   -- claimin päättämä Google-operaatio
  shift_version      bigint not null,
  status             text not null default 'pending' check (status in ('pending','processing','done','blocked','error','skipped')),
  attempts           int not null default 0,
  last_error         text,
  result             text,
  request            jsonb,
  g_updated          timestamptz,
  g_etag             text,
  next_attempt_at    timestamptz not null default now(),
  locked_at          timestamptz,
  created_at         timestamptz not null default now(),
  processed_at       timestamptz
);
create unique index shift_outbox_one_open_idx on public.shift_outbox (shift_id) where status in ('pending','blocked');
create index shift_outbox_due_idx on public.shift_outbox (calendar_source_id, next_attempt_at) where status in ('pending','blocked','processing');
create index shift_outbox_calendar_idx on public.shift_outbox (calendar_source_id);
create index shift_outbox_shift_idx on public.shift_outbox (shift_id);
alter table public.shift_outbox enable row level security;
revoke all on table public.shift_outbox from public, anon, authenticated;

-- ---------- ristiriidat (ilmoitus Joonakselle: notified_at is null) ----------
create table public.shift_sync_conflicts (
  id             bigint generated always as identity primary key,
  shift_id       uuid references public.work_shifts(id) on delete set null,
  detected_at    timestamptz not null default now(),
  kind           text not null check (kind in ('concurrent_edit','deleted_in_calendar','push_failed','push_target_missing')),
  winner         text not null check (winner in ('calendar','db','merged','none')),
  db_state       jsonb,
  calendar_state jsonb,
  details        jsonb,
  run_id         text,
  notified_at    timestamptz,
  resolved_at    timestamptz,
  note           text
);
create index shift_sync_conflicts_shift_idx on public.shift_sync_conflicts (shift_id);
create index shift_sync_conflicts_unnotified_idx on public.shift_sync_conflicts (detected_at) where notified_at is null;
alter table public.shift_sync_conflicts enable row level security;
revoke all on table public.shift_sync_conflicts from public, anon, authenticated;

-- ---------- koukku: vuoro muuttui avoimeksi (tarjousmoottori myöhemmin) ----------
create table public.shift_open_events (
  id           bigint generated always as identity primary key,
  shift_id     uuid not null references public.work_shifts(id) on delete cascade,
  role_type    text not null,
  starts_at    timestamptz not null,
  source       text not null,
  detected_at  timestamptz not null default now(),
  status       text not null default 'new' check (status in ('new','processing','done','ignored')),
  processed_at timestamptz
);
create unique index shift_open_events_open_idx on public.shift_open_events (shift_id) where status in ('new','processing');
create index shift_open_events_shift_idx on public.shift_open_events (shift_id);
alter table public.shift_open_events enable row level security;
revoke all on table public.shift_open_events from public, anon, authenticated;

-- ---------- apufunktiot ----------
create or replace function public._shift_ctx(p_key text) returns text
language sql stable set search_path = '' as $$
  select nullif(current_setting('sipoo.shift_' || p_key, true), '')
$$;

create or replace function public._shift_db_first_enabled() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select s.db_first_enabled from public.shift_sync_settings s where s.id), false)
$$;

create or replace function public._shift_title_norm(p_title text) returns text
language sql immutable set search_path = '' as $$
  select case when btrim(coalesce(p_title, '')) in ('', '-') then '-'
              else regexp_replace(btrim(p_title), '\s*&\s*', ' & ', 'g') end
$$;

-- Google event id omille uusille tapahtumille (base32hex: a-v, 0-9) -> idempotentti insert (409 = jo olemassa)
create or replace function public._shift_new_event_id(p_shift_id uuid) returns text
language sql immutable set search_path = '' as $$
  select 'sps' || replace(p_shift_id::text, '-', '')
$$;

-- DB:n haluama kalenteriotsikko: nykyisten tekijöiden calendar_name:t ' & ' -erottimella, kalenterin nykyjärjestys säilyttäen;
-- ei tekijöitä -> '-' (tai '?' jos epävarma); otsikko jota ei voi tulkita (unresolved) jätetään ennalleen.
create or replace function public._shift_desired_title(p_shift_id uuid) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_title text; v_staffing text; v text;
begin
  select w.calendar_title, w.staffing_status into v_title, v_staffing from public.work_shifts w where w.id = p_shift_id;
  if not found then return null; end if;
  if v_staffing = 'unresolved' then return v_title; end if;
  select string_agg(s.calendar_name, ' & ' order by coalesce(o.ord, 1000), s.calendar_name) into v
    from public.shift_assignments a
    join public.staff s on s.id = a.staff_id
    left join lateral (
      select min(t.ord) as ord from unnest(string_to_array(v_title, '&')) with ordinality t(part, ord)
       where btrim(t.part) = s.calendar_name) o on true
   where a.shift_id = p_shift_id and a.status in ('assigned','confirmed') and s.calendar_name is not null;
  if v is not null then return v; end if;
  return case when v_staffing = 'uncertain' then '?' else '-' end;
end $$;

create or replace function public._shift_enqueue(p_shift_id uuid) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  w public.work_shifts%rowtype; v_id bigint;
begin
  select * into w from public.work_shifts where id = p_shift_id;
  if not found or w.db_version <= w.pushed_version then return null; end if;
  insert into public.shift_outbox (shift_id, calendar_source_id, op, shift_version)
  values (w.id, w.calendar_source_id, case when w.status = 'cancelled' then 'delete' else 'upsert' end, w.db_version)
  on conflict (shift_id) where status in ('pending','blocked')
  do update set op = excluded.op, shift_version = excluded.shift_version, status = 'pending',
                next_attempt_at = least(public.shift_outbox.next_attempt_at, now())
  returning id into v_id;
  perform pg_notify('shift_outbox', w.calendar_source_id::text);
  return v_id;
end $$;

create or replace function public._shift_log(p_shift_id uuid, p_action text, p_staff_id uuid, p_old jsonb, p_new jsonb, p_version bigint)
returns bigint
language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_src text := coalesce(public._shift_ctx('source'), 'bot');
begin
  if v_src not in ('calendar','staff_bot','bot','hallinta','offer_engine','system') then v_src := 'bot'; end if;
  insert into public.shift_change_log (shift_id, source, actor, actor_staff_id, action, staff_id, old_data, new_data, db_version, request_id, run_id)
  values (p_shift_id, v_src,
          coalesce(public._shift_ctx('actor'), case when v_src = 'calendar' then 'calendar-sync' else current_user end),
          public._shift_ctx('actor_staff')::uuid, p_action, p_staff_id, p_old, p_new, p_version,
          public._shift_ctx('request_id')::uuid, public._shift_ctx('run_id'))
  returning id into v_id;
  return v_id;
end $$;

-- ---------- triggerit ----------
create or replace function public._shift_ws_before() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_src text := coalesce(public._shift_ctx('source'), 'bot');
begin
  if not public._shift_db_first_enabled() or v_src in ('calendar','push') then return new; end if;
  if tg_op = 'INSERT' then
    new.google_event_id := coalesce(new.google_event_id, public._shift_new_event_id(new.id));
    new.db_version := 1; new.pushed_version := 0;
    new.last_change_at := now(); new.last_change_source := v_src;
    return new;
  end if;
  if (new.starts_at, new.ends_at, new.status, new.staffing_status) is distinct from (old.starts_at, old.ends_at, old.status, old.staffing_status)
     and new.db_version = old.db_version then
    new.db_version := old.db_version + 1;
    new.last_change_at := now(); new.last_change_source := v_src;
  end if;
  return new;
end $$;

create or replace function public._shift_ws_after() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_src text := coalesce(public._shift_ctx('source'), 'bot');
begin
  if not public._shift_db_first_enabled() or v_src = 'push' then return null; end if;
  if tg_op = 'INSERT' then
    perform public._shift_log(new.id, 'create', null, null,
      jsonb_build_object('starts_at', new.starts_at, 'ends_at', new.ends_at, 'role_type', new.role_type,
                         'calendar_title', new.calendar_title, 'staffing_status', new.staffing_status, 'google_event_id', new.google_event_id),
      new.db_version);
  else
    if (new.starts_at, new.ends_at) is distinct from (old.starts_at, old.ends_at) then
      perform public._shift_log(new.id, 'change_time', null, jsonb_build_object('starts_at', old.starts_at, 'ends_at', old.ends_at),
                                jsonb_build_object('starts_at', new.starts_at, 'ends_at', new.ends_at), new.db_version);
    end if;
    if new.status <> old.status then
      perform public._shift_log(new.id, case when new.status = 'cancelled' then 'cancel' else 'reactivate' end, null,
                                jsonb_build_object('status', old.status), jsonb_build_object('status', new.status), new.db_version);
    end if;
    if new.staffing_status is distinct from old.staffing_status then
      perform public._shift_log(new.id, 'staffing_status', null, jsonb_build_object('staffing_status', old.staffing_status),
                                jsonb_build_object('staffing_status', new.staffing_status), new.db_version);
    end if;
  end if;

  if v_src <> 'calendar' and new.db_version > new.pushed_version then
    perform public._shift_enqueue(new.id);
  end if;

  -- KOUKKU: vuoro muuttui avoimeksi (kalenterin '-' tai viimeinen tekijä poistettu DB:ssä). Tarjousmoottori kuuntelee/lukee myöhemmin.
  if new.status = 'active' and new.staffing_status = 'open' and coalesce(new.ends_at, new.starts_at) > now()
     and (tg_op = 'INSERT' or old.staffing_status is distinct from 'open' or old.status <> 'active') then
    insert into public.shift_open_events (shift_id, role_type, starts_at, source)
    values (new.id, new.role_type, new.starts_at, v_src)
    on conflict (shift_id) where status in ('new','processing') do nothing;
    perform pg_notify('shift_became_open',
      json_build_object('shift_id', new.id, 'role_type', new.role_type, 'starts_at', new.starts_at, 'source', v_src)::text);
  end if;
  return null;
end $$;

create or replace function public._shift_sa_after() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_src   text := coalesce(public._shift_ctx('source'), 'bot');
  v_shift uuid := coalesce(new.shift_id, old.shift_id);
  v_was   boolean := tg_op <> 'INSERT' and old.status in ('assigned','confirmed');
  v_is    boolean := tg_op <> 'DELETE' and new.status in ('assigned','confirmed');
  v_has   boolean;
begin
  if not public._shift_db_first_enabled() or v_src = 'push' then return null; end if;
  if v_was = v_is and (tg_op <> 'UPDATE' or old.staff_id = new.staff_id) then return null; end if;
  if v_was then perform public._shift_log(v_shift, 'unassign', old.staff_id, jsonb_build_object('status', old.status),
                                          case when tg_op = 'DELETE' then null else jsonb_build_object('status', new.status) end, null); end if;
  if v_is then perform public._shift_log(v_shift, 'assign', new.staff_id,
                                         case when tg_op = 'INSERT' then null else jsonb_build_object('status', old.status) end,
                                         jsonb_build_object('status', new.status, 'source', new.source), null); end if;
  if v_src = 'calendar' then return null; end if;

  select exists (select 1 from public.shift_assignments a where a.shift_id = v_shift and a.status in ('assigned','confirmed')) into v_has;
  update public.work_shifts w
     set db_version = w.db_version + 1, last_change_at = now(), last_change_source = v_src,
         staffing_status = case when v_has then 'assigned' when w.staffing_status = 'assigned' then 'open' else w.staffing_status end
   where w.id = v_shift;
  return null;
end $$;

create trigger work_shifts_db_first_before before insert or update on public.work_shifts
  for each row execute function public._shift_ws_before();
create trigger work_shifts_db_first_after after insert or update on public.work_shifts
  for each row execute function public._shift_ws_after();
create trigger shift_assignments_db_first_after after insert or update or delete on public.shift_assignments
  for each row execute function public._shift_sa_after();

-- oikeudet: ei anon/authenticated
revoke all on function public._shift_ctx(text), public._shift_db_first_enabled(), public._shift_title_norm(text),
  public._shift_new_event_id(uuid), public._shift_desired_title(uuid), public._shift_enqueue(uuid),
  public._shift_log(uuid, text, uuid, jsonb, jsonb, bigint), public._shift_ws_before(), public._shift_ws_after(), public._shift_sa_after()
  from public, anon, authenticated;
grant execute on function public._shift_desired_title(uuid), public._shift_title_norm(text), public._shift_db_first_enabled() to service_role;
