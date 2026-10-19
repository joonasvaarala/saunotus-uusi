-- t112: laskutusasiakkaan haku ja Y-tunnuksen duplikaattisuoja (booking_112).
-- Rollback-transaktio: lopuksi tahallinen poikkeus. Ei tuotantodataa.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t112.log', '', true);
create function public.t112_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t112.log', coalesce(current_setting('t112.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t112_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 180) end;
end $$;
create function public.t112_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text; h text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text, s = returned_sqlstate, h = pg_exception_hint;
  return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 180) end, 'hint', h);
end $$;
create function public.t112_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t112_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_mgr uuid := gen_random_uuid();
  u_staff uuid := gen_random_uuid();
  cust jsonb; dup jsonb; named jsonb; again jsonb; inv jsonb; booked jsonb; def text;
  o1 bigint; o2 bigint; v_book bigint;
  log text; npass int; nfail int;
begin
  perform public.t112_ck(not has_function_privilege('anon', 'booking.admin_search_invoice_customers(text,integer)', 'execute'), 'G1: anonilta ei hakua');
  perform public.t112_ck(has_function_privilege('authenticated', 'booking.admin_search_invoice_customers(text,integer)', 'execute'), 'G2: authenticated saa haun');
  perform public.t112_ck(has_function_privilege('service_role', 'booking.admin_search_invoice_customers(text,integer)', 'execute'), 'G3: service_role saa haun');
  perform public.t112_ck(not has_function_privilege('anon', 'booking._invoice_customer_clean(jsonb)', 'execute'), 'G4: anonilta ei siivousta');
  perform public.t112_ck(not has_function_privilege('authenticated', 'booking._err_hint(text,text,text)', 'execute'), 'G5: authenticated ei saa sisäistä virhettä');
  def := pg_get_functiondef('booking.admin_search_invoice_customers(text,integer)'::regprocedure);
  perform public.t112_ck(position('SECURITY DEFINER' in def) > 0, 'G6: haku on security definer');
  perform public.t112_ck(position('search_path' in def) > 0 and position('invoices.manage' in def) > 0, 'G7: search_path ja invoices.manage');
  def := pg_get_functiondef('booking.admin_save_invoice_customer(bigint,jsonb)'::regprocedure);
  perform public.t112_ck(position('customer_exists' in def) > 0 and position('SECURITY DEFINER' in def) > 0, 'G8: tallennus tunnistaa customer_exists');

  insert into booking.customers(name, email, phone, company, address, zip, city, customer_kind, business_id)
  values ('Liisa Lasku', 'liisa@t112.test', '0401234567', 'Havu Testi Zz', 'Koivukuja 2', '01300', 'Vantaa', 'company', '1000000-4')
  returning id into v_book;
  insert into auth.users(id, email) values (u_mgr, 't112-mgr@example.test'), (u_staff, 't112-staff@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_mgr, 't112-mgr@example.test', 't112 manager', 'manager'),
    (u_staff, 't112-staff@example.test', 't112 staff', 'staff');

  perform public.t112_login(u_staff);
  perform public.t112_ck(public.t112_try($$select booking.admin_search_invoice_customers('havu')$$) = 'forbidden', 'P1: työntekijällä ei invoices.manage');
  perform public.t112_logout();

  perform public.t112_login(u_mgr);
  perform public.t112_ck(jsonb_array_length(booking.admin_search_invoice_customers('a')) = 0, 'H0: alle kaksi merkkiä ei hae');
  cust := booking.admin_save_invoice_customer(null, '{"company_name":"Havu Testi Oy","business_id":"0112038-9","email":"lasku@example.test","street":"Vanha 1"}'::jsonb);
  perform public.t112_ck(cust ->> 'business_id' = '0112038-9', 'C1: y-tunnus normalisoitu');
  perform public.t112_ck((booking.admin_search_invoice_customers('HAVU') -> 0 ->> 'company_name') = 'Havu Testi Oy', 'H1: kirjainkoosta riippumaton nimi');
  perform public.t112_ck(jsonb_array_length(booking.admin_search_invoice_customers('testi o')) = 1, 'H2: osittainen nimi');
  perform public.t112_ck(jsonb_array_length(booking.admin_search_invoice_customers('01120389')) = 1, 'H3: y-tunnus ilman viivaa');
  perform public.t112_ck((booking.admin_search_invoice_customers('Havu Testi Zz') -> 0 ->> 'source') = 'booking', 'B1: varausasiakas');
  perform public.t112_ck(jsonb_exists(booking.admin_search_invoice_customers('Havu Testi Zz') -> 0, 'marketing_consent') = false, 'B2: ei markkinointisuostumusta');
  perform public.t112_ck((booking.admin_search_invoice_customers('Havu Testi Zz') -> 0 ->> 'company_name') = 'Havu Testi Zz', 'B3: yrityksen nimi');
  perform public.t112_ck((booking.admin_search_invoice_customers('Havu Testi Zz') -> 0 ->> 'contact_name') = 'Liisa Lasku', 'B4: yhteyshenkilö');
  perform public.t112_ck((booking.admin_search_invoice_customers('Havu Testi Zz') -> 0 ->> 'phone') = '0401234567', 'B5: puhelin');
  perform public.t112_ck((booking.admin_search_invoice_customers('Havu Testi Zz') -> 0 ->> 'street') = 'Koivukuja 2', 'B6: osoite');
  perform public.t112_ck((booking.admin_search_invoice_customers('Havu Testi Zz') -> 0 ->> 'business_id') = '1000000-4', 'B7: y-tunnus');
  perform public.t112_ck((booking.admin_search_invoice_customers('Havu Testi') -> 0 ->> 'source') = 'invoice', 'B8: laskutusasiakas ennen varausasiakasta');
  perform public.t112_ck(jsonb_array_length(booking.admin_search_invoice_customers('Havu Testi', 1)) = 1, 'B9: tulosmäärä rajattu');
  dup := public.t112_call($$select booking.admin_save_invoice_customer(null, '{"company_name":"Toinen Oy","business_id":"FI01120389","email":"toinen@example.test"}'::jsonb)$$);
  perform public.t112_ck(dup ->> 'err' = 'customer_exists', 'D1: customer_exists');
  perform public.t112_ck((dup ->> 'hint')::jsonb ->> 'id' = cust ->> 'id', 'D2: virheessä on olemassa oleva asiakas');
  perform public.t112_logout();
  perform public.t112_ck((select count(*) from booking.invoice_customers where booking._norm_business_id(business_id) = '0112038-9') = 1, 'D3: toista riviä ei syntynyt');
  perform public.t112_ck(public.t112_try($$insert into booking.invoice_customers(company_name, business_id) values ('Duplikaatti Oy', '0112038-9')$$) like '23505%', 'D4: unique-indeksi estää saman Y-tunnuksen');
  perform public.t112_login(u_mgr);

  named := booking.admin_save_invoice_customer(null, '{"company_name":"Matti Meikäläinen","email":"matti@example.test"}'::jsonb);
  again := public.t112_call($$select booking.admin_save_invoice_customer(null, '{"company_name":"matti meikäläinen","email":"MATTI@example.test"}'::jsonb)$$);
  perform public.t112_ck(again ->> 'err' = 'name_email_match', 'N1: sama nimi ja sähköposti varoitetaan');
  again := booking.admin_save_invoice_customer(null, '{"company_name":"Matti Meikäläinen","email":"matti@example.test","ack_name_email":true}'::jsonb);
  perform public.t112_ck(again ->> 'id' is distinct from named ->> 'id', 'N2: vahvistus sallii uuden yksityisasiakkaan');

  inv := booking.admin_save_invoice(null, jsonb_build_object(
    'customer_id', (cust ->> 'id')::bigint,
    'snapshot_mode', 'invoice',
    'customer_override', '{"company_name":"Havu Testi Oy","business_id":"0112038-9","street":"Uusi katu 2","einvoice_address":"003701120389","einvoice_operator":"003723327487"}'::jsonb,
    'lines', jsonb_build_array(jsonb_build_object('description','Saunavuoro','quantity',1,'unit','kpl','unit_price_net',10,'vat_rate',25.5))));
  perform public.t112_ck(inv -> 'customer_snapshot' ->> 'street' = 'Uusi katu 2', 'S1: laskun kuva on lomakkeen osoite');
  perform public.t112_ck((inv ->> 'customer_snapshot_locked')::boolean, 'S2: kuva on lukittu laskuun');
  perform public.t112_logout();
  perform public.t112_ck((select street from booking.invoice_customers where id = (cust ->> 'id')::bigint) = 'Vanha 1', 'S3: rekisteriä ei päivitetty');
  perform public.t112_login(u_mgr);
  inv := booking.admin_send_invoice((inv ->> 'id')::bigint, true, false);
  perform public.t112_ck(inv -> 'customer_snapshot' ->> 'street' = 'Uusi katu 2', 'S4: lähetys säilyttää laskun kuvan');
  booked := booking.admin_save_invoice_customer(null, jsonb_build_object(
    'company_name', 'Havu Testi Zz', 'contact_name', 'Liisa Lasku', 'business_id', '1000000-4',
    'email', 'liisa@t112.test', 'phone', '0401234567', 'street', 'Koivukuja 2', 'zip', '01300', 'city', 'Vantaa',
    'customer_id', v_book));
  perform public.t112_ck(booked ->> 'business_id' = '1000000-4', 'B10: varausasiakkaasta syntyi laskutusasiakas');
  perform public.t112_ck(booked ->> 'customer_id' = v_book::text, 'B11: linkki varausasiakkaaseen');
  again := public.t112_call($$select booking.admin_save_invoice_customer(null, '{"company_name":"Havu Testi Uusi","business_id":"1000000-4","email":"uusi@t112.test"}'::jsonb)$$);
  perform public.t112_ck(again ->> 'err' = 'customer_exists' and (again ->> 'hint')::jsonb ->> 'id' = booked ->> 'id', 'B12: sama y-tunnus palauttaa olemassa olevan');
  perform public.t112_ck((select count(*) from jsonb_array_elements(booking.admin_search_invoice_customers('Havu Testi Zz')) e where e ->> 'source' = 'booking') = 0, 'B13: samaa y-tunnusta ei ehdoteta kahdesti');
  perform public.t112_logout();
  perform public.t112_ck((select marketing_consent from booking.customers where email = 'liisa@t112.test') = false, 'B14: markkinointisuostumus ennallaan');

  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale, customer_kind, billing)
  values (991121, 'confirmed', 'paid', 50, 'EUR', 'web', 'fi', 'company',
          '{"company":"Uusi Kerta Oy","business_id":"1234567-1","street":"Katu 1","zip":"00100","city":"Helsinki"}'::jsonb)
  returning id into o1;
  insert into booking.order_items(order_id, product_name, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o1, 'Vuoro', 1, 50, 50, 25.5);
  insert into booking.payments(order_id, method, provider, status, amount) values (o1, 'invoice', 'manual', 'pending', 50);
  update booking.orders set payment_status = 'unpaid' where id = o1;
  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale, customer_kind, billing)
  values (991122, 'confirmed', 'paid', 60, 'EUR', 'web', 'fi', 'company',
          '{"company":"Uusi Kerta Oy","business_id":"FI12345671","street":"Katu 9","zip":"00100","city":"Helsinki"}'::jsonb)
  returning id into o2;
  insert into booking.order_items(order_id, product_name, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o2, 'Vuoro', 1, 60, 60, 25.5);
  insert into booking.payments(order_id, method, provider, status, amount) values (o2, 'invoice', 'manual', 'pending', 60);
  update booking.orders set payment_status = 'unpaid' where id = o2;
  perform public.t112_ck((select count(*) from booking.invoice_customers where booking._norm_business_id(business_id) = '1234567-1') = 1, 'R1: toinen tilaus käyttää samaa asiakasta');
  perform public.t112_ck((select count(*) from booking.invoices where order_id in (o1, o2) and status = 'draft') = 2, 'R2: molemmille tilauksille syntyi luonnos');

  log := current_setting('t112.log', true);
  npass := (length(log) - length(replace(log, 'P ', ''))) / 2;
  nfail := (length(log) - length(replace(log, 'F ', ''))) / 2;
  raise exception 'TESTRESULT pass=% fail=%\n%', npass, nfail, log;
end $t$;
