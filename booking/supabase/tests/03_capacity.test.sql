-- Kapasiteetit: ma–ke 16, torstai 16 (turvesauna 8 mukana), viikonloppu 6 samanaikaista (limittäiset vuorot)
begin;
set local search_path = extensions, public;
select no_plan();

select test.next_dow(1) as mon, test.next_dow(4) as thu, test.next_dow(6) as sat, test.next_dow(7) as sun,
       test.rule('Miesten sauna%') as r_mon, test.rule('Turvetorstai%') as r_peat, test.rule('Yleinen vuoro to 17–19') as r_thu,
       test.rule('Yleinen vuoro la–su 14:00%') as r_1400, test.rule('Yleinen vuoro la–su 14:30%') as r_1430,
       test.rule('Yleinen vuoro la–su 15:00%') as r_1500, test.rule('Yleinen vuoro la–su 16:00%') as r_1600,
       test.rule('Yleinen vuoro la–su 16:30%') as r_1630, test.rule('Yleinen vuoro la–su 17:00%') as r_1700,
       test.rule('Tunnin saunavuoro la–su 14:00') as r_h14, test.rule('Tunnin saunavuoro la–su 18:00') as r_h18 \gset

-- ma: 16 henkilöä
select test.anon();
select is((test.pub_book(:r_mon, :'mon', 10) ->> 'ok')::boolean, true, 'ma: 10 hlö');
select is((test.pub_book(:r_mon, :'mon', 6) ->> 'ok')::boolean, true, 'ma: +6 = 16 hlö');
select is(test.pub_book(:r_mon, :'mon', 1) ->> 'code', 'capacity_exceeded', 'ma: 17. henkilö estyy');
select is((select status from booking.public_availability(2, :'mon', :'mon')), 'full', 'ma: vuoro näkyy täynnä');
select is((select remaining from booking.public_availability(2, :'mon', :'mon')), 0, 'ma: vapaana 0');
select is(test.pub_book(:r_mon, :'mon', 17) ->> 'code', 'persons_max', 'ma: yli 16 hlön yksittäinen varaus estyy (persons_max)');
select test.logout();

-- torstai: turvesauna 16–19 (max 8) + yleinen 17–19; yhteensä 16
select test.anon();
select is((test.pub_book(:r_peat, :'thu', 8) ->> 'ok')::boolean, true, 'to: turvesauna 8 hlö');
select is(test.pub_book(:r_peat, :'thu', 1) ->> 'code', 'capacity_exceeded', 'to: 9. turvesaunalainen estyy (turve-pooli 8)');
select is((select remaining from booking.public_availability(1, :'thu', :'thu')), 8, 'to: yleisellä vuorolla 16 - 8 turvesaunalaista = 8 paikkaa');
select is((test.pub_book(:r_thu, :'thu', 8) ->> 'ok')::boolean, true, 'to: yleinen vuoro 8 hlö (yhteensä 16)');
select is(test.pub_book(:r_thu, :'thu', 1) ->> 'code', 'capacity_exceeded', 'to: yhteensä enintään 16 – 17. estyy');
select is((select status from booking.public_availability(1, :'thu', :'thu')), 'full', 'to: yleinen vuoro täynnä');
select is((select status from booking.public_availability(5, :'thu', :'thu')), 'full', 'to: turvetorstai täynnä');
select test.logout();
-- torstai (seuraava): pelkkä yleinen vuoro 16 hlöä ilman turvesaunaa
select test.anon();
select is((test.pub_book(:r_thu, (:'thu'::date + 7), 16) ->> 'ok')::boolean, true, 'to: 16 hlöä pelkälle yleiselle vuorolle');
select is((select remaining from booking.public_availability(5, (:'thu'::date + 7), (:'thu'::date + 7))), 0, 'to: turvetorstailta ei jää tilaa kun yleinen vuoro täynnä (16 hlön kokonaisraja)');
select test.logout();

-- viikonloppu: limittäiset 2 h vuorot, 6 hlöä sisällä yhtä aikaa
select test.anon();
select is((test.pub_book(:r_1400, :'sat', 3) ->> 'ok')::boolean, true, 'la 14:00: 3 hlö');
select is((test.pub_book(:r_1430, :'sat', 3) ->> 'ok')::boolean, true, 'la 14:30: 3 hlö (limittyy 14:30–16:00, yht. 6)');
select is(test.pub_book(:r_1500, :'sat', 1) ->> 'code', 'capacity_exceeded', 'la 15:00: estyy (14:00- ja 14:30-vuorot sisällä => 6)');
select is((select remaining from booking.public_availability(1, :'sat', :'sat') where label like '%15:00%'), 0, 'la 15:00: vapaana 0');
select is((select remaining from booking.public_availability(1, :'sat', :'sat') where label like '%16:00%'), 3, 'la 16:00: vapaana 3 (14:00-vuoro on poistunut, 14:30-vuoro vielä 16:00–16:30)');
select is((select remaining from booking.public_availability(1, :'sat', :'sat') where label like '%16:30%'), 6, 'la 16:30: vapaana 6 (14:30-vuoro päättyy 16:30)');
select is((test.pub_book(:r_1630, :'sat', 6) ->> 'ok')::boolean, true, 'la 16:30: 6 hlö onnistuu');
select is(test.pub_book(:r_1700, :'sat', 1) ->> 'code', 'capacity_exceeded', 'la 17:00: estyy (16:30-vuoro täynnä 17:00–18:30)');
select is((select remaining from booking.public_availability(1, :'sat', :'sat') where label like '%17:00%'), 0, 'la 17:00: vapaana 0');
select is(test.pub_book(:r_1600, :'sat', 4) ->> 'code', 'capacity_exceeded', 'la 16:00: 4 hlö estyy (16:00–16:30 sisällä 3 + 16:30– alkaa 6)');
select is((test.pub_book(:r_1600, :'sat', 0 + 0) ->> 'code'), 'invalid_persons', 'la: 0 henkilöä ei kelpaa');
select test.logout();

-- tunnin vuorot jakavat saman viikonlopun 6 hlön kapasiteetin
select test.anon();
select is((test.pub_book(:r_h14, (:'sun'::date), 6) ->> 'ok')::boolean, true, 'su tunnin vuoro 14:00: 6 hlö');
select is(test.pub_book(:r_1400, (:'sun'::date), 1) ->> 'code', 'capacity_exceeded', 'su 14:00 2 h vuoro estyy kun tunnin vuoro täyttää 14–15');
select is((select remaining from booking.public_availability(6, :'sun', :'sun') where label like '%18:00%'), 6, 'su tunnin vuoro 18:00 vapaana');
select is((test.pub_book(:r_h18, :'sun', 6) ->> 'ok')::boolean, true, 'su tunnin vuoro 18:00: 6 hlö');
select is(test.pub_book(:r_1700, :'sun', 1) ->> 'code', 'capacity_exceeded', 'su 17:00–19:00 2 h vuoro estyy kun 18:00-tunnin vuoro täynnä');
select test.logout();

-- peruttu varaus vapauttaa kapasiteetin
select test.mk_staff('cap-staff@example.com', 'staff') as sid \gset
select test.login(:'sid');
select booking.admin_set_reservation_status((select id from booking.reservations where mode = 'shared' and product_id = 6 and starts_at::date = :'sun'::date order by id limit 1), 'cancelled', 'testi');
select test.logout();
select test.anon();
select is((test.pub_book(:r_h14, :'sun', 6) ->> 'ok')::boolean, true, 'peruutuksen jälkeen tunnin vuoro 14:00 taas varattavissa');
select test.logout();

select * from finish();
rollback;
