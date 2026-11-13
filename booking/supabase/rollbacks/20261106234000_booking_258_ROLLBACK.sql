-- ROLLBACK booking_258. Poistaa tuote-RPC:n ja palauttaa _customer_message_hits booking_257-muotoon
-- (p_product_ids aina rajaa; ei null=kaikki). Ei koske lokitaulua eikä lähetys-RPC:itä.
set local lock_timeout = '5s';

drop function if exists booking.admin_customer_message_products(date, date);

create or replace function booking._customer_message_hits(p_from date, p_to date, p_product_ids bigint[])
returns table (
  uniq text,
  order_id bigint,
  customer_id bigint,
  email text,
  cust_name text,
  locale text,
  public_token uuid,
  order_no bigint,
  hit_kind text,
  product_id bigint,
  starts_at timestamptz,
  ends_at timestamptz,
  paid_at timestamptz,
  persons integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce('c:' || o.customer_id::text,
                  nullif('e:' || lower(btrim(coalesce(c.email, ''))), 'e:'),
                  'o:' || o.id::text),
         o.id, o.customer_id, c.email, c.name, coalesce(o.locale, 'fi'), o.public_token, o.order_no,
         'reservation'::text, r.product_id, r.starts_at, r.ends_at, null::timestamptz, r.persons
    from booking.reservations r
    join booking.orders o on o.id = r.order_id
    left join booking.customers c on c.id = o.customer_id
   where r.product_id = any (p_product_ids)
     and (r.starts_at at time zone 'Europe/Helsinki')::date between p_from and p_to
     and (booking._res_active(r.status, r.hold_expires_at) or r.status = 'completed')
     and o.external_source is null
     and (c.id is null or c.anonymized_at is null)
  union all
  select coalesce('c:' || o.customer_id::text,
                  nullif('e:' || lower(btrim(coalesce(c.email, ''))), 'e:'),
                  'o:' || o.id::text),
         o.id, o.customer_id, c.email, c.name, coalesce(o.locale, 'fi'), o.public_token, o.order_no,
         'purchase'::text, oi.product_id, null::timestamptz, null::timestamptz, pay.paid_at, null::integer
    from booking.order_items oi
    join booking.orders o on o.id = oi.order_id
    join booking.payments pay on pay.order_id = o.id
     and pay.status in ('paid', 'partially_refunded')
     and pay.paid_at is not null
     and pay.external_source is null
     and (pay.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to
    left join booking.customers c on c.id = o.customer_id
   where oi.product_id = any (p_product_ids)
     and o.external_source is null
     and o.cancelled_at is null
     and (c.id is null or c.anonymized_at is null)
$$;

do $$
begin
  execute 'revoke all on function booking._customer_message_hits(date, date, bigint[]) from public, anon, authenticated';
end $$;

notify pgrst, 'reload schema';
