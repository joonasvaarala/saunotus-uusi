-- ============================================================
-- booking_80_pos_fridge_schema: pikakassa ja kylmälaitteiden QR-myynti (skeema).
--  * orders.source_channel: pikakassa, kylmalaite (raportit erottavat lähteen)
--  * orders.sale_ref: kylmälaitteen koodi (EI external_source – se on Johku-pari ja estää verkkomaksun)
--  * product_config: pos_enabled, pos_sort, fridge_sale, age_restricted
--  * cold_units: laitteet, palvelimen generoima koodi
--  * pos_tenders: maksutaparekisteri (ei käteistä; korttipääte mukana mutta pois päältä)
--  * oikeus pos.use: admin, manager, staff
-- Hinnat ja ALV pysyvät kb.products-taulussa. Tätä ei ajeta tästä repossa; Bottiavustus ajaa.
-- Rollback: rollbacks/20261019001000_booking_80_ROLLBACK.sql
-- ============================================================
set local lock_timeout = '5s';

-- ---------- lähde ja kohde ----------
alter table booking.orders drop constraint orders_source_channel_check;
alter table booking.orders add constraint orders_source_channel_check
  check (source_channel in ('web','admin','phone','email','walk_in','johku_import','other','pikakassa','kylmalaite'));

alter table booking.orders add column sale_ref text;
alter table booking.orders add constraint orders_sale_ref_len check (sale_ref is null or char_length(sale_ref) between 1 and 80);
comment on column booking.orders.sale_ref is 'Myynnin kohde, esim. kylmälaitteen koodi. Ei ole Johkun external_source/external_id -pari.';
create index orders_sale_ref_idx on booking.orders(source_channel, sale_ref) where sale_ref is not null;

-- ---------- tuote: pikakassa ja kylmälaite ----------
alter table booking.product_config
  add column pos_enabled boolean not null default false,
  add column pos_sort integer not null default 100,
  add column fridge_sale boolean not null default false,
  add column age_restricted boolean not null default false;
alter table booking.product_config add constraint product_config_pos_sort_check check (pos_sort between 0 and 10000);
alter table booking.product_config add constraint product_config_fridge_not_age check (not (fridge_sale and age_restricted));
comment on column booking.product_config.pos_enabled is 'Näytetään hallinnan pikakassassa. Hinta ja ALV luetaan kb.productsista.';
comment on column booking.product_config.fridge_sale is 'Myytävissä pukuhuoneen kylmälaitteessa (vain virvoitusjuoma, ei ikärajallinen).';
comment on column booking.product_config.age_restricted is 'Ikärajallinen tuote (alkoholi). Ei voi olla fridge_sale.';

-- Sanaraja: alkoholiton ja viinirypäle eivät osu. gin keskellä sanaa (ginger) ei osu.
create function booking._text_looks_like_alcohol(p_text text)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(p_text, '') ~* '(^|[^[:alpha:]])(olut|oluet|viini|viinit|siideri|lonkero|alkoholi|viina|beer|beers|wine|wines|cider|ciders|whiskey|whisky|vodka|gin|rum|champagne|prosecco|spirits)([^[:alpha:]]|$)'
$$;

create function booking._assert_fridge_product(p_product_id bigint)
returns void language plpgsql stable security definer set search_path = '' as $$
declare p record;
begin
  select name, name_en, description, description_en, category into p from kb.products where id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotetta ei löydy'); end if;
  if p.category in ('gift_card', 'season_card') then
    perform booking._err('not_counter_product', 'Lahjakorttia tai kausikorttia ei myydä kylmälaitteessa');
  end if;
  if booking._text_looks_like_alcohol(p.name) or booking._text_looks_like_alcohol(p.name_en)
     or booking._text_looks_like_alcohol(p.description) or booking._text_looks_like_alcohol(p.description_en) then
    perform booking._err('age_restricted', 'Alkoholipitoista tuotetta ei voi myydä kylmälaitteessa');
  end if;
end $$;

create function booking._product_config_fridge_trg()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.fridge_sale and new.age_restricted then
    perform booking._err('age_restricted', 'Ikärajallista tuotetta ei voi myydä kylmälaitteessa');
  end if;
  if new.fridge_sale then
    perform booking._assert_fridge_product(new.product_id);
  end if;
  return new;
end $$;
create trigger product_config_fridge before insert or update of fridge_sale, age_restricted on booking.product_config
  for each row execute function booking._product_config_fridge_trg();

-- Lukitut polut. Eivät ole asetuksia, jotta osoitetta ei voi vaihtaa tekstinä.
create function booking._drinks_path(p_locale text)
returns text language sql immutable set search_path = '' as $$
  select case when p_locale = 'en' then '/en/drinks/' else '/juomat/' end
$$;
comment on function booking._drinks_path(text) is 'Kylmälaite-sivun lukittu polku: /juomat/ ja /en/drinks/.';

-- ---------- kylmälaitteet ----------
create table booking.cold_units (
  id          bigint generated always as identity primary key,
  code        text not null unique check (code ~ '^[a-z0-9-]{8,48}$'),
  name        text not null check (char_length(btrim(name)) between 1 and 80),
  location    text check (location is null or char_length(location) <= 120),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table booking.cold_units is 'Pukuhuoneen kylmälaitteet. code on arvauksen kestävä ja menee QR-osoitteeseen (?laite=).';
create trigger cold_units_updated before update on booking.cold_units for each row execute function booking.set_updated_at();

-- ---------- maksutaparekisteri (laajennuskohta; käteistä ei ole) ----------
create table booking.pos_tenders (
  code                text primary key check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  handler             text not null check (handler ~ '^[a-z][a-z0-9_]{1,40}$'),
  channels            text[] not null,
  active              boolean not null default false,
  sort_order          integer not null default 100,
  unavailable_reason  text,
  created_at          timestamptz not null default now(),
  constraint pos_tenders_channels_check check (channels <@ array['pos','drinks']::text[] and cardinality(channels) >= 1)
);
comment on table booking.pos_tenders is
  'Kassan ja kylmälaite-sivun maksutavat. Korttipääte (handler terminal) on rivinä mutta active=false, kunnes pääteintegraatio tehdään. Käteistä ei lisätä.';

insert into booking.pos_tenders(code, handler, channels, active, sort_order, unavailable_reason) values
  ('payment_link',  'payment_link', array['pos'],              true,  10, null),
  ('mobilepay',     'mobilepay',    array['pos','drinks'],     true,  20, null),
  ('visma_pay',     'visma_pay',    array['drinks'],           true,  30, null),
  ('card_terminal', 'terminal',     array['pos'],              false, 40, 'not_implemented');

-- ---------- oikeus ----------
insert into booking.role_permissions(role_code, permission) values
  ('admin', 'pos.use'), ('manager', 'pos.use'), ('staff', 'pos.use')
on conflict do nothing;

-- ---------- RLS: ei anon- eikä authenticated-tauluoikeutta ----------
alter table booking.cold_units enable row level security;
alter table booking.pos_tenders enable row level security;
revoke all on booking.cold_units, booking.pos_tenders from public, anon, authenticated;
grant all on booking.cold_units, booking.pos_tenders to service_role;
select booking._add_audit('booking.cold_units'::regclass);
select booking._add_audit('booking.pos_tenders'::regclass);

revoke all on function booking._text_looks_like_alcohol(text) from public, anon, authenticated;
revoke all on function booking._assert_fridge_product(bigint) from public, anon, authenticated;
revoke all on function booking._product_config_fridge_trg() from public, anon, authenticated;
revoke all on function booking._drinks_path(text) from public, anon, authenticated;
grant execute on function booking._text_looks_like_alcohol(text) to service_role;
grant execute on function booking._assert_fridge_product(bigint) to service_role;
grant execute on function booking._drinks_path(text) to service_role;
