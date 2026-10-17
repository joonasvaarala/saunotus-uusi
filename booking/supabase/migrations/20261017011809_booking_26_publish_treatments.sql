-- booking_26 (17.10.2026): julkaisu – hoito- ja rituaalivaraus kb 8, 10, 11, 12 näkyviin ja varattaviksi (Joonaksen lupa; Koodarin PR #14 mainissa 28a6dfa).
-- kb 8: puuttuva englanninkielinen nimi ja kuvaus. Muita tuotteita ei muuteta. Peruutus: booking_26_ROLLBACK.sql (liput false).
update kb.products set
  name_en = coalesce(name_en, 'Short sauna ritual'),
  description_en = coalesce(description_en, 'A short sauna ritual in the Rauni healing sauna (up to six guests at a time): a greeting of the steam (löyly), gentle warming with birch whisks and a mini treatment that follows the turning of the seasons.')
 where id = 8;
update booking.product_config set bookable = true, shop_visible = true where product_id in (8, 10, 11, 12) and public_slots;
