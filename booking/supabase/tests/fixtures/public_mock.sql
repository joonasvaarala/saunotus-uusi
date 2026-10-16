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
  name text not null,
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
  staff_id uuid not null references public.staff(id)
);
revoke all on public.staff, public.calendar_sources, public.work_shifts, public.shift_assignments from anon, authenticated;
