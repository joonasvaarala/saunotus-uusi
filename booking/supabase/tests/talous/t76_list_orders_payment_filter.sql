-- t76: admin_list_orders p_payment_filter (booking_76). Rollback-transaktio: lopuksi tahallinen poikkeus.
-- Oletus paid: paid ja partially_refunded, netto > 0, ei cancelled/expired. Johku ilman maksurivejä mukana.
-- Vanha 11 argumentin kutsu toimii. all palauttaa myös maksamattoman. Haku ei laajenna palvelimella.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t76.log', '', true);
create function public.t76_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t76.log', coalesce(current_setting('t76.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t76_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 160) end;
end $$;
create function public.t76_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 160) end);
end $$;
create function public.t76_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t76_anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; end $$;
create function public.t76_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_staff uuid := gen_random_uuid();
  sig text := 'booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer,text)';
  oldsig text := 'booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer)';
  o_paid bigint; o_part bigint; o_ref bigint; o_un bigint; o_pend bigint; o_fail bigint; o_ppaid bigint;
  o_can bigint; o_exp bigint; o_zero bigint; o_johku bigint; o_jpart bigint; o_jref bigint;
  n_paid int; n_def int; n_all int; n_un int; n_ref int; n_can int; n_old int; n_pos int;
  log text; npass int; nfail int;
begin
  perform public.t76_ck(not has_function_privilege('anon', sig, 'execute'), 'G1: anonilta ei execute');
  perform public.t76_ck(not has_function_privilege('public', sig, 'execute'), 'G2: publicilta ei execute');
  perform public.t76_ck(has_function_privilege('authenticated', sig, 'execute'), 'G3: authenticated saa execute');
  perform public.t76_ck(has_function_privilege('service_role', sig, 'execute'), 'G4: service_role saa execute');
  perform public.t76_ck(to_regprocedure(oldsig) is null, 'G5: vanhaa 11 argumentin ylikuormitusta ei ole');
  perform public.t76_ck(public.t76_try('select booking.admin_list_orders(p_payment_filter => ''nope'')') = 'invalid_param', 'G6: tuntematon suodatin');

  perform public.t76_anon();
  perform public.t76_ck(public.t76_try('select booking.admin_list_orders()') like '42501%', 'G7: rooli anon ei pääse funktioon');
  perform public.t76_logout();

  insert into auth.users(id, email) values (u_staff, 't76-staff@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_staff, 't76-staff@example.test', 't76 staff', 'staff');

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale)
  values (976101, 'confirmed', 'paid', 80, 'EUR', 'admin', 'fi') returning id into o_paid;
  insert into booking.payments(order_id, method, status, amount, refunded_amount) values (o_paid, 'cash', 'paid', 80, 0);

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale)
  values (976102, 'confirmed', 'partially_refunded', 80, 'EUR', 'web', 'fi') returning id into o_part;
  insert into booking.payments(order_id, method, status, amount, refunded_amount) values (o_part, 'cash', 'partially_refunded', 80, 30);

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale)
  values (976103, 'confirmed', 'refunded', 40, 'EUR', 'web', 'fi') returning id into o_ref;
  insert into booking.payments(order_id, method, status, amount, refunded_amount) values (o_ref, 'cash', 'refunded', 40, 40);

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale)
  values (976104, 'confirmed', 'unpaid', 25, 'EUR', 'phone', 'fi') returning id into o_un;

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale)
  values (976105, 'pending', 'pending', 25, 'EUR', 'web', 'fi') returning id into o_pend;

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale)
  values (976106, 'confirmed', 'failed', 25, 'EUR', 'web', 'fi') returning id into o_fail;

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale)
  values (976107, 'confirmed', 'partially_paid', 100, 'EUR', 'web', 'fi') returning id into o_ppaid;
  insert into booking.payments(order_id, method, status, amount, refunded_amount) values (o_ppaid, 'cash', 'paid', 40, 0);

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale)
  values (976108, 'cancelled', 'paid', 60, 'EUR', 'admin', 'fi') returning id into o_can;
  insert into booking.payments(order_id, method, status, amount, refunded_amount) values (o_can, 'cash', 'paid', 60, 0);

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale)
  values (976109, 'expired', 'paid', 60, 'EUR', 'web', 'fi') returning id into o_exp;
  insert into booking.payments(order_id, method, status, amount, refunded_amount) values (o_exp, 'cash', 'paid', 60, 0);

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale)
  values (976110, 'confirmed', 'partially_refunded', 20, 'EUR', 'web', 'fi') returning id into o_zero;
  insert into booking.payments(order_id, method, status, amount, refunded_amount) values (o_zero, 'cash', 'partially_refunded', 20, 20);

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale, external_source, external_id, johku_order_no)
  values (976111, 'confirmed', 'paid', 50, 'EUR', 'johku_import', 'fi', 'johku', 't76-j', 976111) returning id into o_johku;

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale, external_source, external_id, johku_order_no)
  values (976112, 'confirmed', 'partially_refunded', 15, 'EUR', 'johku_import', 'fi', 'johku', 't76-jp', 976112) returning id into o_jpart;

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale, external_source, external_id, johku_order_no)
  values (976113, 'cancelled', 'refunded', 12, 'EUR', 'johku_import', 'fi', 'johku', 't76-jr', 976113) returning id into o_jref;

  perform public.t76_login(u_staff);

  n_def := (public.t76_call('booking.admin_list_orders(p_search => ''976101'')') ->> 'total')::int;
  perform public.t76_ck(n_def = 1, 'P1: oletus paid löytää täysin maksetun');
  n_paid := (public.t76_call('booking.admin_list_orders(p_search => ''976101'', p_payment_filter => ''paid'')') ->> 'total')::int;
  perform public.t76_ck(n_paid = 1, 'P2: nimetty paid sama kuin oletus');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976102'')') ->> 'total')::int = 1, 'P3: osittain hyvitetty, netto > 0, oletuksessa');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976103'')') ->> 'total')::int = 0, 'P4: kokonaan hyvitetty ei oletuksessa');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976104'')') ->> 'total')::int = 0, 'P5: maksamaton ei oletuksessa');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976107'')') ->> 'total')::int = 0, 'P6: partially_paid ei oletuksessa vaikka netto > 0');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976108'')') ->> 'total')::int = 0, 'P7: peruttu maksettu ei oletuksessa');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976109'')') ->> 'total')::int = 0, 'P8: vanhentunut maksettu ei oletuksessa');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976110'')') ->> 'total')::int = 0, 'P9: netto 0 ei oletuksessa');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976111'')') ->> 'total')::int = 1, 'P10: Johku paid ilman maksurivejä oletuksessa');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976112'')') ->> 'total')::int = 1, 'P11: Johku partially_refunded ilman rivejä oletuksessa');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976113'')') ->> 'total')::int = 0, 'P12: Johku refunded+cancelled ei oletuksessa');

  n_all := (public.t76_call('booking.admin_list_orders(p_search => ''976104'', p_payment_filter => ''all'')') ->> 'total')::int;
  perform public.t76_ck(n_all = 1, 'A1: all löytää maksamattoman numerolla');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976104'')') ->> 'total')::int = 0, 'A2: palvelin ei laajenna hakua oletuksesta');

  n_un := (public.t76_call($q$booking.admin_list_orders(p_search => '976', p_payment_filter => 'unpaid', p_limit => 50)$q$) ->> 'total')::int;
  perform public.t76_ck(n_un = 0, 'U0: numeroalkuinen haku on tarkka, ei osittainen');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976104'', p_payment_filter => ''unpaid'')') ->> 'total')::int = 1, 'U1: unpaid');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976105'', p_payment_filter => ''unpaid'')') ->> 'total')::int = 1, 'U2: pending');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976106'', p_payment_filter => ''unpaid'')') ->> 'total')::int = 1, 'U3: failed');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976107'', p_payment_filter => ''unpaid'')') ->> 'total')::int = 1, 'U4: partially_paid');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976108'', p_payment_filter => ''unpaid'')') ->> 'total')::int = 0, 'U5: peruttu ei maksamattomissa');

  n_ref := (public.t76_call('booking.admin_list_orders(p_search => ''976103'', p_payment_filter => ''refunded'')') ->> 'total')::int;
  perform public.t76_ck(n_ref = 1, 'R1: kokonaan hyvitetty Hyvitetyissä');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976102'', p_payment_filter => ''refunded'')') ->> 'total')::int = 1, 'R2: osittain hyvitetty myös Hyvitetyissä');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976101'', p_payment_filter => ''refunded'')') ->> 'total')::int = 0, 'R3: täysin maksettu ei Hyvitetyissä');

  n_can := (public.t76_call('booking.admin_list_orders(p_search => ''976108'', p_payment_filter => ''cancelled'')') ->> 'total')::int;
  perform public.t76_ck(n_can = 1, 'C1: cancelled');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976109'', p_payment_filter => ''cancelled'')') ->> 'total')::int = 1, 'C2: expired');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976113'', p_payment_filter => ''cancelled'')') ->> 'total')::int = 1, 'C3: Johku cancelled');
  perform public.t76_ck((public.t76_call('booking.admin_list_orders(p_search => ''976101'', p_payment_filter => ''cancelled'')') ->> 'total')::int = 0, 'C4: confirmed ei Perutuissa');

  n_old := (public.t76_call($q$booking.admin_list_orders('976101', null, null, null, null, 'created', null, null, 'created_desc', 10, 0)$q$) ->> 'total')::int;
  perform public.t76_ck(n_old = 1, 'B1: vanha 11 argumentin kutsu käyttää oletusta paid');
  n_pos := (public.t76_call($q$booking.admin_list_orders('976104', null, 'unpaid', null, null, 'created', null, null, 'created_desc', 10, 0, 'all')$q$) ->> 'total')::int;
  perform public.t76_ck(n_pos = 1, 'B2: p_payment_status unpaid ja filter all');
  perform public.t76_ck((public.t76_call($q$booking.admin_list_orders('976104', null, 'unpaid', null, null, 'created', null, null, 'created_desc', 10, 0)$q$) ->> 'total')::int = 0, 'B3: vanha p_payment_status ilman all leikkaa oletukseen');

  perform public.t76_logout();

  log := current_setting('t76.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
