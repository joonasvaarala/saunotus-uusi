-- Rollback booking_219: poistaa suoriteperusteisen raportin. Ei koske kassaperusteista _report_jsonia.
drop function if exists booking.admin_report_accrual_csv(date, date);
drop function if exists booking.admin_report_accrual(date, date);
drop function if exists booking._accrual_json(date, date, date);
