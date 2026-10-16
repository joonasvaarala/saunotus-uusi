-- Käyttäjähallinta (roolin vaihto, työntekijälinkitys, svc_*-funktiot Edge Functionille) ja työvuorojen lukunäkymä (public-skeema vain luetaan)
begin;
set local search_path = extensions, public;
select no_plan();

-- ---------- mock-data: public-skeema (oletetut sarakenimet, ks. fixtures/public_mock.sql) ----------
insert into public.staff(id, name, email, phone, active) values
  ('00000000-0000-4000-8000-0000000000e1', 'Pekka Työntekijä', 'pekka@example.com', '0401110001', true),
  ('00000000-0000-4000-8000-0000000000e2', 'Paula Vuoro',      'paula@example.com', '0401110002', true),
  ('00000000-0000-4000-8000-0000000000e3', 'Passiivinen Pena', 'pena@example.com',  '0401110003', false);
insert into public.calendar_sources(id, calendar_name, google_calendar_id) values ('00000000-0000-4000-8000-0000000000c1', 'Savusauna-vuorot', 'secret-cal-id@group.calendar.google.com');
insert into public.work_shifts(id, calendar_source_id, starts_at, ends_at, role_type, status, staffing_status, notes) values
  ('00000000-0000-4000-8000-0000000000f1', '00000000-0000-4000-8000-0000000000c1', now() + interval '1 day',  now() + interval '1 day 4 hours',  'saunottaja', 'active',    'full',    'SALAINEN-HUOMIO-A'),
  ('00000000-0000-4000-8000-0000000000f2', '00000000-0000-4000-8000-0000000000c1', now() + interval '2 days', now() + interval '2 days 4 hours', 'vastaanotto', 'active',   'full',    'SALAINEN-HUOMIO-B'),
  ('00000000-0000-4000-8000-0000000000f3', '00000000-0000-4000-8000-0000000000c1', now() + interval '3 days', now() + interval '3 days 4 hours', 'saunottaja', 'cancelled', 'full',    'SALAINEN-HUOMIO-C'),
  ('00000000-0000-4000-8000-0000000000f4', '00000000-0000-4000-8000-0000000000c1', now() + interval '4 days', now() + interval '4 days 4 hours', 'saunottaja', 'active',    'open',    'SALAINEN-HUOMIO-D'),
  ('00000000-0000-4000-8000-0000000000f5', '00000000-0000-4000-8000-0000000000c1', now() + interval '100 days', now() + interval '100 days 4 hours', 'saunottaja', 'active', 'full',  'SALAINEN-HUOMIO-E');
insert into public.shift_assignments(shift_id, staff_id) values
  ('00000000-0000-4000-8000-0000000000f1', '00000000-0000-4000-8000-0000000000e1'),
  ('00000000-0000-4000-8000-0000000000f1', '00000000-0000-4000-8000-0000000000e2'),
  ('00000000-0000-4000-8000-0000000000f2', '00000000-0000-4000-8000-0000000000e2'),
  ('00000000-0000-4000-8000-0000000000f3', '00000000-0000-4000-8000-0000000000e1'),
  ('00000000-0000-4000-8000-0000000000f5', '00000000-0000-4000-8000-0000000000e1');
create temp table pub_before as select md5(string_agg(t::text, '|' order by t::text)) h from (
  select 's:' || s::text as t from public.staff s union all select 'c:' || c::text from public.calendar_sources c
  union all select 'w:' || w::text from public.work_shifts w union all select 'a:' || a::text from public.shift_assignments a) x;
grant select on pub_before to public;

-- ---------- käyttäjät ja roolit ----------
-- uusi roolilla ilman vuorooikeuksia ja "hr"-rooli, jolla on staff.manage mutta ei admin (todistaa että viimeisen adminin suoja ei riipu roolinimestä)
insert into booking.roles(code, label, is_staff, sort_order) values ('nofiles', 'Ei vuoroja', true, 40), ('hr', 'Henkilöstö', true, 45);
insert into booking.role_permissions(role_code, permission) values ('nofiles', 'bookings.manage'), ('hr', 'staff.manage');
select test.mk_staff('u-admin@example.com', 'admin') as a1, test.mk_staff('u-manager@example.com', 'manager') as m1,
       test.mk_staff('u-staff1@example.com', 'staff') as s1, test.mk_staff('u-staff2@example.com', 'staff') as s2,
       test.mk_staff('u-nofiles@example.com', 'nofiles') as nf, test.mk_staff('u-hr@example.com', 'hr') as hr \gset
select test.mk_user('u-outsider@example.com') as outsider, test.mk_user('u-new@example.com') as newu \gset
update booking.staff set public_staff_id = '00000000-0000-4000-8000-0000000000e1' where user_id = :'s1';

-- ---------- työvuorot: oikeudet ----------
select test.login(:'s1');
select is((select count(*)::int from booking.admin_upcoming_shifts(now(), now() + interval '30 days')), 1, 'staff (shifts.view): näkee vain omat vuorot (1 kpl; peruttu ja kaukainen pois)');
select is((select staff_name from booking.admin_upcoming_shifts(now(), now() + interval '30 days')), 'Pekka Työntekijä', 'staff: näkee vain oman nimensä (ei kollegan nimeä samalta vuorolta)');
select is((select array_agg(k order by k) from (select jsonb_object_keys(to_jsonb(s)) k from booking.admin_upcoming_shifts(now(), now() + interval '30 days') s limit 7) x),
          array['calendar_name','ends_at','role_type','shift_id','staff_name','staffing_status','starts_at'], 'vuorofunktio palauttaa vain sallitut kentät');
select is((select count(*)::int from booking.admin_upcoming_shifts(now(), now() + interval '30 days') s
            where to_jsonb(s)::text ~ '(0401110|pekka@|SALAINEN|secret-cal)'), 0, 'vuorot: ei puhelinta, sähköpostia, muistiinpanoja eikä kalenteri-id:tä');
select throws_ok($$select * from booking.admin_upcoming_shifts(now(), now() + interval '63 days')$$, 'BK001', 'Aikaväli saa olla enintään 62 päivää', 'väli yli 62 pv → virhe');
select lives_ok($$select * from booking.admin_upcoming_shifts(now(), now() + interval '62 days')$$, 'väli tasan 62 pv sallittu');
select throws_ok($$select * from booking.admin_upcoming_shifts(now(), now() - interval '1 day')$$, 'BK001', 'Virheellinen aikaväli', 'käänteinen väli → virhe');
select throws_ok($$select * from booking.admin_upcoming_shifts(null, now())$$, 'BK001', 'Virheellinen aikaväli', 'null-väli → virhe');
select throws_ok($$select * from booking.admin_list_public_staff()$$, 'BK001', 'Ei oikeutta tähän toimintoon (staff.manage)', 'staff: public.staff-listaus estetty');
select throws_ok(format($$select booking.admin_link_public_staff(%L, null)$$, :'s2'), 'BK001', 'Ei oikeutta tähän toimintoon (staff.manage)', 'staff: linkitys estetty');
select throws_ok(format($$select booking.admin_set_staff_role(%L, 'manager')$$, :'s2'), 'BK001', 'Ei oikeutta tähän toimintoon (staff.manage)', 'staff: roolin vaihto estetty');
select test.logout();

select test.login(:'s2');
select is((select count(*)::int from booking.admin_upcoming_shifts(now(), now() + interval '30 days')), 0, 'staff ilman linkkiä työntekijään: tyhjä lista');
select test.logout();

select test.login(:'m1');
select is((select count(*)::int from booking.admin_upcoming_shifts(now(), now() + interval '30 days')), 4, 'manager (shifts.view_all): kaikki aktiiviset vuorot (A kahdelle + B + D; peruttu ja kaukainen pois)');
select is((select count(distinct shift_id)::int from booking.admin_upcoming_shifts(now(), now() + interval '30 days')), 3, 'manager: 3 eri vuoroa');
select is((select count(*)::int from booking.admin_upcoming_shifts(now(), now() + interval '30 days') where staff_name is null), 1, 'manager: vuoro ilman henkilöä näkyy tyhjällä nimellä');
select is((select count(*)::int from booking.admin_upcoming_shifts(now(), now() + interval '30 days') where staff_name = 'Paula Vuoro'), 2, 'manager: näkee muidenkin vuorot');
select is((select count(*)::int from booking.admin_upcoming_shifts(now(), now() + interval '30 days') s where to_jsonb(s)::text ~ '(0401110|@example.com|SALAINEN|secret-cal)'), 0, 'manager: ei vuotavia kenttiä');
select throws_ok($$select * from booking.admin_list_public_staff()$$, 'BK001', 'Ei oikeutta tähän toimintoon (staff.manage)', 'manager: public.staff-listaus estetty (staff.manage vain admin)');
select throws_ok(format($$select booking.admin_set_staff_role(%L, 'admin')$$, :'s2'), 'BK001', 'Ei oikeutta tähän toimintoon (staff.manage)', 'manager ei voi antaa admin-oikeutta');
select throws_ok(format($$select booking.admin_link_public_staff(%L, '00000000-0000-4000-8000-0000000000e2')$$, :'s2'), 'BK001', 'Ei oikeutta tähän toimintoon (staff.manage)', 'manager: linkitys estetty');
select throws_ok($$select * from booking.admin_list_staff()$$, 'BK001', 'Ei oikeutta tähän toimintoon (staff.manage)', 'manager: käyttäjälista estetty');
select test.logout();

select test.login(:'a1');
select is((select count(*)::int from booking.admin_upcoming_shifts(now(), now() + interval '30 days')), 4, 'admin: kaikki vuorot');
select test.logout();

select test.login(:'nf');
select throws_ok($$select * from booking.admin_upcoming_shifts(now(), now() + interval '30 days')$$, 'BK001', 'Ei oikeutta tähän toimintoon (shifts.view)', 'ilman vuorooikeuksia: virhe');
select test.logout();
select test.login(:'outsider');
select throws_ok($$select * from booking.admin_upcoming_shifts(now(), now() + interval '30 days')$$, 'BK001', 'Ei oikeuksia', 'ei-henkilöstö: virhe');
select test.logout();
select test.anon();
select throws_ok($$select * from booking.admin_upcoming_shifts(now(), now() + interval '30 days')$$, '42501', null, 'anon ei voi kutsua vuorofunktiota');
select throws_ok($$select * from booking.admin_list_public_staff()$$, '42501', null, 'anon ei voi listata public.staff');
select throws_ok($$select * from booking.svc_staff_upsert(null, null, 'x', 'staff')$$, '42501', null, 'anon ei voi kutsua svc_staff_upsert');
select test.logout();

-- ---------- admin: työntekijälistaus ja linkitys ----------
select test.login(:'a1');
select is((select array_agg(k order by k) from (select jsonb_object_keys(to_jsonb(p)) k from booking.admin_list_public_staff() p limit 4) x), array['active','email','id','name'], 'admin_list_public_staff: vain id, name, email, active');
select is((select count(*)::int from booking.admin_list_public_staff()), 3, 'admin_list_public_staff: kaikki public.staff-rivit');
select is((select count(*)::int from booking.admin_list_public_staff() p where to_jsonb(p)::text ~ '0401110'), 0, 'admin_list_public_staff: ei puhelinta');
select is(test.code(format($$select booking.admin_link_public_staff(%L, '00000000-0000-4000-8000-0000000000e1')$$, :'s2')), 'public_staff_taken', 'sama työntekijä ei voi olla kahdella käyttäjällä (selkeä virhe)');
select is(test.code(format($$select booking.admin_link_public_staff(%L, '00000000-0000-4000-8000-0000000000e3')$$, :'s2')), 'public_staff_inactive', 'ei-aktiivista työntekijää ei voi linkittää');
select is(test.code(format($$select booking.admin_link_public_staff(%L, '00000000-0000-4000-8000-0000000000ff')$$, :'s2')), 'public_staff_not_found', 'tuntematon työntekijä');
select is(test.code(format($$select booking.admin_link_public_staff(%L, '00000000-0000-4000-8000-0000000000e2')$$, :'outsider')), 'no_such_staff', 'linkitys vaatii booking.staff-rivin');
select is((booking.admin_link_public_staff(:'s2', '00000000-0000-4000-8000-0000000000e2') ->> 'ok')::boolean, true, 'admin linkittää s2:n työntekijään Paula');
select is((select public_staff_id from booking.staff where user_id = :'s2'), '00000000-0000-4000-8000-0000000000e2'::uuid, 'linkki tallentui vain booking.staff-tauluun');
select is((select public_staff_id from booking.admin_list_staff() where user_id = :'s2'), '00000000-0000-4000-8000-0000000000e2'::uuid, 'admin_list_staff palauttaa public_staff_id:n');
select is((booking.admin_upsert_staff(:'s2', 'u-staff2', 'staff', true) ->> 'ok')::boolean, true, 'admin_upsert_staff ilman p_public_staff_id säilyttää linkin');
select is((select public_staff_id from booking.staff where user_id = :'s2'), '00000000-0000-4000-8000-0000000000e2'::uuid, 'linkki säilyi upsertissa');
select is(test.code(format($$select booking.admin_upsert_staff(%L, 'u-staff2', 'staff', true, '00000000-0000-4000-8000-0000000000e1')$$, :'s2')), 'public_staff_taken', 'admin_upsert_staff: sama työntekijä kahdelle estetty');
select is(test.code(format($$select booking.admin_upsert_staff(%L, 'u-staff2', 'staff', true, '00000000-0000-4000-8000-0000000000e3')$$, :'s2')), 'public_staff_inactive', 'admin_upsert_staff: ei-aktiivinen työntekijä estetty');
select is((booking.admin_link_public_staff(:'s2', null) ->> 'ok')::boolean, true, 'linkin poisto (null)');
select is((select public_staff_id from booking.staff where user_id = :'s2'), null, 'linkki poistettu');
select lives_ok(format($$select booking.admin_upsert_staff(%L, 'Uusi Käyttäjä', 'manager', true, '00000000-0000-4000-8000-0000000000e2')$$, :'newu'), 'admin_upsert_staff: uusi käyttäjä linkillä');
select test.logout();
select is((select public_staff_id from booking.staff where user_id = :'newu'), '00000000-0000-4000-8000-0000000000e2'::uuid, 'uuden käyttäjän linkki');
update booking.staff set public_staff_id = null where user_id = :'newu';

-- ---------- admin_set_staff_role ----------
select test.login(:'a1');
select is(test.code(format($$select booking.admin_set_staff_role(%L, 'manager')$$, :'a1')), 'cannot_change_self', 'admin ei voi muuttaa omaa rooliaan');
select is(test.code(format($$select booking.admin_set_staff_role(%L, 'manager')$$, :'outsider')), 'no_such_staff', 'kohteen pitää olla booking.staff-rivillä');
select is(test.code($$select booking.admin_set_staff_role('00000000-0000-4000-8000-00000000dead', 'manager')$$), 'no_such_staff', 'tuntematon kohde');
select is(test.code(format($$select booking.admin_set_staff_role(%L, 'customer')$$, :'s2')), 'invalid_role', 'customer ei kelpaa henkilöstöroolina');
select is(test.code(format($$select booking.admin_set_staff_role(%L, 'annual_card')$$, :'s2')), 'invalid_role', 'annual_card ei kelpaa henkilöstöroolina');
select is(test.code(format($$select booking.admin_set_staff_role(%L, 'olematon')$$, :'s2')), 'invalid_role', 'tuntematon rooli');
select is((booking.admin_set_staff_role(:'s2', 'manager') ->> 'role'), 'manager', 'admin vaihtaa s2:n rooliksi manager');
select is((select role from booking.staff where user_id = :'s2'), 'manager', 'rooli päivittyi');
select test.logout();
select ok((select count(*) from booking.audit_log where table_name = 'staff' and row_pk = :'s2' and action = 'UPDATE' and new_data ->> 'role' = 'manager') >= 1, 'roolin vaihto kirjautui audit-lokiin');
update booking.staff set active = false where user_id = :'s1';
select test.login(:'a1');
select is(test.code(format($$select booking.admin_set_staff_role(%L, 'manager')$$, :'s1')), 'staff_inactive', 'ei-aktiivista käyttäjää ei voi vaihtaa (aktivoi ensin)');
select test.logout();
update booking.staff set active = true where user_id = :'s1';
-- viimeinen admin: hr-rooli (staff.manage, ei admin) yrittää alentaa/deaktivoida ainoaa adminia
select test.login(:'hr');
select is(test.code(format($$select booking.admin_set_staff_role(%L, 'staff')$$, :'a1')), 'last_admin', 'ainoaa aktiivista adminia ei voi alentaa (admin_set_staff_role)');
select is(test.code(format($$select booking.admin_upsert_staff(%L, 'x', 'staff', true)$$, :'a1')), 'last_admin', 'ainoaa aktiivista adminia ei voi alentaa (admin_upsert_staff)');
select is(test.code(format($$select booking.admin_upsert_staff(%L, 'x', 'admin', false)$$, :'a1')), 'last_admin', 'ainoaa aktiivista adminia ei voi deaktivoida (admin_upsert_staff)');
select is((booking.admin_set_staff_role(:'s2', 'staff') ->> 'ok')::boolean, true, 'hr (staff.manage) voi vaihtaa muiden rooleja – oikeus, ei roolinimi ratkaisee');
select test.logout();

-- ---------- svc_*: Edge Function admin-users (service_role) ----------
select test.service();
select is(booking.svc_find_auth_user('U-NEW@example.com'), :'newu'::uuid, 'svc_find_auth_user löytää käyttäjän (kirjainkoosta riippumatta)');
select is(test.code(format($$select booking.svc_staff_upsert(%L, %L, 'Kutsuttu', 'manager')$$, :'m1', :'outsider')), 'forbidden', 'svc_staff_upsert: kutsuja ilman staff.manage (manager) estetty');
select is(test.code(format($$select booking.svc_staff_upsert(%L, %L, 'Kutsuttu', 'manager')$$, :'s1', :'outsider')), 'forbidden', 'svc_staff_upsert: staff estetty');
select is(test.code(format($$select booking.svc_staff_upsert(%L, %L, 'Kutsuttu', 'manager')$$, null, :'outsider')), 'forbidden', 'svc_staff_upsert: ilman kutsujaa estetty');
select is(test.code(format($$select booking.svc_staff_upsert(%L, %L, 'Kutsuttu', 'customer')$$, :'a1', :'outsider')), 'invalid_role', 'svc_staff_upsert: customer ei kelpaa');
select is(test.code(format($$select booking.svc_staff_upsert(%L, %L, 'Kutsuttu', 'annual_card')$$, :'a1', :'outsider')), 'invalid_role', 'svc_staff_upsert: annual_card ei kelpaa');
select is(test.code(format($$select booking.svc_staff_upsert(%L, '00000000-0000-4000-8000-00000000dead', 'Kutsuttu', 'staff')$$, :'a1')), 'no_such_user', 'svc_staff_upsert: tuntematon Auth-käyttäjä');
select is(test.code(format($$select booking.svc_staff_upsert(%L, %L, 'Kutsuttu', 'manager')$$, :'a1', :'outsider')), 'ok', 'svc_staff_upsert: admin kutsuu managerin');
select is((select role from booking.staff where user_id = :'outsider'), 'manager', 'kutsuttu käyttäjä sai roolin');
select is((select active from booking.staff where user_id = :'outsider'), true, 'kutsuttu käyttäjä aktiivinen');
select is((select count(*)::int from booking.audit_log where table_name = 'staff' and row_pk = :'outsider' and action = 'INVITE' and actor = :'a1'::uuid), 1, 'kutsu kirjattu audit-lokiin kutsujan tunnuksella');
select is(test.code(format($$select booking.svc_staff_set_active(%L, %L, false)$$, :'a1', :'a1')), 'cannot_change_self', 'svc_staff_set_active: itseä ei voi deaktivoida');
select is(test.code(format($$select booking.svc_staff_set_active(%L, %L, false)$$, :'m1', :'s1')), 'forbidden', 'svc_staff_set_active: manager estetty');
select is(test.code(format($$select booking.svc_staff_set_active(%L, %L, false)$$, :'hr', :'a1')), 'last_admin', 'svc_staff_set_active: viimeistä adminia ei voi deaktivoida');
select is(test.code(format($$select booking.svc_staff_upsert(%L, %L, 'x', 'staff')$$, :'hr', :'a1')), 'last_admin', 'svc_staff_upsert: viimeistä adminia ei voi alentaa');
select is(test.code(format($$select booking.svc_staff_set_active(%L, '00000000-0000-4000-8000-00000000dead', false)$$, :'a1')), 'no_such_staff', 'svc_staff_set_active: tuntematon');
select is(test.code(format($$select booking.svc_staff_set_active(%L, %L, false)$$, :'a1', :'s1')), 'ok', 'svc_staff_set_active: admin deaktivoi s1:n');
select is((select active from booking.staff where user_id = :'s1'), false, 's1 ei aktiivinen');
select is((select count(*)::int from booking.audit_log where table_name = 'staff' and row_pk = :'s1' and action = 'DEACTIVATE' and actor = :'a1'::uuid), 1, 'deaktivointi kirjattu audit-lokiin');
select is(test.code(format($$select booking.svc_staff_set_active(%L, %L, true)$$, :'a1', :'s1')), 'ok', 'svc_staff_set_active: uudelleenaktivointi');
select is((select count(*)::int from booking.audit_log where table_name = 'staff' and row_pk = :'s1' and action = 'REACTIVATE'), 1, 'uudelleenaktivointi kirjattu');
select test.logout();
-- toinen admin → ensimmäinen voidaan deaktivoida
select test.mk_staff('u-admin2@example.com', 'admin') as a2 \gset
select test.service();
select is(test.code(format($$select booking.svc_staff_set_active(%L, %L, false)$$, :'a2', :'a1')), 'ok', 'kahden adminin kesken toisen deaktivointi sallittu');
select test.logout();
select test.login(:'a1');
select throws_ok($$select booking.svc_staff_upsert(null, null, 'x', 'staff')$$, '42501', null, 'authenticated ei voi kutsua svc_staff_upsert');
select throws_ok($$select booking.svc_staff_set_active(null, null, true)$$, '42501', null, 'authenticated ei voi kutsua svc_staff_set_active');
select test.logout();

-- ---------- public-skeemaan ei kirjoiteta ----------
select is((select md5(string_agg(t::text, '|' order by t::text)) from (
  select 's:' || s::text as t from public.staff s union all select 'c:' || c::text from public.calendar_sources c
  union all select 'w:' || w::text from public.work_shifts w union all select 'a:' || a::text from public.shift_assignments a) x),
  (select h from pub_before), 'public-taulujen sisältö ei muuttunut mistään funktiokutsusta');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'booking' and p.prokind = 'f' and pg_get_functiondef(p.oid) ~* '(insert\s+into|update|delete\s+from|truncate|alter\s+table|create\s+table|drop|grant)\s+(table\s+)?public\.'), 0,
          'yksikään booking-funktio ei sisällä INSERT/UPDATE/DELETE/DDL-lauseita public-skeemaan');
select is((select count(*)::int from information_schema.table_constraints c where c.table_schema = 'booking' and c.table_name = 'staff' and c.constraint_type = 'FOREIGN KEY'
            and exists (select 1 from information_schema.constraint_column_usage u where u.constraint_name = c.constraint_name and u.table_schema = 'public')), 0,
          'booking.staff:lla ei ole viiteavainta public-skeemaan');
select is((select col_description('booking.staff'::regclass, (select attnum from pg_attribute where attrelid = 'booking.staff'::regclass and attname = 'public_staff_id')) like '%LÖYHÄSTI%'), true, 'public_staff_id-sarakkeella on selittävä kommentti');

select * from finish();
rollback;
