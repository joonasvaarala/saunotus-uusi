-- t190: asiakkaan lisäys vahvistettuun tilaukseen on 15 min pito; vanhentunut kassapito lähettää yhden viestin.
-- Aja migraation 20261028030913 ja fixtures/10_test_helpers.sql jälkeen. Yksi transaktio, kaikki kumoutuu.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table t190_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  insert into t190_r values (coalesce(p_ok, false), p_label) $$;
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
do $t$
declare
  v_mode text; v_mins int;
  vrule bigint; dt date; mgr uuid;
  b jsonb; v jsonb; tok uuid; oid bigint; res bigint; addon bigint;
  item bigint; hold timestamptz; total0 numeric; n int; em booking.email_outbox;
  slots timestamptz[]; r record; t_oid bigint; t_tok uuid; t_item bigint; t_res bigint;
begin
  select mode into v_mode from booking.integration_config where key = 'resend';
  update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode';
  update booking.settings set value = '0'::jsonb where key = 'checkout_group_threshold_persons';
  v_mins := booking._checkout_hold_minutes();
  perform pg_temp.ck(v_mins between 1 and 60, 'S1: checkout_hold_minutes ' || v_mins::text);
  vrule := test.rule('Miesten sauna%');
  dt := test.next_dow(1) + 140;
  mgr := test.mk_staff('manager@t190.example.test', 'manager');

  -- A) lisäpalvelu vahvistettuun tilaukseen: pito, peruutus, vanheneminen, maksettu säilyy, henkilökunta ei
  b := test.pub_book(vrule, dt, 2, 'a@t190.example.test');
  perform pg_temp.ck((b ->> 'ok')::boolean, 'A0: varaus (' || coalesce(b ->> 'code', '') || ')');
  tok := (b ->> 'token')::uuid;
  oid := (test.ord(tok)).id;
  select id into res from booking.reservations where order_id = oid order by id limit 1;
  v := pg_temp.as_(mgr, format('select booking.admin_record_payment(%s, %L, %s, null, null)', oid, 'card_terminal', (select total_gross from booking.orders where id = oid)));
  perform pg_temp.ck(v ->> 'ok' = 'true' and (select status from booking.orders where id = oid) = 'confirmed', 'A1: tilaus maksettu ja vahvistettu (' || coalesce(v ->> 'err', '') || ')');
  select id into addon from booking.addons where code = 'pyyhe' and active;
  perform pg_temp.ck(addon is not null, 'A2: pyyhe löytyy');
  perform test.anon('203.0.113.190');
  v := booking.public_add_to_order(tok, jsonb_build_array(jsonb_build_object('type', 'addon', 'code', 'pyyhe', 'quantity', 1, 'reservation_id', res)));
  perform test.logout();
  perform pg_temp.ck(v ->> 'ok' = 'true', 'A3: asiakas lisäsi pyyhkeen (' || coalesce(v ->> 'code', v ->> 'message', '') || ')');
  select i.id, i.hold_expires_at into item, hold
    from booking.order_items i
   where i.order_id = oid and i.addon_id = addon and i.kind = 'addon'
   order by i.id desc limit 1;
  perform pg_temp.ck(item is not null and hold between now() + make_interval(mins => v_mins - 1) and now() + make_interval(mins => v_mins + 1), 'A4: lisäyksellä ' || v_mins::text || ' min pito');
  perform pg_temp.ck((select status from booking.reservations where id = res) = 'confirmed' and (select status from booking.orders where id = oid) = 'confirmed', 'A5: alkuperäinen varaus ja tilaus pysyvät vahvistettuina');
  perform pg_temp.ck(jsonb_array_length(coalesce(booking.public_get_order(tok) -> 'pending_additions', '[]'::jsonb)) = 1, 'A6: tilaussivu näyttää maksamattoman lisäyksen');

  perform test.anon('203.0.113.191');
  v := booking.public_cancel_addition(tok, item);
  perform test.logout();
  perform pg_temp.ck(v ->> 'ok' = 'true' and not exists (select 1 from booking.order_items where id = item), 'A7: Peru lisätilaus vapauttaa heti (' || coalesce(v ->> 'code', '') || ')');
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'confirmed' and (select status from booking.reservations where id = res) = 'confirmed', 'A8: peruutus ei koske alkuperäistä varausta');
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = oid and kind = 'unpaid_booking_cancelled'), 'A9: lisäyksen peruutus ei lähetä varausviestiä');

  perform test.anon('203.0.113.192');
  v := booking.public_add_to_order(tok, jsonb_build_array(jsonb_build_object('type', 'addon', 'code', 'pyyhe', 'quantity', 1, 'reservation_id', res)));
  perform test.logout();
  select i.id into item from booking.order_items i where i.order_id = oid and i.addon_id = addon order by i.id desc limit 1;
  update booking.order_items set hold_expires_at = now() - interval '1 minute' where id = item;
  perform booking.expire_holds();
  perform pg_temp.ck(not exists (select 1 from booking.order_items where id = item), 'A10: 15 min jälkeen cron vapauttaa maksamattoman lisäyksen');
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'confirmed' and (select status from booking.reservations where id = res) = 'confirmed', 'A11: cron ei peru alkuperäistä tilausta');

  perform test.anon('203.0.113.193');
  v := booking.public_add_to_order(tok, jsonb_build_array(jsonb_build_object('type', 'addon', 'code', 'pyyhe', 'quantity', 1, 'reservation_id', res)));
  perform test.logout();
  select i.id, i.line_total_gross into item, total0 from booking.order_items i where i.order_id = oid and i.addon_id = addon order by i.id desc limit 1;
  v := pg_temp.as_(mgr, format('select booking.admin_record_payment(%s, %L, %s, null, null)', oid, 'card_terminal', total0));
  perform pg_temp.ck(v ->> 'ok' = 'true' and (select hold_expires_at from booking.order_items where id = item) is null, 'A12: maksetulta lisäykseltä pito poistuu (' || coalesce(v ->> 'err', '') || ')');
  update booking.order_items set hold_expires_at = now() - interval '1 minute' where id = item;
  perform booking.expire_holds();
  perform pg_temp.ck(exists (select 1 from booking.order_items where id = item), 'A13: maksettua lisäystä ei vapauteta');
  update booking.order_items set hold_expires_at = null where id = item;

  v := pg_temp.as_(mgr, format('select booking.admin_add_to_order(%s, %L::jsonb, false, false, null)', oid,
    jsonb_build_array(jsonb_build_object('type', 'addon', 'reservation_id', res, 'code', 'saunavihta', 'quantity', 1))::text));
  perform pg_temp.ck(v ->> 'ok' = 'true' or v ? 'added', 'A14: henkilökunnan lisäys (' || coalesce(v ->> 'err', left(v::text, 120)) || ')');
  perform pg_temp.ck(not exists (
    select 1 from booking.order_items i join booking.addons a on a.id = i.addon_id
     where i.order_id = oid and a.code = 'saunavihta' and i.hold_expires_at is not null), 'A15: henkilökunnan lisäyksellä ei ole pitoa');

  -- B) hoito: kapasiteetti pidossa ja vapautuu
  for r in select q.starts_at from (
      select * from booking.public_treatment_availability(11, current_date + 40, current_date + 55, 1)
      union all select * from booking.public_treatment_availability(11, current_date + 56, current_date + 70, 1)) q
     where q.status = 'available' order by q.starts_at loop
    if slots is null or r.starts_at >= slots[cardinality(slots)] + interval '4 hours' then slots := array_append(slots, r.starts_at); end if;
    exit when slots is not null and cardinality(slots) >= 6;
  end loop;
  if slots is null or cardinality(slots) < 6 then
    raise exception 'TESTRESULT_ABORT vapaita hoitoaikoja %', coalesce(cardinality(slots), 0);
  end if;
  perform test.anon('203.0.113.194');
  v := booking.public_add_to_order(tok, jsonb_build_array(jsonb_build_object('type', 'reservation', 'product_id', 11, 'persons', 1, 'start', slots[1])));
  perform test.logout();
  perform pg_temp.ck(v ->> 'ok' = 'true', 'B1: hoito lisätty (' || coalesce(v ->> 'code', v ->> 'message', '') || ')');
  select r.id, r.order_item_id, r.hold_expires_at into t_res, t_item, hold
    from booking.reservations r where r.order_id = oid and r.product_id = 11 order by r.id desc limit 1;
  perform pg_temp.ck(t_res is not null and (select status from booking.reservations where id = t_res) = 'pending'
    and hold between now() + make_interval(mins => v_mins - 1) and now() + make_interval(mins => v_mins + 1), 'B2: hoidon varaus on pending-pito');
  perform test.anon('203.0.113.195');
  b := booking.public_create_treatment_booking(11, slots[1], 1, 'Toinen', 'b2@t190.example.test', '+358401112233', false, 'fi', null, 'private', null, null);
  perform test.logout();
  perform pg_temp.ck(not coalesce((b ->> 'ok')::boolean, false), 'B3: sama aika ei ole vapaana pidon aikana (' || coalesce(b ->> 'code', 'ok') || ')');
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where id = t_res;
  update booking.order_items set hold_expires_at = now() - interval '1 minute' where id = t_item;
  perform booking.expire_holds();
  perform pg_temp.ck((select status from booking.reservations where id = t_res) = 'cancelled'
    and (select cancel_reason from booking.reservations where id = t_res) = 'hold_expired'
    and not exists (select 1 from booking.order_items where id = t_item), 'B4: hoidon pito vanheni ja rivi poistui');
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'confirmed', 'B5: tilaus jäi vahvistetuksi');
  perform test.anon('203.0.113.196');
  b := booking.public_create_treatment_booking(11, slots[1], 1, 'Kolmas', 'b3@t190.example.test', '+358401112244', false, 'fi', null, 'private', null, null);
  perform test.logout();
  perform pg_temp.ck((b ->> 'ok')::boolean, 'B6: aika on taas varattavissa (' || coalesce(b ->> 'code', '') || ')');

  -- C) koko tilauksen pito vanhenee: yksi viesti, rajaukset
  perform test.anon('203.0.113.197');
  b := booking.public_create_treatment_booking(11, slots[2], 1, 'Viesti', 'c1@t190.example.test', '+358401112255', false, 'en', null, 'private', null, null);
  perform test.logout();
  perform pg_temp.ck((b ->> 'ok')::boolean and b ->> 'checkout_state' = 'awaiting_payment', 'C1: kassapito (' || coalesce(b ->> 'code', b ->> 'status', '') || ')');
  t_tok := (b ->> 'token')::uuid;
  t_oid := (select id from booking.orders where public_token = t_tok);
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = t_oid;
  perform booking.expire_holds();
  perform pg_temp.ck((select status from booking.orders where id = t_oid) = 'cancelled', 'C2: tilaus cancelled');
  select * into em from booking.email_outbox where order_id = t_oid and kind = 'unpaid_booking_cancelled';
  perform pg_temp.ck(em.id is not null and em.dedupe_key = 'unpaid_booking_cancelled:' || t_oid::text and em.locale = 'en', 'C3: yksi viesti, asiakkaan kieli');
  perform pg_temp.ck(em.payload ->> 'retry_url' like '%/en/book/#/tuote/%', 'C4: Yritä uudelleen vie tuotteen sivulle (' || coalesce(em.payload ->> 'retry_url', '') || ')');
  perform pg_temp.ck(em.status = case when coalesce(v_mode, 'off') = 'off' then 'skipped' else 'pending' end, 'C5: tila seuraa resend.mode=' || coalesce(v_mode, 'off'));
  perform booking._enqueue_unpaid_booking_email(t_oid);
  perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = t_oid and kind = 'unpaid_booking_cancelled') = 1, 'C6: ei toista viestiä');

  perform test.anon('203.0.113.198');
  b := booking.public_create_treatment_booking(11, slots[3], 1, 'Johku', 'c2@t190.example.test', '+358401112266', false, 'fi', null, 'private', null, null);
  perform test.logout();
  t_oid := (select id from booking.orders where public_token = (b ->> 'token')::uuid);
  update booking.orders set external_source = 'johku', external_id = 't190-johku' where id = t_oid;
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = t_oid;
  perform booking.expire_holds();
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = t_oid and kind = 'unpaid_booking_cancelled'), 'C7: Johku-historiaan ei viestiä');

  perform test.anon('203.0.113.199');
  b := booking.public_create_treatment_booking(11, slots[4], 1, 'Henkilokunta', 'c3@t190.example.test', '+358401112277', false, 'fi', null, 'private', null, null);
  perform test.logout();
  t_oid := (select id from booking.orders where public_token = (b ->> 'token')::uuid);
  update booking.orders set source_channel = 'admin' where id = t_oid;
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = t_oid;
  perform booking.expire_holds();
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = t_oid and kind = 'unpaid_booking_cancelled'), 'C8: henkilökunnan tilaukseen ei viestiä');

  perform test.anon('203.0.113.200');
  b := booking.public_create_treatment_booking(11, slots[5], 1, 'Lasku', 'c4@t190.example.test', '+358401112288', false, 'fi', null, 'private', null, null);
  perform test.logout();
  t_oid := (select id from booking.orders where public_token = (b ->> 'token')::uuid);
  update booking.orders set billing = jsonb_build_object('invoice_method', 'pdf') where id = t_oid;
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = t_oid;
  perform booking.expire_holds();
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = t_oid and kind = 'unpaid_booking_cancelled'), 'C9: laskutilaukseen ei viestiä');

  perform test.anon('203.0.113.201');
  b := booking.public_create_treatment_booking(11, slots[6], 1, 'Osoite', 'c5@t190.example.test', '+358401112299', false, 'fi', null, 'private', null, null);
  perform test.logout();
  t_oid := (select id from booking.orders where public_token = (b ->> 'token')::uuid);
  update booking.customers set email = 'a@b.c' where id = (select customer_id from booking.orders where id = t_oid);
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = t_oid;
  perform booking.expire_holds();
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = t_oid and kind = 'unpaid_booking_cancelled'), 'C10: kelvoton osoite ei jonoon');

  select count(*) into n from t190_r where not ok;
  if n > 0 then
    raise exception 'TESTRESULT fail=% pass=% %', n, (select count(*) from t190_r where ok),
      (select string_agg(label, ' | ') from t190_r where not ok);
  end if;
  raise notice 'TESTRESULT pass=% fail=0', (select count(*) from t190_r);
end $t$;
rollback;
