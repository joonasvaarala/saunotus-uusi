-- t171: hiljaisen ajan ale vain vuoron perushinnasta, lisähenkilö täyshintainen (booking_171, migraatio 20261024210635, väliaikainen versio).
-- A rakenne ja md5, B _quiet_base, C tarjous (144 €, lisähenkilö 10 €), D varaus 7 hlö = 154 € (ei 152 €), E 6 / 3 / 10 hlö,
-- F alennuskoodin esikatselu (hiljainen ale perushinnasta, suurempi koodi voittaa), G varaus koodilla, H migraation uudelleenajo,
-- I rollback kahdesti (tuotannon md5, vanha käytös 152 €) + migraatio uudelleen.
-- Ajo (psql, paikallinen PG17, migraatiot ja fixtures/10_test_helpers.sql ajettu; kb 26: 180 €, sis. 6 hlö, lisähenkilö 10 €):
--   cd booking/supabase/tests/discounts && psql -X -v ON_ERROR_STOP=0 -f t171_quiet_extra_person.sql
-- Kaikki yhdessä transaktiossa; lopussa tahallinen poikkeus "TESTRESULT pass=… fail=…" kumoaa kaiken. Data feikkiä (@example.test). Ei tuotantoon.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table t171_r(ok boolean, label text);
grant all on t171_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t171_r values (coalesce(p_ok, false), p_label) $$;
-- tuotteen 26 vapaat 180 €:n vuorot (sis. 6 hlö, lisähenkilö 10 €) seuraavalle 14 päivälle, alkuun yli 3 h
create temp table t171_s as
  select row_number() over (order by s.starts_at) n, s.rule_id, s.session_date, s.starts_at, s.base_price, s.included_persons, s.extra_person_price
    from booking._sessions((now() at time zone 'Europe/Helsinki')::date, (now() at time zone 'Europe/Helsinki')::date + 14, 26, true) s
   where s.status = 'available' and s.starts_at > now() + interval '3 hours' and s.price_mode = 'fixed_plus_extra'
     and s.base_price = 180 and s.included_persons = 6 and s.extra_person_price = 10;
grant all on t171_s to public;

-- ===== A: rakenne
do $t$ begin
  perform pg_temp.ck((select count(*) from t171_s) >= 8, 'A1: testivuoroja riittää (' || (select count(*) from t171_s) || ')');
  perform pg_temp.ck(md5(pg_get_functiondef('booking._quiet_apply(bigint,jsonb)'::regprocedure)) = 'dd2139dc889d981e6623ef1fceaeec3d'
    and md5(pg_get_functiondef('booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)'::regprocedure)) = 'e8fe514b4ec9db4043d388e5547f94ad', 'A2: booking_171:n md5');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._quiet_base(jsonb,numeric)', 'execute')
    and not has_function_privilege('authenticated', 'booking._quiet_base(jsonb,numeric)', 'execute')
    and not has_function_privilege('anon', 'booking._quiet_apply(bigint,jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'booking._quiet_apply(bigint,jsonb)', 'execute')
    and has_function_privilege('anon', 'booking.public_check_code(text,bigint,date,integer,jsonb,text,text)', 'execute'), 'A3: oikeudet');
  perform pg_temp.ck((select bool_and(prosecdef and proconfig @> array['search_path=""']) from pg_proc p where p.pronamespace = 'booking'::regnamespace
    and p.proname in ('_quiet_apply', 'public_preview_code')), 'A4: security definer, search_path tyhjä');
  perform pg_temp.ck((select proconfig @> array['search_path=""'] and provolatile = 'i' from pg_proc where oid = 'booking._quiet_base(jsonb,numeric)'::regprocedure), 'A5: _quiet_base immutable, search_path tyhjä');
end $t$;

-- ===== B: _quiet_base
do $t$ begin
  perform pg_temp.ck(booking._quiet_base('{"mode":"fixed_plus_extra","base":180,"extra_persons":1,"extra_person_price":10}', 190) = 180, 'B1: 7 hlö → 180');
  perform pg_temp.ck(booking._quiet_base('{"mode":"fixed_plus_extra","base":180,"extra_persons":0}', 180) = 180, 'B2: 6 hlö → 180');
  perform pg_temp.ck(booking._quiet_base('{"mode":"fixed_plus_extra","base":180}', 100) = 100, 'B3: rivi pienempi kuin perushinta → rivi');
  perform pg_temp.ck(booking._quiet_base('{"mode":"per_person","unit_price":25,"persons":4}', 100) = 100, 'B4: per_person → koko rivi');
  perform pg_temp.ck(booking._quiet_base('{"mode":"fixed","base":150}', 150) = 150, 'B5: fixed → koko rivi');
  perform pg_temp.ck(booking._quiet_base(null, 120) = 120 and booking._quiet_base('{}', 120) = 120 and booking._quiet_base('{"mode":"fixed_plus_extra","base":"x"}', 120) = 120, 'B6: puuttuva / virheellinen breakdown → koko rivi');
  perform pg_temp.ck(booking._quiet_base('{"mode":"fixed_plus_extra","base":180}', 0) = 0 and booking._quiet_base('{"mode":"fixed_plus_extra","base":180}', null) = 0, 'B7: 0 / null → 0');
end $t$;

do $t$
declare
  u_adm uuid := test.mk_staff('t171-adm@example.test', 'admin');
  s1 t171_s; s2 t171_s; s3 t171_s; s4 t171_s; s5 t171_s; s6 t171_s;
  j jsonb; j2 jsonb; v_ord booking.orders; v_item booking.order_items; v_pay booking.payments; v_q1 bigint; v_q2 bigint;
begin
  select * into s1 from t171_s where n = 1; select * into s2 from t171_s where n = 2; select * into s3 from t171_s where n = 3;
  select * into s4 from t171_s where n = 4; select * into s5 from t171_s where n = 5; select * into s6 from t171_s where n = 6;
  v_q1 := (select id from booking.quiet_discount_rules where 26 = any(product_ids) and hours_before = 72);
  v_q2 := (select id from booking.quiet_discount_rules where 26 = any(product_ids) and hours_before = 36);
  perform test.login(u_adm);
  perform booking.admin_quiet_set_enabled(true);
  perform booking.admin_quiet_rule_upsert(v_q1, '{"hours_before":336}');   -- kaikki 14 päivän vuorot −20 %
  perform booking.admin_quiet_rule_upsert(v_q2, '{"hours_before":1}');
  perform test.logout();

  -- ===== C: tarjous
  perform test.anon('10.171.0.1');
  j := booking.public_quiet_offers(current_date, current_date + 14);
  perform test.logout();
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(j) e where (e ->> 'rule_id')::bigint = s1.rule_id and (e ->> 'starts_at')::timestamptz = s1.starts_at
      and (e ->> 'percent')::numeric = 20 and (e ->> 'base_price')::numeric = 180 and (e ->> 'discounted_price')::numeric = 144
      and (e ->> 'extra_person_price')::numeric = 10 and (e ->> 'included_persons')::int = 6), 'C1: tarjous −20 % 180 → 144, lisähenkilö 10 € (ei alennettu)');

  -- ===== D: varaus 7 hlö = 144 + 10 = 154
  perform test.anon('10.171.0.2');
  j := booking.public_create_booking(s1.rule_id, s1.session_date, 7, 'Testi Lisähenkilö', 't171-d@example.test', '0401234567', false, 'fi', null, 'private', null, null);
  perform test.logout();
  select * into v_ord from booking.orders where public_token = (j ->> 'token')::uuid;
  select * into v_item from booking.order_items where order_id = v_ord.id and kind = 'reservation';
  select * into v_pay from booking.payments where order_id = v_ord.id order by id limit 1;
  perform pg_temp.ck((j ->> 'ok')::boolean and j ->> 'discount_source' = 'quiet' and (j ->> 'discount')::numeric = 36 and (j ->> 'total')::numeric = 154
    and (j #>> '{quiet,amount}')::numeric = 36, 'D1: vastaus: ale 36 €, yhteensä 154 €: ' || j::text);
  perform pg_temp.ck(v_item.unit_price_gross = 190 and v_item.discount_amount = 36 and v_item.line_total_gross = 154
    and (v_item.price_breakdown #>> '{quiet,base}')::numeric = 190 and (v_item.price_breakdown #>> '{quiet,discount_base}')::numeric = 180
    and (v_item.price_breakdown #>> '{quiet,amount}')::numeric = 36 and (v_item.price_breakdown ->> 'extra_person_price')::numeric = 10, 'D2: rivi 190 − 36 = 154, price_breakdown.quiet');
  perform pg_temp.ck(v_ord.total_gross = 154 and (v_pay.id is null or v_pay.amount = 154), 'D3: tilaus ja maksu 154 €');

  -- ===== E: 6, 3 ja 10 henkeä
  perform test.reset_rl();
  perform test.anon('10.171.0.3');
  j := booking.public_create_booking(s2.rule_id, s2.session_date, 6, 'Testi Kuusi', 't171-e1@example.test', '0401234567', false, 'fi', null, 'private', null, null);
  j2 := booking.public_create_booking(s3.rule_id, s3.session_date, 10, 'Testi Kymmenen', 't171-e2@example.test', '0401234567', false, 'fi', null, 'private', null, null);
  perform test.logout();
  perform pg_temp.ck((j ->> 'total')::numeric = 144 and (j ->> 'discount')::numeric = 36, 'E1: 6 hlö → 144 €: ' || j::text);
  perform pg_temp.ck((j2 ->> 'total')::numeric = 184 and (j2 ->> 'discount')::numeric = 36, 'E2: 10 hlö → 144 + 4 × 10 = 184 €: ' || j2::text);
  perform test.reset_rl();
  perform test.anon('10.171.0.4');
  j := booking.public_create_booking(s4.rule_id, s4.session_date, 3, 'Testi Kolme', 't171-e3@example.test', '0401234567', false, 'fi', null, 'private', null, null);
  perform test.logout();
  perform pg_temp.ck((j ->> 'total')::numeric = 144, 'E3: 3 hlö (alle sisältyvän) → 144 €: ' || j::text);

  -- ===== F: alennuskoodin esikatselu
  insert into booking.discount_codes(code, kind, value) values ('T171PIENI', 'percent', 10), ('T171ISO', 'percent', 50);
  perform test.reset_rl();
  perform test.anon('10.171.0.5');
  j := booking.public_check_code('T171PIENI', s5.rule_id, s5.session_date, 7);
  j2 := booking.public_check_code('T171ISO', s5.rule_id, s5.session_date, 7);
  perform test.logout();
  perform pg_temp.ck((j ->> 'ok')::boolean and j ->> 'discount_source' = 'quiet' and (j ->> 'discount')::numeric = 36 and (j ->> 'total')::numeric = 154
    and (j ->> 'code_discount')::numeric = 19, 'F1: pieni koodi (19 €) < hiljainen ale 36 € → 154 €: ' || j::text);
  perform pg_temp.ck(j2 ->> 'discount_source' = 'code' and (j2 ->> 'discount')::numeric = 95 and (j2 ->> 'total')::numeric = 95
    and (j2 #>> '{quiet,amount}')::numeric = 36, 'F2: iso koodi 95 € voittaa; quiet.amount 36: ' || j2::text);

  -- ===== G: varaus koodilla
  perform test.reset_rl();
  perform test.anon('10.171.0.6');
  j := booking.public_create_booking_code(s5.rule_id, s5.session_date, 7, 'Testi Koodi', 't171-g1@example.test', '0401234567', false, 'fi', null, 'private', null, null, 'T171PIENI');
  j2 := booking.public_create_booking_code(s6.rule_id, s6.session_date, 7, 'Testi Koodi2', 't171-g2@example.test', '0401234567', false, 'fi', null, 'private', null, null, 'T171ISO');
  perform test.logout();
  select * into v_item from booking.order_items where order_id = (select id from booking.orders where public_token = (j ->> 'token')::uuid) and kind = 'reservation';
  perform pg_temp.ck((j ->> 'ok')::boolean and j ->> 'discount_source' = 'quiet' and (j ->> 'total')::numeric = 154 and v_item.line_total_gross = 154
    and v_item.discount_code_id is null and (select used_count from booking.discount_codes where code = 'T171PIENI') = 0, 'G1: pieni koodi → hiljainen ale 154 €, koodia ei kuluteta: ' || j::text);
  select * into v_ord from booking.orders where public_token = (j2 ->> 'token')::uuid;
  select * into v_item from booking.order_items where order_id = v_ord.id and kind = 'reservation';
  perform pg_temp.ck((j2 ->> 'ok')::boolean and j2 ->> 'discount_source' = 'code' and v_item.line_total_gross = 95 and v_ord.total_gross = 95
    and not (v_item.price_breakdown ? 'quiet') and (v_item.price_breakdown #>> '{quiet_superseded,amount}')::numeric = 36, 'G2: iso koodi → 190 − 95 = 95 €, hiljainen ale (36 €) perutaan: ' || j2::text);
end $t$;

-- ===== H: migraation uudelleenajo
\ir ../../migrations/20261024210635_booking_171_quiet_extra_person.sql
do $t$ begin
  perform pg_temp.ck(md5(pg_get_functiondef('booking._quiet_apply(bigint,jsonb)'::regprocedure)) = 'dd2139dc889d981e6623ef1fceaeec3d'
    and md5(pg_get_functiondef('booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)'::regprocedure)) = 'e8fe514b4ec9db4043d388e5547f94ad', 'H1: uudelleenajo: md5 ennallaan');
end $t$;

-- ===== I: rollback kahdesti → tuotannon md5 ja vanha käytös; sitten migraatio uudelleen
\ir ../../rollbacks/20261024210635_booking_171_ROLLBACK.sql
\ir ../../rollbacks/20261024210635_booking_171_ROLLBACK.sql
do $t$
declare j jsonb; s t171_s;
begin
  select * into s from t171_s where n = 7;
  perform pg_temp.ck(md5(pg_get_functiondef('booking._quiet_apply(bigint,jsonb)'::regprocedure)) = '92d6a01979c46e9f12b5edb2f9dacd2a'
    and md5(pg_get_functiondef('booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)'::regprocedure)) = '4816fbaf5149e501a128aed40f2bf505'
    and to_regprocedure('booking._quiet_base(jsonb,numeric)') is null, 'I1: rollback: tuotannon md5, _quiet_base poistettu');
  perform test.reset_rl();
  perform test.anon('10.171.0.7');
  j := booking.public_create_booking(s.rule_id, s.session_date, 7, 'Testi Rollback', 't171-rb@example.test', '0401234567', false, 'fi', null, 'private', null, null);
  perform test.logout();
  perform pg_temp.ck((j ->> 'ok')::boolean and (j ->> 'total')::numeric = 152, 'I2: rollbackin jälkeen vanha käytös (lisähenkilö alennettu, 152 €): ' || j::text);
end $t$;
\ir ../../migrations/20261024210635_booking_171_quiet_extra_person.sql
do $t$
declare j jsonb; s t171_s;
begin
  select * into s from t171_s where n = 8;
  perform test.reset_rl();
  perform test.anon('10.171.0.8');
  j := booking.public_create_booking(s.rule_id, s.session_date, 7, 'Testi Uudelleen', 't171-re@example.test', '0401234567', false, 'fi', null, 'private', null, null);
  perform test.logout();
  perform pg_temp.ck(md5(pg_get_functiondef('booking._quiet_apply(bigint,jsonb)'::regprocedure)) = 'dd2139dc889d981e6623ef1fceaeec3d'
    and (j ->> 'total')::numeric = 154, 'I3: migraatio rollbackin jälkeen: md5 ja 154 €: ' || j::text);
end $t$;

do $t$
declare v_pass int; v_fail int; v_list text; begin
  select count(*) filter (where ok), count(*) filter (where not ok), string_agg(case when not ok then label end, ' | ') into v_pass, v_fail, v_list from t171_r;
  raise exception 'TESTRESULT pass=% fail=% :: %', v_pass, v_fail, coalesce(v_list, 'ALL OK');
end $t$;
rollback;
