-- booking_35 rollback: palauttaa booking_32:n (ja 34:n) wrapperit ilman gross_after_refunds/period.kind
create or replace function booking.admin_report_daily(p_date date) returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._report_check(false);
  if p_date is null then perform booking._err('invalid_param', 'Anna päivämäärä'); end if;
  return booking._report_json(p_date, p_date, true, false);
end $$;
create or replace function booking.admin_report_month(p_ym text) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_from date;
begin
  perform booking._report_check(true);
  if p_ym is null or p_ym !~ '^\d{4}-(0[1-9]|1[0-2])$' then perform booking._err('invalid_param', 'Kuukausi muodossa YYYY-MM'); end if;
  v_from := (p_ym || '-01')::date;
  return booking._report_json(v_from, (v_from + interval '1 month' - interval '1 day')::date, false, true);
end $$;
