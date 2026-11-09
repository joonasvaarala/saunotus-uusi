-- booking_266 rollback: poistaa svc_set_order_price. Jo tehdyt hinnanmuutokset ja audit-rivit säilyvät.
drop function if exists booking.svc_set_order_price(bigint, numeric, text, text, bigint, text);
