-- booking_224 rollback. Laskun maksu luo taas kuitin, laskuraportti poistuu.
set local lock_timeout = '5s';

create or replace function booking.admin_mark_invoice_paid(p_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i booking.invoices;
begin
  perform booking._require_permission('invoices.manage');
  select * into i from booking.invoices where id = p_id for update;
  if not found then perform booking._err('not_found', 'Laskua ei löydy'); end if;
  if i.kind = 'credit' then perform booking._err('invalid_status', 'Hyvityslaskua ei merkitä maksetuksi'); end if;
  if i.status not in ('sent', 'overdue') then perform booking._err('invalid_status', 'Vain lähetetty lasku voidaan merkitä maksetuksi'); end if;
  update booking.invoices set status = 'paid', paid_at = now() where id = p_id;
  if i.order_id is not null then
    update booking.payments set status = 'paid', paid_at = now()
     where order_id = i.order_id and method = 'invoice' and status = 'pending';
    perform booking._refresh_order_payment(i.order_id);
  end if;
  return booking._invoice_row(p_id);
end $$;

drop function if exists booking.admin_report_invoices(date, date, text);
alter table booking.invoices drop constraint if exists invoices_procountor_export_status_check;
alter table booking.invoices drop column if exists procountor_export_status;
alter table booking.invoices drop column if exists procountor_invoice_id;
