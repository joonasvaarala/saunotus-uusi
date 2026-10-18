-- ROLLBACK booking_78_procountor_rpc.
-- Aja ennen booking_77:n purkua. Ei koske accounting_exports-tauluun.

drop function if exists booking.admin_procountor_status();
drop function if exists booking.procountor_export_mark(bigint, text, text, jsonb);
drop function if exists booking.procountor_invoice_reserve(text, jsonb, text, date, jsonb, boolean);
drop function if exists booking.procountor_daily_prepare(date, boolean);
drop function if exists booking._procountor_daily_build(date, jsonb, jsonb);
