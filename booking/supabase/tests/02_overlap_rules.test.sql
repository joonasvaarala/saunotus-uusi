-- Päällekkäisyyssäännöt: yksityisvuoro <-> yleinen vuoro (molempiin suuntiin), sulut, vanhenevat pidot
begin;
set local search_path = extensions, public;
select no_plan();

select test.next_dow(4) as thu, test.next_dow(6) as sat, test.next_dow(1) as mon, test.next_dow(5) as fri \gset
select test.rule('Oma savusaunavuoro ma–pe 16–19%') as r_priv_1619,
       test.rule('Jälkilöylyt ma–to 19–21%') as r_after,
       test.rule('Oma savusaunavuoro la–su 13–15%') as r_priv_sat_1315,
       test.rule('Oma savusaunavuoro la–su 13–14%') as r_priv_sat_1314,
       test.rule('Yleinen vuoro to 17–19') as r_thu_public,
       test.rule('Turvetorstai%') as r_peat,
       test.rule('Yleinen vuoro la–su 14:00%') as r_sat_1400,
       test.rule('Yleinen vuoro la–su 14:30%') as r_sat_1430,
       test.rule('Yleinen vuoro la–su 15:00%') as r_sat_1500,
       test.rule('Yleinen vuoro la–su 16:00%') as r_sat_1600,
       test.rule('Yleinen vuoro la–su 17:00%') as r_sat_1700,
       test.rule('Miesten sauna%') as r_mon,
       test.rule('Naisten sauna%') as r_tue_public,
       test.rule('Yleinen vuoro la–su 16:00%') as r_x,
       test.rule('Tunnin saunavuoro la–su 14:00') as r_h14,
       test.rule('Tunnin saunavuoro la–su 18:00') as r_h18,
       test.rule('Jälkilöylyt la 19–22%') as r_after_sat,
       test.rule('Yleinen vuoro la–su 17:00%') as r_sat_1700b \gset

-- 0) alkutila: kaikki myytävissä
select test.anon();
select is((select count(*)::int from booking.public_availability(1, :'thu', :'thu') where status = 'available'), 1, 'torstain yleinen vuoro näkyy vapaana');
select is((select count(*)::int from booking.public_availability(1, :'sat', :'sat') where status = 'available'), 6, 'la: 6 yleistä vuoroa vapaana (14:00,14:30,15:00,16:00,16:30,17:00; ei 15:30)');
select is((select count(*)::int from booking.public_availability(6, :'sat', :'sat') where status = 'available'), 2, 'la: 2 tunnin vuoroa vapaana (14:00, 18:00)');
select test.logout();

-- A) YKSITYISVUORO torstaille 16–19 -> yleiset torstain vuorot poistuvat myynnistä
select test.anon();
select is((test.pub_book(:r_priv_1619, :'thu', 4) ->> 'ok')::boolean, true, 'A1: yksityisvuoro to 16–19 onnistuu');
select is((select status from booking.public_availability(1, :'thu', :'thu')), 'unavailable', 'A2: to yleinen vuoro 17–19 ei enää myynnissä');
select is((select status from booking.public_availability(5, :'thu', :'thu')), 'unavailable', 'A3: turvetorstai ei enää myynnissä');
select is(test.pub_book(:r_thu_public, :'thu', 2) ->> 'code', 'private_booked', 'A4: yleisen vuoron varaus estetään (private_booked)');
select is(test.pub_book(:r_peat, :'thu', 1) ->> 'code', 'private_booked', 'A5: turvetorstain varaus estetään');
select is(test.pub_book(:r_priv_1619, :'thu', 4) ->> 'code', 'private_booked', 'A6: toinen yksityisvuoro samalle ajalle estetään');
select is((select status from booking.public_availability(25, :'thu', :'thu') where label like '%ma–pe 16–19%'), 'unavailable', 'A7: yksityisvuoro 16–19 itse näkyy varattuna');
select test.logout();

-- B) YLEISEN VUORON VARAUS -> yksityisvuoro samalle ajalle estyy (vastakkainen suunta); ei-päällekkäinen onnistuu
select test.anon();
select is((test.pub_book(:r_thu_public, (:'thu'::date + 7), 1) ->> 'ok')::boolean, true, 'B1: yksi paikka yleiselle torstain vuorolle');
select is(test.pub_book(:r_priv_1619, (:'thu'::date + 7), 4) ->> 'code', 'public_shift_booked', 'B2: yksityisvuoro 16–19 estyy kun yleisellä vuorolla on edes 1 varaus');
select is((select status from booking.public_availability(25, (:'thu'::date + 7), (:'thu'::date + 7)) where label like '%ma–pe 16–19%'), 'unavailable', 'B3: yksityisvuoro ei näy vapaana');
select is((test.pub_book(:r_after, (:'thu'::date + 7), 4) ->> 'ok')::boolean, true, 'B4: jälkilöylyt 19–21 (ei päällekkäinen) onnistuu');
select test.logout();

-- C) VIIKONLOPPU: yksityisvuoro 13–15 poistaa 14:00 ja 14:30 -vuorot, ei 15:00-vuoroa
select test.anon();
select is((test.pub_book(:r_priv_sat_1315, (:'sat'::date + 7), 3) ->> 'ok')::boolean, true, 'C1: la yksityisvuoro 13–15 onnistuu');
select is((select array_agg(label order by starts_at) filter (where status = 'unavailable') from booking.public_availability(1, (:'sat'::date + 7), (:'sat'::date + 7)))::text[],
          array['Yleinen vuoro la–su 14:00 (2 h)', 'Yleinen vuoro la–su 14:30 (2 h)'], 'C2: päällekkäiset 14:00 ja 14:30 poistuvat myynnistä');
select is((select count(*)::int from booking.public_availability(1, (:'sat'::date + 7), (:'sat'::date + 7)) where status = 'available'), 4, 'C3: loput 4 vuoroa (15:00 alkaen) vapaina');
select is(test.pub_book(:r_sat_1430, (:'sat'::date + 7), 1) ->> 'code', 'private_booked', 'C4: 14:30-vuoron varaus estyy');
select is((test.pub_book(:r_sat_1500, (:'sat'::date + 7), 1) ->> 'ok')::boolean, true, 'C5: 15:00-vuoro (alkaa kun yksityinen päättyy) onnistuu');
select test.logout();

-- D) VIIKONLOPPU: yleinen vuoro 14:00 varattu -> yksityisvuoro 13–14 onnistuu (ei päällekkäinen), 13–15 estyy
select test.anon();
select is((test.pub_book(:r_sat_1400, (:'sat'::date + 14), 2) ->> 'ok')::boolean, true, 'D1: yleinen la 14:00, 2 hlö');
select is(test.pub_book(:r_priv_sat_1315, (:'sat'::date + 14), 4) ->> 'code', 'public_shift_booked', 'D2: yksityisvuoro 13–15 estyy (yleisellä vuorolla varauksia)');
select is((test.pub_book(:r_priv_sat_1314, (:'sat'::date + 14), 4) ->> 'ok')::boolean, true, 'D3: yksityisvuoro 13–14 onnistuu (päättyy kun yleinen alkaa)');
select test.logout();

-- H) VIIKONLOPUN TUNNIN VUOROT (14:00 ja 18:00): sama päällekkäisyyssääntö molempiin suuntiin kuin 2 h vuoroilla
select test.anon();
-- H1–H3: yksityisvuoro 13–15 poistaa myös tunnin vuoron 14:00 (ei 18:00)
select is((test.pub_book(:r_priv_sat_1315, (:'sat'::date + 21), 3) ->> 'ok')::boolean, true, 'H1: la yksityisvuoro 13–15 onnistuu');
select is((select status from booking.public_availability(6, (:'sat'::date + 21), (:'sat'::date + 21)) where label like '%14:00'), 'unavailable', 'H2: tunnin vuoro 14:00 ei myynnissä yksityisvuoron aikana');
select is((select status from booking.public_availability(6, (:'sat'::date + 21), (:'sat'::date + 21)) where label like '%18:00'), 'available', 'H3: tunnin vuoro 18:00 ei ole päällekkäinen, vapaa');
select is(test.pub_book(:r_h14, (:'sat'::date + 21), 2) ->> 'code', 'private_booked', 'H4: tunnin vuoron 14:00 varaus estyy yksityisvuoron päälle');
select is((test.pub_book(:r_h18, (:'sat'::date + 21), 2) ->> 'ok')::boolean, true, 'H5: tunnin vuoro 18:00 onnistuu');
-- H6–H9: yksi varaus tunnin vuorolle 14:00 estää yksityisvuoron 13–15 (ja 13–14 onnistuu, koska päättyy kun tunnin vuoro alkaa)
select is((test.pub_book(:r_h14, (:'sat'::date + 28), 1) ->> 'ok')::boolean, true, 'H6: yksi paikka tunnin vuorolle 14:00');
select is(test.pub_book(:r_priv_sat_1315, (:'sat'::date + 28), 4) ->> 'code', 'public_shift_booked', 'H7: yksityisvuoro 13–15 estyy tunnin vuoron varauksen takia');
select is((select status from booking.public_availability(25, (:'sat'::date + 28), (:'sat'::date + 28)) where label like '%13–15%'), 'unavailable', 'H8: yksityisvuoro 13–15 näkyy ei-varattavissa');
select is((test.pub_book(:r_priv_sat_1314, (:'sat'::date + 28), 4) ->> 'ok')::boolean, true, 'H9: yksityisvuoro 13–14 onnistuu (päättyy kun tunnin vuoro alkaa)');
-- H10–H12: tunnin vuoro 18:00 ja yksityiset jälkilöylyt 19–22 (ei päällekkäisyyttä); 2 h vuoro 17:00–19:00 vs. yksityisvuoro 18:00 jälkeen
select is((test.pub_book(:r_h18, (:'sat'::date + 35), 1) ->> 'ok')::boolean, true, 'H10: tunnin vuoro 18:00');
select is((test.pub_book(:r_after_sat, (:'sat'::date + 35), 2) ->> 'ok')::boolean, true, 'H11: jälkilöylyt 19–22 onnistuvat (tunnin vuoro päättyy 19:00)');
select is((test.pub_book(:r_sat_1700b, (:'sat'::date + 35), 1) ->> 'ok')::boolean, true, 'H12: 2 h vuoro 17:00–19:00 ei ole päällekkäinen jälkilöylyjen kanssa');
select test.logout();
-- H13: sulku peittää tunnin vuoron
select test.mk_staff('block-staff2@example.com', 'staff') as bid2 \gset
select test.login(:'bid2');
select is((booking.admin_create_block((select id from booking.resources where code = 'savusauna'),
            ((:'sat'::date + 42)::timestamp + time '17:30') at time zone 'Europe/Helsinki', ((:'sat'::date + 42)::timestamp + time '19:30') at time zone 'Europe/Helsinki', 'huolto') ->> 'ok')::boolean, true, 'H13: sulku luotu la 17:30–19:30');
select test.logout();
select test.anon();
select is((select status from booking.public_availability(6, (:'sat'::date + 42), (:'sat'::date + 42)) where label like '%18:00'), 'unavailable', 'H14: tunnin vuoro 18:00 ei myynnissä sulun aikana');
select is(test.pub_book(:r_h18, (:'sat'::date + 42), 1) ->> 'code', 'space_closed', 'H15: tunnin vuoron varaus estyy sulun aikana');
select test.logout();

-- E) SULKU: admin sulkee ajan -> ei varattavissa
select test.mk_staff('block-staff@example.com', 'staff') as bid \gset
select test.login(:'bid');
select is((booking.admin_create_block((select id from booking.resources where code = 'savusauna'),
            (:'mon'::date + 1)::timestamp at time zone 'Europe/Helsinki', (:'mon'::date + 2)::timestamp at time zone 'Europe/Helsinki', 'huolto') ->> 'ok')::boolean, true, 'E1: sulku luotu');
select test.logout();
select test.anon();
select is((select status from booking.public_availability(3, :'mon'::date + 1, :'mon'::date + 1)), 'unavailable', 'E2: sulun alla oleva vuoro ei myynnissä');
select is(test.pub_book(:r_tue_public, :'mon'::date + 1, 1) ->> 'code', 'space_closed', 'E3: varaus sulun aikaan estyy');
select test.logout();

-- F) PERUUTUS vapauttaa ajan
select test.mk_staff('cancel-staff@example.com', 'staff') as cid \gset
select test.login(:'cid');
select booking.admin_set_reservation_status((select id from booking.reservations where mode = 'exclusive' and starts_at::date >= :'thu'::date and order_id in (select id from booking.orders) order by id limit 1), 'cancelled', 'testi');
select test.logout();
select test.anon();
select is((select status from booking.public_availability(1, :'thu', :'thu')), 'available', 'F1: yksityisvuoron peruutuksen jälkeen yleinen vuoro palaa myyntiin');
select is((test.pub_book(:r_thu_public, :'thu', 2) ->> 'ok')::boolean, true, 'F2: yleisen vuoron varaus onnistuu uudelleen');
select test.logout();

-- G) VANHENEVA PITO (hold_until_paid): pending-pito estää, vanhennuttua vapautuu
update booking.settings set value = '"hold_until_paid"' where key = 'public_payment_mode';
select test.anon();
select test.logout();
select test.next_dow(2, 10) as tue \gset
select test.anon();
select test.pub_book(:r_priv_1619, :'tue', 3) as hold \gset
select is((:'hold'::jsonb ->> 'status'), 'pending', 'G1: pending-varaus luotu');
select is((:'hold'::jsonb ->> 'payment_mode'), 'hold_until_paid', 'G2: maksutila hold_until_paid');
select ok((:'hold'::jsonb ->> 'hold_expires_at')::timestamptz > now() + interval '14 minutes', 'G3: pito noin 15 min');
select is(test.pub_book(:r_priv_1619, :'tue', 2) ->> 'code', 'private_booked', 'G4: pending-pito estää toisen yksityisvuoron');
select is((select status from booking.public_availability(3, :'tue', :'tue')), 'unavailable', 'G5: pending-pito poistaa yleisen vuoron myynnistä');
select test.logout();
-- pito vanhenee
update booking.reservations set hold_expires_at = now() - interval '1 minute' where status = 'pending';
select test.anon();
select is((select status from booking.public_availability(3, :'tue', :'tue')), 'available', 'G6: vanhentunut pito ei enää estä (ilman cron-ajoa)');
select is((test.pub_book(:r_tue_public, :'tue', 2) ->> 'ok')::boolean, true, 'G7: yleinen vuoro varattavissa vanhentuneen pidon jälkeen');
select test.logout();
select is(booking.expire_holds() >= 0, true, 'G8: expire_holds() ajettavissa');
select is((select count(*)::int from booking.reservations where status = 'pending'), 1, 'G9: vain uusi (pending) varaus jäi; vanhentunut siivottu tilaan expired');
select is((select count(*)::int from booking.reservations where status = 'expired'), 1, 'G10: vanhentunut pito merkitty expired');
update booking.settings set value = '"pay_later"' where key = 'public_payment_mode';

select * from finish();
rollback;
