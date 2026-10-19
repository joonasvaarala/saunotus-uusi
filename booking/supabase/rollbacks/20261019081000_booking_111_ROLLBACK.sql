-- ROLLBACK booking_111_admin_product_create.
-- Poistaa vain tämän migraation funktion. Ei poista sillä luotuja tuoterivejä
-- eikä muuta admin_update_product-funktiota tai site_texts-taulua.

revoke all on function booking.admin_product_create(jsonb) from authenticated, service_role;
drop function if exists booking.admin_product_create(jsonb);
