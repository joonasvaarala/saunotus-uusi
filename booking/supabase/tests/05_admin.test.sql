-- Hallinta: roolit, kb-tuotemuokkaus, manuaalinen varaus, maksut, auditointi, asiakashaku
begin;
set local search_path = extensions, public;
select no_plan();

select test.next_dow(2) as tue, test.next_dow(4) as thu,
       test.rule('Naisten sauna%') as r_tue, test.rule('Oma savusaunavuoro ma–pe 16–19%') as r_priv, test.rule('Yleinen vuoro to 17–19') as r_thu \gset
select test.mk_staff('adm@example.com', 'admin') as aid, test.mk_staff('stf@example.com', 'staff') as sid \gset
select p.id as pid, p.price as old_price, p.name as old_name from booking.schedule_rules r join kb.products p on p.id = r.product_id where r.id = :r_tue \gset

-- admin muokkaa tuotteen nimeä, kuvausta ja hintaa -> kb päivittyy, audit + kb.change_log
select test.login(:'aid');
select is((booking.admin_update_product(:pid, '{"name": "Naisten sauna (testi)", "description": "Uusi kuvaus", "price": 31.5}') ->> 'ok')::boolean, true, 'admin päivittää tuotteen');
select throws_ok(format($$select booking.admin_update_product(%s, '{"id": 5}')$$, :pid), 'BK001', null, 'kiellettyä kenttää (id) ei voi muokata');
select throws_ok(format($$select booking.admin_update_product(%s, '{"price": -1}')$$, :pid), 'BK001', null, 'negatiivinen hinta hylätään');
select throws_ok(format($$select booking.admin_update_product(%s, '{"vat_rate": 17}')$$, :pid), 'BK001', null, 'ei-sallittu ALV-kanta hylätään');
select throws_ok(format($$select booking.admin_update_product(%s, '{"name": "  "}')$$, :pid), 'BK001', null, 'tyhjä nimi hylätään');
select is((booking.admin_update_product(:pid, '{"vat_rate": 25.5}') ->> 'ok')::boolean, true, 'ALV 25,5 sallittu');
select test.logout();
select is((select name from kb.products where id = :pid), 'Naisten sauna (testi)', 'kb.products.name päivittyi');
select is((select price from kb.products where id = :pid), 31.5, 'kb.products.price päivittyi');
select is((select count(*)::int from kb.change_log where table_name = 'products' and row_id = :pid and actor like 'booking-admin:%'), 2, 'kb.change_log kirjattu (2 muutosta)');
select is((select count(*)::int from booking.audit_log where table_name = 'kb.products' and row_pk = :pid::text and action = 'ADMIN_UPDATE'), 2, 'booking.audit_log kirjattu');
select is((select old_data ->> 'name' from booking.audit_log where table_name = 'kb.products' and row_pk = :pid::text order by id limit 1), :'old_name', 'audit sisältää vanhan arvon');

-- uusi hinta näkyy julkisessa katalogissa ja uusissa varauksissa
select test.anon('10.1.1.1');
select is((select (e ->> 'price')::numeric from jsonb_array_elements(booking.public_catalog()) e where (e ->> 'id')::bigint = :pid), 31.5, 'katalogi näyttää uuden hinnan');
select is((booking.public_create_booking(:r_tue, :'tue', 2, 'Hinta Testi', 'hinta@example.com', '0401234567') ->> 'total')::numeric, 63.0, 'uusi varaus käyttää uutta hintaa (2 x 31,5)');
select test.logout();

-- hintavariantti
select v.id as vid from kb.product_price_variants v join booking.schedule_rules r on r.price_variant_id = v.id where r.id = :r_priv limit 1 \gset
select test.login(:'sid');
select throws_ok(format($$select booking.admin_update_price_variant(%s, '{"price": 1}')$$, :vid), 'BK001', null, 'staff ei voi muokata hintavarianttia');
select test.logout();
select test.login(:'aid');
select is((booking.admin_update_price_variant(:vid, '{"price": 777}') ->> 'ok')::boolean, true, 'admin muokkaa hintavarianttia');
select throws_ok(format($$select booking.admin_update_price_variant(%s, '{"foo": 1}')$$, :vid), 'BK001', null, 'tuntematon kenttä hylätään');
select test.logout();
select is((select price from kb.product_price_variants where id = :vid), 777::numeric, 'variantin hinta päivittyi kb:hen');

-- manuaalinen varaus (staff): puhelinvaraus, maksettu käteisellä
select test.login(:'sid');
select booking.admin_create_booking(:r_thu, :'thu', 4, null, '{"name": "Puhelin Asiakas", "email": "puhelin@example.com", "phone": "0407654321"}', 'cash', true, 'puhelimitse') as ab \gset
select ok(:'ab'::jsonb ? 'order_id', 'staff luo manuaalisen varauksen');
select (:'ab'::jsonb ->> 'order_id')::bigint as oid \gset
select test.logout();
select is((select payment_status from booking.orders where id = :oid), 'paid', 'manuaalinen maksettu => payment_status paid');
select is((select source_channel from booking.orders where id = :oid), 'admin', 'lähdekanava admin');
select is((select count(*)::int from booking.payments where order_id = :oid and status = 'paid' and provider = 'manual'), 1, 'maksu kirjattu (provider manual)');
select is((select created_by from booking.orders where id = :oid), :'sid'::uuid, 'created_by = staff');
select ok((select count(*) from booking.audit_log where table_name = 'orders' and row_pk = :oid::text) >= 1, 'tilauksesta audit-rivi');

-- manuaalinen varaus kunnioittaa päällekkäisyyssääntöjä
select test.login(:'sid');
select throws_ok(format($$select booking.admin_create_booking(%s, %L, 4, null, '{"name": "P A", "email": "puhelin@example.com", "phone": "0407654321"}')$$, :r_priv, :'thu'), 'BK001', 'Ajalle on jo varauksia yleisille vuoroille – yksityisvuoroa ei voi varata', 'manuaalinenkaan yksityisvuoro ei mene yleisen vuoron päälle');
select throws_ok(format($$select booking.admin_create_booking(%s, %L, 13, null, '{"name": "P A", "email": "puhelin@example.com", "phone": "0407654321"}')$$, :r_thu, :'thu'), 'BK001', null, 'manuaalinen varaus ei ylitä kapasiteettia (4 + 13 > 16)');
select test.logout();

-- maksun kirjaus, osamaksu, maksulinkki-placeholder
select test.login(:'sid');
select booking.admin_create_booking(:r_tue, (:'tue'::date + 7), 2, null, '{"name": "Maksu Testi", "email": "maksu@example.com", "phone": "0407654321"}', 'pay_later', false) ->> 'order_id' as oid2 \gset
select is((select payment_status from booking.orders where id = :oid2), 'unpaid', 'pay_later => unpaid');
select is((booking.admin_record_payment(:oid2, 'cash', 10) ->> 'ok')::boolean, true, 'osamaksun kirjaus');
select is((select payment_status from booking.orders where id = :oid2), 'partially_paid', 'osamaksu => partially_paid');
select is((booking.admin_record_payment(:oid2, 'cash', (select total_gross - 10 from booking.orders where id = :oid2)) ->> 'ok')::boolean, true, 'loppumaksu');
select is((select payment_status from booking.orders where id = :oid2), 'paid', 'täysi maksu => paid');
select is((booking.admin_create_payment_link(:oid2) ->> 'implemented')::boolean, false, 'maksulinkki on placeholder (ei toteutettu)');
select is((select link_url from booking.payments where order_id = :oid2 and provider = 'visma_pay' limit 1), null, 'placeholder ei luo oikeaa linkkiä');
select test.logout();

-- varauksen tilasiirtymät ja peruutus
select test.login(:'sid');
select is((booking.admin_set_reservation_status((select id from booking.reservations where order_id = :oid2 limit 1), 'cancelled', 'asiakas pyysi') ->> 'ok')::boolean, true, 'staff peruu varauksen');
select test.logout();
select is((select cancel_reason from booking.reservations where order_id = :oid2 limit 1), 'asiakas pyysi', 'peruutussyy tallennettu');
select is((select status from booking.orders where id = :oid2), 'cancelled', 'kaikki varaukset peruttu => tilaus cancelled');

-- maksuadapteri (vain service_role): Visma Pay -rajapinnan runko, ei oikeaa maksua
update booking.settings set value = '"hold_until_paid"' where key = 'public_payment_mode';
select test.anon('10.3.3.3');
select booking.public_create_booking(:r_tue, (:'tue'::date + 21), 2, 'Adapteri Testi', 'adapteri@example.com', '0401234567') as ad \gset
select test.logout();
update booking.settings set value = '"pay_later"' where key = 'public_payment_mode';
select (select id from booking.orders where public_token = (:'ad'::jsonb ->> 'token')::uuid) as aoid \gset
select is((select status from booking.orders where id = :aoid), 'pending', 'maksua odottava tilaus on pending');
select test.service();
select (booking.payment_prepare(:aoid) ->> 'payment_id')::bigint as pay_id \gset
select is((select status from booking.payments where id = :pay_id), 'pending', 'payment_prepare luo maksurivin (pending)');
select lives_ok(format($$select booking.payment_attach_provider_ref(%s, 'VP-TEST-1', 'https://example.invalid/pay/1')$$, :pay_id), 'provider_ref liitettävissä');
select is((select booking.payment_mark_paid('visma_pay', 'VP-TEST-1', (select total_gross from booking.orders where id = :aoid)) ->> 'ok')::boolean, true, 'payment_mark_paid onnistuu');
select is((booking.payment_mark_paid('visma_pay', 'VP-TEST-1', 1) ->> 'already')::boolean, true, 'payment_mark_paid on idempotentti (callback voi tulla kahdesti)');
select test.logout();
select is((select status from booking.orders where id = :aoid), 'confirmed', 'maksettu tilaus vahvistettu');
select is((select payment_status from booking.orders where id = :aoid), 'paid', 'tilaus paid');
select is((select count(*)::int from booking.reservations where order_id = :aoid and status = 'confirmed' and hold_expires_at is null), 1, 'varaus vahvistettu, pito poistettu');
select test.service();
select (booking.payment_prepare(:aoid) ->> 'payment_id')::bigint as pay2 \gset
select lives_ok(format($$select booking.payment_mark_failed('visma_pay', 'EI-OLE', 'failed')$$), 'mark_failed tuntemattomalle refille ei kaada');
select test.logout();

-- asiakashaku ja asiakastiedot
select test.login(:'sid');
select is((select count(*)::int from booking.admin_list_customers('puhelin')), 1, 'asiakashaku sähköpostilla/nimellä');
select ok((select count(*)::int from booking.admin_list_customers('0407654321')) >= 1, 'asiakashaku puhelimella');
select is((select count(*)::int from booking.admin_list_customers('eioleolemassa')), 0, 'haku ei löydä olematonta');
select is((booking.admin_update_customer((select id from booking.customers where email = 'puhelin@example.com'), '{"notes": "VIP"}') ->> 'ok')::boolean, true, 'staff voi päivittää asiakkaan muistiinpanon');
select lives_ok($$select booking.admin_update_customer((select id from booking.customers where email = 'puhelin@example.com'), '{"marketing_consent": true}')$$, 'staff voi kirjata markkinointisuostumuksen');
select test.logout();
select ok((select count(*) from booking.audit_log where table_name = 'customers' and action = 'UPDATE') >= 1, 'asiakasmuutos auditoitu');
select is((select marketing_consent_source from booking.customers where email = 'puhelin@example.com'), 'admin', 'admin-kirjattu suostumus: lähde admin');

-- varausnäkymät
select test.login(:'sid');
select ok((select count(*) from booking.admin_list_reservations(p_search => 'puhelin')) >= 1, 'varauslistan haku');
select ok(jsonb_typeof(booking.admin_day_view(:'thu')) in ('array', 'object'), 'päivänäkymä palauttaa dataa');
select test.logout();

-- asetukset (vain admin) ja julkiset asetukset
select test.login(:'aid');
select is((booking.admin_set_setting('hold_minutes', '20') ->> 'ok')::boolean, true, 'admin muuttaa asetusta');
select test.logout();
select test.anon('10.2.2.2');
select is(booking.public_settings() ->> 'rl_ip_per_10min', null, 'julkiset asetukset eivät sisällä sisäisiä asetuksia (rate limit)');
select is(booking.public_settings() ->> 'hold_minutes', '20', 'julkiset asetukset sisältävät julkiset asetukset (hold_minutes)');
select test.logout();

select * from finish();
rollback;
