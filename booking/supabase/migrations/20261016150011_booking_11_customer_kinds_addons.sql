-- =====================================================================
-- booking 11: asiakastyypit (yksityis-/yritysasiakas, verkkolaskutustiedot), lisäpalvelut (add-ons) ja niiden hinnoittelu/tilaus.
-- UUSI migraatio (01–10 on jo ajettu eikä niitä muokata): kaikki muutokset tehdään alter table / create or replace -lauseilla.
--
--  1) booking.customer_kinds (taulupohjainen luettelo: private, company) + customers.customer_kind, y-tunnus, verkkolaskuosoite,
--     välittäjätunnus, viite. HUOM: customers.customer_type (migraatio 02) on edelleen asiakkaan ROOLI/etuustaso (customer / annual_card);
--     customer_kind on eri akseli: yksityinen vs yritys.
--  2) y-tunnuksen validointi (muoto 1234567-8 + tarkistenumero) ja yritystietojen siivous/validointi (_clean_company).
--  3) orders: customer_kind + billing (laskutustietojen kuva tilaushetkeltä, jsonb) + invoice_reference (viite/tilausnumero).
--  4) booking.addons (lisäpalvelut: hinta sis. ALV, ALV-kanta, max kpl / henkilö, mille vuorotyypeille) + order_items.addon_id / parent_item_id
--     (kind='addon': lisäpalvelurivi kuuluu varausriviin, jolloin vuorokohtainen yhteenveto onnistuu).
--  5) public_create_booking: uudet parametrit (asiakastyyppi, yritystiedot, lisäpalvelut); public_addons(); public_get_booking näyttää lisäpalvelut.
--  6) hallinta: admin_create_customer, admin_update_customer (+kentät), admin_list_customers (+kentät), admin_create_booking (+yritys, lisäpalvelut),
--     admin_list_addons / admin_create_addon / admin_update_addon (oikeus catalog.edit), admin_set_reservation_addons, admin_get_order,
--     admin_day_view (+lisäpalvelut ja "valmistele"-yhteenveto per vuoro).
--  7) _change_booking_core: lisäpalvelurivit huomioidaan hinnassa (maksetun tilauksen hintatarkistus, määrien rajaus henkilömäärän muuttuessa).
-- Kaikki uudet funktiot: SECURITY DEFINER + search_path = ''; sisäiset (_*) eivät ole anon/authenticated-käytössä.
-- =====================================================================
begin;
set local search_path = booking, extensions, public;

-- ---------- 1) y-tunnus ----------
-- Muoto 1234567-8 (myös 8 numeroa ilman viivaa ja vanha 6+1-muoto, jolloin eteen lisätään nolla). Tarkistenumero: painot 7,9,10,5,8,4,2;
-- summa mod 11: 0 → 0, 1 → virheellinen, muuten 11 − jäännös.
create or replace function booking._norm_business_id(p_id text)
returns text language plpgsql immutable set search_path = '' as $$
declare s text := regexp_replace(coalesce(p_id, ''), '\s', '', 'g');
begin
  s := regexp_replace(s, '^(FI|fi)(\d{8})$', '\2');                  -- ALV-tunnus FI12345678 → 12345678
  if s ~ '^\d{8}$' then return substr(s, 1, 7) || '-' || substr(s, 8, 1); end if;
  if s ~ '^\d{6}-\d$' then return '0' || s; end if;
  return nullif(s, '');
end $$;

create or replace function booking._business_id_ok(p_id text)
returns boolean language plpgsql immutable set search_path = '' as $$
declare s text := booking._norm_business_id(p_id); w int[] := array[7,9,10,5,8,4,2]; v_sum int := 0; r int; i int;
begin
  if s is null or s !~ '^\d{7}-\d$' then return false; end if;
  for i in 1..7 loop v_sum := v_sum + substr(s, i, 1)::int * w[i]; end loop;
  r := v_sum % 11;
  if r = 1 then return false; end if;
  return (case when r = 0 then 0 else 11 - r end) = substr(s, 9, 1)::int;
end $$;

-- ---------- 2) asiakastyypit ----------
create table booking.customer_kinds (
  code       text primary key check (code ~ '^[a-z][a-z0-9_]{1,30}$'),
  label      text not null,
  label_en   text not null,
  is_company boolean not null default false,       -- true: vaatii yritystiedot (y-tunnus, osoite, yhteyshenkilö) ja laskutustiedot
  active     boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now()
);
comment on table booking.customer_kinds is 'Asiakastyypit (taulupohjainen): private = yksityisasiakas, company = yritysasiakas. Eri asia kuin customers.customer_type (rooli: customer / annual_card).';
insert into booking.customer_kinds(code, label, label_en, is_company, sort_order) values
  ('private', 'Yksityisasiakas', 'Private customer', false, 10),
  ('company', 'Yritysasiakas',   'Business customer', true,  20);

alter table booking.customers
  add column customer_kind     text not null default 'private' references booking.customer_kinds(code),
  add column business_id       text,          -- y-tunnus 1234567-8 (yritysasiakas)
  add column einvoice_address  text,          -- verkkolaskuosoite / OVT-tunnus
  add column einvoice_operator text,          -- verkkolaskuoperaattori / välittäjätunnus
  add column invoice_reference text,          -- oletusviite / tilausnumero laskulle (tilauskohtainen: orders.invoice_reference)
  add constraint customers_business_id_valid check (business_id is null or booking._business_id_ok(business_id)),
  -- uusi yritysasiakas vaatii yrityksen nimen (company) ja y-tunnuksen; Johku-tuonti (external_source) saa olla vajaa
  add constraint customers_company_data check (customer_kind <> 'company' or external_source is not null or (nullif(btrim(company), '') is not null and business_id is not null));
comment on column booking.customers.name is 'Asiakkaan nimi. Yritysasiakkaalla: yhteyshenkilön nimi (email/phone = yhteyshenkilön tiedot).';
comment on column booking.customers.company is 'Yrityksen nimi (yritysasiakas). address/zip/city/country = yrityksen osoite.';
create index customers_business_id_idx on booking.customers(business_id) where business_id is not null;
create index customers_kind_idx on booking.customers(customer_kind);

-- ---------- 3) tilaus: asiakastyyppi + laskutustietojen kuva ----------
alter table booking.orders
  add column customer_kind    text not null default 'private' references booking.customer_kinds(code),
  add column billing          jsonb,          -- yritystilaus: laskutustiedot tilaushetkellä (company, business_id, street, zip, city, country, einvoice_*, contact_*)
  add column invoice_reference text;          -- viite / tilausnumero (yritys)

-- ---------- 4) lisäpalvelut ----------
-- price_gross = hinta SISÄLTÄEN ALV:n (kuten kb.products.price ja order_items.unit_price_gross); vat_rate = ALV-kanta (yleinen 25,5 %).
create table booking.addons (
  id             bigint generated always as identity primary key,
  code           text not null unique check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  name           text not null check (char_length(btrim(name)) between 1 and 200),
  name_en        text,
  description    text,
  description_en text,
  price_gross    numeric(10,2) not null check (price_gross >= 0 and price_gross <= 100000),
  vat_rate       numeric(5,2) not null default 25.5 check (vat_rate in (0, 10, 13.5, 14, 24, 25.5)),
  max_per_person integer check (max_per_person is null or max_per_person between 1 and 20),   -- kpl / henkilö; null = vain yleinen yläraja (99 kpl)
  applies_modes  text[] not null default '{shared,exclusive}' check (cardinality(applies_modes) > 0 and applies_modes <@ array['shared','exclusive']),
  active         boolean not null default true,
  sort_order     integer not null default 100,
  external_source text, external_id text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint addons_ext_pair check ((external_source is null) = (external_id is null))
);
comment on table booking.addons is 'Lisäpalvelut (turvenaamio ja jalkakylpy, saunavihta…). applies_modes: shared = yleinen vuoro, exclusive = yksityisvuoro. Muokkaus: catalog.edit (admin_update_addon).';
create unique index addons_external_uq on booking.addons(external_source, external_id) where external_source is not null;
create trigger addons_updated before update on booking.addons for each row execute function booking.set_updated_at();
do $$ begin perform booking._add_audit('booking.addons'); end $$;

insert into booking.addons(code, name, name_en, description, description_en, price_gross, vat_rate, max_per_person, sort_order) values
  ('turvenaamio_jalkakylpy', 'Turvenaamio ja jalkakylpy', 'Peat mask and foot bath',
   'Lisäpalvelu varaukseen: turvenaamio ja jalkakylpy.', 'Add-on for your booking: peat mask and foot bath.', 15.00, 25.5, 1, 10),
  ('saunavihta', 'Saunavihta', 'Sauna whisk (vihta)',
   'Lisäpalvelu varaukseen: saunavihta.', 'Add-on for your booking: sauna whisk (vihta).', 13.00, 25.5, 1, 20);

alter table booking.order_items drop constraint if exists order_items_kind_check;
alter table booking.order_items
  add constraint order_items_kind_check check (kind in ('reservation','product','gift_card','fee','discount','addon')),
  add column addon_id       bigint references booking.addons(id),
  add column parent_item_id bigint references booking.order_items(id) on delete cascade,   -- lisäpalvelurivi → varausrivi, johon se kuuluu
  add constraint order_items_addon_kind check (addon_id is null or kind = 'addon');
create index order_items_parent_idx on booking.order_items(parent_item_id) where parent_item_id is not null;
create index order_items_addon_idx on booking.order_items(addon_id) where addon_id is not null;

-- RLS + lukuoikeus henkilökunnalle (kirjoitus vain funktioiden kautta); anon ei pääse tauluihin
alter table booking.customer_kinds enable row level security;
alter table booking.addons enable row level security;
revoke all on booking.customer_kinds, booking.addons from public, anon, authenticated;
grant select on booking.customer_kinds, booking.addons to authenticated;
create policy staff_read on booking.customer_kinds for select to authenticated using ((select booking.is_staff()));
create policy staff_read on booking.addons for select to authenticated using ((select booking.is_staff()));

-- ---------- 5) yritystietojen validointi ----------
-- Palauttaa siivotun jsonb:n tai nostaa BK001-virheen. Kentät: company_name, business_id, street, zip, city, country, einvoice_address,
-- einvoice_operator, reference. Verkkolaskuosoite ja välittäjätunnus ovat valinnaisia, mutta vain yhdessä.
create or replace function booking._clean_company(p jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  v_name text := btrim(coalesce(p ->> 'company_name', p ->> 'name', ''));
  v_bid text := booking._norm_business_id(p ->> 'business_id');
  v_street text := btrim(coalesce(p ->> 'street', p ->> 'address', ''));
  v_zip text := btrim(coalesce(p ->> 'zip', ''));
  v_city text := btrim(coalesce(p ->> 'city', ''));
  v_country text := upper(btrim(coalesce(nullif(p ->> 'country', ''), 'FI')));
  v_ei text := upper(regexp_replace(coalesce(p ->> 'einvoice_address', ''), '\s', '', 'g'));
  v_op text := upper(regexp_replace(coalesce(p ->> 'einvoice_operator', ''), '\s', '', 'g'));
  v_ref text := btrim(coalesce(p ->> 'reference', ''));
begin
  if p is null or jsonb_typeof(p) <> 'object' then perform booking._err('invalid_company', 'Anna yrityksen tiedot'); end if;
  if char_length(v_name) < 2 or char_length(v_name) > 200 then perform booking._err('invalid_company_name', 'Anna yrityksen nimi'); end if;
  if v_bid is null or not booking._business_id_ok(v_bid) then perform booking._err('invalid_business_id', 'Tarkista y-tunnus (muoto 1234567-8)'); end if;
  if char_length(v_street) < 2 or char_length(v_street) > 200 then perform booking._err('invalid_address', 'Anna yrityksen katuosoite'); end if;
  if v_country !~ '^[A-Z]{2}$' then perform booking._err('invalid_country', 'Tarkista maa (kaksikirjaiminen koodi, esim. FI)'); end if;
  if (v_country = 'FI' and v_zip !~ '^\d{5}$') or (v_country <> 'FI' and v_zip !~ '^[A-Za-z0-9 -]{2,12}$') then perform booking._err('invalid_zip', 'Tarkista postinumero'); end if;
  if char_length(v_city) < 2 or char_length(v_city) > 100 then perform booking._err('invalid_city', 'Anna postitoimipaikka'); end if;
  if v_ei <> '' and v_ei !~ '^[A-Z0-9]{6,35}$' then perform booking._err('invalid_einvoice_address', 'Tarkista verkkolaskuosoite / OVT-tunnus'); end if;
  if v_op <> '' and v_op !~ '^[A-Z0-9]{3,35}$' then perform booking._err('invalid_einvoice_operator', 'Tarkista verkkolaskuoperaattorin välittäjätunnus'); end if;
  if (v_ei = '') <> (v_op = '') then perform booking._err('einvoice_incomplete', 'Anna sekä verkkolaskuosoite että operaattorin välittäjätunnus (tai kumpikaan)'); end if;
  if char_length(v_ref) > 100 then perform booking._err('invalid_reference', 'Viite on liian pitkä (enintään 100 merkkiä)'); end if;
  return jsonb_build_object('company_name', v_name, 'business_id', v_bid, 'street', v_street, 'zip', v_zip, 'city', v_city, 'country', v_country,
                            'einvoice_address', nullif(v_ei, ''), 'einvoice_operator', nullif(v_op, ''), 'reference', nullif(v_ref, ''));
end $$;

create or replace function booking._valid_email(p text)
returns boolean language sql immutable set search_path = '' as $$
  select p is not null and char_length(p) <= 254 and p ~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$'
$$;

-- ---------- asiakkaan haku/luonti ----------
-- Yksityisasiakas: vain yksityisasiakkaat (customer_kind = 'private') yhdistetään sähköpostilla; yritysasiakasta ei koskaan käytetä yksityisvarauksessa.
create or replace function booking._upsert_customer(
  p_name text, p_email text, p_phone text, p_marketing boolean, p_source text, p_locale text, p_text_version text default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare c booking.customers; v_id bigint;
begin
  select * into c from booking.customers
   where lower(email) = lower(p_email) and anonymized_at is null and customer_kind = 'private' order by id desc limit 1;
  if found then
    update booking.customers set
      phone = coalesce(nullif(phone, ''), p_phone),
      marketing_consent = marketing_consent or coalesce(p_marketing, false),
      marketing_consent_at = case when not marketing_consent and coalesce(p_marketing, false) then now() else marketing_consent_at end,
      marketing_consent_source = case when not marketing_consent and coalesce(p_marketing, false) then p_source else marketing_consent_source end,
      marketing_consent_text_version = case when not marketing_consent and coalesce(p_marketing, false) then p_text_version else marketing_consent_text_version end,
      marketing_unsubscribed_at = case when not marketing_consent and coalesce(p_marketing, false) then null else marketing_unsubscribed_at end
     where id = c.id;
    return c.id;
  end if;
  insert into booking.customers(name, email, phone, language, marketing_consent, marketing_consent_at, marketing_consent_source, marketing_consent_text_version)
  values (p_name, p_email, p_phone, coalesce(p_locale, 'fi'), coalesce(p_marketing, false),
          case when coalesce(p_marketing, false) then now() end,
          case when coalesce(p_marketing, false) then p_source end,
          case when coalesce(p_marketing, false) then p_text_version end)
  returning id into v_id;
  return v_id;
end $$;

-- Yritysasiakas: yhdistetään (y-tunnus + yhteyshenkilön sähköposti); olemassa olevan tietoja ei ylikirjoiteta (vain tyhjät täydennetään).
-- p_company = _clean_company-tulos. Tilauksen laskutustiedot tallennetaan erikseen tilaukselle (_stamp_order_billing).
create or replace function booking._upsert_company_customer(
  p_kind text, p_name text, p_email text, p_phone text, p_company jsonb, p_marketing boolean, p_source text, p_locale text, p_text_version text default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare c booking.customers; v_id bigint; v_consent boolean := coalesce(p_marketing, false);
begin
  if p_email is not null then
    select * into c from booking.customers
     where customer_kind = p_kind and business_id = p_company ->> 'business_id' and lower(email) = lower(p_email) and anonymized_at is null
     order by id desc limit 1;
  end if;
  if found then
    update booking.customers set
      phone = coalesce(nullif(phone, ''), p_phone),
      address = coalesce(nullif(address, ''), p_company ->> 'street'), zip = coalesce(nullif(zip, ''), p_company ->> 'zip'),
      city = coalesce(nullif(city, ''), p_company ->> 'city'),
      einvoice_address = coalesce(einvoice_address, p_company ->> 'einvoice_address'),
      einvoice_operator = coalesce(einvoice_operator, p_company ->> 'einvoice_operator'),
      invoice_reference = coalesce(invoice_reference, p_company ->> 'reference'),
      marketing_consent = marketing_consent or v_consent,
      marketing_consent_at = case when not marketing_consent and v_consent then now() else marketing_consent_at end,
      marketing_consent_source = case when not marketing_consent and v_consent then p_source else marketing_consent_source end,
      marketing_consent_text_version = case when not marketing_consent and v_consent then p_text_version else marketing_consent_text_version end,
      marketing_unsubscribed_at = case when not marketing_consent and v_consent then null else marketing_unsubscribed_at end
     where id = c.id;
    return c.id;
  end if;
  insert into booking.customers(customer_kind, name, email, phone, language, company, business_id, address, zip, city, country,
                                einvoice_address, einvoice_operator, invoice_reference,
                                marketing_consent, marketing_consent_at, marketing_consent_source, marketing_consent_text_version)
  values (p_kind, p_name, p_email, p_phone, coalesce(p_locale, 'fi'), p_company ->> 'company_name', p_company ->> 'business_id',
          p_company ->> 'street', p_company ->> 'zip', p_company ->> 'city', coalesce(p_company ->> 'country', 'FI'),
          p_company ->> 'einvoice_address', p_company ->> 'einvoice_operator', p_company ->> 'reference',
          v_consent, case when v_consent then now() end, case when v_consent then p_source end, case when v_consent then p_text_version end)
  returning id into v_id;
  return v_id;
end $$;

-- Tilauksen asiakastyyppi + laskutustietojen kuva. p_company annettu → käytetään sitä (juuri lähetetyt tiedot), muuten asiakasrivin tietoja.
create or replace function booking._stamp_order_billing(p_order_id bigint, p_customer_id bigint, p_company jsonb default null)
returns void language plpgsql security definer set search_path = '' as $$
declare c booking.customers; k booking.customer_kinds;
begin
  select * into c from booking.customers where id = p_customer_id;
  if not found then return; end if;
  select * into k from booking.customer_kinds where code = c.customer_kind;
  update booking.orders set
    customer_kind = c.customer_kind,
    billing = case when k.is_company then jsonb_build_object(
        'company', coalesce(p_company ->> 'company_name', c.company), 'business_id', coalesce(p_company ->> 'business_id', c.business_id),
        'street', coalesce(p_company ->> 'street', c.address), 'zip', coalesce(p_company ->> 'zip', c.zip), 'city', coalesce(p_company ->> 'city', c.city),
        'country', coalesce(p_company ->> 'country', c.country), 'einvoice_address', coalesce(p_company ->> 'einvoice_address', c.einvoice_address),
        'einvoice_operator', coalesce(p_company ->> 'einvoice_operator', c.einvoice_operator),
        'contact_name', c.name, 'contact_phone', c.phone, 'contact_email', c.email) end,
    invoice_reference = case when k.is_company then coalesce(nullif(p_company ->> 'reference', ''), c.invoice_reference) end
   where id = p_order_id;
end $$;

-- ---------- 6) lisäpalveluiden tilaus ----------
-- Suurin sallittu kappalemäärä: henkilömäärä × max_per_person (ei rajaa kpl/hlö → 99), enintään 99 kpl.
create or replace function booking._addon_limit(p_max_per_person integer, p_persons integer)
returns integer language sql immutable set search_path = '' as $$
  select least(coalesce(p_max_per_person, 99) * greatest(coalesce(p_persons, 1), 1), 99)
$$;

-- Liittää lisäpalvelut varaukseen: p_addons = [{"id":1,"quantity":2} | {"code":"saunavihta","quantity":1}, …]. Rivit tilaukselle (kind='addon',
-- parent_item_id = varausrivi), tilauksen summa kasvaa. Palauttaa lisättyjen rivien yhteissumman (brutto). Virheet BK001.
create or replace function booking._attach_addons(p_reservation_id bigint, p_addons jsonb)
returns numeric language plpgsql security definer set search_path = '' as $$
declare
  r booking.reservations; a booking.addons; e jsonb; v_acc jsonb := '{}'::jsonb; v_key text; v_qty integer; v_total numeric := 0;
  v_idtxt text; v_code text; v_lim integer;
begin
  if p_addons is null or p_addons = 'null'::jsonb then return 0; end if;
  if jsonb_typeof(p_addons) <> 'array' then perform booking._err('invalid_addons', 'Lisäpalvelut väärässä muodossa'); end if;
  if jsonb_array_length(p_addons) = 0 then return 0; end if;
  if jsonb_array_length(p_addons) > 20 then perform booking._err('invalid_addons', 'Liian monta lisäpalvelua'); end if;
  select * into r from booking.reservations where id = p_reservation_id;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;

  for e in select * from jsonb_array_elements(p_addons) loop
    if jsonb_typeof(e) <> 'object' then perform booking._err('invalid_addons', 'Lisäpalvelut väärässä muodossa'); end if;
    v_idtxt := e ->> 'id'; v_code := e ->> 'code';
    if coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' then perform booking._err('addon_quantity', 'Lisäpalvelun määrän pitää olla kokonaisluku'); end if;
    v_qty := (e ->> 'quantity')::int;
    if v_idtxt is not null and v_idtxt !~ '^\d{1,18}$' then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
    select * into a from booking.addons where (v_idtxt is not null and id = v_idtxt::bigint) or (v_idtxt is null and v_code is not null and code = v_code);
    if not found then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
    v_acc := jsonb_set(v_acc, array[a.id::text], to_jsonb(coalesce((v_acc ->> a.id::text)::int, 0) + v_qty));
  end loop;

  for v_key, v_qty in select k, (v_acc ->> k)::int from jsonb_object_keys(v_acc) k order by k::bigint loop
    continue when v_qty = 0;
    select * into a from booking.addons where id = v_key::bigint;
    if not a.active then perform booking._err('addon_inactive', format('Lisäpalvelu "%s" ei ole käytössä', a.name)); end if;
    if not (r.mode = any (a.applies_modes)) then perform booking._err('addon_not_allowed', format('Lisäpalvelu "%s" ei ole saatavilla tälle vuorolle', a.name)); end if;
    v_lim := booking._addon_limit(a.max_per_person, r.persons);
    if v_qty > v_lim then perform booking._err('addon_quantity', format('Lisäpalvelua "%s" voi valita enintään %s kpl', a.name, v_lim)); end if;
    insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, addon_id, parent_item_id, price_breakdown)
    values (r.order_id, a.name, 'addon', v_qty, a.price_gross, a.price_gross * v_qty, a.vat_rate, a.id, r.order_item_id,
            jsonb_build_object('addon_code', a.code, 'name_en', a.name_en, 'unit_price', a.price_gross, 'quantity', v_qty, 'max_per_person', a.max_per_person));
    v_total := v_total + a.price_gross * v_qty;
  end loop;
  if v_total > 0 then update booking.orders set total_gross = total_gross + v_total where id = r.order_id; end if;
  return v_total;
end $$;

-- Lisäpalvelurivien yhteissumma, jos varauksen henkilömäärä olisi p_persons (määrät rajataan uuteen rajaan)
create or replace function booking._addon_total_after(p_item_id bigint, p_persons integer)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(sum(it.unit_price_gross * least(it.quantity, booking._addon_limit(a.max_per_person, p_persons))), 0)
    from booking.order_items it join booking.addons a on a.id = it.addon_id
   where it.parent_item_id = p_item_id and it.kind = 'addon'
$$;

-- Rajaa lisäpalvelurivien määrät henkilömäärän mukaan (henkilömäärän pienentyessä)
create or replace function booking._clamp_addons(p_item_id bigint, p_persons integer)
returns void language plpgsql security definer set search_path = '' as $$
declare q record; v_lim integer;
begin
  for q in select it.id, it.quantity, it.unit_price_gross, a.max_per_person from booking.order_items it join booking.addons a on a.id = it.addon_id
            where it.parent_item_id = p_item_id and it.kind = 'addon' loop
    v_lim := booking._addon_limit(q.max_per_person, p_persons);
    if q.quantity > v_lim then
      update booking.order_items set quantity = v_lim, line_total_gross = q.unit_price_gross * v_lim,
             price_breakdown = coalesce(price_breakdown, '{}'::jsonb) || jsonb_build_object('quantity', v_lim, 'clamped_from', q.quantity)
       where id = q.id;
    end if;
  end loop;
end $$;

-- ---------- 7) varauksen muutos: lisäpalvelut mukaan hintaan (korvaa migraation 05 version) ----------
create or replace function booking._change_booking_core(
  p_reservation_id bigint, p_rule_id bigint, p_date date, p_persons integer,
  p_enforce_deadline boolean, p_notice_hours integer, p_actor uuid, p_via text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  res booking.reservations; o booking.orders; rs record; pr record; v_keep boolean := (p_rule_id is null and p_date is null);
  v_persons integer; v_rule bigint; v_total numeric; v_paid numeric; v_old booking.reservations; v_addons numeric; v_order_total numeric;
begin
  if (p_rule_id is null) <> (p_date is null) then perform booking._err('invalid_change', 'Anna sekä uusi vuoro että päivä, tai kumpikaan'); end if;
  select * into res from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  select * into o from booking.orders where id = res.order_id;
  if res.status <> 'confirmed' or o.status <> 'confirmed' then
    perform booking._err('not_changeable', 'Vain vahvistettua varausta voi muuttaa');
  end if;
  if p_notice_hours is not null and res.starts_at - make_interval(hours => p_notice_hours) < now() then
    perform booking._err('change_too_late', format('Varausta voi muuttaa itse viimeistään %s tuntia ennen vuoron alkua – ota yhteyttä sähköpostitse', p_notice_hours));
  end if;
  v_old := res;
  v_persons := coalesce(p_persons, res.persons);
  v_rule := coalesce(p_rule_id, res.rule_id);

  if v_keep then   -- vain henkilömäärä: aika, tila ja poolit säilyvät
    select * into rs from booking._resolve_session(v_rule, null, v_persons, false, res.starts_at, res.ends_at, true);
  else
    select * into rs from booking._resolve_session(v_rule, p_date, v_persons, p_enforce_deadline);
  end if;
  if rs.o_product_id is distinct from res.product_id then
    perform booking._err('product_mismatch', 'Varauksen voi siirtää vain saman tuotteen toiseen vuoroon');
  end if;
  if p_notice_hours is not null and rs.o_starts_at - make_interval(hours => p_notice_hours) < now() then
    perform booking._err('change_too_late', format('Uuden vuoron pitää alkaa vähintään %s tuntia päästä', p_notice_hours));
  end if;

  select * into pr from booking._rule_price(v_rule, v_persons);
  v_total := case when res.annual_card_id is not null then 0 else pr.total end;
  v_addons := booking._addon_total_after(res.order_item_id, v_persons);   -- lisäpalvelut uudella henkilömäärällä (määrät rajataan)
  select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded')), 0) into v_paid from booking.payments where order_id = o.id;
  if p_notice_hours is not null and v_paid > 0 and (v_total + v_addons) is distinct from o.total_gross then
    perform booking._err('price_change_requires_staff', 'Maksettu varaus, jonka hinta muuttuisi: ota yhteyttä henkilökuntaan');
  end if;

  -- trigger reservations_validate tarkistaa kaiken (lukko, päällekkäisyys, kapasiteetti, sulku, vuosikortti)
  update booking.reservations set rule_id = v_rule, space_id = rs.o_space_id, mode = rs.o_mode, starts_at = rs.o_starts_at,
         ends_at = rs.o_ends_at, persons = v_persons, pool_ids = rs.o_pool_ids
   where id = res.id returning * into res;

  update booking.order_items set unit_price_gross = v_total, line_total_gross = v_total,
         price_breakdown = pr.breakdown || jsonb_build_object('rule_id', v_rule, 'rule_label', (select label from booking.schedule_rules where id = v_rule))
   where id = res.order_item_id;
  perform booking._clamp_addons(res.order_item_id, v_persons);
  update booking.orders set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = o.id), 0) where id = o.id
    returning total_gross into v_order_total;
  update booking.payments set amount = v_order_total where order_id = o.id and status = 'pending' and provider = 'manual';
  perform booking._refresh_order_payment(o.id);

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (p_actor, booking._jwt_role(), 'reservations', res.id::text, p_via, to_jsonb(v_old), to_jsonb(res));

  return jsonb_build_object('reservation_id', res.id, 'order_id', o.id, 'order_no', o.order_no, 'starts_at', res.starts_at, 'ends_at', res.ends_at,
                            'persons', res.persons, 'total', v_order_total, 'rule_id', v_rule, 'product_id', res.product_id);
end $$;

-- ---------- 8) JULKINEN rajapinta ----------
-- Lisäpalvelut kauppaan (vain aktiiviset; ei sisäisiä kenttiä)
create or replace function booking.public_addons()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'code', a.code, 'name', a.name, 'name_en', a.name_en, 'description', a.description, 'description_en', a.description_en,
      'price', a.price_gross, 'vat_rate', a.vat_rate, 'max_per_person', a.max_per_person, 'applies_modes', a.applies_modes
    ) order by a.sort_order, a.id), '[]'::jsonb)
  from booking.addons a where a.active
$$;

-- Uusi allekirjoitus (lisäparametrit lopussa, oletusarvot → vanhat kutsut toimivat sellaisenaan):
--   p_customer_kind 'private' | 'company' (taulu customer_kinds); yritykselle p_name/p_email/p_phone = YHTEYSHENKILÖ,
--   p_company = {company_name, business_id, street, zip, city, country?, einvoice_address?, einvoice_operator?, reference?}
--   p_addons  = [{"id":1,"quantity":2}, …] (määrä ≤ henkilömäärä × lisäpalvelun max_per_person; ks. _attach_addons)
drop function booking.public_create_booking(bigint, date, integer, text, text, text, boolean, text, text);
create function booking.public_create_booking(
  p_rule_id bigint, p_date date, p_persons integer,
  p_name text, p_email text, p_phone text,
  p_marketing_consent boolean default false, p_locale text default 'fi', p_note text default null,
  p_customer_kind text default 'private', p_company jsonb default null, p_addons jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}';
  v_ip text := booking._client_ip();
  v_cust bigint; v_res jsonb; v_status text; v_pay_method text; v_pay_provider text;
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_detail text; v_msg text;
  v_hold int := (booking._setting('hold_minutes', '15'::jsonb) #>> '{}')::int;
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private'))); v_is_company boolean; v_company jsonb; v_add numeric; v_total numeric;
begin
  if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
    return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
  end if;

  -- rate limit (kirjataan myös estetyt yritykset)
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;

  -- syötteiden validointi
  select k.is_company into v_is_company from booking.customer_kinds k where k.code = v_kind and k.active;
  if v_is_company is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_customer_kind', 'message', 'Valitse asiakastyyppi (yksityinen / yritys)');
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', case when v_is_company then 'Anna yhteyshenkilön nimi' else 'Anna nimi' end);
  end if;
  if not booking._valid_email(v_email) then
    return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite');
  end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero');
  end if;
  if p_persons is null or p_persons < 1 or p_persons > 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_persons', 'message', 'Tarkista henkilömäärä');
  end if;
  if p_note is not null and char_length(p_note) > 1000 then
    return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä');
  end if;
  if p_date is null or p_date < (now() at time zone booking._tz())::date
     or p_date > (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int then
    return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
  end if;
  -- rajoita samanaikaisia maksamattomia pitoja / sähköposti
  if (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id
       where lower(c.email) = v_email and o.status = 'pending' and o.created_at > now() - interval '1 hour') >= 3 then
    return jsonb_build_object('ok', false, 'code', 'too_many_pending', 'message', 'Sinulla on jo useita keskeneräisiä varauksia');
  end if;

  v_status := case when v_mode = 'pay_later' then 'confirmed' else 'pending' end;
  v_pay_method := case when v_mode = 'pay_later' then case when v_is_company then 'invoice' else 'pay_later' end else 'visma_pay' end;
  v_pay_provider := case when v_mode = 'pay_later' then 'manual' else 'visma_pay' end;

  begin  -- alitransaktio: virhe kumoaa asiakkaan/tilauksen/varauksen luonnin mutta rate limit -kirjaus säilyy
    if v_is_company then v_company := booking._clean_company(p_company); end if;
    if v_is_company then
      v_cust := booking._upsert_company_customer(v_kind, v_name, v_email, v_phone, v_company, p_marketing_consent, 'web_booking', p_locale,
                                                 (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    else
      v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale,
                                         (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    end if;
    v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, 'web', null, p_locale, p_note,
                                          v_status, v_hold, true);
    perform booking._stamp_order_billing((v_res ->> 'order_id')::bigint, v_cust, v_company);
    v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);
    v_total := (v_res ->> 'total')::numeric + v_add;
    insert into booking.payments(order_id, method, provider, status, amount)
    values ((v_res ->> 'order_id')::bigint, v_pay_method, v_pay_provider, 'pending', v_total);
    update booking.orders set payment_status = case when v_mode = 'pay_later' then 'unpaid' else 'pending' end
     where id = (v_res ->> 'order_id')::bigint;
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;

  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token',
                            'status', v_status, 'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at',
                            'total', v_total, 'addons_total', v_add, 'hold_expires_at', v_res -> 'hold_expires_at',
                            'payment_mode', v_mode, 'payment_url', null, 'product_name', v_res -> 'product_name', 'customer_kind', v_kind);
end $$;

-- Vahvistussivu: items = vain varausrivit; addons = lisäpalvelurivit; ei asiakastietoja (vain etunimi / asiakastyyppi)
create or replace function booking.public_get_booking(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  o booking.orders; res jsonb; adds jsonb; cust text;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  v_conf_n integer; v_conf_start timestamptz;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select split_part(c.name, ' ', 1) into cust from booking.customers c where c.id = o.customer_id;
  select jsonb_agg(jsonb_build_object(
           'product_name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'product_id', r.product_id, 'rule_id', r.rule_id,
           'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'mode', r.mode,
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() then 'expired' else r.status end,
           'hold_expires_at', r.hold_expires_at) order by r.starts_at)
    into res
    from booking.order_items it left join booking.reservations r on r.order_item_id = it.id
   where it.order_id = o.id and it.kind = 'reservation';
  select jsonb_agg(jsonb_build_object('addon_id', it.addon_id, 'name', it.product_name, 'name_en', it.price_breakdown ->> 'name_en',
           'quantity', it.quantity, 'unit_price', it.unit_price_gross, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'max_per_person', ad.max_per_person) order by it.id)
    into adds from booking.order_items it left join booking.addons ad on ad.id = it.addon_id where it.order_id = o.id and it.kind = 'addon';
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status',
           case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) then 'expired' else o.status end,
           'payment_status', o.payment_status, 'total', o.total_gross, 'currency', o.currency, 'created_at', o.created_at,
           'first_name', cust, 'customer_kind', o.customer_kind, 'items', coalesce(res, '[]'::jsonb), 'addons', coalesce(adds, '[]'::jsonb),
           'payment_methods', (select coalesce(jsonb_agg(p.method), '[]'::jsonb) from booking.payments p where p.order_id = o.id),
           'can_change', (o.status = 'confirmed' and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now()),
           'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end,
           'change_hours_before', v_hours);
end $$;

-- ---------- 9) HALLINTA: asiakkaat ----------
-- Uusi asiakas hallinnasta (oikeus customers.manage). p_data: kind ('private'|'company'), name (yritykselle: yhteyshenkilö), email, phone, language, notes,
-- marketing_consent, address/zip/city (yksityinen, valinnainen), company_details (yritys: company_name, business_id, street, zip, city, country?,
-- einvoice_address?, einvoice_operator?, reference?). Vähintään email tai phone vaaditaan. Sama sähköposti (+ y-tunnus yritykselle) → customer_exists.
create or replace function booking.admin_create_customer(p_data jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  allowed text[] := array['kind','name','email','phone','language','notes','marketing_consent','address','zip','city','country','company_details'];
  k text; v_kind text; v_is_company boolean; v_name text; v_email text; v_phone text; v_lang text; v_company jsonb; v_id bigint; v_dup bigint; v_consent boolean;
begin
  perform booking._require_permission('customers.manage');
  if p_data is null or jsonb_typeof(p_data) <> 'object' then perform booking._err('invalid_customer', 'Anna asiakkaan tiedot'); end if;
  for k in select jsonb_object_keys(p_data) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa antaa: ' || k); end if;
  end loop;
  v_kind := lower(btrim(coalesce(nullif(p_data ->> 'kind', ''), 'private')));
  select ck.is_company into v_is_company from booking.customer_kinds ck where ck.code = v_kind and ck.active;
  if v_is_company is null then perform booking._err('invalid_customer_kind', 'Valitse asiakastyyppi (yksityinen / yritys)'); end if;
  v_name := btrim(coalesce(p_data ->> 'name', ''));
  v_email := lower(nullif(btrim(coalesce(p_data ->> 'email', '')), ''));
  v_phone := nullif(btrim(coalesce(p_data ->> 'phone', '')), '');
  v_lang := coalesce(nullif(p_data ->> 'language', ''), 'fi');
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    perform booking._err('invalid_name', case when v_is_company then 'Anna yhteyshenkilön nimi' else 'Anna asiakkaan nimi' end);
  end if;
  if v_email is not null and not booking._valid_email(v_email) then perform booking._err('invalid_email', 'Tarkista sähköpostiosoite'); end if;
  if v_phone is not null and v_phone !~ '^[0-9+()\- ]{6,30}$' then perform booking._err('invalid_phone', 'Tarkista puhelinnumero'); end if;
  if v_email is null and v_phone is null then perform booking._err('contact_required', 'Anna sähköposti tai puhelinnumero'); end if;
  if v_lang not in ('fi','en','sv') then perform booking._err('invalid_language', 'Kieli ei ole sallittu'); end if;
  v_consent := coalesce((p_data ->> 'marketing_consent')::boolean, false);

  if v_is_company then
    v_company := booking._clean_company(p_data -> 'company_details');
    if v_email is not null then
      select id into v_dup from booking.customers where customer_kind = v_kind and business_id = v_company ->> 'business_id' and lower(email) = v_email and anonymized_at is null limit 1;
    end if;
  elsif v_email is not null then
    select id into v_dup from booking.customers where customer_kind = v_kind and lower(email) = v_email and anonymized_at is null limit 1;
  end if;
  if v_dup is not null then perform booking._err('customer_exists', format('Asiakas on jo olemassa (asiakas #%s)', v_dup)); end if;

  insert into booking.customers(customer_kind, name, email, phone, language, notes, company, business_id, address, zip, city, country,
                                einvoice_address, einvoice_operator, invoice_reference,
                                marketing_consent, marketing_consent_at, marketing_consent_source)
  values (v_kind, v_name, v_email, v_phone, v_lang, nullif(btrim(coalesce(p_data ->> 'notes', '')), ''),
          v_company ->> 'company_name', v_company ->> 'business_id',
          case when v_is_company then v_company ->> 'street' else nullif(btrim(coalesce(p_data ->> 'address', '')), '') end,
          case when v_is_company then v_company ->> 'zip' else nullif(btrim(coalesce(p_data ->> 'zip', '')), '') end,
          case when v_is_company then v_company ->> 'city' else nullif(btrim(coalesce(p_data ->> 'city', '')), '') end,
          case when v_is_company then v_company ->> 'country' else coalesce(nullif(upper(btrim(coalesce(p_data ->> 'country', ''))), ''), 'FI') end,
          v_company ->> 'einvoice_address', v_company ->> 'einvoice_operator', v_company ->> 'reference',
          v_consent, case when v_consent then now() end, case when v_consent then 'admin' end)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'customer_kind', v_kind);
end $$;

-- Asiakkaan muokkaus (korvaa migraation 06 version): + customer_kind, business_id, einvoice_address, einvoice_operator, invoice_reference
create or replace function booking.admin_update_customer(p_id bigint, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  allowed text[] := array['name','email','phone','company','address','zip','city','country','language','notes','marketing_consent',
                          'customer_kind','business_id','einvoice_address','einvoice_operator','invoice_reference'];
  k text; v_consent boolean; c booking.customers; v_bid text; v_ei text; v_op text; v_kind text; v_email text;
begin
  perform booking._require_permission('customers.manage');
  select * into c from booking.customers where id = p_id;
  if not found then perform booking._err('not_found', 'Asiakasta ei löydy'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  if p_patch ? 'name' and char_length(btrim(coalesce(p_patch ->> 'name', ''))) < 1 then perform booking._err('invalid_name', 'Nimi ei voi olla tyhjä'); end if;
  if p_patch ? 'email' then
    v_email := nullif(btrim(coalesce(p_patch ->> 'email', '')), '');
    if v_email is not null and not booking._valid_email(v_email) then perform booking._err('invalid_email', 'Tarkista sähköpostiosoite'); end if;
  end if;
  if p_patch ? 'phone' and nullif(btrim(coalesce(p_patch ->> 'phone', '')), '') is not null and btrim(p_patch ->> 'phone') !~ '^[0-9+()\- ]{6,30}$' then
    perform booking._err('invalid_phone', 'Tarkista puhelinnumero');
  end if;
  if p_patch ? 'customer_kind' then
    v_kind := lower(btrim(coalesce(p_patch ->> 'customer_kind', '')));
    if not exists (select 1 from booking.customer_kinds where code = v_kind and active) then perform booking._err('invalid_customer_kind', 'Asiakastyyppi ei ole sallittu'); end if;
  end if;
  if p_patch ? 'business_id' then
    v_bid := booking._norm_business_id(p_patch ->> 'business_id');
    if v_bid is not null and not booking._business_id_ok(v_bid) then perform booking._err('invalid_business_id', 'Tarkista y-tunnus (muoto 1234567-8)'); end if;
  end if;
  v_ei := case when p_patch ? 'einvoice_address' then upper(regexp_replace(coalesce(p_patch ->> 'einvoice_address', ''), '\s', '', 'g')) else coalesce(c.einvoice_address, '') end;
  v_op := case when p_patch ? 'einvoice_operator' then upper(regexp_replace(coalesce(p_patch ->> 'einvoice_operator', ''), '\s', '', 'g')) else coalesce(c.einvoice_operator, '') end;
  if v_ei <> '' and v_ei !~ '^[A-Z0-9]{6,35}$' then perform booking._err('invalid_einvoice_address', 'Tarkista verkkolaskuosoite / OVT-tunnus'); end if;
  if v_op <> '' and v_op !~ '^[A-Z0-9]{3,35}$' then perform booking._err('invalid_einvoice_operator', 'Tarkista verkkolaskuoperaattorin välittäjätunnus'); end if;
  if (v_ei = '') <> (v_op = '') then perform booking._err('einvoice_incomplete', 'Anna sekä verkkolaskuosoite että operaattorin välittäjätunnus (tai kumpikaan)'); end if;
  if p_patch ? 'marketing_consent' then v_consent := (p_patch ->> 'marketing_consent')::boolean; end if;
  begin
    update booking.customers set
      name = case when p_patch ? 'name' then btrim(p_patch ->> 'name') else name end,
      email = case when p_patch ? 'email' then v_email else email end,
      phone = case when p_patch ? 'phone' then nullif(btrim(p_patch ->> 'phone'), '') else phone end,
      company = case when p_patch ? 'company' then nullif(btrim(p_patch ->> 'company'), '') else company end,
      address = case when p_patch ? 'address' then p_patch ->> 'address' else address end,
      zip = case when p_patch ? 'zip' then p_patch ->> 'zip' else zip end,
      city = case when p_patch ? 'city' then p_patch ->> 'city' else city end,
      country = case when p_patch ? 'country' then p_patch ->> 'country' else country end,
      language = case when p_patch ? 'language' then p_patch ->> 'language' else language end,
      notes = case when p_patch ? 'notes' then p_patch ->> 'notes' else notes end,
      customer_kind = case when p_patch ? 'customer_kind' then v_kind else customer_kind end,
      business_id = case when p_patch ? 'business_id' then v_bid else business_id end,
      einvoice_address = case when p_patch ? 'einvoice_address' then nullif(v_ei, '') else einvoice_address end,
      einvoice_operator = case when p_patch ? 'einvoice_operator' then nullif(v_op, '') else einvoice_operator end,
      invoice_reference = case when p_patch ? 'invoice_reference' then nullif(btrim(coalesce(p_patch ->> 'invoice_reference', '')), '') else invoice_reference end,
      marketing_consent = coalesce(v_consent, marketing_consent),
      marketing_consent_at = case when v_consent is distinct from marketing_consent and v_consent is not null then now() else marketing_consent_at end,
      marketing_consent_source = case when v_consent is distinct from marketing_consent and v_consent is not null then 'admin' else marketing_consent_source end,
      marketing_unsubscribed_at = case when v_consent is false and marketing_consent then now() else marketing_unsubscribed_at end
     where id = p_id;
  exception when check_violation then
    perform booking._err('invalid_company', 'Yritysasiakkaalla pitää olla yrityksen nimi ja kelvollinen y-tunnus');
  end;
  return jsonb_build_object('ok', true);
end $$;

-- Asiakaslista (korvaa migraation 06 version): + customer_kind, business_id; haku myös y-tunnuksella
drop function booking.admin_list_customers(text, integer, integer);
create function booking.admin_list_customers(p_search text default null, p_limit integer default 50, p_offset integer default 0)
returns table (
  id bigint, name text, email text, phone text, company text, city text, marketing_consent boolean,
  marketing_consent_at timestamptz, created_at timestamptz, orders_count bigint, last_visit timestamptz, total_count bigint,
  customer_type text, customer_kind text, business_id text)
language plpgsql stable security definer set search_path = '' as $$
declare q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform booking._require_staff();
  return query
    select c.id, c.name, c.email, c.phone, c.company, c.city, c.marketing_consent, c.marketing_consent_at, c.created_at,
           (select count(*) from booking.orders o where o.customer_id = c.id and o.status in ('pending','confirmed','completed')),
           (select max(r.starts_at) from booking.reservations r join booking.orders o on o.id = r.order_id
             where o.customer_id = c.id and r.status in ('confirmed','completed')),
           count(*) over (), c.customer_type, c.customer_kind, c.business_id
      from booking.customers c
     where c.anonymized_at is null
       and (q is null or c.name ilike '%' || q || '%' or c.email ilike '%' || q || '%' or c.phone ilike '%' || q || '%' or c.company ilike '%' || q || '%'
            or c.business_id ilike '%' || q || '%')
     order by c.created_at desc, c.id desc
     limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0);
end $$;

-- ---------- 10) HALLINTA: varauksen luonti (korvaa migraation 06 version; lisäparametrit lopussa) ----------
-- p_customer (uusi asiakas): {kind?, name, email?, phone?, language?, marketing_consent?, company? (yksityisen yrityskenttä, teksti), company_details? (yritysasiakas)}
-- p_addons: [{"id":1,"quantity":2}, …]; p_invoice_reference: yritystilauksen viite / tilausnumero.
drop function booking.admin_create_booking(bigint, date, integer, bigint, jsonb, text, boolean, text, timestamptz, timestamptz, numeric, text);
create function booking.admin_create_booking(
  p_rule_id bigint, p_date date, p_persons integer,
  p_customer_id bigint default null, p_customer jsonb default null,
  p_payment_method text default 'pay_later', p_paid boolean default false,
  p_note text default null, p_start timestamptz default null, p_end timestamptz default null,
  p_price numeric default null, p_channel text default 'admin',
  p_addons jsonb default null, p_invoice_reference text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_cust bigint := p_customer_id; v_res jsonb; v_email text; v_order bigint; v_pm booking.payment_methods;
  v_kind text; v_is_company boolean; v_company jsonb; v_add numeric; v_total numeric; v_consent boolean; v_ref text := nullif(btrim(coalesce(p_invoice_reference, '')), '');
begin
  perform booking._require_permission('bookings.manage');
  select * into v_pm from booking.payment_methods where code = p_payment_method and active;
  if not found then perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä'); end if;
  if p_channel not in ('admin','phone','email','walk_in','other') then perform booking._err('invalid_channel', 'Virheellinen lähdekanava'); end if;
  if p_price is not null and p_price < 0 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  if v_ref is not null and char_length(v_ref) > 100 then perform booking._err('invalid_reference', 'Viite on liian pitkä (enintään 100 merkkiä)'); end if;
  if v_cust is null then
    if p_customer is null or char_length(btrim(coalesce(p_customer ->> 'name', ''))) < 2 then
      perform booking._err('customer_required', 'Valitse asiakas tai anna nimi');
    end if;
    v_kind := lower(btrim(coalesce(nullif(p_customer ->> 'kind', ''), 'private')));
    select ck.is_company into v_is_company from booking.customer_kinds ck where ck.code = v_kind and ck.active;
    if v_is_company is null then perform booking._err('invalid_customer_kind', 'Valitse asiakastyyppi (yksityinen / yritys)'); end if;
    v_email := lower(nullif(btrim(coalesce(p_customer ->> 'email', '')), ''));
    if v_email is not null and not booking._valid_email(v_email) then perform booking._err('invalid_email', 'Tarkista sähköpostiosoite'); end if;
    v_consent := coalesce((p_customer ->> 'marketing_consent')::boolean, false);
    if v_is_company then
      v_company := booking._clean_company(p_customer -> 'company_details');
      v_cust := booking._upsert_company_customer(v_kind, btrim(p_customer ->> 'name'), v_email, nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''),
                  v_company, v_consent, 'admin', coalesce(p_customer ->> 'language', 'fi'));
    elsif v_email is not null then
      v_cust := booking._upsert_customer(btrim(p_customer ->> 'name'), v_email, nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''),
                 v_consent, 'admin', coalesce(p_customer ->> 'language', 'fi'));
    else
      insert into booking.customers(name, phone, company, language, marketing_consent, marketing_consent_at, marketing_consent_source)
      values (btrim(p_customer ->> 'name'), nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''), nullif(btrim(coalesce(p_customer ->> 'company', '')), ''),
              coalesce(p_customer ->> 'language', 'fi'), v_consent,
              case when v_consent then now() end, case when v_consent then 'admin' end)
      returning id into v_cust;
    end if;
  elsif not exists (select 1 from booking.customers where id = v_cust) then
    perform booking._err('customer_not_found', 'Asiakasta ei löydy');
  end if;

  v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, p_channel, auth.uid(), 'fi', p_note,
                                        'confirmed', null, false, p_start, p_end, p_price);
  v_order := (v_res ->> 'order_id')::bigint;
  perform booking._stamp_order_billing(v_order, v_cust, v_company);
  if v_ref is not null then update booking.orders set invoice_reference = v_ref where id = v_order and customer_kind <> 'private'; end if;
  v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);
  v_total := (v_res ->> 'total')::numeric + v_add;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at, created_by)
  values (v_order, p_payment_method, 'manual', case when p_paid then 'paid' else 'pending' end, v_total,
          case when p_paid then now() end, auth.uid());
  update booking.orders set payment_status = case when p_paid then 'paid' else 'unpaid' end where id = v_order;
  return v_res - 'public_token' || jsonb_build_object('customer_id', v_cust, 'total', v_total, 'addons_total', v_add);
end $$;

-- Lisäpalveluiden korvaus olemassa olevalla varauksella (bookings.manage): poistaa varauksen lisäpalvelurivit ja liittää annetut uudelleen.
create or replace function booking.admin_set_reservation_addons(p_reservation_id bigint, p_addons jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare res booking.reservations; v_old jsonb; v_total numeric;
begin
  perform booking._require_permission('bookings.manage');
  select * into res from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if res.status not in ('pending','confirmed') then perform booking._err('not_editable', 'Lisäpalveluita voi muuttaa vain voimassa olevaan varaukseen'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('addon_id', addon_id, 'name', product_name, 'quantity', quantity) order by id), '[]'::jsonb)
    into v_old from booking.order_items where parent_item_id = res.order_item_id and kind = 'addon';
  delete from booking.order_items where parent_item_id = res.order_item_id and kind = 'addon';
  update booking.orders set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = res.order_id), 0) where id = res.order_id;
  perform booking._attach_addons(res.id, p_addons);
  select total_gross into v_total from booking.orders where id = res.order_id;
  update booking.payments set amount = v_total where order_id = res.order_id and status = 'pending' and provider = 'manual';
  perform booking._refresh_order_payment(res.order_id);
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'order_items', res.order_id::text, 'ADMIN_SET_ADDONS', jsonb_build_object('addons', v_old),
          jsonb_build_object('addons', coalesce(p_addons, '[]'::jsonb), 'total', v_total));
  return jsonb_build_object('ok', true, 'total', v_total);
end $$;

-- Varauksen / tilauksen tiedot hallinnan katseluun (asiakas + laskutustiedot + rivit + lisäpalvelut + maksut)
create or replace function booking.admin_get_order(p_order_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o booking.orders; c booking.customers;
begin
  perform booking._require_staff();
  select * into o from booking.orders where id = p_order_id;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  select * into c from booking.customers where id = o.customer_id;
  return jsonb_build_object(
    'order_id', o.id, 'order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status, 'total', o.total_gross,
    'source_channel', o.source_channel, 'created_at', o.created_at, 'customer_note', o.customer_note, 'internal_note', o.internal_note,
    'customer_kind', o.customer_kind, 'billing', o.billing, 'invoice_reference', o.invoice_reference,
    'customer', case when c.id is null then null else jsonb_build_object('id', c.id, 'name', c.name, 'email', c.email, 'phone', c.phone,
        'company', c.company, 'customer_kind', c.customer_kind, 'business_id', c.business_id) end,
    'reservations', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status, 'product_name', it.product_name, 'mode', r.mode,
        'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'notes', r.notes, 'item_total', it.line_total_gross,
        'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', ai.addon_id, 'name', ai.product_name, 'quantity', ai.quantity,
                     'unit_price', ai.unit_price_gross, 'line_total', ai.line_total_gross, 'vat_rate', ai.vat_rate) order by ai.id)
                   from booking.order_items ai where ai.parent_item_id = r.order_item_id and ai.kind = 'addon'), '[]'::jsonb)) order by r.starts_at)
        from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'method', p.method, 'status', p.status, 'amount', p.amount, 'paid_at', p.paid_at) order by p.id)
        from booking.payments p where p.order_id = o.id), '[]'::jsonb));
end $$;

-- Päivänäkymä (korvaa migraation 06 version): varauksiin lisäpalvelut + asiakastyyppi; 'prep' = valmisteltavat lisäpalvelut per vuoro, 'addon_totals' = päivän summat
create or replace function booking.admin_day_view(p_date date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_from timestamptz := p_date::timestamp at time zone 'Europe/Helsinki';
        v_to timestamptz := (p_date + 1)::timestamp at time zone 'Europe/Helsinki';
        v_prep jsonb; v_totals jsonb;
begin
  perform booking._require_staff();
  with rs as (
    select r.rule_id, r.starts_at, r.ends_at, r.order_item_id, coalesce(it.product_name, '') as product_name
      from booking.reservations r left join booking.order_items it on it.id = r.order_item_id
     where r.starts_at < v_to and r.ends_at > v_from and booking._res_active(r.status, r.hold_expires_at)),
  per as (
    select rs.rule_id, rs.starts_at, rs.ends_at, rs.product_name, ai.addon_id, min(ai.product_name) as name, sum(ai.quantity)::int as qty
      from rs join booking.order_items ai on ai.parent_item_id = rs.order_item_id and ai.kind = 'addon'
     group by rs.rule_id, rs.starts_at, rs.ends_at, rs.product_name, ai.addon_id),
  grp as (
    select rule_id, starts_at, ends_at, product_name,
           jsonb_agg(jsonb_build_object('addon_id', addon_id, 'name', name, 'quantity', qty) order by name) as items
      from per group by rule_id, starts_at, ends_at, product_name)
  select (select coalesce(jsonb_agg(jsonb_build_object('rule_id', g.rule_id, 'starts_at', g.starts_at, 'ends_at', g.ends_at,
                    'product_name', g.product_name, 'items', g.items) order by g.starts_at, g.rule_id), '[]'::jsonb) from grp g),
         (select coalesce(jsonb_agg(jsonb_build_object('addon_id', t.addon_id, 'name', t.name, 'quantity', t.qty) order by t.name), '[]'::jsonb)
            from (select addon_id, min(name) as name, sum(qty)::int as qty from per group by addon_id) t)
    into v_prep, v_totals;
  return jsonb_build_object(
    'date', p_date,
    'sessions', coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at, s.rule_id)
                           from booking._sessions(p_date, p_date, null, false) s), '[]'::jsonb),
    'reservations', coalesce((select jsonb_agg(jsonb_build_object(
        'reservation_id', r.id, 'order_id', o.id, 'order_no', o.order_no, 'status', r.status, 'payment_status', o.payment_status,
        'product_name', coalesce(it.product_name, p.name), 'mode', r.mode, 'starts_at', r.starts_at, 'ends_at', r.ends_at,
        'persons', r.persons, 'customer_name', c.name, 'customer_phone', c.phone, 'rule_id', r.rule_id, 'notes', r.notes,
        'annual_card', r.annual_card_id is not null, 'hold_expires_at', r.hold_expires_at,
        'customer_kind', o.customer_kind, 'company', case when o.customer_kind <> 'private' then coalesce(o.billing ->> 'company', c.company) end,
        'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', ai.addon_id, 'name', ai.product_name, 'quantity', ai.quantity) order by ai.id)
                              from booking.order_items ai where ai.parent_item_id = r.order_item_id and ai.kind = 'addon'), '[]'::jsonb))
        order by r.starts_at, r.id)
        from booking.reservations r join booking.orders o on o.id = r.order_id
        left join booking.order_items it on it.id = r.order_item_id left join kb.products p on p.id = r.product_id
        left join booking.customers c on c.id = o.customer_id
        where r.starts_at < v_to and r.ends_at > v_from and booking._res_active(r.status, r.hold_expires_at)), '[]'::jsonb),
    'prep', v_prep, 'addon_totals', v_totals,
    'blocks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'space_id', b.space_id, 'starts_at', b.starts_at,
        'ends_at', b.ends_at, 'reason', b.reason) order by b.starts_at)
        from booking.space_blocks b where b.active and b.starts_at < v_to and b.ends_at > v_from), '[]'::jsonb));
end $$;

-- ---------- 11) HALLINTA: lisäpalveluiden ylläpito (oikeus catalog.edit; luku: kaikki henkilökunta) ----------
create or replace function booking.admin_list_addons()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_staff();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', a.id, 'code', a.code, 'name', a.name, 'name_en', a.name_en, 'description', a.description, 'description_en', a.description_en,
      'price', a.price_gross, 'vat_rate', a.vat_rate, 'max_per_person', a.max_per_person, 'applies_modes', a.applies_modes,
      'active', a.active, 'sort_order', a.sort_order, 'updated_at', a.updated_at) order by a.sort_order, a.id) from booking.addons a), '[]'::jsonb);
end $$;

create or replace function booking.admin_create_addon(p_data jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  allowed text[] := array['code','name','name_en','description','description_en','price','vat_rate','max_per_person','applies_modes','active','sort_order'];
  k text; v_price numeric; v_vat numeric; v_max integer; v_modes text[]; v_id bigint; v_sort integer;
begin
  perform booking._require_permission('catalog.edit');
  if p_data is null or jsonb_typeof(p_data) <> 'object' then perform booking._err('invalid_addon', 'Anna lisäpalvelun tiedot'); end if;
  for k in select jsonb_object_keys(p_data) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa antaa: ' || k); end if;
  end loop;
  if coalesce(p_data ->> 'code', '') !~ '^[a-z][a-z0-9_]{1,40}$' then perform booking._err('invalid_code', 'Tunnus: pienet kirjaimet, numerot ja alaviiva (alkaa kirjaimella)'); end if;
  if exists (select 1 from booking.addons where code = p_data ->> 'code') then perform booking._err('code_exists', 'Tunnus on jo käytössä'); end if;
  if char_length(btrim(coalesce(p_data ->> 'name', ''))) = 0 or char_length(p_data ->> 'name') > 200 then perform booking._err('invalid_name', 'Anna nimi'); end if;
  if coalesce(p_data ->> 'price', '') !~ '^\d{1,6}([.,]\d{1,2})?$' then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  v_price := replace(p_data ->> 'price', ',', '.')::numeric;
  v_vat := case when coalesce(p_data ->> 'vat_rate', '') ~ '^\d{1,2}([.,]\d)?$' then replace(p_data ->> 'vat_rate', ',', '.')::numeric when p_data ? 'vat_rate' then -1 else 25.5 end;
  if v_vat not in (0, 10, 13.5, 14, 24, 25.5) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu (0, 10, 13.5, 14, 24, 25.5)'); end if;
  if p_data ? 'max_per_person' and nullif(p_data ->> 'max_per_person', '') is not null then
    if p_data ->> 'max_per_person' !~ '^\d{1,2}$' or (p_data ->> 'max_per_person')::int not between 1 and 20 then perform booking._err('invalid_max', 'Enimmäismäärä / henkilö: 1–20'); end if;
    v_max := (p_data ->> 'max_per_person')::int;
  end if;
  if p_data ? 'applies_modes' then
    if jsonb_typeof(p_data -> 'applies_modes') <> 'array' then perform booking._err('invalid_modes', 'Vuorotyypit virheellisessä muodossa'); end if;
    select array_agg(distinct x) into v_modes from jsonb_array_elements_text(p_data -> 'applies_modes') x;
    if v_modes is null or not (v_modes <@ array['shared','exclusive']) then perform booking._err('invalid_modes', 'Vuorotyyppi: shared (yleinen) ja/tai exclusive (yksityinen)'); end if;
  end if;
  v_sort := case when coalesce(p_data ->> 'sort_order', '') ~ '^\d{1,5}$' then (p_data ->> 'sort_order')::int else 100 end;
  insert into booking.addons(code, name, name_en, description, description_en, price_gross, vat_rate, max_per_person, applies_modes, active, sort_order)
  values (p_data ->> 'code', btrim(p_data ->> 'name'), nullif(btrim(coalesce(p_data ->> 'name_en', '')), ''), nullif(p_data ->> 'description', ''),
          nullif(p_data ->> 'description_en', ''), v_price, v_vat, v_max, coalesce(v_modes, '{shared,exclusive}'),
          coalesce((p_data ->> 'active')::boolean, true), v_sort)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function booking.admin_update_addon(p_id bigint, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  allowed text[] := array['name','name_en','description','description_en','price','vat_rate','max_per_person','applies_modes','active','sort_order'];
  k text; v_price numeric; v_vat numeric; v_max integer; v_modes text[];
begin
  perform booking._require_permission('catalog.edit');
  if not exists (select 1 from booking.addons where id = p_id) then perform booking._err('not_found', 'Lisäpalvelua ei löydy'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  if p_patch ? 'name' and (char_length(btrim(coalesce(p_patch ->> 'name', ''))) = 0 or char_length(p_patch ->> 'name') > 200) then perform booking._err('invalid_name', 'Nimi ei voi olla tyhjä'); end if;
  if p_patch ? 'price' then
    if coalesce(p_patch ->> 'price', '') !~ '^\d{1,6}([.,]\d{1,2})?$' then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
    v_price := replace(p_patch ->> 'price', ',', '.')::numeric;
  end if;
  if p_patch ? 'vat_rate' then
    v_vat := case when coalesce(p_patch ->> 'vat_rate', '') ~ '^\d{1,2}([.,]\d)?$' then replace(p_patch ->> 'vat_rate', ',', '.')::numeric else -1 end;
    if v_vat not in (0, 10, 13.5, 14, 24, 25.5) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu (0, 10, 13.5, 14, 24, 25.5)'); end if;
  end if;
  if p_patch ? 'max_per_person' and nullif(p_patch ->> 'max_per_person', '') is not null then
    if p_patch ->> 'max_per_person' !~ '^\d{1,2}$' or (p_patch ->> 'max_per_person')::int not between 1 and 20 then perform booking._err('invalid_max', 'Enimmäismäärä / henkilö: 1–20'); end if;
    v_max := (p_patch ->> 'max_per_person')::int;
  end if;
  if p_patch ? 'applies_modes' then
    if jsonb_typeof(p_patch -> 'applies_modes') <> 'array' then perform booking._err('invalid_modes', 'Vuorotyypit virheellisessä muodossa'); end if;
    select array_agg(distinct x) into v_modes from jsonb_array_elements_text(p_patch -> 'applies_modes') x;
    if v_modes is null or not (v_modes <@ array['shared','exclusive']) then perform booking._err('invalid_modes', 'Vuorotyyppi: shared (yleinen) ja/tai exclusive (yksityinen)'); end if;
  end if;
  if p_patch ? 'sort_order' and coalesce(p_patch ->> 'sort_order', '') !~ '^\d{1,5}$' then perform booking._err('invalid_sort', 'Virheellinen järjestys'); end if;
  update booking.addons set
    name = case when p_patch ? 'name' then btrim(p_patch ->> 'name') else name end,
    name_en = case when p_patch ? 'name_en' then nullif(btrim(coalesce(p_patch ->> 'name_en', '')), '') else name_en end,
    description = case when p_patch ? 'description' then nullif(p_patch ->> 'description', '') else description end,
    description_en = case when p_patch ? 'description_en' then nullif(p_patch ->> 'description_en', '') else description_en end,
    price_gross = case when p_patch ? 'price' then v_price else price_gross end,
    vat_rate = case when p_patch ? 'vat_rate' then v_vat else vat_rate end,
    max_per_person = case when p_patch ? 'max_per_person' then v_max else max_per_person end,
    applies_modes = case when p_patch ? 'applies_modes' then v_modes else applies_modes end,
    active = case when p_patch ? 'active' then (p_patch ->> 'active')::boolean else active end,
    sort_order = case when p_patch ? 'sort_order' then (p_patch ->> 'sort_order')::int else sort_order end
   where id = p_id;
  return jsonb_build_object('ok', true, 'id', p_id);
end $$;

-- ---------- 12) oikeudet ----------
-- Uudet funktiot: oletuksena PUBLIC voi suorittaa → poistetaan ja annetaan vain tarvittaville
revoke all on function
  booking._norm_business_id(text), booking._business_id_ok(text), booking._clean_company(jsonb), booking._valid_email(text),
  booking._upsert_customer(text, text, text, boolean, text, text, text),
  booking._upsert_company_customer(text, text, text, text, jsonb, boolean, text, text, text),
  booking._stamp_order_billing(bigint, bigint, jsonb), booking._addon_limit(integer, integer), booking._attach_addons(bigint, jsonb),
  booking._addon_total_after(bigint, integer), booking._clamp_addons(bigint, integer),
  booking._change_booking_core(bigint, bigint, date, integer, boolean, integer, uuid, text),
  booking.public_addons(), booking.public_create_booking(bigint, date, integer, text, text, text, boolean, text, text, text, jsonb, jsonb),
  booking.public_get_booking(uuid),
  booking.admin_create_customer(jsonb), booking.admin_update_customer(bigint, jsonb), booking.admin_list_customers(text, integer, integer),
  booking.admin_create_booking(bigint, date, integer, bigint, jsonb, text, boolean, text, timestamptz, timestamptz, numeric, text, jsonb, text),
  booking.admin_set_reservation_addons(bigint, jsonb), booking.admin_get_order(bigint), booking.admin_day_view(date),
  booking.admin_list_addons(), booking.admin_create_addon(jsonb), booking.admin_update_addon(bigint, jsonb)
  from public, anon, authenticated;
grant execute on function
  booking.public_addons(),
  booking.public_create_booking(bigint, date, integer, text, text, text, boolean, text, text, text, jsonb, jsonb),
  booking.public_get_booking(uuid)
  to anon, authenticated;
grant execute on function
  booking.admin_create_customer(jsonb), booking.admin_update_customer(bigint, jsonb), booking.admin_list_customers(text, integer, integer),
  booking.admin_create_booking(bigint, date, integer, bigint, jsonb, text, boolean, text, timestamptz, timestamptz, numeric, text, jsonb, text),
  booking.admin_set_reservation_addons(bigint, jsonb), booking.admin_get_order(bigint), booking.admin_day_view(date),
  booking.admin_list_addons(), booking.admin_create_addon(jsonb), booking.admin_update_addon(bigint, jsonb)
  to authenticated;
grant all on all tables in schema booking to service_role;
grant all on all sequences in schema booking to service_role;
grant execute on all functions in schema booking to service_role;

commit;
