-- APPLIED 2026-10-16 klo 23.36 (Europe/Helsinki): versio 20261016203603 (booking_15_resource_seed) via apply_migration; sama SQL kuin tässä tiedostossa.
-- 15_resource_seed (Joonas hyväksyi ajon chatissa 16.10.2026; schema booking; ei kb-/public-muutoksia, kb:tä vain luetaan)
-- Sisältö (DESIGN_resources_v2.md B3, B5b, B6b, B8, §0b–§0e):
--  * resources.buffer_after_min (Rauni 15) + buffer_ritual_ritual_min (Rauni 10: rituaalien keskinäinen poikkeus, Joonas O2)
--  * resurssit: rauni, lovi, saunottaja (person), ei_resurssia, perinnesaunotus_ryhma (virtuaalinen) + poolit rauni_rituaali (6), event_9/32/32_rauni/33/34 (8)
--    Savusaunan tilakapasiteetti pysyy NULL (§0e: rajat ovat tuotekohtaisia). Rauni/Lovi kapasiteetti NULL samasta syystä (tapahtumat 8 > DESIGN B3:n alkuperäinen 6).
--  * product_space_rules: tuote -> tila/leg-säännöt (data-ohjattu; moottori lukee vasta booking_17:ssä). Lovi: selection='auto_if_blocked' + requires_blocked_space_id=rauni.
--    Lisäys DESIGNiin: sarake `role` (space|group) sulkuryhmälegille ja `requires_blocked_space_id`.
--  * RLS + staff_read-politiikka ((select booking.is_staff())), audit_trg, set_updated_at; oikeudet: authenticated vain SELECT (RLS), service_role kaikki.
--  * EI mukana (ei pyydetty / DESIGN D1:ssä erikseen): viikonlopun yksityisvuorosäännöt (schedule_rules, hinnoittelu vaatii päätöksen), reservation_legs/v_claims (booking_17).
-- Idempotentti: add column if not exists, ON CONFLICT DO NOTHING, drop trigger if exists + add.
set local search_path = booking, extensions, public;

alter table booking.resources
  add column if not exists buffer_after_min integer not null default 0,
  add column if not exists buffer_ritual_ritual_min integer;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'resources_buffer_check' and conrelid = 'booking.resources'::regclass) then
    alter table booking.resources add constraint resources_buffer_check
      check (buffer_after_min between 0 and 240 and (buffer_ritual_ritual_min is null or buffer_ritual_ritual_min between 0 and 240));
  end if;
end $$;

-- tilat (kb_location_id: 3 Hoitosauna Rauni, 7 Hoitosauna Lovi)
insert into booking.resources (code, name, kind, kb_location_id, sort_order, buffer_after_min, notes)
select v.code, v.name, v.kind, v.loc, v.so, v.buf, v.notes
  from (values
  ('rauni', 'Hoitosauna Rauni', 'space', 3, 100, 15, 'Hoidot/saunotukset exclusive; rituaalit/tapahtumat shared + pooli. Väli >= 15 min istuntojen välillä (rituaali-rituaali 10 min: buffer_ritual_ritual_min). Kapasiteetti NULL: rajat tuote-/pooli-/sääntökohtaisia (4/6/8).'),
  ('lovi', 'Hoitosauna Lovi', 'space', 7, 110, 0, 'Vain 1 hlö; tarjotaan vain kun Rauni on suljettu (product_space_rules.auto_if_blocked + requires_blocked_space_id).'),
  ('saunottaja', 'Saunottaja (kapasiteetti työvuoroista)', 'person', null, 120, 0, 'Person-resurssi ilman henkilöitä: lukumäärä johdetaan public.work_shifts-datasta (booking_16 therapist_on_duty). Ei koskaan julkisessa rajapinnassa.'),
  ('ei_resurssia', 'Ei resurssia (tekstituonti / lisäpalvelut)', 'space', null, 130, 0, 'Tekstituonti ja lisäpalvelut (kb 27/28): ei sulkuja eikä poolia.'),
  ('perinnesaunotus_ryhma', 'Perinnesaunotus-sulkuryhmä (virtuaalinen)', 'space', null, 140, 0, 'Virtuaalinen: kalenterin "1 perinnesaunotus kiinni" kohde; ryhmän tuotteet (closure_group=perinnesaunotus) saavat role=group-legin. Ei fyysinen paikka, ei julkinen.')
  ) v(code, name, kind, loc, so, buf, notes)
on conflict (code) do nothing;

update booking.resources set buffer_after_min = 0 where code = 'savusauna' and buffer_after_min is distinct from 0;
update booking.resources set buffer_after_min = 15, buffer_ritual_ritual_min = 10 where code = 'rauni' and (buffer_after_min, buffer_ritual_ritual_min) is distinct from (15, 10);

-- poolit (capacity_pool: parent + capacity pakollisia)
insert into booking.resources (code, name, kind, parent_id, capacity, sort_order, notes)
select v.code, v.name, 'capacity_pool', p.id, v.cap, v.so, v.notes
  from (values
  ('rauni_rituaali', 'Rauni: rituaalipaikat (20 min rituaali, jaettu istunto)', 'rauni', 6, 150, 'Saunotusrituaali kb 8 ja paketin kb 7 rituaaliosa: max 6 hlö / istunto. Shared vs exclusive-poissulku sulkee Raunin hoidoilta.'),
  ('event_9', 'Perinnesaunotusilta kb 9: paikat', 'savusauna', 8, 151, 'Ryhmätapahtuma: max 8 hlö (Joonas). Savusauna jaettu.'),
  ('event_32', 'Naisten jouluinen saunailta kb 32: savusaunapaikat', 'savusauna', 8, 152, 'max 8 hlö (Joonas); sama tapahtuma varaa myös Raunin (pooli event_32_rauni).'),
  ('event_32_rauni', 'Naisten jouluinen saunailta kb 32: Raunin paikat', 'rauni', 8, 153, 'max 8 hlö.'),
  ('event_33', 'Sipoonjoen Kekri kb 33: Raunin paikat', 'rauni', 8, 154, 'max 8 hlö; Rauni täynnä 240 min; Lovi kiinni (Lovi tarjotaan vain Raunin sulkuna).'),
  ('event_34', 'Saunottajien yhteisöpäivä kb 34: Raunin paikat', 'rauni', 8, 155, 'max 8 hlö.')
  ) v(code, name, parent, cap, so, notes)
  join booking.resources p on p.code = v.parent
on conflict (code) do nothing;

-- ---------- product_space_rules ----------
create table if not exists booking.product_space_rules (
  id bigint generated always as identity primary key,
  product_id bigint not null references kb.products(id),
  leg_no smallint not null default 1,          -- sama leg_no = vaihtoehtoiset tilat (priority), eri leg_no = kaikki vaaditaan
  priority smallint not null default 1,
  role text not null default 'space' check (role in ('space','group')),   -- group = sulkuryhmäleg (perinnesaunotus_ryhma)
  space_id bigint not null references booking.resources(id),
  mode text not null check (mode in ('shared','exclusive')),
  pool_id bigint references booking.resources(id),
  min_persons integer not null default 1 check (min_persons >= 1),
  max_persons integer check (max_persons is null or max_persons >= 1),
  selection text not null default 'auto' check (selection in ('auto','auto_if_blocked','manual')),
  requires_blocked_space_id bigint references booking.resources(id),     -- auto_if_blocked: tarjotaan vain kun tämä tila on suljettu (Lovi <- Rauni)
  offset_min integer not null default 0 check (offset_min >= 0),         -- leg-ikkuna suhteessa varauksen alkuun
  minutes integer check (minutes is null or minutes > 0),                -- null = koko ikkuna
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint psr_unique unique (product_id, leg_no, priority),
  constraint psr_persons_ok check (max_persons is null or max_persons >= min_persons),
  constraint psr_blocked_ok check (selection <> 'auto_if_blocked' or requires_blocked_space_id is not null),
  constraint psr_group_ok check (role <> 'group' or (pool_id is null and mode = 'shared'))
);
create index if not exists product_space_rules_space_idx on booking.product_space_rules (space_id);

insert into booking.product_space_rules
  (product_id, leg_no, priority, role, space_id, mode, pool_id, min_persons, max_persons, selection, requires_blocked_space_id, offset_min, minutes)
select v.kb, v.leg, v.prio, v.role, s.id, v.mode, p.id, v.mn, v.mx, v.sel, rq.id, v.off, v.mins
  from (values
  (1, 1, 1, 'space', 'savusauna', 'shared', null, 1, null, 'auto', null, 0, null),
  (2, 1, 1, 'space', 'savusauna', 'shared', null, 1, null, 'auto', null, 0, null),
  (3, 1, 1, 'space', 'savusauna', 'shared', null, 1, null, 'auto', null, 0, null),
  (4, 1, 1, 'space', 'savusauna', 'shared', null, 1, null, 'auto', null, 0, null),
  (5, 1, 1, 'space', 'savusauna', 'shared', null, 1, null, 'auto', null, 0, null),
  (6, 1, 1, 'space', 'savusauna', 'shared', null, 1, null, 'auto', null, 0, null),
  (7, 1, 1, 'space', 'savusauna', 'shared', null, 1, null, 'auto', null, 30, 90),
  (7, 2, 1, 'space', 'rauni', 'shared', 'rauni_rituaali', 1, 6, 'auto', null, 0, 20),
  (8, 1, 1, 'space', 'rauni', 'shared', 'rauni_rituaali', 1, 6, 'auto', null, 0, 20),
  (9, 1, 1, 'space', 'savusauna', 'shared', 'event_9', 1, 8, 'auto', null, 0, null),
  (10, 1, 1, 'space', 'rauni', 'exclusive', null, 1, 4, 'auto', null, 0, null),
  (10, 1, 2, 'space', 'lovi', 'exclusive', null, 1, 1, 'auto_if_blocked', 'rauni', 0, null),
  (16, 1, 1, 'space', 'rauni', 'exclusive', null, 1, 4, 'auto', null, 0, null),
  (16, 1, 2, 'space', 'lovi', 'exclusive', null, 1, 1, 'auto_if_blocked', 'rauni', 0, null),
  (17, 1, 1, 'space', 'rauni', 'exclusive', null, 1, 4, 'auto', null, 0, null),
  (17, 1, 2, 'space', 'lovi', 'exclusive', null, 1, 1, 'auto_if_blocked', 'rauni', 0, null),
  (18, 1, 1, 'space', 'rauni', 'exclusive', null, 1, 4, 'auto', null, 0, null),
  (18, 1, 2, 'space', 'lovi', 'exclusive', null, 1, 1, 'auto_if_blocked', 'rauni', 0, null),
  (19, 1, 1, 'space', 'rauni', 'exclusive', null, 1, 4, 'auto', null, 0, null),
  (19, 1, 2, 'space', 'lovi', 'exclusive', null, 1, 1, 'auto_if_blocked', 'rauni', 0, null),
  (20, 1, 1, 'space', 'rauni', 'exclusive', null, 1, 4, 'auto', null, 0, null),
  (20, 1, 2, 'space', 'lovi', 'exclusive', null, 1, 1, 'auto_if_blocked', 'rauni', 0, null),
  (21, 1, 1, 'space', 'rauni', 'exclusive', null, 1, 4, 'auto', null, 0, null),
  (21, 1, 2, 'space', 'lovi', 'exclusive', null, 1, 1, 'auto_if_blocked', 'rauni', 0, null),
  (22, 1, 1, 'space', 'rauni', 'exclusive', null, 1, 4, 'auto', null, 0, null),
  (22, 1, 2, 'space', 'lovi', 'exclusive', null, 1, 1, 'auto_if_blocked', 'rauni', 0, null),
  (24, 1, 1, 'space', 'rauni', 'exclusive', null, 1, 4, 'auto', null, 0, null),
  (24, 1, 2, 'space', 'lovi', 'exclusive', null, 1, 1, 'auto_if_blocked', 'rauni', 0, null),
  (11, 1, 1, 'space', 'rauni', 'exclusive', null, 1, 4, 'auto', null, 0, null),
  (11, 1, 2, 'space', 'lovi', 'exclusive', null, 1, 1, 'auto_if_blocked', 'rauni', 0, null),
  (12, 1, 1, 'space', 'rauni', 'exclusive', null, 1, 4, 'auto', null, 0, null),
  (12, 1, 2, 'space', 'lovi', 'exclusive', null, 1, 1, 'auto_if_blocked', 'rauni', 0, null),
  (14, 1, 1, 'space', 'rauni', 'exclusive', null, 1, 4, 'auto', null, 0, null),
  (14, 1, 2, 'space', 'lovi', 'exclusive', null, 1, 1, 'auto_if_blocked', 'rauni', 0, null),
  (15, 1, 1, 'space', 'rauni', 'exclusive', null, 1, 4, 'auto', null, 0, null),
  (15, 1, 2, 'space', 'lovi', 'exclusive', null, 1, 1, 'auto_if_blocked', 'rauni', 0, null),
  (23, 1, 1, 'space', 'rauni', 'exclusive', null, 1, 4, 'auto', null, 0, null),
  (23, 1, 2, 'space', 'lovi', 'exclusive', null, 1, 1, 'auto_if_blocked', 'rauni', 0, null),
  (11, 1, 3, 'space', 'savusauna', 'exclusive', null, 1, 6, 'manual', null, 0, null),
  (11, 2, 1, 'group', 'perinnesaunotus_ryhma', 'shared', null, 1, null, 'auto', null, 0, null),
  (12, 1, 3, 'space', 'savusauna', 'exclusive', null, 1, 6, 'manual', null, 0, null),
  (12, 2, 1, 'group', 'perinnesaunotus_ryhma', 'shared', null, 1, null, 'auto', null, 0, null),
  (14, 1, 3, 'space', 'savusauna', 'exclusive', null, 1, 6, 'manual', null, 0, null),
  (14, 2, 1, 'group', 'perinnesaunotus_ryhma', 'shared', null, 1, null, 'auto', null, 0, null),
  (15, 1, 3, 'space', 'savusauna', 'exclusive', null, 1, 6, 'manual', null, 0, null),
  (15, 2, 1, 'group', 'perinnesaunotus_ryhma', 'shared', null, 1, null, 'auto', null, 0, null),
  (23, 1, 3, 'space', 'savusauna', 'exclusive', null, 1, 6, 'manual', null, 0, null),
  (23, 2, 1, 'group', 'perinnesaunotus_ryhma', 'shared', null, 1, null, 'auto', null, 0, null),
  (13, 1, 1, 'space', 'rauni', 'exclusive', null, 3, 6, 'auto', null, 0, null),
  (25, 1, 1, 'space', 'savusauna', 'exclusive', null, 1, 18, 'auto', null, 0, null),
  (26, 1, 1, 'space', 'savusauna', 'exclusive', null, 1, 20, 'auto', null, 0, null),
  (48, 1, 1, 'space', 'savusauna', 'exclusive', null, 1, 20, 'auto', null, 0, null),
  (49, 1, 1, 'space', 'savusauna', 'exclusive', null, 1, 20, 'auto', null, 0, null),
  (27, 1, 1, 'space', 'ei_resurssia', 'shared', null, 1, 8, 'auto', null, 0, null),
  (28, 1, 1, 'space', 'ei_resurssia', 'shared', null, 1, 8, 'auto', null, 0, null),
  (29, 1, 1, 'space', 'savusauna', 'exclusive', null, 1, 15, 'auto', null, 0, null),
  (30, 1, 1, 'space', 'savusauna', 'exclusive', null, 1, 8, 'auto', null, 0, null),
  (31, 1, 1, 'space', 'savusauna', 'exclusive', null, 1, 8, 'auto', null, 0, null),
  (32, 1, 1, 'space', 'savusauna', 'shared', 'event_32', 1, 8, 'auto', null, 0, null),
  (32, 2, 1, 'space', 'rauni', 'shared', 'event_32_rauni', 1, 8, 'auto', null, 0, null),
  (33, 1, 1, 'space', 'rauni', 'shared', 'event_33', 1, 8, 'auto', null, 0, null),
  (34, 1, 1, 'space', 'rauni', 'shared', 'event_34', 1, 8, 'auto', null, 0, null)
  ) v(kb, leg, prio, role, space, mode, pool, mn, mx, sel, req, off, mins)
  join kb.products kp on kp.id = v.kb
  join booking.resources s on s.code = v.space
  left join booking.resources p on p.code = v.pool
  left join booking.resources rq on rq.code = v.req
on conflict (product_id, leg_no, priority) do nothing;

-- ---------- RLS, oikeudet, audit, updated_at ----------
alter table booking.product_space_rules enable row level security;
revoke all on booking.product_space_rules from public, anon, authenticated;
grant select on booking.product_space_rules to authenticated;
grant all on booking.product_space_rules to service_role;
drop policy if exists staff_read on booking.product_space_rules;
create policy staff_read on booking.product_space_rules for select to authenticated using ((select booking.is_staff()));
drop trigger if exists product_space_rules_updated on booking.product_space_rules;
create trigger product_space_rules_updated before update on booking.product_space_rules for each row execute function booking.set_updated_at();
drop trigger if exists audit_trg on booking.product_space_rules;
select booking._add_audit('booking.product_space_rules');
revoke all on sequence booking.product_space_rules_id_seq from public, anon, authenticated;
grant all on sequence booking.product_space_rules_id_seq to service_role;
