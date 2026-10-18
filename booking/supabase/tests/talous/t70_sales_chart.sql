-- t70: admin_sales_chart (booking_71). Rollback-transaktio: lopuksi tahallinen poikkeus. Ei bottitunnuksia.
-- Varmistaa: reports.view, ei anon; Johku mukana käyrässä; raportin totals ja CSV eivät kasva Johkun verran.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t70.log', '', true);
create function public.t70_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t70.log', coalesce(current_setting('t70.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t70_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 120) end;
end $$;
create function public.t70_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 120) end);
end $$;
create function public.t70_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t70_anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; end $$;
create function public.t70_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_staff uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid();
  o_nat bigint; p_nat bigint; o_a bigint; o_b bigint; o_c bigint; o_d bigint; p_j bigint;
  apr_g0 numeric; apr_v0 numeric;
  before_chart jsonb; after_chart jsonb; before_rep jsonb; after_rep jsonb; csv text;
  g0 numeric; v0 numeric; n0 numeric; jg0 numeric; jv0 numeric; jn0 numeric; u0 numeric; tot0 numeric;
  rg0 numeric; jstat0 numeric; jref0 numeric;
  log text; npass int; nfail int;
begin
  perform public.t70_ck(not has_function_privilege('anon', 'booking.admin_sales_chart(integer)', 'execute'), 'G1: anonilta ei execute');
  perform public.t70_ck(not has_function_privilege('public', 'booking.admin_sales_chart(integer)', 'execute'), 'G2: publicilta ei execute');
  perform public.t70_ck(has_function_privilege('authenticated', 'booking.admin_sales_chart(integer)', 'execute'), 'G3: authenticated saa execute (runko vaatii reports.view)');
  perform public.t70_ck(has_function_privilege('service_role', 'booking.admin_sales_chart(integer)', 'execute'), 'G4: service_role saa execute');
  perform public.t70_ck(public.t70_try('select booking.admin_sales_chart(2031)') = 'forbidden', 'G5: ilman henkilöstöä forbidden');

  perform public.t70_anon();
  perform public.t70_ck(public.t70_try('select booking.admin_sales_chart(2031)') like '42501%', 'G6: rooli anon ei pääse funktioon');
  perform public.t70_logout();

  insert into auth.users(id, email) values (u_staff, 't70-staff@example.test'), (u_mgr, 't70-mgr@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_staff, 't70-staff@example.test', 't70 staff', 'staff'),
    (u_mgr, 't70-mgr@example.test', 't70 manager', 'manager');

  perform public.t70_login(u_staff);
  perform public.t70_ck(public.t70_try('select booking.admin_sales_chart(2031)') = 'forbidden', 'G7: staff (vain reports.daily) forbidden');
  perform public.t70_logout();

  perform public.t70_login(u_mgr);
  perform public.t70_ck(public.t70_try('select booking.admin_sales_chart(1999)') = 'invalid_param', 'G8: vuosi alle 2000');
  perform public.t70_ck(public.t70_try('select booking.admin_sales_chart(2101)') = 'invalid_param', 'G9: vuosi yli 2100');

  before_chart := public.t70_call('booking.admin_sales_chart(2031)');
  before_rep := public.t70_call($q$booking.admin_report_month('2031-03')$q$);
  perform public.t70_ck(before_chart ? 'months' and jsonb_array_length(before_chart -> 'months') = 12, 'D0: 12 kuukautta ennen lisäyksiä');
  g0 := coalesce((before_chart -> 'months' -> 2 ->> 'native_gross')::numeric, 0);
  v0 := coalesce((before_chart -> 'months' -> 2 ->> 'native_vat')::numeric, 0);
  n0 := coalesce((before_chart -> 'months' -> 2 ->> 'native_net')::numeric, 0);
  jg0 := coalesce((before_chart -> 'months' -> 2 ->> 'johku_gross')::numeric, 0);
  jv0 := coalesce((before_chart -> 'months' -> 2 ->> 'johku_vat')::numeric, 0);
  jn0 := coalesce((before_chart -> 'months' -> 2 ->> 'johku_net')::numeric, 0);
  u0 := coalesce((before_chart -> 'months' -> 2 ->> 'unsplit_gross')::numeric, 0);
  tot0 := coalesce((before_chart -> 'months' -> 2 ->> 'gross')::numeric, 0);
  -- huhtikuun osahyvitys: erotus, ei absoluuttinen (kannassa voi olla muuta dataa)
  rg0 := coalesce((before_rep -> 'totals' ->> 'gross_after_refunds')::numeric, 0);
  jstat0 := coalesce((before_rep -> 'statistics' -> 'johku' ->> 'gross')::numeric, 0);
  jref0 := coalesce((before_rep -> 'statistics' -> 'johku' ->> 'refunded_gross')::numeric, 0);
  apr_g0 := coalesce((before_chart -> 'months' -> 3 ->> 'johku_gross')::numeric, 0);
  apr_v0 := coalesce((before_chart -> 'months' -> 3 ->> 'johku_vat')::numeric, 0);
  perform public.t70_logout();

  -- Lisäykset superuserina (RLS). Natiivi kuitti 100 €, ALV 25,5 % → ALV 20,32, netto 79,68. Antopäivä 2031-03-10 UTC.
  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale)
  values (880010, 'confirmed', 'paid', 100, 'EUR', 'admin', 'fi') returning id into o_nat;
  insert into booking.payments(order_id, method, status, amount) values (o_nat, 'cash', 'pending', 100) returning id into p_nat;
  insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, issued_at, total_gross, snapshot, text_body)
  values ('K-2031-T70-1', 'receipt', 'T70', 2031, 1, o_nat, p_nat, '2031-03-10 10:00:00+00', 100,
          jsonb_build_object('total_net', 79.68, 'total_vat', 20.32, 'total_gross', 100,
            'lines', jsonb_build_array(jsonb_build_object('description', 't70 sauna', 'quantity', 1, 'line_gross', 100, 'line_net', 79.68, 'vat_rate', 25.5, 'category', 'public')),
            'payment', jsonb_build_object('method_label', 'Käteinen')), 't70 native');

  -- Johku maksettu 50 @ 13,5 % (paid_at 2031-03-15).
  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale, external_source, external_id, johku_order_no, external_meta)
  values (880001, 'confirmed', 'paid', 50, 'EUR', 'johku_import', 'fi', 'johku', 't70-a', 880001,
          jsonb_build_object('johku', jsonb_build_object('paid', true, 'amount', '50', 'paid_at', '2031-03-15T12:00:00+00', 'payment_method', 'mobilepay')))
  returning id into o_a;
  insert into booking.order_items(order_id, product_name, quantity, unit_price_gross, line_total_gross, vat_rate, external_source, external_id)
  values (o_a, 't70 vuoro', 1, 50, 50, 13.5, 'johku', 't70-a-1');

  -- Johku kokonaan hyvitetty 20 @ 25,5 %. Käyrään 0 (alkuperäistä plussaa ei ole). Raportin refunded_gross kasvaa, gross ei.
  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale, external_source, external_id, johku_order_no, external_meta)
  values (880002, 'cancelled', 'refunded', 20, 'EUR', 'johku_import', 'fi', 'johku', 't70-b', 880002,
          jsonb_build_object('johku', jsonb_build_object('paid', true, 'amount', '20', 'paid_at', '2031-03-20T12:00:00+00', 'payment_method', 'cash')))
  returning id into o_b;
  insert into booking.order_items(order_id, product_name, quantity, unit_price_gross, line_total_gross, vat_rate, external_source, external_id)
  values (o_b, 't70 hyvitys', 1, 20, 20, 25.5, 'johku', 't70-b-1');

  -- Johku ilman rivejä: 10 €, ALV-kantaa ei keksitä.
  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale, external_source, external_id, johku_order_no, external_meta)
  values (880003, 'confirmed', 'paid', 10, 'EUR', 'johku_import', 'fi', 'johku', 't70-c', 880003,
          jsonb_build_object('johku', jsonb_build_object('paid', true, 'amount', '10', 'paid_at', '2031-03-21T12:00:00+00', 'payment_method', 'voucher')))
  returning id into o_c;

  -- Osittain hyvitetty huhtikuussa: koko Johku-summa 7 € (osahyvitystä ei eritellä).
  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale, external_source, external_id, johku_order_no, external_meta)
  values (880004, 'confirmed', 'partially_refunded', 7, 'EUR', 'johku_import', 'fi', 'johku', 't70-d', 880004,
          jsonb_build_object('johku', jsonb_build_object('paid', true, 'amount', '7', 'paid_at', '2031-04-02T12:00:00+00', 'payment_method', 'mobilepay')))
  returning id into o_d;
  insert into booking.order_items(order_id, product_name, quantity, unit_price_gross, line_total_gross, vat_rate, external_source, external_id)
  values (o_d, 't70 osa', 1, 7, 7, 25.5, 'johku', 't70-d-1');

  -- Johku-kuitti estyy (olemassa oleva suoja): samaa myyntiä ei voi kirjata kuitiksi.
  insert into booking.payments(order_id, method, status, amount, paid_at) values (o_a, 'cash', 'paid', 50, '2031-03-15 12:00:00+00') returning id into p_j;
  perform public.t70_ck((select count(*) from booking.receipts where order_id = o_a) = 0, 'X1: Johku-maksu ei luonut kuittia');
  perform public.t70_ck(public.t70_try(format('insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, issued_at, total_gross, snapshot, text_body) values (''K-2031-T70-J'', ''receipt'', ''T70'', 2031, 2, %s, %s, ''2031-03-15 12:00:00+00'', 50, ''{"total_net":44.05,"total_vat":5.95}''::jsonb, ''ei'')', o_a, p_j)) = 'johku_not_accounted', 'X2: Johku-kuitti estetty');

  perform public.t70_login(u_mgr);
  after_chart := public.t70_call('booking.admin_sales_chart(2031)');
  after_rep := public.t70_call($q$booking.admin_report_month('2031-03')$q$);
  csv := public.t70_call($q$booking.admin_report_csv('2031-03-01'::date, '2031-03-31'::date, 'lines')$q$) ->> 'content';

  perform public.t70_ck((after_chart ->> 'basis') = 'cash_receipt_issued_at', 'C1: kassaperuste kuitin antamispäivä');
  perform public.t70_ck((after_chart ->> 'johku_basis') = 'johku_paid_at', 'C2: Johku-päivä paid_at');
  perform public.t70_ck((after_chart ->> 'vat_method') = 'order_item_rates_proportional', 'C3: ALV rivien suhteessa');
  perform public.t70_ck((after_chart -> 'months' -> 2 ->> 'native_gross')::numeric - g0 = 100, 'C4: natiivi brutto 100');
  perform public.t70_ck((after_chart -> 'months' -> 2 ->> 'native_vat')::numeric - v0 = 20.32, 'C5: natiivi ALV 20,32');
  perform public.t70_ck((after_chart -> 'months' -> 2 ->> 'native_net')::numeric - n0 = 79.68, 'C6: natiivi netto 79,68');
  perform public.t70_ck((after_chart -> 'months' -> 2 ->> 'johku_gross')::numeric - jg0 = 50, 'C7: Johku eritelty brutto 50');
  perform public.t70_ck((after_chart -> 'months' -> 2 ->> 'johku_vat')::numeric - jv0 = 5.95, 'C8: Johku ALV 5,95');
  perform public.t70_ck((after_chart -> 'months' -> 2 ->> 'johku_net')::numeric - jn0 = 44.05, 'C9: Johku netto 44,05');
  perform public.t70_ck((after_chart -> 'months' -> 2 ->> 'unsplit_gross')::numeric - u0 = 10, 'C10: erittelemätön 10');
  perform public.t70_ck((after_chart -> 'months' -> 2 ->> 'gross')::numeric - tot0 = 160, 'C11: kuukauden brutto 160 (100 + 50 + erittelemätön 10; hyvitetty 20 ei vähennä)');
  perform public.t70_ck((after_chart -> 'months' -> 2 ->> 'net')::numeric + (after_chart -> 'months' -> 2 ->> 'vat')::numeric + (after_chart -> 'months' -> 2 ->> 'unsplit_gross')::numeric
                         = (after_chart -> 'months' -> 2 ->> 'gross')::numeric, 'C12: netto + ALV + erittelemätön = brutto');
  perform public.t70_ck((after_chart -> 'months' -> 3 ->> 'johku_gross')::numeric - apr_g0 = 7, 'C13: osahyvitys lasketaan koko Johku-summana');
  perform public.t70_ck((after_chart -> 'months' -> 3 ->> 'johku_vat')::numeric - apr_v0 = 1.42, 'C14: osahyvityksen ALV rivin kannasta');
  perform public.t70_ck(
    ((after_chart -> 'months' -> 2 ->> 'johku_gross')::numeric - jg0) + ((after_chart -> 'months' -> 2 ->> 'unsplit_gross')::numeric - u0)
      = (after_rep -> 'statistics' -> 'johku' ->> 'gross')::numeric - jstat0,
    'C15: käyrän Johku (brutto + erittelemätön) = statistics.johku.gross, hyvitetty 880002 mukana');

  perform public.t70_ck((after_rep -> 'totals' ->> 'gross_after_refunds')::numeric - rg0 = 100, 'R1: raportin brutto kasvaa vain kuitilla');
  perform public.t70_ck((after_rep -> 'statistics' -> 'johku' ->> 'gross')::numeric - jstat0 = 60, 'R2: statistics.johku.gross = maksetut 50+10 (hyvitetty ei vähennä bruttoa)');
  perform public.t70_ck((after_rep -> 'statistics' -> 'johku' ->> 'refunded_gross')::numeric - jref0 = 20, 'R3: statistics.johku.refunded_gross = 20');
  perform public.t70_ck(position('880001' in csv) = 0 and position('880002' in csv) = 0 and position('880003' in csv) = 0, 'R4: Johku-tilausnumerot eivät ole CSV:ssä');
  perform public.t70_ck(position('K-2031-T70-1' in csv) > 0, 'R5: natiivikuitti on CSV:ssä');
  perform public.t70_ck(position('880010' in csv) > 0, 'R6: natiivitilaus on CSV:ssä');

  perform public.t70_logout();

  log := current_setting('t70.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
