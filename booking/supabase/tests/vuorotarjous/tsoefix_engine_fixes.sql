-- tsoefix: vuorotarjousmoottorin korjaukset (migraatio *_soefix_engine_fixes.sql): B2, B4/C1, C2, B3, B7/B8, B9, T1.
-- Puhdas SQL, kaikki data feikkiä (@example.test), mitään ei lähetetä (ei WhatsAppia, ei sähköpostia: email_outbox-rivit vain
-- tarkistetaan ja kumotaan). Ajetaan paikalliseen kantaan, jossa on tuotannon määrittelyt:
--   fixtures/10_test_helpers.sql, tests/vuorotarjous/tsoefix_prep_local.sql, migraatio. Yksi DO-lohko; lopun poikkeus kumoaa kaiken
--   (myös testin ajaksi päälle laitetut sender_enabled/whatsapp_enabled-kytkimet, jotka ovat vain tässä transaktiossa).
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table tsoefix_r(ok boolean, label text) on commit drop;
grant all on tsoefix_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into tsoefix_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.st(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $$;
create function pg_temp.as_auth(p_user uuid, p_sql text) returns text language plpgsql as $$
declare v text := 'ok';
begin
  perform test.login(p_user);
  begin execute p_sql; exception when others then v := sqlstate; end;
  perform test.logout();
  return v;
end $$;
insert into vault.decrypted_secrets (name, decrypted_secret) values ('shift_offer_token_secret', 'test-key-soefix')
on conflict (name) do update set decrypted_secret = excluded.decrypted_secret;
do $t$
declare
  CS uuid; H1 uuid; H2 uuid; H3 uuid; H4 uuid; JO uuid; TT uuid; PA uuid; PP uuid;
  t0 timestamptz; d1 date; v_st timestamptz; v_wed date; v_mon date;
  S1 uuid; S2 uuid; S3 uuid; S4 uuid; S5 uuid; S6 uuid;
  j jsonb; v_o uuid; v_o2 uuid; v_o3 uuid; v_id bigint; v_id2 bigint; v_m1 bigint; v_m2 bigint; v_m3 bigint; v_m4 bigint;
  v_r1 bigint; v_r2 bigint; v_dl1 timestamptz; v_dl2 timestamptz; v_na timestamptz; v_out bigint; v_out2 bigint; v_n int;
  v_wm uuid; v_cli uuid; v_adm uuid; v_txt text; v_b1 bigint; v_b2 bigint; v_b3 bigint; flags0 jsonb;
begin
  t0 := (((now() at time zone 'Europe/Helsinki')::date + 1) + time '12:00') at time zone 'Europe/Helsinki';
  d1 := (t0 at time zone 'Europe/Helsinki')::date + 30;
  v_st := (d1 + time '10:00') at time zone 'Europe/Helsinki';
  v_wed := d1 + ((3 - extract(isodow from d1)::int + 7) % 7);
  v_mon := d1 + ((1 - extract(isodow from d1)::int + 7) % 7) + 7;
  flags0 := (select row_to_json(e)::jsonb - 'updated_at' from public.shift_offer_engine_settings e where e.id);

  -- ---------------- M: migraation jälki (kytkimet pois, tekstit, asetukset)
  perform pg_temp.ck(not (flags0->>'sender_enabled')::boolean and not (flags0->>'whatsapp_enabled')::boolean
                     and (flags0->>'whatsapp_dry_run')::boolean and jsonb_array_length(flags0->'whatsapp_allow_staff_ids') = 0,
                     'M1: moottori pois (sender_enabled, whatsapp_enabled false, dry_run true, allowlist tyhjä)');
  perform pg_temp.ck(not booking.shift_offer_cfg_bool('welcome_enabled', true), 'M2: welcome_enabled pysyy false');
  perform pg_temp.ck(not (booking.shift_offer_cfg('wa_templates') -> 'offer' ? 'fallback')
                     and booking.shift_offer_cfg('wa_templates') -> 'offer' ->> 'name' = 'tyovuoro_kysely', 'M3: offer-pohjan fallback vuorotarjous poistettu');
  select published_text into v_txt from booking.site_texts where key = 'shift_offer.whatsapp.welcome' and lang = 'fi';
  perform pg_temp.ck(replace(replace(v_txt, '{{var:name}}', '{nimi}'), '{{var:link}}', '{linkki}')
    = 'Hei {nimi}! Tervetuloa Sipoonjoen perinnesaunan vuoroviesteihin. Saat tästä numerosta tarjouksia avoimista vuoroista, jotka sopivat sinulle. Vastaa tarjoukseen painamalla viestin "Avaa vastaus" -painiketta, ja valitse sivulla hyväksy tai kieltäydy. Kirjautumista ei tarvita. Jos useampi ehtii hyväksyä saman vuoron, se menee ensimmäiselle. Omalla sivullasi näet avoimet ja jo vastatut päiväsi, ja voit muuttaa vastaustasi siellä: {linkki} Viestejä lähetetään vain klo 8–21. Tapio',
    'M4: tervetuloteksti sanatarkasti (paikkamerkit {nimi}/{linkki} = {{var:name}}/{{var:link}})');
  perform pg_temp.ck((select t.published_version = 2 and t.latest_version = 2 and t.max_len = 600 and t.status = 'published' from booking.site_texts t
                       where t.key = 'shift_offer.whatsapp.welcome' and t.lang = 'fi')
                     and (select string_agg(v.version || ':' || v.status || ':' || v.author_kind, ',' order by v.version) from booking.site_text_versions v
                           join booking.site_texts t on t.id = v.text_id where t.key = 'shift_offer.whatsapp.welcome' and t.lang = 'fi')
                         = '1:superseded:human,2:published:system', 'M5: versio 2 julkaistu, versio 1 superseded');
  perform pg_temp.ck(position('<' in v_txt) = 0 and (select needs_translation from booking.site_texts where key = 'shift_offer.whatsapp.welcome' and lang = 'en'),
                     'M6: ei <-merkkiä; en-rivi needs_translation');
  perform pg_temp.ck(pg_temp.st($q$select booking._text_validate('normal', 'plain', 600, '{"{{var:link}}","{{var:name}}"}', 'Hei <b>x</b> {{var:name}} {{var:link}}')$q$) = 'BK001',
                     'M7: <-sääntö: HTML hylätään (SQLSTATE BK001)');

  -- ---------------- testidata (RETURNING id)
  insert into public.calendar_sources (calendar_name, role_type) values ('soefix-testi', 'heater') returning id into CS;
  insert into public.staff (name, calendar_name, email, phone_e164, active, whatsapp_enabled, bot_channel)
  values ('Hilma Soefix', 'Hilma Soefix', 'hilma.soefix@example.test', '+358401990001', true, true, false) returning id into H1;
  insert into public.staff (name, calendar_name, email, phone_e164, active, whatsapp_enabled, bot_channel)
  values ('Heikki Soefix', 'Heikki Soefix', 'heikki.soefix@example.test', null, true, false, false) returning id into H2;
  insert into public.staff (name, calendar_name, email, phone_e164, active, whatsapp_enabled, bot_channel)
  values ('Hanna Soefix', 'Hanna Soefix', 'hanna.soefix@', null, true, false, false) returning id into H3;
  insert into public.staff (name, calendar_name, email, phone_e164, active, whatsapp_enabled, bot_channel)
  values ('Helmi Soefix', 'Helmi Soefix', 'helmi.soefix@example.test', '+358401990004', true, true, false) returning id into H4;
  insert into public.staff (name, calendar_name, email, phone_e164, active, whatsapp_enabled, bot_channel)
  values ('Jope Soefix', 'Jope Soefix', 'jope.soefix@example.test', null, true, false, true) returning id into JO;
  insert into public.staff (name, calendar_name, email, phone_e164, active, whatsapp_enabled, bot_channel)
  values ('Terttu Soefix', 'Terttu Soefix', 'terttu.soefix@example.test', null, true, false, false) returning id into TT;
  insert into public.staff (name, calendar_name, active) values ('Pekka Aktiivi', 'PekkaSoefixA', true) returning id into PA;
  insert into public.staff (name, calendar_name, active) values ('Pekka Passiivi', 'PekkaSoefixP', false) returning id into PP;
  insert into public.staff_roles (staff_id, role_type, active) values
    (H1, 'heater', true), (H2, 'heater', true), (H3, 'heater', true), (H4, 'heater', true), (TT, 'therapist', true), (H1, 'reception', true);
  delete from public.shift_offer_settings where role_type in ('heater', 'therapist', 'reception');
  insert into public.shift_offer_settings (role_type, enabled, auto_close_enabled, exhausted_ask_count) values
    ('heater', true, false, 3), ('therapist', true, true, 1), ('reception', true, false, 3);
  delete from public.shift_offer_response_tiers;
  insert into public.shift_offer_response_tiers (role_type, min_lead, wait, wait_last_round, direct_to_all, note) values
    (null, interval '28 days', interval '3 days', null, false, 'soefix 4 vk'),
    (null, interval '14 days', interval '2 days', null, false, 'soefix 2–4 vk'),
    (null, interval '7 days', interval '24 hours', null, false, 'soefix 1–2 vk'),
    (null, interval '2 days', interval '6 hours', interval '12 hours', false, 'soefix 2–7 vrk'),
    (null, interval '0', null, null, true, 'soefix alle 2 vrk');
  delete from public.shift_offer_rounds where role_type in ('heater', 'therapist', 'reception');
  insert into public.shift_offer_rounds (role_type, scenario, weekdays, round_no, kind) values
    ('heater', 'vacant_shift', '{1,2,3,4,5,6,7}', 1, 'named'), ('heater', 'vacant_shift', '{1,2,3,4,5,6,7}', 2, 'named'),
    ('reception', 'vacant_shift', '{6,7}', 1, 'named');
  insert into public.shift_offer_round_members (round_id, staff_id, sort_order)
  select r.id, m.s, m.o from public.shift_offer_rounds r
    join (values ('heater', 1, H1, 1), ('heater', 1, H2, 2), ('heater', 1, H3, 3), ('heater', 1, H4, 4), ('heater', 2, H1, 1), ('reception', 1, H1, 1))
         m(role, rn, s, o) on m.role = r.role_type and m.rn = r.round_no;
  -- vain tämän transaktion ajaksi: lähetin päälle (dry run), H1 allowlistalle, WhatsApp-ikkuna koko vuorokausi (deterministinen)
  update public.shift_offer_engine_settings set sender_enabled = true, whatsapp_enabled = true, whatsapp_dry_run = true,
         whatsapp_allow_staff_ids = array[H1] where id;
  update booking.settings set value = '{"start": "00:00", "end": "24:00"}' where key = 'shift_offer.whatsapp_hours';

  -- ---------------- C2 + T1: queue_message
  insert into public.work_shifts (calendar_source_id, google_event_id, calendar_title, starts_at, ends_at, role_type, status, staffing_status)
  values (CS, 'soefix-' || gen_random_uuid()::text, '-', v_st, v_st + interval '8 hours', 'heater', 'active', 'open') returning id into S1;
  j := public.shift_offer_ensure(S1, t0, false);
  v_o := (j->>'offer_id')::uuid;
  perform pg_temp.ck(j->>'action' = 'offered', 'Q0: tarjous: ' || j::text);
  select id into v_m1 from public.shift_offer_messages where offer_id = v_o and staff_id = H1 and kind = 'offer';
  select id into v_m2 from public.shift_offer_messages where offer_id = v_o and staff_id = H2 and kind = 'offer';
  perform pg_temp.ck((select channel = 'whatsapp' and status = 'queued' from public.shift_offer_messages where id = v_m1)
                     and (select channel = 'email' and status = 'queued' from public.shift_offer_messages where id = v_m2), 'Q1: H1 WhatsApp, H2 sähköposti');
  perform pg_temp.ck((select status = 'failed_no_contact' and last_error = 'no_working_channel' and channel = 'none'
                        from public.shift_offer_messages where offer_id = v_o and staff_id = H3 and kind = 'offer'),
                     'C2: ei puhelinta eikä kelvollista sähköpostia (hanna.soefix@) → failed_no_contact / no_working_channel');
  update public.staff set active = false where id = H4;   -- deaktivoidaan tarjouksen jälkeen
  v_id := public.shift_offer_queue_message(v_o, null, H4, 'alert', 'x', 'soefix:inactive:' || v_o::text);
  perform pg_temp.ck((select status = 'skipped' and last_error = 'skipped_inactive' from public.shift_offer_messages where id = v_id),
                     'T1a: deaktivoidulle ei jonoon (skipped_inactive)');
  perform pg_temp.ck(booking.shift_offer_email(H4, 'x', 'y', 'soefix-inactive') is null, 'T1b: shift_offer_email ei deaktivoidulle');
  perform pg_temp.ck((select staffing_status = 'assigned' and staff_ids = array[PA] from public.parse_shift_title('PekkaSoefixA'))
                     and (select staffing_status = 'unresolved' from public.parse_shift_title('PekkaSoefixP'))
                     and (select staffing_status = 'unresolved' from public.parse_shift_title('PekkaSoefixA & PekkaSoefixP')),
                     'T1c: parse_shift_title täsmää vain aktiiviseen');

  -- ---------------- B2: claim / email_drain eivät jatka; vain onnistunut lähetys
  update public.shift_offer_recipients set deadline_at = now() + interval '1 minute' where offer_id = v_o and status = 'pending';
  update public.shift_offer_messages set next_attempt_at = now() - interval '1 minute' where offer_id = v_o and status = 'queued';
  select id into v_r1 from public.shift_offer_recipients where offer_id = v_o and staff_id = H1;
  select id into v_r2 from public.shift_offer_recipients where offer_id = v_o and staff_id = H2;
  select next_action_at into v_na from public.shift_offers where id = v_o;
  perform pg_temp.ck(not booking.shift_offer_wa_ready(H1, 'offer', null) and booking.shift_offer_wa_ready(H1, 'alert', 'day_digest')
                     and not booking.shift_offer_wa_ready(H2, 'offer', null) and not booking.shift_offer_wa_ready(H4, 'alert', null),
                     'C1a: wa_ready: hyväksymätön offer-pohja ei kelpaa, kooste kelpaa, ei puhelinta / deaktivoitu ei');
  j := public.shift_offer_sender_claim(20);
  perform pg_temp.ck((j->>'emailed')::int >= 1 and (j->>'email_enabled')::boolean and (j->>'resent')::int = 0, 'B2a: claim ajoi sähköpostin: ' || left(j::text, 200));
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(j->'messages') x where (x->>'id')::bigint = v_m1
                              and (x->>'deadline_at')::timestamptz > now() + interval '1 hour'),
                     'C1b: hyväksymätön pohja → WhatsApp-rivi poimitaan (edge siirtää sähköpostiin), näytetty määräaika = jatkettu esikatselu');
  perform pg_temp.ck((select deadline_at from public.shift_offer_recipients where id = v_r1) = now() + interval '1 minute'
                     and (select deadline_at from public.shift_offer_recipients where id = v_r2) = now() + interval '1 minute'
                     and (select next_action_at from public.shift_offers where id = v_o) is not distinct from v_na,
                     'B2b: claim ja email_drain eivät jatka määräaikaa eivätkä kierroksen next_action_at:ia');
  perform pg_temp.ck((select status = 'sent' and deadline_extended_at is null from public.shift_offer_messages where id = v_m2), 'B2c: sähköpostiviesti jonossa, ei jatkoa vielä');
  select id into v_out from booking.email_outbox where dedupe_key = 'b153:msg:' || v_m2::text;
  j := public.shift_offer_sender_complete(jsonb_build_object('id', v_m1, 'action', 'release', 'channel', 'email', 'to', 'hilma.soefix@example.test',
                                                             'error', 'template_not_approved', 'retry_at', now() - interval '1 minute'));
  perform pg_temp.ck(j->>'status' = 'queued' and (select deadline_at from public.shift_offer_recipients where id = v_r1) = now() + interval '1 minute',
                     'B2d: release (WhatsApp → sähköposti) ei jatka');
  v_n := booking.shift_offer_email_drain(50);
  select id into v_out2 from booking.email_outbox where dedupe_key = 'b153:msg:' || v_m1::text;
  update booking.email_outbox set status = 'skipped' where id = v_out;
  perform pg_temp.ck((select deadline_at from public.shift_offer_recipients where id = v_r2) = now() + interval '1 minute', 'B2e: email skipped ei jatka');
  update booking.email_outbox set status = 'sent', sent_at = now(), provider_id = 'test-provider' where id = v_out2;
  select deadline_at into v_dl1 from public.shift_offer_recipients where id = v_r1;
  perform pg_temp.ck(v_dl1 > now() + interval '1 hour' and (select deadline_extended_at is not null from public.shift_offer_messages where id = v_m1),
                     'B2f: email_outbox sent → jatko kerran');
  update public.shift_offer_recipients set deadline_at = now() + interval '2 minutes' where id = v_r1;
  update booking.email_outbox set status = 'pending' where id = v_out2;
  update booking.email_outbox set status = 'sent' where id = v_out2;
  perform pg_temp.ck((select deadline_at from public.shift_offer_recipients where id = v_r1) = now() + interval '2 minutes', 'B2g: toinen sent ei jatka uudelleen (idempotentti)');
  update booking.email_outbox set status = 'sent' where id = v_out;   -- skipped → sent: trigger ei saa kaatua vaikka viesti jo käsitelty
  perform pg_temp.ck((select deadline_extended_at is not null from public.shift_offer_messages where id = v_m2), 'B2h: sähköposti sent myöhemmin → jatko');

  -- WhatsApp sent / fail (pohja hyväksytty vain tässä transaktiossa)
  update booking.settings set value = jsonb_set(value, '{offer,approved}', 'true') where key = 'shift_offer.wa_templates';
  insert into public.work_shifts (calendar_source_id, google_event_id, calendar_title, starts_at, ends_at, role_type, status, staffing_status)
  values (CS, 'soefix-' || gen_random_uuid()::text, '-', v_st + interval '1 day', v_st + interval '1 day 8 hours', 'heater', 'active', 'open') returning id into S2;
  j := public.shift_offer_ensure(S2, t0, false);
  v_o2 := (j->>'offer_id')::uuid;
  select id into v_m3 from public.shift_offer_messages where offer_id = v_o2 and staff_id = H1 and kind = 'offer';
  select id into v_r1 from public.shift_offer_recipients where offer_id = v_o2 and staff_id = H1;
  update public.shift_offer_recipients set deadline_at = now() + interval '1 minute' where offer_id = v_o2;
  update public.shift_offer_messages set next_attempt_at = now() - interval '1 minute' where offer_id = v_o2 and status = 'queued';
  perform pg_temp.ck(booking.shift_offer_wa_ready(H1, 'offer', null) and not booking.shift_offer_wa_ready(H1, 'offer', 'round_reminder'), 'C1c: hyväksytty offer-pohja kelpaa, muistutuspohja ei');
  j := public.shift_offer_sender_claim(20);
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(j->'messages') x where (x->>'id')::bigint = v_m3), 'B2i: valmis WhatsApp-rivi poimitaan (ikkuna auki)');
  j := public.shift_offer_sender_complete(jsonb_build_object('id', v_m3, 'action', 'sent', 'wamid', 'wamid.SOEFIX1', 'channel', 'whatsapp'));
  select deadline_at into v_dl2 from public.shift_offer_recipients where id = v_r1;
  perform pg_temp.ck(j->>'status' = 'sent' and v_dl2 > now() + interval '1 hour', 'B2j: WhatsApp sent (wamid) → jatko');
  j := public.shift_offer_sender_complete(jsonb_build_object('id', v_m3, 'action', 'sent', 'wamid', 'wamid.SOEFIX1'));
  perform pg_temp.ck((j->>'duplicate')::boolean and (select deadline_at from public.shift_offer_recipients where id = v_r1) = v_dl2, 'B2k: uusinta-sent ei jatka toiste');
  insert into public.work_shifts (calendar_source_id, google_event_id, calendar_title, starts_at, ends_at, role_type, status, staffing_status)
  values (CS, 'soefix-' || gen_random_uuid()::text, '-', v_st + interval '2 days', v_st + interval '2 days 8 hours', 'heater', 'active', 'open') returning id into S3;
  j := public.shift_offer_ensure(S3, t0, false);
  v_o3 := (j->>'offer_id')::uuid;
  select id into v_m4 from public.shift_offer_messages where offer_id = v_o3 and staff_id = H1 and kind = 'offer';
  update public.shift_offer_recipients set deadline_at = now() + interval '1 minute' where offer_id = v_o3;
  update public.shift_offer_messages set next_attempt_at = now() - interval '1 minute' where offer_id = v_o3 and status = 'queued';
  update public.shift_offer_engine_settings set whatsapp_allow_staff_ids = '{}' where id;   -- resend_lost ei saa poimia tätä vielä WhatsAppiin
  update public.shift_offer_engine_settings set whatsapp_allow_staff_ids = array[H1] where id;
  j := public.shift_offer_sender_claim(20);
  j := public.shift_offer_sender_complete(jsonb_build_object('id', v_m4, 'action', 'fail', 'error', 'wa_131026'));
  perform pg_temp.ck(j->>'status' = 'failed' and (select deadline_at from public.shift_offer_recipients where offer_id = v_o3 and staff_id = H1) = now() + interval '1 minute',
                     'B2l: fail ei jatka');
  perform pg_temp.ck(pg_temp.st(format('select public.shift_offer_sender_complete(%L::jsonb)', jsonb_build_object('id', v_m4, 'action', 'sent', 'wamid', 'x')::text)) = 'ok'
                     and (select status from public.shift_offer_messages where id = v_m4) = 'failed', 'B2m: suljettua riviä ei voi merkitä lähetetyksi');

  -- ---------------- T1: tarjouksen jälkeen deaktivoitu → claim ohittaa
  perform pg_temp.ck((select status = 'skipped' and last_error = 'skipped_inactive' from public.shift_offer_messages where offer_id = v_o and staff_id = H4 and kind = 'offer'),
                     'T1d: deaktivoidun jonossa ollut tarjous ohitettiin claimissa');

  -- ---------------- B7/B8: kadonnut viesti → kerran toista kanavaa
  v_n := booking.shift_offer_resend_lost(now());
  select id into v_id from public.shift_offer_messages where dedupe_key = 'resend:' || v_m4::text;
  perform pg_temp.ck(v_id is not null and (select channel = 'email' and status = 'queued' and recipient_id is not null from public.shift_offer_messages where id = v_id)
                     and (select resent_message_id = v_id from public.shift_offer_messages where id = v_m4), 'B7a: failed WhatsApp → sähköposti kerran');
  v_n := booking.shift_offer_resend_lost(now());
  perform pg_temp.ck((select count(*) from public.shift_offer_messages where dedupe_key like 'resend:%') = 1, 'B7b: ei toista uudelleenlähetystä');
  perform pg_temp.ck(not exists (select 1 from public.shift_offer_messages m where m.dedupe_key = 'resend:' || (select id from public.shift_offer_messages
                       where offer_id = v_o and staff_id = H3 and kind = 'offer')::text), 'B7c: failed_no_contact ei uudelleenlähetetä');
  -- bottikanava: kuittaamaton > 2 h → sähköpostikopio; kuitattu (bot_ack / botgw.inbox_ack) ei
  v_b1 := public.shift_offer_queue_message(v_o, null, JO, 'alert', 'soefix bot 1', 'soefix:bot1');
  v_b2 := public.shift_offer_queue_message(v_o, null, JO, 'alert', 'soefix bot 2', 'soefix:bot2');
  v_b3 := public.shift_offer_queue_message(v_o, null, JO, 'alert', 'soefix bot 3', 'soefix:bot3');
  update public.shift_offer_messages set created_at = now() - interval '3 hours' where id in (v_b1, v_b2, v_b3);
  perform pg_temp.ck((select status from public.shift_offer_messages where id = v_b1) = 'bot_channel', 'B8a: bottikanavan rivi');
  perform pg_temp.ck(public.shift_offer_bot_ack(array[v_b2]) = 1, 'B8b: shift_offer_bot_ack kuittaa');
  insert into botgw.bot_clients (name, staff_id, active) values ('soefix-test', JO, false) returning id into v_cli;
  insert into botgw.inbox_ack (client_id, message_id) values (v_cli, v_b3);
  v_n := booking.shift_offer_resend_lost(now());
  perform pg_temp.ck((select bot_email_outbox_id from public.shift_offer_messages where id = v_b1) = (select id from booking.email_outbox where dedupe_key = 'b153:botcopy:' || v_b1::text)
                     and (select bot_email_outbox_id is null from public.shift_offer_messages where id = v_b2)
                     and (select bot_email_outbox_id is null from public.shift_offer_messages where id = v_b3), 'B8c: vain kuittaamaton saa sähköpostikopion');
  v_n := booking.shift_offer_resend_lost(now());
  perform pg_temp.ck((select count(*) from booking.email_outbox where dedupe_key like 'b153:botcopy:%') = 1, 'B8d: kopio kerran');
  perform pg_temp.ck(pg_temp.st('select public.shift_offer_bot_ack(array(select generate_series(1, 501))::bigint[])') = '22023', 'B8e: yli 500 id:tä → SQLSTATE 22023');

  -- ---------------- B3: ei kierroksia → no_rounds, raportissa; hoitajavuoro ennallaan
  insert into public.work_shifts (calendar_source_id, google_event_id, calendar_title, starts_at, ends_at, role_type, status, staffing_status)
  values (CS, 'soefix-' || gen_random_uuid()::text, '-', (v_wed + time '10:00') at time zone 'Europe/Helsinki', (v_wed + time '18:00') at time zone 'Europe/Helsinki', 'reception', 'active', 'open') returning id into S4;
  j := public.shift_offer_ensure(S4, t0, true);
  perform pg_temp.ck(j->>'reason' = 'no_rounds' and not exists (select 1 from booking.shift_offer_skips where shift_id = S4), 'B3a: dry run: no_rounds, ei kirjausta');
  j := public.shift_offer_ensure(S4, t0, false);
  perform pg_temp.ck(j->>'action' = 'skip' and j->>'reason' = 'no_rounds' and j->>'role_type' = 'reception'
                     and not exists (select 1 from public.shift_offers where shift_id = S4), 'B3b: vastaanotto keskiviikkona → skip no_rounds, ei tarjousta: ' || j::text);
  j := public.shift_offer_ensure(S4, t0, false);
  perform pg_temp.ck((select seen_count = 2 from booking.shift_offer_skips where shift_id = S4 and reason = 'no_rounds'), 'B3c: kirjaus päivittyy (seen_count 2)');
  j := booking.shift_offer_report_issues(now() - interval '1 day');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(j->'no_rounds') x where x->>'shift_id' = S4::text and x->>'shift_date' = v_wed::text)
                     and exists (select 1 from jsonb_array_elements(j->'no_working_channel') x where x->>'staff_id' = H3::text and (x->>'offers_skipped')::int >= 1)
                     and (j->>'resent')::int = 1 and (j->>'bot_email_copies')::int = 1 and (j->>'skipped_inactive')::int >= 2
                     and j::text !~ '\+358' and j::text !~ 'example\.test', 'B3d/C2b: raportti: no_rounds, no_working_channel, ei puhelinnumeroita/osoitteita: ' || left(j::text, 400));
  insert into public.work_shifts (calendar_source_id, google_event_id, calendar_title, starts_at, ends_at, role_type, status, staffing_status)
  values (CS, 'soefix-' || gen_random_uuid()::text, '-', (v_mon + time '10:00') at time zone 'Europe/Helsinki', (v_mon + time '18:00') at time zone 'Europe/Helsinki', 'therapist', 'active', 'open') returning id into S5;
  j := public.shift_offer_ensure(S5, t0, false);
  perform pg_temp.ck(coalesce(j->>'reason', '') <> 'no_rounds' and not exists (select 1 from booking.shift_offer_skips where shift_id = S5),
                     'B3e: hoitajavuoro ilman kierroksia ei ole no_rounds (6 h -logiikka ennallaan): ' || j::text);

  -- ---------------- B9: tervetuloviesti
  update booking.settings set value = 'true' where key = 'shift_offer.welcome_enabled';
  insert into public.whatsapp_messages (staff_id, direction, provider_message_id, message_text, received_at, phone_e164)
  values (H1, 'inbound', 'wamid.IN.SOEFIX', 'moi', now(), '+358401990001') returning id into v_wm;
  j := booking.shift_staff_welcome(v_wm);
  perform pg_temp.ck((j->>'send')::boolean and j->>'body' like 'Hei Hilma! Tervetuloa Sipoonjoen perinnesaunan vuoroviesteihin.%'
                     and j->>'body' like '%siellä: https://joonasvaarala.github.io/saunotus-uusi/vuoro/oma/%Viestejä lähetetään vain klo 8–21. Tapio'
                     and j->>'body' !~ '\{' and j->>'staff_id' = H1::text, 'B9a: tervetuloteksti täytetty (nimi + oma linkki): ' || left(j->>'body', 120));
  perform pg_temp.ck((select welcome_sent_at is null and welcome_claimed_at is not null from booking.shift_staff_whatsapp_consent where staff_id = H1),
                     'B9b: welcome_sent_at ei asetu ennen lähetystä (vain varaus)');
  perform pg_temp.ck(booking.shift_staff_welcome(v_wm)->>'reason' = 'claimed', 'B9c: rinnakkainen käsittely ei lähetä toista');
  perform pg_temp.ck(booking.shift_staff_welcome_release(H1) and (booking.shift_staff_welcome(v_wm)->>'send')::boolean, 'B9d: epäonnistunut → vapautus → uusi yritys');
  perform pg_temp.ck(not booking.shift_staff_welcome_mark_sent(H1, '') and booking.shift_staff_welcome_mark_sent(H1, 'wamid.OUT.SOEFIX'), 'B9e: mark_sent vain wamidilla');
  perform pg_temp.ck((select welcome_sent_at is not null and welcome_wamid = 'wamid.OUT.SOEFIX' and welcome_claimed_at is null
                        from booking.shift_staff_whatsapp_consent where staff_id = H1)
                     and booking.shift_staff_welcome(v_wm)->>'reason' = 'already_sent', 'B9f: lähetetty kirjattu, ei uudelleen');

  -- ---------------- oikeudet (oikea auth/staff-malli) ja SQLSTATE
  v_adm := test.mk_staff('adm.soefix@example.test', 'admin');
  perform pg_temp.ck(pg_temp.as_auth(v_adm, 'select public.shift_offer_bot_ack(array[1]::bigint[])') = '42501'
                     and pg_temp.as_auth(v_adm, 'select booking.shift_offer_report_issues()') = '42501'
                     and pg_temp.as_auth(v_adm, format('select booking.shift_staff_welcome_mark_sent(%L, %L)', H1, 'x')) = '42501'
                     and pg_temp.as_auth(v_adm, 'select count(*) from booking.shift_offer_skips') = '42501',
                     'A1: kirjautunut hallinnan käyttäjä ei pääse uusiin funktioihin eikä skips-tauluun (42501)');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.shift_offer_resend_lost(timestamptz)', 'execute')
                     and has_function_privilege('service_role', 'booking.shift_offer_resend_lost(timestamptz)', 'execute')
                     and (select relrowsecurity from pg_class where oid = 'booking.shift_offer_skips'::regclass), 'A2: service_role, RLS päällä');
  perform pg_temp.ck(pg_temp.st($q$insert into booking.shift_offer_skips (shift_id, reason) values (gen_random_uuid(), 'no_rounds')$q$) = '23503'
                     and pg_temp.st(format('insert into booking.shift_offer_skips (shift_id, reason) values (%L, %L)', S4, 'muu')) = '23514',
                     'A3: skips FK (23503) ja reason-check (23514)');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from tsoefix_r where ok), (select count(*) from tsoefix_r where not ok),
    coalesce((select string_agg(label, ' || ') from tsoefix_r where not ok), '-')
    using errcode = 'TRBK0';
end $t$;
