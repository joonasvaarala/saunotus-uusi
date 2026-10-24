-- =============================================================================
-- booking_138_reservations_nav.sql (paketti 05: hallinnan navigaatio)
-- =============================================================================
-- VAIN LUKU. admin_list_reservations saa kaksi parametria lisää (molemmat DEFAULT NULL):
--   p_sort           NULL = aiempi järjestys (alkamisaika laskevasti, kuten booking_72);
--                    'start_asc' (tulevat lähin ensin), 'created_desc' (uusin tilaus ensin), 'created_asc'.
--                    Lajittelu tehdään palvelimella, joten sivutus (limit/offset) pysyy oikeana.
--   p_reservation_id rajaa yhteen varaukseen (suora linkki #/varaukset?id=...).
-- Yhdeksän paikallista argumenttia toimii yhä (admin_day_bundle, booking_133). Vanha 9-argumenttinen
-- ylikuorma poistetaan, jotta PostgREST ei jää PGRST203-tilaan. Runko on booking_72:n funktio + yksi
-- WHERE-ehto + ORDER BY. Ei taulu-, data- eikä public-skeeman muutoksia.
-- Rollback: rollbacks/20261024081128_booking_138_ROLLBACK.sql (palauttaa booking_72:n funktion sellaisenaan).
-- =============================================================================

set local lock_timeout = '5s';

drop function if exists booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer, text, boolean);
drop function if exists booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer, text, boolean, text, bigint);

create function booking.admin_list_reservations(
  p_from timestamp with time zone default null,
  p_to timestamp with time zone default null,
  p_search text default null,
  p_status text default null,
  p_product_id bigint default null,
  p_limit integer default 50,
  p_offset integer default 0,
  p_source text default null,
  p_option_missing boolean default null,
  p_sort text default null,
  p_reservation_id bigint default null)
returns table (reservation_id bigint, order_id bigint, order_no bigint, status text, order_status text, payment_status text, product_id bigint, product_name text, mode text, starts_at timestamp with time zone, ends_at timestamp with time zone, persons integer, total_gross numeric, customer_id bigint, customer_name text, customer_email text, customer_phone text, source_channel text, created_at timestamp with time zone, hold_expires_at timestamp with time zone, notes text, annual_card_id bigint, total_count bigint, source text, external_id text, lifecycle text, space_code text, legs jsonb, parent_reservation_id bigint, option_id bigint, option_code text, option_name text, option_name_en text, option_missing boolean)
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform booking._require_staff();
  return query
    select r.id, o.id, o.order_no,
           case when r.status = 'pending' and r.hold_expires_at <= now() then 'expired' else r.status end,
           o.status, o.payment_status, r.product_id, coalesce(it.product_name, p.name), r.mode, r.starts_at, r.ends_at, r.persons,
           o.total_gross, c.id, c.name, c.email, c.phone, o.source_channel, o.created_at, r.hold_expires_at, r.notes, r.annual_card_id,
           count(*) over (), coalesce(r.external_source, 'native'), r.external_id,
           pcf.lifecycle, sp.code,
           coalesce((select jsonb_agg(jsonb_build_object('role', l.role, 'resource_code', lr.code, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'persons', l.persons, 'skill', l.skill)
                                      order by l.starts_at, l.id)
                       from booking.reservation_legs l join booking.resources lr on lr.id = l.resource_id where l.reservation_id = r.id), '[]'::jsonb),
           r.parent_reservation_id, po.id, po.code, po.name, po.name_en,
           (po.id is null and exists (select 1 from booking.product_options x where x.product_id = r.product_id and x.active))
      from booking.reservations r
      join booking.orders o on o.id = r.order_id
      join booking.resources sp on sp.id = r.space_id
      left join booking.order_items it on it.id = r.order_item_id
      left join kb.products p on p.id = r.product_id
      left join booking.product_config pcf on pcf.product_id = r.product_id
      left join booking.product_options po on po.id = r.product_option_id
      left join booking.customers c on c.id = o.customer_id
     where r.hidden_at is null and (p_from is null or r.starts_at >= p_from) and (p_to is null or r.starts_at < p_to)
       and (p_product_id is null or r.product_id = p_product_id)
       and (p_source is null or coalesce(r.external_source, 'native') = p_source)
       and (p_status is null
            or (p_status = 'active' and booking._res_active(r.status, r.hold_expires_at))
            or (p_status = 'expired' and r.status = 'pending' and r.hold_expires_at <= now()) or r.status = p_status)
       and (q is null or c.name ilike '%' || q || '%' or c.email ilike '%' || q || '%' or c.phone ilike '%' || q || '%'
            or o.order_no::text = q or c.company ilike '%' || q || '%')
       and (p_option_missing is not true
            or (po.id is null and exists (select 1 from booking.product_options x where x.product_id = r.product_id and x.active)))
       and (p_reservation_id is null or r.id = p_reservation_id)
     order by
       case when p_sort = 'start_asc' then r.starts_at end asc,
       case when p_sort = 'created_desc' then o.created_at end desc,
       case when p_sort = 'created_asc' then o.created_at end asc,
       case when p_sort in ('start_asc', 'created_asc') then r.id end asc,
       r.starts_at desc, r.id desc
     limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0);
end $function$;


comment on function booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer, text, boolean, text, bigint) is
  'Henkilökunta: varauslista. p_option_missing=true rajaa hoidot, joissa valinta puuttuu. p_sort: NULL (alkamisaika laskevasti), start_asc, created_desc, created_asc. p_reservation_id rajaa yhteen varaukseen. Vain luku.';

revoke all on function booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer, text, boolean, text, bigint) from public, anon, authenticated;
grant execute on function booking.admin_list_reservations(timestamptz, timestamptz, text, text, bigint, integer, integer, text, boolean, text, bigint) to service_role, authenticated;
