-- ROLLBACK booking_70: palauttaa _expire_holds ja _checkout_state_json booking_53-tilaan.
-- Kertasiivouksen leimaamat rivit (external_meta.booking_70 / payments.raw.booking_70) palautetaan vain jos ne ovat yhä cancelled
-- ja tilaus on varsinainen kassapito (external_source is null AND hold_kind is not null). Johku-tuontia ei palautella.
-- Lahjakortin palautuskirjauksia ei peruta (ne vastaavat jo booking_53:n vanhenemista; ei kynnetä saldoa takaisin).
-- Ajonaikaiset vanhenemiset migraation jälkeen eivät saa leimaa, eikä niitä palauteta expired-tilaan.
set local lock_timeout = '5s';

update booking.reservations r
   set status = r.external_meta -> 'booking_70' ->> 'prev_status',
       cancel_reason = r.external_meta -> 'booking_70' ->> 'prev_cancel_reason',
       cancelled_at = (r.external_meta -> 'booking_70' ->> 'prev_cancelled_at')::timestamptz,
       external_meta = r.external_meta - 'booking_70'
 where r.external_meta ? 'booking_70'
   and r.status = 'cancelled'
   and r.external_meta -> 'booking_70' ->> 'prev_status' in ('expired', 'pending')
   and exists (
     select 1 from booking.orders o
      where o.id = r.order_id and o.external_source is null and o.hold_kind is not null);

update booking.payments p
   set status = p.raw -> 'booking_70' ->> 'prev_status',
       raw = case when (p.raw - 'booking_70') = '{}'::jsonb then null else p.raw - 'booking_70' end
 where jsonb_typeof(p.raw) = 'object' and p.raw ? 'booking_70'
   and p.status = 'cancelled'
   and p.raw -> 'booking_70' ->> 'prev_status' = 'pending'
   and exists (
     select 1 from booking.orders o
      where o.id = p.order_id and o.external_source is null and o.hold_kind is not null);

update booking.orders o
   set status = 'expired',
       cancelled_at = (o.external_meta -> 'booking_70' ->> 'prev_cancelled_at')::timestamptz,
       external_meta = o.external_meta - 'booking_70'
 where o.external_meta ? 'booking_70'
   and o.status = 'cancelled'
   and o.external_meta -> 'booking_70' ->> 'prev_status' = 'expired'
   and o.external_source is null
   and o.hold_kind is not null;

create or replace function booking._checkout_state_json(p_order bigint) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o booking.orders; v_hold timestamptz; v_due numeric; v_net numeric; v_inflight boolean; v_state text; v_open boolean;
begin
  select * into o from booking.orders where id = p_order;
  if not found then return '{}'::jsonb; end if;
  select min(r.hold_expires_at) filter (where r.hold_expires_at > now()) into v_hold from booking.reservations r where r.order_id = o.id and r.status = 'pending';
  select coalesce(sum(p.amount) filter (where p.status in ('paid', 'partially_refunded', 'refunded')), 0) - coalesce(sum(p.refunded_amount), 0)
    into v_net from booking.payments p where p.order_id = o.id;
  v_due := case when o.status in ('cancelled', 'expired', 'draft') then 0 else greatest(o.total_gross - v_net, 0) end;
  v_inflight := o.status = 'pending' and booking._order_mp_inflight(o.id);
  v_open := o.status = 'pending' and (v_hold is not null or v_inflight);
  v_state := case
    when o.status in ('cancelled', 'draft') then o.status
    when o.status = 'expired' then 'expired'
    when o.status = 'pending' and not v_open then 'expired'
    when o.status = 'pending' and o.hold_kind = 'preliminary' then 'preliminary'
    when o.status = 'pending' and v_inflight then 'processing_payment'
    when o.status = 'pending' then 'awaiting_payment'
    when v_due > 0.004 then 'confirmed_unpaid'
    else 'confirmed' end;
  return jsonb_build_object(
    'checkout_state', v_state,
    'awaiting_payment', v_state in ('awaiting_payment', 'processing_payment'),
    'hold_kind', case when o.status = 'pending' then o.hold_kind end,
    'hold_expires_at', case when o.status = 'pending' then v_hold end,
    'seconds_left', case when o.status = 'pending' and v_open then greatest(floor(extract(epoch from (coalesce(v_hold, now()) - now())))::int, 0) end,
    'server_now', now(),
    'remaining_amount', v_due,
    'payment_in_progress', v_inflight);
end $$;

create or replace function booking._expire_holds(p_space bigint default null, p_except bigint default null) returns integer language plpgsql security definer set search_path = '' as $$
declare n integer; v_res_orders bigint[]; v_orders bigint[]; v_maxwait int := booking._checkout_cfg_int('checkout_mobilepay_max_wait_minutes', 30, 0, 120);
begin
  with e as (
    update booking.reservations r
       set status = 'expired', cancelled_at = coalesce(r.cancelled_at, now()), cancel_reason = coalesce(r.cancel_reason, 'hold_expired')
     where r.status = 'pending' and r.hold_expires_at <= now()
       and (p_space is null or r.space_id = p_space)
       and r.id is distinct from p_except
       and not (booking._order_mp_inflight(r.order_id) and r.hold_expires_at > now() - make_interval(mins => v_maxwait))
    returning r.order_id
  )
  select count(*), coalesce(array_agg(distinct order_id), '{}') into n, v_res_orders from e;
  if n = 0 then return 0; end if;
  with o as (
    update booking.orders o set status = 'expired'
     where o.id = any (v_res_orders) and o.status = 'pending' and o.payment_status in ('unpaid', 'pending', 'partially_paid')
       and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status in ('pending', 'confirmed'))
       and not exists (select 1 from booking.payments p where p.order_id = o.id and p.status in ('paid', 'partially_refunded', 'refunded')
                          and not (p.method = 'gift_card' and not exists (select 1 from booking.receipts rc where rc.payment_id = p.id)))
    returning o.id
  )
  select coalesce(array_agg(id), '{}') into v_orders from o;
  if cardinality(v_orders) > 0 then perform booking._checkout_release_gift_cards(v_orders); end if;
  return n;
end $$;

revoke all on function booking._checkout_state_json(bigint) from public, anon, authenticated;
drop function if exists booking._cancel_unpaid_expired_orders();
