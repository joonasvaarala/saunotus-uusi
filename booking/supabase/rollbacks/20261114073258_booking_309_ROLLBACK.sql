-- booking_309 ROLLBACK: palauttaa expire_holds- ja admin_get_customer-funktiot booking_308-tilaan
-- (md5 e8a677d847de8669ef8a4070c95abfdd, 3753915f420e2819699a1d08a64e4857), purkaa booking_309:n automaattiset arkistoinnit
-- (orders.archive_reason = 'auto:expired_unpaid' + external_meta.booking_309: tila/maksutila/cancelled_at takaisin, varausten hidden_at 'expired_unpaid_auto' pois)
-- ja poistaa uudet funktiot, asetuksen ja indeksin. late_paid_archived-hälytysrivit jätetään (historiaa). Myöhään maksetun tilauksen purku jätetään väliin
-- (se on käsiteltävä käsin) ja raportoidaan noticena.
set local lock_timeout = '5s';
do $pre$
begin
  if to_regprocedure('booking.expired_web_orders_archive_sweep(integer)') is null then raise exception 'booking_309 ROLLBACK: booking_309 ei ole ajettu. Ei muutoksia.'; end if;
end $pre$;

do $un$
declare n int; m int;
begin
  select count(*) into m from booking.orders o where o.archive_reason = 'auto:expired_unpaid' and o.external_meta ? 'booking_309'
     and exists (select 1 from booking.payments p where p.order_id = o.id and p.status in ('paid','partially_refunded','refunded'));
  update booking.reservations r set hidden_at = null, hidden_reason = null
   where r.hidden_reason = 'expired_unpaid_auto'
     and r.order_id in (select o.id from booking.orders o where o.archive_reason = 'auto:expired_unpaid' and o.external_meta ? 'booking_309'
                          and not exists (select 1 from booking.payments p where p.order_id = o.id and p.status in ('paid','partially_refunded','refunded')));
  update booking.orders o
     set status = coalesce(o.external_meta #>> '{booking_309,prev_status}', o.status),
         payment_status = coalesce(o.external_meta #>> '{booking_309,prev_payment_status}', o.payment_status),
         cancelled_at = (o.external_meta #>> '{booking_309,prev_cancelled_at}')::timestamptz,
         archived_at = null, archived_by = null, archive_reason = null,
         external_meta = o.external_meta - 'booking_309'
   where o.archive_reason = 'auto:expired_unpaid' and o.external_meta ? 'booking_309'
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

drop function if exists booking.expired_web_orders_archive_sweep(integer);
drop function if exists booking._expired_web_order_archivable(bigint);
drop index if exists booking.orders_expired_web_309_idx;
delete from booking.settings where key = 'expired_unpaid_auto_archive_paused';
