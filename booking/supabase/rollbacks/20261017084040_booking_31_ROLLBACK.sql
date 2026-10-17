-- booking_31 rollback (aja ennen booking_30/29 rollbackia). Kuitteja ei pidä poistaa tuotannosta kun niitä on – tämä vain testi-/kehitysympäristöön.
select cron.unschedule('booking_send_emails');
drop trigger if exists orders_confirmed_ins on booking.orders;
drop trigger if exists orders_confirmed_upd on booking.orders;
create or replace function booking._on_payment_paid(p_payment_id bigint) returns void language plpgsql security definer set search_path = '' as $$ begin null; end $$;
create or replace function booking._on_refund_done(p_refund_id bigint) returns void language plpgsql security definer set search_path = '' as $$ begin null; end $$;
drop function if exists booking.orders_confirmed_mail_trg(), booking._issue_refund_receipt(bigint), booking._issue_receipt(bigint), booking._buyer_json(bigint), booking._receipt_year(timestamptz),
  booking._receipt_text(jsonb), booking._vat_groups(jsonb), booking._next_receipt_no(text, integer), booking._seller(), booking._rate_txt(numeric, text), booking._money(numeric, text),
  booking._cron_secret_ok(text), booking.email_outbox_claim(integer), booking.email_outbox_mark(bigint, text, text, text), booking._receipt_json(booking.receipts, boolean),
  booking.admin_get_receipt(bigint), booking.admin_resend_receipt(bigint), booking.public_get_receipt(uuid, text), booking.receipt_by_token(uuid), booking.receipt_set_pdf(bigint, text);
delete from booking.settings where key in ('functions_base_url','receipt_series');
-- admin_list_vat_rates: palauta booking_30:n versio tarvittaessa
