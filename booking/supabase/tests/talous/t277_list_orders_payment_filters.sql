-- t277: admin_list_orders p_payment_filters text[] (booking_277). Rollback-transaktio: lopuksi tahallinen poikkeus.
-- Monivalinta OR-ehdolla, ei tuplia, total ja sivutus oikein. NULL/tyhjä = vanha p_payment_filter. Vanhat kutsut toimivat.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t277.log', '', true);
create function public.t277_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t277.log', coalesce(current_setting('t277.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t277_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 160) end;
end $$;
create function public.t277_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 160) end);
end $$;
create function public.t277_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t277_anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; end $$;
create function public.t277_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_staff uuid := gen_random_uuid();
  sig text := 'booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer,text,text[])';
  oldsig text := 'booking.admin_list_orders(text,text,text,text,boolean,text,date,date,text,integer,integer,text)';
  o_paid bigint; o_part bigint; o_ref bigint; o_un bigint; o_pend bigint; o_fail bigint; o_ppaid bigint;
  o_can bigint; o_exp bigint; o_zero bigint; o_johku bigint; o_jpart bigint; o_jref bigint;
  n_paid int; n_def int; n_all int; n_un int; n_ref int; n_can int; n_old int; n_pos int;
  log text; npass int; nfail int;
begin
  perform public.t277_ck(not has_function_privilege('anon', sig, 'execute'), 'G1: anonilta ei execute');
  perform public.t277_ck(not has_function_privilege('public', sig, 'execute'), 'G2: publicilta ei execute');
  perform public.t277_ck(has_function_privilege('authenticated', sig, 'execute'), 'G3: authenticated saa execute');
  perform public.t277_ck(has_function_privilege('service_role', sig, 'execute'), 'G4: service_role saa execute');
  perform public.t277_ck(to_regprocedure(oldsig) is null, 'G5: vanhaa 12 argumentin ylikuormitusta ei ole (ei PGRST203)');
  perform public.t277_ck(public.t277_try($q$select booking.admin_list_orders(p_payment_filters => array['paid'])$q$) <> 'ok', 'G6: ilman henkilökuntaa ei listaa (taulukkoparametrilla)');

  perform public.t277_anon();
  perform public.t277_ck(public.t277_try('select booking.admin_list_orders()') like '42501%', 'G7: rooli anon ei pääse funktioon');
  perform public.t277_logout();

  insert into auth.users(id, email) values (u_staff, 't277-staff@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_staff, 't277-staff@example.test', 't277 staff', 'staff');

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
  values (976111, 'confirmed', 'paid', 50, 'EUR', 'johku_import', 'fi', 'johku', 't277-j', 976111) returning id into o_johku;

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale, external_source, external_id, johku_order_no)
  values (976112, 'confirmed', 'partially_refunded', 15, 'EUR', 'johku_import', 'fi', 'johku', 't277-jp', 976112) returning id into o_jpart;

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale, external_source, external_id, johku_order_no)
  values (976113, 'cancelled', 'refunded', 12, 'EUR', 'johku_import', 'fi', 'johku', 't277-jr', 976113) returning id into o_jref;

  perform public.t277_login(u_staff);

  -- vanha käytös ennallaan
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders(p_search => '976101')$q$) ->> 'total')::int = 1, 'O1: oletus paid ilman uutta parametria');
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders(p_search => '976104', p_payment_filter => 'unpaid')$q$) ->> 'total')::int = 1, 'O2: vanha yhden arvon kutsu');
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders('976101', null, null, null, null, 'created', null, null, 'created_desc', 10, 0)$q$) ->> 'total')::int = 1, 'O3: vanha 11 positionaalista argumenttia');
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders('976104', null, 'unpaid', null, null, 'created', null, null, 'created_desc', 10, 0, 'all')$q$) ->> 'total')::int = 1, 'O4: vanha 12 positionaalista argumenttia');
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders(p_search => '976104', p_payment_filters => null)$q$) ->> 'total')::int = 0, 'O5: NULL-taulukko = oletus paid');
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders(p_search => '976104', p_payment_filters => '{}'::text[])$q$) ->> 'total')::int = 0, 'O6: tyhjä taulukko = oletus paid');
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders(p_search => '976104', p_payment_filter => 'all', p_payment_filters => '{}'::text[])$q$) ->> 'total')::int = 1, 'O7: tyhjä taulukko käyttää p_payment_filter-arvoa');

  -- monivalinta
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders(p_search => '976104', p_payment_filters => array['paid','unpaid'])$q$) ->> 'total')::int = 1, 'M1: paid+unpaid löytää maksamattoman');
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders(p_search => '976101', p_payment_filters => array['paid','unpaid'])$q$) ->> 'total')::int = 1, 'M2: paid+unpaid löytää maksetun');
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders(p_search => '976108', p_payment_filters => array['paid','unpaid'])$q$) ->> 'total')::int = 0, 'M3: peruttu ei paid+unpaid');
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders(p_search => '976101', p_payment_filter => 'cancelled', p_payment_filters => array['paid'])$q$) ->> 'total')::int = 1, 'M4: taulukko ohittaa p_payment_filter-arvon');
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders(p_search => '976102', p_payment_filters => array['paid','refunded'])$q$) -> 'rows') = (public.t277_call($q$booking.admin_list_orders(p_search => '976102', p_payment_filters => array['paid'])$q$) -> 'rows'), 'M5: osittain hyvitetty paid+refunded näkyy kerran');
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders(p_search => '976102', p_payment_filters => array['paid','refunded'])$q$) ->> 'total')::int = 1, 'M6: total ilman tuplia');
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders(p_search => '976104', p_payment_filters => array['cancelled','all'])$q$) ->> 'total')::int = 1, 'M7: all taulukossa = kaikki');
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders(p_search => '976109', p_payment_filters => array['cancelled','invoiced'])$q$) ->> 'total')::int = 1, 'M8: cancelled+invoiced löytää vanhentuneen');
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders(p_search => '976101', p_payment_filters => array['paid','paid',' paid '])$q$) ->> 'total')::int = 1, 'M9: toistot ja välilyönnit');
  perform public.t277_ck(public.t277_try($q$select booking.admin_list_orders(p_payment_filters => array['paid','nope'])$q$) = 'invalid_param', 'M10: tuntematon arvo taulukossa');
  perform public.t277_ck(public.t277_try($q$select booking.admin_list_orders(p_payment_filters => array['paid', null])$q$) = 'invalid_param', 'M11: NULL-alkio hylätään');
  perform public.t277_ck(public.t277_try($q$select booking.admin_list_orders(p_payment_filters => array[''])$q$) = 'invalid_param', 'M12: tyhjä merkkijono hylätään');

  -- koko joukko: paid+unpaid+refunded = unioni yksittäisistä, sivutus jatkuu ilman tuplia
  n_all := (public.t277_call($q$booking.admin_list_orders(p_payment_filters => array['paid','unpaid','refunded'], p_limit => 200)$q$) ->> 'total')::int;
  n_paid := (select count(distinct x) from (
      select jsonb_array_elements(public.t277_call($q$booking.admin_list_orders(p_payment_filter => 'paid', p_limit => 200)$q$) -> 'rows') ->> 'order_id' x
      union all select jsonb_array_elements(public.t277_call($q$booking.admin_list_orders(p_payment_filter => 'unpaid', p_limit => 200)$q$) -> 'rows') ->> 'order_id'
      union all select jsonb_array_elements(public.t277_call($q$booking.admin_list_orders(p_payment_filter => 'refunded', p_limit => 200)$q$) -> 'rows') ->> 'order_id') u);
  perform public.t277_ck(n_all = n_paid and n_all > 0, 'S1: total = yksittäisten unioni (' || n_all || ' / ' || n_paid || ')');
  n_un := (select count(distinct x) from (
      select jsonb_array_elements(public.t277_call($q$booking.admin_list_orders(p_payment_filters => array['paid','unpaid','refunded'], p_limit => 3, p_offset => 0, p_sort => 'order_no_desc')$q$) -> 'rows') ->> 'order_id' x
      union all select jsonb_array_elements(public.t277_call($q$booking.admin_list_orders(p_payment_filters => array['paid','unpaid','refunded'], p_limit => 3, p_offset => 3, p_sort => 'order_no_desc')$q$) -> 'rows') ->> 'order_id'
      union all select jsonb_array_elements(public.t277_call($q$booking.admin_list_orders(p_payment_filters => array['paid','unpaid','refunded'], p_limit => 200, p_offset => 6, p_sort => 'order_no_desc')$q$) -> 'rows') ->> 'order_id') u);
  perform public.t277_ck(n_un = n_all, 'S2: sivut yhdessä = total, ei tuplia (' || n_un || ')');
  perform public.t277_ck((public.t277_call($q$booking.admin_list_orders(p_payment_filters => array['paid','unpaid'], p_limit => 1, p_sort => 'order_no_desc')$q$) -> 'rows' -> 0 ->> 'order_no')::bigint
     >= (public.t277_call($q$booking.admin_list_orders(p_payment_filters => array['paid','unpaid'], p_limit => 1, p_offset => 1, p_sort => 'order_no_desc')$q$) -> 'rows' -> 0 ->> 'order_no')::bigint, 'S3: lajittelu säilyy');

  perform public.t277_logout();

  log := current_setting('t277.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
