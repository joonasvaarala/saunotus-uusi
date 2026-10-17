-- booking_26 peruutus: piilota hoitotuotteet (kb 8, 10, 11, 12) verkkokaupasta
update booking.product_config set bookable = false, shop_visible = false where product_id in (8, 10, 11, 12);
