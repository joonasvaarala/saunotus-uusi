-- t280_281: lahjakortti-/kumppanivarauksen peruutus (booking_280) + yhdistetty reservation_cancelled-viesti (booking_281).
-- Ajetaan migraatioiden 279, 280, 281 ja fixtures/10_test_helpers.sql:n JÄLKEEN. Yksi transaktio; lopuksi tahallinen poikkeus kumoaa kaiken.
-- Ei sähköposteja: rivit jäävät email_outboxiin, mitään ei lähetetä (claim ajetaan vain sisällön tarkistamiseksi ja kumotaan).
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t28x_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t28x_r values (coalesce(p_ok, false), p_label) $$;
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
-- tilaus: yksi varaus, osa lahjakortilla (p_gc euroa), loput korttipäätteellä (maksettu)
create function pg_temp.mk(p_rule bigint, p_date date, p_email text, p_code text, p_gc numeric) returns bigint language plpgsql as $$
declare a jsonb; o bigint;
begin
  perform test.reset_rl();
  a := test.pub_book(p_rule, p_date, 2, p_email);
  if not coalesce((a ->> 'ok')::boolean, false) then raise exception 'pub_book: %', a; end if;
  o := (test.ord((a ->> 'token')::uuid)).id;
  if p_code is not null then
    insert into booking.gift_cards(code, initial_amount, balance, valid_to, status) values (p_code, p_gc, p_gc, current_date + 200, 'active');
    perform booking._apply_gift_core(o, p_code, 'card_terminal', true, 'Testi');
  end if;
  return o;
end $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%'); d date := test.next_dow(1, 20);
  u_adm uuid := test.mk_staff('adm@t28x.example', 'admin'); u_mgr uuid := test.mk_staff('mgr@t28x.example', 'manager'); u_stf uuid := test.mk_staff('stf@t28x.example', 'staff');
  v jsonb; w jsonb; o1 bigint; o2 bigint; o3 bigint; o4 bigint; o5 bigint; r1 bigint; r2 bigint; r3 bigint; r4 bigint; r5 bigint;
  g1 bigint; v_total numeric; v_gcpay bigint; v_out bigint; v_act uuid; v_ref bigint; v_pay bigint; v_n int; v_ts timestamptz;
begin
  update booking.settings set value = '200'::jsonb where key = 'public_treatment_global_per_hour';
  update booking.settings set value = 'true'::jsonb where key = 'gift_cards.redeem_enabled'; -- vain tämän testitransaktion sisällä
  -- ================= 280: lahjakortti =================
  o1 := pg_temp.mk(v_rule, d, 'gc1@t28x.example', 'HHGCAAA28001', 20);
  select id into r1 from booking.reservations where order_id = o1;
  select id into g1 from booking.gift_cards where code = 'HHGCAAA28001';
  select total_gross into v_total from booking.orders where id = o1;
  select id into v_gcpay from booking.payments where order_id = o1 and method = 'gift_card';
  perform pg_temp.ck(v_gcpay is not null and (select balance from booking.gift_cards where id = g1) = 0, 'G0: lahjakortti käytetty tilaukseen');
  perform pg_temp.ck((select payment_status from booking.orders where id = o1) = 'paid', 'G0b: tilaus maksettu (lahjakortti + korttipääte)');

  v := pg_temp.as_(u_mgr, format('select booking.admin_reservation_cancel_options(%s)', r1));
  perform pg_temp.ck((v ->> 'gift_card_choice_required')::boolean and (v ->> 'gift_card_total')::numeric = 20, 'G1: valinta vaaditaan, 20 € ' || v::text);
  perform pg_temp.ck((v -> 'gift_cards' -> 0 ->> 'keep_allowed')::boolean and v -> 'gift_cards' -> 0 ->> 'code_last4' = '8001', 'G2: koodi voimassa, loppuosa');
  perform pg_temp.ck((v ->> 'money_share')::numeric = v_total - 20, 'G3: rahaosuus = summa - lahjakortti');
  perform pg_temp.ck((v ->> 'customer_email')::boolean, 'G3b: asiakkaalla sähköposti');
  v := pg_temp.as_(u_stf, format('select booking.admin_reservation_cancel_options(%s)', r1));
  perform pg_temp.ck((v ->> 'ok')::boolean and v ->> 'money_share' is null, 'G3c: staff näkee valinnat ilman rahasummaa');

  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_reservation(%s, null, true, null)', r1));
  perform pg_temp.ck(v ->> 'err' = 'gift_card_keep_required', 'G4: ilman valintaa ei peruta: ' || coalesce(v ->> 'err', v::text));
  v := pg_temp.as_(u_adm, format('select booking.admin_refund(%s, 5, %L, null, false)', v_gcpay, 'testi'));
  perform pg_temp.ck(v ->> 'err' = 'gift_card_requires_keep_choice', 'G5: lahjakorttimaksua ei hyvitetä suoraan: ' || coalesce(v ->> 'err', v::text));
  perform pg_temp.ck((select status from booking.reservations where id = r1) = 'confirmed', 'G6: varaus ennallaan');

  -- keep = true + rahahyvitys (käsin, valmis heti) + viesti → viesti heti; kuitit liitteenä, erilliset refund_receipt-rivit ohitetaan claimissa
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_reservation(%s, %L, true, null, true, true)', r1, 'asiakkaan pyyntö'));
  perform pg_temp.ck((v ->> 'ok')::boolean, 'K1: peruttu ' || coalesce(v ->> 'err', '') || coalesce(v ->> 'msg', ''));
  perform pg_temp.ck(v -> 'gift_card' -> 0 ->> 'action' = 'returned' and (v ->> 'refunded_total')::numeric = v_total - 20, 'K2: lahjakortti palautettu, raha hyvitetty ' || v::text);
  perform pg_temp.ck((select balance from booking.gift_cards where id = g1) = 20 and (select status from booking.gift_cards where id = g1) = 'active', 'K3: kortin saldo palautui 20 €');
  perform pg_temp.ck((v ->> 'notified')::boolean and v ->> 'action_id' is not null, 'K4: viesti jonossa');
  perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = o1 and kind = 'reservation_cancelled') = 1, 'K5: tasan yksi reservation_cancelled');
  select id into v_out from booking.email_outbox where order_id = o1 and kind = 'reservation_cancelled';
  perform pg_temp.ck((select next_attempt_at <= now() and status = 'pending' from booking.email_outbox where id = v_out), 'K6: lähtee heti (ei odotusta)');
  perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = o1 and kind = 'refund_receipt' and status = 'pending') = 2, 'K7: kuitit jonossa ennen lähetystä (raha + lahjakortti)');
  w := booking.email_outbox_claim(50);
  select x into v from jsonb_array_elements(w) x where (x ->> 'id')::bigint = v_out;
  perform pg_temp.ck(v is not null, 'K8: claim ottaa peruutusviestin');
  perform pg_temp.ck(jsonb_array_length(v -> 'cancellation' -> 'refunds') = 2
                     and (select bool_and(f ->> 'status' = 'done' and f -> 'receipt' ->> 'public_token' is not null) from jsonb_array_elements(v -> 'cancellation' -> 'refunds') f),
                     'K9: valmiit hyvitykset + kuitit liitteeksi ' || coalesce(v -> 'cancellation' ->> 'refunds', ''));
  perform pg_temp.ck((select sum((f ->> 'amount')::numeric) from jsonb_array_elements(v -> 'cancellation' -> 'refunds') f where f ->> 'kind' = 'money') = v_total - 20, 'K10: rahahyvityksen summa');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(w) x where (x ->> 'id')::bigint in (select id from booking.email_outbox where order_id = o1 and kind = 'refund_receipt'))
                     and (select count(*) from booking.email_outbox where order_id = o1 and kind = 'refund_receipt' and status = 'skipped') = 2, 'K11: erilliset kuittiviestit ohitettu (ei tuplaa)');
  perform pg_temp.ck(v -> 'cancellation' -> 'gift_card' -> 0 ->> 'action' = 'returned' and v -> 'cancellation' -> 'gift_card' -> 0 ->> 'code_last4' = '8001', 'K12: lahjakortin tila viestissä');
  perform pg_temp.ck(not (v -> 'cancellation' ->> 'order_kept')::boolean, 'K13: tilaus ei jää voimaan');
  perform pg_temp.ck((select status from booking.orders where id = o1) = 'cancelled', 'K14: tilaus peruttu (ainoa varaus)');
  perform pg_temp.ck(test.audit_n('GIFT_CARD_RETURNED_ON_CANCEL') >= 1, 'K15: palautus auditoitu');

  -- forfeit (keep=false) + kysymys "Ei" → ei viestiä, ei refund_receiptia
  o2 := pg_temp.mk(v_rule, d + 7, 'gc2@t28x.example', 'HHGCAAA28002', 15);
  select id into r2 from booking.reservations where order_id = o2;
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_reservation(%s, null, true, null, false, false)', r2));
  perform pg_temp.ck((v ->> 'ok')::boolean and v -> 'gift_card' -> 0 ->> 'action' = 'forfeited', 'F1: lahjakortti menetetty ' || coalesce(v ->> 'err', '') || coalesce(v ->> 'msg', ''));
  perform pg_temp.ck((select balance from booking.gift_cards where code = 'HHGCAAA28002') = 0, 'F2: saldo ei palaudu');
  perform pg_temp.ck((select count(*) from booking.gift_card_forfeits where order_id = o2) = 1 and test.audit_n('GIFT_CARD_FORFEITED_ON_CANCEL') >= 1, 'F3: menetys kirjattu + auditoitu');
  perform pg_temp.ck(not (v ->> 'notified')::boolean and not exists (select 1 from booking.email_outbox where order_id = o2 and kind in ('reservation_cancelled') ), 'F4: ei peruutusviestiä');
  perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = o2 and kind = 'refund_receipt' and status = 'pending') = 1, 'F5: ei peruutusviestiä → hyvityskuitti lähtee tavalliseen tapaan');

  -- vanhentunut lahjakortti: keep=true estetty
  o3 := pg_temp.mk(v_rule, d + 14, 'gc3@t28x.example', 'HHGCAAA28003', 10);
  select id into r3 from booking.reservations where order_id = o3;
  update booking.gift_cards set valid_to = current_date - 1 where code = 'HHGCAAA28003';
  v := pg_temp.as_(u_mgr, format('select booking.admin_reservation_cancel_options(%s)', r3));
  perform pg_temp.ck(not (v -> 'gift_cards' -> 0 ->> 'keep_allowed')::boolean, 'E1: vanhentunut → keep_allowed=false');
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_reservation(%s, null, false, null, true, null)', r3));
  perform pg_temp.ck(v ->> 'err' = 'gift_card_expired', 'E2: vanhentunutta ei jätetä voimaan: ' || coalesce(v ->> 'err', v::text));
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_reservation(%s, null, false, null, false, null)', r3));
  perform pg_temp.ck((v ->> 'ok')::boolean and v ->> 'notify' is null, 'E3: menetys onnistuu, p_notify null = vanha käytös');

  -- ================= 280: kumppanikoodi =================
  perform test.reset_rl();
  v := test.pub_book(v_rule, d + 21, 2, 'pv@t28x.example');
  o4 := (test.ord((v ->> 'token')::uuid)).id; select id into r4 from booking.reservations where order_id = o4;
  select total_gross into v_total from booking.orders where id = o4;
  v := pg_temp.as_(u_adm, format('select booking.admin_record_payment(%s, %L, %s, null, null)', o4, 'partner_voucher_elamyslahjat', v_total));
  perform pg_temp.ck((v ->> 'ok')::boolean, 'P0: kumppanimaksu kirjattu ' || coalesce(v ->> 'err', '') || coalesce(v ->> 'msg', ''));
  select id into v_pay from booking.payments where order_id = o4 and status = 'paid';
  insert into booking.voucher_claims(order_id, reservation_id, code, source, status, resolved_at, resolved_by, payment_id)
  values (o4, r4, 'ELAMYS280TEST', 'elamyslahjat', 'redeemed', now(), 'staff', v_pay);
  v := pg_temp.as_(u_mgr, format('select booking.admin_reservation_cancel_options(%s)', r4));
  perform pg_temp.ck((v ->> 'voucher_redeemed')::boolean and (v ->> 'order_stays')::boolean and (v ->> 'partner_share')::numeric = v_total, 'P1: valinnat: lunastettu, tilaus jää ' || v::text);
  v := pg_temp.as_(u_adm, format('select booking.admin_refund(%s, 5, %L, null, false)', v_pay, 'testi'));
  perform pg_temp.ck(v ->> 'err' = 'voucher_not_refundable', 'P2: kumppanimaksua ei hyvitetä: ' || coalesce(v ->> 'err', v::text));
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_reservation(%s, null, true, null, null, true)', r4));
  perform pg_temp.ck((v ->> 'ok')::boolean and (v ->> 'refunded_total')::numeric = 0 and (v ->> 'order_kept')::boolean, 'P3: peruttu, ei rahaa, tilaus jää ' || coalesce(v ->> 'err', '') || coalesce(v ->> 'msg', ''));
  perform pg_temp.ck((select status from booking.orders where id = o4) <> 'cancelled' and (select status from booking.voucher_claims where order_id = o4) = 'redeemed', 'P4: tilaus ja lunastus voimassa');
  select id into v_out from booking.email_outbox where order_id = o4 and kind = 'reservation_cancelled';
  perform pg_temp.ck(v_out is not null and (booking._reservation_cancelled_mail(v_out) ->> 'order_kept')::boolean, 'P5: viesti kertoo tilauksen jäävän voimaan');
  -- tila-muutos cancelled (admin_set_reservation_status) ei peru lunastettua tilausta
  perform test.reset_rl();
  v := test.pub_book(v_rule, d + 28, 2, 'pv2@t28x.example');
  o5 := (test.ord((v ->> 'token')::uuid)).id; select id into r5 from booking.reservations where order_id = o5;
  insert into booking.voucher_claims(order_id, reservation_id, code, source, status, resolved_at, resolved_by) values (o5, r5, 'ELAMYS280TST2', 'elamyslahjat', 'redeemed', now(), 'staff');
  v := pg_temp.as_(u_adm, format('select booking.admin_set_reservation_status(%s, %L)', r5, 'cancelled'));
  perform pg_temp.ck((select status from booking.orders where id = o5) <> 'cancelled', 'P6: set_status ei peru lunastettua tilausta ' || coalesce(v ->> 'err', '') || coalesce(v ->> 'msg', ''));

  -- ================= 281: ei hyvitystä → viestissä ei hyvityksiä =================
  w := booking._reservation_cancelled_mail((select id from booking.email_outbox where order_id = o4 and kind = 'reservation_cancelled'));
  perform pg_temp.ck(jsonb_array_length(w -> 'refunds') = 0 and jsonb_array_length(w -> 'gift_card') = 0, 'N1: kumppanivaraus: ei hyvityksiä viestin datassa ' || w::text);

  -- ================= 281: Montonio-hyvitys kesken lähetyshetkellä → "käsittelyssä", kuitti erikseen vahvistuksen jälkeen =================
  perform test.reset_rl();
  v := test.pub_book(v_rule, d + 35, 2, 'mo1@t28x.example');
  o3 := (test.ord((v ->> 'token')::uuid)).id; select id into r3 from booking.reservations where order_id = o3;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at) select o3, 'montonio', 'montonio', 'paid', total_gross, now() from booking.orders where id = o3 returning id into v_pay;
  perform booking._alloc_payment_lines(v_pay); perform booking._issue_receipt(v_pay); perform booking._refresh_order_payment(o3);
  update booking.reservations set status = 'cancelled' where id = r3;
  insert into booking.refunds(payment_id, order_id, amount, status, provider, lines)
  values (v_pay, o3, 10, 'requested', 'montonio', jsonb_build_array(jsonb_build_object('payment_line_id', (select min(id) from booking.payment_lines where payment_id = v_pay), 'amount', 10))) returning id into v_ref;
  v_act := gen_random_uuid();
  perform pg_temp.ck(booking._enqueue_reservation_cancelled(o3, v_act, array[r3], jsonb_build_array(jsonb_build_object('refund_id', v_ref, 'amount', 10, 'status', 'requested')), '[]'::jsonb, false), 'M1: jonotettu heti');
  select id into v_out from booking.email_outbox where dedupe_key = 'reservation_cancelled:' || o3 || ':' || v_act;
  perform pg_temp.ck((select next_attempt_at <= now() from booking.email_outbox where id = v_out), 'M2: ei odotusta');
  w := booking.email_outbox_claim(50);
  select x into v from jsonb_array_elements(w) x where (x ->> 'id')::bigint = v_out;
  perform pg_temp.ck(v -> 'cancellation' -> 'refunds' -> 0 ->> 'status' = 'requested' and v -> 'cancellation' -> 'refunds' -> 0 -> 'receipt' = 'null'::jsonb, 'M3: hyvitys käsittelyssä, ei kuittia ' || coalesce(v ->> 'cancellation', ''));
  update booking.email_outbox set status = 'sent', locked_at = null where id = v_out;   -- simuloitu lähetys (ei oikeaa viestiä)
  v := booking.montonio_refund_complete(v_ref, 'mo-ref-1', null);
  perform pg_temp.ck((v ->> 'ok')::boolean and (select status from booking.refunds where id = v_ref) = 'done', 'M4: Montonio vahvisti hyvityksen ' || v::text);
  perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = o3 and kind = 'refund_receipt' and status = 'pending') = 1, 'M5: hyvityskuitti jonossa erikseen');
  w := booking.email_outbox_claim(50);
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(w) x where (x ->> 'id')::bigint in (select id from booking.email_outbox where order_id = o3 and kind = 'refund_receipt')), 'M6: kuitti lähtee erillisenä viestinä');

  -- ================= 281: Montonio vahvisti ennen lähetystä → yksi viesti kuitteineen =================
  perform test.reset_rl();
  v := test.pub_book(v_rule, d + 42, 2, 'mo2@t28x.example');
  o5 := (test.ord((v ->> 'token')::uuid)).id; select id into r5 from booking.reservations where order_id = o5;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at) select o5, 'montonio', 'montonio', 'paid', total_gross, now() from booking.orders where id = o5 returning id into v_pay;
  perform booking._alloc_payment_lines(v_pay); perform booking._issue_receipt(v_pay); perform booking._refresh_order_payment(o5);
  update booking.reservations set status = 'cancelled' where id = r5;
  insert into booking.refunds(payment_id, order_id, amount, status, provider, lines)
  values (v_pay, o5, 10, 'requested', 'montonio', jsonb_build_array(jsonb_build_object('payment_line_id', (select min(id) from booking.payment_lines where payment_id = v_pay), 'amount', 10))) returning id into v_ref;
  v_act := gen_random_uuid();
  perform booking._enqueue_reservation_cancelled(o5, v_act, array[r5], jsonb_build_array(jsonb_build_object('refund_id', v_ref, 'amount', 10)), '[]'::jsonb, false);
  select id into v_out from booking.email_outbox where dedupe_key = 'reservation_cancelled:' || o5 || ':' || v_act;
  perform booking.montonio_refund_complete(v_ref, 'mo-ref-2', null);
  perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = o5 and kind = 'refund_receipt' and status = 'pending') = 1, 'D1: kuitti jonossa ennen peruutusviestin lähtöä');
  w := booking.email_outbox_claim(50);
  select x into v from jsonb_array_elements(w) x where (x ->> 'id')::bigint = v_out;
  perform pg_temp.ck(v -> 'cancellation' -> 'refunds' -> 0 ->> 'status' = 'done' and v -> 'cancellation' -> 'refunds' -> 0 -> 'receipt' ->> 'public_token' is not null, 'D2: hyvitetty + kuitti liitteenä');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(w) x where (x ->> 'id')::bigint in (select id from booking.email_outbox where order_id = o5 and kind = 'refund_receipt'))
                     and (select status from booking.email_outbox where order_id = o5 and kind = 'refund_receipt') = 'skipped', 'D3: erillinen kuittiviesti ohitettu (yksi viesti)');
  perform pg_temp.ck(not booking._enqueue_reservation_cancelled(o5, v_act, array[r5], '[]'::jsonb, '[]'::jsonb, false), 'D4: dedupe');
  perform pg_temp.ck(to_regprocedure('booking._add_bank_days(timestamp with time zone,integer)') is null and to_regclass('booking.refund_mail_links') is null, 'D5: ei pankkipäiväodotusta eikä linkkitaulua');

  -- ================= oikeudet =================
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_cancel_reservation(bigint,text,boolean,text,boolean,boolean,numeric)', 'execute')
                     and has_function_privilege('authenticated', 'booking.admin_cancel_reservation(bigint,text,boolean,text,boolean,boolean,numeric)', 'execute'), 'R1: peruutus-RPC vain kirjautuneille');
  perform pg_temp.ck(to_regprocedure('booking.admin_cancel_reservation(bigint,text,boolean,text,boolean)') is null
                     and to_regprocedure('booking.admin_cancel_reservation(bigint,text,boolean,text)') is null, 'R2: vanhat ylikuormitukset poissa');
  perform pg_temp.ck(not has_function_privilege('authenticated', 'booking._reservation_cancelled_mail(bigint)', 'execute')
                     and not has_function_privilege('authenticated', 'booking._enqueue_reservation_cancelled(bigint,uuid,bigint[],jsonb,jsonb,boolean)', 'execute')
                     and not has_function_privilege('authenticated', 'booking._gc_return_to_card(bigint,numeric,jsonb,text,bigint)', 'execute')
                     and not has_function_privilege('authenticated', 'booking._gc_forfeit_on_cancel(bigint,numeric,bigint,text)', 'execute'), 'R3: sisäiset suljettu');
  v := pg_temp.as_(u_stf, 'select to_jsonb(count(*)) from booking.gift_card_forfeits');
  perform pg_temp.ck((v #>> '{}')::int >= 1, 'R5: payments.manage näkee menetykset ' || v::text);
  perform pg_temp.ck(not has_table_privilege('anon', 'booking.gift_card_forfeits', 'select'), 'R5b: anon ei menetyksiä');
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where status = 'sent' and kind in ('reservation_cancelled', 'refund_receipt') and created_at > now() - interval '1 hour' and order_id not in (o3)), 'R6: mitään ei lähetetty (paitsi simuloitu M-rivi)');
end $t$;
do $r$
declare p int; f int; s text;
begin
  select count(*) filter (where ok), count(*) filter (where not ok), string_agg(case when not ok then label end, E'\n') into p, f, s from t28x_r;
  raise exception 'TESTRESULT pass=% fail=% %', p, f, coalesce(E'\n' || s, '');
end $r$;
