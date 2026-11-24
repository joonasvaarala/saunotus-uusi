begin;
-- t345: lahjakortin oston hyvitys lukitsee kortit (K2) + kumppanikoodin lunastus vaatii viitteen (K8). booking_345, 25.11.2026.
-- Vaatii migraation 345 + fixtures/10_test_helpers.sql. Yksi transaktio; lopuksi rollback. Montonio mockattu (claim/stamp/complete/fail-funktiot).
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t345_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t345_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare d text;
begin
  execute p_sql; return null;
exception when others then get stacked diagnostics d = pg_exception_detail; return coalesce(nullif(d, ''), sqlstate);
end $$;
-- lahjakorttimyynti (2 × 50 €) maksettuna Montoniolla: palauttaa maksun
create function pg_temp.sale(p_adm uuid, p_n int default 2) returns bigint language plpgsql as $$
declare r jsonb; v_o bigint; v_p bigint;
begin
  perform test.login(p_adm);
  r := booking.admin_create_gift_card('open', 50, p_n, jsonb_build_object('name', 'Olli', 'email', 'olli@t345.example'), null, null, null, 'card_terminal', null, null, 'fi', 'testi', 'admin', 'buyer');
  perform test.logout();
  v_o := (select purchase_order_id from booking.gift_cards where id = (r -> 'cards' -> 0 ->> 'id')::bigint);
  update booking.payments set provider = 'montonio', method = 'montonio', raw = '{"order_uuid":"x","env":"test"}'::jsonb
   where order_id = v_o and status = 'paid' returning id into v_p;
  return v_p;
end $$;
create function pg_temp.cards(p_pay bigint) returns text language sql as $$
  select string_agg(g.status || ':' || g.balance, ',' order by g.id) from booking.gift_cards g join booking.payments p on p.order_id = g.purchase_order_id where p.id = p_pay
$$;
do $t$
declare
  u_adm uuid := test.mk_staff('adm@t345.example', 'admin');
  v jsonb; p1 bigint; p2 bigint; p3 bigint; p4 bigint; r1 bigint; r2 bigint; r3 bigint; c1 bigint; c2 bigint; e text;
  v_rule bigint := test.rule('Miesten sauna%'); d date := test.next_dow(1, 20); tok uuid; o5 bigint; cl bigint;
begin
  update booking.settings set value = '1000'::jsonb where key in ('rl_change_per_10min', 'rl_ip_per_10min', 'rl_email_per_10min');
  update booking.integration_config set mode = 'test', settings = settings || '{"approved_by":"testi"}'::jsonb where key = 'montonio';

  -- A: hyvitys alkaa → kortit suspended; ei voi käyttää eikä saldoa muuttaa
  p1 := pg_temp.sale(u_adm);
  select min(g.id), max(g.id) into c1, c2 from booking.gift_cards g join booking.payments p on p.order_id = g.purchase_order_id where p.id = p1;
  perform test.login(u_adm);
  v := booking.admin_refund(p1, 100, 'Asiakas perui oston', null, false);
  perform test.logout();
  r1 := (v ->> 'refund_id')::bigint;
  perform pg_temp.ck(r1 is not null and (select status from booking.refunds where id = r1) = 'requested', 'A1: hyvitys luotu (requested) ' || v::text);
  perform pg_temp.ck(pg_temp.cards(p1) = 'suspended:50.00,suspended:50.00', 'A2: kortit suspended ' || pg_temp.cards(p1));
  perform pg_temp.ck((select count(*) from booking.gift_cards where refund_hold_id = r1 and refund_hold_prev_status = 'active') = 2, 'A3: refund_hold_id + aiempi tila');
  perform pg_temp.ck(pg_temp.err(format('select booking._gc_apply(%s, -10, %L)', c1, 'redemption')) = 'gift_card_suspended', 'A4: saldoa ei voi vähentää (gift_card_suspended)');
  perform pg_temp.ck(pg_temp.err(format('update booking.gift_cards set status = %L where id = %s', 'active', c1)) = 'gift_card_suspended', 'A5: tilaa ei voi palauttaa käsin');
  perform pg_temp.ck((booking.public_check_gift_card((select code from booking.gift_cards where id = c1)) ->> 'code') = 'invalid_code', 'A6: julkinen tarkistus: ei käytettävissä');
  perform test.login(u_adm);
  v := booking.admin_list_gift_cards(null, 'suspended');
  perform test.logout();
  perform pg_temp.ck(v::text like '%"status": "suspended"%' and v::text not like '%"status": "active"%', 'A7: hallinnan suodatin suspended');
  update booking.settings set value = 'true'::jsonb where key = 'gift_cards.redeem_enabled';
  perform test.reset_rl();
  v := test.pub_book(v_rule, d, 2, 'a8@t345.example');
  o5 := (test.ord((v ->> 'token')::uuid)).id;
  e := pg_temp.err(format('select booking._gc_redeem(%s, %s, 1, null, false)', o5, c1));
  perform pg_temp.ck(e = 'gift_card_inactive', 'A8: lunastus varaukselle estetty (' || coalesce(e, 'ok') || ')');

  -- B: Montonio valmis → mitätöinti ledgerillä (cancel_refund), saldo 0
  perform booking.montonio_refund_claim(r1, 5);
  perform booking.montonio_refund_stamp(r1, 'mt-r1', 'PENDING', '{}'::jsonb);
  v := booking.montonio_refund_complete(r1, 'mt-r1', '{"status":"SUCCESSFUL"}'::jsonb);
  perform pg_temp.ck((select status from booking.refunds where id = r1) = 'done', 'B1: hyvitys done ' || coalesce(v::text, ''));
  perform pg_temp.ck(pg_temp.cards(p1) = 'cancelled:0.00,cancelled:0.00', 'B2: kortit cancelled, saldo 0 ' || pg_temp.cards(p1));
  perform pg_temp.ck((select count(*) from booking.gift_card_ledger where gift_card_id in (c1, c2) and reason = 'cancel_refund' and delta = -50) = 2
                     and (select count(*) from booking.gift_card_ledger where gift_card_id in (c1, c2) and reason = 'cancel_refund') = 2, 'B3: yksi cancel_refund-rivi per kortti (−50), ei tuplia');
  perform pg_temp.ck((select count(*) from booking.gift_cards where refund_hold_id = r1) = 0, 'B4: pito purettu');

  -- C: Montonio epäonnistuu → pito vapautuu, kortti taas active
  p2 := pg_temp.sale(u_adm, 1);
  perform test.login(u_adm);
  r2 := (booking.admin_refund(p2, 50, 'Asiakas perui oston', null, false) ->> 'refund_id')::bigint;
  perform test.logout();
  perform pg_temp.ck(pg_temp.cards(p2) = 'suspended:50.00', 'C1: suspended');
  perform booking.montonio_refund_claim(r2, 5);
  perform booking.montonio_refund_fail(r2, '{"error":"test"}'::jsonb);
  perform pg_temp.ck((select status from booking.refunds where id = r2) = 'failed' and pg_temp.cards(p2) = 'active:50.00', 'C2: failed → active ' || pg_temp.cards(p2) || ' ' || (select status from booking.refunds where id = r2));
  perform pg_temp.ck((select count(*) from booking.gift_card_ledger l join booking.gift_cards g on g.id = l.gift_card_id join booking.payments p on p.order_id = g.purchase_order_id where p.id = p2 and l.reason = 'cancel_refund') = 0, 'C3: ei mitätöintiä');
  -- uusi hyvitys peruutetaan (cancelled) → vapautuu
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines) select p2, order_id, 50, 'testi', 'requested', 'montonio', null from booking.payments where id = p2 returning id into r3;
  perform pg_temp.ck(pg_temp.cards(p2) = 'suspended:50.00', 'C4: rivitön hyvitys → kaikki lahjakorttirivit lukkoon');
  update booking.refunds set status = 'cancelled' where id = r3;
  perform pg_temp.ck(pg_temp.cards(p2) = 'active:50.00', 'C5: cancelled → active');

  -- D: käytettyä osaa ei hyvitetä
  p3 := pg_temp.sale(u_adm, 1);
  update booking.gift_cards g set balance = 30 from booking.payments p where p.id = p3 and g.purchase_order_id = p.order_id;
  e := pg_temp.err(format('insert into booking.refunds(payment_id, order_id, amount, reason, status, provider) select %s, order_id, 50, %L, %L, %L from booking.payments where id = %s', p3, 'x', 'requested', 'montonio', p3));
  perform pg_temp.ck(e = 'gift_card_in_use', 'D1: käytetty kortti → gift_card_in_use (' || coalesce(e, 'ok') || ')');
  e := pg_temp.err(format('insert into booking.refunds(payment_id, order_id, amount, reason, status, provider) select %s, order_id, 50, %L, %L, %L from booking.payments where id = %s', p3, 'x', 'done', 'manual', p3));
  perform pg_temp.ck(e = 'gift_card_in_use', 'D2: myös käsin kirjattu (done) estetty');

  -- E: käsin kirjattu hyvitys (done heti) mitätöi; pending_verification lukitaan ja palautuu sellaisenaan
  p4 := pg_temp.sale(u_adm, 1);
  update booking.integration_config set mode = 'off' where key = 'montonio';
  perform test.login(u_adm);
  v := booking.admin_refund(p4, 50, 'Käsin hyvitetty', null, true);
  perform test.logout();
  perform pg_temp.ck(pg_temp.cards(p4) = 'cancelled:0.00' and (select count(*) from booking.gift_card_ledger l join booking.gift_cards g on g.id = l.gift_card_id join booking.payments p on p.order_id = g.purchase_order_id where p.id = p4 and l.reason = 'cancel_refund') = 1, 'E1: käsin done → cancelled, yksi ledger ' || pg_temp.cards(p4) || ' ' || v::text);
  update booking.integration_config set mode = 'test' where key = 'montonio';
  p4 := pg_temp.sale(u_adm, 1);
  update booking.gift_cards g set status = 'pending_verification' from booking.payments p where p.id = p4 and g.purchase_order_id = p.order_id;
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines) select p4, order_id, 50, 'testi', 'processing', 'montonio', null from booking.payments where id = p4 returning id into r3;
  perform pg_temp.ck(pg_temp.cards(p4) = 'suspended:50.00', 'E2: pending_verification → suspended');
  update booking.refunds set status = 'failed' where id = r3;
  perform pg_temp.ck(pg_temp.cards(p4) = 'pending_verification:50.00', 'E3: palautuu pending_verification');

  -- F: datakorjausfunktio jo kesken olevalle hyvitykselle (kuten 71 / 2918)
  alter table booking.refunds disable trigger refunds_gc_hold;
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines) select p4, order_id, 50, 'testi', 'processing', 'montonio', null from booking.payments where id = p4 returning id into r3;
  alter table booking.refunds enable trigger refunds_gc_hold;
  perform pg_temp.ck(pg_temp.cards(p4) = 'pending_verification:50.00', 'F0: ennen korjausta ei pitoa');
  perform test.service();
  v := booking.svc_refund_gift_card_hold(r3, 'testi');
  perform test.logout();
  perform pg_temp.ck((v ->> 'cards_held')::int = 1 and pg_temp.cards(p4) = 'suspended:50.00', 'F1: svc_refund_gift_card_hold lukitsee ' || v::text);
  perform pg_temp.ck(not has_function_privilege('authenticated', 'booking.svc_refund_gift_card_hold(bigint,text)', 'execute') and not has_function_privilege('anon', 'booking.svc_refund_gift_card_hold(bigint,text)', 'execute')
                     and has_function_privilege('service_role', 'booking.svc_refund_gift_card_hold(bigint,text)', 'execute'), 'F2: vain service_role');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_refund_gift_card_hold(%s)', r1)) = 'refund_not_pending', 'F3: valmis hyvitys → refund_not_pending');

  -- G: varauksen hyvitys (ei lahjakorttirivejä) ei koske kortteihin
  perform pg_temp.ck((select count(*) from booking._refund_gc_cards(p1, (select order_id from booking.payments where id = p1), '[{"payment_line_id":0,"amount":1}]'::jsonb)) = 0, 'G1: rivit eivät osu lahjakorttiriviin → ei kortteja');

  -- K8: lunastus vaatii partner_ref:n
  update booking.settings set value = 'true'::jsonb where key = 'voucher_claims.enabled';
  perform test.reset_rl();
  v := test.pub_book(v_rule, d, 2, 'k8@t345.example');
  tok := (v ->> 'token')::uuid; o5 := (test.ord(tok)).id;
  perform test.anon(null);
  v := booking.public_submit_voucher_claim(tok, 'KK91239EKKHHA', 'kokemuskauppa', null);
  perform test.logout();
  cl := coalesce((v ->> 'claim_id')::bigint, (v ->> 'id')::bigint, (select max(id) from booking.voucher_claims where order_id = o5));
  perform pg_temp.ck(cl is not null, 'K0: koodi lähetetty ' || v::text);
  perform test.login(u_adm);
  e := pg_temp.err(format('select booking.admin_mark_voucher_claim_redeemed(%s, null, null, %L)', cl, 'testi'));
  perform test.logout();
  perform pg_temp.ck(e = 'partner_ref_required', 'K1: ilman viitettä → partner_ref_required (' || coalesce(e, 'ok') || ')');
  perform test.login(u_adm);
  e := pg_temp.err(format('select booking.admin_mark_voucher_claim_redeemed(%s, null, %L, %L)', cl, '   ', 'testi'));
  perform test.logout();
  perform pg_temp.ck(e = 'partner_ref_required', 'K2: tyhjä viite → partner_ref_required');
  perform test.login(u_adm);
  e := pg_temp.err(format('select booking.admin_mark_voucher_claim_redeemed(%s, null, %L, %L)', cl, 'KK-123456', 'testi'));
  perform test.logout();
  perform pg_temp.ck(e is null and (select status || ':' || partner_ref from booking.voucher_claims where id = cl) = 'redeemed:KK-123456', 'K3: viitteellä lunastettu (' || coalesce(e, 'ok') || ')');
  perform pg_temp.ck(pg_temp.err(format('update booking.voucher_claims set partner_ref = null where id = %s', cl)) = 'partner_ref_required', 'K4: viitettä ei voi poistaa lunastetulta');
  -- vanha lunastettu rivi ilman viitettä: muut muutokset sallittu
  alter table booking.voucher_claims disable trigger voucher_claims_partner_ref_guard;
  update booking.voucher_claims set partner_ref = null where id = cl;
  alter table booking.voucher_claims enable trigger voucher_claims_partner_ref_guard;
  perform pg_temp.ck(pg_temp.err(format('update booking.voucher_claims set needs_review = not coalesce(needs_review, false) where id = %s', cl)) is null, 'K5: vanha rivi ilman viitettä: muu muutos sallittu');
end $t$;
select ok, label from t345_r;
select count(*) filter (where ok) || '/' || count(*) as tulos from t345_r;
rollback;
