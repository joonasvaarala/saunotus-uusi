-- booking_268 ROLLBACK: palauttaa _arm_staff_overrides (md5 d02fc399...) ja _staff_overbook (md5 74747984...) PROD-määrittelyt 9.11.2026
CREATE OR REPLACE FUNCTION booking._arm_staff_overrides(p_overbook boolean, p_off_schedule boolean, p_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_permission('bookings.manage');
  if coalesce(p_overbook, false) and not booking.is_admin() then
    perform booking._err('overbook_admin_only', 'Vain admin voi ylibuukata.');
  end if;
  if coalesce(p_overbook, false) or coalesce(p_off_schedule, false) then
    perform set_config('booking.allow_overbook', case when coalesce(p_overbook, false) then 'on' else 'off' end, true);
    perform set_config('booking.allow_off_schedule', case when coalesce(p_off_schedule, false) then 'on' else 'off' end, true);
    perform set_config('booking.off_schedule_start', coalesce(p_start::text, ''), true);
    perform set_config('booking.off_schedule_end', coalesce(p_end::text, ''), true);
  else
    perform booking._clear_staff_overrides();
  end if;
end $function$;

CREATE OR REPLACE FUNCTION booking._staff_overbook()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(current_setting('booking.allow_overbook', true), '') = 'on'
     and (coalesce(booking.is_admin(), false)
          or coalesce(current_setting('booking.svc_overbook', true), '') = 'on')
$function$;

