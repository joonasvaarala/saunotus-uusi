-- =====================================================================
-- booking 08: perusdata – resurssit, asetukset, tuotekonfiguraatio ja vuorosäännöt (Savusauna)
-- Säännöt ovat DATAA (taulut schedule_rules / schedule_rule_pools / resources), ei koodia.
-- Muutos: lisää uusi migraatio (tai Koodarin SQL) – ks. booking/README.md "Sääntöjen muuttaminen".
-- Viikonlopun kapasiteetti on PER ALOITUSAIKA: jokaisella la–su aloitusajalla on oma kapasiteettipooli (2 h vuorot 6 hlö,
-- tunnin vuorot 14:00 ja 18:00 omat poolit 10 hlö). Moottori (migraatio 04) laskee kapasiteetin poolikohtaisesti, joten
-- erillistä moottorimuutosta ei tarvita: uusi aloitusaika = uusi pooli + uusi sääntö + linkki (schedule_rule_pools).
-- Tuotteet haetaan kb:stä Johku-tunnisteella (kb.products.external_system='johku'), ei kovakoodatuilla id:illä.
-- Lähteet: kb.products / product_price_variants / opening_hours + Johku (products/132,152,120,32,9,61,16,15,17,41).
-- Tulkinnat ja ristiriidat: booking/docs/ristiriidat-ja-tulkinnat.md
-- =====================================================================
set local search_path = booking, extensions, public;

-- ---------- asetukset ----------
insert into booking.settings(key, value, description, is_public) values
  ('public_booking_enabled', 'true',          'Verkkovaraus päällä (false = kauppapaikka ei ota varauksia)', true),
  ('public_payment_mode',    '"pay_later"',   'pay_later = vahvistetaan heti, maksetaan paikan päällä (TESTI); hold_until_paid = pending + pito kunnes maksettu (Visma Pay)', true),
  ('hold_minutes',           '15',            'Maksamattoman (pending) varauksen pitoaika minuutteina', true),
  ('customer_change_hours_before', '48',      'Kuinka monta tuntia ennen vuoron alkua asiakas voi viimeistään itse muuttaa varaustaan (siirto toiseen vapaaseen vuoroon / henkilömäärä). Vahvistetun varauksen peruutus tehdään sähköpostitse henkilökunnalle.', true),
  ('annual_card_max_persons', '1',             'Vuosikorttivarauksen henkilömäärä (ilmainen yleinen vuoro; yksi tuleva varaus kerrallaan)', false),
  ('booking_horizon_days',   '120',           'Kuinka monta päivää eteenpäin verkossa voi varata', true),
  ('business_name',          '"Sipoonjoen perinnesauna"', 'Yrityksen nimi (näytetään kauppapaikassa)', true),
  ('timezone',               '"Europe/Helsinki"', 'Aikavyöhyke (vuorosäännöt tulkitaan tässä)', true),
  ('rl_ip_per_10min',        '12',            'Rate limit: julkisia varausyrityksiä / IP / 10 min', false),
  ('rl_email_per_10min',     '5',             'Rate limit: julkisia varausyrityksiä / sähköposti / 10 min', false),
  ('rl_change_per_10min',    '10',            'Rate limit: varauksen muutosyrityksiä / varaustunnus (token) / 10 min', false),
  ('marketing_consent_text_version', '"v1"',  'Markkinointisuostumuksen tekstin versio (tallennetaan asiakkaalle)', false);

-- ---------- resurssit ----------
insert into booking.resources(code, name, kind, kb_location_id, notes, sort_order)
select 'savusauna', 'Savusauna', 'space', (select id from kb.locations where name ilike 'Savusauna%' order by id limit 1),
       'Poissulkevuusalue: yksityisvuoro vie koko saunan, yleiset vuorot jakavat sen.', 10;

insert into booking.resources(code, name, kind, parent_id, capacity, notes, sort_order)
select v.code, v.name, 'capacity_pool', (select id from booking.resources where code = 'savusauna'), v.cap, v.notes, v.ord
from (values
  ('yleinen_arki', 'Yleiset vuorot ma–to (samanaikaisia henkilöitä)', 16, 'Ma–ke yleinen vuoro 16 hlö; to 16–19 yhteensä 16 hlö turvesaunalaiset mukaan lukien. (Johku: resurssi "Viikkovuorot" 28)', 20),
  ('turve',        'Turvetorstai (turvesauna)', 8, 'Turvetorstain turvesaunaan enintään 8 hlö; kuuluu myös yleisen torstaikapasiteetin 16 sisään. (Johku: resurssi "Turvetorstai" 195)', 40),
  -- la–su: kapasiteetti PER ALOITUSAIKA (omistajan päätös). Jokaisella aloitusajalla oma pooli; poolien välillä ei jaeta paikkoja.
  ('yleinen_vkp_1400', 'La–su 2 h vuoro 14:00 (paikat / vuoro)', 6, 'Viikonlopun 2 h yleinen vuoro klo 14:00: 6 hlö per vuoro.', 31),
  ('yleinen_vkp_1430', 'La–su 2 h vuoro 14:30 (paikat / vuoro)', 6, 'Viikonlopun 2 h yleinen vuoro klo 14:30: 6 hlö per vuoro.', 32),
  ('yleinen_vkp_1500', 'La–su 2 h vuoro 15:00 (paikat / vuoro)', 6, 'Viikonlopun 2 h yleinen vuoro klo 15:00: 6 hlö per vuoro.', 33),
  ('yleinen_vkp_1600', 'La–su 2 h vuoro 16:00 (paikat / vuoro)', 6, 'Viikonlopun 2 h yleinen vuoro klo 16:00: 6 hlö per vuoro.', 34),
  ('yleinen_vkp_1630', 'La–su 2 h vuoro 16:30 (paikat / vuoro)', 6, 'Viikonlopun 2 h yleinen vuoro klo 16:30: 6 hlö per vuoro.', 35),
  ('yleinen_vkp_1700', 'La–su 2 h vuoro 17:00 (paikat / vuoro)', 6, 'Viikonlopun 2 h yleinen vuoro klo 17:00 (päättyy 19:00): 6 hlö per vuoro.', 36),
  ('tunti_vkp_1400',   'La–su 1 h vuoro 14:00 (paikat / vuoro)', 10, 'Tunnin vuoro (Johku 152) klo 14:00: 10 hlö per vuoro, OMA kapasiteetti (ei jaa 2 h vuorojen kanssa).', 37),
  ('tunti_vkp_1800',   'La–su 1 h vuoro 18:00 (paikat / vuoro)', 10, 'Tunnin vuoro (Johku 152) klo 18:00: 10 hlö per vuoro, OMA kapasiteetti (ei jaa 2 h vuorojen kanssa).', 38)
) as v(code, name, cap, notes, ord);

-- ---------- tuotekonfiguraatio (lookup: kb.products.external_id = Johku-id) ----------
insert into booking.product_config(product_id, sale_kind, bookable, shop_visible, sort_order, min_persons, max_persons, notes)
select p.id, v.kind, true, true, v.ord, 1, v.maxp, v.note
from (values
  ('132', 'public_shift',  10, null, 'Yleinen vuoro (to 17–19, la–su 2 h vuorot)'),
  ('152', 'public_shift',  15, 10,   'Tunnin saunavuoro la–su klo 14 tai 18 (10 hlö / vuoro)'),
  ('32',  'public_shift',  20, null, 'Miesten sauna ma 16–19'),
  ('9',   'public_shift',  21, null, 'Naisten sauna ti 16–19'),
  ('61',  'public_shift',  22, null, 'Hiljainen sauna ke 16–19'),
  ('120', 'public_shift',  30, 8,    'Turvetorstai to 16–19 (turvesauna 16–17)'),
  ('16',  'private_shift', 100, 16,  'Oma savusaunavuoro'),
  ('15',  'private_shift', 110, 16,  'Savusaunan jälkilöylyt'),
  ('17',  'private_shift', 120, 16,  'Savusaunavuoro yrityksille'),
  ('41',  'private_shift', 130, 16,  'Jälkilöylyt yrityksille')
) as v(ext, kind, ord, maxp, note)
join kb.products p on p.external_system = 'johku' and p.external_id = v.ext;

-- ---------- vuorosäännöt ----------
-- Aikataulu (pooli-sarake: mitä kapasiteettipooleja vuoro kuluttaa; yksityisvuoroilla ei pooleja)
-- var_* = kb.product_price_variants -rivi, josta hinta luetaan (weekdays + time_start + time_end).
create temp table _rules (
  ext text, label text, mode text, weekdays smallint[], start_time time, dur int, pools text[],
  var_wd smallint[], var_start time, var_end time, price_mode text, inc int, maxp int, deadline int,
  active boolean, valid_from date, valid_to date, ord int, notes text
) on commit drop;

insert into _rules values
 -- === YLEISET VUOROT (shared) ===
 -- ma–ke 16–19: miesten / naisten / hiljainen sauna, 16 hlö (kb.opening_hours + Johku-tuotteet 32/9/61)
 ('32','Miesten sauna ma 16–19','shared','{1}',  '16:00',180,'{yleinen_arki}',null,null,null,'per_person',null,16,0,true,null,null,20,'kb.opening_hours id1'),
 ('9', 'Naisten sauna ti 16–19','shared','{2}',  '16:00',180,'{yleinen_arki}',null,null,null,'per_person',null,16,0,true,null,null,21,'kb.opening_hours id2'),
 ('61','Hiljainen sauna ke 16–19','shared','{3}','16:00',180,'{yleinen_arki}',null,null,null,'per_person',null,16,0,true,null,null,22,'kb.opening_hours id3'),
 -- torstai: turvesauna 16–19 (turve-pooli 8 + torstain yhteiskapasiteetti 16), yleinen vuoro 17–19
 ('120','Turvetorstai to 16–19 (turvesauna 16–17, jää yleiselle vuorolle 17–19)','shared','{4}','16:00',180,'{yleinen_arki,turve}',null,null,null,'per_person',null,8,0,true,null,null,30,'Turvesaunaan max 8; sama 16 hlön kapasiteetti kuin yleisellä vuorolla'),
 ('132','Yleinen vuoro to 17–19','shared','{4}','17:00',120,'{yleinen_arki}',null,null,null,'per_person',null,16,15,true,null,null,10,'Voi tulla pelkälle yleiselle vuorolle; 16 hlön kokonaiskapasiteetti sisältää turvesaunalaiset'),
 -- la–su: 2 h vuorot, alkamisajat Johkusta (tuote 132 ownStarttime). Kapasiteetti 6 hlöä PER ALOITUSAIKA (oma pooli per vuoro).
 -- Klo 15:30 EI ole aloitusaikaa (omistajan päätös: ei ympäri vuoden).
 ('132','Yleinen vuoro la–su 14:00 (2 h)','shared','{6,7}','14:00',120,'{yleinen_vkp_1400}',null,null,null,'per_person',null,6,15,true,null,null,11,null),
 ('132','Yleinen vuoro la–su 14:30 (2 h)','shared','{6,7}','14:30',120,'{yleinen_vkp_1430}',null,null,null,'per_person',null,6,15,true,null,null,12,null),
 ('132','Yleinen vuoro la–su 15:00 (2 h)','shared','{6,7}','15:00',120,'{yleinen_vkp_1500}',null,null,null,'per_person',null,6,15,true,null,null,13,null),
 ('132','Yleinen vuoro la–su 16:00 (2 h)','shared','{6,7}','16:00',120,'{yleinen_vkp_1600}',null,null,null,'per_person',null,6,15,true,null,null,15,null),
 ('132','Yleinen vuoro la–su 16:30 (2 h)','shared','{6,7}','16:30',120,'{yleinen_vkp_1630}',null,null,null,'per_person',null,6,15,true,null,null,16,null),
 ('132','Yleinen vuoro la–su 17:00 (2 h)','shared','{6,7}','17:00',120,'{yleinen_vkp_1700}',null,null,null,'per_person',null,6,15,true,null,null,17,'Viimeinen vuoro päättyy 19:00'),
 -- tunnin vuorot la–su klo 14 ja 18 (tuote Johku 152, 18 €/hlö): OMA kapasiteetti 10 hlö per vuoro, ei jaa kapasiteettia 2 h vuorojen kanssa
 ('152','Tunnin saunavuoro la–su 14:00','shared','{6,7}','14:00',60,'{tunti_vkp_1400}',null,null,null,'per_person',null,10,30,true,null,null,18,'10 hlö / vuoro, oma kapasiteetti'),
 ('152','Tunnin saunavuoro la–su 18:00','shared','{6,7}','18:00',60,'{tunti_vkp_1800}',null,null,null,'per_person',null,10,30,true,null,null,19,'10 hlö / vuoro, oma kapasiteetti'),
 -- === YKSITYISVUOROT (exclusive): Oma savusaunavuoro (kb 25 / Johku 16) ===
 ('16','Oma savusaunavuoro la–su 13–14 (1 h)','exclusive','{6,7}','13:00',60,null,'{6,7}','13:00','14:00','fixed_plus_extra',8,16,720,true,null,null,100,'Sisältyvät henkilöt 8 = Johku price row includes (kb:ssä puuttuu)'),
 ('16','Oma savusaunavuoro la–su 13–15 (2 h)','exclusive','{6,7}','13:00',120,null,'{6,7}','13:00','15:00','fixed_plus_extra',8,16,720,true,null,null,101,'Johku includes=11 tälle hintariville, kb tyhjä → käytetään 8 (vahvistettava)'),
 ('16','Oma savusaunavuoro pe 14–21 (7 h)','exclusive','{5}','14:00',420,null,'{5}','14:00','21:00','fixed_plus_extra',8,16,720,true,null,null,102,null),
 ('16','Oma savusaunavuoro pe 16–21 (5 h)','exclusive','{5}','16:00',300,null,'{5}','16:00','21:00','fixed_plus_extra',8,16,720,true,null,null,103,null),
 ('16','Oma savusaunavuoro pe 14–16 (2 h)','exclusive','{5}','14:00',120,null,'{5}','14:00','16:00','fixed_plus_extra',8,16,720,true,null,null,104,null),
 ('16','Oma savusaunavuoro ma–pe 16–19 (3 h)','exclusive','{1,2,3,4,5}','16:00',180,null,'{1,2,3,4,5}','16:00','19:00','fixed_plus_extra',8,16,720,true,null,null,105,'Ma–to 16–19 osuu yleisiin vuoroihin → päällekkäissääntö estää jos yleisillä vuoroilla varauksia'),
 ('16','Oma savusaunavuoro ma–to 14–16 esilöylyt (2 h)','exclusive','{1,2,3,4}','14:00',120,null,'{1,2,3,4}','14:00','16:00','fixed_plus_extra',8,16,720,true,null,null,106,'Omistajan päätös: ma–to esilöylyt jatkuu toistaiseksi (kb-variantin valid_to tyhjä, hinta ennallaan)'),
 ('16','Oma savusaunavuoro uudenvuodenaatto 31.12.2026 (7 h)','exclusive','{4}','14:00',420,null,null,null,null,'fixed_plus_extra',8,16,720,false,'2026-12-31','2026-12-31',107,'EI KÄYTÖSSÄ: kb-variantissa 1 ei ole alkamisaikaa → omistajan vahvistettava (esim. 14–21 vai 16–23)'),
 -- === Savusaunan jälkilöylyt (kb 26 / Johku 15): alkaa 19:00 ===
 ('15','Jälkilöylyt ma–to 19–21 (2 h)','exclusive','{1,2,3,4}','19:00',120,null,'{1,2,3,4}','19:00','21:00','fixed_plus_extra',6,16,120,true,null,null,110,'deadline 120 min = oletus (Johkussa tyhjä)'),
 ('15','Jälkilöylyt pe 19–22 (3 h)','exclusive','{5}','19:00',180,null,'{5}','19:00','22:00','fixed_plus_extra',6,16,120,true,null,null,111,'Johkussa pe-aloitusaika vain yksittäiselle päivälle 16.1.2026; kb:n mukaan pe tarjolla'),
 ('15','Jälkilöylyt la 19–22 (3 h)','exclusive','{6}','19:00',180,null,'{6}','19:00','22:00','fixed_plus_extra',6,16,120,true,null,null,112,null),
 ('15','Jälkilöylyt su 19–22 (3 h)','exclusive','{7}','19:00',180,null,'{7}','19:00','22:00','fixed_plus_extra',6,16,120,true,null,null,113,null),
 -- === Yritysten savusaunavuorot (kb 48 / Johku 17) ===
 ('17','Savusaunavuoro yrityksille pe 12–21 (9 h)','exclusive','{5}','12:00',540,null,'{5}','12:00','21:00','fixed',null,16,1440,true,null,null,120,'Johku: Pe pitkä, deadline 24 h'),
 ('17','Savusaunavuoro yrityksille pe 16–21 (5 h)','exclusive','{5}','16:00',300,null,'{5}','16:00','21:00','fixed',null,16,1440,true,null,null,121,null),
 ('17','Savusaunavuoro yrityksille ma–to 14–16 (2 h)','exclusive','{1,2,3,4}','14:00',120,null,'{1,2,3,4}','14:00','16:00','fixed',null,16,1440,true,null,null,122,null),
 -- === Yritysten jälkilöylyt (kb 49 / Johku 41) ===
 ('41','Jälkilöylyt yrityksille la–su 19–22 (3 h)','exclusive','{6,7}','19:00',180,null,'{6,7}','19:00','22:00','fixed_plus_extra',6,16,120,true,null,null,130,'Sisältyvät henkilöt 6 = oletus (kb:ssä vain lisähenkilöhinta 10 €)'),
 ('41','Jälkilöylyt yrityksille ma–to 19–21 (2 h)','exclusive','{1,2,3,4}','19:00',120,null,'{1,2,3,4}','19:00','21:00','fixed_plus_extra',6,16,120,true,null,null,131,null);

with ins as (
  insert into booking.schedule_rules(product_id, label, mode, space_id, weekdays, start_time, duration_minutes, valid_from, valid_to,
                                     min_persons, max_persons, price_mode, price_variant_id, included_persons, deadline_minutes, active, sort_order, notes)
  select p.id, r.label, r.mode, (select id from booking.resources where code = 'savusauna'), r.weekdays, r.start_time, r.dur, r.valid_from, r.valid_to,
         1, r.maxp, r.price_mode,
         (select v.id from kb.product_price_variants v
           where v.product_id = p.id and v.weekdays::int[] = r.var_wd::int[] and v.time_start = r.var_start and v.time_end = r.var_end
           order by v.active desc, v.id limit 1),
         r.inc, r.deadline, r.active, r.ord, r.notes
    from _rules r
    join kb.products p on p.external_system = 'johku' and p.external_id = r.ext
  returning id, label
)
insert into booking.schedule_rule_pools(rule_id, pool_id)
select ins.id, res.id
  from ins join _rules r on r.label = ins.label
  cross join lateral unnest(r.pools) as pc(code)
  join booking.resources res on res.code = pc.code;

-- Varmistus: jokaisella yksityisvuorolla pitää olla hintavariantti kb:ssä (paitsi ei-käytössä oleva)
do $$
begin
  if exists (select 1 from booking.schedule_rules where mode = 'exclusive' and active and price_variant_id is null) then
    raise exception 'Seed: yksityisvuorosäännöltä puuttuu kb-hintavariantti';
  end if;
  if (select count(*) from booking.schedule_rules where mode = 'shared' and active) <> 13 then
    raise exception 'Seed: odotettiin 13 yleistä vuorosääntöä, löytyi %', (select count(*) from booking.schedule_rules where mode = 'shared' and active);
  end if;
  -- jokaisella viikonlopun yleisellä vuorosäännöllä on täsmälleen yksi OMA pooli (kapasiteetti per aloitusaika), eikä pooli ole jaettu
  if exists (select 1 from booking.schedule_rules r where r.mode = 'shared' and r.weekdays = '{6,7}'
              and (select count(*) from booking.schedule_rule_pools p where p.rule_id = r.id) <> 1) then
    raise exception 'Seed: viikonlopun yleisellä vuorolla pitää olla täsmälleen yksi oma kapasiteettipooli';
  end if;
  if exists (select 1 from booking.schedule_rule_pools p join booking.schedule_rules r on r.id = p.rule_id
              where r.weekdays = '{6,7}' and r.mode = 'shared' group by p.pool_id having count(*) > 1) then
    raise exception 'Seed: viikonlopun kapasiteettipooli on jaettu usean vuorosäännön kesken';
  end if;
  if exists (select 1 from booking.schedule_rules where start_time = '15:30' and weekdays && array[6,7]::smallint[] and mode = 'shared') then
    raise exception 'Seed: klo 15:30 ei ole aloitusaika';
  end if;
end $$;
