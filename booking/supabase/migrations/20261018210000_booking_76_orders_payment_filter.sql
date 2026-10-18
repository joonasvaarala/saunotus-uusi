-- booking_76_orders_payment_filter (18.10.2026)
-- Talous-tilauslista: admin_list_orders saa p_payment_filter (oletus 'paid').
-- paid = payment_status paid|partially_refunded, nettomaksu > 0, tila ei cancelled eikä expired.
-- Nettomaksu = payments (paid|partially_refunded|refunded) − refunded_amount.
-- Ilman maksurivejä (Johku, booking_41) nettomaksu on total_gross, jos maksutila on paid tai partially_refunded.
-- unpaid = unpaid|pending|failed|partially_paid, ei cancelled eikä expired.
-- refunded = refunded|partially_refunded. cancelled = orders.status cancelled|expired.
-- all = ei tätä rajausta. p_payment_status rajaa yhä yhteen tilaan (AND).
-- Vanha 11 argumentin kutsu toimii: uusi parametri on viimeinen ja sillä on oletus.
-- Yksi funktio (vanha allekirjoitus pois), jotta PostgREST ei jää kahden version väliin.
-- Ei taulu- eikä datamuutoksia. Ei tuotantoajoa tästä tiedostosta.
-- Rollback: rollbacks/20261018210000_booking_76_ROLLBACK.sql

drop function if exists booking.admin_list_orders(text, text, text, text, boolean, text, date, date, text, integer, integer);

create or replace function booking.admin_list_orders(
  p_search text default null,
  p_status text default null,
  p_payment_status text default null,
  p_source text default null,
  p_native boolean default null,
  p_date_field text default 'created',
  p_from date default null,
  p_to date default null,
  p_sort text default 'created_desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_payment_filter text default 'paid'
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_s text := nullif(btrim(coalesce(p_search, '')), '');
  v_num bigint;
  v_like text;
  v_total int;
  v_rows jsonb;
  v_lim int := coalesce(p_limit, 50);
  v_off int := greatest(coalesce(p_offset, 0), 0);
  v_pf text := coalesce(nullif(btrim(p_payment_filter), ''), 'paid');
begin
  perform booking._require_staff();
  if p_sort is null or p_sort not in ('created_desc','created_asc','order_no_desc','order_no_asc','total_desc','total_asc','start_desc','start_asc','paid_desc','paid_asc','unpaid_desc') then
    perform booking._err('invalid_sort', 'Tuntematon lajittelu'); end if;
  if v_lim < 1 or v_lim > 200 then perform booking._err('invalid_param', 'p_limit 1–200'); end if;
  if coalesce(p_date_field, 'created') not in ('created','start') then perform booking._err('invalid_param', 'p_date_field: created|start'); end if;
  if v_pf not in ('paid','unpaid','all','refunded','cancelled') then
    perform booking._err('invalid_param', 'p_payment_filter: paid|unpaid|all|refunded|cancelled'); end if;
  if v_s ~ '^\d{1,12}$' then v_num := v_s::bigint; end if;
  if v_s is not null then v_like := '%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  with base as (
    select o.id, o.order_no, o.johku_order_no, o.created_at, o.status, o.payment_status, o.source_channel, (o.external_source is null) as is_native, o.total_gross,
           pp.paid, pp.refunded, pp.pc, pp.lp, rr.fs, rr.le, rr.cnt, rcc.rc,
           case when o.status in ('cancelled','expired','draft') then 0 else greatest(o.total_gross - (pp.paid - pp.refunded), 0) end as unpaid,
           c.id as cid, c.name as cname, c.company as ccompany, o.customer_kind
      from booking.orders o
      left join booking.customers c on c.id = o.customer_id
      left join lateral (select min(r.starts_at) fs, max(r.ends_at) le, count(*) cnt from booking.reservations r where r.order_id = o.id and r.hidden_at is null) rr on true
      left join lateral (select coalesce(sum(p.amount) filter (where p.status in ('paid','partially_refunded','refunded')), 0) paid, coalesce(sum(p.refunded_amount), 0) refunded,
                                count(*) filter (where p.status in ('paid','partially_refunded','refunded')) pc, max(p.paid_at) lp
                           from booking.payments p where p.order_id = o.id) pp on true
      left join lateral (select count(*) rc from booking.receipts x where x.order_id = o.id) rcc on true
     where (p_status is null or o.status = p_status)
       and (p_payment_status is null or o.payment_status = p_payment_status)
       and (p_source is null or o.source_channel = p_source)
       and (p_native is null or (o.external_source is null) = p_native)
       and (v_s is null or (v_num is not null and (o.order_no = v_num or o.johku_order_no = v_num))
            or (v_num is null and (c.name ilike v_like or c.email ilike v_like or c.phone ilike v_like or c.company ilike v_like)))
       and (p_from is null or case when coalesce(p_date_field, 'created') = 'created' then (o.created_at at time zone 'Europe/Helsinki')::date else (rr.fs at time zone 'Europe/Helsinki')::date end >= p_from)
       and (p_to   is null or case when coalesce(p_date_field, 'created') = 'created' then (o.created_at at time zone 'Europe/Helsinki')::date else (rr.fs at time zone 'Europe/Helsinki')::date end <= p_to)
       and case v_pf
             when 'all' then true
             when 'paid' then o.payment_status in ('paid','partially_refunded')
               and o.status not in ('cancelled','expired')
               and (case when pp.pc > 0 then pp.paid - pp.refunded
                         when o.payment_status in ('paid','partially_refunded') then o.total_gross
                         else 0 end) > 0.004
             when 'unpaid' then o.payment_status in ('unpaid','pending','failed','partially_paid')
               and o.status not in ('cancelled','expired')
             when 'refunded' then o.payment_status in ('refunded','partially_refunded')
             when 'cancelled' then o.status in ('cancelled','expired')
             else false
           end
  ), page as (
    select b.*, row_number() over (order by
        case when p_sort = 'created_asc' then b.created_at end asc, case when p_sort = 'created_desc' then b.created_at end desc,
        case when p_sort = 'order_no_asc' then b.order_no end asc, case when p_sort = 'order_no_desc' then b.order_no end desc,
        case when p_sort = 'total_asc' then b.total_gross end asc, case when p_sort = 'total_desc' then b.total_gross end desc,
        case when p_sort = 'start_asc' then b.fs end asc nulls last, case when p_sort = 'start_desc' then b.fs end desc nulls last,
        case when p_sort = 'paid_asc' then b.lp end asc nulls last, case when p_sort = 'paid_desc' then b.lp end desc nulls last,
        case when p_sort = 'unpaid_desc' then b.unpaid end desc, b.id desc) as rn
      from base b
  )
  select (select count(*) from base),
         coalesce(jsonb_agg(jsonb_build_object('order_id', p.id, 'order_no', p.order_no, 'johku_order_no', p.johku_order_no, 'created_at', p.created_at, 'status', p.status,
           'payment_status', p.payment_status, 'source_channel', p.source_channel, 'is_native', p.is_native, 'total', p.total_gross, 'paid', p.paid, 'refunded', p.refunded,
           'unpaid', p.unpaid, 'customer_id', p.cid, 'customer_name', p.cname, 'customer_company', p.ccompany, 'customer_kind', p.customer_kind, 'first_start', p.fs, 'last_end', p.le,
           'reservation_count', p.cnt, 'payment_count', p.pc, 'last_paid_at', p.lp, 'receipt_count', p.rc) order by p.rn), '[]'::jsonb)
    into v_total, v_rows from page p where p.rn > v_off and p.rn <= v_off + v_lim;
  return jsonb_build_object('total', v_total, 'rows', v_rows);
end $function$;

comment on function booking.admin_list_orders(text, text, text, text, boolean, text, date, date, text, integer, integer, text) is
  'Talous-tilauslista. p_payment_filter oletus paid (paid|partially_refunded, netto>0, ei cancelled/expired). all = koko kanta. booking_76.';

revoke all on function booking.admin_list_orders(text, text, text, text, boolean, text, date, date, text, integer, integer, text) from public, anon, authenticated;
grant execute on function booking.admin_list_orders(text, text, text, text, boolean, text, date, date, text, integer, integer, text) to service_role;
grant execute on function booking.admin_list_orders(text, text, text, text, boolean, text, date, date, text, integer, integer, text) to authenticated;
