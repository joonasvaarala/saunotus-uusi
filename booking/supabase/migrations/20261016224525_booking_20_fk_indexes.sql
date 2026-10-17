-- booking_20_fk_indexes (17.10.2026): additiivinen. Indeksit FK-sarakkeille jotka liittyvät Johku-tuontiin / rollbackiin.
-- reservations.order_item_id (FK ON DELETE SET NULL: order_items-poisto skannasi koko reservations-taulun per rivi)
-- reservations.product_id    (FK: tuote-/kb-poistojen ja tuotekohtaisten hakujen tarkistus)
create index if not exists reservations_order_item_idx on booking.reservations (order_item_id) where order_item_id is not null;
create index if not exists reservations_product_idx on booking.reservations (product_id) where product_id is not null;
