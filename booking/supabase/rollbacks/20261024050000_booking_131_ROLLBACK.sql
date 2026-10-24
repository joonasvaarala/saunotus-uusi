-- booking_131 rollback: palauta checkout-tilalogiikka booking_70:n mukaiseksi.
set local lock_timeout = '5s';

create or replace function booking._checkout_state_json(p_order bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o booking.orders; v_hold timestamptz; v_due numeric; v_net numeric; v_inflight boolean; v_state text; v_open boolean; v_reason text;
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
  v_reason := null;
  if o.status = 'cancelled' then
    select case when bool_or(r.cancel_reason = 'hold_expired')
                 and not coalesce(bool_or(r.status in ('pending', 'confirmed', 'completed')), false)
                then 'hold_expired' end
      into v_reason
      from booking.reservations r
     where r.order_id = o.id;
  end if;
  return jsonb_build_object(
    'checkout_state', v_state,
    'awaiting_payment', v_state in ('awaiting_payment', 'processing_payment'),
    'hold_kind', case when o.status = 'pending' then o.hold_kind end,
    'hold_expires_at', case when o.status = 'pending' then v_hold end,
    'seconds_left', case when o.status = 'pending' and v_open then greatest(floor(extract(epoch from (coalesce(v_hold, now()) - now())))::int, 0) end,
    'server_now', now(),
    'remaining_amount', v_due,
    'payment_in_progress', v_inflight,
    'cancel_reason', v_reason);
end $$;

do $rollback$
declare
  v_old text := $$v_status := case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end;$$;
  v_new text := $$v_status := case when o.status = 'pending' and exists (select 1 from booking.reservations r where r.order_id = o.id) and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end;$$;
  v_ddl text;
begin
  select pg_get_functiondef('booking.public_get_order(uuid)'::regprocedure) into v_ddl;
  if position(v_old in v_ddl) > 0 then return; end if;
  if position(v_new in v_ddl) = 0 then
    raise exception 'booking_131 rollback: public_get_order vanhenemisehto muuttunut, palautus ei ole turvallinen';
  end if;
  execute replace(v_ddl, v_new, v_old);
end
$rollback$;

revoke all on function booking._checkout_state_json(bigint) from public, anon, authenticated;
