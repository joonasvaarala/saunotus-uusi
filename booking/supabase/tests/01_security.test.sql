-- Turvallisuus: RLS, oikeudet, search_path, anon-rajapinta
begin;
set local search_path = extensions, public;
select no_plan();

-- RLS päällä kaikilla booking-tauluilla
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'booking' and c.relkind = 'r' and not c.relrowsecurity), 0, 'RLS päällä kaikilla booking-tauluilla');

-- jokainen SECURITY DEFINER -funktio asettaa search_pathin (Supabase advisor: function_search_path_mutable)
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'booking' and p.prosecdef
              and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')), 0,
          'kaikilla SECURITY DEFINER -funktioilla on kiinteä search_path');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'booking'
              and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')), 0,
          'kaikilla booking-funktioilla on kiinteä search_path');

-- anon saa suorittaa VAIN public_*-funktioita
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'booking' and has_function_privilege('anon', p.oid, 'execute')),
          array['public_addons','public_availability','public_cancel_booking','public_catalog','public_change_booking','public_create_booking','public_get_booking','public_product_images','public_settings'],
          'anon voi kutsua vain public_*-funktioita');
-- authenticated: public_* + admin_* + is_staff/is_admin/current_staff_role/has_permission, EI sisäisiä (_*) eikä maksuadapteria
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'booking' and has_function_privilege('authenticated', p.oid, 'execute')
              and p.proname not like 'public\_%' and p.proname not like 'admin\_%' and p.proname not in ('is_staff','is_admin','current_staff_role','has_permission')), 0,
          'authenticated ei voi kutsua sisäisiä funktioita eikä maksuadapteria');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'booking' and p.proname like 'payment\_%' and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0,
          'maksuadapterifunktiot vain service_rolelle');
select ok(has_function_privilege('service_role', 'booking.payment_mark_paid(text,text,numeric,jsonb)', 'execute'), 'service_role voi kutsua payment_mark_paid');
-- Edge Function admin-users: svc_*-funktiot vain service_rolelle
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'booking' and p.proname like 'svc\_%' and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute') or not has_function_privilege('service_role', p.oid, 'execute'))), 0,
          'svc_*-funktiot (Edge Function) vain service_rolelle');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'booking' and p.proname in ('admin_set_staff_role','admin_list_public_staff','admin_link_public_staff','admin_upcoming_shifts')
              and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('public', p.oid, 'execute')), 4,
          'uudet henkilöstö-/vuorofunktiot: execute vain authenticated (ei anon/public)');

-- anon ei pääse mihinkään tauluun
select test.anon();
select throws_ok('select * from booking.customers', '42501', null, 'anon ei lue asiakkaita');
select throws_ok('select * from booking.reservations', '42501', null, 'anon ei lue varauksia');
select throws_ok('select * from booking.orders', '42501', null, 'anon ei lue tilauksia');
select throws_ok('select * from booking.settings', '42501', null, 'anon ei lue asetuksia suoraan');
select throws_ok('select * from booking.rate_limit_hits', '42501', null, 'anon ei lue rate limit -lokia');
select throws_ok($$insert into booking.customers(name) values ('x')$$, '42501', null, 'anon ei kirjoita asiakkaita');
select throws_ok('select * from kb.products', '42501', null, 'anon ei pääse kb-tauluihin booking-skeeman kautta');
select throws_ok($$select booking.admin_list_customers()$$, '42501', null, 'anon ei voi kutsua admin_list_customers');
select throws_ok($$select booking._create_booking_core(1, current_date, 1, null, 'web', null, 'fi', null, 'confirmed', 15, false)$$, '42501', null, 'anon ei voi kutsua sisäistä ydintä');
select lives_ok($$select booking.public_catalog()$$, 'anon voi hakea katalogin');
select test.logout();

-- kirjautunut mutta EI staff: ei näe mitään
select test.mk_user('random@example.com') as uid \gset
select test.login(:'uid');
select is((select count(*)::int from booking.customers), 0, 'ei-staff ei näe asiakkaita (RLS)');
select is((select count(*)::int from booking.settings), 0, 'ei-staff ei näe asetuksia (RLS)');
select throws_ok($$select booking.admin_list_customers()$$, 'BK001', 'Ei oikeuksia', 'ei-staff ei voi käyttää hallinnan funktioita');
select throws_ok($$insert into booking.customers(name) values ('x')$$, '42501', null, 'ei-staff ei kirjoita');
select test.logout();

-- staff: lukee, ei kirjoita suoraan; ei admin-toimintoja
select test.mk_staff('staff@example.com', 'staff') as sid \gset
select test.mk_staff('admin@example.com', 'admin') as aid \gset
select test.login(:'sid');
select ok((select count(*) from booking.resources) > 0, 'staff lukee resurssit');
select is((select count(*)::int from booking.staff), 1, 'staff näkee vain oman rivinsä');
select is((select count(*)::int from booking.audit_log), 0, 'staff ei näe audit-lokia');
select throws_ok($$update booking.resources set capacity = 99$$, '42501', null, 'staff ei päivitä resursseja suoraan');
select throws_ok($$insert into booking.reservations(order_id, space_id, mode, starts_at, ends_at, persons, status) values (1,1,'shared', now(), now() + interval '1 h', 1, 'confirmed')$$, '42501', null, 'staff ei lisää varauksia suoraan');
select throws_ok($$select booking.admin_update_product(1, '{"price": 1}')$$, 'BK001', 'Ei oikeutta tähän toimintoon (catalog.edit)', 'staff ei muokkaa hintoja');
select throws_ok($$select booking.admin_set_setting('hold_minutes', '20')$$, 'BK001', 'Ei oikeutta tähän toimintoon (settings.edit)', 'staff ei muuta asetuksia');
select throws_ok($$select booking.admin_upsert_staff(gen_random_uuid(), 'x', 'admin')$$, 'BK001', 'Ei oikeutta tähän toimintoon (staff.manage)', 'staff ei hallinnoi henkilöstöä');
select lives_ok($$select * from booking.admin_list_reservations()$$, 'staff voi listata varaukset');
select test.logout();

select test.login(:'aid');
select is((select count(*)::int from booking.staff), 2, 'admin näkee koko henkilöstön');
select lives_ok($$select * from booking.audit_log limit 1$$, 'admin lukee audit-lokin');
select test.logout();

-- epäaktiivinen staff menettää oikeudet
update booking.staff set active = false where user_id = :'sid';
select test.login(:'sid');
select is((select count(*)::int from booking.resources), 0, 'epäaktiivinen staff ei näe mitään');
select test.logout();

select * from finish();
rollback;
