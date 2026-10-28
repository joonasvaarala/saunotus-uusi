-- t70: pidon vanheneminen peruu tilauksen (cancelled + cancel_reason hold_expired).
-- Kertasiivous koskee vain varsinaista kassapitoa: external_source is null AND hold_kind is not null. Johku-tuonti ei muutu.
-- Ajetaan migraation JÄLKEEN. Yksi DO-lohko; tahallinen poikkeus kumoaa kaiken. Tulos: TESTRESULT pass=… fail=…
-- statement_timeout on tämän lohkon aikaraja. lock_timeout pysyy lyhyenä (SET LOCAL, ei istuntotason SET): statement_timeout ei pidennä sitä eikä vuoda transaktion ulkopuolelle.
set local lock_timeout = '3s';
set local statement_timeout = '90s';
create temp table t70_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t70_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.mk(p_start timestamptz, p_email text) returns jsonb language sql as $$
  select booking.public_create_treatment_booking(11, p_start, 2, 'Testi Asiakas', p_email, '+358401234567', false, 'fi', null, 'private', null, null) $$;
create function pg_temp.oid(p_tok uuid) returns bigint language sql as $$ select id from booking.orders where public_token = p_tok $$;
do $t$
declare
  v_seq0 bigint; v_seq1 bigint; v_maxid bigint; v_foreign int; v_made int;
  r jsonb; tok uuid; oid bigint; pid bigint; v_bal0 numeric; v_mail int; g1 bigint;
  r_s record; v_slots timestamptz[]; v_st text; v_reason text;
begin
  select last_value into v_seq0 from booking.orders_order_no_seq;
  select coalesce(max(id), 0) into v_maxid from booking.orders;
  update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode';
  update booking.settings set value = 'true'::jsonb where key = 'gift_cards.redeem_enabled';
  update booking.integration_config set mode = 'test', settings = coalesce(settings, '{}'::jsonb) || '{"approved_by":"t70"}'::jsonb where key = 'mobilepay';
  insert into booking.integration_config(key, mode, settings) values ('montonio', 'test', '{"approved_by":"t70"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = booking.integration_config.settings || '{"approved_by":"t70"}'::jsonb;
  insert into booking.gift_cards(code, issuer, kind, initial_amount, balance, status, source, vat_treatment, accounting_origin, balance_verified, valid_to)
  values ('HH69TEST0001', 'own', 'value', 1000, 1000, 'active', 'native', 'at_redemption', 'native', true, current_date + 100) returning id into g1;
  for r_s in select q.starts_at from (
      select * from booking.public_treatment_availability(11, current_date + 3, current_date + 16, 2)
      union all select * from booking.public_treatment_availability(11, current_date + 17, current_date + 30, 2)) q
     where q.status = 'available' order by q.starts_at loop
    if v_slots is null or r_s.starts_at >= v_slots[cardinality(v_slots)] + interval '5 hours' then v_slots := array_append(v_slots, r_s.starts_at); end if;
  end loop;
  if v_slots is null or cardinality(v_slots) < 8 then raise exception 'TESTRESULT_ABORT vapaita hoitoaikoja %', coalesce(cardinality(v_slots), 0); end if;
  perform pg_temp.ck(current_setting('lock_timeout') = '3s' and current_setting('statement_timeout') = '90s', 'L1: lock_timeout 3s, statement_timeout 90s (lukkoaikaraja ei pidentynyt)');

  -- A) cron peruu pidon: tilaus säilyy, kapasiteetti vapaa, ei viestiä
  r := pg_temp.mk(v_slots[1], 'a1@t69.example'); tok := (r ->> 'token')::uuid; oid := pg_temp.oid(tok);
  perform pg_temp.ck((r ->> 'ok')::boolean and r ->> 'checkout_state' = 'awaiting_payment', 'A1: pito luotu (' || coalesce(r ->> 'code', '') || ')');
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = oid;
  perform pg_temp.ck(booking._checkout_state_json(oid) ->> 'checkout_state' = 'expired', 'A2: ennen cronia checkout_state expired (tilaus yhä pending)');
  perform pg_temp.ck(not booking._res_active((select status from booking.reservations where order_id = oid), (select hold_expires_at from booking.reservations where order_id = oid)), 'A3: vanhentunut pending ei ole _res_active');
  perform booking.expire_holds();
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'cancelled' and (select cancelled_at from booking.orders where id = oid) is not null, 'A4: tilaus cancelled, rivi tallella');
  perform pg_temp.ck((select status from booking.reservations where order_id = oid) = 'cancelled' and (select cancel_reason from booking.reservations where order_id = oid) = 'hold_expired', 'A5: varaus cancelled / hold_expired');
  perform pg_temp.ck(not booking._res_active('cancelled', now() + interval '1 hour'), 'A6: cancelled ei ole aktiivinen');
  perform pg_temp.ck(not exists (select 1 from booking.v_claims c where c.order_id = oid and booking._res_active(c.status, c.hold_expires_at)), 'A7: claimit eivät varaa aikaa');
  r := booking.public_get_order(tok);
  perform pg_temp.ck(r ->> 'status' = 'cancelled' and r ->> 'checkout_state' = 'cancelled' and r ->> 'cancel_reason' = 'hold_expired', 'A8: tilaussivu: cancelled + cancel_reason hold_expired');
  perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = oid and kind = 'unpaid_booking_cancelled') = 1
    and (select dedupe_key from booking.email_outbox where order_id = oid and kind = 'unpaid_booking_cancelled') = 'unpaid_booking_cancelled:' || oid::text, 'A9: vanheneminen jonottaa yhden maksamaton-viestin');
  r := pg_temp.mk(v_slots[1], 'a2@t69.example');
  perform pg_temp.ck((r ->> 'ok')::boolean, 'A10: sama aika on taas varattavissa (' || coalesce(r ->> 'code', '') || ')');

  -- B) lahjakortin osuus palautuu, kun pito vanhenee uuteen cancelled-tilaan
  select balance into v_bal0 from booking.gift_cards where id = g1;
  r := pg_temp.mk(v_slots[2], 'b1@t69.example'); tok := (r ->> 'token')::uuid; oid := pg_temp.oid(tok);
  r := booking.public_apply_gift_card(tok, 'HH69TEST0001', 5);
  perform pg_temp.ck((r ->> 'ok')::boolean, 'B1: osamaksu 5 € (' || coalesce(r ->> 'code', '') || ')');
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = oid;
  perform booking.expire_holds();
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'cancelled', 'B2: osamaksun tilaus cancelled');
  perform pg_temp.ck((select balance from booking.gift_cards where id = g1) = v_bal0, 'B3: lahjakortin saldo palautettu');
  perform pg_temp.ck((select status from booking.payments where order_id = oid and method = 'gift_card') = 'cancelled', 'B4: korttimaksu cancelled');
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = oid and kind in ('order_confirmation', 'receipt')), 'B5: ei vahvistusta eikä kuittia');

  -- C) verkkomaksu kesken ei vapaudu (booking_189: MobilePay-aloitus ei enää luo maksua; pito on Montoniossa)
  r := pg_temp.mk(v_slots[3], 'c1@t69.example'); tok := (r ->> 'token')::uuid; oid := pg_temp.oid(tok);
  r := booking.montonio_payment_prepare(tok, null, 'cardPayments');
  perform pg_temp.ck((r ->> 'ok')::boolean, 'C1: verkkomaksu aloitettu (' || coalesce(r ->> 'code', '') || ')');
  r := booking.montonio_payment_event(r ->> 'order_number', 'CREATED', 'https://pay.example/t70', '00000000-0000-4000-8000-000000000070', null);
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = oid;
  perform booking.expire_holds();
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'pending' and (select status from booking.reservations where order_id = oid) = 'pending', 'C2: inflight-pitoa ei peruta');

  -- D) kertasiivous: valmiiksi expired + unpaid → cancelled; maksettu / kuitti / partially_paid / confirmed ohitetaan
  r := pg_temp.mk(v_slots[4], 'd1@t69.example'); tok := (r ->> 'token')::uuid; oid := pg_temp.oid(tok);
  insert into booking.payments(order_id, method, provider, status, amount) values (oid, 'cash', 'manual', 'pending', 10) returning id into pid;
  update booking.reservations set status = 'expired', cancel_reason = null, cancelled_at = null, hold_expires_at = now() - interval '2 minutes' where order_id = oid;
  update booking.orders set status = 'expired', payment_status = 'unpaid', cancelled_at = null where id = oid;
  select count(*) into v_mail from booking.email_outbox where order_id = oid;
  perform pg_temp.ck((select external_source from booking.orders where id = oid) is null and (select hold_kind from booking.orders where id = oid) is not null, 'D0: siivottava rivi on kassapito');
  perform pg_temp.ck(booking._cancel_unpaid_expired_orders() >= 1, 'D1: siivous peruu expired/unpaid-kassapidon');
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'cancelled' and (select external_meta -> 'booking_70' ->> 'prev_status' from booking.orders where id = oid) = 'expired', 'D2: leima booking_70, tila cancelled');
  perform pg_temp.ck((select status from booking.reservations where order_id = oid) = 'cancelled' and (select cancel_reason from booking.reservations where order_id = oid) = 'hold_expired', 'D3: vanha expired-varaus cancelled');
  perform pg_temp.ck((select status from booking.payments where id = pid) = 'cancelled' and (select raw -> 'booking_70' ->> 'prev_status' from booking.payments where id = pid) = 'pending', 'D4: avoin maksu peruttu ja leimattu');
  perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = oid) = v_mail, 'D5: siivous ei lisää sähköpostia');
  perform pg_temp.ck(exists (select 1 from booking.orders where id = oid), 'D6: tilausta ei poistettu');
  perform pg_temp.ck(booking._cancel_unpaid_expired_orders() = 0, 'D7: toinen ajo ei koske samaa tilausta');

  r := pg_temp.mk(v_slots[5], 'd2@t69.example'); oid := pg_temp.oid((r ->> 'token')::uuid);
  update booking.reservations set status = 'expired', hold_expires_at = now() - interval '2 minutes' where order_id = oid;
  update booking.orders set status = 'expired', payment_status = 'paid' where id = oid;
  perform booking._cancel_unpaid_expired_orders();
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'expired' and (select status from booking.reservations where order_id = oid) = 'expired', 'D8: maksettua expired-tilausta ei peruta');

  r := pg_temp.mk(v_slots[6], 'd3@t69.example'); oid := pg_temp.oid((r ->> 'token')::uuid);
  update booking.reservations set status = 'expired', hold_expires_at = now() - interval '2 minutes' where order_id = oid;
  update booking.orders set status = 'expired', payment_status = 'partially_paid' where id = oid;
  perform booking._cancel_unpaid_expired_orders();
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'expired', 'D9: partially_paid expired jää (avoin kysymys, ei automaattista peruutusta)');

  r := pg_temp.mk(v_slots[2], 'd4@t69.example'); oid := pg_temp.oid((r ->> 'token')::uuid);
  insert into booking.payments(order_id, method, provider, status, amount) values (oid, 'cash', 'manual', 'pending', 1) returning id into pid;
  insert into booking.receipts(receipt_no, kind, series, year, seq, order_id, payment_id, total_gross, snapshot, text_body)
  values ('T69-SKIP-' || oid::text, 'receipt', 'T69', 2099, 1, oid, pid, 1, '{}'::jsonb, 't69');
  update booking.reservations set status = 'expired', hold_expires_at = now() - interval '2 minutes' where order_id = oid;
  update booking.orders set status = 'expired', payment_status = 'unpaid' where id = oid;
  perform booking._cancel_unpaid_expired_orders();
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'expired', 'D10: kuitillista tilausta ei peruta');

  r := pg_temp.mk(v_slots[4], 'd5@t69.example');
  oid := pg_temp.oid((r ->> 'token')::uuid);
  perform pg_temp.ck(oid is not null, 'D11: confirmed-suojan tilaus luotu (' || coalesce(r ->> 'code', '') || ')');
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = oid;
  update booking.orders set status = 'expired', payment_status = 'unpaid' where id = oid;
  perform booking._cancel_unpaid_expired_orders();
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'expired' and (select status from booking.reservations where order_id = oid) = 'confirmed', 'D12: confirmed-varausta ei peruta vaikka tilaus olisi expired');

  -- D13 Johku-tuonti: expired + unpaid, mutta external_source johku ja hold_kind tyhjä → ei muutosta
  r := pg_temp.mk(v_slots[7], 'j1@t70.example'); oid := pg_temp.oid((r ->> 'token')::uuid);
  perform pg_temp.ck(oid is not null, 'D13a: Johku-tapauksen tilaus luotu (' || coalesce(r ->> 'code', '') || ')');
  update booking.orders set status = 'expired', payment_status = 'unpaid', cancelled_at = null, hold_kind = null, external_source = 'johku', external_id = 't70-johku-' || id::text where id = oid;
  update booking.reservations set status = 'expired', cancel_reason = null, cancelled_at = null, hold_expires_at = now() - interval '2 minutes' where order_id = oid;
  select count(*) into v_mail from booking.email_outbox where order_id = oid;
  perform booking._cancel_unpaid_expired_orders();
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'expired' and (select external_source from booking.orders where id = oid) = 'johku' and (select hold_kind from booking.orders where id = oid) is null and not (coalesce((select external_meta from booking.orders where id = oid), '{}'::jsonb) ? 'booking_70'), 'D13: Johku-tuontitilaus (external_source johku, expired) ei muutu');
  perform pg_temp.ck((select status from booking.reservations where order_id = oid) = 'expired' and not (coalesce((select external_meta from booking.reservations where order_id = oid), '{}'::jsonb) ? 'booking_70'), 'D13b: Johku-tilauksen varausta ei leimata');
  perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = oid) = v_mail, 'D13c: Johku-tuontiin ei jonoudu viestiä');

  -- D14 sama rajaus toisesta suunnasta: native mutta hold_kind tyhjä ei ole kassapito
  r := pg_temp.mk(v_slots[8], 'n1@t70.example'); oid := pg_temp.oid((r ->> 'token')::uuid);
  update booking.orders set status = 'expired', payment_status = 'unpaid', cancelled_at = null, hold_kind = null where id = oid;
  update booking.reservations set status = 'expired', cancel_reason = null, cancelled_at = null, hold_expires_at = now() - interval '2 minutes' where order_id = oid;
  perform booking._cancel_unpaid_expired_orders();
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'expired' and (select external_source from booking.orders where id = oid) is null and (select hold_kind from booking.orders where id = oid) is null and not (coalesce((select external_meta from booking.orders where id = oid), '{}'::jsonb) ? 'booking_70'), 'D14: hold_kind-tyhjä expired-tilaus ei ole kassapito eikä muutu');

  select booking._checkout_state_json((select id from booking.orders where public_token = (select public_token from booking.orders where id = (select order_id from booking.reservations where cancel_reason = 'hold_expired' order by id desc limit 1)))) ->> 'cancel_reason' into v_reason;
  perform pg_temp.ck(v_reason = 'hold_expired', 'E1: checkout cancel_reason hold_expired');
  select booking._checkout_state_json(oid) ->> 'checkout_state' into v_st;
  perform pg_temp.ck(v_st = 'expired', 'E2: ohitettu expired-tilaus näkyy yhä expired (ei siivottu)');
  perform pg_temp.ck((select mode from booking.integration_config where key = 'resend') = 'dry_run', 'E3: resend pysyy dry_run');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._cancel_unpaid_expired_orders()', 'execute'), 'E4: siivousfunktio ei ole anonin ajettavissa');
  perform pg_temp.ck(current_setting('lock_timeout') = '3s', 'E5: lock_timeout on yhä 3s testin jälkeen');

  select last_value into v_seq1 from booking.orders_order_no_seq;
  select count(*) into v_made from booking.orders where id > v_maxid;
  select count(*) into v_foreign from booking.orders where id > v_maxid and created_at <> now();
  if v_foreign = 0 then perform setval('booking.orders_order_no_seq', v_seq0, true); end if;
  raise exception 'TESTRESULT pass=% fail=% seq0=% seq1=% orders_made=% :: %',
    (select count(*) from t70_r where ok), (select count(*) from t70_r where not ok), v_seq0, v_seq1, v_made,
    coalesce((select string_agg(label, ' | ') from t70_r where not ok), 'ALL OK');
end $t$;
