-- booking_136: hallinnan hyvitys ↔ peruutus.
-- * admin_refund_order: tilauksen maksun hyvitys (admin_refund ennallaan) + valinnainen tilauksen varausten peruutus samassa transaktiossa.
-- * admin_reservation_refund_preview: varauksen osuus maksuista (varauksen rivi + sen lisäpalvelut), aiemmat (osa)hyvitykset ja
--   käsittelyssä olevat hyvitykset vähennettynä; ei koskaan yli maksetun.
-- * admin_cancel_reservation: varauksen peruutus (admin_set_reservation_status ennallaan) + valinnainen varauksen osuuden hyvitys
--   admin_refundilla (rivijako p_lines) samassa transaktiossa.
-- Hyvitysoikeus ennallaan: payments.refund (admin, manager); peruutus: bookings.manage. Olemassa olevia funktioita ei muuteta,
-- ei taulumuutoksia, ei public-skeemaa, ei jonotuslistan funktioita. Uudelleenajettava.
-- Rollback: booking/supabase/rollbacks/20261024090000_booking_136_ROLLBACK.sql
set local lock_timeout = '5s';

-- Varauksen osuus maksuista. Palauttaa { reservation_id, order_id, status, total, unallocated, payments:[{payment_id, provider, method,
-- gift_card, online_off, amount, lines:[{payment_line_id, amount}]}] }. Rivit: varauksen order_item + sen lapsirivit (lisäpalvelut, parent_item_id).
-- Hyvitettävissä rivillä = amount_gross - refunded_gross - käsittelyssä olevat (requested/processing) hyvitykset rivillä;
-- maksulla enintään amount - refunded_amount - käsittelyssä olevat (sama raja kuin admin_refundissa).
-- online_off = verkkomaksu, jonka integraatio on pois päältä: admin_refund hylkää (hyvitys maksupalvelun portaalissa + käsinkirjaus Talous-näkymässä).
create or replace function booking._reservation_refund_plan(p_reservation_id bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  r booking.reservations; o booking.orders; p record; l record;
  v_items bigint[]; v_pending numeric; v_cap numeric; v_net numeric; v_amt numeric; v_left numeric; v_use numeric;
  v_lines jsonb; v_out jsonb := '[]'::jsonb; v_total numeric := 0; v_unalloc int := 0;
begin
  select * into r from booking.reservations where id = p_reservation_id;
  if not found then return null; end if;
  select * into o from booking.orders where id = r.order_id;
  if r.order_item_id is null or o.external_source is not null then
    return jsonb_build_object('reservation_id', r.id, 'order_id', r.order_id, 'status', r.status, 'total', 0, 'unallocated', 0, 'payments', '[]'::jsonb);
  end if;
  select array_agg(i.id order by i.id) into v_items from booking.order_items i
   where i.order_id = r.order_id and (i.id = r.order_item_id or i.parent_item_id = r.order_item_id);
  for p in select * from booking.payments x where x.order_id = r.order_id and x.status in ('paid','partially_refunded')
             and x.external_source is null order by x.id loop
    if not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id) then v_unalloc := v_unalloc + 1; continue; end if;
    v_pending := coalesce((select sum(f.amount) from booking.refunds f where f.payment_id = p.id and f.status in ('requested','processing')), 0);
    v_cap := p.amount - p.refunded_amount - v_pending;
    select coalesce(sum(c.cap), 0) into v_net from (
      select pl.amount_gross - pl.refunded_gross - coalesce((select sum((x ->> 'amount')::numeric) from booking.refunds f, jsonb_array_elements(coalesce(f.lines, '[]'::jsonb)) x
              where f.payment_id = p.id and f.status in ('requested','processing') and (x ->> 'payment_line_id')::bigint = pl.id), 0) as cap
        from booking.payment_lines pl where pl.payment_id = p.id and pl.order_item_id = any(v_items)) c;
    v_amt := round(least(v_net, v_cap), 2);
    if v_amt <= 0 then continue; end if;
    v_left := v_amt; v_lines := '[]'::jsonb;
    for l in select pl.id, pl.amount_gross - pl.refunded_gross - coalesce((select sum((x ->> 'amount')::numeric) from booking.refunds f, jsonb_array_elements(coalesce(f.lines, '[]'::jsonb)) x
                     where f.payment_id = p.id and f.status in ('requested','processing') and (x ->> 'payment_line_id')::bigint = pl.id), 0) as cap
               from booking.payment_lines pl where pl.payment_id = p.id and pl.order_item_id = any(v_items) order by pl.id loop
      exit when v_left <= 0.004;
      continue when l.cap <= 0;
      v_use := least(l.cap, v_left);
      v_lines := v_lines || jsonb_build_object('payment_line_id', l.id, 'amount', v_use);
      v_left := v_left - v_use;
    end loop;
    if v_left > 0.004 then v_amt := v_amt - v_left; end if;
    if v_amt <= 0 then continue; end if;
    v_out := v_out || jsonb_build_object('payment_id', p.id, 'provider', p.provider, 'method', p.method, 'gift_card', p.gift_card_id is not null,
      'online_off', p.provider <> 'manual' and coalesce((select c.mode from booking.integration_config c where c.key = replace(p.provider, '_', '')), 'off') = 'off',
      'amount', v_amt, 'lines', v_lines);
    v_total := v_total + v_amt;
  end loop;
  return jsonb_build_object('reservation_id', r.id, 'order_id', r.order_id, 'status', r.status, 'total', v_total, 'unallocated', v_unalloc, 'payments', v_out);
end $$;
revoke all on function booking._reservation_refund_plan(bigint) from public, anon, authenticated;

create or replace function booking.admin_reservation_refund_preview(p_reservation_id bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform booking._require_permission('payments.refund');
  v := booking._reservation_refund_plan(p_reservation_id);
  if v is null then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  return v || jsonb_build_object('ok', true);
end $$;
revoke all on function booking.admin_reservation_refund_preview(bigint) from public, anon;
grant execute on function booking.admin_reservation_refund_preview(bigint) to authenticated, service_role;

-- Varauksen peruutus + valinnainen hyvitys. Oletus p_refund = false (turvallinen: ei rahaliikettä).
create or replace function booking.admin_cancel_reservation(p_reservation_id bigint, p_reason text default null,
  p_refund boolean default false, p_refund_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r booking.reservations; v_plan jsonb; x jsonb; v_res jsonb; v_out jsonb := '[]'::jsonb; v_total numeric := 0; v_reason text;
begin
  perform booking._require_permission('bookings.manage');
  if coalesce(p_refund, false) then perform booking._require_permission('payments.refund'); end if;
  select * into r from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if r.status not in ('pending','confirmed') then perform booking._err('invalid_status', 'Vain voimassa olevan varauksen voi perua'); end if;
  if coalesce(p_refund, false) then v_plan := booking._reservation_refund_plan(r.id); end if;   -- ennen peruutusta (rivit eivät muutu)
  perform booking.admin_set_reservation_status(r.id, 'cancelled', coalesce(nullif(btrim(p_reason), ''), 'henkilökunta'));
  if coalesce(p_refund, false) then
    v_reason := coalesce(nullif(btrim(p_refund_reason), ''), 'Varauksen peruutus (varaus #' || r.id || ')');
    for x in select * from jsonb_array_elements(v_plan -> 'payments') loop
      v_res := booking.admin_refund((x ->> 'payment_id')::bigint, (x ->> 'amount')::numeric, v_reason, x -> 'lines', false);
      v_out := v_out || jsonb_build_object('payment_id', (x ->> 'payment_id')::bigint, 'provider', x ->> 'provider', 'amount', (x ->> 'amount')::numeric,
        'refund_id', v_res -> 'refund_id', 'status', v_res ->> 'status', 'receipt_no', v_res -> 'receipt_no');
      v_total := v_total + (x ->> 'amount')::numeric;
    end loop;
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'reservations', r.id::text, 'ADMIN_CANCEL_RESERVATION', jsonb_build_object('status', r.status),
          jsonb_build_object('status', 'cancelled', 'refund', coalesce(p_refund, false), 'refunded_total', v_total));
  return jsonb_build_object('ok', true, 'cancelled', true, 'order_id', r.order_id, 'refunds', v_out, 'refunded_total', v_total,
    'balance', booking._order_balance(r.order_id));
end $$;
revoke all on function booking.admin_cancel_reservation(bigint, text, boolean, text) from public, anon;
grant execute on function booking.admin_cancel_reservation(bigint, text, boolean, text) to authenticated, service_role;

-- Tilauksen maksun hyvitys + valinnainen varausten peruutus. Oletus p_cancel_reservations = false (varaukset säilyvät).
create or replace function booking.admin_refund_order(p_payment_id bigint, p_amount numeric, p_reason text, p_lines jsonb default null,
  p_cancel_reservations boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_res jsonb; v_order bigint; x record; n int := 0;
begin
  perform booking._require_permission('payments.refund');
  if coalesce(p_cancel_reservations, false) then perform booking._require_permission('bookings.manage'); end if;
  v_res := booking.admin_refund(p_payment_id, p_amount, p_reason, p_lines, false);
  if coalesce(p_cancel_reservations, false) then
    select order_id into v_order from booking.payments where id = p_payment_id;
    for x in select id from booking.reservations where order_id = v_order and status in ('pending','confirmed') order by id for update loop
      perform booking.admin_set_reservation_status(x.id, 'cancelled', 'hyvitys');
      n := n + 1;
    end loop;
  end if;
  return v_res || jsonb_build_object('cancelled_reservations', n);
end $$;
revoke all on function booking.admin_refund_order(bigint, numeric, text, jsonb, boolean) from public, anon;
grant execute on function booking.admin_refund_order(bigint, numeric, text, jsonb, boolean) to authenticated, service_role;
