-- Johku-merkintä (migraatio 12): admin_list_reservations(+p_source, +source/external_id), admin_day_view(source/external_id), external_meta-sarakkeet.
-- Migraatio 12 on ajettu tuotantoon (Bottiavustus 16.10.2026). booking_72 lisää 9. argumentin p_option_missing
-- ja poistaa 8-argumenttisen ylikuorman. Jos 9-argumenttista funktiota ei ole, testi ohitetaan.
begin;
set local search_path = extensions, public;
select no_plan();

select to_regprocedure('booking.admin_list_reservations(timestamptz,timestamptz,text,text,bigint,integer,integer,text,boolean,text,bigint)') is not null as has12 \gset
\if :has12

select test.next_dow(4) as thu, test.rule('Yleinen vuoro to 17–19') as r_thu \gset
select test.mk_staff('johku-stf@example.com', 'staff') as sid \gset

-- kaksi uutta varausta; toinen merkitään Johku-tuoduksi (kuten tuonti tekee: orders + reservations -pari)
select test.anon('10.12.0.1');
select (test.pub_book(:r_thu, :'thu', 2, 'uusi-12@example.com', 'Uusi Asiakas') ->> 'ok')::boolean as ok1 \gset
select (test.pub_book(:r_thu, :'thu', 3, 'johku-12@example.com', 'Johku Asiakas') ->> 'ok')::boolean as ok2 \gset
select test.logout();
select ok(:'ok1'::boolean and :'ok2'::boolean, 'testivaraukset luotu');
select r.id as rj, r.order_id as oj from booking.reservations r join booking.orders o on o.id = r.order_id join booking.customers c on c.id = o.customer_id where c.email = 'johku-12@example.com' \gset
update booking.orders set external_source = 'johku', external_id = 'T-ORD-77', external_meta = '{"payment":{"method":"verkkomaksu","paid":true}}' where id = :oj;
update booking.reservations set external_source = 'johku', external_id = 'T-RES-77', external_meta = '{"johku_status":"paid"}' where id = :rj;

-- rakenne
select is((select pronargs::int from pg_proc where oid = 'booking.admin_list_reservations(timestamptz,timestamptz,text,text,bigint,integer,integer,text,boolean,text,bigint)'::regprocedure), 11, 'admin_list_reservations: 11 parametria (booking_138 lisäsi p_sort ja p_reservation_id)');
select is((select (proargnames)[8] from pg_proc where oid = 'booking.admin_list_reservations(timestamptz,timestamptz,text,text,bigint,integer,integer,text,boolean,text,bigint)'::regprocedure), 'p_source', 'kahdeksas parametri on p_source');
select is((select (proargnames)[9] from pg_proc where oid = 'booking.admin_list_reservations(timestamptz,timestamptz,text,text,bigint,integer,integer,text,boolean,text,bigint)'::regprocedure), 'p_option_missing', 'yhdeksäs parametri on p_option_missing');
select ok((select pg_get_function_result(oid) like '%, total_count bigint, source text, external_id text%' from pg_proc where oid = 'booking.admin_list_reservations(timestamptz,timestamptz,text,text,bigint,integer,integer,text,boolean,text,bigint)'::regprocedure), 'uudet sarakkeet source, external_id ovat vanhojen perässä (migraatio 17c lisää niiden jälkeen lifecycle, space_code, legs, parent_reservation_id)');
select is((select count(*)::int from pg_proc where pronamespace = 'booking'::regnamespace and proname = 'admin_list_reservations'), 1, 'vanha 7- ja 8-parametrinen versio on poistettu (ei monitulkintaisia kutsuja)');
select is((select data_type from information_schema.columns where table_schema = 'booking' and table_name = 'orders' and column_name = 'external_meta'), 'jsonb', 'orders.external_meta jsonb');
select is((select data_type from information_schema.columns where table_schema = 'booking' and table_name = 'reservations' and column_name = 'external_meta'), 'jsonb', 'reservations.external_meta jsonb');
select ok(has_function_privilege('authenticated', 'booking.admin_list_reservations(timestamptz,timestamptz,text,text,bigint,integer,integer,text,boolean,text,bigint)', 'execute'), 'authenticated voi kutsua (funktio tarkistaa staff-roolin)');
select ok(has_function_privilege('service_role', 'booking.admin_list_reservations(timestamptz,timestamptz,text,text,bigint,integer,integer,text,boolean,text,bigint)', 'execute'), 'service_role voi kutsua');
select ok(not has_function_privilege('anon', 'booking.admin_list_reservations(timestamptz,timestamptz,text,text,bigint,integer,integer,text,boolean,text,bigint)', 'execute'), 'anon ei voi kutsua');

-- anon ei pääse maksutietoihin (external_meta) eikä hallinnan RPC:hen
select test.anon('10.12.0.2');
select throws_ok($$select external_meta from booking.orders$$, '42501', null, 'anon ei lue orders.external_meta -saraketta');
select throws_ok($$select external_meta from booking.reservations$$, '42501', null, 'anon ei lue reservations.external_meta -saraketta');
select throws_ok($$select * from booking.admin_list_reservations(p_source => 'johku')$$, '42501', null, 'anon ei voi listata varauksia');
select test.logout();

-- ei-staff ei näe mitään
select test.login(test.mk_user('johku-ei-staff@example.com'));
select throws_ok($$select * from booking.admin_list_reservations(p_source => 'johku')$$, null, null, 'ei-staff-käyttäjä ei voi listata (p_source)');
select test.logout();

-- lista: source / external_id, suodatin
select test.login(:'sid');
select is((select source from booking.admin_list_reservations(p_search => 'johku-12@example.com')), 'johku', 'Johku-varaus: source = johku');
select is((select external_id from booking.admin_list_reservations(p_search => 'johku-12@example.com')), 'T-RES-77', 'Johku-varaus: external_id näkyy');
select is((select source from booking.admin_list_reservations(p_search => 'uusi-12@example.com')), 'native', 'uusi varaus: source = native');
select is((select external_id from booking.admin_list_reservations(p_search => 'uusi-12@example.com')), null, 'uusi varaus: external_id tyhjä');
select is((select count(*)::int from booking.admin_list_reservations(p_source => 'johku', p_limit => 500)), 1, 'p_source = johku: vain Johku-varaukset');
select is((select count(*)::int from booking.admin_list_reservations(p_source => 'johku', p_search => 'uusi-12@example.com')), 0, 'p_source = johku ei palauta uutta varausta');
select ok((select count(*)::int from booking.admin_list_reservations(p_source => 'native', p_limit => 500)) >= 1
          and (select bool_and(source = 'native') from booking.admin_list_reservations(p_source => 'native', p_limit => 500)), 'p_source = native: vain uudet varaukset');
select is((select count(*)::int from booking.admin_list_reservations(p_source => 'native', p_search => 'johku-12@example.com')), 0, 'p_source = native ei palauta Johku-varausta');
select is((select count(*)::int from booking.admin_list_reservations(p_source => null, p_limit => 500)),
          (select count(*)::int from booking.admin_list_reservations(p_source => 'johku', p_limit => 500)) + (select count(*)::int from booking.admin_list_reservations(p_source => 'native', p_limit => 500)), 'p_source = null: kaikki (= Johku + uudet)');
select is((select total_count from booking.admin_list_reservations(p_source => 'johku', p_limit => 1)), 1::bigint, 'total_count noudattaa lähdesuodatinta');
select is((select count(*)::int from booking.admin_list_reservations(p_source => 'olematon', p_limit => 500)), 0, 'tuntematon lähde: ei rivejä');
-- vanhat kutsut (nimetyt argumentit, ilman p_source) toimivat
select ok((select count(*) from booking.admin_list_reservations(p_search => 'johku-12@example.com', p_status => 'active', p_limit => 10, p_offset => 0)) = 1, 'vanha kutsutapa (ilman p_source) toimii');
select lives_ok($$select reservation_id, order_id, order_no, status, order_status, payment_status, product_id, product_name, mode, starts_at, ends_at, persons, total_gross, customer_id, customer_name, customer_email, customer_phone, source_channel, created_at, hold_expires_at, notes, annual_card_id, total_count from booking.admin_list_reservations()$$, 'vanhat sarakkeet säilyvät');

-- päivänäkymä: source + external_id jokaisessa varauksessa
select is((select r ->> 'source' from jsonb_array_elements(booking.admin_day_view(:'thu') -> 'reservations') r where (r ->> 'reservation_id')::bigint = :rj), 'johku', 'admin_day_view: Johku-varaus source = johku');
select is((select r ->> 'external_id' from jsonb_array_elements(booking.admin_day_view(:'thu') -> 'reservations') r where (r ->> 'reservation_id')::bigint = :rj), 'T-RES-77', 'admin_day_view: external_id');
select ok((select bool_and(r ? 'source' and r ? 'external_id') from jsonb_array_elements(booking.admin_day_view(:'thu') -> 'reservations') r), 'admin_day_view: kaikilla varauksilla on avaimet source ja external_id');
select is((select count(*)::int from jsonb_array_elements(booking.admin_day_view(:'thu') -> 'reservations') r where r ->> 'source' = 'native'), 1, 'admin_day_view: uusi varaus source = native');
-- external_meta ei vuoda hallinnan listaan eikä päivänäkymään
select ok(not (to_jsonb((select l from booking.admin_list_reservations(p_search => 'johku-12@example.com') l)) ? 'external_meta'), 'lista ei palauta external_meta-kenttää');
select ok(position('verkkomaksu' in booking.admin_day_view(:'thu')::text) = 0, 'päivänäkymä ei palauta external_meta-sisältöä');
select test.logout();

\else
select skip('admin_list_reservations (9 argumenttia, p_source + p_option_missing) puuttuu testikannasta: Johku-merkintätestit ohitetaan', 1);
\endif

select * from finish();
rollback;
