drop trigger if exists voucher_claims_webhook on booking.voucher_claims;
drop function if exists booking._vc_webhook_trg();
-- vault-salaisuudet voucher_claims_webhook_url/_key jätetään (poista tarvittaessa käsin).
