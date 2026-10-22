-- Saapuva WhatsApp: tallennus aina, vastaus vain kun whatsapp_inbound_enabled ja numero on yksi aktiivinen työntekijä.
-- Tuntemattomalle numerolle ei tule reply_bodyä eikä outbound-riviä.
begin;
set local search_path = extensions, public;
select no_plan();

select is(
  (select whatsapp_inbound_enabled from public.shift_offer_engine_settings),
  false,
  'whatsapp_inbound_enabled on oletuksena pois');

-- ---------- henkilöstö ----------
insert into public.staff (id, name, email, active, phone_e164, calendar_name, whatsapp_enabled) values
  ('11111111-1111-4111-8111-111111111111', 'Pekka Testi', 'pekka.wa@example.com', true, '+358401110001', 'Pekka', false),
  ('22222222-2222-4222-8222-222222222222', 'Paula Testi', 'paula.secret@example.com', true, '+358401110002', 'Paula', false),
  ('33333333-3333-4333-8333-333333333333', 'Aino Yllapito', 'aino.wa@example.com', true, '+358401110003', 'Aino', false),
  ('44444444-4444-4444-8444-444444444444', 'Matti Yllapito', 'matti.wa@example.com', true, '+358401110004', 'Matti', false),
  ('55555555-5555-4555-8555-555555555555', 'Sami Puhelin', 'sami.wa@example.com', true, '+358401110005', 'Sami', false),
  ('66666666-6666-4666-8666-666666666661', 'Kaksonen A', 'kaks.a@example.com', true, '+358401110077', 'Kaksonen A', false),
  ('66666666-6666-4666-8666-666666666662', 'Kaksonen B', 'kaks.b@example.com', true, '+358401110077', 'Kaksonen B', false),
  ('77777777-7777-4777-8777-777777777777', 'Entinen Ella', 'ella.wa@example.com', false, '+358401110088', 'Ella', false);
insert into public.staff_roles (staff_id, role_type, active) values
  ('11111111-1111-4111-8111-111111111111', 'heater', true),
  ('22222222-2222-4222-8222-222222222222', 'heater', true),
  ('33333333-3333-4333-8333-333333333333', 'heater', true),
  ('44444444-4444-4444-8444-444444444444', 'heater', true),
  ('55555555-5555-4555-8555-555555555555', 'heater', true);
select test.mk_staff('pekka.wa@example.com', 'staff') as pekka_user \gset
select test.mk_staff('aino.wa@example.com', 'admin') as aino_user \gset
select test.mk_staff('matti.wa@example.com', 'manager') as matti_user \gset
update booking.staff set public_staff_id = '11111111-1111-4111-8111-111111111111', name = 'Pekka Testi' where user_id = :'pekka_user';
update booking.staff set public_staff_id = '33333333-3333-4333-8333-333333333333', name = 'Aino Yllapito' where user_id = :'aino_user';
update booking.staff set public_staff_id = '44444444-4444-4444-8444-444444444444', name = 'Matti Yllapito' where user_id = :'matti_user';

select (public.whatsapp_store_inbound(
  'wamid.off', '358401110001', now(), 'text', 'vuorot', null)->>'id')::uuid as off_id \gset
select is(
  (select staff_id = '11111111-1111-4111-8111-111111111111' and handled_at is null
     from public.whatsapp_messages where id = :'off_id'::uuid),
  true,
  'kytkin pois: viesti tallentuu tunnistetulle työntekijälle ja jää käsittelemättömäksi');
select ok(
  (public.whatsapp_inbound_act(:'off_id'::uuid, '{"op":"own_shifts"}'::jsonb)->>'reply_body') is null
  and (public.whatsapp_inbound_act(:'off_id'::uuid, '{"op":"all_shifts"}'::jsonb)->>'suppressed')::boolean,
  'kytkin pois: act on hiljaa');
select is(
  (select count(*)::int from public.whatsapp_messages where direction = 'outbound'),
  0,
  'kytkin pois: ei outbound-riviä');

update public.shift_offer_engine_settings set whatsapp_inbound_enabled = true;

-- ---------- tuntematon, kaksoiskappale, epäselvä ja passiivinen ----------
select public.whatsapp_store_inbound(
  'wamid.unknown', '358409990099', now(), 'text', 'vuorot Paula', null) as unknown_store \gset
select ok(
  (:'unknown_store'::jsonb->>'staff_id') is null
  and (:'unknown_store'::jsonb->>'duplicate')::boolean = false
  and (:'unknown_store'::jsonb->>'inbound_enabled')::boolean,
  'tuntematon numero tallentuu ilman staff_id:tä');
select is(
  (select handled_at is null and direction = 'inbound' and phone_e164 = '+358409990099'
     from public.whatsapp_messages where provider_message_id = 'wamid.unknown'),
  true,
  'tuntematon rivi jää Tapiolle käsittelemättömänä');
select ok(
  (public.whatsapp_inbound_act((:'unknown_store'::jsonb->>'id')::uuid, '{"op":"all_shifts"}'::jsonb)->>'reply_body') is null
  and (public.whatsapp_inbound_act((:'unknown_store'::jsonb->>'id')::uuid, '{"op":"person_shifts","name":"Paula"}'::jsonb)->>'suppressed')::boolean
  and (public.whatsapp_inbound_act((:'unknown_store'::jsonb->>'id')::uuid, '{"op":"own_shifts"}'::jsonb)->>'reply_body') is null,
  'tuntematon numero: act ei palauta tekstiä');
select is(
  (select count(*)::int from public.whatsapp_messages where direction = 'outbound'),
  0,
  'tuntematon numero: ei outbound-viestiä');
select ok(
  not exists (
    select 1 from public.whatsapp_messages
     where direction = 'outbound'
        or (direction = 'inbound' and provider_message_id = 'wamid.unknown' and message_text like '%03:33%')
  ),
  'tuntemattoman rivillä ei ole vuorotietoja eikä lähtevää viestiä');

select is((public.whatsapp_store_inbound(
  'wamid.unknown', '358409990099', now(), 'text', 'uudestaan', null)->>'duplicate')::boolean,
  true, 'sama wamid on kaksoiskappale');
select is(
  (select count(*)::int from public.whatsapp_messages where provider_message_id = 'wamid.unknown'),
  1, 'kaksoiskappale ei tee toista riviä');

select ok(
  (public.whatsapp_store_inbound('wamid.twin', '358401110077', now(), 'text', 'vuorot', null)->>'staff_id') is null,
  'kaksi aktiivista samaa numeroa ei täsmää kehenkään');
select ok(
  (public.whatsapp_inbound_act(
     (select id from public.whatsapp_messages where provider_message_id = 'wamid.twin'),
     '{"op":"own_shifts"}'::jsonb)->>'reply_body') is null,
  'epäselvä numero on hiljaa');
select ok(
  (public.whatsapp_store_inbound('wamid.inactive', '358401110088', now(), 'text', 'vuorot', null)->>'staff_id') is null,
  'passiivista työntekijää ei täsmätä');
select is(
  (select count(*)::int from public.whatsapp_messages where direction = 'outbound'),
  0,
  'epäselvä ja passiivinen numero eivät myöskään luo outbound-riviä');

-- ---------- vuorot ----------
insert into public.calendar_sources (id, calendar_name, google_calendar_id, role_type, active)
values ('cccccccc-cccc-4ccc-8ccc-cccccccccc01', 'Lämmitys testi', 'wa-test@example.com', 'heater', true);
select ((now() at time zone 'Europe/Helsinki')::date + 2) as d2 \gset
select ((now() at time zone 'Europe/Helsinki')::date + 3) as d3 \gset
select ((now() at time zone 'Europe/Helsinki')::date + 4) as d4 \gset
select ((now() at time zone 'Europe/Helsinki')::date + 5) as d5 \gset
insert into public.work_shifts (id, calendar_source_id, starts_at, ends_at, role_type, status, staffing_status) values
  ('12121212-1212-4212-8212-121212121212', 'cccccccc-cccc-4ccc-8ccc-cccccccccc01',
    (:'d2'::date + time '10:00') at time zone 'Europe/Helsinki',
    (:'d2'::date + time '14:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'assigned'),
  ('23232323-2323-4232-8232-232323232323', 'cccccccc-cccc-4ccc-8ccc-cccccccccc01',
    (:'d3'::date + time '03:33') at time zone 'Europe/Helsinki',
    (:'d3'::date + time '07:33') at time zone 'Europe/Helsinki', 'heater', 'active', 'assigned'),
  ('56565656-5656-4565-8565-565656565656', 'cccccccc-cccc-4ccc-8ccc-cccccccccc01',
    (:'d2'::date + time '08:15') at time zone 'Europe/Helsinki',
    (:'d2'::date + time '12:15') at time zone 'Europe/Helsinki', 'heater', 'active', 'assigned'),
  ('34343434-3434-4343-8343-343434343434', 'cccccccc-cccc-4ccc-8ccc-cccccccccc01',
    (:'d4'::date + time '12:00') at time zone 'Europe/Helsinki',
    (:'d4'::date + time '16:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'open'),
  ('45454545-4545-4454-8454-454545454545', 'cccccccc-cccc-4ccc-8ccc-cccccccccc01',
    (:'d5'::date + time '12:00') at time zone 'Europe/Helsinki',
    (:'d5'::date + time '16:00') at time zone 'Europe/Helsinki', 'heater', 'active', 'open');
insert into public.shift_assignments (shift_id, staff_id, status) values
  ('12121212-1212-4212-8212-121212121212', '11111111-1111-4111-8111-111111111111', 'assigned'),
  ('12121212-1212-4212-8212-121212121212', '22222222-2222-4222-8222-222222222222', 'assigned'),
  ('23232323-2323-4232-8232-232323232323', '22222222-2222-4222-8222-222222222222', 'assigned'),
  ('56565656-5656-4565-8565-565656565656', '55555555-5555-4555-8555-555555555555', 'assigned');

select (public.whatsapp_store_inbound('wamid.pekka.own', '358401110001', now(), 'text', 'vuorot', null)->>'id')::uuid as pekka_own \gset
with act as (
  select public.whatsapp_inbound_act(:'pekka_own'::uuid, '{"op":"own_shifts"}'::jsonb) as doc
)
select ok(
  (select doc->>'reply_body' from act) like '%10:00%'
  and (select doc->>'reply_body' from act) like '%lämmitysvuoro%'
  and (select doc->>'reply_body' from act) like '%–Tapio'
  and (select doc->>'reply_body' from act) not like '%Paula%'
  and (select doc->>'reply_body' from act) not like '%03:33%'
  and (select doc->>'reply_body' from act) not like '%08:15%'
  and (select doc->>'reply_body' from act) not like '%401110002%'
  and (select doc->>'reply_body' from act) not like '%@example.com%',
  'Pekka näkee vain oman vuoronsa, ei Paulan nimeä, merkkihetkeä, numeroa tai sähköpostia');

select (public.whatsapp_store_inbound('wamid.pekka.other', '358401110001', now(), 'text', 'vuorot Paula', null)->>'id')::uuid as pekka_other \gset
with act as (
  select public.whatsapp_inbound_act(:'pekka_other'::uuid, '{"op":"person_shifts","name":"Paula"}'::jsonb) as doc
)
select ok(
  (select doc->>'reply_body' from act) = E'Näet vain omat vuorosi. Kirjoita vuorot.\n–Tapio'
  and (select doc->>'reply_body' from act) not like '%Paula%'
  and (select doc->>'reply_body' from act) not like '%03:33%',
  'peruskäyttäjä ei näe toisen vuoroja eikä nimeä');
select (public.whatsapp_store_inbound('wamid.pekka.all', '358401110001', now(), 'text', 'kaikki vuorot', null)->>'id')::uuid as pekka_all \gset
select is(
  public.whatsapp_inbound_act(:'pekka_all'::uuid, '{"op":"all_shifts"}'::jsonb)->>'reply_body',
  E'Näet vain omat vuorosi. Kirjoita vuorot.\n–Tapio',
  'peruskäyttäjä ei näe kaikkien listaa');
select is(
  (select count(*)::int from public.whatsapp_pending_actions),
  0,
  'peruskäyttäjän katselu ei luo odottavaa muutosta');
select is(
  public.whatsapp_inbound_act(:'pekka_all'::uuid, '{"op":"prepare_cancel","index":1}'::jsonb)->>'reply_body',
  E'Vain ylläpitäjä voi muuttaa vuoroja.\n–Tapio',
  'peruskäyttäjä ei pääse muokkaukseen');

select (public.whatsapp_store_inbound('wamid.sami.own', '358401110005', now(), 'text', 'vuorot', null)->>'id')::uuid as sami_own \gset
with act as (
  select public.whatsapp_inbound_act(:'sami_own'::uuid, '{"op":"own_shifts"}'::jsonb) as doc
)
select ok(
  (select doc->>'reply_body' from act) like '%08:15%'
  and (select doc->>'reply_body' from act) not like '%03:33%'
  and (select doc->>'reply_body' from act) not like '%Paula%',
  'pelkkä puhelinnumero näkee omat vuoronsa');
select is(
  public.whatsapp_inbound_act(:'sami_own'::uuid, '{"op":"all_shifts"}'::jsonb)->>'reply_body',
  E'Näet vain omat vuorosi. Kirjoita vuorot.\n–Tapio',
  'pelkkä puhelinnumero ei näe muiden vuoroja');

select (public.whatsapp_store_inbound('wamid.aino.all', '358401110003', now(), 'text', 'kaikki vuorot', null)->>'id')::uuid as aino_all \gset
with act as (
  select public.whatsapp_inbound_act(:'aino_all'::uuid, '{"op":"all_shifts"}'::jsonb) as doc
)
select ok(
  (select doc->>'reply_body' from act) like '%Paula Testi%'
  and (select doc->>'reply_body' from act) like '%03:33%'
  and (select doc->>'reply_body' from act) not like '%401110002%'
  and (select doc->>'reply_body' from act) not like '%paula.secret%',
  'admin näkee nimet ja merkkihetken, ei puhelinta eikä sähköpostia');
select (public.whatsapp_store_inbound('wamid.matti.all', '358401110004', now(), 'text', 'kaikki vuorot', null)->>'id')::uuid as matti_all \gset
select ok(
  (public.whatsapp_inbound_act(:'matti_all'::uuid, '{"op":"all_shifts"}'::jsonb)->>'reply_body') like '%03:33%',
  'ylläpitäjä näkee muiden vuorot');

-- ---------- hyväksyntä ja vahvistettu muutos ----------
update public.shift_sync_settings set db_first_enabled = true;
insert into public.shift_offers (id, shift_id, role_type, scenario, status) values
  ('88888888-8888-4888-8888-888888888881', '34343434-3434-4343-8343-343434343434', 'heater', 'vacant_shift', 'active'),
  ('88888888-8888-4888-8888-888888888882', '45454545-4545-4454-8454-454545454545', 'heater', 'vacant_shift', 'active');
insert into public.shift_offer_recipients (offer_id, staff_id, round_no, round_kind, status, deadline_at) values
  ('88888888-8888-4888-8888-888888888881', '11111111-1111-4111-8111-111111111111', 1, 'named', 'pending', now() + interval '2 days'),
  ('88888888-8888-4888-8888-888888888882', '11111111-1111-4111-8111-111111111111', 1, 'named', 'pending', now() + interval '2 days');

select (public.whatsapp_store_inbound('wamid.pekka.accept', '358401110001', now(), 'text', 'hyväksy', null)->>'id')::uuid as pekka_acc \gset
select ok(
  (public.whatsapp_inbound_act(
     :'pekka_acc'::uuid,
     jsonb_build_object('op', 'accept', 'offer_id', '88888888-8888-4888-8888-888888888881'))->>'reply_body')
  like 'Vuoro on sinun:%',
  'WhatsApp-hyväksyntä vahvistaa vuoron');
select is(
  (select status from public.shift_offer_recipients
    where offer_id = '88888888-8888-4888-8888-888888888881' and staff_id = '11111111-1111-4111-8111-111111111111'),
  'accepted',
  'vastaanottaja on accepted');
select is(
  (select count(*)::int from public.shift_assignments
    where shift_id = '34343434-3434-4343-8343-343434343434'
      and staff_id = '11111111-1111-4111-8111-111111111111'
      and status = 'assigned'),
  1,
  'hyväksyntä kirjoittaa vuoron shift_apply_changella');
select is(
  (public.shift_offer_respond(
     '88888888-8888-4888-8888-888888888882',
     '11111111-1111-4111-8111-111111111111',
     'accept', null, true, 'link')->>'result'),
  'accepted',
  'linkkipolku shift_offer_respond hyväksyy yhä');

select ok(
  (public.whatsapp_inbound_act(:'aino_all'::uuid, '{"op":"all_shifts"}'::jsonb)->>'reply_body') like '%03:33%',
  'admin listaa vuorot uudelleen ennen peruutusta');
select array_position(c.shift_ids, '23232323-2323-4232-8232-232323232323'::uuid)::int as paula_idx
  from public.whatsapp_staff_context c
 where c.staff_id = '33333333-3333-4333-8333-333333333333' \gset
select ok(:paula_idx > 0, 'Paulan vuoro on adminin listalla');
select ok(
  (public.whatsapp_inbound_act(
     :'aino_all'::uuid,
     jsonb_build_object('op', 'prepare_cancel', 'index', :paula_idx))->>'reply_body') like 'Vahvistatko peruutuksen:%',
  'peruutus kysyy vahvistuksen eikä kirjoita vielä');
select is(
  (select status from public.work_shifts where id = '23232323-2323-4232-8232-232323232323'),
  'active',
  'vahvistamaton peruutus jättää vuoron voimaan');
select id::text as aino_action from public.whatsapp_pending_actions
 where staff_id = '33333333-3333-4333-8333-333333333333' and consumed_at is null \gset
select ok(:'aino_action' <> '', 'odottava muutos on olemassa');

select (public.whatsapp_store_inbound('wamid.pekka.confirm', '358401110001', now(), 'text', 'kyllä', null)->>'id')::uuid as pekka_yes \gset
select is(
  public.whatsapp_inbound_act(
    :'pekka_yes'::uuid,
    jsonb_build_object('op', 'confirm', 'action_id', :'aino_action'))->>'reply_body',
  E'Vain ylläpitäjä voi muuttaa vuoroja.\n–Tapio',
  'peruskäyttäjä ei vahvista toisen muutosta');
select is(
  (select status from public.work_shifts where id = '23232323-2323-4232-8232-232323232323'),
  'active',
  'väärä vahvistaja ei peru vuoroa');
select is(
  (select consumed_at is null from public.whatsapp_pending_actions where id = :'aino_action'::uuid),
  true,
  'väärä vahvistaja ei kuluta odottavaa muutosta');

select ok(
  (public.whatsapp_inbound_act(
     :'aino_all'::uuid,
     jsonb_build_object('op', 'confirm', 'action_id', :'aino_action'))->>'reply_body') like 'Peruin vuoron:%',
  'adminin vahvistus peruu vuoron');
select is(
  (select status from public.work_shifts where id = '23232323-2323-4232-8232-232323232323'),
  'cancelled',
  'vuoro on peruttu vasta vahvistuksen jälkeen');
select is(
  (select count(*)::int from public.whatsapp_messages where direction = 'outbound'),
  0,
  'tietokanta ei lähetä outbound-viestiä kenellekään; lähetys on edge-funktion asia');

-- ---------- oikeudet ----------
set local role anon;
select throws_ok('select * from public.whatsapp_messages', '42501', null, 'anon ei lue viestejä');
select throws_ok(
  $$insert into public.whatsapp_messages (direction, message_text) values ('inbound', 'x')$$,
  '42501', null, 'anon ei kirjoita viestejä');
select throws_ok(
  $$select public.whatsapp_store_inbound('wamid.anon', '358409990099', now(), 'text', 'vuorot', null)$$,
  '42501', null, 'anon ei tallenna saapuvaa');
select throws_ok(
  $$select public.whatsapp_inbound_act('11111111-1111-4111-8111-111111111111', '{"op":"own_shifts"}'::jsonb)$$,
  '42501', null, 'anon ei aja itsepalvelua');
reset role;
set local role service_role;
select lives_ok(
  $$select public.whatsapp_store_inbound('wamid.service', '358409990099', now(), 'text', 'hei', null)$$,
  'service_role tallentaa saapuvan');
reset role;
select is(
  (select staff_id is null and handled_at is null from public.whatsapp_messages where provider_message_id = 'wamid.service'),
  true,
  'service_role-tallennus jättää tuntemattoman käsittelemättömäksi');

select finish();
rollback;
