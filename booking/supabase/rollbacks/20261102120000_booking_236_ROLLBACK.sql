-- Rollback booking_236. Poistaa monikorttikirjauksen.
-- svc_mark_voucher_claim_redeemed ja _vc_redeem eivät muuttuneet tässä migraatiossa, joten niiden runkoja ei kirjoiteta uudelleen.
set local lock_timeout = '5s';
set local statement_timeout = '60s';

drop function if exists booking.svc_mark_voucher_claims_redeemed(bigint[], numeric, text, text, boolean);
drop function if exists booking.svc_mark_voucher_claims_redeemed(bigint[], numeric[], text, text, boolean);
drop function if exists booking._vc_redeem_many(bigint[], numeric[], text, text, text, boolean);
