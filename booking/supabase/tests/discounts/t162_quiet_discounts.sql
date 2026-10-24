-- t162: hiljaisten aikojen ale (booking_162, migraatio 20261024184729).
-- A rakenne, oikeudet ja oletukset (pois päältä), B pois päältä kaikki kuten ennen, C kytkin ja oikeudet, D tarjoukset (tyhjä vuoro, portaat,
-- rajat ≤, tuote 49 samassa saunassa, tilasulku), E varaus lukitsee alennetun hinnan (koko vuoron hinta lisähenkilöineen, ei lisäpalveluita),
-- F alennuskoodi: ei pinoudu, suurempi etu voittaa (tasatilanteessa hiljainen ale, koodin käyttökertaa ei kuluteta), G siirto poistaa alen
-- (E:n varaus vahvistetaan ensin testin sisällä, koska tuotannossa verkkovaraus on maksamaton pito),
-- H hallinnan säännöt (validointi, päällekkäisyys, poisto), I migraation uudelleenajo, J rollback (tuotannon md5) + rollbackin uudelleenajo.
-- Ajo (psql, paikallinen PG17, migraatiot ja fixtures/10_test_helpers.sql ajettu):
--   cd booking/supabase/tests/discounts && psql -X -v ON_ERROR_STOP=0 -f t162_quiet_discounts.sql
-- Kaikki yhdessä transaktiossa; lopussa tahallinen poikkeus "TESTRESULT pass=… fail=…" kumoaa kaiken. Kaikki data feikkiä (@example.test). Ei tuotantoon.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table t162_r(ok boolean, label text);
grant all on t162_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t162_r values (coalesce(p_ok, false), p_label) $$;
-- tuotteen 26 vapaat vuorot seuraavalle 14 päivälle (alkuun yli 3 h), järjestyksessä
create temp table t162_s as
  select row_number() over (order by s.starts_at) n, s.rule_id, s.session_date, s.starts_at, s.ends_at, s.base_price,
         extract(epoch from (s.starts_at - now())) / 3600 h
    from booking._sessions((now() at time zone 'Europe/Helsinki')::date, (now() at time zone 'Europe/Helsinki')::date + 14, 26, true) s
   where s.status = 'available' and s.starts_at > now() + interval '3 hours';
grant all on t162_s to public;

-- A0: oletukset ennen muutoksia
do $t$ begin
  perform pg_temp.ck((select value from booking.settings where key = 'quiet_discounts.enabled') = 'false'::jsonb
    and not (select is_public from booking.settings where key = 'quiet_discounts.enabled'), 'A1: quiet_discounts.enabled = false, ei julkinen');
  perform pg_temp.ck((select array_agg(hours_before || ':' || percent::numeric(5,0) order by hours_before) from booking.quiet_discount_rules where 26 = any(product_ids) and active)
    = array['36:30', '72:20'], 'A2: siemenportaat tuotteelle 26: 72 h −20 %, 36 h −30 %');
  perform pg_temp.ck(not exists (select 1 from booking.quiet_discount_rules where 49 = any(product_ids)), 'A3: tuote 49 ei mukana');
  perform pg_temp.ck((select count(*) from t162_s) >= 6, 'A4: testivuoroja riittää (' || (select count(*) from t162_s) || ')');
end $t$;

-- I: migraation uudelleenajo
\ir ../../migrations/20261024184729_booking_162_quiet_discounts.sql

do $t$
declare
  u_adm uuid := test.mk_staff('t162-adm@example.test', 'admin');
  u_staff uuid := test.mk_staff('t162-staff@example.test', 'staff');
  s1 t162_s; s2 t162_s; s3 t162_s; s4 t162_s; s5 t162_s; s6 t162_s; s7 t162_s;
  j jsonb; j2 jsonb; v_tok uuid; v_item booking.order_items; v_ord booking.orders; v_pay booking.payments; v_full numeric; v_amt numeric;
  v_q1 bigint; v_q2 bigint; v_cust bigint; v_r49 bigint; v_res bigint; v_n int; v_dc bigint;
begin
  select * into s1 from t162_s where n = 1; select * into s2 from t162_s where n = 2; select * into s3 from t162_s where n = 3;
  select * into s4 from t162_s where n = 4; select * into s5 from t162_s where n = 5; select * into s6 from t162_s where n = 6;
  select * into s7 from t162_s where n = 7;
  v_q1 := (select id from booking.quiet_discount_rules where 26 = any(product_ids) and hours_before = 72);
  v_q2 := (select id from booking.quiet_discount_rules where 26 = any(product_ids) and hours_before = 36);

  -- ===== A: rakenne ja oikeudet
  perform pg_temp.ck((select relrowsecurity from pg_class where oid = 'booking.quiet_discount_rules'::regclass)
    and not has_table_privilege('anon', 'booking.quiet_discount_rules', 'select')
    and not has_table_privilege('authenticated', 'booking.quiet_discount_rules', 'select'), 'A5: taulu RLS, ei suoria oikeuksia');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_quiet_offers(date,date,text)', 'execute')
    and not has_function_privilege('anon', 'booking._quiet_offers(date,date,bigint,boolean)', 'execute')
    and not has_function_privilege('authenticated', 'booking._quiet_offers(date,date,bigint,boolean)', 'execute')
    and not has_function_privilege('authenticated', 'booking._quiet_apply(bigint,jsonb)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_quiet_rule_upsert(bigint,jsonb)', 'execute')
    and has_function_privilege('authenticated', 'booking.admin_quiet_rule_upsert(bigint,jsonb)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_quiet_set_enabled(boolean)', 'execute'), 'A6: funktioiden oikeudet');
  perform pg_temp.ck((select bool_and(prosecdef and proconfig @> array['search_path=""']) from pg_proc p where p.pronamespace = 'booking'::regnamespace
    and p.proname in ('_quiet_offers', '_quiet_for_rule', '_quiet_apply', 'admin_quiet_rules_list', 'admin_quiet_rule_upsert', 'admin_quiet_rule_delete',
                      'admin_quiet_set_enabled', 'admin_quiet_preview', 'public_quiet_offers', 'public_create_booking', 'public_create_booking_code', 'public_preview_code')),
    'A7: security definer, search_path tyhjä');
  perform pg_temp.ck(exists (select 1 from pg_trigger where tgname = 'order_items_quiet_reset' and tgrelid = 'booking.order_items'::regclass), 'A8: trigger order_items_quiet_reset');

  -- ===== B: pois päältä → kuten ennen
  perform test.anon('10.162.0.1');
  perform pg_temp.ck(booking.public_quiet_offers(current_date, current_date + 14) = '[]'::jsonb, 'B1: public_quiet_offers [] kun pois');
  perform test.logout();
  perform pg_temp.ck(booking._quiet_for_rule(s7.rule_id, s7.session_date) is null, 'B2: _quiet_for_rule null kun pois');
  perform pg_temp.ck((select count(*) from booking._quiet_offers(current_date, current_date + 14, null, false)) >= 1, 'B3: esikatselu (ilman kytkintä) näkee tarjoukset');
  perform test.anon('10.162.0.2');
  j := test.pub_book(s7.rule_id, s7.session_date, 2, 't162-off@example.test');
  perform test.logout();
  select * into v_item from booking.order_items where order_id = (select id from booking.orders where public_token = (j ->> 'token')::uuid) and kind = 'reservation';
  perform pg_temp.ck((j ->> 'ok')::boolean and not (j ? 'discount_source') and not (j ? 'quiet') and not (j ? 'discount')
    and (j ->> 'total')::numeric = v_item.unit_price_gross and v_item.line_total_gross = v_item.unit_price_gross
    and coalesce(v_item.discount_amount, 0) = 0 and not (v_item.price_breakdown ? 'quiet'), 'B4: varaus pois päältä: täysi hinta, ei uusia kenttiä: ' || j::text);

  -- ===== C: kytkin
  perform test.login(u_staff);
  perform pg_temp.ck(test.code('select booking.admin_quiet_set_enabled(true)') = 'forbidden', 'C1: staff ei voi kytkeä');
  perform pg_temp.ck(test.code($q$select booking.admin_quiet_rule_upsert(null, '{"label":"x","product_ids":[26],"hours_before":10,"percent":5}')$q$) = 'forbidden', 'C2: staff ei voi muokata sääntöjä');
  perform pg_temp.ck((booking.admin_quiet_rules_list() ->> 'enabled')::boolean = false and jsonb_array_length(booking.admin_quiet_rules_list() -> 'rules') = 2, 'C3: staff näkee listan');
  perform test.logout();
  perform test.login(u_adm);
  j := booking.admin_quiet_set_enabled(true);
  perform pg_temp.ck((j ->> 'enabled')::boolean and (select value from booking.settings where key = 'quiet_discounts.enabled') = 'true'::jsonb, 'C4: admin kytkee päälle');
  -- testin portaat: 336 h −20 % (kaikki 14 päivän vuorot), 36 h → säädetään vuorokohtaisesti
  perform booking.admin_quiet_rule_upsert(v_q1, '{"hours_before":336}');
  perform booking.admin_quiet_rule_upsert(v_q2, jsonb_build_object('hours_before', greatest(1, floor(s1.h)::int - 1)));
  perform test.logout();

  -- ===== D: tarjoukset
  perform test.anon('10.162.0.3');
  j := booking.public_quiet_offers(current_date, current_date + 14);
  perform test.logout();
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(j) e where (e ->> 'rule_id')::bigint = s1.rule_id and (e ->> 'starts_at')::timestamptz = s1.starts_at
      and (e ->> 'percent')::numeric = 20 and (e ->> 'discounted_price')::numeric = s1.base_price - round(s1.base_price * 0.2, 2)), 'D1: tyhjä vuoro −20 %: ' || left(j::text, 300));
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(j) e where (e ->> 'product_id')::bigint <> 26), 'D2: vain tuote 26');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(j) e where (e ->> 'rule_id')::bigint = s7.rule_id and (e ->> 'starts_at')::timestamptz = s7.starts_at), 'D3: varattu vuoro (B4) ei tarjouksissa');
  perform pg_temp.ck(booking.public_quiet_offers(current_date, current_date + 14, 'business') = '[]'::jsonb, 'D4: yritysyleisölle ei tarjouksia (tuote 49 ei säännöissä)');
  perform pg_temp.ck(test.code('select booking.public_quiet_offers(current_date, current_date + 20)') = 'bad_range', 'D5: yli 15 päivää → bad_range');
  -- rajat: porras hours_before = ceil(h) on voimassa (alkuun ≤ raja), floor(h) - 1 ei
  perform test.login(u_adm); perform booking.admin_quiet_rule_upsert(v_q2, jsonb_build_object('hours_before', ceil(s4.h)::int)); perform test.logout();
  perform pg_temp.ck((booking._quiet_for_rule(s4.rule_id, s4.session_date) ->> 'percent')::numeric = 30, 'D6: alkuun ≤ porras → −30 % (suurin voimassa oleva)');
  perform pg_temp.ck((booking._quiet_for_rule(s5.rule_id, s5.session_date) ->> 'percent')::numeric = case when s5.h <= ceil(s4.h) then 30 else 20 end, 'D7: myöhempi vuoro −20 %');
  perform pg_temp.ck((select next_change_at from booking._quiet_offers(s5.session_date, s5.session_date, s5.rule_id, true))
    = case when s5.h <= ceil(s4.h) then s5.starts_at - interval '2 hours' else s5.starts_at - make_interval(hours => ceil(s4.h)::int) end, 'D8: next_change_at = seuraava porras (tai myynnin sulkeutuminen)');
  perform test.login(u_adm); perform booking.admin_quiet_rule_upsert(v_q2, jsonb_build_object('hours_before', greatest(1, floor(s4.h)::int - 1))); perform test.logout();
  perform pg_temp.ck((booking._quiet_for_rule(s4.rule_id, s4.session_date) ->> 'percent')::numeric = 20, 'D9: alkuun > porras → −20 %');
  perform test.login(u_adm); perform booking.admin_quiet_rule_upsert(v_q2, '{"hours_before":1}'); perform test.logout();   -- jatkossa kaikki testivuorot −20 %
  -- tuote 49 samassa saunassa → vuoro ei tyhjä
  insert into booking.customers(name, email) values ('Yritys T162', 't162-b2b@example.test') returning id into v_cust;
  v_r49 := (select sr.id from booking.schedule_rules sr where sr.product_id = 49 and sr.active and extract(isodow from s2.session_date)::int = any(sr.weekdays) limit 1);
  if v_r49 is null then
    perform pg_temp.ck(true, 'D10: tuotteella 49 ei vuoroa samana viikonpäivänä → ohitettu');
  else
    perform booking._create_booking_core(v_r49, s2.session_date, 2, v_cust, 'admin', null, 'fi', null, 'confirmed', null, false);
    perform pg_temp.ck(booking._quiet_for_rule(s2.rule_id, s2.session_date) is null
      and not exists (select 1 from booking._quiet_offers(s2.session_date, s2.session_date, null, false) o where o.starts_at = s2.starts_at), 'D10: tuotteen 49 varaus samassa saunassa → ei alea tuotteelle 26');
  end if;
  -- tilasulku
  insert into booking.space_blocks(space_id, starts_at, ends_at, reason) values ((select space_id from booking.schedule_rules where id = s3.rule_id), s3.starts_at, s3.ends_at, 't162');
  perform pg_temp.ck(booking._quiet_for_rule(s3.rule_id, s3.session_date) is null, 'D11: tilasulku → ei alea');

  -- ===== E: varaus lukitsee alennetun hinnan (8 henkeä: lisähenkilöt mukana)
  perform test.anon('10.162.0.4');
  j := booking.public_create_booking(s1.rule_id, s1.session_date, 8, 'Testi Hiljainen', 't162-e@example.test', '0401234567', false, 'fi', null, 'private', null, null);
  perform test.logout();
  v_tok := (j ->> 'token')::uuid;
  select * into v_ord from booking.orders where public_token = v_tok;
  select * into v_item from booking.order_items where order_id = v_ord.id and kind = 'reservation';
  select * into v_pay from booking.payments where order_id = v_ord.id order by id limit 1;
  v_full := v_item.unit_price_gross; v_amt := round(v_full * 0.2, 2);
  perform pg_temp.ck((j ->> 'ok')::boolean and j ->> 'discount_source' = 'quiet' and (j #>> '{quiet,percent}')::numeric = 20
    and (j ->> 'discount')::numeric = v_amt and (j ->> 'total')::numeric = v_full - v_amt, 'E1: vastaus: discount_source quiet, −20 %: ' || j::text);
  perform pg_temp.ck(v_item.discount_amount = v_amt and v_item.line_total_gross = v_full - v_amt and v_item.discount_code_id is null
    and (v_item.price_breakdown #>> '{quiet,percent}')::numeric = 20 and (v_item.price_breakdown #>> '{quiet,base}')::numeric = v_full, 'E2: rivi: discount_amount, line_total, price_breakdown.quiet');
  perform pg_temp.ck(v_full = (select total from booking._rule_price(s1.rule_id, 8)) and v_ord.total_gross = v_full - v_amt
    and (v_pay.id is null or v_pay.amount = v_full - v_amt), 'E3: koko vuoron hinta lisähenkilöineen alennettu; tilaus ja maksu alennetulla summalla');
  perform pg_temp.ck(not exists (select 1 from booking._quiet_offers(s1.session_date, s1.session_date, s1.rule_id, true)), 'E4: varattu vuoro poistuu tarjouksista');

  -- ===== F: alennuskoodi (ei pinoudu)
  insert into booking.discount_codes(code, kind, value) values ('T162PIENI', 'percent', 10), ('T162ISO', 'percent', 50), ('T162TASA', 'percent', 20);
  perform test.reset_rl();
  perform test.anon('10.162.0.5');
  j := booking.public_check_code('T162PIENI', s4.rule_id, s4.session_date, 2);
  j2 := booking.public_check_code('T162ISO', s4.rule_id, s4.session_date, 2);
  perform test.logout();
  v_full := (select total from booking._rule_price(s4.rule_id, 2));
  perform pg_temp.ck((j ->> 'ok')::boolean and j ->> 'discount_source' = 'quiet' and (j ->> 'code_applied')::boolean = false
    and (j ->> 'discount')::numeric = round(v_full * 0.2, 2) and (j ->> 'total')::numeric = v_full - round(v_full * 0.2, 2), 'F1: esikatselu: pienempi koodi → hiljainen ale voittaa: ' || j::text);
  perform pg_temp.ck(j2 ->> 'discount_source' = 'code' and (j2 ->> 'discount')::numeric = round(v_full * 0.5, 2) and (j2 #>> '{quiet,percent}')::numeric = 20, 'F2: esikatselu: suurempi koodi voittaa: ' || j2::text);
  perform test.anon('10.162.0.6');
  j := booking.public_check_code('T162TASA', s4.rule_id, s4.session_date, 2);
  perform pg_temp.ck(j ->> 'discount_source' = 'quiet', 'F3: tasatilanne → hiljainen ale');
  j := booking.public_create_booking_code(s4.rule_id, s4.session_date, 2, 'Testi Koodi', 't162-f1@example.test', '0401234567', false, 'fi', null, 'private', null, null, 'T162PIENI');
  perform test.logout();
  select * into v_item from booking.order_items where order_id = (select id from booking.orders where public_token = (j ->> 'token')::uuid) and kind = 'reservation';
  perform pg_temp.ck((j ->> 'ok')::boolean and j ->> 'discount_source' = 'quiet' and (j ->> 'code_applied')::boolean = false and v_item.discount_code_id is null
    and v_item.line_total_gross = v_full - round(v_full * 0.2, 2) and (select used_count from booking.discount_codes where code = 'T162PIENI') = 0, 'F4: varaus pienellä koodilla: hiljainen ale, koodin käyttökertaa ei kuluteta: ' || j::text);
  perform test.reset_rl();
  perform test.anon('10.162.0.7');
  j := booking.public_create_booking_code(s5.rule_id, s5.session_date, 2, 'Testi Koodi2', 't162-f2@example.test', '0401234567', false, 'fi', null, 'private', null, null, 'T162ISO');
  perform test.logout();
  v_full := (select total from booking._rule_price(s5.rule_id, 2));
  select * into v_ord from booking.orders where public_token = (j ->> 'token')::uuid;
  select * into v_item from booking.order_items where order_id = v_ord.id and kind = 'reservation';
  perform pg_temp.ck((j ->> 'ok')::boolean and j ->> 'discount_source' = 'code' and j ->> 'discount_code' = 'T162ISO' and (j ->> 'discount')::numeric = round(v_full * 0.5, 2)
    and v_item.discount_code_id is not null and v_item.discount_amount = round(v_full * 0.5, 2) and v_item.line_total_gross = v_full - round(v_full * 0.5, 2)
    and not (v_item.price_breakdown ? 'quiet') and v_item.price_breakdown #>> '{quiet_superseded,by}' = 'code' and v_ord.total_gross = v_item.line_total_gross
    and (select used_count from booking.discount_codes where code = 'T162ISO') = 1, 'F5: suurempi koodi: koodi käytetään, hiljainen ale perutaan (ei pinoudu): ' || j::text);

  -- ===== G: siirto poistaa alen
  v_res := (select id from booking.reservations where order_id = (select id from booking.orders where public_token = v_tok));
  -- E:n verkkovaraus on tuotannon asetuksilla maksamaton pito (pending), jota ei voi siirtää (BK001 not_changeable).
  -- Vahvistetaan testin tilaus ja varaus tässä transaktiossa kuten maksun vahvistus tekee (sama päivitys kuin booking_162:n
  -- vahvistuspolussa); tyhjällä paikalliskannalla varaus on jo vahvistettu, jolloin päivitykset eivät muuta mitään.
  update booking.reservations set status = 'confirmed', hold_expires_at = null where id = v_res and status = 'pending';
  update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()), hold_kind = null
   where public_token = v_tok and status = 'pending';
  perform test.login(u_adm);
  j := booking.admin_change_booking(v_res, s6.rule_id, s6.session_date, null);
  perform test.logout();
  select * into v_ord from booking.orders where public_token = v_tok;
  select * into v_item from booking.order_items where order_id = v_ord.id and kind = 'reservation';
  perform pg_temp.ck((j ->> 'ok')::boolean and coalesce(v_item.discount_amount, 0) = 0 and v_item.line_total_gross = v_item.unit_price_gross
    and not (v_item.price_breakdown ? 'quiet') and (v_item.price_breakdown #>> '{quiet_removed,percent}')::numeric = 20
    and v_ord.total_gross = v_item.line_total_gross, 'G1: siirto → ale pois, täysi hinta: ' || coalesce(v_item.price_breakdown::text, 'null'));

  -- ===== H: hallinnan säännöt
  perform test.login(u_adm);
  perform pg_temp.ck(test.code($q$select booking.admin_quiet_rule_upsert(null, '{"label":"Liian iso","product_ids":[26],"hours_before":12,"percent":95}')$q$) = 'invalid_value', 'H1: ale > 90 % hylätään');
  perform pg_temp.ck(test.code($q$select booking.admin_quiet_rule_upsert(null, '{"label":"Ei tuotetta","product_ids":[999999],"hours_before":12,"percent":10}')$q$) = 'invalid_value', 'H2: tuntematon tuote hylätään');
  perform pg_temp.ck(test.code($q$select booking.admin_quiet_rule_upsert(null, '{"label":"Tunnit","product_ids":[26],"hours_before":400,"percent":10}')$q$) = 'invalid_value', 'H3: tunnit > 336 hylätään');
  perform pg_temp.ck(test.code($q$select booking.admin_quiet_rule_upsert(null, '{"label":"Tuplaporras","product_ids":[26],"hours_before":336,"percent":10}')$q$) = 'quiet_overlap', 'H4: sama porras samalle tuotteelle hylätään');
  perform pg_temp.ck(test.code($q$select booking.admin_quiet_rule_upsert(null, '{"label":"Väli","product_ids":[26],"hours_before":12,"percent":10,"valid_from":"2026-12-01","valid_to":"2026-11-01"}')$q$) = 'invalid_value', 'H5: voimassaolo väärin päin hylätään');
  j := booking.admin_quiet_rule_upsert(null, '{"label":"Testi 12 h","label_en":"Test 12 h","product_ids":[26],"hours_before":12,"percent":12.5}');
  perform pg_temp.ck((j ->> 'ok')::boolean and (j #>> '{rule,percent}')::numeric = 12.5 and j #>> '{rule,label_en}' = 'Test 12 h', 'H6: uusi sääntö');
  j2 := booking.admin_quiet_rule_delete((j #>> '{rule,id}')::bigint);
  perform pg_temp.ck((j2 ->> 'ok')::boolean and jsonb_array_length(booking.admin_quiet_rules_list() -> 'rules') = 2, 'H7: poisto');
  j := booking.admin_quiet_preview(current_date, 7);
  perform pg_temp.ck((j ->> 'enabled')::boolean and jsonb_typeof(j -> 'offers') = 'array', 'H8: esikatselu');
  perform booking.admin_quiet_set_enabled(false);
  perform test.logout();
  perform pg_temp.ck(booking.public_quiet_offers(current_date, current_date + 14) = '[]'::jsonb and booking._quiet_for_rule(s6.rule_id, s6.session_date + 7) is null, 'H9: pois kytkettynä ei tarjouksia');
  perform pg_temp.ck(test.audit_n('UPDATE') > 0, 'H10: muutokset audit-lokissa');
end $t$;

-- J: rollback (ajetaan kahdesti)
\ir ../../rollbacks/20261024184729_booking_162_ROLLBACK.sql
\ir ../../rollbacks/20261024184729_booking_162_ROLLBACK.sql
do $t$
declare v_md5 jsonb := (select jsonb_object_agg(p.proname, md5(pg_get_functiondef(p.oid))) from pg_proc p where p.pronamespace = 'booking'::regnamespace
  and p.proname in ('public_create_booking', 'public_create_booking_code', 'public_preview_code')); j jsonb;
begin
  -- tuotannon md5(pg_get_functiondef) ennen booking_162:ta (luettu sxbofnuisemspgquoxyv 2026-10-24)
  perform pg_temp.ck(v_md5 = '{"public_create_booking":"f7b15dca769f5fb4abfd9f81090718ac","public_create_booking_code":"31a03d52526c7b22d2643be477589b7f","public_preview_code":"aaac81dc8ae5704a67b56184e5cd4cd7"}'::jsonb,
    'J1: funktiot tuotannon muodossa: ' || v_md5::text);
  perform pg_temp.ck(to_regclass('booking.quiet_discount_rules') is null and to_regprocedure('booking.public_quiet_offers(date,date,text)') is null
    and to_regprocedure('booking._quiet_offers(date,date,bigint,boolean)') is null and to_regprocedure('booking.admin_quiet_rule_upsert(bigint,jsonb)') is null
    and not exists (select 1 from pg_trigger where tgname = 'order_items_quiet_reset')
    and not exists (select 1 from booking.settings where key = 'quiet_discounts.enabled'), 'J2: uudet objektit ja asetus poistettu');
  perform test.anon('10.162.0.9');
  j := test.pub_book((select rule_id from t162_s where n = 8), (select session_date from t162_s where n = 8), 2, 't162-rb@example.test');
  perform test.logout();
  perform pg_temp.ck((j ->> 'ok')::boolean and not (j ? 'discount_source'), 'J3: varaus toimii rollbackin jälkeen: ' || j::text);
end $t$;

do $t$
declare v_pass int; v_fail int; v_list text; begin
  select count(*) filter (where ok), count(*) filter (where not ok), string_agg(case when not ok then label end, ' | ') into v_pass, v_fail, v_list from t162_r;
  raise exception 'TESTRESULT pass=% fail=% :: %', v_pass, v_fail, coalesce(v_list, 'ALL OK');
end $t$;
rollback;
