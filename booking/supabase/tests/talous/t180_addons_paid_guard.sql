-- booking_180: maksettujen ja avoimien maksulinkkien lisäpalvelurivit säilyvät.
-- Aja migraation ja booking/supabase/tests/fixtures/10_test_helpers.sql:n jälkeen PG17:ssä.
-- Yksi transaktio, jokainen kirjattu testivaraus kumoutuu lopussa.
-- t180_fixed (Grok Bot 26.10.2026): E2-fixture korjattu: dev public_create_booking ei luo pending manual -paikkamerkkiä,
-- joten testi luo sen itse (manual/pay_later, kuten devin olemassa olevat paikkamerkit). Lisätty T1-T4 total_gross = rivien summa -tarkistukset.
-- Grok Bot 26.10.2026: lisätty R (hyvitetyt rivit), L (laskenut enimmäismäärä) ja U (lukitsematon polku ennallaan).
begin;
set local lock_timeout = '3s';
set local statement_timeout = '90s';
create temp table t180_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  insert into t180_r values (coalesce(p_ok, false), p_label)
$$;
create function pg_temp.as_(p_user uuid, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb; d text;
begin
  perform test.login(p_user);
  begin
    execute p_sql into v;
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(nullif(d, ''), sqlstate), 'msg', sqlerrm);
  end;
  perform test.logout();
  return v;
end $$;
do $test$
declare
  vrule bigint := test.rule('Miesten sauna%');
  dt date := test.next_dow(1) + 91;
  mgr uuid := test.mk_staff('manager@t180.example.test', 'manager');
  outsider uuid := test.mk_user('outsider@t180.example.test');
  v jsonb; b jsonb; v_order_id bigint; res_id bigint; parent_id bigint; addon_id bigint;
  item_id bigint; v_payment_id bigint; total_before numeric; total_after numeric;
  status_before text; n_before bigint; ref_before bigint; n integer;
begin
  -- Erilliset tilaukset pitävät testien rivit erillään; ei oikeaa asiakasdataa.
  b := test.pub_book(vrule, dt, 2, 'paid@t180.example.test');
  perform pg_temp.ck((b ->> 'ok')::boolean, 'A0: testivaraus syntyi');
  v_order_id := (test.ord((b ->> 'token')::uuid)).id;
  select id, order_item_id into res_id, parent_id from booking.reservations where booking.reservations.order_id = v_order_id limit 1;
  select id into addon_id from booking.addons where code = 'saunavihta';
  v := pg_temp.as_(mgr, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id,
                               jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', 1))::text));
  perform pg_temp.ck(v ->> 'ok' = 'true', 'A1: maksamattomaan lisäpalvelu');
  select id into item_id from booking.order_items where parent_item_id = parent_id and kind = 'addon';
  select total_gross, payment_status into total_before, status_before from booking.orders where id = v_order_id;
  v := pg_temp.as_(mgr, format('select booking.admin_record_payment(%s, %L, %s, null, null)', v_order_id, 'card_terminal', total_before));
  perform pg_temp.ck(v ->> 'ok' = 'true', 'A2: käsimaksu kirjautuu');
  select id into v_payment_id from booking.payments where order_id = v_order_id and status = 'paid' order by id desc limit 1;
  perform pg_temp.ck(exists (select 1 from booking.payment_lines where payment_id = v_payment_id and order_item_id = item_id), 'A3: kohdistuva payment_line');
  select count(*), count(*) filter (where order_item_id = item_id) into n_before, ref_before
    from booking.payment_lines where payment_id = v_payment_id;

  v := pg_temp.as_(mgr, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id,
                               jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', 1))::text));
  perform pg_temp.ck(v ->> 'ok' = 'true', 'A4: saman setin tallennus onnistuu');
  perform pg_temp.ck((select count(*) from booking.order_items where id = item_id) = 1, 'A5: vanha rivitunniste säilyi');
  perform pg_temp.ck((select count(*) from booking.payment_lines where payment_id = v_payment_id and order_item_id = item_id) = ref_before,
                     'A6: payment_lines-viite pysyy');
  perform pg_temp.ck((select total_gross from booking.orders where id = v_order_id) = total_before and
                     (select payment_status from booking.orders where id = v_order_id) = 'paid',
                     'A7: summa ja maksutila ennallaan');
  perform pg_temp.ck((select total_gross from booking.orders where id = v_order_id) =
                     (select sum(line_total_gross) from booking.order_items where order_id = v_order_id), 'T1: total_gross = rivien summa (A)');

  v := pg_temp.as_(mgr, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id,
                               jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', 2))::text));
  select total_gross into total_after from booking.orders where id = v_order_id;
  perform pg_temp.ck(v ->> 'ok' = 'true' and total_after > total_before, 'B1: lisäys kasvattaa summaa');
  perform pg_temp.ck((select count(*) from booking.order_items where parent_item_id = parent_id and kind='addon') = 2,
                     'B2: alkuperäinen ja uusi rivi');
  perform pg_temp.ck((select payment_status from booking.orders where id = v_order_id) = 'partially_paid',
                     'B3: tilaus osittain maksettu');
  perform pg_temp.ck((select total_gross from booking.orders where id = v_order_id) =
                     (select sum(line_total_gross) from booking.order_items where order_id = v_order_id), 'T2: total_gross = rivien summa (B)');
  v := pg_temp.as_(mgr, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id, '[]'));
  perform pg_temp.ck(v ->> 'err' = 'addon_paid', 'C1: vähennys palauttaa BK001 addon_paid');
  perform pg_temp.ck((select count(*) from booking.order_items where parent_item_id = parent_id and kind = 'addon') = 2
                  and (select total_gross from booking.orders where id = v_order_id) = total_after,
                     'C2: virhe ei muuta rivejä eikä summaa');
  v := pg_temp.as_(mgr, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id,
                               jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', 99))::text));
  perform pg_temp.ck(v ->> 'err' = 'addon_quantity', 'C3: enimmäismäärä lukitut + uudet');

  -- Osittain maksetun tilauksen kattamaton rivi (toisen addonin määrää voi muuttaa).
  v := pg_temp.as_(mgr, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id,
                               jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', 1))::text));
  perform pg_temp.ck(v ->> 'ok' = 'true', 'D1: kattamattoman rivin vähennys sallittu');
  perform pg_temp.ck((select id from booking.order_items where parent_item_id = parent_id and kind = 'addon') = item_id,
                     'D2: maksettu rivitunniste säilyy');
  perform pg_temp.ck((select total_gross from booking.orders where id = v_order_id) = total_before
                     and (select total_gross from booking.orders where id = v_order_id) =
                     (select sum(line_total_gross) from booking.order_items where order_id = v_order_id)
                     and (select payment_status from booking.orders where id = v_order_id) = 'paid', 'T3: summa palasi maksettuun, tila paid (D)');

  -- Toinen maksamaton varaus: summan ja pending manual -paikkamerkin päivitys.
  b := test.pub_book(vrule, dt + 7, 2, 'unpaid@t180.example.test');
  v_order_id := (test.ord((b ->> 'token')::uuid)).id;
  select id, order_item_id into res_id, parent_id from booking.reservations where booking.reservations.order_id = v_order_id limit 1;
  -- FIXTURE-KORJAUS: dev ei luo paikkamerkkiä varauksessa; luodaan pending manual (pay_later) -paikkamerkki ilman maksurivejä.
  if not exists (select 1 from booking.payments where order_id = v_order_id and status = 'pending' and provider = 'manual') then
    insert into booking.payments(order_id, provider, method, status, amount)
      values (v_order_id, 'manual', 'pay_later', 'pending', (select total_gross from booking.orders where id = v_order_id));
  end if;
  v := pg_temp.as_(mgr, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id,
                               jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', 1))::text));
  select id into item_id from booking.order_items where parent_item_id = parent_id and kind = 'addon' limit 1;
  v := pg_temp.as_(mgr, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id,
                               jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', 2))::text));
  perform pg_temp.ck((v ->> 'ok')::boolean and (select count(*) from booking.order_items where id = item_id) = 0,
                     'E1: maksamaton rivi korvataan kuten ennen');
  perform pg_temp.ck((select amount from booking.payments where order_id = v_order_id and status='pending' and provider='manual' limit 1)
                      is not distinct from (select total_gross from booking.orders where id = v_order_id),
                     'E2: pending manual -paikkamerkin summa synkronissa');
  perform pg_temp.ck((select total_gross from booking.orders where id = v_order_id) =
                     (select sum(line_total_gross) from booking.order_items where order_id = v_order_id), 'T4: total_gross = rivien summa (E)');

  -- Avoin online-maksu, maksurivi jo kohdistettu (ei oikeaa verkkomaksua).
  select id into item_id from booking.order_items where parent_item_id = parent_id and kind = 'addon' limit 1;
  insert into booking.payments(order_id, provider, method, status, amount)
    values (v_order_id, 'visma_pay', 'visma_pay', 'pending', (select line_total_gross from booking.order_items where id = item_id))
    returning id into v_payment_id;
  insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
    select v_payment_id, item_id, product_name, 'addon', quantity, line_total_gross, vat_rate from booking.order_items where id = item_id;
  v := pg_temp.as_(mgr, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id, '[]'));
  perform pg_temp.ck(v ->> 'err' = 'addon_link_open', 'F1: avoin Visma-linkki palauttaa addon_link_open');
  perform pg_temp.ck((select count(*) from booking.order_items where id = item_id) = 1,
                     'F2: avoimen linkin rivi säilyi');

  -- Oikeudet ja peruuntunut varaus
  perform pg_temp.ck(not has_function_privilege('anon','booking.admin_set_reservation_addons(bigint,jsonb)','execute'),
                     'G1: anon ei saa kutsuoikeutta');
  v := pg_temp.as_(outsider, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id, '[]'));
  perform pg_temp.ck(v ->> 'err' = 'forbidden', 'G2: puuttuva bookings.manage hylätään');
  update booking.reservations set status = 'cancelled' where id = res_id;
  v := pg_temp.as_(mgr, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id, '[]'));
  perform pg_temp.ck(v ->> 'err' = 'not_editable', 'G3: peruttu varaus');
end $test$;
-- booking_180 (Grok Bot): hyvitetyt rivit (c), laskenut enimmäismäärä (d) ja lukitsemattoman polun ennallaan pysyminen.
do $test2$
declare
  vrule bigint := test.rule('Miesten sauna%');
  dt date := test.next_dow(1) + 98;
  adm uuid := test.mk_staff('admin@t180.example.test', 'admin');
  b jsonb; v jsonb; v_order_id bigint; res_id bigint; parent_id bigint; aid bigint; pyy bigint; itm bigint; pay bigint; pl bigint; amt numeric;
begin
  select id into aid from booking.addons where code = 'saunavihta';
  select id into pyy from booking.addons where code = 'pyyhe';

  -- R: kokonaan hyvitetty lisäpalvelu ei ole lukittu (vanha käytös), osittain hyvitetty on.
  b := test.pub_book(vrule, dt, 2, 'refund@t180.example.test');
  v_order_id := (test.ord((b ->> 'token')::uuid)).id;
  select id, order_item_id into res_id, parent_id from booking.reservations where order_id = v_order_id limit 1;
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id,
                               jsonb_build_array(jsonb_build_object('id', aid, 'quantity', 2))::text));
  v := pg_temp.as_(adm, format('select booking.admin_record_payment(%s, %L, %s, null, null)', v_order_id, 'card_terminal',
                               (select total_gross from booking.orders where id = v_order_id)));
  select id into pay from booking.payments where order_id = v_order_id and status = 'paid';
  select id into itm from booking.order_items where parent_item_id = parent_id and kind = 'addon';
  select id, amount_gross into pl, amt from booking.payment_lines where payment_id = pay and order_item_id = itm;
  perform pg_temp.ck(pay is not null and pl is not null and amt > 0, 'R0: maksettu lisäpalvelurivi');
  v := pg_temp.as_(adm, format('select booking.admin_refund(%s, %s, %L, %L::jsonb)', pay, round(amt / 2, 2), 'Testi osahyvitys',
                               jsonb_build_array(jsonb_build_object('payment_line_id', pl, 'amount', round(amt / 2, 2)))::text));
  perform pg_temp.ck(v ->> 'status' = 'done', 'R1: osahyvitys kirjautui');
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id, '[]'));
  perform pg_temp.ck(v ->> 'err' = 'addon_paid' and (select count(*) from booking.order_items where id = itm) = 1,
                     'R2: osittain hyvitetty rivi pysyy lukittuna');
  v := pg_temp.as_(adm, format('select booking.admin_refund(%s, %s, %L, %L::jsonb)', pay, round(amt / 2, 2), 'Testi loppuhyvitys',
                               jsonb_build_array(jsonb_build_object('payment_line_id', pl, 'amount', round(amt / 2, 2)))::text));
  perform pg_temp.ck(v ->> 'status' = 'done' and (booking._order_balance(v_order_id) ->> 'unpaid')::numeric = amt,
                     'R3: kokonaan hyvitetty rivi näkyy maksamattomana ennen poistoa');
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id, '[]'));
  perform pg_temp.ck(v ->> 'ok' = 'true' and (select count(*) from booking.order_items where id = itm) = 0,
                     'R4: kokonaan hyvitetyn rivin poisto onnistuu');
  perform pg_temp.ck((booking._order_balance(v_order_id) ->> 'unpaid')::numeric = 0
                     and not exists (select 1 from booking._order_uncovered(v_order_id, false) where remaining > 0),
                     'R5: poiston jälkeen ei veloitettavaa');
  perform pg_temp.ck((select order_item_id from booking.payment_lines where id = pl) is null
                     and (select refunded_gross from booking.payment_lines where id = pl) = amt,
                     'R6: hyvitetty maksurivi säilyy, viite nollautuu kuten ennen');

  -- L: max_per_person laskee maksun jälkeen; lukittu määrä kelpaa, sen ylitys ei.
  update booking.addons set max_per_person = 2 where id = aid;
  b := test.pub_book(vrule, dt + 7, 1, 'limit@t180.example.test');
  v_order_id := (test.ord((b ->> 'token')::uuid)).id;
  select id, order_item_id into res_id, parent_id from booking.reservations where order_id = v_order_id limit 1;
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id,
                               jsonb_build_array(jsonb_build_object('id', aid, 'quantity', 2))::text));
  v := pg_temp.as_(adm, format('select booking.admin_record_payment(%s, %L, %s, null, null)', v_order_id, 'card_terminal',
                               (select total_gross from booking.orders where id = v_order_id)));
  update booking.addons set max_per_person = 1 where id = aid;
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id,
                               jsonb_build_array(jsonb_build_object('id', aid, 'quantity', 2))::text));
  perform pg_temp.ck(v ->> 'ok' = 'true', 'L1: sama setti tallentuu, vaikka enimmäismäärä laski');
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id,
                               jsonb_build_array(jsonb_build_object('id', aid, 'quantity', 2), jsonb_build_object('id', pyy, 'quantity', 1))::text));
  perform pg_temp.ck(v ->> 'ok' = 'true' and (select count(*) from booking.order_items where parent_item_id = parent_id and kind = 'addon') = 2,
                     'L2: toisen lisäpalvelun lisäys onnistuu');
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id,
                               jsonb_build_array(jsonb_build_object('id', aid, 'quantity', 3))::text));
  perform pg_temp.ck(v ->> 'err' = 'addon_quantity', 'L3: lukitun määrän ylitys hylätään');

  -- U: lukitsematon polku antaa samat virheet kuin ennen (inaktiivinen ennen määrää).
  update booking.addons set active = false where id = pyy;
  b := test.pub_book(vrule, dt + 14, 1, 'unlocked@t180.example.test');
  v_order_id := (test.ord((b ->> 'token')::uuid)).id;
  select id into res_id from booking.reservations where order_id = v_order_id limit 1;
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id,
                               jsonb_build_array(jsonb_build_object('id', pyy, 'quantity', 50))::text));
  perform pg_temp.ck(v ->> 'err' = 'addon_inactive', 'U1: lukitsematon polku: addon_inactive kuten ennen');
end $test2$;
select format('TESTRESULT pass=%s fail=%s', count(*) filter (where ok), count(*) filter (where not ok)) from t180_r;
select label from t180_r where not ok;
rollback;
