-- APPLIED 2026-10-17 (Europe/Helsinki ~01:2x): version 20261016221808 (booking_18a_schema) via apply_migration; sama SQL kuin alla (otsikkorivi lisätty tiedostoon ajon jälkeen).
-- ===================================================================================================================
-- booking_18a_schema: sulkukalenterien rekisteri, tapahtumaloki, luokittelusäännöt, Laura-resurssi (additiivinen)
-- ===================================================================================================================
set local search_path = booking, extensions, public;

-- ---------- Laura-resurssi: henkilömääräpohjaisen taidon (Laura) oma "sulkukohde" ----------
-- Syy: "1 hoidot kiinni" sulkee saunottaja-resurssin (vuoropohjaiset taidot), eikä se saa sulkea Lauran tuotteita (closure_calendar_check.py: Laura-tuotteet eivät kuulu hoidot-sulkuun).
-- Lauran koulutus-/poissaolosulut tehdään tarvittaessa käsin tälle resurssille (admin_create_block); Koulutus-kalenteritapahtumat eivät sulje mitään.
insert into booking.resources(code, name, kind, sort_order, buffer_after_min, notes)
select 'laura', 'Laura (henkilömääräpohjainen taito)', 'person', 125, 0,
       'Person-resurssi ilman henkilöitä: sulkukohde taidolle laura (booking_18); hoidot kiinni ei sulje tätä. Käsin tehdyt sulut (koulutus) kohdistetaan tähän. Ei koskaan julkisessa rajapinnassa.'
 where not exists (select 1 from booking.resources where code = 'laura');

-- ---------- sulkukalenteri-rekisteri ----------
create table if not exists booking.closure_calendars (
  code               text primary key check (code ~ '^[a-z_]+$'),
  name               text not null,                                   -- Google-kalenterin nimi (vain informatiivinen)
  resource_id        bigint not null references booking.resources(id), -- resurssi johon kalenterin sulut kirjoitetaan (space_blocks.space_id)
  google_calendar_id text,                                            -- asetetaan vasta kun kalenteri on jaettu palvelutilille (ei julkinen)
  timezone           text not null default 'Europe/Helsinki',        -- kokopäivätapahtumien päivämäärien tulkinta
  active             boolean not null default false,                  -- synkka ajaa vain active + google_calendar_id
  sort_order         integer not null default 100,
  last_attempt_at    timestamptz,
  last_success_at    timestamptz,
  last_error         text,
  consecutive_failures integer not null default 0,
  last_stats         jsonb,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint closure_calendars_active_needs_id check (not active or google_calendar_id is not null)
);

insert into booking.closure_calendars(code, name, resource_id, sort_order)
select v.code, v.name, r.id, v.so
  from (values ('hoidot',          '1 hoidot kiinni',          'saunottaja',            10),
               ('rauni',           '1 Rauni kiinni',           'rauni',                 20),
               ('perinnesaunotus', '1 perinnesaunotus kiinni', 'perinnesaunotus_ryhma', 30),
               ('savusauna',       '1 savusauna kiinni',       'savusauna',             40)) v(code, name, rc, so)
  join booking.resources r on r.code = v.rc
on conflict (code) do nothing;

-- ---------- luokittelusäännöt (muokattavissa ilman koodimuutosta) ----------
create table if not exists booking.closure_event_rules (
  id                  bigint generated always as identity primary key,
  calendar_code       text references booking.closure_calendars(code),  -- null = kaikki kalenterit
  sort_order          integer not null default 100,
  match_type          text not null check (match_type in ('prefix', 'equals', 'regex')),
  pattern             text not null,
  action              text not null check (action in ('ignore', 'block')),
  class               text not null,                                   -- 'mirror' | 'marker' | 'training' | ...
  extra_resource_code text,                                            -- action=block: sulje myös tämä resurssi (ei käytössä oletussäännöissä)
  note                text,
  active              boolean not null default true
);
create unique index if not exists closure_event_rules_uq on booking.closure_event_rules (coalesce(calendar_code, ''), match_type, pattern);

insert into booking.closure_event_rules(sort_order, match_type, pattern, action, class, extra_resource_code, note)
select v.* from (values
  (10, 'prefix', '[AUTO-JOHKU]',  'ignore', 'mirror',   null,    'Johkusta peilattu varaus – ei sulku (PLAN §16)'),
  (20, 'equals', 'Kekri',         'ignore', 'marker',   null,    'Oma tapahtuma-merkintä – ei sulku'),
  (21, 'equals', 'Yhteisöpäivä',  'ignore', 'marker',   null,    'Oma tapahtuma-merkintä – ei sulku'),
  (22, 'equals', 'Joulusauna',    'ignore', 'marker',   null,    'Oma tapahtuma-merkintä – ei sulku'),
  (30, 'equals', 'Koulutus',      'ignore', 'training', null,    'Koulutus ei sulje mitään (Joonas 17.10.); koulutussulut tehdään käsin (admin_create_block, myös laura-resurssille)')
) v(sort_order, match_type, pattern, action, class, extra_resource_code, note)
where not exists (select 1 from booking.closure_event_rules r where r.calendar_code is null and r.match_type = v.match_type and r.pattern = v.pattern);

-- ---------- synkattujen tapahtumien kirjanpito (ulkoinen id talteen; vain sulkuehdokkaat, ei peilejä) ----------
create table if not exists booking.closure_events (
  id               bigint generated always as identity primary key,
  calendar_code    text not null references booking.closure_calendars(code),
  external_id      text not null,                                     -- Google events.id (toistuvilla instanssikohtainen id)
  class            text not null check (class in ('closure', 'rough')),   -- rough = >36 h kestävä kellonaikatapahtuma (karkea jakso), ei sulje oletuksena
  reason           text,                                              -- tapahtuman otsikko (vain sulkuehdokkaat; peilien otsikoita ei tallenneta)
  all_day          boolean not null default false,
  starts_at        timestamptz not null,
  ends_at          timestamptz not null,
  extra_resource_id bigint references booking.resources(id),
  g_updated        timestamptz,
  content_hash     text not null,
  status           text not null default 'active' check (status in ('active', 'deleted')),
  override         text check (override in ('ignore', 'block')),      -- henkilökunnan ohitus: ignore = ei sulje; block = sulkee (esim. rough). Synkka säilyttää.
  override_note    text,
  override_by      uuid,
  override_at      timestamptz,
  first_seen_at    timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz,
  constraint closure_events_time_ok check (ends_at > starts_at),
  constraint closure_events_uq unique (calendar_code, external_id)
);
create index if not exists closure_events_cal_idx on booking.closure_events (calendar_code, status, starts_at);

-- ---------- ajoloki ----------
create table if not exists booking.closure_sync_runs (
  id            bigint generated always as identity primary key,
  calendar_code text not null,
  started_at    timestamptz not null default now(),
  outcome       text not null check (outcome in ('ok', 'guard', 'error')),
  stats         jsonb,
  error         text,
  source        text
);
create index if not exists closure_sync_runs_idx on booking.closure_sync_runs (started_at desc);

-- ---------- space_blocks: linkki ulkoiseen tapahtumaan ----------
alter table booking.space_blocks add column if not exists closure_event_id bigint references booking.closure_events(id) on delete cascade;
create unique index if not exists space_blocks_closure_uq on booking.space_blocks (closure_event_id, space_id) where closure_event_id is not null;

-- kalenterista tulevaa sulkua ei voi muokata/poistaa ylläpidon kautta (synkka palauttaisi sen) – muutos kalenterissa tai closure_events.override
create or replace function booking.space_blocks_managed_guard() returns trigger
 language plpgsql security definer set search_path to ''
as $function$
begin
  if old.closure_event_id is not null and coalesce(current_setting('booking.closure_sync', true), '') <> 'on' then
    perform booking._err('closure_managed', 'Tämä sulku tulee sulkukalenterista – muuta tai poista tapahtuma kalenterissa (tai merkitse tapahtuma ohitettavaksi)');
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $function$;
drop trigger if exists space_blocks_managed_guard on booking.space_blocks;
create trigger space_blocks_managed_guard before update or delete on booking.space_blocks
  for each row execute function booking.space_blocks_managed_guard();

-- ---------- asetukset ----------
-- (max_timed_hours = tätä pidemmät kellonaikatapahtumat luokitellaan rough (ei sulje); guard_* = massapoistosuoja; window_* = synkkaikkuna; tombstone_days = poistettujen kirjanpitorivien säilytys)
insert into booking.settings(key, value) values ('closure_sync', '{"max_timed_hours":36,"guard_min_deletes":5,"guard_ratio":0.5,"window_back_days":1,"window_forward_months":18,"tombstone_days":90}'::jsonb)
on conflict (key) do nothing;

-- ---------- oikeudet ----------
alter table booking.closure_calendars  enable row level security;
alter table booking.closure_event_rules enable row level security;
alter table booking.closure_events     enable row level security;
alter table booking.closure_sync_runs  enable row level security;
do $$ begin
  if not exists (select 1 from pg_policy where polrelid = 'booking.closure_calendars'::regclass and polname = 'staff_read') then
    create policy staff_read on booking.closure_calendars for select to authenticated using ((select booking.is_staff()));
  end if;
  if not exists (select 1 from pg_policy where polrelid = 'booking.closure_event_rules'::regclass and polname = 'staff_read') then
    create policy staff_read on booking.closure_event_rules for select to authenticated using ((select booking.is_staff()));
  end if;
  if not exists (select 1 from pg_policy where polrelid = 'booking.closure_events'::regclass and polname = 'staff_read') then
    create policy staff_read on booking.closure_events for select to authenticated using ((select booking.is_staff()));
  end if;
  if not exists (select 1 from pg_policy where polrelid = 'booking.closure_sync_runs'::regclass and polname = 'staff_read') then
    create policy staff_read on booking.closure_sync_runs for select to authenticated using ((select booking.is_staff()));
  end if;
end $$;
revoke all on booking.closure_calendars, booking.closure_event_rules, booking.closure_events, booking.closure_sync_runs from public, anon, authenticated;
grant select (code, name, resource_id, timezone, active, sort_order, last_attempt_at, last_success_at, last_error, consecutive_failures, last_stats)
  on booking.closure_calendars to authenticated;                       -- google_calendar_id EI näy asiakasrajapinnassa
grant select on booking.closure_event_rules, booking.closure_events, booking.closure_sync_runs to authenticated;
grant all on booking.closure_calendars, booking.closure_event_rules, booking.closure_events, booking.closure_sync_runs to service_role;
