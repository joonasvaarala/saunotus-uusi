-- PALUU booking_212. public_product_images takaisin booking_19:n muotoon (ei updated_at).
-- CREATE OR REPLACE säilyttää oikeudet. Sivusto toimii ilman kenttää: versio on silloin kuvan polku.
set local lock_timeout = '5s';

create or replace function booking.public_product_images()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'product_id', p.id, 'slug', p.slug, 'path', pc.image_path, 'alt', pc.image_alt
    ) order by pc.sort_order, p.id), '[]'::jsonb)
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where pc.bookable and pc.shop_visible and pc.image_path is not null
$$;
