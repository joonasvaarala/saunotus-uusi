-- t113: verollinen ja veroton á-hinta (booking_113).
-- Rollback-transaktio: lopuksi tahallinen poikkeus. Ei tuotantodataa, ei laskunumeron kulutusta.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t113.log', '', true);
create function public.t113_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t113.log', coalesce(current_setting('t113.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t113_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 180) end;
end $$;
create function public.t113_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text; h text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text, s = returned_sqlstate, h = pg_exception_hint;
  return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 180) end, 'hint', h);
end $$;
create function public.t113_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t113_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_mgr uuid := gen_random_uuid();
  u_staff uuid := gen_random_uuid();
  cust jsonb; inv jsonb; credit jsonb; bad jsonb;
  v_id bigint; v_old bigint; v_seq int; v_counter int; v_before int;
  log text; npass int; nfail int;
begin
  perform public.t113_ck(not has_function_privilege('anon', 'booking.admin_save_invoice(bigint,jsonb)', 'execute'), 'G1: anonilta ei tallennusta');
  v_before := (select last_seq from booking.invoice_counters where series = 'L');

  insert into auth.users(id, email) values (u_mgr, 't113-mgr@example.test'), (u_staff, 't113-staff@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_mgr, 't113-mgr@example.test', 't113 manager', 'manager'),
    (u_staff, 't113-staff@example.test', 't113 staff', 'staff');

  perform public.t113_login(u_staff);
  perform public.t113_ck(public.t113_try($$select booking.admin_save_invoice(null, '{}'::jsonb)$$) = 'forbidden', 'P1: työntekijällä ei invoices.manage');
  perform public.t113_logout();

  perform public.t113_login(u_mgr);
  cust := booking.admin_save_invoice_customer(null, '{"company_name":"t113 Hintahattu Zzq","business_id":"9999999-2","email":"t113@example.test"}'::jsonb);
  inv := booking.admin_save_invoice(null, jsonb_build_object(
    'customer_id', (cust ->> 'id')::bigint,
    'lines', jsonb_build_array(
      jsonb_build_object('description','Gross 64','quantity',1,'unit','kpl','price_basis','gross','unit_price_gross',64,'vat_rate',25.5),
      jsonb_build_object('description','Gross 3.50 x3','quantity',3,'unit','kpl','price_basis','gross','unit_price_gross',3.50,'vat_rate',13.5),
      jsonb_build_object('description','Net 100','quantity',1,'unit','kpl','price_basis','net','unit_price_net',100,'vat_rate',25.5),
      jsonb_build_object('description','Zero','quantity',1,'unit','kpl','price_basis','gross','unit_price_gross',10,'vat_rate',0),
      jsonb_build_object('description','Legacy net','quantity',2,'unit','kpl','unit_price_net',80,'vat_rate',25.5))));
  v_id := (inv ->> 'id')::bigint;
  perform public.t113_ck((select (l ->> 'line_gross')::numeric from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Gross 64') = 64.00, 'A1: 64,00 € @25,5 % verollinen summa');
  perform public.t113_ck((select (l ->> 'line_vat')::numeric from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Gross 64') = 13.00, 'A2: 64,00 € alv');
  perform public.t113_ck((select (l ->> 'line_net')::numeric from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Gross 64') = 51.00, 'A3: 64,00 € veroton');
  perform public.t113_ck((select (l ->> 'unit_price_net')::numeric from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Gross 64') = 51.0000, 'A4: johdettu veroton á-hinta');
  perform public.t113_ck((select l ->> 'price_basis' from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Gross 64') = 'gross', 'A5: peruste gross');
  perform public.t113_ck((select (l ->> 'line_gross')::numeric from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Gross 3.50 x3') = 10.50, 'B1: 3 × 3,50 €');
  perform public.t113_ck((select (l ->> 'line_vat')::numeric from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Gross 3.50 x3') = 1.25, 'B2: 13,5 % alv');
  perform public.t113_ck((select (l ->> 'line_net')::numeric from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Gross 3.50 x3') = 9.25, 'B3: veroton osuus');
  perform public.t113_ck((select (l ->> 'unit_price_net')::numeric from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Gross 3.50 x3') = 3.0833, 'B4: johdettu á-hinta');
  perform public.t113_ck((select (l ->> 'line_net')::numeric from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Net 100') = 100.00, 'C1: veroton 100,00');
  perform public.t113_ck((select (l ->> 'line_vat')::numeric from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Net 100') = 25.50, 'C2: alv 25,50');
  perform public.t113_ck((select (l ->> 'line_gross')::numeric from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Net 100') = 125.50, 'C3: verollinen 125,50');
  perform public.t113_ck((select l ->> 'price_basis' from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Net 100') = 'net', 'C4: peruste net');
  perform public.t113_ck((select (l ->> 'line_gross')::numeric from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Zero') = 10.00, 'D1: 0 % verollinen');
  perform public.t113_ck((select (l ->> 'line_vat')::numeric from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Zero') = 0.00, 'D2: 0 % alv');
  perform public.t113_ck((select (l ->> 'line_net')::numeric from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Zero') = 10.00, 'D3: 0 % veroton');
  perform public.t113_ck((select (l ->> 'line_gross')::numeric from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Legacy net') = 200.80, 'E1: vanha kutsu ilman perustetta');
  perform public.t113_ck((select l ->> 'price_basis' from jsonb_array_elements(inv -> 'lines') l where l ->> 'description' = 'Legacy net') = 'net', 'E2: puuttuva peruste on net');
  perform public.t113_ck((inv ->> 'total_gross')::numeric = 410.80, 'T1: laskun verollinen summa');
  perform public.t113_ck((inv ->> 'total_vat')::numeric = 80.55, 'T2: laskun alv');
  perform public.t113_ck((inv ->> 'total_net')::numeric = 330.25, 'T3: laskun veroton');
  perform public.t113_ck((select (g ->> 'gross')::numeric from jsonb_array_elements(inv -> 'vat_breakdown') g where (g ->> 'rate')::numeric = 25.5) = 390.30, 'T4: alv-erittely 25,5 %');
  perform public.t113_ck((select (g ->> 'vat')::numeric from jsonb_array_elements(inv -> 'vat_breakdown') g where (g ->> 'rate')::numeric = 13.5) = 1.25, 'T5: alv-erittely 13,5 %');
  perform public.t113_ck((select l ->> 'price_basis' from jsonb_array_elements(inv -> 'normalized' -> 'lines') l where l ->> 'description' = 'Gross 64') = 'gross', 'N1: normalisoitu peruste');
  perform public.t113_ck((select (l ->> 'unit_price_gross')::numeric from jsonb_array_elements(inv -> 'normalized' -> 'lines') l where l ->> 'description' = 'Gross 64') = 64, 'N2: normalisoitu verollinen á-hinta');
  bad := public.t113_call(format('select booking.admin_save_invoice(null, %L::jsonb)', jsonb_build_object(
    'customer_id', (cust ->> 'id')::bigint,
    'lines', jsonb_build_array(jsonb_build_object('description','X','quantity',1,'unit','kpl','price_basis','both','unit_price_net',1,'vat_rate',0)))::text));
  perform public.t113_ck(bad ->> 'err' = 'invalid_lines', 'X1: virheellinen peruste');
  perform public.t113_logout();

  perform public.t113_ck((select line_gross from booking.invoice_lines where invoice_id = v_id and description = 'Gross 64') = 64.00, 'S1: tallennettu verollinen summa');
  perform public.t113_ck((select price_basis from booking.invoice_lines where invoice_id = v_id and description = 'Gross 3.50 x3') = 'gross', 'S2: tallennettu peruste');
  insert into booking.invoices(customer_id, invoice_date, due_date, seller_snapshot, customer_snapshot)
  select customer_id, invoice_date, due_date, seller_snapshot, customer_snapshot from booking.invoices where id = v_id
  returning id into v_old;
  insert into booking.invoice_lines(invoice_id, line_no, description, quantity, unit, unit_price_net, vat_rate, line_net, line_vat, line_gross)
  values (v_old, 1, 'Vanha sentti', 1, 'kpl', 50.9960, 25.5, 51.00, 13.01, 64.01);
  perform public.t113_ck((select price_basis from booking.invoice_lines where invoice_id = v_old) = 'net', 'O1: vanha rivi jää net-perusteelle');
  perform public.t113_ck((select unit_price_gross from booking.invoice_lines where invoice_id = v_old) is null, 'O2: vanhalla rivillä ei verollista á-hintaa');
  perform public.t113_ck((select line_gross from booking.invoice_lines where invoice_id = v_old) = 64.01, 'O3: vanhaa rivisummaa ei lasketa uudelleen');

  v_seq := coalesce((select max(seq) from booking.invoices where series = 'L'), 0) + 1;
  update booking.invoices set status = 'sent', seq = v_seq, invoice_no = 'T113ZZ' || v_seq::text, reference_no = '00010', sent_at = now(), locked_at = now()
   where id = v_id;
  perform public.t113_login(u_mgr);
  credit := booking.admin_credit_invoice(v_id);
  perform public.t113_ck(credit ->> 'kind' = 'credit', 'H1: hyvitys');
  perform public.t113_ck((select (l ->> 'line_gross')::numeric from jsonb_array_elements(credit -> 'lines') l where l ->> 'description' = 'Gross 64') = -64.00, 'H2: hyvityksen verollinen summa');
  perform public.t113_ck((select l ->> 'price_basis' from jsonb_array_elements(credit -> 'lines') l where l ->> 'description' = 'Gross 64') = 'gross', 'H3: hyvitys kopioi perusteen');
  perform public.t113_ck((select (l ->> 'unit_price_gross')::numeric from jsonb_array_elements(credit -> 'lines') l where l ->> 'description' = 'Gross 64') = -64, 'H4: hyvitys kääntää verollisen á-hinnan');
  perform public.t113_ck((select (l ->> 'line_gross')::numeric from jsonb_array_elements(credit -> 'lines') l where l ->> 'description' = 'Legacy net') = -200.80, 'H5: vanha kaava hyvityksessä');
  perform public.t113_ck((credit ->> 'total_gross')::numeric = -410.80, 'H6: hyvityksen loppusumma');
  perform public.t113_logout();
  perform public.t113_ck((select line_gross from booking.invoice_lines where invoice_id = v_id and description = 'Gross 64') = 64.00, 'H7: alkuperäinen rivi ennallaan');
  perform public.t113_ck((select line_gross from booking.invoice_lines where invoice_id = v_old) = 64.01, 'O4: vanha rivi ennallaan hyvityksen jälkeen');
  v_counter := (select last_seq from booking.invoice_counters where series = 'L');
  perform public.t113_ck(v_counter = v_before, 'N0: laskurinumero ei kulunut');

  log := current_setting('t113.log', true);
  npass := (length(log) - length(replace(log, 'P ', ''))) / 2;
  nfail := (length(log) - length(replace(log, 'F ', ''))) / 2;
  raise exception 'TESTRESULT pass=% fail=%\n%', npass, nfail, log;
end $t$;
