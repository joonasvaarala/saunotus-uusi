-- t153: vuorotarjousmoottorin sääntömuutokset (booking_153) ja henkilökunnan oma sivu.
-- Säännöt 1–8 sekä a, d, e, f, h; oman sivun token (muut eivät näy, uusinta ja peruutus), tervetuloviesti (kerran,
-- vain 24 h ikkunassa, asetus pois = ei viestiä, tuntematon numero = ei viestiä). Ajan kulku simuloidaan p_now-parametrilla.
-- Kaikki data on feikkiä (@example.test). Mitään ei lähetetä: viestit jäävät outboxiin, sähköposti email_outboxiin.
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN. Yksi DO-lohko; lopun poikkeus kumoaa kaiken.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table t153_r(ok boolean, label text) on commit drop;
grant all on t153_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t153_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.msg(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'NO ERROR'; exception when others then return sqlerrm; end $$;
insert into vault.decrypted_secrets (name, decrypted_secret) values ('shift_offer_token_secret', 'test-key-153')
on conflict (name) do update set decrypted_secret = excluded.decrypted_secret;
do $t$
declare
  H1 uuid := 'bbbbbbbb-0153-4000-8000-0000000000a1'; H2 uuid := 'bbbbbbbb-0153-4000-8000-0000000000a2'; H3 uuid := 'bbbbbbbb-0153-4000-8000-0000000000a3';
  T1 uuid := 'bbbbbbbb-0153-4000-8000-0000000000b1'; T2 uuid := 'bbbbbbbb-0153-4000-8000-0000000000b2';
  JO uuid := 'bbbbbbbb-0153-4000-8000-0000000000d1'; OT uuid := 'bbbbbbbb-0153-4000-8000-0000000000c1'; LA uuid := 'bbbbbbbb-0153-4000-8000-0000000000c2';
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
    (H1, 'Hilma Testi', 'hilma153@example.test', '+358401530001', true, true, false),
    (H2, 'Heikki Testi', 'heikki153@example.test', '+358401530002', true, false, false),
    (H3, 'Hanna Testi', 'hanna153@example.test', '+358401530003', true, true, false),
    (T1, 'Tiina Testi', 'tiina153@example.test', null, true, false, false),
    (T2, 'Terhi Testi', 'terhi153@example.test', null, true, false, false),
    (JO, 'Joonas Testi', 'joonas153@example.test', null, true, false, true),
    (OT, 'Otto Testi', 'otto153@example.test', null, true, false, false),
    (LA, 'Laura Testi', 'laura153@example.test', null, true, false, false);
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

  -- ---------------- oletukset
  perform pg_temp.ck(not booking.shift_offer_cfg_bool('email_enabled', true) and not booking.shift_offer_cfg_bool('offer_uncertain_shifts', true)
                     and not booking.shift_offer_cfg_bool('welcome_enabled', true) and (not booking.shift_offer_cfg_bool('already_taken_message', true)
                          -- booking_155 kääntää oletuksen päälle (Joonaksen päätös 4)
                          or exists (select 1 from pg_proc where oid = to_regprocedure('booking._shift_offer_already_taken_mail()')))
                     and booking.shift_offer_cfg_bool('unavailability_frees_shift', false), 'D1: oletukset (sähköposti, ?-vuorot, tervetulo, jo mennyt -viesti pois ennen booking_155:ttä; poissaolo päällä)');
  perform pg_temp.ck((booking.shift_offer_cfg('wa_templates') #>> '{offer,name}') = 'tyovuoro_kysely' and (booking.shift_offer_cfg('wa_templates') #>> '{offer,approved}') = 'false'
                     and (booking.shift_offer_cfg('wa_templates') #>> '{offer,fallback}') = 'vuorotarjous', 'D2: pääpohja tyovuoro_kysely (ei hyväksytty), varapohja vuorotarjous');
  -- a: Otto voi jo olla Resendin allowlistalla (tuotannossa on); sähköpostit estää shift_offer.email_enabled = false, ei allowlista
  perform pg_temp.ck(booking.shift_offer_email(OT, 't153 a', 'x', 't153-a') is null
                     and not exists (select 1 from booking.email_outbox e where e.dedupe_key = 'b153:t153-a'), 'a: email_enabled=false → ei sähköpostia Otolle allowlistasta riippumatta');
  perform pg_temp.ck((select p.prosecdef and p.proconfig @> array['search_path=""'] from pg_proc p where p.oid = 'booking.shift_staff_page(text)'::regprocedure)
                     and not has_function_privilege('anon', 'booking.shift_staff_page(text)', 'execute')
                     and not has_function_privilege('authenticated', 'booking.shift_staff_page(text)', 'execute')
                     and has_function_privilege('service_role', 'booking.shift_staff_page(text)', 'execute'), 'P0: oma sivu vain service_rolelle (edge), security definer');
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.shift_staff_welcome(uuid)', 'execute') and not has_function_privilege('anon', 'booking.admin_shift_staff_link(uuid, text)', 'execute'),
                     'P0b: anon ei kutsu tervetulo- eikä hallintafunktiota');

  -- ---------------- 2: viimeisen kierroksen takaraja
  v_st := (d1 + time '10:00') at time zone 'Europe/Helsinki';
  perform pg_temp.ck(public.shift_offer_round_deadline('heater', v_st, t0, 'named', true) = v_st - interval '14 days', '2a: lämmittäjän viimeinen kierros päättyy 14 pv ennen');
  perform pg_temp.ck(public.shift_offer_round_deadline('therapist', v_st, t0, 'named', true) = v_st - interval '21 days', '2b: hoitajan viimeinen kierros päättyy 21 pv ennen');
  perform pg_temp.ck(public.shift_offer_round_deadline('reception', v_st, t0, 'named', true) = v_st - interval '14 days', '2c: vastaanotto oletus 14 pv (asetus)');
  update booking.settings set value = '{"heater":"14 days","therapist":"21 days","reception":"10 days"}' where key = 'shift_offer.last_round_before';
  perform pg_temp.ck(public.shift_offer_round_deadline('reception', v_st, t0, 'named', true) = v_st - interval '10 days', '2d: vastaanoton raja tulee asetuksesta');
  update booking.settings set value = '{"heater":"14 days","therapist":"21 days","reception":"14 days"}' where key = 'shift_offer.last_round_before';
  perform pg_temp.ck(public.shift_offer_round_deadline('heater', v_st, t0, 'named', false) = least(t0 + ((v_st - interval '14 days') - t0) / 2, (select w.deadline_at from public.shift_offer_wait('heater', v_st, t0, false) w)), '2e: aiempi kierros: portaan aika, enintään puoliväliin takarajasta');
  v_t := t0 + interval '18 days';
  perform pg_temp.ck(public.shift_offer_round_deadline('heater', (d1 + 6 + time '10:00') at time zone 'Europe/Helsinki', t0 + interval '18 days', 'named', true)
                     = (select w.deadline_at from public.shift_offer_wait('heater', (d1 + 6 + time '10:00') at time zone 'Europe/Helsinki', t0 + interval '18 days', true) w),
                     '2f: alle 3 vk ennen alkava tarjous käyttää portaita');

  -- ---------------- 1: täytetty vuoro, myöhäinen hyväksyjä
  insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
    (S1, v_st, (d1 + time '18:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'open');
  j := public.shift_offer_ensure(S1, t0, false);
  v_o := (j->>'offer_id')::uuid;
  perform pg_temp.ck(j->>'action' = 'offered' and (j->>'recipients')::int = 2, '1a: tarjous lähti kahdelle: ' || j::text);
  perform pg_temp.ck((select deadline_at from public.shift_offer_recipients where offer_id = v_o and staff_id = H1) <= t0 + ((v_st - interval '14 days') - t0) / 2,
                     '2g: ensimmäinen kierros päättyy ennen 14 pv rajaa');
  update booking.settings set value = 'true' where key = 'shift_offer.already_taken_message';
  j := public.shift_offer_respond(v_o, H1, 'accept', null, false, 'test');
  perform pg_temp.ck(j->>'result' = 'accepted' and j->'notify_filled_staff_ids' = '[]'::jsonb, '1b: hyväksyntä ei listaa muita ilmoitettaviksi');
  j := public.shift_offer_engine_respond(v_o, H1, 'accept', null, null);
  perform pg_temp.ck(not exists (select 1 from public.shift_offer_messages m where m.offer_id = v_o and m.kind = 'filled'), '1c: muille ei jonoon "täytetty"-viestiä');
  j := public.shift_offer_respond(v_o, H2, 'accept', null, false, 'test');
  perform pg_temp.ck(j->>'result' = 'already_filled', '1d: myöhäinen hyväksyjä saa tiedon, että vuoro on mennyt');
  perform pg_temp.ck((select count(*) from public.shift_offer_messages m join booking.shift_offer_message_meta mm on mm.message_id = m.id
                       where m.offer_id = v_o and m.staff_id = H2 and mm.subkind = 'already_taken' and m.body like '%jo mennyt%' and m.body like '%–Tapio') = 1,
                     '1e: asetuksella myöhäinen hyväksyjä saa "jo mennyt" -viestin (vain hän)');
  perform pg_temp.ck(not exists (select 1 from public.shift_offer_messages m where m.offer_id = v_o and m.staff_id not in (H1, H2) and m.kind = 'filled'), '1f: muut eivät saa mitään');
  update booking.settings set value = 'false' where key = 'shift_offer.already_taken_message';

  -- ---------------- 8: kieltäytyjä ja saman päivän toinen vuoro
  insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
    (S2, (d2 + time '08:00') at time zone 'Europe/Helsinki', (d2 + time '12:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'open'),
    (S3, (d2 + time '14:00') at time zone 'Europe/Helsinki', (d2 + time '18:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'open');
  j := public.shift_offer_ensure(S2, t0, false); v_o := (j->>'offer_id')::uuid;
  j := public.shift_offer_respond(v_o, H1, 'decline', null, false, 'test');
  j := public.shift_offer_ensure(S3, t0, false); v_o2 := (j->>'offer_id')::uuid;
  perform pg_temp.ck(not exists (select 1 from public.shift_offer_recipients r where r.offer_id = v_o2 and r.staff_id = H1)
                     and exists (select 1 from public.shift_offer_recipients r where r.offer_id = v_o2 and r.staff_id = H2), '8a: saman päivän toista vuoroa ei tarjota kieltäytyneelle');
  -- H2 vastasi myöhässä S1:een ja kieltäytyy nyt S2:sta → jatkokierroksessa ei viestiä
  j := public.shift_offer_respond(v_o, H2, 'decline', null, false, 'test');
  j := public.shift_offer_ensure(S2, t0 + interval '1 minute', false);
  perform pg_temp.ck(not exists (select 1 from public.shift_offer_messages m where m.offer_id = v_o and m.staff_id in (H1, H2) and m.created_at is not null and m.kind <> 'offer'),
                     '8b: kieltäytyneille ei uusia viestejä saman vuoron jatkokierroksista');
  perform pg_temp.ck(exists (select 1 from public.shift_offer_recipients r where r.offer_id = v_o and r.staff_id = H3), '8c: jatkokierros eteni seuraavalle (H3)');

  -- oma sivu
  v_tok := booking.shift_staff_page_token(H1, true);
  perform pg_temp.ck(length(v_tok) > 100, 'P1: pitkä satunnainen token');
  j := booking.shift_staff_page(v_tok);
  perform pg_temp.ck((j->>'ok')::boolean and j->>'name' = 'Hilma', 'P2: sivu aukeaa omalla tokenilla');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(j->'answered') a where a->>'offer_id' = v_o::text and a->>'my_status' = 'declined' and (a->>'can_accept')::boolean),
                     'P3: vastatuissa kieltäytyminen, jonka voi muuttaa');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(j->'answered') a where a->>'my_status' = 'accepted'), 'P4: hyväksytty vuoro näkyy');
  perform pg_temp.ck(j::text !~ '(Heikki|Hanna|Tiina|Terhi|Joonas|Otto|Laura|winner|bbbbbbbb-0153-4000-8000-0000000000a2)', 'P5: sivulla ei muiden nimiä eikä tunnisteita');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(j->'open') a where a->>'offer_id' = v_o2::text)
                     and not exists (select 1 from jsonb_array_elements(j->'answered') a where a->>'offer_id' = v_o2::text), 'P6: muiden tarjoukset eivät näy');
  v_tok2 := booking.shift_staff_page_token(H2, true);
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(booking.shift_staff_page(v_tok2)->'open') a where a->>'offer_id' = v_o2::text), 'P7: H2 näkee oman avoimen tarjouksensa');
  perform pg_temp.ck(booking.shift_staff_page(v_tok || 'x')->>'error' = 'bad_token' and booking.shift_staff_page(split_part(v_tok, '.', 1) || '.' || split_part(v_tok2, '.', 2))->>'error' = 'bad_token'
                     and booking.shift_staff_page('')->>'error' = 'bad_token' and booking.shift_staff_page(null)->>'error' = 'bad_token', 'P8: väärennetty / vaihdettu token hylätään');
  j := booking.shift_staff_page_respond(v_tok, v_o2, 'accept');
  perform pg_temp.ck(j->>'result' = 'not_owner', 'P9: toisen tarjoukseen ei voi vastata');
  j := booking.shift_staff_page_respond(v_tok, v_o, 'accept');
  perform pg_temp.ck(j->>'result' = 'accepted' and (j->'page'->>'ok')::boolean, '8d/P10: kieltäytymisen voi muuttaa hyväksynnäksi omalla sivulla');
  j := booking.shift_staff_page_respond(v_tok2, v_o, 'accept');
  perform pg_temp.ck(j->>'result' = 'already_taken' and j::text !~ 'Hilma', 'P11: myöhäinen hyväksyjä omalla sivulla: jo mennyt, ei voittajan nimeä');
  -- hallinta: uusinta ja peruutus
  insert into auth.users(id, email) select gen_random_uuid(), 'adm153@example.test' where not exists (select 1 from auth.users u where u.email = 'adm153@example.test');
  v_adm := test.mk_staff('adm153@example.test', 'admin');
  perform test.login(v_adm);
  j := booking.admin_shift_staff_link(H1, 'renew');
  perform test.logout();
  perform pg_temp.ck(booking.shift_staff_page(v_tok)->>'error' = 'bad_token' and (booking.shift_staff_page(split_part(j->>'url', 'token=', 2))->>'ok')::boolean,
                     'P12: uusittu linkki toimii, vanha lakkaa');
  v_tok := split_part(j->>'url', 'token=', 2);
  perform test.login(v_adm);
  j := booking.admin_shift_staff_link(H1, 'revoke');
  perform test.logout();
  perform pg_temp.ck(booking.shift_staff_page(v_tok)->>'error' = 'bad_token' and booking.shift_staff_page_token(H1, true) is null, 'P13: peruttu linkki ei toimi eikä uutta synny automaattisesti');
  perform test.login(v_adm);
  j := booking.admin_shift_staff_link(H1, 'issue');
  perform test.logout();
  perform pg_temp.ck((booking.shift_staff_page(split_part(j->>'url', 'token=', 2))->>'ok')::boolean and split_part(j->>'url', 'token=', 2) <> v_tok, 'P14: uudelleen myönnetty linkki on uusi');
  perform pg_temp.ck(pg_temp.msg($q$select booking.admin_shift_staff_link('bbbbbbbb-0153-4000-8000-0000000000a1', 'renew')$q$) <> 'NO ERROR', 'P15: ilman staff.manage-oikeutta ei hallintaa');

  -- ---------------- 7: kierroksen loppumuistutus
  insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
    (S4, (d8 + time '10:00') at time zone 'Europe/Helsinki', (d8 + time '18:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'open');
  j := public.shift_offer_ensure(S4, t0, false); v_o := (j->>'offer_id')::uuid;
  select deadline_at into v_dl from public.shift_offer_recipients where offer_id = v_o and staff_id = H1;
  j := public.shift_offer_respond(v_o, H2, 'decline', null, false, 'test');
  j := public.shift_offer_ensure(S4, v_dl - interval '13 hours', false);
  perform pg_temp.ck(j->>'action' = 'waiting', '7a: ennen muistutushetkeä ei muistutusta');
  j := public.shift_offer_ensure(S4, v_dl - interval '11 hours', false);
  perform pg_temp.ck(j->>'action' = 'round_reminded' and (j->>'count')::int = 1, '7b: muistutus vain vastaamattomalle: ' || j::text);
  perform pg_temp.ck((select count(*) from public.shift_offer_messages m join booking.shift_offer_message_meta mm on mm.message_id = m.id
                       where m.offer_id = v_o and mm.subkind = 'round_reminder' and m.staff_id = H1 and m.kind = 'reminder') = 1
                     and not exists (select 1 from public.shift_offer_messages m where m.offer_id = v_o and m.staff_id = H2 and m.kind = 'reminder'), '7c: muistutus H1:lle, ei kieltäytyneelle H2:lle');
  j := public.shift_offer_ensure(S4, v_dl - interval '10 hours', false);
  perform pg_temp.ck(j->>'action' = 'waiting', '7d: muistutus vain kerran');

  -- ---------------- 3: lämmittäjä ilman tekijää
  v_st := (d5 + time '10:00') at time zone 'Europe/Helsinki';
  insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
    (S5, v_st, (d5 + time '18:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'open');
  j := public.shift_offer_ensure(S5, t0, false); v_o := (j->>'offer_id')::uuid;
  perform public.shift_offer_respond(v_o, H1, 'decline', null, false, 'test');
  perform public.shift_offer_respond(v_o, H2, 'decline', null, false, 'test');
  j := public.shift_offer_ensure(S5, t0 + interval '1 minute', false);
  perform pg_temp.ck(j->>'action' = 'advanced', '3a: kaikki kieltäytyivät → seuraava kierros');
  perform public.shift_offer_respond(v_o, H3, 'decline', null, false, 'test');
  j := public.shift_offer_ensure(S5, t0 + interval '2 minutes', false);
  perform pg_temp.ck(j->>'action' = 'vacant_notice' and j->>'stage' = 'vacant', '3b: ilman tekijää → ilmoitus: ' || j::text);
  perform pg_temp.ck(exists (select 1 from public.shift_offer_messages m where m.offer_id = v_o and m.staff_id = JO and m.status = 'bot_channel' and m.body like '%ilman tekijää%'),
                     '3c: Joonakselle chat-ilmoitus (bot_channel)');
  perform pg_temp.ck(not exists (select 1 from booking.email_outbox e where e.kind = 'staff_shift_notice'), '3d: sähköposti pois päältä → ei sähköpostia Otolle');
  perform pg_temp.ck(not exists (select 1 from public.shift_offer_messages m where m.offer_id = v_o and m.kind = 'exhausted_ask'), '3e: vanha 3 kysymyksen kierto ei käynnisty');
  perform pg_temp.ck((select next_action_at from public.shift_offers where id = v_o) = least(t0 + interval '2 minutes' + interval '3 days', v_st - interval '7 days'), '3f: muistutus 3 pv päästä tai 7 pv ennen');
  update booking.settings set value = 'true' where key = 'shift_offer.email_enabled';
  j := public.shift_offer_ensure(S5, t0 + interval '2 days', false);
  perform pg_temp.ck(j->>'action' = 'waiting', '3g: ennen muistutusta odotetaan');
  j := public.shift_offer_ensure(S5, t0 + interval '3 days 3 minutes', false);
  perform pg_temp.ck(j->>'stage' = 'vacant_r1', '3h: muistutus 3 pv päästä: ' || j::text);
  perform pg_temp.ck(exists (select 1 from booking.email_outbox e where e.kind = 'staff_shift_notice' and e.payload->>'to_email' = 'otto153@example.test' and e.payload->>'text' like '%–Tapio'
                             and e.status = 'pending'), '3i: asetuksella sähköposti Otolle (Resend dry_run → pending)');
  perform pg_temp.ck((select next_action_at from public.shift_offers where id = v_o) = v_st - interval '7 days', '3j: seuraava viimeistään 7 pv ennen');
  j := public.shift_offer_ensure(S5, v_st - interval '7 days' + interval '1 minute', false);
  perform pg_temp.ck(j->>'stage' = 'vacant_r2', '3k: 7 pv ennen muistutus');
  j := public.shift_offer_ensure(S5, v_st - interval '6 days 12 hours', false);
  perform pg_temp.ck(j->>'action' = 'waiting', '3l: samana päivänä ei uutta');
  j := public.shift_offer_ensure(S5, v_st - interval '6 days' + interval '2 minutes', false);
  perform pg_temp.ck(j->>'stage' = 'vacant_r3', '3m: siitä alkaen päivittäin');
  insert into public.shift_assignments (shift_id, staff_id, status, source) values (S5, H3, 'assigned', 'test');
  j := public.shift_offer_ensure(S5, v_st - interval '5 days' + interval '3 minutes', false);
  perform pg_temp.ck(j->>'action' = 'skip', '3n: kun vuorolla on tekijä, muistutukset loppuvat');
  update booking.settings set value = 'false' where key = 'shift_offer.email_enabled';

  -- ---------------- 5: hoitaja puuttuu, ei varauksia
  v_st := (d6 + time '10:00') at time zone 'Europe/Helsinki';
  insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
    (S6, v_st, (d6 + time '16:00') at time zone 'Europe/Helsinki', 'therapist', 'active', 'open');
  j := public.shift_offer_ensure(S6, t0, false); v_o := (j->>'offer_id')::uuid;
  perform public.shift_offer_respond(v_o, T1, 'decline', null, false, 'test');
  perform public.shift_offer_respond(v_o, T2, 'decline', null, false, 'test');
  j := public.shift_offer_ensure(S6, t0 + interval '1 minute', false);
  perform pg_temp.ck(j->>'stage' = 'th_exhausted' and (j->>'sent')::int = 2, '5a: kaikki kieltäytyivät → heti ilmoitus Joonakselle ja Lauralle: ' || j::text);
  perform pg_temp.ck(exists (select 1 from public.shift_offer_messages m where m.offer_id = v_o and m.staff_id = LA and m.body like '%ei ole hoitovarauksia%'), '5b: Lauran viesti kertoo varaustilanteen');
  j := public.shift_offer_ensure(S6, t0 + interval '5 days', false);
  perform pg_temp.ck(j->>'action' = 'therapist_waiting', '5c: yli 3 vk ennen ei uutta viestiä');
  j := public.shift_offer_ensure(S6, v_st - interval '21 days' + interval '1 minute', false);
  perform pg_temp.ck(j->>'stage' = 'th_3wk', '5d: 3 vk ennen viesti');
  j := public.shift_offer_ensure(S6, v_st - interval '19 days', false);
  perform pg_temp.ck(j->>'action' = 'therapist_waiting', '5e: ennen 3 pv ei varoitusta');
  j := public.shift_offer_ensure(S6, v_st - interval '18 days' + interval '2 minutes', false);
  perform pg_temp.ck(j->>'stage' = 'th_warn' and exists (select 1 from public.shift_offer_messages m where m.offer_id = v_o and m.body like '%Vuoro suljetaan, jos siihen ei ilmoiteta ketään 6 h kuluessa.%'),
                     '5f: 3 pv myöhemmin varoitus 6 h sulusta');
  j := public.shift_offer_ensure(S6, v_st - interval '18 days' + interval '5 hours', false);
  perform pg_temp.ck(j->>'action' = 'therapist_waiting', '5g: ennen 6 h ei suljeta');
  select count(*) into v_n from public.shift_offer_messages m where m.offer_id = v_o;
  j := public.shift_offer_ensure(S6, v_st - interval '18 days' + interval '6 hours 3 minutes', false);
  perform pg_temp.ck(j->>'action' = 'closed' and (select status from public.shift_offers where id = v_o) = 'closed', '5h: 6 h jälkeen hoidot suljetaan: ' || j::text);
  perform pg_temp.ck((select count(*) from public.shift_offer_messages m where m.offer_id = v_o) = v_n, '5i: sulusta ei erillistä viestiä');

  -- ---------------- 6: hoitaja puuttuu ja varauksia on (varaustieto stubattu tämän transaktion ajaksi)
  create or replace function booking.shift_offer_day_treatments(p_date date) returns int language sql stable as $f$
    select case when p_date = (select (current_setting('t153.booked_day', true))::date) then 2 else 0 end $f$;
  v_st := (d7 + time '10:00') at time zone 'Europe/Helsinki';
  insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
    (S7, v_st, (d7 + time '16:00') at time zone 'Europe/Helsinki', 'therapist', 'active', 'open');
  j := public.shift_offer_ensure(S7, t0, false); v_o := (j->>'offer_id')::uuid;
  perform public.shift_offer_respond(v_o, T1, 'decline', null, false, 'test');
  perform public.shift_offer_respond(v_o, T2, 'decline', null, false, 'test');
  j := public.shift_offer_ensure(S7, t0 + interval '1 minute', false);
  perform pg_temp.ck(j->>'stage' = 'th_exhausted', '6a: ensin ilmoitus ilman varauksia');
  perform set_config('t153.booked_day', d7::text, true);
  j := public.shift_offer_tick(false, t0 + interval '2 hours');
  perform pg_temp.ck(exists (select 1 from booking.shift_offer_notices n where n.offer_id = v_o and n.stage = 'th_booked0'), '6b: varaus tyhjälle päivälle → heti ilmoitus (tick)');
  j := public.shift_offer_ensure(S7, t0 + interval '4 days', false);
  perform pg_temp.ck(j->>'action' = 'therapist_waiting', '6c: viikon sisällä ei uutta');
  j := public.shift_offer_ensure(S7, t0 + interval '7 days 3 hours', false);
  perform pg_temp.ck(j->>'stage' like 'th_booked%' and j->>'stage' <> 'th_booked0', '6d: viikoittainen muistutus: ' || j::text);
  j := public.shift_offer_ensure(S7, v_st - interval '21 days' + interval '1 hour', false);
  perform pg_temp.ck(j->>'stage' like 'th_booked%', '6e: 3 vk ennen muistutus');
  j := public.shift_offer_ensure(S7, v_st - interval '20 days' + interval '2 hours', false);
  perform pg_temp.ck(j->>'stage' like 'th_booked%', '6f: siitä alkaen päivittäin');
  j := public.shift_offer_ensure(S7, v_st - interval '10 hours', false);
  perform pg_temp.ck((select status from public.shift_offers where id = v_o) = 'escalated' and not exists (select 1 from booking.shift_offer_notices n where n.offer_id = v_o and n.stage like '%warn%' or n.offer_id = v_o and n.stage = 'th_closed'),
                     '6g: varauksellista päivää ei varoiteta eikä suljeta');
  perform set_config('t153.booked_day', '1900-01-01', true);

  -- ---------------- 4: saman päivän viestit yhdeksi
  insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
    (S8a, (d1 + 5 + time '08:00') at time zone 'Europe/Helsinki', (d1 + 5 + time '11:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'open'),
    (S8b, (d1 + 5 + time '15:00') at time zone 'Europe/Helsinki', (d1 + 5 + time '19:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'open');
  perform public.shift_offer_ensure(S8a, t0, false);
  perform public.shift_offer_ensure(S8b, t0, false);
  v_n := booking.shift_offer_merge_same_day(now());
  perform pg_temp.ck(v_n >= 1, '4a: yhdistettiin ' || v_n);
  perform pg_temp.ck((select count(*) from public.shift_offer_messages m join booking.shift_offer_message_meta mm on mm.message_id = m.id
                       where m.staff_id = H1 and mm.subkind = 'day_digest' and m.status = 'queued' and m.body like '%; %' and m.body like '%token=%') = 1,
                     '4b: H1 saa yhden koosteviestin, jossa vuorot ja oman sivun linkki');
  perform pg_temp.ck((select count(*) from public.shift_offer_messages m join public.shift_offers o on o.id = m.offer_id
                       where m.staff_id = H1 and o.shift_id in (S8a, S8b) and m.status = 'skipped' and m.last_error like 'merged:%') = 2, '4c: alkuperäiset ohitetaan (merged)');
  perform pg_temp.ck(booking.shift_offer_merge_same_day(now()) = 0, '4d: toinen ajo ei yhdistä uudelleen');
  -- claim: kooste mukana, sivun token mukana; WhatsApp-ikkunan ulkopuolella ei lähetetä
  update public.shift_offer_engine_settings set sender_enabled = true where id;
  update booking.settings set value = '{"start":"00:00","end":"23:59:59"}' where key = 'shift_offer.whatsapp_hours';
  j := public.shift_offer_sender_claim(50);
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(j->'messages') m where m->>'subkind' = 'day_digest' and m->>'staff_id' = H1::text and length(m->>'page_token') > 100
                             and m->'digest'->>'items' like '%; %'), '4e/d: claim antaa koosteen, sivun tokenin ja listan');
  perform pg_temp.ck(j->'templates'->'offer'->>'name' = 'tyovuoro_kysely', 'T1: claim välittää pohja-asetukset');
  update public.shift_offer_messages set status = 'queued', locked_at = null where id in (select (m->>'id')::bigint from jsonb_array_elements(j->'messages') m);
  update booking.settings set value = jsonb_build_object('start', to_char((now() at time zone 'Europe/Helsinki') + interval '1 hour', 'HH24:MI'),
                                                         'end', to_char((now() at time zone 'Europe/Helsinki') + interval '2 hours', 'HH24:MI'))
   where key = 'shift_offer.whatsapp_hours';
  j := public.shift_offer_sender_claim(50);
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(j->'messages') m where m->>'channel' = 'whatsapp') and (j->>'whatsapp_hours_open')::boolean is false,
                     'd1: WhatsApp-ikkunan ulkopuolella ei WhatsApp-viestejä');
  update booking.settings set value = '{"start":"08:00","end":"21:00"}' where key = 'shift_offer.whatsapp_hours';
  perform pg_temp.ck(booking.shift_offer_wa_open(((d1 + time '07:59') at time zone 'Europe/Helsinki')) is false and booking.shift_offer_wa_open(((d1 + time '08:00') at time zone 'Europe/Helsinki'))
                     and booking.shift_offer_wa_open(((d1 + time '20:59') at time zone 'Europe/Helsinki')) and booking.shift_offer_wa_open(((d1 + time '21:00') at time zone 'Europe/Helsinki')) is false,
                     'd2: ikkuna 08–21 Europe/Helsinki');
  perform pg_temp.ck(booking.shift_offer_wa_next_open(((d1 + time '22:30') at time zone 'Europe/Helsinki')) = ((d1 + 1 + time '08:00') at time zone 'Europe/Helsinki'), 'd3: seuraava avautuminen 08:00');
  -- d: vastausaika lasketaan lähetyshetkestä
  select r.id, r.deadline_at into v_rec, v_dl from public.shift_offer_recipients r join public.shift_offers o on o.id = r.offer_id where o.shift_id = S8a and r.staff_id = H2;
  perform pg_temp.ck(booking.shift_offer_extend_deadline(v_rec, now() + interval '2 days') > v_dl, 'd4: myöhemmin lähtevän viestin takaraja siirtyy');
  perform pg_temp.ck(booking.shift_offer_extend_deadline(v_rec, now()) = (select deadline_at from public.shift_offer_recipients where id = v_rec), 'd5: takaraja ei koskaan lyhene');
  -- sähköpostikanava: H2 (ei WhatsAppia) saa viestinsä sähköpostina vain asetuksella
  perform pg_temp.ck(booking.shift_offer_email_drain(50) = 0, 'E1: sähköposti pois → mitään ei siirry');
  update booking.settings set value = 'true' where key = 'shift_offer.email_enabled';
  v_n := booking.shift_offer_email_drain(50);
  perform pg_temp.ck(v_n >= 1 and exists (select 1 from booking.email_outbox e where e.kind = 'staff_shift_notice' and e.payload->>'to_email' = 'heikki153@example.test'), 'E2: asetuksella sähköpostijonoon');
  perform pg_temp.ck(exists (select 1 from jsonb_each(booking.email_staff_notice_payload(array(select id from booking.email_outbox where kind = 'staff_shift_notice'))) x
                             where x.value->>'text' like '%–Tapio'), 'E3: send-emails saa otsikon ja tekstin');
  update booking.settings set value = 'false' where key = 'shift_offer.email_enabled';

  -- ---------------- e / f
  insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
    (S9, (d1 + 7 + time '10:00') at time zone 'Europe/Helsinki', (d1 + 7 + time '18:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'uncertain'),
    (S10, (d1 + 8 + time '10:00') at time zone 'Europe/Helsinki', (d1 + 8 + time '18:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'filled');
  perform pg_temp.ck(not booking.shift_offer_is_vacant(S9) and public.shift_offer_ensure(S9, t0, false)->>'action' = 'skip', 'e1: ?-vuoroa ei tarjota oletuksena');
  update booking.settings set value = 'true' where key = 'shift_offer.offer_uncertain_shifts';
  perform pg_temp.ck(booking.shift_offer_is_vacant(S9) and public.shift_offer_ensure(S9, t0, false)->>'action' = 'offered', 'e2: asetuksella ?-vuoro tarjotaan');
  update booking.settings set value = 'false' where key = 'shift_offer.offer_uncertain_shifts';
  insert into public.shift_assignments (shift_id, staff_id, status, source) values (S10, H3, 'assigned', 'test');
  perform pg_temp.ck(not booking.shift_offer_is_vacant(S10), 'f1: tekijällinen vuoro ei ole vapaa');
  insert into public.staff_unavailability (staff_id, starts_at, ends_at, source) values (H3, (d1 + 8 + time '00:00') at time zone 'Europe/Helsinki', (d1 + 9 + time '00:00') at time zone 'Europe/Helsinki', 'test');
  perform pg_temp.ck(booking.shift_offer_is_vacant(S10) and public.shift_offer_ensure(S10, t0, false)->>'action' = 'offered', 'f2: poissaolo vapauttaa vuoron tarjolle');
  update booking.settings set value = 'false' where key = 'shift_offer.unavailability_frees_shift';
  perform pg_temp.ck(not booking.shift_offer_is_vacant(S10), 'f3: asetus pois → poissaolo ei vapauta');
  update booking.settings set value = 'true' where key = 'shift_offer.unavailability_frees_shift';
  update public.shift_sync_settings set db_first_enabled = true where id;
  update public.staff set calendar_name = name where id in (H1, H3);
  insert into public.calendar_sources (id, calendar_name, role_type) values (gen_random_uuid(), 't153 lämmitys', 'heater') returning id into v_msg;
  update public.work_shifts set calendar_source_id = v_msg where id = S10;
  select o.id into v_o from public.shift_offers o where o.shift_id = S10;
  j := public.shift_offer_respond(v_o, H1, 'accept', null, true, 'test');
  perform pg_temp.ck(j->>'result' = 'accepted' and exists (select 1 from public.shift_assignments a where a.shift_id = S10 and a.staff_id = H1 and a.status in ('assigned','confirmed'))
                     and not exists (select 1 from public.shift_assignments a where a.shift_id = S10 and a.staff_id = H3 and a.status in ('assigned','confirmed')),
                     'f4: hyväksyjä vuoroon, poissaoleva pois: ' || coalesce((select assignment_error from public.shift_offers where id = v_o), j::text));

  -- ---------------- h
  v_txt := public.shift_offer_compose('exhausted_ask', JO, gen_random_uuid(), 'heater', t0 + interval '3 days', t0 + interval '3 days 6 hours', null, 1);
  perform pg_temp.ck(v_txt like '%Lämmitysvuoro %' and v_txt not like '%Hoitajavuoro%', 'h1: kysymysviestin roolinimi oikein (lämmitys)');
  v_txt := public.shift_offer_compose('exhausted_ask', JO, gen_random_uuid(), 'reception', t0 + interval '3 days', t0 + interval '3 days 6 hours', null, 1);
  perform pg_temp.ck(v_txt like '%Vastaanottovuoro %', 'h2: kysymysviestin roolinimi oikein (vastaanotto)');

  -- ---------------- tervetuloviesti ja suostumus
  insert into public.whatsapp_messages (staff_id, direction, provider_message_id, message_text, status, received_at, phone_e164, message_type)
  values (H1, 'inbound', 'wamid.t153.1', 'moi', 'received', now(), '+358401530001', 'text') returning id into v_msg;
  j := booking.shift_staff_welcome(v_msg);
  perform pg_temp.ck(j->>'send' = 'false' and j->>'reason' = 'disabled' and exists (select 1 from booking.shift_staff_whatsapp_consent c where c.staff_id = H1), 'W1: asetus pois → ei viestiä, suostumus kirjataan');
  update booking.settings set value = 'true' where key = 'shift_offer.welcome_enabled';
  insert into public.whatsapp_messages (staff_id, direction, provider_message_id, message_text, status, received_at, phone_e164, message_type)
  values (H3, 'inbound', 'wamid.t153.2', 'hei', 'received', now(), '+358401530003', 'text') returning id into v_msg;
  j := booking.shift_staff_welcome(v_msg);
  perform pg_temp.ck(j->>'send' = 'true' and j->>'body' like 'Hei Hanna.%' and j->>'body' like '%token=%' and j->>'body' like '%–Tapio' and j->>'body' not like '%{{%' and j->>'to' = '+358401530003',
                     'W2: ensimmäiseen viestiin tervetulo nimellä, ohje ja linkki: ' || coalesce(j->>'body', j::text));
  insert into public.whatsapp_messages (staff_id, direction, provider_message_id, message_text, status, received_at, phone_e164, message_type)
  values (H3, 'inbound', 'wamid.t153.3', 'hei taas', 'received', now(), '+358401530003', 'text') returning id into v_msg;
  perform pg_temp.ck(booking.shift_staff_welcome(v_msg)->>'send' = 'false', 'W3: tervetulo vain kerran');
  insert into public.whatsapp_messages (staff_id, direction, provider_message_id, message_text, status, received_at, phone_e164, message_type)
  values (H2, 'inbound', 'wamid.t153.4', 'vanha', 'received', now() - interval '25 hours', '+358401530002', 'text') returning id into v_msg;
  j := booking.shift_staff_welcome(v_msg);
  perform pg_temp.ck(j->>'send' = 'false' and j->>'reason' = 'window_closed', 'W4: 24 h ikkunan ulkopuolella ei viestiä');
  insert into public.whatsapp_messages (staff_id, direction, provider_message_id, message_text, status, received_at, phone_e164, message_type)
  values (null, 'inbound', 'wamid.t153.5', 'kuka', 'received', now(), '+358409999999', 'text') returning id into v_msg;
  perform pg_temp.ck(booking.shift_staff_welcome(v_msg)->>'reason' = 'unknown', 'W5: tuntematon numero ei saa vastausta');
  insert into public.whatsapp_messages (staff_id, direction, provider_message_id, message_text, status, received_at, phone_e164, message_type)
  values (JO, 'inbound', 'wamid.t153.6', 'moi', 'received', now(), '+358409999998', 'text') returning id into v_msg;
  perform pg_temp.ck(booking.shift_staff_welcome(v_msg)->>'reason' = 'bot_channel', 'W6: bottikanavan henkilö ei saa tervetuloa');
  update booking.settings set value = 'false' where key = 'shift_offer.welcome_enabled';
  perform test.login(v_adm);
  j := booking.admin_shift_staff_overview();
  perform test.logout();
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(j) x where x->>'staff_id' = H2::text and (x->>'suggest_whatsapp')::boolean and x->>'consent_at' is not null),
                     'W7: hallinta ehdottaa WhatsAppin avaamista suostuneelle');
  perform pg_temp.ck((select not whatsapp_enabled from public.staff where id = H2), 'W8: whatsapp_enabled ei muutu automaattisesti');

  -- moottori pysyy pois päältä: migraatio ei kytke mitään päälle (tarkistetaan tuotantoasetuksia muuttamatta)
  perform pg_temp.ck(position('enabled = true' in (select prosrc from pg_proc where oid = 'booking.shift_offer_vacant_step(uuid, timestamptz, boolean)'::regprocedure)) = 0, 'M1: ei kytkimiä päälle');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t153_r where ok), (select count(*) from t153_r where not ok),
    coalesce((select string_agg(label, ' | ') from t153_r where not ok), 'ALL OK');
end $t$;
