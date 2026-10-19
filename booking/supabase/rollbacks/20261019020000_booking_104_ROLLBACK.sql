-- ROLLBACK booking_104_product_qr_schema.
-- Aja ensin booking_105-rollback (se pudottaa product_qr-funktiot ja palauttaa cold_units-taulun).
-- fridge_sale-sarake jää. Kommentti palautetaan booking_80:n tekstiin.

drop table if exists booking.product_qr;

comment on column booking.product_config.fridge_sale is
  'Myytävissä pukuhuoneen kylmälaitteessa (vain virvoitusjuoma, ei ikärajallinen).';
