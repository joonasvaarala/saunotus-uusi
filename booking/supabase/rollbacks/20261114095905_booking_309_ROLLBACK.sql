-- booking_309 ROLLBACK: palauttaa expire_holds-, admin_get_customer-, admin_list_customers- ja admin_search_customers-funktiot booking_308-tilaan
-- (md5 e8a677d847de8669ef8a4070c95abfdd, 3753915f420e2819699a1d08a64e4857), purkaa booking_309:n automaattiset arkistoinnit
-- (orders.archive_reason = 'auto:expired_unpaid' + external_meta.booking_309: tila/maksutila/cancelled_at takaisin, varausten hidden_at 'expired_unpaid_auto' pois)
-- ja asiakaspiilotukset (customers.archived_at/archive_reason poistetaan) sekä poistaa uudet funktiot, asetuksen ja indeksit. late_paid_archived-hälytysrivit jätetään (historiaa). Myöhään maksetun tilauksen purku jätetään väliin
-- (se on käsiteltävä käsin) ja raportoidaan noticena.
set local lock_timeout = '5s';
do $pre$
begin
  if to_regprocedure('booking.expired_web_orders_archive_sweep(integer)') is null then raise exception 'booking_309 ROLLBACK: booking_309 ei ole ajettu. Ei muutoksia.'; end if;
end $pre$;

do $un$
declare n int; m int;
begin
  select count(*) into m from booking.orders o where o.archive_reason in ('auto:expired_unpaid', 'auto:customer_cancelled_unpaid') and o.external_meta ? 'booking_309'
     and exists (select 1 from booking.payments p where p.order_id = o.id and p.status in ('paid','partially_refunded','refunded'));
  update booking.reservations r set hidden_at = null, hidden_reason = null
   where r.hidden_reason = 'expired_unpaid_auto'
     and r.order_id in (select o.id from booking.orders o where o.archive_reason in ('auto:expired_unpaid', 'auto:customer_cancelled_unpaid') and o.external_meta ? 'booking_309'
                          and not exists (select 1 from booking.payments p where p.order_id = o.id and p.status in ('paid','partially_refunded','refunded')));
  update booking.customers set archived_at = null, archive_reason = null where archive_reason = 'auto:only_archived_unpaid_orders';
  update booking.orders o
     set status = coalesce(o.external_meta #>> '{booking_309,prev_status}', o.status),
         payment_status = coalesce(o.external_meta #>> '{booking_309,prev_payment_status}', o.payment_status),
         cancelled_at = (o.external_meta #>> '{booking_309,prev_cancelled_at}')::timestamptz,
         archived_at = null, archived_by = null, archive_reason = null,
         external_meta = o.external_meta - 'booking_309'
   where o.archive_reason in ('auto:expired_unpaid', 'auto:customer_cancelled_unpaid') and o.external_meta ? 'booking_309'
     and not exists (select 1 from booking.payments p where p.order_id = o.id and p.status in ('paid','partially_refunded','refunded'));
  get diagnostics n = row_count;
  raise notice 'booking_309 ROLLBACK: % arkistointia purettu, % myöhään maksettua jätetty arkistoiduksi (käsittele käsin)', n, m;
end $un$;

CREATE OR REPLACE FUNCTION booking.expire_holds()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n integer;
begin
  n := booking._expire_holds(null);
  delete from booking.rate_limit_hits where at < now() - interval '2 days';
  return n;
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_get_customer(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c booking.customers;
begin
  perform booking._require_staff();
  select * into c from booking.customers where id = p_id;
  if not found then perform booking._err('not_found', 'Asiakasta ei löydy'); end if;
  return to_jsonb(c) - 'unsubscribe_token' - 'customer_type_is_staff' || jsonb_build_object(
    'annual_cards', coalesce((select jsonb_agg(to_jsonb(ac) - 'created_by' - 'revoked_by' order by ac.valid_from desc) from booking.annual_cards ac where ac.customer_id = c.id), '[]'::jsonb),
    'orders', coalesce((
    select jsonb_agg(jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'status', o.status, 'payment_status', o.payment_status,
        'total', o.total_gross, 'created_at', o.created_at, 'channel', o.source_channel,
        'reservations', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'starts_at', r.starts_at, 'persons', r.persons, 'status', r.status,
              'product_name', coalesce(it.product_name, '')) order by r.starts_at), '[]'::jsonb)
              from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id and r.hidden_at is null))
      order by o.created_at desc) from booking.orders o where o.customer_id = c.id), '[]'::jsonb))
  -- booking_278 (H): asiakasnäkymän tunnusluvut, avoin saldo ja ostetut lahjakortit (koodit maskattuna). Vain lukua.
  || jsonb_build_object(
    'open_balance', coalesce((select sum(b.unpaid) from (select (booking._order_balance(o.id) ->> 'unpaid')::numeric unpaid
        from booking.orders o where o.customer_id = c.id and o.status not in ('cancelled','expired','draft')) b), 0),
    'open_orders', (select count(*) from (select (booking._order_balance(o.id) ->> 'unpaid')::numeric unpaid
        from booking.orders o where o.customer_id = c.id and o.status not in ('cancelled','expired','draft')) b where b.unpaid > 0.004),
    'stats', (select jsonb_build_object(
        'orders', (select count(*) from booking.orders o where o.customer_id = c.id),
        'first_order_at', (select min(o.created_at) from booking.orders o where o.customer_id = c.id),
        'visits', count(*) filter (where r.status = 'completed' or (r.checkin_at is not null and r.status not in ('cancelled','no_show'))),
        'last_visit', max(r.starts_at) filter (where r.status = 'completed' or (r.checkin_at is not null and r.status not in ('cancelled','no_show'))),
        'upcoming', count(*) filter (where r.status in ('pending','confirmed') and r.starts_at > now()),
        'next_at', min(r.starts_at) filter (where r.status in ('pending','confirmed') and r.starts_at > now()),
        'no_show', count(*) filter (where r.status = 'no_show'),
        'last_no_show', max(r.starts_at) filter (where r.status = 'no_show'))
        from booking.reservations r join booking.orders o on o.id = r.order_id
       where o.customer_id = c.id and r.hidden_at is null),
    'gift_cards', jsonb_build_object(
        'bought', coalesce((select jsonb_agg(x.obj order by x.created_at desc) from (
            select g.created_at, jsonb_build_object('id', g.id, 'code_masked', '****-****-' || right(g.code, 4), 'kind', g.kind,
              'initial_amount', g.initial_amount, 'balance', g.balance, 'valid_to', g.valid_to, 'status', g.status, 'created_at', g.created_at) obj
              from booking.gift_cards g where g.buyer_customer_id = c.id order by g.created_at desc limit 50) x), '[]'::jsonb),
        'bought_count', (select count(*) from booking.gift_cards g where g.buyer_customer_id = c.id),
        'bought_total', coalesce((select sum(g.initial_amount) from booking.gift_cards g where g.buyer_customer_id = c.id), 0),
        'redeemed_count', (select count(distinct l.gift_card_id) from booking.gift_card_ledger l join booking.orders o on o.id = l.order_id
                            where o.customer_id = c.id and l.delta < 0)));
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_list_customers(p_search text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(id bigint, name text, email text, phone text, company text, city text, marketing_consent boolean, marketing_consent_at timestamp with time zone, created_at timestamp with time zone, orders_count bigint, last_visit timestamp with time zone, total_count bigint, customer_type text, customer_kind text, business_id text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform booking._require_staff();
  return query
    select c.id, c.name, c.email, c.phone, c.company, c.city, c.marketing_consent, c.marketing_consent_at, c.created_at,
           (select count(*) from booking.orders o where o.customer_id = c.id and o.status in ('pending','confirmed','completed')),
           (select max(r.starts_at) from booking.reservations r join booking.orders o on o.id = r.order_id
             where o.customer_id = c.id and r.status in ('confirmed','completed')),
           count(*) over (), c.customer_type, c.customer_kind, c.business_id
      from booking.customers c
     where c.anonymized_at is null
       and (q is null or c.name ilike '%' || q || '%' or c.email ilike '%' || q || '%' or c.phone ilike '%' || q || '%' or c.company ilike '%' || q || '%'
            or c.business_id ilike '%' || q || '%')
     order by c.created_at desc, c.id desc
     limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_search_customers(p_search text DEFAULT NULL::text, p_limit integer DEFAULT 8)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_s text := nullif(btrim(coalesce(p_search, '')), '');
  v_like text; v_digits text; v_norm text;
  v_lim int := least(greatest(coalesce(p_limit, 8), 1), 20);
begin
  perform booking._require_staff();
  if v_s is null or char_length(v_s) < 2 then return '[]'::jsonb; end if;
  v_like := lower('%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%');
  v_digits := nullif(regexp_replace(v_s, '\D', '', 'g'), '');
  v_norm := booking._norm_business_id(v_s);
  if v_norm is not null and not booking._business_id_ok(v_norm) then v_norm := null; end if;
  return coalesce((
    with cust as (
      select 0 as sort, c.created_at as ts, c.id as sid,
             booking._norm_business_id(c.business_id) as nbid, lower(nullif(btrim(c.company), '')) as lco,
             jsonb_build_object(
               'source', 'customer', 'id', c.id, 'customer_id', c.id, 'name', c.name, 'email', c.email, 'phone', c.phone,
               'company', c.company, 'business_id', c.business_id, 'customer_kind', c.customer_kind, 'customer_type', c.customer_type,
               'street', nullif(btrim(c.address), ''), 'zip', nullif(btrim(c.zip), ''), 'city', nullif(btrim(c.city), ''), 'country', c.country,
               'einvoice_address', c.einvoice_address, 'einvoice_operator', c.einvoice_operator, 'invoice_reference', c.invoice_reference
             ) as row
        from booking.customers c
       where c.anonymized_at is null
         and (lower(c.name) like v_like escape '\'
              or lower(coalesce(c.email, '')) like v_like escape '\'
              or lower(coalesce(c.phone, '')) like v_like escape '\'
              or lower(coalesce(c.company, '')) like v_like escape '\'
              or lower(coalesce(c.business_id, '')) like v_like escape '\'
              or (v_norm is not null and booking._norm_business_id(c.business_id) = v_norm)
              or (v_digits is not null and char_length(v_digits) >= 2
                  and regexp_replace(coalesce(c.business_id, ''), '\D', '', 'g') like '%' || v_digits || '%'))
       order by c.created_at desc, c.id desc
       limit v_lim
    ),
    comp as (
      select 1 as sort, h.last_order_at as ts, h.customer_id as sid,
             jsonb_build_object(
               'source', 'orders', 'id', null, 'customer_id', h.customer_id, 'name', h.contact_name, 'email', h.email, 'phone', h.phone,
               'company', h.company, 'business_id', h.business_id, 'customer_kind', 'company', 'customer_type', null,
               'street', h.street, 'zip', h.zip, 'city', h.city, 'country', h.country,
               'einvoice_address', h.einvoice_address, 'einvoice_operator', h.einvoice_operator,
               'orders_count', h.orders_count, 'last_order_at', h.last_order_at
             ) as row
        from booking._order_company_hits(v_s, v_lim) h
       where not exists (
         select 1 from cust x
          where (h.business_id is not null and x.nbid is not null and x.nbid = booking._norm_business_id(h.business_id))
             or (x.lco is not null and x.lco = lower(h.company))
       )
    )
    select jsonb_agg(u.row order by u.sort, u.ts desc, u.sid)
      from (select sort, ts, sid, row from cust union all select sort, ts, sid, row from comp) u
  ), '[]'::jsonb);
end $function$;

drop function if exists booking.expired_web_orders_archive_sweep(integer);
drop function if exists booking._customer_archivable(bigint);
drop index if exists booking.customers_archived_309_idx;
alter table booking.customers drop column if exists archived_at, drop column if exists archive_reason;
drop function if exists booking._expired_web_order_archivable(bigint);
drop index if exists booking.orders_expired_web_309_idx;
delete from booking.settings where key = 'expired_unpaid_auto_archive_paused';
