-- tdigest: päiväkoosteen (day_digest) korjaukset, migraatio 20261025171500_day_digest_fixes.sql (väliaikainen versio):
--   #1 B2 (kooste jatkaa jokaisen yhdistetyn määräajan, näytetty = kirjattu), #2 resend_lost (avoimista, uusi teksti),
--   #3 yö / hyväksymätön pohja (wa_ready day_digest), #4 horisontti (skipped 'horizon', fail-closed), R report_issues.
-- Puhdas SQL, kaikki data feikkiä (@example.test), mitään ei lähetetä (email_outbox-rivit vain tarkistetaan ja kumotaan).
-- Itsenäinen (ei test-skeemaa). Yksi DO-lohko; lopun poikkeus (SQLSTATE TRBK0, 'TESTRESULT pass=N fail=M :: ...') kumoaa kaiken,
-- myös testin ajaksi päälle laitetut sender_enabled/whatsapp_enabled-kytkimet, allowlistan, horisontin ja pohja-asetukset.
--
-- AJO (tuotanto tai paikallinen; postgres-roolina, yhtenä transaktiona, migraation jälkeen; vaatii horisonttimigraation 20261025165813):
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -1 -f booking/supabase/tests/vuorotarjous/tdigest_fixes.sql
-- Odotettu tulos: ERROR:  TESTRESULT pass=N fail=0 :: -   (SQLSTATE TRBK0; psql:n exit-koodi 3 on tarkoitus).
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table tdigest_r(ok boolean, label text) on commit drop;
grant all on tdigest_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into tdigest_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.sh(p_cs uuid, p_role text, p_day date, p_from time, p_hours int) returns uuid language sql as $$
  insert into public.work_shifts (calendar_source_id, google_event_id, calendar_title, starts_at, ends_at, role_type, status, staffing_status)
  values (p_cs, 'tdigest-' || gen_random_uuid()::text, '-', (p_day + p_from) at time zone 'Europe/Helsinki',
          (p_day + p_from) at time zone 'Europe/Helsinki' + make_interval(hours => p_hours), p_role, 'active', 'open') returning id $$;
create function pg_temp.dg(p_staff uuid, p_day date) returns bigint language sql as $$
  select m.id from public.shift_offer_messages m join booking.shift_offer_message_meta mm on mm.message_id = m.id
   where mm.subkind = 'day_digest' and m.staff_id = p_staff and mm.digest_key = p_staff::text || ':' || p_day::text and m.dedupe_key like 'b153:digest:%'
   order by m.id desc limit 1 $$;
create function pg_temp.rc(p_offer uuid, p_staff uuid) returns bigint language sql as $$
  select id from public.shift_offer_recipients where offer_id = p_offer and staff_id = p_staff $$;
create function pg_temp.om(p_offer uuid, p_staff uuid) returns bigint language sql as $$
  select id from public.shift_offer_messages where offer_id = p_offer and staff_id = p_staff and kind = 'offer' and dedupe_key not like 'resend:%' order by id limit 1 $$;
create function pg_temp.fd(p timestamptz) returns text language sql as $$ select '(vastaa viimeistään ' || to_char(p at time zone 'Europe/Helsinki', 'DD.MM. HH24:MI') || ')' $$;
create function pg_temp.lbl(p_offer uuid) returns text language sql as $$
  select booking.shift_offer_cap_label(o.role_type) || ' ' || booking.shift_offer_when(coalesce(o.window_starts_at, w.starts_at), coalesce(o.window_ends_at, w.ends_at))
    from public.shift_offers o join public.work_shifts w on w.id = o.shift_id where o.id = p_offer $$;
-- tokenien allekirjoitusavain (oma sivu -linkki): olemassa oleva; puuttuessa vain tämän transaktion ajaksi
do $v$ begin
  if not exists (select 1 from vault.secrets where name = 'shift_offer_token_secret') then
    perform vault.create_secret('test-key-tdigest', 'shift_offer_token_secret', 'tdigest (kumoutuu)');
  end if;
end $v$;
do $t$
declare
  CS uuid; P1 uuid; P2 uuid; P5 uuid; t0 timestamptz; d1 date; j jsonb; v_n int; v_txt text;
  oA1 uuid; oA2 uuid; oB1 uuid; oB2 uuid; oC1 uuid; oC2 uuid; oD1 uuid; oD2 uuid; oE1 uuid; oE2 uuid;
  oF1 uuid; oF2 uuid; oG1 uuid; oG2 uuid; oH1 uuid; oJ1 uuid; oK1 uuid; oK2 uuid;
  g1 bigint; g2 bigint; g bigint; v_rs bigint; v_out bigint;
  e1 timestamptz; e2 timestamptz; e3 timestamptz; e4 timestamptz; v_far timestamptz; v_hz jsonb;
begin
  t0 := (((now() at time zone 'Europe/Helsinki')::date + 1) + time '12:00') at time zone 'Europe/Helsinki';
  d1 := (t0 at time zone 'Europe/Helsinki')::date + 30;

  -- ---------------- M: migraation jälki
  perform pg_temp.ck(to_regprocedure('booking.shift_offer_digest_items(bigint,timestamptz,boolean)') is not null
                     and to_regprocedure('booking.shift_offer_digest_body(uuid,date,text)') is not null
                     and to_regprocedure('booking.shift_offer_in_horizon(timestamptz)') is not null, 'M1: apufunktiot + horisonttifunktio olemassa');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.shift_offer_digest_items(bigint,timestamptz,boolean)', 'execute')
                     and not has_function_privilege('authenticated', 'booking.shift_offer_digest_body(uuid,date,text)', 'execute')
                     and has_function_privilege('service_role', 'booking.shift_offer_digest_items(bigint,timestamptz,boolean)', 'execute'),
                     'M2: apufunktiot vain service_role');

  -- ---------------- testidata
  insert into public.calendar_sources (calendar_name, role_type) values ('tdigest-testi', 'heater') returning id into CS;
  insert into public.staff (name, calendar_name, email, phone_e164, active, whatsapp_enabled, bot_channel)
  values ('Dora Digest', 'Dora Digest', 'dora.digest@example.test', '+358401990101', true, true, false) returning id into P1;
  insert into public.staff (name, calendar_name, email, phone_e164, active, whatsapp_enabled, bot_channel)
  values ('Daniel Digest', 'Daniel Digest', 'daniel.digest@example.test', null, true, false, false) returning id into P2;
  insert into public.staff (name, calendar_name, email, phone_e164, active, whatsapp_enabled, bot_channel)
  values ('Disa Digest', 'Disa Digest', 'disa.digest@example.test', '+358401990105', true, true, false) returning id into P5;
  insert into public.staff_roles (staff_id, role_type, active) values (P1, 'heater', true), (P2, 'heater', true), (P5, 'reception', true);
  delete from public.shift_offer_settings where role_type in ('heater', 'reception');
  insert into public.shift_offer_settings (role_type, enabled, auto_close_enabled, exhausted_ask_count) values
    ('heater', true, false, 3), ('reception', true, false, 3);
  delete from public.shift_offer_response_tiers;
  insert into public.shift_offer_response_tiers (role_type, min_lead, wait, wait_last_round, direct_to_all, note) values
    (null, interval '28 days', interval '3 days', null, false, 'tdigest 4 vk'),
    (null, interval '14 days', interval '2 days', null, false, 'tdigest 2–4 vk'),
    (null, interval '7 days', interval '24 hours', null, false, 'tdigest 1–2 vk'),
    (null, interval '2 days', interval '6 hours', interval '12 hours', false, 'tdigest 2–7 vrk'),
    (null, interval '0', null, null, true, 'tdigest alle 2 vrk');
  delete from public.shift_offer_rounds where role_type in ('heater', 'reception');
  insert into public.shift_offer_rounds (role_type, scenario, weekdays, round_no, kind) values
    ('heater', 'vacant_shift', '{1,2,3,4,5,6,7}', 1, 'named'), ('heater', 'vacant_shift', '{1,2,3,4,5,6,7}', 2, 'named'),
    ('reception', 'vacant_shift', '{1,2,3,4,5,6,7}', 1, 'named');
  insert into public.shift_offer_round_members (round_id, staff_id, sort_order)
  select r.id, m.s, m.o from public.shift_offer_rounds r
    join (values ('heater', 1, P1, 1), ('heater', 1, P2, 2), ('heater', 2, P1, 1), ('reception', 1, P5, 1)) m(role, rn, s, o)
      on m.role = r.role_type and m.rn = r.round_no;
  -- vain tämän transaktion ajaksi: lähetin päälle (dry run), P1+P5 allowlistalle, ikkuna koko vuorokausi, pohjat hyväksymättä, horisontti d1+20
  update public.shift_offer_engine_settings set sender_enabled = true, whatsapp_enabled = true, whatsapp_dry_run = true,
         whatsapp_allow_staff_ids = array[P1, P5] where id;
  update booking.settings set value = '{"start": "00:00", "end": "24:00"}' where key = 'shift_offer.whatsapp_hours';
  update booking.settings set value = jsonb_set(jsonb_set(value, '{offer,approved}', 'false'), '{day_digest,approved}', 'false') where key = 'shift_offer.wa_templates';
  update booking.settings set value = 'true' where key = 'shift_offer.email_enabled';
  v_hz := to_jsonb((d1 + 20)::text);
  insert into booking.settings (key, value) values ('shift_offer.offer_horizon_until', v_hz)
  on conflict (key) do update set value = excluded.value;
  -- muut jonossa olevat (tuotannossa oikeat) eivät häiritse: siirretään tämän transaktion ajaksi myöhemmäksi
  update public.shift_offer_messages set next_attempt_at = now() + interval '30 days' where status = 'queued';

  -- ---------------- #1 B2: kooste jatkaa jokaista yhdistettyä, näytetty määräaika = kirjattu (sähköposti P2, WhatsApp P1)
  oA1 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1, time '10:00', 4), t0, false)->>'offer_id')::uuid;
  oA2 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1, time '16:00', 4), t0, false)->>'offer_id')::uuid;
  update public.shift_offer_recipients set deadline_at = now() + interval '1 minute' where offer_id in (oA1, oA2);
  update public.shift_offer_messages set next_attempt_at = now() - interval '1 minute' where offer_id in (oA1, oA2) and status = 'queued';
  e1 := booking.shift_offer_deadline_preview(pg_temp.rc(oA1, P2), now()); e2 := booking.shift_offer_deadline_preview(pg_temp.rc(oA2, P2), now());
  e3 := booking.shift_offer_deadline_preview(pg_temp.rc(oA1, P1), now()); e4 := booking.shift_offer_deadline_preview(pg_temp.rc(oA2, P1), now());
  perform pg_temp.ck(e1 > now() + interval '1 day' and e3 > now() + interval '1 day', 'B0: esikatselu jatkaa (> 1 vrk)');
  j := public.shift_offer_sender_claim(50);
  g2 := pg_temp.dg(P2, d1); g1 := pg_temp.dg(P1, d1);
  perform pg_temp.ck((j->>'merged')::int >= 2 and g1 is not null and g2 is not null
                     and (select channel = 'email' from public.shift_offer_messages where id = g2)
                     and (select channel = 'whatsapp' and status = 'sending' from public.shift_offer_messages where id = g1), 'B1: koosteet P1 (WhatsApp) ja P2 (sähköposti): ' || left(j::text, 200));
  perform pg_temp.ck((select bool_and(status = 'skipped' and last_error = 'merged:' || g2) from public.shift_offer_messages where id in (pg_temp.om(oA1, P2), pg_temp.om(oA2, P2))),
                     'B1b: alkuperäiset skipped merged:<kooste>');
  select body into v_txt from public.shift_offer_messages where id = g2;
  perform pg_temp.ck(v_txt like 'Hei Daniel.' || E'\n' || 'Sinulle on useampi vuoroasia ' || to_char(d1, 'DD.MM.YYYY') || ': %'
                     and position(pg_temp.lbl(oA1) || ' ' || pg_temp.fd(e1) || '; ' || pg_temp.lbl(oA2) || ' ' || pg_temp.fd(e2) in v_txt) > 0
                     and v_txt like '%Vastaa omalla sivullasi: https://%token=%' and v_txt like '%–Tapio',
                     'B1c: koosteen määräajat = jatkettu esikatselu: ' || left(v_txt, 260));
  perform pg_temp.ck((select position((mm.payload->>'items') in v_txt) > 0 and mm.payload->>'rendered_at' is not null
                        from booking.shift_offer_message_meta mm where mm.message_id = g2), 'B1d: meta.items = tekstin rivit');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(j->'messages') x where (x->>'id')::bigint = g1
                              and position(pg_temp.fd(e3) in x->'digest'->>'items') > 0 and position(pg_temp.fd(e4) in x->'digest'->>'items') > 0),
                     'B1e: claimin WhatsApp-kooste: rivien määräajat = esikatselu hetkellä locked_at');
  perform pg_temp.ck((select bool_and(deadline_at = now() + interval '1 minute') from public.shift_offer_recipients where offer_id in (oA1, oA2)),
                     'B2a: claim / email_drain eivät vielä jatka');
  select id into v_out from booking.email_outbox where dedupe_key = 'b153:msg:' || g2::text;
  perform pg_temp.ck(v_out is not null and (select payload->>'text' from booking.email_outbox where id = v_out) = v_txt, 'B2b: sähköposti = koosteen teksti');
  update booking.email_outbox set status = 'sent', sent_at = now(), provider_id = 'test-provider' where id = v_out;
  perform pg_temp.ck((select deadline_at from public.shift_offer_recipients where id = pg_temp.rc(oA1, P2)) = e1
                     and (select deadline_at from public.shift_offer_recipients where id = pg_temp.rc(oA2, P2)) = e2,
                     'B2c: sähköpostikooste sent → MOLEMMAT yhdistetyt jatkettu täsmälleen näytettyyn aikaan');
  perform pg_temp.ck((select count(*) = 3 from public.shift_offer_messages where id in (g2, pg_temp.om(oA1, P2), pg_temp.om(oA2, P2)) and deadline_extended_at is not null),
                     'B2d: deadline_extended_at koosteelle ja molemmille alkuperäisille');
  update public.shift_offer_recipients set deadline_at = now() + interval '2 minutes' where offer_id in (oA1, oA2) and staff_id = P2;
  update booking.email_outbox set status = 'pending' where id = v_out;
  update booking.email_outbox set status = 'sent' where id = v_out;
  perform pg_temp.ck((select bool_and(deadline_at = now() + interval '2 minutes') from public.shift_offer_recipients where offer_id in (oA1, oA2) and staff_id = P2),
                     'B2e: toinen sent ei jatka uudelleen (idempotentti)');
  perform pg_temp.ck(booking.shift_offer_deadline_on_sent(g2, now()) is null, 'B2f: deadline_on_sent uudelleen → ei mitään');
  j := public.shift_offer_sender_complete(jsonb_build_object('id', g1, 'action', 'sent', 'wamid', 'wamid.TDIGEST1', 'channel', 'whatsapp'));
  perform pg_temp.ck(j->>'status' = 'sent' and (select deadline_at from public.shift_offer_recipients where id = pg_temp.rc(oA1, P1)) = e3
                     and (select deadline_at from public.shift_offer_recipients where id = pg_temp.rc(oA2, P1)) = e4,
                     'B2g: WhatsApp-kooste sent (sender_complete) → molemmat jatkettu näytettyyn aikaan');
  j := public.shift_offer_sender_complete(jsonb_build_object('id', g1, 'action', 'sent', 'wamid', 'wamid.TDIGEST1'));
  perform pg_temp.ck((select deadline_at from public.shift_offer_recipients where id = pg_temp.rc(oA1, P1)) = e3, 'B2h: uusinta-sent ei jatka toiste');

  -- ---------------- #2 resend_lost: päätös kaikista yhdistetyistä, teksti avoimista
  oB1 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1 + 1, time '10:00', 4), t0, false)->>'offer_id')::uuid;
  oB2 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1 + 1, time '16:00', 4), t0, false)->>'offer_id')::uuid;
  update public.shift_offer_recipients set deadline_at = now() + interval '1 minute' where offer_id in (oB1, oB2);
  update public.shift_offer_messages set next_attempt_at = now() - interval '1 minute' where offer_id in (oB1, oB2) and status = 'queued';
  j := public.shift_offer_sender_claim(50);
  g := pg_temp.dg(P1, d1 + 1);
  j := public.shift_offer_sender_complete(jsonb_build_object('id', g, 'action', 'fail', 'error', 'wa_131026'));
  perform pg_temp.ck(j->>'status' = 'failed' and (select bool_and(deadline_at = now() + interval '1 minute') from public.shift_offer_recipients where offer_id in (oB1, oB2) and staff_id = P1),
                     'R0: epäonnistunut kooste ei jatka määräaikoja');
  -- ensimmäinen (koosteen offer_id) suljettu henkilölle, toinen yhä auki
  update public.shift_offer_recipients set status = 'declined' where id = pg_temp.rc(oB1, P1);
  e1 := booking.shift_offer_deadline_preview(pg_temp.rc(oB2, P1), now());
  v_n := booking.shift_offer_resend_lost(now());
  select id into v_rs from public.shift_offer_messages where dedupe_key = 'resend:' || g::text;
  select body into v_txt from public.shift_offer_messages where id = v_rs;
  perform pg_temp.ck(v_rs is not null and (select channel = 'email' and status = 'queued' and kind = 'alert' and offer_id = oB2 from public.shift_offer_messages where id = v_rs)
                     and (select resent_message_id = v_rs from public.shift_offer_messages where id = g),
                     'R1: kadonnut kooste → sähköposti kerran, offer_id = ensimmäinen AVOIN');
  perform pg_temp.ck(v_txt is distinct from (select body from public.shift_offer_messages where id = g)
                     and position(pg_temp.lbl(oB2) || ' ' || pg_temp.fd(e1) in v_txt) > 0 and position(pg_temp.lbl(oB1) in v_txt) = 0
                     and v_txt like 'Hei Dora.%Vastaa omalla sivullasi: https://%', 'R2: teksti rakennettu uudelleen vain avoimista: ' || left(coalesce(v_txt, '-'), 220));
  perform pg_temp.ck((select mm.subkind = 'day_digest' and mm.payload->'merged_ids' = jsonb_build_array(pg_temp.om(oB2, P1))
                             and mm.payload->'recipient_ids' = jsonb_build_array(pg_temp.rc(oB2, P1)) and (mm.payload->>'resent_from')::bigint = g
                             and position(mm.payload->>'items' in v_txt) > 0
                        from booking.shift_offer_message_meta mm where mm.message_id = v_rs), 'R3: meta: merged_ids/recipient_ids vain avoimet, resent_from');
  v_n := booking.shift_offer_email_drain(50);
  select id into v_out from booking.email_outbox where dedupe_key = 'b153:msg:' || v_rs::text;
  update booking.email_outbox set status = 'sent', sent_at = now() where id = v_out;
  perform pg_temp.ck((select deadline_at from public.shift_offer_recipients where id = pg_temp.rc(oB2, P1)) = e1
                     and (select deadline_extended_at is null from public.shift_offer_messages where id = pg_temp.om(oB1, P1)),
                     'R4: uudelleenlähetetty kooste sent → avoin jatkettu näytettyyn aikaan, suljettua ei käsitellä');
  v_n := booking.shift_offer_resend_lost(now());
  perform pg_temp.ck((select count(*) from public.shift_offer_messages where dedupe_key = 'resend:' || g::text) = 1, 'R5: ei toista uudelleenlähetystä');
  -- kaikki suljettu → ei uudelleenlähetystä
  oC1 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1 + 2, time '10:00', 4), t0, false)->>'offer_id')::uuid;
  oC2 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1 + 2, time '16:00', 4), t0, false)->>'offer_id')::uuid;
  update public.shift_offer_messages set next_attempt_at = now() - interval '1 minute' where offer_id in (oC1, oC2) and status = 'queued';
  j := public.shift_offer_sender_claim(50);
  g := pg_temp.dg(P1, d1 + 2);
  j := public.shift_offer_sender_complete(jsonb_build_object('id', g, 'action', 'fail', 'error', 'wa_131026'));
  update public.shift_offer_recipients set status = 'declined' where id in (pg_temp.rc(oC1, P1), pg_temp.rc(oC2, P1));
  v_n := booking.shift_offer_resend_lost(now());
  perform pg_temp.ck(g is not null and not exists (select 1 from public.shift_offer_messages where dedupe_key = 'resend:' || g::text)
                     and (select resent_message_id is null from public.shift_offer_messages where id = g), 'R6: kaikki yhdistetyt suljettu → ei uudelleenlähetystä');
  -- vain jälkimmäinen suljettu (koosteen offer_id auki) toimii samoin kuin ennen; tarjous peruttu kokonaan = suljettu
  update public.shift_offer_recipients set status = 'pending' where id = pg_temp.rc(oC2, P1);
  update public.shift_offers set status = 'cancelled' where id = oC2;
  v_n := booking.shift_offer_resend_lost(now());
  perform pg_temp.ck(not exists (select 1 from public.shift_offer_messages where dedupe_key = 'resend:' || g::text), 'R7: peruttu tarjous ei ole auki → ei uudelleenlähetystä');

  -- ---------------- #3 yö / hyväksymätön pohja: kuten tarjous (B4/C1)
  perform pg_temp.ck(not booking.shift_offer_wa_ready(P1, 'alert', 'day_digest') and not booking.shift_offer_wa_ready(P1, 'offer', null),
                     'N1: hyväksymätön day_digest-pohja ei kelpaa (kuten offer)');
  update booking.settings set value = jsonb_set(value, '{day_digest,approved}', 'true') where key = 'shift_offer.wa_templates';
  perform pg_temp.ck(booking.shift_offer_wa_ready(P1, 'alert', 'day_digest') and not booking.shift_offer_wa_ready(P2, 'alert', 'day_digest'),
                     'N2: hyväksytty pohja kelpaa; ei WhatsAppia → ei');
  update booking.settings set value = jsonb_set(value, '{day_digest,name}', '"Huono Nimi"') where key = 'shift_offer.wa_templates';
  perform pg_temp.ck(not booking.shift_offer_wa_ready(P1, 'alert', 'day_digest'), 'N3: virheellinen pohjan nimi ei kelpaa');
  update booking.settings set value = jsonb_set(jsonb_set(value, '{day_digest,name}', '"tyovuoro_paivan_kooste"'), '{day_digest,approved}', 'false') where key = 'shift_offer.wa_templates';
  update booking.settings set value = '{"start": "00:00", "end": "00:00"}' where key = 'shift_offer.whatsapp_hours';   -- yö koko ajan
  oD1 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1 + 3, time '10:00', 4), t0, false)->>'offer_id')::uuid;
  oD2 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1 + 3, time '16:00', 4), t0, false)->>'offer_id')::uuid;
  update public.shift_offer_messages set next_attempt_at = now() - interval '1 minute' where offer_id in (oD1, oD2) and status = 'queued';
  j := public.shift_offer_sender_claim(50);
  g := pg_temp.dg(P1, d1 + 3);
  perform pg_temp.ck(not (j->>'whatsapp_hours_open')::boolean
                     and exists (select 1 from jsonb_array_elements(j->'messages') x where (x->>'id')::bigint = g and x->>'subkind' = 'day_digest')
                     and (select status = 'sending' from public.shift_offer_messages where id = g),
                     'N4: yöllä hyväksymätön kooste poimitaan heti (edge → sähköposti heti, kuten tarjous)');
  update booking.settings set value = jsonb_set(value, '{day_digest,approved}', 'true') where key = 'shift_offer.wa_templates';
  oE1 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1 + 4, time '10:00', 4), t0, false)->>'offer_id')::uuid;
  oE2 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1 + 4, time '16:00', 4), t0, false)->>'offer_id')::uuid;
  update public.shift_offer_messages set next_attempt_at = now() - interval '1 minute' where offer_id in (oE1, oE2) and status = 'queued';
  j := public.shift_offer_sender_claim(50);
  g := pg_temp.dg(P1, d1 + 4);
  perform pg_temp.ck(g is not null and not exists (select 1 from jsonb_array_elements(j->'messages') x where (x->>'id')::bigint = g)
                     and (select status = 'queued' from public.shift_offer_messages where id = g), 'N5: yöllä hyväksytty kooste odottaa aamuun (kuten tarjous)');
  update public.shift_offer_messages set status = 'skipped', last_error = 'tdigest-clean' where id = g;
  update booking.settings set value = jsonb_set(value, '{day_digest,approved}', 'false') where key = 'shift_offer.wa_templates';
  update booking.settings set value = '{"start": "00:00", "end": "24:00"}' where key = 'shift_offer.whatsapp_hours';

  -- ---------------- #4 horisontti: skipped 'horizon', ei koosteeseen eikä yksittäin (fail-closed)
  oG1 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1 + 11, time '10:00', 4), t0, false)->>'offer_id')::uuid;
  oG2 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1 + 11, time '16:00', 4), t0, false)->>'offer_id')::uuid;
  oF1 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1 + 12, time '10:00', 4), t0, false)->>'offer_id')::uuid;
  oF2 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1 + 12, time '16:00', 4), t0, false)->>'offer_id')::uuid;
  oH1 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1 + 13, time '10:00', 4), t0, false)->>'offer_id')::uuid;
  oJ1 := (public.shift_offer_ensure(pg_temp.sh(CS, 'heater', d1 + 5, time '10:00', 4), t0, false)->>'offer_id')::uuid;
  perform pg_temp.ck(oG1 is not null and oF2 is not null and oH1 is not null and oJ1 is not null, 'H0: tarjoukset horisontin sisällä (d1+20)');
  update public.shift_offer_messages set next_attempt_at = now() - interval '1 minute' where offer_id in (oG1, oG2) and status = 'queued';
  update public.shift_offer_messages set next_attempt_at = now() + interval '1 hour' where offer_id in (oF1, oF2, oH1, oJ1) and status = 'queued';
  v_n := booking.shift_offer_merge_same_day(now());
  g := pg_temp.dg(P1, d1 + 11);
  perform pg_temp.ck(v_n = 2 and g is not null and (select status = 'queued' from public.shift_offer_messages where id = g), 'H1: kooste d1+11 jonossa');
  -- jonossa olevan koosteen piirto uudelleen: määräaika muuttuu → teksti ja items seuraavat (näytetty = kirjattava)
  v_far := date_trunc('minute', now()) + interval '10 days';
  update public.shift_offer_recipients set deadline_at = v_far where id = pg_temp.rc(oG1, P1);
  v_n := booking.shift_offer_merge_same_day(now());
  perform pg_temp.ck((select position(pg_temp.lbl(oG1) || ' ' || pg_temp.fd(v_far) in m.body) > 0 and position(pg_temp.fd(v_far) in mm.payload->>'items') > 0
                        from public.shift_offer_messages m join booking.shift_offer_message_meta mm on mm.message_id = m.id where m.id = g),
                     'H2: jonossa oleva kooste piirretään uudelleen (uusi määräaika tekstissä ja itemsissä)');
  update booking.settings set value = to_jsonb((d1 + 10)::text) where key = 'shift_offer.offer_horizon_until';
  v_n := booking.shift_offer_merge_same_day(now());
  perform pg_temp.ck(v_n = 0 and (select count(*) = 4 from public.shift_offer_messages where offer_id in (oF1, oF2) and status = 'skipped' and last_error = 'horizon')
                     and pg_temp.dg(P1, d1 + 12) is null and pg_temp.dg(P2, d1 + 12) is null,
                     'H3: horisontin ulkopuoliset jonossa olevat → skipped horizon, ei koostetta');
  perform pg_temp.ck((select count(*) = 2 from public.shift_offer_messages where offer_id = oH1 and status = 'skipped' and last_error = 'horizon'),
                     'H4: yksittäinen horisontin ulkopuolinen → skipped horizon (ei lähde yksittäin)');
  perform pg_temp.ck((select status = 'skipped' and last_error = 'horizon' from public.shift_offer_messages where id = g)
                     and (select status = 'skipped' and last_error = 'horizon' from public.shift_offer_messages where id = pg_temp.dg(P2, d1 + 11)),
                     'H5: jonossa oleva kooste, jonka kaikki rivit horisontin ulkopuolella → skipped horizon');
  perform pg_temp.ck((select bool_and(status = 'queued') from public.shift_offer_messages where offer_id = oJ1), 'H6: horisontin sisällä oleva ennallaan');
  delete from booking.settings where key = 'shift_offer.offer_horizon_until';
  v_n := booking.shift_offer_merge_same_day(now());
  perform pg_temp.ck((select bool_and(status = 'skipped' and last_error = 'horizon') from public.shift_offer_messages where offer_id = oJ1),
                     'H7: horisonttiasetus puuttuu → fail-closed (skipped horizon)');
  insert into booking.settings (key, value) values ('shift_offer.offer_horizon_until', v_hz);

  -- ---------------- R: report_issues — kooste ilman toimivaa kanavaa lasketaan jokaisena yhdistettynä tarjouksena
  oK1 := (public.shift_offer_ensure(pg_temp.sh(CS, 'reception', d1 + 6, time '10:00', 4), t0, false)->>'offer_id')::uuid;
  oK2 := (public.shift_offer_ensure(pg_temp.sh(CS, 'reception', d1 + 6, time '15:00', 4), t0, false)->>'offer_id')::uuid;
  perform pg_temp.ck((select count(*) = 2 from public.shift_offer_messages where staff_id = P5 and status = 'queued' and channel = 'whatsapp'), 'I0: P5 kaksi WhatsApp-tarjousta jonossa');
  update public.shift_offer_messages set next_attempt_at = now() - interval '1 minute' where staff_id = P5 and status = 'queued';
  update public.staff set phone_e164 = null, whatsapp_enabled = false, email = 'disa.digest@' where id = P5;
  j := public.shift_offer_sender_claim(50);
  g := pg_temp.dg(P5, d1 + 6);
  perform pg_temp.ck((select status = 'failed_no_contact' and last_error = 'no_working_channel' from public.shift_offer_messages where id = g),
                     'I1: kooste ilman kanavaa → failed_no_contact (alkuperäiset merged)');
  j := booking.shift_offer_report_issues(now() - interval '1 day');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(j->'no_working_channel') x where x->>'staff_id' = P5::text
                              and (x->>'offers_skipped')::int = 2 and x->'roles' = '["reception"]'::jsonb),
                     'I2: no_working_channel laskee molemmat yhdistetyt tarjoukset: ' || left(coalesce((select x::text from jsonb_array_elements(j->'no_working_channel') x where x->>'staff_id' = P5::text), '-'), 200));

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from tdigest_r where ok), (select count(*) from tdigest_r where not ok),
    coalesce((select string_agg(label, ' || ') from tdigest_r where not ok), '-')
    using errcode = 'TRBK0';
end $t$;
