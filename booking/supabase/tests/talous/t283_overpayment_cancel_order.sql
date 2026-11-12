begin;
-- t283: ylisuorituksen hyvitys (E) ja atominen "peru koko tilaus" (F), booking_283 (tilausnäkymä v3 PR 3).
-- Vaatii migraatiot 282 + 283, booking_288:n triggerin (PROD-tila) ja fixtures/10_test_helpers.sql:n. Yksi transaktio; lopuksi rollback.
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t283_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t283_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.as_(p_user uuid, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb; d text;
begin
  perform test.login(p_user);
  begin execute p_sql into v;
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(nullif(d, ''), sqlstate), 'msg', sqlerrm);
  end;
  perform test.logout();
  return v;
end $$;
-- tilaus: p_persons henkilöä, p_second = toinen varaus samalle tilaukselle (siirretään toisesta tilauksesta), maksettu kokonaan
create function pg_temp.mk(p_rule bigint, p_date date, p_persons int, p_email text, p_method text, p_gc numeric default 0, p_code text default null, p_second_date date default null) returns bigint language plpgsql as $$
declare a jsonb; o bigint; o2 bigint; u uuid; v_unpaid numeric; v_half bigint;
begin
  perform test.reset_rl();
  a := test.pub_book(p_rule, p_date, p_persons, p_email);
  if not coalesce((a ->> 'ok')::boolean, false) then raise exception 'pub_book: %', a; end if;
  o := (test.ord((a ->> 'token')::uuid)).id;
  if p_second_date is not null then
    perform test.reset_rl();
    a := test.pub_book(p_rule, p_second_date, p_persons, p_email);
    if not coalesce((a ->> 'ok')::boolean, false) then raise exception 'pub_book 2: %', a; end if;
    o2 := (test.ord((a ->> 'token')::uuid)).id;
    update booking.order_items set order_id = o where order_id = o2;
    update booking.reservations set order_id = o where order_id = o2;
    update booking.orders set total_gross = (select sum(line_total_gross) from booking.order_items where order_id = o) where id = o;
    delete from booking.payments where order_id = o2;
    delete from booking.orders where id = o2;
  end if;
  if p_gc > 0 then
    insert into booking.gift_cards(code, initial_amount, balance, valid_to, status) values (p_code, p_gc, p_gc, current_date + 200, 'active');
    perform booking._apply_gift_core(o, p_code, 'card_terminal', true, 'Testi');
  end if;
  select (booking._order_balance(o) ->> 'unpaid')::numeric into v_unpaid;
  if v_unpaid > 0 then
    select id into u from auth.users where email = 'adm@t283.example';
    perform test.login(u);
    if p_method = 'split' then   -- kaksi maksua: käteinen/pääte 30 € + Montonio loput
      perform booking.admin_record_payment(o, 'card_terminal', 30, null, null);
      perform test.logout();
      insert into booking.payments(order_id, method, provider, status, amount, paid_at, raw) values (o, 'montonio', 'montonio', 'paid', v_unpaid - 30, now(), '{"order_uuid":"x","env":"test"}'::jsonb) returning id into v_half;
      perform booking._alloc_payment_lines(v_half);
      perform booking._sync_placeholder(o); perform booking._refresh_order_payment(o);
    else
      perform booking.admin_record_payment(o, 'card_terminal', v_unpaid, null, null);
      perform test.logout();
    end if;
  end if;
  if p_method = 'montonio' then
    update booking.payments set provider = 'montonio', method = 'montonio' where order_id = o and method = 'card_terminal' and gift_card_id is null;
  end if;
  return o;
end $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%'); d date := test.next_dow(1, 20);
  u_adm uuid := test.mk_staff('adm@t283.example', 'admin'); u_stf uuid := test.mk_staff('stf@t283.example', 'staff');
  v jsonb; w jsonb; o1 bigint; o2 bigint; o3 bigint; o4 bigint; o5 bigint; o6 bigint; o7 bigint; o8 bigint; r1 bigint; r2 bigint; r3 bigint; r4 bigint; r5 bigint; r6 bigint; r7 bigint;
  p1 bigint; p2 bigint; v_tot numeric; v_n int; v_ref bigint; v_pay_cash bigint; v_pay_mon bigint; v_lk bigint;
begin
  update booking.settings set value = '200'::jsonb where key = 'public_treatment_global_per_hour';
  update booking.settings set value = 'true'::jsonb where key = 'gift_cards.redeem_enabled';
  update booking.integration_config set mode = 'test', settings = settings || '{"approved_by":"testi"}'::jsonb where key = 'montonio';

  -- ================= E: ylisuorituksen hyvitys =================
  o1 := pg_temp.mk(v_rule, d, 3, 'a@t283.example', 'card_terminal');
  select id into r1 from booking.reservations where order_id = o1;
  select id into p1 from booking.payments where order_id = o1 and status = 'paid';
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2)', r1));     -- pienennys ilman hyvitystä → ylisuoritus 29 €
  perform pg_temp.ck((v ->> 'ok')::boolean and (booking._order_balance(o1) ->> 'net_paid')::numeric = 87 and (select total_gross from booking.orders where id = o1) = 58, 'E0: pienennys ilman hyvitystä jättää ylisuorituksen');
  v := pg_temp.as_(u_adm, format('select booking.admin_refund_overpayment(%s, 10, null, %L, false)', o1, 'testi'));
  perform pg_temp.ck(v ->> 'err' = 'partial_refunds_disabled', 'E1: lippu pois → estetty ' || coalesce(v ->> 'err', v::text));
  update booking.settings set value = 'true'::jsonb where key = 'partial_refunds_enabled';
  v := pg_temp.as_(u_stf, format('select booking.admin_refund_overpayment(%s, 10, null, %L, false)', o1, 'testi'));
  perform pg_temp.ck(v ->> 'err' = 'forbidden', 'E2: staff ei voi hyvittää ' || coalesce(v ->> 'err', v::text));
  v := pg_temp.as_(u_stf, format('select booking.admin_order_refund_info(%s)', o1));
  perform pg_temp.ck((v ->> 'overpaid')::numeric = 29 and (v ->> 'refundable_max')::numeric = 29 and not (v ->> 'can_refund')::boolean, 'E3: info: ylisuoritus 29, staff ei voi hyvittää ' || v::text);
  v := pg_temp.as_(u_adm, format('select booking.admin_refund_overpayment(%s, 29.01, null, %L, false)', o1, 'testi'));
  perform pg_temp.ck(v ->> 'err' = 'amount_exceeds_refundable', 'E4: yli ylisuorituksen ' || coalesce(v ->> 'err', v::text));
  v := pg_temp.as_(u_adm, format('select booking.admin_refund_overpayment(%s, 0.04, null, %L, false)', o1, 'testi'));
  perform pg_temp.ck(v ->> 'err' = 'invalid_amount', 'E5: minimi 0,05 €');
  v := pg_temp.as_(u_adm, format('select booking.admin_refund_overpayment(%s, 10, null, %L, false)', o1, 'osa 1'));
  perform pg_temp.ck((v ->> 'ok')::boolean and (v ->> 'refunded_total')::numeric = 10 and (v -> 'refund_info' ->> 'refundable_max')::numeric = 19, 'E6: osahyvitys 10 €, jäljellä 19 € ' || coalesce(v ->> 'err', '') || coalesce(v ->> 'msg', ''));
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = o1 and kind = 'refund_receipt' and status = 'pending'), 'E7: viesti = ei → ei kuittiviestiä');
  perform pg_temp.ck((select count(*) from booking.receipts r join booking.refunds f on f.id = r.refund_id where f.order_id = o1) = 1, 'E7b: kuitti syntyy silti');
  v := pg_temp.as_(u_adm, format('select booking.admin_refund_overpayment(%s, 19, %s, %L, true)', o1, p1, 'osa 2'));
  perform pg_temp.ck((v ->> 'ok')::boolean and exists (select 1 from booking.email_outbox where order_id = o1 and kind = 'refund_receipt' and status = 'pending'), 'E8: viesti = kyllä → kuittiviesti jonossa');
  v := pg_temp.as_(u_adm, format('select booking.admin_refund_overpayment(%s, 0.05, null, %L, false)', o1, 'toisto'));
  perform pg_temp.ck(v ->> 'err' = 'nothing_to_refund', 'E9: toisto → ei hyvitettävää ' || coalesce(v ->> 'err', v::text));
  perform pg_temp.ck((select (booking._order_balance(o1) ->> 'net_paid')::numeric) = 58 and test.audit_n('ADMIN_REFUND_OVERPAYMENT') = 2, 'E10: netto = uusi summa, audit');

  -- Montonio + käteinen (split): verkkomaksut ensin; Montonio: release / fail
  o2 := pg_temp.mk(v_rule, d + 7, 3, 'b@t283.example', 'split');
  select id into r2 from booking.reservations where order_id = o2;
  select id into v_pay_cash from booking.payments where order_id = o2 and provider = 'manual' and status = 'paid';
  select id into v_pay_mon from booking.payments where order_id = o2 and provider = 'montonio' and status = 'paid';
  perform pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 1)', r2));   -- 87 → 29, ylisuoritus 58
  v := pg_temp.as_(u_adm, format('select booking.admin_refund_overpayment(%s, 58, null, %L, false)', o2, 'monimaksu'));
  perform pg_temp.ck((v ->> 'ok')::boolean and jsonb_array_length(v -> 'refunds') = 2, 'S1: monimaksu → kaksi hyvitystä (maksu kohti) ' || coalesce(v ->> 'err', '') || coalesce(v ->> 'msg', ''));
  perform pg_temp.ck((select amount from booking.refunds where order_id = o2 and provider = 'montonio') = 57 and (select amount from booking.refunds where order_id = o2 and provider = 'manual') = 1, 'S2: verkkomaksu ensin (57 €), loput käteinen/pääte (1 €)');
  select id into v_ref from booking.refunds where order_id = o2 and provider = 'montonio';
  perform pg_temp.ck((select status from booking.refunds where id = v_ref) = 'requested' and (select notify_customer is false from booking.refunds where id = v_ref), 'S3: Montonio-hyvitys requested, ilmoitus pois');
  v := booking.montonio_refund_release(v_ref, '{"reason":"not_settled"}'::jsonb);
  perform pg_temp.ck((select status from booking.refunds where id = v_ref) in ('requested', 'processing'), 'S4: ei tilitetty → release: odottaa ja yritetään uudelleen ' || (select status || '/' || coalesce(provider_status, '') from booking.refunds where id = v_ref));
  perform pg_temp.ck((booking._order_refund_info(o2) ->> 'refundable_max')::numeric = 0, 'S5: käsittelyssä oleva hyvitys varaa summan (ei tuplahyvitystä)');
  v := booking.montonio_refund_fail(v_ref, '{"status":"REJECTED"}'::jsonb);
  perform pg_temp.ck((select status from booking.refunds where id = v_ref) = 'failed', 'S6: REJECTED → failed');
  perform pg_temp.ck((booking._order_refund_info(o2) ->> 'refundable_max')::numeric = 57, 'S7: epäonnistunut hyvitys vapauttaa summan uudelleen yritettäväksi');
  -- lahjakorttimaksua ei voi valita
  o3 := pg_temp.mk(v_rule, d + 14, 3, 'c@t283.example', 'montonio', 20, 'HHGCAAA28301');
  select id into r3 from booking.reservations where order_id = o3;
  perform pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2)', r3));
  v := pg_temp.as_(u_adm, format('select booking.admin_refund_overpayment(%s, 5, %s, %L, false)', o3, (select id from booking.payments where order_id = o3 and gift_card_id is not null), 'lahjakortille'));
  perform pg_temp.ck(v ->> 'err' = 'amount_exceeds_refundable', 'G1: lahjakorttimaksua ei hyvitetä rahana ' || coalesce(v ->> 'err', v::text));
  v := pg_temp.as_(u_adm, format('select booking.admin_refund_overpayment(%s, 29, null, %L, false)', o3, 'lahjakortti + raha'));
  perform pg_temp.ck((v ->> 'ok')::boolean and (select balance from booking.gift_cards where code = 'HHGCAAA28301') = 0, 'G2: raha hyvitetään, lahjakortti ennallaan');
  -- laskulukko
  o4 := pg_temp.mk(v_rule, d + 21, 3, 'd@t283.example', 'card_terminal');
  select id into r4 from booking.reservations where order_id = o4;
  perform pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2)', r4));
  insert into booking.invoice_customers(company_name) values ('T283 Oy');
  insert into booking.invoices(order_id, customer_id, kind, status, due_date, seller_snapshot, customer_snapshot) select o4, (select max(id) from booking.invoice_customers), 'debit', 'sent', current_date + 14, '{}'::jsonb, '{}'::jsonb;
  v := pg_temp.as_(u_adm, format('select booking.admin_refund_overpayment(%s, 5, null, %L, false)', o4, 'lukko'));
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced', 'L1: laskulukko estää ylisuorituksen hyvityksen ' || coalesce(v ->> 'err', v::text));
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_order(%s, null, %L::jsonb, null, null)', o4, jsonb_build_array(jsonb_build_object('payment_id', (select id from booking.payments where order_id = o4 and status = 'paid'), 'amount', 10))));
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced' and (select status from booking.orders where id = o4) = 'confirmed', 'L2: laskulukko estää peruutuksen hyvityksen, tilaus ennallaan');
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_order(%s, %L, null, false, null)', o4, 'lasku peruttu'));
  perform pg_temp.ck((v ->> 'ok')::boolean and (select status from booking.orders where id = o4) = 'cancelled', 'L3: peruutus ilman hyvitystä onnistuu laskulukossa');

  -- kumppanikoodi: käyttämätön arvo ei ole hyvitettävää
  o5 := pg_temp.mk(v_rule, d + 28, 3, 'e@t283.example', 'card_terminal');
  update booking.payments set method = 'partner_voucher_elamyslahjat' where order_id = o5 and status = 'paid';
  select id into r5 from booking.reservations where order_id = o5;
  perform pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2)', r5));
  v := pg_temp.as_(u_adm, format('select booking.admin_refund_overpayment(%s, 5, null, %L, false)', o5, 'kumppani'));
  perform pg_temp.ck(v ->> 'err' = 'nothing_to_refund', 'K0: kumppanilunastuksen ylimenevä arvo ei hyvitettävää ' || coalesce(v ->> 'err', v::text));

  -- ================= F: atominen peru koko tilaus =================
  -- F1: kaksi varausta, kaksi maksua (pääte 30 € + Montonio loput) → tasan yksi hyvitys / maksu
  o6 := pg_temp.mk(v_rule, d + 35, 2, 'f@t283.example', 'split', 0, null, d + 77);
  select count(*) into v_n from booking.reservations where order_id = o6;
  perform pg_temp.ck(v_n = 2, 'F0: tilauksella kaksi varausta');
  select id into v_pay_cash from booking.payments where order_id = o6 and provider = 'manual' and status = 'paid';
  select id into v_pay_mon from booking.payments where order_id = o6 and provider = 'montonio' and status = 'paid';
  select total_gross into v_tot from booking.orders where id = o6;
  v := pg_temp.as_(u_stf, format('select booking.admin_cancel_order(%s, null, %L::jsonb, null, null)', o6, jsonb_build_array(jsonb_build_object('payment_id', v_pay_cash, 'amount', 5))));
  perform pg_temp.ck(v ->> 'err' = 'forbidden', 'F1: staff ei voi hyvittää peruutuksessa ' || coalesce(v ->> 'err', v::text));
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_order(%s, null, %L::jsonb, null, null)', o6, jsonb_build_array(jsonb_build_object('payment_id', v_pay_mon, 'amount', (select amount from booking.payments where id = v_pay_mon) + 1))));
  perform pg_temp.ck(v ->> 'err' = 'amount_exceeds_refundable' and (select count(*) from booking.reservations where order_id = o6 and status = 'confirmed') = 2, 'F2: liian suuri summa → kaikki kumoutuu (varaukset voimassa) ' || coalesce(v ->> 'err', v::text));
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_order(%s, null, %L::jsonb, null, null)', o6, jsonb_build_array(jsonb_build_object('payment_id', v_pay_mon, 'amount', 10), jsonb_build_object('payment_id', v_pay_mon, 'amount', 5))));
  perform pg_temp.ck(v ->> 'err' = 'invalid_items', 'F3: sama maksu kahdesti estetty ' || coalesce(v ->> 'err', v::text));
  update booking.settings set value = 'false'::jsonb where key = 'partial_refunds_enabled';
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_order(%s, null, %L::jsonb, null, null)', o6, jsonb_build_array(jsonb_build_object('payment_id', v_pay_mon, 'amount', 10))));
  perform pg_temp.ck(v ->> 'err' = 'partial_refunds_disabled', 'F4: lippu pois → hyvitys estetty');
  update booking.settings set value = 'true'::jsonb where key = 'partial_refunds_enabled';
  -- lisäksi odottava maksulinkki (booking_288:n triggerin pitää sulkea se)
  insert into booking.payments(order_id, method, provider, status, amount, link_url, link_expires_at) values (o6, 'montonio', 'montonio', 'pending', 5, 'https://x.example/l', now() + interval '2 days') returning id into v_lk;
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_order(%s, %L, %L::jsonb, true, null)', o6, 'asiakas perui',
        jsonb_build_array(jsonb_build_object('payment_id', v_pay_mon, 'amount', (select amount from booking.payments where id = v_pay_mon)), jsonb_build_object('payment_id', v_pay_cash, 'amount', 30))));
  perform pg_temp.ck((v ->> 'ok')::boolean and jsonb_array_length(v -> 'refunds') = 2 and jsonb_array_length(v -> 'cancelled_reservations') = 2, 'F5: peruttu, 2 varausta, 2 hyvitystä (yksi / maksu) ' || coalesce(v ->> 'err', '') || coalesce(v ->> 'msg', ''));
  perform pg_temp.ck((select count(*) from booking.refunds where order_id = o6) = 2, 'F5b: tasan 2 hyvitysriviä (ei per varaus)');
  perform pg_temp.ck((select status from booking.orders where id = o6) = 'cancelled' and not exists (select 1 from booking.reservations where order_id = o6 and status <> 'cancelled'), 'F6: tilaus ja varaukset peruttu');
  perform pg_temp.ck((select status from booking.payments where id = v_lk) = 'cancelled' and exists (select 1 from booking.audit_log where action = 'CANCELLED_ORDER_LINKS_CLOSED' and row_pk = o6::text), 'F7: booking_288-triggeri sulki maksulinkin (ei päällekkäistä logiikkaa)');
  perform pg_temp.ck((v ->> 'notified')::boolean and (select count(*) from booking.email_outbox where order_id = o6 and kind = 'reservation_cancelled') = 1, 'F8: tasan yksi reservation_cancelled');
  perform pg_temp.ck(test.audit_n('ADMIN_CANCEL_ORDER') >= 1, 'F9: audit');
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_order(%s, null, null, null, null)', o6));
  perform pg_temp.ck(v ->> 'err' = 'invalid_status', 'F10: toinen peruutus → ei voimassa olevia varauksia (idempotenssi)');
  -- F11: lahjakortti pakollinen valinta, atomisuus
  o7 := pg_temp.mk(v_rule, d + 42, 3, 'g@t283.example', 'montonio', 20, 'HHGCAAA28302');
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_order(%s, null, null, null, null)', o7));
  perform pg_temp.ck(v ->> 'err' = 'gift_card_keep_required' and (select status from booking.orders where id = o7) = 'confirmed', 'F11: lahjakorttivalinta puuttuu → ei muutoksia');
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_order(%s, null, null, null, true)', o7));
  perform pg_temp.ck((v ->> 'ok')::boolean and (select balance from booking.gift_cards where code = 'HHGCAAA28302') = 20 and v -> 'gift_card' -> 0 ->> 'action' = 'returned' and (v ->> 'refunded_total')::numeric = 0, 'F12: koodi voimaan → arvo palautuu kortille, rahaa ei hyvitetty ' || coalesce(v ->> 'err', '') || coalesce(v ->> 'msg', ''));
  o8 := pg_temp.mk(v_rule, d + 49, 3, 'h@t283.example', 'montonio', 20, 'HHGCAAA28303');
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_order(%s, null, null, null, false)', o8));
  perform pg_temp.ck((v ->> 'ok')::boolean and (select balance from booking.gift_cards where code = 'HHGCAAA28303') = 0 and v -> 'gift_card' -> 0 ->> 'action' = 'forfeited'
                     and (select count(*) from booking.gift_card_forfeits where order_id = o8) = 1, 'F13: koodi ei voimaan → arvo menetetään');
  -- F14: kumppanilunastus → tilaus jää voimaan
  perform test.reset_rl();
  v := test.pub_book(v_rule, d + 56, 2, 'pv@t283.example');
  o5 := (test.ord((v ->> 'token')::uuid)).id; select id into r5 from booking.reservations where order_id = o5;
  select total_gross into v_tot from booking.orders where id = o5;
  perform pg_temp.as_(u_adm, format('select booking.admin_record_payment(%s, %L, %s, null, null)', o5, 'partner_voucher_elamyslahjat', v_tot));
  insert into booking.voucher_claims(order_id, reservation_id, code, source, status, resolved_at, resolved_by, payment_id)
  values (o5, r5, 'ELAMYS283TEST', 'elamyslahjat', 'redeemed', now(), 'staff', (select id from booking.payments where order_id = o5 and status = 'paid'));
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_order(%s, null, null, true, null)', o5));
  perform pg_temp.ck((v ->> 'ok')::boolean and (v ->> 'order_kept')::boolean and (select status from booking.orders where id = o5) = 'confirmed'
                     and (select status from booking.reservations where id = r5) = 'cancelled' and (v ->> 'refunded_total')::numeric = 0, 'F14: kumppanilunastus: varaus peruttu, tilaus jää voimaan ' || coalesce(v ->> 'err', '') || coalesce(v ->> 'msg', ''));
  perform pg_temp.ck((select status from booking.payments where order_id = o5 and method like 'partner_voucher%') = 'paid' and not exists (select 1 from booking.refunds where order_id = o5), 'F15: kumppanimaksu säilyy, hyvitystä ei luotu');

  -- ================= admin_cancel_reservation: osittainen summa =================
  o7 := pg_temp.mk(v_rule, d + 63, 3, 'i@t283.example', 'montonio');
  select id into r7 from booking.reservations where order_id = o7;
  update booking.settings set value = 'false'::jsonb where key = 'partial_refunds_enabled';
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_reservation(%s, null, false, null, null, null, 20)', r7));
  perform pg_temp.ck(v ->> 'err' = 'partial_refunds_disabled', 'R1: osasumma vaatii lipun');
  update booking.settings set value = 'true'::jsonb where key = 'partial_refunds_enabled';
  v := pg_temp.as_(u_stf, format('select booking.admin_cancel_reservation(%s, null, false, null, null, null, 20)', r7));
  perform pg_temp.ck(v ->> 'err' = 'forbidden', 'R2: staff ei voi hyvittää osaa');
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_reservation(%s, null, false, null, null, null, 87.01)', r7));
  perform pg_temp.ck(v ->> 'err' = 'amount_exceeds_refundable' and (select status from booking.reservations where id = r7) = 'confirmed', 'R3: yli osuuden → kumoutuu');
  v := pg_temp.as_(u_adm, format('select booking.admin_cancel_reservation(%s, null, false, null, null, null, 20)', r7));
  perform pg_temp.ck((v ->> 'ok')::boolean and (v ->> 'refunded_total')::numeric = 20 and (select amount from booking.refunds where order_id = o7) = 20
                     and (select sum((x ->> 'amount')::numeric) from booking.refunds f, jsonb_array_elements(f.lines) x where f.order_id = o7) = 20, 'R4: peruttu + osahyvitys 20 € rivikohdistuksella ' || coalesce(v ->> 'err', '') || coalesce(v ->> 'msg', ''));
end $t$;
select 'RESULT ' || case when ok then 'ok' else 'NOT OK' end || ' - ' || label from t283_r;
select 'SUMMARY ' || count(*) filter (where not ok) || ' failed / ' || count(*) from t283_r;
rollback;
