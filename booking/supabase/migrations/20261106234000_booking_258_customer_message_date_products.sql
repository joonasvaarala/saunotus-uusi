-- booking_258: Viesti asiakkaalle – tuotevalinnassa vain valitun päivän/välin
-- varatut tai myydyt tuotteet (sama kelpoisuus kuin vastaanottajahaku).
-- Laajentaa _customer_message_hits: p_product_ids null = kaikki tuotteet.
-- Uusi RPC admin_customer_message_products. Ei muuta lähetys-/esikatselupolkua muuten.
-- Ei koske uutiskirjettä. Riippuu booking_257:stä.

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
   where (p_product_ids is null or r.product_id = any (p_product_ids))
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
   where (p_product_ids is null or oi.product_id = any (p_product_ids))
     and o.external_source is null
     and o.cancelled_at is null
     and (c.id is null or c.anonymized_at is null)
$$;

create or replace function booking.admin_customer_message_products(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from date;
  v_to date;
begin
  perform booking._require_permission('messages.edit');
  if p_from is null then perform booking._err('invalid_param', 'Valitse päivä tai aikaväli'); end if;
  v_from := p_from;
  v_to := coalesce(p_to, p_from);
  if v_to < v_from then perform booking._err('invalid_param', 'Loppupäivä ei voi olla ennen alkupäivää'); end if;
  if (v_to - v_from) > 366 then perform booking._err('invalid_param', 'Aikaväli on liian pitkä'); end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id,
             'name', p.name,
             'name_en', p.name_en,
             'category', p.category,
             'category_label', booking._category_label(p.category),
             'active', p.active
           ) order by booking._category_label(p.category), p.name, p.id)
      from kb.products p
     where p.id in (
       select distinct h.product_id
         from booking._customer_message_hits(v_from, v_to, null) h
     )
  ), '[]'::jsonb);
end $$;

comment on function booking.admin_customer_message_products(date, date) is
  'booking_258: tuotteet, joilla on kelvollinen varaus (alkupäivä HH) tai osto (maksupäivä HH) valitulla päivällä/välillä. Sama kelpoisuus kuin vastaanottajahaku. messages.edit. Ei sähköposteja.';

comment on function booking._customer_message_hits(date, date, bigint[]) is
  'booking_257/258: asiakasviestin osumat. p_product_ids null = kaikki tuotteet (tuotelista); muuten rajaus. Ei public-grants.';

do $$
begin
  execute 'revoke all on function booking._customer_message_hits(date, date, bigint[]) from public, anon, authenticated';
  execute 'revoke all on function booking.admin_customer_message_products(date, date) from public, anon, authenticated';
  execute 'grant execute on function booking.admin_customer_message_products(date, date) to authenticated, service_role';
end $$;

notify pgrst, 'reload schema';
