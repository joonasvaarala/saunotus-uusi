-- Migraatio 10: RLS-politiikat käyttävät (select …) -muotoa (auth_rls_initplan) ja käyttäytyvät kuten ennen
begin;
set local search_path = extensions, public;
select no_plan();

select is((select count(*)::int from pg_policies where schemaname = 'booking'), 27, 'booking-skeemassa 27 politiikkaa (25 staff_read + staff_self_read + audit_admin_read; migraatio 11 lisäsi customer_kinds ja addons)');
select is((select count(*)::int from pg_policies where schemaname = 'booking' and (qual is null or qual !~* '\(\s*select\s')), 0, 'jokaisen politiikan lauseke sisältää (select …) -InitPlanin');
select is((select count(*)::int from pg_policies where schemaname = 'booking' and qual ~* 'auth\.uid\(\)' and qual !~* '\(\s*select\s+auth\.uid\(\)'), 0, 'auth.uid() on aina (select auth.uid()) -muodossa');
select ok((select qual ~* 'select\s+auth\.uid\(\)' from pg_policies where schemaname = 'booking' and tablename = 'staff' and policyname = 'staff_self_read'), 'staff_self_read: auth.uid() kääritty selectiin');
select is((select count(*)::int from pg_policies where schemaname = 'booking' and tablename = 'staff'), 1, 'booking.staff: vain yksi politiikka (ei kaksoiskappaleita)');
select is((select cmd || ':' || array_to_string(roles, ',') from pg_policies where schemaname = 'booking' and tablename = 'staff'), 'SELECT:authenticated', 'staff_self_read: edelleen vain SELECT / authenticated');

-- käyttäytyminen: staff näkee vain oman rivinsä, admin kaikki, manager vain omansa; anon ei mitään
select test.mk_staff('p-admin@example.com', 'admin') as a1, test.mk_staff('p-manager@example.com', 'manager') as m1, test.mk_staff('p-staff@example.com', 'staff') as s1 \gset
select test.login(:'s1');
select is((select count(*)::int from booking.staff), 1, 'staff näkee vain oman rivinsä');
select is((select user_id from booking.staff), :'s1'::uuid, 'staff: rivi on oma');
select ok((select count(*) from booking.settings) > 0, 'staff lukee asetukset (staff_read)');
select is((select count(*)::int from booking.audit_log), 0, 'staff ei lue audit-lokia');
select test.logout();
select test.login(:'m1');
select is((select count(*)::int from booking.staff), 1, 'manager näkee vain oman rivinsä (ei staff.manage)');
select test.logout();
select test.login(:'a1');
select is((select count(*)::int from booking.staff), 3, 'admin näkee kaikki henkilöstörivit');
select ok((select count(*) from booking.audit_log) > 0, 'admin lukee audit-lokin');
select test.logout();
select test.anon();
select throws_ok($$select count(*) from booking.staff$$, '42501', null, 'anon ei voi lukea staff-taulua');
select test.logout();
-- ei-henkilöstö (pelkkä Auth-tili) ei näe mitään
select test.mk_user('p-outsider@example.com') as o1 \gset
select test.login(:'o1');
select is((select count(*)::int from booking.settings), 0, 'ei-henkilöstö ei lue asetuksia');
select is((select count(*)::int from booking.staff), 0, 'ei-henkilöstö ei näe henkilöstörivejä');
select test.logout();

select * from finish();
rollback;
