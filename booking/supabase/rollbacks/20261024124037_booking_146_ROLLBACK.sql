-- ROLLBACK booking_146_annual_card_email: vuosikortin koodin sähköposti ja kassan koodinäkymä pois.
-- Palauttaa booking_132:n email_outbox_claim-funktion ja kind-rajoitteen. Uudelleenajettava (toinen ajo ei tee mitään).
-- HUOM: poistaa kaikki annual_card_code-rivit email_outboxista (myös lähetetyt), koska vanha kind-rajoite ei salli niitä.
-- Vuosikortit ja niiden koodit säilyvät.
set local lock_timeout = '5s';
drop trigger if exists annual_cards_email on booking.annual_cards;
drop function if exists booking._annual_card_email_trg();
drop function if exists booking.admin_annual_card_for_order(bigint);
do $$
begin
  if to_regprocedure('booking.email_outbox_claim_base_146(integer)') is not null then
    drop function if exists booking.email_outbox_claim(integer);
    alter function booking.email_outbox_claim_base_146(integer) rename to email_outbox_claim;
  end if;
end $$;
drop function if exists booking._annual_card_mail(bigint);
delete from booking.email_outbox where kind = 'annual_card_code';
alter table booking.email_outbox drop constraint if exists email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check
  check (kind in ('order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change', 'gift_card_buyer', 'gift_card_recipient', 'voucher_claim_received', 'voucher_claim_problem', 'business_quote_ack', 'business_quote_notify', 'invoice_pdf', 'product_message', 'waitlist_spot_freed'));
