-- t69_day_revenue_role: booking_69. Tuottoluvut vain admin ja manager.
-- Ajo botille (ei CI:ssä): psql -v ON_ERROR_STOP=1 -f tämä, kun migraatiot ja testifixtuurit on ladattu.
-- Lopuksi tahallinen poikkeus: TESTRESULT pass=N fail=0 ja koko lohko kumoutuu.
-- Aikakatkaisuja ei aseteta tässä tiedostossa.

do $t$
declare
  v_admin uuid; v_manager uuid; v_worker uuid; v_rule bigint; v_thu date;
  v jsonb; v_staff jsonb; v_mgr jsonb; v_adm jsonb; r jsonb;
  v_gross numeric; v_code text; log text; npass int; nfail int;
begin
  create function pg_temp.t69_ck(p_ok boolean, p_label text) returns void language plpgsql as $ck$
  begin
    perform set_config('t69.log', coalesce(current_setting('t69.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true);
  end $ck$;
  perform set_config('t69.log', '', true);

  v_admin := test.mk_staff('t69-admin@example.test', 'admin');
  v_manager := test.mk_staff('t69-manager@example.test', 'manager');
  v_worker := test.mk_staff('t69-staff@example.test', 'staff');
  select min(d)::date into v_thu from generate_series(date '2035-06-01', date '2035-06-07', interval '1 day') d where extract(isodow from d) = 4;
  select id into v_rule from booking.schedule_rules where label like 'Yleinen vuoro to 17%' and active order by id limit 1;
  if v_rule is null or v_thu is null then
    raise exception 'TESTRESULT_ABORT rule=% thu=%', v_rule, v_thu;
  end if;

  perform test.anon();
  v_code := test.code(format('select booking.admin_day_revenue(%L)', v_thu));
  perform test.logout();
  perform pg_temp.t69_ck(v_code in ('forbidden', '42501') or v_code ilike '%permission denied%', 'A1: anon ei saa päivän tuottoa');

  perform test.login(v_admin);
  r := booking.admin_create_booking(v_rule, v_thu, 2, null, '{"name":"T69 Maksettu","email":"t69-paid@example.test","phone":"0400006901"}'::jsonb, 'card_terminal', true, null);
  perform test.logout();
  if (r ->> 'reservation_id') is null then
    raise exception 'TESTRESULT_ABORT booking %', r;
  end if;

  if to_regclass('kb.event_dates') is not null and exists (select 1 from kb.products where id = 9) then
    insert into kb.event_dates(product_id, starts_on, ends_on, time_text, active) values (9, v_thu, null, 'klo 18–20', true);
  end if;

  perform test.login(v_worker);
  v_staff := booking.admin_day_extras(v_thu);
  v_code := test.code(format('select booking.admin_day_revenue(%L)', v_thu));
  perform test.logout();
  perform pg_temp.t69_ck(jsonb_typeof(v_staff -> 'revenue') = 'null' and jsonb_typeof(v_staff -> 'revenue_rows') = 'null', 'B1: työntekijän extras ei sisällä tuottolukuja');
  perform pg_temp.t69_ck(jsonb_typeof(v_staff -> 'events') = 'array', 'B2: työntekijä saa tapahtumat');
  perform pg_temp.t69_ck(v_code = 'forbidden', 'B3: työntekijä ei saa kutsua admin_day_revenue');

  perform test.login(v_manager);
  v_mgr := booking.admin_day_revenue(v_thu);
  v := booking.admin_day_extras(v_thu);
  perform test.logout();
  v_gross := (v_mgr -> 'revenue' ->> 'gross')::numeric;
  perform pg_temp.t69_ck(v_gross > 0 and (v -> 'revenue' ->> 'gross')::numeric = v_gross, 'C1: manager saa saman brutton extrasista ja admin_day_revenuesta');
  perform pg_temp.t69_ck(jsonb_typeof(v_mgr -> 'revenue_rows') = 'array' and jsonb_array_length(v_mgr -> 'revenue_rows') >= 1, 'C2: manager saa tuottorivit');

  perform test.login(v_admin);
  v_adm := booking.admin_day_revenue(v_thu);
  v := booking.admin_day_extras(v_thu);
  perform test.logout();
  perform pg_temp.t69_ck((v_adm -> 'revenue' ->> 'gross')::numeric = v_gross and (v -> 'revenue' ->> 'gross')::numeric = v_gross, 'D1: admin saa saman brutton');
  perform pg_temp.t69_ck((v -> 'events') = (v_staff -> 'events'), 'D2: työntekijä näkee samat tapahtumat kuin admin');

  log := current_setting('t69.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
