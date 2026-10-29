-- booking_212: tuotekuvan versio julkiseen listaan.
-- public_product_images palauttaa lisäksi product_config.updated_at. Kuva vaihtuu
-- (admin_set_product_image päivittää rivin, trigger product_config_updated kirjoittaa updated_at),
-- ja selain liittää arvon kuvan osoitteeseen (?v=), jotta sama polku ei näytä välimuistin vanhaa tiedostoa.
-- Rivijoukko, polku, alt ja järjestys eivät muutu. Ei uutta saraketta: updated_at on ollut product_configissa booking_01:stä.
-- CREATE OR REPLACE säilyttää omistajan ja oikeudet (anon, authenticated, service_role).
-- Paluu: booking/supabase/rollbacks/20261028194142_booking_212_ROLLBACK.sql.
set local lock_timeout = '5s';

create or replace function booking.public_product_images()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'product_id', p.id, 'slug', p.slug, 'path', pc.image_path, 'alt', pc.image_alt,
      'updated_at', pc.updated_at
    ) order by pc.sort_order, p.id), '[]'::jsonb)
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where pc.bookable and pc.shop_visible and pc.image_path is not null
$$;
