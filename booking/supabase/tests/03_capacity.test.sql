-- Kapasiteetit: ma–ke 16, torstai 16 (turvesauna 8 mukana), viikonloppu 6 / aloitusaika (2 h vuorot), tunnin vuorot 10 / vuoro (oma kapasiteetti)
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

-- viikonloppu: kapasiteetti 6 PER ALOITUSAIKA (jokaisella aloitusajalla oma pooli); limittäiset vuorot eivät jaa paikkoja
select test.anon();
select is((select count(*)::int from booking.public_availability(1, :'sat', :'sat')), 6, 'la: täsmälleen 6 aloitusaikaa tarjolla');
select is((select array_agg(to_char(starts_at at time zone 'Europe/Helsinki', 'HH24:MI') order by starts_at) from booking.public_availability(1, :'sat', :'sat')),
          array['14:00','14:30','15:00','16:00','16:30','17:00'], 'la: aloitusajat 14:00, 14:30, 15:00, 16:00, 16:30, 17:00');
select is((select count(*)::int from booking.public_availability(1, :'sat', :'sat') where label like '%15:30%' or to_char(starts_at at time zone 'Europe/Helsinki', 'HH24:MI') = '15:30'), 0, 'la: klo 15:30 ei ole aloitusaika');
select is((select count(*)::int from booking.public_availability(1, :'sat', :'sat') where remaining = 6), 6, 'la: jokaisella aloitusajalla 6 paikkaa vapaana');
select is((test.pub_book(:r_1400, :'sat', 6) ->> 'ok')::boolean, true, 'la 14:00: 6 hlö täyttää vuoron');
select is(test.pub_book(:r_1400, :'sat', 1) ->> 'code', 'capacity_exceeded', 'la 14:00: 7. henkilö estyy');
select is((select status from booking.public_availability(1, :'sat', :'sat') where label like '%14:00%'), 'full', 'la 14:00: vuoro täynnä');
select is((test.pub_book(:r_1430, :'sat', 6) ->> 'ok')::boolean, true, 'la 14:30: 6 hlö onnistuu vaikka 14:00-vuoro on täynnä ja limittyy (oma kapasiteetti)');
select is((test.pub_book(:r_1500, :'sat', 6) ->> 'ok')::boolean, true, 'la 15:00: 6 hlö onnistuu (kolme limittäistä täyttä vuoroa = 18 hlöä saunassa)');
select is((select remaining from booking.public_availability(1, :'sat', :'sat') where label like '%16:00%'), 6, 'la 16:00: vapaana 6 (limittäiset vuorot eivät vaikuta)');
select is((select remaining from booking.public_availability(1, :'sat', :'sat') where label like '%16:30%'), 6, 'la 16:30: vapaana 6');
select is((test.pub_book(:r_1630, :'sat', 2) ->> 'ok')::boolean, true, 'la 16:30: 2 hlö');
select is((test.pub_book(:r_1630, :'sat', 4) ->> 'ok')::boolean, true, 'la 16:30: +4 = 6 hlö');
select is(test.pub_book(:r_1630, :'sat', 1) ->> 'code', 'capacity_exceeded', 'la 16:30: 7. henkilö estyy');
select is((select remaining from booking.public_availability(1, :'sat', :'sat') where label like '%17:00%'), 6, 'la 17:00: vapaana 6 (16:30-vuoro täynnä, oma pooli)');
select is((test.pub_book(:r_1700, :'sat', 6) ->> 'ok')::boolean, true, 'la 17:00: 6 hlö');
select is(test.pub_book(:r_1600, :'sat', 7) ->> 'code', 'persons_max', 'la 16:00: yli 6 hlön yksittäinen varaus estyy (persons_max)');
select is((test.pub_book(:r_1600, :'sat', 0 + 0) ->> 'code'), 'invalid_persons', 'la: 0 henkilöä ei kelpaa');
select is((select count(*)::int from booking.public_availability(1, :'sat', :'sat') where status = 'full'), 5, 'la: täynnä 5 vuoroa (14:00, 14:30, 15:00, 16:30, 17:00), 16:00 vapaa');
select test.logout();

-- tunnin vuorot (14:00 ja 18:00): oma kapasiteetti 10 / vuoro, EIVÄT jaa kapasiteettia 2 h vuorojen kanssa
select test.anon();
select is((select count(*)::int from booking.public_availability(6, :'sun', :'sun')), 2, 'su: tunnin vuoroja 2 (14:00 ja 18:00)');
select is((select array_agg(to_char(starts_at at time zone 'Europe/Helsinki', 'HH24:MI') order by starts_at) from booking.public_availability(6, :'sun', :'sun')), array['14:00','18:00'], 'su: tunnin vuorojen aloitusajat 14:00 ja 18:00');
select is((select min(remaining) from booking.public_availability(6, :'sun', :'sun')), 10, 'su: tunnin vuoroilla 10 paikkaa');
select is((test.pub_book(:r_h14, :'sun', 10) ->> 'ok')::boolean, true, 'su tunnin vuoro 14:00: 10 hlö');
select is(test.pub_book(:r_h14, :'sun', 1) ->> 'code', 'capacity_exceeded', 'su tunnin vuoro 14:00: 11. henkilö estyy');
select is(test.pub_book(:r_h14, :'sun', 11) ->> 'code', 'persons_max', 'su tunnin vuoro: yli 10 hlön varaus estyy (persons_max)');
select is((test.pub_book(:r_1400, :'sun', 6) ->> 'ok')::boolean, true, 'su 2 h vuoro 14:00: 6 hlö onnistuu vaikka tunnin vuoro 14:00 on täynnä (erilliset kapasiteetit)');
select is(test.pub_book(:r_1400, :'sun', 1) ->> 'code', 'capacity_exceeded', 'su 2 h vuoro 14:00: 7. henkilö estyy');
select is((select remaining from booking.public_availability(6, :'sun', :'sun') where label like '%18:00%'), 10, 'su tunnin vuoro 18:00 vapaana 10');
select is((test.pub_book(:r_h18, :'sun', 10) ->> 'ok')::boolean, true, 'su tunnin vuoro 18:00: 10 hlö');
select is(test.pub_book(:r_h18, :'sun', 1) ->> 'code', 'capacity_exceeded', 'su tunnin vuoro 18:00: 11. estyy');
select is((test.pub_book(:r_1700, :'sun', 6) ->> 'ok')::boolean, true, 'su 17:00–19:00 2 h vuoro: 6 hlö onnistuu vaikka tunnin vuoro 18:00 on täynnä');
select test.logout();
-- poolit: jokaisella viikonlopun säännöllä oma pooli, kapasiteetit 6 / 10
select is((select count(*)::int from booking.schedule_rule_pools p join booking.schedule_rules r on r.id = p.rule_id where r.weekdays = '{6,7}' and r.mode = 'shared'), 8, 'viikonlopun yleisillä säännöillä 8 poolilinkkiä (6 x 2 h + 2 x 1 h)');
select is((select count(distinct p.pool_id)::int from booking.schedule_rule_pools p join booking.schedule_rules r on r.id = p.rule_id where r.weekdays = '{6,7}' and r.mode = 'shared'), 8, 'jokaisella viikonlopun säännöllä oma pooli (ei jaettuja)');
select is((select array_agg(distinct capacity order by capacity) from booking.resources where code like 'yleinen\_vkp\_%'), array[6], '2 h vuorojen poolit: kapasiteetti 6');
select is((select array_agg(distinct capacity order by capacity) from booking.resources where code like 'tunti\_vkp\_%'), array[10], 'tunnin vuorojen poolit: kapasiteetti 10');
select is((select count(*)::int from booking.resources where code = 'yleinen_vkp'), 0, 'vanha jaettu pooli yleinen_vkp on poistettu');
select is((select count(*)::int from booking.schedule_rules where start_time = '15:30' and mode = 'shared'), 0, 'sääntöjä klo 15:30 ei ole');
select is((select count(*)::int from booking.schedule_rules where valid_from is not null or valid_to is not null), 1, 'vain yksi voimassaolorajattu sääntö (uudenvuodenaatto, ei käytössä); kesäkauden 15:30-rajaus poistettu');
select is((select max_persons from booking.product_config where product_id = 6), 10, 'tunnin vuoron tuotteen max hlö 10');

-- peruttu varaus vapauttaa kapasiteetin
select test.mk_staff('cap-staff@example.com', 'staff') as sid \gset
select test.login(:'sid');
select booking.admin_set_reservation_status((select id from booking.reservations where mode = 'shared' and product_id = 6 and starts_at::date = :'sun'::date order by id limit 1), 'cancelled', 'testi');
select test.logout();
select test.anon();
select is((select remaining from booking.public_availability(6, :'sun', :'sun') where label like '%14:00%'), 10, 'peruutus vapauttaa tunnin vuoron 14:00 paikat');
select is((select status from booking.public_availability(1, :'sun', :'sun') where label like '%14:00%'), 'full', 'tunnin vuoron peruutus ei vapauta 2 h vuoron paikkoja (eri pooli)');
select is((test.pub_book(:r_h14, :'sun', 10) ->> 'ok')::boolean, true, 'peruutuksen jälkeen tunnin vuoro 14:00 taas varattavissa');
select test.logout();

select * from finish();
rollback;
