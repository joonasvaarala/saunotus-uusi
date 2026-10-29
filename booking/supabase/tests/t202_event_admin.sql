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

\ir ../migrations/20261029065818_booking_202_event_admin.sql

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
  -- Siirto menneisyyteen estetty (Joonas 29.10.); kerta ja varaus pysyvät ennallaan. Keston muutos ilman siirtoa sallittu.
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_upsert(%s, null, jsonb_build_object('date', (now() at time zone 'Europe/Helsinki')::date - 1))$q$, v_rule)) = 'past_move', 'D5: siirto eiliseen estetty');
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_upsert(%s, null, jsonb_build_object('date', (now() at time zone 'Europe/Helsinki')::date, 'start_time', '00:00'))$q$, v_rule)) = 'past_move', 'D6: siirto tämän päivän menneeseen aikaan estetty');
  perform pg_temp.ck((select valid_from = d and start_time = '18:00' from booking.schedule_rules where id = v_rule)
    and (select to_char(starts_at at time zone 'Europe/Helsinki', 'HH24:MI') from booking.reservations where id = v_res) = '18:00', 'D7: kerta ja varaus ennallaan');
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

-- G–K (review 28.10.): ajan siirto jonon, vanhentuneen pidon, ylibuukkauksen ja yksityisvuoron kanssa; peruutus ja jono; anonymisointi.
do $t$
declare
  u_mgr uuid := test.mk_staff('t202-mgr@example.test', 'manager');
  u_adm uuid := test.mk_staff('t202-adm@example.test', 'admin');
  d date := date '2027-05-04';
  v_savu bigint := (select id from booking.resources where code = 'savusauna');
  v_private bigint := test.rule('Oma savusaunavuoro ma–pe 16–19%');
  res jsonb; v_rule bigint; v_rule2 bigint; v_rule3 bigint; v_res bigint; v_res2 bigint; v_c text; v_wl bigint; v_st text; v_mail int;
begin
  perform pg_temp.ck(not (has_function_privilege('anon', 'booking.admin_event_participant_note_set(bigint, text)', 'execute')
     or has_function_privilege('anon', 'booking.admin_event_occurrence_cancel(bigint)', 'execute')
     or has_function_privilege('anon', 'booking.admin_event_message_send(bigint, bigint, text, text, boolean)', 'execute')
     or has_function_privilege('anon', 'booking.admin_event_messages_list(bigint)', 'execute')), 'G1: anon ei suorita yhtään RPC:tä');
  perform pg_temp.ck((select bool_and(p.prosecdef and p.proconfig @> array['search_path=""']) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'booking' and p.proname in ('admin_event_participants', 'admin_event_participant_note_set', 'admin_event_occurrence_cancel',
       'admin_event_message_send', 'admin_event_messages_list', 'reservations_drop_event_note', 'customers_drop_event_notes', 'admin_event_rule_upsert')),
     'G2: security definer + search_path');

  -- H: täysi kerta + jono: siirto ei lähetä jonolle "paikka vapautui"; jonorivi siirtyy
  perform test.login(u_mgr);
  res := booking.admin_event_rule_upsert(null, 33, jsonb_build_object('date', d, 'start_time', '10:00', 'duration_minutes', 60, 'max_persons', 2));
  v_rule := (res ->> 'id')::bigint;
  perform test.logout();
  perform test.reset_rl();
  perform test.anon('10.202.1.1'); res := test.pub_book(v_rule, d, 1, 't202-h1@example.com'); perform test.logout();
  perform test.reset_rl();
  perform test.anon('10.202.1.2'); res := test.pub_book(v_rule, d, 1, 't202-h2@example.com'); perform test.logout();
  insert into booking.waitlist_entries(product_id, rule_id, session_date, starts_at, ends_at, space_id, persons, customer_name, customer_email, status)
  select r.product_id, r.id, d, (d + r.start_time) at time zone 'Europe/Helsinki', (d + r.start_time + make_interval(mins => r.duration_minutes)) at time zone 'Europe/Helsinki',
         r.space_id, 1, 'Jono Testi', 't202-jono@example.test', 'waiting' from booking.schedule_rules r where r.id = v_rule returning id into v_wl;
  select count(*) into v_mail from booking.email_outbox where kind = 'waitlist_spot_freed';
  perform test.login(u_mgr);
  v_c := test.code(format($q$select booking.admin_event_rule_upsert(%s, null, '{"start_time":"10:30"}'::jsonb)$q$, v_rule));
  perform test.logout();
  perform pg_temp.ck(v_c = 'ok', 'H1: täyden kerran siirto: ' || v_c);
  perform pg_temp.ck((select status from booking.waitlist_entries where id = v_wl) = 'waiting'
    and (select count(*) from booking.email_outbox where kind = 'waitlist_spot_freed') = v_mail, 'H2: jonolle ei väärää ilmoitusta');
  perform pg_temp.ck((select to_char(starts_at at time zone 'Europe/Helsinki', 'HH24:MI') from booking.waitlist_entries where id = v_wl) = '10:30', 'H3: jonorivi siirtyi');

  -- I: vanhentunut pending-pito ei kaada siirtoa
  select id into v_res from booking.reservations where rule_id = v_rule and status in ('pending', 'confirmed') order by id limit 1;
  set constraints all immediate;
  alter table booking.reservations disable trigger user;
  update booking.reservations set status = 'pending', hold_expires_at = now() - interval '1 minute' where id = v_res;
  alter table booking.reservations enable trigger user;
  perform test.login(u_mgr);
  v_c := test.code(format($q$select booking.admin_event_rule_upsert(%s, null, '{"start_time":"11:00"}'::jsonb)$q$, v_rule));
  perform test.logout();
  perform pg_temp.ck(v_c = 'ok', 'I1: siirto, vaikka kerralla on vanhentunut pito: ' || v_c);
  perform pg_temp.ck((select status from booking.reservations where id = v_res) = 'cancelled', 'I2: vanhentunut pito peruttiin, ei siirretty');

  -- J: hallinnan ylibuukkaama kerta siirtyy, julkinen ei silti ylibuukkaa, max ei laske alle myydyn
  perform test.login(u_adm);
  res := booking.admin_event_rule_upsert(null, 33, jsonb_build_object('date', d, 'start_time', '12:00', 'duration_minutes', 60, 'max_persons', 1));
  v_rule2 := (res ->> 'id')::bigint;
  v_c := test.code(format($q$select booking.admin_create_booking(p_rule_id := %s, p_date := %L, p_persons := 2, p_customer := '{"name":"Yli Testi","kind":"private"}'::jsonb, p_allow_overbook := true)$q$, v_rule2, d));
  perform pg_temp.ck(v_c = 'ok', 'J1: admin ylibuukkaa: ' || v_c);
  perform test.logout();
  perform test.login(u_mgr);
  v_c := test.code(format($q$select booking.admin_create_booking(p_rule_id := %s, p_date := %L, p_persons := 1, p_customer := '{"name":"Yli Testi 2","kind":"private"}'::jsonb, p_allow_overbook := true)$q$, v_rule2, d));
  perform pg_temp.ck(v_c <> 'ok', 'J2: manager ei ylibuukkaa: ' || v_c);
  v_c := test.code(format($q$select booking.admin_event_rule_upsert(%s, null, '{"start_time":"12:30"}'::jsonb)$q$, v_rule2));
  perform pg_temp.ck(v_c = 'ok', 'J3: ylibuukatun kerran siirto: ' || v_c);
  perform pg_temp.ck((select capacity from booking.resources where code = 'event_rule_' || v_rule2) = 1, 'J4: poolin kapasiteetti palautui');
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_upsert(%s, null, '{"max_persons":1}'::jsonb)$q$, v_rule2)) = 'max_below_sold', 'J5: max ei laske alle myydyn');
  perform test.logout();
  perform test.reset_rl();
  perform test.anon('10.202.1.3'); res := test.pub_book(v_rule2, d, 1, 't202-j@example.com'); perform test.logout();
  perform pg_temp.ck(coalesce(res ->> 'token', '') = '', 'J6: julkinen ei ylibuukkaa');

  -- K: siirto yksityisvuoron päälle estyy (exclusive-sulku savusaunaan), varaukset jäävät paikalleen
  perform test.login(u_mgr);
  res := booking.admin_event_rule_upsert(null, 33, jsonb_build_object('date', d, 'start_time', '08:00', 'duration_minutes', 60, 'max_persons', 4));
  v_rule3 := (res ->> 'id')::bigint;
  perform booking.admin_event_blocks_set(v_rule3, jsonb_build_array(jsonb_build_object('resource_id', v_savu, 'mode', 'exclusive', 'offset_min', 0, 'minutes', 60)));
  v_c := test.code(format($q$select booking.admin_create_booking(p_rule_id := %s, p_date := %L, p_persons := 1, p_customer := '{"name":"Oma Testi","kind":"private"}'::jsonb)$q$, v_private, d));
  perform pg_temp.ck(v_c = 'ok', 'K1: yksityisvuoro 16–19: ' || v_c);
  perform test.logout();
  perform test.reset_rl();
  perform test.anon('10.202.1.4'); res := test.pub_book(v_rule3, d, 1, 't202-k@example.com'); perform test.logout();
  perform test.login(u_mgr);
  perform pg_temp.ck(test.code(format($q$select booking.admin_event_rule_upsert(%s, null, '{"start_time":"17:00"}'::jsonb)$q$, v_rule3)) = 'conflict', 'K2: siirto yksityisvuoron päälle estyy');
  perform test.logout();
  perform pg_temp.ck((select to_char(starts_at at time zone 'Europe/Helsinki', 'HH24:MI') from booking.reservations where rule_id = v_rule3 and status in ('pending', 'confirmed') limit 1) = '08:00', 'K3: varaus jäi 08:00');

  -- L: peruutus sulkee jonon; uudelleenaktivointi nollaa cancelled_at
  perform test.login(u_mgr);
  res := booking.admin_event_occurrence_cancel(v_rule);
  perform test.logout();
  perform pg_temp.ck((select status from booking.waitlist_entries where id = v_wl) = 'cancelled', 'L1: perutun kerran jono suljettu');
  select count(*) into v_mail from booking.email_outbox where kind = 'waitlist_spot_freed';
  update booking.reservations set status = 'cancelled', cancelled_at = now() where rule_id = v_rule and status = 'confirmed';
  perform pg_temp.ck((select count(*) from booking.email_outbox where kind = 'waitlist_spot_freed') = v_mail, 'L2: lippujen peruutus ei ilmoita jonolle');
  perform test.login(u_mgr);
  res := booking.admin_event_rule_upsert(v_rule3, null, '{"label":"Testikerta"}'::jsonb);
  res := booking.admin_event_occurrence_cancel(v_rule3);
  res := booking.admin_event_rule_upsert(v_rule3, null, '{"active":true}'::jsonb);
  perform pg_temp.ck((res ->> 'active')::boolean and res ->> 'cancelled_at' is null, 'L3: uudelleenaktivointi nollaa cancelled_at');
  perform test.logout();

  -- M: anonymisointi poistaa muistiinpanon; tavallinen notes-tyhjennys ei
  select id into v_res2 from booking.reservations where rule_id = v_rule3 and status in ('pending', 'confirmed') order by id limit 1;
  update booking.reservations set notes = 'x' where id = v_res2;
  perform test.login(u_mgr); perform booking.admin_event_participant_note_set(v_res2, 'Pyörätuoli'); perform test.logout();
  update booking.reservations set notes = null where id = v_res2;
  perform pg_temp.ck(exists (select 1 from booking.event_participant_notes where reservation_id = v_res2), 'M1: notes-tyhjennys ei poista muistiinpanoa');
  perform test.login(u_mgr); perform booking.admin_event_participant_note_set(v_res, 'Allergia'); perform test.logout();
  update booking.customers c set anonymized_at = now(), name = 'Anonymisoitu asiakas', email = null, phone = null
    from booking.orders o, booking.reservations x where x.id = v_res and o.id = x.order_id and c.id = o.customer_id;
  perform pg_temp.ck(not exists (select 1 from booking.event_participant_notes where reservation_id = v_res), 'M2: asiakkaan anonymisointi poistaa muistiinpanon');
  perform pg_temp.ck(not exists (select 1 from pg_trigger where tgrelid = 'booking.event_participant_notes'::regclass and tgname = 'audit_trg'), 'M3: muistiinpanoja ei kopioida audit_logiin');
end $t$;

do $$
declare n int; bad int;
begin
  select count(*) filter (where ok), count(*) filter (where not ok) into n, bad from t202_r;
  raise exception 'TESTRESULT pass=% fail=%', n, bad;
end $$;
