-- HISTORY-SYNC: applied in production, do not rerun. Tuotannon versio 20261021203653 (staff_unavailability), Supabase sxbofnuisemspgquoxyv.
-- Lähde: tuotannon supabase_migrations.schema_migrations.statements[1] (md5 3b95c16cca26f20f8f1a51e6418f1e46). Sisältö sama, mutta
-- idempotentiksi vartioituna: create table / create [unique] index if not exists sellaisenaan (rajoitteet ovat create tablen sisällä);
-- RLS ja kommentit asetetaan vain, jos tila poikkeaa (alter table enable rls kirjoittaisi muuten pg_classin uudelleen ja lukitsisi taulun).
-- Ei RLS-politiikkoja (tuotannossakaan ei ole). Uudelleenajo on no-op (ei katalogimuutoksia).
-- Myöhemmät muutokset: lähderajoite laajenee (staff_bot / otto_bot) ja staff_unavailability_otto_bot_ref_uidx syntyy migraatiossa
-- 20261025160701_botgw_otto_calendar_guard. Tuotannon staff_bot_access (20261021212547) ja staff_bot_unavailability_write_all
-- (20261021213138) puuttuvat vielä reposta.
create table if not exists public.staff_unavailability (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  source text not null check (source in ('personal_calendar','sauna_calendar','email','whatsapp','hallinta')),
  external_ref text,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint staff_unavailability_range_chk check (ends_at > starts_at)
);
create index if not exists staff_unavailability_staff_time_idx on public.staff_unavailability (staff_id, starts_at, ends_at);
create unique index if not exists staff_unavailability_source_ref_uidx on public.staff_unavailability (source, external_ref) where external_ref is not null;
do $hs$
begin
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.staff_unavailability'::regclass) then
    alter table public.staff_unavailability enable row level security;
  end if;
  if obj_description('public.staff_unavailability'::regclass, 'pg_class') is distinct from 'Työntekijöiden esteet vuorotarjouksille. Ei syytä tai otsikkoa, vain aika. source kertoo kirjaajan: personal_calendar ja sauna_calendar = Henkilökohtainen Avustaja, email/whatsapp = Työvuoro-Tapio, hallinta = käsin.' then
    comment on table public.staff_unavailability is 'Työntekijöiden esteet vuorotarjouksille. Ei syytä tai otsikkoa, vain aika. source kertoo kirjaajan: personal_calendar ja sauna_calendar = Henkilökohtainen Avustaja, email/whatsapp = Työvuoro-Tapio, hallinta = käsin.';
  end if;
  if col_description('public.staff_unavailability'::regclass,
       (select a.attnum from pg_attribute a where a.attrelid = 'public.staff_unavailability'::regclass and a.attname = 'external_ref'))
     is distinct from 'Vapaaehtoinen lähdeviite (esim. kalenteritapahtuman id) tuplien estoon; ei sisällä otsikkoa.' then
    comment on column public.staff_unavailability.external_ref is 'Vapaaehtoinen lähdeviite (esim. kalenteritapahtuman id) tuplien estoon; ei sisällä otsikkoa.';
  end if;
end $hs$;
