-- Asiakkaan oma varauksen MUUTTAMINEN (public_change_booking, tokenilla) ja henkilökunnan admin_change_booking:
-- siirto toiseen vapaaseen vuoroon samalle tuotteelle / henkilömäärän muutos; 48 h ennakkoraja; atomisuus; päällekkäisyys- ja kapasiteettisäännöt.
-- Asiakas EI voi peruuttaa vahvistettua varausta (public_cancel_booking vapauttaa vain maksamattoman pidon).
begin;
set local search_path = extensions, public;
select no_plan();

select test.next_dow(2, 6) as tue, test.next_dow(1, 6) as mon, test.next_dow(4, 6) as thu, test.next_dow(5, 6) as fri, test.next_dow(6, 6) as sat,
       test.rule('Naisten sauna%') as r_tue, test.rule('Miesten sauna%') as r_mon, test.rule('Yleinen vuoro to 17–19') as r_thu,
       test.rule('Oma savusaunavuoro ma–pe 16–19%') as r_priv, test.rule('Jälkilöylyt ma–to 19–21%') as r_after,
       test.rule('Yleinen vuoro la–su 14:00%') as r_sat1400, test.rule('Yleinen vuoro la–su 14:30%') as r_sat1430,
       test.rule('Tunnin saunavuoro la–su 14:00') as r_h14 \gset
select p.price as p_tue, p.id as prod_tue from booking.schedule_rules r join kb.products p on p.id = r.product_id where r.id = :r_tue \gset
select test.mk_staff('chg-staff@example.com', 'staff') as sid, test.mk_staff('chg-admin@example.com', 'admin') as aid \gset

update booking.settings set value = '1000' where key in ('rl_change_per_10min', 'rl_ip_per_10min', 'rl_email_per_10min');
select is((select value from booking.settings where key = 'customer_change_hours_before'), '48'::jsonb, 'asetus customer_change_hours_before = 48');
select is((select is_public from booking.settings where key = 'customer_change_hours_before'), true, 'asetus on julkinen (kauppa näyttää rajan)');

-- ---------- perusmuutokset ----------
select test.anon('10.5.0.1');
select booking.public_create_booking(:r_tue, :'tue', 3, 'Muutos Asiakas', 'muutos@example.com', '0401234567') as b1 \gset
select (:'b1'::jsonb ->> 'token') as tok1 \gset
select is((booking.public_get_booking(:'tok1'::uuid) ->> 'can_change')::boolean, true, 'get_booking: can_change = true (yli 48 h)');
select is((booking.public_get_booking(:'tok1'::uuid) ->> 'change_hours_before')::int, 48, 'get_booking: change_hours_before = 48');
select is((booking.public_get_booking(:'tok1'::uuid) -> 'items' -> 0 ->> 'rule_id')::bigint, :r_tue::bigint, 'get_booking: item sisältää rule_id (muutosnäkymä)');
select ok(booking.public_get_booking(:'tok1'::uuid) -> 'items' -> 0 ? 'product_id', 'get_booking: item sisältää product_id');
select ok(not (booking.public_get_booking(:'tok1'::uuid)::text ~* 'example\.com|0401234567|Asiakas'), 'get_booking ei vuoda henkilötietoja muutoskentistäkään');

-- henkilömäärä 3 → 5 (aika säilyy)
select is((booking.public_change_booking(:'tok1'::uuid, null, null, 5) ->> 'ok')::boolean, true, 'C1: henkilömäärän muutos 3 → 5');
select is((test.res(:'tok1'::uuid)).persons, 5, 'C1: varauksen henkilömäärä 5');
select is((test.ord(:'tok1'::uuid)).total_gross, 5 * :p_tue::numeric, 'C1: tilauksen summa päivittyi (5 x hinta)');
select is((test.item(:'tok1'::uuid)).line_total_gross, 5 * :p_tue::numeric, 'C1: tilausrivin summa päivittyi');
select is((test.pay(:'tok1'::uuid)).amount, 5 * :p_tue::numeric, 'C1: maksamattoman maksurivin summa päivittyi');
select is((test.res(:'tok1'::uuid)).status, 'confirmed', 'C1: varaus pysyy vahvistettuna');
select is(test.audit_n('CUSTOMER_CHANGE'), 1, 'C1: muutos kirjattu audit-lokiin (CUSTOMER_CHANGE)');

-- siirto toiselle päivälle (sama sääntö)
select is((booking.public_change_booking(:'tok1'::uuid, :r_tue, (:'tue'::date + 7), null) ->> 'ok')::boolean, true, 'C2: siirto seuraavalle viikolle');
select is(test.hel_date((test.res(:'tok1'::uuid)).starts_at), (:'tue'::date + 7), 'C2: varaus on uudella päivällä');
select is(test.cnt_res(:'tok1'::uuid), 1, 'C2: edelleen yksi varaus (ei kaksoisvarausta)');
select is((select remaining from booking.public_availability(:prod_tue, :'tue', :'tue') where session_date = :'tue'), 16, 'C2: vanha vuoro vapautui kokonaan');
select is((select remaining from booking.public_availability(:prod_tue, (:'tue'::date + 7), (:'tue'::date + 7))), 11, 'C2: uusi vuoro kuluttaa 5 paikkaa');

-- virheelliset muutokset
select is(booking.public_change_booking(:'tok1'::uuid, :r_mon, :'mon', null) ->> 'code', 'product_mismatch', 'C3: toisen tuotteen vuoroon ei voi siirtää');
select is(booking.public_change_booking(:'tok1'::uuid, :r_tue, :'mon', null) ->> 'code', 'no_session', 'C4: väärä viikonpäivä hylätään');
select is(booking.public_change_booking(:'tok1'::uuid, :r_tue, (:'tue'::date + 8), null) ->> 'code', 'no_session', 'C4b: päivä jolle sääntöä ei ole');
select is(booking.public_change_booking(:'tok1'::uuid, :r_tue, null, null) ->> 'code', 'invalid_change', 'C5: sääntö ilman päivää hylätään');
select is(booking.public_change_booking(:'tok1'::uuid, null, null, null) ->> 'code', 'invalid_change', 'C5b: ei muutettavaa');
select is(booking.public_change_booking(:'tok1'::uuid, null, null, 0) ->> 'code', 'invalid_persons', 'C6: nolla henkilöä hylätään');
select is(booking.public_change_booking(:'tok1'::uuid, null, null, 17) ->> 'code', 'persons_max', 'C6b: yli säännön enimmäismäärän hylätään');
select is(booking.public_change_booking(:'tok1'::uuid, :r_tue, current_date - 3, null) ->> 'code', 'invalid_date', 'C7: menneeseen päivään ei voi siirtää');
select is(booking.public_change_booking(gen_random_uuid(), null, null, 2) ->> 'code', 'not_found', 'C8: tuntematon token');
select is(booking.public_change_booking(null, null, null, 2) ->> 'code', 'not_found', 'C8b: tyhjä token');
select is((test.res(:'tok1'::uuid)).persons, 5, 'C9: epäonnistuneet muutokset eivät muuttaneet varausta');

-- ---------- kapasiteetti: atomisuus ja oma paikka ei kuluta kahdesti ----------
select booking.public_create_booking(:r_tue, (:'tue'::date + 14), 10, 'Täysi Toinen', 'toinen1@example.com', '0401234567') ->> 'ok' as _ \gset
select booking.public_create_booking(:r_tue, (:'tue'::date + 14), 6, 'Täysi Kolmas', 'toinen2@example.com', '0401234567') ->> 'ok' as _ \gset
select is((select status from booking.public_availability(:prod_tue, (:'tue'::date + 14), (:'tue'::date + 14))), 'full', 'K1: kohdevuoro on täynnä');
select is(booking.public_change_booking(:'tok1'::uuid, :r_tue, (:'tue'::date + 14), null) ->> 'code', 'capacity_exceeded', 'K2: siirto täyteen vuoroon estyy');
select is(test.hel_date((test.res(:'tok1'::uuid)).starts_at), (:'tue'::date + 7), 'K3: virheen jälkeen varaus on edelleen vanhalla paikallaan (atomisuus)');
select is((select status from booking.public_availability(:prod_tue, (:'tue'::date + 7), (:'tue'::date + 7))), 'available', 'K3b: vanha vuoro ei vapautunut tai kadonnut virheen takia');
-- oma paikka: vuoro (tue+14) täynnä, toisen asiakkaan varauksen muutos henkilömäärään (10 → 9 → 10) onnistuu
select (booking.public_create_booking(:r_tue, (:'tue'::date + 21), 10, 'Oma Paikka', 'omapaikka@example.com', '0401234567') ->> 'token') as tokp \gset
select booking.public_create_booking(:r_tue, (:'tue'::date + 21), 6, 'Muu Asiakas', 'muu@example.com', '0401234567') ->> 'ok' as _ \gset
select is((booking.public_change_booking(:'tokp'::uuid, null, null, 9) ->> 'ok')::boolean, true, 'K4: täydessä vuorossa oman henkilömäärän vähennys onnistuu');
select is((booking.public_change_booking(:'tokp'::uuid, null, null, 10) ->> 'ok')::boolean, true, 'K5: oma vapautettu paikka ei kulu kahdesti (9 → 10 onnistuu)');
select is(booking.public_change_booking(:'tokp'::uuid, null, null, 11) ->> 'code', 'capacity_exceeded', 'K6: kapasiteetin ylitys (11) estyy');
select is((booking.public_change_booking(:'tokp'::uuid, :r_tue, (:'tue'::date + 21), 10) ->> 'ok')::boolean, true, 'K7: siirto samaan vuoroon (ei muutosta) onnistuu');
select test.logout();

-- ---------- päällekkäisyys: samat säännöt kuin uudella varauksella (molempiin suuntiin) ----------
select test.anon('10.5.0.2');
-- yksityisvuoro to 16–19 → asiakkaan yleinen vuoro ei voi siirtyä sille päivälle
select is((test.pub_book(:r_priv, (:'thu'::date + 7), 4) ->> 'ok')::boolean, true, 'P1: yksityisvuoro to+7 16–19');
select (test.pub_book(:r_thu, :'thu', 2) ->> 'token') as tokt \gset
select is(booking.public_change_booking(:'tokt'::uuid, :r_thu, (:'thu'::date + 7), null) ->> 'code', 'private_booked', 'P2: yleistä vuoroa ei voi siirtää yksityisvuoron päälle');
select is(test.hel_date((test.res(:'tokt'::uuid)).starts_at), :'thu'::date, 'P3: varaus ei liikkunut');
-- yleinen vuoro (to+14) varattu → yksityisvuoro ei voi siirtyä sille päivälle
select (test.pub_book(:r_priv, :'fri', 4) ->> 'token') as tokpr \gset
select is((test.pub_book(:r_thu, (:'thu'::date + 14), 1) ->> 'ok')::boolean, true, 'P4: yksi paikka yleiselle torstain vuorolle to+14');
select is(booking.public_change_booking(:'tokpr'::uuid, :r_priv, (:'thu'::date + 14), null) ->> 'code', 'public_shift_booked', 'P5: yksityisvuoroa ei voi siirtää päivälle, jolla yleisellä vuorolla on varaus');
select is(booking.public_change_booking(:'tokpr'::uuid, :r_priv, (:'thu'::date + 7), null) ->> 'code', 'private_booked', 'P6: yksityisvuoroa ei voi siirtää toisen yksityisvuoron päälle');
select is((booking.public_change_booking(:'tokpr'::uuid, :r_priv, (:'fri'::date + 7), null) ->> 'ok')::boolean, true, 'P7: yksityisvuoro siirtyy vapaalle päivälle (to+14 -varaus ei ole esteenä muulla päivällä)');
-- viikonloppu: 14:00 2 h → tunnin vuoro samalle ajalle ei ole sama tuote; mutta yksityinen 13–15 ei saa mennä 14:00-varauksen päälle
select (test.pub_book(:r_sat1400, (:'sat'::date + 7), 2) ->> 'token') as toksat \gset
select is((booking.public_change_booking(:'toksat'::uuid, :r_sat1430, (:'sat'::date + 7), null) ->> 'ok')::boolean, true, 'W1: 2 h vuoro 14:00 → 14:30 samana päivänä onnistuu');
select is(test.hel_hm((test.res(:'toksat'::uuid)).starts_at), '14:30', 'W1: uusi aloitusaika 14:30');
select is(booking.public_change_booking(:'toksat'::uuid, :r_h14, (:'sat'::date + 7), null) ->> 'code', 'product_mismatch', 'W2: 2 h vuoroa ei voi vaihtaa tunnin vuoroon (eri tuote)');
select (test.pub_book(:r_h14, (:'sat'::date + 14), 3) ->> 'token') as tokh \gset
select test.logout();
select test.mk_staff('chg-staff2@example.com', 'staff') as sid2 \gset
select test.login(:'sid2');
select throws_ok(format($$select booking.admin_create_booking(%s, %L, 4, null, '{"name": "Yks Vuoro", "email": "yks@example.com", "phone": "0407654321"}')$$, test.rule('Oma savusaunavuoro la–su 13–15%'), (:'sat'::date + 14)), 'BK001', null, 'W3: yksityisvuoro 13–15 estyy tunnin vuoron 14:00 varauksen takia');
select test.logout();
select test.anon('10.5.0.3');
select is(booking.public_change_booking(:'tokh'::uuid, null, null, 11) ->> 'code', 'persons_max', 'W4: tunnin vuoron enimmäismäärä 10 myös muutoksessa');
select is((booking.public_change_booking(:'tokh'::uuid, null, null, 10) ->> 'ok')::boolean, true, 'W5: tunnin vuoro 3 → 10 hlö onnistuu (oma kapasiteetti 10)');
select test.logout();

-- ---------- 48 h ennakkoraja ----------
select test.anon('10.5.0.4');
select booking.public_create_booking(:r_mon, :'mon', 2, 'Raja Asiakas', 'raja@example.com', '0401234567') ->> 'token' as tokr \gset
select test.logout();
select (test.res(:'tokr'::uuid)).id as rid_r \gset
-- tasan 48 h ennen alkua: sallittu; 48 h - 1 min: ei sallittu
update booking.reservations set starts_at = now() + interval '48 hours', ends_at = now() + interval '51 hours' where id = :rid_r;
select test.anon('10.5.0.4');
select is((booking.public_get_booking(:'tokr'::uuid) ->> 'can_change')::boolean, true, 'T1: täsmälleen 48 h ennen alkua: can_change = true');
select is((booking.public_change_booking(:'tokr'::uuid, null, null, 3) ->> 'ok')::boolean, true, 'T2: täsmälleen 48 h ennen alkua muutos sallittu');
select test.logout();
update booking.reservations set starts_at = now() + interval '48 hours' - interval '1 minute', ends_at = now() + interval '51 hours' where id = :rid_r;
select test.anon('10.5.0.4');
select is((booking.public_get_booking(:'tokr'::uuid) ->> 'can_change')::boolean, false, 'T3: alle 48 h ennen alkua: can_change = false');
select is(booking.public_change_booking(:'tokr'::uuid, null, null, 2) ->> 'code', 'change_too_late', 'T4: alle 48 h ennen alkua henkilömäärän muutos hylätään');
select is(booking.public_change_booking(:'tokr'::uuid, :r_mon, (:'mon'::date + 14), null) ->> 'code', 'change_too_late', 'T5: alle 48 h ennen alkua siirto hylätään');
select is(booking.public_cancel_booking(:'tokr'::uuid) ->> 'code', 'not_cancellable', 'T6: asiakas ei voi peruuttaa vahvistettua varausta (ei 48 h rajan sisälläkään)');
select is((test.res(:'tokr'::uuid)).persons, 3, 'T7: hylätty muutos ei muuttanut varausta');
select test.logout();
-- henkilökunta voi muuttaa myös alle 48 h ennen alkua
select test.login(:'sid');
select is((booking.admin_change_booking(:rid_r, null, null, 4) ->> 'ok')::boolean, true, 'T8: henkilökunta voi muuttaa alle 48 h ennen alkua (ei rajaa)');
select test.logout();
-- uusi vuoro liian lähellä: raja koskee myös kohdetta (asetus 336 h = 14 pv)
update booking.settings set value = '336' where key = 'customer_change_hours_before';
select test.anon('10.5.0.5');
select booking.public_create_booking(:r_tue, (:'tue'::date + 35), 1, 'Kohde Raja', 'kohderaja@example.com', '0401234567') ->> 'token' as tokk \gset
select (test.res(:'tokk'::uuid)).id as rid_k \gset
select test.logout();
update booking.reservations set starts_at = starts_at + interval '70 days', ends_at = ends_at + interval '70 days' where id = :rid_k;
select test.anon('10.5.0.5');
select is((booking.public_get_booking(:'tokk'::uuid) ->> 'can_change')::boolean, true, 'T9: asetus 336 h: kaukainen varaus on muutettavissa');
select is(booking.public_change_booking(:'tokk'::uuid, :r_tue, :'tue'::date, null) ->> 'code', 'change_too_late', 'T10: kohdevuoron on alettava vähintään raja-ajan päästä');
select test.logout();
update booking.settings set value = '0' where key = 'customer_change_hours_before';
select test.anon('10.5.0.5');
select is((booking.public_get_booking(:'tokk'::uuid) ->> 'change_hours_before')::int, 0, 'T11: asetus 0 näkyy get_bookingissa');
select test.logout();
update booking.settings set value = '48' where key = 'customer_change_hours_before';

-- ---------- tila: vain vahvistettua voi muuttaa; pending-pito vain peruttavissa ----------
update booking.settings set value = '"hold_until_paid"' where key = 'public_payment_mode';
select test.anon('10.5.0.6');
select booking.public_create_booking(:r_tue, (:'tue'::date + 28), 1, 'Pito Muutos', 'pitomuutos@example.com', '0401234567') ->> 'token' as tokpend \gset
select is(booking.public_change_booking(:'tokpend'::uuid, null, null, 2) ->> 'code', 'not_changeable', 'S1: maksamatonta pitoa (pending) ei muuteta – vain peruutus');
select is((booking.public_get_booking(:'tokpend'::uuid) ->> 'can_change')::boolean, false, 'S2: pending-varauksella can_change = false');
select is((booking.public_cancel_booking(:'tokpend'::uuid) ->> 'ok')::boolean, true, 'S3: pending-pidon voi peruuttaa (kesken ostoprosessin)');
select is(booking.public_change_booking(:'tokpend'::uuid, null, null, 2) ->> 'code', 'not_changeable', 'S4: peruttua varausta ei voi muuttaa');
select test.logout();
update booking.settings set value = '"pay_later"' where key = 'public_payment_mode';
-- vahvistettu, jonka henkilökunta peruu → ei muutettavissa
select test.anon('10.5.0.7');
select booking.public_create_booking(:r_tue, (:'tue'::date + 28), 1, 'Peruttu Muutos', 'peruttumuutos@example.com', '0401234567') ->> 'token' as tokc \gset
select test.logout();
select test.login(:'sid');
select booking.admin_set_reservation_status((test.res(:'tokc'::uuid)).id, 'cancelled', 'testi');
select test.logout();
select test.anon('10.5.0.7');
select is(booking.public_change_booking(:'tokc'::uuid, null, null, 2) ->> 'code', 'not_changeable', 'S5: henkilökunnan peruttua varausta ei voi muuttaa');
select is((booking.public_get_booking(:'tokc'::uuid) ->> 'can_change')::boolean, false, 'S6: peruttu: can_change = false');
select test.logout();

-- ---------- maksettu tilaus: hinnan muutos vaatii henkilökunnan ----------
select test.anon('10.5.0.8');
select booking.public_create_booking(:r_tue, (:'tue'::date + 42), 2, 'Maksettu Muutos', 'maksettumuutos@example.com', '0401234567') ->> 'token' as tokpaid \gset
select test.logout();
select test.login(:'sid');
select booking.admin_record_payment((select id from booking.orders where public_token = :'tokpaid'::uuid), 'cash', (test.ord(:'tokpaid'::uuid)).total_gross);
select test.logout();
select test.anon('10.5.0.8');
select is(booking.public_change_booking(:'tokpaid'::uuid, null, null, 3) ->> 'code', 'price_change_requires_staff', 'M1: maksetun tilauksen hinta ei muutu asiakkaan toimesta');
select is((booking.public_change_booking(:'tokpaid'::uuid, :r_tue, (:'tue'::date + 49), null) ->> 'ok')::boolean, true, 'M2: maksetun tilauksen siirto samalla hinnalla onnistuu');
select test.logout();
select is((test.ord(:'tokpaid'::uuid)).payment_status, 'paid', 'M3: tilaus pysyy maksettuna');
select test.login(:'sid');
select is((booking.admin_change_booking((test.res(:'tokpaid'::uuid)).id, null, null, 3) ->> 'ok')::boolean, true, 'M4: henkilökunta voi muuttaa maksetun hinnan');
select is((test.ord(:'tokpaid'::uuid)).payment_status, 'partially_paid', 'M5: summan kasvettua tilaus on osittain maksettu');
select test.logout();

-- ---------- admin_change_booking ----------
select test.login(:'sid');
select booking.admin_create_booking(:r_priv, (:'fri'::date + 21), 6, null, '{"name": "Oma Aika", "email": "omaaika@example.com", "phone": "0407654321"}', 'pay_later', false, null,
         ((:'fri'::date + 21)::timestamp + time '15:00') at time zone 'Europe/Helsinki', ((:'fri'::date + 21)::timestamp + time '17:00') at time zone 'Europe/Helsinki') ->> 'reservation_id' as rid_p \gset
select is((booking.admin_change_booking(:rid_p, null, null, 8) ->> 'ok')::boolean, true, 'A1: yksityisvuoron henkilömäärän muutos säilyttää mukautetun ajan');
select is((select to_char(starts_at at time zone 'Europe/Helsinki', 'HH24:MI') || '-' || to_char(ends_at at time zone 'Europe/Helsinki', 'HH24:MI') from booking.reservations where id = :rid_p), '15:00-17:00', 'A1b: mukautettu aika säilyi');
select throws_ok(format($$select booking.admin_change_booking(%s, null, null, 99)$$, :rid_p), 'BK001', null, 'A2: yli enimmäismäärän hylätään');
select throws_ok(format($$select booking.admin_change_booking(%s)$$, :rid_p), 'BK001', 'Ei muutettavaa', 'A3: ei muutettavaa');
select throws_ok($$select booking.admin_change_booking(99999999, null, null, 2)$$, 'BK001', 'Varausta ei löydy', 'A4: tuntematon varaus');
select throws_ok(format($$select booking.admin_change_booking(%s, %s, %L, null)$$, :rid_r, :r_thu, :'thu'), 'BK001', 'Varauksen voi siirtää vain saman tuotteen toiseen vuoroon', 'A5: henkilökunta ei voi siirtää toiseen tuotteeseen');
select test.logout();
select test.anon();
select throws_ok(format($$select booking.admin_change_booking(%s, null, null, 2)$$, :rid_p), '42501', null, 'A6: anon ei voi kutsua admin_change_booking');
select test.logout();
select test.mk_user('ei-staff-chg@example.com') as nsid \gset
select test.login(:'nsid');
select throws_ok(format($$select booking.admin_change_booking(%s, null, null, 2)$$, :rid_p), 'BK001', 'Ei oikeuksia', 'A7: ei-henkilöstö ei voi muuttaa varausta');
select test.logout();

-- ---------- rate limit tokenia kohti ----------
update booking.settings set value = '10' where key = 'rl_change_per_10min';
select test.anon('10.5.0.9');
select count(booking.public_change_booking(:'tokk'::uuid, null, null, 1)) as _r1 from generate_series(1, 14) \gset
select is(booking.public_change_booking(:'tokk'::uuid, null, null, 1) ->> 'code', 'rate_limited', 'R1: muutosyritysten rate limit tokenia kohti laukeaa');
select test.logout();

select * from finish();
rollback;
