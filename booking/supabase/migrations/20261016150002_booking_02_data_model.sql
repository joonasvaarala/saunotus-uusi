-- =====================================================================
-- booking 02: asiakkaat, tilaukset, rivit, varaukset, maksut, alennukset/lahjakortit, markkinointi
-- Kentät on mitoitettu yhteensopiviksi Johku-tuonnin kanssa (external_source/external_id, johku_order_no,
-- rivikohtainen ALV, lähdekanava, maksutavat). Katso booking/docs/johku-tuonti.md
-- =====================================================================
set local search_path = booking, extensions, public;

-- ---------- asiakkaat ----------
create table booking.customers (
  id            bigint generated always as identity primary key,
  name          text not null,
  email         text,
  phone         text,
  company       text,
  address       text,
  zip           text,
  city          text,
  country       text not null default 'FI',
  language      text not null default 'fi' check (language in ('fi','en','sv')),
  notes         text,                         -- sisäinen muistiinpano (Johku: description)
  -- markkinointisuostumus (GDPR): milloin, mistä ja minkä tekstiversion perusteella
  marketing_consent              boolean not null default false,
  marketing_consent_at           timestamptz,
  marketing_consent_source       text,        -- web_booking / admin / johku_import / newsletter_form ...
  marketing_consent_text_version text,
  marketing_unsubscribed_at      timestamptz,
  unsubscribe_token uuid not null default gen_random_uuid(),
  -- ulkoiset tunnisteet (Johku-tuonti)
  external_source text,
  external_id     text,
  anonymized_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint customers_consent_has_time check (not marketing_consent or marketing_consent_at is not null),
  constraint customers_name_len check (char_length(name) between 1 and 200),
  constraint customers_ext_pair check ((external_source is null) = (external_id is null))
);
create unique index customers_external_uq on booking.customers(external_source, external_id) where external_source is not null;
create index customers_email_idx on booking.customers(lower(email));
create index customers_name_idx on booking.customers(lower(name));
create index customers_phone_idx on booking.customers(phone);
create unique index customers_unsub_token_uq on booking.customers(unsubscribe_token);
create trigger customers_updated before update on booking.customers for each row execute function booking.set_updated_at();

-- suostumushistoria (todiste siitä, milloin ja mihin suostuttu / peruttu)
create table booking.marketing_consent_events (
  id           bigint generated always as identity primary key,
  customer_id  bigint not null references booking.customers(id) on delete cascade,
  granted      boolean not null,
  at           timestamptz not null default now(),
  source       text,
  text_version text
);
create index consent_events_customer_idx on booking.marketing_consent_events(customer_id, at desc);

create or replace function booking.customers_consent_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' and new.marketing_consent then
    insert into booking.marketing_consent_events(customer_id, granted, at, source, text_version)
    values (new.id, true, new.marketing_consent_at, new.marketing_consent_source, new.marketing_consent_text_version);
  elsif tg_op = 'UPDATE' and new.marketing_consent is distinct from old.marketing_consent then
    insert into booking.marketing_consent_events(customer_id, granted, at, source, text_version)
    values (new.id, new.marketing_consent, coalesce(new.marketing_consent_at, now()),
            new.marketing_consent_source, new.marketing_consent_text_version);
  end if;
  return null;
end $$;
create trigger customers_consent after insert or update on booking.customers for each row execute function booking.customers_consent_trg();

-- ---------- maksutavat (hallittava luettelo) ----------
create table booking.payment_methods (
  code        text primary key,
  label       text not null,
  is_manual   boolean not null default true,   -- käsin kirjattava (ei maksuvälittäjä)
  active      boolean not null default true,   -- valittavissa uuteen kirjaukseen
  johku_codes text[] not null default '{}',    -- vastaavat Johku orders.payment -arvot (tuonti)
  sort_order  integer not null default 100
);

-- ---------- alennuskoodit ja lahjakortit (rakenne valmiina, toteutus myöhemmin) ----------
create table booking.discount_codes (
  id          bigint generated always as identity primary key,
  code        text not null unique,
  description text,
  kind        text not null check (kind in ('percent','fixed')),
  value       numeric(10,2) not null check (value >= 0),
  valid_from  date,
  valid_to    date,
  max_uses    integer,
  used_count  integer not null default 0,
  product_ids bigint[],                     -- null = kaikki tuotteet
  active      boolean not null default true,
  external_source text, external_id text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index discount_external_uq on booking.discount_codes(external_source, external_id) where external_source is not null;
create trigger discount_updated before update on booking.discount_codes for each row execute function booking.set_updated_at();

create table booking.gift_cards (
  id            bigint generated always as identity primary key,
  code          text not null unique,
  issuer        text not null default 'own' check (issuer in ('own','elamyslahjat','kokemuskauppa','offerilla','johku','other')),
  kind          text not null default 'value' check (kind in ('value','product')),
  product_id    bigint references kb.products(id),  -- tuotekohtainen kortti (esim. Arkivuoro kahdelle)
  initial_amount numeric(10,2) not null check (initial_amount >= 0),
  balance       numeric(10,2) not null check (balance >= 0),
  currency      text not null default 'EUR',
  valid_to      date,
  status        text not null default 'active' check (status in ('active','used','expired','cancelled','pending_verification')),
  purchase_order_id bigint,                 -- FK lisätään orders-taulun jälkeen
  note          text,
  external_source text, external_id text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index gift_cards_external_uq on booking.gift_cards(external_source, external_id) where external_source is not null;
create trigger gift_cards_updated before update on booking.gift_cards for each row execute function booking.set_updated_at();

-- ---------- tilaukset ----------
create table booking.orders (
  id             bigint generated always as identity primary key,
  order_no       bigint generated by default as identity (start with 10001) unique,  -- asiakkaalle näkyvä tilausnumero
  public_token   uuid not null default gen_random_uuid() unique,                      -- vahvistussivun salainen linkki
  customer_id    bigint references booking.customers(id),
  status         text not null default 'pending'
                 check (status in ('draft','pending','confirmed','cancelled','expired','completed')),
  payment_status text not null default 'unpaid'
                 check (payment_status in ('unpaid','pending','paid','partially_paid','refunded','partially_refunded','failed')),
  total_gross    numeric(10,2) not null default 0 check (total_gross >= 0),
  currency       text not null default 'EUR',
  source_channel text not null default 'web'
                 check (source_channel in ('web','admin','phone','email','walk_in','johku_import','other')),
  locale         text not null default 'fi' check (locale in ('fi','en','sv')),
  customer_note  text,
  internal_note  text,
  discount_code_id bigint references booking.discount_codes(id),
  created_by     uuid,                       -- staff user_id (käsivaraus); null = asiakas itse
  confirmed_at   timestamptz,
  cancelled_at   timestamptz,
  external_source text,
  external_id     text,
  johku_order_no  bigint,                    -- Johku orders.id / tilausnumero
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint orders_ext_pair check ((external_source is null) = (external_id is null))
);
create unique index orders_external_uq on booking.orders(external_source, external_id) where external_source is not null;
create index orders_customer_idx on booking.orders(customer_id);
create index orders_created_idx on booking.orders(created_at desc);
create index orders_johku_idx on booking.orders(johku_order_no) where johku_order_no is not null;
create trigger orders_updated before update on booking.orders for each row execute function booking.set_updated_at();
alter table booking.gift_cards add constraint gift_cards_order_fk foreign key (purchase_order_id) references booking.orders(id);

-- ---------- tilausrivit (rivikohtainen ALV: 24 / 25,5 / 14 / 13,5 / 10 / 0 %) ----------
create table booking.order_items (
  id               bigint generated always as identity primary key,
  order_id         bigint not null references booking.orders(id) on delete cascade,
  product_id       bigint references kb.products(id),     -- null = tuote jota ei ole kb:ssä (esim. Johku-tuonti)
  product_name     text not null,                          -- nimi tilaushetkellä
  kind             text not null default 'reservation' check (kind in ('reservation','product','gift_card','fee','discount')),
  quantity         integer not null default 1 check (quantity >= 0),
  unit_price_gross numeric(10,2) not null,
  discount_amount  numeric(10,2) not null default 0,
  line_total_gross numeric(10,2) not null,
  vat_rate         numeric(5,2) not null check (vat_rate >= 0 and vat_rate <= 100),
  line_vat         numeric(10,2) generated always as (round(line_total_gross * vat_rate / (100 + vat_rate), 2)) stored,
  line_net         numeric(10,2) generated always as (line_total_gross - round(line_total_gross * vat_rate / (100 + vat_rate), 2)) stored,
  price_breakdown  jsonb,                                  -- miten hinta muodostui (tila, kpl, lisähenkilöt)
  discount_code_id bigint references booking.discount_codes(id),
  gift_card_id     bigint references booking.gift_cards(id),
  external_source  text,
  external_id      text,
  external_product_id text,                                -- Johku products.id jos tuotetta ei löydy kb:stä
  created_at       timestamptz not null default now()
);
create index order_items_order_idx on booking.order_items(order_id);
create index order_items_product_idx on booking.order_items(product_id);
create unique index order_items_external_uq on booking.order_items(external_source, external_id) where external_source is not null;

-- ---------- varaukset ----------
-- mode: shared = yleinen vuoro (kapasiteetti), exclusive = yksityisvuoro (vie koko tilan)
-- Invarianttien valvonta: trigger booking.reservations_validate (migraatio 04) + exclusion constraint.
create table booking.reservations (
  id             bigint generated always as identity primary key,
  order_id       bigint not null references booking.orders(id) on delete cascade,
  order_item_id  bigint references booking.order_items(id) on delete set null,
  product_id     bigint references kb.products(id),
  rule_id        bigint,                                   -- FK schedule_rules (migraatio 03)
  space_id       bigint not null references booking.resources(id),
  mode           text not null check (mode in ('shared','exclusive')),
  starts_at      timestamptz not null,
  ends_at        timestamptz not null,
  during         tstzrange generated always as (tstzrange(starts_at, ends_at, '[)')) stored,
  persons        integer not null check (persons >= 1),
  participant_breakdown jsonb,                             -- esim. {"adults":3,"children":1} / Johku pricetiers "6:3"
  pool_ids       bigint[] not null default '{}',           -- kapasiteettipoolit, jotka tämä varaus kuluttaa (kopio säännöstä)
  status         text not null default 'pending'
                 check (status in ('pending','confirmed','cancelled','expired','completed','no_show')),
  hold_expires_at timestamptz,                             -- pending-varauksen pito; vanhenee → vapautuu
  checkin_at     timestamptz,
  checkout_at    timestamptz,
  cancelled_at   timestamptz,
  cancel_reason  text,
  notes          text,
  external_source text,
  external_id     text,                                    -- Johku reservations.id
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint reservations_time_ok check (ends_at > starts_at),
  constraint reservations_hold_for_pending check (status <> 'pending' or hold_expires_at is not null),
  constraint reservations_ext_pair check ((external_source is null) = (external_id is null)),
  -- Kaksi yksityisvuoroa ei voi olla päällekkäin samassa tilassa (kova takaraja; trigger tekee loput säännöt)
  constraint reservations_no_exclusive_overlap
    exclude using gist (space_id with =, during with &&)
    where (mode = 'exclusive' and status in ('pending','confirmed'))
);
create unique index reservations_external_uq on booking.reservations(external_source, external_id) where external_source is not null;
create index reservations_space_time_idx on booking.reservations using gist (space_id, during) where status in ('pending','confirmed');
create index reservations_starts_idx on booking.reservations(starts_at);
create index reservations_order_idx on booking.reservations(order_id);
create index reservations_status_idx on booking.reservations(status, hold_expires_at);
create trigger reservations_updated before update on booking.reservations for each row execute function booking.set_updated_at();

-- ---------- maksut (Visma Pay lisätään myöhemmin tähän: provider='visma_pay') ----------
create table booking.payments (
  id              bigint generated always as identity primary key,
  order_id        bigint not null references booking.orders(id) on delete cascade,
  method          text not null references booking.payment_methods(code),
  provider        text not null default 'manual',          -- manual / visma_pay / johku / ...
  provider_ref    text,                                    -- maksuvälittäjän tunniste (Visma Pay: token / order_number)
  provider_status text,                                    -- välittäjän raakatila
  status          text not null default 'pending'
                  check (status in ('pending','paid','failed','cancelled','refunded','partially_refunded')),
  amount          numeric(10,2) not null check (amount >= 0),
  refunded_amount numeric(10,2) not null default 0 check (refunded_amount >= 0),
  currency        text not null default 'EUR',
  paid_at         timestamptz,
  link_url        text,                                    -- maksulinkki (Visma Pay -toteutus täyttää)
  link_token      uuid default gen_random_uuid(),
  link_expires_at timestamptz,
  raw             jsonb,                                   -- välittäjän vastaus (ei korttitietoja)
  gift_card_id    bigint references booking.gift_cards(id),
  note            text,
  created_by      uuid,
  external_source text,
  external_id     text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint payments_refund_le_amount check (refunded_amount <= amount)
);
create unique index payments_provider_ref_uq on booking.payments(provider, provider_ref) where provider_ref is not null;
create unique index payments_external_uq on booking.payments(external_source, external_id) where external_source is not null;
create index payments_order_idx on booking.payments(order_id);
create trigger payments_updated before update on booking.payments for each row execute function booking.set_updated_at();

create table booking.gift_card_ledger (
  id           bigint generated always as identity primary key,
  gift_card_id bigint not null references booking.gift_cards(id),
  order_id     bigint references booking.orders(id),
  payment_id   bigint references booking.payments(id),
  delta        numeric(10,2) not null,
  balance_after numeric(10,2) not null check (balance_after >= 0),
  reason       text not null,
  at           timestamptz not null default now(),
  created_by   uuid
);
create index gift_card_ledger_card_idx on booking.gift_card_ledger(gift_card_id, at);

-- ---------- uutiskirjeet / markkinointi (vain rakenne; toteutus myöhemmin) ----------
create table booking.marketing_segments (
  id          bigint generated always as identity primary key,
  name        text not null,
  description text,
  kind        text not null default 'dynamic' check (kind in ('dynamic','static')),
  filter      jsonb not null default '{}'::jsonb,   -- esim. {"consent":true,"visited_after":"2026-01-01","product_ids":[1]}
  created_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create table booking.marketing_segment_members (
  segment_id  bigint not null references booking.marketing_segments(id) on delete cascade,
  customer_id bigint not null references booking.customers(id) on delete cascade,
  primary key (segment_id, customer_id)
);
create table booking.campaigns (
  id          bigint generated always as identity primary key,
  name        text not null,
  kind        text not null check (kind in ('manual','targeted','automatic')),
  status      text not null default 'draft' check (status in ('draft','scheduled','sending','sent','cancelled')),
  segment_id  bigint references booking.marketing_segments(id),
  subject     text,
  body_html   text,
  body_text   text,
  trigger_rule jsonb,                                -- automaattiset: esim. {"event":"visit","after_days":2}
  scheduled_at timestamptz,
  sent_at     timestamptz,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create table booking.campaign_sends (
  id          bigint generated always as identity primary key,
  campaign_id bigint not null references booking.campaigns(id) on delete cascade,
  customer_id bigint not null references booking.customers(id) on delete cascade,
  email       text not null,                          -- osoite lähetyshetkellä
  status      text not null default 'queued' check (status in ('queued','sent','failed','bounced','unsubscribed','skipped_no_consent')),
  provider_ref text,
  error       text,
  queued_at   timestamptz not null default now(),
  sent_at     timestamptz,
  unique (campaign_id, customer_id)
);
create index campaign_sends_status_idx on booking.campaign_sends(status);

-- ---------- rate limit -tapahtumat (julkisen varauksen väärinkäytön esto) ----------
create table booking.rate_limit_hits (
  id     bigint generated always as identity primary key,
  bucket text not null,
  at     timestamptz not null default now()
);
create index rate_limit_bucket_idx on booking.rate_limit_hits(bucket, at desc);

-- ---------- audit-triggerit ----------
do $$ begin
  perform booking._add_audit('booking.customers');
  perform booking._add_audit('booking.orders');
  perform booking._add_audit('booking.order_items');
  perform booking._add_audit('booking.reservations');
  perform booking._add_audit('booking.payments');
  perform booking._add_audit('booking.payment_methods');
  perform booking._add_audit('booking.discount_codes');
  perform booking._add_audit('booking.gift_cards');
  perform booking._add_audit('booking.gift_card_ledger');
  perform booking._add_audit('booking.marketing_segments');
  perform booking._add_audit('booking.campaigns');
end $$;

-- ---------- maksutapojen oletusluettelo ----------
insert into booking.payment_methods(code, label, is_manual, active, johku_codes, sort_order) values
  ('pay_later',     'Maksetaan paikan päällä / myöhemmin (testi)', true,  true,  '{open}', 10),
  ('cash',          'Käteinen',                   true,  true,  '{cash,admincash}', 20),
  ('card_terminal', 'Korttipääte',                true,  true,  '{admincard,creditcard}', 30),
  ('mobilepay',     'MobilePay',                  true,  true,  '{mobilepay}', 40),
  ('bank_transfer', 'Tilisiirto',                 true,  true,  '{}', 50),
  ('invoice',       'Lasku (yritykset)',          true,  true,  '{bill}', 60),
  ('gift_card',     'Lahjakortti (oma)',          true,  true,  '{}', 70),
  ('partner_voucher','Kumppanin lahjakortti (Elämyslahjat/Kokemuskauppa/Offerilla)', true, true, '{voucher}', 80),
  ('visma_pay',     'Visma Pay (verkkomaksu)',    false, false, '{paybywaychannel,multi}', 90),
  ('other',         'Muu',                        true,  true,  '{paypal,stripe,viva}', 100);
