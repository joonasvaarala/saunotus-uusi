-- t155: booking_155 vuorotarjousmoottorin jatkopaketti. Joonaksen päätös 4: myöhäinen hyväksyjä saa "jo mennyt" -ilmoituksen
-- WhatsAppilla JA sähköpostilla (oletus päällä, sähköposti vain email_enabled-asetuksella), toiselle mennyt vuoro katoaa omalta sivulta,
-- auki ollut sivu näyttää already_taken, WhatsAppin sähköpostivarapolku ei lähetä toista sähköpostia. Lisäksi test 'a' (Otto/allowlist).
-- Kaikki data on feikkiä (@example.test). Mitään ei lähetetä. Ajetaan booking_153- ja booking_155-migraatioiden ja
-- fixtures/10_test_helpers.sql:n JÄLKEEN. Yksi DO-lohko; lopun poikkeus kumoaa kaiken.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table t155_r(ok boolean, label text) on commit drop;
grant all on t155_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t155_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.msg(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'NO ERROR'; exception when others then return sqlerrm; end $$;
insert into vault.decrypted_secrets (name, decrypted_secret) values ('shift_offer_token_secret', 'test-key-155')
on conflict (name) do update set decrypted_secret = excluded.decrypted_secret;
do $t$
declare
  H1 uuid := 'bbbbbbbb-0155-4000-8000-0000000000a1'; H2 uuid := 'bbbbbbbb-0155-4000-8000-0000000000a2'; H3 uuid := 'bbbbbbbb-0155-4000-8000-0000000000a3';
  T1 uuid := 'bbbbbbbb-0155-4000-8000-0000000000b1'; T2 uuid := 'bbbbbbbb-0155-4000-8000-0000000000b2';
  JO uuid := 'bbbbbbbb-0155-4000-8000-0000000000d1'; OT uuid := 'bbbbbbbb-0155-4000-8000-0000000000c1'; LA uuid := 'bbbbbbbb-0155-4000-8000-0000000000c2';
  t0 timestamptz; d1 date; d2 date; d5 date; d6 date; d7 date; d8 date;
  S1 uuid := gen_random_uuid(); S2 uuid := gen_random_uuid(); S3 uuid := gen_random_uuid(); S4 uuid := gen_random_uuid();
  S5 uuid := gen_random_uuid(); S6 uuid := gen_random_uuid(); S7 uuid := gen_random_uuid(); S8a uuid := gen_random_uuid(); S8b uuid := gen_random_uuid();
  S9 uuid := gen_random_uuid(); S10 uuid := gen_random_uuid(); S11 uuid := gen_random_uuid();
  j jsonb; j2 jsonb; v_o uuid; v_o2 uuid; v_dl timestamptz; v_cap timestamptz; v_n int; v_tok text; v_tok2 text; v_t timestamptz; v_st timestamptz;
  v_msg uuid; v_adm uuid; v_rec bigint; v_id bigint; v_txt text;
begin
  -- aika: t0 = huomenna klo 12 (Helsinki), jotta WhatsApp-ikkuna ja hiljaiset tunnit eivät satunnaista testiä
  t0 := (((now() at time zone 'Europe/Helsinki')::date + 1) + time '12:00') at time zone 'Europe/Helsinki';
  d1 := (t0 at time zone 'Europe/Helsinki')::date + 30; d2 := d1 + 1; d5 := (t0 at time zone 'Europe/Helsinki')::date + 16;
  d6 := (t0 at time zone 'Europe/Helsinki')::date + 40; d7 := d6 + 1; d8 := d1 + 3;

  insert into public.staff (id, name, email, phone_e164, active, whatsapp_enabled, bot_channel) values
    (H1, 'Hilma Testi', 'hilma155@example.test', '+358401550001', true, true, false),
    (H2, 'Heikki Testi', 'heikki155@example.test', '+358401550002', true, false, false),
    (H3, 'Hanna Testi', 'hanna155@example.test', '+358401550003', true, true, false),
    (T1, 'Tiina Testi', 'tiina155@example.test', null, true, false, false),
    (T2, 'Terhi Testi', 'terhi155@example.test', null, true, false, false),
    (JO, 'Joonas Testi', 'joonas155@example.test', null, true, false, true),
    (OT, 'Otto Testi', 'otto155@example.test', null, true, false, false),
    (LA, 'Laura Testi', 'laura155@example.test', null, true, false, false);
  insert into public.staff_roles (staff_id, role_type, active) values
    (H1, 'heater', true), (H2, 'heater', true), (H3, 'heater', true), (T1, 'therapist', true), (T2, 'therapist', true), (H1, 'reception', true);
  delete from public.shift_offer_settings where role_type in ('heater','therapist','reception');
  insert into public.shift_offer_settings (role_type, enabled, auto_close_enabled, exhausted_ask_count) values
    ('heater', true, false, 3), ('therapist', true, true, 1), ('reception', true, false, 3);
  delete from public.shift_offer_response_tiers;
  insert into public.shift_offer_response_tiers (role_type, min_lead, wait, wait_last_round, direct_to_all, note) values
    (null, interval '28 days', interval '3 days', null, false, 't153 4 vk'),
    (null, interval '14 days', interval '2 days', null, false, 't153 2–4 vk'),
    (null, interval '7 days', interval '24 hours', null, false, 't153 1–2 vk'),
    (null, interval '2 days', interval '6 hours', interval '12 hours', false, 't153 2–7 vrk'),
    (null, interval '0', null, null, true, 't153 alle 2 vrk');
  delete from public.shift_offer_rounds where role_type in ('heater','therapist','reception');
  insert into public.shift_offer_rounds (role_type, scenario, weekdays, round_no, kind) values
    ('heater', 'vacant_shift', '{1,2,3,4,5,6,7}', 1, 'named'), ('heater', 'vacant_shift', '{1,2,3,4,5,6,7}', 2, 'named'),
    ('therapist', 'vacant_shift', '{1,2,3,4,5,6,7}', 1, 'named'), ('reception', 'vacant_shift', '{1,2,3,4,5,6,7}', 1, 'named');
  insert into public.shift_offer_round_members (round_id, staff_id, sort_order)
  select r.id, m.s, m.o from public.shift_offer_rounds r
    join (values ('heater', 1, H1, 1), ('heater', 1, H2, 2), ('heater', 2, H3, 1), ('therapist', 1, T1, 1), ('therapist', 1, T2, 2), ('reception', 1, H1, 1))
         m(role, rn, s, o) on m.role = r.role_type and m.rn = r.round_no and r.weekdays = '{1,2,3,4,5,6,7}';
  update booking.settings set value = jsonb_build_object('chat_staff_ids', jsonb_build_array(JO), 'email_staff_ids', jsonb_build_array(OT), 'first_reminder_after', '3 days', 'daily_from', '7 days')
   where key = 'shift_offer.vacant_notice';
  update booking.settings set value = jsonb_build_object('staff_ids', jsonb_build_array(JO, LA), 'three_weeks', '21 days', 'warn_after', '3 days', 'close_after', '6 hours', 'weekly', '7 days')
   where key = 'shift_offer.therapist_notice';


  v_st := (d1 + time '10:00') at time zone 'Europe/Helsinki';

  -- ---------------- oletukset
  perform pg_temp.ck(booking.shift_offer_cfg_bool('already_taken_message', false), 'D1: shift_offer.already_taken_message oletus päällä');
  perform pg_temp.ck(not booking.shift_offer_cfg_bool('email_enabled', true), 'D2: email_enabled pysyy pois');
  perform pg_temp.ck(exists (select 1 from pg_trigger where tgname = 'shift_offer_already_taken_mail_trg' and tgrelid = 'booking.shift_offer_notices'::regclass), 'D3: sähköpostikopion trigger');
  perform pg_temp.ck(booking.shift_offer_email(OT, 't155 a', 'x', 't155-a') is null
                     and not exists (select 1 from booking.email_outbox e where e.dedupe_key = 'b153:t155-a'), 'a: email_enabled=false → ei sähköpostia Otolle allowlistasta riippumatta');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking._shift_offer_already_taken_mail()', 'execute')
                     and not has_function_privilege('authenticated', 'booking._shift_offer_already_taken_mail()', 'execute'), 'D4: triggerifunktio ei anonille');

  -- ---------------- 4a: oma sivu ennen ja jälkeen täyttymisen
  insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
    (S1, v_st, (d1 + time '18:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'open');
  j := public.shift_offer_ensure(S1, t0, false);
  v_o := (j->>'offer_id')::uuid;
  perform pg_temp.ck(j->>'action' = 'offered' and (j->>'recipients')::int = 2, 'S0: tarjous lähti kahdelle: ' || j::text);
  v_tok := booking.shift_staff_page_token(H1, true);
  v_tok2 := booking.shift_staff_page_token(H2, true);
  j := booking.shift_staff_page(v_tok2);
  perform pg_temp.ck(jsonb_array_length(j->'open') = 1 and j->'open'->0->>'offer_id' = v_o::text, 'P1: avoin tarjous näkyy ennen täyttymistä');
  update booking.settings set value = 'true' where key = 'shift_offer.email_enabled';
  j := public.shift_offer_respond(v_o, H1, 'accept', null, false, 'test');
  perform pg_temp.ck(j->>'result' = 'accepted', 'S1: H1 hyväksyi');
  j := booking.shift_staff_page(v_tok2);
  perform pg_temp.ck(j->>'ok' = 'true' and not (j::text like '%' || v_o::text || '%'), 'P2: toiselle mennyt vuoro katoaa omalta sivulta (avoimet ja vastatut)');
  j := booking.shift_staff_page(v_tok);
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(j->'answered') x where x->>'offer_id' = v_o::text and x->>'my_status' = 'accepted'), 'P3: voittajalle oma vuoro näkyy vastatuissa');

  -- ---------------- 4b: auki ollut sivu, Hyväksy → already_taken, WhatsApp + sähköposti
  j := booking.shift_staff_page_respond(v_tok2, v_o, 'accept');
  perform pg_temp.ck(j->>'result' = 'already_taken' and (j->>'ok')::boolean is false and not ((j->'page')::text like '%' || v_o::text || '%'),
                     'P4: auki olleelta sivulta Hyväksy → already_taken, päivitetty sivu ilman vuoroa: ' || left(j::text, 300));
  perform pg_temp.ck((select count(*) from public.shift_offer_messages m join booking.shift_offer_message_meta mm on mm.message_id = m.id
                       where m.offer_id = v_o and m.staff_id = H2 and mm.subkind = 'already_taken' and m.body like '%jo mennyt%') = 1, 'W1: WhatsApp-ilmoitus jonoon (yksi)');
  perform pg_temp.ck((select count(*) from booking.email_outbox e where e.dedupe_key = 'b153:at-mail:' || v_o::text || ':' || H2::text and e.kind = 'staff_shift_notice'
                       and e.payload->>'to_email' = 'heikki155@example.test' and e.payload->>'subject' = 'Vuoro on jo mennyt – Tapio'
                       and e.payload->>'text' like '%jo mennyt%' and e.payload->>'text' like '%–Tapio') = 1, 'E1: sähköpostikopio jonoon (yksi)');
  perform pg_temp.ck((select n.email_outbox_id is not null from booking.shift_offer_notices n where n.dedupe_key = 'at:' || v_o::text || ':' || H2::text), 'E2: ilmoituslokiin sähköpostin id');
  j := public.shift_offer_respond(v_o, H2, 'accept', null, false, 'test');
  perform pg_temp.ck((select count(*) from booking.email_outbox e where e.dedupe_key like 'b153:at-mail:' || v_o::text || ':%') = 1
                     and (select count(*) from booking.shift_offer_message_meta mm join public.shift_offer_messages m on m.id = mm.message_id
                           where m.offer_id = v_o and mm.subkind = 'already_taken') = 1, 'E3: toinen painallus ei tuplaa viestejä');
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox e where e.dedupe_key like 'b153:at-mail:' || v_o::text || ':' || H1::text), 'E4: voittaja ei saa ilmoitusta');

  -- ---------------- 4c: WhatsAppin sähköpostivarapolku ei lähetä toista sähköpostia
  select m.id into v_id from public.shift_offer_messages m join booking.shift_offer_message_meta mm on mm.message_id = m.id
   where m.offer_id = v_o and m.staff_id = H2 and mm.subkind = 'already_taken';
  update public.shift_offer_messages set channel = 'email', status = 'queued', next_attempt_at = now() - interval '1 minute' where id = v_id;
  v_n := booking.shift_offer_email_drain(50);
  perform pg_temp.ck((select status = 'skipped' and last_error = 'email_copy_sent' from public.shift_offer_messages where id = v_id)
                     and not exists (select 1 from booking.email_outbox e where e.dedupe_key = 'b153:msg:' || v_id::text), 'E5: varapolku ohitetaan, ei toista sähköpostia');

  -- ---------------- 4d: email_enabled pois → vain WhatsApp
  update booking.settings set value = 'false' where key = 'shift_offer.email_enabled';
  insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
    (S2, v_st + interval '1 day', (d2 + time '18:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'open');
  j := public.shift_offer_ensure(S2, t0, false);
  v_o2 := (j->>'offer_id')::uuid;
  j := public.shift_offer_respond(v_o2, H1, 'accept', null, false, 'test');
  j := public.shift_offer_respond(v_o2, H2, 'accept', null, false, 'test');
  perform pg_temp.ck(j->>'result' = 'already_filled'
                     and exists (select 1 from booking.shift_offer_notices n where n.dedupe_key = 'at:' || v_o2::text || ':' || H2::text and n.message_id is not null and n.email_outbox_id is null)
                     and not exists (select 1 from booking.email_outbox e where e.dedupe_key like 'b153:at-mail:' || v_o2::text || ':%'), 'E6: email_enabled=false → WhatsApp, ei sähköpostia');

  -- ---------------- 4e: asetus pois → ei ilmoitusta lainkaan
  update booking.settings set value = 'false' where key = 'shift_offer.already_taken_message';
  insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
    (S3, v_st + interval '3 days', (d8 + time '18:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'open');
  j := public.shift_offer_ensure(S3, t0, false);
  v_o := (j->>'offer_id')::uuid;
  j := public.shift_offer_respond(v_o, H1, 'accept', null, false, 'test');
  j := public.shift_offer_respond(v_o, H2, 'accept', null, false, 'test');
  perform pg_temp.ck(j->>'result' = 'already_filled' and not exists (select 1 from booking.shift_offer_notices n where n.offer_id = v_o and n.stage = 'already_taken'),
                     'E7: asetus pois → ei "jo mennyt" -ilmoitusta');
  update booking.settings set value = 'true' where key = 'shift_offer.already_taken_message';

  -- moottori pysyy pois päältä
  perform pg_temp.ck(position('enabled = true' in (select prosrc from pg_proc where oid = 'booking._shift_offer_already_taken_mail()'::regprocedure)) = 0, 'M1: ei kytkimiä päälle');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t155_r where ok), (select count(*) from t155_r where not ok),
    coalesce((select string_agg(label, ' | ') from t155_r where not ok), 'ALL OK');
end $t$;
