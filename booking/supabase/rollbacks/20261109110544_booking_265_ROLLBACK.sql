-- booking_265 rollback: poistaa svc_redeem_partner_voucher_at_value. Jo tehdyt kirjaukset (maksut, hinnat, audit) säilyvät.
drop function if exists booking.svc_redeem_partner_voucher_at_value(bigint, numeric, text, text, text, text);
