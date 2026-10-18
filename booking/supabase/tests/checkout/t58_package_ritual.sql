-- t58: paketti kb 7 verkkokaupassa (rituaali Rauni 0–20 + savusauna 30–120). Kumoutuu lopuksi (tahallinen poikkeus). Tilausnumerolaskuri palautetaan.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table t58_r(n serial, ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t58_r(ok, label) values (coalesce(p_ok, false), coalesce(p_label, 'NULL-LABEL')) $$;
create function pg_temp.ts(p_d date, p_t text) returns timestamptz language sql as $$ select (p_d + p_t::time) at time zone 'Europe/Helsinki' $$;
create function pg_temp.mk(p_prod bigint, p_slot timestamptz, p_persons int, p_email text) returns jsonb language sql as $$
  select booking.public_create_treatment_booking(p_prod, p_slot, p_persons, 'Testi Asiakas', p_email, '+358401234567', false, 'fi', null, 'private', null, case when p_prod = 10 then 'hunajahoito' end) $$;
-- vapaat alkuajat (public RPC) merkkijonona
create function pg_temp.pav(p_prod bigint, p_d date, p_persons int) returns text language sql as $$
  select coalesce(string_agg(to_char(q.starts_at at time zone 'Europe/Helsinki', 'HH24:MI'), ',' order by q.starts_at), '') from booking.public_treatment_availability(p_prod, p_d, p_d, p_persons) q where q.status = 'available' $$;
do $t$
declare v_seq0 bigint; v_maxid bigint; v_foreign int; r jsonb; tok uuid; oid bigint; rid bigint; v_cust bigint; w1 date; w2 date; w3 date; d date; n int; v_ok boolean; v_s text; rr record; v_ws date[];
  v_cat jsonb; o_item record; v_blk bigint;
begin
  select last_value into v_seq0 from booking.orders_order_no_seq; select coalesce(max(id), 0) into v_maxid from booking.orders;
  update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode';
  update booking.integration_config set mode = 'test' where key = 'mobilepay';
  update booking.settings set value = '400'::jsonb where key = 'public_treatment_horizon_days';
  update booking.settings set value = '1000'::jsonb where key in ('public_treatment_global_per_hour', 'public_treatment_max_open_per_email', 'rl_email_per_10min', 'rl_ip_per_10min');
  -- valitse kolme siistiä viikonloppua (la+su): paketilla 3 alkuaikaa, hoidoilla/saunotuksella tarvittavat ajat vapaana, ei varauksia eikä sulkuja
  for d in select x::date from generate_series(current_date + 20, current_date + 160, interval '7 days') x where extract(isodow from x) = 6 loop
    exit when cardinality(coalesce(v_ws, '{}')) >= 3;
    continue when not (booking._public_shift_day_open(d) and booking._public_shift_day_open(d + 1));
    continue when exists (select 1 from booking.reservations r where r.status in ('pending', 'confirmed') and r.starts_at >= (d::timestamp) at time zone 'Europe/Helsinki' and r.starts_at < ((d + 2)::timestamp) at time zone 'Europe/Helsinki');
    continue when exists (select 1 from booking.space_blocks b where b.active and b.during && tstzrange((d::timestamp) at time zone 'Europe/Helsinki', ((d + 2)::timestamp) at time zone 'Europe/Helsinki'));
    continue when (select count(*) from booking._treatment_availability_core(7, d, d, 1, true, false)) <> 3 or (select count(*) from booking._treatment_availability_core(7, d + 1, d + 1, 1, true, false)) <> 3;
    v_ws := array_append(v_ws, d);
  end loop;
  if cardinality(coalesce(v_ws, '{}')) < 3 then raise exception 'TESTRESULT_ABORT siistejä viikonloppuja %', coalesce(cardinality(v_ws), 0); end if;
  w1 := v_ws[1]; w2 := v_ws[2]; w3 := v_ws[3];

  -- ===== A: konfiguraatio / näkyvyys (migraation jälkeen) =====
  select e into v_cat from jsonb_array_elements(booking.public_catalog()) e where (e ->> 'id')::bigint = 7;
  perform pg_temp.ck(v_cat is not null and v_cat ->> 'booking_kind' = 'slots' and (v_cat ->> 'price')::numeric = 49 and v_cat ->> 'price_type' = 'per_person' and (v_cat ->> 'max_persons')::int = 6 and (v_cat ->> 'slot_grid_minutes')::int = 30,
                     'A1: public_catalog sisältää tuotteen 7 (slots, 49 €/hlö, max 6)');
  perform pg_temp.ck((select vat_rate from kb.products where id = 7) = 25.5 and (select price_includes_vat from kb.products where id = 7), 'A2: ALV 25,5 % (sis.) ennallaan');
  perform pg_temp.ck(pg_temp.pav(7, w1, 2) = '16:00,16:30,17:00' and pg_temp.pav(7, w1 + 1, 2) = '16:00,16:30,17:00', 'A3: la ja su: alkuajat 16:00, 16:30, 17:00');
  select count(*) into n from booking.public_treatment_availability(7, w1, w1, 2) q where q.ends_at - q.starts_at = interval '120 minutes' and q.total = 98 and q.duration_minutes = 120;
  perform pg_temp.ck(n = 3, 'A4: kesto 120 min, hinta 2 hlö = 98 €');
  perform pg_temp.ck(pg_temp.pav(7, w1 - 1, 2) = '' and pg_temp.pav(7, w1 + 2, 2) = '' and pg_temp.pav(7, w1 + 3, 2) = '', 'A5: pe, ma, ti: ei tarjolla (vain la & su)');
  perform pg_temp.ck(pg_temp.pav(7, w1, 6) = '16:00,16:30,17:00' and pg_temp.pav(7, w1, 7) = '', 'A6: 6 hlö ok, 7 hlö ei tarjolla');
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
  v_s := pg_temp.pav(7, w1, 2);
  execute 'reset role';
  perform pg_temp.ck(v_s = '16:00,16:30,17:00', 'A7: anon-roolilla saatavuus toimii');

  -- ===== B: varaus, legit, rajat 20/30/120 =====
  r := pg_temp.mk(7, pg_temp.ts(w1, '16:00'), 2, 'b1@t58.example'); tok := (r ->> 'token')::uuid; oid := (select id from booking.orders where public_token = tok);
  perform pg_temp.ck((r ->> 'ok')::boolean and (r ->> 'total')::numeric = 98 and r ->> 'checkout_state' = 'awaiting_payment', 'B1: varaus 2 hlö la 16:00 (pending, odottaa maksua, 98 €) ' || coalesce(r ->> 'code', ''));
  select id into rid from booking.reservations where order_id = oid;
  perform pg_temp.ck((select starts_at = pg_temp.ts(w1, '16:00') and ends_at = pg_temp.ts(w1, '18:00') from booking.reservations where id = rid), 'B2: varaus 16:00–18:00 (120 min)');
  perform pg_temp.ck((select count(*) = 1 and bool_and(starts_at = pg_temp.ts(w1, '16:00') and ends_at = pg_temp.ts(w1, '16:20') and mode = 'shared' and pool_ids = array[17]::bigint[] and persons = 2) from booking.reservation_legs where reservation_id = rid and resource_id = 12),
                     'B3: Rauni-leg 16:00–16:20 (20 min), rituaalipooli 17, jaettu istunto');
  -- ensisijainen leg (savusauna) on varausrivillä itsellään: claim_offset_min / claim_minutes / pool_ids
  perform pg_temp.ck((select space_id = 1 and mode = 'shared' and claim_offset_min = 30 and coalesce(claim_minutes, 90) = 90 and pool_ids = array[(select id from booking.resources where code = 'yleinen_vkp_1630')] from booking.reservations where id = rid),
                     'B4: savusauna-claim alkaa +30 min, kestää 90 min (16:30–18:00), pooli yleinen_vkp_1630, jaettu: ' || (select claim_offset_min || '/' || coalesce(claim_minutes::text, 'loppuun') || '/' || pool_ids::text from booking.reservations where id = rid));
  perform pg_temp.ck((select count(*) = 1 from booking.v_claims c where c.reservation_id = rid and c.resource_id = 1 and c.role = 'space' and c.claim_start = pg_temp.ts(w1, '16:30') and c.claim_end = pg_temp.ts(w1, '18:00') and c.persons = 2)
                 and (select count(*) = 1 from booking.v_claims c where c.reservation_id = rid and c.resource_id = 12 and c.claim_start = pg_temp.ts(w1, '16:00') and c.claim_end = pg_temp.ts(w1, '16:20')), 'B4b: v_claims: savusauna 16:30–18:00 (30–120) ja Rauni 16:00–16:20 (0–20)');
  perform pg_temp.ck(not exists (select 1 from booking.v_claims c where c.reservation_id = rid and c.resource_id in (1, 12) and c.claim_start < pg_temp.ts(w1, '16:30') and c.claim_end > pg_temp.ts(w1, '16:20')), 'B4c: tauko 16:20–16:30: kumpaakaan tilaa ei varata taukoaikana');
  perform pg_temp.ck((select count(*) from booking.order_items where order_id = oid and line_total_gross = 98 and quantity = 2) = 1 or (select total_gross from booking.orders where id = oid) = 98, 'B6: tilauksen summa 98 €');
  -- tauko-/raja-aika: seuraava paketti 16:30 sallitaan heti (rituaali-rituaali 10 min väli täyttyy), kapasiteetti ei jaa istuntojen välillä
  r := pg_temp.mk(7, pg_temp.ts(w1, '16:30'), 6, 'b2@t58.example');
  perform pg_temp.ck((r ->> 'ok')::boolean, 'B7: toinen paketti 16:30 (6 hlö) onnistuu: 10 min rituaali-rituaali-väli riittää (' || coalesce(r ->> 'code', 'ok') || ')');
  perform pg_temp.ck(pg_temp.pav(7, w1, 5) = '17:00', 'B8: 2 hlö 16:00 + 6 hlö 16:30 varattu: 5 hlö mahtuu vain 17:00 (16:00: 2+5>6, 16:30: täynnä)');
  perform pg_temp.ck(pg_temp.pav(7, w1, 4) = '16:00,17:00' or pg_temp.pav(7, w1, 4) = '17:00', 'B9: 4 hlö: 16:00 (2+4=6 mahtuu jos saunottaja/pooli sallii) tai 17:00');
  -- kaksi pakettia samaan aikaan: 16:00 2 + 3 = 5, kolmas 2 hlö ei mahdu, 1 hlö mahtuu
  r := pg_temp.mk(7, pg_temp.ts(w1, '16:00'), 3, 'b3@t58.example');
  perform pg_temp.ck((r ->> 'ok')::boolean, 'B10: kaksi pakettia samaan aikaan (2+3=5 hlö) onnistuu (' || coalesce(r ->> 'code', 'ok') || ')');
  r := pg_temp.mk(7, pg_temp.ts(w1, '16:00'), 2, 'b4@t58.example');
  perform pg_temp.ck(not (r ->> 'ok')::boolean and r ->> 'code' in ('capacity_exceeded', 'slot_unavailable'), 'B11: kolmas paketti 2 hlö (5+2>6) hylätään: ' || coalesce(r ->> 'code', 'ok'));
  r := pg_temp.mk(7, pg_temp.ts(w1, '16:00'), 1, 'b5@t58.example');
  perform pg_temp.ck((r ->> 'ok')::boolean, 'B12: 6. paikka (5+1=6) onnistuu');
  r := pg_temp.mk(7, pg_temp.ts(w1, '16:00'), 1, 'b6@t58.example');
  perform pg_temp.ck(not (r ->> 'ok')::boolean, 'B13: 7. paikka hylätään (rituaalipooli 6/6)');
  perform pg_temp.ck(pg_temp.pav(7, w1, 1) = '17:00' and pg_temp.pav(8, w1, 1) = '17:00', 'B14: 16:00 täynnä (paketti+rituaali jakavat pooli 17): vain 17:00 vapaana, myös saunotusrituaalille');
  -- virheelliset: henkilömäärä, väärä aika, väärä päivä
  r := pg_temp.mk(7, pg_temp.ts(w1 + 1, '16:00'), 7, 'b7@t58.example');
  perform pg_temp.ck(not (r ->> 'ok')::boolean, 'B15: 7 hlö hylätään (max 6): ' || coalesce(r ->> 'code', 'ok'));
  r := pg_temp.mk(7, pg_temp.ts(w1 + 1, '15:30'), 2, 'b8@t58.example');
  perform pg_temp.ck(not (r ->> 'ok')::boolean, 'B16: alkuaika 15:30 ei sallittu: ' || coalesce(r ->> 'code', 'ok'));
  r := pg_temp.mk(7, pg_temp.ts(w1 - 1, '16:00'), 2, 'b9@t58.example');
  perform pg_temp.ck(not (r ->> 'ok')::boolean, 'B17: perjantai hylätään: ' || coalesce(r ->> 'code', 'ok'));
  -- peruutus vapauttaa paikat
  perform booking.public_cancel_booking(tok);
  perform pg_temp.ck(pg_temp.pav(7, w1, 2) like '%16:00%', 'B18: peruutus vapauttaa 16:00-paikat');
  -- ryhmäkoko-käsittely: alustava varaus kun kynnys ylittyy
  update booking.settings set value = '5'::jsonb where key = 'checkout_group_threshold_persons';
  r := pg_temp.mk(7, pg_temp.ts(w1 + 1, '16:00'), 5, 'g1@t58.example');
  perform pg_temp.ck((r ->> 'ok')::boolean and r ->> 'checkout_state' = 'preliminary' and (select hold_kind from booking.orders where public_token = (r ->> 'token')::uuid) = 'preliminary', 'B19: ryhmä (5 hlö, kynnys 5) => alustava varaus kuten muillakin tuotteilla');
  update booking.settings set value = '0'::jsonb where key = 'checkout_group_threshold_persons';

  -- ===== C: sunnuntai: yhteiskapasiteetti Rauni-rituaalivarausten kanssa =====
  r := pg_temp.mk(8, pg_temp.ts(w1 + 1, '17:00'), 4, 'c1@t58.example');
  perform pg_temp.ck((r ->> 'ok')::boolean, 'C1: saunotusrituaali 4 hlö su 17:00 (' || coalesce(r ->> 'code', 'ok') || ')');
  perform pg_temp.ck(pg_temp.pav(7, w1 + 1, 2) like '%17:00%' and pg_temp.pav(7, w1 + 1, 3) not like '%17:00%' and pg_temp.pav(7, w1 + 1, 3) like '%16:30%', 'C2: su 17:00 (4 hlö rituaalia): paketti 2 hlö mahtuu, 3 hlö ei (' || pg_temp.pav(7, w1 + 1, 3) || ')');
  r := pg_temp.mk(7, pg_temp.ts(w1 + 1, '17:00'), 3, 'c2@t58.example');
  perform pg_temp.ck(not (r ->> 'ok')::boolean, 'C4: paketti 3 hlö su 17:00 hylätään (4+3>6 yhteinen Rauni-pooli): ' || coalesce(r ->> 'code', 'ok'));
  r := pg_temp.mk(7, pg_temp.ts(w1 + 1, '17:00'), 2, 'c3@t58.example');
  perform pg_temp.ck((r ->> 'ok')::boolean, 'C5: paketti 2 hlö su 17:00 mahtuu (4+2=6) ' || coalesce(r ->> 'code', 'ok'));
  perform pg_temp.ck(pg_temp.pav(8, w1 + 1, 1) not like '%17:00%', 'C6: 17:00 täynnä myös saunotusrituaalille');

  -- ===== D: päällekkäinen hoito Raunissa (w2 la) =====
  perform pg_temp.ck(pg_temp.pav(10, w2, 1) like '%17:00%' and pg_temp.pav(10, w2, 1) like '%18:00%', 'D0: esiehto: Saunahoito 17:00 ja 18:00 tarjolla');
  r := pg_temp.mk(10, pg_temp.ts(w2, '17:00'), 1, 'd1@t58.example');
  perform pg_temp.ck((r ->> 'ok')::boolean, 'D1: Saunahoito (60 min) la 17:00–18:00 Raunissa ' || coalesce(r ->> 'code', 'ok'));
  perform pg_temp.ck(pg_temp.pav(7, w2, 2) = '16:00', 'D2: hoito 17:00–18:00: paketti vain 16:00 (rituaali 16:00–16:20, 15 min puskuri ok); 16:30 ja 17:00 estetty (' || pg_temp.pav(7, w2, 2) || ')');
  r := pg_temp.mk(7, pg_temp.ts(w2, '16:30'), 2, 'd2@t58.example');
  perform pg_temp.ck(not (r ->> 'ok')::boolean, 'D3: paketti 16:30 hylätään (rituaali 16:30–16:50 osuu hoidon puskuriin): ' || coalesce(r ->> 'code', 'ok'));
  perform pg_temp.ck(booking.public_cancel_booking((select public_token from booking.orders where id = (select order_id from booking.reservations where product_id = 10 and starts_at = pg_temp.ts(w2, '17:00')))) ->> 'ok' = 'true', 'D4: hoito peruttu (esiehto)');
  r := pg_temp.mk(10, pg_temp.ts(w2, '18:00'), 1, 'd3@t58.example');
  perform pg_temp.ck((r ->> 'ok')::boolean and pg_temp.pav(7, w2, 2) = '16:00,16:30,17:00', 'D5: hoito 18:00–19:00 ei estä (17:00 rituaali päättyy 17:20, puskuri 17:35 < 18:00)');

  -- ===== E: päällekkäinen saunotus Raunissa (w2 su) =====
  r := pg_temp.mk(11, pg_temp.ts(w2 + 1, '14:00'), 1, 'e1@t58.example');
  perform pg_temp.ck((r ->> 'ok')::boolean, 'E1: Saunotus (120 min) su 14:00–16:00 ' || coalesce(r ->> 'code', 'ok'));
  perform pg_temp.ck(pg_temp.pav(7, w2 + 1, 2) = '16:30,17:00', 'E2: saunotus päättyy 16:00 + 15 min puskuri: paketti 16:00 estetty, 16:30 ja 17:00 sallittu (' || pg_temp.pav(7, w2 + 1, 2) || ')');
  r := pg_temp.mk(11, pg_temp.ts(w2 + 1, '15:00'), 1, 'e2@t58.example');
  perform pg_temp.ck(not (r ->> 'ok')::boolean, 'E3: toinen saunotus 15:00 hylätään (Raunin istunto 14–16 + puskuri; Lovi vain kun Rauni suljettu): ' || coalesce(r ->> 'code', 'ok'));
  -- saunotus 15:00-17:00 olisi estänyt kaikki: tarkistus kooltaan pienellä päivällä (w3 su)
  r := pg_temp.mk(11, pg_temp.ts(w3 + 1, '15:00'), 1, 'e3@t58.example');
  perform pg_temp.ck((r ->> 'ok')::boolean and pg_temp.pav(7, w3 + 1, 2) = '', 'E4: saunotus su 15:00–17:00: kaikki paketin alkuajat estetty (17:00 < 17:15) (' || pg_temp.pav(7, w3 + 1, 2) || ')');

  -- ===== F: suljettu päivä / sulut (w3 la) =====
  insert into booking.space_blocks(space_id, starts_at, ends_at, reason) values (12, pg_temp.ts(w3, '00:00'), pg_temp.ts(w3 + 1, '00:00'), 't58 Rauni kiinni koko päivä') returning id into v_blk;
  perform pg_temp.ck(pg_temp.pav(7, w3, 2) = '' and pg_temp.pav(8, w3, 2) = '', 'F1: Rauni suljettu koko päivän => paketti ei varattavissa (eikä rituaali)');
  r := pg_temp.mk(7, pg_temp.ts(w3, '16:00'), 2, 'f1@t58.example');
  perform pg_temp.ck(not (r ->> 'ok')::boolean, 'F2: varaus suljetulle päivälle hylätään: ' || coalesce(r ->> 'code', 'ok'));
  delete from booking.space_blocks where id = v_blk;
  perform pg_temp.ck(pg_temp.pav(7, w3, 2) = '16:00,16:30,17:00', 'F3: sulku poistettu => taas tarjolla');
  insert into booking.space_blocks(space_id, starts_at, ends_at, reason) values (12, pg_temp.ts(w3, '16:00'), pg_temp.ts(w3, '16:10'), 't58 Rauni 16:00–16:10') returning id into v_blk;
  perform pg_temp.ck(pg_temp.pav(7, w3, 2) = '16:30,17:00', 'F4: Rauni suljettu 16:00–16:10 => vain 16:00 estetty');
  delete from booking.space_blocks where id = v_blk;
  insert into booking.space_blocks(space_id, starts_at, ends_at, reason) values (12, pg_temp.ts(w3, '16:20'), pg_temp.ts(w3, '16:25'), 't58 Rauni 16:20–16:25') returning id into v_blk;
  perform pg_temp.ck(pg_temp.pav(7, w3, 2) like '16:00%', 'F5: raja 20 min: Rauni suljettu 16:20– (rituaalin jälkeen) ei estä 16:00-pakettia (' || pg_temp.pav(7, w3, 2) || ')');
  delete from booking.space_blocks where id = v_blk;
  -- savusauna suljettu: vain savusaunaosan aikana
  insert into booking.space_blocks(space_id, starts_at, ends_at, reason) values (1, pg_temp.ts(w3, '16:20'), pg_temp.ts(w3, '16:30'), 't58 savusauna 16:20–16:30 (tauko)') returning id into v_blk;
  perform pg_temp.ck(pg_temp.pav(7, w3, 2) = '16:00,16:30,17:00', 'F6: raja 30 min: savusauna suljettu tauon aikana (16:20–16:30) ei estä (' || pg_temp.pav(7, w3, 2) || ')');
  delete from booking.space_blocks where id = v_blk;
  insert into booking.space_blocks(space_id, starts_at, ends_at, reason) values (1, pg_temp.ts(w3, '16:30'), pg_temp.ts(w3, '16:31'), 't58 savusauna 16:30–16:31') returning id into v_blk;
  perform pg_temp.ck(pg_temp.pav(7, w3, 2) = '16:30,17:00', 'F7: savusauna suljettu 16:30–16:31 => 16:00-paketti estetty (' || pg_temp.pav(7, w3, 2) || ')');
  delete from booking.space_blocks where id = v_blk;
  insert into booking.space_blocks(space_id, starts_at, ends_at, reason) values (1, pg_temp.ts(w3, '18:00'), pg_temp.ts(w3, '18:01'), 't58 savusauna 18:00–18:01') returning id into v_blk;
  perform pg_temp.ck(pg_temp.pav(7, w3, 2) = '16:00', 'F8: raja 120 min: savusauna suljettu 18:00– => 16:00 (loppuu 18:00) sallittu, 16:30 ja 17:00 estetty (' || pg_temp.pav(7, w3, 2) || ')');
  delete from booking.space_blocks where id = v_blk;

  -- ===== G: savusauna varattu yksityisvuorolle (exclusive) (w3 la) =====
  v_cust := booking._upsert_customer('Yksityinen Testi', 'g2@t58.example', '+358401234567', false, 'web_booking', 'fi', 'v1');
  perform booking._create_legs_booking('current', 25, pg_temp.ts(w3, '18:00'), pg_temp.ts(w3, '20:00'), 4, v_cust, 'web', null, null, 250, null, false, null, false, null, null, null);
  perform pg_temp.ck(pg_temp.pav(7, w3, 2) = '16:00', 'G1: yksityisvuoro 18:00–20:00: paketti 16:00 (savusauna 16:30–18:00) sallittu, 16:30 ja 17:00 estetty (' || pg_temp.pav(7, w3, 2) || ')');
  perform booking._create_legs_booking('current', 25, pg_temp.ts(w3 + 1, '16:00'), pg_temp.ts(w3 + 1, '18:00'), 4, v_cust, 'web', null, null, 250, null, false, null, false, null, null, null);
  perform pg_temp.ck(pg_temp.pav(7, w3 + 1, 2) = '', 'G2: yksityisvuoro 16:00–18:00 => paketin kaikki alkuajat estetty (' || pg_temp.pav(7, w3 + 1, 2) || ')');
  r := pg_temp.mk(7, pg_temp.ts(w3 + 1, '16:30'), 2, 'g3@t58.example');
  perform pg_temp.ck(not (r ->> 'ok')::boolean, 'G3: varaus yksityisvuoron päälle hylätään: ' || coalesce(r ->> 'code', 'ok'));

  -- ===== H: ei vuoda / ei riko muita =====
  perform pg_temp.ck(not exists (select 1 from booking.product_config where product_id <> 7 and public_slots and bookable and shop_visible and product_id not in (8, 10, 11, 12)), 'H1: muiden tuotteiden näkyvyys ei muuttunut');

  select count(*) into v_foreign from booking.orders where id > v_maxid and created_at <> now();
  if v_foreign = 0 then perform setval('booking.orders_order_no_seq', v_seq0, true); end if;
  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t58_r where ok), (select count(*) from t58_r where not ok), coalesce((select string_agg(x.n || ': ' || x.label, ' | ' order by x.n) from t58_r x where not x.ok), 'ALL OK');
end $t$;
