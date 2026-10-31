-- t224: lasku on myyntitosite. Maksuksi merkitseminen ei luo K-kuittia
-- eikä muuta myyntiraportin tai ALV:n lukuja. Laskuraportti ja maksutapojen
-- laskutettu rivi käyttävät laskun päivää. Hyvityslasku on oma osio.
-- Aja migraatioiden jälkeen. Yksi transaktio, lopussa TESTRESULT + ROLLBACK.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t224.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t224.log', coalesce(current_setting('t224.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
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
  u uuid := gen_random_uuid();
  o_id bigint; inv jsonb; credit jsonb; rep jsonb; before_n int; after_n int; gross numeric;
  log text; np int; nf int;
begin
  perform pg_temp.ck(
    (select count(*) from information_schema.columns where table_schema = 'booking' and table_name = 'invoices' and column_name in ('procountor_invoice_id', 'procountor_export_status')) = 2,
    'C1 procountor-kentät');
  insert into auth.users(id, email) values (u, 't224-mgr@example.test');
  insert into booking.staff(user_id, email, name, role) values (u, 't224-mgr@example.test', 't224 manager', 'manager');
  insert into booking.orders(order_no, status, payment_status, total_gross, currency, source_channel, locale, customer_kind, billing)
  values (990224, 'confirmed', 'paid', 303.50, 'EUR', 'web', 'fi', 'company',
          '{"company":"T224 Oy","business_id":"0112038-9","street":"Kuja 1","zip":"00100","city":"Helsinki","country":"FI","einvoice_address":"003701120389","einvoice_operator":"003723327487"}'::jsonb)
  returning id into o_id;
  insert into booking.order_items(order_id, product_name, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_id, 't224 sauna', 1, 303.50, 303.50, 25.5);
  insert into booking.payments(order_id, method, provider, status, amount) values (o_id, 'invoice', 'manual', 'pending', 303.50);
  update booking.orders set payment_status = 'unpaid' where id = o_id;

  perform pg_temp.login(u);
  inv := booking.admin_send_invoice((select id from booking.invoices where order_id = o_id and kind = 'debit'), true, false);
  perform pg_temp.logout();
  perform pg_temp.ck(inv ->> 'status' = 'sent' and inv ->> 'invoice_no' is not null, 'S1 lasku lähetetty: ' || coalesce(inv ->> 'err', inv ->> 'invoice_no', 'null'));
  alter table booking.invoices disable trigger invoices_lock;
  update booking.invoices set invoice_date = '2036-04-10', due_date = '2036-05-10' where id = (inv ->> 'id')::bigint;
  alter table booking.invoices enable trigger invoices_lock;
  gross := (select total_gross from booking.invoices where id = (inv ->> 'id')::bigint);
  perform pg_temp.ck(gross = 303.50, 'S2 brutto 303,50');
  perform pg_temp.ck((select procountor_invoice_id is null and procountor_export_status is null from booking.invoices where id = (inv ->> 'id')::bigint), 'S3 vientikentät tyhjiä');

  select count(*) into before_n from booking.receipts rc join booking.payments p on p.id = rc.payment_id where p.order_id = o_id;
  perform pg_temp.login(u);
  inv := booking.admin_mark_invoice_paid((inv ->> 'id')::bigint);
  perform pg_temp.logout();
  select count(*) into after_n from booking.receipts rc join booking.payments p on p.id = rc.payment_id where p.order_id = o_id;
  perform pg_temp.ck(inv ->> 'status' = 'paid', 'P1 tila maksettu');
  perform pg_temp.ck(before_n = after_n, 'P2 ei K-kuittia');
  perform pg_temp.ck(exists (select 1 from booking.audit_log a where a.action = 'INVOICE_MARK_PAID' and a.row_pk = inv ->> 'id'), 'P3 kirjausketju');
  alter table booking.invoices disable trigger invoices_lock;
  update booking.invoices set paid_at = '2036-05-02 12:00:00+00' where id = (inv ->> 'id')::bigint;
  alter table booking.invoices enable trigger invoices_lock;

  perform pg_temp.login(u);
  rep := booking.admin_report_range('2036-04-01', '2036-04-30');
  perform pg_temp.ck(coalesce((rep #>> '{totals,gross}')::numeric, 0) = 0 and coalesce((rep #>> '{totals,vat_after_refunds}')::numeric, 0) = 0, 'R1 huhtikuun myynti ja ALV ennallaan');
  perform pg_temp.ck(coalesce((rep #>> '{reconciliation,invoiced}')::numeric, 0) = gross, 'R2 maksutapojen laskutettu rivi on laskun brutto');
  rep := booking.admin_report_range('2036-05-01', '2036-05-31');
  perform pg_temp.ck(coalesce((rep #>> '{totals,gross}')::numeric, 0) = 0 and coalesce((rep #>> '{reconciliation,invoiced}')::numeric, 0) = 0, 'R3 maksukuukauden myynti ja laskutettu ennallaan');
  rep := booking.admin_report_invoices('2036-04-01', '2036-04-30', 'json');
  perform pg_temp.ck((select count(*) from jsonb_array_elements(rep -> 'invoices') e where e ->> 'invoice_no' = inv ->> 'invoice_no' and (e ->> 'gross')::numeric = gross and (e ->> 'vat')::numeric > 0 and e ->> 'status' = 'paid') = 1, 'L1 laskuraportti laskun päivältä, ALV mukana');
  credit := booking.admin_credit_invoice((inv ->> 'id')::bigint);
  credit := booking.admin_send_invoice((credit ->> 'id')::bigint, true, false);
  perform pg_temp.logout();
  alter table booking.invoices disable trigger invoices_lock;
  update booking.invoices set invoice_date = '2036-04-20', due_date = '2036-04-20' where id = (credit ->> 'id')::bigint;
  alter table booking.invoices enable trigger invoices_lock;
  perform pg_temp.login(u);
  rep := booking.admin_report_invoices('2036-04-01', '2036-04-30', 'json');
  perform pg_temp.logout();
  perform pg_temp.ck((select count(*) from jsonb_array_elements(rep -> 'credits') e where e ->> 'invoice_no' = credit ->> 'invoice_no' and (e ->> 'gross')::numeric < 0) = 1, 'H1 hyvityslasku omassa osiossa');
  perform pg_temp.ck(not exists (select 1 from booking.receipts rc join booking.payments p on p.id = rc.payment_id where p.order_id = o_id and p.method = 'invoice'), 'H2 hyvitys ei luonut kuittia');

  log := current_setting('t224.log', true);
  np := (length(log) - length(replace(log, 'P ', ''))) / 2;
  nf := (length(log) - length(replace(log, 'F ', ''))) / 2;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
