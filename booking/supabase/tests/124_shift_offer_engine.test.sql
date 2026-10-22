-- Vuorotarjousmoottori: kytkimet, kuivaharjoitus, esteet, hoidot kiinni, ensimmäinen hyväksyjä, outbox.
-- Rinnakkainen hyväksyntä on shift_offer_race.sh (run.sh ajaa sen tämän jälkeen).
begin;
set local search_path = extensions, public;
select no_plan();
insert into vault.decrypted_secrets (name, decrypted_secret)
values ('shift_offer_token_secret', 'test-key')
on conflict (name) do update set decrypted_secret = excluded.decrypted_secret;
select set_config('sipoo.shift_offer_token_key', 'other-key', true);

-- ---------- oikeudet ----------
select ok((select prosecdef and exists (select 1 from unnest(proconfig) c where c like 'search_path=%')
            from pg_proc where pronamespace = 'public'::regnamespace and proname = 'shift_offer_tick'),
          'shift_offer_tick on security definer ja search_path on kiinnitetty');
select ok((select prosrc !~* 'http_post|net\.http|whatsapp' from pg_proc
            where pronamespace = 'public'::regnamespace and proname = 'shift_offer_sender_drain'),
          'lähettäjästubi ei soita verkkoon');
set local role anon;
select throws_ok('select * from public.shift_offer_messages', '42501', null, 'anon ei lue outboxia');
select throws_ok($$insert into public.shift_offer_messages (kind, channel, body, dedupe_key) values ('alert','none','x','x')$$, '42501', null, 'anon ei kirjoita outboxia');
select throws_ok('select public.shift_offer_tick(true, now())', '42501', null, 'anon ei aja tickiä');
select throws_ok($$select public.shift_offer_engine_respond(null, null, 'accept', null, null)$$, '42501', null, 'anon ei kirjaa vastausta');
reset role;
set local role service_role;
select lives_ok('select count(*) from public.shift_offer_messages', 'service_role lukee outboxin');
select lives_ok('select public.shift_offer_tick(true, now())', 'service_role ajaa kuivaharjoituksen');
reset role;

-- ---------- token ----------
select ok((select prosrc !~ 'sipoo.shift_offer_token_key' from pg_proc
            where pronamespace = 'public'::regnamespace and proname = 'shift_offer_token_key'),
          'token-avain ei lue GUC-ylikirjoitusta');
select is(
  public.shift_offer_sign_token('11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222', to_timestamp(2000000000)),
  'eyJvIjoiMTExMTExMTEtMTExMS00MTExLTgxMTEtMTExMTExMTExMTExIiwicyI6IjIyMjIyMjIyLTIyMjItNDIyMi04MjIyLTIyMjIyMjIyMjIyMiIsImUiOjIwMDAwMDAwMDB9.pVV62_nGcsqs9VobW5n0oSq2sY92eZqw2BHCrPGbg48',
  'HMAC-token vastaa tunnettua vektoria, GUC ei vaihda vault-avainta');
select ok(public.shift_offer_ct_eq('abc', 'abc') and not public.shift_offer_ct_eq('abc', 'abd') and not public.shift_offer_ct_eq('abc', 'ab'),
          'vakioaikavertailu täsmää vain saman tavujonon');
select is(
  (public.shift_offer_verify_token('eyJvIjoiMTExMTExMTEtMTExMS00MTExLTgxMTEtMTExMTExMTExMTExIiwicyI6IjIyMjIyMjIyLTIyMjItNDIyMi04MjIyLTIyMjIyMjIyMjIyMiIsImUiOjIwMDAwMDAwMDB9.pVV62_nGcsqs9VobW5n0oSq2sY92eZqw2BHCrPGbg48')->>'ok')::boolean,
  true, 'vektori kelpaa');
select is((public.shift_offer_verify_token('nope.nope')->>'error'), 'bad_token', 'väärä token hylätään');

-- ---------- asetukset, portaat, henkilöt ----------
insert into public.shift_offer_settings (role_type, enabled, snooze_any_recipient, exhausted_ask_count, auto_close_enabled, auto_close_after)
values
  ('heater', false, false, 3, false, null),
  ('reception', false, true, 3, false, null),
  ('therapist', false, true, 1, true, interval '0');
insert into public.shift_offer_response_tiers (role_type, min_lead, wait, wait_last_round, direct_to_all, note) values
  (null, interval '1 month 15 days', interval '7 days', null, false, 'testi yli 1,5 kk'),
  (null, interval '1 month', interval '5 days', null, false, 'testi 1–1,5 kk'),
  (null, interval '28 days', interval '3 days', null, false, 'testi 4 vk'),
  (null, interval '14 days', interval '2 days', null, false, 'testi 2–4 vk'),
  (null, interval '7 days', interval '24 hours', null, false, 'testi 1–2 vk'),
  (null, interval '2 days', interval '6 hours', interval '12 hours', false, 'testi 2–7 vrk'),
  (null, interval '0', null, null, true, 'testi alle 2 vrk');

select is(public.shift_offer_all_by_at('heater', timestamptz '2027-03-02 06:00+02'), timestamptz '2027-02-26 21:00+02',
          'kaikille-hetki 06:00 siirtyy edellisen illan 21:00');
select is((select direct_to_all from public.shift_offer_wait('heater', timestamptz '2027-03-02 06:00+02', timestamptz '2027-02-26 20:00+02', false)),
          false, 'ennen illan 21:00 ei vielä kaikille');
select is((select direct_to_all from public.shift_offer_wait('heater', timestamptz '2027-03-02 06:00+02', timestamptz '2027-02-26 22:00+02', false)),
          true, 'illan 21:00 jälkeen kaikille');
update public.shift_offer_settings set all_by_quiet = 'exact' where role_type = 'heater';
select is(public.shift_offer_all_by_at('heater', timestamptz '2027-03-02 06:00+02'), timestamptz '2027-02-27 08:00+02',
          'exact siirtää hiljaisen 06:00 saman päivän 08:00');
select is(public.shift_offer_all_by_at('heater', timestamptz '2027-03-02 12:00+02'), timestamptz '2027-02-27 12:00+02',
          'exact jättää päivähetken 12:00 ennalleen');
select is((select direct_to_all from public.shift_offer_wait('heater', timestamptz '2027-03-02 06:00+02', timestamptz '2027-02-27 01:00+02', false)),
          false, 'exact-tilassa 01:00 ei ole vielä kaikille-hetki');
update public.shift_offer_settings set all_by_quiet = 'previous_evening' where role_type = 'heater';
update public.shift_offer_settings set all_round_wait = interval '2 hours' where role_type = 'heater';
select is(
  public.shift_offer_round_deadline('heater', now() + interval '30 hours', now(), 'named', true),
  public.shift_add_active_time(now(), interval '2 hours', 'heater'),
  'kaikille-kierroksen vastausaika tulee asetuksesta');
update public.shift_offer_settings set all_round_wait = interval '6 hours' where role_type = 'heater';

insert into public.staff (id, name, email, active, whatsapp_enabled) values
  ('aaaaaaaa-0000-4000-8000-0000000000a1', 'Aino', 'aino@example.com', true, false),
  ('aaaaaaaa-0000-4000-8000-0000000000a2', 'Bertta', 'bertta@example.com', true, false),
  ('aaaaaaaa-0000-4000-8000-0000000000a3', 'Cecilia', 'cecilia@example.com', true, false),
  ('aaaaaaaa-0000-4000-8000-0000000000a4', 'Dora', 'dora@example.com', true, false),
  ('aaaaaaaa-0000-4000-8000-0000000000b1', 'Taina', 'taina@example.com', true, false),
  ('aaaaaaaa-0000-4000-8000-0000000000b2', 'Tuula', 'tuula@example.com', true, false),
  ('aaaaaaaa-0000-4000-8000-0000000000d1', 'Joonas Testi', 'joonas.testi@example.com', true, false),
  ('aaaaaaaa-0000-4000-8000-0000000000c1', 'Otto Testi', 'otto.testi@example.com', true, false),
  ('aaaaaaaa-0000-4000-8000-0000000000c2', 'Raija', 'raija@example.com', true, false),
  ('aaaaaaaa-0000-4000-8000-0000000000c3', 'Saara Testi', 'saara.testi@example.com', true, false);
insert into public.staff_roles (staff_id, role_type, active) values
  ('aaaaaaaa-0000-4000-8000-0000000000a1', 'heater', true),
  ('aaaaaaaa-0000-4000-8000-0000000000a2', 'heater', true),
  ('aaaaaaaa-0000-4000-8000-0000000000a3', 'heater', true),
  ('aaaaaaaa-0000-4000-8000-0000000000a4', 'heater', true),
  ('aaaaaaaa-0000-4000-8000-0000000000b1', 'therapist', true),
  ('aaaaaaaa-0000-4000-8000-0000000000b2', 'therapist', true),
  ('aaaaaaaa-0000-4000-8000-0000000000d1', 'therapist', true),
  ('aaaaaaaa-0000-4000-8000-0000000000c1', 'reception', true),
  ('aaaaaaaa-0000-4000-8000-0000000000c2', 'reception', true),
  ('aaaaaaaa-0000-4000-8000-0000000000c3', 'reception', true);
update public.shift_offer_settings
   set exhausted_ask_staff_id = 'aaaaaaaa-0000-4000-8000-0000000000d1'
 where role_type in ('therapist', 'reception');

select (((now() at time zone 'Europe/Helsinki')::date + 42)
        - (extract(isodow from (now() at time zone 'Europe/Helsinki')::date + 42)::int - 1))::date as mon \gset
select case
         when (now() at time zone 'Europe/Helsinki')::time >= time '08:00'
          and (now() at time zone 'Europe/Helsinki')::time < time '21:00' then now()
         else (((now() at time zone 'Europe/Helsinki')::date + time '12:00') at time zone 'Europe/Helsinki')
       end as tick_now \gset
select (:'tick_now'::timestamptz + interval '2 days') as tick_later \gset
select ((now() at time zone 'Europe/Helsinki')::date + 10) as near_day \gset

insert into public.shift_default_owners (role_type, weekday, week_parity, owner_kind, staff_id, follow_role_type, note) values
  ('therapist', 3, 'any', 'staff', 'aaaaaaaa-0000-4000-8000-0000000000b1', null, 'ke Taina'),
  ('therapist', 4, 'any', 'staff', 'aaaaaaaa-0000-4000-8000-0000000000b1', null, 'to Taina, ei kierrosta'),
  ('therapist', 5, 'any', 'closed', null, null, 'pe hoidot kiinni'),
  ('reception', 3, 'any', 'follow_role', null, 'therapist', 'ke vastaanotto = hoitaja'),
  ('reception', 6, 'any', 'staff', 'aaaaaaaa-0000-4000-8000-0000000000c2', null, 'la Raija'),
  ('reception', 5, 'any', 'not_offered', null, null, 'pe vastaanottoa ei tarjota');

insert into public.shift_offer_rounds (role_type, scenario, weekdays, round_no, kind) values
  ('heater', 'vacant_shift', '{4}', 1, 'named'),
  ('heater', 'vacant_shift', '{1}', 1, 'named'),
  ('therapist', 'vacant_shift', '{3}', 1, 'named'),
  ('reception', 'vacant_shift', '{3}', 1, 'named'),
  ('reception', 'vacant_shift', '{6}', 1, 'named');
insert into public.shift_offer_round_members (round_id, staff_id, sort_order)
select r.id, m.staff_id, m.sort_order
  from (values
    ('heater', '{4}'::smallint[], 'aaaaaaaa-0000-4000-8000-0000000000a1'::uuid, 1::smallint),
    ('heater', '{4}', 'aaaaaaaa-0000-4000-8000-0000000000a2', 2),
    ('heater', '{4}', 'aaaaaaaa-0000-4000-8000-0000000000a3', 3),
    ('heater', '{4}', 'aaaaaaaa-0000-4000-8000-0000000000a4', 4),
    ('heater', '{1}', 'aaaaaaaa-0000-4000-8000-0000000000a1', 1),
    ('heater', '{1}', 'aaaaaaaa-0000-4000-8000-0000000000a3', 2),
    ('therapist', '{3}', 'aaaaaaaa-0000-4000-8000-0000000000b2', 1),
    ('therapist', '{3}', 'aaaaaaaa-0000-4000-8000-0000000000b1', 2),
    ('reception', '{3}', 'aaaaaaaa-0000-4000-8000-0000000000c1', 1),
    ('reception', '{6}', 'aaaaaaaa-0000-4000-8000-0000000000c3', 1)
  ) m(role_type, weekdays, staff_id, sort_order)
  join public.shift_offer_rounds r on r.role_type = m.role_type and r.weekdays = m.weekdays and r.round_no = 1;

insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
  ('aaaaaaaa-0000-4000-8000-0000000000f1', (:'mon'::date + 3 + time '10:00') at time zone 'Europe/Helsinki', (:'mon'::date + 3 + time '18:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'open'),
  ('aaaaaaaa-0000-4000-8000-0000000000f2', (:'mon'::date + time '10:00') at time zone 'Europe/Helsinki', (:'mon'::date + time '18:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'open'),
  ('aaaaaaaa-0000-4000-8000-0000000000f3', (:'mon'::date + 2 + time '10:00') at time zone 'Europe/Helsinki', (:'mon'::date + 2 + time '18:00') at time zone 'Europe/Helsinki', 'therapist', 'active', 'open'),
  ('aaaaaaaa-0000-4000-8000-0000000000f4', (:'mon'::date + 3 + time '10:00') at time zone 'Europe/Helsinki', (:'mon'::date + 3 + time '18:00') at time zone 'Europe/Helsinki', 'therapist', 'active', 'open'),
  ('aaaaaaaa-0000-4000-8000-0000000000f5', (:'mon'::date + 2 + time '10:00') at time zone 'Europe/Helsinki', (:'mon'::date + 2 + time '18:00') at time zone 'Europe/Helsinki', 'reception', 'active', 'open'),
  ('aaaaaaaa-0000-4000-8000-0000000000f6', (:'mon'::date + 5 + time '10:00') at time zone 'Europe/Helsinki', (:'mon'::date + 5 + time '18:00') at time zone 'Europe/Helsinki', 'reception', 'active', 'open'),
  ('aaaaaaaa-0000-4000-8000-0000000000f7', (:'mon'::date + 4 + time '10:00') at time zone 'Europe/Helsinki', (:'mon'::date + 4 + time '18:00') at time zone 'Europe/Helsinki', 'reception', 'active', 'open');

-- Cecilia on estynyt sekä maanantain että torstain lämmitysvuoron ajan.
insert into public.staff_unavailability (staff_id, starts_at, ends_at, source)
values ('aaaaaaaa-0000-4000-8000-0000000000a3',
        (:'mon'::date + time '00:00') at time zone 'Europe/Helsinki',
        (:'mon'::date + 4 + time '00:00') at time zone 'Europe/Helsinki',
        'email');

-- ---------- kytkin pois: ei tarjouksia ----------
select is(jsonb_array_length(public.shift_offer_tick(false, :'tick_now'::timestamptz)->'actions'), 0, 'kytkimet pois: tick on tyhjä');
select is((select count(*)::int from public.shift_offers), 0, 'kytkimet pois: ei tarjousrivejä');

-- ---------- kuivaharjoitus ----------
update public.shift_offer_settings set enabled = true where role_type = 'heater';
select ok((public.shift_offer_tick(true, :'tick_now'::timestamptz)->'actions')::text like '%would_offer%', 'dry_run palauttaa would_offer');
select is((public.shift_offer_tick(true, :'tick_now'::timestamptz)->>'dry_run')::boolean, true, 'dry_run-lippu vastauksessa');
select is((select count(*)::int from public.shift_offers), 0, 'dry_run ei kirjoita tarjousta');
select is((select count(*)::int from public.shift_offer_messages), 0, 'dry_run ei kirjoita viestiä');

-- ---------- lämmitys: Cecilia ohitetaan ----------
select public.shift_offer_tick(false, :'tick_now'::timestamptz) as heater_tick \gset
select is((select count(*)::int from public.shift_offer_recipients r
            join public.shift_offers o on o.id = r.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f1'), 3, 'torstain lämmitykseen kolme vastaanottajaa');
select ok(not exists (select 1 from public.shift_offer_recipients r
            join public.shift_offers o on o.id = r.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f1'
             and r.staff_id = 'aaaaaaaa-0000-4000-8000-0000000000a3'),
          'Cecilian staff_unavailability ohittaa torstain');
select is((select count(*)::int from public.shift_offer_recipients r
            join public.shift_offers o on o.id = r.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f2'
             and r.staff_id = 'aaaaaaaa-0000-4000-8000-0000000000a1'), 1, 'maanantaina vain Aino');
select ok(not exists (select 1 from public.shift_offer_candidates(
            'heater', :'mon'::date, 1, 'vacant_shift',
            (:'mon'::date + time '10:00') at time zone 'Europe/Helsinki',
            (:'mon'::date + time '18:00') at time zone 'Europe/Helsinki') c
           where c.staff_id = 'aaaaaaaa-0000-4000-8000-0000000000a3'),
          'ehdokaslista ohittaa esteen');
select ok((select body from public.shift_offer_messages m
            join public.shift_offers o on o.id = m.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f1' and m.staff_id = 'aaaaaaaa-0000-4000-8000-0000000000a1'
             and m.kind = 'offer') like '%lämmitysvuoro%'
       and (select body from public.shift_offer_messages m
            join public.shift_offers o on o.id = m.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f1' and m.staff_id = 'aaaaaaaa-0000-4000-8000-0000000000a1'
             and m.kind = 'offer') like '%Hyväksy%'
       and (select body from public.shift_offer_messages m
            join public.shift_offers o on o.id = m.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f1' and m.staff_id = 'aaaaaaaa-0000-4000-8000-0000000000a1'
             and m.kind = 'offer') like '%–Tapio%'
       and (select body from public.shift_offer_messages m
            join public.shift_offers o on o.id = m.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f1' and m.staff_id = 'aaaaaaaa-0000-4000-8000-0000000000a1'
             and m.kind = 'offer') not like '%Palaan asiaan%',
          'lämmitysviesti on suomeksi, allekirjoitus Tapio, ei torkkulinkkiä');
select is((select channel from public.shift_offer_messages m
            join public.shift_offers o on o.id = m.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f1' and m.staff_id = 'aaaaaaaa-0000-4000-8000-0000000000a1'),
          'email', 'kanava on sähköposti kun numeroa ei ole');
select is((select m.status from public.shift_offer_messages m
            join public.shift_offers o on o.id = m.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f1' and m.staff_id = 'aaaaaaaa-0000-4000-8000-0000000000a1'),
          'queued', 'viesti jää jonoon');

-- ---------- hoitaja ja vastaanotto ----------
update public.shift_offer_settings set enabled = true where role_type in ('therapist', 'reception');
select public.shift_offer_tick(false, :'tick_now'::timestamptz) as care_tick \gset
select is((select r.staff_id from public.shift_offer_recipients r
            join public.shift_offers o on o.id = r.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f3' and r.round_kind = 'named'),
          'aaaaaaaa-0000-4000-8000-0000000000b2'::uuid, 'keskiviikon hoito Tuulalle, omistaja Taina ei saa tarjousta');
select is((select r.staff_id from public.shift_offer_recipients r
            join public.shift_offers o on o.id = r.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f5'),
          'aaaaaaaa-0000-4000-8000-0000000000c1'::uuid, 'hoitajan vastaanotto tarjotaan Otolle');
select is((select r.staff_id from public.shift_offer_recipients r
            join public.shift_offers o on o.id = r.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f6'),
          'aaaaaaaa-0000-4000-8000-0000000000c3'::uuid, 'lauantain vastaanotto Saaralle, ei hoitajan perässä');
select is((select o.status from public.shift_offers o where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f4'),
          'escalated', 'torstain tyhjä hoitajakierros eskaloituu');
select is((select o.exhausted_asks from public.shift_offers o where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f4'),
          1::smallint, 'Joonas Testiltä kysytään kerran');
select is((select count(*)::int from public.shift_offer_messages m
            join public.shift_offers o on o.id = m.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f4' and m.kind = 'exhausted_ask'),
          1, 'tyhjä vuoro jonottaa kysymyksen');
select is((select count(*)::int from public.shift_offers where shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f7'),
          0, 'perjantain vastaanottoa ei tarjota');
select throws_ok(
  $$insert into public.shift_offers (shift_id, role_type, scenario, status)
    values ('aaaaaaaa-0000-4000-8000-0000000000f7', 'reception', 'vacant_shift', 'active')$$,
  'P0001', null, 'guard torjuu perjantain vastaanoton');

-- ---------- hoidot kiinni sulkee jo tehdyn tarjouksen ja estää uuden ----------
insert into booking.closure_events (calendar_code, external_id, class, reason, all_day, starts_at, ends_at, content_hash)
values ('hoidot', 'test-hoidot-ke', 'closure', 'Hoidot kiinni', true,
        (:'mon'::date + 2 + time '00:00') at time zone 'Europe/Helsinki',
        (:'mon'::date + 3 + time '00:00') at time zone 'Europe/Helsinki',
        'test-hoidot-ke');
update booking.closure_calendars set google_calendar_id = 'test-hoidot@example.com', active = true where code = 'hoidot';
select public.shift_offer_tick(false, :'tick_later'::timestamptz) as close_tick \gset
select is((select status from public.shift_offers where shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f3'), 'cancelled', 'keskiviikon hoitotarjous perutaan');
select is((select note from public.shift_offers where shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f3'), 'hoidot_kiinni', 'peruutuksen syy');
select is((select status from public.shift_offers where shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f5'), 'cancelled', 'hoitajan vastaanottotarjous perutaan');
select is((select status from public.shift_offers where shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f6'), 'active', 'lauantain oma vastaanotto jää voimaan');
select is((select status from public.shift_offers where shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f1'), 'active', 'lämmitystarjous ei peru hoidot-sulusta');
select ok((select body from public.shift_offer_messages m
            join public.shift_offers o on o.id = m.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f3' and m.kind = 'cancelled') like '%hoidot ovat kiinni%'
       and (select body from public.shift_offer_messages m
            join public.shift_offers o on o.id = m.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f3' and m.kind = 'cancelled') like '%–Tapio%',
          'peruutusviesti kertoo että hoidot ovat kiinni');
select is((select status from public.shift_offers where shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f4'), 'closed', 'tyhjä hoitovuoro suljetaan');
select is((select count(*)::int from booking.space_blocks b
            join booking.resources r on r.id = b.space_id
           where r.code = 'saunottaja' and b.reason like '%hoitajavuoro tyhjä%'),
          1, 'automaattisulku kirjoittaa saunottaja-resurssin space_blockin');
select is((select count(*)::int from booking.closure_outbox o
            join booking.space_blocks b on b.id = o.block_id
            join booking.resources r on r.id = b.space_id
           where r.code = 'saunottaja' and o.op = 'upsert'),
          1, 'aktiivinen hoidot-kalenteri jonottaa sulun olemassa olevaan outboxiin');

insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
  ('aaaaaaaa-0000-4000-8000-0000000000f9', (:'mon'::date + 2 + time '11:00') at time zone 'Europe/Helsinki', (:'mon'::date + 2 + time '17:00') at time zone 'Europe/Helsinki', 'therapist', 'active', 'open'),
  ('aaaaaaaa-0000-4000-8000-0000000000fa', (:'mon'::date + 2 + time '11:00') at time zone 'Europe/Helsinki', (:'mon'::date + 2 + time '17:00') at time zone 'Europe/Helsinki', 'reception', 'active', 'open');
select is((public.shift_offer_ensure('aaaaaaaa-0000-4000-8000-0000000000f9', :'tick_later'::timestamptz, false)->>'reason'),
          'treatment_closed', 'uutta hoitotarjousta ei luoda suljetulle päivälle');
select is((public.shift_offer_ensure('aaaaaaaa-0000-4000-8000-0000000000fa', :'tick_later'::timestamptz, false)->>'reason'),
          'treatment_closed', 'uutta hoitajan vastaanottotarjousta ei luoda suljetulle päivälle');
select is((select count(*)::int from public.shift_offers where shift_id in ('aaaaaaaa-0000-4000-8000-0000000000f9', 'aaaaaaaa-0000-4000-8000-0000000000fa')),
          0, 'suljetulle päivälle ei jää tarjousriviä');

-- ---------- ensimmäinen hyväksyjä (peräkkäin; rinnakkaisuus race-skriptissä) ----------
select id as thu_offer from public.shift_offers where shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f1' \gset
select is((public.shift_offer_engine_respond(:'thu_offer'::uuid, 'aaaaaaaa-0000-4000-8000-0000000000a4', 'accept', null, 'nope.nope')->>'result'),
          'bad_token', 'huono token ei hyväksy');
select is((select status from public.shift_offer_recipients where offer_id = :'thu_offer'::uuid and staff_id = 'aaaaaaaa-0000-4000-8000-0000000000a4'),
          'pending', 'Doran tila ei muutu huonosta tokenista');
update public.shift_offer_settings set snooze_any_recipient = true where role_type = 'heater';
select is((public.shift_offer_engine_respond(:'thu_offer'::uuid, 'aaaaaaaa-0000-4000-8000-0000000000a4', 'snooze',
            (:'mon'::date + 3 + time '10:00') at time zone 'Europe/Helsinki', null)->>'result'),
          'snoozed', 'yli 14 vuorokautta: torkku onnistuu');
select is((public.shift_offer_engine_respond(:'thu_offer'::uuid, 'aaaaaaaa-0000-4000-8000-0000000000a1', 'accept', null,
            public.shift_offer_sign_token(:'thu_offer'::uuid, 'aaaaaaaa-0000-4000-8000-0000000000a1', now() + interval '30 days'))->>'result'),
          'accepted', 'ensimmäinen hyväksyjä voittaa');
select is((public.shift_offer_engine_respond(:'thu_offer'::uuid, 'aaaaaaaa-0000-4000-8000-0000000000a2', 'accept', null, null)->>'result'),
          'already_taken', 'toinen hyväksyjä saa already taken');
select is((select count(*)::int from public.shift_offer_recipients where offer_id = :'thu_offer'::uuid and status = 'accepted'),
          1, 'tasan yksi accepted');
select is((select count(*)::int from public.shift_offer_messages
           where offer_id = :'thu_offer'::uuid and kind = 'filled' and body like '%Vuoro on täytetty%' and body like '%–Tapio%'),
          2, 'muut avoimet saavat vuoro täytetty -ilmoituksen');
select is((select count(*)::int from public.shift_offer_messages
           where offer_id = :'thu_offer'::uuid and kind = 'filled' and staff_id = 'aaaaaaaa-0000-4000-8000-0000000000a1'),
          0, 'voittajalle ei lähde täytetty-ilmoitusta');
select ok((select assignment_error from public.shift_offers where id = :'thu_offer'::uuid) is not null,
          'db-first pois päältä: kirjausvirhe talteen, hyväksyntä jää');

-- alle 14 vrk: torkku ei ole sallittu
insert into public.shift_offer_rounds (role_type, scenario, weekdays, round_no, kind)
select 'heater', 'vacant_shift', array[extract(isodow from :'near_day'::date)::smallint], 1, 'named'
 where extract(isodow from :'near_day'::date) not in (1, 4);
insert into public.shift_offer_round_members (round_id, staff_id, sort_order)
select r.id, 'aaaaaaaa-0000-4000-8000-0000000000a1', 1
  from public.shift_offer_rounds r
 where r.role_type = 'heater' and r.round_no = 1 and r.kind = 'named'
   and extract(isodow from :'near_day'::date)::smallint = any (r.weekdays)
   and not exists (select 1 from public.shift_offer_round_members m
                    where m.round_id = r.id and m.staff_id = 'aaaaaaaa-0000-4000-8000-0000000000a1');
insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status)
values ('aaaaaaaa-0000-4000-8000-0000000000f8',
        (:'near_day'::date + time '10:00') at time zone 'Europe/Helsinki',
        (:'near_day'::date + time '18:00') at time zone 'Europe/Helsinki',
        'heater', 'active', 'open');
select is((public.shift_offer_ensure('aaaaaaaa-0000-4000-8000-0000000000f8', :'tick_now'::timestamptz, false)->>'action'),
          'offered', 'lyhyt lämmitysvuoro tarjotaan');
select is((public.shift_offer_engine_respond(
            (select id from public.shift_offers where shift_id = 'aaaaaaaa-0000-4000-8000-0000000000f8'),
            'aaaaaaaa-0000-4000-8000-0000000000a1', 'snooze', now() + interval '30 days', null)->>'reason'),
          'too_close', 'alle 14 vuorokautta: torkku ei ole sallittu');

-- ---------- lähettäjä ----------
select is((public.shift_offer_sender_drain(50)->>'sent')::int, 0, 'lähettäjä pois: mitään ei merkitä lähetetyksi');
select ok(exists (select 1 from public.shift_offer_messages where status = 'queued'), 'viestit ovat yhä jonossa');
select is((select count(*)::int from public.shift_offer_messages where status = 'sent'), 0, 'lähettäjä pois ei merkitse sent');
update public.shift_offer_engine_settings set sender_enabled = true where id;
create temp table drain_out as select public.shift_offer_sender_drain(200) as j;
select is((select j->>'transport' from drain_out), 'edge', 'kytkin päällä ei lähetä SQL:stä');
select is((select (j->>'sent')::int from drain_out), 0, 'SQL-tyhjennys ei raportoi lähetyksiä');
select is((select (j->>'skipped')::int from drain_out), 0, 'jonoa ei merkitä skipped-tilaan');
select is((select count(*)::int from public.shift_offer_messages where status = 'sent'), 0, 'yksikään viesti ei ole sent');
select ok((select count(*)::int from public.shift_offer_messages where status = 'queued') > 0, 'jono jää edge-lähettäjälle');
select is((select count(*)::int from public.shift_offer_messages where status = 'skipped'), 0, 'skipped-rivejä ei synny');

-- ---------- la–su: kaikille-hetki hyppää suoraan all-kierrokseen ----------
insert into public.shift_offer_rounds (role_type, scenario, weekdays, round_no, kind) values
  ('heater', 'vacant_shift', '{6,7}', 1, 'named'),
  ('heater', 'vacant_shift', '{6,7}', 2, 'named'),
  ('heater', 'vacant_shift', '{6,7}', 3, 'all'),
  ('heater', 'vacant_shift', '{6,7}', 4, 'named_last');
insert into public.shift_offer_round_members (round_id, staff_id, sort_order)
select r.id, m.staff_id, m.sort_order
  from (values
    (1::smallint, 'aaaaaaaa-0000-4000-8000-0000000000a1'::uuid, 1::smallint),
    (2, 'aaaaaaaa-0000-4000-8000-0000000000a2', 1),
    (4, 'aaaaaaaa-0000-4000-8000-0000000000a4', 1)
  ) m(round_no, staff_id, sort_order)
  join public.shift_offer_rounds r
    on r.role_type = 'heater' and r.scenario = 'vacant_shift' and r.weekdays = '{6,7}' and r.round_no = m.round_no;
insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
  ('aaaaaaaa-0000-4000-8000-0000000000fb',
   (:'mon'::date + 5 + time '10:00') at time zone 'Europe/Helsinki',
   (:'mon'::date + 5 + time '18:00') at time zone 'Europe/Helsinki',
   'heater', 'active', 'open');
select is((public.shift_offer_ensure('aaaaaaaa-0000-4000-8000-0000000000fb', :'tick_now'::timestamptz, false)->>'action'),
          'offered', 'lauantain ketju alkaa ensimmäisestä kierroksesta');
select is((select r.staff_id from public.shift_offer_recipients r
            join public.shift_offers o on o.id = r.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000fb'),
          'aaaaaaaa-0000-4000-8000-0000000000a1'::uuid, 'ennen kaikille-hetkeä vain Aino');
create temp table jump_out as
  select public.shift_offer_ensure(
           'aaaaaaaa-0000-4000-8000-0000000000fb',
           ((:'mon'::date + 5 + time '10:00') at time zone 'Europe/Helsinki' - interval '2 days'),
           false) as j;
select is((select j->>'action' from jump_out), 'advanced', 'kaikille-hetken jälkeen edetään yhdellä kutsulla');
select is((select (j->>'round_no')::int from jump_out), 3, 'hyppy osuu all-kierrokseen, ei kierrokseen 2');
select is((select j->>'round_kind' from jump_out), 'all', 'kierroksen laji on all');
select is((select (j->>'recipients')::int from jump_out), 3, 'Bertta, Cecilia ja Dora samassa aallossa');
select is((select count(*)::int from public.shift_offer_recipients r
            join public.shift_offers o on o.id = r.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000fb' and r.round_no = 2),
          0, 'välikierrosta 2 ei lähetetä');
select is((select count(*)::int from public.shift_offer_recipients r
            join public.shift_offers o on o.id = r.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000fb'
             and r.round_kind = 'all' and r.round_no = 3
             and r.staff_id in ('aaaaaaaa-0000-4000-8000-0000000000a2',
                                'aaaaaaaa-0000-4000-8000-0000000000a3',
                                'aaaaaaaa-0000-4000-8000-0000000000a4')),
          3, 'all-aaltoon kuuluvat Bertta, Cecilia ja Dora');
select ok((select o.all_sent_at is not null from public.shift_offers o
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000fb'),
          'all_sent_at kirjataan hypyssä');
select is((select o.current_round_no::int from public.shift_offers o
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000fb'),
          3, 'nykyinen kierros on all-kierros');

-- ---------- viimeinen kierros: voimassaolo ja settings.timezone ----------
select ok((select prosrc !~ 'Europe/Helsinki' from pg_proc
            where pronamespace = 'public'::regnamespace and proname = 'shift_offer_issue_recipients'),
          'issue_recipients ei kovakoodaa aikavyöhykettä');
insert into public.shift_offer_rounds (role_type, scenario, weekdays, round_no, kind, valid_to) values
  ('heater', 'vacant_shift', '{1}', 8, 'named', date '2026-01-01'),
  ('heater', 'vacant_shift', '{2}', 5, 'named', null);
insert into public.shift_offer_round_members (round_id, staff_id, sort_order)
select r.id, 'aaaaaaaa-0000-4000-8000-0000000000a2', 1
  from public.shift_offer_rounds r
 where r.role_type = 'heater' and r.weekdays = '{2}' and r.round_no = 5;
update public.shift_offer_settings set timezone = 'UTC' where role_type = 'heater';
insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
  ('aaaaaaaa-0000-4000-8000-0000000000fc',
   timestamptz '2027-02-02 01:30+02', timestamptz '2027-02-02 09:30+02', 'heater', 'active', 'open');
select is((public.shift_offer_ensure('aaaaaaaa-0000-4000-8000-0000000000fc', timestamptz '2027-01-28 10:00+02', false)->>'action'),
          'offered', 'UTC-asetus näkee vuoron maanantaina');
select is((select min(r.deadline_at) from public.shift_offer_recipients r
            join public.shift_offers o on o.id = r.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000fc'),
          public.shift_add_active_time(timestamptz '2027-01-28 10:00+02', interval '12 hours', 'heater'),
          'viimeinen voimassa oleva kierros saa 12 tunnin vastausajan');
select ok((select min(r.deadline_at) from public.shift_offer_recipients r
            join public.shift_offers o on o.id = r.offer_id
           where o.shift_id = 'aaaaaaaa-0000-4000-8000-0000000000fc')
          is distinct from public.shift_add_active_time(timestamptz '2027-01-28 10:00+02', interval '6 hours', 'heater'),
          'vanhentunut tai väärän päivän kierros ei lyhennä vastausaikaa kuuteen tuntiin');
update public.shift_offer_settings set timezone = 'Europe/Helsinki' where role_type = 'heater';

-- ---------- sääntö 9: perjantai ei sulkeudu, koska allow-listalla ei ole perjantaita ----------
update public.shift_offer_settings set start_before = interval '8 days' where role_type = 'therapist';
insert into public.shift_service_allowed_therapists (service_code, weekday, staff_id, note)
values ('perinnesaunotus', 3, 'aaaaaaaa-0000-4000-8000-0000000000b2', 'testi: ke vain Tuula');
select public.shift_offer_service_closures(:'tick_now'::timestamptz, false) as svc \gset
select ok((select count(*)::int from booking.space_blocks b
            join booking.resources r on r.id = b.space_id
           where r.code = 'perinnesaunotus_ryhma' and b.reason like 'Tarjousmoottori: perinnesaunotus%') >= 1,
          'keskiviikolle, jonka hoitaja ei ole listalla, tulee perinnesaunotussulku');
select is((select count(*)::int from booking.space_blocks b
            join booking.resources r on r.id = b.space_id
           where r.code = 'perinnesaunotus_ryhma'
             and b.reason like 'Tarjousmoottori: perinnesaunotus%'
             and extract(isodow from (b.starts_at at time zone 'Europe/Helsinki')) = 5),
          0, 'perjantaille ei tule perinnesaunotussulkua');
select is((public.shift_service_closure_needed('perinnesaunotus', :'mon'::date + 4, null)->>'reason'),
          'therapist_closed', 'funktio sanoo perjantaina therapist_closed, moottori ei silti sulje ilman allow-riviä');
insert into public.shift_service_date_overrides (service_code, on_date, mode, note)
values ('perinnesaunotus', date '2026-10-26', 'open', 'testi');
select is((public.shift_service_closure_needed('perinnesaunotus', date '2026-10-26', null)->>'reason'),
          'date_override_open', '26.10.2026 override open ei sulje');

-- ---------- WhatsApp-kanava: numero, lukko, wamid, puuttuva yhteystieto ----------
select is(public.shift_offer_phone_e164('040 123 4567'), '+358401234567', '040 normalisoituu E.164-muotoon');
select is(public.shift_offer_phone_e164('+358401234567'), '+358401234567', 'plus-358 pysyy');
select is(public.shift_offer_phone_e164('00358401234567'), '+358401234567', '00-etuliite normalisoituu');
select is(public.shift_offer_phone_e164('358401234567'), '+358401234567', 'maakoodi ilman plussaa');
select is(public.shift_offer_phone_e164(''), null, 'tyhjä numero ei kelpaa');
select is(public.shift_offer_phone_e164('091234567'), null, 'lankapuhelin ei kelpaa');
select is((select whatsapp_enabled from public.shift_offer_engine_settings), false, 'whatsapp-kytkin on oletuksena pois');
select is((select whatsapp_dry_run from public.shift_offer_engine_settings), true, 'whatsapp-kuivaharjoitus on oletuksena päällä');
select is(cardinality((select whatsapp_allow_staff_ids from public.shift_offer_engine_settings)), 0, 'allowlist on oletuksena tyhjä');

insert into public.staff (id, name, active, phone_e164, whatsapp_enabled) values
  ('aaaaaaaa-0000-4000-8000-0000000000e2', 'Puhelin Testi', true, '040 123 4567', true);
insert into public.staff (id, name, active) values
  ('aaaaaaaa-0000-4000-8000-0000000000e1', 'Mona Testi', true);
insert into public.staff (id, name, email, active) values
  ('aaaaaaaa-0000-4000-8000-0000000000e3', 'Sähköposti Testi', 'sahkoposti@example.com', true);
insert into public.staff (id, name, email, active, phone_e164, whatsapp_enabled) values
  ('aaaaaaaa-0000-4000-8000-0000000000e4', 'Opt-out Testi', 'optout@example.com', true, '0407654321', false);
insert into public.staff (id, name, active, phone_e164, whatsapp_enabled) values
  ('aaaaaaaa-0000-4000-8000-0000000000e5', 'Numero ilman opt-inia', true, '0501234567', false);
select ok(public.shift_offer_queue_message(null, null, 'aaaaaaaa-0000-4000-8000-0000000000e2', 'alert', 'x', 'dedupe-phone') is not null, 'numero jonottaa viestin');
select is((select channel from public.shift_offer_messages where dedupe_key = 'dedupe-phone'), 'whatsapp', 'opt-in ja numero valitsevat whatsapp-kanavan');
select is((select to_address from public.shift_offer_messages where dedupe_key = 'dedupe-phone'), '+358401234567', 'jonon osoite on E.164');
select ok(public.shift_offer_queue_message(null, null, 'aaaaaaaa-0000-4000-8000-0000000000e4', 'alert', 'x', 'dedupe-optout') is not null, 'opt-out jonottaa viestin');
select is((select channel from public.shift_offer_messages where dedupe_key = 'dedupe-optout'), 'email', 'numero ilman opt-inia ei valitse whatsappia');
select is((select to_address from public.shift_offer_messages where dedupe_key = 'dedupe-optout'), 'optout@example.com', 'opt-out jää sähköpostiosoitteeseen');
select ok(public.shift_offer_queue_message(null, null, 'aaaaaaaa-0000-4000-8000-0000000000e5', 'alert', 'x', 'dedupe-nopt') is not null, 'pelkkä numero ilman opt-inia jonottaa');
select is((select channel from public.shift_offer_messages where dedupe_key = 'dedupe-nopt'), 'none', 'ilman opt-inia ja sähköpostia kanava on none');
insert into public.shift_offer_messages (staff_id, kind, channel, body, dedupe_key, status)
values ('aaaaaaaa-0000-4000-8000-0000000000e1', 'alert', 'none', 'ei yhteystietoja', 'dedupe-mona', 'queued');
insert into public.shift_offer_messages (staff_id, kind, channel, to_address, body, dedupe_key, status)
values ('aaaaaaaa-0000-4000-8000-0000000000e3', 'alert', 'email', 'sahkoposti@example.com', 'vain posti', 'dedupe-email', 'queued');
select is((public.shift_offer_sender_complete(jsonb_build_object('id', (select id from public.shift_offer_messages where dedupe_key = 'dedupe-email'), 'action', 'sent', 'wamid', 'wamid.EARLY'))->>'error'),
          'not_locked', 'lähetys ilman lukkoa ei onnistu');
select is((select status from public.shift_offer_messages where dedupe_key = 'dedupe-email'), 'queued', 'lukitsematon rivi jää jonoon');
select is((select wamid from public.shift_offer_messages where dedupe_key = 'dedupe-email'), null, 'lukitsemattomalle riville ei tallennu wamidia');
update public.shift_offer_messages
   set next_attempt_at = now() + interval '30 days'
 where status = 'queued'
   and dedupe_key not in ('dedupe-phone', 'dedupe-mona', 'dedupe-email', 'dedupe-optout');
create temp table wa_claim as select public.shift_offer_sender_claim(50) as j;
select is((select (j->>'sender_enabled')::boolean from wa_claim), true, 'lähettäjä varaa jonon kun kytkin on päällä');
select is((
  select e->>'staff_whatsapp_enabled'
    from wa_claim, lateral jsonb_array_elements(j->'messages') e
   where e->>'staff_id' = 'aaaaaaaa-0000-4000-8000-0000000000e2'
), 'true', 'varaus kertoo henkilön whatsapp-opt-inin');
select is((select status from public.shift_offer_messages where dedupe_key = 'dedupe-mona'), 'sending', 'ilman yhteystietoja oleva rivi lukitaan');
select is((select status from public.shift_offer_messages where dedupe_key = 'dedupe-email'), 'queued', 'pelkkä sähköposti ei lähde whatsapp-varaukseen');
select is((select status from public.shift_offer_messages where dedupe_key = 'dedupe-optout'), 'queued', 'opt-out-numero ei lähde whatsapp-varaukseen');
select is((public.shift_offer_sender_complete(jsonb_build_object('id', (select id from public.shift_offer_messages where dedupe_key = 'dedupe-mona'), 'action', 'fail_no_contact'))->>'status'),
          'failed_no_contact', 'puuttuva numero merkitään failed_no_contact');
select is((select status from public.shift_offer_messages where dedupe_key = 'dedupe-mona'), 'failed_no_contact', 'failed_no_contact jää näkyviin');
select is((select count(*)::int from public.shift_offer_messages where dedupe_key = 'dedupe-mona'), 1, 'riviä ei poisteta');
select is((public.shift_offer_sender_complete(jsonb_build_object('id', (select id from public.shift_offer_messages where dedupe_key = 'dedupe-phone'), 'action', 'sent', 'wamid', 'wamid.ONE', 'channel', 'whatsapp', 'to', '+358401234567'))->>'status'),
          'sent', 'lukittu rivi saa wamidin');
select is((public.shift_offer_sender_complete(jsonb_build_object('id', (select id from public.shift_offer_messages where dedupe_key = 'dedupe-phone'), 'action', 'sent', 'wamid', 'wamid.TWO'))->>'duplicate'),
          'true', 'toinen lähetys ei vaihda wamidia');
select is((select wamid from public.shift_offer_messages where dedupe_key = 'dedupe-phone'), 'wamid.ONE', 'ensimmäinen wamid jää voimaan');
select is((public.shift_offer_whatsapp_apply_status('wamid.ONE', 'delivered', null, timestamptz '2026-10-22 12:00+00')->>'status'), 'delivered', 'webhook kirjaa delivered');
select is((public.shift_offer_whatsapp_apply_status('wamid.ONE', 'sent', null, now())->>'unchanged'), 'true', 'delivered ei peruudu sentiksi');
select is((public.shift_offer_whatsapp_apply_status('wamid.ONE', 'read', null, timestamptz '2026-10-22 12:05+00')->>'status'), 'read', 'webhook kirjaa read');
select is((public.shift_offer_whatsapp_apply_status('wamid.ONE', 'failed', 'x', now())->>'unchanged'), 'true', 'read ei peruudu failediksi');
select is((public.shift_offer_whatsapp_apply_status('wamid.MISSING', 'delivered', null, now())->>'matched'), 'false', 'tuntematon wamid ei osu');
select is(public.shift_offer_mask_phone('+358401234567'), '+358*******67', 'numero peitetään');
select is(public.shift_offer_mask_phone('+358*******67'), '+358*******67', 'peitto on idempotentti');
insert into public.shift_offer_messages (staff_id, kind, channel, to_address, body, dedupe_key, status, locked_at)
values ('aaaaaaaa-0000-4000-8000-0000000000e2', 'offer', 'whatsapp', '+358401234567', 'peitto', 'dedupe-mask', 'sending', now());
select is((public.shift_offer_sender_complete(jsonb_build_object(
            'id', (select id from public.shift_offer_messages where dedupe_key = 'dedupe-mask'),
            'action', 'release',
            'error', 'dry_run',
            'channel', 'whatsapp',
            'to', '+358401234567',
            'retry_at', now() + interval '30 days',
            'payload', jsonb_build_object(
              'messaging_product', 'whatsapp',
              'to', '+358401234567',
              'type', 'template',
              'template', jsonb_build_object(
                'name', 'vuorotarjous',
                'language', jsonb_build_object('code', 'fi'),
                'components', jsonb_build_array(
                  jsonb_build_object('type', 'body', 'parameters', jsonb_build_array(jsonb_build_object('type', 'text', 'text', 'lämmitysvuoro'))),
                  jsonb_build_object('type', 'button', 'sub_type', 'url', 'index', '0',
                    'parameters', jsonb_build_array(jsonb_build_object('type', 'text', 'text', 'payload.sig')))
                )
              )
            )
          ))->>'status'), 'queued', 'peitetty runko kirjataan');
select is((select last_payload->>'to' from public.shift_offer_messages where dedupe_key = 'dedupe-mask'), '+358*******67', 'last_payload peittää numeron');
select is((select last_payload #>> '{template,components,1,parameters,0,text}' from public.shift_offer_messages where dedupe_key = 'dedupe-mask'), '***', 'last_payload peittää poletin');
select is((select last_payload #>> '{template,components,0,parameters,0,text}' from public.shift_offer_messages where dedupe_key = 'dedupe-mask'), 'lämmitysvuoro', 'mallin teksti säilyy last_payloadissa');
select ok((select last_payload::text not like '%+358401234567%' and last_payload::text not like '%payload.sig%'
             from public.shift_offer_messages where dedupe_key = 'dedupe-mask'),
          'last_payload ei sisällä numeroa eikä polettia');
select is((select to_address from public.shift_offer_messages where dedupe_key = 'dedupe-mask'), '+358401234567', 'to_address jää oikeaksi numeroksi');

insert into public.shift_offer_messages (staff_id, kind, channel, body, dedupe_key, status, locked_at) values
  ('aaaaaaaa-0000-4000-8000-0000000000e2', 'alert', 'whatsapp', 'jumissa', 'dedupe-stuck', 'sending', now() - interval '11 minutes'),
  ('aaaaaaaa-0000-4000-8000-0000000000e2', 'alert', 'whatsapp', 'tuore', 'dedupe-fresh', 'sending', now() - interval '1 minute');
insert into public.shift_offer_messages (staff_id, kind, channel, body, dedupe_key, status, locked_at, wamid) values
  ('aaaaaaaa-0000-4000-8000-0000000000e2', 'alert', 'whatsapp', 'tunnus', 'dedupe-keep', 'sending', now() - interval '11 minutes', 'wamid.KEEP');
create temp table wa_claim2 as select public.shift_offer_sender_claim(50) as j;
select ok(not exists (
  select 1 from wa_claim2, lateral jsonb_array_elements(j->'messages') e
   where e->>'staff_id' in ('aaaaaaaa-0000-4000-8000-0000000000e1', 'aaaaaaaa-0000-4000-8000-0000000000e2')
      or e->>'id' = (select id::text from public.shift_offer_messages where dedupe_key = 'dedupe-stuck')
), 'lähetettyä, failed_no_contact- tai unknown-riviä ei varata uudelleen');
select is((select status from public.shift_offer_messages where dedupe_key = 'dedupe-stuck'), 'unknown', 'vanha sending ilman wamidia on unknown');
select is((select last_error from public.shift_offer_messages where dedupe_key = 'dedupe-stuck'), 'unknown_delivery', 'unknown vaatii käsintarkistuksen');
select is((select wamid from public.shift_offer_messages where dedupe_key = 'dedupe-stuck'), null, 'unknown-riville ei keksitä wamidia');
select is((select status from public.shift_offer_messages where dedupe_key = 'dedupe-fresh'), 'sending', 'tuore lukko jää sending-tilaan');
select is((select status from public.shift_offer_messages where dedupe_key = 'dedupe-keep'), 'sending', 'wamidilla varustettua lukkoa ei merkitä unknowniksi');
select is((select wamid from public.shift_offer_messages where dedupe_key = 'dedupe-keep'), 'wamid.KEEP', 'olemassa oleva wamid säilyy');
select is((public.shift_offer_sender_claim(50)->>'ok')::boolean, true, 'toinen varaus onnistuu unknown-rivin jälkeen');
select is((select status from public.shift_offer_messages where dedupe_key = 'dedupe-stuck'), 'unknown', 'unknown ei palaa jonoon');
update public.shift_offer_messages set wamid = 'wamid.UNKNOWN' where dedupe_key = 'dedupe-stuck';
select is((public.shift_offer_whatsapp_apply_status('wamid.UNKNOWN', 'delivered', null, now())->>'unchanged'), 'true', 'webhook ei siirrä unknown-riviä');
select is((select status from public.shift_offer_messages where dedupe_key = 'dedupe-stuck'), 'unknown', 'unknown pysyy webhookin jälkeen');

-- ---------- vastaussivu: poletti oikeuttaa vain oman henkilön avoimiin tarjouksiin ----------
select ok((select prosecdef and exists (select 1 from unnest(proconfig) c where c like 'search_path=%')
            from pg_proc where pronamespace = 'public'::regnamespace and proname = 'shift_offer_open_for_token'),
          'shift_offer_open_for_token on security definer ja search_path on kiinnitetty');
select ok((select prosecdef and exists (select 1 from unnest(proconfig) c where c like 'search_path=%')
            from pg_proc where pronamespace = 'public'::regnamespace and proname = 'shift_offer_respond_as_staff'),
          'shift_offer_respond_as_staff on security definer ja search_path on kiinnitetty');
select is((select pronargs from pg_proc where pronamespace = 'public'::regnamespace and proname = 'shift_offer_respond_as_staff'),
          4::smallint, 'vastausfunktiolla ei ole erillistä henkilön parametria');
select ok((select prosrc !~ 'p_staff_id' from pg_proc
            where pronamespace = 'public'::regnamespace and proname = 'shift_offer_respond_as_staff'),
          'henkilö luetaan vain poletista');

insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status) values
  ('aaaaaaaa-0000-4000-8000-0000000000g1', timestamptz '2027-06-07 13:00+03', timestamptz '2027-06-07 17:00+03', 'heater', 'active', 'open'),
  ('aaaaaaaa-0000-4000-8000-0000000000g2', timestamptz '2027-06-08 13:00+03', timestamptz '2027-06-08 17:00+03', 'heater', 'active', 'open'),
  ('aaaaaaaa-0000-4000-8000-0000000000g3', timestamptz '2027-06-09 13:00+03', timestamptz '2027-06-09 17:00+03', 'heater', 'active', 'open'),
  ('aaaaaaaa-0000-4000-8000-0000000000g4', timestamptz '2027-06-10 13:00+03', timestamptz '2027-06-10 17:00+03', 'heater', 'active', 'open'),
  ('aaaaaaaa-0000-4000-8000-0000000000g5', timestamptz '2027-06-14 13:00+03', timestamptz '2027-06-14 17:00+03', 'heater', 'active', 'open'),
  ('aaaaaaaa-0000-4000-8000-0000000000g6', timestamptz '2027-06-15 13:00+03', timestamptz '2027-06-15 17:00+03', 'heater', 'active', 'open');
insert into public.shift_offers (id, shift_id, role_type, scenario, status, accepted_staff_id, accepted_at) values
  ('aaaaaaaa-0000-4000-8000-0000000000h1', 'aaaaaaaa-0000-4000-8000-0000000000g1', 'heater', 'vacant_shift', 'active', null, null),
  ('aaaaaaaa-0000-4000-8000-0000000000h2', 'aaaaaaaa-0000-4000-8000-0000000000g2', 'heater', 'vacant_shift', 'active', null, null),
  ('aaaaaaaa-0000-4000-8000-0000000000h3', 'aaaaaaaa-0000-4000-8000-0000000000g3', 'heater', 'vacant_shift', 'cancelled', null, null),
  ('aaaaaaaa-0000-4000-8000-0000000000h4', 'aaaaaaaa-0000-4000-8000-0000000000g4', 'heater', 'vacant_shift', 'active', null, null),
  ('aaaaaaaa-0000-4000-8000-0000000000h5', 'aaaaaaaa-0000-4000-8000-0000000000g5', 'heater', 'vacant_shift', 'paused', null, null),
  ('aaaaaaaa-0000-4000-8000-0000000000h6', 'aaaaaaaa-0000-4000-8000-0000000000g6', 'heater', 'vacant_shift', 'filled', 'aaaaaaaa-0000-4000-8000-0000000000e1', now());
insert into public.shift_offer_recipients (offer_id, staff_id, round_no, round_kind, status, deadline_at, sent_at) values
  ('aaaaaaaa-0000-4000-8000-0000000000h1', 'aaaaaaaa-0000-4000-8000-0000000000e2', 1, 'named', 'pending', now() + interval '5 days', now()),
  ('aaaaaaaa-0000-4000-8000-0000000000h2', 'aaaaaaaa-0000-4000-8000-0000000000e1', 1, 'named', 'pending', now() + interval '5 days', now()),
  ('aaaaaaaa-0000-4000-8000-0000000000h3', 'aaaaaaaa-0000-4000-8000-0000000000e2', 1, 'named', 'pending', now() + interval '5 days', now()),
  ('aaaaaaaa-0000-4000-8000-0000000000h4', 'aaaaaaaa-0000-4000-8000-0000000000e2', 1, 'named', 'pending', now() - interval '1 hour', now()),
  ('aaaaaaaa-0000-4000-8000-0000000000h5', 'aaaaaaaa-0000-4000-8000-0000000000e2', 1, 'named', 'pending', now() + interval '5 days', now()),
  ('aaaaaaaa-0000-4000-8000-0000000000h6', 'aaaaaaaa-0000-4000-8000-0000000000e2', 1, 'named', 'pending', now() + interval '5 days', now());

select public.shift_offer_sign_token(
  'aaaaaaaa-0000-4000-8000-0000000000h1',
  'aaaaaaaa-0000-4000-8000-0000000000e2',
  now() + interval '20 days') as page_token \gset
select public.shift_offer_open_for_token(:'page_token') as page_open \gset
select is((:'page_open'::jsonb->>'ok')::boolean, true, 'avoimet tarjoukset löytyvät poletilla');
select is(:'page_open'::jsonb->>'staff_id', 'aaaaaaaa-0000-4000-8000-0000000000e2', 'henkilö tulee poletista');
select is(:'page_open'::jsonb->>'focus_offer_id', 'aaaaaaaa-0000-4000-8000-0000000000h1', 'linkin tarjous on focus');
select is((select count(*)::int from jsonb_array_elements(:'page_open'::jsonb->'offers')), 2, 'vain omat avoimet tarjoukset');
select is(:'page_open'::jsonb#>>'{offers,0,offer_id}', 'aaaaaaaa-0000-4000-8000-0000000000h1', 'linkin tarjous on listassa ensin');
select is(:'page_open'::jsonb#>>'{offers,1,offer_id}', 'aaaaaaaa-0000-4000-8000-0000000000h5', 'tauolla oleva oma tarjous näkyy');
select ok(not exists (
  select 1 from jsonb_array_elements(:'page_open'::jsonb->'offers') e
   where e->>'offer_id' in (
     'aaaaaaaa-0000-4000-8000-0000000000h2',
     'aaaaaaaa-0000-4000-8000-0000000000h3',
     'aaaaaaaa-0000-4000-8000-0000000000h4',
     'aaaaaaaa-0000-4000-8000-0000000000h6')
), 'toisen tarjous, peruttu, vanhentunut ja täytetty eivät näy');

select is((public.shift_offer_respond_as_staff(:'page_token', 'aaaaaaaa-0000-4000-8000-0000000000h2', 'decline', null)->>'result'),
          'not_owner', 'toisen henkilön tarjoukseen ei voi vastata');
select is((select status from public.shift_offer_recipients
            where offer_id = 'aaaaaaaa-0000-4000-8000-0000000000h2'
              and staff_id = 'aaaaaaaa-0000-4000-8000-0000000000e1'),
          'pending', 'toisen rivi ei muutu');
select is((public.shift_offer_respond_as_staff('bad.token', 'aaaaaaaa-0000-4000-8000-0000000000h1', 'decline', null)->>'result'),
          'bad_token', 'huono token ei kirjaa vastausta');
select is((select status from public.shift_offer_recipients
            where offer_id = 'aaaaaaaa-0000-4000-8000-0000000000h1'
              and staff_id = 'aaaaaaaa-0000-4000-8000-0000000000e2'),
          'pending', 'huono token ei muuta omaa riviä');
select is((public.shift_offer_respond_as_staff(:'page_token', 'aaaaaaaa-0000-4000-8000-0000000000h5', 'decline', null)->>'result'),
          'declined', 'omaan toiseen tarjoukseen voi vastata');
select is((select status from public.shift_offer_recipients
            where offer_id = 'aaaaaaaa-0000-4000-8000-0000000000h5'
              and staff_id = 'aaaaaaaa-0000-4000-8000-0000000000e2'),
          'declined', 'oma rivi kieltäytyy');
select is((public.shift_offer_open_for_token('bad.token')->>'ok')::boolean, false, 'huono token ei listaa tarjouksia');

set local role anon;
select throws_ok('select public.shift_offer_sender_claim(1)', '42501', null, 'anon ei varaa lähetysjonoa');
select throws_ok($$select public.shift_offer_sender_complete('{}'::jsonb)$$, '42501', null, 'anon ei kirjaa lähetystä');
select throws_ok($$select public.shift_offer_whatsapp_apply_status('wamid.x','delivered',null,now())$$, '42501', null, 'anon ei kirjaa toimitusta');
select throws_ok($$select public.shift_offer_mask_phone('+358401234567')$$, '42501', null, 'anon ei peitä numeroa');
select throws_ok($$select public.shift_offer_mask_payload('{}'::jsonb)$$, '42501', null, 'anon ei peitä runkoa');
select throws_ok($$select public.shift_offer_open_for_token('x')$$, '42501', null, 'anon ei listaa tarjouksia');
select throws_ok($$select public.shift_offer_respond_as_staff('x', null, 'decline', null)$$, '42501', null, 'anon ei kirjaa vastaussivun vastausta');
reset role;

select * from finish();
rollback;
