-- booking_180 ROLLBACK: palauttaa booking.admin_set_reservation_addons(bigint,jsonb) tuotannon rungon täsmälleen (md5 3a9ec1b6cb0358977d970fdb2886f46e).
-- Vartija: nykyinen md5 on oltava 55897305ec87eb5a0c016154aa275107 (booking_180) tai jo 3a9ec1b6cb0358977d970fdb2886f46e, muuten ajo keskeytyy eikä mitään muuteta.
-- Ei datamuutoksia. Huom: rollbackin jälkeen maksetut lisäpalvelurivit voi taas poistaa ja luoda uudelleen kattamattomina.
set local lock_timeout = '5s';

do $g$
declare v_md5 text := (select md5(pg_get_functiondef('booking.admin_set_reservation_addons(bigint,jsonb)'::regprocedure)));
begin
  if v_md5 not in ('55897305ec87eb5a0c016154aa275107', '3a9ec1b6cb0358977d970fdb2886f46e') then
    raise exception 'booking_180 rollback: booking.admin_set_reservation_addons md5 % ei ole odotettu (55897305ec87eb5a0c016154aa275107 / 3a9ec1b6cb0358977d970fdb2886f46e); mitään ei muutettu', v_md5;
  end if;
end $g$;

CREATE OR REPLACE FUNCTION booking.admin_set_reservation_addons(p_reservation_id bigint, p_addons jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare res booking.reservations; v_old jsonb; v_total numeric;
begin
  perform booking._require_permission('bookings.manage');
  select * into res from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if res.status not in ('pending','confirmed') then perform booking._err('not_editable', 'Lisäpalveluita voi muuttaa vain voimassa olevaan varaukseen'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('addon_id', addon_id, 'name', product_name, 'quantity', quantity) order by id), '[]'::jsonb)
    into v_old from booking.order_items where parent_item_id = res.order_item_id and kind = 'addon';
  delete from booking.order_items where parent_item_id = res.order_item_id and kind = 'addon';
  update booking.orders set total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = res.order_id), 0) where id = res.order_id;
  perform booking._attach_addons(res.id, p_addons);
  select total_gross into v_total from booking.orders where id = res.order_id;
  if v_total < (select coalesce(sum(p.amount), 0) - coalesce(sum(p.refunded_amount), 0) from booking.payments p
                 where p.order_id = res.order_id and p.status in ('paid','partially_refunded','refunded')) then
    perform booking._err('below_paid', 'Tilauksen summa ei voi laskea alle maksetun summan (hyvitä ensin)');
  end if;
  perform booking._sync_placeholder(res.order_id);
  perform booking._refresh_order_payment(res.order_id);
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'order_items', res.order_id::text, 'ADMIN_SET_ADDONS', jsonb_build_object('addons', v_old),
          jsonb_build_object('addons', coalesce(p_addons, '[]'::jsonb), 'total', v_total));
  return jsonb_build_object('ok', true, 'total', v_total);
end $function$;

revoke all on function booking.admin_set_reservation_addons(bigint, jsonb) from public, anon;
grant execute on function booking.admin_set_reservation_addons(bigint, jsonb) to authenticated, service_role;
