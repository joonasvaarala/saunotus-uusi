-- t222: booking_222 raporttirakenne.
-- Avoin saatava ei kasva hyvityksestä. Myynti-CSV ilman maksutapoja.
-- Lahjakortti-CSV ilman Johkua. Provisio ilman lahjakorttia ja Johkua.
-- Aja migraatioiden jälkeen. Yksi transaktio, lopussa TESTRESULT + ROLLBACK.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t222.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t222.log', coalesce(current_setting('t222.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 180) end;
end $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;

do $t$
declare
  u_mgr uuid := gen_random_uuid();
  u_st uuid := gen_random_uuid();
  o_part bigint; o_mix bigint; o_full bigint; o_open bigint; o_late bigint; o_johku bigint; o_fee bigint;
  p_part bigint; p_gc bigint; p_card bigint; p_full bigint; p_fee bigint; p_fee_gc bigint; p_fee_j bigint;
  n_part text; n_mix text; n_full text; n_open text; n_late text; n_johku text;
  c_open bigint;
  rep jsonb; tx jsonb; gc jsonb; fees jsonb; csv text; log text; np int; nf int;
  d0 date := '2035-04-01'; d1 date := '2035-04-30';
begin
  perform pg_temp.ck(
    not has_function_privilege('anon', 'booking.admin_report_gift_cards(text,text,date,date)', 'execute')
    and not has_function_privilege('anon', 'booking._order_open_amount(bigint)', 'execute')
    and not has_function_privilege('authenticated', 'booking._report_open_rows(date)', 'execute')
    and has_function_privilege('authenticated', 'booking.admin_report_gift_cards(text,text,date,date)', 'execute'),
    'A1 oikeudet');
  perform pg_temp.ck(to_regprocedure('booking.admin_report_gift_cards(text,text)') is null, 'A2 vanha lahjakorttiallekirjoitus on poissa');

  insert into auth.users(id, email) values (u_mgr, 't222-mgr@example.test'), (u_st, 't222-staff@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_mgr, 't222-mgr@example.test', 't222 manager', 'manager'),
    (u_st, 't222-staff@example.test', 't222 staff', 'staff');
  insert into booking.customers(name, email) values ('T222 Avoin', 't222-open@example.test') returning id into c_open;

  alter table booking.payments disable trigger user;
  insert into booking.orders(status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values ('confirmed', 'partially_refunded', 2.02, 'admin', 'fi', '2035-04-02 09:00:00+00') returning id into o_part;
  insert into booking.payments(order_id, method, provider, status, amount, refunded_amount, paid_at)
  values (o_part, 'card_terminal', 'manual', 'partially_refunded', 2.02, 1.00, '2035-04-02 10:00:00+00') returning id into p_part;

  insert into booking.orders(status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values ('confirmed', 'partially_refunded', 53.50, 'admin', 'fi', '2035-04-03 09:00:00+00') returning id into o_mix;
  insert into booking.payments(order_id, method, provider, status, amount, refunded_amount, paid_at)
  values (o_mix, 'gift_card', 'manual', 'paid', 20.00, 0, '2035-04-03 10:00:00+00') returning id into p_gc;
  insert into booking.payments(order_id, method, provider, status, amount, refunded_amount, paid_at)
  values (o_mix, 'card_terminal', 'manual', 'refunded', 33.50, 33.50, '2035-04-03 10:05:00+00') returning id into p_card;

  insert into booking.orders(status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values ('confirmed', 'refunded', 58.00, 'admin', 'fi', '2035-04-04 09:00:00+00') returning id into o_full;
  insert into booking.payments(order_id, method, provider, status, amount, refunded_amount, paid_at)
  values (o_full, 'card_terminal', 'manual', 'refunded', 58.00, 58.00, '2035-04-04 10:00:00+00') returning id into p_full;

  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values (c_open, 'confirmed', 'unpaid', 40.00, 'admin', 'fi', '2035-04-05 09:00:00+00') returning id into o_open;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_open, 'T222 avoin vuoro', 'product', 2, 20, 40, 25.5);

  insert into booking.orders(status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values ('confirmed', 'unpaid', 15.00, 'admin', 'fi', '2035-05-02 09:00:00+00') returning id into o_late;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_late, 'T222 myohemmin', 'product', 1, 15, 15, 25.5);

  insert into booking.orders(status, payment_status, total_gross, source_channel, locale, confirmed_at, external_source, johku_order_no)
  values ('confirmed', 'unpaid', 70.00, 'johku_import', 'fi', '2035-04-06 09:00:00+00', 'johku', 770222) returning id into o_johku;

  insert into booking.orders(status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values ('confirmed', 'paid', 10.00, 'admin', 'fi', '2035-04-10 09:00:00+00') returning id into o_fee;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at, provider_fee)
  values (o_fee, 'montonio', 'montonio', 'paid', 10.00, '2035-04-10 11:00:00+00', 1.00) returning id into p_fee;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at, provider_fee)
  values (o_fee, 'gift_card', 'manual', 'paid', 20.00, '2035-04-10 11:05:00+00', 0) returning id into p_fee_gc;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at, provider_fee)
  values (o_johku, 'card_terminal', 'manual', 'paid', 30.00, '2035-04-10 11:10:00+00', 0.50) returning id into p_fee_j;
  alter table booking.payments enable trigger user;

  select order_no::text into n_part from booking.orders where id = o_part;
  select order_no::text into n_mix from booking.orders where id = o_mix;
  select order_no::text into n_full from booking.orders where id = o_full;
  select order_no::text into n_open from booking.orders where id = o_open;
  select order_no::text into n_late from booking.orders where id = o_late;
  select order_no::text into n_johku from booking.orders where id = o_johku;

  perform pg_temp.ck(booking._order_open_amount(o_part) = 0, 'B1 osahyvitys ei ole avoin: ' || booking._order_open_amount(o_part));
  perform pg_temp.ck(booking._order_open_amount(o_mix) = 0, 'B2 lahjakortti + hyvitetty kortti ei ole avoin: ' || booking._order_open_amount(o_mix));
  perform pg_temp.ck(booking._order_open_amount(o_full) = 0, 'B3 täysi hyvitys ei ole avoin: ' || booking._order_open_amount(o_full));
  perform pg_temp.ck(booking._order_open_amount(o_open) = 40, 'B4 maksamaton avoin = 40');
  perform pg_temp.ck(booking._order_open_amount(o_johku) = 40, 'B5 Johku-maksu pienentää funktion tulosta, raportti rajaa tilauksen pois');

  perform pg_temp.ck(not exists (
    select 1 from jsonb_array_elements(booking._report_open_rows(d1)) x
     where x ->> 'voucher' in (n_part, n_mix, n_full, n_late, n_johku)), 'C1 hyvitykset, tuleva ja Johku eivät ole avoimissa');
  perform pg_temp.ck(exists (
    select 1 from jsonb_array_elements(booking._report_open_rows(d1)) x
     where x ->> 'voucher' = n_open and (x ->> 'gross')::numeric = 40 and (x ->> 'quantity')::numeric = 2
       and x ->> 'customer' = 'T222 Avoin' and x ->> 'status' = 'open'), 'C2 maksamaton rivi 40 € / 2 kpl');
  perform pg_temp.ck(not exists (
    select 1 from jsonb_array_elements(booking._report_open_rows('2035-04-04')) x where x ->> 'voucher' = n_open), 'C3 vahvistuspäivän jälkeen ei vielä avoin');

  rep := booking._report_json(d0, d1, false, true);
  perform pg_temp.ck((
    select coalesce(jsonb_agg(jsonb_build_object('v', x ->> 'voucher', 'g', x ->> 'gross', 'p', x ->> 'product') order by x ->> 'voucher', x ->> 'product'), '[]'::jsonb)
      from jsonb_array_elements(rep -> 'open' -> 'rows') x)
    = (
    select coalesce(jsonb_agg(jsonb_build_object('v', x ->> 'voucher', 'g', x ->> 'gross', 'p', x ->> 'product') order by x ->> 'voucher', x ->> 'product'), '[]'::jsonb)
      from jsonb_array_elements(booking._report_tx(d0, d1)) x where x ->> 'status' = 'open'),
    'C4 avoimet rivit ovat samat yhteenvedossa ja tapahtumissa');
  perform pg_temp.ck(exists (
    select 1 from jsonb_array_elements(rep -> 'open' -> 'rows') x where x ->> 'voucher' = n_open and (x ->> 'gross')::numeric = 40), 'C5 yhteenveto näyttää maksamattoman');
  perform pg_temp.ck((select coalesce(sum((x ->> 'gross')::numeric), 0) from jsonb_array_elements(booking._report_tx(d0, d1)) x where x ->> 'status' = 'open')
    = (rep -> 'open' ->> 'unpaid')::numeric, 'C6 avoin summa = rivien brutto');

  perform pg_temp.login(u_st);
  perform pg_temp.ck(pg_temp.try($q$select booking.admin_report_csv('2035-04-05', '2035-04-05', 'summary')$q$) = 'forbidden', 'D1 staff ei saa CSV:tä');
  perform pg_temp.logout();
  perform pg_temp.login(u_mgr);
  csv := booking.admin_report_csv(d0, d1, 'summary') ->> 'content';
  perform pg_temp.ck(position(E'\nmaksutapa;' in csv) = 0 and position('tasmaytys;maksutavat' in csv) = 0 and position('tasmaytys;erotus' in csv) = 0 and position('johku_loppusaldo' in csv) = 0, 'D2 myynti-CSV ilman maksutapoja ja Johku-saldoa');
  perform pg_temp.ck((booking.admin_report_csv('2035-04-05', '2035-04-05', 'summary') ->> 'filename') = 'myynti_2035-04-05.csv', 'D3 päivän tiedostonimi');
  perform pg_temp.ck((booking.admin_report_csv(d0, d1, 'summary') ->> 'filename') = 'myynti_2035-04-01_2035-04-30.csv', 'D4 jakson tiedostonimi');
  csv := booking.admin_report_csv(d0, d1, 'lines') ->> 'content';
  perform pg_temp.ck(position(n_open in csv) > 0 and position('avoin' in csv) > 0, 'D5 tapahtuma-CSV sisältää avoimen');
  perform pg_temp.ck(position(n_part in csv) = 0 and position(n_full in csv) = 0 and position(n_johku in csv) = 0, 'D6 hyvitykset ja Johku eivät ole tapahtuma-CSV:ssä');
  csv := booking.admin_report_csv(d0, d1, 'methods') ->> 'content';
  perform pg_temp.ck(position('avoin;' || n_open in csv) > 0 and position('avoin;' || n_part in csv) = 0 and position('tasmaytys;' in csv) > 0, 'D7 maksutapa-CSV:n avoimet rivit');

  tx := booking.admin_report_transactions(d0, d1);
  perform pg_temp.ck(exists (
    select 1 from jsonb_array_elements(tx -> 'rows') x
     where x ->> 'voucher' = n_open and x ->> 'status' = 'open' and (x ->> 'gross')::numeric = 40)
    and not exists (
    select 1 from jsonb_array_elements(tx -> 'rows') x
     where x ->> 'voucher' in (n_part, n_mix, n_full, n_johku)), 'E1 tapahtumaraportin avoimet');

  fees := booking.admin_report_provider_fees(d0, d1, 'json');
  perform pg_temp.ck((fees -> 'totals' ->> 'sales_gross')::numeric = 10 and (fees -> 'totals' ->> 'sales_count')::int = 1, 'F1 provisio brutto vain korttimaksu: ' || coalesce(fees -> 'totals' ->> 'sales_gross', 'null'));
  perform pg_temp.ck(not exists (
    select 1 from jsonb_array_elements(fees -> 'rows') x
     where x ->> 'method' = 'gift_card' or x ->> 'provider' = 'johku' or coalesce((x ->> 'gross')::numeric, 0) in (20, 30)), 'F2 ei lahjakorttia eikä Johkua');
  csv := booking.admin_report_provider_fees(d0, d1, 'csv') ->> 'content';
  perform pg_temp.ck(position('10,00' in csv) > 0 and position('20,00' in csv) = 0 and position('30,00' in csv) = 0, 'F3 provisio-CSV');
  perform pg_temp.ck((booking.admin_report_provider_fees(d0, d1, 'csv') ->> 'filename') = 'palkkiot_2035-04-01_2035-04-30.csv', 'F4 tiedostonimi palkkiot_');

  perform pg_temp.logout();
  insert into booking.gift_cards(code, issuer, source, accounting_origin, vat_treatment, sale_vat_rate, initial_amount, balance, status, buyer_name, complimentary, activated_at, valid_from, valid_to)
  values ('HHT222CARDQW71', 'own', 'native', 'native', 'at_sale', 25.5, 40, 40, 'active', 'T222 Oma', false, '2035-04-01 10:00:00+00', '2035-04-01', '2036-04-01');
  insert into booking.gift_cards(code, issuer, source, accounting_origin, vat_treatment, sale_vat_rate, initial_amount, balance, status, buyer_name, complimentary, activated_at, valid_from, valid_to)
  values ('JK222CARD0JK99', 'johku', 'johku', 'johku', 'at_sale', 25.5, 80, 80, 'active', 'T222 Johku', false, '2035-01-01 10:00:00+00', '2035-01-01', '2036-01-01');
  perform pg_temp.login(u_mgr);
  gc := booking.admin_report_gift_cards('all', 'json', d0, d1);
  perform pg_temp.ck(gc -> 'johku' is null and gc -> 'period' ->> 'to' = '2035-04-30' and gc -> 'balance' ? 'native_paid' and gc -> 'balance' ? 'native_complimentary' and not (gc -> 'balance' ? 'johku'), 'G1 jakso ja oma saldo');
  perform pg_temp.ck((select count(*) from jsonb_array_elements(gc -> 'own' -> 'rows') e where e ->> 'code_masked' = '****-****-JK99') = 0, 'G2 Johku ei ole omassa osiossa');
  perform pg_temp.ck((select count(*) from jsonb_array_elements(gc -> 'statistics' -> 'johku' -> 'rows') e where e ->> 'code_masked' = '****-****-JK99') = 1, 'G3 Johku on statistics.johku');
  perform pg_temp.ck((select count(*) from jsonb_array_elements(gc -> 'own' -> 'rows') e where e ->> 'code_masked' = '****-****-QW71' and coalesce(e ->> 'source', '') <> 'johku') = 1, 'G4 oma kortti omassa osiossa');
  csv := booking.admin_report_gift_cards('all', 'csv', d0, d1) ->> 'content';
  perform pg_temp.ck(position('johku;' in csv) = 0 and position('QW71' in csv) > 0 and position('JK99' in csv) = 0 and position('saldo;oma_maksettu;alkusaldo' in csv) > 0, 'G5 CSV ilman Johkua, saldorivit mukana');
  perform pg_temp.ck((booking.admin_report_gift_cards('open', 'csv', d0, d1) ->> 'filename') = 'lahjakortit_2035-04-30_open.csv', 'G6 tiedostonimi');
  perform pg_temp.ck((booking.admin_report_accrual_csv(d0, d1) ->> 'filename') = 'palvelupaiva_2035-04-01_2035-04-30.csv', 'G7 palvelupaiva-CSV');
  perform pg_temp.logout();

  log := current_setting('t222.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
