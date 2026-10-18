-- t77: Procountor-vienti (booking_77–79). Rollback-transaktio: lopuksi tahallinen poikkeus.
-- Päiväkirja verrataan booking._report_json-tulokseen. Tilinumerot ovat testikokoonpanoa, eivät Havuhatun tilikarttaa.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t77.log', '', true);
create function public.t77_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t77.log', coalesce(current_setting('t77.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t77_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 180) end;
end $$;
create function public.t77_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 180) end);
end $$;
create function public.t77_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t77_anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '{"role":"anon"}', true); execute 'set local role anon'; end $$;
create function public.t77_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_staff uuid := gen_random_uuid();
  u_mgr uuid := gen_random_uuid();
  sig_admin text := 'booking.admin_procountor_status()';
  sig_prep text := 'booking.procountor_daily_prepare(date,boolean)';
  sig_inv text := 'booking.procountor_invoice_reserve(text,jsonb,text,date,jsonb,boolean)';
  sig_mark text := 'booking.procountor_export_mark(bigint,text,text,jsonb)';
  sig_build text := 'booking._procountor_daily_build(date,jsonb,jsonb)';
  sig_disp text := 'booking.procountor_daily_dispatch()';
  st jsonb; prep jsonb; prep2 jsonb; rep jsonb; req jsonb;
  o_id bigint; p_id bigint; r_id bigint; o_u bigint;
  n int; npass int; nfail int; log text; ok_vat boolean; ok_method boolean;
  inv jsonb; inv2 jsonb; inv3 jsonb; req_before jsonb;
  iban text := 'FI2112345600000785';
begin
  perform public.t77_ck(not has_function_privilege('anon', sig_admin, 'execute'), 'G1: anonilta ei admin-tilaa');
  perform public.t77_ck(not has_function_privilege('public', sig_prep, 'execute'), 'G2: publicilta ei prepare');
  perform public.t77_ck(not has_function_privilege('anon', sig_inv, 'execute'), 'G3: anonilta ei laskuvarausta');
  perform public.t77_ck(not has_function_privilege('authenticated', sig_prep, 'execute'), 'G4: authenticated ei prepare');
  perform public.t77_ck(not has_function_privilege('authenticated', sig_inv, 'execute'), 'G5: authenticated ei laskuvarausta');
  perform public.t77_ck(not has_function_privilege('authenticated', sig_mark, 'execute'), 'G6: authenticated ei mark');
  perform public.t77_ck(not has_function_privilege('authenticated', sig_build, 'execute'), 'G7: authenticated ei build');
  perform public.t77_ck(not has_function_privilege('authenticated', sig_disp, 'execute'), 'G8: authenticated ei dispatch');
  perform public.t77_ck(has_function_privilege('authenticated', sig_admin, 'execute'), 'G9: authenticated saa tilan');
  perform public.t77_ck(has_function_privilege('service_role', sig_prep, 'execute'), 'G10: service prepare');
  perform public.t77_ck(has_function_privilege('service_role', sig_admin, 'execute'), 'G11: service tila');

  perform public.t77_anon();
  perform public.t77_ck(public.t77_try('select booking.admin_procountor_status()') like '42501%', 'G12: rooli anon ei pääse');
  perform public.t77_logout();

  perform booking.procountor_daily_dispatch();
  perform public.t77_ck(true, 'D1: dispatch pois päältä palaa');

  insert into auth.users(id, email) values (u_staff, 't77-staff@example.test'), (u_mgr, 't77-mgr@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_staff, 't77-staff@example.test', 't77 staff', 'staff'),
    (u_mgr, 't77-mgr@example.test', 't77 manager', 'manager');

  update booking.integration_config
     set settings = settings || jsonb_build_object('bank_account', iban)
   where key = 'procountor';

  perform public.t77_login(u_staff);
  perform public.t77_ck(public.t77_try('select booking.admin_procountor_status()') = 'forbidden', 'S0: staff ei settings.edit');
  perform public.t77_logout();

  perform public.t77_login(u_mgr);
  st := public.t77_call('booking.admin_procountor_status()');
  perform public.t77_ck(st ->> 'mode' = 'off', 'S1: mode off');
  perform public.t77_ck((st ->> 'daily_enabled')::boolean = false, 'S2: daily pois');
  perform public.t77_ck((st ->> 'bank_account_configured')::boolean = true, 'S3: pankkitili kerrotaan booleanina');
  perform public.t77_ck(position(iban in st::text) = 0, 'S4: tila ei paljasta pankkitiliä');
  perform public.t77_ck(position('client_secret' in st::text) = 0 and position('api_key' in st::text) = 0, 'S5: tila ei paljasta salaisuuksien nimiä arvoina');
  perform public.t77_ck(st -> 'request' is null and st -> 'report' is null, 'S6: tila ei palauta pyyntöä eikä raporttia');
  perform public.t77_logout();

  prep := public.t77_call('booking.procountor_daily_prepare(''2020-01-15''::date, false)');
  perform public.t77_ck(prep ->> 'action' = 'skip' and prep ->> 'reason' = 'disabled', 'P0: pois päältä ei kirjaa');
  perform public.t77_ck((select count(*) from booking.accounting_exports) = 0, 'P1: disabled ei luo riviä');

  update booking.integration_config
     set mode = 'dry_run',
         settings = settings || jsonb_build_object(
           'daily_enabled', true,
           'vat_status', '1',
           'accounts', jsonb_build_object(
             'sales_by_vat', jsonb_build_object('25.5', '3000', '13.5', '3001'),
             'clearing_by_method', jsonb_build_object('card_terminal', '1910'),
             'rounding', '3740'))
   where key = 'procountor';

  prep := public.t77_call('booking.procountor_daily_prepare(''2020-01-15''::date, false)');
  perform public.t77_ck(prep ->> 'status' = 'skipped' and prep ->> 'action' = 'skip', 'E1: tyhjä päivä skipped');
  prep2 := public.t77_call('booking.procountor_daily_prepare(''2020-01-15''::date, false)');
  perform public.t77_ck(prep2 ->> 'id' = prep ->> 'id', 'E2: sama tyhjä päivä ei luo toista riviä');
  perform public.t77_ck((select count(*) from booking.accounting_exports where business_date = '2020-01-15') = 1, 'E3: yksi rivi');

  perform public.t77_ck(public.t77_try('select booking.procountor_daily_prepare((now() at time zone ''Europe/Helsinki'')::date, false)') = 'invalid_param', 'E4: ei tulevaa eikä kuluvaa päivää');

  insert into booking.orders(status, payment_status, total_gross, currency, source_channel, locale)
  values ('confirmed', 'paid', 150, 'EUR', 'admin', 'fi') returning id into o_id;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_id, 'Saunavuoro', 'product', 1, 100, 100, 25.5),
         (o_id, 'Kahvi', 'product', 1, 50, 50, 13.5);
  insert into booking.payments(order_id, method, status, amount) values (o_id, 'card_terminal', 'paid', 150) returning id into p_id;
  select id into r_id from booking.receipts where payment_id = p_id and kind = 'receipt';
  perform public.t77_ck(r_id is not null, 'R1: maksettu maksu loi kuitin');

  alter table booking.receipts disable trigger receipts_guard;
  update booking.receipts set issued_at = timestamptz '2020-03-03 10:00+00' where id = r_id;
  alter table booking.receipts enable trigger receipts_guard;

  rep := booking._report_json('2020-03-03', '2020-03-03', false, false);
  prep := public.t77_call('booking.procountor_daily_prepare(''2020-03-03''::date, false)');
  req := prep -> 'request';
  perform public.t77_ck(prep ->> 'status' = 'dry_run', 'J1: dry_run');
  perform public.t77_ck(req ->> 'type' = 'JOURNAL' and req ->> 'vatType' = 'SALES' and req ->> 'status' = 'UNFINISHED', 'J2: JOURNAL SALES UNFINISHED');
  perform public.t77_ck(req ->> 'receiptDate' = '2020-03-03', 'J3: kirjauspäivä');
  perform public.t77_ck((req ->> 'vatStatus')::int = 1, 'J4: vatStatus asetuksesta');
  perform public.t77_ck(req #>> '{transactions,0,transactionType}' = 'REVERSING_ENTRY', 'J5: ensimmäinen rivi REVERSING_ENTRY');
  perform public.t77_ck((req #>> '{transactions,0,vatPercent}')::numeric = 0, 'J6: selvittelyrivin alv 0');

  select coalesce(bool_and(exists (
           select 1 from jsonb_array_elements(req -> 'transactions') t
            where (t ->> 'vatPercent')::numeric = (e ->> 'rate')::numeric
              and round((t ->> 'accountingValue')::numeric, 2) = round(- (e ->> 'net')::numeric, 2)
              and t ->> 'transactionType' = 'ENTRY')), false)
    into ok_vat
    from jsonb_array_elements(rep -> 'by_vat') e
   where round(coalesce((e ->> 'net')::numeric, 0), 2) <> 0;
  perform public.t77_ck(ok_vat, 'J7: myyntirivit = raportin by_vat netot');

  select coalesce(bool_and(exists (
           select 1 from jsonb_array_elements(req -> 'transactions') t
            where (t ->> 'vatPercent')::numeric = 0
              and round((t ->> 'accountingValue')::numeric, 2) = round(coalesce((e ->> 'gross')::numeric, 0) + coalesce((e ->> 'refunds')::numeric, 0), 2))), false)
    into ok_method
    from jsonb_array_elements(rep -> 'by_method') e
   where round(coalesce((e ->> 'gross')::numeric, 0) + coalesce((e ->> 'refunds')::numeric, 0), 2) <> 0;
  perform public.t77_ck(ok_method, 'J8: maksutaparivit = raportin by_method');
  perform public.t77_ck((select count(*) from booking.accounting_exports where kind = 'daily_sales' and business_date = '2020-03-03') = 1, 'J9: yksi päivärivi');
  prep2 := public.t77_call('booking.procountor_daily_prepare(''2020-03-03''::date, false)');
  perform public.t77_ck(prep2 ->> 'id' = prep ->> 'id', 'J10: sama päivä ei lähde kahdesti');

  update booking.integration_config
     set settings = settings || jsonb_build_object('vat_status', '', 'accounts', '{}'::jsonb)
   where key = 'procountor';
  prep := public.t77_call('booking.procountor_daily_prepare(''2020-03-03''::date, false)');
  perform public.t77_ck(prep ->> 'status' = 'needs_review' and coalesce(prep ->> 'reason', '') like 'missing:%', 'N1: puuttuvat tilit');

  alter table booking.payments disable trigger payments_paid_ins;
  insert into booking.orders(status, payment_status, total_gross, currency, source_channel, locale)
  values ('confirmed', 'paid', 20, 'EUR', 'admin', 'fi') returning id into o_u;
  insert into booking.payments(order_id, method, status, amount, paid_at)
  values (o_u, 'card_terminal', 'paid', 20, timestamptz '2020-02-02 10:00+00');
  alter table booking.payments enable trigger payments_paid_ins;
  prep := public.t77_call('booking.procountor_daily_prepare(''2020-02-02''::date, false)');
  perform public.t77_ck(prep ->> 'status' = 'needs_review' and coalesce(prep ->> 'reason', '') like '%unreceipted%', 'U1: kuittiton maksu');

  update booking.integration_config set mode = 'dry_run' where key = 'procountor';
  inv := public.t77_call($q$booking.procountor_invoice_reserve('inv-1', '{"type":"SALES_INVOICE"}'::jsonb, 'EMAIL', '2020-04-01'::date, '[]'::jsonb, false)$q$);
  perform public.t77_ck(inv ->> 'action' = 'dry_run' and inv ->> 'status' = 'dry_run', 'I1: lasku dry_run');
  inv2 := public.t77_call($q$booking.procountor_invoice_reserve('inv-1', '{"type":"SALES_INVOICE","replaced":true}'::jsonb, 'EMAIL', '2020-04-01'::date, '[]'::jsonb, false)$q$);
  perform public.t77_ck(inv2 ->> 'id' = inv ->> 'id', 'I2: sama avain yksi rivi');
  perform public.t77_ck(public.t77_try('select booking.procountor_export_mark(' || (inv ->> 'id') || ', ''failed'', ''x'', ''{"access_token":"z"}''::jsonb)') = 'invalid_param', 'I3: vastaus ei saa sisältää salaisuutta');
  perform public.t77_ck(public.t77_call('booking.procountor_export_mark(' || (inv ->> 'id') || ', ''sent'', null, ''{"invoice_id":90,"step":"sent"}''::jsonb)') ->> 'status' = 'sent', 'I4: merkintä sent');
  select request into req_before from booking.accounting_exports where id = (inv ->> 'id')::bigint;
  inv3 := public.t77_call($q$booking.procountor_invoice_reserve('inv-1', '{"type":"OTHER"}'::jsonb, 'EMAIL', '2020-04-01'::date, '[]'::jsonb, false)$q$);
  perform public.t77_ck(inv3 ->> 'action' = 'already', 'I5: lähetettyä ei korvata');
  perform public.t77_ck((select request from booking.accounting_exports where id = (inv ->> 'id')::bigint) = req_before, 'I6: pyyntö säilyy');

  perform public.t77_login(u_mgr);
  perform public.t77_ck(public.t77_try('select booking.procountor_daily_prepare(''2020-01-01''::date, false)') like '42501%', 'A1: authenticated ei prepare');
  perform public.t77_ck(public.t77_try($q$select booking.procountor_invoice_reserve('x', '{}'::jsonb, 'EMAIL', '2020-01-01'::date, '[]'::jsonb, false)$q$) like '42501%', 'A2: authenticated ei laskuvarausta');
  perform public.t77_logout();

  log := current_setting('t77.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
