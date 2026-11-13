-- booking_283 ROLLBACK: palauttaa booking_281-tilan (admin_cancel_reservation 6 arg md5 f76f9885…), pudottaa admin_cancel_order, admin_refund_overpayment,
-- admin_order_refund_info ja _payment_free_lines. Koko tiedosto yhtenä transaktiona (psql -1). Tehdyt hyvitykset/peruutukset säilyvät datana.
set local lock_timeout = '5s';
do $pre$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_cancel_reservation(bigint,text,boolean,text,boolean,boolean,numeric)')));
  if v is distinct from 'e3f801fef6332eb5bb110a8efb10efd1' then raise exception 'rollback 283: % md5 % ei vastaa booking_283-versiota (e3f801fef6332eb5bb110a8efb10efd1). Ei muutoksia.', 'booking.admin_cancel_reservation(bigint,text,boolean,text,boolean,boolean,numeric)', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_cancel_order(bigint,text,jsonb,boolean,boolean)')));
  if v is distinct from '784437b1c9bb6b9aa428f015013a8c8f' then raise exception 'rollback 283: % md5 % ei vastaa booking_283-versiota (784437b1c9bb6b9aa428f015013a8c8f). Ei muutoksia.', 'booking.admin_cancel_order(bigint,text,jsonb,boolean,boolean)', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_refund_overpayment(bigint,numeric,bigint,text,boolean)')));
  if v is distinct from '0319667cddff9516428664d19ec34a04' then raise exception 'rollback 283: % md5 % ei vastaa booking_283-versiota (0319667cddff9516428664d19ec34a04). Ei muutoksia.', 'booking.admin_refund_overpayment(bigint,numeric,bigint,text,boolean)', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_order_refund_info(bigint)')));
  if v is distinct from '50c2b9f7637e004d692e1344320f45fe' then raise exception 'rollback 283: % md5 % ei vastaa booking_283-versiota (50c2b9f7637e004d692e1344320f45fe). Ei muutoksia.', 'booking.admin_order_refund_info(bigint)', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._payment_free_lines(bigint)')));
  if v is distinct from '4c7cd6c3eaf488462345219540c42ce8' then raise exception 'rollback 283: % md5 % ei vastaa booking_283-versiota (4c7cd6c3eaf488462345219540c42ce8). Ei muutoksia.', 'booking._payment_free_lines(bigint)', v; end if;
end $pre$;

drop function if exists booking.admin_cancel_order(bigint, text, jsonb, boolean, boolean);
drop function if exists booking.admin_refund_overpayment(bigint, numeric, bigint, text, boolean);
drop function if exists booking.admin_order_refund_info(bigint);
drop function if exists booking._payment_free_lines(bigint);
drop function if exists booking.admin_cancel_reservation(bigint, text, boolean, text, boolean, boolean, numeric);
CREATE OR REPLACE FUNCTION booking.admin_cancel_reservation(p_reservation_id bigint, p_reason text DEFAULT NULL::text, p_refund boolean DEFAULT false, p_refund_reason text DEFAULT NULL::text, p_gift_card_keep boolean DEFAULT NULL::boolean, p_notify boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r booking.reservations; v_plan jsonb; x jsonb; v_res jsonb; v_out jsonb := '[]'::jsonb; v_total numeric := 0; v_reason text;
        v_gc jsonb := '[]'::jsonb; v_gc_out jsonb := '[]'::jsonb; g booking.gift_cards; v_rid bigint; v_kept_order boolean; v_partner numeric := 0;
        v_action uuid; v_notified boolean := false;
begin
  perform booking._require_permission('bookings.manage');
  if coalesce(p_refund, false) then perform booking._require_permission('payments.refund'); end if;
  select * into r from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if r.status not in ('pending','confirmed') then perform booking._err('invalid_status', 'Vain voimassa olevan varauksen voi perua'); end if;
  if coalesce(p_refund, false) and booking._order_invoice_locked(r.order_id) then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  v_plan := booking._reservation_refund_plan(r.id);   -- ennen peruutusta (rivit eivät muutu)
  -- booking_280: lahjakorttiosuus (rahaa ei koskaan hyvitetä) → pakollinen valinta "jätetäänkö koodi voimaan"
  select coalesce(jsonb_agg(e), '[]'::jsonb) into v_gc from jsonb_array_elements(coalesce(v_plan -> 'payments', '[]'::jsonb)) e where coalesce((e ->> 'gift_card')::boolean, false);
  select coalesce(sum((e ->> 'amount')::numeric), 0) into v_partner from jsonb_array_elements(coalesce(v_plan -> 'payments', '[]'::jsonb)) e
   where e ->> 'method' = 'partner_voucher' or e ->> 'method' like 'partner\_voucher\_%';
  if jsonb_array_length(v_gc) > 0 and p_gift_card_keep is null then
    perform booking._err('gift_card_keep_required', 'Varaus on maksettu lahjakortilla: valitse, jätetäänkö lahjakorttikoodi voimaan');
  end if;
  if jsonb_array_length(v_gc) > 0 and p_gift_card_keep and booking._order_invoice_locked(r.order_id) then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  if jsonb_array_length(v_gc) > 0 and p_gift_card_keep then
    for x in select * from jsonb_array_elements(v_gc) loop
      select gc.* into g from booking.gift_cards gc join booking.payments p on p.gift_card_id = gc.id where p.id = (x ->> 'payment_id')::bigint;
      if not booking._gc_keep_allowed(g) then
        perform booking._err('gift_card_expired', 'Lahjakortti ei ole enää voimassa: koodia ei voi jättää voimaan');
      end if;
    end loop;
  end if;
  perform booking.admin_set_reservation_status(r.id, 'cancelled', coalesce(nullif(btrim(p_reason), ''), 'henkilökunta'));
  for x in select * from jsonb_array_elements(v_gc) loop
    if p_gift_card_keep then
      v_rid := booking._gc_return_to_card((x ->> 'payment_id')::bigint, (x ->> 'amount')::numeric, x -> 'lines',
                 'Varauksen peruutus, koodi jätetty voimaan (varaus #' || r.id || ')', r.id);
      v_gc_out := v_gc_out || jsonb_build_object('payment_id', (x ->> 'payment_id')::bigint, 'amount', (x ->> 'amount')::numeric, 'action', 'returned', 'refund_id', v_rid);
    else
      perform booking._gc_forfeit_on_cancel((x ->> 'payment_id')::bigint, (x ->> 'amount')::numeric, r.id, 'Varauksen peruutus, koodi ei jäänyt voimaan');
      v_gc_out := v_gc_out || jsonb_build_object('payment_id', (x ->> 'payment_id')::bigint, 'amount', (x ->> 'amount')::numeric, 'action', 'forfeited');
    end if;
  end loop;
  if coalesce(p_refund, false) then
    v_reason := coalesce(nullif(btrim(p_refund_reason), ''), 'Varauksen peruutus (varaus #' || r.id || ')');
    for x in select * from jsonb_array_elements(v_plan -> 'payments') e
              where not coalesce((e ->> 'gift_card')::boolean, false)
                and not (e ->> 'method' = 'partner_voucher' or e ->> 'method' like 'partner\_voucher\_%') loop
      v_res := booking.admin_refund((x ->> 'payment_id')::bigint, (x ->> 'amount')::numeric, v_reason, x -> 'lines', false);
      v_out := v_out || jsonb_build_object('payment_id', (x ->> 'payment_id')::bigint, 'provider', x ->> 'provider', 'amount', (x ->> 'amount')::numeric,
        'refund_id', v_res -> 'refund_id', 'status', v_res ->> 'status', 'receipt_no', v_res -> 'receipt_no');
      v_total := v_total + (x ->> 'amount')::numeric;
    end loop;
  end if;
  v_kept_order := booking._order_voucher_redeemed(r.order_id)
                  and not exists (select 1 from booking.reservations y where y.order_id = r.order_id and y.status in ('pending','confirmed'));
  -- booking_281 (Joonas 11.11.2026 18.12): p_notify = true → yksi reservation_cancelled-viesti HETI (peruutus + "hyvitys käsittelyssä"
  -- + lahjakortin/kumppanilunastuksen tila). Hyvityskuitti lähtee erikseen nykyisellä refund_receipt-polulla, kun hyvitys on vahvistettu
  -- (manuaalinen heti; Montonio montonio_refund_complete → _on_refund_done). p_notify null/false → ei peruutusviestiä.
  if p_notify then
    v_action := gen_random_uuid();
    v_notified := booking._enqueue_reservation_cancelled(r.order_id, v_action, array[r.id], v_out, v_gc_out, v_kept_order);
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'reservations', r.id::text, 'ADMIN_CANCEL_RESERVATION', jsonb_build_object('status', r.status),
          jsonb_build_object('status', 'cancelled', 'refund', coalesce(p_refund, false), 'refunded_total', v_total,
                             'gift_card_keep', p_gift_card_keep, 'gift_card', v_gc_out, 'partner_share', v_partner, 'order_kept_voucher', v_kept_order,
                             'notify', p_notify, 'notified', v_notified, 'action_id', v_action));
  return jsonb_build_object('ok', true, 'cancelled', true, 'order_id', r.order_id, 'refunds', v_out, 'refunded_total', v_total,
    'gift_card', v_gc_out, 'partner_share', v_partner, 'order_kept', v_kept_order,
    'notified', v_notified, 'action_id', v_action,
    'balance', booking._order_balance(r.order_id));
end $function$;

revoke all on function booking.admin_cancel_reservation(bigint, text, boolean, text, boolean, boolean) from public, anon;
grant execute on function booking.admin_cancel_reservation(bigint, text, boolean, text, boolean, boolean) to authenticated, service_role;

notify pgrst, 'reload schema';
