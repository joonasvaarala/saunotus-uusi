-- DRAFT (EI AJETTU) 17.10.2026 – booking_17a_schema: legit, tilapuskuri, istuntoavaimet, saunottajan taitomalli (additiivinen, ei käyttäytymismuutosta)
-- Lähde: DESIGN_resources_v2.md B3–B9 + §0b–§0e; nykyinen DB-tila luettu 17.10.2026 (booking_01–16 + testierä).
-- Turvallisuus: vain ADD COLUMN (vakioarvo) / CREATE TABLE / CREATE VIEW / CREATE FUNCTION + datasiemenet; ei muuta olemassa olevia rivejä (paitsi siemenet alla).
-- Idempotentti: if not exists / on conflict / drop trigger if exists / create or replace.
set local search_path = booking, extensions, public;

-- ---------- varaukset: kiintiövapautus (lahjakortti), varauksen "claim"-ikkuna, lisäpalvelun vanhempi ----------
alter table booking.reservations
  add column if not exists quota_exempt boolean not null default false,            -- ohittaa vain myyntikiintiön (poolit); ei sulkuja/poissulkua
  add column if not exists claim_offset_min integer not null default 0,           -- ensisijaisen tilan käyttö alkaa starts_at + offset (paketti kb 7: 30)
  add column if not exists claim_minutes integer,                                  -- null = ends_at asti (paketti kb 7: 90)
  add column if not exists parent_reservation_id bigint references booking.reservations(id) on delete set null,  -- lisäpalvelu (kb 27/28) -> jälkilöyly-/yksityisvuoro
  add column if not exists override_reason text;                                   -- ylitys (oikeus bookings.override): ohittaa sulku- ja saunottajatarkistuksen; näkyy "Tarkista"-listalla
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'reservations_claim_ok' and conrelid = 'booking.reservations'::regclass) then
    alter table booking.reservations add constraint reservations_claim_ok check (
      claim_offset_min >= 0 and (claim_minutes is null or claim_minutes > 0)
      and (mode = 'shared' or (claim_offset_min = 0 and claim_minutes is null)));    -- yksinoikeusvarauksella aina koko ikkuna (EXCLUDE käyttää during-saraketta)
  end if;
end $$;
create index if not exists reservations_parent_idx on booking.reservations (parent_reservation_id) where parent_reservation_id is not null;

-- ---------- resurssit: istuntopohjainen yksinoikeus (Rauni/Lovi) ja rituaalipooli ----------
alter table booking.resources
  add column if not exists session_exclusive boolean not null default false,       -- true: shared-varaukset jakavat tilan vain samassa istunnossa (sama pooli + sama alku); muuten konflikti (+ puskuri)
  add column if not exists is_ritual_pool boolean not null default false;          -- rituaali-claimien välillä käytetään buffer_ritual_ritual_min (10) eikä buffer_after_min (15)
update booking.resources set session_exclusive = true where code in ('rauni', 'lovi') and not session_exclusive;
update booking.resources set is_ritual_pool = true where code = 'rauni_rituaali' and not is_ritual_pool;

-- ---------- taidot: vuoropohjainen vs. henkilömääräpohjainen (Laura) ----------
alter table booking.skills add column if not exists shift_based boolean not null default true;   -- false: kapasiteetti = taidon haltijoiden lukumäärä, ei vuoroja (Laura, O3)
update booking.skills set shift_based = false where code = 'laura' and shift_based;

-- ---------- tuotekonfiguraatio: istuntopooli saunottajalle, alkuaikapoolin etuliite, lisäpalvelun vanhempituotteet ----------
alter table booking.product_config
  add column if not exists therapist_session_pool_id bigint references booking.resources(id),   -- samaan pooliin+alkuun kuuluvat saunottajalegit jakavat yhden saunottajan (rituaali, tapahtuma)
  add column if not exists start_pool_prefix text,                                               -- kb 7: leg 1 pooli = etuliite || HH24MI (alku+offset), esim. yleinen_vkp_1430
  add column if not exists requires_parent_product_ids bigint[] not null default '{}';           -- kb 27/28: vaatii samalle ajalle jälkilöyly-/yksityisvuorovarauksen
update booking.product_config pc set therapist_session_pool_id = r.id
  from booking.resources r
 where r.code = case pc.product_id when 7 then 'rauni_rituaali' when 8 then 'rauni_rituaali' when 9 then 'event_9' when 32 then 'event_32'
                                   when 33 then 'event_33' when 34 then 'event_34' end
   and pc.therapist_session_pool_id is null;
update booking.product_config set start_pool_prefix = 'yleinen_vkp_' where product_id = 7 and start_pool_prefix is null;
update booking.product_config set requires_parent_product_ids = '{26,48,49}' where product_id = 27 and requires_parent_product_ids = '{}';  -- Perinnesaunotus jälkilöylyille
update booking.product_config set requires_parent_product_ids = '{25}'       where product_id = 28 and requires_parent_product_ids = '{}';  -- Perinnesaunotus yksityisvuorolle

-- ---------- oikeus: ylitys (saunottaja-/sulkutarkistuksen ohitus syyllä) ----------
insert into booking.role_permissions (role_code, permission) values ('admin', 'bookings.override'), ('manager', 'bookings.override') on conflict do nothing;

-- ---------- reservation_legs ----------
create table if not exists booking.reservation_legs (
  id bigint generated always as identity primary key,
  reservation_id bigint not null references booking.reservations(id) on delete cascade,
  resource_id bigint not null references booking.resources(id),
  role text not null check (role in ('space', 'therapist', 'group')),             -- group = sulkuryhmäleg (perinnesaunotus_ryhma)
  mode text not null check (mode in ('shared', 'exclusive')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  during tstzrange generated always as (tstzrange(starts_at, ends_at, '[)')) stored,
  offset_min integer not null default 0 check (offset_min >= 0),                   -- suhteessa varauksen alkuun (leg-ikkuna lasketaan uudelleen kun varaus siirtyy)
  minutes integer check (minutes is null or minutes > 0),                          -- null = varauksen loppuun asti
  persons integer not null check (persons >= 1),                                   -- saunottajalle: tarvittavien saunottajien lukumäärä
  pool_ids bigint[] not null default '{}',
  skill text references booking.skills(code),                                      -- vain role='therapist'
  session_key text,                                                                -- samaan avaimeen kuuluvat shared-legit jakavat tilan/saunottajan
  staff_id uuid,                                                                   -- valinnainen nimetty saunottaja (vain sisäinen tieto; ei FK public-skeemaan)
  quota_exempt boolean not null default false,
  override_reason text,
  rule_id bigint references booking.product_space_rules(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint reservation_legs_time_ok check (ends_at > starts_at),
  constraint reservation_legs_skill_ok check ((role = 'therapist') = (skill is not null)),
  constraint reservation_legs_group_ok check (role <> 'group' or (mode = 'shared' and cardinality(pool_ids) = 0))
);
create index if not exists reservation_legs_res_idx on booking.reservation_legs (reservation_id);
create unique index if not exists reservation_legs_uq on booking.reservation_legs (reservation_id, role, resource_id, offset_min);   -- idempotentti backfill (ON CONFLICT)
create index if not exists reservation_legs_res_time_idx on booking.reservation_legs using gist (resource_id, during);
alter table booking.reservation_legs enable row level security;
revoke all on booking.reservation_legs from public, anon, authenticated;
grant select on booking.reservation_legs to authenticated;
grant all on booking.reservation_legs to service_role;
drop policy if exists staff_read on booking.reservation_legs;
create policy staff_read on booking.reservation_legs for select to authenticated using ((select booking.is_staff()));
drop trigger if exists audit_trg on booking.reservation_legs;
select booking._add_audit('booking.reservation_legs');
revoke all on sequence booking.reservation_legs_id_seq from public, anon, authenticated;
grant all on sequence booking.reservation_legs_id_seq to service_role;

-- ---------- apufunktiot ----------
create or replace function booking._session_key(p_pools bigint[], p_mode text, p_start timestamptz)
 returns text language sql immutable set search_path to ''
as $$ select case when p_mode = 'shared' and cardinality(coalesce(p_pools, '{}')) > 0
                  then array_to_string(p_pools, ',') || '@' || extract(epoch from p_start)::bigint::text end $$;

create or replace function booking._is_ritual(p_pools bigint[])
 returns boolean language sql stable security definer set search_path to ''
as $$ select exists (select 1 from booking.resources r where r.id = any (coalesce(p_pools, '{}')) and r.is_ritual_pool) $$;

-- Ottaa tilalukot nousevassa resurssi-id-järjestyksessä (samat avaimet kuin reservations_validate) -> ei ristiinlukitusta
create or replace function booking._lock_resources(p_ids bigint[])
 returns void language plpgsql security definer set search_path to ''
as $$
declare v bigint;
begin
  for v in select distinct x from unnest(coalesce(p_ids, '{}')) x where x is not null order by x loop
    perform pg_advisory_xact_lock(hashtextextended('booking:space:' || v::text, 0));
  end loop;
end $$;

-- Yhteinen claim-virta: ensisijainen tila (varaus) + legit. Tila ja pitoaika liitetään varauksesta (ei kopioida).
create or replace view booking.v_claims with (security_invoker = true) as
  select r.id as reservation_id, null::bigint as leg_id, r.space_id as resource_id, 'space'::text as role, r.mode,
         r.starts_at + make_interval(mins => r.claim_offset_min) as claim_start,
         case when r.claim_minutes is null then r.ends_at else r.starts_at + make_interval(mins => r.claim_offset_min + r.claim_minutes) end as claim_end,
         r.persons, r.pool_ids, null::text as skill,
         booking._session_key(r.pool_ids, r.mode, r.starts_at + make_interval(mins => r.claim_offset_min)) as session_key,
         r.quota_exempt, r.status, r.hold_expires_at, r.product_id, r.order_id, (r.override_reason is not null) as is_override
    from booking.reservations r
  union all
  select l.reservation_id, l.id, l.resource_id, l.role, l.mode, l.starts_at, l.ends_at, l.persons, l.pool_ids, l.skill, l.session_key,
         (l.quota_exempt or r.quota_exempt), r.status, r.hold_expires_at, r.product_id, r.order_id, (l.override_reason is not null or r.override_reason is not null)
    from booking.reservation_legs l join booking.reservations r on r.id = l.reservation_id;
revoke all on booking.v_claims from public, anon, authenticated;
grant select on booking.v_claims to service_role;
revoke all on function booking._session_key(bigint[], text, timestamptz) from public, anon, authenticated;
revoke all on function booking._is_ritual(bigint[]) from public, anon, authenticated;
revoke all on function booking._lock_resources(bigint[]) from public, anon, authenticated;
grant execute on function booking._session_key(bigint[], text, timestamptz) to service_role;
grant execute on function booking._is_ritual(bigint[]) to service_role;
grant execute on function booking._lock_resources(bigint[]) to service_role;
