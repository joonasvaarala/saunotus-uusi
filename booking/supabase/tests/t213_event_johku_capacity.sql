-- t213: tapahtumakerran Johku-paikat (booking_213). Myydyt, kapasiteetti, julkinen tila, osallistujat, muokkausesteet, ei Tapio-allekirjoitusta.
-- Ajo (psql, paikallinen PG17, migraatiot ja fixtures/10_test_helpers.sql ajettu):
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=0 -f t213_event_johku_capacity.sql
-- Kaikki yhdessä transaktiossa; lopussa TESTRESULT kumoaa kaiken. Ei tuotantoon.
\if :{?tz}
\else
\set tz UTC
\endif
begin;
set local timezone = :'tz';
set local lock_timeout = '3s';
set local statement_timeout = '180s';
create temp table t213_r(ok boolean, label text);
grant all on t213_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t213_r values (coalesce(p_ok, false), p_label) $$;
grant execute on all functions in schema pg_temp to public;

\ir ../migrations/20261029072745_booking_213_event_johku_capacity.sql

update booking.settings set value = '400'::jsonb where key = 'booking_horizon_days';
update booking.settings set value = '"pay_later"'::jsonb where key = 'public_payment_mode';
update booking.settings set value = 'true'::jsonb where key = 'events.sale_enabled';

do $t$
declare
  u_mgr uuid := test.mk_staff('t213-mgr@example.test', 'manager');
  u_staff uuid := test.mk_staff('t213-staff@example.test', 'staff');
  d date := date '2027-05-04';
  res jsonb; j jsonb; v_rule bigint; v_rule2 bigint; v_jres bigint; v_jord bigint; v_pool bigint; v_pool2 bigint; v_peak_before int;
begin
  update booking.product_config set bookable = true, shop_visible = true, lifecycle = 'current', max_persons = 12, min_persons = 1 where product_id = 33;
  perform pg_temp.ck(not has_function_privilege('authenticated', 'booking._event_rule_res_ids(bigint)', 'execute')
    and not has_function_privilege('anon', 'booking._event_rule_res_ids(bigint)', 'execute'), 'A1: apufunktio ei ole julkinen');

  perform test.login(u_mgr);
  res := booking.admin_event_rule_upsert(null, 33, jsonb_build_object('date', d, 'start_time', '17:00', 'duration_minutes', 120, 'max_persons', 8));
  v_rule := (res ->> 'id')::bigint;
  res := booking.admin_event_rule_upsert(null, 33, jsonb_build_object('date', d, 'start_time', '20:00', 'duration_minutes', 60, 'max_persons', 4));
  v_rule2 := (res ->> 'id')::bigint;
  perform test.logout();
  select id into v_pool from booking.resources where code = 'event_rule_' || v_rule::text;
  select id into v_pool2 from booking.resources where code = 'event_rule_' || v_rule2::text;
  v_peak_before := booking._pool_peak(v_pool2, (d + time '20:00') at time zone 'Europe/Helsinki', (d + time '21:00') at time zone 'Europe/Helsinki');

  -- Johku-tuotu varaus: sama tuote, alku 1 min kerran jälkeen (kuten tuotannon 20.2.2027), ei rule_id:tä eikä poolia.
  perform test.anon('10.213.0.1');
  res := test.pub_book(v_rule, d, 3, 't213-johku@example.com', 'Johku Asiakas');
  perform test.logout();
  select r.id, r.order_id into v_jres, v_jord from booking.reservations r where r.rule_id = v_rule order by r.id desc limit 1;
  update booking.orders set external_source = 'johku', external_id = 't213-o1', status = 'confirmed' where id = v_jord;
  update booking.reservations
     set rule_id = null, pool_ids = '{}', external_source = 'johku', external_id = 't213-r1', status = 'confirmed', hold_expires_at = null,
         starts_at = starts_at + interval '1 minute', ends_at = ends_at + interval '1 minute'
   where id = v_jres;

  res := booking._event_rule_json(v_rule);
  perform pg_temp.ck((res ->> 'sold_persons')::int = 3 and (res ->> 'johku_persons')::int = 3 and (res ->> 'johku_count')::int = 1
    and (res ->> 'reservation_count')::int = 1 and (res ->> 'max_persons')::int = 8, 'B1: Johku-paikat näkyvät myytyinä (3 / 8)');
  j := (select to_jsonb(a) from booking.public_availability(33, d, d) a where a.rule_id = v_rule);
  perform pg_temp.ck(j ->> 'status' = 'available' and (j ->> 'remaining')::int = 5, 'B2: julkinen jäljellä 8 − 3 = 5');
  perform pg_temp.ck(booking._pool_peak(v_pool2, (d + time '20:00') at time zone 'Europe/Helsinki', (d + time '21:00') at time zone 'Europe/Helsinki') = v_peak_before
    and (select (to_jsonb(a) ->> 'remaining')::int from booking.public_availability(33, d, d) a where a.rule_id = v_rule2) = 4, 'B3: toinen kerta ei saa Johku-paikkoja');

  perform test.anon('10.213.0.2');
  begin res := test.pub_book(v_rule, d, 6, 't213-liikaa@example.com'); exception when others then res := '{}'::jsonb; end;
  perform test.logout();
  perform pg_temp.ck((res ->> 'token') is null and not exists (select 1 from booking.reservations r join booking.orders o on o.id = r.order_id
    join booking.customers c on c.id = o.customer_id where c.email = 't213-liikaa@example.com' and booking._res_active(r.status, r.hold_expires_at)), 'B4: 6 ei mahdu (5 jäljellä)');
  perform test.anon('10.213.0.3');
  res := test.pub_book(v_rule, d, 5, 't213-kauppa@example.com', 'Kauppa Asiakas');
  perform test.logout();
  perform pg_temp.ck((res ->> 'token') is not null, 'B5: 5 mahtuu');
  res := booking._event_rule_json(v_rule);
  j := (select to_jsonb(a) from booking.public_availability(33, d, d) a where a.rule_id = v_rule);
  perform pg_temp.ck((res ->> 'sold_persons')::int = 8 and (res ->> 'reservation_count')::int = 2 and j ->> 'status' = 'full' and (j ->> 'remaining')::int = 0, 'B6: täynnä 8 / 8');
  perform pg_temp.ck((select w.min_persons <= w.max_persons from booking._waitlist_party(v_rule) w), 'B7: jonon ryhmäkoko min <= max');

  perform test.login(u_staff);
  res := booking.admin_event_participants(33, v_rule);
  perform pg_temp.ck(jsonb_array_length(res) = 2
    and exists (select 1 from jsonb_array_elements(res) e where e ->> 'source' = 'johku' and e ->> 'name' = 'Johku Asiakas' and (e ->> 'rule_id')::bigint = v_rule and (e ->> 'persons')::int = 3)
    and exists (select 1 from jsonb_array_elements(res) e where e ->> 'source' = 'shop' and e ->> 'name' = 'Kauppa Asiakas'), 'C1: osallistujissa Johku ja kauppa');
  res := booking.admin_event_participants(33, null);
  perform pg_temp.ck((select count(*) from jsonb_array_elements(res) e where (e ->> 'rule_id')::bigint = v_rule) = 2, 'C2: kaikki kerrat: kerran rivit mukana kerran tunnuksella');
  res := booking.admin_event_participant_note_set(v_jres, 'Johku-muistio');
  perform test.logout();
  perform pg_temp.ck((res ->> 'ok')::boolean and exists (select 1 from booking.event_participant_notes where reservation_id = v_jres), 'C3: muistiinpano Johku-osallistujalle');

  perform test.login(u_mgr);
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_upsert(%s, null, '{"max_persons":7}'::jsonb)$q$, v_rule)) = 'max_below_sold', 'D1: max ei alle myydyn (Johku mukana)');
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_upsert(%s, null, '{"start_time":"18:00"}'::jsonb)$q$, v_rule)) = 'has_reservations', 'D2: Johku-kerran aikaa ei siirretä');
  res := booking.admin_event_rule_upsert(v_rule, null, '{"max_persons":10}'::jsonb);
  perform pg_temp.ck((res ->> 'max_persons')::int = 10 and (select capacity from booking.resources where id = v_pool) = 10
    and (select (to_jsonb(a) ->> 'remaining')::int from booking.public_availability(33, d, d) a where a.rule_id = v_rule) = 2, 'D3: kapasiteetin nosto: 10 − 8 = 2');
  res := booking.admin_event_message_send(33, v_rule, 'Muistutus', 'Ota pyyhe mukaan.\n\nTerveisin Anni', false);
  perform pg_temp.ck(res ->> 'signature' is null and (res ->> 'recipient_count')::int = 1 and res::text !~ 'Tapio', 'E1: ei Tapio-allekirjoitusta, Johku-tilaus ei saa viestiä');
  perform test.logout();

  update booking.reservations set status = 'cancelled', cancelled_at = now() where id = v_jres;
  res := booking._event_rule_json(v_rule);
  perform pg_temp.ck((res ->> 'sold_persons')::int = 5 and (res ->> 'johku_persons')::int = 0
    and (select (to_jsonb(a) ->> 'remaining')::int from booking.public_availability(33, d, d) a where a.rule_id = v_rule) = 5, 'F1: Johku-peruutus vapauttaa paikat');
  update booking.reservations set status = 'confirmed', cancelled_at = null, hidden_at = now() where id = v_jres;
  perform pg_temp.ck((booking._event_rule_json(v_rule) ->> 'johku_persons')::int = 0, 'F2: piilotettu Johku-varaus ei kohdistu');
end $t$;

do $$
declare n int; bad int; fl text;
begin
  select count(*) filter (where ok), count(*) filter (where not ok), string_agg(label, ' | ') filter (where not ok) into n, bad, fl from t213_r;
  raise exception 'TESTRESULT pass=% fail=% %', n, bad, coalesce(fl, '');
end $$;
