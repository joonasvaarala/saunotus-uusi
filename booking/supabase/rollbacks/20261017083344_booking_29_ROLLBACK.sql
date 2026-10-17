-- booking_29 rollback (vain jos taulut ovat tyhjiä; kuitteja ei pidä poistaa tuotannosta kun niitä on)
drop table if exists booking.accounting_outbox, booking.integration_config, booking.order_requests, booking.email_outbox,
  booking.receipts, booking.receipt_counters, booking.refunds, booking.payment_lines cascade;
alter table booking.payments drop column if exists rounding, drop column if exists link_sent_at;
drop trigger if exists order_items_vat_guard on booking.order_items;
drop trigger if exists addons_vat_guard on booking.addons;
drop function if exists booking.vat_guard_trg(), booking.receipts_guard_trg(), booking._vat_active(numeric);
drop table if exists booking.vat_rates cascade;
delete from booking.role_permissions where permission in ('payments.refund','reports.view','reports.daily');
delete from booking.settings where key in ('seller','site_base_url','payment_link_path','order_page_path');
