-- public-skeeman MOCK testeihin ja demoon (Työvuoro-Tapion taulut). EI AJETA TUOTANTOON.
-- Sarakenimet ovat OLETUKSIA (ei yhteyttä tuotantokantaan): Bottiavustuksen on tarkistettava ne list_tables-työkalulla ennen migraatioiden ajoa,
-- ks. docs/roolit-ja-kb.md. Mukana tarkoituksella henkilötietosarakkeita (phone, notes), joiden ei pidä vuotaa booking-funktioista.
-- authenticated/anon-rooleille EI anneta oikeuksia näihin tauluihin: booking-funktiot (SECURITY DEFINER) lukevat ne.
create table if not exists public.staff (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text,
  phone text,
  active boolean not null default true
);
create table if not exists public.calendar_sources (
  id uuid primary key default gen_random_uuid(),
  calendar_name text not null,
  google_calendar_id text
);
create table if not exists public.work_shifts (
  id uuid primary key default gen_random_uuid(),
  calendar_source_id uuid references public.calendar_sources(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  role_type text,
  status text not null default 'active',
  staffing_status text,
  notes text
);
create table if not exists public.shift_assignments (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null references public.work_shifts(id) on delete cascade,
  staff_id uuid not null references public.staff(id),
  status text not null default 'assigned'          -- migraatio 16 (therapist_on_duty): 'assigned' | 'confirmed' lasketaan työvuoroksi
);
-- Migraatio 16 (taidot): saunottajaroolit. therapist_skills() laskee aktiiviset saunottajat (role_type = 'therapist' AND active) tästä taulusta.
create table if not exists public.staff_roles (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  role_type text not null,
  active boolean not null default true
);
revoke all on public.staff, public.calendar_sources, public.work_shifts, public.shift_assignments, public.staff_roles from anon, authenticated;
-- Migraatio 16 siemenää staff_skill_overrides-rivit tuotannon public.staff-id:illä ja keskeytyy, jos ne puuttuvat. Mock-henkilöt samoilla id:illä
-- (keksityt nimet; ei oikeita henkilötietoja). Ladataan ENNEN migraatioita (run.sh / setup-db.sh lataavat tämän tiedoston ensin).
insert into public.staff (id, name, email, phone, active) values
  ('040e1780-554c-4842-bc7d-b53053de9e5f', 'Mock Saunottaja A (saunotus, erityistilaisuudet)', 'mock.a@example.com', '0400000010', true),
  ('5ab2ba62-97b2-4712-b500-a47a898036a5', 'Mock Saunottaja B (saunotus)',                     'mock.b@example.com', '0400000011', true),
  ('d88e26c4-1830-42e1-86f5-ae63e8653b86', 'Mock Saunottaja C (ei morsiussauna)',              'mock.c@example.com', '0400000012', true)
on conflict (id) do nothing;
insert into public.staff_roles (staff_id, role_type, active)
select id, 'therapist', true from public.staff where id in ('040e1780-554c-4842-bc7d-b53053de9e5f', '5ab2ba62-97b2-4712-b500-a47a898036a5', 'd88e26c4-1830-42e1-86f5-ae63e8653b86');

-- Tuotannon public-skeema on laajempi kuin tämä mockki. Sarakkeet ja triggeri tarvitaan, jotta
-- shift_db_first- ja vuorotarjousmigraatiot sekä niiden testit asentuvat (EI tuotantoon).
alter table public.staff add column if not exists calendar_name text;
alter table public.staff add column if not exists phone_e164 text;
alter table public.staff add column if not exists whatsapp_enabled boolean not null default false;
alter table public.work_shifts add column if not exists calendar_title text not null default '';
alter table public.work_shifts add column if not exists google_event_id text;
alter table public.work_shifts add column if not exists updated_at timestamptz not null default now();
alter table public.work_shifts add column if not exists last_synced_at timestamptz not null default now();
alter table public.work_shifts add column if not exists cancelled_at timestamptz;
alter table public.calendar_sources add column if not exists role_type text;
alter table public.calendar_sources add column if not exists active boolean not null default true;
alter table public.calendar_sources add column if not exists created_at timestamptz not null default now();
alter table public.shift_assignments add column if not exists source text;
alter table public.shift_assignments add column if not exists notes text;
alter table public.shift_assignments add column if not exists updated_at timestamptz not null default now();
create unique index if not exists shift_assignments_shift_staff_uidx on public.shift_assignments (shift_id, staff_id);
create table if not exists public.staff_unavailability (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  source text not null default 'email',
  external_ref text,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint staff_unavailability_time_chk check (ends_at > starts_at)
);
revoke all on public.staff_unavailability from anon, authenticated;
create or replace function public.tg_work_shifts_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
drop trigger if exists work_shifts_updated_at on public.work_shifts;
create trigger work_shifts_updated_at before update on public.work_shifts
  for each row execute function public.tg_work_shifts_updated_at();
