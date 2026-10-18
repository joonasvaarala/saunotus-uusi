-- t57: "maksa myöhemmin" (testi). Kumoutuu lopuksi (tahallinen poikkeus). Tilausnumerolaskuri palautetaan kuten t53/t54:ssä.
set local lock_timeout = '3s';
set local statement_timeout = '90s';
create temp table t57_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t57_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.mk(p_slot timestamptz, p_email text) returns jsonb language sql as $$
  select booking.public_create_treatment_booking(11, p_slot, 2, 'Testi Asiakas', p_email, '+358401234567', false, 'fi', null, 'private', null, null) $$;
do $t$
declare v_seq0 bigint; v_maxid bigint; v_foreign int; r jsonb; r2 jsonb; tok uuid; oid bigint; v_slots timestamptz[]; r_s record; g1 bigint; v_total numeric; n1 int; n2 int; o1 jsonb; o2 jsonb; o3 jsonb;
  tok2 uuid; oid2 bigint; tok3 uuid; oid3 bigint; tok4 uuid; oid4 bigint; tok5 uuid; oid5 bigint; tok6 uuid; oid6 bigint; tok7 uuid; oid7 bigint; tok8 uuid; oid8 bigint; v_audit int; v_mail int; v_ok boolean;
begin
  select last_value into v_seq0 from booking.orders_order_no_seq; select coalesce(max(id), 0) into v_maxid from booking.orders;
  update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode';
  update booking.integration_config set mode = 'test' where key = 'mobilepay';
  insert into booking.gift_cards(code, issuer, kind, initial_amount, balance, status, source, vat_treatment, accounting_origin, balance_verified, valid_to)
  values ('HHTEST570001', 'own', 'value', 1000, 1000, 'active', 'native', 'at_redemption', 'native', true, current_date + 100) returning id into g1;
  for r_s in
    select q.starts_at from (
      select * from booking.public_treatment_availability(11, current_date + 3, current_date + 16, 2)
      union all select * from booking.public_treatment_availability(11, current_date + 17, current_date + 30, 2)
      union all select * from booking.public_treatment_availability(11, current_date + 31, current_date + 44, 2)) q
     where q.status = 'available' order by q.starts_at loop
    if v_slots is null or r_s.starts_at >= v_slots[cardinality(v_slots)] + interval '5 hours' then v_slots := array_append(v_slots, r_s.starts_at); end if;
  end loop;
  if v_slots is null or cardinality(v_slots) < 6 then raise exception 'TESTRESULT_ABORT vapaita hoitoaikoja %', coalesce(cardinality(v_slots), 0); end if;

  -- ===== lippu pois päältä (oletus) =====
  perform pg_temp.ck((select value from booking.settings where key = 'pay_later_test_enabled') = 'false'::jsonb, 'L0: asetus pay_later_test_enabled on oletuksena false');
  r := pg_temp.mk(v_slots[1], 'p1@t57.example'); tok := (r ->> 'token')::uuid; oid := (select id from booking.orders where public_token = tok); v_total := (r ->> 'total')::numeric;
  perform pg_temp.ck((r ->> 'ok')::boolean and (select status from booking.orders where id = oid) = 'pending', 'L1: hold-tilaus luotu (pending)');
  r := booking.public_confirm_pay_later(tok);
  perform pg_temp.ck(r ->> 'code' = 'pay_later_unavailable' and not (r ->> 'ok')::boolean, 'L2: lippu pois => pay_later_unavailable');
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'pending' and exists (select 1 from booking.reservations where order_id = oid and status = 'pending' and hold_expires_at is not null), 'L3: tilaus ennallaan (pending, pito voimassa)');
  perform pg_temp.ck(booking.public_confirm_pay_later(null) ->> 'code' = 'pay_later_unavailable', 'L4: null-token + lippu pois => pay_later_unavailable');
  o1 := booking.public_checkout_payment_options(); o2 := booking.public_payment_options(null); o3 := booking.public_payment_options(tok);
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(o1 -> 'methods') m where m ->> 'code' = 'pay_later')
                 and not exists (select 1 from jsonb_array_elements(o2 -> 'methods') m where m ->> 'code' = 'pay_later')
                 and not exists (select 1 from jsonb_array_elements(o3 -> 'methods') m where m ->> 'code' = 'pay_later'), 'L5: lippu pois => pay_later ei methods-listoissa (kolme RPC:tä)');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(o1 -> 'methods') m where m ->> 'code' = 'mobilepay') and (o1 ->> 'pay_later_test_enabled')::boolean = false, 'L6: MobilePay-lista ennallaan, pay_later_test_enabled=false');

  -- ===== lippu päälle (vain tämän transaktion ajan) =====
  update booking.settings set value = 'true'::jsonb where key = 'pay_later_test_enabled';
  o1 := booking.public_checkout_payment_options(); o2 := booking.public_payment_options(null); o3 := booking.public_payment_options(tok);
  perform pg_temp.ck((select count(*) from jsonb_array_elements(o1 -> 'methods') m where m ->> 'code' = 'pay_later' and (m ->> 'test')::boolean and (m ->> 'enabled')::boolean) = 1
                 and (select count(*) from jsonb_array_elements(o1 -> 'methods') m where m ->> 'code' = 'mobilepay') = 1, 'O1: public_checkout_payment_options: pay_later {test:true, enabled:true} + MobilePay');
  perform pg_temp.ck((select count(*) from jsonb_array_elements(o2 -> 'methods') m where m ->> 'code' = 'pay_later' and (m ->> 'test')::boolean and (m ->> 'enabled')::boolean) = 1, 'O2: public_payment_options(null): pay_later mukana');
  perform pg_temp.ck((select count(*) from jsonb_array_elements(o3 -> 'methods') m where m ->> 'code' = 'pay_later') = 1 and o3 -> 'order' ->> 'checkout_state' = 'awaiting_payment', 'O3: public_payment_options(token): awaiting_payment => pay_later mukana');

  -- ===== onnistunut vahvistus anon-roolilla =====
  select count(*) into n1 from booking.email_outbox where order_id = oid and kind = 'order_confirmation';
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
  r := booking.public_confirm_pay_later(tok);
  execute 'reset role';
  perform pg_temp.ck((r ->> 'ok')::boolean and r ->> 'checkout_state' = 'confirmed_unpaid' and not (r ->> 'idempotent')::boolean, 'C1: anon: ok + checkout_state=confirmed_unpaid (' || coalesce(r ->> 'code', r ->> 'checkout_state') || ')');
  perform pg_temp.ck((r ->> 'remaining_amount')::numeric = v_total and (r ->> 'order_id')::bigint = oid and r ->> 'status' = 'confirmed' and r ->> 'payment_status' = 'unpaid' and not (r ->> 'awaiting_payment')::boolean, 'C2: remaining_amount = koko summa, status confirmed, payment_status unpaid');
  perform pg_temp.ck((select status = 'confirmed' and payment_status = 'unpaid' and confirmed_at is not null from booking.orders where id = oid), 'C3: tilaus confirmed/unpaid, confirmed_at asetettu');
  perform pg_temp.ck(not exists (select 1 from booking.reservations where order_id = oid and status <> 'confirmed') and not exists (select 1 from booking.reservations where order_id = oid and hold_expires_at is not null)
                 and exists (select 1 from booking.reservations where order_id = oid and status = 'confirmed'), 'C4: varaukset confirmed, hold_expires_at null (paikka säilyy)');
  select count(*) into n2 from booking.email_outbox where order_id = oid and kind = 'order_confirmation';
  perform pg_temp.ck(n1 = 0 and n2 = 1 and (select dedupe_key from booking.email_outbox where order_id = oid and kind = 'order_confirmation') = 'order_confirmation:' || oid, 'C5: normaali order_confirmation-viesti jonossa (1 kpl, dedupe)');
  perform pg_temp.ck((select count(*) from booking.audit_log where action = 'pay_later_confirmed' and table_name = 'orders' and row_pk = oid::text) = 1, 'C6: audit_log-rivi pay_later_confirmed');
  perform pg_temp.ck(not exists (select 1 from booking.payments where order_id = oid and status in ('paid', 'cancelled')), 'C7: ei maksurivejä paid/cancelled');
  r := booking.public_payment_options(tok);
  perform pg_temp.ck((r -> 'order' ->> 'can_pay_online')::boolean and not exists (select 1 from jsonb_array_elements(r -> 'methods') m where m ->> 'code' = 'pay_later')
                 and exists (select 1 from jsonb_array_elements(r -> 'methods') m where m ->> 'code' = 'mobilepay'), 'C8: vahvistetun jälkeen MobilePay-maksu yhä mahdollinen, pay_later ei enää tarjolla');

  -- ===== idempotenssi =====
  select count(*) into v_audit from booking.audit_log where action = 'pay_later_confirmed' and row_pk = oid::text;
  r2 := booking.public_confirm_pay_later(tok);
  perform pg_temp.ck((r2 ->> 'ok')::boolean and (r2 ->> 'idempotent')::boolean and r2 ->> 'checkout_state' = 'confirmed_unpaid' and (r2 ->> 'remaining_amount')::numeric = v_total, 'I1: toinen kutsu palauttaa nykyisen tilan idempotentisti');
  perform pg_temp.ck((select count(*) from booking.audit_log where action = 'pay_later_confirmed' and row_pk = oid::text) = v_audit
                 and (select count(*) from booking.email_outbox where order_id = oid and kind = 'order_confirmation') = 1, 'I2: ei uutta lokiriviä eikä uutta sähköpostia');
  -- cron ei vanhenna vahvistettua
  perform booking._expire_holds();
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'confirmed' and exists (select 1 from booking.reservations where order_id = oid and status = 'confirmed')
                 and booking._checkout_state_json(oid) ->> 'checkout_state' = 'confirmed_unpaid', 'E1: _expire_holds ei vanhenna pay_later-tilausta');
  -- jo maksettuna vahvistettu (ei pay_later): palauta tila idempotentisti ilman kirjausta
  r := pg_temp.mk(v_slots[2], 'p2@t57.example'); tok2 := (r ->> 'token')::uuid; oid2 := (select id from booking.orders where public_token = tok2);
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = oid2 and status = 'pending';
  update booking.orders set status = 'confirmed', payment_status = 'paid', confirmed_at = now() where id = oid2;
  insert into booking.payments(order_id, provider, method, amount, status, currency) values (oid2, 'manual', 'cash', (select total_gross from booking.orders where id = oid2), 'paid', 'EUR');
  r := booking.public_confirm_pay_later(tok2);
  perform pg_temp.ck((r ->> 'ok')::boolean and r ->> 'checkout_state' = 'confirmed' and (r ->> 'idempotent')::boolean and not (r ->> 'pay_later')::boolean
                 and not exists (select 1 from booking.audit_log where action = 'pay_later_confirmed' and row_pk = oid2::text), 'I3: jo maksettu+vahvistettu => state confirmed, ei pay_later-kirjausta');

  -- ===== osittainen lahjakorttimaksu =====
  r := pg_temp.mk(v_slots[3], 'p3@t57.example'); tok3 := (r ->> 'token')::uuid; oid3 := (select id from booking.orders where public_token = tok3); v_total := (r ->> 'total')::numeric;
  r := booking.public_apply_gift_card(tok3, 'HHTEST570001', 5);
  perform pg_temp.ck((r ->> 'ok')::boolean and (select balance from booking.gift_cards where id = g1) = 995 and (select status from booking.orders where id = oid3) = 'pending', 'G1: lahjakortin osamaksu 5 € pitotilassa (pending)');
  r := booking.public_confirm_pay_later(tok3);
  perform pg_temp.ck((r ->> 'ok')::boolean and r ->> 'checkout_state' = 'confirmed_unpaid' and (r ->> 'remaining_amount')::numeric = v_total - 5 and r ->> 'payment_status' = 'partially_paid', 'G2: confirmed_unpaid, remaining = summa - 5, payment_status partially_paid');
  perform pg_temp.ck((select balance from booking.gift_cards where id = g1) = 995 and (select status from booking.payments where order_id = oid3 and method = 'gift_card') = 'paid', 'G3: lahjakorttiosuus säilyy käytettynä (saldo 995, maksu paid)');
  perform booking._expire_holds();
  perform pg_temp.ck((select status from booking.orders where id = oid3) = 'confirmed' and (select balance from booking.gift_cards where id = g1) = 995 and (select status from booking.payments where order_id = oid3 and method = 'gift_card') = 'paid', 'G4: cron ei palauta lahjakorttia eikä vanhenna');
  perform pg_temp.ck((select payment_status from booking.orders where id = oid3) = 'partially_paid', 'G5: payment_status pysyy partially_paid');

  -- ===== MobilePay kesken =====
  r := pg_temp.mk(v_slots[4], 'p4@t57.example'); tok4 := (r ->> 'token')::uuid; oid4 := (select id from booking.orders where public_token = tok4);
  perform booking.mobilepay_payment_prepare(tok4, null, 120);
  r := booking.public_confirm_pay_later(tok4);
  perform pg_temp.ck(r ->> 'code' = 'payment_in_progress' and (select status from booking.orders where id = oid4) = 'pending', 'M1: MobilePay kesken => payment_in_progress, tilaus pending');
  -- lopputilan jälkeen (ABORTED) ja pito yhä voimassa => onnistuu
  update booking.payments set raw = jsonb_set(raw, '{mobilepay,last_state}', '"ABORTED"') where order_id = oid4;
  r := booking.public_confirm_pay_later(tok4);
  perform pg_temp.ck((r ->> 'ok')::boolean and r ->> 'checkout_state' = 'confirmed_unpaid', 'M2: maksun peruuntumisen jälkeen vahvistus onnistuu');

  -- ===== alustava (preliminary) =====
  r := pg_temp.mk(v_slots[5], 'p5@t57.example'); tok5 := (r ->> 'token')::uuid; oid5 := (select id from booking.orders where public_token = tok5);
  update booking.orders set hold_kind = 'preliminary' where id = oid5;
  r := booking.public_confirm_pay_later(tok5);
  perform pg_temp.ck(r ->> 'code' = 'payment_in_progress' and r ->> 'checkout_state' = 'preliminary' and (select status from booking.orders where id = oid5) = 'pending', 'P1: preliminary => payment_in_progress, ei vahvisteta');

  -- ===== vanhentunut =====
  r := pg_temp.mk(v_slots[6], 'p6@t57.example'); tok6 := (r ->> 'token')::uuid; oid6 := (select id from booking.orders where public_token = tok6);
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = oid6 and status = 'pending';
  r := booking.public_confirm_pay_later(tok6);
  perform pg_temp.ck(r ->> 'code' = 'order_expired' and not exists (select 1 from booking.reservations where order_id = oid6 and status = 'confirmed'), 'X1: pito päättynyt (cron ei vielä ajanut) => order_expired, ei elvytetä');
  perform booking._expire_holds();
  r := booking.public_confirm_pay_later(tok6);
  perform pg_temp.ck(r ->> 'code' = 'order_cancelled' and (select status from booking.orders where id = oid6) = 'cancelled', 'X2: cronin jälkeen (cancelled) => order_cancelled');

  -- ===== peruttu =====
  r := pg_temp.mk(v_slots[6], 'p7@t57.example'); tok7 := (r ->> 'token')::uuid; oid7 := (select id from booking.orders where public_token = tok7);
  perform booking.public_cancel_booking(tok7);
  r := booking.public_confirm_pay_later(tok7);
  perform pg_temp.ck(r ->> 'code' = 'order_cancelled' and (select status from booking.orders where id = oid7) = 'cancelled', 'N1: peruttu => order_cancelled');

  -- ===== virheelliset tunnisteet =====
  perform pg_temp.ck(booking.public_confirm_pay_later(gen_random_uuid()) ->> 'code' = 'not_found', 'U1: tuntematon token => not_found');
  perform pg_temp.ck(booking.public_confirm_pay_later(null) ->> 'code' = 'not_found', 'U2: null-token (lippu päällä) => not_found');

  -- ===== oikeudet =====
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_confirm_pay_later(uuid)', 'execute') and has_function_privilege('authenticated', 'booking.public_confirm_pay_later(uuid)', 'execute')
                 and has_function_privilege('service_role', 'booking.public_confirm_pay_later(uuid)', 'execute'), 'R1: anon/authenticated/service_role saavat ajaa public_confirm_pay_later');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._pay_later_test_enabled()', 'execute') and not has_function_privilege('anon', 'booking._pay_later_method_json()', 'execute')
                 and not has_function_privilege('authenticated', 'booking._pay_later_test_enabled()', 'execute'), 'R2: apufunktiot eivät ole anonin ajettavissa');
  perform pg_temp.ck((select pp.prosecdef and pp.proconfig @> array['search_path=""'] from pg_proc pp where pp.oid = 'booking.public_confirm_pay_later(uuid)'::regprocedure), 'R3: SECURITY DEFINER + search_path lukittu');
  -- anon ei näe luonnoksia / suoraa taulukäyttöä (anon-rooli): suora update estetty
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
  v_ok := true;
  begin
    update booking.orders set status = 'confirmed' where id = oid5;
    get diagnostics n1 = row_count;
    v_ok := n1 = 0;   -- RLS: 0 riviä (tai poikkeus)
  exception when others then v_ok := true;
  end;
  execute 'reset role';
  perform pg_temp.ck(v_ok, 'R4: anon ei saa päivittää orders suoraan');

  -- ===== lippu takaisin pois =====
  update booking.settings set value = 'false'::jsonb where key = 'pay_later_test_enabled';
  r := booking.public_confirm_pay_later(tok);
  perform pg_temp.ck(r ->> 'code' = 'pay_later_unavailable', 'F1: lippu takaisin pois => pay_later_unavailable (myös vahvistetulle)');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(booking.public_checkout_payment_options() -> 'methods') m where m ->> 'code' = 'pay_later'), 'F2: lippu pois => ei pay_later-listassa');

  select count(*) into v_foreign from booking.orders where id > v_maxid and created_at <> now();
  if v_foreign = 0 then perform setval('booking.orders_order_no_seq', v_seq0, true); end if;
  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t57_r where ok), (select count(*) from t57_r where not ok), coalesce((select string_agg(label, ' | ') from t57_r where not ok), 'ALL OK');
end $t$;
