-- =====================================================================
-- booking 08: perusdata – resurssit, asetukset, tuotekonfiguraatio ja vuorosäännöt (Savusauna)
-- Säännöt ovat DATAA (taulut schedule_rules / schedule_rule_pools / resources), ei koodia.
-- Muutos: lisää uusi migraatio (tai Koodarin SQL) – ks. booking/README.md "Miten säännöt muutetaan".
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
  ('booking_horizon_days',   '120',           'Kuinka monta päivää eteenpäin verkossa voi varata', true),
  ('business_name',          '"Sipoonjoen perinnesauna"', 'Yrityksen nimi (näytetään kauppapaikassa)', true),
  ('timezone',               '"Europe/Helsinki"', 'Aikavyöhyke (vuorosäännöt tulkitaan tässä)', true),
  ('rl_ip_per_10min',        '12',            'Rate limit: julkisia varausyrityksiä / IP / 10 min', false),
  ('rl_email_per_10min',     '5',             'Rate limit: julkisia varausyrityksiä / sähköposti / 10 min', false),
  ('marketing_consent_text_version', '"v1"',  'Markkinointisuostumuksen tekstin versio (tallennetaan asiakkaalle)', false);

-- ---------- resurssit ----------
insert into booking.resources(code, name, kind, kb_location_id, notes, sort_order)
select 'savusauna', 'Savusauna', 'space', (select id from kb.locations where name ilike 'Savusauna%' order by id limit 1),
       'Poissulkevuusalue: yksityisvuoro vie koko saunan, yleiset vuorot jakavat sen.', 10;

insert into booking.resources(code, name, kind, parent_id, capacity, notes, sort_order)
select v.code, v.name, 'capacity_pool', (select id from booking.resources where code = 'savusauna'), v.cap, v.notes, v.ord
from (values
  ('yleinen_arki', 'Yleiset vuorot ma–to (samanaikaisia henkilöitä)', 16, 'Ma–ke yleinen vuoro 16 hlö; to 16–19 yhteensä 16 hlö turvesaunalaiset mukaan lukien. (Johku: resurssi "Viikkovuorot" 28)', 20),
  ('yleinen_vkp',  'Yleiset vuorot la–su (samanaikaisia henkilöitä)', 6,  'Viikonlopun yleiset vuorot ja tunnin vuorot: enintään 6 henkilöä sisällä yhtä aikaa limittäisistä vuoroista huolimatta. (Johku: resurssi "Viikonloppu" 206)', 30),
  ('turve',        'Turvetorstai (turvesauna)', 8, 'Turvetorstain turvesaunaan enintään 8 hlö; kuuluu myös yleisen torstaikapasiteetin 16 sisään. (Johku: resurssi "Turvetorstai" 195)', 40)
) as v(code, name, cap, notes, ord);

-- ---------- tuotekonfiguraatio (lookup: kb.products.external_id = Johku-id) ----------
insert into booking.product_config(product_id, sale_kind, bookable, shop_visible, sort_order, min_persons, max_persons, notes)
select p.id, v.kind, true, true, v.ord, 1, v.maxp, v.note
from (values
  ('132', 'public_shift',  10, null, 'Yleinen vuoro (to 17–19, la–su 2 h vuorot)'),
  ('152', 'public_shift',  15, 6,    'Tunnin saunavuoro la–su klo 14 tai 18'),
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
 -- la–su: 2 h vuorot, alkamisajat Johkusta (tuote 132 ownStarttime); samanaikaisia henkilöitä max 6 (yleinen_vkp)
 ('132','Yleinen vuoro la–su 14:00 (2 h)','shared','{6,7}','14:00',120,'{yleinen_vkp}',null,null,null,'per_person',null,6,15,true,null,null,11,null),
 ('132','Yleinen vuoro la–su 14:30 (2 h)','shared','{6,7}','14:30',120,'{yleinen_vkp}',null,null,null,'per_person',null,6,15,true,null,null,12,null),
 ('132','Yleinen vuoro la–su 15:00 (2 h)','shared','{6,7}','15:00',120,'{yleinen_vkp}',null,null,null,'per_person',null,6,15,true,null,null,13,null),
 ('132','Yleinen vuoro la–su 15:30 (2 h, kesäkausi)','shared','{6,7}','15:30',120,'{yleinen_vkp}',null,null,null,'per_person',null,6,15,true,'2026-06-13','2026-08-31',14,'Johku: 15:30-aloitus vain 13.6.–31.8.2026; jatkuuko kesällä 2027 → päivitä valid_from/valid_to'),
 ('132','Yleinen vuoro la–su 16:00 (2 h)','shared','{6,7}','16:00',120,'{yleinen_vkp}',null,null,null,'per_person',null,6,15,true,null,null,15,null),
 ('132','Yleinen vuoro la–su 16:30 (2 h)','shared','{6,7}','16:30',120,'{yleinen_vkp}',null,null,null,'per_person',null,6,15,true,null,null,16,null),
 ('132','Yleinen vuoro la–su 17:00 (2 h)','shared','{6,7}','17:00',120,'{yleinen_vkp}',null,null,null,'per_person',null,6,15,true,null,null,17,'Viimeinen vuoro päättyy 19:00'),
 -- tunnin vuorot la–su klo 14 ja 18 (18 €/hlö); jakavat saman 6 hlön kapasiteetin (OMISTAJAN OHJE; Johkussa 18:00-resurssilla 10 paikkaa → ks. ristiriidat)
 ('152','Tunnin saunavuoro la–su 14:00','shared','{6,7}','14:00',60,'{yleinen_vkp}',null,null,null,'per_person',null,6,30,true,null,null,18,null),
 ('152','Tunnin saunavuoro la–su 18:00','shared','{6,7}','18:00',60,'{yleinen_vkp}',null,null,null,'per_person',null,6,30,true,null,null,19,null),
 -- === YKSITYISVUOROT (exclusive): Oma savusaunavuoro (kb 25 / Johku 16) ===
 ('16','Oma savusaunavuoro la–su 13–14 (1 h)','exclusive','{6,7}','13:00',60,null,'{6,7}','13:00','14:00','fixed_plus_extra',8,16,720,true,null,null,100,'Sisältyvät henkilöt 8 = Johku price row includes (kb:ssä puuttuu)'),
 ('16','Oma savusaunavuoro la–su 13–15 (2 h)','exclusive','{6,7}','13:00',120,null,'{6,7}','13:00','15:00','fixed_plus_extra',8,16,720,true,null,null,101,'Johku includes=11 tälle hintariville, kb tyhjä → käytetään 8 (vahvistettava)'),
 ('16','Oma savusaunavuoro pe 14–21 (7 h)','exclusive','{5}','14:00',420,null,'{5}','14:00','21:00','fixed_plus_extra',8,16,720,true,null,null,102,null),
 ('16','Oma savusaunavuoro pe 16–21 (5 h)','exclusive','{5}','16:00',300,null,'{5}','16:00','21:00','fixed_plus_extra',8,16,720,true,null,null,103,null),
 ('16','Oma savusaunavuoro pe 14–16 (2 h)','exclusive','{5}','14:00',120,null,'{5}','14:00','16:00','fixed_plus_extra',8,16,720,true,null,null,104,null),
 ('16','Oma savusaunavuoro ma–pe 16–19 (3 h)','exclusive','{1,2,3,4,5}','16:00',180,null,'{1,2,3,4,5}','16:00','19:00','fixed_plus_extra',8,16,720,true,null,null,105,'Ma–to 16–19 osuu yleisiin vuoroihin → päällekkäissääntö estää jos yleisillä vuoroilla varauksia'),
 ('16','Oma savusaunavuoro ma–to 14–16 esilöylyt (2 h)','exclusive','{1,2,3,4}','14:00',120,null,'{1,2,3,4}','14:00','16:00','fixed_plus_extra',8,16,720,true,null,null,106,'kb-variantin voimassaolo päättyy 1.11.2026 → rivi poistuu tarjonnasta itsestään'),
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
  if (select count(*) from booking.schedule_rules where mode = 'shared' and active) <> 14 then
    raise exception 'Seed: odotettiin 14 yleistä vuorosääntöä, löytyi %', (select count(*) from booking.schedule_rules where mode = 'shared' and active);
  end if;
end $$;
