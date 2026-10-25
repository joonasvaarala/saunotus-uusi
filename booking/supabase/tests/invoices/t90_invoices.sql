-- t90: laskutus (booking_90–93). Rollback-transaktio: lopuksi tahallinen poikkeus.
-- Ajaa Bottiavustus (psql). Ei tuotantodataa: kaikki perutaan.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t90.log', '', true);
create function public.t90_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t90.log', coalesce(current_setting('t90.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t90_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 180) end;
end $$;
create function public.t90_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 180) end);
end $$;
create function public.t90_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t90_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_mgr uuid := gen_random_uuid();
  u_staff uuid := gen_random_uuid();
  o_id bigint; inv jsonb; inv2 jsonb; credit jsonb; disc jsonb; n1 text; n2 text; claim text; draftfn text;
  log text; npass int; nfail int;
begin
  perform public.t90_ck(booking._fi_reference('123456') = '1234561', 'R1: viite 123456 → 1234561');
  perform public.t90_ck(booking._fi_reference('1') = '0013', 'R2: lyhyt pohja täytetään kolmeen');
  perform public.t90_ck(booking._ovt_ok('003701120389', '0112038-9'), 'R3: OVT vastaa y-tunnusta');
  perform public.t90_ck(not booking._ovt_ok('003700000000', '0112038-9'), 'R4: väärä OVT hylätään');
  perform public.t90_ck(booking._clean_company('{"company_name":"Testi Oy","business_id":"0112038-9","street":"Katu 1","zip":"00100","city":"Helsinki"}'::jsonb) ->> 'business_id' = '0112038-9', 'C1: ilman lippua verkkolasku on yhä valinnainen');
  perform public.t90_ck(public.t90_try($s$select booking._clean_company('{"company_name":"Testi Oy","business_id":"0112038-9","street":"Katu 1","zip":"00100","city":"Helsinki","require_einvoice":true}'::jsonb)$s$) = 'einvoice_incomplete', 'C2: kauppa vaatii OVT:n');
  perform public.t90_ck(booking._clean_company('{"company_name":"Testi Oy","business_id":"0112038-9","street":"Katu 1","zip":"00100","city":"Helsinki","einvoice_address":"003701120389","einvoice_operator":"003723327487","require_einvoice":true,"reference":"PO-1"}'::jsonb) ->> 'einvoice_address' = '003701120389', 'C3: kelvollinen OVT hyväksytään');
  claim := pg_get_functiondef('booking.email_outbox_claim(integer)'::regprocedure);
  perform public.t90_ck(position('reply_to' in claim) > 0, 'E1: claim sisältää reply_to');
  perform public.t90_ck(position('business_quote_requests' in claim) > 0, 'E2: claim liittyy business_quote_requests');
  perform public.t90_ck(position('''invoice''' in claim) > 0, 'E3: claim sisältää invoice-lohkon');
  draftfn := pg_get_functiondef('booking.orders_invoice_draft_trg()'::regprocedure);
  perform public.t90_ck(position('raise warning' in draftfn) > 0, 'E4: luonnoksen virhe kirjataan varoituksena');
  perform public.t90_ck(position('audit_log' in draftfn) > 0, 'E5: luonnoksen virhe menee audit-lokiin');

  perform public.t90_ck(not has_function_privilege('anon', 'booking.admin_list_invoices(text,text,text,date,date,integer,integer)', 'execute'), 'G1: anonilta ei listaa');
  perform public.t90_ck(not has_function_privilege('anon', 'booking.admin_send_invoice(bigint,boolean,boolean)', 'execute'), 'G2: anonilta ei lähetystä');
  perform public.t90_ck(has_function_privilege('authenticated', 'booking.admin_save_invoice(bigint,jsonb)', 'execute'), 'G3: authenticated saa hallinnan RPC:n');
  perform public.t90_ck(has_function_privilege('service_role', 'booking.invoice_dispatch_claim(integer)', 'execute'), 'G4: service_role saa jonon');
  perform public.t90_ck(not has_function_privilege('authenticated', 'booking.invoice_dispatch_claim(integer)', 'execute'), 'G5: authenticated ei saa jonoa');

  insert into auth.users(id, email) values (u_mgr, 't90-mgr@example.test'), (u_staff, 't90-staff@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_mgr, 't90-mgr@example.test', 't90 manager', 'manager'),
    (u_staff, 't90-staff@example.test', 't90 staff', 'staff');

  perform public.t90_login(u_staff);
  perform public.t90_ck(public.t90_try('select booking.admin_list_invoices()') = 'forbidden', 'P1: työntekijällä ei invoices.manage');
  perform public.t90_logout();

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale, customer_kind, billing)
  values (990901, 'confirmed', 'paid', 124, 'EUR', 'web', 'fi', 'company',
          '{"company":"Havuhattu Testi Oy","business_id":"0112038-9","street":"Hindsbyntie 124","zip":"04130","city":"Sipoo","country":"FI","einvoice_address":"003701120389","einvoice_operator":"003723327487"}'::jsonb)
  returning id into o_id;
  insert into booking.order_items(order_id, product_name, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_id, 'Yksityinen vuoro', 1, 124, 124, 25.5);
  insert into booking.payments(order_id, method, provider, status, amount) values (o_id, 'invoice', 'manual', 'pending', 124);
  update booking.orders set payment_status = 'unpaid' where id = o_id;
  perform public.t90_ck((select payment_status from booking.orders where id = o_id) = 'invoiced', 'K1: yritystilaus on invoiced, ei paid');
  perform public.t90_ck((select count(*) from booking.invoices where order_id = o_id and status = 'draft') = 1, 'K2: luonnoslasku syntyi');
  perform public.t90_ck((select count(*) from booking.invoices i join booking.invoice_lines l on l.invoice_id = i.id where i.order_id = o_id) = 1, 'K3: tilausrivi siirtyi laskulle');

  perform public.t90_login(u_mgr);
  perform public.t90_ck((booking.admin_list_orders(p_search => '990901') ->> 'total')::int = 0, 'F1: oletus paid ei palauta laskutettua');
  perform public.t90_ck((booking.admin_list_orders(p_search => '990901', p_payment_filter => 'invoiced') ->> 'total')::int = 1, 'F2: suodatin invoiced löytää tilauksen');
  perform public.t90_ck(public.t90_try('select booking.admin_list_orders(p_payment_filter => ''nope'')') = 'invalid_param', 'F3: tuntematon suodatin');

  inv := booking.admin_get_invoice((select id from booking.invoices where order_id = o_id));
  perform public.t90_ck(inv -> 'normalized' -> 'customer' ->> 'name' = 'Havuhattu Testi Oy', 'N1: normalisoidun JSON:n customer.name');
  perform public.t90_ck(inv -> 'normalized' -> 'customer' ->> 'einvoice_address' = '003701120389', 'N2: OVT normalisoidussa JSON:ssa');
  perform public.t90_ck(jsonb_typeof(inv -> 'normalized' -> 'lines') = 'array', 'N3: lines-taulukko');

  inv := booking.admin_send_invoice((inv ->> 'id')::bigint, true, false);
  n1 := inv ->> 'invoice_no';
  perform public.t90_ck(n1 = 'L000001', 'S1: ensimmäinen numero L000001');
  perform public.t90_ck(inv ->> 'reference_no' = '731010', 'S2: viite = etuliite 7310 + numero 1 + tarkiste 7-3-1 (booking_175)');
  perform public.t90_ck(inv ->> 'status' = 'sent', 'S3: tila sent');
  perform public.t90_ck(inv ->> 'dispatch_status' = 'dry_run', 'S4: ilman Procountoria dry_run');
  perform public.t90_ck((select count(*) from booking.invoice_dispatch_log d where d.invoice_id = (inv ->> 'id')::bigint) = 1, 'S5: lähetysloki');
  inv := booking.admin_mark_invoice_paid((inv ->> 'id')::bigint);
  perform public.t90_ck(inv ->> 'status' = 'paid', 'M1: lasku merkitty maksetuksi');
  perform public.t90_ck((select payment_status from booking.orders where id = o_id) = 'paid', 'M2: tilauksen maksutila on paid');
  perform public.t90_ck(exists (select 1 from booking.receipts rc join booking.payments p on p.id = rc.payment_id where p.order_id = o_id and p.method = 'invoice' and rc.kind = 'receipt'), 'M3: kuitti syntyi');
  perform public.t90_ck((booking.admin_list_orders(p_search => '990901', p_payment_filter => 'paid') ->> 'total')::int = 1, 'M4: maksetut-suodatin löytää tilauksen');
  perform public.t90_logout();
  perform public.t90_ck(public.t90_try(format('update booking.invoice_lines set description = %L where invoice_id = %s', 'muutos', inv ->> 'id')) = 'invoice_locked', 'S6: rivit lukossa lähetyksen jälkeen');
  perform public.t90_login(u_mgr);

  credit := booking.admin_credit_invoice((inv ->> 'id')::bigint);
  perform public.t90_ck(credit ->> 'kind' = 'credit' and credit ->> 'status' = 'draft' and (credit ->> 'total_gross')::numeric < 0, 'H1: hyvitysluonnos, negatiivinen summa');
  credit := booking.admin_send_invoice((credit ->> 'id')::bigint, true, false);
  n2 := credit ->> 'invoice_no';
  perform public.t90_ck(n2 = 'L000002', 'H2: seuraava numero ilman aukkoa');
  perform public.t90_ck((select status from booking.invoices where id = (inv ->> 'id')::bigint) = 'credited', 'H3: alkuperäinen merkitty hyvitetyksi');
  perform public.t90_ck(public.t90_try(format('select booking.admin_mark_invoice_paid(%s)', credit ->> 'id')) = 'invalid_status', 'H4: hyvityslaskua ei merkitä maksetuksi');

  inv2 := booking.admin_save_invoice_customer(null, '{"company_name":"Vapaa Oy","business_id":"1234567-1","email":"lasku@example.test"}'::jsonb);
  inv2 := booking.admin_save_invoice(null, jsonb_build_object('customer_id', (inv2 ->> 'id')::bigint, 'lines', jsonb_build_array(jsonb_build_object('description','Saunavuoro','quantity',2,'unit','kpl','unit_price_net',10,'vat_rate',25.5))));
  perform public.t90_ck(inv2 ->> 'status' = 'draft' and inv2 ->> 'invoice_no' is null, 'V1: itse tehty lasku on luonnos ilman numeroa');
  perform public.t90_ck(public.t90_try(format('select booking.admin_void_invoice(%s)', inv2 ->> 'id')) = 'ok', 'V2: luonnos mitätöidään');
  disc := booking.admin_save_invoice_customer(null, '{"company_name":"Alennus Oy","business_id":"2336509-6","email":"alennus@example.test","einvoice_address":"003723365096","einvoice_operator":"003723327487"}'::jsonb);
  disc := booking.admin_save_invoice(null, jsonb_build_object('customer_id', (disc ->> 'id')::bigint, 'lines', jsonb_build_array(
    jsonb_build_object('description','Saunavuoro','quantity',1,'unit','kpl','unit_price_net',100,'vat_rate',25.5),
    jsonb_build_object('description','Alennus','quantity',1,'unit','kpl','unit_price_net',-10,'vat_rate',25.5))));
  disc := booking.admin_send_invoice((disc ->> 'id')::bigint, true, false);
  disc := booking.admin_credit_invoice((disc ->> 'id')::bigint);
  perform public.t90_ck((select (l ->> 'quantity')::numeric from jsonb_array_elements(disc -> 'lines') l where l ->> 'description' = 'Alennus') = 1, 'D1: alennusrivin määrä säilyy');
  perform public.t90_ck((select (l ->> 'unit_price_net')::numeric from jsonb_array_elements(disc -> 'lines') l where l ->> 'description' = 'Alennus') = 10, 'D2: alennusrivin hinta on vastaluku');
  perform public.t90_ck((select (l ->> 'line_gross')::numeric from jsonb_array_elements(disc -> 'lines') l where l ->> 'description' = 'Alennus') > 0, 'D3: alennuksen hyvitysrivi on positiivinen');
  perform public.t90_logout();

  log := current_setting('t90.log', true);
  npass := (length(log) - length(replace(log, 'P ', ''))) / 2;
  nfail := (length(log) - length(replace(log, 'F ', ''))) / 2;
  raise exception 'TESTRESULT pass=% fail=%\n%', npass, nfail, log;
end $t$;
