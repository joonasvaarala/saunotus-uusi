-- t202: tapahtumahallinta (booking_202). Osallistujat, muistiinpano, viesti, ajan siirto ja peruutus.
-- Ajo (psql, paikallinen PG17, migraatiot ja fixtures/10_test_helpers.sql ajettu):
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=0 -f t202_event_admin.sql
-- Kaikki yhdessä transaktiossa; lopussa TESTRESULT kumoaa kaiken. Ei tuotantoon. Migraatiota ei ajeta tästä työtilasta.
\if :{?tz}
\else
\set tz UTC
\endif
begin;
set local timezone = :'tz';
set local lock_timeout = '3s';
set local statement_timeout = '180s';
create temp table t202_r(ok boolean, label text);
grant all on t202_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t202_r values (coalesce(p_ok, false), p_label) $$;
grant execute on all functions in schema pg_temp to public;

\ir ../migrations/20261028183000_booking_202_event_admin.sql

update booking.settings set value = '400'::jsonb where key = 'booking_horizon_days';
update booking.settings set value = '"pay_later"'::jsonb where key = 'public_payment_mode';
update booking.settings set value = 'true'::jsonb where key = 'events.sale_enabled';

do $t$
declare
  u_mgr uuid := test.mk_staff('t202-mgr@example.test', 'manager');
  u_staff uuid := test.mk_staff('t202-staff@example.test', 'staff');
  d date := date '2027-05-03';
  res jsonb; v_rule bigint; v_res bigint; v_ord bigint; v_before int; v_after int; v_mail text;
begin
  update booking.product_config set bookable = true, shop_visible = true, lifecycle = 'current' where product_id = 33;
  perform pg_temp.ck((select relrowsecurity from pg_class where oid = 'booking.event_participant_notes'::regclass)
    and (select relrowsecurity from pg_class where oid = 'booking.event_messages'::regclass), 'A1: RLS päällä');
  perform pg_temp.ck(not has_table_privilege('authenticated', 'booking.event_participant_notes', 'select')
    and not has_table_privilege('anon', 'booking.event_messages', 'select'), 'A2: tauluja ei lueta suoraan');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_event_participants(bigint, bigint)', 'execute')
    and has_function_privilege('authenticated', 'booking.admin_event_message_send(bigint, bigint, text, text, boolean)', 'execute')
    and not has_function_privilege('authenticated', 'booking._event_message_blocked(text)', 'execute'), 'A3: RPC authenticatedille, apufunktio ei');

  perform test.login(u_staff);
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_upsert(null, 33, '{"date":"%s","start_time":"17:00","duration_minutes":120,"max_persons":8}'::jsonb)$q$, d)) = 'forbidden', 'B1: staff ei luo kertaa');
  perform test.logout();

  perform test.login(u_mgr);
  res := booking.admin_event_rule_upsert(null, 33, jsonb_build_object('date', d, 'start_time', '17:00', 'duration_minutes', 120, 'max_persons', 8));
  v_rule := (res ->> 'id')::bigint;
  perform test.logout();
  perform pg_temp.ck(v_rule is not null and (res ->> 'cancelled_at') is null, 'B2: kerta luotu');

  perform test.anon('10.202.0.1');
  res := test.pub_book(v_rule, d, 2, 't202-a@example.com');
  perform test.logout();
  perform pg_temp.ck((res ->> 'token') is not null, 'B3: lippu varattu');
  select r.id, r.order_id into v_res, v_ord from booking.reservations r where r.rule_id = v_rule and r.status in ('pending', 'confirmed') order by r.id limit 1;
  update booking.orders set customer_note = 'Tulen ystävän kanssa' where id = v_ord;

  perform test.login(u_staff);
  res := booking.admin_event_participants(33, v_rule);
  perform pg_temp.ck(jsonb_array_length(res) = 1 and res -> 0 ->> 'email' = 't202-a@example.com' and (res -> 0 ->> 'persons')::int = 2
    and res -> 0 ->> 'customer_note' = 'Tulen ystävän kanssa' and not (res -> 0 ? 'provider') and not (res -> 0 ? 'billing'), 'C1: osallistuja, ei välittäjää');
  res := booking.admin_event_participant_note_set(v_res, 'Ovi auki');
  perform pg_temp.ck(res ->> 'note' = 'Ovi auki', 'C2: muistiinpano');
  perform pg_temp.ck((booking.admin_event_participants(33, v_rule) -> 0 ->> 'staff_note') = 'Ovi auki', 'C3: muistiinpano näkyy listassa');
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_message_send(33, %s, 'Hei', 'Nähdään', true)$q$, v_rule)) = 'forbidden', 'C4: staff ei lähetä');
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_occurrence_cancel(%s)$q$, v_rule)) = 'forbidden', 'C5: staff ei peru');
  perform test.logout();

  perform test.login(u_mgr);
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_upsert(%s, null, '{"active":false}'::jsonb)$q$, v_rule)) = 'has_reservations', 'D1: passivointi estetty');
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_delete(%s)$q$, v_rule)) = 'has_reservations', 'D2: poisto estetty');
  res := booking.admin_event_rule_upsert(v_rule, null, '{"start_time":"18:00"}'::jsonb);
  perform pg_temp.ck((res ->> 'start_time') = '18:00' and (res ->> 'moved_bookings')::int >= 1, 'D3: aika siirtyy ja varaukset mukana');
  perform pg_temp.ck((select to_char(starts_at at time zone 'Europe/Helsinki', 'HH24:MI') from booking.reservations where id = v_res) = '18:00', 'D4: varauksen kello on 18:00');
  res := booking.admin_event_message_send(33, v_rule, 'Muistutus', 'Ota pyyhe mukaan.', false);
  perform pg_temp.ck((res ->> 'sent')::boolean = false and (res ->> 'recipient_count')::int = 1 and res ->> 'signature' = 'Tapio'
    and not (res::text ~* 'montonio|visma|paybyway'), 'E1: esikatselu ei lähetä');
  select count(*) into v_before from booking.email_outbox where kind = 'event_message';
  res := booking.admin_event_message_send(33, v_rule, 'Muistutus', 'Ota pyyhe mukaan.', true);
  select count(*) into v_after from booking.email_outbox where kind = 'event_message';
  perform pg_temp.ck((res ->> 'sent')::boolean and v_after = v_before + 1 and (res ->> 'queued_count')::int + (res ->> 'skipped_count')::int >= 1, 'E2: yksi jonorivi');
  select e.payload::text into v_mail from booking.email_outbox e where e.kind = 'event_message' order by e.id desc limit 1;
  perform pg_temp.ck(v_mail like '%Ota pyyhe mukaan.%' and v_mail !~* 'montonio|visma|paybyway|mobilepay', 'E3: payloadissa ei välittäjää');
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_message_send(33, %s, 'Hei', 'Maksu Montonio', true)$q$, v_rule)) = 'provider_name', 'E4: välittäjän nimi hylätään');
  res := booking.admin_event_messages_list(33);
  perform pg_temp.ck(jsonb_array_length(res) >= 1 and res -> 0 ->> 'subject' = 'Muistutus' and not (res::text ~* '@'), 'E5: lokissa ei osoitteita');
  res := booking.admin_event_occurrence_cancel(v_rule);
  perform pg_temp.ck(res ->> 'cancelled_at' is not null and (res ->> 'active')::boolean = false, 'F1: peruttu');
  perform pg_temp.ck(not exists (select 1 from booking.public_availability(33, d, d) pa where pa.rule_id = v_rule and pa.status = 'available'), 'F2: peruttu kerta ei ole myynnissä');
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_delete(%s)$q$, v_rule)) = 'has_reservations', 'F3: peruttua kertaa ei poisteta');
  perform test.logout();
end $t$;

do $$
declare n int; bad int;
begin
  select count(*) filter (where ok), count(*) filter (where not ok) into n, bad from t202_r;
  raise exception 'TESTRESULT pass=% fail=%', n, bad;
end $$;
