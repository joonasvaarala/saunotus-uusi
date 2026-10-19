-- ============================================================
-- booking_104_product_qr_schema: QR-linkki on tuotekohtainen, ei kylmälaite.
-- Tuotannossa ei ole cold_units-rivejä eikä pikakassa-/kylmälaitetilauksia, joten
-- taulun vaihto tehdään booking_105:ssä (funktiot riippuvat cold_units-tyypistä).
-- Tässä syntyy booking.product_qr. fridge_sale-sarake säilyy: se on
-- "ostettavissa QR-linkillä" -tila, ei julkinen verkkokauppanäkyvyys.
-- Hinnat, ALV, site_base_url ja polut /juomat/ + /en/drinks/ eivät muutu.
-- Rollback: rollbacks/20261019020000_booking_104_ROLLBACK.sql (aja 105 ensin).
-- ============================================================
set local lock_timeout = '5s';

comment on column booking.product_config.fridge_sale is
  'Ostettavissa QR-linkillä. Ei lisää tuotetta verkkokaupan listoihin. Ikärajallinen tuote ei voi olla tässä tilassa.';

create table booking.product_qr (
  id          bigint generated always as identity primary key,
  code        text not null unique check (code ~ '^[a-f0-9]{32}$'),
  product_id  bigint not null references kb.products(id),
  label       text check (label is null or char_length(label) <= 120),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table booking.product_qr is
  'Tuotekohtainen QR-koodi. code on 32 heksaa (gen_random_uuid ilman viivoja) eikä sisällä tuotetunnusta. Osoite on /juomat/?laite=<code>.';
comment on column booking.product_qr.label is 'Valinnainen tarra, esim. pukuhuoneen jääkaappi. Ei ole osa ostosivun hintaa.';
create index product_qr_product_idx on booking.product_qr(product_id);
create trigger product_qr_updated before update on booking.product_qr
  for each row execute function booking.set_updated_at();

alter table booking.product_qr enable row level security;
revoke all on booking.product_qr from public, anon, authenticated;
grant all on booking.product_qr to service_role;
select booking._add_audit('booking.product_qr'::regclass);
