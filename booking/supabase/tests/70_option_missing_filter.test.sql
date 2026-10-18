-- booking_70: admin_list_reservations(p_option_missing) on vain luku -rajaus.
-- TRUE = option_missing (hoito pakollinen, product_option_id null). NULL ja FALSE eivät rajaa.
-- 8-argumenttinen ylikuorma on poissa. Valinnan jälkeen rivi katoaa suodattimesta.
begin;
set local search_path = extensions, public;
select no_plan();

select is(
  (select pg_get_function_identity_arguments(p.oid)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'booking' and p.proname = 'admin_list_reservations'),
  'p_from timestamp with time zone, p_to timestamp with time zone, p_search text, p_status text, p_product_id bigint, p_limit integer, p_offset integer, p_source text, p_option_missing boolean',
  'funktio on 9-argumenttinen, viimeinen p_option_missing');

select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'booking' and p.proname = 'admin_list_reservations'),
  1::bigint,
  '8-argumenttista ylikuormaa ei jää');

select ok(
  to_regprocedure('booking.admin_list_reservations(timestamptz,timestamptz,text,text,bigint,integer,integer,text)') is null,
  '8-argumenttinen allekirjoitus on poistettu');

select ok(
  not has_function_privilege('anon', 'booking.admin_list_reservations(timestamptz,timestamptz,text,text,bigint,integer,integer,text,boolean)', 'execute'),
  'anon ei saa kutsua listaa');

select ok(
  has_function_privilege('authenticated', 'booking.admin_list_reservations(timestamptz,timestamptz,text,text,bigint,integer,integer,text,boolean)', 'execute'),
  'authenticated saa kutsua listaa');

select ok(
  has_function_privilege('service_role', 'booking.admin_list_reservations(timestamptz,timestamptz,text,text,bigint,integer,integer,text,boolean)', 'execute'),
  'service_role saa kutsua listaa');

select test.logout();
select s.starts_at::text as slot
  from booking.public_treatment_availability(
         10,
         (timezone('Europe/Helsinki', now()))::date + 3,
         (timezone('Europe/Helsinki', now()))::date + 16,
         1) s
 where s.status = 'available'
 order by s.starts_at
 limit 1 \gset

select ok(coalesce(:'slot', '') <> '', 'testivapaa saunahoitoaika löytyi');

select test.mk_staff('t70-admin@saunotus.fi', 'admin') as sid \gset
select test.login(:'sid');

select coalesce(j ->> 'reservation_id', '') as rid, left(coalesce(j::text, ''), 240) as created_body
  from (select booking.admin_create_resource_booking(
                 p_product_id => 10,
                 p_start => nullif(:'slot', '')::timestamptz,
                 p_persons => 1,
                 p_customer => jsonb_build_object('name', 'Hoito Rajaus', 'email', 'hoito70@example.com', 'phone', '+358401112233'),
                 p_option_code => 'hunajahoito') j) s \gset

select ok(:'rid' ~ '^[0-9]+$', 'saunahoitovaraus luotiin hunajahoidolla: ' || :'created_body');

select is(
  (select count(*)::int from booking.admin_list_reservations(p_search => 'hoito70@example.com', p_option_missing => true)),
  0,
  'valittu hoito ei näy Hoito valitsematta -suodattimessa');

select test.logout();
update booking.reservations set product_option_id = null where id = :rid;
select test.login(:'sid');

select is(
  (select option_missing from booking.admin_list_reservations(p_search => 'hoito70@example.com', p_option_missing => true) where reservation_id = :rid),
  true,
  'valitsematta jäänyt saunahoito näkyy suodattimessa');

select is(
  (select count(*)::int from booking.admin_list_reservations(p_option_missing => true, p_limit => 500) where option_missing is not true),
  0,
  'suodatin ei palauta rivejä, joilla option_missing on false');

select is(
  (select total_count::int from booking.admin_list_reservations(p_search => 'hoito70@example.com', p_option_missing => true, p_limit => 1) limit 1),
  1,
  'total_count on suodatettu lukumäärä');

select is((booking.admin_set_reservation_option(:rid, 'vihtahoito') ->> 'ok')::boolean, true, 'hoidon valinta onnistuu');

select is(
  (select count(*)::int from booking.admin_list_reservations(p_search => 'hoito70@example.com', p_option_missing => true)),
  0,
  'hoidon valinta poistaa varauksen suodatetusta listasta');

select is(
  (select option_code from booking.admin_list_reservations(p_search => 'hoito70@example.com', p_option_missing => null) where reservation_id = :rid),
  'vihtahoito',
  'p_option_missing null ei rajaa');

select is(
  (select count(*)::int from booking.admin_list_reservations(null, null, 'hoito70@example.com', null, null, 50, 0, null) where reservation_id = :rid),
  1,
  'kahdeksan paikallista argumenttia toimii (yhdeksäs oletus null)');

select test.logout();
select * from finish();
rollback;
