-- ROLLBACK booking_80_pos_fridge_schema.
-- Poistaa pikakassan ja kylmälaitteiden skeeman. Tilaukset, joiden source_channel on pikakassa tai kylmalaite,
-- pitää käsitellä ennen constraintin palautusta (tämä rollback epäonnistuu, jos sellaisia rivejä on).

drop trigger if exists product_config_fridge on booking.product_config;
drop function if exists booking._product_config_fridge_trg();
drop function if exists booking._assert_fridge_product(bigint);
drop function if exists booking._text_looks_like_alcohol(text);
drop function if exists booking._drinks_path(text);

drop table if exists booking.cold_units;
drop table if exists booking.pos_tenders;

alter table booking.product_config drop constraint if exists product_config_fridge_not_age;
alter table booking.product_config drop constraint if exists product_config_pos_sort_check;
alter table booking.product_config drop column if exists age_restricted;
alter table booking.product_config drop column if exists fridge_sale;
alter table booking.product_config drop column if exists pos_sort;
alter table booking.product_config drop column if exists pos_enabled;

drop index if exists booking.orders_sale_ref_idx;
alter table booking.orders drop constraint if exists orders_sale_ref_len;
alter table booking.orders drop column if exists sale_ref;

alter table booking.orders drop constraint if exists orders_source_channel_check;
alter table booking.orders add constraint orders_source_channel_check
  check (source_channel in ('web','admin','phone','email','walk_in','johku_import','other'));

delete from booking.role_permissions where permission = 'pos.use';
