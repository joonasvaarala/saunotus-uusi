-- t219: booking_219 suoriteperuste ja saadut ennakot.
-- Aja migraatioiden jälkeen. Yksi transaktio, lopussa TESTRESULT + ROLLBACK.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t219.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t219.log', coalesce(current_setting('t219.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 180) end;
end $$;
create function pg_temp.call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then return jsonb_build_object('err', pg_temp.try(p_sql));
end $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;

do $t$
declare
  u_mgr uuid := gen_random_uuid();
  u_st uuid := gen_random_uuid();
  o bigint; p bigint; rid bigint; g bigint;
  pay jsonb; june jsonb; dec jsonb; csv text;
  log text; np int; nf int;
begin
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_report_accrual(date,date)', 'execute')
      and not has_function_privilege('anon', 'booking.admin_report_accrual_csv(date,date)', 'execute')
      and has_function_privilege('authenticated', 'booking.admin_report_accrual(date,date)', 'execute'), 'A1 oikeudet');

  insert into auth.users(id, email) values (u_mgr, 't219-mgr@example.test'), (u_st, 't219-staff@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_mgr, 't219-mgr@example.test', 't219 manager', 'manager'),
    (u_st, 't219-staff@example.test', 't219 staff', 'staff');

  insert into booking.orders(status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values ('confirmed', 'paid', 125.50, 'admin', 'fi', '2032-06-01 09:00:00+00') returning id into o;
  alter table booking.payments disable trigger payments_paid_ins;
  alter table booking.payments disable trigger payments_paid_upd;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at)
  values (o, 'card_terminal', 'manual', 'paid', 125.50, '2032-06-01 10:00:00+00') returning id into p;
  alter table booking.payments enable trigger payments_paid_ins;
  alter table booking.payments enable trigger payments_paid_upd;
  insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, issued_at, total_gross, snapshot, text_body)
  values ('K-2032-900001', 'receipt', 'K', 2032, 900001, o, p, '2032-06-01 10:00:00+00', 125.50,
    jsonb_build_object('lines', jsonb_build_array(jsonb_build_object(
      'description', 'T219 saunavuoro', 'kind', 'reservation', 'vat_rate', 25.5, 'quantity', 1,
      'line_gross', 125.50, 'line_net', 100.00, 'starts_at', '2032-12-01T12:00:00Z', 'ends_at', '2032-12-01T14:00:00Z')),
      'total_net', 100, 'total_vat', 25.50),
    't219') returning id into rid;

  insert into booking.gift_cards(code, issuer, initial_amount, balance, status, vat_treatment, sale_vat_rate, accounting_origin, source, complimentary, activated_at, valid_from, valid_to)
  values ('T219NATIVE01', 'own', 40, 40, 'active', 'at_sale', 25.5, 'native', 'native', false, '2032-06-01 10:00:00+00', '2032-06-01', '2033-06-01')
  returning id into g;
  insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, at)
  values (g, 40, 40, 'purchase', '2032-06-01 10:00:00+00');

  perform pg_temp.login(u_st);
  perform pg_temp.ck(pg_temp.try($q$select booking.admin_report_accrual('2032-06-01', '2032-06-30')$q$) = 'forbidden', 'B1 staff ei saa kuukautta');
  perform pg_temp.ck(pg_temp.try($q$select booking.admin_report_accrual_csv('2032-06-01', '2032-06-01')$q$) = 'forbidden', 'B2 staff ei saa CSV:tä');
  june := pg_temp.call($q$booking.admin_report_accrual('2032-06-01', '2032-06-01')$q$);
  perform pg_temp.ck(june ->> 'err' is null, 'B3 staff saa yhden päivän: ' || coalesce(june ->> 'err', 'ok'));
  perform pg_temp.logout();

  pay := booking._report_json('2032-06-01', '2032-06-30', false, false);
  perform pg_temp.login(u_mgr);
  june := booking.admin_report_accrual('2032-06-01', '2032-06-30');
  dec := booking.admin_report_accrual('2032-12-01', '2032-12-31');
  perform pg_temp.ck((pay #>> '{totals,gross}')::numeric = 125.50, 'C1 kassaperuste kesäkuussa: ' || coalesce(pay #>> '{totals,gross}', 'null'));
  perform pg_temp.ck((june #>> '{totals,sales_gross}')::numeric = 0, 'C2 suorite kesäkuussa 0');
  perform pg_temp.ck((dec #>> '{totals,sales_gross}')::numeric = 125.50, 'C3 suorite joulukuussa 125,50');
  perform pg_temp.ck((june #>> '{advances,services,gross}')::numeric = 125.50, 'C4 ennakko kesäkuun lopussa');
  perform pg_temp.ck((dec #>> '{advances,services,gross}')::numeric = 0, 'C5 joulukuun lopussa palvelu ei ole enää ennakko');
  perform pg_temp.ck((june #>> '{advances,gift_cards_unused,gross}')::numeric = 40, 'C6 lahjakorttisaldo oma rivi');
  perform pg_temp.ck((june #>> '{advances,gift_cards_unused,vat_at_sale}')::boolean, 'C7 lahjakortin ALV myynnissä');
  perform pg_temp.ck((june #>> '{advances,total_gross}')::numeric = 165.50, 'C8 ennakot yhteensä');
  perform pg_temp.ck((booking.admin_report_accrual('2033-07-01', '2033-07-01') #>> '{advances,gift_cards_unused,gross}')::numeric = 0, 'C9 vanhentunut kortti ei ole ennakko');
  csv := booking.admin_report_accrual_csv('2032-06-01', '2032-06-30') ->> 'content';
  perform pg_temp.ck(left(csv, 1) = chr(65279) and csv like '%' || E'\r\n' || '%' and position('osio;tuote;alv_%' in csv) > 0 and position('ennakko;Lahjakortit kayttamatta' in csv) > 0, 'D1 CSV BOM, rivinvaihto, ennakkorivi');
  perform pg_temp.ck((booking.admin_report_accrual_csv('2032-06-01', '2032-06-30') ->> 'filename') = 'suorite_2032-06-01_2032-06-30.csv', 'D2 tiedostonimi');
  perform pg_temp.logout();

  log := current_setting('t219.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
