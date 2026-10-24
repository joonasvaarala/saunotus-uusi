-- t158: tapahtumat ja koulutukset (booking_158, migraatio 20261024300000, väliaikainen versio).
-- A skeema ja oikeudet, B myyntikytkin (oletus pois), C oikeudet (catalog.edit / henkilökunta luku), D kerran luonti ja pooli,
-- E resurssivaraukset materialisoituvat heti ilman lippuja (ei sulkukalenterin outbox-rivejä), F blokit estävät yleisen vuoron, yksityisvuoron ja Raunin,
-- G myynti kiinni, H myynti auki: oma lippu, kapasiteetti, jono, has_reservations, I ristiriidat (conflict + details), J suojaus (event_managed),
-- K kopiot, L koulutus ei kaupassa mutta varaa resurssit, M poisto, N Lovi-sääntö, O migraation uudelleenajo, P rollback (md5) + uudelleenajo.
-- Ajo (psql, paikallinen PG17 tai testikanta, migraatiot ja fixtures/10_test_helpers.sql ajettu):
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=0 -f t158_events.sql
-- Kaikki yhdessä transaktiossa; lopussa tahallinen poikkeus "TESTRESULT pass=… fail=…" kumoaa kaiken (myös rollbackin). Ei tuotantoon.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '180s';
create temp table t158_r(ok boolean, label text);
grant all on t158_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t158_r values (coalesce(p_ok, false), p_label) $$;
-- virheen DETAIL (koodi) ja HINT (details) talteen
create function pg_temp.err(p_sql text) returns jsonb language plpgsql as $$
declare d text; h text;
begin
  execute p_sql;
  return jsonb_build_object('code', 'ok');
exception when others then
  get stacked diagnostics d = pg_exception_detail, h = pg_exception_hint;
  return jsonb_build_object('code', coalesce(nullif(d, ''), sqlstate), 'hint', h);
end $$;
-- public_create_booking palauttaa {ok:false, code} virheissä
create function pg_temp.pb(p_rule bigint, p_date date, p_persons int, p_email text default null) returns text language plpgsql as $$
declare r jsonb;
begin
  r := test.pub_book(p_rule, p_date, p_persons, p_email);
  return coalesce(r ->> 'code', case when (r ->> 'ok')::boolean then 'ok' end, r::text);
exception when others then
  return 'exception: ' || sqlerrm;
end $$;
grant execute on all functions in schema pg_temp to public;

-- O: migraatio ajetaan uudelleen heti alussa (uudelleenajettavuus)
create temp table t158_before as select
  (select count(*) from booking.m158_lovi_rows) n_lovi,
  (select count(*) from booking.settings where key = 'events.sale_enabled') n_set,
  (select count(*) from pg_constraint where conrelid = 'booking.schedule_rules'::regclass and conname like 'schedule_rules_%kind%') n_con;
\ir ../migrations/20261024300000_booking_158_events.sql

do $t$
declare
  u_mgr uuid := test.mk_staff('t158-mgr@example.test', 'manager');
  u_staff uuid := test.mk_staff('t158-staff@example.test', 'staff');
  d date := test.next_dow(1, 10);           -- maanantai (Miesten sauna ma 16–19 savusaunassa)
  d2 date := test.next_dow(1, 10) + 7;
  v_savu bigint := (select id from booking.resources where code = 'savusauna');
  v_rauni bigint := (select id from booking.resources where code = 'rauni');
  v_person bigint := (select id from booking.resources where code = 'saunottaja');
  v_shift bigint := test.rule('Miesten sauna ma%');
  v_private bigint := test.rule('Oma savusaunavuoro ma–pe 16–19%');
  res jsonb; e jsonb; v_rule bigint; v_rule2 bigint; v_rule3 bigint; v_pool bigint; v_n int; v_n2 int; v_outbox int; v_tok uuid;
  v_t1 timestamptz; v_t2 timestamptz; v_copy bigint; v_slug text;
begin
  -- A: skeema ja oikeudet
  perform pg_temp.ck((select count(*) from information_schema.columns where table_schema = 'booking' and table_name = 'schedule_rules' and column_name = 'kind' and is_nullable = 'NO') = 1, 'A1: schedule_rules.kind not null');
  perform pg_temp.ck((select relrowsecurity from pg_class where oid = 'booking.event_resource_blocks'::regclass), 'A2: event_resource_blocks RLS päällä');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_event_rule_upsert(bigint, bigint, jsonb)', 'execute')
                     and not has_function_privilege('anon', 'booking.admin_product_copy(bigint)', 'execute')
                     and has_function_privilege('authenticated', 'booking.admin_event_blocks_set(bigint, jsonb)', 'execute'), 'A3: admin-RPC:t vain authenticated (ei anon)');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_events(date, text)', 'execute'), 'A4: public_events anonille');
  perform pg_temp.ck(not has_function_privilege('authenticated', 'booking._event_sync_blocks(bigint)', 'execute')
                     and not has_function_privilege('anon', 'booking._product_copy_core(bigint)', 'execute')
                     and not has_function_privilege('authenticated', 'booking._event_block_is_own(bigint, bigint, bigint[])', 'execute'), 'A5: apufunktiot eivät anonille/authenticatedille');
  perform pg_temp.ck((select prosecdef from pg_proc where oid = 'booking.admin_event_rule_upsert(bigint, bigint, jsonb)'::regprocedure)
                     and (select array_to_string(proconfig, ',') = 'search_path=""' from pg_proc where oid = 'booking.public_events(date, text)'::regprocedure), 'A6: security definer + search_path tyhjä');
  perform pg_temp.ck((select count(*) from t158_before where n_set = 1 and n_con = 1) = 1, 'O1: settings- ja rajoiterivit tasan kerran uudelleenajon jälkeen');

  -- B: myyntikytkin
  perform pg_temp.ck((select value = 'false'::jsonb from booking.settings where key = 'events.sale_enabled') and not booking._events_sale_enabled(), 'B1: events.sale_enabled = false oletuksena');

  -- C: oikeudet
  perform test.login(u_staff);
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_upsert(null, 33, '{"date":"%s","start_time":"17:00"}'::jsonb)$q$, d)) = 'forbidden', 'C1: staff ei luo kertaa (catalog.edit)');
  perform pg_temp.ck(test.code($q$select booking.admin_product_copy(33)$q$) = 'forbidden', 'C2: staff ei kopioi tuotetta');
  res := booking.admin_event_list(null, false);
  perform test.logout();
  perform pg_temp.ck(jsonb_array_length(res) >= 7 and (select bool_and(x ->> 'category' in ('event', 'training')) from jsonb_array_elements(res) x), 'C3: admin_event_list henkilökunnalle (event + training)');
  perform pg_temp.ck((select x -> 'channels' = '["widget"]'::jsonb from jsonb_array_elements(res) x where (x ->> 'product_id')::int = 36)
                     and (select x -> 'channels' = '["shop"]'::jsonb from jsonb_array_elements(res) x where (x ->> 'product_id')::int = 33), 'C4: kanavat oletuksena (training widget, event shop)');
  perform test.anon();
  perform pg_temp.ck(test.code($q$select booking.admin_event_list(null, false)$q$) <> 'ok', 'C5: anon ei saa admin_event_list');
  perform test.logout();

  -- D: kerran luonti
  update booking.product_config set bookable = true, shop_visible = true, lifecycle = 'current' where product_id in (33, 34);
  perform test.login(u_mgr);
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_upsert(null, 2, '{"date":"%s","start_time":"17:00"}'::jsonb)$q$, d)) = 'not_event', 'D1: tavallinen tuote ei käy');
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_upsert(null, 33, '{"date":"%s","start_time":"17:00","duration_minutes":2000}'::jsonb)$q$, d)) = 'multi_day_training_only', 'D2: monipäiväinen vain koulutukselle');
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_upsert(null, 33, '{"date":"%s","start_time":"17:00","foo":1}'::jsonb)$q$, d)) = 'unknown_field', 'D3: tuntematon kenttä');
  res := booking.admin_event_rule_upsert(null, 33, jsonb_build_object('date', d, 'start_time', '17:00', 'duration_minutes', 180, 'max_persons', 6, 'label_en', 'Kekri evening'));
  perform test.logout();
  v_rule := (res ->> 'id')::bigint;
  perform pg_temp.ck(res ->> 'date' = d::text and res ->> 'start_time' = '17:00' and (res ->> 'max_persons')::int = 6 and (res ->> 'sold_persons')::int = 0
                     and res ->> 'label' = to_char(d, 'DD.MM.YYYY') || ' klo 17.00' and res -> 'blocks' = '[]'::jsonb, 'D4: ruleObj (päivä, aika, oletusnimi, ei blokkeja)');
  perform pg_temp.ck(test.hel_hm((res ->> 'starts_at')::timestamptz) = '17:00' and test.hel_hm((res ->> 'ends_at')::timestamptz) = '20:00', 'D5: starts_at/ends_at laskettu');
  select id, capacity into v_pool, v_n from booking.resources where code = 'event_rule_' || v_rule;
  perform pg_temp.ck(v_n = 6 and exists (select 1 from booking.schedule_rule_pools where rule_id = v_rule and pool_id = v_pool), 'D6: kerran oma pooli (kapasiteetti 6)');
  perform pg_temp.ck((select kind = 'event' and mode = 'shared' and valid_from = d and valid_to = d and weekdays = array[1::smallint]
                       and space_id = (select id from booking.resources where code = 'ei_resurssia') from booking.schedule_rules where id = v_rule), 'D7: kind event, yksi päivä, ei_resurssia');
  perform pg_temp.ck(exists (select 1 from booking.site_texts where source_table = 'booking.schedule_rules' and source_pk = v_rule::text), 'D8: kerran nimi tekstijärjestelmään');

  -- E: resurssivaraukset materialisoituvat heti (ei lippuja)
  select count(*) into v_outbox from booking.closure_outbox;
  perform test.login(u_mgr);
  res := booking.admin_event_blocks_set(v_rule, jsonb_build_array(
    jsonb_build_object('resource_id', v_savu, 'mode', 'exclusive', 'starts_at', '16:30', 'ends_at', '20:30', 'note', 'lämmitys'),
    jsonb_build_object('resource_id', v_rauni, 'mode', 'exclusive', 'offset_min', -30, 'minutes', 240),
    jsonb_build_object('resource_id', v_person, 'mode', 'exclusive', 'offset_min', 0, 'minutes', 180)));
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_blocks_set(%s, '[{"resource_id":%s,"offset_min":0,"minutes":60}]'::jsonb)$q$, v_rule, v_pool)) = 'invalid_resource', 'E1: kapasiteettipoolia ei voi valita');
  perform test.logout();
  perform pg_temp.ck(jsonb_array_length(res) = 3 and (select count(*) from jsonb_array_elements(res) x where (x ->> 'materialized')::boolean) = 2, 'E2: 3 varausta, 2 materialisoituu (tilat), henkilö ei');
  perform pg_temp.ck((select test.hel_hm((x ->> 'starts_at')::timestamptz) || '-' || test.hel_hm((x ->> 'ends_at')::timestamptz) from jsonb_array_elements(res) x where (x ->> 'resource_id')::bigint = v_savu) = '16:30-20:30'
                     and (select test.hel_hm((x ->> 'starts_at')::timestamptz) || '-' || test.hel_hm((x ->> 'ends_at')::timestamptz) from jsonb_array_elements(res) x where (x ->> 'resource_id')::bigint = v_rauni) = '16:30-20:30', 'E3: kellonaika- ja suhteellinen ajoitus');
  perform pg_temp.ck((select count(*) from booking.space_blocks b join booking.event_resource_blocks e on e.id = b.event_block_id where e.rule_id = v_rule and b.active and b.reason like 'Tapahtuma: Sipoonjoen Kekri%') = 2, 'E4: space_blocks-rivit heti ilman lippuja');
  perform pg_temp.ck((select count(*) from booking.closure_outbox) = v_outbox, 'E5: ei closure_outbox-rivejä');
  perform test.service();
  perform booking.closure_outbox_backfill();
  perform test.logout();
  perform pg_temp.ck((select count(*) from booking.closure_outbox o join booking.space_blocks b on b.id = o.block_id where b.event_block_id is not null) = 0, 'E6: backfill ei vie tapahtumablokkeja kalenteriin');

  -- F: blokit estävät
  perform pg_temp.ck((select status from booking.public_availability(2, d, d) where rule_id = v_shift) = 'unavailable', 'F1: yleinen vuoro samaan aikaan ei varattavissa');
  perform test.anon('10.158.0.1');
  perform pg_temp.ck(pg_temp.pb(v_shift, d, 1) = 'space_closed', 'F2: yleisen vuoron lippu hylätään (space_closed)');
  perform test.logout();
  v_t1 := (d + time '17:00') at time zone 'Europe/Helsinki'; v_t2 := (d + time '18:00') at time zone 'Europe/Helsinki';
  perform pg_temp.ck(test.code(format($q$select booking._check_claim(null, null, %s, 'space', 'exclusive', %L, %L, 1, null, null, null, false, false, 'blocks')$q$, v_savu, v_t1, v_t2)) = 'space_closed', 'F3: yksityisvuoro (exclusive savusauna) estyy');
  perform pg_temp.ck(test.code(format($q$select booking._check_claim(null, null, %s, 'space', 'exclusive', %L, %L, 1, null, null, null, false, false, 'blocks')$q$, v_rauni, v_t1, v_t2)) = 'space_closed', 'F4: Rauni (hoidot) estyy');
  perform pg_temp.ck(test.code(format($q$select booking._check_claim(null, null, %s, 'space', 'shared', %L, %L, 1, array[%s]::bigint[], null, null, false, false, 'blocks')$q$, v_savu, v_t1, v_t2, v_pool)) = 'ok', 'F5: oma lippu (oma pooli) ohittaa oman kerran blokin');
  perform pg_temp.ck((select status from booking.public_availability(25, d, d) where rule_id = v_private) is distinct from 'available', 'F6: yksityisvuoro ei näy vapaana');

  -- G: myynti kiinni
  perform pg_temp.ck(not exists (select 1 from booking.public_availability(33, d, d)), 'G1: kerta ei näy saatavuudessa');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(booking.public_catalog()) x where (x ->> 'id')::int = 33), 'G2: tapahtuma ei näy katalogissa');
  perform test.anon('10.158.0.2');
  perform pg_temp.ck(pg_temp.pb(v_rule, d, 1) = 'sale_closed', 'G3: asiakkaan varaus hylätään (sale_closed)');
  res := booking.public_events(null, 'shop');
  perform test.logout();
  e := (select x from jsonb_array_elements(res) x where (x ->> 'product_id')::int = 33);
  perform pg_temp.ck(e is not null and e -> 'occurrences' -> 0 ->> 'status' = 'closed' and e -> 'occurrences' -> 0 -> 'remaining' = 'null'::jsonb
                     and (e ->> 'sale_open')::boolean = false, 'G4: public_events: kerta näkyy suljettuna');
  perform pg_temp.ck(e -> 'occurrences' -> 0 ->> 'time_text' = 'ma ' || to_char(d, 'FMDD.FMMM.') || ' klo 17.00–20.00'
                     and e -> 'occurrences' -> 0 ->> 'time_text_en' = to_char(d, 'Dy FMDD Mon') || ' 17:00–20:00' and e ->> 'slug' = 'sipoonjoen-kekri', 'G5: time_text fi/en ja slug');

  -- H: myynti auki
  update booking.settings set value = 'true'::jsonb where key = 'events.sale_enabled';
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(booking.public_catalog()) x where (x ->> 'id')::int = 33), 'H1: tapahtuma näkyy katalogissa');
  perform pg_temp.ck((select status = 'available' and remaining = 6 from booking.public_availability(33, d, d) where rule_id = v_rule), 'H2: kerta varattavissa, 6 paikkaa');
  perform test.anon('10.158.0.3');
  res := test.pub_book(v_rule, d, 2, 't158-a@example.com');
  perform test.logout();
  v_tok := (res ->> 'token')::uuid;
  perform pg_temp.ck(v_tok is not null and (test.res(v_tok)).rule_id = v_rule and (test.res(v_tok)).persons = 2, 'H3: oma lippu varattu (blokit eivät estä)');
  perform test.reset_rl();
  perform test.anon('10.158.0.4');
  perform pg_temp.ck(pg_temp.pb(v_rule, d, 4) = 'ok', 'H4: 4 lisää (yhteensä 6)');
  perform pg_temp.ck(pg_temp.pb(v_rule, d, 1) in ('capacity_exceeded', 'session_full', 'full'), 'H5: 7. paikka hylätään');
  perform pg_temp.ck(test.code(format($q$select booking.public_join_waitlist(%s, %L, 1, 'Jono Testi', 't158-w@example.com', '0401234567', 'fi', false)$q$, v_rule, d)) = 'ok', 'H6: jonoon täydelle kerralle');
  res := booking.public_events(null, 'shop');
  perform test.logout();
  e := (select x -> 'occurrences' -> 0 from jsonb_array_elements(res) x where (x ->> 'product_id')::int = 33);
  perform pg_temp.ck(e ->> 'status' = 'full' and (e ->> 'remaining')::int = 0, 'H7: public_events full, remaining 0');
  perform pg_temp.ck(not exists (select 1 from booking._block_conflict_pairs() c join booking.reservations r on r.id = c.reservation_id where r.rule_id = v_rule), 'H8: omat liput eivät ole sulkuristiriitoja');
  res := booking._event_rule_json(v_rule);
  perform test.login(u_mgr);
  perform pg_temp.ck((res ->> 'sold_persons')::int = 6 and (res ->> 'waitlist_count')::int = 1, 'H9: sold_persons 6, waitlist_count 1');
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_upsert(%s, null, '{"max_persons":5}'::jsonb)$q$, v_rule)) = 'max_below_sold', 'H10: max alle myytyjen hylätään');
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_upsert(%s, null, '{"start_time":"18:00"}'::jsonb)$q$, v_rule)) = 'has_reservations', 'H11: myydyn kerran aikaa ei siirretä');
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_delete(%s)$q$, v_rule)) = 'has_reservations', 'H12: myytyä kertaa ei poisteta');
  res := booking.admin_event_rule_upsert(v_rule, null, '{"max_persons":8}'::jsonb);
  perform pg_temp.ck((res ->> 'max_persons')::int = 8 and (select capacity from booking.resources where id = v_pool) = 8, 'H13: max nostettu, pooli päivittyy');
  perform test.logout();

  -- I: ristiriidat
  perform test.login(u_mgr);
  res := booking.admin_event_rule_upsert(null, 34, jsonb_build_object('date', d, 'start_time', '19:00', 'duration_minutes', 120, 'max_persons', 8));
  v_rule2 := (res ->> 'id')::bigint;
  e := pg_temp.err(format($q$select booking.admin_event_blocks_set(%s, '[{"resource_id":%s,"mode":"exclusive","offset_min":0,"minutes":120}]'::jsonb)$q$, v_rule2, v_rauni));
  perform pg_temp.ck(e ->> 'code' = 'conflict' and (e ->> 'hint')::jsonb -> 0 ->> 'reason' = 'event_block' and ((e ->> 'hint')::jsonb -> 0 ->> 'resource_id')::bigint = v_rauni, 'I1: päällekkäinen tapahtumablokki -> conflict (event_block)');
  perform pg_temp.ck(not exists (select 1 from booking.event_resource_blocks where rule_id = v_rule2), 'I2: hylätty blokkimuutos ei jäänyt voimaan');
  perform test.logout();
  perform test.reset_rl();
  perform test.anon('10.158.0.5');
  perform pg_temp.ck(pg_temp.pb(v_shift, d2, 2) = 'ok', 'I3: yleisen vuoron lippu d2');
  perform test.logout();
  perform test.login(u_mgr);
  res := booking.admin_event_rule_upsert(null, 34, jsonb_build_object('date', d2, 'start_time', '17:00', 'duration_minutes', 120, 'max_persons', 8));
  v_rule3 := (res ->> 'id')::bigint;
  e := pg_temp.err(format($q$select booking.admin_event_blocks_set(%s, '[{"resource_id":%s,"starts_at":"16:00","ends_at":"19:00"}]'::jsonb)$q$, v_rule3, v_savu));
  perform pg_temp.ck(e ->> 'code' = 'conflict' and (e ->> 'hint')::jsonb -> 0 ->> 'reason' = 'reservation' and (e ->> 'hint')::jsonb -> 0 ? 'starts_at', 'I4: myyty yleinen vuoro -> conflict (reservation, details)');
  res := booking.admin_event_blocks_set(v_rule3, jsonb_build_array(jsonb_build_object('resource_id', v_savu, 'mode', 'shared', 'starts_at', '16:00', 'ends_at', '19:00')));
  perform pg_temp.ck(jsonb_array_length(res) = 1 and not (res -> 0 ->> 'materialized')::boolean, 'I5: shared-varaus ei ole ristiriita eikä materialisoidu');
  perform test.logout();

  -- J: suojaus
  perform pg_temp.ck(test.code(format('update booking.space_blocks set active = false where event_block_id in (select id from booking.event_resource_blocks where rule_id = %s)', v_rule)) = 'event_managed', 'J1: tapahtumasulkua ei voi muuttaa suoraan');
  perform test.login(u_mgr);
  perform pg_temp.ck(test.code(format('select booking.admin_delete_block(%s)', (select b.id from booking.space_blocks b join booking.event_resource_blocks e on e.id = b.event_block_id where e.rule_id = v_rule limit 1))) = 'event_managed', 'J2: admin_delete_block hylkää tapahtumasulun');
  perform test.logout();

  -- K: kopiot
  perform test.login(u_mgr);
  res := booking.admin_product_copy(33);
  perform test.logout();
  v_copy := (res ->> 'product_id')::bigint; v_slug := res ->> 'slug';
  perform pg_temp.ck(v_slug = 'kopio-sipoonjoen-kekri' and (select name = 'Kopio: Sipoonjoen Kekri' and name_en like 'Copy: %' and not active from kb.products where id = v_copy), 'K1: Kopio: nimi, Copy: name_en, uusi slug, active=false');
  perform pg_temp.ck((select (a.price, a.vat_rate, a.price_text, a.category) = (b.price, b.vat_rate, b.price_text, b.category) from kb.products a, kb.products b where a.id = v_copy and b.id = 33), 'K2: hinta, ALV, hintateksti ja kategoria sellaisenaan');
  perform pg_temp.ck((select not bookable and not shop_visible and max_persons = 8 from booking.product_config where product_id = v_copy), 'K3: kopio ei myynnissä, asetukset kopioitu');
  perform pg_temp.ck((select count(*) from booking.product_space_rules where product_id = v_copy) = (select count(*) from booking.product_space_rules where product_id = 33), 'K4: tilasäännöt kopioitu');
  perform test.login(u_mgr);
  v_slug := booking.admin_product_copy(33) ->> 'slug';
  res := booking.admin_event_copy(33, true, 7);
  perform test.logout();
  perform pg_temp.ck(v_slug = 'kopio-sipoonjoen-kekri-2', 'K5: toinen kopio saa eri slugin');
  perform pg_temp.ck((res ->> 'rules_copied')::int = 1, 'K6: admin_event_copy kopioi tulevan kerran');
  perform pg_temp.ck((select count(*) from booking.schedule_rules r where r.product_id = (res ->> 'product_id')::bigint and r.kind = 'event' and r.valid_from = d + 7 and not r.active) = 1, 'K7: kopiokerta siirretty 7 pv, passiivinen');
  perform pg_temp.ck((select count(*) from booking.event_resource_blocks e join booking.schedule_rules r on r.id = e.rule_id where r.product_id = (res ->> 'product_id')::bigint) = 3
                     and (select count(*) from booking.space_blocks b join booking.event_resource_blocks e on e.id = b.event_block_id join booking.schedule_rules r on r.id = e.rule_id where r.product_id = (res ->> 'product_id')::bigint) = 0, 'K8: blokit kopioitu, passiivinen kerta ei varaa');
  perform test.login(u_mgr);
  res := booking.admin_event_rule_copy(v_rule, d + 42);
  perform test.logout();
  perform pg_temp.ck(res ->> 'date' = (d + 42)::text and (res ->> 'active')::boolean and jsonb_array_length(res -> 'blocks') = 3 and res ->> 'label' = to_char(d + 42, 'DD.MM.YYYY') || ' klo 17.00'
                     and (select count(*) from booking.space_blocks b join booking.event_resource_blocks e on e.id = b.event_block_id where e.rule_id = (res ->> 'id')::bigint) = 2, 'K9: admin_event_rule_copy (uusi päivä, blokit materialisoitu)');

  -- L: koulutus
  perform test.login(u_mgr);
  res := booking.admin_event_rule_upsert(null, 36, jsonb_build_object('date', d + 3, 'start_time', '10:00', 'duration_minutes', 3240, 'max_persons', 12));
  perform pg_temp.ck((res ->> 'duration_minutes')::int = 3240, 'L1: monipäiväinen koulutus (yksi lippu)');
  res := booking.admin_event_blocks_set((res ->> 'id')::bigint, jsonb_build_array(
    jsonb_build_object('resource_id', v_savu, 'starts_at', to_char(d + 3, 'YYYY-MM-DD') || 'T09:00:00+03:00', 'ends_at', to_char(d + 3, 'YYYY-MM-DD') || 'T18:00:00+03:00'),
    jsonb_build_object('resource_id', v_savu, 'starts_at', to_char(d + 5, 'YYYY-MM-DD') || 'T09:00', 'ends_at', to_char(d + 5, 'YYYY-MM-DD') || 'T16:00')));
  perform pg_temp.ck((res -> 1 ->> 'start_day')::int = 2 and (res -> 1 ->> 'start_clock') = '09:00', 'L2: ISO-aika muunnetaan päivä+kello');
  perform test.logout();
  update booking.product_config set bookable = true, shop_visible = true where product_id = 36;
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(booking.public_catalog()) x where (x ->> 'id')::int = 36), 'L3: koulutus ei näy kaupassa (kanava widget)');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(booking.public_events(null, 'shop')) x where (x ->> 'product_id')::int = 36)
                     and exists (select 1 from jsonb_array_elements(booking.public_events(null, 'widget')) x where (x ->> 'product_id')::int = 36), 'L4: public_events: koulutus vain widget-kanavassa');
  perform pg_temp.ck((select count(*) from booking.space_blocks b join booking.event_resource_blocks e on e.id = b.event_block_id join booking.schedule_rules r on r.id = e.rule_id where r.product_id = 36) = 2, 'L5: koulutuksen blokit varaavat savusaunan');
  perform test.login(u_mgr);
  res := booking.admin_event_set_channels(36, array['shop', 'widget']);
  perform pg_temp.ck(test.code($q$select booking.admin_event_set_channels(36, array['johku'])$q$) = 'invalid_param', 'L6: tuntematon kanava hylätään');
  perform test.logout();
  perform pg_temp.ck((select channels = array['shop', 'widget'] from booking.product_config where product_id = 36), 'L7: kanavat tallentuvat');

  -- M: poisto
  v_n := (select count(*) from booking.space_blocks);
  v_n2 := (select id from booking.schedule_rules where product_id = 33 and kind = 'event' and valid_from = d + 42);
  perform test.login(u_mgr);
  res := booking.admin_event_rule_delete(v_rule3);
  perform test.logout();
  perform pg_temp.ck((res ->> 'ok')::boolean and not exists (select 1 from booking.schedule_rules where id = v_rule3)
                     and not exists (select 1 from booking.resources where code = 'event_rule_' || v_rule3), 'M1: kerta ja pooli poistettu');
  perform test.login(u_mgr);
  res := booking.admin_event_rule_delete(v_n2);
  perform test.logout();
  perform pg_temp.ck((select count(*) from booking.space_blocks) = v_n - 2, 'M2: poistetun kerran sulut poistuvat');
  perform test.login(u_mgr);
  res := booking.admin_event_rule_upsert(v_rule2, null, '{"active":false}'::jsonb);
  perform test.logout();
  perform pg_temp.ck(not (res ->> 'active')::boolean, 'M3: myymätön kerta passivoituu');

  -- N: Lovi
  perform pg_temp.ck(not exists (select 1 from booking.product_space_rules s where s.space_id = (select id from booking.resources where code = 'lovi') and s.active and s.product_id not in (10, 11, 12)), 'N1: Loviin vain tuotteet 10–12');
  perform pg_temp.ck((select count(*) from booking.product_space_rules s where s.space_id = (select id from booking.resources where code = 'lovi') and s.active and s.product_id in (10, 11, 12)
                       and s.selection = 'auto_if_blocked' and s.requires_blocked_space_id = v_rauni and s.max_persons = 1) = 3, 'N2: hoitojen 10–12 Lovi-säännöt ennallaan (Rauni suljettu, 1 hlö)');
  perform pg_temp.ck((select n_lovi from t158_before) = (select count(*) from booking.m158_lovi_rows), 'O2: uudelleenajo ei muuttanut Lovi-taulua');

  -- myynti takaisin pois: kerrat katoavat saatavuudesta
  update booking.settings set value = 'false'::jsonb where key = 'events.sale_enabled';
  perform pg_temp.ck(not exists (select 1 from booking.public_availability_all(d, d) where rule_id = v_rule), 'B2: kytkin pois -> kerta pois public_availability_all');
end $t$;

-- P: rollback (kahdesti) ja md5-tarkistus (rollback keskeyttää itse, jos md5 ei täsmää)
\ir ../rollbacks/20261024300000_booking_158_ROLLBACK.sql
\ir ../rollbacks/20261024300000_booking_158_ROLLBACK.sql
do $t$
begin
  perform pg_temp.ck((select count(*) from pg_proc p where p.pronamespace = 'booking'::regnamespace and (
      (p.proname = '_sessions' and md5(pg_get_functiondef(p.oid)) = '872ef0fc6a9d38726ea2438f11ba3f01') or
      (p.proname = '_check_claim' and md5(pg_get_functiondef(p.oid)) = 'bf875a55f4d73bfdcbaf107c29f09f45') or
      (p.proname = '_resolve_session' and md5(pg_get_functiondef(p.oid)) = '132d5ce9356106af79cfa84658e76fd1') or
      (p.proname = '_block_conflict_pairs' and md5(pg_get_functiondef(p.oid)) = 'cd2a64faf36994de5c99979816876f99') or
      (p.proname = 'space_blocks_managed_guard' and md5(pg_get_functiondef(p.oid)) = '6b9f525403f3a69285b65921c1a79196') or
      (p.proname = 'closure_blocks_outbox_trg' and md5(pg_get_functiondef(p.oid)) = '17ce83a9fbf50bebaffe2568438757ec') or
      (p.proname = 'closure_outbox_backfill' and md5(pg_get_functiondef(p.oid)) = 'd6ddcaf1e152d74b8093d158e3394209') or
      (p.proname = 'public_catalog' and md5(pg_get_functiondef(p.oid)) = 'b869be5d3444cc3d6923153efc336120') or
      (p.proname = 'public_availability' and md5(pg_get_functiondef(p.oid)) = '503709f45fe0e98b9d4701c95297312f') or
      (p.proname = 'public_availability_all' and md5(pg_get_functiondef(p.oid)) = 'eeb7cf54b957b2d29b9ea2fcc4f2a409'))) = 10, 'P1: 10 funktiota tuotannon md5:llä');
  perform pg_temp.ck(to_regclass('booking.event_resource_blocks') is null and to_regclass('booking.m158_lovi_rows') is null
                     and not exists (select 1 from information_schema.columns where table_schema = 'booking' and ((table_name = 'schedule_rules' and column_name = 'kind') or (table_name = 'product_config' and column_name = 'channels') or (table_name = 'space_blocks' and column_name = 'event_block_id')))
                     and not exists (select 1 from booking.space_blocks where reason like 'Tapahtuma: %'), 'P2: taulut, sarakkeet ja tapahtumasulut poistettu');
  perform pg_temp.ck(to_regprocedure('booking.public_events(date, text)') is null and to_regprocedure('booking.admin_event_rule_upsert(bigint, bigint, jsonb)') is null
                     and not exists (select 1 from booking.settings where key = 'events.sale_enabled'), 'P3: uudet funktiot ja asetus poistettu');
  perform pg_temp.ck((select count(*) from booking.product_space_rules s where s.space_id = (select id from booking.resources where code = 'lovi') and s.active) >= 3
                     and exists (select 1 from booking.product_space_rules s where s.space_id = (select id from booking.resources where code = 'lovi') and s.active and s.product_id not in (10, 11, 12)), 'P4: Lovi-rivit aktivoitu takaisin');
end $t$;
-- migraatio uudelleen rollbackin jälkeen (koko kierros)
\ir ../migrations/20261024300000_booking_158_events.sql
do $t$
begin
  perform pg_temp.ck(to_regclass('booking.event_resource_blocks') is not null and to_regprocedure('booking.public_events(date, text)') is not null, 'P5: migraatio ajettavissa uudelleen rollbackin jälkeen');
  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t158_r where ok), (select count(*) from t158_r where not ok),
    coalesce((select string_agg(label, ' | ') from t158_r where not ok), 'ALL OK');
end $t$;
