-- Rollback booking_234: poista asiakaspalvelubotin lahjakortin voimassaolon pidennys.
set local lock_timeout = '5s';
set local statement_timeout = '60s';

drop function if exists booking.svc_set_gift_card_expiry(text, date, text, text);
drop function if exists booking.svc_set_gift_card_expiry(bigint, date, text, text);
