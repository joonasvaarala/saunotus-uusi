-- Migraatio 11: asiakastyypit (yksityinen / yritys, y-tunnus, verkkolaskutustiedot) + lisäpalvelut (hinnoittelu, tilaus, oikeudet, RLS, päivänäkymä)
begin;
set local search_path = extensions, public;
select no_plan();

select test.next_dow(2, 6) as tue, test.next_dow(5, 6) as fri,
       test.rule('Naisten sauna%') as r_tue, test.rule('Oma savusaunavuoro ma–pe 16–19%') as r_priv \gset
select p.price as p_tue from booking.schedule_rules r join kb.products p on p.id = r.product_id where r.id = :r_tue \gset
select (select id from booking.addons where code = 'turvenaamio_jalkakylpy') as a_mask, (select id from booking.addons where code = 'saunavihta') as a_vihta \gset
update booking.settings set value = '1000' where key in ('rl_change_per_10min', 'rl_ip_per_10min', 'rl_email_per_10min');
select test.mk_staff('k-admin@example.com', 'admin') as adm, test.mk_staff('k-manager@example.com', 'manager') as mgr, test.mk_staff('k-staff@example.com', 'staff') as stf,
       test.mk_user('k-outsider@example.com') as outs \gset

-- ================= A) y-tunnus =================
select is(booking._business_id_ok('0112038-9'), true, 'y-tunnus 0112038-9 kelpaa (tarkiste 9)');
select is(booking._business_id_ok('2336509-6'), true, 'y-tunnus 2336509-6 kelpaa (tarkiste 6)');
select is(booking._business_id_ok('1000002-0'), true, 'y-tunnus: jäännös 0 → tarkiste 0');
select is(booking._business_id_ok('1000008-5'), false, 'y-tunnus: jäännös 1 ei ole koskaan kelvollinen');
select is(booking._business_id_ok('0112038-8'), false, 'väärä tarkistenumero hylätään');
select is(booking._business_id_ok('abc'), false, 'roskasyöte hylätään');
select is(booking._business_id_ok('1234567'), false, 'ilman tarkistenumeroa (7 numeroa) hylätään');
select is(booking._business_id_ok(null), false, 'null hylätään');
select is(booking._norm_business_id(' 01120389 '), '0112038-9', 'normalisointi: 8 numeroa ilman viivaa → 1234567-8');
select is(booking._norm_business_id('112038-9'), '0112038-9', 'normalisointi: vanha 6+1-muoto saa etunollan');
select is(booking._norm_business_id('FI01120389'), '0112038-9', 'normalisointi: ALV-tunnus FI… → y-tunnus');
select is(booking._business_id_ok('FI01120389'), true, 'ALV-tunnuksesta johdettu y-tunnus kelpaa');

-- ================= B) asiakastyypit: taulu + rajoitteet =================
select is((select array_agg(code order by sort_order) from booking.customer_kinds), array['private','company'], 'asiakastyypit: private, company (taulupohjainen)');
select is((select is_company from booking.customer_kinds where code = 'company'), true, 'company-tyyppi vaatii yritystiedot');
select throws_ok($$insert into booking.customers(name, customer_kind) values ('X Y', 'company')$$, '23514', null, 'yritysasiakas ilman yrityksen nimeä ja y-tunnusta hylätään (rajoite)');
select throws_ok($$insert into booking.customers(name, customer_kind, company, business_id) values ('X Y', 'company', 'Oy Testi', '0112038-8')$$, '23514', null, 'virheellinen y-tunnus hylätään rajoitteella');
select throws_ok($$insert into booking.customers(name, customer_kind) values ('X Y', 'ei_ole')$$, '23503', null, 'tuntematon asiakastyyppi hylätään (viiteavain)');
select lives_ok($$insert into booking.customers(name, customer_kind, company, business_id) values ('X Y', 'company', 'Oy Testi', '0112038-9')$$, 'kelvollinen yritysasiakas hyväksytään');
select is((select customer_kind from booking.customers where name = 'X Y' and customer_kind = 'private' limit 1), null, 'oletus on private (vanhat asiakkaat)');

-- ================= C) lisäpalvelut: seed, julkinen luku, RLS =================
select is((select count(*)::int from booking.addons), 3, 'kolme alkulisäpalvelua (turvenaamio+jalkakylpy, vihta + migraation 27 pyyhe)');
select is((select price_gross from booking.addons where code = 'turvenaamio_jalkakylpy'), 15.00, 'Turvenaamio ja jalkakylpy = 15 € (sis. ALV)');
select is((select price_gross from booking.addons where code = 'saunavihta'), 13.00, 'Saunavihta = 13 € (sis. ALV)');
select is((select array_agg(distinct vat_rate) from booking.addons), array[25.5::numeric], 'lisäpalvelujen ALV 25,5 % (kuten muu hinnoittelu)');
select is((select bool_and(applies_modes @> array['shared','exclusive']) from booking.addons), true, 'lisäpalvelut koskevat yleisiä ja yksityisvuoroja');
select test.anon();
select is(jsonb_array_length(booking.public_addons()), 3, 'anon: public_addons palauttaa 3 aktiivista');
select ok(not (booking.public_addons()::text ~ 'external_source|created_at|updated_at'), 'public_addons ei sisällä sisäisiä kenttiä');
select throws_ok('select * from booking.addons', '42501', null, 'anon ei lue addons-taulua suoraan');
select throws_ok('select * from booking.customer_kinds', '42501', null, 'anon ei lue customer_kinds-taulua suoraan');
select test.logout();
select test.login(:'stf');
select is((select count(*)::int from booking.addons), 3, 'staff lukee lisäpalvelut (staff_read)');
select is((select count(*)::int from booking.customer_kinds), 2, 'staff lukee asiakastyypit');
select throws_ok($$insert into booking.addons(code, name, price_gross) values ('x_y','X',1)$$, '42501', null, 'staff ei kirjoita addons-tauluun suoraan');
select test.logout();
select test.login(:'outs');
select is((select count(*)::int from booking.addons), 0, 'ei-henkilöstö ei näe lisäpalveluita (RLS)');
select test.logout();

-- ================= D) julkinen varaus + lisäpalvelut (yleinen vuoro) =================
select test.anon('10.9.0.1');
select booking.public_create_booking(:r_tue, :'tue', 3, 'Vihta Asiakas', 'vihta@example.com', '0401234567', false, 'fi', null, 'private', null,
         '[{"code":"turvenaamio_jalkakylpy","quantity":2},{"code":"saunavihta","quantity":3}]'::jsonb) as b1 \gset
select is((:'b1'::jsonb ->> 'ok')::boolean, true, 'varaus lisäpalveluilla onnistuu');
select is((:'b1'::jsonb ->> 'total')::numeric, 3 * :p_tue::numeric + 2 * 15 + 3 * 13, 'kokonaishinta = vuoro + 2 × 15 + 3 × 13');
select is((:'b1'::jsonb ->> 'addons_total')::numeric, 69.00, 'addons_total = 69 €');
select (:'b1'::jsonb ->> 'token') as tok1 \gset
select test.logout();
select is((select total_gross from booking.orders where public_token = :'tok1'::uuid), 3 * :p_tue::numeric + 69, 'tilauksen summa sisältää lisäpalvelut');
select is((select count(*)::int from booking.order_items i join booking.orders o on o.id = i.order_id where o.public_token = :'tok1'::uuid and i.kind = 'addon'), 2, 'kaksi lisäpalvelurivia tilauksella');
select is((select sum(line_total_gross) from booking.order_items i join booking.orders o on o.id = i.order_id where o.public_token = :'tok1'::uuid and i.kind = 'addon'), 69.00, 'lisäpalvelurivien summa 69 €');
select is((select array_agg(distinct vat_rate) from booking.order_items i join booking.orders o on o.id = i.order_id where o.public_token = :'tok1'::uuid and i.kind = 'addon'), array[25.5::numeric], 'lisäpalvelurivin ALV 25,5 %');
select is((select i.line_vat from booking.order_items i join booking.orders o on o.id = i.order_id where o.public_token = :'tok1'::uuid and i.addon_id = :a_vihta), round(39 * 25.5 / 125.5, 2), 'ALV-osuus lasketaan bruttohinnasta (sis. ALV)');
select is((select count(*)::int from booking.order_items i join booking.orders o on o.id = i.order_id
            where o.public_token = :'tok1'::uuid and i.kind = 'addon' and i.parent_item_id = (select order_item_id from booking.reservations where order_id = o.id)), 2, 'lisäpalvelurivit kuuluvat varausriviin (parent_item_id)');
select is((select amount from booking.payments p join booking.orders o on o.id = p.order_id where o.public_token = :'tok1'::uuid), 3 * :p_tue::numeric + 69, 'maksurivin summa = koko tilaus');
select is((select persons from booking.reservations r join booking.orders o on o.id = r.order_id where o.public_token = :'tok1'::uuid), 3, 'varauksen henkilömäärä ennallaan');
select test.anon('10.9.0.1');
select is(jsonb_array_length(booking.public_get_booking(:'tok1'::uuid) -> 'items'), 1, 'get_booking: items = vain varausrivi');
select is(jsonb_array_length(booking.public_get_booking(:'tok1'::uuid) -> 'addons'), 2, 'get_booking: addons-lista');
select is((booking.public_get_booking(:'tok1'::uuid) -> 'addons' -> 0 ->> 'quantity')::int, 2, 'get_booking: lisäpalvelun määrä');
select is((booking.public_get_booking(:'tok1'::uuid) ->> 'total')::numeric, 3 * :p_tue::numeric + 69, 'get_booking: kokonaissumma sis. lisäpalvelut');
select ok(not (booking.public_get_booking(:'tok1'::uuid)::text ~* 'example\.com|0401234567|Asiakas'), 'get_booking ei vuoda henkilötietoja lisäpalveluiden kanssa');

-- virheet: määrä > henkilömäärä × max_per_person, tuntematon, passiivinen, väärä tyyppi, väärä muoto
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'ad1@example.com', '0401234567', false, 'fi', null, 'private', null, '[{"code":"saunavihta","quantity":3}]') ->> 'code', 'addon_quantity', 'liikaa lisäpalveluita (3 > 2 hlö × 1) hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'ad2@example.com', '0401234567', false, 'fi', null, 'private', null, '[{"code":"saunavihta","quantity":1},{"code":"saunavihta","quantity":1},{"code":"saunavihta","quantity":1}]') ->> 'code', 'addon_quantity', 'samaan lisäpalveluun kohdistuvat rivit summataan rajaa vasten');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'ad3@example.com', '0401234567', false, 'fi', null, 'private', null, '[{"code":"ei_ole","quantity":1}]') ->> 'code', 'addon_not_found', 'tuntematon lisäpalvelu hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'ad4@example.com', '0401234567', false, 'fi', null, 'private', null, '[{"id":999999,"quantity":1}]') ->> 'code', 'addon_not_found', 'tuntematon id hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'ad5@example.com', '0401234567', false, 'fi', null, 'private', null, '[{"code":"saunavihta","quantity":-1}]') ->> 'code', 'addon_quantity', 'negatiivinen määrä hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'ad6@example.com', '0401234567', false, 'fi', null, 'private', null, '[{"code":"saunavihta","quantity":1.5}]') ->> 'code', 'addon_quantity', 'desimaalimäärä hylätään (vain kokonaisluku)');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'ad7@example.com', '0401234567', false, 'fi', null, 'private', null, '{"code":"saunavihta"}') ->> 'code', 'invalid_addons', 'lisäpalvelut väärässä muodossa (ei taulukko) hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'ad8@example.com', '0401234567', false, 'fi', null, 'private', null, '[{"code":"saunavihta"}]') ->> 'code', 'addon_quantity', 'puuttuva määrä hylätään');
select test.logout();
select is((select count(*)::int from booking.customers where email like 'ad_@example.com'), 0, 'epäonnistuneet lisäpalveluvaraukset eivät jätä asiakkaita');
select is((select count(*)::int from booking.orders o join booking.customers c on c.id = o.customer_id where c.email like 'ad_@example.com'), 0, 'eivätkä tilauksia (atominen)');
update booking.addons set active = false where code = 'saunavihta';
select test.anon('10.9.0.1');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'ad9@example.com', '0401234567', false, 'fi', null, 'private', null, '[{"code":"saunavihta","quantity":1}]') ->> 'code', 'addon_inactive', 'passiivista lisäpalvelua ei voi tilata');
select is(jsonb_array_length(booking.public_addons()), 2, 'public_addons: passiivinen piilossa');
select test.logout();
update booking.addons set active = true, applies_modes = '{exclusive}' where code = 'saunavihta';
select test.anon('10.9.0.1');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'ad10@example.com', '0401234567', false, 'fi', null, 'private', null, '[{"code":"saunavihta","quantity":1}]') ->> 'code', 'addon_not_allowed', 'vain yksityisvuoroille sallittua lisäpalvelua ei voi tilata yleiselle vuorolle');
select test.logout();
update booking.addons set applies_modes = '{shared,exclusive}' where code = 'saunavihta';

-- nolla-määrä ohitetaan; ilman lisäpalveluita hinta kuten ennen; yksityisvuoro + lisäpalvelu
select test.anon('10.9.0.2');
select booking.public_create_booking(:r_tue, (:'tue'::date + 7), 2, 'Nolla Asiakas', 'nolla@example.com', '0401234567', false, 'fi', null, 'private', null, '[{"code":"saunavihta","quantity":0}]') as b0 \gset
select is((:'b0'::jsonb ->> 'total')::numeric, 2 * :p_tue::numeric, 'määrä 0 → ei riviä, hinta pelkkä vuoro');
select booking.public_create_booking(:r_priv, :'fri', 4, 'Yksityis Asiakas', 'yksityis@example.com', '0401234567', false, 'fi', null, 'private', null, '[{"code":"saunavihta","quantity":4}]') as bp \gset
select is((:'bp'::jsonb ->> 'ok')::boolean, true, 'yksityisvuoro + lisäpalvelu onnistuu');
select is((:'bp'::jsonb ->> 'addons_total')::numeric, 52.00, 'yksityisvuoron lisäpalveluiden summa 4 × 13');
select test.logout();
select is((select mode from booking.reservations r join booking.orders o on o.id = r.order_id where o.public_token = (:'bp'::jsonb ->> 'token')::uuid), 'exclusive', 'varaus on yksityisvuoro');

-- ================= E) yritysasiakas julkisessa varauksessa =================
select test.anon('10.9.0.3');
select booking.public_create_booking(:r_tue, :'tue', 2, 'Yrjö Yhteyshenkilö', 'yrjo@yritys.example.com', '+358 40 555 1234', true, 'fi', 'Yritysvarausviesti', 'company',
   '{"company_name":"Testi Oy","business_id":"01120389","street":"Yrityskatu 1","zip":"00100","city":"Helsinki","einvoice_address":"003701120389","einvoice_operator":"003723327487","reference":"PO-4711"}'::jsonb,
   '[{"code":"saunavihta","quantity":2}]'::jsonb) as c1 \gset
select is((:'c1'::jsonb ->> 'ok')::boolean, true, 'yritysvaraus onnistuu');
select is(:'c1'::jsonb ->> 'customer_kind', 'company', 'vastauksessa customer_kind = company');
select is((:'c1'::jsonb ->> 'total')::numeric, 2 * :p_tue::numeric + 26, 'yritysvarauksen hinta sis. lisäpalvelut');
select (:'c1'::jsonb ->> 'token') as ctok \gset
select test.logout();
select is((select customer_kind from booking.customers where email = 'yrjo@yritys.example.com'), 'company', 'asiakasrivi: customer_kind = company');
select is((select company || '|' || business_id || '|' || address || '|' || zip || '|' || city from booking.customers where email = 'yrjo@yritys.example.com'), 'Testi Oy|0112038-9|Yrityskatu 1|00100|Helsinki', 'yritystiedot tallennettu, y-tunnus normalisoitu muotoon 1234567-8');
select is((select einvoice_address || '|' || einvoice_operator || '|' || invoice_reference from booking.customers where email = 'yrjo@yritys.example.com'), '003701120389|003723327487|PO-4711', 'verkkolaskutustiedot ja viite tallennettu');
select is((select name || '|' || phone from booking.customers where email = 'yrjo@yritys.example.com'), 'Yrjö Yhteyshenkilö|+358 40 555 1234', 'yhteyshenkilön nimi ja puhelin tallennettu');
select is((select customer_kind from booking.orders where public_token = :'ctok'::uuid), 'company', 'tilaus: customer_kind = company');
select is((select billing ->> 'business_id' from booking.orders where public_token = :'ctok'::uuid), '0112038-9', 'tilaus: laskutustietojen kuva (y-tunnus)');
select is((select billing ->> 'company' || '|' || (billing ->> 'contact_email') from booking.orders where public_token = :'ctok'::uuid), 'Testi Oy|yrjo@yritys.example.com', 'tilaus: yritys + yhteyshenkilön sähköposti');
select is((select invoice_reference from booking.orders where public_token = :'ctok'::uuid), 'PO-4711', 'tilaus: viite / tilausnumero');
select is((select method from booking.payments p join booking.orders o on o.id = p.order_id where o.public_token = :'ctok'::uuid), 'invoice', 'yritysvaraus: maksutapa lasku (invoice)');
select is((select marketing_consent from booking.customers where email = 'yrjo@yritys.example.com'), true, 'yritysasiakkaan markkinointisuostumus tallentuu');
select test.anon('10.9.0.3');
select ok(not (booking.public_get_booking(:'ctok'::uuid)::text ~* '0112038|Testi Oy|Yrityskatu|yritys\.example|PO-4711|Yhteyshenkilö'), 'get_booking ei vuoda yritystietoja eikä y-tunnusta');
select is(booking.public_get_booking(:'ctok'::uuid) ->> 'customer_kind', 'company', 'get_booking kertoo asiakastyypin');
-- sama yritys + sähköposti → sama asiakas; yksityinen samalla sähköpostilla → eri asiakasrivi
select booking.public_create_booking(:r_tue, (:'tue'::date + 7), 1, 'Yrjö Yhteyshenkilö', 'yrjo@yritys.example.com', '0405551234', false, 'fi', null, 'company',
   '{"company_name":"Testi Oy","business_id":"0112038-9","street":"Yrityskatu 1","zip":"00100","city":"Helsinki"}'::jsonb) as c2 \gset
select booking.public_create_booking(:r_tue, (:'tue'::date + 14), 1, 'Yrjö Yksityinen', 'yrjo@yritys.example.com', '0405551234', false, 'fi', null) as c3 \gset
select test.logout();
select is((select count(*)::int from booking.customers where email = 'yrjo@yritys.example.com' and customer_kind = 'company'), 1, 'sama yritys + sähköposti → sama asiakas (ei kaksoiskappaleita)');
select is((select count(*)::int from booking.customers where email = 'yrjo@yritys.example.com' and customer_kind = 'private'), 1, 'yksityisvaraus samalla sähköpostilla → erillinen yksityisasiakas (ei yhdistetä yritykseen)');
select is((select customer_kind from booking.orders where public_token = (:'c3'::jsonb ->> 'token')::uuid), 'private', 'yksityisvarauksen tilaus on private');
select is((select billing from booking.orders where public_token = (:'c3'::jsonb ->> 'token')::uuid), null, 'yksityisellä ei laskutustietokuvaa');
select is((select count(*)::int from booking.orders o join booking.customers c on c.id = o.customer_id where c.email = 'yrjo@yritys.example.com' and c.customer_kind = 'company'), 2, 'yritysasiakkaalla 2 tilausta');

-- validoinnit
select test.anon('10.9.0.4');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'y1@example.com', '0401234567', false, 'fi', null, 'company', null) ->> 'code', 'invalid_company', 'yritys ilman yritystietoja hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'y2@example.com', '0401234567', false, 'fi', null, 'company',
   '{"company_name":"Testi Oy","business_id":"0112038-8","street":"Katu 1","zip":"00100","city":"Helsinki"}') ->> 'code', 'invalid_business_id', 'virheellinen y-tunnus (tarkiste) hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'y3@example.com', '0401234567', false, 'fi', null, 'company',
   '{"company_name":"Testi Oy","business_id":"abc","street":"Katu 1","zip":"00100","city":"Helsinki"}') ->> 'code', 'invalid_business_id', 'y-tunnus roskaa hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'y4@example.com', '0401234567', false, 'fi', null, 'company',
   '{"business_id":"0112038-9","street":"Katu 1","zip":"00100","city":"Helsinki"}') ->> 'code', 'invalid_company_name', 'yrityksen nimi puuttuu');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'y5@example.com', '0401234567', false, 'fi', null, 'company',
   '{"company_name":"Testi Oy","business_id":"0112038-9","zip":"00100","city":"Helsinki"}') ->> 'code', 'invalid_address', 'katuosoite puuttuu');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'y6@example.com', '0401234567', false, 'fi', null, 'company',
   '{"company_name":"Testi Oy","business_id":"0112038-9","street":"Katu 1","zip":"123","city":"Helsinki"}') ->> 'code', 'invalid_zip', 'postinumero (FI) pitää olla 5 numeroa');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'y7@example.com', '0401234567', false, 'fi', null, 'company',
   '{"company_name":"Testi Oy","business_id":"0112038-9","street":"Katu 1","zip":"00100"}') ->> 'code', 'invalid_city', 'postitoimipaikka puuttuu');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'y8@example.com', '0401234567', false, 'fi', null, 'company',
   '{"company_name":"Testi Oy","business_id":"0112038-9","street":"Katu 1","zip":"00100","city":"Helsinki","einvoice_address":"003701120389"}') ->> 'code', 'einvoice_incomplete', 'verkkolaskuosoite ilman operaattoria hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'y9@example.com', '0401234567', false, 'fi', null, 'company',
   '{"company_name":"Testi Oy","business_id":"0112038-9","street":"Katu 1","zip":"00100","city":"Helsinki","einvoice_address":"!!","einvoice_operator":"003723327487"}') ->> 'code', 'invalid_einvoice_address', 'virheellinen verkkolaskuosoite hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'y10@example.com', '0401234567', false, 'fi', null, 'company',
   '{"company_name":"Testi Oy","business_id":"0112038-9","street":"Katu 1","zip":"00100","city":"Helsinki","einvoice_address":"003701120389","einvoice_operator":"!"}') ->> 'code', 'invalid_einvoice_operator', 'virheellinen välittäjätunnus hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'y11@example.com', '0401234567', false, 'fi', null, 'company',
   ('{"company_name":"Testi Oy","business_id":"0112038-9","street":"Katu 1","zip":"00100","city":"Helsinki","reference":"' || repeat('x', 101) || '"}')::jsonb) ->> 'code', 'invalid_reference', 'liian pitkä viite hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'ei-sahkoposti', '0401234567', false, 'fi', null, 'company',
   '{"company_name":"Testi Oy","business_id":"0112038-9","street":"Katu 1","zip":"00100","city":"Helsinki"}') ->> 'code', 'invalid_email', 'yhteyshenkilön sähköposti validoidaan');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'y12@example.com', 'abc', false, 'fi', null, 'company',
   '{"company_name":"Testi Oy","business_id":"0112038-9","street":"Katu 1","zip":"00100","city":"Helsinki"}') ->> 'code', 'invalid_phone', 'yhteyshenkilön puhelin validoidaan');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A', 'y13@example.com', '0401234567', false, 'fi', null, 'company',
   '{"company_name":"Testi Oy","business_id":"0112038-9","street":"Katu 1","zip":"00100","city":"Helsinki"}') ->> 'code', 'invalid_name', 'yhteyshenkilön nimi vaaditaan');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'y14@example.com', '0401234567', false, 'fi', null, 'foo', null) ->> 'code', 'invalid_customer_kind', 'tuntematon asiakastyyppi hylätään');
select test.logout();
select is((select count(*)::int from booking.customers where email ~ '^y[0-9]+@example\.com$'), 0, 'validointivirheet eivät luo asiakkaita');

-- ================= F) hallinta: asiakkaan lisäys =================
select test.login(:'stf');
select booking.admin_create_customer('{"kind":"private","name":"Pekka Yksityinen","email":"Pekka@Example.com","phone":"0401112222","notes":"huom"}') as k1 \gset
select is((:'k1'::jsonb ->> 'ok')::boolean, true, 'staff (customers.manage) lisää yksityisasiakkaan');
select booking.admin_create_customer('{"kind":"company","name":"Liisa Laskutus","email":"liisa@firma.example.com","phone":"0409998888",
  "company_details":{"company_name":"Firma Oy","business_id":"2336509-6","street":"Tehdaskatu 2","zip":"33100","city":"Tampere","einvoice_address":"003723365096","einvoice_operator":"BAWCFI22","reference":"OSTO-1"}}') as k2 \gset
select is((:'k2'::jsonb ->> 'ok')::boolean, true, 'staff lisää yritysasiakkaan');
select is(test.code($$select booking.admin_create_customer('{"kind":"private","name":"Pekka Toinen","email":"pekka@example.com"}')$$), 'customer_exists', 'sama sähköposti samalle tyypille → customer_exists');
select is(test.code($$select booking.admin_create_customer('{"kind":"company","name":"Liisa Toinen","email":"liisa@firma.example.com","company_details":{"company_name":"Firma Oy","business_id":"2336509-6","street":"Tehdaskatu 2","zip":"33100","city":"Tampere"}}')$$), 'customer_exists', 'sama yritys + sähköposti → customer_exists');
select is(test.code($$select booking.admin_create_customer('{"kind":"company","name":"Liisa Toinen","email":"liisa2@firma.example.com","company_details":{"company_name":"Firma Oy","business_id":"2336509-5","street":"Tehdaskatu 2","zip":"33100","city":"Tampere"}}')$$), 'invalid_business_id', 'admin: virheellinen y-tunnus hylätään');
select is(test.code($$select booking.admin_create_customer('{"kind":"company","name":"Liisa Toinen","email":"liisa2@firma.example.com"}')$$), 'invalid_company', 'admin: yritys ilman yritystietoja hylätään');
select is(test.code($$select booking.admin_create_customer('{"kind":"private","name":"Ei Yhteystietoa"}')$$), 'contact_required', 'admin: sähköposti tai puhelin vaaditaan');
select is(test.code($$select booking.admin_create_customer('{"kind":"private","name":"Huono Email","email":"ei-ole"}')$$), 'invalid_email', 'admin: sähköposti validoidaan');
select is(test.code($$select booking.admin_create_customer('{"kind":"private","name":"Huono Puh","phone":"abc"}')$$), 'invalid_phone', 'admin: puhelin validoidaan');
select is(test.code($$select booking.admin_create_customer('{"kind":"muu","name":"Muu Tyyppi","email":"muu@example.com"}')$$), 'invalid_customer_kind', 'admin: tuntematon asiakastyyppi hylätään');
select is(test.code($$select booking.admin_create_customer('{"kind":"private","name":"Kenttä","email":"kentta@example.com","customer_type":"annual_card"}')$$), 'unknown_field', 'admin: tuntematon kenttä (customer_type) hylätään');
select is(test.code($$select booking.admin_create_customer('{"kind":"private","name":"X","email":"x1@example.com"}')$$), 'invalid_name', 'admin: liian lyhyt nimi hylätään');
select is((select count(*)::int from booking.admin_list_customers('2336509-6')), 1, 'asiakashaku y-tunnuksella');
select is((select customer_kind from booking.admin_list_customers('2336509-6')), 'company', 'asiakaslista näyttää asiakastyypin');
select is((select business_id from booking.admin_list_customers('liisa@firma')), '2336509-6', 'asiakaslista näyttää y-tunnuksen');
select is(booking.admin_get_customer((:'k2'::jsonb ->> 'id')::bigint) ->> 'einvoice_operator', 'BAWCFI22', 'admin_get_customer palauttaa verkkolaskutustiedot');
select is(booking.admin_get_customer((:'k2'::jsonb ->> 'id')::bigint) ->> 'invoice_reference', 'OSTO-1', 'admin_get_customer palauttaa viitteen');
select is(booking.admin_get_customer((:'k1'::jsonb ->> 'id')::bigint) ->> 'email', 'pekka@example.com', 'sähköposti normalisoitu pieniksi kirjaimiksi');
-- muokkaus
select is(test.code(format($$select booking.admin_update_customer(%s, '{"business_id":"1234567-0"}')$$, (:'k2'::jsonb ->> 'id')::bigint)), 'invalid_business_id', 'muokkaus: virheellinen y-tunnus hylätään');
select is(test.code(format($$select booking.admin_update_customer(%s, '{"einvoice_operator":""}')$$, (:'k2'::jsonb ->> 'id')::bigint)), 'einvoice_incomplete', 'muokkaus: verkkolaskuosoite ilman operaattoria hylätään');
select is(test.code(format($$select booking.admin_update_customer(%s, '{"customer_kind":"company"}')$$, (:'k1'::jsonb ->> 'id')::bigint)), 'invalid_company', 'muokkaus: yksityinen → yritys ilman yritystietoja hylätään');
select is(test.code(format($$select booking.admin_update_customer(%s, '{"customer_kind":"nope"}')$$, (:'k1'::jsonb ->> 'id')::bigint)), 'invalid_customer_kind', 'muokkaus: tuntematon tyyppi hylätään');
select is(test.code(format($$select booking.admin_update_customer(%s, '{"email":"rikki"}')$$, (:'k1'::jsonb ->> 'id')::bigint)), 'invalid_email', 'muokkaus: sähköposti validoidaan');
select lives_ok(format($$select booking.admin_update_customer(%s, '{"company":"Firma Group Oy","invoice_reference":"OSTO-2","einvoice_address":"003723365096 ","einvoice_operator":"bawcfi22"}')$$, (:'k2'::jsonb ->> 'id')::bigint), 'muokkaus: yritystietojen päivitys onnistuu');
select is(booking.admin_get_customer((:'k2'::jsonb ->> 'id')::bigint) ->> 'einvoice_operator', 'BAWCFI22', 'verkkolaskuoperaattori normalisoitu isoiksi kirjaimiksi');
select lives_ok(format($$select booking.admin_update_customer(%s, '{"business_id":"01120389","company":"Pekka Oy","customer_kind":"company"}')$$, (:'k1'::jsonb ->> 'id')::bigint), 'muokkaus: yksityinen → yritys kun tiedot annetaan');
select is(booking.admin_get_customer((:'k1'::jsonb ->> 'id')::bigint) ->> 'business_id', '0112038-9', 'y-tunnus normalisoitu muokkauksessa');
select test.logout();
-- oikeudet
select test.anon();
select throws_ok($$select booking.admin_create_customer('{"name":"Anon Yritys","email":"anon@example.com"}')$$, '42501', null, 'anon ei voi lisätä asiakasta');
select test.logout();
select test.login(:'outs');
select throws_ok($$select booking.admin_create_customer('{"name":"Ulkopuolinen","email":"out@example.com"}')$$, 'BK001', 'Ei oikeuksia', 'ei-henkilöstö ei voi lisätä asiakasta');
select throws_ok($$select booking.admin_list_addons()$$, 'BK001', 'Ei oikeuksia', 'ei-henkilöstö ei lue lisäpalveluita funktiolla');
select throws_ok($$select booking.admin_get_order(1)$$, 'BK001', 'Ei oikeuksia', 'ei-henkilöstö ei lue tilausta');
select test.logout();

-- ================= G) hallinta: varaus (yritys + lisäpalvelut) =================
select test.login(:'stf');
select booking.admin_create_booking(:r_tue, (:'tue'::date + 21), 3, (:'k2'::jsonb ->> 'id')::bigint, null, 'invoice', false, 'Puhelinvaraus', null, null, null, 'phone',
         format('[{"id":%s,"quantity":3},{"id":%s,"quantity":1}]', :a_mask, :a_vihta)::jsonb, 'TILAUS-77') as g1 \gset
select is((:'g1'::jsonb ->> 'total')::numeric, 3 * :p_tue::numeric + 45 + 13, 'admin: yritysvaraus + lisäpalvelut, hinta oikein');
select (:'g1'::jsonb ->> 'order_id')::bigint as g1_order \gset
select is((select customer_kind from booking.orders where id = :g1_order), 'company', 'admin: tilaus on yritystilaus (asiakkaan tyyppi periytyy)');
select is((select billing ->> 'business_id' from booking.orders where id = :g1_order), '2336509-6', 'admin: laskutustietojen kuva asiakkaalta');
select is((select invoice_reference from booking.orders where id = :g1_order), 'TILAUS-77', 'admin: tilauskohtainen viite ohittaa asiakkaan oletusviitteen');
select is((select amount from booking.payments where order_id = :g1_order), 3 * :p_tue::numeric + 58, 'admin: maksurivin summa sis. lisäpalvelut');
select is((select count(*)::int from booking.order_items where order_id = :g1_order and kind = 'addon'), 2, 'admin: kaksi lisäpalvelurivia');
-- uusi yritysasiakas samalla lomakkeella
select booking.admin_create_booking(:r_tue, (:'tue'::date + 28), 2, null,
   '{"kind":"company","name":"Matti Yhteys","email":"matti@uusi.example.com","phone":"0401230000","company_details":{"company_name":"Uusi Oy","business_id":"1000002-0","street":"Uusikatu 5","zip":"20100","city":"Turku"}}'::jsonb,
   'invoice', false, null, null, null, null, 'email') as g2 \gset
select is((select customer_kind from booking.customers where email = 'matti@uusi.example.com'), 'company', 'admin: uusi yritysasiakas luodaan varauslomakkeelta');
select is((select billing ->> 'city' from booking.orders where id = (:'g2'::jsonb ->> 'order_id')::bigint), 'Turku', 'admin: laskutustietojen kuva tilauksella');
select is(test.code(format($$select booking.admin_create_booking(%s, current_date + 80, 1, null, '{"kind":"company","name":"Eka Toka","company_details":{"company_name":"X Oy","business_id":"1234567-0"}}'::jsonb)$$, :r_tue)), 'invalid_business_id', 'admin: virheellinen y-tunnus varauslomakkeella hylätään');
select is(test.code(format($$select booking.admin_create_booking(%s, %L, 2, null, '{"name":"Huono Email","email":"huono"}'::jsonb)$$, :r_tue, (:'tue'::date + 35))), 'invalid_email', 'admin: sähköposti validoidaan varauslomakkeella');
select is(test.code(format($$select booking.admin_create_booking(%s, %L, 2, null, '{"name":"Lisä Virhe","email":"lisa.virhe@example.com"}'::jsonb, 'pay_later', false, null, null, null, null, 'admin', '[{"code":"saunavihta","quantity":5}]'::jsonb)$$, :r_tue, (:'tue'::date + 35))), 'addon_quantity', 'admin: lisäpalvelun enimmäismäärä pätee');
select is((select count(*)::int from booking.customers where email = 'lisa.virhe@example.com'), 0, 'admin: epäonnistunut varaus ei jätä asiakasta (atominen)');
select booking.admin_create_booking(:r_priv, (:'fri'::date + 7), 4, null, '{"name":"Käsi Asiakas","email":"kasi@example.com"}'::jsonb, 'card_terminal', true, null, null, null, null, 'walk_in',
   '[{"code":"saunavihta","quantity":2}]'::jsonb) as g3 \gset
select is((select payment_status from booking.orders where id = (:'g3'::jsonb ->> 'order_id')::bigint), 'paid', 'admin: maksettu varaus lisäpalveluilla → paid');
select is((select amount from booking.payments where order_id = (:'g3'::jsonb ->> 'order_id')::bigint), (:'g3'::jsonb ->> 'total')::numeric, 'admin: maksettu summa = kokonaissumma');
select test.logout();

-- tilauksen tiedot (katselu)
select test.login(:'stf');
select is(booking.admin_get_order(:g1_order) ->> 'customer_kind', 'company', 'admin_get_order: asiakastyyppi');
select is(booking.admin_get_order(:g1_order) -> 'billing' ->> 'company', 'Firma Group Oy', 'admin_get_order: laskutustiedot (yritys)');
select is(jsonb_array_length(booking.admin_get_order(:g1_order) -> 'reservations' -> 0 -> 'addons'), 2, 'admin_get_order: varauksen lisäpalvelut');
select is(booking.admin_get_order(:g1_order) ->> 'invoice_reference', 'TILAUS-77', 'admin_get_order: viite');
select is(booking.admin_get_order(:g1_order) -> 'customer' ->> 'business_id', '2336509-6', 'admin_get_order: asiakkaan y-tunnus');
select is(test.code($$select booking.admin_get_order(99999999)$$), 'not_found', 'admin_get_order: tuntematon tilaus');
select test.logout();

-- ================= H) lisäpalveluiden ylläpito (catalog.edit) + hinnan muutos ei kosketa vanhoja tilauksia =================
select test.login(:'stf');
select is(jsonb_array_length(booking.admin_list_addons()), 3, 'staff näkee lisäpalvelut hallinnassa');
select throws_ok($$select booking.admin_update_addon(1, '{"price":99}')$$, 'BK001', 'Ei oikeutta tähän toimintoon (catalog.edit)', 'staff: ei oikeutta catalog.edit');
select throws_ok($$select booking.admin_create_addon('{"code":"uusi","name":"Uusi","price":5}')$$, 'BK001', 'Ei oikeutta tähän toimintoon (catalog.edit)', 'staff ei luo lisäpalvelua');
select test.logout();
select test.login(:'mgr');
select lives_ok(format($$select booking.admin_update_addon(%s, '{"name":"Saunavihta (koivu)","name_en":"Birch whisk","description":"Koivuvihta","price":14.50,"active":true}')$$, :a_vihta), 'manager muokkaa lisäpalvelun nimeä, kuvausta ja hintaa');
select is((select price_gross from booking.addons where id = :a_vihta), 14.50, 'hinta päivittyi');
select is((select name from booking.addons where id = :a_vihta), 'Saunavihta (koivu)', 'nimi päivittyi');
select is((select unit_price_gross from booking.order_items where order_id = :g1_order and addon_id = :a_vihta), 13.00, 'vanhan tilauksen rivin hinta ei muutu hintamuutoksessa (rivi on kuva)');
select is((select name_en from booking.addons where id = :a_vihta), 'Birch whisk', 'englanninkielinen nimi tallentuu');
select is(test.code(format($$select booking.admin_update_addon(%s, '{"price":-1}')$$, :a_vihta)), 'invalid_price', 'negatiivinen hinta hylätään');
select is(test.code(format($$select booking.admin_update_addon(%s, '{"price":"abc"}')$$, :a_vihta)), 'invalid_price', 'hinta ei-numero hylätään');
select is(test.code(format($$select booking.admin_update_addon(%s, '{"vat_rate":19}')$$, :a_vihta)), 'invalid_vat', 'ALV-kanta tarkistetaan sallitusta listasta');
select is(test.code(format($$select booking.admin_update_addon(%s, '{"name":""}')$$, :a_vihta)), 'invalid_name', 'tyhjä nimi hylätään');
select is(test.code(format($$select booking.admin_update_addon(%s, '{"code":"toinen"}')$$, :a_vihta)), 'unknown_field', 'koodia ei voi vaihtaa');
select is(test.code(format($$select booking.admin_update_addon(%s, '{"applies_modes":["foo"]}')$$, :a_vihta)), 'invalid_modes', 'tuntematon vuorotyyppi hylätään');
select is(test.code(format($$select booking.admin_update_addon(%s, '{"max_per_person":0}')$$, :a_vihta)), 'invalid_max', 'max / henkilö 1–20');
select is(test.code($$select booking.admin_update_addon(999999, '{"price":1}')$$), 'not_found', 'tuntematon lisäpalvelu');
select lives_ok($$select booking.admin_create_addon('{"code":"kahvi","name":"Kahvi ja pulla","name_en":"Coffee","price":"4,50","vat_rate":14,"max_per_person":2,"applies_modes":["shared"]}')$$, 'manager luo uuden lisäpalvelun');
select is((select price_gross || '|' || vat_rate || '|' || max_per_person from booking.addons where code = 'kahvi'), '4.50|14.00|2', 'uusi lisäpalvelu: hinta (pilkku → piste), ALV 14 %, max 2');
select is(test.code($$select booking.admin_create_addon('{"code":"kahvi","name":"Kahvi","price":4}')$$), 'code_exists', 'tunnus on yksilöllinen');
select is(test.code($$select booking.admin_create_addon('{"code":"Iso Kirjain","name":"Kahvi","price":4}')$$), 'invalid_code', 'tunnuksen muoto tarkistetaan');
select is(test.code($$select booking.admin_create_addon('{"code":"ilman_hintaa","name":"Kahvi"}')$$), 'invalid_price', 'hinta vaaditaan');
select lives_ok($$select booking.admin_update_addon((select id from booking.addons where code = 'kahvi'), '{"active":false}')$$, 'lisäpalvelun voi passivoida');
select test.logout();
select ok((select count(*) from booking.audit_log where table_name like '%addons') > 0, 'lisäpalvelumuutokset kirjautuvat audit-lokiin');
select test.anon('10.9.0.5');
select is(jsonb_array_length(booking.public_addons()), 3, 'public_addons: passiivinen kahvi piilossa, hintamuutos näkyy');
select is((booking.public_addons() -> 1 ->> 'price')::numeric, 14.50, 'public_addons: uusi hinta näkyy kaupassa');
select is((select count(*)::int from jsonb_array_elements(booking.public_addons()) e where e ->> 'code' = 'kahvi'), 0, 'passiivinen ei näy');
-- uusi hinta koskee uusia tilauksia
select booking.public_create_booking(:r_tue, (:'tue'::date + 42), 1, 'Uusi Hinta', 'uusihinta@example.com', '0401234567', false, 'fi', null, 'private', null, '[{"code":"saunavihta","quantity":1}]') as h1 \gset
select is((:'h1'::jsonb ->> 'addons_total')::numeric, 14.50, 'uusi hinta koskee uusia tilauksia');
select test.logout();

-- ================= I) lisäpalveluiden muokkaus olemassa olevalla varauksella =================
select test.login(:'stf');
select (select id from booking.reservations where order_id = :g1_order) as g1_res \gset
select is((booking.admin_set_reservation_addons(:g1_res, '[{"code":"saunavihta","quantity":2}]'::jsonb) ->> 'total')::numeric, 3 * :p_tue::numeric + 29, 'korvaus: uusi kokonaissumma (3 × vuoro + 2 × 14,50)');
select is((select count(*)::int from booking.order_items where order_id = :g1_order and kind = 'addon'), 1, 'korvaus: vanhat rivit poistettu, uusi lisätty');
select is((select amount from booking.payments where order_id = :g1_order), 3 * :p_tue::numeric + 29, 'korvaus: odottava maksu päivittyi');
select is(test.code(format($$select booking.admin_set_reservation_addons(%s, '[{"code":"saunavihta","quantity":9}]')$$, :g1_res)), 'addon_quantity', 'korvaus: enimmäismäärä pätee');
select is((select count(*)::int from booking.order_items where order_id = :g1_order and kind = 'addon'), 1, 'korvaus: virhe ei kosketa rivejä (atominen)');
select lives_ok(format($$select booking.admin_set_reservation_addons(%s, '[]')$$, :g1_res), 'korvaus: tyhjä lista poistaa lisäpalvelut');
select is((select total_gross from booking.orders where id = :g1_order), 3 * :p_tue::numeric, 'korvaus: summa palaa pelkkään vuoroon');
select is(test.code($$select booking.admin_set_reservation_addons(999999, '[]')$$), 'not_found', 'korvaus: tuntematon varaus');
select test.logout();

-- ================= J) päivänäkymä: lisäpalvelut ja "valmistele"-yhteenveto =================
select test.login(:'stf');
select booking.admin_create_booking(:r_tue, (:'tue'::date + 49), 2, null, '{"name":"Päivä Yksi","email":"paiva1@example.com"}'::jsonb, 'pay_later', false, null, null, null, null, 'admin',
   '[{"code":"saunavihta","quantity":2},{"code":"turvenaamio_jalkakylpy","quantity":1}]'::jsonb) as d1 \gset
select booking.admin_create_booking(:r_tue, (:'tue'::date + 49), 3, null, '{"name":"Päivä Kaksi","email":"paiva2@example.com"}'::jsonb, 'pay_later', false, null, null, null, null, 'admin',
   '[{"code":"saunavihta","quantity":3}]'::jsonb) as d2 \gset
select booking.admin_create_booking(:r_tue, (:'tue'::date + 49), 1, null, '{"name":"Päivä Kolme","email":"paiva3@example.com"}'::jsonb, 'pay_later', false, null, null, null, null, 'admin',
   '[{"code":"saunavihta","quantity":1}]'::jsonb) as d3 \gset
select booking.admin_create_booking(:r_tue, (:'tue'::date + 49), 1, null, '{"name":"Päivä Ei","email":"paiva4@example.com"}'::jsonb) as d4 \gset
select booking.admin_set_reservation_status((:'d3'::jsonb ->> 'reservation_id')::bigint, 'cancelled', 'testi');
select booking.admin_day_view((:'tue'::date + 49)) as dv \gset
select is(jsonb_array_length(:'dv'::jsonb -> 'prep'), 1, 'päivänäkymä: yksi valmisteltava vuoro (sama vuoro yhdistetään)');
select is((select sum((i ->> 'quantity')::int)::int from jsonb_array_elements(:'dv'::jsonb -> 'prep' -> 0 -> 'items') i where i ->> 'name' like 'Saunavihta%'), 5, 'päivänäkymä: vihdat yhteensä 5 (2 + 3; peruttu 1 ei mukana)');
select is((select sum((i ->> 'quantity')::int)::int from jsonb_array_elements(:'dv'::jsonb -> 'prep' -> 0 -> 'items') i where i ->> 'name' like 'Turvenaamio%'), 1, 'päivänäkymä: turvenaamiot 1');
select is((select sum((i ->> 'quantity')::int)::int from jsonb_array_elements(:'dv'::jsonb -> 'addon_totals') i where i ->> 'name' like 'Saunavihta%'), 5, 'päivänäkymä: päivän summa per lisäpalvelu (vihta 5)');
select ok(:'dv'::jsonb -> 'prep' -> 0 ? 'starts_at' and :'dv'::jsonb -> 'prep' -> 0 ? 'product_name', 'päivänäkymä: valmistele-rivillä vuoron aika ja tuote');
select is((select count(*)::int from jsonb_array_elements(:'dv'::jsonb -> 'reservations') r where jsonb_array_length(r -> 'addons') > 0), 2, 'päivänäkymä: kahdella aktiivisella varauksella lisäpalveluita');
select is((select count(*)::int from jsonb_array_elements(:'dv'::jsonb -> 'reservations')), 3, 'päivänäkymä: peruttu varaus ei listalla');
select is((select count(*)::int from jsonb_array_elements(:'dv'::jsonb -> 'reservations') r where r ? 'customer_kind'), 3, 'päivänäkymä: asiakastyyppi mukana');
select is(jsonb_array_length(booking.admin_day_view((:'tue'::date + 56)) -> 'prep'), 0, 'päivä ilman lisäpalveluita: prep tyhjä');
select test.logout();

-- ================= K) varauksen muutos + lisäpalvelut =================
select test.anon('10.9.0.6');
select booking.public_create_booking(:r_tue, (:'tue'::date + 63), 3, 'Muutos Vihta', 'muutosvihta@example.com', '0401234567', false, 'fi', null, 'private', null,
   '[{"code":"saunavihta","quantity":3}]'::jsonb) as m1 \gset
select (:'m1'::jsonb ->> 'token') as mtok \gset
select (:'m1'::jsonb ->> 'total')::numeric as m1_total \gset
select is(:m1_total, 3 * :p_tue::numeric + 43.50, 'muutostesti: lähtösumma (3 × vuoro + 3 × 14,50)');
select is((booking.public_change_booking(:'mtok'::uuid, null, null, 2) ->> 'ok')::boolean, true, 'henkilömäärän vähennys onnistuu');
select test.logout();
select is((select quantity from booking.order_items i join booking.orders o on o.id = i.order_id where o.public_token = :'mtok'::uuid and i.kind = 'addon'), 2, 'lisäpalvelun määrä rajattu uuteen henkilömäärään (3 → 2)');
select is((select total_gross from booking.orders where public_token = :'mtok'::uuid), 2 * :p_tue::numeric + 29, 'tilauksen summa päivittyi (2 × vuoro + 2 × 14,50)');
select is((select amount from booking.payments p join booking.orders o on o.id = p.order_id where o.public_token = :'mtok'::uuid), 2 * :p_tue::numeric + 29, 'odottava maksu päivittyi koko tilauksen summaan');
-- maksettu tilaus + lisäpalvelut: siirto samanhintaiseen vuoroon sallittu (ei virheellistä hintamuutosta), henkilömäärän muutos ei
select (select id from booking.orders where public_token = :'mtok'::uuid) as m_order \gset
select test.login(:'stf');
select booking.admin_record_payment(:m_order, 'card_terminal', 2 * :p_tue::numeric + 29, null);
select test.logout();
select is((select payment_status from booking.orders where id = :m_order), 'paid', 'maksettu kokonaan (lisäpalvelut mukana)');
select test.anon('10.9.0.6');
select is((booking.public_change_booking(:'mtok'::uuid, :r_tue, (:'tue'::date + 70), null) ->> 'ok')::boolean, true, 'maksettu tilaus lisäpalveluilla: siirto samanhintaiseen vuoroon sallittu');
select is(booking.public_change_booking(:'mtok'::uuid, null, null, 1) ->> 'code', 'price_change_requires_staff', 'maksettu tilaus: henkilömäärän muutos (hinta muuttuu) vaatii henkilökunnan');
select test.logout();
select is((select total_gross from booking.orders where id = :m_order), 2 * :p_tue::numeric + 29, 'maksetun tilauksen summa ennallaan epäonnistuneen muutoksen jälkeen');
select is((select payment_status from booking.orders where id = :m_order), 'paid', 'ja maksutila edelleen paid');

-- ================= L) integriteetti =================
select throws_ok($$insert into booking.addons(code, name, price_gross, vat_rate) values ('huono_alv','X',1,19)$$, '23514', null, 'addons: ALV-kanta rajoitettu sallittuihin');
select throws_ok($$insert into booking.addons(code, name, price_gross) values ('negatiivinen','X',-1)$$, '23514', null, 'addons: negatiivinen hinta estetty');
select throws_ok($$insert into booking.addons(code, name, price_gross, applies_modes) values ('tyhja_modes','X',1,'{}')$$, '23514', null, 'addons: tyhjä vuorotyyppilista estetty');
select throws_ok($$insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, addon_id) select id, 'X', 'product', 1, 1, 1, 25.5, (select id from booking.addons limit 1) from booking.orders limit 1$$, '23514', null, 'order_items: addon_id vaatii kind = addon');

-- ================= M) lisäyksiä: muutosnäkymän tiedot, funktiooikeudet =================
select test.anon('10.9.0.7');
select is((booking.public_get_booking(:'tok1'::uuid) -> 'addons' -> 0 ->> 'max_per_person')::int, 1, 'get_booking: lisäpalvelun max_per_person (kauppa rajaa määrän muutosnäkymässä)');
select is((booking.public_get_booking(:'tok1'::uuid) -> 'addons' -> 0 ->> 'unit_price')::numeric, 15.00, 'get_booking: rivin hinta (kuva tilaushetkestä)');
select throws_ok($$select booking._attach_addons(1, '[]')$$, '42501', null, 'anon ei kutsu sisäistä _attach_addons-funktiota');
select throws_ok($$select booking._clean_company('{}')$$, '42501', null, 'anon ei kutsu sisäistä _clean_company-funktiota');
select test.logout();
select test.login(:'stf');
select throws_ok($$select booking._stamp_order_billing(1, 1)$$, '42501', null, 'authenticated ei kutsu sisäistä _stamp_order_billing-funktiota');
select throws_ok($$select booking._upsert_company_customer('company','A B','a@example.com','0401234567','{}',false,'x','fi',null)$$, '42501', null, 'authenticated ei kutsu sisäistä _upsert_company_customer-funktiota');
select test.logout();
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'booking' and p.proname ~ 'addon|company|customer_kind|business_id|_stamp_order_billing|_valid_email|admin_create_customer|admin_get_order|admin_day_view|public_create_booking|public_get_booking'
              and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c = 'search_path=""')), 0, 'migraation 11 funktioilla (kaikki uudet/uudelleenmääritellyt) search_path on tyhjä');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'booking' and p.proname in ('_attach_addons','_clamp_addons','_addon_total_after','_stamp_order_billing','_upsert_company_customer') and p.prosecdef), 5, 'lisäpalvelu- ja asiakastyyppifunktiot, jotka kirjoittavat tauluihin, ovat SECURITY DEFINER');

select * from finish();
rollback;
