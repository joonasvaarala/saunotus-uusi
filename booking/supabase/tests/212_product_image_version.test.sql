-- booking_212: public_product_images palauttaa updated_at, sama rivijoukko kuin ennen.
begin;
set local search_path = extensions, public;
select no_plan();

select test.mk_staff('i212-manager@example.com', 'manager') as mgr \gset
select pc.product_id as pid from booking.product_config pc join kb.products p on p.id = pc.product_id
 where pc.bookable and pc.shop_visible and p.active order by pc.product_id limit 1 \gset
select 'products/' || :pid || '-v212aa.webp' as path1 \gset

select test.login(:'mgr');
select is((booking.admin_set_product_image(:pid, :'path1', 'Versio') ->> 'ok')::boolean, true, 'kuva asetettu');
select test.logout();

select test.anon();
select ok((select (x) ? 'updated_at' from jsonb_array_elements(booking.public_product_images()) x where (x ->> 'product_id')::bigint = :pid), 'public_product_images: updated_at mukana');
select is(
  (select (x ->> 'updated_at')::timestamptz from jsonb_array_elements(booking.public_product_images()) x where (x ->> 'product_id')::bigint = :pid),
  (select updated_at from booking.product_config where product_id = :pid),
  'updated_at on product_config.updated_at');
select is(
  (select x ->> 'path' from jsonb_array_elements(booking.public_product_images()) x where (x ->> 'product_id')::bigint = :pid),
  :'path1', 'polku ennallaan');
select ok((select not ((x) ? 'image_path') and not ((x) ? 'notes') from jsonb_array_elements(booking.public_product_images()) x where (x ->> 'product_id')::bigint = :pid), 'ei sisäisiä kenttiä');
select test.logout();

select * from finish();
rollback;
