-- t199: booking_199/200. Henkilöhintainen kuitti näyttää henkilömäärän ja à-hinnan.
-- Osahyvitys on 1 × à-hinta, ei alkuperäinen henkilömäärä × puolitettu hinta.
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
  pay bigint; ord bigint; v_pl bigint; rf bigint; hid bigint; sale bigint;
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
  sale := rid;
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

  perform pg_temp.ck(to_regprocedure('booking._receipt_refresh_per_person_qty()') is null, 'D1 kertakorjaus ei ole enää kutsuttavissa');
  u := booking._receipt_refund_units(-29, 29, 2, null);
  perform pg_temp.ck((u ->> 'quantity')::int = 1 and (u ->> 'unit_gross')::numeric = -29, 'E1 yhden henkilön osuus on 1 × -29, ei 2 × -14,50');
  u := booking._receipt_refund_units(-58, 29, 2, null);
  perform pg_temp.ck((u ->> 'quantity')::int = 2 and (u ->> 'unit_gross')::numeric = -29, 'E2 koko rivin hyvitys on 2 × -29');
  u := booking._receipt_refund_units(-20, 29, 2, null);
  perform pg_temp.ck((u ->> 'quantity')::int = 1 and (u ->> 'unit_gross')::numeric = -20, 'E3 epätasainen hyvitys on 1 × summa');
  u := booking._receipt_refund_units(-29, 29, 2, 1);
  perform pg_temp.ck((u ->> 'quantity')::int = 1 and (u ->> 'unit_gross')::numeric = -29, 'E4 rivin persons=1 säilyy');

  select r.payment_id, r.order_id into pay, ord from booking.receipts r where r.id = sale;
  select l.id into v_pl from booking.payment_lines l where l.payment_id = pay and l.description = 'Yleinen vuoro';
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines, done_at)
  values (pay, ord, 29, 'yksi henkilö', 'done', 'manual', jsonb_build_array(jsonb_build_object('payment_line_id', v_pl, 'amount', 29)), now())
  returning id into rf;
  hid := booking._issue_refund_receipt(rf);
  select snapshot, total_gross into snap, gross from booking.receipts where id = hid;
  select l into line from jsonb_array_elements(snap -> 'lines') l;
  perform pg_temp.ck(hid is not null and gross = -29
                      and (line ->> 'quantity')::int = 1 and (line ->> 'unit_gross')::numeric = -29 and (line ->> 'line_gross')::numeric = -29
                      and (select sum((x ->> 'gross')::numeric) from jsonb_array_elements(snap -> 'vat') x) = gross
                      and position('1 × -29,00 € = -29,00 €' in (select text_body from booking.receipts where id = hid)) > 0, 'F1 hyvityskuitti 1 × -29, ALV ja summa -29');

  log := current_setting('t199.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end
$t$;
rollback;
