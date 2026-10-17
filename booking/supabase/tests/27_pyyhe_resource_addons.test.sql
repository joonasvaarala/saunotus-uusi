-- Migraatio 27: Pyyhe 5 € (applies_modes 'resource'), lisäpalvelurajaus (hoito/saunotus = resource, tapahtuma = event), admin_day_view.code, admin_day_shifts (päivän työvuorot kaikille henkilöstöroolille)
begin;
set local search_path = extensions, public;
select no_plan();

select test.next_dow(2, 6) as tue, test.rule('Naisten sauna%') as r_tue, test.rule('Oma savusaunavuoro ma–pe 16–19%') as r_priv \gset
select (select id from booking.addons where code = 'pyyhe') as a_towel, (select id from booking.addons where code = 'saunavihta') as a_vihta,
       (select id from booking.addons where code = 'turvenaamio_jalkakylpy') as a_mask \gset
update booking.settings set value = '1000' where key in ('rl_change_per_10min', 'rl_ip_per_10min', 'rl_email_per_10min');
select test.mk_staff('p-admin@example.com', 'admin') as adm, test.mk_staff('p-manager@example.com', 'manager') as mgr, test.mk_staff('p-staff@example.com', 'staff') as stf,
       test.mk_user('p-outsider@example.com') as outs \gset
insert into booking.customers(name, email) values ('Pyyhe Testi', 'pyyhe-testi@example.com');
select id as cust from booking.customers where email = 'pyyhe-testi@example.com' \gset
select p.price as p_tue from booking.schedule_rules r join kb.products p on p.id = r.product_id where r.id = :r_tue \gset

-- ================= A) rakenne ja rivit =================
select is((select price_gross from booking.addons where code = 'pyyhe'), 5.00, 'pyyhe: hinta 5,00 €');
select is((select vat_rate from booking.addons where code = 'pyyhe'), 25.5, 'pyyhe: ALV 25,5 %');
select is((select applies_modes from booking.addons where code = 'pyyhe'), array['shared','exclusive','resource'], 'pyyhe: yleinen, yksityinen ja resurssivaraus (hoito, saunotus)');
select is((select active from booking.addons where code = 'pyyhe'), true, 'pyyhe on käytössä');
select is((select applies_modes from booking.addons where code = 'saunavihta'), array['shared','exclusive'], 'saunavihta: ei resource-tilaa');
select is((select applies_modes from booking.addons where code = 'turvenaamio_jalkakylpy'), array['shared','exclusive'], 'turvenaamio ja jalkakylpy: ei resource-tilaa');
select throws_ok($$update booking.addons set applies_modes = '{foo}' where code = 'saunavihta'$$, '23514', null, 'rajoite: tuntematon tila hylätään');
select throws_ok($$update booking.addons set applies_modes = '{event}' where code = 'saunavihta'$$, '23514', null, 'rajoite: event ei ole sallittu tila (tapahtumalle ei lisäpalveluita)');
select lives_ok($$update booking.addons set applies_modes = '{resource}' where code = 'saunavihta'; update booking.addons set applies_modes = '{shared,exclusive}' where code = 'saunavihta'$$, 'rajoite: resource sallittu');

-- ================= B) admin_create_addon / admin_update_addon =================
select test.login(:'adm');
select is(test.code($$select booking.admin_create_addon('{"code":"testi_res","name":"Testi","price":"1","applies_modes":["event"]}'::jsonb)$$), 'invalid_modes', 'admin_create_addon: event hylätään');
select lives_ok($$select booking.admin_create_addon('{"code":"testi_res","name":"Testi","price":"1","applies_modes":["resource"]}'::jsonb)$$, 'admin_create_addon: resource sallittu');
select is((select applies_modes from booking.addons where code = 'testi_res'), array['resource'], 'admin_create_addon: tila tallentui');
select is(test.code(format($$select booking.admin_update_addon(%s, '{"applies_modes":["foo"]}'::jsonb)$$, (select id from booking.addons where code = 'testi_res'))), 'invalid_modes', 'admin_update_addon: tuntematon tila hylätään');
select lives_ok(format($$select booking.admin_update_addon(%s, '{"applies_modes":["shared","resource"]}'::jsonb)$$, (select id from booking.addons where code = 'testi_res')), 'admin_update_addon: shared+resource sallittu');
select test.logout();

-- ================= C) _attach_addons: tehokas tila =================
select test.login(:'stf');
select booking.admin_create_booking(:r_tue, (:'tue'::date + 70), 1, :cust, null, 'pay_later', false, null, null, null, null, 'phone',
         format('[{"id":%s,"quantity":1},{"id":%s,"quantity":1},{"id":%s,"quantity":1}]', :a_towel, :a_vihta, :a_mask)::jsonb, null) as g1 \gset
select is((select count(*)::int from booking.order_items where order_id = (:'g1'::jsonb ->> 'order_id')::bigint and kind = 'addon'), 3, 'yleinen vuoro: pyyhe, vihta ja turvenaamio+jalkakylpy kaikki sallittu');
select is((:'g1'::jsonb ->> 'total')::numeric, (:p_tue)::numeric + 5 + 13 + 15, 'yleinen vuoro: hintaan +5 +13 +15 €');
select booking.admin_create_booking(:r_priv, (:'tue'::date + 71), 2, :cust, null, 'pay_later', false, null, null, null, null, 'phone',
         format('[{"id":%s,"quantity":2},{"id":%s,"quantity":1}]', :a_towel, :a_vihta)::jsonb, null) as g2 \gset
select is((select count(*)::int from booking.order_items where order_id = (:'g2'::jsonb ->> 'order_id')::bigint and kind = 'addon'), 2, 'yksityisvuoro: pyyhe ja vihta sallittu');
select test.logout();
select (:'g1'::jsonb ->> 'reservation_id')::bigint as res1, (select product_id from booking.schedule_rules where id = :r_tue) as prod1 \gset
-- sama varaus resurssivarauksena (hoito/saunotus): sale_kind 'other' + resourced → tila 'resource'
update booking.product_config set sale_kind = 'other', resource_class = 'resourced' where product_id = :prod1;
select is(test.code(format($$select booking._attach_addons(%s, '[{"id":%s,"quantity":1}]'::jsonb)$$, :res1, :a_vihta)), 'addon_not_allowed', 'hoito/saunotus: saunavihta ei sallittu');
select is(test.code(format($$select booking._attach_addons(%s, '[{"id":%s,"quantity":1}]'::jsonb)$$, :res1, :a_mask)), 'addon_not_allowed', 'hoito/saunotus: turvenaamio ja jalkakylpy ei sallittu');
select is(booking._attach_addons(:res1, format('[{"id":%s,"quantity":1}]', :a_towel)::jsonb), 5.00, 'hoito/saunotus: pyyhe sallittu (+5 €)');
-- tapahtuma (kategoria event): ei mitään
update kb.products set category = 'event' where id = :prod1;
select is(test.code(format($$select booking._attach_addons(%s, '[{"id":%s,"quantity":1}]'::jsonb)$$, :res1, :a_towel)), 'addon_not_allowed', 'tapahtuma: pyyhekään ei ole sallittu');
select is(test.code(format($$select booking._attach_addons(%s, '[{"id":%s,"quantity":1}]'::jsonb)$$, :res1, :a_vihta)), 'addon_not_allowed', 'tapahtuma: saunavihta ei sallittu');

-- ================= D) admin_day_view: code lisäpalvelurivillä =================
select test.login(:'stf');
select booking.admin_day_view((:'tue'::date + 70)) as dv \gset
select is((select array_agg(a ->> 'code' order by a ->> 'code') from jsonb_array_elements(:'dv'::jsonb -> 'reservations') r, jsonb_array_elements(r -> 'addons') a where (r ->> 'reservation_id')::bigint = :res1),
          array['pyyhe','pyyhe','saunavihta','turvenaamio_jalkakylpy'], 'admin_day_view.reservations[].addons[].code (varaus 1: pyyhe ×2 sis. lisätty, vihta, turvenaamio)');
select ok((select bool_and(i ? 'code' and i ->> 'code' is not null) from jsonb_array_elements(:'dv'::jsonb -> 'prep') p, jsonb_array_elements(p -> 'items') i), 'admin_day_view.prep[].items[].code');
select ok((select bool_and(t ? 'code' and t ->> 'code' is not null) from jsonb_array_elements(:'dv'::jsonb -> 'addon_totals') t) and jsonb_array_length(:'dv'::jsonb -> 'addon_totals') >= 3, 'admin_day_view.addon_totals[].code');
select test.logout();

-- ================= E) admin_day_shifts: päivän työvuorot kaikille henkilöstöroolille =================
insert into public.staff(id, name, email, active) values ('00000000-0000-4000-8000-0000000027e1', 'Vuoro Vesa', 'vesa27@example.com', true), ('00000000-0000-4000-8000-0000000027e2', 'Vuoro Venla', 'venla27@example.com', true);
insert into public.calendar_sources(id, calendar_name, google_calendar_id) values ('00000000-0000-4000-8000-0000000027c1', 'Lämmitykset', 'x27@group.calendar.google.com');
insert into public.work_shifts(id, calendar_source_id, starts_at, ends_at, role_type, status, staffing_status, notes) values
  ('00000000-0000-4000-8000-0000000027f1', '00000000-0000-4000-8000-0000000027c1', ((current_date + 40)::timestamp + interval '10 hours') at time zone 'Europe/Helsinki', ((current_date + 40)::timestamp + interval '14 hours') at time zone 'Europe/Helsinki', 'heater', 'active', 'full', 'SALAINEN27'),
  ('00000000-0000-4000-8000-0000000027f2', '00000000-0000-4000-8000-0000000027c1', ((current_date + 40)::timestamp + interval '12 hours') at time zone 'Europe/Helsinki', ((current_date + 40)::timestamp + interval '18 hours') at time zone 'Europe/Helsinki', 'therapist', 'cancelled', 'full', 'SALAINEN27'),
  ('00000000-0000-4000-8000-0000000027f3', '00000000-0000-4000-8000-0000000027c1', ((current_date + 41)::timestamp + interval '10 hours') at time zone 'Europe/Helsinki', ((current_date + 41)::timestamp + interval '12 hours') at time zone 'Europe/Helsinki', 'therapist', 'active', 'open', 'SALAINEN27');
insert into public.shift_assignments(shift_id, staff_id) values ('00000000-0000-4000-8000-0000000027f1', '00000000-0000-4000-8000-0000000027e1'), ('00000000-0000-4000-8000-0000000027f1', '00000000-0000-4000-8000-0000000027e2');
select test.login(:'stf');
select is((select count(*)::int from booking.admin_upcoming_shifts(((current_date + 40)::timestamp) at time zone 'Europe/Helsinki', ((current_date + 41)::timestamp) at time zone 'Europe/Helsinki')), 0, 'lähtötilanne: staff (shifts.view, ei linkkiä) ei saa muiden vuoroja admin_upcoming_shiftsistä');
select is((select array_agg(staff_name order by staff_name) from booking.admin_day_shifts(current_date + 40)), array['Vuoro Venla','Vuoro Vesa'], 'admin_day_shifts: staff näkee päivän vuoron kaikki nimet');
select is((select count(distinct shift_id)::int from booking.admin_day_shifts(current_date + 40)), 1, 'admin_day_shifts: peruttu vuoro ei näy');
select is((select role_type from booking.admin_day_shifts(current_date + 40) limit 1), 'heater', 'admin_day_shifts: tehtävätyyppi');
select is((select count(*)::int from booking.admin_day_shifts(current_date + 41)), 1, 'admin_day_shifts: vuoro ilman henkilöä saa rivin (nimi null)');
select is((select staff_name from booking.admin_day_shifts(current_date + 41)), null, 'admin_day_shifts: vuoro ilman henkilöä → tyhjä nimi');
select ok(not exists (select 1 from jsonb_object_keys((select to_jsonb(s) from booking.admin_day_shifts(current_date + 40) s limit 1)) k where k in ('notes','email','phone')), 'admin_day_shifts: ei muistiinpanoja, sähköpostia eikä puhelinta');
select test.logout();
select test.login(:'mgr');
select is((select count(distinct shift_id)::int from booking.admin_day_shifts(current_date + 40)), 1, 'admin_day_shifts: manager näkee vuoron');
select test.logout();
select test.login(:'outs');
select is(test.code($$select * from booking.admin_day_shifts(current_date + 40)$$), 'forbidden', 'admin_day_shifts: ei-henkilöstö ei pääse');
select test.logout();
select test.anon();
select throws_ok($$select * from booking.admin_day_shifts(current_date + 40)$$, '42501', null, 'admin_day_shifts: anon ei pääse (ei EXECUTE-oikeutta)');
select test.logout();

-- ================= F) ACL =================
select is((select has_function_privilege('anon', 'booking.admin_day_shifts(date)', 'execute')), false, 'admin_day_shifts: anonilla ei execute-oikeutta');
select is((select has_function_privilege('authenticated', 'booking.admin_day_shifts(date)', 'execute')), true, 'admin_day_shifts: authenticated saa kutsua (funktion sisäinen _require_staff rajaa)');

select * from finish();
rollback;
