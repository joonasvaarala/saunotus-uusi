-- =====================================================================
-- booking 03: vuorosäännöt (data, ei kovakoodattua), kapasiteettipoolit, sulut
-- Säännöt ovat tauluissa: muutokset tehdään Koodarin kautta (migraatio/SQL), ei pakollinen hallintasivulta.
-- =====================================================================
set local search_path = booking, extensions, public;

-- Yksi rivi = yksi toistuva vuoromalli (viikonpäivät + alkamisaika + kesto) tuotteelle.
create table booking.schedule_rules (
  id               bigint generated always as identity primary key,
  product_id       bigint not null references kb.products(id),
  label            text not null,                       -- esim. "Yleinen vuoro la–su 14:00 (2 h)"
  mode             text not null check (mode in ('shared','exclusive')),
  -- shared    = yleinen vuoro: usea asiakas, kapasiteetti poolien kautta
  -- exclusive = yksityisvuoro: koko tila yhdelle varaajalle
  space_id         bigint not null references booking.resources(id),
  weekdays         smallint[] not null check (cardinality(weekdays) > 0 and weekdays <@ array[1,2,3,4,5,6,7]::smallint[]),  -- ISO: 1=ma … 7=su
  start_time       time not null,                        -- Helsingin paikallinen kellonaika
  duration_minutes integer not null check (duration_minutes > 0),
  valid_from       date,
  valid_to         date,
  min_persons      integer not null default 1 check (min_persons >= 1),
  max_persons      integer check (max_persons is null or max_persons >= 1),
  -- hinnoittelu: lukee hinnan aina kb:stä (kb.products / kb.product_price_variants)
  price_mode       text not null default 'per_person' check (price_mode in ('per_person','fixed','fixed_plus_extra')),
  price_variant_id bigint references kb.product_price_variants(id),
  included_persons integer check (included_persons is null or included_persons >= 0),  -- fixed_plus_extra: hintaan sisältyvät henkilöt
  extra_person_price numeric(10,2),                       -- tyhjä = otetaan kb:stä (variantti/tuote)
  deadline_minutes integer not null default 0 check (deadline_minutes >= 0),  -- myynti sulkeutuu näin monta min ennen alkua
  active           boolean not null default true,
  sort_order       integer not null default 100,
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint rules_valid_range check (valid_to is null or valid_from is null or valid_to >= valid_from)
);
create index schedule_rules_product_idx on booking.schedule_rules(product_id) where active;
create trigger schedule_rules_updated before update on booking.schedule_rules for each row execute function booking.set_updated_at();

-- Mitkä kapasiteettipoolit vuoro kuluttaa (esim. torstain turvesauna: yleinen_arki + turve)
create table booking.schedule_rule_pools (
  rule_id bigint not null references booking.schedule_rules(id) on delete cascade,
  pool_id bigint not null references booking.resources(id),
  primary key (rule_id, pool_id)
);

alter table booking.reservations
  add constraint reservations_rule_fk foreign key (rule_id) references booking.schedule_rules(id) on delete set null;

-- Sulku: tila ei myynnissä (huolto, omat menot). Estää kaikki varaukset ajalle.
create table booking.space_blocks (
  id         bigint generated always as identity primary key,
  space_id   bigint not null references booking.resources(id),
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  during     tstzrange generated always as (tstzrange(starts_at, ends_at, '[)')) stored,
  reason     text,
  active     boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint blocks_time_ok check (ends_at > starts_at)
);
create index space_blocks_idx on booking.space_blocks using gist (space_id, during) where active;

select booking._add_audit('booking.schedule_rules');
select booking._add_audit('booking.schedule_rule_pools');
select booking._add_audit('booking.space_blocks');
