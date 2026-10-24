-- t151: vuorojen englanninkieliset nimet (booking_151): booking.schedule_rules.label_en → _sessions / public_availability / public_availability_all.
-- a) paluutyyppi: label_en viimeisenä sarakkeena, muut sarakkeet ennallaan ja samassa järjestyksessä
-- b) label_en null → kenttä null, label ennallaan; label_en asetettu → näkyy molemmissa julkisissa funktioissa (anon) ja admin_day_view-sessioissa
-- c) muut kentät (tila, jäljellä, hinnat) eivät muutu label_en:n asettamisesta; oikeudet ennallaan (_sessions ei anonille)
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN. Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken.
-- Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t151_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t151_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.pub(p_rule bigint, p_date date) returns jsonb language plpgsql as $$
declare v_p bigint; a jsonb; b jsonb; begin
  select product_id into v_p from booking.schedule_rules where id = p_rule;
  perform test.anon();
  select to_jsonb(x) into a from booking.public_availability(v_p, p_date, p_date) x where x.rule_id = p_rule;
  select to_jsonb(x) into b from booking.public_availability_all(p_date, p_date, 'consumer') x where x.rule_id = p_rule;
  perform test.logout();
  return jsonb_build_object('one', a, 'all', b); end $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%');
  d date := test.next_dow(1) + 14;
  v_label text; r0 jsonb; r1 jsonb; v_day jsonb;
begin
  perform pg_temp.ck(v_rule is not null, 'A0: testivuoro (Miesten sauna) löytyy');
  perform pg_temp.ck(pg_get_function_result('booking._sessions(date,date,bigint,boolean)'::regprocedure)
    = 'TABLE(rule_id bigint, product_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric, sale_closes_at timestamp with time zone, label_en text)', 'A1: _sessions paluutyyppi + label_en viimeisenä');
  perform pg_temp.ck(pg_get_function_result('booking.public_availability(bigint,date,date)'::regprocedure)
    = 'TABLE(rule_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric, label_en text)', 'A2: public_availability paluutyyppi + label_en viimeisenä');
  perform pg_temp.ck(pg_get_function_result('booking.public_availability_all(date,date,text)'::regprocedure)
    = 'TABLE(product_id bigint, rule_id bigint, label text, mode text, session_date date, starts_at timestamp with time zone, ends_at timestamp with time zone, status text, remaining integer, min_persons integer, max_persons integer, price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric, label_en text)', 'A3: public_availability_all paluutyyppi + label_en viimeisenä');

  select label into v_label from booking.schedule_rules where id = v_rule;
  update booking.schedule_rules set label_en = null where id = v_rule;
  r0 := pg_temp.pub(v_rule, d);
  perform pg_temp.ck(r0 -> 'one' is not null and r0 -> 'all' is not null, 'B1: vuoro näkyy molemmissa julkisissa funktioissa');
  perform pg_temp.ck((r0 -> 'one') ? 'label_en' and r0 #>> '{one,label_en}' is null and r0 #>> '{all,label_en}' is null, 'B2: label_en null kun käännöstä ei ole');
  perform pg_temp.ck(r0 #>> '{one,label}' = v_label and r0 #>> '{all,label}' = v_label, 'B3: label (fi) ennallaan');

  update booking.schedule_rules set label_en = 'Men''s sauna (test)' where id = v_rule;
  r1 := pg_temp.pub(v_rule, d);
  perform pg_temp.ck(r1 #>> '{one,label_en}' = 'Men''s sauna (test)' and r1 #>> '{all,label_en}' = 'Men''s sauna (test)', 'B4: label_en näkyy anonille molemmissa');
  perform pg_temp.ck(r1 #>> '{one,label}' = v_label, 'B5: label ei muutu label_en:n mukana');
  perform pg_temp.ck((r1 -> 'one') - 'label_en' = (r0 -> 'one') - 'label_en' and (r1 -> 'all') - 'label_en' = (r0 -> 'all') - 'label_en', 'C1: muut kentät (tila, jäljellä, hinnat) identtiset');
  perform pg_temp.ck(exists (select 1 from booking._sessions(d, d, null, true) s where s.rule_id = v_rule and s.label_en = 'Men''s sauna (test)'), 'C2: _sessions palauttaa label_en');
  perform pg_temp.ck((select count(*) from booking._sessions(d, d, null, true)) = (select count(*) from booking._sessions(d, d, null, true) s where s.label_en is null or s.rule_id = v_rule), 'C3: muiden vuorojen label_en null (ei sivuvaikutuksia)');

  perform test.login(test.mk_staff('t151@example.com', 'admin'));
  v_day := booking.admin_day_view(d);
  perform test.logout();
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(v_day -> 'sessions') e where (e ->> 'rule_id')::bigint = v_rule and e ->> 'label_en' = 'Men''s sauna (test)' and e ->> 'label' = v_label), 'C4: admin_day_view sessions: label + label_en');

  perform pg_temp.ck(not has_function_privilege('anon', 'booking._sessions(date,date,bigint,boolean)', 'execute')
    and not has_function_privilege('authenticated', 'booking._sessions(date,date,bigint,boolean)', 'execute')
    and has_function_privilege('service_role', 'booking._sessions(date,date,bigint,boolean)', 'execute'), 'X1: _sessions vain service_role');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_availability(bigint,date,date)', 'execute')
    and has_function_privilege('anon', 'booking.public_availability_all(date,date,text)', 'execute')
    and has_function_privilege('authenticated', 'booking.public_availability_all(date,date,text)', 'execute'), 'X2: julkiset funktiot anonille ja authenticatedille');
  perform pg_temp.ck(obj_description('booking.public_availability_all(date,date,text)'::regprocedure, 'pg_proc') like 'Kauppa, vain luku:%', 'X3: public_availability_all-kommentti säilyy');

  declare v_pass int; v_fail int; v_list text; begin
    select count(*) filter (where ok), count(*) filter (where not ok), string_agg(case when not ok then label end, ' | ') into v_pass, v_fail, v_list from t151_r;
    raise exception 'TESTRESULT pass=% fail=% :: %', v_pass, v_fail, coalesce(v_list, 'ALL OK');
  end;
end $t$;
