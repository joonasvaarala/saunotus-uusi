-- Migraatio 19: tuotekuvat (product_config.image_path/image_alt, Storage-bucket product-images + policyt, public_product_images, admin_set_product_image)
begin;
set local search_path = extensions, public;
select no_plan();

select test.mk_staff('i-admin@example.com', 'admin') as adm, test.mk_staff('i-manager@example.com', 'manager') as mgr, test.mk_staff('i-staff@example.com', 'staff') as stf,
       test.mk_user('i-outsider@example.com') as outs \gset
select pc.product_id as pid from booking.product_config pc join kb.products p on p.id = pc.product_id where pc.bookable and pc.shop_visible and p.active order by pc.product_id limit 1 \gset
select pc.product_id as pid2 from booking.product_config pc where pc.product_id <> :pid order by pc.product_id limit 1 \gset
select 'products/' || :pid || '-abc123xy.webp' as path1, 'products/' || :pid || '-zzz999aa.png' as path2, 'products/' || :pid2 || '-abc123xy.webp' as other_path \gset

-- ================= A) rakenne =================
select has_column('booking', 'product_config', 'image_path', 'product_config.image_path on olemassa');
select has_column('booking', 'product_config', 'image_alt', 'product_config.image_alt on olemassa');
select is((select count(*)::int from booking.product_config where image_path is not null), 0, 'oletuksena kenelläkään ei ole kuvaa (null = ei kuvaa)');
select throws_ok($$update booking.product_config set image_path = '../x.png' where product_id = (select min(product_id) from booking.product_config)$$, '23514', null, 'rajoite: väärän muotoinen kuvapolku hylätään');
select throws_ok($$update booking.product_config set image_path = 'products/1-abcdef.gif' where product_id = (select min(product_id) from booking.product_config)$$, '23514', null, 'rajoite: gif ei kelpaa');
select throws_ok($$update booking.product_config set image_alt = '' where product_id = (select min(product_id) from booking.product_config)$$, '23514', null, 'rajoite: tyhjä alt-teksti hylätään (null = tuotteen nimi)');

-- ================= B) Storage-bucket ja policyt =================
select is((select public from storage.buckets where id = 'product-images'), true, 'bucket product-images on julkinen');
select is((select file_size_limit from storage.buckets where id = 'product-images'), 2097152::bigint, 'bucket: max 2 MB');
select is((select allowed_mime_types from storage.buckets where id = 'product-images'), array['image/jpeg','image/png','image/webp'], 'bucket: vain jpeg/png/webp');
select is((select count(*)::int from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'product_images_%'), 4, 'storage.objects: 4 product_images_* -politiikkaa');
select is((select count(*)::int from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'product_images_%' and cmd <> 'SELECT' and qual !~ 'has_permission' and with_check !~ 'has_permission'), 0, 'kirjoituspolitiikat vaativat oikeuden catalog.edit (has_permission)');
select is((select count(*)::int from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'product_images_%' and cmd <> 'SELECT' and (coalesce(qual,'') || coalesce(with_check,'')) !~* '\(\s*select\s+booking\.has_permission'), 0, 'storage-politiikat käyttävät (select …) -InitPlania');

select test.anon();
select is((select count(*)::int from storage.objects where bucket_id = 'product-images'), 0, 'anon voi lukea bucketin (tyhjä)');
select throws_ok($$insert into storage.objects(bucket_id, name) values ('product-images', 'products/1-abcdef.png')$$, '42501', null, 'anon ei voi ladata kuvia');
select test.logout();
select test.login(:'stf');
select throws_ok($$insert into storage.objects(bucket_id, name) values ('product-images', 'products/1-abcdef.png')$$, '42501', null, 'staff (ei catalog.edit) ei voi ladata kuvia');
select test.logout();
select test.login(:'outs');
select throws_ok($$insert into storage.objects(bucket_id, name) values ('product-images', 'products/1-abcdef.png')$$, '42501', null, 'kirjautunut ei-henkilöstö ei voi ladata kuvia');
select test.logout();
select test.login(:'mgr');
select lives_ok($$insert into storage.objects(bucket_id, name) values ('product-images', 'products/1-abcdef.png')$$, 'manager (catalog.edit) voi ladata kuvan oikeaan polkuun');
select throws_ok($$insert into storage.objects(bucket_id, name) values ('product-images', 'muu/kuva.png')$$, '42501', null, 'manager ei voi ladata kuvaa väärään polkuun');
select throws_ok($$insert into storage.objects(bucket_id, name) values ('muu-bucket', 'products/1-abcdef.png')$$, null, null, 'muuhun bucketiin ei kirjoiteta politiikalla');
select lives_ok($$delete from storage.objects where bucket_id = 'product-images' and name = 'products/1-abcdef.png'$$, 'manager voi poistaa kuvan');
select test.logout();

-- ================= C) admin_set_product_image =================
select test.anon();
select throws_ok(format('select booking.admin_set_product_image(%s, %L)', :pid, :'path1'), '42501', null, 'anon ei voi kutsua admin_set_product_image');
select test.logout();
select test.login(:'outs');
select is(test.code(format('select booking.admin_set_product_image(%s, %L)', :pid, :'path1')), 'forbidden', 'kirjautunut ei-henkilöstö: forbidden');
select test.logout();
select test.login(:'stf');
select is(test.code(format('select booking.admin_set_product_image(%s, %L)', :pid, :'path1')), 'forbidden', 'staff ilman catalog.edit -oikeutta: forbidden');
select test.logout();

select test.login(:'mgr');
select is((booking.admin_set_product_image(:pid, :'path1', '  Saunan lauteet  ') ->> 'ok')::boolean, true, 'manager asettaa kuvan');
select is((select image_path from booking.product_config where product_id = :pid), :'path1', 'kuvapolku tallentui');
select is((select image_alt from booking.product_config where product_id = :pid), 'Saunan lauteet', 'alt-teksti tallentui trimmattuna');
select is((booking.admin_set_product_image(:pid, :'path2') ->> 'previous_path'), :'path1', 'vastaus kertoo edellisen polun (vanha kuva voidaan poistaa Storagesta)');
select is((select image_alt from booking.product_config where product_id = :pid), null, 'alt tyhjenee kun sitä ei anneta');
select is(test.code(format('select booking.admin_set_product_image(%s, %L)', :pid, 'products/' || :pid || '-abcdef.gif')), 'invalid_image', 'väärä tiedostopääte hylätään');
select is(test.code(format('select booking.admin_set_product_image(%s, %L)', :pid, 'products/../etc/passwd.png')), 'invalid_image', 'polkuhyökkäys hylätään');
select is(test.code(format('select booking.admin_set_product_image(%s, %L)', :pid, 'https://example.com/x.png')), 'invalid_image', 'ulkoinen URL hylätään');
select is(test.code(format('select booking.admin_set_product_image(%s, %L)', :pid, :'other_path')), 'invalid_image', 'toisen tuotteen kuvapolku hylätään');
select is(test.code(format('select booking.admin_set_product_image(%s, %L, %L)', :pid, :'path1', repeat('a', 201))), 'invalid_alt', 'liian pitkä alt hylätään');
select is(test.code(format('select booking.admin_set_product_image(%s, %L)', 99999999, :'path1')), 'not_found', 'tuntematon tuote: not_found');
select is(test.code(format('select booking.admin_set_product_image(%s, %L)', :pid, 'products/' || :pid || '-abc123xy.webp')), 'ok', 'kelvollinen polku menee läpi (ei virhekoodia)');
select test.logout();
select is((select count(*)::int from booking.audit_log where action = 'ADMIN_SET_IMAGE' and row_pk = :pid::text), 3, 'jokainen kuvamuutos kirjautuu audit-lokiin (3 onnistunutta)');
select is((select new_data ->> 'image_path' from booking.audit_log where action = 'ADMIN_SET_IMAGE' and row_pk = :pid::text order by id desc limit 1), :'path1', 'audit: uusi polku tallennettu');

-- ================= D) julkinen luku =================
select test.anon();
select is((select jsonb_array_length(booking.public_product_images())), 1, 'public_product_images palauttaa asetetun kuvan');
select is((booking.public_product_images() -> 0 ->> 'product_id')::bigint, :pid::bigint, 'public_product_images: product_id');
select is((booking.public_product_images() -> 0 ->> 'path'), :'path1', 'public_product_images: polku');
select ok((booking.public_product_images() -> 0 ->> 'slug') is not null, 'public_product_images: slug mukana');
select ok(not (booking.public_product_images() -> 0 ? 'image_path') and not (booking.public_product_images() -> 0 ? 'notes'), 'public_product_images: ei sisäisiä kenttiä');
select test.logout();
select test.login(:'mgr');
select is((booking.admin_set_product_image(:pid, null) ->> 'ok')::boolean, true, 'null poistaa kuvan');
select is((select image_path from booking.product_config where product_id = :pid), null, 'kuvapolku tyhjennetty');
select test.logout();
select test.anon();
select is((select jsonb_array_length(booking.public_product_images())), 0, 'ilman kuvaa tuote ei näy public_product_images-listassa');
select test.logout();
-- kuva piilotetulle / ei-varattavalle tuotteelle ei vuoda
select test.service();
update booking.product_config set image_path = :'path1', shop_visible = false where product_id = :pid;
select test.logout();
select test.anon();
select is((select jsonb_array_length(booking.public_product_images())), 0, 'kaupassa piilotetun tuotteen kuvaa ei palauteta julkisesti');
select test.logout();
select test.login(:'mgr');
select ok((select (p ->> 'id')::bigint = :pid::bigint and p -> 'config' ->> 'image_path' = :'path1' from jsonb_array_elements(booking.admin_list_products()) p where (p ->> 'id')::bigint = :pid::bigint), 'admin_list_products palauttaa kuvan polun (config.image_path)');
select test.logout();

-- ================= E) oikeudet funktioihin =================
select is((select count(*)::int from information_schema.routine_privileges where routine_schema = 'booking' and routine_name = 'admin_set_product_image' and grantee in ('anon', 'PUBLIC')), 0, 'admin_set_product_image: ei anon/PUBLIC-oikeutta');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'booking' and p.proname in ('public_product_images', 'admin_set_product_image') and p.prosecdef and p.proconfig @> array['search_path=""']), 2, 'uudet funktiot: SECURITY DEFINER + search_path=""');

select * from finish();
rollback;
