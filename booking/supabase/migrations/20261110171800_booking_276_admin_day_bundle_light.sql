-- booking_276: hallinnan päivänippu kevyemmäksi (Joonas t427u, selvitys 10.11.2026)
-- 1) Uusi booking.admin_ui_texts(p_lang): vain hallinnan käyttämät julkaistut tekstit (ui.admin.*, ui.pos.*, ui.upsell.*, admin.*),
--    sama muoto kuin public_get_site_texts: { ok, generated_at, texts: [{ key, lang, text, version, placeholders }] }.
--    PRODissa 10.11: public_get_site_texts(null) = 8612 riviä / 1,35 MB / 455 ms; hallinnan osuus ~3600 riviä.
-- 2) admin_day_bundle(p_date): 'site_texts' = admin_ui_texts(null) (ennen public_get_site_texts(null)). Muut kentät ja muoto ennallaan.
--    Vanha client toimii: se lukee nipun site_texts-kentästä vain hallinnan avaimia; julkisia avaimia hallinta ei käytä.
-- 3) Uusi booking.admin_day_data(p_date): päivänvaihdon kevyt nippu ilman roolia, oikeuksia, tuotteita, maksutapoja,
--    resursseja ja tekstejä (ne ovat clientillä jo avauksen admin_day_bundle-kutsusta). Kentät: date, view, reservations,
--    shifts, addons, options, extras, notes_bundle (+ light = true). Samat alikutsut kuin admin_day_bundlessa.
-- Ei taulumuutoksia, ei datamuutoksia, ei public-skeemaa. Oikeudet: authenticated (kuten admin_day_bundle); molemmat
-- uudet funktiot vaativat henkilökunnan (booking._require_staff()). Peruutus: rollbacks/20261110171800_booking_276_ROLLBACK.sql.

CREATE OR REPLACE FUNCTION booking.admin_ui_texts(p_lang text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_staff();
  return (
    select jsonb_build_object('ok', true, 'generated_at', now(), 'scope', 'admin', 'texts', coalesce(jsonb_agg(jsonb_build_object('key', t.key, 'lang', t.lang, 'text', t.published_text, 'version', t.published_version, 'placeholders', to_jsonb(t.placeholders))
                                                                                                         order by t.key, t.lang), '[]'::jsonb))
      from booking.site_texts t
     where t.published_version > 0 and t.published_text <> '' and t.class <> 'locked' and (p_lang is null or t.lang = lower(btrim(p_lang)))
       and (t.key like 'ui.admin.%' or t.key like 'ui.pos.%' or t.key like 'ui.upsell.%' or t.key like 'admin.%')
       and not (t.source_table = 'booking.product_timeline_segments' and exists (select 1 from booking.product_timeline_segments s where s.id::text = t.source_pk and not s.customer_visible))
  );
end $function$;

revoke all on function booking.admin_ui_texts(text) from public, anon;
grant execute on function booking.admin_ui_texts(text) to authenticated, service_role;

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
    'site_texts', booking.admin_ui_texts(null),
    'notes_bundle', booking.admin_list_day_notes(p_date)
  );
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_day_data(p_date date)
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
    'light', true,
    'view', booking.admin_day_view(p_date),
    'reservations', coalesce((select jsonb_agg(to_jsonb(x) order by x.starts_at desc, x.reservation_id desc)
       from booking.admin_list_reservations(v_from, v_to, null, null, null, 200, 0, null, null) x), '[]'::jsonb),
    'shifts', coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at, s.shift_id, s.staff_name nulls last)
       from booking.admin_day_shifts(p_date) s), '[]'::jsonb),
    'addons', booking.admin_list_addons(),
    'options', booking.admin_list_product_options(null),
    'extras', booking.admin_day_extras(p_date),
    'notes_bundle', booking.admin_list_day_notes(p_date)
  );
end $function$;

revoke all on function booking.admin_day_data(date) from public, anon;
grant execute on function booking.admin_day_data(date) to authenticated, service_role;

notify pgrst, 'reload schema';
