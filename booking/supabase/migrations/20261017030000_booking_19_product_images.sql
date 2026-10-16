-- =====================================================================
-- booking 19: tuotekuvat (kuva tuotteen yhteyteen kaupassa ja hallinnassa)
-- UUSI migraatio (numero 19 + myöhäinen versio: tuotannossa on jo 12–17d, 18 on tulossa). EI korvaa olemassa olevia funktioita (admin_update_product,
-- public_catalog, admin_day_view, admin_list_reservations …), jotta aiemmat migraatiot eivät ylikirjoitu: kaikki on lisäyksiä
-- (add column, uudet funktiot public_product_images / admin_set_product_image, uusi bucket + politiikat).
--
--  1) booking.product_config.image_path / image_alt: kuvan polku Storage-bucketissa `product-images` (null = ei kuvaa) ja valinnainen alt-teksti
--     (null = näytetään tuotteen nimi). Kuva on varauskonfiguraation (booking.product_config) tieto, ei kb.products-taulun: kb on sivuston/botin
--     yhteistä totuutta eikä sen skeemaa muuteta tästä. admin_list_products palauttaa kentät jo ennestään (config = to_jsonb(product_config)).
--  2) Storage-bucket `product-images`: julkinen luku, max 2 MB, vain jpeg/png/webp. Kirjoitus (insert/update/delete) vain kirjautuneille,
--     joilla on oikeus catalog.edit, ja vain polkuun products/<tuote-id>-<satunnaistunnus>.<jpg|png|webp>.
--  3) public_product_images(): julkinen luku – kuvat varattaville, kaupassa näkyville ja aktiivisille tuotteille (id, slug, path, alt).
--  4) admin_set_product_image(tuote, polku, alt): oikeus catalog.edit, validointi, null poistaa kuvan; kirjaa audit-lokiin (action ADMIN_SET_IMAGE).
-- SECURITY DEFINER + search_path = '' kuten aiemmissa. Kuvatiedoston lataus tapahtuu selaimesta Storage-rajapintaan käyttäjän omalla istunnolla.
-- =====================================================================
begin;
set local search_path = booking, extensions, public;

-- ---------- 1) kentät ----------
alter table booking.product_config
  add column if not exists image_path text,
  add column if not exists image_alt  text;
alter table booking.product_config drop constraint if exists product_config_image_path_ok;
alter table booking.product_config add constraint product_config_image_path_ok
  check (image_path is null or image_path ~ '^products/[0-9]{1,18}-[a-z0-9]{6,32}\.(jpg|jpeg|png|webp)$');
alter table booking.product_config drop constraint if exists product_config_image_alt_ok;
alter table booking.product_config add constraint product_config_image_alt_ok
  check (image_alt is null or char_length(image_alt) between 1 and 200);

-- ---------- 2) Storage ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists product_images_read   on storage.objects;
drop policy if exists product_images_insert on storage.objects;
drop policy if exists product_images_update on storage.objects;
drop policy if exists product_images_delete on storage.objects;
create policy product_images_read on storage.objects for select to anon, authenticated
  using (bucket_id = 'product-images');
create policy product_images_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and name ~ '^products/[0-9]{1,18}-[a-z0-9]{6,32}\.(jpg|jpeg|png|webp)$' and (select booking.has_permission('catalog.edit')));
create policy product_images_update on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and (select booking.has_permission('catalog.edit')))
  with check (bucket_id = 'product-images' and name ~ '^products/[0-9]{1,18}-[a-z0-9]{6,32}\.(jpg|jpeg|png|webp)$' and (select booking.has_permission('catalog.edit')));
create policy product_images_delete on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and (select booking.has_permission('catalog.edit')));

-- ---------- 3) julkinen luku ----------
create or replace function booking.public_product_images()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'product_id', p.id, 'slug', p.slug, 'path', pc.image_path, 'alt', pc.image_alt
    ) order by pc.sort_order, p.id), '[]'::jsonb)
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where pc.bookable and pc.shop_visible and pc.image_path is not null
$$;

-- ---------- 4) hallinta: kuvan asetus / poisto ----------
create or replace function booking.admin_set_product_image(p_product_id bigint, p_image_path text, p_image_alt text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_path text := nullif(btrim(coalesce(p_image_path, '')), ''); v_alt text := nullif(btrim(coalesce(p_image_alt, '')), '');
        o booking.product_config; n booking.product_config;
begin
  perform booking._require_permission('catalog.edit');
  select * into o from booking.product_config where product_id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotteella ei ole varauskonfiguraatiota'); end if;
  if v_path is not null then
    if v_path !~ '^products/[0-9]{1,18}-[a-z0-9]{6,32}\.(jpg|jpeg|png|webp)$' then
      perform booking._err('invalid_image', 'Kuvan polku ei kelpaa (products/<tuote-id>-<tunnus>.jpg|png|webp)');
    end if;
    if split_part(split_part(v_path, '/', 2), '-', 1) <> p_product_id::text then
      perform booking._err('invalid_image', 'Kuvan polun pitää alkaa tuotteen tunnuksella');
    end if;
  else
    v_alt := null;                                      -- ei kuvaa → ei alt-tekstiä
  end if;
  if v_alt is not null and char_length(v_alt) > 200 then perform booking._err('invalid_alt', 'Alt-teksti on enintään 200 merkkiä'); end if;
  update booking.product_config set image_path = v_path, image_alt = v_alt where product_id = p_product_id returning * into n;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'booking.product_config', p_product_id::text, 'ADMIN_SET_IMAGE',
          jsonb_build_object('image_path', o.image_path, 'image_alt', o.image_alt), jsonb_build_object('image_path', n.image_path, 'image_alt', n.image_alt));
  return jsonb_build_object('ok', true, 'image_path', n.image_path, 'image_alt', n.image_alt, 'previous_path', o.image_path);
end $$;

revoke all on function booking.public_product_images(), booking.admin_set_product_image(bigint, text, text) from public, anon, authenticated;
grant execute on function booking.public_product_images() to anon, authenticated;
grant execute on function booking.admin_set_product_image(bigint, text, text) to authenticated;
grant execute on function booking.public_product_images(), booking.admin_set_product_image(bigint, text, text) to service_role;

commit;
