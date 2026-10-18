-- t53_checkout_hold: kassan pitomalli. Ajetaan migraation JÄLKEEN (tai migraation kanssa samassa rollback-transaktiossa).
-- Kaikki yhdessä DO-lohkossa; lopuksi tahallinen poikkeus => KAIKKI kumoutuu. Tulos luetaan virheilmoituksesta (TESTRESULT ...).
-- Tilausnumerolaskuri (identity) ei ole transaktionaalinen: lohko palauttaa sen setvalilla jos KAIKKI uudet tilaukset ovat testin omia.
set local lock_timeout = '3s';
set local statement_timeout = '90s';
create temp table t53_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t53_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.mk(p_start timestamptz, p_email text, p_persons int default 2, p_kind text default 'private', p_company jsonb default null) returns jsonb language sql as $$
  select booking.public_create_treatment_booking(11, p_start, p_persons, 'Testi Asiakas', p_email, '+358401234567', false, 'fi', null, p_kind, p_company, null) $$;
create function pg_temp.oid(p_tok uuid) returns bigint language sql as $$ select id from booking.orders where public_token = p_tok $$;
do $t$
declare
  v_seq0 bigint; v_seq1 bigint; v_maxid bigint; v_foreign int; v_made int;
  r jsonb; r2 jsonb; tok uuid; tok2 uuid; oid bigint; pid bigint; ref text; v_total numeric; v_amt numeric; v_bal0 numeric; v_bal1 numeric;
  r_s record; v_slots timestamptz[]; v_rule bigint; v_rdate date; v_rule2 bigint; v_rdate2 date; g1 bigint; g2 bigint; g3 bigint; v_det text; v_msg text; v_ok boolean;
begin
  -- ---------- valmistelu ----------
  select last_value into v_seq0 from booking.orders_order_no_seq;
  select coalesce(max(id), 0) into v_maxid from booking.orders;
  update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode';
  update booking.integration_config set mode = 'test' where key = 'mobilepay';
  insert into booking.gift_cards(code, issuer, kind, initial_amount, balance, status, source, vat_treatment, accounting_origin, balance_verified, valid_to)
  values ('HHTEST000001', 'own', 'value', 1000, 1000, 'active', 'native', 'at_redemption', 'native', true, current_date + 100) returning id into g1;
  insert into booking.gift_cards(code, issuer, kind, initial_amount, balance, status, source, vat_treatment, accounting_origin, balance_verified, valid_to)
  values ('HHTEST000002', 'own', 'value', 900, 900, 'active', 'native', 'at_redemption', 'native', true, current_date + 100) returning id into g2;
  insert into booking.gift_cards(code, issuer, kind, initial_amount, balance, status, source, vat_treatment, accounting_origin, balance_verified, valid_to, single_order)
  values ('HHTEST000003', 'own', 'value', 50, 50, 'active', 'native', 'at_redemption', 'native', true, current_date + 100, true) returning id into g3;
  for r_s in select q.starts_at from (
      select * from booking.public_treatment_availability(11, current_date + 3, current_date + 16, 2)
      union all select * from booking.public_treatment_availability(11, current_date + 17, current_date + 30, 2)
      union all select * from booking.public_treatment_availability(11, current_date + 31, current_date + 44, 2)) q
     where q.status = 'available' order by q.starts_at loop
    if v_slots is null or r_s.starts_at >= v_slots[cardinality(v_slots)] + interval '5 hours' then v_slots := array_append(v_slots, r_s.starts_at); end if;   -- ei päällekkäisiä aikoja
  end loop;
  if v_slots is null or cardinality(v_slots) < 7 then raise exception 'TESTRESULT_ABORT vapaita hoitoaikoja %', coalesce(cardinality(v_slots), 0); end if;
  select rule_id, session_date into v_rule, v_rdate from booking.public_availability(3, current_date + 3, current_date + 16) where status = 'available' order by session_date limit 1;
  select rule_id, session_date into v_rule2, v_rdate2 from booking.public_availability(3, current_date + 3, current_date + 16) where status = 'available' and session_date <> v_rdate order by session_date limit 1;
  perform pg_temp.ck(v_rule is not null and v_rule2 is not null, 'S0: yleinen vuoro löytyi testiin');

  -- ---------- A) hoitovaraus pitotilassa ----------
  r := pg_temp.mk(v_slots[1], 'a1@t53.example');
  perform pg_temp.ck((r ->> 'ok')::boolean, 'A1: varaus onnistuu (' || coalesce(r ->> 'code', '') || ')');
  tok := (r ->> 'token')::uuid; oid := pg_temp.oid(tok); v_total := (r ->> 'total')::numeric;
  perform pg_temp.ck(r ->> 'status' = 'pending', 'A2: status pending');
  perform pg_temp.ck(r ->> 'checkout_state' = 'awaiting_payment' and (r ->> 'awaiting_payment')::boolean, 'A3: checkout_state awaiting_payment');
  perform pg_temp.ck((r ->> 'hold_expires_at')::timestamptz between now() + interval '14 minutes 30 seconds' and now() + interval '15 minutes 30 seconds', 'A4: hold_expires_at ~ +15 min');
  perform pg_temp.ck((r ->> 'seconds_left')::int between 870 and 900, 'A5: seconds_left ~ 900');
  perform pg_temp.ck((r ->> 'remaining_amount')::numeric = v_total and v_total > 0, 'A6: remaining_amount = total');
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'pending' and (select hold_kind from booking.orders where id = oid) = 'checkout', 'A7: tilaus pending/hold_kind checkout');
  perform pg_temp.ck((select count(*) from booking.reservations where order_id = oid and status = 'pending' and hold_expires_at is not null) = 1, 'A8: varaus pending + hold_expires_at');
  perform pg_temp.ck(not exists (select 1 from booking.payments where order_id = oid), 'A9: ei paikkaajamaksua pitotilassa');
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = oid), 'A10: ei vahvistusviestiä eikä kuittia luonnissa');
  perform pg_temp.ck(not exists (select 1 from booking.receipts where order_id = oid), 'A11: ei kuittia luonnissa');
  r2 := booking.public_get_order(tok);
  perform pg_temp.ck(r2 ->> 'status' = 'pending' and r2 ->> 'checkout_state' = 'awaiting_payment' and r2 ->> 'hold_expires_at' is not null and (r2 ->> 'unpaid')::numeric = v_total and (r2 ->> 'remaining_amount')::numeric = v_total, 'A12: public_get_order palauttaa tilan, pidon ja jäljellä olevan');
  r2 := booking.public_get_booking(tok);
  perform pg_temp.ck(r2 ->> 'status' = 'pending' and r2 ->> 'checkout_state' = 'awaiting_payment' and r2 ->> 'hold_expires_at' is not null and r2 ->> 'server_now' is not null, 'A13: public_get_booking palauttaa tilan ja pidon');
  r2 := booking.public_payment_options(tok);
  perform pg_temp.ck((r2 -> 'order' ->> 'can_pay_online')::boolean and r2 -> 'order' ->> 'checkout_state' = 'awaiting_payment', 'A14: public_payment_options: voi maksaa + tila');
  r2 := booking.public_checkout_payment_options();
  perform pg_temp.ck((r2 ->> 'hold_until_paid')::boolean and (r2 ->> 'hold_minutes')::int = 15, 'A15: public_checkout_payment_options kertoo pitotilan ja minuutit');
  r2 := pg_temp.mk(v_slots[1], 'a2@t53.example');
  perform pg_temp.ck(r2 ->> 'code' = 'slot_unavailable', 'A16: pito estää saman ajan toiselta (' || coalesce(r2 ->> 'code', 'ok') || ')');

  -- ---------- B) lahjakortti: osamaksu ei vahvista; ylitys estetty; kate => vahvistus + kuitit ----------
  v_amt := round(v_total / 3, 2);
  select balance into v_bal0 from booking.gift_cards where id = g1;
  r := booking.public_apply_gift_card(tok, 'HHTEST000001', v_amt);
  perform pg_temp.ck((r ->> 'ok')::boolean, 'B1: osamaksu lahjakortilla onnistuu (' || coalesce(r ->> 'code', '') || ')');
  perform pg_temp.ck(not (r ->> 'order_confirmed')::boolean and (r ->> 'remaining')::numeric = v_total - v_amt and r ->> 'checkout_state' = 'awaiting_payment', 'B2: osamaksu ei vahvista, jäljellä oikein');
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'pending' and (select status from booking.reservations where order_id = oid) = 'pending', 'B3: tilaus ja varaus edelleen pending');
  perform pg_temp.ck(not exists (select 1 from booking.receipts where order_id = oid), 'B4: kuittia ei anneta osamaksusta ennen vahvistusta');
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = oid), 'B5: ei viestejä ennen vahvistusta');
  perform pg_temp.ck((select balance from booking.gift_cards where id = g1) = v_bal0 - v_amt, 'B6: kortin saldo vähenee');
  r := booking.public_apply_gift_card(tok, 'HHTEST000002', v_total);
  perform pg_temp.ck(r ->> 'code' = 'amount_exceeds_unpaid', 'B7: yli maksamattoman ei mene läpi (' || coalesce(r ->> 'code', 'ok') || ')');
  r := booking.public_apply_gift_card(tok, 'HHTEST000002', null);
  perform pg_temp.ck((r ->> 'ok')::boolean and (r ->> 'order_confirmed')::boolean and (r ->> 'remaining')::numeric = 0, 'B8: loppuosa kortilla => vahvistuu (' || coalesce(r ->> 'code', '') || ')');
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'confirmed' and (select payment_status from booking.orders where id = oid) = 'paid', 'B9: tilaus confirmed/paid');
  perform pg_temp.ck((select status from booking.reservations where order_id = oid) = 'confirmed' and (select hold_expires_at from booking.reservations where order_id = oid) is null, 'B10: varaus confirmed, pito poistunut');
  perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = oid and kind = 'order_confirmation') = 1, 'B11: täsmälleen yksi vahvistusviesti');
  perform pg_temp.ck((select count(*) from booking.receipts where order_id = oid and kind = 'receipt') = 2, 'B12: kuitit molemmista korttimaksuista vahvistuksen jälkeen (' || (select count(*) from booking.receipts where order_id = oid) || ')');
  perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = oid and kind = 'receipt') = 2, 'B13: kuittiviestit jonossa (2)');
  r := booking.public_apply_gift_card(tok, 'HHTEST000002', null);
  perform pg_temp.ck(r ->> 'code' = 'nothing_to_pay', 'B14: maksettua tilausta ei voi maksaa uudelleen (' || coalesce(r ->> 'code', 'ok') || ')');
  perform pg_temp.ck(booking._checkout_state_json(oid) ->> 'checkout_state' = 'confirmed', 'B15: lopputila confirmed');

  -- ---------- C) vanheneminen: osamaksu palautuu kortille; kertakäyttökortti ehjäksi ----------
  select balance into v_bal0 from booking.gift_cards where id = g1;
  r := pg_temp.mk(v_slots[2], 'c1@t53.example'); tok := (r ->> 'token')::uuid; oid := pg_temp.oid(tok); v_total := (r ->> 'total')::numeric;
  r := booking.public_apply_gift_card(tok, 'HHTEST000001', 5);
  perform pg_temp.ck((r ->> 'ok')::boolean and not (r ->> 'order_confirmed')::boolean, 'C1: osamaksu 5 € (' || coalesce(r ->> 'code', '') || ')');
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = oid;
  perform pg_temp.ck(booking._checkout_state_json(oid) ->> 'checkout_state' = 'expired', 'C2: pito ohi => tila expired jo ennen cronia');
  r := booking.public_apply_gift_card(tok, 'HHTEST000002', null);
  perform pg_temp.ck(r ->> 'code' = 'order_expired', 'C3: vanhentuneeseen pitoon ei voi enää maksaa lahjakortilla (' || coalesce(r ->> 'code', 'ok') || ')');
  perform booking.expire_holds();
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'cancelled' and (select status from booking.reservations where order_id = oid) = 'cancelled' and (select cancel_reason from booking.reservations where order_id = oid) = 'hold_expired', 'C4: cron perui pidon (tilaus+varaus cancelled, syy hold_expired)');
  perform pg_temp.ck((select balance from booking.gift_cards where id = g1) = v_bal0, 'C5: osamaksu palautettu kortille');
  perform pg_temp.ck((select status from booking.payments where order_id = oid and method = 'gift_card') = 'cancelled', 'C6: korttimaksu merkitty cancelled');
  perform pg_temp.ck(exists (select 1 from booking.gift_card_ledger where gift_card_id = g1 and order_id = oid and reason = 'refund' and delta = 5), 'C7: ledger-rivi palautuksesta');
  perform pg_temp.ck((select payment_status from booking.orders where id = oid) = 'unpaid', 'C8: payment_status unpaid');
  perform pg_temp.ck(not exists (select 1 from booking.receipts where order_id = oid) and not exists (select 1 from booking.email_outbox where order_id = oid and kind in ('receipt', 'order_confirmation')), 'C9: vanhentuneelle ei kuittia/vahvistusta');
  perform pg_temp.ck(booking.public_get_order(tok) ->> 'checkout_state' = 'cancelled' and booking.public_get_order(tok) ->> 'cancel_reason' = 'hold_expired', 'C10: public_get_order: cancelled / hold_expired');
  r := booking.public_apply_gift_card(tok, 'HHTEST000002', null);
  perform pg_temp.ck(r ->> 'code' = 'order_not_editable', 'C11: peruttuun tilaukseen ei voi maksaa');
  r := pg_temp.mk(v_slots[2], 'c2@t53.example');
  perform pg_temp.ck((r ->> 'ok')::boolean, 'C12: vapautunut aika on taas varattavissa (' || coalesce(r ->> 'code', '') || ')');
  -- kertakäyttökortti
  tok := (r ->> 'token')::uuid; oid := pg_temp.oid(tok);
  r := booking.public_apply_gift_card(tok, 'HHTEST000003', 10);
  perform pg_temp.ck((r ->> 'ok')::boolean and (select balance from booking.gift_cards where id = g3) = 0, 'C13: kertakäyttökortin jäännös menetetty käytössä (' || coalesce(r ->> 'code', '') || ')');
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = oid;
  perform booking.expire_holds();
  perform pg_temp.ck((select balance from booking.gift_cards where id = g3) = 50 and (select status from booking.gift_cards where id = g3) = 'active', 'C14: kertakäyttökortin koko saldo palautuu vanhenemisessa');

  -- ---------- D) MobilePay kesken: pito jatkuu, cron odottaa; lopputulos vapauttaa/vahvistaa ----------
  r := pg_temp.mk(v_slots[2], 'd1@t53.example'); tok := (r ->> 'token')::uuid; oid := pg_temp.oid(tok); v_total := (r ->> 'total')::numeric;
  r := booking.mobilepay_payment_prepare(tok, null, 120);
  perform pg_temp.ck((r ->> 'ok')::boolean and (r ->> 'amount')::numeric = v_total, 'D1: mobilepay_payment_prepare: summa = jäljellä');
  pid := (r ->> 'payment_id')::bigint; ref := r ->> 'reference';
  perform pg_temp.ck((select min(hold_expires_at) from booking.reservations where order_id = oid) > now() + interval '14 minutes', 'D2: pito jatkuu kun MobilePay alkaa');
  perform pg_temp.ck(booking._order_mp_inflight(oid), 'D3: maksu tunnistetaan keskeneräiseksi');
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = oid;
  perform booking.expire_holds();
  perform pg_temp.ck((select status from booking.reservations where order_id = oid) = 'pending' and (select status from booking.orders where id = oid) = 'pending', 'D4: cron EI vapauta kun MobilePay on kesken');
  r2 := booking.public_get_order(tok);
  perform pg_temp.ck(r2 ->> 'status' = 'pending' and r2 ->> 'checkout_state' = 'processing_payment' and (r2 ->> 'payment_in_progress')::boolean, 'D5: public_get_order: processing_payment');
  -- odotus ei ole ikuinen: vanha yritys (yli grace) ei enää suojaa
  update booking.payments set raw = jsonb_set(raw, '{mobilepay,attempt_started_at}', to_jsonb(now() - interval '20 minutes')) where id = pid;
  perform pg_temp.ck(not booking._order_mp_inflight(oid), 'D6: yli grace-ajan vanha yritys ei ole enää kesken');
  update booking.payments set raw = jsonb_set(raw, '{mobilepay,attempt_started_at}', to_jsonb(now())) where id = pid;
  -- Vipps lopputila ABORTED => ei kesken => vapautus
  update booking.payments set raw = jsonb_set(raw, '{mobilepay,last_state}', '"ABORTED"') where id = pid;
  perform booking.expire_holds();
  perform pg_temp.ck((select status from booking.reservations where order_id = oid) = 'cancelled' and (select cancel_reason from booking.reservations where order_id = oid) = 'hold_expired' and (select status from booking.orders where id = oid) = 'cancelled', 'D7: lopputilan (ABORTED) jälkeen pito perutaan');

  -- ---------- E) MobilePay-maksu kokonaan: vahvistus + kuitti; ylimaksu-/alimaksusuojat ----------
  r := pg_temp.mk(v_slots[3], 'e1@t53.example'); tok := (r ->> 'token')::uuid; oid := pg_temp.oid(tok); v_total := (r ->> 'total')::numeric;
  r := booking.mobilepay_payment_prepare(tok, null, 120); pid := (r ->> 'payment_id')::bigint; ref := r ->> 'reference';
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = oid) and not exists (select 1 from booking.receipts where order_id = oid), 'E1: maksun aloitus ei lähetä viestiä eikä kuittia');
  perform pg_temp.ck((booking.mobilepay_payment_confirmable(ref) ->> 'confirmable')::boolean, 'E2: maksu on vahvistettavissa');
  r := booking.payment_mark_paid('mobilepay', ref, v_total, '{"test":true}'::jsonb);
  perform pg_temp.ck((r ->> 'ok')::boolean and (r ->> 'overpaid_amount')::numeric = 0, 'E3: payment_mark_paid ok, ei ylimaksua');
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'confirmed' and (select status from booking.reservations where order_id = oid) = 'confirmed' and (select payment_status from booking.orders where id = oid) = 'paid', 'E4: vahvistui kun summa katettu');
  perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = oid and kind = 'order_confirmation') = 1 and (select count(*) from booking.receipts where order_id = oid) = 1 and (select count(*) from booking.email_outbox where order_id = oid and kind = 'receipt') = 1, 'E5: yksi vahvistusviesti + yksi kuitti');
  perform pg_temp.ck((booking.payment_mark_paid('mobilepay', ref, v_total, null) ->> 'already')::boolean, 'E6: toinen callback idempotentti (ei tuplakuittia)');
  perform pg_temp.ck((select count(*) from booking.receipts where order_id = oid) = 1, 'E7: ei tuplakuittia');
  -- uusi maksuyritys maksetulle tilaukselle
  begin perform booking.mobilepay_payment_prepare(tok, null, 120); perform pg_temp.ck(false, 'E8: prepare maksetulle tilaukselle piti epäonnistua');
  exception when sqlstate 'BK001' then get stacked diagnostics v_det = pg_exception_detail; perform pg_temp.ck(v_det in ('already_paid', 'nothing_to_pay'), 'E8: prepare maksetulle tilaukselle estetty (' || coalesce(v_det, '') || ')'); end;
  -- ylimaksu: eksynyt pending-maksu maksetulle tilaukselle
  insert into booking.payments(order_id, method, provider, status, amount, provider_ref, raw) values (oid, 'mobilepay', 'mobilepay', 'pending', 10, 'x-over-' || oid, '{}'::jsonb);
  perform pg_temp.ck(booking.mobilepay_payment_confirmable('x-over-' || oid) ->> 'reason' = 'overpay', 'E9: ylimaksu ei ole vahvistettavissa (cancel valtuutus)');
  -- alimaksu: odottava tilaus, maksu pienempi kuin jäljellä
  r := pg_temp.mk(v_slots[4], 'e2@t53.example'); tok2 := (r ->> 'token')::uuid; v_total := (r ->> 'total')::numeric;
  insert into booking.payments(order_id, method, provider, status, amount, provider_ref, raw) values (pg_temp.oid(tok2), 'mobilepay', 'mobilepay', 'pending', v_total - 5, 'x-under-' || pg_temp.oid(tok2), '{}'::jsonb);
  perform pg_temp.ck(booking.mobilepay_payment_confirmable('x-under-' || pg_temp.oid(tok2)) ->> 'reason' = 'underpay', 'E10: alimaksu ei vahvista odottavaa tilausta');
  -- ylimaksun merkintä (jo veloitettu): lisämaksu maksetulle tilaukselle
  begin
    r := booking.payment_mark_paid('mobilepay', 'x-over-' || oid, null, null);
    perform pg_temp.ck((r ->> 'overpaid_amount')::numeric = 10 and (select internal_note from booking.orders where id = oid) like '%YLIMAKSU 10.00%', 'E11: veloitettu ylimaksu merkitään palautettavaksi');
  exception when others then perform pg_temp.ck(false, 'E11: poikkeus ' || sqlerrm); end;

  -- ---------- F) lahjakortin osa + MobilePay loppu ----------
  r := pg_temp.mk(v_slots[5], 'f1@t53.example'); tok := (r ->> 'token')::uuid; oid := pg_temp.oid(tok); v_total := (r ->> 'total')::numeric;
  r := booking.public_apply_gift_card(tok, 'HHTEST000001', 5);
  perform pg_temp.ck((r ->> 'ok')::boolean, 'F1: lahjakortti 5 € (' || coalesce(r ->> 'code', '') || ')');
  r := booking.mobilepay_payment_prepare(tok, null, 120); pid := (r ->> 'payment_id')::bigint; ref := r ->> 'reference';
  perform pg_temp.ck((r ->> 'amount')::numeric = v_total - 5, 'F2: MobilePay-summa = jäännös');
  perform pg_temp.ck((booking.mobilepay_payment_confirmable(ref) ->> 'confirmable')::boolean, 'F3: vahvistettavissa');
  perform booking.payment_mark_paid('mobilepay', ref, v_total - 5, null);
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'confirmed' and (select payment_status from booking.orders where id = oid) = 'paid', 'F4: katettu => vahvistui');
  perform pg_temp.ck((select count(*) from booking.receipts where order_id = oid and kind = 'receipt') = 2 and (select count(*) from booking.email_outbox where order_id = oid and kind = 'order_confirmation') = 1, 'F5: 2 kuittia (kortti + MobilePay) ja 1 vahvistusviesti');
  -- lahjakortti kesken MobilePay -yrityksen: kortti peruu avoimen MobilePay-maksun (ei tuplamaksua)
  r := pg_temp.mk(v_slots[6], 'f2@t53.example'); tok := (r ->> 'token')::uuid; oid := pg_temp.oid(tok); v_total := (r ->> 'total')::numeric;
  r := booking.mobilepay_payment_prepare(tok, null, 120); ref := r ->> 'reference'; pid := (r ->> 'payment_id')::bigint;
  r := booking.public_apply_gift_card(tok, 'HHTEST000002', null);
  perform pg_temp.ck((r ->> 'order_confirmed')::boolean and (select status from booking.payments where id = pid) = 'cancelled', 'F6: kortti kattaa kaiken ja peruu avoimen MobilePay-maksun');
  perform pg_temp.ck(booking.mobilepay_payment_confirmable(ref) ->> 'reason' = 'payment_cancelled', 'F7: peruttu MobilePay-maksu ei vahvistu jälkikäteen (valtuutus peruttavissa)');

  -- ---------- G) iso ryhmä: alustava varaus ----------
  update booking.settings set value = '2'::jsonb where key = 'checkout_group_threshold_persons';
  r := pg_temp.mk(v_slots[2], 'g1@t53.example', 2); tok := (r ->> 'token')::uuid; oid := pg_temp.oid(tok);
  perform pg_temp.ck((r ->> 'ok')::boolean and r ->> 'checkout_state' = 'preliminary' and r ->> 'hold_kind' = 'preliminary', 'G1: alustava varaus (' || coalesce(r ->> 'code', '') || ')');
  perform pg_temp.ck((r ->> 'hold_expires_at')::timestamptz between now() + interval '6 days 23 hours' and now() + interval '7 days 1 hour', 'G2: vapautuspäivä ~ +7 pv');
  perform pg_temp.ck(not (booking.public_payment_options(tok) -> 'order' ->> 'can_pay_online')::boolean, 'G3: alustavaa ei makseta verkossa');
  r := booking.public_apply_gift_card(tok, 'HHTEST000002', null);
  perform pg_temp.ck(r ->> 'code' = 'order_preliminary', 'G4: lahjakortti ei lunasta alustavaa (' || coalesce(r ->> 'code', 'ok') || ')');
  begin perform booking.mobilepay_payment_prepare(tok, null, 120); perform pg_temp.ck(false, 'G5: prepare alustavalle piti epäonnistua');
  exception when sqlstate 'BK001' then get stacked diagnostics v_det = pg_exception_detail; perform pg_temp.ck(v_det = 'order_not_payable', 'G5: prepare alustavalle estetty'); end;
  perform booking.expire_holds();
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'pending', 'G6: cron ei vapauta ennen vapautuspäivää');
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = oid;
  perform booking.expire_holds();
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'cancelled' and (select cancel_reason from booking.reservations where order_id = oid) = 'hold_expired', 'G7: vapautuspäivän jälkeen perutaan');
  update booking.settings set value = '0'::jsonb where key = 'checkout_group_threshold_persons';

  -- ---------- H) sauna (yleinen vuoro), yritys, verkkomaksu pois ----------
  r := booking.public_create_booking(v_rule, v_rdate, 2, 'Sauna Testi', 'h1@t53.example', '+358401234567');
  perform pg_temp.ck((r ->> 'ok')::boolean and r ->> 'status' = 'pending' and r ->> 'checkout_state' = 'awaiting_payment' and (r ->> 'hold_expires_at')::timestamptz > now() + interval '14 minutes', 'H1: sauna: pending + hold (' || coalesce(r ->> 'code', '') || ')');
  perform pg_temp.ck(not exists (select 1 from booking.payments where order_id = pg_temp.oid((r ->> 'token')::uuid)) and not exists (select 1 from booking.email_outbox where order_id = pg_temp.oid((r ->> 'token')::uuid)), 'H2: sauna: ei paikkaajamaksua eikä viestejä');
  r := booking.public_create_booking(v_rule, v_rdate, 2, 'Yritys Testi', 'h2@t53.example', '+358401234567', false, 'fi', null, 'company',
         '{"company_name":"Testi Oy","business_id":"0112038-9","street":"Testikatu 1","zip":"00100","city":"Helsinki"}'::jsonb);
  perform pg_temp.ck((r ->> 'ok')::boolean and r ->> 'status' = 'confirmed' and r ->> 'checkout_state' = 'confirmed_unpaid', 'H3: yritys laskulle: vahvistuu heti (' || coalesce(r ->> 'code', '') || ')');
  update booking.settings set value = 'false'::jsonb where key = 'checkout_company_invoice_enabled';
  r := booking.public_create_booking(v_rule2, v_rdate2, 2, 'Yritys Testi', 'h3@t53.example', '+358401234567', false, 'fi', null, 'company',
         '{"company_name":"Testi Oy","business_id":"0112038-9","street":"Testikatu 1","zip":"00100","city":"Helsinki"}'::jsonb);
  perform pg_temp.ck((r ->> 'ok')::boolean and r ->> 'status' = 'pending', 'H4: yritys-asetus pois: yritys pitoon (' || coalesce(r ->> 'code', '') || ')');
  update booking.settings set value = 'true'::jsonb where key = 'checkout_company_invoice_enabled';
  update booking.integration_config set mode = 'off' where key = 'mobilepay';
  r := pg_temp.mk(v_slots[7], 'h4@t53.example');
  perform pg_temp.ck(r ->> 'code' = 'online_payment_unavailable', 'H5: verkkomaksu pois => online_payment_unavailable (' || coalesce(r ->> 'code', 'ok') || ')');
  r := booking.public_create_booking(v_rule2, v_rdate2, 2, 'Sauna Testi', 'h5@t53.example', '+358401234567');
  perform pg_temp.ck(r ->> 'code' = 'online_payment_unavailable', 'H6: sauna: sama virhe');
  update booking.integration_config set mode = 'test' where key = 'mobilepay';

  -- ---------- I) pay_later ennallaan ----------
  update booking.settings set value = '"pay_later"'::jsonb where key = 'public_payment_mode';
  r := pg_temp.mk(v_slots[7], 'i1@t53.example'); oid := pg_temp.oid((r ->> 'token')::uuid);
  perform pg_temp.ck((r ->> 'ok')::boolean and r ->> 'status' = 'confirmed' and r ->> 'payment_mode' = 'pay_later' and r ->> 'checkout_state' = 'confirmed_unpaid', 'I1: pay_later hoitovaraus: confirmed/ennallaan (' || coalesce(r ->> 'code', '') || ')');
  perform pg_temp.ck(exists (select 1 from booking.payments where order_id = oid and provider = 'manual' and method = 'pay_later') and (select hold_kind from booking.orders where id = oid) is null, 'I2: paikkaajamaksu pay_later + ei hold_kind');
  r := booking.public_create_booking(v_rule2, v_rdate2, 2, 'Sauna Testi', 'i2@t53.example', '+358401234567');
  perform pg_temp.ck((r ->> 'ok')::boolean and r ->> 'status' = 'confirmed' and r ->> 'payment_mode' = 'pay_later', 'I3: pay_later sauna: ennallaan');
  perform pg_temp.ck((booking.public_checkout_payment_options() ->> 'hold_until_paid')::boolean = false, 'I4: checkout_payment_options: hold_until_paid=false');

  -- ---------- J) asetukset ----------
  perform pg_temp.ck(booking._checkout_hold_minutes() = 15, 'J1: oletus 15 min');
  update booking.settings set value = '"x"'::jsonb where key = 'checkout_hold_minutes';
  perform pg_temp.ck(booking._checkout_hold_minutes() = 15, 'J2: virheellinen arvo => oletus');
  update booking.settings set value = '2'::jsonb where key = 'checkout_hold_minutes';
  perform pg_temp.ck(booking._checkout_hold_minutes() = 5, 'J3: alaraja 5 min');
  update booking.settings set value = '15'::jsonb where key = 'checkout_hold_minutes';
  perform pg_temp.ck((select count(*) from booking.settings where key like 'checkout\_%') = 6, 'J4: 6 asetusta');
  perform pg_temp.ck((select mode from booking.integration_config where key = 'resend') = 'dry_run', 'J5: send-emails (resend) pysyy dry_run');

  -- ---------- tilausnumerolaskuri: palautus jos kaikki uudet tilaukset ovat testin omia ----------
  select last_value into v_seq1 from booking.orders_order_no_seq;
  select count(*) into v_made from booking.orders where id > v_maxid;
  select count(*) into v_made from booking.orders where id > v_maxid;
  select count(*) into v_foreign from booking.orders where id > v_maxid and created_at <> now();   -- testin omat tilaukset: created_at = transaktion alku
  if v_foreign = 0 then perform setval('booking.orders_order_no_seq', v_seq0, true); end if;
  raise exception 'TESTRESULT pass=% fail=% seq0=% seq1=% orders_made=% :: %',
    (select count(*) from t53_r where ok), (select count(*) from t53_r where not ok), v_seq0, v_seq1, v_made,
    coalesce((select string_agg(label, ' | ') from t53_r where not ok), 'ALL OK');
end $t$;
