-- Vuosikortti: vapaa varaus vain yleiselle vuorolle, yksi tuleva varaus kerrallaan, moottoritason pakotus
begin;
set local search_path = extensions, public;
select no_plan();

select test.mk_staff('ac-admin@example.com', 'admin') as aid, test.mk_staff('ac-manager@example.com', 'manager') as mid,
       test.mk_staff('ac-staff@example.com', 'staff') as sid \gset
select test.next_dow(2, 6) as tue, test.next_dow(2, 80) as tue_far, test.next_dow(2, 420) as tue_late \gset
select test.rule('Naisten sauna%') as r_tue, test.rule('Oma savusaunavuoro ma–pe 16–19%') as r_priv \gset
insert into booking.customers(name, email, phone) values ('Kortti Kalle', 'kortti@example.com', '0401111111'), ('Kortti Kaisa', 'kortti2@example.com', '0402222222'),
       ('Ei Korttia', 'eikorttia@example.com', '0403333333'), ('Kortti Kolmas', 'kortti3@example.com', '0404444444');
select (select id from booking.customers where email = 'kortti@example.com') as c1,
       (select id from booking.customers where email = 'kortti2@example.com') as c2,
       (select id from booking.customers where email = 'eikorttia@example.com') as c0,
       (select id from booking.customers where email = 'kortti3@example.com') as c3 \gset

-- ---------- myöntäminen: oikeudet ----------
select test.login(:'sid');
select throws_ok(format($$select booking.admin_grant_annual_card(%s, current_date - 1, current_date + 60)$$, :c1), 'BK001', 'Ei oikeutta tähän toimintoon (annual_cards.manage)', 'staff ei voi myöntää vuosikorttia');
select throws_ok(format($$select booking.admin_revoke_annual_card(%s)$$, 1), 'BK001', 'Ei oikeutta tähän toimintoon (annual_cards.manage)', 'staff ei voi peruuttaa vuosikorttia');
select test.logout();
select test.login(:'mid');
select is((booking.admin_grant_annual_card(:c1, current_date - 1, current_date + 60, 'testikortti') ->> 'ok')::boolean, true, 'manager voi myöntää vuosikortin');
select (booking.admin_grant_annual_card(:c1 + 0, current_date + 61, current_date + 400) ->> 'id')::bigint as card1b \gset
select is(test.code(format($$select booking.admin_grant_annual_card(%s, current_date + 10, current_date + 100)$$, :c1)), 'annual_card_overlap', 'päällekkäinen kortti estetty');
select is(test.code(format($$select booking.admin_grant_annual_card(%s, current_date + 10, current_date + 5)$$, :c2)), 'invalid_dates', 'virheellinen voimassaoloaika estetty');
select is(test.code($$select booking.admin_grant_annual_card(999999, current_date, current_date + 5)$$), 'customer_not_found', 'tuntematon asiakas');
select is(test.code(format($$select booking.admin_update_customer(%s, '{"customer_type": "annual_card"}')$$, :c0)), 'unknown_field', 'customer_type ei ole suoraan muokattavissa');
select test.logout();
select is((select customer_type from booking.customers where id = :c1), 'annual_card', 'myöntäminen asettaa asiakastyypin annual_card');
select is((select customer_type from booking.customers where id = :c0), 'customer', 'muut pysyvät customer-tyyppisinä');
select (select id from booking.annual_cards where customer_id = :c1 and valid_from = current_date - 1) as card1 \gset

-- ---------- vuosikorttivaraus ----------
select test.login(:'sid');
select booking.admin_create_annual_card_booking(:c1, :r_tue, :'tue', 'kortilla') ->> 'reservation_id' as rid1 \gset
select is((select persons from booking.reservations where id = :rid1), 1, 'vuosikorttivaraus: 1 henkilö');
select is((select annual_card_id from booking.reservations where id = :rid1), :card1::bigint, 'vuosikorttivaraus: annual_card_id asetettu');
select is((select status from booking.reservations where id = :rid1), 'confirmed', 'vuosikorttivaraus: vahvistettu');
select is((select o.total_gross from booking.orders o join booking.reservations r on r.order_id = o.id where r.id = :rid1), 0::numeric, 'vuosikorttivaraus: hinta 0 €');
select is((select o.payment_status from booking.orders o join booking.reservations r on r.order_id = o.id where r.id = :rid1), 'paid', 'vuosikorttivaraus: maksutila paid');
select is((select p.method from booking.payments p join booking.reservations r on r.order_id = p.order_id where r.id = :rid1), 'annual_card', 'vuosikorttivaraus: maksutapa annual_card');
select is(test.code(format($$select booking.admin_create_annual_card_booking(%s, %s, %L::date + 7)$$, :c1, :r_tue, :'tue')), 'annual_card_limit', 'toinen tuleva varaus estetty (annual_card_limit)');
select is(test.code(format($$select booking.admin_create_annual_card_booking(%s, %s, %L::date)$$, :c1, :r_priv, :'tue')), 'annual_card_shared_only', 'yksityisvuoro estetty vuosikortilla');
select is(test.code(format($$select booking.admin_create_annual_card_booking(%s, %s, %L::date)$$, :c0, :r_tue, :'tue')), 'no_annual_card', 'ilman korttia ei vuosikorttivarausta');
select is(test.code(format($$select booking.admin_create_annual_card_booking(%s, %s, %L::date)$$, :c1, :r_tue, :'tue_late')), 'no_annual_card', 'voimassaolon ulkopuolella ei vuosikorttivarausta');
select is((select count(*)::int from booking.reservations where annual_card_id = :card1 and status = 'confirmed'), 1, 'kortilla vain yksi vahvistettu varaus');
-- kapasiteetti kuluu normaalisti
select is((select remaining from booking.public_availability((select product_id from booking.schedule_rules where id = :r_tue), :'tue', :'tue') where rule_id = :r_tue), 15, 'vuosikorttivaraus kuluttaa 1 paikan');
-- peru → seuraava onnistuu
select is((booking.admin_set_reservation_status(:rid1, 'cancelled', 'testi') ->> 'ok')::boolean, true, 'vuosikorttivarauksen peruutus');
select is((booking.admin_create_annual_card_booking(:c1, :r_tue, (:'tue'::date + 7)) ->> 'reservation_id') is not null, true, 'peruutuksen jälkeen uusi vuosikorttivaraus onnistuu');
select test.logout();
select (select r.id from booking.reservations r where r.annual_card_id = :card1 and r.status = 'confirmed') as rid2 \gset

-- peruttua varausta ei voi aktivoida uudelleen jos se rikkoisi rajan (rid2 on jo tuleva varaus)
select test.login(:'sid');
select is(test.code(format($$select booking.admin_set_reservation_status(%s, 'confirmed')$$, :rid1)), 'annual_card_limit', 'peruttu vuosikorttivaraus ei aktivoidu uudelleen kun toinen tuleva varaus on olemassa');
-- admin_change_booking: henkilömäärä yli rajan
select is(test.code(format($$select booking.admin_change_booking(%s, null, null, 2)$$, :rid2)), 'annual_card_persons', 'vuosikorttivarauksen henkilömäärää ei voi nostaa yli rajan');
select is((booking.admin_change_booking(:rid2, :r_tue, (:'tue'::date + 14), null) ->> 'ok')::boolean, true, 'vuosikorttivarauksen siirto toiselle yleiselle vuorolle onnistuu');
select test.logout();

-- ---------- ohitusyritykset suoraan tietokannassa (trigger pakottaa) ----------
-- normaali maksullinen varaus, johon yritetään liittää kortti
select test.login(:'sid');
select booking.admin_create_booking(:r_tue, (:'tue'::date + 21), 2, null, '{"name": "Kortti Kalle", "email": "kortti@example.com", "phone": "0401111111"}', 'pay_later', false) ->> 'reservation_id' as rpay \gset
select booking.admin_create_booking(:r_tue, (:'tue'::date + 28), 1, null, '{"name": "Kortti Kaisa", "email": "kortti2@example.com", "phone": "0402222222"}', 'pay_later', false) ->> 'reservation_id' as rother \gset
select test.logout();
-- peru rid2 jotta raja ei peitä muita virheitä
update booking.reservations set status = 'cancelled' where id = :rid2;
select is(test.code(format($$update booking.reservations set annual_card_id = %s where id = %s$$, :card1, :rpay)), 'annual_card_must_be_free', 'ohitus: maksullista tilausta ei voi liittää korttiin');
update booking.orders set total_gross = 0 where id = (select order_id from booking.reservations where id = :rother);
select is(test.code(format($$update booking.reservations set annual_card_id = %s where id = %s$$, :card1, :rother)), 'annual_card_customer_mismatch', 'ohitus: toisen asiakkaan varausta ei voi liittää korttiin');
update booking.orders set total_gross = 0 where id = (select order_id from booking.reservations where id = :rpay);
select is(test.code(format($$update booking.reservations set annual_card_id = %s where id = %s$$, :card1, :rpay)), 'annual_card_persons', 'ohitus: 2 henkilöä kortilla estetty (raja 1)');
update booking.reservations set persons = 1 where id = :rpay;
select is(test.code(format($$update booking.reservations set annual_card_id = %s where id = %s$$, :card1, :rpay)), 'ok', 'ohitus: ehdot täyttävä varaus saa kortin');
select is(test.code(format($$update booking.reservations set annual_card_id = %s where id = %s$$, :card1, :rother)), 'annual_card_customer_mismatch', 'ohitus: asiakasristiriita edelleen estetty');
-- toisen asiakkaan kortti, varaus kortin voimassaolon jälkeen
update booking.orders set customer_id = :c2 where id = (select order_id from booking.reservations where id = :rother);
select test.login(:'mid');
select booking.admin_grant_annual_card(:c2, current_date, current_date + 20, null) ->> 'id' as card2 \gset
select test.logout();
select is(test.code(format($$update booking.reservations set annual_card_id = %s where id = %s$$, :card2, :rother)), 'annual_card_expired', 'ohitus: kortti ei voimassa vuoron päivänä');
-- yksityisvuoro
select test.next_dow(3, 10) as wed \gset
select test.login(:'sid');
select booking.admin_create_booking(:r_priv, :'wed', 4, null, '{"name": "Kortti Kolmas", "email": "kortti3@example.com", "phone": "0404444444"}', 'pay_later', false) ->> 'reservation_id' as rpriv \gset
select test.logout();
update booking.orders set total_gross = 0 where id = (select order_id from booking.reservations where id = :rpriv);
update booking.reservations set persons = 1 where id = :rpriv;
select test.login(:'mid');
select booking.admin_grant_annual_card(:c3, current_date, current_date + 60, null) ->> 'id' as card3 \gset
select test.logout();
select is(test.code(format($$update booking.reservations set annual_card_id = %s where id = %s$$, :card3, :rpriv)), 'annual_card_shared_only', 'ohitus: yksityisvuoro estetty triggerissä');

-- ---------- asetus annual_card_max_persons ----------
select test.login(:'mid');
select is((booking.admin_set_setting('annual_card_max_persons', '2') ->> 'ok')::boolean, true, 'manager muuttaa annual_card_max_persons');
select test.logout();
select is(test.code(format($$update booking.reservations set persons = 2 where id = %s$$, :rpay)), 'ok', 'asetuksella 2 henkilöä sallitaan kortilla');
select is(test.code(format($$update booking.reservations set persons = 3 where id = %s$$, :rpay)), 'annual_card_persons', '3 henkilöä edelleen estetty');
update booking.settings set value = '1' where key = 'annual_card_max_persons';
update booking.reservations set persons = 1 where id = :rpay;

-- ---------- päivitys ja peruutus ----------
select test.login(:'mid');
select is(test.code(format($$select booking.admin_update_annual_card(%s, '{"valid_to": "%s"}')$$, :card1, current_date + 62)), 'annual_card_overlap', 'voimassaolon jatko päällekkäin seuraavan kortin kanssa estetty');
select is((booking.admin_update_annual_card(:card1, '{"notes": "päivitetty"}') ->> 'ok')::boolean, true, 'kortin muistiinpanon päivitys');
select is(test.code(format($$select booking.admin_update_annual_card(%s, '{"active": true}')$$, :card1)), 'unknown_field', 'active ei ole suoraan muokattavissa');
select is((select count(*)::int from booking.admin_list_annual_cards(:c1, false)), 2, 'admin_list_annual_cards: asiakkaan kortit');
select is(jsonb_array_length(booking.admin_get_customer(:c1) -> 'annual_cards'), 2, 'admin_get_customer sisältää vuosikortit');
select is((booking.admin_revoke_annual_card(:card1, false) ->> 'future_reservations')::int, 1, 'peruutus ilman cancel_future: tulevat varaukset säilyvät');
select is((select status from booking.reservations where id = :rpay), 'confirmed', 'varaus säilyi vahvistettuna');
select is((select active from booking.annual_cards where id = :card1), false, 'kortti ei ole aktiivinen');
select is((booking.admin_revoke_annual_card(:card1, true) ->> 'cancelled')::int, 1, 'peruutus cancel_future: perui tulevan varauksen');
select is((select status from booking.reservations where id = :rpay), 'cancelled', 'tuleva varaus peruttu');
select is(test.code(format($$select booking.admin_set_reservation_status(%s, 'confirmed')$$, :rpay)), 'annual_card_inactive', 'ei-aktiivisen kortin varausta ei voi aktivoida');
select test.logout();

-- ---------- julkinen varaus ei saa korttia / asiakas ei voi itse ----------
select test.anon('10.8.0.1');
select (test.pub_book(:r_tue, (:'tue'::date + 35), 1, 'kortti2@example.com') ->> 'token') as tokp \gset
select test.logout();
select is((select annual_card_id from booking.reservations r join booking.orders o on o.id = r.order_id where o.public_token = :'tokp'::uuid), null, 'julkinen varaus ei liity korttiin');
select ok((select o.total_gross from booking.orders o where o.public_token = :'tokp'::uuid) > 0, 'julkinen varaus on maksullinen vaikka asiakkaalla olisi kortti');

-- ---------- RLS ----------
select test.anon();
select throws_ok($$select * from booking.annual_cards$$, '42501', null, 'anon ei lue annual_cards');
select test.logout();
select test.mk_user('ac-asiakas@example.com') as nsid \gset
select test.login(:'nsid');
select is((select count(*)::int from booking.annual_cards), 0, 'ei-henkilöstö ei näe vuosikortteja');
select throws_ok($$insert into booking.annual_cards(customer_id, valid_from, valid_to) values (1, current_date, current_date)$$, '42501', null, 'ei-henkilöstö ei voi lisätä vuosikorttia');
select test.logout();
select test.login(:'sid');
select ok((select count(*) from booking.annual_cards) >= 3, 'staff näkee vuosikortit');
select throws_ok($$update booking.annual_cards set valid_to = current_date + 9999$$, '42501', null, 'staff ei voi muokata vuosikortteja suoraan');
select test.logout();

select * from finish();
rollback;
