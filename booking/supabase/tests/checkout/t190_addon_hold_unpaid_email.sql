-- t190: asiakkaan lisäys vahvistettuun tilaukseen on 15 min pito; vanhentunut kassapito lähettää yhden viestin.
-- Ajetaan kuten muut kassatestit (t53, t70): psql -X -1 -v ON_ERROR_STOP=1 -f t190_addon_hold_unpaid_email.sql
-- mock-kb + migraatiot riittävät. Ei test-skeeman apureita eikä paikallista fixture-kantaa.
-- Hoitoajat pysyvät public_treatment_horizon_days- ja 14 päivän kyselyrajassa. Lopun TESTRESULT-poikkeus kumoaa transaktion.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table t190_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  insert into t190_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;
create function pg_temp.as_admin(p_uid uuid, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb; d text;
begin
  perform pg_temp.login(p_uid);
  begin
    execute 'select (' || p_sql || ')::jsonb' into v;
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(nullif(d, ''), sqlstate), 'msg', sqlerrm);
  end;
  perform pg_temp.logout();
  return v;
end $$;

do $t$
declare
  v_mode text; v_mins int;
  v_rule bigint; v_rdate date; u_adm uuid := gen_random_uuid();
  b jsonb; v jsonb; tok uuid; oid bigint; res bigint; addon bigint; vihta bigint;
  item bigint; hold timestamptz; hold2 timestamptz; total0 numeric; n int;
  mail booking.email_outbox; claimed jsonb;
  slots timestamptz[]; slot_row record;
  t_oid bigint; t_tok uuid; t_item bigint; t_res bigint;
begin
  select mode into v_mode from booking.integration_config where key = 'resend';
  update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode';
  update booking.settings set value = '0'::jsonb where key = 'checkout_group_threshold_persons';
  update booking.integration_config set mode = 'test', settings = coalesce(settings, '{}'::jsonb) || '{"approved_by":"t190"}'::jsonb where key = 'mobilepay';
  insert into booking.integration_config(key, mode, settings) values ('montonio', 'test', '{"approved_by":"t190"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = booking.integration_config.settings || '{"approved_by":"t190"}'::jsonb;
  v_mins := booking._checkout_hold_minutes();
  perform pg_temp.ck(v_mins between 1 and 60, 'S1: checkout_hold_minutes ' || v_mins::text);

  insert into auth.users(id, email) values (u_adm, 't190-admin@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_adm, 't190-admin@example.test', 't190 admin', 'admin');

  -- yleinen vuoro 14 päivän sisällä (ei test.rule / test.next_dow + 140, joka ylittää varaushorisontin)
  select a.rule_id, a.session_date into v_rule, v_rdate
    from booking.public_availability(3, current_date + 1, current_date + 14) a
   where a.status = 'available' and a.session_date <= current_date + 14
   order by a.session_date
   limit 1;
  perform pg_temp.ck(v_rule is not null, 'S2: yleinen vuoro löytyi');

  -- hoitoajat: kyselyväli enintään 14 päivää ja horisontin sisällä (public_treatment_horizon_days)
  for slot_row in
    select q.starts_at
      from booking.public_treatment_availability(11, current_date + 1, current_date + 14, 1) q
     where q.status = 'available'
     order by q.starts_at
  loop
    if slots is null or slot_row.starts_at >= slots[cardinality(slots)] + interval '4 hours' then
      slots := array_append(slots, slot_row.starts_at);
    end if;
    exit when slots is not null and cardinality(slots) >= 6;
  end loop;
  if slots is null or cardinality(slots) < 6 then
    raise exception 'TESTRESULT_ABORT vapaita hoitoaikoja %', coalesce(cardinality(slots), 0);
  end if;

  -- A) lisäpalvelu vahvistettuun tilaukseen: pito, peruutus, vanheneminen, maksettu säilyy, henkilökunta ei
  b := booking.public_create_booking(v_rule, v_rdate, 2, 'Testi Asiakas', 'a@t190.example.test', '+358401112200');
  perform pg_temp.ck((b ->> 'ok')::boolean and b ->> 'checkout_state' = 'awaiting_payment', 'A0: varaus (' || coalesce(b ->> 'code', b ->> 'status', '') || ')');
  tok := (b ->> 'token')::uuid;
  oid := (select id from booking.orders where public_token = tok);
  select id into res from booking.reservations where order_id = oid order by id limit 1;
  v := pg_temp.as_admin(u_adm, format('booking.admin_record_payment(%s, %L, %s, null, null)', oid, 'card_terminal', (select total_gross from booking.orders where id = oid)));
  perform pg_temp.ck(v ->> 'ok' = 'true' and (select status from booking.orders where id = oid) = 'confirmed', 'A1: tilaus maksettu ja vahvistettu (' || coalesce(v ->> 'err', v ->> 'msg', '') || ')');
  select id into addon from booking.addons where code = 'pyyhe' and active;
  perform pg_temp.ck(addon is not null, 'A2: pyyhe löytyy');
  v := booking.public_add_to_order(tok, jsonb_build_array(jsonb_build_object('type', 'addon', 'code', 'pyyhe', 'quantity', 1, 'reservation_id', res)));
  perform pg_temp.ck(v ->> 'ok' = 'true', 'A3: asiakas lisäsi pyyhkeen (' || coalesce(v ->> 'code', v ->> 'message', '') || ')');
  select i.id, i.hold_expires_at into item, hold
    from booking.order_items i
   where i.order_id = oid and i.addon_id = addon and i.kind = 'addon'
   order by i.id desc limit 1;
  perform pg_temp.ck(item is not null and hold between now() + make_interval(mins => v_mins - 1) and now() + make_interval(mins => v_mins + 1), 'A4: lisäyksellä ' || v_mins::text || ' min pito');
  perform pg_temp.ck((select status from booking.reservations where id = res) = 'confirmed' and (select status from booking.orders where id = oid) = 'confirmed', 'A5: alkuperäinen varaus ja tilaus pysyvät vahvistettuina');
  perform pg_temp.ck(jsonb_array_length(coalesce(booking.public_get_order(tok) -> 'pending_additions', '[]'::jsonb)) = 1, 'A6: tilaussivu näyttää maksamattoman lisäyksen');
  perform pg_temp.ck(jsonb_array_length(coalesce(booking.public_get_booking(tok) -> 'pending_additions', '[]'::jsonb)) = 1, 'A6b: vahvistussivu näyttää saman lisäyksen');

  -- uusi varaus, kun lisäyksen pito on yhä rivillä: tämä on se polku, jonka DISTINCT FOR UPDATE kaatoi
  b := booking.public_create_treatment_booking(11, slots[6], 1, 'Sivu', 'a-side@t190.example.test', '+358401112201', false, 'fi', null, 'private', null, null);
  perform pg_temp.ck((b ->> 'ok')::boolean, 'A6c: uusi varaus onnistuu, vaikka lisäyksen pito on auki (' || coalesce(b ->> 'code', '') || ')');
  update booking.reservations set hold_expires_at = now() - interval '1 minute'
   where order_id = (select id from booking.orders where public_token = (b ->> 'token')::uuid);
  perform booking.expire_holds();
  perform pg_temp.ck(exists (select 1 from booking.order_items where id = item), 'A6d: toisen tilauksen vanheneminen ei vapauta tämän lisäystä');

  v := booking.public_cancel_addition(tok, item);
  perform pg_temp.ck(v ->> 'ok' = 'true' and not exists (select 1 from booking.order_items where id = item), 'A7: Peru lisätilaus vapauttaa heti (' || coalesce(v ->> 'code', '') || ')');
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'confirmed' and (select status from booking.reservations where id = res) = 'confirmed', 'A8: peruutus ei koske alkuperäistä varausta');
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = oid and kind = 'unpaid_booking_cancelled'), 'A9: lisäyksen peruutus ei lähetä varausviestiä');

  v := booking.public_upsell_add(tok, jsonb_build_object('type', 'addon', 'addon_id', addon, 'quantity', 1, 'reservation_id', res), gen_random_uuid(), null);
  perform pg_temp.ck(v ->> 'ok' = 'true', 'A10a: vahvistussivun lisäys (' || coalesce(v ->> 'code', '') || ')');
  select i.id into item from booking.order_items i where i.order_id = oid and i.addon_id = addon order by i.id desc limit 1;
  update booking.order_items set hold_expires_at = now() - interval '1 minute' where id = item;
  perform booking.expire_holds();
  perform pg_temp.ck(not exists (select 1 from booking.order_items where id = item), 'A10: 15 min jälkeen cron vapauttaa maksamattoman lisäyksen');
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'confirmed' and (select status from booking.reservations where id = res) = 'confirmed', 'A11: cron ei peru alkuperäistä tilausta');

  v := booking.public_add_to_order(tok, jsonb_build_array(jsonb_build_object('type', 'addon', 'code', 'pyyhe', 'quantity', 1, 'reservation_id', res)));
  perform pg_temp.ck(v ->> 'ok' = 'true', 'A12a: pyyhe uudelleen (' || coalesce(v ->> 'code', '') || ')');
  select i.id, i.line_total_gross, i.hold_expires_at into item, total0, hold
    from booking.order_items i where i.order_id = oid and i.addon_id = addon order by i.id desc limit 1;
  perform booking._checkout_extend_hold(oid);
  select hold_expires_at into hold2 from booking.order_items where id = item;
  perform pg_temp.ck(hold2 is not null and hold2 >= hold, 'A12b: maksun aloitus jatkaa lisäyksen pitoa');
  v := pg_temp.as_admin(u_adm, format('booking.admin_record_payment(%s, %L, %s, null, null)', oid, 'card_terminal', total0));
  perform pg_temp.ck(v ->> 'ok' = 'true' and (select hold_expires_at from booking.order_items where id = item) is null, 'A12: maksetulta lisäykseltä pito poistuu (' || coalesce(v ->> 'err', v ->> 'msg', '') || ')');
  update booking.order_items set hold_expires_at = now() - interval '1 minute' where id = item;
  perform booking.expire_holds();
  perform pg_temp.ck(exists (select 1 from booking.order_items where id = item), 'A13: maksettua lisäystä ei vapauteta');
  update booking.order_items set hold_expires_at = null where id = item;

  select id into vihta from booking.addons where code = 'saunavihta' and active;
  v := pg_temp.as_admin(u_adm, format('booking.admin_add_to_order(%s, %L::jsonb, false, false, null)', oid,
    jsonb_build_array(jsonb_build_object('type', 'addon', 'reservation_id', res, 'code', 'saunavihta', 'quantity', 1))::text));
  perform pg_temp.ck(v ->> 'ok' = 'true', 'A14: henkilökunnan lisäys (' || coalesce(v ->> 'err', v ->> 'msg', left(v::text, 160)) || ')');
  perform pg_temp.ck(vihta is not null and not exists (
    select 1 from booking.order_items i
     where i.order_id = oid and i.addon_id = vihta and i.hold_expires_at is not null), 'A15: henkilökunnan lisäyksellä ei ole pitoa');

  -- B) hoito: kapasiteetti pidossa ja vapautuu
  v := booking.public_add_to_order(tok, jsonb_build_array(jsonb_build_object('type', 'reservation', 'product_id', 11, 'persons', 1, 'start', slots[1])));
  perform pg_temp.ck(v ->> 'ok' = 'true', 'B1: hoito lisätty (' || coalesce(v ->> 'code', v ->> 'message', '') || ')');
  select rv.id, rv.order_item_id, rv.hold_expires_at into t_res, t_item, hold
    from booking.reservations rv
   where rv.order_id = oid and rv.product_id = 11
   order by rv.id desc limit 1;
  perform pg_temp.ck(t_res is not null and (select status from booking.reservations where id = t_res) = 'pending'
    and hold between now() + make_interval(mins => v_mins - 1) and now() + make_interval(mins => v_mins + 1), 'B2: hoidon varaus on pending-pito');
  b := booking.public_create_treatment_booking(11, slots[1], 1, 'Toinen', 'b2@t190.example.test', '+358401112233', false, 'fi', null, 'private', null, null);
  perform pg_temp.ck(not coalesce((b ->> 'ok')::boolean, false), 'B3: sama aika ei ole vapaana pidon aikana (' || coalesce(b ->> 'code', 'ok') || ')');
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where id = t_res;
  update booking.order_items set hold_expires_at = now() - interval '1 minute' where id = t_item;
  perform booking.expire_holds();
  perform pg_temp.ck((select status from booking.reservations where id = t_res) = 'cancelled'
    and (select cancel_reason from booking.reservations where id = t_res) = 'hold_expired'
    and not exists (select 1 from booking.order_items where id = t_item), 'B4: hoidon pito vanheni ja rivi poistui');
  perform pg_temp.ck((select status from booking.orders where id = oid) = 'confirmed', 'B5: tilaus jäi vahvistetuksi');
  b := booking.public_create_treatment_booking(11, slots[1], 1, 'Kolmas', 'b3@t190.example.test', '+358401112244', false, 'fi', null, 'private', null, null);
  perform pg_temp.ck((b ->> 'ok')::boolean, 'B6: aika on taas varattavissa (' || coalesce(b ->> 'code', '') || ')');

  -- C) koko tilauksen pito vanhenee: yksi viesti, rajaukset
  b := booking.public_create_treatment_booking(11, slots[2], 1, 'Viesti', 'c1@t190.example.test', '+358401112255', false, 'en', null, 'private', null, null);
  perform pg_temp.ck((b ->> 'ok')::boolean and b ->> 'checkout_state' = 'awaiting_payment', 'C1: kassapito (' || coalesce(b ->> 'code', b ->> 'status', '') || ')');
  t_tok := (b ->> 'token')::uuid;
  t_oid := (select id from booking.orders where public_token = t_tok);
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = t_oid;
  perform booking.expire_holds();
  perform pg_temp.ck((select status from booking.orders where id = t_oid) = 'cancelled', 'C2: tilaus cancelled');
  select * into mail from booking.email_outbox where order_id = t_oid and kind = 'unpaid_booking_cancelled';
  perform pg_temp.ck(mail.id is not null and mail.dedupe_key = 'unpaid_booking_cancelled:' || t_oid::text and mail.locale = 'en', 'C3: yksi viesti, asiakkaan kieli');
  perform pg_temp.ck(mail.payload ->> 'retry_url' like '%/en/book/#/tuote/%', 'C4: Yritä uudelleen vie tuotteen sivulle (' || coalesce(mail.payload ->> 'retry_url', '') || ')');
  perform pg_temp.ck(mail.status = case when coalesce(v_mode, 'off') = 'off' then 'skipped' else 'pending' end, 'C5: tila seuraa resend.mode=' || coalesce(v_mode, 'off'));
  perform booking._enqueue_unpaid_booking_email(t_oid);
  perform pg_temp.ck((select count(*) from booking.email_outbox where order_id = t_oid and kind = 'unpaid_booking_cancelled') = 1, 'C6: ei toista viestiä');
  claimed := booking.email_outbox_claim(50);
  perform pg_temp.ck(exists (
    select 1 from jsonb_array_elements(claimed) e
     where e ->> 'kind' = 'unpaid_booking_cancelled'
       and e -> 'unpaid_booking' ->> 'retry_url' = mail.payload ->> 'retry_url'
       and e -> 'unpaid_booking' ->> 'product_name' is not null), 'C6b: claim liittää unpaid_booking-kentän');

  b := booking.public_create_treatment_booking(11, slots[3], 1, 'Johku', 'c2@t190.example.test', '+358401112266', false, 'fi', null, 'private', null, null);
  t_oid := (select id from booking.orders where public_token = (b ->> 'token')::uuid);
  update booking.orders set external_source = 'johku', external_id = 't190-johku' where id = t_oid;
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = t_oid;
  perform booking.expire_holds();
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = t_oid and kind = 'unpaid_booking_cancelled'), 'C7: Johku-historiaan ei viestiä');

  b := booking.public_create_treatment_booking(11, slots[4], 1, 'Henkilokunta', 'c3@t190.example.test', '+358401112277', false, 'fi', null, 'private', null, null);
  t_oid := (select id from booking.orders where public_token = (b ->> 'token')::uuid);
  update booking.orders set source_channel = 'admin' where id = t_oid;
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = t_oid;
  perform booking.expire_holds();
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = t_oid and kind = 'unpaid_booking_cancelled'), 'C8: henkilökunnan tilaukseen ei viestiä');

  b := booking.public_create_treatment_booking(11, slots[5], 1, 'Lasku', 'c4@t190.example.test', '+358401112288', false, 'fi', null, 'private', null, null);
  t_oid := (select id from booking.orders where public_token = (b ->> 'token')::uuid);
  update booking.orders set billing = jsonb_build_object('invoice_method', 'pdf') where id = t_oid;
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = t_oid;
  perform booking.expire_holds();
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = t_oid and kind = 'unpaid_booking_cancelled'), 'C9: laskutilaukseen ei viestiä');

  -- slots[6] käytettiin A6c:ssä ja vapautettiin. Sama aika käy kelvottoman osoitteen tilaukseen.
  b := booking.public_create_treatment_booking(11, slots[6], 1, 'Osoite', 'c5@t190.example.test', '+358401112299', false, 'fi', null, 'private', null, null);
  perform pg_temp.ck((b ->> 'ok')::boolean, 'C10a: aika vapaa sivutilauksen jälkeen (' || coalesce(b ->> 'code', '') || ')');
  t_oid := (select id from booking.orders where public_token = (b ->> 'token')::uuid);
  update booking.customers set email = 'a@b.c' where id = (select customer_id from booking.orders where id = t_oid);
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = t_oid;
  perform booking.expire_holds();
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox where order_id = t_oid and kind = 'unpaid_booking_cancelled'), 'C10: kelvoton osoite ei jonoon');

  select count(*) into n from t190_r where not ok;
  raise exception 'TESTRESULT pass=% fail=% :: %',
    (select count(*) from t190_r where ok), n,
    coalesce((select string_agg(label, ' | ') from t190_r where not ok), 'ALL OK');
end $t$;
