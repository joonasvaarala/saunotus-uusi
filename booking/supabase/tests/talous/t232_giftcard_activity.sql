-- t232: lahjakorttiraportin jakson aktiviteetti (booking_232).
-- Oma myynti ja lunastus, vanhentuminen, Johku, kumppanilunastus lähteittäin (value_card).
-- Selkokielinen koodi ei tule vastaukseen. Myynti-CSV ei saa kumppania eikä Johkua.
-- Aja migraatioiden jälkeen. Yksi transaktio, lopussa TESTRESULT + ROLLBACK.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t232.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t232.log', coalesce(current_setting('t232.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;

do $t$
declare
  u uuid := gen_random_uuid();
  o_own bigint; o_off bigint; o_kk bigint; o_ki bigint; o_late bigint;
  n_own bigint; n_off bigint; n_kk bigint; n_ki bigint;
  p_off bigint; p_kk bigint; p_ki bigint;
  g_sale bigint; g_exp bigint; g_free bigint; g_johku bigint;
  gc jsonb; rowj jsonb; csv text; sales text;
  d0 date := '2035-06-01'; d1 date := '2035-06-30';
  log text; np int; nf int;
begin
  perform pg_temp.ck(
    not has_function_privilege('anon', 'booking._gc_period_activity(date,date)', 'execute')
    and not has_function_privilege('authenticated', 'booking._gc_period_activity(date,date)', 'execute')
    and has_function_privilege('service_role', 'booking._gc_period_activity(date,date)', 'execute')
    and has_function_privilege('authenticated', 'booking.admin_report_gift_cards(text,text,date,date)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_report_gift_cards(text,text,date,date)', 'execute'),
    'A1 oikeudet');
  perform pg_temp.ck(exists (select 1 from booking.payment_methods where code in ('partner_voucher', 'partner_voucher_offerilla', 'partner_voucher_kokemuskauppa')), 'A2 kumppanimaksutavat');

  -- Ympäristön lippu voi olla true (DEV/PROD); testi olettaa lähtötilan false ja kokeilee true-tilan erikseen (E2).
  update booking.settings set value = 'false'::jsonb where key = 'voucher_claims.partner_voucher_accounted';
  insert into auth.users(id, email) values (u, 't232-mgr@example.test');
  insert into booking.staff(user_id, email, name, role) values (u, 't232-mgr@example.test', 't232 manager', 'manager');

  insert into booking.orders(status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values ('confirmed', 'paid', 40, 'admin', 'fi', '2035-06-02 09:00:00+00') returning id, order_no into o_own, n_own;
  insert into booking.orders(status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values ('confirmed', 'paid', 40, 'web', 'fi', '2035-06-10 09:00:00+00') returning id, order_no into o_off, n_off;
  insert into booking.orders(status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values ('confirmed', 'paid', 25, 'web', 'fi', '2035-06-11 09:00:00+00') returning id, order_no into o_kk, n_kk;
  insert into booking.orders(status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values ('confirmed', 'paid', 12, 'web', 'fi', '2035-06-12 09:00:00+00') returning id, order_no into o_ki, n_ki;
  insert into booking.orders(status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values ('confirmed', 'paid', 9, 'web', 'fi', '2035-07-02 09:00:00+00') returning id into o_late;

  insert into booking.gift_cards(code, issuer, source, accounting_origin, vat_treatment, sale_vat_rate, initial_amount, balance, status, buyer_name, complimentary, activated_at, valid_from, valid_to)
  values ('HH232OWN00Q7', 'own', 'native', 'native', 'at_sale', 25.5, 40, 25, 'active', 'T232 Oma', false, '2035-06-02 10:00:00+00', '2035-06-02', '2036-06-02') returning id into g_sale;
  insert into booking.gift_card_ledger(gift_card_id, order_id, delta, balance_after, reason, at)
  values (g_sale, o_own, 40, 40, 'purchase', '2035-06-02 10:00:00+00'),
         (g_sale, o_own, -15, 25, 'redemption', '2035-06-03 11:00:00+00');

  insert into booking.gift_cards(code, issuer, source, accounting_origin, vat_treatment, sale_vat_rate, initial_amount, balance, status, buyer_name, complimentary, activated_at, valid_from, valid_to)
  values ('HH232EXP00Q8', 'own', 'native', 'native', 'at_sale', 25.5, 8, 8, 'active', 'T232 Vanha', false, '2035-05-01 10:00:00+00', '2035-05-01', '2035-06-15') returning id into g_exp;
  insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, at)
  values (g_exp, 8, 8, 'purchase', '2035-05-02 10:00:00+00');

  insert into booking.gift_cards(code, issuer, source, accounting_origin, vat_treatment, sale_vat_rate, initial_amount, balance, status, buyer_name, complimentary, activated_at, valid_from, valid_to)
  values ('HH232FRE00Q9', 'own', 'native', 'native', 'at_sale', 0, 10, 10, 'active', 'T232 Vapaa', true, '2035-06-04 10:00:00+00', '2035-06-04', '2036-06-04') returning id into g_free;
  insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, at)
  values (g_free, 10, 10, 'manual_issue', '2035-06-04 10:00:00+00');

  insert into booking.gift_cards(code, issuer, source, accounting_origin, vat_treatment, sale_vat_rate, initial_amount, balance, status, buyer_name, complimentary, activated_at, valid_from, valid_to)
  values ('JK232JOH00K1', 'johku', 'johku', 'johku', 'at_sale', 25.5, 100, 72, 'active', 'T232 Johku', false, '2035-05-01 10:00:00+00', '2035-05-01', '2036-05-01') returning id into g_johku;
  insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, at)
  values (g_johku, 100, 100, 'johku_purchase', '2035-05-01 10:00:00+00'),
         (g_johku, -28, 72, 'johku_usage', '2035-06-05 12:00:00+00');

  alter table booking.payments disable trigger user;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at)
  values (o_off, 'partner_voucher_offerilla', 'manual', 'paid', 40, '2035-06-10 12:00:00+00') returning id into p_off;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at)
  values (o_kk, 'partner_voucher_kokemuskauppa', 'manual', 'paid', 25, '2035-06-11 12:00:00+00') returning id into p_kk;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at)
  values (o_ki, 'partner_voucher', 'manual', 'paid', 12, '2035-06-12 12:00:00+00') returning id into p_ki;

  insert into booking.voucher_claims(order_id, code, source, status, hold_until, amount, payment_id, value_card, resolved_at, resolved_by, locale)
  values (o_off, 'OFFERILLA232', 'offerilla', 'redeemed', '2035-06-20 00:00:00+00', 40, p_off, true, '2035-06-10 12:00:00+00', 'bot', 'fi'),
         (o_kk, 'KK23219ABCDEF', 'kokemuskauppa', 'redeemed', '2035-06-20 00:00:00+00', 25, p_kk, false, '2035-06-11 12:00:00+00', 'staff', 'fi'),
         (o_ki, 'KIITOS2320001', 'kiitoskauppa', 'redeemed', '2035-06-20 00:00:00+00', 12, p_ki, false, '2035-06-12 12:00:00+00', 'bot', 'fi'),
         (o_late, 'KK99999LATE01', 'kokemuskauppa', 'redeemed', '2035-07-20 00:00:00+00', 9, null, false, '2035-07-02 12:00:00+00', 'bot', 'fi');

  perform pg_temp.login(u);
  gc := booking.admin_report_gift_cards('all', 'json', d0, d1);
  perform pg_temp.ck(gc -> 'johku' is null and not (gc -> 'balance' ? 'johku') and gc -> 'activity' ? 'rows', 'B1 activity on lisä, saldoennallaan');
  perform pg_temp.ck(position('HH232OWN00Q7' in gc::text) = 0 and position('OFFERILLA232' in gc::text) = 0 and position('JK232JOH00K1' in gc::text) = 0, 'B2 selkokoodi ei vastauksessa');

  select e into rowj from jsonb_array_elements(gc -> 'activity' -> 'rows') e where e ->> 'source' = 'native_paid';
  perform pg_temp.ck((rowj ->> 'accounting')::boolean and (rowj ->> 'sold_count')::int = 1 and (rowj ->> 'sold_gross')::numeric = 40
    and (rowj ->> 'redeemed_count')::int = 1 and (rowj ->> 'redeemed_gross')::numeric = 15
    and (rowj ->> 'expired_count')::int = 1 and (rowj ->> 'expired_gross')::numeric = 8
    and (rowj ->> 'opening')::numeric = 8 and (rowj ->> 'closing')::numeric = 25, 'C1 oma maksettu: myynti, lunastus, vanhentunut, saldo');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(rowj -> 'events') e where e ->> 'kind' = 'redemption' and (e ->> 'amount')::numeric = 15 and (e ->> 'order_no')::bigint = n_own and e ->> 'code_masked' = '****-****-00Q7'), 'C2 lunastuksen tilaus ja maski');

  select e into rowj from jsonb_array_elements(gc -> 'activity' -> 'rows') e where e ->> 'source' = 'native_complimentary';
  perform pg_temp.ck(not (rowj ->> 'accounting')::boolean and (rowj ->> 'sold_count')::int = 1 and (rowj ->> 'sold_gross')::numeric = 10 and (rowj ->> 'redeemed_count')::int = 0, 'C3 maksuton erikseen, ei kirjanpitoa');

  select e into rowj from jsonb_array_elements(gc -> 'activity' -> 'rows') e where e ->> 'source' = 'johku';
  perform pg_temp.ck(not (rowj ->> 'accounting')::boolean and (rowj ->> 'opening')::numeric = 100 and (rowj ->> 'redeemed_gross')::numeric = 28 and (rowj ->> 'redeemed_count')::int = 1 and (rowj ->> 'closing')::numeric = 72, 'C4 Johku vain tiedoksi');

  select e into rowj from jsonb_array_elements(gc -> 'activity' -> 'rows') e where e ->> 'source' = 'offerilla';
  perform pg_temp.ck(rowj ->> 'group' = 'partner' and not coalesce((rowj ->> 'sold_applicable')::boolean, true)
    and not (rowj ->> 'accounting')::boolean and (rowj ->> 'redeemed_count')::int = 1 and (rowj ->> 'redeemed_gross')::numeric = 40
    and (rowj ->> 'value_card_count')::int = 1 and (rowj -> 'sold_gross') is null, 'C5 Offerilla: lunastus ja arvolahjakortti, ei myyntiä');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(rowj -> 'events') e where (e ->> 'value_card')::boolean and (e ->> 'order_no')::bigint = n_off and e ->> 'code_masked' like '%A232'), 'C6 Offerillan tapahtuma');

  select e into rowj from jsonb_array_elements(gc -> 'activity' -> 'rows') e where e ->> 'source' = 'kokemuskauppa';
  perform pg_temp.ck((rowj ->> 'redeemed_gross')::numeric = 25 and (rowj ->> 'value_card_count')::int = 0, 'C7 Kokemuskauppa, jakson ulkopuolinen ei mukana');

  select e into rowj from jsonb_array_elements(gc -> 'activity' -> 'rows') e where e ->> 'source' = 'kiitoskauppa';
  perform pg_temp.ck((rowj ->> 'redeemed_gross')::numeric = 12 and (rowj ->> 'redeemed_count')::int = 1, 'C8 Kiitoskauppa partner_voucher-maksusta');

  perform pg_temp.ck((gc -> 'activity' -> 'totals' ->> 'redeemed_gross')::numeric = 15 + 28 + 40 + 25 + 12, 'C9 yhteensä käytetty');
  perform pg_temp.ck((gc -> 'activity' -> 'totals' ->> 'accounting_closing')::numeric = (select (e ->> 'closing')::numeric from jsonb_array_elements(gc -> 'activity' -> 'rows') e where e ->> 'source' = 'native_paid'), 'C10 kirjanpitosaldo on vain oma maksettu');

  csv := booking.admin_report_gift_cards('all', 'csv', d0, d1) ->> 'content';
  perform pg_temp.ck(position('aktiviteetti;johku_tiedoksi;tiedoksi;' in csv) > 0 and position('johku;' in csv) = 0, 'D1 Johku CSV:ssä tiedoksi, ei johku;-osiota');
  perform pg_temp.ck(position('aktiviteetti;kumppani_offerilla;tiedoksi;' in csv) > 0 and position('tapahtuma;kumppani_offerilla;redemption;' in csv) > 0 and position('arvolahjakortti' in csv) > 0, 'D2 kumppanin lunastus ja arvolahjakortti CSV:ssä');
  perform pg_temp.ck(position('OFFERILLA232' in csv) = 0 and position('saldo;oma_maksettu;alkusaldo' in csv) > 0 and position('yhteensa;kaikki;ei_kirjanpitosumma;' in csv) > 0, 'D3 maski, kirjanpitosaldo ja yhteenveto');

  sales := booking.admin_report_csv(d0, d1, 'summary') ->> 'content';
  perform pg_temp.ck(position('johku' in lower(sales)) = 0 and position('offerilla' in lower(sales)) = 0 and position('kumppani_' in sales) = 0, 'E1 myynti-CSV ilman Johkua ja kumppaneita');

  perform pg_temp.logout();
  update booking.settings set value = 'true'::jsonb where key = 'voucher_claims.partner_voucher_accounted';
  perform pg_temp.ck(found, 'E2a lippu asetettu');
  perform pg_temp.login(u);
  gc := booking.admin_report_gift_cards('all', 'json', d0, d1);
  perform pg_temp.ck((select (e ->> 'accounting')::boolean from jsonb_array_elements(gc -> 'activity' -> 'rows') e where e ->> 'source' = 'offerilla')
    and not (select (e ->> 'accounting')::boolean from jsonb_array_elements(gc -> 'activity' -> 'rows') e where e ->> 'source' = 'johku'), 'E2 kumppani kirjanpitoon vain lipulla, Johku ei');
  perform pg_temp.logout();
  update booking.settings set value = 'false'::jsonb where key = 'voucher_claims.partner_voucher_accounted';

  log := current_setting('t232.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
