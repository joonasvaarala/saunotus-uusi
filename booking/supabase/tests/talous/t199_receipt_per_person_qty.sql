-- t199: booking_199. Henkilöhintainen kuitti näyttää henkilömäärän ja à-hinnan.
-- Loppusumma ja ALV eivät muutu. Ajo migraatioiden ja fixtures/10_test_helpers.sql:n jälkeen.
-- Lopussa RAISE 'TESTRESULT pass=N fail=M' ja ROLLBACK.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t199.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t199.log', coalesce(current_setting('t199.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function pg_temp.issue(p_cu bigint, p_lines jsonb) returns bigint language plpgsql as $$
declare o bigint; it bigint; p bigint; r bigint; ln jsonb; v_total numeric := 0;
begin
  for ln in select * from jsonb_array_elements(p_lines) loop
    v_total := v_total + (ln ->> 'gross')::numeric;
  end loop;
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale)
  values (p_cu, 'confirmed', 'unpaid', v_total, 'admin', 'fi') returning id into o;
  insert into booking.payments(order_id, method, status, amount, provider)
  values (o, 'card_terminal', 'pending', v_total, 'manual') returning id into p;
  for ln in select * from jsonb_array_elements(p_lines) loop
    insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
    values (o, ln ->> 'name', coalesce(ln ->> 'kind', 'reservation'), coalesce((ln ->> 'item_qty')::int, 1), (ln ->> 'gross')::numeric, (ln ->> 'gross')::numeric, 25.5, ln -> 'breakdown')
    returning id into it;
    insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
    values (p, it, ln ->> 'name', coalesce(ln ->> 'kind', 'reservation'), coalesce((ln ->> 'pay_qty')::int, 1), (ln ->> 'gross')::numeric, 25.5);
  end loop;
  update booking.payments set status = 'paid', paid_at = now() where id = p;
  select id into r from booking.receipts where payment_id = p and kind = 'receipt';
  if r is null then raise exception 't199 receipt missing'; end if;
  return r;
end $$;

do $t$
declare
  run text := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
  cu bigint; rid bigint; line jsonb; snap jsonb; gross numeric; u jsonb;
  log text; np int; nf int;
  old_id bigint; old_total numeric; old_vat jsonb; pay bigint; item bigint;
begin
  u := booking._receipt_per_person_units(58, 2);
  perform pg_temp.ck((u ->> 'quantity')::int = 2 and (u ->> 'unit_gross')::numeric = 29, 'A1 58 € / 2 hlö = 2 × 29');
  perform pg_temp.ck(booking._receipt_per_person_units(58, 3) is null, 'A2 epätasainen jako ei vaihda kpl-määrää');
  perform pg_temp.ck((booking._receipt_per_person_units(-58, 2) ->> 'quantity')::int = 2
                      and (booking._receipt_per_person_units(-58, 2) ->> 'unit_gross')::numeric = -29, 'A3 hyvitys 2 × -29');
  perform pg_temp.ck(booking._receipt_per_person_units(49, null) is null, 'A4 ilman henkilömäärää ei jakoa');

  insert into booking.customers(name, email) values ('T199 Testi', 't199-' || run || '@example.invalid') returning id into cu;
  rid := pg_temp.issue(cu, jsonb_build_array(
    jsonb_build_object('name', 'Yleinen vuoro', 'gross', 58, 'kind', 'reservation', 'item_qty', 1, 'pay_qty', 1,
      'breakdown', jsonb_build_object('mode', 'per_person', 'unit_price', 29, 'persons', 2)),
    jsonb_build_object('name', 'Pyyhe', 'gross', 5, 'kind', 'addon', 'item_qty', 1, 'pay_qty', 1, 'breakdown', '{}'::jsonb)));
  select snapshot, total_gross into snap, gross from booking.receipts where id = rid;
  select l into line from jsonb_array_elements(snap -> 'lines') l where l ->> 'description' = 'Yleinen vuoro';
  perform pg_temp.ck((line ->> 'quantity')::int = 2 and (line ->> 'unit_gross')::numeric = 29 and (line ->> 'line_gross')::numeric = 58, 'B1 yleinen vuoro 2 × 29 = 58');
  select l into line from jsonb_array_elements(snap -> 'lines') l where l ->> 'description' = 'Pyyhe';
  perform pg_temp.ck((line ->> 'quantity')::int = 1 and (line ->> 'unit_gross')::numeric = 5 and (line ->> 'line_gross')::numeric = 5, 'B2 pyyhe säilyy 1 × 5');
  perform pg_temp.ck((select sum((x ->> 'line_gross')::numeric) from jsonb_array_elements(snap -> 'lines') x) = (select total_gross from booking.receipts where id = rid)
                      and (select sum((x ->> 'gross')::numeric) from jsonb_array_elements(snap -> 'vat') x) = (select total_gross from booking.receipts where id = rid)
                      and (select total_gross from booking.receipts where id = rid) = 63, 'B3 loppusumma 63 € ja ALV ennallaan');
  perform pg_temp.ck(position('2 × 29,00 € = 58,00 €' in (select text_body from booking.receipts where id = rid)) > 0, 'B4 tekstikuitti näyttää à-hinnan');

  rid := pg_temp.issue(cu, jsonb_build_array(jsonb_build_object(
    'name', 'Kiinteä vuoro', 'gross', 40, 'kind', 'reservation', 'breakdown', jsonb_build_object('mode', 'fixed', 'persons', 2))));
  select l into line from jsonb_array_elements((select snapshot -> 'lines' from booking.receipts where id = rid)) l;
  perform pg_temp.ck((line ->> 'quantity')::int = 1 and (line ->> 'unit_gross')::numeric = 40 and (line ->> 'line_gross')::numeric = 40, 'C1 kiinteä hinta ei jaeta henkilöille');

  rid := pg_temp.issue(cu, jsonb_build_array(jsonb_build_object(
    'name', 'Epätasainen', 'gross', 10, 'kind', 'reservation', 'breakdown', jsonb_build_object('mode', 'per_person', 'persons', 3))));
  select l into line from jsonb_array_elements((select snapshot -> 'lines' from booking.receipts where id = rid)) l;
  perform pg_temp.ck((line ->> 'quantity')::int = 1 and (line ->> 'line_gross')::numeric = 10, 'C2 epätasainen per_person jää yhdelle riville');

  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale)
  values (cu, 'confirmed', 'paid', 58, 'admin', 'fi') returning id into item;
  insert into booking.payments(order_id, method, status, amount, provider)
  values (item, 'card_terminal', 'pending', 58, 'manual') returning id into pay;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
  values (item, 'Yleinen vuoro', 'reservation', 1, 58, 58, 25.5, '{"mode":"per_person","unit_price":29,"persons":2}'::jsonb)
  returning id into old_id;
  insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
  values (pay, old_id, 'Yleinen vuoro', 'reservation', 1, 58, 25.5);
  insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, total_gross, snapshot, text_body, pdf_path)
  values ('T199-' || run, 'receipt', 'T199', 2099, 1, item, pay, 58,
    jsonb_build_object('v', 1, 'document', 'receipt', 'receipt_no', 'T199-' || run, 'locale', 'fi', 'total_gross', 58, 'total_net', 46.22, 'total_vat', 11.78, 'total_paid', 58, 'rounding', 0,
      'seller', '{}'::jsonb, 'payment', jsonb_build_object('method_label', 'Kortti'),
      'vat', jsonb_build_array(jsonb_build_object('rate', 25.5, 'net', 46.22, 'vat', 11.78, 'gross', 58)),
      'lines', jsonb_build_array(jsonb_build_object('description', 'Yleinen vuoro', 'quantity', 1, 'unit_gross', 58, 'unit_net', 46.22, 'line_gross', 58, 'line_net', 46.22, 'vat_rate', 25.5))),
    'vanha', 'T199-' || run || '.pdf')
  returning id, total_gross, snapshot -> 'vat' into old_id, old_total, old_vat;
  perform pg_temp.ck(booking._receipt_refresh_per_person_qty() >= 1, 'D1 vanha kuitti päivitetään');
  select snapshot, total_gross into snap, gross from booking.receipts where id = old_id;
  select l into line from jsonb_array_elements(snap -> 'lines') l;
  perform pg_temp.ck(gross = old_total and snap -> 'vat' = old_vat
                      and (line ->> 'quantity')::int = 2 and (line ->> 'unit_gross')::numeric = 29 and (line ->> 'line_gross')::numeric = 58
                      and (line ->> 'line_net')::numeric = 46.22
                      and (select pdf_path is null from booking.receipts where id = old_id)
                      and position('2 × 29,00 € = 58,00 €' in (select text_body from booking.receipts where id = old_id)) > 0, 'D2 1 × 58 muuttuu 2 × 29, summa ja ALV ennallaan');
  perform pg_temp.ck(booking._receipt_refresh_per_person_qty() = 0, 'D3 toinen ajo ei muuta mitään');

  log := current_setting('t199.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end
$t$;
rollback;
