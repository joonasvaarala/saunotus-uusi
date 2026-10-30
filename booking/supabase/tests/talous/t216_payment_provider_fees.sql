-- t216: booking_216 maksuvälittäjän provisio.
--   A) provisio poimitaan payloadista; amount ei ole provisio; trigger täyttää sarakkeen.
--   B) sääntö vain jos toteutunutta ei ole; tarkempi maksutapa voittaa tähden; hyvitys erikseen.
--   C) jakso on Helsinki-päivä; CSV puolipiste ja pilkku; kuitti ei näytä Montonio-nimeä.
--   D) reports.view ja settings.edit; anon ei suorita.
-- Aja migraatioiden jälkeen. Yksi transaktio, lopussa TESTRESULT + ROLLBACK.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t216.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t216.log', coalesce(current_setting('t216.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
create function pg_temp.try(p_sql text) returns text language plpgsql as $$
declare v_state text; v_detail text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
  return v_state || ':' || coalesce(v_detail, '');
end $$;

do $t$
declare
  run text := substr(md5(gen_random_uuid()::text), 1, 10);
  u_adm uuid := gen_random_uuid(); u_st uuid := gen_random_uuid();
  o bigint; p_act bigint; p_est bigint; p_miss bigint; p_spec bigint; p_edge bigint; p_out bigint;
  rid bigint; rep jsonb; csv text; rowj jsonb; log text; np int; nf int; ns int;
begin
  perform pg_temp.ck(booking._extract_provider_fee('{"merchantFee":1.25,"grandTotal":100}'::jsonb) = 1.25, 'A1 merchantFee');
  perform pg_temp.ck(booking._extract_provider_fee('{"feeCents":150,"amount":40}'::jsonb) = 1.5, 'A2 sentit, juuren amount ei ole provisio');
  perform pg_temp.ck(booking._extract_provider_fee('{"fees":{"amount":"0.35"}}'::jsonb) = 0.35, 'A3 fees.amount');
  perform pg_temp.ck(booking._extract_provider_fee('{"settlement":{"feeAmount":0.9}}'::jsonb) = 0.9, 'A4 settlement.feeAmount');
  perform pg_temp.ck(booking._extract_provider_fee('{"commission":0}'::jsonb) = 0, 'A5 nolla on toteutunut');
  perform pg_temp.ck(booking._extract_provider_fee('{"amount":40,"grandTotal":40}'::jsonb) is null, 'A6 pelkkä summa ei riitä');
  perform pg_temp.ck(booking._extract_provider_fee('{"senderIban":"FI00","fee":"1,10"}'::jsonb) = 1.10, 'A7 pilkku');

  insert into auth.users(id, email) values
    (u_adm, 't216-admin-' || run || '@example.test'),
    (u_st, 't216-staff-' || run || '@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_adm, 't216-admin-' || run || '@example.test', 't216 manager', 'manager'),
    (u_st, 't216-staff-' || run || '@example.test', 't216 staff', 'staff');

  insert into booking.orders(status, payment_status, total_gross, source_channel, locale)
  values ('confirmed', 'unpaid', 178, 'admin', 'fi') returning id into o;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o, 'T216 palvelu', 'product', 1, 178, 178, 25.5);

  insert into booking.payments(order_id, method, provider, status, amount, paid_at, raw)
  values (o, 'montonio', 'montonio', 'paid', 100, timestamptz '2032-05-15 10:00+03', '{"merchantFee":1.25,"paymentStatus":"PAID"}'::jsonb)
  returning id into p_act;
  perform pg_temp.ck((select provider_fee from booking.payments where id = p_act) = 1.25, 'A8 trigger täyttää provider_fee');
  perform pg_temp.ck(
    not exists (select 1 from booking.receipts r where r.payment_id = p_act and r.text_body ilike '%montonio%')
    and not exists (select 1 from booking.receipts r where r.payment_id = p_act and coalesce(r.snapshot #>> '{payment,method_label}', '') ilike '%montonio%'),
    'C3 kuitti ei näytä Montonio-nimeä');

  insert into booking.payments(order_id, method, provider, status, amount, paid_at, raw)
  values
    (o, 'visma_pay', 'visma_pay', 'paid', 40, timestamptz '2032-05-16 12:00+03', '{"paymentStatus":"settled"}'::jsonb),
    (o, 'card_terminal', 'manual', 'paid', 20, timestamptz '2032-05-16 13:00+03', '{}'::jsonb),
    (o, 'montonio', 'montonio', 'paid', 10, timestamptz '2032-05-18 09:00+03', '{}'::jsonb),
    (o, 'montonio', 'montonio', 'paid', 8, timestamptz '2032-04-30 21:30+00', '{"fee":0.08}'::jsonb),
    (o, 'montonio', 'montonio', 'paid', 9, timestamptz '2032-05-31 21:30+00', '{"fee":0.09}'::jsonb);
  select id into p_est from booking.payments where order_id = o and provider = 'visma_pay';
  select id into p_miss from booking.payments where order_id = o and method = 'card_terminal';
  select id into p_spec from booking.payments where order_id = o and provider = 'montonio' and amount = 10;
  select id into p_edge from booking.payments where order_id = o and amount = 8;
  select id into p_out from booking.payments where order_id = o and amount = 9;
  perform pg_temp.ck((select provider_fee from booking.payments where id = p_edge) = 0.08, 'A9 rajapäivän provisio');
  perform pg_temp.ck((select (paid_at at time zone 'Europe/Helsinki')::date from booking.payments where id = p_out) = date '2032-06-01', 'C1 kesäkuun puolella');

  insert into booking.refunds(payment_id, order_id, amount, status, provider, done_at, raw)
  values (p_act, o, 20, 'done', 'montonio', timestamptz '2032-05-20 15:00+03', '{"feeAmount":0.20}'::jsonb)
  returning id into rid;
  perform pg_temp.ck((select provider_fee from booking.refunds where id = rid) = 0.20, 'A10 hyvityksen provisio');

  perform pg_temp.login(u_adm);
  perform booking.admin_upsert_payment_fee_rule('{"provider":"montonio","method":"*","fixed_eur":0,"percent":2,"active":true}'::jsonb);
  perform booking.admin_upsert_payment_fee_rule('{"provider":"montonio","method":"montonio","fixed_eur":"0,25","percent":1,"active":true}'::jsonb);
  perform booking.admin_upsert_payment_fee_rule('{"provider":"visma_pay","method":"visma_pay","fixed_eur":0.5,"percent":1,"active":true}'::jsonb);
  rep := booking.admin_report_provider_fees('2032-05-01', '2032-05-31', 'json');
  perform pg_temp.logout();

  perform pg_temp.ck((rep -> 'period' ->> 'from') = '2032-05-01' and (rep ->> 'basis') = 'paid_at', 'C2 jakso ja peruste');
  select x into rowj from jsonb_array_elements(rep -> 'rows') x
   where x ->> 'direction' = 'sale' and x ->> 'provider' = 'montonio' and x ->> 'basis' = 'actual';
  perform pg_temp.ck((rowj ->> 'provider_label') = 'Montonio' and (rowj ->> 'method_label') = 'Maksa verkossa'
      and (rowj ->> 'count')::int = 2 and (rowj ->> 'gross')::numeric = 108 and (rowj ->> 'fee')::numeric = 1.33
      and (rowj ->> 'net')::numeric = 106.67, 'B1 toteutunut Montonio, netto brutto miinus provisio');
  select x into rowj from jsonb_array_elements(rep -> 'rows') x
   where x ->> 'direction' = 'sale' and x ->> 'provider' = 'montonio' and x ->> 'basis' = 'estimated';
  perform pg_temp.ck((rowj ->> 'count')::int = 1 and (rowj ->> 'gross')::numeric = 10 and (rowj ->> 'fee')::numeric = 0.35
      and (rowj ->> 'net')::numeric = 9.65, 'B2 tarkempi sääntö 0,25 + 1 %');
  select x into rowj from jsonb_array_elements(rep -> 'rows') x
   where x ->> 'provider' = 'visma_pay' and x ->> 'direction' = 'sale';
  perform pg_temp.ck((rowj ->> 'basis') = 'estimated' and (rowj ->> 'provider_label') = 'Visma Pay'
      and (rowj ->> 'fee')::numeric = 0.90 and (rowj ->> 'net')::numeric = 39.10, 'B3 Visma-arvio 0,50 + 1 %');
  select x into rowj from jsonb_array_elements(rep -> 'rows') x
   where x ->> 'method' = 'card_terminal';
  perform pg_temp.ck((rowj ->> 'basis') = 'missing' and (rowj ->> 'fee') is null and (rowj ->> 'gross')::numeric = 20, 'B4 ilman sääntöä puuttuu');
  select x into rowj from jsonb_array_elements(rep -> 'rows') x where x ->> 'direction' = 'refund';
  perform pg_temp.ck((rowj ->> 'basis') = 'actual' and (rowj ->> 'gross')::numeric = 20 and (rowj ->> 'fee')::numeric = 0.20
      and (rowj ->> 'net')::numeric = -20.20, 'B5 hyvitys erikseen, netto miinus');
  perform pg_temp.ck((rep -> 'totals' ->> 'sales_count')::int = 5 and (rep -> 'totals' ->> 'sales_gross')::numeric = 178
      and (rep -> 'totals' ->> 'missing')::int = 1 and (rep -> 'totals' ->> 'settlement') is null
      and (rep -> 'totals' ->> 'refund_count')::int = 1 and (rep -> 'totals' ->> 'refund_net')::numeric = -20.20, 'B6 puuttuva estää tilitettävän summan');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(rep -> 'rows') x where (x ->> 'gross')::numeric in (9)), 'C4 kesäkuun maksu ei ole toukokuussa');

  perform pg_temp.login(u_adm);
  csv := booking.admin_report_provider_fees('2032-05-01', '2032-05-31', 'csv') ->> 'content';
  perform pg_temp.ck(left(csv, 1) = chr(65279) and position('palvelu;maksutapa;laji;lahde;kpl;brutto;provisio;netto' in csv) = 2, 'C5 CSV BOM ja otsikko');
  perform pg_temp.ck(position('Montonio;Maksa verkossa;maksu;toteutunut;2;108,00;1,33;106,67' in csv) > 0, 'C6 suomalainen desimaali');
  perform pg_temp.ck(position('hyvitys;toteutunut;1;20,00;0,20;-20,20' in csv) > 0, 'C7 hyvitysrivi');
  perform pg_temp.ck(position('puuttuu;1;20,00;;' in csv) > 0, 'C8 puuttuva provisio tyhjänä');
  perform pg_temp.ck(pg_temp.try($q$select booking.admin_report_provider_fees('2032-01-01','2033-06-01','json')$q$) like 'BK001:invalid_param%', 'C9 liian pitkä jakso');
  perform pg_temp.ck((booking.admin_upsert_payment_fee_rule('{"provider":" Montonio ","method":"*","fixed_eur":1,"percent":1}'::jsonb) #>> '{rule,provider}') = 'montonio', 'D1 palvelukoodi pienin kirjaimin');
  perform pg_temp.ck(pg_temp.try($q$select booking.admin_upsert_payment_fee_rule('{"provider":"Monto nio","method":"*","fixed_eur":1,"percent":1}'::jsonb)$q$) like 'BK001:invalid_value%', 'D1b virheellinen palvelukoodi');
  perform pg_temp.logout();

  perform pg_temp.login(u_st);
  perform pg_temp.ck(pg_temp.try($q$select booking.admin_report_provider_fees('2032-05-01','2032-05-31','json')$q$) like 'BK001:forbidden%', 'D2 staff ilman reports.view');
  perform pg_temp.ck(pg_temp.try($q$select booking.admin_upsert_payment_fee_rule('{"provider":"manual","method":"*","fixed_eur":0,"percent":0}'::jsonb)$q$) like 'BK001:forbidden%', 'D3 staff ei tallenna sääntöä');
  perform pg_temp.logout();

  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_report_provider_fees(date,date,text)', 'execute')
      and not has_function_privilege('anon', 'booking.admin_upsert_payment_fee_rule(jsonb)', 'execute')
      and not has_function_privilege('anon', 'booking._extract_provider_fee(jsonb)', 'execute')
      and has_function_privilege('authenticated', 'booking.admin_report_provider_fees(date,date,text)', 'execute'), 'D4 oikeudet');

  perform pg_temp.login(u_adm);
  perform pg_temp.ck((booking.admin_delete_payment_fee_rule((select id from booking.payment_fee_rules where provider = 'visma_pay' and method = 'visma_pay')) ->> 'ok')::boolean, 'D5 poisto');
  perform pg_temp.ck(pg_temp.try('select booking.admin_delete_payment_fee_rule(-1)') like 'BK001:not_found%', 'D6 tuntematon sääntö');
  perform pg_temp.logout();

  log := current_setting('t216.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  ns := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'S %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% skip=% %', np, nf, ns, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
