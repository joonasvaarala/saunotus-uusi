-- shift_offer_rules: vapaiden vuorojen automaattisen tarjoamisen sääntödata + tarjoukset (Joonas 22.10.2026, SPEC.md).
-- Vaatii 20261021224946/224952 (DB-first). Yksi vuokralainen. Kaikki uusi on pois päältä: shift_offer_settings.enabled = false.
-- Viikonpäivä = ISO (1 = ma ... 7 = su), Helsingin paikallinen päivä. Viikon pariteetti = ISO-viikkonumero (even/odd).
-- Sulut: EI omaa sulkumallia. Rooli 'closed' (esim. hoidot pe, parittomat ma) ja perinnesaunotuksen hoitajasääntö ovat dataa,
-- jonka perusteella tarjousmoottori/Tapio JÄTTÄÄ tarjoamatta ja tarvittaessa luo sulun olemassa olevaan booking.closure_*-malliin.

-- ---------- asetukset (rivi per rooli) ----------
create table public.shift_offer_settings (
  role_type               text primary key check (role_type in ('heater','reception','therapist')),
  enabled                 boolean not null default false,            -- tarjousmoottori saa toimia tälle roolille
  start_before            interval not null default interval '3 months',  -- kysyminen alkaa aikaisintaan näin paljon ennen vuoroa
  all_by_before           interval not null default interval '3 days',    -- viimeistään tällöin kaikille
  quiet_start             time not null default '21:00',
  quiet_end               time not null default '08:00',
  quiet_mode              text not null default 'shift_deadline' check (quiet_mode in ('pause','shift_deadline')),
                          -- shift_deadline (Joonas 22.10. klo 2.37, oletus kaikille) = vastausaika kalenteriaikana; jos takaraja osuu
                          --   hiljaiseen aikaan [quiet_start, quiet_end) (21:00–08:00), se siirtyy seuraavaan klo 8:aan.
                          -- pause = vanha malli, vastausaika ei kulu 21–8 (ei käytössä, jätetty vaihtoehdoksi)
  timezone                text not null default 'Europe/Helsinki',
  group_size              int not null default 3 check (group_size between 1 and 20),
  group_max_wait          interval not null default interval '24 hours',
  rotation_last_staff_id  uuid references public.staff(id) on delete set null,   -- kiertovuoron osoitin
  snooze_staff_ids        uuid[] not null default '{}',               -- "Palaan asiaan" -oikeus (nimetyt)
  snooze_any_recipient    boolean not null default false,             -- "Palaan asiaan" kaikille vastaanottajille (hoitaja, vastaanotto; Joonas 22.10. klo 2.38)
  snooze_min_left         interval not null default interval '14 days',
  conflicting_roles       text[] not null default '{}',               -- päällekkäinen vuoro näissä rooleissa = este
  conflict_weekdays       smallint[] not null default '{1,2,3,4,5,6,7}',
  conflict_same_day       boolean not null default false,             -- true = päällekkäisyys koko Helsingin päivä (hoito <-> lämmitys); false = aikapäällekkäisyys
  conflict_exemptions     jsonb not null default '[]'::jsonb          -- [{"staff_id": uuid, "weekdays": [3]}] = ei estettä (Joonas ke lämmittää ja hoitaa)
                          check (jsonb_typeof(conflict_exemptions) = 'array'),
  exhausted_ask_staff_id  uuid references public.staff(id) on delete set null,   -- kaikki kysytty -> kysytään tältä (Joonas)
  exhausted_ask_count     smallint not null default 3 check (exhausted_ask_count between 1 and 10),  -- kysytään enintään N kertaa (Joonas 22.10. klo 2.41)
  exhausted_ask_interval  interval not null default interval '1 day', -- kerran vrk:ssa klo 8–21; tiiviimmin lähellä vuoroa (shift_exhausted_next_step)
  exhausted_ask_min_interval interval not null default interval '1 hour',
  auto_close_enabled      boolean not null default false,             -- N:nteenkään kysymykseen ei vastausta -> vuoro suljetaan (hoidot kiinni)
  auto_close_after        interval,                                   -- odotus viimeisen kysymyksen jälkeen; null = sama väli kuin kysymyksillä
  alert_before            interval not null default interval '24 hours',
  alert_staff_ids         uuid[] not null default '{}',
  updated_at              timestamptz not null default now(),
  updated_by              text,
  constraint shift_offer_settings_interval_chk check (exhausted_ask_min_interval > interval '0' and exhausted_ask_min_interval <= exhausted_ask_interval)
);

-- ---------- vakituiset tekijät / suljetut päivät ----------
create table public.shift_default_owners (
  id               bigint generated always as identity primary key,
  role_type        text not null check (role_type in ('heater','reception','therapist')),
  weekday          smallint not null check (weekday between 1 and 7),
  week_parity      text not null default 'any' check (week_parity in ('any','even','odd')),
  owner_kind       text not null check (owner_kind in ('staff','closed','follow_role','not_offered')),
  staff_id         uuid references public.staff(id) on delete cascade,
  follow_role_type text check (follow_role_type in ('heater','reception','therapist')),
  valid_from       date not null default date '2000-01-01',
  valid_to         date,                                   -- mukaan lukien; null = toistaiseksi
  priority         int not null default 0,                 -- isompi voittaa (esim. väliaikainen korvaaja)
  note             text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint shift_default_owners_staff_chk check ((owner_kind = 'staff') = (staff_id is not null)),
  constraint shift_default_owners_follow_chk check ((owner_kind = 'follow_role') = (follow_role_type is not null)
                                                    and follow_role_type is distinct from role_type),
  constraint shift_default_owners_range_chk check (valid_to is null or valid_to >= valid_from),
  constraint shift_default_owners_uniq unique (role_type, weekday, week_parity, priority, valid_from)
);
create index shift_default_owners_staff_idx on public.shift_default_owners (staff_id);
comment on table public.shift_default_owners is 'Vakiotekijä per rooli/viikonpäivä/viikon pariteetti. closed = rooli ei toimi (ei vuoroja, ei tarjouksia). not_offered = roolia ei määritellä eikä tarjota (pe vastaanotto: vuoron lämmittäjä tai tapahtuman vetäjä); tarjousmoottori ei luo ehdokkaita eikä tarjouksia (trigger torjuu). follow_role = sama henkilö kuin toisen roolin vakiotekijä (arjen vastaanotto = hoitaja). Valinta: voimassa olevista tarkka pariteetti > any, sitten priority, sitten uusin valid_from.';

-- ---------- tarjouskierrokset + jäsenet ----------
create table public.shift_offer_rounds (
  id          bigint generated always as identity primary key,
  role_type   text not null check (role_type in ('heater','reception','therapist')),
  scenario    text not null default 'vacant_shift' check (scenario in ('vacant_shift','reception_extra')),
              -- vacant_shift = koko vuoro vapaana; reception_extra = erillinen vastaanottaja (hoito 16–17 / jälkilöylyt)
  weekdays    smallint[] not null check (cardinality(weekdays) > 0 and weekdays <@ '{1,2,3,4,5,6,7}'::smallint[]),
  round_no    smallint not null check (round_no >= 1),
  kind        text not null check (kind in ('named','rotation','all','named_last')),
  valid_from  date not null default date '2000-01-01',
  valid_to    date,
  note        text,
  created_at  timestamptz not null default now(),
  constraint shift_offer_rounds_range_chk check (valid_to is null or valid_to >= valid_from),
  constraint shift_offer_rounds_uniq unique (role_type, scenario, weekdays, round_no, valid_from)
);
create table public.shift_offer_round_members (
  round_id     bigint not null references public.shift_offer_rounds(id) on delete cascade,
  staff_id     uuid not null references public.staff(id) on delete cascade,
  week_parity  text not null default 'any' check (week_parity in ('any','even','odd')),
  sort_order   smallint not null default 0,
  primary key (round_id, staff_id)
);
create index shift_offer_round_members_staff_idx on public.shift_offer_round_members (staff_id);
comment on table public.shift_offer_rounds is 'Kierrokset vakiotekijän jälkeen. named/named_last = jäsenet yhtä aikaa; rotation = group_size kerrallaan kiertäen roolin muista; all = kaikki roolin aktiiviset paitsi named_last-jäsenet. Aiemman kierroksen tarjoukset pysyvät voimassa.';

-- ---------- henkilö-päivä-rajoitukset ----------
create table public.shift_staff_restrictions (
  id          bigint generated always as identity primary key,
  role_type   text not null check (role_type in ('heater','reception','therapist')),
  staff_id    uuid not null references public.staff(id) on delete cascade,
  weekdays    smallint[] check (weekdays is null or (cardinality(weekdays) > 0 and weekdays <@ '{1,2,3,4,5,6,7}'::smallint[])), -- null = kaikki
  week_parity text not null default 'any' check (week_parity in ('any','even','odd')),
  valid_from  date not null default date '2000-01-01',
  valid_to    date,
  note        text,
  created_at  timestamptz not null default now(),
  constraint shift_staff_restrictions_range_chk check (valid_to is null or valid_to >= valid_from)
);
create index shift_staff_restrictions_staff_idx on public.shift_staff_restrictions (staff_id);
comment on table public.shift_staff_restrictions is 'Ei koskaan tarjota: rooli + henkilö + viikonpäivät + pariteetti. Ohittaa kierrosten jäsenyyden.';

-- ---------- vastausajat ----------
create table public.shift_offer_response_tiers (
  id               bigint generated always as identity primary key,
  role_type        text check (role_type in ('heater','reception','therapist')),  -- null = kaikki roolit
  min_lead         interval not null,          -- porras pätee, kun now + min_lead <= vuoron alku (suurin täyttyvä voittaa)
  wait             interval,
  wait_last_round  interval,                   -- kaikille lähtevä kierros, jos eri
  direct_to_all    boolean not null default false,
  note             text,
  constraint shift_offer_response_tiers_chk check (direct_to_all or wait is not null)
);
create unique index shift_offer_response_tiers_uniq on public.shift_offer_response_tiers (coalesce(role_type, '*'), min_lead);

-- ---------- palvelun sallitut hoitajat (sääntö 9: perinnesaunotus) ----------
create table public.shift_service_allowed_therapists (
  id            bigint generated always as identity primary key,
  service_code  text not null references booking.closure_calendars(code),
  weekday       smallint not null check (weekday between 1 and 7),
  staff_id      uuid not null references public.staff(id) on delete cascade,
  valid_from    date not null default date '2000-01-01',
  valid_to      date,
  note          text,
  constraint shift_service_allowed_range_chk check (valid_to is null or valid_to >= valid_from),
  constraint shift_service_allowed_uniq unique (service_code, weekday, staff_id, valid_from)
);
create index shift_service_allowed_staff_idx on public.shift_service_allowed_therapists (staff_id);
create table public.shift_service_date_overrides (
  id            bigint generated always as identity primary key,
  service_code  text not null references booking.closure_calendars(code),
  on_date       date not null,
  mode          text not null check (mode in ('open','closed')),   -- open = ei suljeta hoitajasta riippumatta
  note          text,
  created_at    timestamptz not null default now(),
  constraint shift_service_date_overrides_uniq unique (service_code, on_date)
);
comment on table public.shift_service_allowed_therapists is 'Palvelu (booking.closure_calendars.code) on auki vain, jos päivän hoitaja on listalla; muuten tarvitaan sulku olemassa olevaan closure-malliin. Ei rivejä viikonpäivälle = ei rajoitusta.';

-- ---------- tarjoukset ----------
create table public.shift_offers (
  id                    uuid primary key default gen_random_uuid(),
  shift_id              uuid not null references public.work_shifts(id) on delete cascade,
  role_type             text not null check (role_type in ('heater','reception','therapist')),
  scenario              text not null default 'vacant_shift' check (scenario in ('vacant_shift','reception_extra')),
  window_starts_at      timestamptz,             -- reception_extra: tarvittava aikaikkuna
  window_ends_at        timestamptz,
  status                text not null default 'active'
                        check (status in ('active','paused','filled','exhausted','escalated','closed','cancelled')),
  current_round_no      smallint not null default 1,
  round_started_at      timestamptz,
  next_action_at        timestamptz,
  all_sent_at           timestamptz,
  accepted_staff_id     uuid references public.staff(id) on delete set null,
  accepted_recipient_id bigint,
  accepted_at           timestamptz,
  assignment_result     jsonb,
  assignment_error      text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  created_by            text,
  note                  text,
  constraint shift_offers_window_chk check ((window_starts_at is null) = (window_ends_at is null) and (window_ends_at is null or window_ends_at > window_starts_at)),
  constraint shift_offers_filled_chk check ((status = 'filled') = (accepted_staff_id is not null and accepted_at is not null))
);
create unique index shift_offers_one_open_idx on public.shift_offers (shift_id, scenario, coalesce(window_starts_at, '-infinity'::timestamptz))
  where status in ('active','paused','escalated');
create index shift_offers_due_idx on public.shift_offers (next_action_at) where status in ('active','paused','escalated');
create index shift_offers_shift_idx on public.shift_offers (shift_id);
create index shift_offers_accepted_staff_idx on public.shift_offers (accepted_staff_id);

create table public.shift_offer_recipients (
  id                  bigint generated always as identity primary key,
  offer_id            uuid not null references public.shift_offers(id) on delete cascade,
  staff_id            uuid not null references public.staff(id) on delete cascade,
  round_no            smallint not null,
  round_kind          text not null check (round_kind in ('named','rotation','all','named_last','owner_ask')),
  status              text not null default 'pending'
                      check (status in ('queued','pending','accepted','declined','snoozed','filled_other','withdrawn')),
  sent_at             timestamptz,
  deadline_at         timestamptz,
  responded_at        timestamptz,
  snooze_until        timestamptz,
  reminder_sent_at    timestamptz,
  filled_notified_at  timestamptz,               -- "vuoro on täytetty" -ilmoitus lähetetty
  channel             text,
  message_ref         text,
  created_at          timestamptz not null default now(),
  constraint shift_offer_recipients_uniq unique (offer_id, staff_id),
  constraint shift_offer_recipients_snooze_chk check ((status = 'snoozed') = (snooze_until is not null))
);
-- KOVA TAKUU: yksi hyväksyjä per tarjous
create unique index shift_offer_recipients_one_winner_idx on public.shift_offer_recipients (offer_id) where status = 'accepted';
create index shift_offer_recipients_staff_idx on public.shift_offer_recipients (staff_id);
create index shift_offer_recipients_open_idx on public.shift_offer_recipients (deadline_at) where status in ('pending','snoozed');
create index shift_offer_recipients_notify_idx on public.shift_offer_recipients (offer_id) where status = 'filled_other' and filled_notified_at is null;
alter table public.shift_offers add constraint shift_offers_accepted_recipient_fkey
  foreign key (accepted_recipient_id) references public.shift_offer_recipients(id) on delete set null;
create index shift_offers_accepted_recipient_idx on public.shift_offers (accepted_recipient_id);

-- ---------- RLS + oikeudet: vain service_role ----------
do $$
declare t text;
begin
  foreach t in array array['shift_offer_settings','shift_default_owners','shift_offer_rounds','shift_offer_round_members',
    'shift_staff_restrictions','shift_offer_response_tiers','shift_service_allowed_therapists','shift_service_date_overrides',
    'shift_offers','shift_offer_recipients'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
    execute format('grant select, insert, update, delete on table public.%I to service_role', t);
  end loop;
end $$;
