-- ROLLBACK booking_104_product_qr_schema.
-- Aja ensin booking_105-rollback: se palauttaa rivit arkistosta cold_units-tauluun
-- eikä pudota arkistoa. Tämä pudottaa arkiston vasta sen jälkeen.
-- fridge_sale-sarake jää. Kommentti palautetaan booking_80:n tekstiin.

drop table if exists booking.product_qr;
drop table if exists booking.cold_units_archive;

comment on column booking.product_config.fridge_sale is
  'Myytävissä pukuhuoneen kylmälaitteessa (vain virvoitusjuoma, ei ikärajallinen).';
