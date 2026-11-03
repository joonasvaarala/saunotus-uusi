CREATE OR REPLACE FUNCTION booking._analytics_paid_orders(p_from date, p_to date)
 RETURNS TABLE(buyers integer, orders integer, gross numeric, linked integer, orders_all integer, gross_all numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with o as (
    select o.id, o.total_gross, o.source_channel
      from booking.orders o
     where o.created_at >= (p_from::timestamp at time zone 'Europe/Helsinki')
       and o.created_at <  ((p_to + 1)::timestamp at time zone 'Europe/Helsinki')
       and o.payment_status in ('paid', 'partially_refunded')
       and o.status not in ('cancelled', 'expired', 'pending')
       and o.external_source is null and o.johku_order_no is null
       and o.source_channel is distinct from 'johku_import'
  )
  select count(*) filter (where o.source_channel = 'web')::int,
         count(*) filter (where o.source_channel = 'web')::int,
         coalesce(sum(o.total_gross) filter (where o.source_channel = 'web'), 0)::numeric(12,2),
         count(*) filter (where o.source_channel = 'web' and exists (
           select 1 from booking.analytics_events e where e.event_type = 'purchase' and e.order_id = o.id))::int,
         count(*)::int,
         coalesce(sum(o.total_gross), 0)::numeric(12,2)
    from o
$function$
;
