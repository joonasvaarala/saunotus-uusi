-- booking_276 ROLLBACK: palauttaa admin_day_bundlen PRODin 10.11.2026 määrittelyyn (md5(pg_get_functiondef) 2b6b937daf1b26b76d174c4e208cb715,
-- site_texts = public_get_site_texts(null)) ja poistaa uudet funktiot admin_ui_texts ja admin_day_data.
-- Client (PR B) toimii myös rollbackin jälkeen: puuttuvat funktiot → varapolku admin_day_bundle / public_get_site_texts.
CREATE OR REPLACE FUNCTION booking.admin_day_bundle(p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_from timestamptz := (p_date::timestamp at time zone booking._tz());
  v_to timestamptz := ((p_date + 1)::timestamp at time zone booking._tz());
begin
  perform booking._require_staff();
  if p_date is null then perform booking._err('invalid_date', 'Päivä puuttuu'); end if;
  return jsonb_build_object(
    'date', p_date,
    'role', booking.current_staff_role(),
    'permissions', booking.admin_my_permissions(),
    'products', booking.admin_list_products(),
    'payment_methods', coalesce((select jsonb_agg(to_jsonb(pm) order by pm.sort_order, pm.code)
       from (select code, label, is_manual, active, sort_order from booking.payment_methods) pm), '[]'::jsonb),
    'resources', coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from booking.resources r), '[]'::jsonb),
    'view', booking.admin_day_view(p_date),
    'reservations', coalesce((select jsonb_agg(to_jsonb(x) order by x.starts_at desc, x.reservation_id desc)
       from booking.admin_list_reservations(v_from, v_to, null, null, null, 200, 0, null, null) x), '[]'::jsonb),
    'shifts', coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at, s.shift_id, s.staff_name nulls last)
       from booking.admin_day_shifts(p_date) s), '[]'::jsonb),
    'addons', booking.admin_list_addons(),
    'options', booking.admin_list_product_options(null),
    'extras', booking.admin_day_extras(p_date),
    'site_texts', booking.public_get_site_texts(null),
    'notes_bundle', booking.admin_list_day_notes(p_date)
  );
end $function$;

drop function if exists booking.admin_day_data(date);
drop function if exists booking.admin_ui_texts(text);

notify pgrst, 'reload schema';
