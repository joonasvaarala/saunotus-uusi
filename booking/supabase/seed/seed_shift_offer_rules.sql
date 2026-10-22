-- Vuorotarjousten sääntödata (SPEC.md, Joonas 22.10.2026).
-- EI AJETA TUOTANTOON: rivit ovat jo kannassa sxbofnuisemspgquoxyv. Skripti keskeyttää, jos asetukset eivät ole tyhjät.
-- Henkilöt haetaan public.staff.name-nimellä (nimet ovat yksikäsitteisiä).
--
-- Perinnesaunotus: perjantai (viikonpäivä 5) EI ole allow-listalla. Hoidot ovat perjantaisin aina kiinni,
-- eikä perinnesaunotukselle ole erillistä rajoitusta — rivit poistettiin tuotannosta. Siemen vastaa sitä:
-- ma vain Joonas; ti, ke, to, la, su Joonas tai Laura. Viikonpäivät 1,2,3,4,6,7.
--
-- Kytkimet: enabled = false kaikilla rooleilla, auto_close_enabled = false.
-- Tuotannossa therapist.auto_close_enabled on tällä hetkellä true. Tämä siemen ei kopioi sitä,
-- jotta tyhjä kanta ei sulje hoitoja ennen kuin kytkin erikseen avataan.

do $$
declare n text;
begin
  if exists (select 1 from public.shift_offer_settings) then
    raise exception 'shift_offer_settings ei ole tyhjä — siementä ei ajeta päälle (tuotanto mukaan lukien)';
  end if;
  foreach n in array array['Joonas','Otto','Ksenia','Laura','Jaakko H','Alex','Saara','Johanna','Inkeri'] loop
    if (select count(*) from public.staff where name = n) <> 1 then
      raise exception 'Siemen vaatii tasan yhden public.staff-rivin nimellä %', n;
    end if;
  end loop;
end $$;

create or replace function pg_temp.sid(p_name text) returns uuid
language sql stable as $$ select id from public.staff where name = p_name $$;

insert into public.shift_offer_settings (
  role_type, enabled, start_before, all_by_before, quiet_start, quiet_end, quiet_mode, timezone,
  group_size, group_max_wait, snooze_staff_ids, snooze_any_recipient, snooze_min_left,
  conflicting_roles, conflict_weekdays, conflict_same_day, conflict_exemptions,
  exhausted_ask_staff_id, exhausted_ask_count, exhausted_ask_interval, exhausted_ask_min_interval,
  auto_close_enabled, auto_close_after, alert_before, alert_staff_ids
) values
  ('heater', false, interval '3 months', interval '3 days', '21:00', '08:00', 'shift_deadline', 'Europe/Helsinki',
   3, interval '24 hours', array[pg_temp.sid('Joonas'), pg_temp.sid('Otto')], false, interval '14 days',
   '{therapist}', '{1,2,3,4,5,6,7}', true,
   jsonb_build_array(jsonb_build_object('staff_id', pg_temp.sid('Joonas'), 'weekdays', jsonb_build_array(3))),
   pg_temp.sid('Joonas'), 3, interval '1 day', interval '1 hour', false, null, interval '24 hours',
   array[pg_temp.sid('Joonas'), pg_temp.sid('Otto')]),
  ('reception', false, interval '3 months', interval '3 days', '21:00', '08:00', 'shift_deadline', 'Europe/Helsinki',
   3, interval '24 hours', '{}', true, interval '14 days',
   '{therapist}', '{6,7}', false, '[]'::jsonb,
   pg_temp.sid('Joonas'), 3, interval '1 day', interval '1 hour', false, null, interval '24 hours',
   array[pg_temp.sid('Joonas')]),
  ('therapist', false, interval '3 months', interval '3 days', '21:00', '08:00', 'shift_deadline', 'Europe/Helsinki',
   3, interval '24 hours', '{}', true, interval '14 days',
   '{heater}', '{1,2,3,4,5,6,7}', true,
   jsonb_build_array(jsonb_build_object('staff_id', pg_temp.sid('Joonas'), 'weekdays', jsonb_build_array(3))),
   pg_temp.sid('Joonas'), 3, interval '1 day', interval '1 hour', false, null, interval '24 hours',
   array[pg_temp.sid('Joonas')]);

insert into public.shift_default_owners (role_type, weekday, week_parity, owner_kind, staff_id, follow_role_type, priority, valid_from, valid_to, note) values
  ('heater', 1, 'any', 'staff', pg_temp.sid('Ksenia'), null, 0, '2000-01-01', null, null),
  ('heater', 2, 'any', 'staff', pg_temp.sid('Otto'), null, 0, '2000-01-01', null, null),
  ('heater', 3, 'any', 'staff', pg_temp.sid('Joonas'), null, 0, '2000-01-01', null, null),
  ('heater', 3, 'any', 'staff', pg_temp.sid('Otto'), null, 10, '2026-10-21', '2026-11-30', 'Joonas rakennustöissä, korvaaja Otto (Joonas 21.10.)'),
  ('heater', 4, 'any', 'staff', pg_temp.sid('Ksenia'), null, 0, '2000-01-01', null, null),
  ('heater', 5, 'any', 'staff', pg_temp.sid('Joonas'), null, 0, '2000-01-01', null, null),
  ('heater', 5, 'any', 'staff', pg_temp.sid('Otto'), null, 10, '2026-10-21', '2026-11-30', 'Joonas rakennustöissä, korvaaja Otto (Joonas 21.10.)'),
  ('heater', 6, 'any', 'staff', pg_temp.sid('Otto'), null, 0, '2000-01-01', null, null),
  ('heater', 7, 'any', 'staff', pg_temp.sid('Otto'), null, 0, '2000-01-01', null, null),
  ('reception', 1, 'even', 'follow_role', null, 'therapist', 0, '2000-01-01', null, 'ma parillinen: päivän hoitaja (Jaakko H tai hänen tuuraajansa) on itse vastaanotossa (Joonas 22.10. klo 2.41)'),
  ('reception', 1, 'odd', 'staff', pg_temp.sid('Otto'), null, 0, '2000-01-01', null, 'maanantaisin vastaanotossa Otto'),
  ('reception', 2, 'any', 'follow_role', null, 'therapist', 0, '2000-01-01', null, 'arki: hoitaja = vastaanottaja'),
  ('reception', 3, 'any', 'follow_role', null, 'therapist', 0, '2000-01-01', null, 'arki: hoitaja = vastaanottaja'),
  ('reception', 4, 'any', 'follow_role', null, 'therapist', 0, '2000-01-01', null, 'arki: hoitaja = vastaanottaja'),
  ('reception', 5, 'any', 'not_offered', null, null, 0, '2000-01-01', null, 'pe: vastaanottoa ei määritellä eikä tarjota – vuoron lämmittäjä tai tapahtuman vetäjä (Joonas 22.10. klo 2.37)'),
  ('reception', 6, 'any', 'staff', pg_temp.sid('Otto'), null, 0, '2000-01-01', null, null),
  ('reception', 7, 'any', 'staff', pg_temp.sid('Otto'), null, 0, '2000-01-01', null, null),
  ('therapist', 1, 'even', 'staff', pg_temp.sid('Jaakko H'), null, 0, '2000-01-01', null, 'parilliset viikot'),
  ('therapist', 1, 'odd', 'closed', null, null, 0, '2000-01-01', null, 'parittomien viikkojen maanantait hoidot kiinni'),
  ('therapist', 2, 'any', 'staff', pg_temp.sid('Laura'), null, 0, '2000-01-01', null, null),
  ('therapist', 3, 'any', 'staff', pg_temp.sid('Joonas'), null, 0, '2000-01-01', null, null),
  ('therapist', 4, 'any', 'staff', pg_temp.sid('Laura'), null, 0, '2000-01-01', null, null),
  ('therapist', 5, 'any', 'closed', null, null, 0, '2000-01-01', null, 'perjantaisin hoidot aina kiinni'),
  ('therapist', 6, 'any', 'staff', pg_temp.sid('Joonas'), null, 0, '2000-01-01', null, null),
  ('therapist', 7, 'any', 'staff', pg_temp.sid('Joonas'), null, 0, '2000-01-01', null, null);

-- Kierrokset. Viikonpäivätaulukko on osa uniikkiavainta, järjestys kuten tuotannossa.
insert into public.shift_offer_rounds (role_type, scenario, weekdays, round_no, kind) values
  ('heater', 'vacant_shift', '{1}', 1, 'named'),
  ('heater', 'vacant_shift', '{1}', 2, 'rotation'),
  ('heater', 'vacant_shift', '{1}', 3, 'all'),
  ('heater', 'vacant_shift', '{1}', 4, 'named_last'),
  ('heater', 'vacant_shift', '{2}', 1, 'rotation'),
  ('heater', 'vacant_shift', '{2}', 2, 'all'),
  ('heater', 'vacant_shift', '{2}', 3, 'named_last'),
  ('heater', 'vacant_shift', '{3,4,5}', 1, 'named'),
  ('heater', 'vacant_shift', '{3,4,5}', 2, 'rotation'),
  ('heater', 'vacant_shift', '{3,4,5}', 3, 'all'),
  ('heater', 'vacant_shift', '{6,7}', 1, 'named'),
  ('heater', 'vacant_shift', '{6,7}', 2, 'named'),
  ('heater', 'vacant_shift', '{6,7}', 3, 'rotation'),
  ('heater', 'vacant_shift', '{6,7}', 4, 'all'),
  ('reception', 'vacant_shift', '{6,7}', 1, 'named'),
  ('reception', 'vacant_shift', '{6,7}', 2, 'rotation'),
  ('reception', 'vacant_shift', '{6,7}', 3, 'all'),
  ('reception', 'reception_extra', '{1,2,3,4,6,7}', 1, 'named'),
  ('reception', 'reception_extra', '{1,2,3,4,6,7}', 2, 'named'),
  ('reception', 'reception_extra', '{1,2,3,4,6,7}', 3, 'named'),
  ('therapist', 'vacant_shift', '{1,2,3,4,6,7}', 1, 'named'),
  ('therapist', 'vacant_shift', '{1,2,3,4,6,7}', 2, 'named'),
  ('therapist', 'vacant_shift', '{1,2,3,4,6,7}', 3, 'named');

insert into public.shift_offer_round_members (round_id, staff_id, week_parity, sort_order)
select r.id, s.staff_id, m.week_parity, m.sort_order
  from (values
    ('heater','vacant_shift','{1}'::smallint[], 1::smallint, 'Otto', 'any', 1::smallint),
    ('heater','vacant_shift','{1}', 4, 'Joonas', 'any', 1),
    ('heater','vacant_shift','{2}', 3, 'Joonas', 'any', 1),
    ('heater','vacant_shift','{3,4,5}', 1, 'Joonas', 'any', 1),
    ('heater','vacant_shift','{3,4,5}', 1, 'Otto', 'any', 2),
    ('heater','vacant_shift','{6,7}', 1, 'Joonas', 'any', 1),
    ('heater','vacant_shift','{6,7}', 2, 'Alex', 'any', 1),
    ('reception','vacant_shift','{6,7}', 1, 'Joonas', 'any', 1),
    ('reception','reception_extra','{1,2,3,4,6,7}', 1, 'Otto', 'any', 1),
    ('reception','reception_extra','{1,2,3,4,6,7}', 2, 'Saara', 'any', 1),
    ('reception','reception_extra','{1,2,3,4,6,7}', 3, 'Joonas', 'any', 1),
    ('therapist','vacant_shift','{1,2,3,4,6,7}', 1, 'Joonas', 'any', 1),
    ('therapist','vacant_shift','{1,2,3,4,6,7}', 1, 'Laura', 'any', 2),
    ('therapist','vacant_shift','{1,2,3,4,6,7}', 2, 'Johanna', 'any', 1),
    ('therapist','vacant_shift','{1,2,3,4,6,7}', 2, 'Inkeri', 'any', 2),
    ('therapist','vacant_shift','{1,2,3,4,6,7}', 2, 'Jaakko H', 'odd', 3),
    ('therapist','vacant_shift','{1,2,3,4,6,7}', 3, 'Saara', 'any', 1)
  ) m(role_type, scenario, weekdays, round_no, staff_name, week_parity, sort_order)
  join public.shift_offer_rounds r
    on r.role_type = m.role_type and r.scenario = m.scenario and r.weekdays = m.weekdays and r.round_no = m.round_no
  join lateral (select pg_temp.sid(m.staff_name) as staff_id) s on true;

insert into public.shift_staff_restrictions (role_type, staff_id, weekdays, week_parity, note) values
  ('therapist', pg_temp.sid('Jaakko H'), '{2}', 'any', 'tiistain hoitajavuoroa ei tarjota Jaakko H:lle'),
  ('therapist', pg_temp.sid('Jaakko H'), null, 'even', 'Jaakko H:ta ei kysytä parillisilla viikoilla (oma ma-vuoro on vakio)'),
  ('therapist', pg_temp.sid('Joonas'), '{2}', 'any', 'tiistain hoitajavuoroa ei tarjota Joonakselle');

insert into public.shift_offer_response_tiers (role_type, min_lead, wait, wait_last_round, direct_to_all, note) values
  (null, interval '1 month 15 days', interval '7 days', null, false, 'yli 1,5 kk'),
  (null, interval '1 month', interval '5 days', null, false, '1–1,5 kk'),
  (null, interval '28 days', interval '3 days', null, false, '4 vk – 1 kk (Joonas 22.10. klo 2.37)'),
  (null, interval '14 days', interval '2 days', null, false, '2–4 vk'),
  (null, interval '7 days', interval '24 hours', null, false, '1–2 vk'),
  (null, interval '2 days', interval '6 hours', interval '12 hours', false, '2–7 vrk, kaikille lähtevä kierros 12 h'),
  (null, interval '0', null, null, true, 'alle 2 vrk: suoraan kaikille');

-- Perinnesaunotus. Ei perjantaita (5): hoidot kiinni, ei rajoitusta.
insert into public.shift_service_allowed_therapists (service_code, weekday, staff_id, note)
select 'perinnesaunotus', 1, pg_temp.sid('Joonas'), 'ma: vain Joonas'
union all
select 'perinnesaunotus', d, pg_temp.sid(n), 'muut päivät: Joonas tai Laura'
  from unnest(array[2,3,4,6,7]) d
  cross join unnest(array['Joonas','Laura']) n;

insert into public.shift_service_date_overrides (service_code, on_date, mode, note) values
  ('perinnesaunotus', date '2026-10-26', 'open', 'poikkeus: ma 26.10.2026 perinnesaunotus auki hoitajasta riippumatta');
