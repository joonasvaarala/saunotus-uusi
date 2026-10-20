-- Roolit ja oikeudet: admin / manager / staff (henkilöstö) + customer / annual_card (ei-henkilöstö), taulupohjainen laajennettavuus
begin;
set local search_path = extensions, public;
select no_plan();

-- ---------- roolitaulu ----------
select is((select array_agg(code order by sort_order) from booking.roles), array['admin','manager','staff','text_editor','text_editor_approver','customer','annual_card'], 'roolit: henkilöstö, tekstibotit, asiakas, vuosikortti');
select is((select array_agg(code order by sort_order) from booking.roles where is_staff), array['admin','manager','staff'], 'henkilöstörooleja kolme (admin, manager, staff)');
select is((select count(*)::int from booking.role_permissions where role_code in ('customer','annual_card')), 0, 'asiakasrooleilla ei ole hallinnan oikeuksia');
select is((select count(*)::int from booking.role_permissions where role_code = 'admin'), 25, 'admin: 25 oikeutta (pos.use; quotes.manage poistettu booking_101:ssä)');
select is((select array_agg(permission order by permission) from booking.role_permissions where role_code = 'manager'),
          array['annual_cards.manage','articles.manage','blocks.manage','bookings.manage','bookings.override','catalog.edit','customers.manage','giftcards.admin','giftcards.manage','payments.manage','payments.refund','pos.use','reports.daily','reports.view','resources.edit','rules.edit','settings.edit','shifts.view_all','texts.approve','texts.approve_protected','texts.propose'],
          'manager: katalogi, asetukset, raportit, lahjakortit, tekstit, pikakassa (ei quotes.manage, ei staff.manage eikä audit-lokia)');
select is((select array_agg(permission order by permission) from booking.role_permissions where role_code = 'staff'),
          array['blocks.manage','bookings.manage','customers.manage','giftcards.manage','payments.manage','pos.use','reports.daily','shifts.view'], 'staff: varaukset, asiakkaat, maksut, sulut, lahjakortin käyttö, päiväraportti, pikakassa + omat vuorot');

-- ei-henkilöstöroolia ei voi antaa henkilöstörivin rooliksi (FK roles(code, is_staff))
select test.mk_user('role-x@example.com') as ux \gset
select throws_ok(format($$insert into booking.staff(user_id, email, name, role) values (%L, 'x', 'x', 'annual_card')$$, :'ux'), '23503', null, 'annual_card ei kelpaa henkilöstön rooliksi');
select throws_ok(format($$insert into booking.staff(user_id, email, name, role) values (%L, 'x', 'x', 'customer')$$, :'ux'), '23503', null, 'customer ei kelpaa henkilöstön rooliksi');
select throws_ok(format($$insert into booking.staff(user_id, email, name, role) values (%L, 'x', 'x', 'olematon')$$, :'ux'), '23503', null, 'tuntematon rooli ei kelpaa');
-- asiakkaan tyyppi: vain ei-henkilöstöroolit
insert into booking.customers(name, email) values ('Tyyppi Testi', 'tyyppi@example.com');
select is((select customer_type from booking.customers where email = 'tyyppi@example.com'), 'customer', 'asiakkaan oletustyyppi customer');
select throws_ok($$update booking.customers set customer_type = 'admin' where email = 'tyyppi@example.com'$$, '23503', null, 'asiakkaan tyypiksi ei voi asettaa henkilöstörooli');
select lives_ok($$update booking.customers set customer_type = 'annual_card' where email = 'tyyppi@example.com'$$, 'asiakkaan tyypiksi voi asettaa annual_card');
select ok((select auth_user_id is null from booking.customers where email = 'tyyppi@example.com'), 'customers.auth_user_id valmiina (tyhjä)');

-- ---------- käyttäjät ----------
select test.mk_staff('r-admin@example.com', 'admin') as aid, test.mk_staff('r-admin2@example.com', 'admin') as aid2,
       test.mk_staff('r-manager@example.com', 'manager') as mid, test.mk_staff('r-staff@example.com', 'staff') as sid \gset
select test.next_dow(2, 6) as tue \gset
select test.rule('Naisten sauna%') as r_tue, test.rule('Yleinen vuoro la–su 14:00%') as r_sat1400 \gset
select p.id as pid, p.price as old_price from booking.schedule_rules r join kb.products p on p.id = r.product_id where r.id = :r_tue \gset
select v.id as vid from kb.product_price_variants v join booking.schedule_rules r on r.price_variant_id = v.id where r.id = test.rule('Oma savusaunavuoro ma–pe 16–19%') limit 1 \gset
select test.login(:'aid');
select booking.admin_create_booking(:r_tue, :'tue', 2, null, '{"name": "Rooli Asiakas", "email": "rooli@example.com", "phone": "0407654321"}', 'pay_later', false) ->> 'order_id' as oid \gset
select booking.admin_create_booking(:r_tue, (:'tue'::date + 7), 2, null, '{"name": "Rooli Asiakas", "email": "rooli@example.com", "phone": "0407654321"}', 'pay_later', false) ->> 'reservation_id' as rid_b \gset
select (select id from booking.reservations where order_id = :oid) as rid \gset
select test.logout();

-- omat oikeudet (käyttöliittymä)
select test.login(:'sid');
select is(booking.admin_my_permissions() ->> 'role', 'staff', 'staff: oma rooli');
select is(booking.admin_my_permissions() -> 'permissions', '["blocks.manage","bookings.manage","customers.manage","giftcards.manage","payments.manage","pos.use","reports.daily","shifts.view"]'::jsonb, 'staff: omat oikeudet');
select is((select booking.has_permission('catalog.edit')), false, 'staff: has_permission(catalog.edit) = false');
select test.logout();
select test.login(:'mid');
select is(booking.admin_my_permissions() -> 'permissions' ? 'catalog.edit', true, 'manager: omissa oikeuksissa catalog.edit');
select is(booking.admin_my_permissions() -> 'permissions' ? 'staff.manage', false, 'manager: ei staff.manage');
select test.logout();

-- ---------- STAFF (peruskäyttäjä): varaukset, asiakkaat, maksut, sulut – ei hinta-/tuote-/asetusmuokkausta ----------
select test.login(:'sid');
select throws_ok(format($$select booking.admin_update_product(%s, '{"price": 1}')$$, :pid), 'BK001', 'Ei oikeutta tähän toimintoon (catalog.edit)', 'staff: hinnan päivitys estetty');
select throws_ok(format($$select booking.admin_update_product(%s, '{"description": "x"}')$$, :pid), 'BK001', 'Ei oikeutta tähän toimintoon (catalog.edit)', 'staff: kuvauksen päivitys estetty');
select throws_ok(format($$select booking.admin_update_price_variant(%s, '{"price": 1}')$$, :vid), 'BK001', 'Ei oikeutta tähän toimintoon (catalog.edit)', 'staff: hintavariantin päivitys estetty');
select throws_ok(format($$select booking.admin_update_product_config(%s, '{"bookable": false}')$$, :pid), 'BK001', 'Ei oikeutta tähän toimintoon (catalog.edit)', 'staff: tuoteasetusten päivitys estetty');
select throws_ok($$select booking.admin_set_setting('hold_minutes', '20')$$, 'BK001', 'Ei oikeutta tähän toimintoon (settings.edit)', 'staff: asetusten muutos estetty');
select throws_ok($$select booking.admin_update_resource((select id from booking.resources where code = 'turve'), '{"capacity": 9}')$$, 'BK001', 'Ei oikeutta tähän toimintoon (resources.edit)', 'staff: resurssin (kapasiteetin) muutos estetty');
select throws_ok(format($$select booking.admin_update_schedule_rule(%s, '{"active": false}')$$, :r_tue), 'BK001', 'Ei oikeutta tähän toimintoon (rules.edit)', 'staff: vuorosäännön muutos estetty');
select throws_ok($$select * from booking.admin_list_staff()$$, 'BK001', 'Ei oikeutta tähän toimintoon (staff.manage)', 'staff: henkilöstölistaus estetty');
select throws_ok(format($$select booking.admin_upsert_staff(%L, 'x', 'staff')$$, :'ux'), 'BK001', 'Ei oikeutta tähän toimintoon (staff.manage)', 'staff: henkilöstön muokkaus estetty');
select throws_ok(format($$select booking.admin_grant_annual_card((select id from booking.customers where email = 'rooli@example.com'), current_date, current_date + 30)$$), 'BK001', 'Ei oikeutta tähän toimintoon (annual_cards.manage)', 'staff: vuosikortin myöntö estetty');
select is((select count(*)::int from booking.audit_log), 0, 'staff: ei näe audit-lokia');
select lives_ok($$select booking.admin_list_products()$$, 'staff: näkee tuotteet (vain luku)');
select lives_ok(format($$select booking.admin_update_customer((select id from booking.customers where email = 'rooli@example.com'), '{"notes": "staff-muistiinpano"}')$$), 'staff: muokkaa asiakasta');
select is((booking.admin_create_booking(:r_tue, (:'tue'::date + 14), 1, null, '{"name": "Staff Asiakas", "email": "staffasiakas@example.com", "phone": "0407654321"}') ->> 'order_id') is not null, true, 'staff: luo varauksen');
select is((booking.admin_record_payment(:oid, 'card_terminal', 5) ->> 'ok')::boolean, true, 'staff: kirjaa maksun');
select is((booking.admin_create_block((select id from booking.resources where code = 'savusauna'), now() + interval '300 days', now() + interval '300 days 1 hour', 'staff-sulku') ->> 'ok')::boolean, true, 'staff: luo sulun');
select is((booking.admin_change_booking(:rid, null, null, 3) ->> 'ok')::boolean, true, 'staff: muuttaa varausta (henkilömäärä)');
select is((booking.admin_set_reservation_status(:rid_b, 'cancelled', 'staff') ->> 'ok')::boolean, true, 'staff: peruu varauksen');
select throws_ok($$update booking.staff set role = 'admin'$$, '42501', null, 'staff: ei voi kirjoittaa staff-tauluun suoraan');
select throws_ok($$insert into booking.role_permissions(role_code, permission) values ('staff', 'catalog.edit')$$, '42501', null, 'staff: ei voi antaa itselleen oikeuksia (role_permissions)');
select test.logout();
select is((select price from kb.products where id = :pid), :old_price::numeric, 'staffin yritys ei muuttanut hintaa');

-- ---------- MANAGER (ylläpitäjä): hinnat, kuvaukset, tuoteasetukset, asetukset, resurssit, vuorosäännöt ----------
select test.login(:'mid');
select is((booking.admin_update_product(:pid, '{"price": 33, "description": "Manager kuvaus", "name_en": "Women''s sauna"}') ->> 'ok')::boolean, true, 'manager: päivittää hinnan ja kuvauksen');
select is((booking.admin_update_price_variant(:vid, '{"price": 555}') ->> 'ok')::boolean, true, 'manager: päivittää hintavariantin');
select is((booking.admin_update_product_config(:pid, '{"sort_order": 77}') ->> 'ok')::boolean, true, 'manager: päivittää tuoteasetukset');
select is((booking.admin_set_setting('hold_minutes', '25') ->> 'ok')::boolean, true, 'manager: muuttaa asetuksia');
select is((booking.admin_update_resource((select id from booking.resources where code = 'turve'), '{"capacity": 9}') ->> 'ok')::boolean, true, 'manager: muuttaa resurssin kapasiteettia');
select is((booking.admin_update_schedule_rule(:r_tue, '{"deadline_minutes": 5, "notes": "mgr"}') ->> 'ok')::boolean, true, 'manager: muokkaa vuorosääntöä');
select throws_ok(format($$select booking.admin_update_schedule_rule(%s, '{"weekdays": [1]}')$$, :r_tue), 'BK001', null, 'manager: vuorosäännön aikataulukenttiä ei voi muokata (unknown_field)');
select throws_ok(format($$select booking.admin_update_schedule_rule(%s, '{"min_persons": 5, "max_persons": 2}')$$, :r_tue), 'BK001', null, 'manager: min > max hylätään');
select is((booking.admin_grant_annual_card((select id from booking.customers where email = 'rooli@example.com'), current_date, current_date + 365) ->> 'ok')::boolean, true, 'manager: myöntää vuosikortin');
-- ei henkilöstön hallintaa, ei admin-oikeuden antamista
select throws_ok($$select * from booking.admin_list_staff()$$, 'BK001', 'Ei oikeutta tähän toimintoon (staff.manage)', 'manager: ei näe henkilöstölistaa');
select throws_ok(format($$select booking.admin_upsert_staff(%L, 'Manager Itse', 'admin')$$, :'mid'), 'BK001', 'Ei oikeutta tähän toimintoon (staff.manage)', 'manager: ei voi ylentää itseään adminiksi');
select throws_ok(format($$select booking.admin_upsert_staff(%L, 'Uusi', 'admin')$$, :'ux'), 'BK001', 'Ei oikeutta tähän toimintoon (staff.manage)', 'manager: ei voi antaa admin-oikeutta toiselle');
select throws_ok(format($$select booking.admin_upsert_staff(%L, 'Staff Alennus', 'staff', false)$$, :'sid'), 'BK001', 'Ei oikeutta tähän toimintoon (staff.manage)', 'manager: ei voi muokata staff-rooleja eikä poistaa käytöstä');
select throws_ok($$update booking.staff set role = 'admin'$$, '42501', null, 'manager: ei voi kirjoittaa staff-tauluun suoraan');
select throws_ok($$update booking.role_permissions set permission = 'staff.manage' where role_code = 'manager'$$, '42501', null, 'manager: ei voi muuttaa oikeuksiaan');
select is((select count(*)::int from booking.staff), 1, 'manager: näkee vain oman henkilöstörivinsä');
select is((select count(*)::int from booking.audit_log), 0, 'manager: ei näe audit-lokia');
select test.logout();
select is((select price from kb.products where id = :pid), 33::numeric, 'manager muutti hinnan (kb.products)');
select is((select price from kb.product_price_variants where id = :vid), 555::numeric, 'manager muutti hintavariantin (kb)');
select is((select value from booking.settings where key = 'hold_minutes'), '25'::jsonb, 'manager muutti asetuksen');
select is((select capacity from booking.resources where code = 'turve'), 9, 'manager muutti kapasiteetin');
select is((select actor from booking.audit_log where table_name = 'kb.products' and action = 'ADMIN_UPDATE' order by id desc limit 1), :'mid'::uuid, 'hinnanmuutos kirjattu audit-lokiin managerin tunnuksella');
select is((select count(*)::int from booking.staff where role = 'admin' and user_id = :'mid'), 0, 'manager ei ole admin');

-- ---------- ADMIN: kaikki, myös henkilöstön hallinta ----------
select test.login(:'aid');
select is((select count(*)::int from booking.staff), 4, 'admin: näkee koko henkilöstön');
select is((select count(*)::int from booking.admin_list_staff()), 4, 'admin: admin_list_staff');
select lives_ok($$select * from booking.audit_log limit 1$$, 'admin: lukee audit-lokin');
select is((booking.admin_upsert_staff(:'ux', 'Otto Manager', 'manager') ->> 'ok')::boolean, true, 'admin: lisää managerin');
select is((select role from booking.staff where user_id = :'ux'), 'manager', 'rooli manager tallentui');
select is((booking.admin_upsert_staff(:'ux', 'Otto Manager', 'staff') ->> 'ok')::boolean, true, 'admin: alentaa managerin staffiksi');
select throws_ok(format($$select booking.admin_upsert_staff(%L, 'x', 'annual_card')$$, :'ux'), 'BK001', 'Tuntematon henkilöstörooli (booking.roles, is_staff=true)', 'admin: annual_card ei ole henkilöstörooli');
select throws_ok(format($$select booking.admin_upsert_staff(%L, 'x', 'customer')$$, :'ux'), 'BK001', null, 'admin: customer ei ole henkilöstörooli');
select throws_ok(format($$select booking.admin_upsert_staff(%L, 'x', 'foo')$$, :'ux'), 'BK001', null, 'admin: tuntematon rooli hylätään');
select throws_ok(format($$select booking.admin_upsert_staff(gen_random_uuid(), 'x', 'staff')$$), 'BK001', null, 'admin: tuntematon Auth-käyttäjä hylätään');
select is((booking.admin_update_product(:pid, '{"price": 34}') ->> 'ok')::boolean, true, 'admin: päivittää hinnan');
select is((booking.admin_set_setting('hold_minutes', '15') ->> 'ok')::boolean, true, 'admin: muuttaa asetuksia');
-- viimeistä adminia ei voi alentaa
select is((booking.admin_upsert_staff(:'aid2', 'Admin 2', 'manager') ->> 'ok')::boolean, true, 'admin: voi alentaa toisen adminin kun toinen admin jää');
select throws_ok(format($$select booking.admin_upsert_staff(%L, 'Admin 1', 'manager')$$, :'aid'), 'BK001', 'Viimeistä ylläpitäjää (admin) ei voi alentaa tai poistaa käytöstä', 'viimeistä adminia ei voi alentaa');
select throws_ok(format($$select booking.admin_upsert_staff(%L, 'Admin 1', 'admin', false)$$, :'aid'), 'BK001', null, 'viimeistä adminia ei voi poistaa käytöstä');
select test.logout();
select throws_ok(format($$insert into booking.staff(user_id, email, name, role) values (%L, 'x', 'x', 'admin')$$, :'ux'), '23505', null, 'duplikaatti-staff-rivi hylätään (pk)');

-- ---------- ASIAKAS (customer / annual_card): ei oikeuksia hallintaan, vaikka Auth-tunnus olisi linkitetty asiakkaaseen ----------
select test.mk_user('asiakas-login@example.com') as cu \gset
update booking.customers set auth_user_id = :'cu', customer_type = 'annual_card' where email = 'rooli@example.com';
select test.login(:'cu');
select is(booking.current_staff_role(), null, 'asiakas: ei staff-roolia');
select is(booking.is_staff(), false, 'asiakas (annual_card): is_staff = false');
select is(booking.has_permission('bookings.manage'), false, 'asiakas: ei oikeuksia');
select is((select count(*)::int from booking.customers), 0, 'asiakas ei näe asiakasrekisteriä (RLS), ei edes omaa riviään (itsepalvelua ei ole vielä)');
select is((select count(*)::int from booking.reservations), 0, 'asiakas ei näe varauksia');
select is((select count(*)::int from booking.annual_cards), 0, 'asiakas ei näe vuosikortteja');
select throws_ok($$select booking.admin_list_customers()$$, 'BK001', 'Ei oikeuksia', 'asiakas: admin-funktiot estetty');
select throws_ok($$select booking.admin_my_permissions()$$, 'BK001', 'Ei oikeuksia', 'asiakas: admin_my_permissions estetty');
select throws_ok(format($$select booking.admin_create_annual_card_booking(1, %s, current_date)$$, :r_sat1400), 'BK001', 'Ei oikeuksia', 'asiakas: ei voi luoda vuosikorttivarausta hallinnan funktiolla');
select throws_ok($$update booking.customers set customer_type = 'annual_card'$$, '42501', null, 'asiakas: ei voi muokata asiakasriviä');
select throws_ok($$insert into booking.staff(user_id, name, role) values (auth.uid(), 'x', 'admin')$$, '42501', null, 'asiakas: ei voi lisätä itseään henkilöstöön');
select test.logout();

-- ---------- laajennettavuus: uusi rooli on vain data (ei enumia, ei funktiomuutosta) ----------
insert into booking.roles(code, label, is_staff, sort_order) values ('bookkeeper', 'Kirjanpitäjä', true, 40);
insert into booking.role_permissions(role_code, permission) values ('bookkeeper', 'payments.manage');
select test.mk_staff('r-bookkeeper@example.com', 'bookkeeper') as kid \gset
select test.login(:'kid');
select is((booking.admin_record_payment(:oid, 'card_terminal', 1) ->> 'ok')::boolean, true, 'uusi rooli (bookkeeper): sai vain payments.manage → maksun kirjaus onnistuu');
select throws_ok(format($$select booking.admin_create_booking(%s, %L, 1, null, '{"name": "Kirja Pitäjä", "email": "kp@example.com", "phone": "0407654321"}')$$, :r_tue, (:'tue'::date + 21)), 'BK001', 'Ei oikeutta tähän toimintoon (bookings.manage)', 'uusi rooli: varaus estetty (ei bookings.manage)');
select throws_ok(format($$select booking.admin_update_product(%s, '{"price": 2}')$$, :pid), 'BK001', 'Ei oikeutta tähän toimintoon (catalog.edit)', 'uusi rooli: hinnanmuutos estetty');
select test.logout();
-- rooli pois käytöstä → oikeudet katoavat
update booking.roles set active = false where code = 'manager';
select test.login(:'mid');
select is(booking.is_staff(), false, 'epäaktiivinen rooli: manager menettää henkilöstöaseman');
select throws_ok(format($$select booking.admin_update_product(%s, '{"price": 1}')$$, :pid), 'BK001', 'Ei oikeuksia', 'epäaktiivinen rooli: hallinnan funktiot estetty');
select test.logout();
update booking.roles set active = true where code = 'manager';

select * from finish();
rollback;
