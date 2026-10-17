-- booking_35_talous_report_fields (17.10.2026): raportin totals.gross_after_refunds (= net_after_refunds, joka on deprecated), period.kind ('day'|'month'), roolien tarkoituksellisuus kommentteina. Vain create or replace + comment. Rollback: booking_35_ROLLBACK.sql
create or replace function booking.admin_report_daily(p_date date) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform booking._report_check(false);
  if p_date is null then perform booking._err('invalid_param', 'Anna päivämäärä'); end if;
  v := booking._report_json(p_date, p_date, true, false);
  v := jsonb_set(v, '{totals,gross_after_refunds}', v -> 'totals' -> 'net_after_refunds');
  return jsonb_set(v, '{period,kind}', '"day"'::jsonb);
end $$;
create or replace function booking.admin_report_month(p_ym text) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_from date; v jsonb;
begin
  perform booking._report_check(true);
  if p_ym is null or p_ym !~ '^\d{4}-(0[1-9]|1[0-2])$' then perform booking._err('invalid_param', 'Kuukausi muodossa YYYY-MM'); end if;
  v_from := (p_ym || '-01')::date;
  v := booking._report_json(v_from, (v_from + interval '1 month' - interval '1 day')::date, false, true);
  v := jsonb_set(v, '{totals,gross_after_refunds}', v -> 'totals' -> 'net_after_refunds');
  return jsonb_set(v, '{period,kind}', '"month"'::jsonb);
end $$;
comment on function booking.admin_report_daily(date) is 'Päiväraportti: reports.daily TAI reports.view (kassavuorossa oleva henkilökunta saa päiväraportin). Tarkoituksellinen.';
comment on function booking.admin_report_month(text) is 'Kuukausiraportti: vain reports.view (manager/admin). Tarkoituksellinen.';
comment on function booking.admin_report_csv(date, date, text) is 'CSV-vienti: vain reports.view (manager/admin). Tarkoituksellinen.';
comment on function booking.admin_list_payments(text, text, text, date, date, text, boolean, integer, integer) is 'Maksulista ilman laskurivejä (kevyt lista); rivit haetaan admin_get_order():sta. Tarkoituksellinen.';
