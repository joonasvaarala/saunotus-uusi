-- ROLLBACK booking_90_invoices_schema.
-- Poistaa laskutaulut, oikeuden invoices.manage, laskuasetukset ja palauttaa orders.payment_status-rajoitteen ilman invoiced-arvoa.
-- Ajo keskeytyy, jos tauluissa on rivejä joita ei voi pudottaa (tilauksia ei poisteta). Ei tuotantoajoa tästä tiedostosta.

set local lock_timeout = '5s';

drop trigger if exists audit_trg on booking.invoice_dispatch_log;
drop trigger if exists audit_trg on booking.invoice_lines;
drop trigger if exists audit_trg on booking.invoices;
drop trigger if exists audit_trg on booking.invoice_customers;

drop policy if exists invoices_manage_read on booking.invoice_dispatch_log;
drop policy if exists invoices_manage_read on booking.invoice_lines;
drop policy if exists invoices_manage_read on booking.invoices;
drop policy if exists invoices_manage_read on booking.invoice_customers;

drop table if exists booking.invoice_dispatch_log;
drop table if exists booking.invoice_lines;
drop table if exists booking.invoices;
drop table if exists booking.invoice_counters;
drop table if exists booking.invoice_customers;

do $$ begin
  delete from storage.objects where bucket_id = 'invoices';
exception when undefined_table then null;
end $$;
delete from storage.buckets where id = 'invoices';

delete from booking.role_permissions where permission = 'invoices.manage';
delete from booking.settings where key in ('invoice_due_days', 'invoice_bank', 'invoice_dispatch_mode');

update booking.orders set payment_status = 'unpaid' where payment_status = 'invoiced';
alter table booking.orders drop constraint if exists orders_payment_status_check;
alter table booking.orders add constraint orders_payment_status_check
  check (payment_status in ('unpaid','pending','paid','partially_paid','refunded','partially_refunded','failed'));
comment on column booking.orders.payment_status is
  'unpaid|pending|paid|partially_paid|refunded|partially_refunded|failed';
