-- t117: lahjakortin ALV (booking_117), kirjanpitoraportit (booking_118), kuitti ja käteinen (booking_119).
-- Rollback-transaktio: lopuksi tahallinen poikkeus. Ei tuotantoa.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t117.log', '', true);
create function public.t117_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t117.log', coalesce(current_setting('t117.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t117_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 160) end;
end $$;
create function public.t117_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 160) end);
end $$;
create function public.t117_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t117_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_mgr uuid := gen_random_uuid();
  u_staff uuid := gen_random_uuid();
  res jsonb; rep jsonb; tx jsonb; gc jsonb; csv text;
  o_nat bigint; p_nat bigint; o_open bigint; c_open bigint; o_johku bigint; p_cash bigint;
  v_card bigint; v_comp bigint; v_code text; v_pay bigint; o_mix bigint; o_free bigint; o_k bigint; v_rate numeric; v_text text; v_out int; v_k int; v_l int; v_year int;
  log text; npass int; nfail int;
begin
  perform public.t117_ck((select count(*) from booking.gift_card_packages where vat_treatment <> 'at_sale' or vat_rate <> 25.5) = 0, 'V1: kaikki omat paketit at_sale 25,5');
  perform public.t117_ck((select vat_treatment from booking.gift_card_packages where code = 'open') = 'at_sale', 'V2: avoin paketti at_sale');
  perform public.t117_ck(public.t117_try($q$update booking.gift_card_packages set vat_treatment = 'at_redemption' where code = 'open'$q$) = 'gift_card_vat_rate', 'V3: at_redemption kielletty');
  perform public.t117_ck((select active from booking.payment_methods where code = 'cash') = false, 'C1: käteinen ei ole aktiivinen');
  perform public.t117_ck((select is_manual from booking.payment_methods where code = 'cash') = false, 'C2: käteinen ei ole käsin kirjattava');
  perform public.t117_ck(not has_function_privilege('anon', 'booking.admin_report_range(date,date)', 'execute'), 'G1: anonilta ei rangea');
  perform public.t117_ck(not has_function_privilege('anon', 'booking.admin_report_gift_cards(text,text,date,date)', 'execute'), 'G2: anonilta ei lahjakorttiraporttia');
  perform public.t117_ck(not has_function_privilege('anon', 'booking._receipt_text(jsonb)', 'execute') and not has_function_privilege('authenticated', 'booking._receipt_text(jsonb)', 'execute'), 'G5: anon ja authenticated eivät saa tekstikuittia');
  perform public.t117_ck(has_function_privilege('service_role', 'booking._receipt_text(jsonb)', 'execute'), 'G6: service_role saa tekstikuitin');

  insert into auth.users(id, email) values (u_mgr, 't117-mgr@example.test'), (u_staff, 't117-staff@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_mgr, 't117-mgr@example.test', 't117 manager', 'manager'),
    (u_staff, 't117-staff@example.test', 't117 staff', 'staff');

  perform public.t117_login(u_staff);
  perform public.t117_ck(public.t117_try($q$select booking.admin_report_range('2032-06-01'::date, '2032-06-30'::date)$q$) = 'forbidden', 'G3: staff ilman reports.view');
  perform public.t117_logout();

  perform public.t117_login(u_mgr);
  res := public.t117_call($q$booking.admin_create_gift_card('open', 40, 1, null, null, null, null, null, null, null, 'fi', 'Hyvitys testi')$q$);
  v_comp := (res -> 'cards' -> 0 ->> 'id')::bigint;
  perform public.t117_ck(res ->> 'complimentary' = 'true' and res -> 'cards' -> 0 ->> 'complimentary' = 'true' and res -> 'cards' -> 0 ->> 'vat_treatment' = 'at_sale' and (res -> 'cards' -> 0 ->> 'sale_vat_rate')::numeric = 0, 'V4: maksuton ei veroa: ' || coalesce(res ->> 'err', res -> 'cards' -> 0 ->> 'sale_vat_rate', 'null'));
  res := public.t117_call($q$booking.admin_create_gift_card('open', 41, 1, null, null, null, null, null, 'at_redemption', null, 'fi', 'Hyvitys toinen')$q$);
  perform public.t117_ck(res ->> 'err' = 'gift_card_vat_rate', 'V5: maksuton at_redemption kielletty: ' || coalesce(res ->> 'err', 'ok'));
  res := public.t117_call($q$booking.admin_create_gift_card('entry_2', null, 1, '{"name":"Ada","email":"ada@example.test"}'::jsonb, null, null, null, 'card_terminal', 'at_redemption')$q$);
  perform public.t117_ck(res ->> 'err' = 'gift_card_vat_rate', 'V6: maksettu at_redemption kielletty: ' || coalesce(res ->> 'err', 'ok'));
  res := public.t117_call($q$booking.admin_create_gift_card('entry_2', null, 1, '{"name":"Ada","email":"ada@example.test"}'::jsonb, null, null, null, 'card_terminal')$q$);
  perform public.t117_ck(res ->> 'paid' = 'true' and res -> 'cards' -> 0 ->> 'vat_treatment' = 'at_sale' and (res -> 'cards' -> 0 ->> 'sale_vat_rate')::numeric = 25.5 and res -> 'cards' -> 0 ->> 'complimentary' = 'false', 'V7: maksettu kortti at_sale 25,5: ' || coalesce(res ->> 'err', res -> 'cards' -> 0 ->> 'vat_treatment', 'null'));
  v_card := (res -> 'cards' -> 0 ->> 'id')::bigint;
  select i.vat_rate into v_rate from booking.order_items i join booking.gift_cards g on g.purchase_order_id = i.order_id where g.id = v_card and i.kind = 'gift_card';
  perform public.t117_ck(v_rate = 0, 'V8: myyntirivin ALV 0, monikäyttöinen arvoseteli');
  perform public.t117_ck(public.t117_try(format('select booking.admin_record_payment(%s, ''cash'', 1, ''ei'')', (res ->> 'order_id')::bigint)) = 'cash_not_accepted', 'C3: käteinen hylätään');
  perform public.t117_logout();

  insert into booking.customers(name, email) values ('Avoin Asiakas', 'avoin-t117@example.test') returning id into c_open;
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values (c_open, 'confirmed', 'unpaid', 36, 'admin', 'fi', '2032-06-15 10:00:00+00') returning id into o_open;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_open, 't117 avoin vuoro', 'reservation', 2, 18, 36, 25.5);

  insert into booking.orders(status, payment_status, total_gross, currency, source_channel, locale)
  values ('confirmed', 'paid', 30.03, 'EUR', 'admin', 'fi') returning id into o_nat;
  -- Suora snapshot-kuitti: maksutriggeri tekisi toisen kuitin tämän päivän päiväyksellä.
  alter table booking.payments disable trigger payments_paid_ins;
  alter table booking.payments disable trigger payments_paid_upd;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at)
  values (o_nat, 'card_terminal', 'manual', 'paid', 30.03, '2032-06-15 11:00:00+00') returning id into p_nat;
  insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, issued_at, total_gross, snapshot, text_body)
  values ('K-2032-T117-1', 'receipt', 'T117', 2032, 1, o_nat, p_nat, '2032-06-15 11:00:00+00', 30.03,
          jsonb_build_object('total_net', 23.93, 'total_vat', 6.10, 'total_gross', 30.03, 'rounding', 0,
            'payment', jsonb_build_object('method', 'card_terminal', 'method_label', 'Korttipääte'),
            'lines', jsonb_build_array(
              jsonb_build_object('description', 't117 pyöristys', 'quantity', 1, 'line_gross', 10.01, 'line_net', 7.98, 'vat_rate', 25.5),
              jsonb_build_object('description', 't117 pyöristys', 'quantity', 1, 'line_gross', 10.01, 'line_net', 7.98, 'vat_rate', 25.5),
              jsonb_build_object('description', 't117 pyöristys', 'quantity', 1, 'line_gross', 10.01, 'line_net', 7.98, 'vat_rate', 25.5)),
            'vat', jsonb_build_array(jsonb_build_object('rate', 25.5, 'net', 23.93, 'vat', 6.10, 'gross', 30.03))),
          't117');
  alter table booking.payments enable trigger payments_paid_ins;
  alter table booking.payments enable trigger payments_paid_upd;

  insert into booking.orders(status, payment_status, total_gross, currency, source_channel, locale, external_source, external_id, johku_order_no, external_meta)
  values ('confirmed', 'paid', 50, 'EUR', 'johku_import', 'fi', 'johku', 't117-j', 881170,
          jsonb_build_object('johku', jsonb_build_object('paid', true, 'amount', '50', 'paid_at', '2032-06-15T12:00:00+00', 'payment_method', 'mobilepay')))
  returning id into o_johku;

  insert into booking.gift_cards(code, issuer, source, accounting_origin, vat_treatment, sale_vat_rate, initial_amount, balance, status, buyer_name, activated_at, valid_to)
  values ('JK117000AB12', 'johku', 'johku', 'johku', 'at_sale', 25.5, 50, 50, 'active', 'Johku Ostaja', '2032-01-01 10:00:00+00', '2033-01-01');

  update booking.settings set value = 'true'::jsonb where key = 'gift_cards.redeem_enabled';
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values (c_open, 'confirmed', 'unpaid', 56, 'admin', 'fi', '2032-06-15 09:00:00+00') returning id into o_mix;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_mix, 't117 yleinen', 'reservation', 1, 36, 36, 25.5),
         (o_mix, 't117 alennettu', 'reservation', 1, 20, 20, 13.5);
  select code into v_code from booking.gift_cards where id = v_card;

  v_year := booking._receipt_year(now());
  v_k := coalesce((select last_seq from booking.receipt_counters where series = 'K' and year = v_year), 0);
  v_l := coalesce((select last_seq from booking.receipt_counters where series = 'G' and year = v_year), 0);
  perform public.t117_login(u_mgr);
  res := public.t117_call(format($q$booking.admin_redeem_gift_card(%s, %L, 20, 'juoma')$q$, o_mix, v_code));
  perform public.t117_ck(res ->> 'err' is null and res ->> 'accounted' = 'true', 'V9: 13,5 % sallittu: ' || coalesce(res ->> 'err', res ->> 'receipt_no', 'null'));
  res := public.t117_call(format($q$booking.admin_redeem_gift_card(%s, %L, 36, 'vain yleinen')$q$, o_mix, v_code));
  v_pay := (res ->> 'payment_id')::bigint;
  perform public.t117_ck(res ->> 'accounted' = 'true' and res ->> 'receipt_no' like 'K-%', 'V10: lunastus on myyntikuitti: ' || coalesce(res ->> 'err', res ->> 'receipt_no', 'null'));
  perform public.t117_ck(res ->> 'receipt_no' = format('K-%s-%s', v_year, lpad((v_k + 2)::text, 6, '0')), 'V10b: toinen lunastus on seuraava K: ' || coalesce(res ->> 'receipt_no', res ->> 'err', 'null'));
  perform public.t117_logout();
  perform public.t117_ck((select series from booking.receipts where payment_id = v_pay) = 'K', 'V10c: kuitin sarja on K');
  perform public.t117_ck(coalesce((select last_seq from booking.receipt_counters where series = 'K' and year = v_year), 0) = v_k + 2, 'V10d: K-laskuri kasvaa lunastuksista');
  update booking.payments set paid_at = '2032-06-15 12:30:00+00' where order_id = o_mix and method = 'gift_card';
  alter table booking.receipts disable trigger receipts_guard;
  update booking.receipts set issued_at = '2032-06-15 12:30:00+00' where order_id = o_mix and kind = 'receipt';
  alter table booking.receipts enable trigger receipts_guard;
  select count(*) into v_out from booking.accounting_outbox where payment_id = v_pay;
  perform public.t117_ck((select coalesce((snapshot ->> 'informational')::boolean, false) from booking.receipts where payment_id = v_pay) = false, 'V12: lunastuskuitti on kirjanpitoa');
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale)
  values (c_open, 'confirmed', 'unpaid', 10, 'admin', 'fi') returning id into o_k;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_k, 't117 k-sarja', 'reservation', 1, 10, 10, 25.5);
  perform public.t117_login(u_mgr);
  res := public.t117_call(format($q$booking.admin_record_payment(%s, 'card_terminal', 10, 'k-aukko')$q$, o_k));
  perform public.t117_logout();
  perform public.t117_ck(res ->> 'receipt_no' = format('K-%s-%s', v_year, lpad((v_k + 3)::text, 6, '0')), 'V10e: korttimaksu on lunastusten jälkeinen K: ' || coalesce(res ->> 'receipt_no', res ->> 'err', 'null'));
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values (c_open, 'confirmed', 'unpaid', 36, 'admin', 'fi', '2032-06-15 09:30:00+00') returning id into o_free;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_free, 't117 maksuton', 'reservation', 1, 36, 36, 25.5);
  select code into v_code from booking.gift_cards where id = v_comp;
  perform public.t117_login(u_mgr);
  res := public.t117_call(format($q$booking.admin_redeem_gift_card(%s, %L, 36, 'maksuton')$q$, o_free, v_code));
  perform public.t117_ck(res ->> 'accounted' = 'false' and res ->> 'receipt_no' is null, 'V13: maksuton lunastus ei luo kuittia: ' || coalesce(res ->> 'err', res ->> 'receipt_no', 'null'));
  perform public.t117_logout();

  perform public.t117_login(u_mgr);
  rep := public.t117_call($q$booking.admin_report_range('2032-06-01'::date, '2032-06-30'::date)$q$);
  perform public.t117_ck(rep -> 'period' ->> 'kind' = 'range', 'R1: aikavälin tyyppi');
  perform public.t117_ck((rep -> 'reconciliation' ->> 'vat_rounding')::numeric = 0.01, 'R2: rivin ja kuitin ALV-erotus 0,01: ' || coalesce(rep -> 'reconciliation' ->> 'vat_rounding', rep ->> 'err', 'null'));
  perform public.t117_ck(rep -> 'reconciliation' ->> 'rounding_code' = 'line_vs_receipt_vat', 'R3: pyöristyskoodi');
  perform public.t117_ck((rep -> 'reconciliation' ->> 'difference')::numeric = 0, 'R4: maksutavat ja tuotteet täsmäävät');
  perform public.t117_ck((select count(*) from jsonb_array_elements(rep -> 'by_product') e where e ->> 'product' = 't117 pyöristys' and (e ->> 'quantity')::numeric = 3 and (e ->> 'gross')::numeric = 30.03) = 1, 'R5: tuoterivi');
  perform public.t117_ck(coalesce((rep -> 'statistics' -> 'johku' ->> 'gross')::numeric, 0) >= 50, 'R6: Johku vain tilastossa');
  perform public.t117_ck(position('881170' in coalesce(rep::text, '')) = 0 or (rep -> 'statistics' -> 'johku') is not null, 'R7: Johku ei ole myyntiluvuissa');

  tx := public.t117_call($q$booking.admin_report_transactions('2032-06-01'::date, '2032-06-30'::date)$q$);
  perform public.t117_ck((select count(*) from jsonb_array_elements(tx -> 'rows') e where e ->> 'status' = 'open' and e ->> 'customer' = 'Avoin Asiakas' and (e ->> 'gross')::numeric = 36 and (e ->> 'quantity')::numeric = 2) = 1, 'T1: avoin vahvistettu tilaus');
  perform public.t117_ck((select count(*) from jsonb_array_elements(tx -> 'rows') e where e ->> 'voucher' = '881170') = 0, 'T2: Johku-tilaus ei tapahtumissa');
  csv := public.t117_call($q$booking.admin_report_csv('2032-06-01'::date, '2032-06-30'::date, 'transactions')$q$) ->> 'content';
  perform public.t117_ck(left(csv, 1) = chr(65279) and position('tosite;pvm;asiakas;tuote;maara;netto;alv_%;alv_eur;brutto;maksutapa;tila;laji' in csv) = 2, 'T3: CSV BOM ja otsikko');
  perform public.t117_ck(position(';' in csv) > 0 and position('avoin' in csv) > 0 and position('881170' in csv) = 0, 'T4: avoin rivillä, ei Johku-numeroa');
  perform public.t117_ck(position('10,01' in csv) > 0 and position('10.01' in csv) = 0, 'T5: desimaalipilkku');
  csv := public.t117_call($q$booking.admin_report_csv('2032-06-01'::date, '2032-06-30'::date, 'summary')$q$) ->> 'content';
  perform public.t117_ck(position('myynti;t117 pyöristys' in csv) > 0 and position('myynti;t117 yleinen' in csv) > 0, 'S1: lunastus on myyntirivi');
  perform public.t117_ck((rep -> 'prepaid_redemptions' ->> 'payments')::int = 0 and (rep -> 'totals' ->> 'gross')::numeric = 86.03, 'R8: lunastus on myyntiä (30,03 + 20 + 36)');
  perform public.t117_ck(
    (select coalesce(sum((e ->> 'gross')::numeric), 0) from jsonb_array_elements(rep -> 'vat_summary') e) = (rep -> 'reconciliation' ->> 'product_gross')::numeric
    and (select coalesce(sum((e ->> 'vat')::numeric), 0) from jsonb_array_elements(rep -> 'vat_summary') e) = (rep -> 'reconciliation' ->> 'line_vat')::numeric
    and (rep -> 'reconciliation' ->> 'receipt_vat')::numeric - (rep -> 'reconciliation' ->> 'line_vat')::numeric = 0.01,
    'R9: ALV-erittely = myynti miinus hyvitykset, rivin ALV');
  perform public.t117_ck(position(E'\nmaksutapa;' in csv) = 0 and position('tasmaytys;maksutavat' in csv) = 0 and position('tasmaytys;erotus' in csv) = 0 and position('johku_loppusaldo' in csv) = 0, 'S2: yhteenvedossa ei maksutapoja eikä Johku-saldoa');
  csv := public.t117_call($q$booking.admin_report_csv('2032-06-15'::date, '2032-06-15'::date, 'summary')$q$) ->> 'content';
  perform public.t117_ck(position('maksutapa;' in csv) = 0 and position('tasmaytys;erotus' in csv) = 0 and position('tasmaytys;tuotteet' in csv) > 0 and position('lahjakortti_maksuton;myonnetty' in csv) = 0, 'S3: päiväyhteenvedossa ei maksutapoja eikä maksuttomia kortteja');

  gc := public.t117_call($q$booking.admin_report_gift_cards('open', 'json')$q$);
  perform public.t117_ck(gc -> 'johku' is null and (select count(*) from jsonb_array_elements(gc -> 'statistics' -> 'johku' -> 'rows') e where e ->> 'code_masked' = '****-****-AB12' and e ->> 'source' = 'johku') = 1, 'L1: Johku vain statistics.johku');
  perform public.t117_ck((select count(*) from jsonb_array_elements(gc -> 'own' -> 'rows') e where e ->> 'code_masked' = '****-****-AB12') = 0, 'L2: Johku ei sekoitu omaan');
  perform public.t117_ck(coalesce((gc -> 'own' -> 'complimentary' ->> 'vat')::numeric, 0) = 0 and coalesce((gc -> 'own' -> 'at_sale' ->> 'vat')::numeric, 0) > 0, 'L3: maksuton ALV 0, maksettu ALV myynnissä');
  perform public.t117_ck(coalesce((gc -> 'statistics' -> 'johku' -> 'totals' ->> 'initial')::numeric, 0) >= 50, 'L4: Johkun summa ei ole oman osion ALV:ssa');
  csv := public.t117_call($q$booking.admin_report_gift_cards('all', 'csv')$q$) ->> 'content';
  perform public.t117_ck(position('johku;****-****-AB12' in csv) = 0 and position('yhteenveto;johku;' in csv) = 0 and position('yhteenveto;oma_myynnissa;' in csv) > 0 and position('yhteenveto;oma_maksuton;' in csv) > 0 and position('oma_lunastus' in csv) = 0, 'L5: CSV ilman Johkua, omat yhteensä mukana');

  perform public.t117_logout();
  v_text := booking._receipt_text(jsonb_build_object('locale', 'fi', 'document', 'receipt', 'receipt_no', 'K-1', 'issued_local', '15.06.2032 14:00', 'order_no', 1,
    'seller', jsonb_build_object('name', 'S', 'legal_name', 'Havuhattu Oy', 'business_id', '1', 'vat_id', 'FI1'),
    'payment', jsonb_build_object('method_label', 'Kortti'),
    'lines', jsonb_build_array(jsonb_build_object('description', 'Vuoro', 'quantity', 2, 'line_gross', 36, 'line_net', 28.69, 'vat_rate', 25.5)),
    'vat', jsonb_build_array(jsonb_build_object('rate', 25.5, 'net', 28.69, 'vat', 7.31, 'gross', 36)),
    'total_gross', 36, 'total_vat', 7.31, 'total_net', 28.69, 'total_paid', 36));
  perform public.t117_ck(position('veroton 28,69' in v_text) > 0 and position('ALV 25,5 %' in v_text) > 0 and position('ALV 7,31' in v_text) > 0 and position('brutto 36,00' in v_text) > 0, 'K1: kuitin rivi');

  perform public.t117_logout();
  insert into booking.orders(status, payment_status, total_gross, source_channel, locale) values ('confirmed', 'unpaid', 10, 'admin', 'fi') returning id into o_nat;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_nat, 't117 käteinen', 'reservation', 1, 10, 10, 25.5);
  insert into booking.payments(order_id, method, provider, status, amount, rounding, paid_at)
  values (o_nat, 'cash', 'manual', 'paid', 10, 0, '2032-06-16 10:00:00+00') returning id into p_cash;
  perform public.t117_ck((select rounding from booking.payments where id = p_cash) = 0, 'C4: suora käteiskirjaus ei pyöristy');
  perform public.t117_ck((select count(*) from booking.receipts where payment_id = p_cash and kind = 'receipt') = 1, 'C5: vanha käteisrivi saa edelleen kuitin');

  log := current_setting('t117.log', true);
  npass := (length(log) - length(replace(log, E'\nP ', ''))) / 3;
  nfail := (length(log) - length(replace(log, E'\nF ', ''))) / 3;
  if left(log, 1) = 'P' then npass := npass + 1; elsif left(log, 1) = 'F' then nfail := nfail + 1; end if;
  raise exception 'TESTRESULT pass=% fail=%\n%', npass, nfail, log;
end $t$;
