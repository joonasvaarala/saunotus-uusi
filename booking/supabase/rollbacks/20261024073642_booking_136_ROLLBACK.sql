-- Rollback booking_136: poistaa booking_136:n uudet funktiot. Olemassa olevia funktioita (admin_refund, admin_set_reservation_status)
-- ei muutettu, joten niitä ei palauteta. Tehdyt hyvitykset ja peruutukset jäävät (tavallisia refunds-/reservations-rivejä). Voidaan ajaa useasti.
set local lock_timeout = '5s';
drop function if exists booking.admin_refund_order(bigint, numeric, text, jsonb, boolean);
drop function if exists booking.admin_cancel_reservation(bigint, text, boolean, text);
drop function if exists booking.admin_reservation_refund_preview(bigint);
drop function if exists booking._reservation_refund_plan(bigint);
