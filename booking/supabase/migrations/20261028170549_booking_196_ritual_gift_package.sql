-- booking_196: lahjakorttipaketin henkilömäärä + saunarituaalipaketti.
--
-- Hinnat tarkistettu tuotannosta 28.10.2026 (vain luku), niitä ei muuteta:
--   kb 1 yleinensauna            29 €/hlö, per_person. Yleisen vuoron säännöistä 6/7 on max 6 hlö, yksi 16.
--                                Paketin katto on 6 (tavallinen vuoro; rituaalin katto on sama).
--   lisä turvenaamio_jalkakylpy  15 €/kpl. Turvepaketti = 29+15 = 44 €/hlö. Kahdelle yhä 88 €.
--   kb 7 saunarituaali-ja-savusaunavuoro  49 €/hlö, max 6. Tuote 8 Saunotusrituaali on 20 € eikä ole tämä paketti.
--   kb 10 saunahoito  99 € (sis. 1) + 35 €/lisählö, max 4. Kahdelle: 29×2 + 99 + 35 = 192 € (ennallaan).
--   kb 11 saunotus    210 € (sis. 1) + 60 €/lisählö, max 4. Kahdelle: 29×2 + 210 + 60 = 328 € (ennallaan).
-- Henkilömäärä tallennetaan uudelle kortille (gift_cards.persons) ja tilausrivin price_breakdowniin.
-- Vanhojen korttien initial_amount ja balance eivät muutu (saraketta ei täytetä vanhoille riveille).
-- Lunastus on ennallaan eurosaldo: N hengen kortin arvo = N hengen tuotteiden hinta, joten se kattaa sen varauksen.
-- Jos asiakas ei lähetä henkilömäärää, oletus on paketin persons (2) ja vanha pakettihinta.
-- Migraatiota ei ajeta tästä commitista.

set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table booking.gift_cards add column if not exists persons integer;
alter table booking.gift_cards drop constraint if exists gift_cards_persons_check;
alter table booking.gift_cards add constraint gift_cards_persons_check check (persons is null or persons > 0);

alter table booking.gift_card_packages add column if not exists min_persons integer;
alter table booking.gift_card_packages add column if not exists max_persons integer;
alter table booking.gift_card_packages drop constraint if exists gift_card_packages_persons_range;
alter table booking.gift_card_packages add constraint gift_card_packages_persons_range
  check ((min_persons is null and max_persons is null) or (min_persons >= 1 and max_persons >= min_persons));

create or replace function booking._gc_package_amount(p_items jsonb, p_persons integer) returns numeric
language plpgsql immutable set search_path to '' as $$
declare it jsonb; v numeric := 0; v_type text; v_unit numeric; v_extra numeric; v_inc int; v_any boolean := false;
begin
  if p_persons is null or p_persons < 1 or p_items is null or jsonb_typeof(p_items) <> 'array' then return null; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    if it ->> 'unit_price' is null then return null; end if;
    v_any := true;
    v_type := coalesce(it ->> 'price_type', 'per_person');
    v_unit := (it ->> 'unit_price')::numeric;
    if v_type = 'base_plus_extra' then
      v_extra := coalesce((it ->> 'extra_price')::numeric, 0);
      v_inc := coalesce((it ->> 'included')::int, 1);
      v := v + v_unit + v_extra * greatest(p_persons - v_inc, 0);
    else
      v := v + v_unit * p_persons;
    end if;
  end loop;
  if not v_any then return null; end if;
  return round(v, 2);
end $$;
comment on function booking._gc_package_amount(jsonb, integer) is 'booking_196: paketin hinta henkilömäärälle. per_person = unit×n, base_plus_extra = perushinta + lisä×(n−sisältyvät).';
revoke all on function booking._gc_package_amount(jsonb, integer) from public, anon, authenticated;

create or replace function booking._gc_quote(p_pkg booking.gift_card_packages, p_it jsonb) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare v_persons int; v_amt numeric; v_sent numeric;
begin
  if p_pkg.is_open then
    return jsonb_build_object('amount', (p_it ->> 'amount')::numeric, 'persons', null);
  end if;
  if p_it ? 'persons' and jsonb_typeof(p_it -> 'persons') <> 'null' then
    if (p_it ->> 'persons') !~ '^\d{1,2}$' then perform booking._err('invalid_persons', 'Virheellinen henkilömäärä'); end if;
    v_persons := (p_it ->> 'persons')::int;
  else
    v_persons := p_pkg.persons;
  end if;
  if v_persons is null or v_persons < coalesce(p_pkg.min_persons, 1)
     or (p_pkg.max_persons is not null and v_persons > p_pkg.max_persons) then
    perform booking._err('invalid_persons', format('Henkilömäärä %s–%s', coalesce(p_pkg.min_persons, 1), coalesce(p_pkg.max_persons, p_pkg.persons)));
  end if;
  v_amt := booking._gc_package_amount(p_pkg.items, v_persons);
  if v_amt is null then
    if v_persons is not distinct from p_pkg.persons then v_amt := p_pkg.price;
    else perform booking._err('invalid_persons', 'Henkilömäärä ei käy tähän pakettiin'); end if;
  elsif v_persons is not distinct from p_pkg.persons and v_amt is distinct from p_pkg.price then
    perform booking._err('invalid_amount', 'Paketin hinta ei täsmää');
  end if;
  if p_it ? 'amount' and jsonb_typeof(p_it -> 'amount') <> 'null' then
    if (p_it ->> 'amount') !~ '^\d{1,6}(\.\d{1,2})?$' then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
    v_sent := (p_it ->> 'amount')::numeric;
    if v_sent is distinct from v_amt then perform booking._err('invalid_amount', 'Paketin hinta ei täsmää henkilömäärään'); end if;
  end if;
  return jsonb_build_object('amount', v_amt, 'persons', v_persons);
end $$;
revoke all on function booking._gc_quote(booking.gift_card_packages, jsonb) from public, anon, authenticated;

do $m196$
declare
  v7 numeric; v_slug text; v_amt numeric;
  r record;
begin
  if (select price from booking.gift_card_packages where code = 'entry_2') is distinct from 58.00
     or (select price from booking.gift_card_packages where code = 'peat_mask_2') is distinct from 88.00
     or (select price from booking.gift_card_packages where code = 'sauna_treatment_2') is distinct from 192.00
     or (select price from booking.gift_card_packages where code = 'saunotus_2') is distinct from 328.00 then
    raise exception 'booking_196: vanhan paketin hinta ei ole 58/88/192/328. Ei muutoksia.';
  end if;
  select p.price, p.slug into v7, v_slug from kb.products p where p.id = 7;
  if v_slug is distinct from 'saunarituaali-ja-savusaunavuoro' or v7 is distinct from 49.00 then
    raise exception 'booking_196: tuote 7 on % / % € (odotettu saunarituaali-ja-savusaunavuoro / 49.00). Ei arvata. Ei muutoksia.', coalesce(v_slug, 'puuttuu'), coalesce(v7::text, 'null');
  end if;
  if (select price from kb.products where id = 1 and slug = 'yleinensauna') is distinct from 29.00
     or (select price_gross from booking.addons where code = 'turvenaamio_jalkakylpy') is distinct from 15.00
     or (select price from kb.products where id = 10) is distinct from 99.00
     or (select extra_person_price from kb.products where id = 10) is distinct from 35.00
     or (select price from kb.products where id = 11) is distinct from 210.00
     or (select extra_person_price from kb.products where id = 11) is distinct from 60.00
     or (select max_persons from booking.product_config where product_id = 7) is distinct from 6
     or (select max_persons from booking.product_config where product_id = 10) is distinct from 4
     or (select max_persons from booking.product_config where product_id = 11) is distinct from 4 then
    raise exception 'booking_196: tuotteen hinta tai katto ei täsmää tarkistettuun. Ei muutoksia.';
  end if;

  update booking.gift_card_packages set
    name = 'Savusaunavuoro', name_en = 'Smoke sauna session',
    description = 'Yleinen savusaunavuoro.', description_en = 'A public smoke sauna session.',
    min_persons = 1, max_persons = 6,
    items = '[{"label":"Yleinen vuoro","label_en":"General session","kb_product_id":1,"unit_price":29,"price_type":"per_person"}]'::jsonb
  where code = 'entry_2';
  update booking.gift_card_packages set
    name = 'Savusaunaelämys turvenaamiolla ja jalkakylvyllä', name_en = 'Smoke sauna experience with peat mask and foot bath',
    description = 'Yleinen savusaunavuoro sekä omatoiminen turvenaamio ja jalkakylpy.',
    description_en = 'A public smoke sauna session with a self-guided peat mask and foot bath.',
    min_persons = 1, max_persons = 6,
    items = '[{"label":"Yleinen vuoro","label_en":"General session","kb_product_id":1,"unit_price":29,"price_type":"per_person"},{"label":"Turvenaamio ja jalkakylpy","label_en":"Peat mask and foot bath","addon_code":"turvenaamio_jalkakylpy","unit_price":15,"price_type":"per_person"}]'::jsonb
  where code = 'peat_mask_2';
  update booking.gift_card_packages set
    name = 'Savusaunaelämys ja saunahoito', name_en = 'Smoke sauna experience and sauna treatment',
    description = 'Yleinen savusaunavuoro ja saunahoito (60 min).',
    description_en = 'A public smoke sauna session and a sauna treatment (60 min).',
    min_persons = 1, max_persons = 4,
    items = '[{"label":"Yleinen vuoro","label_en":"General session","kb_product_id":1,"unit_price":29,"price_type":"per_person"},{"label":"Saunahoito","label_en":"Sauna treatment","kb_product_id":10,"unit_price":99,"extra_price":35,"included":1,"price_type":"base_plus_extra"}]'::jsonb
  where code = 'sauna_treatment_2';
  update booking.gift_card_packages set
    name = 'Savusaunaelämys ja saunotus', name_en = 'Smoke sauna experience and ritual sauna bathing',
    description = 'Yleinen savusaunavuoro ja saunotus (2 h).',
    description_en = 'A public smoke sauna session and ritual sauna bathing (2 h).',
    min_persons = 1, max_persons = 4,
    items = '[{"label":"Yleinen vuoro","label_en":"General session","kb_product_id":1,"unit_price":29,"price_type":"per_person"},{"label":"Saunotus","label_en":"Ritual sauna bathing","kb_product_id":11,"unit_price":210,"extra_price":60,"included":1,"price_type":"base_plus_extra"}]'::jsonb
  where code = 'saunotus_2';

  for r in select code, price, persons, items from booking.gift_card_packages where code in ('entry_2', 'peat_mask_2', 'sauna_treatment_2', 'saunotus_2') loop
    v_amt := booking._gc_package_amount(r.items, r.persons);
    if v_amt is distinct from r.price then
      raise exception 'booking_196: paketti % henkilömäärällä % maksaa %, ei vanhaa hintaa %. Ei muutoksia.', r.code, r.persons, v_amt, r.price;
    end if;
  end loop;

  insert into booking.gift_card_packages(
    code, name, name_en, description, description_en, kind, is_open, price,
    min_amount, max_amount, persons, min_persons, max_persons, vat_rate, vat_treatment, kb_product_id, items, valid_months, sort_order, active)
  values (
    'saunarituaali_2',
    'Saunotusrituaali ja yleinen vuoro',
    'Sauna ritual and public session',
    'Saunarituaali ja yleinen savusaunavuoro yhdessä.',
    'The sauna ritual and the public smoke sauna session together.',
    'product', false, 98.00,
    null, null, 2, 1, 6, 25.5, 'at_sale', null,
    '[{"label":"Saunarituaali ja savusaunavuoro","label_en":"Sauna ritual and smoke sauna session","kb_product_id":7,"unit_price":49,"price_type":"per_person"}]'::jsonb,
    6, 35, true)
  on conflict (code) do update set
    name = excluded.name, name_en = excluded.name_en,
    description = excluded.description, description_en = excluded.description_en,
    price = excluded.price, persons = excluded.persons, min_persons = excluded.min_persons, max_persons = excluded.max_persons,
    vat_rate = excluded.vat_rate, vat_treatment = excluded.vat_treatment, items = excluded.items,
    valid_months = excluded.valid_months, sort_order = excluded.sort_order, active = excluded.active, kind = excluded.kind, is_open = excluded.is_open
  where booking.gift_card_packages.price is distinct from excluded.price
     or booking.gift_card_packages.name is distinct from excluded.name
     or booking.gift_card_packages.items is distinct from excluded.items
     or booking.gift_card_packages.max_persons is distinct from excluded.max_persons;

  if booking._gc_package_amount((select items from booking.gift_card_packages where code = 'saunarituaali_2'), 2) is distinct from 98.00
     or booking._gc_package_amount((select items from booking.gift_card_packages where code = 'saunarituaali_2'), 1) is distinct from 49.00 then
    raise exception 'booking_196: rituaalipaketin hinta ei ole 49 × henkilömäärä. Ei muutoksia.';
  end if;

  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'name', 'name', $$'fi'$$, $$'normal'$$, $$s.active and s.code = 'saunarituaali_2'$$, 200);
  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'name', 'name_en', $$'en'$$, $$'normal'$$, $$s.active and s.code = 'saunarituaali_2'$$, 200);
  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'description', 'description', $$'fi'$$, $$'normal'$$, $$s.active and s.code = 'saunarituaali_2'$$, 2000);
  perform booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', 'description', 'description_en', $$'en'$$, $$'normal'$$, $$s.active and s.code = 'saunarituaali_2'$$, 2000);

  -- Jo julkaistut kauppatekstit: vain vanha "kahdelle"-lause. Ei texts_proposea (auth.uid() on migraatiossa null).
  -- seo.gift.description on content/site-texts.pending-import-92.json.
  update booking.site_texts s
     set published_text = v.new_text, needs_translation = false
    from (values
      ('ui.gift.pkg_kicker', 'fi', 'Paketti kahdelle', 'Paketti'),
      ('ui.gift.pkg_kicker', 'en', 'Package for two', 'Package'),
      ('ui.gift.buy_lead', 'fi', 'Valitse avoin lahjakortti tai valmis paketti kahdelle. Kortti on voimassa {{var:months}} kuukautta maksun jälkeen.', 'Valitse avoin lahjakortti tai valmis paketti. Kortti on voimassa {{var:months}} kuukautta maksun jälkeen.'),
      ('ui.gift.buy_lead', 'en', 'Choose an open-value gift card or a ready-made package for two. The card is valid for {{var:months}} months after payment.', 'Choose an open-value gift card or a ready-made package. The card is valid for {{var:months}} months after payment.'),
      ('ui.gift.buy_lead_one', 'fi', 'Valitse avoin lahjakortti tai valmis paketti kahdelle. Kortti on voimassa {{var:months}} kuukauden ajan maksun jälkeen.', 'Valitse avoin lahjakortti tai valmis paketti. Kortti on voimassa {{var:months}} kuukauden ajan maksun jälkeen.'),
      ('ui.gift.buy_lead_one', 'en', 'Choose an open-value gift card or a ready-made package for two. The card is valid for {{var:months}} month after payment.', 'Choose an open-value gift card or a ready-made package. The card is valid for {{var:months}} month after payment.')
    ) as v(key, lang, old_text, new_text)
   where s.key = v.key and s.lang = v.lang and s.published_text = v.old_text;
end
$m196$;

create or replace function booking._gc_sell(p_items jsonb, p_cust bigint, p_channel text, p_locale text, p_buyer_name text, p_buyer_email text,
    p_status text, p_vat_override text default null, p_valid_months int default null, p_default_rname text default null, p_default_remail text default null,
    p_default_greeting text default null, p_default_delivery_to text default null, p_default_cover text default null, p_default_deliver_on text default null, p_default_deliver_time text default null) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  it jsonb; pkg booking.gift_card_packages; v_qty int; v_amt numeric; v_n int := 0; v_total numeric := 0; v_max int := (booking._setting('gift_cards.max_cards_per_order', '10'::jsonb) #>> '{}')::int;
  v_order booking.orders; v_oi bigint; v_vat text; v_rate numeric; i int; g booking.gift_cards; v_cards jsonb := '[]'::jsonb;
  v_rn text; v_re text; v_gr text; v_name text; v_months int; v_locale text := coalesce(nullif(p_locale, ''), 'fi');
  v_lines jsonb := '[]'::jsonb; v_dl jsonb; v_quote jsonb; v_persons int;
begin
  if v_locale not in ('fi', 'en', 'sv') then perform booking._err('invalid_param', 'Virheellinen kieli'); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 10 then
    perform booking._err('invalid_items', 'Anna 1–10 riviä: [{"package":"open","amount":50,"quantity":1}]');
  end if;
  if p_vat_override is not null and p_vat_override <> 'at_sale' then
    perform booking._err('gift_card_vat_rate', 'Lahjakortilla voi maksaa vain tuotteita, joiden arvonlisävero on 25,5 %');
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    if jsonb_typeof(it) <> 'object' then perform booking._err('invalid_items', 'Rivi virheellinen'); end if;
    select * into pkg from booking.gift_card_packages where code = it ->> 'package';
    if not found then perform booking._err('invalid_package', 'Tuntematon lahjakorttipaketti'); end if;
    if not pkg.active then perform booking._err('package_inactive', 'Paketti ei ole myynnissä'); end if;
    v_qty := case when it ? 'quantity' and jsonb_typeof(it -> 'quantity') <> 'null' then
                 case when (it ->> 'quantity') ~ '^\d{1,2}$' then (it ->> 'quantity')::int else null end else 1 end;
    if v_qty is null or v_qty < 1 or v_qty > v_max then perform booking._err('invalid_quantity', format('Määrä 1–%s', v_max)); end if;
    if pkg.is_open then
      if coalesce(it ->> 'amount', '') !~ '^\d{1,5}(\.\d{1,2})?$' then perform booking._err('invalid_amount', 'Anna kortin summa'); end if;
      v_amt := (it ->> 'amount')::numeric;
      if v_amt < pkg.min_amount or v_amt > pkg.max_amount then perform booking._err('invalid_amount', format('Summa %s–%s €', pkg.min_amount, pkg.max_amount)); end if;
    else
      v_quote := booking._gc_quote(pkg, it);
      v_amt := (v_quote ->> 'amount')::numeric;
    end if;
    v_rn := nullif(btrim(coalesce(it ->> 'recipient_name', p_default_rname, '')), '');
    v_re := nullif(lower(btrim(coalesce(it ->> 'recipient_email', p_default_remail, ''))), '');
    v_gr := nullif(btrim(regexp_replace(coalesce(it ->> 'greeting', p_default_greeting, ''), '[\x00-\x09\x0b\x0c\x0e-\x1f\x7f]', '', 'g')), '');
    if v_rn is not null and char_length(v_rn) > 120 then perform booking._err('invalid_name', 'Saajan nimi on liian pitkä (max 120)'); end if;
    if v_re is not null and (char_length(v_re) > 200 or not booking._valid_email(v_re)) then perform booking._err('invalid_email', 'Tarkista saajan sähköpostiosoite'); end if;
    if v_gr is not null and char_length(v_gr) > 300 then perform booking._err('invalid_greeting', 'Tervehdys on liian pitkä (max 300 merkkiä)'); end if;
    v_dl := booking._gc_delivery_resolve(coalesce(it ->> 'delivery_to', p_default_delivery_to), v_re, coalesce(it ->> 'cover_message', p_default_cover),
              coalesce(it ->> 'deliver_on', p_default_deliver_on), coalesce(it ->> 'deliver_time', p_default_deliver_time), coalesce(p_valid_months, pkg.valid_months));
    v_n := v_n + v_qty;
    v_total := v_total + coalesce(v_amt, 0) * v_qty;
    v_amt := null;
  end loop;
  if v_n > v_max then perform booking._err('too_many_cards', format('Enintään %s korttia / tilaus', v_max)); end if;
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, created_by)
  values (p_cust, case when p_status = 'confirmed' then 'confirmed' else 'pending' end, 'unpaid', 0, p_channel, v_locale, auth.uid()) returning * into v_order;
  if p_status = 'confirmed' then update booking.orders set confirmed_at = now() where id = v_order.id; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    select * into pkg from booking.gift_card_packages where code = it ->> 'package';
    v_qty := case when it ? 'quantity' and jsonb_typeof(it -> 'quantity') <> 'null' then (it ->> 'quantity')::int else 1 end;
    if pkg.is_open then
      v_amt := (it ->> 'amount')::numeric; v_persons := null;
    else
      v_quote := booking._gc_quote(pkg, it);
      v_amt := (v_quote ->> 'amount')::numeric;
      v_persons := (v_quote ->> 'persons')::int;
    end if;
    v_vat := 'at_sale';
    v_rate := 25.5;
    v_months := coalesce(p_valid_months, pkg.valid_months);
    v_name := case when pkg.is_open then pkg.name || ' ' || trim(trailing '.' from trim(trailing '0' from to_char(v_amt, 'FM99990.00'))) || ' €' else pkg.name end;
    insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
    values (v_order.id, pkg.kb_product_id, v_name, 'gift_card', v_qty, v_amt, v_amt * v_qty, v_rate,
            jsonb_strip_nulls(jsonb_build_object('gift_card_package', pkg.code, 'vat_treatment', v_vat, 'persons', v_persons))) returning id into v_oi;
    v_rn := nullif(btrim(coalesce(it ->> 'recipient_name', p_default_rname, '')), '');
    v_re := nullif(lower(btrim(coalesce(it ->> 'recipient_email', p_default_remail, ''))), '');
    v_gr := nullif(btrim(regexp_replace(coalesce(it ->> 'greeting', p_default_greeting, ''), '[\x00-\x09\x0b\x0c\x0e-\x1f\x7f]', '', 'g')), '');
    v_dl := booking._gc_delivery_resolve(coalesce(it ->> 'delivery_to', p_default_delivery_to), v_re, coalesce(it ->> 'cover_message', p_default_cover),
              coalesce(it ->> 'deliver_on', p_default_deliver_on), coalesce(it ->> 'deliver_time', p_default_deliver_time), coalesce(p_valid_months, pkg.valid_months));
    for i in 1..v_qty loop
      g := booking._gc_create_card(pkg, v_amt, 'pending_payment', v_order.id, v_oi, p_cust,
                                   p_buyer_name, p_buyer_email, v_rn, v_re, v_gr, v_locale, v_months, v_vat, null,
                                   p_delivery_to := v_dl ->> 'delivery_to', p_cover := v_dl ->> 'cover_message', p_deliver_on := (v_dl ->> 'deliver_on')::date, p_deliver_time := (v_dl ->> 'deliver_time')::time);
      if v_persons is not null then update booking.gift_cards set persons = v_persons where id = g.id; end if;
      if v_qty = 1 then update booking.order_items set gift_card_id = g.id where id = v_oi; end if;
      v_cards := v_cards || jsonb_strip_nulls(jsonb_build_object('id', g.id, 'public_token', g.public_token, 'package_code', pkg.code, 'package_name', pkg.name, 'amount', v_amt, 'persons', v_persons, 'status', g.status,
                                               'vat_treatment', v_vat, 'recipient_name', v_rn, 'delivery_to', g.delivery_to, 'deliver_on', g.deliver_on, 'deliver_time', to_char(g.deliver_time, 'HH24:MI')));
    end loop;
    v_lines := v_lines || jsonb_strip_nulls(jsonb_build_object('order_item_id', v_oi, 'package', pkg.code, 'quantity', v_qty, 'unit', v_amt, 'persons', v_persons, 'vat_rate', v_rate, 'vat_treatment', v_vat));
  end loop;
  update booking.orders set total_gross = v_total where id = v_order.id;
  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no, 'public_token', v_order.public_token, 'total', v_total, 'cards', v_cards, 'lines', v_lines);
end $$;

create or replace function booking.public_gift_card_packages() returns jsonb
language sql stable security definer set search_path to ''
as $$
  select jsonb_build_object('ok', true, 'sale_enabled', booking._gc_flag('gift_cards.sale_enabled'), 'redeem_enabled', booking._gc_flag('gift_cards.redeem_enabled'),
    'max_cards_per_order', (booking._setting('gift_cards.max_cards_per_order', '10'::jsonb) #>> '{}')::int, 'currency', 'EUR',
    'packages', coalesce((select jsonb_agg(jsonb_build_object('code', p.code, 'name', p.name, 'name_en', p.name_en, 'description', p.description, 'description_en', p.description_en,
        'kind', p.kind, 'is_open', p.is_open, 'price', p.price, 'min_amount', p.min_amount, 'max_amount', p.max_amount, 'persons', p.persons,
        'min_persons', p.min_persons, 'max_persons', p.max_persons,
        'unit_price', case when not p.is_open and p.items is not null and not exists (
            select 1 from jsonb_array_elements(p.items) it where coalesce(it ->> 'price_type', 'per_person') <> 'per_person' or it ->> 'unit_price' is null)
          then booking._gc_package_amount(p.items, 1) end,
        'vat_rate', p.vat_rate, 'valid_months', p.valid_months, 'items', p.items) order by p.sort_order, p.code)
      from booking.gift_card_packages p where p.active), '[]'::jsonb))
$$;

create or replace function booking.svc_get_gift_card_pdf_data(p_public_token uuid) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare g booking.gift_cards; v_red boolean; v_persons int; v_items jsonb;
begin
  select * into g from booking.gift_cards where public_token = p_public_token and p_public_token is not null;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Korttia ei löydy'); end if;
  -- booking_160: PDF poistettu säilytysajan (3 v) päätyttyä
  if g.pdf_deleted_at is not null then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Korttia ei löydy'); end if;
  if g.status not in ('active', 'used', 'expired') then return jsonb_build_object('ok', false, 'code', 'not_ready', 'message', 'Kortti aktivoituu kun tilaus on maksettu'); end if;
  v_red := booking._gc_flag('gift_cards.redeem_enabled') and (g.source <> 'johku' or booking._gc_flag('gift_cards.johku_cards_redeemable'));
  select coalesce(g.persons, p.persons) into v_persons from booking.gift_card_packages p where p.code = g.package_code;
  select coalesce(jsonb_agg(jsonb_build_object('label', it ->> 'label', 'label_en', it ->> 'label_en', 'persons', v_persons) order by ord), '[]'::jsonb)
    into v_items
    from booking.gift_card_packages p, jsonb_array_elements(p.items) with ordinality t(it, ord)
   where p.code = g.package_code;
  return jsonb_build_object('ok', true, 'code', booking.gift_code_fmt(g.code), 'status', case when g.status = 'active' and g.valid_to < booking._gc_today() then 'expired' else g.status end,
    'kind', g.kind, 'package_code', g.package_code,
    'package', (select jsonb_build_object('name', p.name, 'name_en', p.name_en, 'description', p.description, 'description_en', p.description_en, 'persons', v_persons, 'items', coalesce(v_items, '[]'::jsonb), 'is_open', p.is_open)
                  from booking.gift_card_packages p where p.code = g.package_code),
    'initial_amount', g.initial_amount, 'balance', g.balance, 'currency', g.currency, 'valid_from', g.valid_from, 'valid_to', g.valid_to, 'recipient_name', g.recipient_name,
    'greeting', g.greeting, 'buyer_name', g.buyer_name, 'locale', g.locale, 'issued_at', coalesce(g.activated_at, g.created_at), 'source', g.source, 'persons', v_persons,
    'redeemable_now', v_red, 'seller', booking._seller());
end $$;

create or replace function booking.public_get_order_gift_cards(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare o booking.orders;
begin
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy'); end if;
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'payment_status', o.payment_status, 'cards', coalesce((
    select jsonb_agg(jsonb_build_object('token', g.public_token, 'package_code', g.package_code, 'package_name', (select p.name from booking.gift_card_packages p where p.code = g.package_code),
      'amount', g.initial_amount, 'persons', g.persons, 'status', g.status, 'valid_to', g.valid_to, 'recipient_name', g.recipient_name, 'delivery_to', g.delivery_to, 'deliver_on', g.deliver_on, 'deliver_time', to_char(g.deliver_time, 'HH24:MI'), 'delivered_at', g.delivered_at, 'ready', g.status in ('active', 'used', 'expired')) order by g.id)
      from booking.gift_cards g where g.purchase_order_id = o.id), '[]'::jsonb));
end $$;
