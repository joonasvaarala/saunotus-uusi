-- booking_132 rollback: jonotuslista ja uuden viestityypin käsittely pois.
-- Palauttaa booking_121:n email_outbox_claim-funktion ja kind-rajoitteen. Uudelleenajettava (toinen ajo ei tee mitään).
-- HUOM: poistaa kaikki waitlist_spot_freed-rivit email_outboxista (myös lähetetyt), koska vanha kind-rajoite ei salli niitä.
set local lock_timeout = '5s';
drop trigger if exists waitlist_reservation_booked on booking.reservations;
drop trigger if exists waitlist_reservation_freed on booking.reservations;
drop function if exists booking._waitlist_booked_trg();
drop function if exists booking._waitlist_reservation_freed_trg();
drop function if exists booking._notify_waitlist_for_window(bigint,timestamptz,timestamptz);
drop function if exists booking.public_join_waitlist(bigint,date,integer,text,text,text,text,boolean);
drop function if exists booking.public_leave_waitlist(uuid);
drop function if exists booking.admin_list_waitlist(date,date);
-- Wrapper pois ja alkuperäinen claim takaisin vain, jos booking_132:n tallettama perusfunktio on olemassa.
do $$
begin
  if to_regprocedure('booking.email_outbox_claim_base_132(integer)') is not null then
    drop function if exists booking.email_outbox_claim(integer);
    alter function booking.email_outbox_claim_base_132(integer) rename to email_outbox_claim;
  end if;
end $$;
drop table if exists booking.waitlist_entries;
delete from booking.email_outbox where kind = 'waitlist_spot_freed';
alter table booking.email_outbox drop constraint if exists email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check
  check (kind in ('order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change', 'gift_card_buyer', 'gift_card_recipient', 'voucher_claim_received', 'voucher_claim_problem', 'business_quote_ack', 'business_quote_notify', 'invoice_pdf', 'product_message'));
delete from booking.settings where key in ('waitlist_enabled','waitlist_whatsapp_enabled','waitlist_quiet_hours_start','waitlist_quiet_hours_end');
