begin;
-- t282: pienennyksen esikatselu ja hyvitys (booking_282, tilausnäkymä v3 PR 3 / D).
-- Ajetaan migraatioiden jälkeen (282 mukaan lukien) ja fixtures/10_test_helpers.sql:n jälkeen. Yksi transaktio; lopuksi poikkeus kumoaa kaiken.
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t282_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t282_r values (coalesce(p_ok, false), p_label) $$;
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
-- tilaus: n henkilöä, kokonaan maksettu (p_method), valinnaisesti lahjakortti p_gc ensin
create function pg_temp.mk(p_rule bigint, p_date date, p_persons int, p_email text, p_method text, p_gc numeric default 0, p_code text default null) returns bigint language plpgsql as $$
declare a jsonb; o bigint; u uuid; v_unpaid numeric;
begin
  perform test.reset_rl();
  a := test.pub_book(p_rule, p_date, p_persons, p_email);
  if not coalesce((a ->> 'ok')::boolean, false) then raise exception 'pub_book: %', a; end if;
  o := (test.ord((a ->> 'token')::uuid)).id;
  if p_gc > 0 then
    insert into booking.gift_cards(code, initial_amount, balance, valid_to, status) values (p_code, p_gc, p_gc, current_date + 200, 'active');
    perform booking._apply_gift_core(o, p_code, 'card_terminal', true, 'Testi');
  end if;
  select (booking._order_balance(o) ->> 'unpaid')::numeric into v_unpaid;
  if v_unpaid > 0 then
    select id into u from auth.users where email = 'adm@t282.example';
    perform test.login(u);
    perform booking.admin_record_payment(o, 'card_terminal', v_unpaid, null, null);
    perform test.logout();
  end if;
  if p_method = 'montonio' then
    update booking.payments set provider = 'montonio', method = 'montonio' where order_id = o and method = 'card_terminal' and gift_card_id is null;
  end if;
  return o;
end $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%'); d date := test.next_dow(1, 20);
  u_adm uuid := test.mk_staff('adm@t282.example', 'admin'); u_stf uuid := test.mk_staff('stf@t282.example', 'staff');
  v jsonb; w jsonb; o1 bigint; o2 bigint; o3 bigint; o4 bigint; r1 bigint; r2 bigint; r3 bigint; r4 bigint; v_tot numeric; v_new numeric; v_diff numeric; v_n int; v_sum numeric;
begin
  update booking.settings set value = '200'::jsonb where key = 'public_treatment_global_per_hour';
  update booking.settings set value = 'true'::jsonb where key = 'gift_cards.redeem_enabled';
  update booking.integration_config set mode = 'test', settings = settings || '{"approved_by":"testi"}'::jsonb where key = 'montonio';
  perform pg_temp.ck(not booking._flag_on('partial_refunds_enabled'), 'L0: lippu partial_refunds_enabled on oletuksena pois');

  -- ===== käteinen/korttipääte, 3 → 2 henkilöä =====
  o1 := pg_temp.mk(v_rule, d, 3, 'a@t282.example', 'card_terminal');
  select id into r1 from booking.reservations where order_id = o1;
  select total_gross into v_tot from booking.orders where id = o1;
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking_preview(%s, null, null, 2, null)', r1));
  perform pg_temp.ck((v ->> 'ok')::boolean and (v ->> 'old_total')::numeric = v_tot and (v ->> 'new_total')::numeric < v_tot, 'P1: esikatselu laskee pienemmän hinnan ' || v::text);
  v_new := (v ->> 'new_total')::numeric; v_diff := v_tot - v_new;
  perform pg_temp.ck((v ->> 'diff')::numeric = -v_diff and (v ->> 'overpaid_after')::numeric = v_diff and (v ->> 'refundable_max')::numeric = v_diff, 'P2: erotus = ylisuoritus = hyvitettävä enintään');
  perform pg_temp.ck(not (v ->> 'partial_refunds_enabled')::boolean and (v ->> 'can_refund')::boolean, 'P3: lippu pois, admin saa hyvittää');
  perform pg_temp.ck((select persons from booking.reservations where id = r1) = 3, 'P4: esikatselu ei muuta mitään');
  v := pg_temp.as_(u_stf, format('select booking.admin_change_booking_preview(%s, null, null, 2, null)', r1));
  perform pg_temp.ck(not (v ->> 'can_refund')::boolean, 'P5: staff ei voi hyvittää (can_refund=false)');
  -- lippu pois → hyvitys estetty, muutos ei tapahdu
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2, false, false, null, null, %s, %L, false)', r1, v_diff, 'testi hyvitys'));
  perform pg_temp.ck(v ->> 'err' = 'partial_refunds_disabled', 'F0: lippu pois → estetty ' || coalesce(v ->> 'err', v::text));
  perform pg_temp.ck((select persons from booking.reservations where id = r1) = 3, 'F0b: muutosta ei tehty');
  update booking.settings set value = 'true'::jsonb where key = 'partial_refunds_enabled';
  -- ilman payments.refund
  v := pg_temp.as_(u_stf, format('select booking.admin_change_booking(%s, null, null, 2, false, false, null, null, %s, %L, false)', r1, v_diff, 'testi hyvitys'));
  perform pg_temp.ck(v ->> 'err' = 'forbidden', 'F1: staff ei voi hyvittää: ' || coalesce(v ->> 'err', v::text));
  -- liian suuri summa → koko toiminto kumoutuu
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2, false, false, null, null, %s, %L, false)', r1, v_diff + 1, 'testi hyvitys'));
  perform pg_temp.ck(v ->> 'err' = 'amount_exceeds_refundable', 'F2: yli ylisuorituksen estetty ' || coalesce(v ->> 'err', v::text));
  perform pg_temp.ck((select persons from booking.reservations where id = r1) = 3 and (select total_gross from booking.orders where id = o1) = v_tot, 'F2b: muutos kumoutui (atomisuus)');
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2, false, false, null, null, 0.04, %L, false)', r1, 'testi hyvitys'));
  perform pg_temp.ck(v ->> 'err' = 'invalid_amount', 'F3: alle 0,05 € estetty');
  -- onnistuva muutos + hyvitys + viesti
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2, false, false, null, null, %s, %L, true)', r1, v_diff, 'Henkilömäärä pieneni'));
  perform pg_temp.ck((v ->> 'ok')::boolean and (v ->> 'refunded_total')::numeric = v_diff and (select persons from booking.reservations where id = r1) = 2, 'H1: muutos + hyvitys ' || coalesce(v ->> 'err', '') || coalesce(v ->> 'msg', ''));
  perform pg_temp.ck((select total_gross from booking.orders where id = o1) = v_new, 'H2: tilauksen summa päivittyi');
  perform pg_temp.ck((select sum(amount) from booking.refunds where order_id = o1 and status = 'done') = v_diff, 'H3: hyvitys kirjattu (käsin/korttipääte → done)');
  perform pg_temp.ck((select (booking._order_balance(o1) ->> 'net_paid')::numeric) = v_new, 'H4: maksettu netto = uusi summa');
  perform pg_temp.ck((v ->> 'notified')::boolean and exists (select 1 from booking.email_outbox where order_id = o1 and kind = 'order_change'), 'H5: order_change jonossa');
  perform pg_temp.ck(test.audit_n('ADMIN_CHANGE_REFUND') >= 1, 'H6: audit');
  perform pg_temp.ck((select sum((x ->> 'amount')::numeric) from booking.refunds f, jsonb_array_elements(f.lines) x where f.order_id = o1) = v_diff, 'H7: kohdistus maksuriveille = hyvitys');
  -- toisto: ei enää ylisuoritusta
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2, false, false, null, null, %s, %L, false)', r1, v_diff, 'toisto'));
  perform pg_temp.ck(v ->> 'err' = 'nothing_to_refund', 'I1: toisto samalla tilalla ei hyvitä uudestaan ' || coalesce(v ->> 'err', v::text));

  -- ===== monimaksu: lahjakortti 20 € + Montonio (requested) =====
  o2 := pg_temp.mk(v_rule, d + 7, 3, 'b@t282.example', 'montonio', 20, 'HHGCAAA28201');
  select id into r2 from booking.reservations where order_id = o2;
  select total_gross into v_tot from booking.orders where id = o2;
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking_preview(%s, null, null, 2, null)', r2));
  v_diff := v_tot - (v ->> 'new_total')::numeric;
  perform pg_temp.ck((v ->> 'refundable_max')::numeric = v_diff and (v ->> 'non_refundable_amount')::numeric = 0, 'M1: lahjakortti kattaa ensin, raha hyvitetään ' || v::text);
  perform pg_temp.ck(jsonb_array_length(v -> 'refund_plan') = 1 and v -> 'refund_plan' -> 0 ->> 'provider' = 'montonio', 'M2: suunnitelma vain Montonio-maksulle');
  perform pg_temp.ck(jsonb_array_length(v -> 'non_refundable') = 1 and v -> 'non_refundable' -> 0 ->> 'kind' = 'gift_card', 'M3: lahjakortti listattu ei-hyvitettäväksi');
  w := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2, false, false, null, null, %s, %L, false)', r2, (v ->> 'refundable_max')::numeric, 'Montonio osa'));
  perform pg_temp.ck((w ->> 'ok')::boolean, 'M4: muutos + Montonio-hyvitys ' || coalesce(w ->> 'err', '') || coalesce(w ->> 'msg', ''));
  perform pg_temp.ck((select count(*) from booking.refunds where order_id = o2 and status = 'requested' and provider = 'montonio') = 1, 'M5: Montonio-hyvitys tilassa requested (Edge käsittelee)');
  perform pg_temp.ck((select balance from booking.gift_cards where code = 'HHGCAAA28201') = 0, 'M6: lahjakorttia ei palautettu');
  perform pg_temp.ck(not exists (select 1 from booking.refunds where order_id = o2 and payment_id in (select id from booking.payments where gift_card_id is not null)), 'M7: ei hyvitystä lahjakorttimaksulle');
  -- käsittelyssä oleva hyvitys vähentää hyvitettävää (samanaikaisuus/toisto)
  w := pg_temp.as_(u_adm, format('select booking.admin_change_booking_preview(%s, null, null, 2, null)', r2));
  perform pg_temp.ck((w ->> 'refundable_max')::numeric = 0 and (w ->> 'overpaid_after')::numeric = 0, 'M8: pending-hyvitys huomioitu, ei kaksoishyvitystä ' || w::text);
  -- lahjakortti kattaa suurimman osan: raha hyvitetään vain ylimenevältä osalta
  o4 := pg_temp.mk(v_rule, d + 21, 3, 'd@t282.example', 'montonio', 80, 'HHGCAAA28202');
  select id into r4 from booking.reservations where order_id = o4;
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking_preview(%s, null, null, 2, null)', r4));
  perform pg_temp.ck((v ->> 'refundable_max')::numeric = 7 and (v ->> 'non_refundable_amount')::numeric = 22 and (v ->> 'overpaid_after')::numeric = 29, 'M9: lahjakortti 80 € kattaa; rahaa hyvitettävissä vain 7 € ' || v::text);
  -- laskulukko
  o3 := pg_temp.mk(v_rule, d + 14, 3, 'c@t282.example', 'card_terminal');
  select id into r3 from booking.reservations where order_id = o3;
  insert into booking.invoice_customers(company_name) values ('T282 Oy');
  insert into booking.invoices(order_id, customer_id, kind, status, due_date, seller_snapshot, customer_snapshot) select o3, (select max(id) from booking.invoice_customers), 'debit', 'sent', current_date + 14, '{}'::jsonb, '{}'::jsonb;
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, null, null, 2, false, false, null, null, 5, %L, false)', r3, 'laskulukko'));
  perform pg_temp.ck(v ->> 'err' in ('order_invoiced', 'invalid_amount') , 'LL: laskutettu → hyvitys estetty ' || coalesce(v ->> 'err', v::text));

  create temp table t282_out as select * from t282_r;
end $t$;
select 'RESULT ' || case when ok then 'ok' else 'NOT OK' end || ' - ' || label from t282_r;
select 'SUMMARY ' || count(*) filter (where not ok) || ' failed / ' || count(*) from t282_r;
rollback;
