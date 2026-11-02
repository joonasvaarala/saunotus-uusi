-- Rollback booking_235: poista asiakaspalvelu- ja kääntäjäbotin service_role-työkalut.
-- Ei dataa: funktiot eivät luo tauluja. Aiemmin kirjoitetut audit-rivit ja tehdyt siirrot jäävät.
set local lock_timeout = '5s';
set local statement_timeout = '60s';

drop function if exists booking.svc_set_product_text_en(bigint, text, text, text);
drop function if exists booking.svc_texts_stale_en(integer);
drop function if exists booking.svc_mark_order_paid_external(bigint, text, text);
drop function if exists booking.svc_move_reservation(bigint, timestamptz, text, text);
