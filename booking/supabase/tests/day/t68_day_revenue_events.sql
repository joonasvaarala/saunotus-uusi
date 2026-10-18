-- t68_day_revenue_events: booking.admin_day_extras (booking_68).
-- Ajo botille (ei CI:ssä, ei tuotantokantaan tätä tiedostoa): psql -v ON_ERROR_STOP=1 -f tämä
-- sen jälkeen kun migraatiot ja testifixtuurit (test.login / test.mk_staff / kb.products) on ladattu.
-- Lopuksi tahallinen poikkeus: TESTRESULT pass=N fail=0 ja koko lohko kumoutuu. Ei taulumuutoksia migraatiossa;
-- tämä testi luo kb.event_dates VAIN jos testikannasta puuttuu (tuotannossa taulu on jo).
set local lock_timeout = '5s';
set local statement_timeout = '90s';

do $t$
declare
  v_admin uuid; v_rule bigint; v_space bigint; v_addon bigint; v_thu date; v_other date; v_fri date; v_sat date;
  v jsonb; v2 jsonb; r jsonb; v_rows jsonb; v_parts jsonb;
  v_paid bigint; v_cancel bigint; v_unpaid bigint; v_addon_res bigint; v_gift bigint; v_noshow bigint; v_expired bigint; v_past bigint; v_hold bigint; v_hidden bigint; v_other_res bigint;
  v_ev bigint; v_ev_cancel bigint; v_gc bigint; v_cust bigint; v_oid bigint; v_item bigint;
  v_paid_order bigint; v_unpaid_line numeric; v_gift_line numeric; v_expect numeric; v_row_n int; v_line numeric; v_order_total numeric;
  v_start timestamptz; v_end timestamptz; v_code text; log text; npass int; nfail int;
  v_included bigint[];
begin
  create function pg_temp.t68_ck(p_ok boolean, p_label text) returns void language plpgsql as $ck$
  begin
    perform set_config('t68.log', coalesce(current_setting('t68.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true);
  end $ck$;
  perform set_config('t68.log', '', true);
  if to_regclass('kb.event_dates') is null then
    create table kb.event_dates (
      id bigint generated always as identity primary key,
      product_id bigint not null references kb.products(id),
      starts_on date not null,
      ends_on date,
      time_text text,
      active boolean not null default true
    );
  end if;

  v_admin := test.mk_staff('t68-admin@example.test', 'admin');
  select min(d)::date into v_thu from generate_series(date '2035-06-01', date '2035-06-07', interval '1 day') d where extract(isodow from d) = 4;
  v_other := v_thu + 7; v_fri := v_thu + 1; v_sat := v_thu + 2;
  select id into v_rule from booking.schedule_rules where label like 'Yleinen vuoro to 17%' and active order by id limit 1;
  select id into v_space from booking.resources where code = 'savusauna';
  select id into v_addon from booking.addons where code = 'saunavihta' and active order by id limit 1;
  if v_rule is null or v_space is null or v_addon is null or v_thu is null then
    raise exception 'TESTRESULT_ABORT rule=% space=% addon=% thu=%', v_rule, v_space, v_addon, v_thu;
  end if;

  perform test.anon();
  v_code := test.code(format('select booking.admin_day_extras(%L)', v_thu));
  perform test.logout();
  perform pg_temp.t68_ck(v_code = 'forbidden', 'A1: anon ei saa kutsua');
  perform test.login(test.mk_user('t68-asiakas@example.test'));
  v_code := test.code(format('select booking.admin_day_extras(%L)', v_thu));
  perform test.logout();
  perform pg_temp.t68_ck(v_code = 'forbidden', 'A2: ei-henkilöstö forbidden');

  perform test.login(v_admin);
  r := booking.admin_create_booking(v_rule, v_thu, 2, null, '{"name":"T68 Maksettu","email":"t68-paid@example.test","phone":"0400006801"}'::jsonb, 'cash', true, null);
  v_paid := (r ->> 'reservation_id')::bigint; v_paid_order := (r ->> 'order_id')::bigint;
  r := booking.admin_create_booking(v_rule, v_thu, 2, null, '{"name":"T68 Peruttu","email":"t68-cancel@example.test","phone":"0400006802"}'::jsonb, 'cash', true, null);
  v_cancel := (r ->> 'reservation_id')::bigint;
  perform booking.admin_set_reservation_status(v_cancel, 'cancelled', 't68');
  r := booking.admin_create_booking(v_rule, v_thu, 1, null, '{"name":"T68 Maksamatta","email":"t68-unpaid@example.test","phone":"0400006803"}'::jsonb, 'pay_later', false, null);
  v_unpaid := (r ->> 'reservation_id')::bigint;
  r := booking.admin_create_booking(v_rule, v_thu, 2, null, '{"name":"T68 Lisa","email":"t68-addon@example.test","phone":"0400006804"}'::jsonb, 'cash', true, null, null, null, null, 'admin', jsonb_build_array(jsonb_build_object('id', v_addon, 'quantity', 1)));
  v_addon_res := (r ->> 'reservation_id')::bigint;
  r := booking.admin_create_booking(v_rule, v_thu, 2, null, '{"name":"T68 Lahjakortti","email":"t68-gift@example.test","phone":"0400006805"}'::jsonb, 'pay_later', false, null);
  v_gift := (r ->> 'reservation_id')::bigint;
  r := booking.admin_create_booking(v_rule, v_thu, 1, null, '{"name":"T68 Poissa","email":"t68-noshow@example.test","phone":"0400006806"}'::jsonb, 'cash', true, null);
  v_noshow := (r ->> 'reservation_id')::bigint;
  perform booking.admin_set_reservation_status(v_noshow, 'no_show', 't68');
  r := booking.admin_create_booking(v_rule, v_other, 2, null, '{"name":"T68 Muu Paiva","email":"t68-other@example.test","phone":"0400006807"}'::jsonb, 'cash', true, null);
  v_other_res := (r ->> 'reservation_id')::bigint;
  perform test.logout();

  -- käynti on v_thu, tilaus luotu 2020: tuotto seuraa käyntiä. Johku-lähde ei pudota riviä.
  update booking.orders set created_at = timestamptz '2020-01-15 10:00+00', external_source = 'johku', external_id = 't68-johku-o1' where id = v_paid_order;
  update booking.reservations set external_source = 'johku', external_id = 't68-johku-r1' where id = v_paid;

  select order_id, order_item_id into v_oid, v_item from booking.reservations where id = v_addon_res;
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, parent_item_id)
  values (v_oid, 'T68 rivinalennus', 'discount', 1, -10, -10, 25.5, v_item);
  insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v_oid, 'T68 tilausale', 'discount', 1, -5, -5, 25.5);
  select total_gross into v_order_total from booking.orders where id = v_oid;
  select coalesce(sum(i.line_total_gross), 0) into v_line
    from booking.order_items i where i.id = v_item or i.parent_item_id = v_item;

  insert into booking.gift_cards(code, issuer, kind, initial_amount, balance, status, source, vat_treatment, accounting_origin, balance_verified, valid_to)
  values ('T68TEST00001', 'own', 'value', 500, 500, 'active', 'native', 'at_redemption', 'native', true, date '2036-01-01')
  returning id into v_gc;
  update booking.payments set method = 'gift_card', gift_card_id = v_gc, status = 'paid', paid_at = now(), amount = 1
   where order_id = (select order_id from booking.reservations where id = v_gift);
  update booking.orders set payment_status = 'paid' where id = (select order_id from booking.reservations where id = v_gift);

  perform test.login(v_admin);
  r := booking.admin_create_booking(v_rule, v_thu, 1, null, '{"name":"T68 Vanhentunut","email":"t68-exp@example.test","phone":"0400006808"}'::jsonb, 'cash', true, null);
  v_expired := (r ->> 'reservation_id')::bigint;
  r := booking.admin_create_booking(v_rule, v_thu, 1, null, '{"name":"T68 Pito Ohi","email":"t68-past@example.test","phone":"0400006809"}'::jsonb, 'cash', true, null);
  v_past := (r ->> 'reservation_id')::bigint;
  r := booking.admin_create_booking(v_rule, v_thu, 1, null, '{"name":"T68 Pito Voimassa","email":"t68-hold@example.test","phone":"0400006810"}'::jsonb, 'cash', true, null);
  v_hold := (r ->> 'reservation_id')::bigint;
  r := booking.admin_create_booking(v_rule, v_thu, 1, null, '{"name":"T68 Piilo","email":"t68-hidden@example.test","phone":"0400006812"}'::jsonb, 'cash', true, null);
  v_hidden := (r ->> 'reservation_id')::bigint;
  perform test.logout();

  update booking.reservations set status = 'expired', hold_expires_at = null where id = v_expired;
  update booking.reservations set status = 'pending', hold_expires_at = now() - interval '1 hour' where id = v_past;
  update booking.reservations set status = 'pending', hold_expires_at = now() + interval '30 minutes' where id = v_hold;
  update booking.reservations set hidden_at = now() where id = v_hidden;

  insert into booking.customers(name, email, phone) values ('T68 Illan Vieras', 't68-ev@example.test', '0400006811') returning id into v_cust;
  v_start := (v_thu::timestamp + time '18:00') at time zone 'Europe/Helsinki';
  v_end := (v_thu::timestamp + time '20:00') at time zone 'Europe/Helsinki';
  insert into booking.orders(status, payment_status, total_gross, customer_id, source_channel, confirmed_at)
  values ('completed', 'paid', 59, v_cust, 'admin', now()) returning id into v_oid;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v_oid, 9, 'Perinnesaunotusilta', 'reservation', 1, 59, 59, 25.5) returning id into v_item;
  insert into booking.reservations(order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, status)
  values (v_oid, v_item, 9, v_space, 'shared', v_start, v_end, 2, 'completed') returning id into v_ev;

  insert into booking.orders(status, payment_status, total_gross, customer_id, source_channel)
  values ('cancelled', 'paid', 59, v_cust, 'admin') returning id into v_oid;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v_oid, 9, 'Perinnesaunotusilta', 'reservation', 1, 59, 59, 25.5) returning id into v_item;
  insert into booking.reservations(order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, status)
  values (v_oid, v_item, 9, v_space, 'shared', v_start, v_end, 1, 'cancelled') returning id into v_ev_cancel;

  insert into kb.event_dates(product_id, starts_on, ends_on, time_text, active) values
    (9, v_thu, null, 'klo 18–20', true),
    (32, v_thu, null, null, true),
    (33, v_fri, v_sat, 'klo 12–16', true);
  v_start := (v_fri::timestamp + time '10:00') at time zone 'Europe/Helsinki';
  v_end := (v_fri::timestamp + time '12:00') at time zone 'Europe/Helsinki';
  insert into booking.orders(status, payment_status, total_gross, customer_id, source_channel, confirmed_at)
  values ('completed', 'paid', 79, v_cust, 'admin', now()) returning id into v_oid;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v_oid, 33, 'Sipoonjoen Kekri', 'reservation', 1, 79, 79, 25.5) returning id into v_item;
  insert into booking.reservations(order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, status)
  values (v_oid, v_item, 33, v_space, 'shared', v_start, v_end, 1, 'completed');

  v_included := array[v_paid, v_unpaid, v_addon_res, v_gift, v_ev];
  select coalesce(sum(g), 0) into v_expect from (
    select coalesce(sum(i.line_total_gross), 0) g
      from booking.reservations r
      left join booking.order_items i on r.order_item_id is not null and (i.id = r.order_item_id or i.parent_item_id = r.order_item_id)
     where r.id = any (v_included)
     group by r.id) s;
  select coalesce(sum(i.line_total_gross), 0) into v_unpaid_line
    from booking.reservations r
    left join booking.order_items i on r.order_item_id is not null and (i.id = r.order_item_id or i.parent_item_id = r.order_item_id)
   where r.id = v_unpaid;
  select coalesce(sum(i.line_total_gross), 0) into v_gift_line
    from booking.reservations r
    left join booking.order_items i on r.order_item_id is not null and (i.id = r.order_item_id or i.parent_item_id = r.order_item_id)
   where r.id = v_gift;

  perform test.login(v_admin);
  v := booking.admin_day_extras(v_thu);
  v2 := booking.admin_day_extras(v_other);
  perform test.logout();
  v_rows := v -> 'revenue_rows';

  perform pg_temp.t68_ck(v ->> 'date' = v_thu::text and v ->> 'tz' = 'Europe/Helsinki', 'B1: päivä ja aikavyöhyke');
  perform pg_temp.t68_ck((v -> 'revenue' ->> 'basis') = 'visit_start' and (v -> 'revenue' ->> 'vat_basis') = 'gross_incl_vat' and (v -> 'revenue' ->> 'currency') = 'EUR', 'B2: perustiedot');
  perform pg_temp.t68_ck((v -> 'revenue' ->> 'gross')::numeric = v_expect, 'B3: brutto = käynnin rivit (peruttu/vanhentunut/no_show/piilo pois): ' || (v -> 'revenue' ->> 'gross') || ' vs ' || v_expect);
  perform pg_temp.t68_ck((v -> 'revenue' ->> 'count')::int = cardinality(v_included), 'B4: kappalemäärä');
  perform pg_temp.t68_ck((v -> 'revenue' ->> 'unpaid_count')::int = 1 and (v -> 'revenue' ->> 'unpaid_gross')::numeric = v_unpaid_line and v_unpaid_line > 0, 'B5: maksamaton vahvistettu on bruttossa ja merkitty');
  perform pg_temp.t68_ck((v -> 'revenue' ->> 'pending_count')::int = 1 and (v -> 'revenue' ->> 'gross')::numeric = v_expect, 'B6: voimassa oleva pito ei ole bruttossa');
  perform pg_temp.t68_ck((select (x ->> 'line_gross')::numeric from jsonb_array_elements(v_rows) x where (x ->> 'reservation_id')::bigint = v_gift) = v_gift_line and v_gift_line > 1, 'B7: lahjakortti lasketaan rivin arvona, ei maksun summana (amount=1)');
  perform pg_temp.t68_ck((select (x ->> 'payment_status') from jsonb_array_elements(v_rows) x where (x ->> 'reservation_id')::bigint = v_gift) = 'paid', 'B8: lahjakorttirivi on maksettu');
  perform pg_temp.t68_ck((select (x ->> 'line_gross')::numeric from jsonb_array_elements(v_rows) x where (x ->> 'reservation_id')::bigint = v_addon_res) = v_line and v_line = v_order_total - 10, 'B9: lisäpalvelu ja rivinalennus mukana, tilaustason alennus ei');
  perform pg_temp.t68_ck((select left(x ->> 'order_created_at', 4) from jsonb_array_elements(v_rows) x where (x ->> 'reservation_id')::bigint = v_paid) = '2020', 'B10: tilauksen luontipäivä ei siirrä käyntiä');
  perform pg_temp.t68_ck(exists (select 1 from jsonb_array_elements(v_rows) x where (x ->> 'reservation_id')::bigint = v_paid) and exists (select 1 from booking.reservations where id = v_paid and external_source = 'johku'), 'B11: Johku-käynti on mukana');
  perform pg_temp.t68_ck(not exists (select 1 from jsonb_array_elements(v_rows) x where (x ->> 'reservation_id')::bigint = v_other_res), 'B12: muun päivän varaus ei vaikuta');
  perform pg_temp.t68_ck(exists (select 1 from jsonb_array_elements(v2 -> 'revenue_rows') x where (x ->> 'reservation_id')::bigint = v_other_res) and not exists (select 1 from jsonb_array_elements(v2 -> 'revenue_rows') x where (x ->> 'reservation_id')::bigint = v_paid), 'B13: muu päivä saa oman käyntinsä');
  perform pg_temp.t68_ck(not exists (select 1 from jsonb_array_elements(v_rows) x where (x ->> 'reservation_id')::bigint = v_hidden), 'B14: piilotettu pois');
  perform pg_temp.t68_ck(exists (select 1 from jsonb_array_elements(v_rows) x where (x ->> 'reservation_id')::bigint = v_cancel and x ->> 'status' = 'cancelled'), 'B15: peruttu rivi näkyy aineistossa mutta ei bruttossa (B3)');
  select count(*) into v_row_n from jsonb_array_elements(v_rows);
  perform pg_temp.t68_ck(v_row_n = 11, 'B16: rivimäärä tällä päivällä (piilo ja muu päivä pois): ' || v_row_n);

  perform pg_temp.t68_ck((select count(*) from jsonb_array_elements(v -> 'events') e where (e ->> 'product_id')::bigint = 9) = 1, 'C1: tapahtuma 9 oikealla päivällä');
  perform pg_temp.t68_ck((select count(*) from jsonb_array_elements(v -> 'events') e where (e ->> 'product_id')::bigint = 32) = 1, 'C2: toinen tapahtuma samana päivänä');
  perform pg_temp.t68_ck(not exists (select 1 from jsonb_array_elements(v -> 'events') e where (e ->> 'product_id')::bigint = 33), 'C3: monen päivän tapahtuma ei näy ennen alkua');
  select e -> 'participants' into v_parts from jsonb_array_elements(v -> 'events') e where (e ->> 'product_id')::bigint = 9;
  perform pg_temp.t68_ck(jsonb_array_length(coalesce(v_parts, '[]'::jsonb)) = 1 and v_parts -> 0 ->> 'customer_name' = 'T68 Illan Vieras' and (v_parts -> 0 ->> 'persons')::int = 2 and v_parts -> 0 ->> 'status' = 'completed', 'C4: osallistuja, ei peruttua');
  select e -> 'participants' into v_parts from jsonb_array_elements(v -> 'events') e where (e ->> 'product_id')::bigint = 32;
  perform pg_temp.t68_ck(jsonb_array_length(coalesce(v_parts, '[]'::jsonb)) = 0, 'C5: tyhjä tapahtuma näkyy');
  perform pg_temp.t68_ck((select e ->> 'time_text' from jsonb_array_elements(v -> 'events') e where (e ->> 'product_id')::bigint = 9) = 'klo 18–20', 'C6: time_text');

  perform test.login(v_admin);
  v := booking.admin_day_extras(v_fri);
  v2 := booking.admin_day_extras(v_sat);
  perform test.logout();
  perform pg_temp.t68_ck((select count(*) from jsonb_array_elements(v -> 'events') e where (e ->> 'product_id')::bigint = 33) = 1 and jsonb_array_length(coalesce((select e -> 'participants' from jsonb_array_elements(v -> 'events') e where (e ->> 'product_id')::bigint = 33), '[]'::jsonb)) = 1, 'C7: tapahtuma ja osallistuja alkupäivänä');
  perform pg_temp.t68_ck((select count(*) from jsonb_array_elements(v2 -> 'events') e where (e ->> 'product_id')::bigint = 33) = 1 and jsonb_array_length(coalesce((select e -> 'participants' from jsonb_array_elements(v2 -> 'events') e where (e ->> 'product_id')::bigint = 33), '[]'::jsonb)) = 0, 'C8: loppupäivänä kortti, ei eilisen osallistujaa');
  perform pg_temp.t68_ck(not exists (select 1 from jsonb_array_elements(v -> 'events') e where (e ->> 'product_id')::bigint = 9), 'C9: tiistain tapahtuma ei näy perjantaina');

  log := current_setting('t68.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
