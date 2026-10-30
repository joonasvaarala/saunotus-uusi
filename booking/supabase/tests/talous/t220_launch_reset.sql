-- t220: käyttöönoton nollausskripti siemennetyssä kannassa.
-- Aja booking/supabase-kansiosta migraatioiden jälkeen:
--   psql -v ON_ERROR_STOP=1 -d booking_test -f tests/talous/t220_launch_reset.sql
-- Skripti ajetaan \ir:llä. Poisto peruutetaan tämän transaktion lopussa.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '180s';
select set_config('t220.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t220.log', coalesce(current_setting('t220.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 180) end;
end $$;

\ir ../../../scripts/reset_before_launch.sql

do $t$
declare
  cu bigint; o bigint; p bigint; rc bigint; ic bigint; g bigint; gj bigint;
  inv bigint; v_before int; v_johku int; v_settings int; v_products int;
  dry jsonb; applied jsonb; verify jsonb;
  log text; np int; nf int; v_seq text; v_next bigint;
begin
  insert into booking.customers(name, email) values ('T220 Natiivi', 't220-native@example.test') returning id into cu;
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale)
  values (cu, 'confirmed', 'paid', 40, 'admin', 'fi') returning id into o;
  alter table booking.payments disable trigger payments_paid_ins;
  alter table booking.payments disable trigger payments_paid_upd;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at)
  values (o, 'card_terminal', 'manual', 'paid', 40, now()) returning id into p;
  alter table booking.payments enable trigger payments_paid_ins;
  alter table booking.payments enable trigger payments_paid_upd;
  insert into booking.payment_lines(payment_id, description, kind, quantity, amount_gross, vat_rate)
  values (p, 'T220 vuoro', 'reservation', 1, 40, 25.5);
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines)
  values (p, o, 10, 'Osa', 'failed', 'montonio', jsonb_build_array(jsonb_build_object('payment_line_id', (select id from booking.payment_lines where payment_id = p), 'amount', 10)));
  insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, issued_at, total_gross, snapshot, text_body)
  values ('K-2034-900220', 'receipt', 'K', 2034, 900220, o, p, now(), 40, '{"lines":[]}'::jsonb, 't220') returning id into rc;
  insert into booking.email_outbox(kind, order_id, payment_id, dedupe_key, payload)
  values ('order_confirmation', o, p, 't220:' || o::text, '{}'::jsonb);
  insert into booking.invoice_customers(company_name) values ('T220 Oy') returning id into ic;
  insert into booking.invoices(customer_id, order_id, status, kind, due_date, seller_snapshot, customer_snapshot)
  values (ic, o, 'draft', 'debit', (now() at time zone 'Europe/Helsinki')::date + 14, '{"name":"T220"}'::jsonb, '{"company":"T220 Oy"}'::jsonb)
  returning id into inv;
  insert into booking.invoice_lines(invoice_id, line_no, description, quantity, unit_price_net, vat_rate, line_net, line_vat, line_gross)
  values (inv, 1, 'T220', 1, 31.87, 25.5, 31.87, 8.13, 40);
  update booking.invoices set status = 'sent', invoice_no = 'L000220', seq = 220 where id = inv;
  update booking.invoice_counters set last_seq = greatest(last_seq, 220) where series = 'L';
  insert into booking.receipt_counters(series, year, last_seq) values ('K', 2034, 900220)
  on conflict (series, year) do update set last_seq = 900220;
  insert into booking.gift_cards(code, issuer, initial_amount, balance, status, source, accounting_origin, vat_treatment, complimentary, purchase_order_id, activated_at, valid_to)
  values ('T220NATIVE01', 'own', 40, 40, 'active', 'native', 'native', 'at_sale', false, o, now(), '2035-01-01')
  returning id into g;
  insert into booking.gift_card_ledger(gift_card_id, order_id, delta, balance_after, reason)
  values (g, o, 40, 40, 'purchase');
  insert into booking.audit_log(table_name, row_pk, action, new_data)
  values ('orders', o::text, 'INSERT', jsonb_build_object('order_id', o));

  insert into booking.orders(status, payment_status, total_gross, source_channel, locale, external_source, external_id, johku_order_no, order_no)
  values ('confirmed', 'paid', 15, 'johku_import', 'fi', 'johku', 't220-johku', 770220, 770220);
  insert into booking.gift_cards(code, issuer, initial_amount, balance, status, source, accounting_origin, vat_treatment)
  values ('T220JOHKU001', 'johku', 15, 15, 'active', 'johku', 'johku', 'at_sale')
  returning id into gj;
  insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason)
  values (gj, 15, 15, 'johku_purchase');

  select count(*) into v_johku from booking.orders where external_source = 'johku' or source_channel = 'johku_import' or johku_order_no is not null;
  select count(*) into v_settings from booking.settings;
  select count(*) into v_products from kb.products;
  select count(*) into v_before from booking.orders where id = o;

  dry := booking.cutover_reset(true);
  perform pg_temp.ck((dry ->> 'dry_run')::boolean and (dry ->> 'applied')::boolean = false, 'A1 kuivaharjoitus');
  perform pg_temp.ck((dry #>> '{counts,orders}')::int >= 1 and (dry #>> '{counts,receipts}')::int >= 1 and (dry #>> '{counts,invoices}')::int >= 1, 'A2 määrät: ' || coalesce(dry ->> 'counts', 'null'));
  perform pg_temp.ck((select count(*) from booking.orders where id = o) = v_before, 'A3 kuivaharjoitus ei poista');
  perform pg_temp.ck((dry #>> '{kept,johku_orders}')::int = v_johku, 'A4 Johku säilyy laskennassa');

  applied := booking.cutover_reset(false);
  verify := booking.cutover_reset_verify();
  perform pg_temp.ck((applied ->> 'applied')::boolean, 'B1 poisto ajettiin: ' || coalesce(applied ->> 'note', applied::text));
  perform pg_temp.ck((verify ->> 'ok')::boolean, 'B2 tarkistus nollamyynti: ' || coalesce(verify::text, 'null'));
  perform pg_temp.ck((select count(*) from booking.orders where id = o) = 0, 'B3 natiivitilaus poissa');
  perform pg_temp.ck((select count(*) from booking.receipts where id = rc) = 0, 'B4 kuitti poissa');
  perform pg_temp.ck((select count(*) from booking.invoices where id = inv) = 0, 'B5 lasku poissa');
  perform pg_temp.ck((select count(*) from booking.gift_cards where id = g) = 0, 'B6 natiivi lahjakortti poissa');
  perform pg_temp.ck((select count(*) from booking.gift_cards where id = gj) = 1, 'B7 Johku-lahjakortti tallella');
  perform pg_temp.ck((select count(*) from booking.gift_card_ledger where gift_card_id = gj) = 1, 'B8 Johku-kirjaus tallella');
  perform pg_temp.ck((select count(*) from booking.orders where johku_order_no = 770220) = 1, 'B9 Johku-tilaus tallella');
  perform pg_temp.ck((select count(*) from booking.settings) = v_settings, 'B10 asetukset tallella');
  perform pg_temp.ck((select count(*) from kb.products) = v_products, 'B11 tuotteet tallella');
  perform pg_temp.ck(coalesce((select max(last_seq) from booking.receipt_counters), 0) = coalesce((select max(seq) from booking.receipts), 0), 'B12 kuittisarja = jäljellä oleva max');
  perform pg_temp.ck((select last_seq from booking.invoice_counters where series = 'L') = coalesce((select max(seq) from booking.invoices where series = 'L'), 0), 'B13 L-sarja = jäljellä oleva max, rivi tallella');
  perform pg_temp.ck((select count(*) from booking.receipts where id = rc) = 0 and coalesce((select max(seq) from booking.receipts where series = 'K' and year = 2034), 0) = 0, 'B12b testikuitti ja sen numero poissa');
  perform pg_temp.ck(not exists (select 1 from booking.audit_log where row_pk = o::text and action = 'INSERT'), 'B14 testiaudit poissa');
  perform pg_temp.ck(exists (select 1 from booking.audit_log where action = 'CUTOVER_RESET'), 'B15 nollaus auditoidaan');
  perform pg_temp.ck((select t.tgenabled from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'booking' and t.tgname = 'receipts_guard') <> 'D', 'B16 kuittitriggeri päällä');
  perform pg_temp.ck((select t.tgenabled from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'booking' and t.tgname = 'gift_card_ledger_append_only') <> 'D', 'B17 kirjaustriggeri päällä');
  perform pg_temp.ck(pg_temp.try(format('delete from booking.gift_card_ledger where gift_card_id = %s', gj)) = 'ledger_append_only', 'B18 Johku-kirjausta ei voi poistaa');

  v_seq := pg_get_serial_sequence('booking.orders', 'order_no');
  select case when s.is_called then s.last_value + 1 else s.last_value end into v_next
    from pg_sequences s
   where s.schemaname = split_part(v_seq, '.', 1) and s.sequencename = split_part(v_seq, '.', 2);
  perform pg_temp.ck(v_next = greatest(10001, coalesce((select max(order_no) from booking.orders), 0) + 1), 'B19 seuraava tilausnumero: ' || coalesce(v_next::text, 'null'));

  log := current_setting('t220.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
