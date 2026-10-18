-- booking_75_ROLLBACK: tarjouspyynnöt, oikeus ja sähköpostilajit pois.
-- Poistaa taulun business_quote_requests (pyynnöt menetetään) ja jonossa olevat business_quote_*-viestit.
-- email_outbox_kind_check palautetaan booking_47:n listaan. Aja ennen booking_74:n purkua.
set local lock_timeout = '5s';

drop function if exists booking.admin_set_business_quote_status(bigint, text, text);
drop function if exists booking.admin_list_business_quotes(text);
drop function if exists booking.public_create_business_quote(text, text, text, text, text, integer, jsonb, text, text, text, boolean, text);
drop table if exists booking.business_quote_requests;

delete from booking.email_outbox where kind in ('business_quote_ack', 'business_quote_notify');
alter table booking.email_outbox drop constraint if exists email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check
  check (kind in ('order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change',
                  'gift_card_buyer', 'gift_card_recipient', 'voucher_claim_received', 'voucher_claim_problem'));

delete from booking.role_permissions where permission = 'quotes.manage';
delete from booking.settings where key in (
  'business_quote_rl_ip_per_10min', 'business_quote_rl_email_per_hour',
  'business_quote_notify_email', 'business_quote_notify_name'
);
