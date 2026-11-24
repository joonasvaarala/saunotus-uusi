-- booking_344 ROLLBACK: uudet svc-funktiot pois (ei muutoksia olemassa oleviin funktioihin).
drop function if exists booking.svc_pay_order_with_gift_card(bigint, bigint, numeric, text, text);
drop function if exists booking.svc_reactivate_gift_card(bigint, text, text);
