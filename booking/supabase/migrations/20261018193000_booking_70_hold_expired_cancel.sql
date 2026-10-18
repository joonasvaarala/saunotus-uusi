-- booking_70: maksamattoman pidon vanheneminen peruu tilauksen (status cancelled, varauksen cancel_reason hold_expired).
-- Löydös (ei muuteta tässä): booking._res_active on epätosi tilalle expired ja pidolle jonka hold_expires_at on ohi,
-- joten expired EI kuluta poolikapasiteettia, claim-päällekkäisyyttä (v_claims + _res_active), admin-päivän henkilöitä
-- eikä (PR #68) päivän tuottoa. Exclusive-gist sisältää yhä pending-rivin kunnes tämä funktio ajaa; varaustrigger
-- kutsuu _expire_holds ennen tarkistusta. Roikkuva osa on itse status 'expired': rivi jää listoihin ja
-- payment_mark_paid / mobilepay_payment_confirmable kohtelevat expired-varausta yhä vahvistettavana.
-- Tämä migraatio ei muuta maksun, lahjakortin lunastuksen eikä sähköpostin lähetystä. Vanhentuneelle ei jonoteta viestiä
-- (orders_confirmed_mail_trg laukeaa vain status → confirmed). resend pysyy dry_run.
-- Kertasiivous: vain varsinainen kassapito (external_source is null AND hold_kind is not null) JA status=expired
-- JA payment_status unpaid|pending, ei kuitteja, ei oikeaa maksettua maksua, ei confirmed/completed-varausta,
-- ei kesken olevaa MobilePayta. Johku-tuonti (external_source) ja hold_kind-tyhjät rivit jäävät ennalleen.
-- Tilausriviä ei poisteta.
-- Rollback: rollbacks/20261018193000_booking_70_ROLLBACK.sql
set local lock_timeout = '5s';

create or replace function booking._checkout_state_json(p_order bigint) returns jsonb language plpgsql stable security definer set search_path = '' as $$
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

-- Sama kelpoisuus kuin booking_53: pending-pito jonka hold_expires_at on ohi, ei kesken olevaa MobilePayta (grace).
-- Lopputila on cancelled + cancel_reason hold_expired (ei expired). Lahjakorttiosuudet vapauttaa nykyinen
-- _checkout_release_gift_cards. Avoin pending-maksu perutaan kuten public_cancel_booking. Ei sähköpostia.
create or replace function booking._expire_holds(p_space bigint default null, p_except bigint default null) returns integer language plpgsql security definer set search_path = '' as $$
declare n integer; v_res_orders bigint[]; v_orders bigint[]; v_maxwait int := booking._checkout_cfg_int('checkout_mobilepay_max_wait_minutes', 30, 0, 120);
begin
  with e as (
    update booking.reservations r
       set status = 'cancelled', cancelled_at = coalesce(r.cancelled_at, now()), cancel_reason = coalesce(r.cancel_reason, 'hold_expired')
     where r.status = 'pending' and r.hold_expires_at <= now()
       and (p_space is null or r.space_id = p_space)
       and r.id is distinct from p_except
       and not (booking._order_mp_inflight(r.order_id) and r.hold_expires_at > now() - make_interval(mins => v_maxwait))
    returning r.order_id
  )
  select count(*), coalesce(array_agg(distinct order_id), '{}') into n, v_res_orders from e;
  if n = 0 then return 0; end if;
  with o as (
    update booking.orders o set status = 'cancelled', cancelled_at = coalesce(o.cancelled_at, now())
     where o.id = any (v_res_orders) and o.status = 'pending' and o.payment_status in ('unpaid', 'pending', 'partially_paid')
       and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status in ('pending', 'confirmed'))
       and not exists (select 1 from booking.payments p where p.order_id = o.id and p.status in ('paid', 'partially_refunded', 'refunded')
                          and not (p.method = 'gift_card' and not exists (select 1 from booking.receipts rc where rc.payment_id = p.id)))
    returning o.id
  )
  select coalesce(array_agg(id), '{}') into v_orders from o;
  if cardinality(v_orders) > 0 then
    update booking.payments set status = 'cancelled' where order_id = any (v_orders) and status = 'pending';
    perform booking._checkout_release_gift_cards(v_orders);
  end if;
  return n;
end $$;

-- Kertasiivous jo vanhentuneille maksamattomille kassapidoille. Idempotentti: vain status=expired,
-- external_source is null, hold_kind is not null, leima external_meta.booking_70.
-- Ei koske Johku-tuontia, hold_kind-tyhjää riviä, maksettua, kuitillista, partially_paid, confirmed/completed-varausta eikä MobilePay-kesken -tilausta.
-- Ei poista tilausta. Ei jonota sähköpostia.
create or replace function booking._cancel_unpaid_expired_orders() returns integer language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_n int; n int := 0; v_ids bigint[] := '{}';
begin
  for v_id in
    select o.id from booking.orders o
     where o.status = 'expired'
       and o.payment_status in ('unpaid', 'pending')
       and o.external_source is null
       and o.hold_kind is not null
       and not exists (select 1 from booking.receipts rc where rc.order_id = o.id)
       and not exists (
         select 1 from booking.payments p
          where p.order_id = o.id and p.status in ('paid', 'partially_refunded', 'refunded')
            and not (p.method = 'gift_card' and not exists (select 1 from booking.receipts rc where rc.payment_id = p.id)))
       and not exists (select 1 from booking.reservations r where r.order_id = o.id and r.status in ('confirmed', 'completed'))
       and not booking._order_mp_inflight(o.id)
       and not (coalesce(o.external_meta, '{}'::jsonb) ? 'booking_70')
     order by o.id
     for update of o
  loop
    update booking.reservations r
       set status = 'cancelled',
           cancelled_at = coalesce(r.cancelled_at, now()),
           cancel_reason = coalesce(r.cancel_reason, 'hold_expired'),
           external_meta = coalesce(r.external_meta, '{}'::jsonb) || jsonb_build_object('booking_70', jsonb_build_object(
             'prev_status', r.status, 'prev_cancel_reason', r.cancel_reason, 'prev_cancelled_at', r.cancelled_at))
     where r.order_id = v_id and r.status in ('expired', 'pending')
       and not (coalesce(r.external_meta, '{}'::jsonb) ? 'booking_70');
    update booking.payments p
       set status = 'cancelled',
           raw = coalesce(case when jsonb_typeof(p.raw) = 'object' then p.raw end, '{}'::jsonb)
                || jsonb_build_object('booking_70', jsonb_build_object('prev_status', p.status))
     where p.order_id = v_id and p.status = 'pending'
       and not (coalesce(case when jsonb_typeof(p.raw) = 'object' then p.raw end, '{}'::jsonb) ? 'booking_70');
    update booking.orders o
       set status = 'cancelled',
           cancelled_at = coalesce(o.cancelled_at, now()),
           external_meta = coalesce(o.external_meta, '{}'::jsonb) || jsonb_build_object('booking_70', jsonb_build_object(
             'prev_status', o.status, 'prev_cancelled_at', o.cancelled_at, 'prev_payment_status', o.payment_status, 'at', now()))
     where o.id = v_id and o.status = 'expired'
       and o.external_source is null and o.hold_kind is not null;
    get diagnostics v_n = row_count;
    if v_n = 1 then n := n + 1; v_ids := v_ids || v_id; end if;
  end loop;
  if n > 0 then perform booking._checkout_release_gift_cards(v_ids); end if;
  return n;
end $$;

revoke all on function booking._checkout_state_json(bigint) from public, anon, authenticated;
revoke all on function booking._cancel_unpaid_expired_orders() from public, anon, authenticated;

do $cleanup$
declare n int;
begin
  n := booking._cancel_unpaid_expired_orders();
  raise notice 'booking_70: peruutettu maksamattomia vanhentuneita kassapitoja: %', n;
end
$cleanup$;
