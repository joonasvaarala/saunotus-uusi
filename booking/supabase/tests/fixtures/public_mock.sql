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
