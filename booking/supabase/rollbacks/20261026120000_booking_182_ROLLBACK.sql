-- booking_182 ROLLBACK: poistaa vain tämän ominaisuuden lisätyn asetuksen.
-- Korvattuja funktioita ei ole; aiemmat funktio-md5:t pysyvät ennallaan.
-- Poistaa asetuksen vain, jos se vastaa migraation oletusarvoa false.
delete from booking.settings
where key = 'admin_order_reservation_flow_enabled'
  and value = 'false'::jsonb;
