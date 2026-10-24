-- t166: saunarituaali yleisen vuoron lisäpalveluna (booking_166, migraatio 20261024202015, väliaikainen versio).
-- A aikasääntö (16.00–18.00 → 15.30, 16.00, 16.30, 17.30, 18.00) ja asetus, B saatavuus (public_ritual_addon), C kapasiteetti (täysi aika piiloon,
-- osittain täysi → max_persons), D ei vapaita aikoja / pois päältä / arkivuoro / ei kelpaa → available=false, E Helsinki vs UTC (aika aina
-- aikavyöhykkeen kanssa), F palvelimen hinta + lukitus (asiakkaan hinta ohitetaan, väärä aika / henkilömäärä / täysi → koko varaus kumoutuu),
-- G public_get_booking (vuoro ensin, ritual_addon, can_change false) + asiakkaan muutos estetty, H peruutus (henkilökunta, asiakkaan pito,
-- vanhentunut pito) + palautussuunnitelma, I siirto (rituaali seuraa; ei mahdu → koko siirto kumoutuu) + henkilömäärä, J alennuskoodin esikatselu,
-- K aikaikkuna-trigger (ilman vanhempaa ennallaan), L migraatio uudelleen + rollback (md5) + migraatio uudelleen.
-- Ajo (psql, paikallinen PG17 tai testikanta; migraatiot ja fixtures/10_test_helpers.sql ajettu):
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=0 -f t166_ritual_addon.sql                       (istunnon TimeZone = UTC, kuten tuotannossa)
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=0 -v tz=Europe/Helsinki -f t166_ritual_addon.sql  (sama Helsingin ajassa; molempien on mentävä läpi)
-- Testipäivät 2027 (la 6.3., la 13.3., la 20.3., la 27.3., ma 8.3.); booking_horizon_days nostetaan vain tämän transaktion sisällä.
-- Kaikki yhdessä transaktiossa; lopussa tahallinen poikkeus "TESTRESULT pass=… fail=…" kumoaa kaiken. Ei tuotantoon.
\if :{?tz}
\else
\set tz UTC
\endif
begin;
set local timezone = :'tz';
set local lock_timeout = '3s';
set local statement_timeout = '180s';
create temp table t166_r(ok boolean, label text);
grant all on t166_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t166_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.as_(p_user uuid, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb; d text;
begin
  perform test.login(p_user);
  begin
    execute p_sql into v;
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(nullif(d, ''), sqlstate), 'msg', sqlerrm);
  end;
  perform test.logout();
  return v;
end $$;
-- julkinen varaus + rituaali (p_addons); palauttaa jsonb
create function pg_temp.book(p_rule bigint, p_date date, p_persons int, p_addons jsonb) returns jsonb language sql as $$
  select booking.public_create_booking(p_rule, p_date, p_persons, 'Testi Asiakas', 'asiakas' || nextval('test.seq') || '@t166.example', '0401234567',
                                       false, 'fi', null, 'private', null, p_addons) $$;
-- aikojen HH:MI-lista Helsingin ajassa
create function pg_temp.labels(p jsonb) returns text language sql as $$
  select coalesce(string_agg(to_char((x ->> 'starts_at')::timestamptz at time zone 'Europe/Helsinki', 'HH24:MI'), ',' order by (x ->> 'starts_at')::timestamptz), '')
    from jsonb_array_elements(coalesce(p -> 'times', '[]'::jsonb)) x $$;
create function pg_temp.maxp(p jsonb, p_hm text) returns int language sql as $$
  select (x ->> 'max_persons')::int from jsonb_array_elements(coalesce(p -> 'times', '[]'::jsonb)) x
   where to_char((x ->> 'starts_at')::timestamptz at time zone 'Europe/Helsinki', 'HH24:MI') = p_hm $$;
create function pg_temp.hel(p_date date, p_hm text) returns timestamptz language sql immutable as $$ select (p_date + p_hm::time) at time zone 'Europe/Helsinki' $$;
-- rituaalin (kb 8) suora henkilökunnan varaus täyttämään poolia (sallittu rituaaliaika 16.00/16.30/17.00)
create function pg_temp.fill(p_start timestamptz, p_persons int) returns bigint language plpgsql as $$
declare v jsonb;
begin
  v := booking._create_legs_booking('current', 8, p_start, null, p_persons, null, 'admin', null, null, null, null, false, null, false, null);
  return (v ->> 'reservation_id')::bigint;
end $$;
grant execute on all functions in schema pg_temp to public;

-- L1: migraatio ajetaan uudelleen heti alussa (uudelleenajettavuus)
\ir ../migrations/20261024202015_booking_166_ritual_addon.sql

update booking.settings set value = '900'::jsonb where key = 'booking_horizon_days';   -- vain tässä transaktiossa (tuotannossa 180)
update booking.settings set value = '"pay_later"'::jsonb where key = 'public_payment_mode';
delete from booking.space_blocks where during && tstzrange('2027-03-01', '2027-04-01');

do $t$
declare
  r16 bigint := test.rule('Yleinen vuoro la–su 16:00%'); r1630 bigint := test.rule('Yleinen vuoro la–su 16:30%'); r14 bigint := test.rule('Tunnin saunavuoro la–su 14:00%');
  rmon bigint := test.rule('Miesten sauna%');
  d1 date := '2027-03-06'; d2 date := '2027-03-13'; d3 date := '2027-03-20'; d4 date := '2027-03-27'; dmon date := '2027-03-08';
  u_adm uuid := test.mk_staff('adm@t166.example', 'admin');
  v jsonb; w jsonb; b jsonb; tok uuid; o booking.orders; pr booking.reservations; ch booking.reservations; it booking.order_items;
  v_sess numeric; v_n int; v_txt text; v_id bigint; v_start timestamptz;
begin
  -- ---------- A aikasääntö ----------
  select string_agg(to_char(t at time zone 'Europe/Helsinki', 'HH24:MI'), ',' order by t) into v_txt
    from booking._ritual_addon_starts(pg_temp.hel(d1, '16:00'), pg_temp.hel(d1, '18:00')) t;
  perform pg_temp.ck(v_txt = '15:30,16:00,16:30,17:30,18:00', 'A1: 16.00–18.00 → 15.30, 16.00, 16.30, 17.30, 18.00 (' || coalesce(v_txt, '') || ')');
  select string_agg(to_char(t at time zone 'Europe/Helsinki', 'HH24:MI'), ',' order by t) into v_txt
    from booking._ritual_addon_starts(pg_temp.hel(d1, '14:00'), pg_temp.hel(d1, '15:00')) t;
  perform pg_temp.ck(v_txt = '13:30,14:00,14:30,15:00', 'A2: 14.00–15.00 → 13.30, 14.00, 14.30, 15.00 (' || coalesce(v_txt, '') || ')');
  select string_agg(to_char(t at time zone 'Europe/Helsinki', 'HH24:MI'), ',' order by t) into v_txt
    from booking._ritual_addon_starts(pg_temp.hel(d1, '17:00'), pg_temp.hel(d1, '20:00')) t;
  perform pg_temp.ck(v_txt = '16:30,17:00,17:30,18:30,19:30,20:00', 'A3: 3 h vuoro tunnin välein (' || coalesce(v_txt, '') || ')');
  -- kesäaika vaihtuu su 28.3.2027: Helsingin kellonajat säilyvät
  select string_agg(to_char(t at time zone 'Europe/Helsinki', 'HH24:MI'), ',' order by t) into v_txt
    from booking._ritual_addon_starts(pg_temp.hel('2027-03-28', '16:00'), pg_temp.hel('2027-03-28', '18:00')) t;
  perform pg_temp.ck(v_txt = '15:30,16:00,16:30,17:30,18:00', 'A4: kesäajan vaihtopäivä (' || coalesce(v_txt, '') || ')');
  perform pg_temp.ck((booking._ritual_addon_cfg() ->> 'product_id')::bigint = 8 and (booking._ritual_addon_cfg() ->> 'enabled')::boolean, 'A5: asetus: tuote 8, päällä');
  update booking.settings set value = value || '{"at_start": false, "before_min": null}'::jsonb where key = 'ritual_addon';
  select string_agg(to_char(t at time zone 'Europe/Helsinki', 'HH24:MI'), ',' order by t) into v_txt
    from booking._ritual_addon_starts(pg_temp.hel(d1, '16:00'), pg_temp.hel(d1, '18:00')) t;
  perform pg_temp.ck(v_txt = '16:30,17:30,18:00', 'A6: asetus muuttaa listaa (' || coalesce(v_txt, '') || ')');
  update booking.settings set value = value || '{"at_start": true, "before_min": 30}'::jsonb where key = 'ritual_addon';
  perform pg_temp.ck(not exists (select 1 from booking._ritual_addon_starts(pg_temp.hel(d1, '16:00'), pg_temp.hel(d1, '16:00'))), 'A7: virheellinen vuoro → ei aikoja');

  -- ---------- B saatavuus ----------
  v := booking.public_ritual_addon(r16, d1, 3);
  perform pg_temp.ck((v ->> 'available')::boolean and pg_temp.labels(v) = '15:30,16:00,16:30,17:30,18:00', 'B1: la 16.00-vuoro: 5 aikaa (' || pg_temp.labels(v) || ')');
  perform pg_temp.ck((v ->> 'product_id')::bigint = 8 and (v ->> 'unit_price')::numeric = 20 and (v ->> 'vat_rate')::numeric = 25.5 and (v -> 'prices' ->> '3')::numeric = 60,
                     'B2: tuote 8, 20 €/hlö, ALV 25,5 %, 3 hlö = 60 €');
  perform pg_temp.ck(pg_temp.maxp(v, '15:30') = 3 and (v ->> 'max_persons')::int = 3, 'B3: max_persons rajattu vuoron henkilömäärään');
  perform pg_temp.ck((select bool_and((x ->> 'ends_at')::timestamptz = (x ->> 'starts_at')::timestamptz + interval '20 minutes') from jsonb_array_elements(v -> 'times') x), 'B4: kesto 20 min');
  perform pg_temp.ck((select string_agg(x ->> 'position', ',' order by (x ->> 'starts_at')::timestamptz) from jsonb_array_elements(v -> 'times') x) = 'before,start,during,during,end', 'B5: positiot');
  update booking.product_config set max_persons = 4 where product_id = 8;
  v := booking.public_ritual_addon(r16, d1, 6);
  perform pg_temp.ck(pg_temp.maxp(v, '16:00') = 4 and (v ->> 'max_persons')::int = 4, 'B6: rituaalin oma enimmäismäärä rajaa (6 hlö vuoro, tuote max 4)');
  update booking.product_config set max_persons = 6 where product_id = 8;
  v := booking.public_ritual_addon(r16, d1, 6);
  perform pg_temp.ck(pg_temp.maxp(v, '16:00') = 6, 'B6b: 6 hlö vuoro → 6');
  perform test.anon();
  v := booking.public_ritual_addon(r14, d1, 2);
  perform test.logout();
  perform pg_temp.ck((v ->> 'available')::boolean and pg_temp.labels(v) = '13:30,14:00,14:30,15:00', 'B7: anon, tunnin vuoro 14.00 (' || pg_temp.labels(v) || ')');

  -- ---------- C kapasiteetti ----------
  perform pg_temp.fill(pg_temp.hel(d2, '16:30'), 6);             -- 16.30 täynnä (pooli 6)
  perform pg_temp.fill(pg_temp.hel(d2, '17:00'), 2);             -- 17.00 2 hlö (ei ole vuoron listalla; Raunin puskuri estää 16.30? ei koske 17.30)
  v := booking.public_ritual_addon(r16, d2, 4);
  perform pg_temp.ck(position('16:30' in pg_temp.labels(v)) = 0, 'C1: täysi aika 16.30 piilossa (' || pg_temp.labels(v) || ')');
  perform pg_temp.ck(position('15:30' in pg_temp.labels(v)) > 0 and position('18:00' in pg_temp.labels(v)) > 0, 'C2: muut ajat näkyvät');
  perform pg_temp.fill(pg_temp.hel(d3, '16:00'), 4);             -- 16.00 4/6
  v := booking.public_ritual_addon(r16, d3, 5);
  perform pg_temp.ck(pg_temp.maxp(v, '16:00') = 2 and pg_temp.maxp(v, '15:30') = 5, 'C3: osittain täysi 16.00 → max 2; 15.30 → 5 (' || coalesce(pg_temp.maxp(v, '16:00'), -1) || ')');

  -- ---------- D ei vapaita aikoja ----------
  insert into booking.space_blocks(space_id, starts_at, ends_at, reason, active)
  values ((select id from booking.resources where code = 'rauni'), pg_temp.hel(d4, '12:00'), pg_temp.hel(d4, '22:00'), 't166 Rauni kiinni', true);
  v := booking.public_ritual_addon(r16, d4, 2);
  perform pg_temp.ck(not (v ->> 'available')::boolean and jsonb_array_length(v -> 'times') = 0 and v ->> 'reason' = 'full', 'D1: Rauni suljettu → available=false (' || coalesce(v ->> 'reason', '') || ')');
  b := pg_temp.book(r16, d4, 2, jsonb_build_array(jsonb_build_object('ritual_start', pg_temp.hel(d4, '16:00'), 'quantity', 2)));
  perform pg_temp.ck(b ->> 'code' = 'ritual_addon_full', 'D2: suljetulle ajalle ei voi varata (' || coalesce(b ->> 'code', 'ok') || ')');
  v := booking.public_ritual_addon(rmon, dmon, 2);
  perform pg_temp.ck(not (v ->> 'available')::boolean, 'D3: arkivuoro (rituaali vain la–su) → ei näy');
  update booking.settings set value = value || '{"enabled": false}'::jsonb where key = 'ritual_addon';
  v := booking.public_ritual_addon(r16, d1, 2);
  perform pg_temp.ck(not (v ->> 'available')::boolean and v ->> 'reason' = 'disabled', 'D4: kytkin pois → ei näy');
  b := pg_temp.book(r16, d1, 2, jsonb_build_array(jsonb_build_object('ritual_start', pg_temp.hel(d1, '16:00'), 'quantity', 1)));
  perform pg_temp.ck(b ->> 'code' = 'ritual_addon_unavailable', 'D5: kytkin pois → varaus hylätään (' || coalesce(b ->> 'code', 'ok') || ')');
  update booking.settings set value = value || '{"enabled": true, "session_product_ids": [6]}'::jsonb where key = 'ritual_addon';
  perform pg_temp.ck(not (booking.public_ritual_addon(r16, d1, 2) ->> 'available')::boolean and (booking.public_ritual_addon(r14, d1, 2) ->> 'available')::boolean,
                     'D6: session_product_ids rajaa vuorot');
  update booking.settings set value = value || '{"session_product_ids": null}'::jsonb where key = 'ritual_addon';
  v := booking.public_ritual_addon(r16, d1 - 1, 2);
  perform pg_temp.ck(not (v ->> 'available')::boolean and v ->> 'reason' = 'no_session', 'D7: päivällä ei vuoroa → ei näy');
  update booking.product_config set public_weekdays = null where product_id = 8;   -- ilman viikonpäivärajaa: savusaunan yleisen vuoron päivä ratkaisee
  perform pg_temp.ck(not booking._ritual_addon_session_ok((select id from booking.schedule_rules where product_id = 7 limit 1))
                     and not booking._ritual_addon_session_ok(r16 * 0 + (select coalesce(max(id), 0) + 1 from booking.schedule_rules)), 'D8: rituaalipaketti / tuntematon sääntö ei kelpaa');
  update booking.product_config set public_weekdays = '{6,7}' where product_id = 8;
  perform pg_temp.ck(booking._ritual_addon_fit(now() + interval '30 minutes', 1, true) is null, 'D9: lead-aika (120 min) estää');

  -- ---------- E + F varaus, hinta ja lukitus ----------
  b := pg_temp.book(r16, d1, 3, jsonb_build_array(jsonb_build_object('ritual_start', to_char(pg_temp.hel(d1, '15:30') at time zone 'Europe/Helsinki', 'YYYY-MM-DD"T"HH24:MI:SS') || '+02:00',
                                                                     'quantity', 2, 'price', 1, 'unit_price', 0)));
  perform pg_temp.ck((b ->> 'ok')::boolean, 'F1: varaus + rituaali 15.30 (Helsingin aika +02:00) ' || coalesce(b ->> 'code', '') || coalesce(b ->> 'message', ''));
  tok := (b ->> 'token')::uuid;
  select * into o from booking.orders where public_token = tok;
  select * into pr from booking.reservations where order_id = o.id and parent_reservation_id is null;
  select * into ch from booking.reservations where order_id = o.id and parent_reservation_id is not null;
  select * into it from booking.order_items where id = ch.order_item_id;
  perform pg_temp.ck(ch.id is not null and ch.product_id = 8 and ch.parent_reservation_id = pr.id and ch.persons = 2 and ch.status = pr.status,
                     'F2: rituaalivaraus kb 8, vanhempi = vuoro, 2 hlö, sama tila');
  perform pg_temp.ck(ch.starts_at = pg_temp.hel(d1, '15:30') and ch.ends_at = pg_temp.hel(d1, '15:50') and test.hel_hm(ch.starts_at) = '15:30', 'E1: 15.30 Helsingin aikaa (' || current_setting('TimeZone') || ')');
  perform pg_temp.ck(it.line_total_gross = 40 and it.vat_rate = 25.5 and it.kind = 'reservation' and (it.price_breakdown ->> 'ritual_addon')::boolean and it.parent_item_id is null,
                     'F3: palvelimen hinta 2 × 20 = 40 € (asiakkaan hinta ohitettu)');
  select line_total_gross into v_sess from booking.order_items where id = pr.order_item_id;
  perform pg_temp.ck(o.total_gross = v_sess + 40 and (b ->> 'total')::numeric = v_sess + 40, 'F4: tilauksen summa = vuoro + rituaali');
  perform pg_temp.ck((select amount from booking.payments where order_id = o.id order by id limit 1) = v_sess + 40, 'F5: maksun summa sisältää rituaalin');
  perform pg_temp.ck(exists (select 1 from booking.reservation_legs l where l.reservation_id = ch.id) or ch.therapist_missing, 'F6: saunottajaleg tai therapist_missing');
  v := booking.public_ritual_addon(r16, d1, 6);
  perform pg_temp.ck(pg_temp.maxp(v, '15:30') = 4, 'F7: varattu rituaali vie poolista (15.30 jäljellä 4, ' || coalesce(pg_temp.maxp(v, '15:30'), -1) || ')');
  -- virheet: koko varaus kumoutuu
  select count(*) into v_n from booking.reservations;
  b := pg_temp.book(r16, d1, 2, jsonb_build_array(jsonb_build_object('ritual_start', pg_temp.hel(d1, '16:15'), 'quantity', 1)));
  perform pg_temp.ck(b ->> 'code' = 'ritual_addon_time', 'F8: listan ulkopuolinen aika hylätään (' || coalesce(b ->> 'code', 'ok') || ')');
  b := pg_temp.book(r16, d1, 2, jsonb_build_array(jsonb_build_object('ritual_start', '2027-03-06T15:30:00', 'quantity', 1)));
  perform pg_temp.ck(b ->> 'code' = 'ritual_addon_time', 'E2: aika ilman aikavyöhykettä hylätään (' || coalesce(b ->> 'code', 'ok') || ')');
  b := pg_temp.book(r16, d1, 2, jsonb_build_array(jsonb_build_object('ritual_start', pg_temp.hel(d1, '16:00'), 'quantity', 3)));
  perform pg_temp.ck(b ->> 'code' = 'ritual_addon_persons', 'F9: rituaaliin enemmän kuin vuoroon hylätään (' || coalesce(b ->> 'code', 'ok') || ')');
  b := pg_temp.book(r16, d1, 2, jsonb_build_array(jsonb_build_object('ritual_start', pg_temp.hel(d1, '16:00'), 'quantity', 1), jsonb_build_object('ritual_start', pg_temp.hel(d1, '16:30'), 'quantity', 1)));
  perform pg_temp.ck(b ->> 'code' = 'ritual_addon_invalid', 'F10: kaksi rituaalia hylätään');
  b := pg_temp.book(r16, d2, 5, jsonb_build_array(jsonb_build_object('ritual_start', pg_temp.hel(d2, '16:30'), 'quantity', 1)));
  perform pg_temp.ck(b ->> 'code' = 'ritual_addon_full', 'F11: täysi aika hylätään (' || coalesce(b ->> 'code', 'ok') || ')');
  perform pg_temp.ck((select count(*) from booking.reservations) = v_n, 'F12: hylätyt eivät jättäneet varauksia (vuoro kumoutui)');
  b := pg_temp.book(rmon, dmon, 2, jsonb_build_array(jsonb_build_object('ritual_start', pg_temp.hel(dmon, '16:00'), 'quantity', 1)));
  perform pg_temp.ck(b ->> 'code' = 'ritual_addon_full', 'F13: arkivuoroon ei voi lisätä (' || coalesce(b ->> 'code', 'ok') || ')');
  b := pg_temp.book(r16, d1, 2, '[{"id": 999999, "quantity": 1}]'::jsonb);
  perform pg_temp.ck(b ->> 'code' = 'addon_not_found', 'F14: tavalliset lisäpalvelut ennallaan');

  -- ---------- G public_get_booking + asiakkaan muutos ----------
  v := booking.public_get_booking(tok);
  perform pg_temp.ck(jsonb_array_length(v -> 'items') = 2 and not (v -> 'items' -> 0 ->> 'ritual_addon')::boolean and (v -> 'items' -> 1 ->> 'ritual_addon')::boolean
                     and (v -> 'items' -> 0 ->> 'product_id')::bigint = pr.product_id, 'G1: items[0] = vuoro, items[1] = rituaali (vaikka rituaali alkaa ensin)');
  perform pg_temp.ck((v ->> 'has_ritual_addon')::boolean and not (v ->> 'can_change')::boolean, 'G2: has_ritual_addon, can_change = false');
  v := booking.public_change_booking(tok, r1630, d1, 3);
  perform pg_temp.ck(v ->> 'code' = 'not_changeable', 'G3: asiakkaan verkkomuutos estetty (' || coalesce(v ->> 'code', 'ok') || ')');

  -- ---------- I siirto (henkilökunta) ----------
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, %s, %L, null)', pr.id, r1630, d1));
  select * into ch from booking.reservations where id = ch.id;
  perform pg_temp.ck(coalesce(v ->> 'err', '') = '' and test.hel_hm(ch.starts_at) = '16:00' and test.hel_hm(ch.ends_at) = '16:20' and ch.status = 'confirmed',
                     'I1: vuoro 16.00 → 16.30, rituaali 15.30 → 16.00 ' || coalesce(v ->> 'msg', ''));
  perform pg_temp.ck(not exists (select 1 from booking.reservation_legs l where l.reservation_id = ch.id and l.starts_at < ch.starts_at), 'I2: rituaalin legit siirtyivät');
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, %s)', pr.id, 4));
  select * into ch from booking.reservations where id = ch.id;
  perform pg_temp.ck(coalesce(v ->> 'err', '') = '' and ch.persons = 2 and test.hel_hm(ch.starts_at) = '16:00', 'I3: henkilömäärän muutos ei muuta rituaalia ' || coalesce(v ->> 'msg', ''));
  -- siirto aikaan, jossa rituaali ei mahdu → koko siirto kumoutuu
  perform pg_temp.fill(pg_temp.hel(d3, '16:30'), 6);
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, %s, %L, null)', pr.id, r1630, d3));   -- rituaali 16.00 → la 20.3. 16.00 (4/6 täynnä, 2 hlö mahtuu)
  select * into ch from booking.reservations where id = ch.id;
  perform pg_temp.ck(coalesce(v ->> 'err', '') = '' and test.hel_date(ch.starts_at) = d3 and test.hel_hm(ch.starts_at) = '16:00', 'I4: siirto toiselle päivälle, rituaali mukana ' || coalesce(v ->> 'msg', ''));
  perform pg_temp.fill(pg_temp.hel(d2, '16:00'), 5);
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, %s, %L, null)', pr.id, r1630, d2));   -- la 13.3. 16.00: 5/6 → 2 hlö ei mahdu
  select * into ch from booking.reservations where id = ch.id;
  select * into pr from booking.reservations where id = pr.id;
  perform pg_temp.ck(v ->> 'err' = 'ritual_addon_move' and test.hel_date(pr.starts_at) = d3 and test.hel_date(ch.starts_at) = d3,
                     'I5: rituaali ei mahdu → koko siirto kumoutui (' || coalesce(v ->> 'err', 'ok') || ')');

  -- ---------- H peruutus ----------
  v := booking._reservation_refund_plan(pr.id);
  perform pg_temp.ck(v is not null, 'H0: palautussuunnitelma');
  v := pg_temp.as_(u_adm, format('select booking.admin_record_payment(%s, %L, %s, null, null)', o.id, 'card_terminal', (select total_gross from booking.orders where id = o.id)));
  perform pg_temp.ck(coalesce(v ->> 'err', '') = '', 'H1: maksu kirjattu ' || coalesce(v ->> 'msg', ''));
  v := booking._reservation_refund_plan(pr.id);
  perform pg_temp.ck((v ->> 'total')::numeric = (select total_gross from booking.orders where id = o.id), 'H2: vuoron palautus sisältää rituaalin (' || coalesce(v ->> 'total', '') || ')');
  perform pg_temp.ck((booking._reservation_refund_plan(ch.id) ->> 'total')::numeric = 40, 'H3: rituaalin oma palautus = 40 €');
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_reservation(%s, %L, true, null)', pr.id, 't166'));
  select * into ch from booking.reservations where id = ch.id;
  perform pg_temp.ck(coalesce(v ->> 'err', '') = '' and ch.status = 'cancelled' and ch.cancel_reason = 'ritual_addon_parent_cancelled', 'H4: vuoron peruutus perui rituaalin ' || coalesce(v ->> 'msg', ''));
  perform pg_temp.ck((v ->> 'refunded_total')::numeric = (select total_gross from booking.orders where id = o.id), 'H5: palautettiin myös rituaali (' || coalesce(v ->> 'refunded_total', '') || ')');
  perform pg_temp.ck(not exists (select 1 from booking.reservation_legs l join booking.reservations r on r.id = l.reservation_id where r.id = ch.id and booking._res_active(r.status, r.hold_expires_at)),
                     'H6: rituaali ei enää varaa resursseja');

  -- vain rituaalin peruutus: vuoro jää
  b := pg_temp.book(r16, d1, 2, jsonb_build_array(jsonb_build_object('ritual_start', pg_temp.hel(d1, '18:00'), 'quantity', 2)));
  select * into o from booking.orders where public_token = (b ->> 'token')::uuid;
  select * into ch from booking.reservations where order_id = o.id and parent_reservation_id is not null;
  v := pg_temp.as_(u_adm, format('select booking.admin_set_reservation_status(%s, %L, %L)', ch.id, 'cancelled', 't166 vain rituaali'));
  perform pg_temp.ck((select status from booking.reservations where order_id = o.id and parent_reservation_id is null) = 'confirmed'
                     and (select status from booking.orders where id = o.id) = 'confirmed', 'H7: rituaalin oma peruutus ei peru vuoroa');

  -- asiakkaan pito (hold_until_paid): rituaali odottaa samaa pitoa; asiakas perii → molemmat; pito vanhenee → molemmat
  update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode';
  update booking.integration_config set mode = 'test', settings = settings || '{"approved_by":"testi"}'::jsonb where key = 'mobilepay';
  b := pg_temp.book(r16, d1, 2, jsonb_build_array(jsonb_build_object('ritual_start', pg_temp.hel(d1, '17:30'), 'quantity', 1)));
  select * into o from booking.orders where public_token = (b ->> 'token')::uuid;
  select * into pr from booking.reservations where order_id = o.id and parent_reservation_id is null;
  select * into ch from booking.reservations where order_id = o.id and parent_reservation_id is not null;
  perform pg_temp.ck((b ->> 'ok')::boolean and pr.status = 'pending' and ch.status = 'pending' and ch.hold_expires_at = pr.hold_expires_at, 'H8: pito: rituaali pending samalla pidolla ' || coalesce(b ->> 'code', ''));
  v := booking.public_cancel_booking((b ->> 'token')::uuid);
  perform pg_temp.ck((v ->> 'ok')::boolean and (select count(*) from booking.reservations where order_id = o.id and status = 'cancelled') = 2, 'H9: asiakkaan peruutus perui molemmat');
  b := pg_temp.book(r16, d1, 2, jsonb_build_array(jsonb_build_object('ritual_start', pg_temp.hel(d1, '17:30'), 'quantity', 1)));
  select * into o from booking.orders where public_token = (b ->> 'token')::uuid;
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = o.id;
  perform booking.expire_holds();
  perform pg_temp.ck((select count(*) from booking.reservations where order_id = o.id and status in ('pending', 'confirmed')) = 0, 'H10: pidon vanheneminen vapautti molemmat');
  b := pg_temp.book(r16, d1, 2, jsonb_build_array(jsonb_build_object('ritual_start', pg_temp.hel(d1, '17:30'), 'quantity', 1)));
  select * into o from booking.orders where public_token = (b ->> 'token')::uuid;
  select * into pr from booking.reservations where order_id = o.id and parent_reservation_id is null;
  update booking.reservations set status = 'confirmed', hold_expires_at = null where id = pr.id;
  perform pg_temp.ck((select status from booking.reservations where order_id = o.id and parent_reservation_id = pr.id) = 'confirmed', 'H11: vuoron vahvistus vahvistaa rituaalin');
  update booking.settings set value = '"pay_later"'::jsonb where key = 'public_payment_mode';

  -- ---------- J alennuskoodin esikatselu ----------
  insert into booking.discount_codes(code, kind, value, active) values ('T166PROS', 'percent', 10, true);
  v := booking.public_preview_code('T166PROS', r16, d1, 2, null);
  w := booking.public_preview_code('T166PROS', r16, d1, 2, jsonb_build_array(jsonb_build_object('ritual_start', pg_temp.hel(d1, '16:00'), 'quantity', 2)));
  perform pg_temp.ck((w ->> 'subtotal')::numeric = (v ->> 'subtotal')::numeric + 40, 'J1: esikatselu sisältää rituaalirivin (' || coalesce(w ->> 'subtotal', w::text) || ')');
  b := booking.public_create_booking_code(r16, d1, 2, 'Testi', 'koodi@t166.example', '0401234567', false, 'fi', null, 'private', null,
                                          jsonb_build_array(jsonb_build_object('ritual_start', pg_temp.hel(d1, '16:00'), 'quantity', 2)), 'T166PROS');
  perform pg_temp.ck((b ->> 'ok')::boolean and (b ->> 'total')::numeric = (w ->> 'total')::numeric, 'J2: koodivaraus: summa = esikatselu (' || coalesce(b ->> 'total', b::text) || ' / ' || coalesce(w ->> 'total', '') || ')');

  -- ---------- K aikaikkuna-trigger ----------
  perform pg_temp.ck(test.code(format('select pg_temp.fill(%L::timestamptz, 1)', pg_temp.hel(d3, '15:30'))) = 'ritual_start', 'K1: rituaali 15.30 ilman vuoroa: allowed_starts ennallaan');
  perform pg_temp.ck(test.code(format('select booking.public_ritual_addon(%s, %L, 2)', r16, d1)) = 'ok', 'K2: public_ritual_addon ei kaadu');
end $t$;

-- ---------- L rollback (md5) + migraatio uudelleen ----------
\ir ../rollbacks/20261024202015_booking_166_ROLLBACK.sql
select pg_temp.ck((select string_agg(md5(pg_get_functiondef(x::regprocedure)), ',' order by x) from unnest(array[
  'booking._attach_addons(bigint,jsonb)', 'booking._reservation_refund_plan(bigint)', 'booking.public_get_booking(uuid)',
  'booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)', 'booking.reservations_time_window()']) x)
  = '6a780e8e00229ff273a321591f197541,cb44c682ac0095617fe20b297b0cdac3,a155cd472c356c09e595cbda46b4dada,fec859d04960f42d79412bbdf7dc6561,023b689b0366602ab32738b7821dcc16',
  'L2: rollback palautti tuotannon md5:t');
select pg_temp.ck(to_regprocedure('booking.public_ritual_addon(bigint,date,integer)') is null and not exists (select 1 from booking.settings where key = 'ritual_addon')
                  and not exists (select 1 from pg_trigger where tgname = 'reservations_ritual_addon_parent'), 'L3: rollback poisti uudet');
\ir ../rollbacks/20261024202015_booking_166_ROLLBACK.sql
\ir ../migrations/20261024202015_booking_166_ritual_addon.sql
select pg_temp.ck(to_regprocedure('booking.public_ritual_addon(bigint,date,integer)') is not null and has_function_privilege('anon', 'booking.public_ritual_addon(bigint,date,integer)', 'execute')
                  and not has_function_privilege('anon', 'booking._ritual_addon_attach(bigint,jsonb)', 'execute'), 'L4: migraatio uudelleen + oikeudet');

select label from t166_r where not ok;
do $$ declare p int; f int; begin
  select count(*) filter (where ok), count(*) filter (where not ok) into p, f from t166_r;
  raise exception 'TESTRESULT pass=% fail=%', p, f;
end $$;
