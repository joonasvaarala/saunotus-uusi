-- t223: oma lahjakortti on monikäyttöinen arvoseteli.
-- Myynti ilman ALV:tä, lunastus on K-kuitti tuotteen verokannalla,
-- maksuton kortti ei kirjaudu, Elämyslahjojen polku säilyy.
-- Aja migraatioiden jälkeen. Yksi transaktio, lopussa TESTRESULT + ROLLBACK.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t223.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t223.log', coalesce(current_setting('t223.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 180) end);
end $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;

do $t$
declare
  u uuid := gen_random_uuid();
  res jsonb; rep jsonb; o_sale bigint; o_mix bigint; c_id bigint; code text; gross numeric; rate numeric; name text;
  log text; np int; nf int;
begin
  insert into auth.users(id, email) values (u, 't223-mgr@example.test');
  insert into booking.staff(user_id, email, name, role) values (u, 't223-mgr@example.test', 't223 manager', 'manager');
  update booking.settings set value = 'true'::jsonb where key = 'gift_cards.redeem_enabled';
  perform pg_temp.login(u);
  res := pg_temp.call($q$booking.admin_create_gift_card('entry_2', null, 1, '{"name":"T223","email":"t223@example.test"}'::jsonb, null, null, null, 'card_terminal')$q$);
  perform pg_temp.logout();
  o_sale := (res ->> 'order_id')::bigint;
  gross := (res ->> 'total')::numeric;
  select i.vat_rate, i.product_name into rate, name
    from booking.order_items i where i.order_id = o_sale and i.kind = 'gift_card';
  perform pg_temp.ck(res ->> 'err' is null and rate = 0 and name = 'Lahjakortti (monikäyttöinen arvoseteli, ei ALV)', 'S1 myyntirivi ilman ALV:tä: ' || coalesce(res ->> 'err', name, 'null'));
  alter table booking.receipts disable trigger receipts_guard;
  update booking.receipts set issued_at = '2036-03-01 10:00:00+00' where order_id = o_sale;
  alter table booking.receipts enable trigger receipts_guard;
  update booking.payments set paid_at = '2036-03-01 10:00:00+00' where order_id = o_sale;
  perform pg_temp.login(u);
  rep := booking.admin_report_daily('2036-03-01');
  perform pg_temp.logout();
  perform pg_temp.ck(coalesce((rep #>> '{totals,gross}')::numeric, 0) = 0 and coalesce((rep #>> '{totals,vat}')::numeric, 0) = 0, 'S2 myynti ja ALV eivät sisällä kortin myyntiä');
  perform pg_temp.ck(coalesce((rep #>> '{reconciliation,gift_card_sales}')::numeric, 0) = gross, 'S3 lahjakortin myynti näkyy velkana');
  perform pg_temp.ck((select count(*) from jsonb_array_elements(coalesce(rep -> 'by_vat', '[]'::jsonb)) e where (e ->> 'gross')::numeric = gross) = 0, 'S4 ALV-erittelyssä ei kortin bruttoa');

  insert into booking.customers(name, email) values ('T223 Asiakas', 't223-asiakas@example.test') returning id into c_id;
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, confirmed_at)
  values (c_id, 'confirmed', 'unpaid', 56, 'admin', 'fi', '2036-03-02 09:00:00+00') returning id into o_mix;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_mix, 't223 yleinen', 'reservation', 1, 36, 36, 25.5),
         (o_mix, 't223 juoma', 'reservation', 1, 20, 20, 13.5);
  select g.code into code from booking.gift_cards g where g.purchase_order_id = o_sale;
  perform pg_temp.login(u);
  res := pg_temp.call(format($q$booking.admin_redeem_gift_card(%s, %L, 20, 'juoma')$q$, o_mix, code));
  perform pg_temp.ck(res ->> 'err' is null and res ->> 'accounted' = 'true' and res ->> 'receipt_no' like 'K-%', 'R1 alennettu kanta lunastus on K-kuitti: ' || coalesce(res ->> 'err', res ->> 'receipt_no', 'null'));
  res := pg_temp.call(format($q$booking.admin_redeem_gift_card(%s, %L, 36, 'sauna')$q$, o_mix, code));
  perform pg_temp.ck(res ->> 'err' is null and res ->> 'accounted' = 'true', 'R2 yleinen kanta lunastus on myynti: ' || coalesce(res ->> 'err', res ->> 'receipt_no', 'null'));
  res := pg_temp.call($q$booking.admin_create_gift_card('open', 25, 1, null, null, null, null, null, null, null, 'fi', 't223 maksuton')$q$);
  perform pg_temp.logout();
  perform pg_temp.ck(res ->> 'err' is null and (select count(*) from booking.receipts r where r.order_id = (res ->> 'order_id')::bigint) = 0, 'C1 maksuton kortti ei tee kirjanpitokuittia');
  perform pg_temp.ck(position('partner_voucher_accounted' in pg_get_functiondef('booking._acct_excluded(bigint,bigint)'::regprocedure)) > 0, 'E1 Elämyslahjojen kirjauspolku säilyy');

  log := current_setting('t223.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
