-- booking_43_giftcards_schema (17.10.2026) – lahjakortit vaihe 1 (a): skeema
-- Päätökset (Joonas): oma lahjakorttisysteemi, yhteensopiva Johkun korttien kanssa (nykyiset 12-merkkiset koodit toimivat sellaisinaan; voimassaoloa voi muuttaa hallinnasta).
-- Uudet koodit HHxx-xxxx-xxxx (12 merkkiä, aina HH + Johkun merkistö 3479ACEFHJKLMNPRTUVWXY); tallennus normalisoituna (isot kirjaimet, ilman viivoja) -> UNIQUE(code).
-- Muutokset:
--   1) gift_card_packages (4 pakettia + avoin kortti), gift_card_blocked_codes (Johku-koodien HH-törmäysesto, vain SHA-256), gift_card_check_log (rate limit, ei koodeja)
--   2) gift_cards: uudet kentät (source, package_code, valid_from, buyer_*, recipient_*, greeting <= 300, vat_treatment, accounting_origin, public_token, balance_verified, ...), status + 'pending_payment', koodin muototarkistus + normalisointitrigger
--   3) gift_card_ledger: note/meta/old_valid_to/new_valid_to, reason-tarkistus, append-only-suojaus
--   4) payment_methods.gift_card: ei enää käsin kirjattava (is_manual=false) -> lunastus vain admin_redeem_gift_card / public_apply_gift_card; trigger: method='gift_card' <=> gift_card_id; lahjakortilla ei voi ostaa lahjakorttia
--   5) settings: gift_cards.redeem_enabled=false, gift_cards.johku_cards_redeemable=false, gift_cards.sale_enabled=false ym.; oikeudet giftcards.manage / giftcards.admin
-- Rollback: booking_43_ROLLBACK.sql

-- ---------- apufunktiot ----------
create or replace function booking.gift_code_norm(p text) returns text language sql immutable set search_path to ''
as $$ select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) $$;
create or replace function booking.gift_code_fmt(p text) returns text language sql immutable set search_path to ''
as $$ select case when char_length(p) = 12 then substr(p, 1, 4) || '-' || substr(p, 5, 4) || '-' || substr(p, 9, 4) else p end $$;
comment on function booking.gift_code_norm(text) is 'lahjakortin koodin normalisointi: isot kirjaimet, vain A-Z0-9 (viivat/välilyönnit pois)';

-- ---------- paketit ----------
create table booking.gift_card_packages (
  code          text primary key check (code ~ '^[a-z0-9_]{2,40}$'),
  name          text not null,
  name_en       text,
  description   text,
  description_en text,
  kind          text not null check (kind in ('value', 'product')),
  is_open       boolean not null default false,
  price         numeric(10,2) check (price is null or price > 0),
  min_amount    numeric(10,2),
  max_amount    numeric(10,2),
  persons       integer check (persons is null or persons > 0),
  vat_rate      numeric(5,2) not null references booking.vat_rates(rate),       -- ALV-kanta kun kortti myydään 'at_sale'-käsittelyllä
  vat_treatment text not null check (vat_treatment in ('at_sale', 'at_redemption')),
  kb_product_id bigint references kb.products(id),
  items         jsonb not null default '[]'::jsonb,                             -- koostumus (tiedoksi; arvoperusteinen kortti)
  valid_months  integer not null default 6 check (valid_months between 1 and 36),
  active        boolean not null default true,
  sort_order    integer not null default 100,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint gift_card_packages_shape check ((is_open and price is null and min_amount is not null and max_amount >= min_amount and kind = 'value')
                                          or (not is_open and price is not null and min_amount is null and max_amount is null and kind = 'product'))
);
create trigger gift_card_packages_updated before update on booking.gift_card_packages for each row execute function booking.set_updated_at();

insert into booking.gift_card_packages(code, name, name_en, description, description_en, kind, is_open, price, min_amount, max_amount, persons, vat_rate, vat_treatment, kb_product_id, items, valid_months, sort_order) values
 ('open', 'Avoin lahjakortti', 'Open gift card', 'Vapaa summa; käy kaikkiin palveluihin. Voimassa 6 kuukautta.', 'Any amount; valid for all services. Valid for 6 months.',
   'value', true, null, 29, 500, null, 25.5, 'at_redemption', 38, '[]'::jsonb, 6, 10),
 ('entry_2', 'Sisäänpääsy kahdelle', 'Admission for two', 'Savusaunavuoro kahdelle hengelle (2 × 29 €).', 'Smoke sauna session for two (2 × €29).',
   'product', false, 58, null, null, 2, 25.5, 'at_sale', null, '[{"kb_product_id":1,"persons":2,"label":"Yleinen vuoro"}]'::jsonb, 6, 20),
 ('peat_mask_2', 'Savusaunaelämys turvenaamiolla ja jalkakylvyllä kahdelle', 'Smoke sauna experience with peat mask and foot bath for two', 'Sisäänpääsy kahdelle + omatoiminen turvenaamio ja jalkakylpy (2 × 15 €).', 'Admission for two + self-guided peat mask and foot bath.',
   'product', false, 88, null, null, 2, 25.5, 'at_sale', 42, '[{"kb_product_id":1,"persons":2,"label":"Yleinen vuoro"},{"addon_code":"turvenaamio_jalkakylpy","persons":2}]'::jsonb, 6, 30),
 ('sauna_treatment_2', 'Savusaunaelämys ja saunahoito kahdelle', 'Smoke sauna experience and sauna treatment for two', 'Sisäänpääsy kahdelle + saunahoito kahdelle (60 min).', 'Admission for two + sauna treatment for two (60 min).',
   'product', false, 192, null, null, 2, 25.5, 'at_sale', 41, '[{"kb_product_id":1,"persons":2,"label":"Yleinen vuoro"},{"kb_product_id":10,"persons":2,"label":"Saunahoito"}]'::jsonb, 6, 40),
 ('saunotus_2', 'Savusaunaelämys ja saunotus kahdelle', 'Smoke sauna experience and ritual sauna bathing for two', 'Sisäänpääsy kahdelle + saunotus kahdelle (2 h).', 'Admission for two + ritual sauna bathing for two (2 h).',
   'product', false, 328, null, null, 2, 25.5, 'at_sale', null, '[{"kb_product_id":1,"persons":2,"label":"Yleinen vuoro"},{"kb_product_id":11,"persons":2,"label":"Saunotus"}]'::jsonb, 6, 50);

-- ---------- Johku-koodien törmäysesto (vain hajautteet) ----------
create table booking.gift_card_blocked_codes (
  code_sha256 text primary key check (code_sha256 ~ '^[0-9a-f]{64}$'),
  reason      text not null,
  created_at  timestamptz not null default now()
);
-- Johkun kaikki 9 koodia joiden alku on HH (2 475 koodista; 4 tuodaan, 5 ei tuoda). Hajautteet sha256(normalisoitu koodi), koodeja ei tallenneta.
insert into booking.gift_card_blocked_codes(code_sha256, reason)
select h, 'johku_existing_hh_prefix' from unnest(array[
  '05084927bb9dbece4df8a88b5370c3b185c6e02633e20acaa562031abad5b535',
  '7d277dfedd454affa84263d234ef43799a51c2a4de626c6a08af5c177b83fdf4',
  '05ac84f57ad74e546ac5b7ac0ad59583eec8948696388416c9f844387e0bd7e8',
  '76c68044d12b2c93cbc3e3d95b5a780b7e0d7bdc3d186425866ee70f9bcbf1be',
  '283b9cf5a51e60dfb2260522c230a9a5074700a26d0be875f77943fe77d95b23',
  '9d515e634adff59d988ff8a123589000e093eb662a203d0e6c426af2d66ed9e0',
  'a99e3a1f800ccd443c6082e0f1e9020c6eb64aebfb2f53dbe8789c5a03e62c15',
  'd9fd3e1381befa80a3b9a4dcc6a87ad937a132f35e0cb23a256762a0fab38292',
  '20bd57bb70c7dcfe9cb071c179a4458603139994b31e7b3a7267d9707f956833'
]) h;

-- ---------- julkisen tarkistuksen rate limit -loki (ei koodeja) ----------
create table booking.gift_card_check_log (
  id      bigint generated always as identity primary key,
  at      timestamptz not null default now(),
  ip_key  text not null,
  outcome text not null check (outcome in ('invalid', 'ok', 'blocked'))
);
create index gift_card_check_log_idx on booking.gift_card_check_log (ip_key, outcome, at);

-- ---------- gift_cards ----------
alter table booking.gift_cards
  add column source              text    not null default 'native' check (source in ('johku', 'native')),
  add column package_code        text    references booking.gift_card_packages(code),
  add column valid_from          date,
  add column valid_months        integer not null default 6 check (valid_months between 1 and 36),
  add column buyer_customer_id   bigint  references booking.customers(id),
  add column buyer_name          text,
  add column buyer_email         text,
  add column recipient_name      text    check (recipient_name is null or char_length(recipient_name) <= 120),
  add column recipient_email     text    check (recipient_email is null or char_length(recipient_email) <= 200),
  add column greeting            text    check (greeting is null or char_length(greeting) <= 300),
  add column locale              text    not null default 'fi' check (locale in ('fi', 'en', 'sv')),
  add column vat_treatment       text    not null default 'at_redemption' check (vat_treatment in ('at_sale', 'at_redemption')),
  add column sale_vat_rate       numeric(5,2),
  add column accounting_origin   text    not null default 'native' check (accounting_origin in ('native', 'johku')),
  add column public_token        uuid    not null default gen_random_uuid(),
  add column purchase_order_item_id bigint references booking.order_items(id),
  add column balance_verified    boolean not null default true,
  add column balance_verified_at timestamptz,
  add column balance_source      text,
  add column single_order        boolean not null default false,
  add column activated_at        timestamptz,
  add column last_used_at        timestamptz,
  add column pdf_path            text,
  add column external_meta       jsonb,
  add column created_by          uuid;
create unique index gift_cards_public_token_uq on booking.gift_cards (public_token);
create index gift_cards_purchase_order_idx on booking.gift_cards (purchase_order_id) where purchase_order_id is not null;
create index gift_cards_status_valid_idx on booking.gift_cards (status, valid_to);
create index gift_cards_source_idx on booking.gift_cards (source);
create index gift_cards_buyer_idx on booking.gift_cards (buyer_customer_id) where buyer_customer_id is not null;
create index gift_cards_order_item_idx on booking.gift_cards (purchase_order_item_id) where purchase_order_item_id is not null;
create index gift_cards_package_idx on booking.gift_cards (package_code) where package_code is not null;

alter table booking.gift_cards drop constraint gift_cards_status_check;
alter table booking.gift_cards add constraint gift_cards_status_check
  check (status in ('active', 'used', 'expired', 'cancelled', 'pending_verification', 'pending_payment'));
alter table booking.gift_cards add constraint gift_cards_code_format check (code ~ '^[A-Z0-9]{12}$');
alter table booking.gift_cards add constraint gift_cards_origin_check check (source <> 'johku' or (accounting_origin = 'johku' and issuer = 'johku'));
alter table booking.gift_cards add constraint gift_cards_native_hh check (source <> 'native' or code like 'HH%');

create or replace function booking.gift_cards_norm_trg() returns trigger language plpgsql security definer set search_path to ''
as $$ begin new.code := booking.gift_code_norm(new.code); return new; end $$;
create trigger gift_cards_norm before insert or update of code on booking.gift_cards for each row execute function booking.gift_cards_norm_trg();

-- ---------- ledger ----------
alter table booking.gift_card_ledger
  add column note          text,
  add column meta          jsonb,
  add column old_valid_to  date,
  add column new_valid_to  date;
alter table booking.gift_card_ledger add constraint gift_card_ledger_reason_check
  check (reason in ('purchase', 'manual_issue', 'opening_balance', 'redemption', 'refund', 'adjust', 'expiry_change', 'cancel', 'reactivate',
                    'cancel_refund', 'single_order_forfeit', 'johku_purchase', 'johku_usage', 'johku_adjust', 'johku_sync'));
create index gift_card_ledger_order_idx on booking.gift_card_ledger (order_id) where order_id is not null;
create index gift_card_ledger_payment_idx on booking.gift_card_ledger (payment_id) where payment_id is not null;

create or replace function booking.gift_card_ledger_append_only_trg() returns trigger language plpgsql set search_path to ''
as $$ begin
  if coalesce(current_setting('booking.allow_ledger_rewrite', true), '') = '1' then return coalesce(new, old); end if;
  raise exception 'gift_card_ledger on append-only' using errcode = 'BK001', detail = 'ledger_append_only';
end $$;
create trigger gift_card_ledger_append_only before update or delete on booking.gift_card_ledger for each row execute function booking.gift_card_ledger_append_only_trg();

-- ---------- maksutapa + payments-suoja ----------
update booking.payment_methods set is_manual = false, label = 'Lahjakortti' where code = 'gift_card';

create or replace function booking.payments_gift_card_guard_trg() returns trigger language plpgsql security definer set search_path to ''
as $$ begin
  if new.method = 'gift_card' and new.gift_card_id is null then
    perform booking._err('gift_card_required', 'Lahjakorttimaksu vaatii kortin (käytä admin_redeem_gift_card / public_apply_gift_card)');
  end if;
  if new.method <> 'gift_card' and new.gift_card_id is not null then
    perform booking._err('invalid_payment_method', 'gift_card_id sallitaan vain maksutavalla gift_card');
  end if;
  if new.method = 'gift_card' and exists (select 1 from booking.order_items oi where oi.order_id = new.order_id and oi.kind = 'gift_card') then
    perform booking._err('gift_card_not_allowed', 'Lahjakortilla ei voi ostaa lahjakorttia');
  end if;
  return new;
end $$;
create trigger payments_gift_card_guard before insert or update of method, gift_card_id on booking.payments
  for each row execute function booking.payments_gift_card_guard_trg();

-- ---------- asetukset ja oikeudet ----------
insert into booking.settings(key, value, description, is_public) values
 ('gift_cards.redeem_enabled', 'false'::jsonb, 'Lahjakorttien lunastus päällä (admin_redeem_gift_card, public_apply_gift_card). Oletus false kunnes Joonas aktivoi.', false),
 ('gift_cards.johku_cards_redeemable', 'false'::jsonb, 'Johku-lähtöisten korttien lunastus sallittu. Pidä false kunnes Johkun kortit on suljettu (ei kaksoislunastusta).', false),
 ('gift_cards.sale_enabled', 'false'::jsonb, 'Lahjakorttien verkkomyynti (public_buy_gift_card) päällä.', false),
 ('gift_cards.max_cards_per_order', '10'::jsonb, 'Kortteja enintään / tilaus', false),
 ('gift_cards.rl_check_fail_per_10min', '10'::jsonb, 'public_check_gift_card / public_apply_gift_card: epäonnistuneita yrityksiä / IP-avain / 10 min', false),
 ('gift_cards.rl_global_fail_per_10min', '200'::jsonb, 'Epäonnistuneet yritykset yhteensä / 10 min (hajautettu arvaus)', false),
 ('gift_cards.rl_buy_per_10min', '6'::jsonb, 'public_buy_gift_card: ostoyrityksiä / IP / 10 min', false)
on conflict (key) do nothing;
insert into booking.role_permissions(role_code, permission) values
  ('staff', 'giftcards.manage'), ('manager', 'giftcards.manage'), ('admin', 'giftcards.manage'),
  ('manager', 'giftcards.admin'), ('admin', 'giftcards.admin')
on conflict do nothing;

-- ---------- RLS / oikeudet / audit ----------
do $$ declare t text; begin
  foreach t in array array['gift_card_packages', 'gift_card_blocked_codes', 'gift_card_check_log'] loop
    execute format('alter table booking.%I enable row level security', t);
    execute format('revoke all on booking.%I from public, anon, authenticated', t);
    execute format('grant all on booking.%I to service_role', t);
  end loop;
  grant select on booking.gift_card_packages to authenticated;
  create policy staff_read on booking.gift_card_packages for select to authenticated using ((select booking.is_staff()));
  perform booking._add_audit('booking.gift_card_packages'::regclass);
end $$;
grant usage, select on all sequences in schema booking to service_role;
-- uusi sarake public_token: authenticated-luku taulussa on jo (staff_read), anon ei näe taulua
