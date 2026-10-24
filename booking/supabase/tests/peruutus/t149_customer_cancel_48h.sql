-- t149: asiakkaan itsepalveluperuutuksen ja -hyvityksen takaraja 48 h (booking_149, Joonaksen päätös 24.10.2026).
-- Asiakas (tilaussivun peruutuspyyntö public_request_cancel, jonka kautta myös hyvitys): 49 h ennen vuoron alkua sallittu,
-- 47 h ennen estetty (palvelin: cancel_too_late; public_get_order: can_request_cancel=false, cancel_closed=true).
-- Raja = asetus customer_change_hours_before (tuotannossa 48). Hallinta (admin_cancel_reservation + hyvitys, admin_refund,
-- admin_resolve_order_request) toimii aina, myös alle 48 h ennen alkua.
-- Kaikki data on feikkiä (@example.test). Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN.
-- Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t149_r(ok boolean, label text) on commit drop;
grant all on t149_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t149_r values (coalesce(p_ok, false), p_label) $$;
-- vahvistettu tilaus maanantain miesten vuoroon; palauttaa tokenin
create function pg_temp.book(p_email text, p_ip text) returns uuid language plpgsql as $$
declare j jsonb; r bigint := test.rule('Miesten sauna%'); d date := test.next_dow(1, 3); begin perform test.anon(p_ip);
  j := booking.public_create_booking(r, d, 2, 'Testi Asiakas', p_email, '0401234567', false, 'fi', null);
  perform test.logout(); return (j ->> 'token')::uuid; end $$;
create function pg_temp.oid_(p_tok uuid) returns bigint language sql as $$ select id from booking.orders where public_token = p_tok $$;
create function pg_temp.rid_(p_tok uuid) returns bigint language sql as $$
  select r.id from booking.reservations r join booking.orders o on o.id = r.order_id where o.public_token = p_tok order by r.id limit 1 $$;
-- siirtää tilauksen ainoan varauksen alkamaan p_h tunnin päästä (3 h vuoro)
create function pg_temp.shift(p_tok uuid, p_h interval) returns void language sql as $$
  update booking.reservations set starts_at = now() + p_h, ends_at = now() + p_h + interval '3 hours' where id = pg_temp.rid_(p_tok) $$;
create function pg_temp.get(p_tok uuid) returns jsonb language plpgsql as $$
declare j jsonb; begin perform test.anon(); j := booking.public_get_order(p_tok); perform test.logout(); return j; end $$;
create function pg_temp.req(p_tok uuid) returns jsonb language plpgsql as $$
declare j jsonb; begin perform test.anon(); j := booking.public_request_cancel(p_tok, 'testi'); perform test.logout(); return j; end $$;
create function pg_temp.nreq(p_tok uuid) returns int language sql as $$
  select count(*)::int from booking.order_requests where order_id = pg_temp.oid_(p_tok) and kind = 'cancel' $$;
create function pg_temp.nmail(p_tok uuid) returns int language sql as $$
  select count(*)::int from booking.email_outbox where kind = 'cancel_request_ack' and order_id = pg_temp.oid_(p_tok) $$;
do $t$
declare
  v_adm uuid := test.mk_staff('adm149@example.test', 'admin');
  t49 uuid; t47 uuid; t48 uuid; t48m uuid; tset uuid; ts1 uuid; ts2 uuid; ts3 uuid; ts4 uuid;
  j jsonb; v_o bigint; v_r bigint; v_q bigint; v_pay bigint; v_paid numeric;
begin
  perform test.reset_rl();
  update booking.settings set value = '1000' where key in ('rl_ip_per_10min', 'rl_email_per_10min', 'rl_order_req_per_10min', 'rl_order_get_per_10min', 'rl_change_per_10min');

  -- ===== Tekniset =====
  perform pg_temp.ck((select value from booking.settings where key = 'customer_change_hours_before') = '48'::jsonb, 'T1: asetus customer_change_hours_before = 48');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._customer_cancel_deadline(bigint)', 'execute')
    and not has_function_privilege('authenticated', 'booking._customer_cancel_deadline(bigint)', 'execute'), 'T2: sisäinen takarajafunktio ei anonille eikä authenticatedille');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_request_cancel(uuid,text)', 'execute')
    and has_function_privilege('anon', 'booking.public_get_order(uuid)', 'execute'), 'T3: julkiset oikeudet ennallaan');
  perform pg_temp.ck((select bool_and(prosecdef and proconfig @> array['search_path=""']) from pg_proc p where p.pronamespace = 'booking'::regnamespace
    and p.proname in ('_customer_cancel_deadline', 'public_request_cancel', 'public_get_order')), 'T4: security definer, search_path tyhjä');

  -- ===== A) asiakas 49 h ennen: sallittu =====
  t49 := pg_temp.book('a49@example.test', '10.149.0.1');
  perform pg_temp.ck((select status from booking.orders where public_token = t49) = 'confirmed', 'A0: esiehto: tilaus vahvistettu');
  perform pg_temp.shift(t49, interval '49 hours');
  j := pg_temp.get(t49);
  perform pg_temp.ck((j ->> 'can_request_cancel')::boolean and not (j ->> 'cancel_closed')::boolean, 'A1: 49 h: can_request_cancel = true, cancel_closed = false');
  perform pg_temp.ck((j ->> 'cancel_hours_before')::int = 48 and (j ->> 'cancel_deadline')::timestamptz = now() + interval '1 hour', 'A2: 49 h: cancel_hours_before 48, takaraja = alku − 48 h');
  j := pg_temp.req(t49);
  perform pg_temp.ck((j ->> 'ok')::boolean and pg_temp.nreq(t49) = 1 and pg_temp.nmail(t49) = 1, 'A3: 49 h: peruutuspyyntö onnistuu (pyyntö + kuittausviesti)');
  j := pg_temp.get(t49);
  perform pg_temp.ck(not (j ->> 'can_request_cancel')::boolean and not (j ->> 'cancel_closed')::boolean and j -> 'cancel_request' ->> 'status' = 'open', 'A4: avoin pyyntö: ei uutta pyyntöä, ei suljettu-tekstiä');

  -- ===== B) asiakas 47 h ennen: estetty =====
  t47 := pg_temp.book('b47@example.test', '10.149.0.2');
  perform pg_temp.shift(t47, interval '47 hours');
  j := pg_temp.get(t47);
  perform pg_temp.ck(not (j ->> 'can_request_cancel')::boolean and (j ->> 'cancel_closed')::boolean, 'B1: 47 h: can_request_cancel = false, cancel_closed = true');
  perform pg_temp.ck((j ->> 'cancel_deadline')::timestamptz = now() - interval '1 hour', 'B2: 47 h: takaraja mennyt (alku − 48 h)');
  j := pg_temp.req(t47);
  perform pg_temp.ck(j ->> 'code' = 'cancel_too_late' and not (j ->> 'ok')::boolean, 'B3: 47 h: palvelin hylkää (cancel_too_late)');
  perform pg_temp.ck(j ->> 'message' like '%alle 48 tuntia%' and j ->> 'message' like '%010 299 2866%', 'B4: viestissä raja ja puhelinnumero');
  perform pg_temp.ck(pg_temp.nreq(t47) = 0 and pg_temp.nmail(t47) = 0, 'B5: 47 h: ei pyyntöä eikä sähköpostia');
  perform pg_temp.ck((select status from booking.orders where public_token = t47) = 'confirmed'
    and (select status from booking.reservations where id = pg_temp.rid_(t47)) = 'confirmed', 'B6: 47 h: tilaus ja varaus ennallaan');
  -- ajanmuutos (ja sen kautta syntyvä hyvityspyyntö) oli jo rajattu samaan asetukseen
  v_r := pg_temp.rid_(t47);
  perform test.anon();
  j := booking.public_change_order_time(t47, v_r, null, null, null, 3, null);
  perform test.logout();
  perform pg_temp.ck(j ->> 'code' = 'change_too_late', 'B7: 47 h: ajanmuutos estetty (change_too_late, ennallaan)');

  -- ===== C) rajat: tasan 48 h sallittu, 48 h − 1 min estetty =====
  t48 := pg_temp.book('c48@example.test', '10.149.0.3');
  perform pg_temp.shift(t48, interval '48 hours');
  perform pg_temp.ck((pg_temp.get(t48) ->> 'can_request_cancel')::boolean and (pg_temp.req(t48) ->> 'ok')::boolean, 'C1: tasan 48 h: sallittu');
  t48m := pg_temp.book('c48m@example.test', '10.149.0.4');
  perform pg_temp.shift(t48m, interval '48 hours' - interval '1 minute');
  perform pg_temp.ck(not (pg_temp.get(t48m) ->> 'can_request_cancel')::boolean and pg_temp.req(t48m) ->> 'code' = 'cancel_too_late', 'C2: 48 h − 1 min: estetty');

  -- ===== D) raja tulee asetuksesta =====
  tset := pg_temp.book('d24@example.test', '10.149.0.5');
  perform pg_temp.shift(tset, interval '47 hours');
  update booking.settings set value = '24' where key = 'customer_change_hours_before';
  j := pg_temp.get(tset);
  perform pg_temp.ck((j ->> 'can_request_cancel')::boolean and (j ->> 'cancel_hours_before')::int = 24, 'D1: asetus 24 h → 47 h ennen sallittu');
  update booking.settings set value = '48' where key = 'customer_change_hours_before';
  perform pg_temp.ck(pg_temp.req(tset) ->> 'code' = 'cancel_too_late', 'D2: asetus takaisin 48 h → estetty');
  delete from booking.settings where key = 'customer_change_hours_before';
  perform pg_temp.ck(pg_temp.req(tset) ->> 'code' = 'cancel_too_late' and (pg_temp.get(tset) ->> 'cancel_hours_before')::int = 48, 'D3: asetusrivi puuttuu → oletus 48 h');
  insert into booking.settings(key, value, is_public) values ('customer_change_hours_before', '48', true);

  -- ===== S) hallinta toimii aina (47 h ennen alkua). Tunnisteet haetaan superkäyttäjänä, kutsut admin-roolina. =====
  -- S1: varauksen peruutus + hyvitys
  ts1 := pg_temp.book('s1@example.test', '10.149.0.6'); perform pg_temp.shift(ts1, interval '47 hours');
  v_o := pg_temp.oid_(ts1); v_r := pg_temp.rid_(ts1); v_paid := (select total_gross from booking.orders where id = v_o);
  perform test.login(v_adm);
  perform booking.admin_record_payment(v_o, 'card_terminal', v_paid, 'testi', null);
  j := booking.admin_cancel_reservation(v_r, 'testi 47 h', true, null);
  perform test.logout();
  perform pg_temp.ck((j ->> 'ok')::boolean and (j ->> 'refunded_total')::numeric = v_paid and v_paid > 0
    and (select status from booking.reservations where id = v_r) = 'cancelled', 'S1: 47 h: hallinnan peruutus + hyvitys onnistuu');
  -- S2: maksun hyvitys suoraan (admin_refund)
  ts2 := pg_temp.book('s2@example.test', '10.149.0.7'); perform pg_temp.shift(ts2, interval '47 hours');
  v_o := pg_temp.oid_(ts2); v_paid := (select total_gross from booking.orders where id = v_o);
  perform test.login(v_adm);
  perform booking.admin_record_payment(v_o, 'card_terminal', v_paid, 'testi', null);
  perform test.logout();
  v_pay := (select id from booking.payments where order_id = v_o and status = 'paid' order by id desc limit 1);
  perform test.login(v_adm);
  j := booking.admin_refund(v_pay, v_paid, 'testi 47 h', null, false);
  perform test.logout();
  perform pg_temp.ck((j ->> 'ok')::boolean and (select coalesce(sum(amount), 0) from booking.refunds where payment_id = v_pay) = v_paid,
    'S2: 47 h: hallinnan hyvitys (admin_refund) onnistuu');
  -- S3: ennen rajaa tullut peruutuspyyntö hyväksytään, vaikka vuoroon on nyt alle 48 h
  ts3 := pg_temp.book('s3@example.test', '10.149.0.8'); perform pg_temp.shift(ts3, interval '49 hours');
  perform pg_temp.ck((pg_temp.req(ts3) ->> 'ok')::boolean, 'S3a: pyyntö 49 h ennen (esiehto)');
  perform pg_temp.shift(ts3, interval '47 hours');
  v_q := (select id from booking.order_requests where order_id = pg_temp.oid_(ts3) and kind = 'cancel' and status = 'open');
  v_r := pg_temp.rid_(ts3);
  perform test.login(v_adm);
  j := booking.admin_resolve_order_request(v_q, 'approve', 'testi');
  perform test.logout();
  perform pg_temp.ck((j ->> 'ok')::boolean and (select status from booking.reservations where id = v_r) = 'cancelled', 'S3: 47 h: hallinta hyväksyy peruutuspyynnön');
  -- S4: hallinnan tilan muutos 2 h ennen alkua
  ts4 := pg_temp.book('s4@example.test', '10.149.0.9'); perform pg_temp.shift(ts4, interval '2 hours');
  v_r := pg_temp.rid_(ts4);
  perform test.login(v_adm);
  perform booking.admin_set_reservation_status(v_r, 'cancelled', 'testi 2 h');
  perform test.logout();
  perform pg_temp.ck((select status from booking.reservations where id = v_r) = 'cancelled', 'S4: 2 h ennen: hallinnan peruutus onnistuu');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t149_r where ok), (select count(*) from t149_r where not ok),
    coalesce((select string_agg(label, ' | ') from t149_r where not ok), 'ALL OK');
end $t$;
