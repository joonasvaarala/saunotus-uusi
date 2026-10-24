-- t136: hallinnan hyvitys ↔ peruutus (booking_136). Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN (mock-data: Miesten sauna).
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
-- Migraation/rollbackin uudelleenajettavuus testataan erikseen (migraatio 2x, rollback 2x, migraatio uudelleen).
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t136_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t136_r values (coalesce(p_ok, false), p_label) $$;
-- Ajaa lauseen kirjautuneena (p_user) ja palauttaa jsonb-tuloksen tai {"err": BK001-koodi}; rooli palautetaan aina.
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
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%'); d date := test.next_dow(1, 10);
  u_adm uuid := test.mk_staff('adm@t136.example', 'admin'); u_mgr uuid := test.mk_staff('mgr@t136.example', 'manager'); u_stf uuid := test.mk_staff('stf@t136.example', 'staff');
  a jsonb; b jsonb; v jsonb; w jsonb; o_a bigint; o_b bigint; r1 bigint; r2 bigint; i1 bigint; i2 bigint; v_total numeric; v_pay bigint;
  v_share1 numeric; v_share2 numeric; v_addon numeric; v_ref numeric; v_n int; o_c bigint; r3 bigint; r4 bigint;
begin
  -- ---- tilaus, jossa kaksi varausta + lisäpalvelu varaukselle 1 ----
  a := test.pub_book(v_rule, d, 2, 'yksi@t136.example'); b := test.pub_book(v_rule, d + 7, 3, 'kaksi@t136.example');
  perform pg_temp.ck((a ->> 'ok')::boolean and (b ->> 'ok')::boolean, 'A0: kaksi varausta');
  o_a := (test.ord((a ->> 'token')::uuid)).id; o_b := (test.ord((b ->> 'token')::uuid)).id;
  -- yhdistetään B:n varaus A:n tilaukseen (testidata; vastaa ostoskorin kahden varauksen tilausta)
  update booking.order_items set order_id = o_a where order_id = o_b;
  update booking.reservations set order_id = o_a where order_id = o_b;
  update booking.orders set total_gross = (select sum(line_total_gross) from booking.order_items where order_id = o_a) where id = o_a;
  update booking.orders set status = 'cancelled', total_gross = 0 where id = o_b;
  select id, order_item_id into r1, i1 from booking.reservations where order_id = o_a order by id limit 1;
  select id, order_item_id into r2, i2 from booking.reservations where order_id = o_a and id <> r1 order by id limit 1;
  v := pg_temp.as_(u_adm, format($q$select booking.admin_add_to_order(%s, '[{"type":"addon","reservation_id":%s,"code":"saunavihta","quantity":1}]'::jsonb, false, false, null)$q$, o_a, r1));
  perform pg_temp.ck((v ->> 'ok')::boolean, 'A1: lisäpalvelu varaukselle 1 ' || coalesce(v ->> 'err', ''));
  select line_total_gross into v_share1 from booking.order_items where id = i1;
  select line_total_gross into v_share2 from booking.order_items where id = i2;
  select coalesce(sum(line_total_gross), 0) into v_addon from booking.order_items where parent_item_id = i1;
  perform pg_temp.ck(v_addon > 0, 'A2: lisäpalvelu on varauksen lapsirivi');
  select total_gross into v_total from booking.orders where id = o_a;
  perform pg_temp.ck(v_total = v_share1 + v_share2 + v_addon, 'A3: tilauksen summa = rivit');
  -- maksu käsin (korttipääte) koko summasta → maksurivit
  v := pg_temp.as_(u_adm, format('select booking.admin_record_payment(%s, %L, %s, null, null)', o_a, 'card_terminal', v_total));
  perform pg_temp.ck((v ->> 'ok')::boolean, 'A4: maksu kirjattu ' || coalesce(v ->> 'err', ''));
  select id into v_pay from booking.payments where order_id = o_a and status = 'paid' order by id desc limit 1;
  perform pg_temp.ck((select count(*) from booking.payment_lines where payment_id = v_pay) >= 3, 'A5: maksurivit syntyivät');

  -- ---- B: esikatselu = varauksen osuus (rivi + lisäpalvelut), ei koko tilaus ----
  v := pg_temp.as_(u_mgr, format('select booking.admin_reservation_refund_preview(%s)', r1));
  perform pg_temp.ck((v ->> 'total')::numeric = v_share1 + v_addon, format('B1: varauksen 1 osuus %s = %s', v ->> 'total', v_share1 + v_addon));
  perform pg_temp.ck((v ->> 'total')::numeric < v_total, 'B2: ei koko tilausta');
  perform pg_temp.ck(jsonb_array_length(v -> 'payments') = 1 and (v -> 'payments' -> 0 ->> 'payment_id')::bigint = v_pay, 'B3: yksi maksu');
  perform pg_temp.ck((select sum((x ->> 'amount')::numeric) from jsonb_array_elements(v -> 'payments' -> 0 -> 'lines') x) = v_share1 + v_addon, 'B4: rivijako = summa');
  v := pg_temp.as_(u_mgr, format('select booking.admin_reservation_refund_preview(%s)', r2));
  perform pg_temp.ck((v ->> 'total')::numeric = v_share2, 'B5: varauksen 2 osuus ilman toisen lisäpalveluja');
  -- staff: ei hyvitysoikeutta (ei edes esikatselua)
  v := pg_temp.as_(u_stf, format('select booking.admin_reservation_refund_preview(%s)', r1));
  perform pg_temp.ck(v ->> 'err' = 'forbidden', 'B6: staff ei näe hyvitysesikatselua: ' || coalesce(v ->> 'err', v::text));
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_reservation_refund_preview(bigint)', 'execute'), 'B7: anon ei esikatselua');
  perform pg_temp.ck(not has_function_privilege('authenticated', 'booking._reservation_refund_plan(bigint)', 'execute')
                     and not has_function_privilege('anon', 'booking._reservation_refund_plan(bigint)', 'execute'), 'B8: sisäinen funktio suljettu');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_cancel_reservation(bigint,text,boolean,text)', 'execute')
                     and not has_function_privilege('anon', 'booking.admin_refund_order(bigint,numeric,text,jsonb,boolean)', 'execute'), 'B9: anon ei uusia RPC:itä');

  -- ---- C: aiempi osahyvitys rajaa (rivikohtainen) ----
  -- osahyvitetään 5 € varauksen 1 rivistä (p_lines) → osuus pienenee 5 €
  v := pg_temp.as_(u_adm, format($q$select booking.admin_refund(%s, 5, 'osahyvitys testi', jsonb_build_array(jsonb_build_object('payment_line_id', (select id from booking.payment_lines where payment_id = %s and order_item_id = %s), 'amount', 5)), false)$q$, v_pay, v_pay, i1));
  perform pg_temp.ck(v ->> 'status' = 'done', 'C1: osahyvitys tehty ' || coalesce(v ->> 'err', '') || coalesce(v ->> 'msg', ''));
  v := pg_temp.as_(u_mgr, format('select booking.admin_reservation_refund_preview(%s)', r1));
  perform pg_temp.ck((v ->> 'total')::numeric = v_share1 + v_addon - 5, 'C2: osahyvitys vähennetty osuudesta: ' || (v ->> 'total'));

  -- ---- D: staff saa perua ilman hyvitystä, ei hyvityksen kanssa ----
  v := pg_temp.as_(u_stf, format('select booking.admin_cancel_reservation(%s, null, true, null)', r2));
  perform pg_temp.ck(v ->> 'err' = 'forbidden', 'D1: staff ei saa perua+hyvittää: ' || coalesce(v ->> 'err', v::text));
  perform pg_temp.ck((select status from booking.reservations where id = r2) = 'confirmed', 'D2: varaus ennallaan kiellon jälkeen');
  -- oletus p_refund = false: peruu, ei rahaliikettä
  select refunded_amount into v_ref from booking.payments where id = v_pay;
  v := pg_temp.as_(u_stf, format('select booking.admin_cancel_reservation(%s)', r2));
  perform pg_temp.ck((v ->> 'ok')::boolean and (v ->> 'refunded_total')::numeric = 0, 'D3: staff peruu ilman hyvitystä ' || coalesce(v ->> 'err', ''));
  perform pg_temp.ck((select status from booking.reservations where id = r2) = 'cancelled', 'D4: varaus 2 peruttu');
  perform pg_temp.ck((select refunded_amount from booking.payments where id = v_pay) = v_ref, 'D5: oletuksena ei hyvitystä');
  perform pg_temp.ck((select status from booking.orders where id = o_a) <> 'cancelled', 'D6: tilaus voimassa (varaus 1 jäljellä)');
  v := pg_temp.as_(u_mgr, format('select booking.admin_cancel_reservation(%s, null, true, null)', r2));
  perform pg_temp.ck(v ->> 'err' = 'invalid_status', 'D7: jo peruttua ei voi perua uudelleen');

  -- ---- E: manager peruu + hyvittää varauksen 1: vain sen osuus (osahyvitys huomioiden) ----
  v := pg_temp.as_(u_mgr, format($q$select booking.admin_cancel_reservation(%s, 'asiakas perui', true, 'peruutus ja hyvitys')$q$, r1));
  perform pg_temp.ck((v ->> 'ok')::boolean, 'E1: peruutus + hyvitys ' || coalesce(v ->> 'err', '') || coalesce(v ->> 'msg', ''));
  perform pg_temp.ck((v ->> 'refunded_total')::numeric = v_share1 + v_addon - 5, 'E2: hyvitetty varauksen osuus: ' || coalesce(v ->> 'refunded_total', ''));
  perform pg_temp.ck(v -> 'refunds' -> 0 ->> 'status' = 'done', 'E3: käsimaksun hyvitys valmis');
  perform pg_temp.ck((select refunded_amount from booking.payments where id = v_pay) = v_share1 + v_addon, 'E4: maksun hyvitetty = varaus 1 + lisäpalvelu');
  perform pg_temp.ck((select refunded_amount from booking.payments where id = v_pay) <= (select amount from booking.payments where id = v_pay), 'E5: ei yli maksetun');
  perform pg_temp.ck((select refunded_gross from booking.payment_lines where payment_id = v_pay and order_item_id = i2) = 0, 'E6: varauksen 2 riviä ei hyvitetty');
  perform pg_temp.ck((select status from booking.orders where id = o_a) = 'cancelled', 'E7: tilaus peruttu, kun varauksia ei jäänyt');
  perform pg_temp.ck(test.audit_n('ADMIN_CANCEL_RESERVATION') >= 2, 'E8: audit');
  v := pg_temp.as_(u_mgr, format('select booking.admin_reservation_refund_preview(%s)', r1));
  perform pg_temp.ck((v ->> 'total')::numeric = 0, 'E9: toista hyvitystä ei tarjota');

  -- ---- F: tilauksen hyvitys + varausten peruutus ----
  a := test.pub_book(v_rule, d + 14, 2, 'kolme@t136.example');
  o_c := (test.ord((a ->> 'token')::uuid)).id;
  select id into r3 from booking.reservations where order_id = o_c order by id limit 1;
  select total_gross into v_total from booking.orders where id = o_c;
  v := pg_temp.as_(u_adm, format('select booking.admin_record_payment(%s, %L, %s, null, null)', o_c, 'card_terminal', v_total));
  select id into v_pay from booking.payments where order_id = o_c and status = 'paid' order by id desc limit 1;
  -- staff: ei hyvitysoikeutta
  v := pg_temp.as_(u_stf, format($q$select booking.admin_refund_order(%s, 1, 'testi', null, false)$q$, v_pay));
  perform pg_temp.ck(v ->> 'err' = 'forbidden', 'F1: staff ei hyvitä: ' || coalesce(v ->> 'err', v::text));
  -- oletus: ei peruuta varauksia
  v := pg_temp.as_(u_mgr, format($q$select booking.admin_refund_order(%s, 1, 'osahyvitys')$q$, v_pay));
  perform pg_temp.ck((v ->> 'ok')::boolean and (v ->> 'cancelled_reservations')::int = 0, 'F2: hyvitys ilman peruutusta ' || coalesce(v ->> 'err', ''));
  perform pg_temp.ck((select status from booking.reservations where id = r3) = 'confirmed', 'F3: varaus voimassa (oletus Ei)');
  -- liikaa → hylätään, eikä varausta peruta (atominen)
  v := pg_temp.as_(u_mgr, format($q$select booking.admin_refund_order(%s, %s, 'liikaa', null, true)$q$, v_pay, v_total));
  perform pg_temp.ck(v ->> 'err' = 'amount_exceeds_refundable', 'F4: yli maksetun hylätään: ' || coalesce(v ->> 'err', v::text));
  perform pg_temp.ck((select status from booking.reservations where id = r3) = 'confirmed', 'F5: varaus ennallaan hylätyn jälkeen');
  -- kyllä: hyvitys + peruutus
  v := pg_temp.as_(u_mgr, format($q$select booking.admin_refund_order(%s, %s, 'koko tilaus', null, true)$q$, v_pay, v_total - 1));
  perform pg_temp.ck((v ->> 'ok')::boolean and (v ->> 'cancelled_reservations')::int = 1, 'F6: hyvitys + peruutus ' || coalesce(v ->> 'err', '') || coalesce(v ->> 'msg', ''));
  perform pg_temp.ck((select status from booking.reservations where id = r3) = 'cancelled', 'F7: varaus peruttu');
  perform pg_temp.ck((select status from booking.payments where id = v_pay) = 'refunded', 'F8: maksu hyvitetty kokonaan');

  -- ---- G: verkkomaksu, integraatio pois → peruutus+hyvitys hylätään kokonaan, esikatselu kertoo online_off ----
  a := test.pub_book(v_rule, d + 21, 1, 'nelja@t136.example');
  o_c := (test.ord((a ->> 'token')::uuid)).id;
  select id into r4 from booking.reservations where order_id = o_c order by id limit 1;
  select total_gross into v_total from booking.orders where id = o_c;
  v := pg_temp.as_(u_adm, format('select booking.admin_record_payment(%s, %L, %s, null, null)', o_c, 'card_terminal', v_total));
  update booking.payments set provider = 'visma_pay', method = 'visma_pay' where order_id = o_c and status = 'paid';   -- testidata: verkkomaksu
  v := pg_temp.as_(u_adm, format('select booking.admin_reservation_refund_preview(%s)', r4));
  perform pg_temp.ck((v -> 'payments' -> 0 ->> 'online_off')::boolean, 'G1: online_off näkyy esikatselussa ' || v::text);
  v := pg_temp.as_(u_adm, format($q$select booking.admin_cancel_reservation(%s, null, true, null)$q$, r4));
  perform pg_temp.ck(v ->> 'err' = 'refund_not_allowed', 'G2: verkkohyvitys pois päältä → hylätty: ' || coalesce(v ->> 'err', v::text));
  perform pg_temp.ck((select status from booking.reservations where id = r4) = 'confirmed', 'G3: varaus ennallaan (atominen)');
  perform pg_temp.ck((select mode from booking.integration_config where key = 'vismapay') = 'off', 'G4: Visma Pay ei live');
  -- Johku-tilaus ja olematon varaus
  v := pg_temp.as_(u_mgr, 'select booking.admin_reservation_refund_preview(-1)');
  perform pg_temp.ck(v ->> 'err' = 'not_found', 'G5: olematon varaus');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t136_r where ok), (select count(*) from t136_r where not ok),
    coalesce((select string_agg(label, ' | ') from t136_r where not ok), 'ALL OK');
end $t$;
