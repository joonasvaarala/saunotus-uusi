begin;
-- t309: verkkokaupan maksamatta vanhentuneiden tilausten automaattinen poisto näkyvistä (booking_309, Joonas t1738u 14.11.2026).
-- Vaatii migraatiot ≤ 309 + fixtures/10_test_helpers.sql. Yksi transaktio; lopuksi rollback. VAIN paikalliseen kertakäyttökantaan.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table t309_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t309_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.run(p_who text, p_sql text, p_user uuid default null, p_ip text default null) returns jsonb language plpgsql as $$
declare v jsonb; d text;
begin
  perform test.reset_rl();
  case p_who when 'anon' then perform test.anon(p_ip); when 'service' then perform test.service(); else perform test.login(p_user); end case;
  begin execute p_sql into v;
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(nullif(d, ''), sqlstate), 'msg', sqlerrm);
  end;
  perform test.logout();
  return v;
end $$;
-- verkkokaupan varaus (anon) → order id
create function pg_temp.book(p_rule bigint, p_date date, p_email text) returns bigint language plpgsql as $$
declare a jsonb;
begin
  perform test.reset_rl();
  perform test.anon('10.30.9.' || (1 + (random() * 200)::int));
  a := test.pub_book(p_rule, p_date, 2, p_email);
  perform test.logout();
  if not coalesce((a ->> 'ok')::boolean, false) then raise exception 'pub_book: %', a; end if;
  return (test.ord((a ->> 'token')::uuid)).id;
end $$;
-- pito vanhenee: hold_expires_at menneisyyteen + expire_holds (cron-ajo) ; vanhentumisviesti "lähetetään"
create function pg_temp.expire(p_order bigint) returns void language plpgsql as $$
begin
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = p_order and status = 'pending';
  update booking.payments set raw = coalesce(raw, '{}'::jsonb) || jsonb_build_object('attempt_started_at', now() - interval '2 hours', 'last_state', 'CREATED')
   where order_id = p_order and status = 'pending';
end $$;
create function pg_temp.send_mails(p_order bigint) returns void language sql as $$
  update booking.email_outbox set status = 'sent', sent_at = now(), attempts = 1 where order_id = p_order and status = 'pending' $$;

do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%'); d date := test.next_dow(1, 20);
  u_adm uuid := test.mk_staff('adm@t309.example', 'admin');
  v jsonb; oA bigint; oB bigint; oC bigint; oD bigint; oE bigint; oG bigint; oNew bigint;
  noA bigint; nA_orders int; nA_pay int; v_cnt int; pk jsonb; it jsonb; r jsonb; v_pay bigint; v_amt numeric; v_ref text;
  v_cap_before int; v_cap_after int;
begin
  -- verkkokaupan maksutapa kuten tuotannossa: pito, kunnes maksettu (15 min)
  update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode';
  update booking.settings set value = '0'::jsonb where key = 'checkout_group_threshold_persons';
  insert into booking.integration_config(key, mode, settings) values ('montonio', 'test', '{"approved_by":"t309"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = booking.integration_config.settings || '{"approved_by":"t309"}'::jsonb;
  -- A: verkkokaupan varaus vanhenee
  oA := pg_temp.book(v_rule, d, 'a@t309.example');
  insert into booking.payments(order_id, method, provider, provider_ref, status, amount, raw)
  values (oA, 'montonio', 'montonio', 'sauna-t309-a1', 'pending', (select total_gross from booking.orders where id = oA), '{"order_uuid":"u-t309"}'::jsonb)
  returning id into v_pay;
  select order_no into noA from booking.orders where id = oA;
  perform pg_temp.expire(oA);
  perform booking.expire_holds();
  perform pg_temp.ck((select status = 'cancelled' and archived_at is null from booking.orders where id = oA)
                 and (select bool_and(status = 'cancelled' and cancel_reason = 'hold_expired') from booking.reservations where order_id = oA)
                 and (select status from booking.payments where id = v_pay) = 'cancelled',
                 'A1: vanhentuminen kuten ennen: tilaus+varaus peruttu (hold_expired), maksu cancelled');
  perform pg_temp.ck(exists (select 1 from booking.email_outbox where order_id = oA and kind = 'unpaid_booking_cancelled' and status = 'pending')
                 and (select archived_at is null from booking.orders where id = oA),
                 'A2: vanhentumisviesti jonossa → tilausta EI vielä arkistoida (viesti ei saa skipata)');
  perform pg_temp.send_mails(oA);
  select count(*) into nA_orders from booking.orders; select count(*) into nA_pay from booking.payments;
  v := booking.expired_web_orders_archive_sweep(200);
  perform pg_temp.ck((v ->> 'archived')::int >= 1, 'A3: sweep arkistoi ' || v::text);
  perform pg_temp.ck((select archived_at is not null and archive_reason = 'auto:expired_unpaid' and archived_by is null and status = 'cancelled'
                         and payment_status = 'unpaid' and order_no = noA and external_meta #>> '{booking_309,prev_status}' = 'cancelled' from booking.orders where id = oA),
                 'A4: tilaus arkistoitu (archived_at, syy auto:expired_unpaid), numero ennallaan');
  perform pg_temp.ck((select bool_and(hidden_at is not null and hidden_reason = 'expired_unpaid_auto' and status = 'cancelled') from booking.reservations where order_id = oA),
                 'A5: varaukset piilotettu, tila ennallaan cancelled');
  perform pg_temp.ck((select count(*) from booking.orders) = nA_orders and (select count(*) from booking.payments) = nA_pay
                 and (select status from booking.payments where id = v_pay) = 'cancelled'
                 and exists (select 1 from booking.email_outbox where order_id = oA and kind = 'unpaid_booking_cancelled' and status = 'sent'),
                 'A6: ei fyysistä poistoa: tilaus-, maksu- ja viestirivit säilyvät (FK:t eheät)');
  perform pg_temp.ck(exists (select 1 from booking.audit_log where action = 'ORDER_AUTO_ARCHIVED_EXPIRED' and row_pk = oA::text and old_data ->> 'order_no' = noA::text),
                 'A7: audit-merkintä ORDER_AUTO_ARCHIVED_EXPIRED');
  v := booking.expired_web_orders_archive_sweep(200);
  perform pg_temp.ck((select count(*) from booking.audit_log where action = 'ORDER_AUTO_ARCHIVED_EXPIRED' and row_pk = oA::text) = 1, 'A8: idempotentti (toinen ajo ei koske) ' || v::text);

  -- B–D: tauko päälle, jotta expire_holds-ajojen sisäinen sweep ei arkistoi kesken tarkistusten
  update booking.settings set value = 'true'::jsonb where key = 'expired_unpaid_auto_archive_paused';
  -- numerointi: uusi tilaus saa suuremman numeron (sekvenssi ei palaa)
  oNew := pg_temp.book(v_rule, d, 'n@t309.example');
  perform pg_temp.ck((select order_no from booking.orders where id = oNew) > noA, 'N1: tilausnumeroa ei käytetä uudelleen');
  -- kapasiteetti: vanhentunut varaus ei vie paikkaa (vapautui jo vanhentuessa; arkistointi ei muuta)
  perform pg_temp.ck(not exists (select 1 from booking.reservations where order_id = oA and status in ('pending','confirmed')), 'K1: kapasiteetti vapaa (ei voimassa olevaa varausta)');

  -- B: hallinnan tekemä (created_by) maksamaton vanhentunut → EI
  oB := pg_temp.book(v_rule, d, 'b@t309.example');
  update booking.orders set created_by = u_adm where id = oB;
  perform pg_temp.expire(oB); perform booking.expire_holds(); perform pg_temp.send_mails(oB);
  perform booking.expired_web_orders_archive_sweep(200);
  perform pg_temp.ck((select archived_at is null from booking.orders where id = oB), 'B1: hallinnan tekemä tilaus ei poistu');
  -- B2: muu kanava (admin) → EI
  oC := pg_temp.book(v_rule, d, 'c@t309.example');
  update booking.orders set source_channel = 'admin' where id = oC;
  perform pg_temp.expire(oC); perform booking.expire_holds(); perform pg_temp.send_mails(oC);
  perform booking.expired_web_orders_archive_sweep(200);
  perform pg_temp.ck((select archived_at is null from booking.orders where id = oC), 'B2: hallinnan kanava (admin) ei poistu');

  -- C: asiakkaan itse perumana (ei vanhentunut) → EI
  oD := pg_temp.book(v_rule, d, 'd@t309.example');
  update booking.reservations set status = 'cancelled', cancelled_at = now(), cancel_reason = 'customer_cancelled_pending' where order_id = oD;
  update booking.orders set status = 'cancelled', cancelled_at = now() where id = oD;
  perform booking.expired_web_orders_archive_sweep(200);
  perform pg_temp.ck((select archived_at is null from booking.orders where id = oD), 'C1: asiakkaan peruma (customer_cancelled_pending) ei kuulu');

  -- D: maksu tullut (paid) → EI
  oE := pg_temp.book(v_rule, d, 'e@t309.example');
  perform pg_temp.expire(oE); perform booking.expire_holds(); perform pg_temp.send_mails(oE);
  perform pg_temp.ck(booking._expired_web_order_archivable(oE), 'D0: vanhentunut verkkotilaus ilman maksuja on poistettava');
  -- maksu tullut (paid, kuitti) → EI
  oD := pg_temp.book(v_rule, d, 'e2@t309.example');
  perform pg_temp.expire(oD); perform booking.expire_holds(); perform pg_temp.send_mails(oD);
  insert into booking.payments(order_id, method, provider, status, amount, paid_at) values (oD, 'card_terminal', 'manual', 'paid', 1, now());
  perform pg_temp.ck(not booking._expired_web_order_archivable(oD), 'D1: maksettu rivi estää');
  update booking.payments set status = 'cancelled', paid_at = null where order_id = oD and status = 'paid';
  perform pg_temp.ck(not booking._expired_web_order_archivable(oD), 'D2: kerran maksettu (kuitti/kirjanpito jää) estää edelleen');
  v := booking.expired_web_orders_archive_sweep(200);
  perform pg_temp.ck((select archived_at is null from booking.orders where id = oD), 'D2b: sweep ei koske maksettuun');
  insert into booking.payments(order_id, method, provider, status, amount) values (oE, 'card_terminal', 'manual', 'pending', 1);
  perform pg_temp.ck(not booking._expired_web_order_archivable(oE), 'D3: odottava maksu estää');
  delete from booking.payments where order_id = oE and status = 'pending';
  -- lahjakorttikirjaus nettona ≠ 0 estää
  insert into booking.gift_cards(code, issuer, kind, initial_amount, balance, status, source) values ('HHT309AAAAA1', 'own', 'value', 50, 50, 'active', 'native');
  insert into booking.gift_card_ledger(gift_card_id, order_id, delta, balance_after, reason, note)
    select id, oE, -10, 40, 'redemption', 't309' from booking.gift_cards where code = 'HHT309AAAAA1';
  perform pg_temp.ck(not booking._expired_web_order_archivable(oE), 'D4: käytetty lahjakortti (netto ≠ 0) estää');
  insert into booking.gift_card_ledger(gift_card_id, order_id, delta, balance_after, reason, note)
    select id, oE, 10, 50, 'refund', 't309' from booking.gift_cards where code = 'HHT309AAAAA1';
  perform pg_temp.ck(booking._expired_web_order_archivable(oE), 'D5: palautettu lahjakorttiosuus (netto 0) sallii');

  update booking.settings set value = 'false'::jsonb where key = 'expired_unpaid_auto_archive_paused';
  -- E: verkkokaupan lahjakorttiosto vanhenee (gift_cards_housekeeping 2 h) → tila expired → poistuu näkyvistä
  update booking.settings set value = 'true'::jsonb where key = 'gift_cards.sale_enabled';
  pk := booking.public_gift_card_packages();
  select p into it from jsonb_array_elements(pk -> 'packages') p order by (p ->> 'is_open')::boolean desc nulls last limit 1;
  if coalesce((it ->> 'is_open')::boolean, false) then it := jsonb_build_array(jsonb_build_object('package', it ->> 'code', 'quantity', 1, 'amount', 50));
  else it := jsonb_build_array(jsonb_build_object('package', it ->> 'code', 'quantity', 1)); end if;
  perform test.reset_rl(); perform test.anon('10.30.9.250');
  r := booking.public_buy_gift_card(it, 'Testi Ostaja', 'gc@t309.example', '+358401234567', false, 'fi');
  perform test.logout();
  oG := (test.ord((r ->> 'token')::uuid)).id;
  perform pg_temp.ck(oG is not null and (select status = 'pending' and source_channel = 'web' from booking.orders where id = oG), 'E0: lahjakorttiosto luotu ' || coalesce(r::text, '-'));
  select id, amount into v_pay, v_amt from booking.payments where order_id = oG order by id limit 1;
  update booking.payments set provider = 'visma_pay', method = 'visma_pay', provider_ref = coalesce(provider_ref, 'sauna-t309-gc') where id = v_pay;
  select provider_ref into v_ref from booking.payments where id = v_pay;
  update booking.orders set created_at = now() - interval '3 hours' where id = oG;
  perform booking.gift_cards_housekeeping();
  perform pg_temp.ck((select status = 'expired' from booking.orders where id = oG) and (select status from booking.payments where id = v_pay) = 'cancelled'
                 and not exists (select 1 from booking.gift_cards where purchase_order_id = oG and status <> 'cancelled'),
                 'E1: lahjakorttiosto vanhenee kuten ennen (expired, maksu ja kortti peruttu)');
  perform pg_temp.ck(booking._expired_web_order_archivable(oG), 'E2: #15210-tyyppinen tilaus kuuluu poistettaviin');
  v := booking.expired_web_orders_archive_sweep(200);
  perform pg_temp.ck((select archived_at is not null and status = 'cancelled' and payment_status = 'unpaid'
                         and external_meta #>> '{booking_309,prev_status}' = 'expired' and external_meta #>> '{booking_309,prev_payment_status}' = 'pending'
                       from booking.orders where id = oG), 'E3: arkistoitu, tila expired → cancelled (263-polku myöhäiselle maksulle) ' || v::text);
  perform pg_temp.ck((select count(*) from booking.gift_card_ledger where order_id = oG and not (reason = 'cancel' and delta = 0)) = 0
                 and (select bool_and(status = 'cancelled' and balance = 0) from booking.gift_cards where purchase_order_id = oG),
                 'E4: lahjakortit ja saldo ennallaan (ei orpoja kirjauksia)');

  -- F: myöhäinen maksu poistetulle tilaukselle → ei kaadu, tilaus pysyy poistettuna, hälytys henkilökunnalle kerran
  v := booking.payment_mark_paid('visma_pay', v_ref, v_amt, '{"t309":"late"}'::jsonb);
  perform pg_temp.ck((v ->> 'ok')::boolean and (v ->> 'needs_manual_review')::boolean and (v ->> 'order_cancelled')::boolean,
                 'F1: myöhäinen Visma-maksu: ok + needs_manual_review (booking_263) ' || v::text);
  perform pg_temp.ck((select status = 'cancelled' and archived_at is not null from booking.orders where id = oG), 'F2: tilaus pysyy peruttuna ja poistettuna');
  v := booking.expired_web_orders_archive_sweep(200);
  perform pg_temp.ck(exists (select 1 from booking.notifications_outbox where topic = 'late_paid_archived' and ref_table = 'payments' and ref_id = v_pay
                               and target = 'tapio' and status = 'new' and (payload ->> 'order_id')::bigint = oG), 'F3: hälytys late_paid_archived Tapiolle ' || v::text);
  v := booking.expired_web_orders_archive_sweep(200);
  perform pg_temp.ck((v ->> 'alerts_queued')::int = 0 and (select count(*) from booking.notifications_outbox where topic = 'late_paid_archived' and ref_id = v_pay) = 1,
                 'F4: hälytys vain kerran / maksu ' || v::text);
  -- Montonio: myöhäinen maksu A:n peruttuun maksuriviin
  select id, amount into v_pay, v_amt from booking.payments where order_id = oA and provider = 'montonio';
  v := booking.montonio_payment_apply('sauna-t309-a1', 'paid', v_amt, '{"t309":"late"}'::jsonb);
  perform pg_temp.ck(coalesce((v ->> 'ok')::boolean, false) and (select status from booking.payments where id = v_pay) = 'paid'
                 and (select status = 'cancelled' and archived_at is not null from booking.orders where id = oA),
                 'F5: myöhäinen Montonio-maksu: ei kaadu, maksu kirjataan, tilaus pysyy poistettuna ' || v::text);
  v := booking.expired_web_orders_archive_sweep(200);
  perform pg_temp.ck(exists (select 1 from booking.notifications_outbox where topic = 'late_paid_archived' and ref_id = v_pay), 'F6: Montonio-myöhäismaksusta hälytys ' || v::text);
  perform pg_temp.ck(exists (select 1 from booking.audit_log where action = 'LATE_PAID_CANCELLED_ORDER' and row_pk = v_pay::text), 'F7: booking_263-audit LATE_PAID_CANCELLED_ORDER');

  -- I: tauko-asetus pysäyttää arkistoinnin; expire_holds (cron) ajaa sweepin
  update booking.settings set value = 'true'::jsonb where key = 'expired_unpaid_auto_archive_paused';
  oC := pg_temp.book(v_rule, d, 'i@t309.example');
  perform pg_temp.expire(oC); perform booking.expire_holds(); perform pg_temp.send_mails(oC);
  perform pg_temp.ck(booking._expired_web_order_archivable(oC), 'I0: uusi vanhentunut tilaus olisi poistettava');
  v := booking.expired_web_orders_archive_sweep(200);
  perform pg_temp.ck((v ->> 'paused')::boolean and (v ->> 'archived')::int = 0 and (select archived_at is null from booking.orders where id = oC), 'I1: tauko → ei arkistointia ' || v::text);
  update booking.settings set value = 'false'::jsonb where key = 'expired_unpaid_auto_archive_paused';
  perform booking.expire_holds();
  perform pg_temp.ck((select archived_at is not null from booking.orders where id = oC) and (select archived_at is not null from booking.orders where id = oE),
                 'I2: expire_holds-ajo (cron) arkistoi');

  -- J: hallinnan asiakaskortti ei näytä poistettua maksamatonta tilausta (myöhään maksettu näkyy)
  v := pg_temp.run('user', format('select booking.admin_get_customer(%s)', (select customer_id from booking.orders where id = oE)), u_adm);
  perform pg_temp.ck(not (v ? 'err') and not exists (select 1 from jsonb_array_elements(v -> 'orders') x where (x ->> 'order_id')::bigint = oE),
                 'J1: asiakaskortti piilottaa poistetun tilauksen');
  v := pg_temp.run('user', format('select booking.admin_get_customer(%s)', (select customer_id from booking.orders where id = oA)), u_adm);
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(v -> 'orders') x where (x ->> 'order_id')::bigint = oA), 'J2: myöhään maksettu poistettu tilaus näkyy asiakaskortilla');

  -- K: oikeudet
  v := pg_temp.run('anon', 'select booking.expired_web_orders_archive_sweep(10)', null, '10.30.9.251');
  perform pg_temp.ck(v ? 'err', 'K1: anon ei voi ajaa ' || v::text);
  v := pg_temp.run('user', 'select booking.expired_web_orders_archive_sweep(10)', u_adm);
  perform pg_temp.ck(v ? 'err', 'K2: authenticated (admin) ei voi ajaa ' || v::text);
  v := pg_temp.run('service', 'select booking.expired_web_orders_archive_sweep(10)');
  perform pg_temp.ck(not (v ? 'err') and (v ->> 'ok')::boolean, 'K3: service_role voi ajaa ' || v::text);
  v := pg_temp.run('anon', format('select to_jsonb(booking._expired_web_order_archivable(%s))', oE), null, '10.30.9.252');
  perform pg_temp.ck(v ? 'err', 'K4: anon ei voi kutsua apufunktiota ' || v::text);
end $t$;
select 'RESULT ' || case when ok then 'ok' else 'NOT OK' end || ' - ' || label from t309_r;
select 'SUMMARY ' || count(*) filter (where not ok) || ' failed / ' || count(*) from t309_r;
rollback;
