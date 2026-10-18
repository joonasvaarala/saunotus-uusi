-- t54: asiakkaan peruutus pitotilassa. Kumoutuu lopuksi (tahallinen poikkeus). Tilausnumerolaskuri palautetaan kuten t53:ssa.
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t54_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t54_r values (coalesce(p_ok, false), p_label) $$;
do $t$
declare v_seq0 bigint; v_maxid bigint; v_foreign int; r jsonb; tok uuid; oid bigint; pid bigint; v_slot timestamptz; g1 bigint; v_bal0 numeric; v_total numeric;
begin
  select last_value into v_seq0 from booking.orders_order_no_seq; select coalesce(max(id), 0) into v_maxid from booking.orders;
  update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode';
  update booking.integration_config set mode = 'test' where key = 'mobilepay';
  insert into booking.gift_cards(code, issuer, kind, initial_amount, balance, status, source, vat_treatment, accounting_origin, balance_verified, valid_to)
  values ('HHTEST000001', 'own', 'value', 1000, 1000, 'active', 'native', 'at_redemption', 'native', true, current_date + 100) returning id into g1;
  select q.starts_at into v_slot from booking.public_treatment_availability(11, current_date + 3, current_date + 16, 2) q where q.status = 'available' order by q.starts_at limit 1;
  r := booking.public_create_treatment_booking(11, v_slot, 2, 'Testi Asiakas', 'k1@t54.example', '+358401234567', false, 'fi', null, 'private', null, null);
  tok := (r ->> 'token')::uuid; oid := (select id from booking.orders where public_token = tok); v_total := (r ->> 'total')::numeric;
  perform pg_temp.ck((r ->> 'ok')::boolean, 'K0: hold luotu');
  r := booking.public_apply_gift_card(tok, 'HHTEST000001', 5);
  perform pg_temp.ck((r ->> 'ok')::boolean and (select balance from booking.gift_cards where id = g1) = 995, 'K1: osamaksu 5 €');
  r := booking.public_cancel_booking(tok);
  perform pg_temp.ck((r ->> 'ok')::boolean and (select status from booking.orders where id = oid) = 'cancelled', 'K2: asiakas peruu odottavan');
  perform pg_temp.ck((select balance from booking.gift_cards where id = g1) = 1000 and (select status from booking.payments where order_id = oid and method = 'gift_card') = 'cancelled', 'K3: lahjakorttiosuus palautui kortille');
  perform pg_temp.ck(not exists (select 1 from booking.receipts where order_id = oid), 'K4: ei kuittia');
  perform pg_temp.ck((select payment_status from booking.orders where id = oid) = 'unpaid', 'K5: payment_status unpaid');
  -- MobilePay kesken => ei peruutusta
  r := booking.public_create_treatment_booking(11, v_slot, 2, 'Testi Asiakas', 'k2@t54.example', '+358401234567', false, 'fi', null, 'private', null, null);
  tok := (r ->> 'token')::uuid; oid := (select id from booking.orders where public_token = tok);
  perform booking.mobilepay_payment_prepare(tok, null, 120);
  r := booking.public_cancel_booking(tok);
  perform pg_temp.ck(r ->> 'code' = 'payment_in_progress' and (select status from booking.orders where id = oid) = 'pending', 'K6: MobilePay kesken => peruutus estetty');
  update booking.payments set raw = jsonb_set(raw, '{mobilepay,last_state}', '"ABORTED"') where order_id = oid;
  r := booking.public_cancel_booking(tok);
  perform pg_temp.ck((r ->> 'ok')::boolean and (select status from booking.orders where id = oid) = 'cancelled', 'K7: lopputilan jälkeen peruutus onnistuu');
  -- vahvistettua ei voi peruuttaa itse (ennallaan)
  update booking.settings set value = '"pay_later"'::jsonb where key = 'public_payment_mode';
  r := booking.public_create_treatment_booking(11, v_slot, 2, 'Testi Asiakas', 'k3@t54.example', '+358401234567', false, 'fi', null, 'private', null, null);
  perform pg_temp.ck(booking.public_cancel_booking((r ->> 'token')::uuid) ->> 'code' = 'not_cancellable', 'K8: vahvistettu: not_cancellable (ennallaan)');
  select count(*) into v_foreign from booking.orders where id > v_maxid and created_at <> now();
  if v_foreign = 0 then perform setval('booking.orders_order_no_seq', v_seq0, true); end if;
  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t54_r where ok), (select count(*) from t54_r where not ok), coalesce((select string_agg(label, ' | ') from t54_r where not ok), 'ALL OK');
end $t$;
