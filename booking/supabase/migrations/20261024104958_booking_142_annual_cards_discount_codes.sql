-- =============================================================================
-- booking_142_annual_cards_discount_codes.sql (paketti 10: vuosikortit ja alennuskoodit)
-- =============================================================================
-- Kirjoittaa vain booking-skeemaan (kb.products vain luetaan). Ei muuta olemassa olevia funktioita: kaikki uusi on
-- uusia funktioita, sarakkeita, rajoitteita ja triggereitä, joten rollback poistaa ne.
--  1) annual_cards: code (yksilöllinen, SANA + 1–999, esim. HIRVI123; generoidaan jos puuttuu) ja purchase_order_id
--     (verkko-ostosta myönnetty kortti). Vanhoille korteille generoidaan koodi; voimassaoloa ei muuteta.
--  2) discount_codes: target_scope (order / product), usage_type (single / multi / permanent), is_annual_card_code
--     (yhteinen vuosikorttikoodi: 100 %, pysyvä, vain vuosikorttituotteet). Koodit isoilla kirjaimilla; sama koodi ei voi
--     olla sekä alennuskoodi että vuosikortti. Migraatio EI luo yhtään koodia eikä korttia.
--  3) public_preview_code: kassan esikatselu. Hinta lasketaan palvelimella (_rule_price + lisäpalveluiden hinnat
--     tietokannasta), selaimen hintoihin ei luoteta.
--  4) public_create_booking_code: varaus koodilla. Tyhjä koodi → public_create_booking sellaisenaan.
--     - vuosikortin koodi / yhteinen vuosikorttikoodi: yksi henkilö (annual_card_max_persons), vain yleinen vuoro,
--       tuotteet annual_card_product_ids (oletus 1,2,3,4,6), ei lisäpalveluita, yksityisasiakas, yksi tuleva
--       vuosikorttivaraus per asiakas / sähköposti / puhelin. Hinta 0 €, vahvistetaan heti (maksu annual_card 0 €).
--     - alennuskoodi: public_create_booking luo varauksen normaalisti, sitten alennus jaetaan tilausriveille
--       (discount_amount), rivin line_total_gross pienenee ja rivin oma ALV-kanta säilyy (line_vat / line_net
--       lasketaan alennetusta summasta). unit_price_gross ja tuotteiden hinnat eivät muutu.
--  5) Varauksen muutos (_change_booking_core / _clamp_addons) laskee rivin täyden hinnan: triggeri
--     order_items_discount_keep laskee alennuksen uudelleen (prosentti uudesta summasta, euromäärä säilyy).
--     Yhteisellä vuosikorttikoodilla tehdyn varauksen henkilömäärää ei voi kasvattaa yli rajan.
--  6) Vuosikortin myynti verkossa: public_annual_card_offer / public_buy_annual_card (hinta kb.products-riviltä,
--     annual_card_product_id, oletus 43). Myynti on oletuksena pois (asetus annual_card_sale_enabled = false).
--     Kortti myönnetään vasta kun tilaus on maksettu (orders.payment_status → paid; kaikki maksutavat).
--     Jatkokortti alkaa nykyisen voimassaolon jälkeen. public_annual_card_purchase_code(token) näyttää koodin tilaussivulla.
--  7) Hallinta: admin_list_discount_codes / admin_save_discount_code / admin_delete_discount_code (catalog.edit;
--     yhteinen vuosikorttikoodi vaatii annual_cards.manage), admin_list_annual_cards_details / admin_create_annual_card
--     (annual_cards.manage).
-- Rollback: rollbacks/20261024104958_booking_142_ROLLBACK.sql (poistaa kaiken yllä olevan; HUOM: poistaa koodit
-- vuosikorteista ja alennuskoodien uudet kentät).
-- =============================================================================
set local lock_timeout = '5s';

-- ---------------------------------------------------------------- 1–2) sarakkeet
alter table booking.annual_cards add column if not exists code text;
alter table booking.annual_cards add column if not exists purchase_order_id bigint references booking.orders(id) on delete set null;
create unique index if not exists annual_cards_code_uq on booking.annual_cards(code);
create unique index if not exists annual_cards_purchase_order_uq on booking.annual_cards(purchase_order_id) where purchase_order_id is not null;

alter table booking.discount_codes add column if not exists target_scope text not null default 'order';
alter table booking.discount_codes add column if not exists usage_type text not null default 'permanent';
alter table booking.discount_codes add column if not exists is_annual_card_code boolean not null default false;

do $$ begin
  if exists (select 1 from booking.discount_codes group by upper(btrim(code)) having count(*) > 1) then
    raise exception 'booking_142: discount_codes sisältää saman koodin eri kirjoitusasuilla – korjaa ennen migraatiota';
  end if;
end $$;
update booking.discount_codes set usage_type = case when max_uses = 1 then 'single' when max_uses > 1 then 'multi' else 'permanent' end
 where usage_type = 'permanent' and max_uses is not null;
update booking.discount_codes set max_uses = null where usage_type = 'permanent' and max_uses is not null;   -- max_uses = 0 (vanha data)
update booking.discount_codes set target_scope = 'product' where coalesce(cardinality(product_ids), 0) > 0 and target_scope = 'order';
update booking.discount_codes set code = upper(btrim(code)) where code is distinct from upper(btrim(code));

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'booking142_discount_scope') then
    alter table booking.discount_codes add constraint booking142_discount_scope check (target_scope in ('order', 'product'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'booking142_discount_usage') then
    alter table booking.discount_codes add constraint booking142_discount_usage check (
      (usage_type = 'single' and max_uses = 1) or (usage_type = 'multi' and max_uses > 1) or (usage_type = 'permanent' and max_uses is null));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'booking142_discount_count') then
    alter table booking.discount_codes add constraint booking142_discount_count check (used_count >= 0);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'booking142_discount_percent') then
    alter table booking.discount_codes add constraint booking142_discount_percent check (kind <> 'percent' or value <= 100);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'booking142_discount_dates') then
    alter table booking.discount_codes add constraint booking142_discount_dates check (valid_to is null or valid_from is null or valid_to >= valid_from);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'booking142_discount_annual') then
    alter table booking.discount_codes add constraint booking142_discount_annual check (
      not is_annual_card_code or (kind = 'percent' and value = 100 and usage_type = 'permanent'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'booking142_card_code_format') then
    alter table booking.annual_cards add constraint booking142_card_code_format check (code ~ '^[A-Z0-9-]{3,40}$');
  end if;
end $$;

insert into booking.settings(key, value, description, is_public)
values ('annual_card_sale_enabled', 'false'::jsonb, 'Vuosikortin verkkomyynti kaupassa (booking_142). Kortti myönnetään kun tilaus on maksettu.', false)
on conflict (key) do nothing;

-- ---------------------------------------------------------------- apufunktiot
create or replace function booking._norm_code(p_code text) returns text
language sql immutable set search_path = '' as $$
  select upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'))
$$;

-- Puhelinnumeron vertailuavain: vain numerot, +358 / 00358 → 0. Alle 6 numeroa → null.
create or replace function booking._phone_key(p_phone text) returns text
language plpgsql immutable set search_path = '' as $$
declare d text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
begin
  if d like '00358%' then d := '0' || substr(d, 6); elsif d like '358%' then d := '0' || substr(d, 4); end if;
  return case when char_length(d) >= 6 then d end;
end $$;

-- Vuosikortilla varattavat tuotteet (asetus annual_card_product_ids, oletus 1,2,3,4,6 = yleiset saunavuorot ja tunnin saunavuoro).
create or replace function booking._annual_product_ids() returns bigint[]
language sql stable security definer set search_path = '' as $$
  select coalesce((select array_agg(x::bigint) from jsonb_array_elements_text(
           case when jsonb_typeof(booking._setting('annual_card_product_ids', '[1,2,3,4,6]'::jsonb)) = 'array'
                then booking._setting('annual_card_product_ids', '[1,2,3,4,6]'::jsonb) else '[1,2,3,4,6]'::jsonb end) x
          where x ~ '^\d{1,18}$'), '{}'::bigint[])
$$;

create or replace function booking._annual_max_persons() returns integer
language sql stable security definer set search_path = '' as $$
  select greatest(coalesce((booking._setting('annual_card_max_persons', '1'::jsonb) #>> '{}')::int, 1), 1)
$$;

create or replace function booking._generate_annual_card_code() returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  words text[] := array['HIRVI','NORPPA','KARHU','KUUSI','KOIVU','HONKA','HALTI','AALTO','USVA','KALLIO','SAMMAL','HAVU','KANTO',
                        'JOUTSEN','ILVES','KETTU','ORAVA','PIHLAJA','KATAJA','SUO','LAMPI','KOSKI'];
  c text;
begin
  perform pg_advisory_xact_lock(hashtextextended('booking:generate:annual', 0));
  for i in 1..10000 loop
    c := words[1 + floor(random() * array_length(words, 1))::int] || (1 + floor(random() * 999)::int)::text;
    if not exists (select 1 from booking.annual_cards where code = c) and not exists (select 1 from booking.discount_codes where code = c) then
      return c;
    end if;
  end loop;
  perform booking._err('code_exhausted', 'Vapaata vuosikorttikoodia ei löytynyt');
  return null;
end $$;

create or replace function booking._generate_discount_code() returns text
language plpgsql volatile security definer set search_path = '' as $$
declare alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text;
begin
  perform pg_advisory_xact_lock(hashtextextended('booking:generate:discount', 0));
  for i in 1..10000 loop
    c := '';
    for j in 1..6 loop c := c || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1); end loop;
    if not exists (select 1 from booking.discount_codes where code = c) and not exists (select 1 from booking.annual_cards where code = c) then
      return c;
    end if;
  end loop;
  perform booking._err('code_exhausted', 'Vapaata alennuskoodia ei löytynyt');
  return null;
end $$;

-- ---------------------------------------------------------------- triggerit: koodien normalisointi ja yksilöllisyys
create or replace function booking._discount_code_normalize_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.code := booking._norm_code(new.code);
  if new.code = '' then perform booking._err('invalid_code', 'Alennuskoodi ei voi olla tyhjä'); end if;
  perform pg_advisory_xact_lock(hashtextextended('booking:code:' || new.code, 0));
  if exists (select 1 from booking.annual_cards where code = new.code) then
    perform booking._err('code_exists', 'Koodi on jo vuosikortin käytössä');
  end if;
  if new.usage_type = 'single' then new.max_uses := 1; elsif new.usage_type = 'permanent' then new.max_uses := null; end if;
  if new.is_annual_card_code then new.target_scope := 'product'; new.product_ids := booking._annual_product_ids(); end if;
  if new.target_scope = 'product' and coalesce(cardinality(new.product_ids), 0) = 0 then
    perform booking._err('invalid_products', 'Valitse tuotteet, joihin alennus kohdistuu');
  end if;
  return new;
end $$;
drop trigger if exists discount_codes_normalize on booking.discount_codes;
create trigger discount_codes_normalize before insert or update of code, usage_type, max_uses, target_scope, product_ids, is_annual_card_code
  on booking.discount_codes for each row execute function booking._discount_code_normalize_trg();

create or replace function booking._annual_card_code_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.code is null or btrim(new.code) = '' then new.code := booking._generate_annual_card_code(); else new.code := booking._norm_code(new.code); end if;
  if new.code !~ '^[A-Z0-9-]{3,40}$' then perform booking._err('invalid_code', 'Koodissa saa olla 3–40 merkkiä: kirjaimia A–Z, numeroita ja väliviivoja'); end if;
  perform pg_advisory_xact_lock(hashtextextended('booking:code:' || new.code, 0));
  if exists (select 1 from booking.discount_codes d where d.code = new.code)
     or exists (select 1 from booking.annual_cards a where a.code = new.code and a.id is distinct from new.id) then
    perform booking._err('code_exists', 'Koodi on jo käytössä');
  end if;
  return new;
end $$;
drop trigger if exists annual_cards_code on booking.annual_cards;
create trigger annual_cards_code before insert or update of code on booking.annual_cards
  for each row execute function booking._annual_card_code_trg();

update booking.annual_cards set code = booking._generate_annual_card_code() where code is null;
alter table booking.annual_cards alter column code set not null;

-- ---------------------------------------------------------------- 5) alennus säilyy varauksen muutoksessa
-- _change_booking_core / _clamp_addons kirjoittavat rivin täyden hinnan (line_total_gross = unit_price_gross * quantity).
-- Jos rivillä on jo alennuskoodi, alennus lasketaan uudelleen: prosentti uudesta summasta, euromäärä säilyy (enintään rivin summa).
create or replace function booking._order_items_discount_keep_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
declare d booking.discount_codes; v_full numeric;
begin
  if new.discount_code_id is null or old.discount_code_id is distinct from new.discount_code_id then return new; end if;
  v_full := round(new.unit_price_gross * new.quantity, 2);
  if new.line_total_gross is distinct from v_full then return new; end if;   -- ei täyden hinnan uudelleenlaskentaa
  select * into d from booking.discount_codes where id = new.discount_code_id;
  if d.kind = 'percent' then new.discount_amount := round(v_full * d.value / 100, 2);
  else new.discount_amount := least(coalesce(old.discount_amount, 0), v_full); end if;
  new.discount_amount := least(greatest(coalesce(new.discount_amount, 0), 0), v_full);
  new.line_total_gross := v_full - new.discount_amount;
  return new;
end $$;
drop trigger if exists order_items_discount_keep on booking.order_items;
create trigger order_items_discount_keep before update of unit_price_gross, quantity, line_total_gross on booking.order_items
  for each row execute function booking._order_items_discount_keep_trg();

-- Yhteisellä vuosikorttikoodilla tehty varaus: henkilömäärä enintään annual_card_max_persons, tuote vuosikorttituotteista.
create or replace function booking._annual_code_reservation_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from booking.orders o join booking.discount_codes d on d.id = o.discount_code_id
              where o.id = new.order_id and d.is_annual_card_code) then
    if new.persons > booking._annual_max_persons() then
      perform booking._err('annual_card_persons', format('Vuosikorttivarauksessa enintään %s henkilöä', booking._annual_max_persons()));
    end if;
    if not (new.product_id = any (booking._annual_product_ids())) or new.mode <> 'shared' then
      perform booking._err('annual_card_product', 'Vuosikortilla voi varata vain yleisiä saunavuoroja');
    end if;
  end if;
  return new;
end $$;
drop trigger if exists reservations_annual_code_guard on booking.reservations;
create trigger reservations_annual_code_guard before update of persons, product_id, mode on booking.reservations
  for each row execute function booking._annual_code_reservation_trg();

-- Maksamatta vanhentunut / peruttu pito palauttaa alennuskoodin käyttökerran.
create or replace function booking._discount_release_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update booking.discount_codes set used_count = greatest(used_count - 1, 0)
   where id = new.discount_code_id and not is_annual_card_code;
  return null;
end $$;
drop trigger if exists orders_discount_release on booking.orders;
create trigger orders_discount_release after update of status on booking.orders
  for each row when (new.status in ('cancelled', 'expired') and old.status = 'pending' and new.discount_code_id is not null
                     and new.payment_status not in ('paid', 'partially_paid'))
  execute function booking._discount_release_trg();

-- ---------------------------------------------------------------- vuosikortin myöntäminen maksetusta tilauksesta
create or replace function booking._annual_card_from_order(p_order_id bigint) returns bigint
language plpgsql security definer set search_path = '' as $$
declare o booking.orders; n integer; v_today date := (now() at time zone booking._tz())::date; v_from date; v_id bigint;
begin
  select * into o from booking.orders where id = p_order_id;
  if o.id is null or o.customer_id is null or o.payment_status <> 'paid' or o.status in ('cancelled', 'expired') then return null; end if;
  select id into v_id from booking.annual_cards where purchase_order_id = o.id;
  if v_id is not null then return v_id; end if;
  select coalesce(sum(oi.quantity), 0)::int into n from booking.order_items oi join kb.products p on p.id = oi.product_id
   where oi.order_id = o.id and p.category = 'season_card';
  if n < 1 then return null; end if;
  perform pg_advisory_xact_lock(hashtextextended('booking:annual:customer:' || o.customer_id::text, 0));
  -- jatkokortti: alkaa nykyisen (aktiivisen) kortin päättymisen jälkeen
  select greatest(v_today, coalesce(max(a.valid_to) + 1, v_today)) into v_from from booking.annual_cards a
   where a.customer_id = o.customer_id and a.active and a.valid_to >= v_today;
  begin
    insert into booking.annual_cards(customer_id, valid_from, valid_to, active, notes, purchase_order_id)
    values (o.customer_id, v_from, (v_from + interval '1 year' - interval '1 day')::date, true,
            'Verkko-osto, tilaus ' || coalesce(o.order_no::text, o.id::text) || case when n > 1 then format(' (määrä %s: vain yksi kortti myönnetty)', n) else '' end,
            o.id)
    returning id into v_id;
  exception when others then   -- maksun kirjaus ei saa kaatua kortin myöntämiseen; kirjataan audit-lokiin henkilökunnalle
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (null, booking._jwt_role(), 'annual_cards', o.id::text, 'annual_card_issue_failed', null,
            jsonb_build_object('order_id', o.id, 'error', sqlerrm));
    return null;
  end;
  return v_id;
end $$;

create or replace function booking._annual_orders_paid_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform booking._annual_card_from_order(new.id);
  return null;
end $$;
drop trigger if exists orders_annual_paid on booking.orders;
create trigger orders_annual_paid after update of payment_status on booking.orders
  for each row when (new.payment_status = 'paid' and old.payment_status is distinct from 'paid')
  execute function booking._annual_orders_paid_trg();

-- ---------------------------------------------------------------- vuosikorttivarausten raja (asiakas / sähköposti / puhelin)
create or replace function booking._annual_lock_identity(p_customer_id bigint, p_email text, p_phone text) returns void
language plpgsql security definer set search_path = '' as $$
declare k text;
begin
  for k in select distinct x from unnest(array[
      case when p_customer_id is not null then 'id:' || p_customer_id::text end,
      case when nullif(lower(btrim(coalesce(p_email, ''))), '') is not null then 'email:' || lower(btrim(p_email)) end,
      case when booking._phone_key(p_phone) is not null then 'phone:' || booking._phone_key(p_phone) end]) x
    where x is not null order by x loop
    perform pg_advisory_xact_lock(hashtextextended('booking:annual:user:' || k, 0));
  end loop;
end $$;

create or replace function booking._annual_limit(p_customer_id bigint, p_email text, p_phone text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from booking.reservations r join booking.orders o on o.id = r.order_id
      left join booking.customers c on c.id = o.customer_id
      left join booking.discount_codes d on d.id = o.discount_code_id
     where r.starts_at > now() and booking._res_active(r.status, r.hold_expires_at)
       and (r.annual_card_id is not null or coalesce(d.is_annual_card_code, false))
       and ((p_customer_id is not null and o.customer_id = p_customer_id)
            or (nullif(lower(btrim(coalesce(p_email, ''))), '') is not null and lower(c.email) = lower(btrim(p_email)))
            or (booking._phone_key(p_phone) is not null and booking._phone_key(c.phone) = booking._phone_key(p_phone))))
$$;

-- ---------------------------------------------------------------- alennuksen laskenta
-- Rivit: [{key, product_id, kind, gross}] → {eligible, discount, shares:[{key, amount}]}; jako suhteessa rivin summaan, pyöristysero viimeiselle.
create or replace function booking._discount_split(p_code booking.discount_codes, p_lines jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_elig numeric := 0; v_disc numeric; v_left numeric; v_share numeric; e jsonb; v_n int := 0; v_i int := 0; v_out jsonb := '[]'::jsonb;
begin
  for e in select x from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x loop
    if (e ->> 'gross')::numeric > 0 and (e ->> 'kind') in ('reservation', 'addon', 'product')
       and (p_code.target_scope = 'order' or (e ->> 'product_id')::bigint = any (coalesce(p_code.product_ids, '{}'::bigint[]))) then
      v_elig := v_elig + (e ->> 'gross')::numeric; v_n := v_n + 1;
    end if;
  end loop;
  if v_elig <= 0 then return jsonb_build_object('eligible', 0, 'discount', 0, 'shares', '[]'::jsonb); end if;
  v_disc := case when p_code.kind = 'percent' then round(v_elig * p_code.value / 100, 2) else least(p_code.value, v_elig) end;
  v_disc := least(greatest(v_disc, 0), v_elig);
  v_left := v_disc;
  for e in select x from jsonb_array_elements(p_lines) x loop
    continue when not ((e ->> 'gross')::numeric > 0 and (e ->> 'kind') in ('reservation', 'addon', 'product')
       and (p_code.target_scope = 'order' or (e ->> 'product_id')::bigint = any (coalesce(p_code.product_ids, '{}'::bigint[]))));
    v_i := v_i + 1;
    v_share := case when v_i = v_n then v_left else least(round(v_disc * (e ->> 'gross')::numeric / v_elig, 2), v_left) end;
    v_share := least(v_share, (e ->> 'gross')::numeric);
    v_left := v_left - v_share;
    v_out := v_out || jsonb_build_array(jsonb_build_object('key', e -> 'key', 'amount', v_share));
  end loop;
  return jsonb_build_object('eligible', v_elig, 'discount', v_disc - v_left, 'shares', v_out);
end $$;

-- Koodin tila tänään: null = käytettävissä, muuten virhekoodi.
create or replace function booking._discount_state(p_code booking.discount_codes) returns text
language sql stable security definer set search_path = '' as $$
  select case
    when not p_code.active then 'code_inactive'
    when p_code.valid_from is not null and p_code.valid_from > (now() at time zone booking._tz())::date then 'code_not_started'
    when p_code.valid_to is not null and p_code.valid_to < (now() at time zone booking._tz())::date then 'code_expired'
    when p_code.max_uses is not null and p_code.used_count >= p_code.max_uses then 'code_used_up'
  end
$$;

create or replace function booking._code_msg(p_code text) returns text
language sql immutable set search_path = '' as $$
  select case p_code
    when 'invalid_code' then 'Koodia ei löytynyt'
    when 'code_inactive' then 'Koodi ei ole käytössä'
    when 'code_not_started' then 'Koodi ei ole vielä voimassa'
    when 'code_expired' then 'Koodi on vanhentunut'
    when 'code_used_up' then 'Koodi on jo käytetty'
    when 'code_not_applicable' then 'Koodi ei koske valittua palvelua'
    when 'annual_card_product' then 'Vuosikortilla voi varata vain yleisiä saunavuoroja'
    when 'annual_card_expired' then 'Vuosikortti ei ole voimassa vuoron päivänä'
    when 'annual_card_inactive' then 'Vuosikortti ei ole voimassa'
    when 'annual_card_customer_mismatch' then 'Koodi ei täsmää annettuihin yhteystietoihin'
    when 'annual_card_limit' then 'Vuosikortilla voi olla vain yksi tuleva varaus kerrallaan'
    when 'annual_card_persons' then 'Vuosikorttivaraus on yhdelle henkilölle'
    when 'annual_card_no_addons' then 'Vuosikorttivaraukseen ei voi lisätä lisäpalveluita'
    when 'annual_card_private_only' then 'Vuosikortti on henkilökohtainen (yksityisasiakas)'
    when 'rate_limited' then 'Liian monta yritystä, yritä hetken kuluttua uudelleen'
    else 'Koodia ei voi käyttää' end
$$;

-- Vuosikortin / yhteisen vuosikorttikoodin perustarkistukset varaukselle (ei asiakastarkistusta).
create or replace function booking._annual_rule_check(p_rule_id bigint, p_date date, p_card booking.annual_cards, p_code booking.discount_codes) returns text
language plpgsql stable security definer set search_path = '' as $$
declare r booking.schedule_rules; v_today date := (now() at time zone booking._tz())::date;
begin
  select * into r from booking.schedule_rules where id = p_rule_id;
  if r.id is null or r.mode is distinct from 'shared' or not (r.product_id = any (booking._annual_product_ids())) then return 'annual_card_product'; end if;
  if p_card.id is not null then
    if not p_card.active or p_card.revoked_at is not null then return 'annual_card_inactive'; end if;
    if p_date is not null and (p_date < p_card.valid_from or p_date > p_card.valid_to) then return 'annual_card_expired'; end if;
    if p_card.valid_to < v_today then return 'annual_card_expired'; end if;
  else
    if booking._discount_state(p_code) is not null then return booking._discount_state(p_code); end if;
    if p_date is not null and p_code.valid_to is not null and p_date > p_code.valid_to then return 'annual_card_expired'; end if;
  end if;
  return null;
end $$;

create or replace function booking._annual_card_owner_ok(p_card booking.annual_cards, p_email text, p_phone text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from booking.customers c where c.id = p_card.customer_id and c.anonymized_at is null
     and ((nullif(lower(btrim(coalesce(p_email, ''))), '') is not null and lower(c.email) = lower(btrim(p_email)))
          or (booking._phone_key(p_phone) is not null and booking._phone_key(c.phone) = booking._phone_key(p_phone))))
$$;

-- ---------------------------------------------------------------- 3) esikatselu
create or replace function booking.public_preview_code(p_code text, p_rule_id bigint, p_date date, p_persons integer,
  p_addons jsonb default null, p_email text default null, p_phone text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_code text := booking._norm_code(p_code); v_ip text := booking._client_ip(); v_card booking.annual_cards; d booking.discount_codes;
  r booking.schedule_rules; pr record; v_lines jsonb := '[]'::jsonb; v_sub numeric; v_err text; v_calc jsonb; e jsonb; a booking.addons; v_q int;
begin
  if v_code = '' or char_length(v_code) > 40 then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  select * into r from booking.schedule_rules where id = p_rule_id and active;
  if r.id is null or p_persons is null or p_persons < 1 or p_persons > 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_session', 'message', 'Valitse vuoro ja henkilömäärä');
  end if;
  select * into pr from booking._rule_price(p_rule_id, p_persons);
  v_lines := jsonb_build_array(jsonb_build_object('key', 0, 'product_id', r.product_id, 'kind', 'reservation', 'gross', pr.total));
  v_sub := pr.total;
  if p_addons is not null and jsonb_typeof(p_addons) = 'array' then
    for e in select x from jsonb_array_elements(p_addons) x limit 20 loop
      continue when jsonb_typeof(e) <> 'object' or coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' or coalesce(e ->> 'id', '') !~ '^\d{1,18}$';
      v_q := (e ->> 'quantity')::int; continue when v_q = 0;
      select * into a from booking.addons where id = (e ->> 'id')::bigint and active;
      continue when a.id is null;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('key', a.id, 'product_id', null, 'kind', 'addon', 'gross', a.price_gross * v_q));
      v_sub := v_sub + a.price_gross * v_q;
    end loop;
  end if;

  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code; end if;
  if v_card.id is null and d.id is null then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;

  if v_card.id is not null or d.is_annual_card_code then
    v_err := booking._annual_rule_check(p_rule_id, p_date, v_card, d);
    if v_err is null and v_card.id is not null and (nullif(btrim(coalesce(p_email, '')), '') is not null or booking._phone_key(p_phone) is not null)
       and not booking._annual_card_owner_ok(v_card, p_email, p_phone) then v_err := 'annual_card_customer_mismatch'; end if;
    if v_err is null and (nullif(btrim(coalesce(p_email, '')), '') is not null or booking._phone_key(p_phone) is not null)
       and booking._annual_limit(v_card.customer_id, p_email, p_phone) then v_err := 'annual_card_limit'; end if;
    if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
    select * into pr from booking._rule_price(p_rule_id, booking._annual_max_persons());
    return jsonb_build_object('ok', true, 'type', case when v_card.id is not null then 'annual_card' else 'annual_code' end, 'code', v_code,
      'persons', booking._annual_max_persons(), 'addons_allowed', false, 'subtotal', pr.total, 'discount', pr.total, 'total', 0,
      'valid_to', coalesce(v_card.valid_to, d.valid_to));
  end if;

  v_err := booking._discount_state(d);
  if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
  v_calc := booking._discount_split(d, v_lines);
  if (v_calc ->> 'discount')::numeric <= 0 then
    return jsonb_build_object('ok', false, 'code', 'code_not_applicable', 'message', booking._code_msg('code_not_applicable'));
  end if;
  return jsonb_build_object('ok', true, 'type', 'discount', 'code', v_code, 'kind', d.kind, 'value', d.value, 'subtotal', v_sub,
    'discount', (v_calc ->> 'discount')::numeric, 'total', v_sub - (v_calc ->> 'discount')::numeric, 'addons_allowed', true);
end $$;

-- Esikatselun rate limit erillisenä (stable-funktio ei voi kirjata): kassa kutsuu public_check_code, joka kirjaa yrityksen.
create or replace function booking.public_check_code(p_code text, p_rule_id bigint, p_date date, p_persons integer,
  p_addons jsonb default null, p_email text default null, p_phone text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_ip text := booking._client_ip();
begin
  if v_ip is not null and not booking._rate_limit('code:ip:' || v_ip, 20, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
  end if;
  return booking.public_preview_code(p_code, p_rule_id, p_date, p_persons, p_addons, p_email, p_phone);
end $$;

-- ---------------------------------------------------------------- 4) varaus koodilla
create or replace function booking.public_create_booking_code(p_rule_id bigint, p_date date, p_persons integer, p_name text, p_email text, p_phone text,
  p_marketing_consent boolean default false, p_locale text default 'fi', p_note text default null, p_customer_kind text default 'private',
  p_company jsonb default null, p_addons jsonb default null, p_code text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text := booking._norm_code(p_code); v_ip text := booking._client_ip();
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private')));
  v_card booking.annual_cards; d booking.discount_codes; v_res jsonb; v_order booking.orders; v_cust bigint; v_err text; v_detail text; v_msg text;
  v_lines jsonb; v_calc jsonb; s jsonb; v_disc numeric; v_total numeric; pr record; v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}';
begin
  if v_code = '' then
    return booking.public_create_booking(p_rule_id, p_date, p_persons, p_name, p_email, p_phone, p_marketing_consent, p_locale, p_note,
                                         p_customer_kind, p_company, p_addons);
  end if;
  if v_ip is not null and not booking._rate_limit('code:ip:' || v_ip, 20, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
  end if;
  if char_length(v_code) > 40 then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code for update; end if;
  if v_card.id is null and d.id is null then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;

  -- ---- vuosikortti / yhteinen vuosikorttikoodi
  if v_card.id is not null or d.is_annual_card_code then
    if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
      return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
    end if;
    if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
      return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
    end if;
    if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
      return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
    end if;
    if char_length(v_name) < 2 or char_length(v_name) > 120 then return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', 'Anna nimi'); end if;
    if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
    if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
    if p_note is not null and char_length(p_note) > 1000 then return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä'); end if;
    if p_date is null or p_date < (now() at time zone booking._tz())::date
       or p_date > (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int then
      return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
    end if;
    v_err := case
      when v_kind <> 'private' then 'annual_card_private_only'
      when p_addons is not null and jsonb_typeof(p_addons) = 'array' and exists (select 1 from jsonb_array_elements(p_addons) x where coalesce(x ->> 'quantity', '0') <> '0') then 'annual_card_no_addons'
      when p_persons is distinct from booking._annual_max_persons() then 'annual_card_persons'
      else booking._annual_rule_check(p_rule_id, p_date, v_card, d) end;
    if v_err is null and v_card.id is not null and not booking._annual_card_owner_ok(v_card, v_email, v_phone) then v_err := 'annual_card_customer_mismatch'; end if;
    if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
    begin
      if v_card.id is not null then v_cust := v_card.customer_id;
      else
        v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale,
                                           (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
      end if;
      perform booking._annual_lock_identity(v_cust, v_email, v_phone);
      if booking._annual_limit(v_cust, v_email, v_phone) then perform booking._err('annual_card_limit', booking._code_msg('annual_card_limit')); end if;
      v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, 'web', null, p_locale, p_note, 'confirmed', null, true,
                                            null, null, case when v_card.id is null then 0 end, v_card.id);
      if d.id is not null then
        select * into pr from booking._rule_price(p_rule_id, p_persons);
        update booking.order_items set discount_code_id = d.id, discount_amount = pr.total
         where order_id = (v_res ->> 'order_id')::bigint and kind = 'reservation';
        update booking.orders set discount_code_id = d.id where id = (v_res ->> 'order_id')::bigint;
        update booking.discount_codes set used_count = used_count + 1 where id = d.id;
      end if;
      insert into booking.payments(order_id, method, provider, status, amount, paid_at, note)
      values ((v_res ->> 'order_id')::bigint, 'annual_card', 'manual', 'paid', 0, now(), 'Vuosikorttivaraus verkossa (' || v_code || ')');
      update booking.orders set payment_status = 'paid' where id = (v_res ->> 'order_id')::bigint;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
    end;
    return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token', 'status', 'confirmed',
                              'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at', 'total', 0, 'addons_total', 0,
                              'hold_expires_at', null, 'payment_mode', v_mode, 'payment_url', null, 'product_name', v_res -> 'product_name',
                              'customer_kind', 'private', 'code_type', case when v_card.id is not null then 'annual_card' else 'annual_code' end,
                              'discount', (select coalesce(sum(discount_amount), 0) from booking.order_items where order_id = (v_res ->> 'order_id')::bigint))
           || booking._checkout_state_json((v_res ->> 'order_id')::bigint);
  end if;

  -- ---- alennuskoodi
  v_err := booking._discount_state(d);
  if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
  begin
    v_res := booking.public_create_booking(p_rule_id, p_date, p_persons, p_name, p_email, p_phone, p_marketing_consent, p_locale, p_note,
                                           p_customer_kind, p_company, p_addons);
    if not coalesce((v_res ->> 'ok')::boolean, false) then return v_res; end if;
    select * into v_order from booking.orders where public_token = (v_res ->> 'token')::uuid for update;
    select coalesce(jsonb_agg(jsonb_build_object('key', oi.id, 'product_id', oi.product_id, 'kind', oi.kind, 'gross', oi.line_total_gross) order by oi.id), '[]'::jsonb)
      into v_lines from booking.order_items oi where oi.order_id = v_order.id;
    v_calc := booking._discount_split(d, v_lines);
    v_disc := (v_calc ->> 'discount')::numeric;
    if v_disc <= 0 then perform booking._err('code_not_applicable', booking._code_msg('code_not_applicable')); end if;
    for s in select x from jsonb_array_elements(v_calc -> 'shares') x loop
      update booking.order_items set discount_code_id = d.id, discount_amount = coalesce(discount_amount, 0) + (s ->> 'amount')::numeric,
             line_total_gross = line_total_gross - (s ->> 'amount')::numeric
       where id = (s ->> 'key')::bigint and order_id = v_order.id;
    end loop;
    update booking.orders set discount_code_id = d.id,
           total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = v_order.id), 0)
     where id = v_order.id returning total_gross into v_total;
    update booking.discount_codes set used_count = used_count + 1 where id = d.id;
    if v_total > 0 then
      update booking.payments set amount = v_total where order_id = v_order.id and status = 'pending' and provider = 'manual';
    else   -- 100 % alennus: ei maksettavaa → vahvistetaan heti
      update booking.payments set status = 'cancelled' where order_id = v_order.id and status = 'pending';
      insert into booking.payments(order_id, method, provider, status, amount, paid_at, note)
      values (v_order.id, 'other', 'manual', 'paid', 0, now(), 'Alennuskoodi ' || d.code || ' (100 %)');
      update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = v_order.id and status = 'pending';
      update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()), hold_kind = null where id = v_order.id and status = 'pending';
      update booking.orders set payment_status = 'paid' where id = v_order.id;
    end if;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  select * into v_order from booking.orders where id = v_order.id;
  return v_res || jsonb_build_object('total', v_total, 'status', v_order.status, 'hold_expires_at',
                    (select min(hold_expires_at) from booking.reservations where order_id = v_order.id and status = 'pending'),
                    'discount', v_disc, 'discount_code', d.code, 'code_type', 'discount',
                    'addons_total', (select coalesce(sum(line_total_gross), 0) from booking.order_items where order_id = v_order.id and kind = 'addon'))
                || booking._checkout_state_json(v_order.id);
end $$;

-- ---------------------------------------------------------------- 6) vuosikortin verkko-osto
create or replace function booking._annual_sale_product() returns kb.products
language sql stable security definer set search_path = '' as $$
  select p.* from kb.products p
   where p.id = coalesce((booking._setting('annual_card_product_id', '43'::jsonb) #>> '{}')::bigint, 43)
     and p.category = 'season_card' and p.active and p.price is not null and p.price > 0 and p.vat_rate is not null
$$;

create or replace function booking.public_annual_card_offer() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p kb.products := booking._annual_sale_product();
begin
  if not coalesce((booking._setting('annual_card_sale_enabled', 'false'::jsonb) #>> '{}')::boolean, false) or p.id is null then
    return jsonb_build_object('ok', true, 'available', false);
  end if;
  return jsonb_build_object('ok', true, 'available', true, 'product_id', p.id, 'name', p.name, 'name_en', p.name_en,
                            'price', p.price, 'vat_rate', p.vat_rate, 'valid_months', 12);
end $$;

create or replace function booking.public_buy_annual_card(p_name text, p_email text, p_phone text, p_marketing_consent boolean default false, p_locale text default 'fi')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}'; v_ip text := booking._client_ip();
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_locale text := case when p_locale in ('fi', 'en', 'sv') then p_locale else 'fi' end;
  p kb.products := booking._annual_sale_product(); v_cust bigint; v_order booking.orders; v_status text; v_detail text; v_msg text;
begin
  if not coalesce((booking._setting('annual_card_sale_enabled', 'false'::jsonb) #>> '{}')::boolean, false) or p.id is null then
    return jsonb_build_object('ok', false, 'code', 'sale_disabled', 'message', 'Vuosikorttien verkkomyynti ei ole käytössä');
  end if;
  if v_ip is not null and not booking._rate_limit('annualbuy:ip:' || v_ip, 6, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
  end if;
  if v_email <> '' and not booking._rate_limit('annualbuy:email:' || v_email, 4, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', 'Anna nimi'); end if;
  if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
  v_status := case when v_mode = 'pay_later' then 'confirmed' else 'pending' end;
  begin
    v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_annual_card', v_locale,
                                       (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale)
    values (v_cust, v_status, 'unpaid', p.price, 'web', v_locale) returning * into v_order;
    if v_status = 'confirmed' then update booking.orders set confirmed_at = now() where id = v_order.id; end if;
    insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
    values (v_order.id, p.id, p.name, 'product', 1, p.price, p.price, p.vat_rate, jsonb_build_object('annual_card', true, 'name_en', p.name_en));
    insert into booking.payments(order_id, method, provider, status, amount)
    values (v_order.id, case when v_mode = 'pay_later' then 'pay_later' else 'visma_pay' end, case when v_mode = 'pay_later' then 'manual' else 'visma_pay' end,
            'pending', p.price);
    update booking.orders set payment_status = case when v_mode = 'pay_later' then 'unpaid' else 'pending' end where id = v_order.id;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  return jsonb_build_object('ok', true, 'order_no', v_order.order_no, 'token', v_order.public_token, 'status', v_status, 'total', p.price,
                            'payment_mode', v_mode, 'payment_url', null, 'note', 'Vuosikortti ja sen koodi myönnetään kun tilaus on maksettu');
end $$;

create or replace function booking.public_annual_card_purchase_code(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare o booking.orders; a booking.annual_cards;
begin
  select * into o from booking.orders where public_token = p_token;
  if o.id is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into a from booking.annual_cards where purchase_order_id = o.id;
  if a.id is null then
    return jsonb_build_object('ok', true, 'has_card', exists (select 1 from booking.order_items oi join kb.products p on p.id = oi.product_id
                                                               where oi.order_id = o.id and p.category = 'season_card'), 'code', null);
  end if;
  return jsonb_build_object('ok', true, 'has_card', true, 'code', a.code, 'valid_from', a.valid_from, 'valid_to', a.valid_to, 'active', a.active);
end $$;

-- ---------------------------------------------------------------- 7) hallinta
create or replace function booking.admin_list_discount_codes() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (booking.has_permission('catalog.edit') or booking.has_permission('annual_cards.manage')) then
    perform booking._require_permission('catalog.edit');
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'code', d.code, 'description', d.description, 'kind', d.kind, 'value', d.value,
      'valid_from', d.valid_from, 'valid_to', d.valid_to, 'max_uses', d.max_uses, 'used_count', d.used_count, 'product_ids', d.product_ids,
      'active', d.active, 'target_scope', d.target_scope, 'usage_type', d.usage_type, 'is_annual_card_code', d.is_annual_card_code,
      'external_source', d.external_source, 'state', booking._discount_state(d), 'updated_at', d.updated_at)
      order by d.is_annual_card_code desc, d.active desc, d.code) from booking.discount_codes d), '[]'::jsonb);
end $$;

create or replace function booking.admin_save_discount_code(p_id bigint, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  d booking.discount_codes; v_annual boolean := coalesce((p_data ->> 'is_annual_card_code')::boolean, false);
  v_code text := booking._norm_code(p_data ->> 'code'); v_kind text := coalesce(p_data ->> 'kind', 'percent');
  v_value numeric; v_usage text := coalesce(p_data ->> 'usage_type', 'single'); v_scope text := coalesce(p_data ->> 'target_scope', 'order');
  v_max int; v_pids bigint[]; v_from date; v_to date; v_desc text := nullif(btrim(coalesce(p_data ->> 'description', '')), '');
begin
  perform booking._require_permission('catalog.edit');
  if p_id is not null then
    select * into d from booking.discount_codes where id = p_id for update;
    if d.id is null then perform booking._err('not_found', 'Koodia ei löydy'); end if;
  end if;
  if v_annual or coalesce(d.is_annual_card_code, false) then perform booking._require_permission('annual_cards.manage'); end if;
  if v_code = '' then v_code := booking._generate_discount_code(); end if;
  if v_code !~ '^[A-Z0-9-]{3,40}$' then perform booking._err('invalid_code', 'Koodissa saa olla 3–40 merkkiä: kirjaimia A–Z, numeroita ja väliviivoja'); end if;
  if v_kind not in ('percent', 'fixed') then perform booking._err('invalid_kind', 'Valitse prosentti tai euromäärä'); end if;
  if coalesce(p_data ->> 'value', '') !~ '^\d{1,6}(\.\d{1,2})?$' then perform booking._err('invalid_value', 'Tarkista alennuksen määrä'); end if;
  v_value := (p_data ->> 'value')::numeric;
  if v_value <= 0 or (v_kind = 'percent' and v_value > 100) then perform booking._err('invalid_value', 'Prosentti 0–100, euromäärä yli 0'); end if;
  if v_usage not in ('single', 'multi', 'permanent') then perform booking._err('invalid_usage', 'Tarkista käyttökerrat'); end if;
  if v_usage = 'multi' then
    if coalesce(p_data ->> 'max_uses', '') !~ '^\d{1,6}$' or (p_data ->> 'max_uses')::int < 2 then perform booking._err('invalid_max_uses', 'Käyttökertoja vähintään 2'); end if;
    v_max := (p_data ->> 'max_uses')::int;
  end if;
  if v_scope not in ('order', 'product') then perform booking._err('invalid_scope', 'Tarkista kohdistus'); end if;
  if v_scope = 'product' then
    select coalesce(array_agg(distinct x::bigint order by x::bigint), '{}') into v_pids
      from jsonb_array_elements_text(case when jsonb_typeof(p_data -> 'product_ids') = 'array' then p_data -> 'product_ids' else '[]'::jsonb end) x where x ~ '^\d{1,18}$';
    if exists (select 1 from unnest(v_pids) u where not exists (select 1 from kb.products p where p.id = u)) then
      perform booking._err('invalid_products', 'Tuntematon tuote');
    end if;
  end if;
  begin
    v_from := nullif(p_data ->> 'valid_from', '')::date; v_to := nullif(p_data ->> 'valid_to', '')::date;
  exception when others then perform booking._err('invalid_dates', 'Tarkista päivämäärät'); end;
  if v_from is not null and v_to is not null and v_to < v_from then perform booking._err('invalid_dates', 'Päättymispäivä ennen alkua'); end if;
  if v_desc is not null and char_length(v_desc) > 300 then perform booking._err('invalid_description', 'Kuvaus on liian pitkä'); end if;
  if v_annual then v_kind := 'percent'; v_value := 100; v_usage := 'permanent'; v_scope := 'product'; v_max := null; end if;
  if exists (select 1 from booking.discount_codes where code = v_code and id is distinct from p_id) then
    perform booking._err('code_exists', 'Koodi on jo käytössä');
  end if;
  if p_id is null then
    insert into booking.discount_codes(code, description, kind, value, valid_from, valid_to, max_uses, product_ids, active, target_scope, usage_type, is_annual_card_code)
    values (v_code, v_desc, v_kind, v_value, v_from, v_to, v_max, case when v_scope = 'product' then v_pids end,
            coalesce((p_data ->> 'active')::boolean, true), v_scope, v_usage, v_annual)
    returning * into d;
  else
    if v_usage <> 'permanent' and v_max is null and v_usage = 'single' then v_max := 1; end if;
    if v_max is not null and v_max < d.used_count then perform booking._err('invalid_max_uses', 'Käyttökertoja ei voi asettaa alle jo käytetyn määrän'); end if;
    update booking.discount_codes set code = v_code, description = v_desc, kind = v_kind, value = v_value, valid_from = v_from, valid_to = v_to,
           max_uses = v_max, product_ids = case when v_scope = 'product' then v_pids end, active = coalesce((p_data ->> 'active')::boolean, active),
           target_scope = v_scope, usage_type = v_usage, is_annual_card_code = v_annual
     where id = p_id returning * into d;
  end if;
  return jsonb_build_object('ok', true, 'id', d.id, 'code', d.code);
end $$;

create or replace function booking.admin_delete_discount_code(p_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d booking.discount_codes;
begin
  perform booking._require_permission('catalog.edit');
  select * into d from booking.discount_codes where id = p_id for update;
  if d.id is null then perform booking._err('not_found', 'Koodia ei löydy'); end if;
  if d.is_annual_card_code then perform booking._require_permission('annual_cards.manage'); end if;
  if d.used_count > 0 or exists (select 1 from booking.orders where discount_code_id = d.id)
     or exists (select 1 from booking.order_items where discount_code_id = d.id) then
    update booking.discount_codes set active = false where id = d.id;
    return jsonb_build_object('ok', true, 'deactivated', true);
  end if;
  delete from booking.discount_codes where id = d.id;
  return jsonb_build_object('ok', true, 'deleted', true);
end $$;

create or replace function booking.admin_list_annual_cards_details() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_permission('annual_cards.manage');
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'customer_id', a.customer_id, 'customer_name', c.name,
      'customer_email', c.email, 'valid_from', a.valid_from, 'valid_to', a.valid_to, 'active', a.active, 'revoked_at', a.revoked_at,
      'notes', a.notes, 'purchase_order_no', o.order_no,
      'future_bookings', (select count(*) from booking.reservations r where r.annual_card_id = a.id and r.starts_at > now()
                           and booking._res_active(r.status, r.hold_expires_at)))
      order by a.active desc, a.valid_to desc, a.id desc)
    from booking.annual_cards a join booking.customers c on c.id = a.customer_id left join booking.orders o on o.id = a.purchase_order_id), '[]'::jsonb);
end $$;

create or replace function booking.admin_create_annual_card(p_customer_id bigint, p_valid_from date, p_valid_to date, p_code text default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a booking.annual_cards;
begin
  perform booking._require_permission('annual_cards.manage');
  if not exists (select 1 from booking.customers where id = p_customer_id and anonymized_at is null) then
    perform booking._err('customer_not_found', 'Asiakasta ei löydy');
  end if;
  if p_valid_from is null or p_valid_to is null or p_valid_to < p_valid_from then perform booking._err('invalid_dates', 'Virheellinen voimassaoloaika'); end if;
  begin
    insert into booking.annual_cards(customer_id, valid_from, valid_to, notes, created_by, code)
    values (p_customer_id, p_valid_from, p_valid_to, nullif(btrim(coalesce(p_notes, '')), ''), auth.uid(), nullif(btrim(coalesce(p_code, '')), ''))
    returning * into a;
  exception
    when exclusion_violation then perform booking._err('annual_card_overlap', 'Asiakkaalla on jo aktiivinen vuosikortti tälle ajanjaksolle');
    when unique_violation then perform booking._err('code_exists', 'Koodi on jo käytössä');
  end;
  return jsonb_build_object('ok', true, 'id', a.id, 'code', a.code);
end $$;

-- ---------------------------------------------------------------- oikeudet
do $$
declare f text;
begin
  foreach f in array array[
    'booking._norm_code(text)', 'booking._phone_key(text)', 'booking._annual_product_ids()', 'booking._annual_max_persons()',
    'booking._generate_annual_card_code()', 'booking._generate_discount_code()', 'booking._discount_code_normalize_trg()',
    'booking._annual_card_code_trg()', 'booking._order_items_discount_keep_trg()', 'booking._annual_code_reservation_trg()',
    'booking._discount_release_trg()', 'booking._annual_card_from_order(bigint)', 'booking._annual_orders_paid_trg()',
    'booking._annual_lock_identity(bigint,text,text)', 'booking._annual_limit(bigint,text,text)',
    'booking._discount_split(booking.discount_codes,jsonb)', 'booking._discount_state(booking.discount_codes)', 'booking._code_msg(text)',
    'booking._annual_rule_check(bigint,date,booking.annual_cards,booking.discount_codes)', 'booking._annual_card_owner_ok(booking.annual_cards,text,text)',
    'booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)', 'booking._annual_sale_product()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  foreach f in array array[
    'booking.public_check_code(text,bigint,date,integer,jsonb,text,text)',
    'booking.public_create_booking_code(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb,text)',
    'booking.public_annual_card_offer()', 'booking.public_buy_annual_card(text,text,text,boolean,text)', 'booking.public_annual_card_purchase_code(uuid)'] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated, service_role', f);
  end loop;
  foreach f in array array[
    'booking.admin_list_discount_codes()', 'booking.admin_save_discount_code(bigint,jsonb)', 'booking.admin_delete_discount_code(bigint)',
    'booking.admin_list_annual_cards_details()', 'booking.admin_create_annual_card(bigint,date,date,text,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;
