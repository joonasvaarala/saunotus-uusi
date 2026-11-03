-- booking_240 read-only testi. Ei muuta dataa: set_config(...,true) ja set local role ovat vain tämän erän transaktiossa.
-- Tulostaa vain koosteet (ei henkilötietoja, ei käyttäjätunnisteita).
select set_config('request.jwt.claims',
  (select json_build_object('sub', s.user_id, 'role', 'authenticated')::text
     from booking.staff s join booking.roles r on r.code = s.role and r.active and r.is_staff
    where s.active and exists (select 1 from booking.role_permissions rp where rp.role_code = s.role and rp.permission = 'reports.view')
    order by s.created_at limit 1), true);
set local role authenticated;
with r as (select booking.admin_analytics_summary('2026-10-28', '2026-11-03') j),
     z as (select booking.admin_analytics_summary('2026-11-03', '2026-11-03') j)
select current_user as run_as,
       r.j -> 'funnel' as funnel,
       jsonb_typeof(r.j->'funnel'->'buyers') t_buyers, jsonb_typeof(r.j->'funnel'->'paid_orders') t_orders,
       jsonb_typeof(r.j->'funnel'->'amount_gross') t_amount, jsonb_typeof(r.j->'funnel'->'conversion_pct') t_conv,
       (select array_agg(k order by k) from jsonb_object_keys(r.j) k) top_keys,
       jsonb_array_length(r.j->'daily_series') days,
       z.j -> 'funnel' -> 'conversion_pct' conv_one_day
  from r, z;
