-- booking_281 ROLLBACK: palauttaa booking_280-tilan (admin_cancel_reservation 5 arg md5 5664a3cd…, email_outbox_claim booking_279 e46ae5eb…,
-- email_outbox_kind_check PROD 37e35b13…). Koko tiedosto yhtenä transaktiona (psql -1).
-- Ei saa ajaa, jos reservation_cancelled-viestejä on jo syntynyt (rajoite ei palaudu; forward-fix).
set local lock_timeout = '5s';
do $pre$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.email_outbox_claim(integer)')));
  if v is null or v not in ('44601247f6bbcadfece1e56a0c08fb13', 'e46ae5ebd9fb813a087b7f05c40949b8') then
    raise exception 'rollback booking_281: email_outbox_claim md5 % ei vastaa odotettua. Ei muutoksia.', v;
  end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_cancel_reservation(bigint,text,boolean,text,boolean,boolean)')));
  if v is not null and v <> 'f76f98857d6477f495f276582e732c11' then raise exception 'rollback booking_281: admin_cancel_reservation(6) vieras versio %', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._enqueue_reservation_cancelled(bigint,uuid,bigint[],jsonb,jsonb,boolean)')));
  if v is not null and v <> '64b44693bdf387b9e94b76dccd201094' then raise exception 'rollback booking_281: _enqueue_reservation_cancelled vieras versio %', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._reservation_cancelled_mail(bigint)')));
  if v is not null and v <> '4a944f66279e4c82b3c4aa03707ad3da' then raise exception 'rollback booking_281: _reservation_cancelled_mail vieras versio %', v; end if;
  if exists (select 1 from booking.email_outbox where kind = 'reservation_cancelled') then
    raise exception 'rollback booking_281: reservation_cancelled-viestejä on jo; forward-fix vaaditaan. Ei muutoksia.';
  end if;
end $pre$;

drop function if exists booking.admin_cancel_reservation(bigint, text, boolean, text, boolean, boolean);
CREATE OR REPLACE FUNCTION booking.admin_cancel_reservation(p_reservation_id bigint, p_reason text DEFAULT NULL::text, p_refund boolean DEFAULT false, p_refund_reason text DEFAULT NULL::text, p_gift_card_keep boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r booking.reservations; v_plan jsonb; x jsonb; v_res jsonb; v_out jsonb := '[]'::jsonb; v_total numeric := 0; v_reason text;
        v_gc jsonb := '[]'::jsonb; v_gc_out jsonb := '[]'::jsonb; g booking.gift_cards; v_rid bigint; v_kept_order boolean; v_partner numeric := 0;
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
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'reservations', r.id::text, 'ADMIN_CANCEL_RESERVATION', jsonb_build_object('status', r.status),
          jsonb_build_object('status', 'cancelled', 'refund', coalesce(p_refund, false), 'refunded_total', v_total,
                             'gift_card_keep', p_gift_card_keep, 'gift_card', v_gc_out, 'partner_share', v_partner, 'order_kept_voucher', v_kept_order));
  return jsonb_build_object('ok', true, 'cancelled', true, 'order_id', r.order_id, 'refunds', v_out, 'refunded_total', v_total,
    'gift_card', v_gc_out, 'partner_share', v_partner, 'order_kept', v_kept_order,
    'balance', booking._order_balance(r.order_id));
end $function$;
revoke all on function booking.admin_cancel_reservation(bigint, text, boolean, text, boolean) from public, anon;
grant execute on function booking.admin_cancel_reservation(bigint, text, boolean, text, boolean) to authenticated, service_role;

CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_rows jsonb;
begin
  -- Separate SPI statement: observe actual post-trigger statuses, not the caller SELECT snapshot.
  v_rows := booking.email_outbox_claim_base_215(p_limit);
  return (
  select coalesce(jsonb_agg(
    case when z.item->>'kind' = 'payment_link_reminder' then
      (case when exists (
          select 1 from booking.email_outbox e
          join booking.payments p on p.id = e.payment_id
          join booking.orders o on o.id = e.order_id
         where e.id = (z.item->>'id')::bigint
           and p.status = 'pending' and p.provider <> 'manual' and p.external_source is null and o.external_source is null
           and (p.link_expires_at is null or p.link_expires_at > now()))
        then z.item
        else z.item || jsonb_build_object('payment', (coalesce(z.item->'payment', '{}'::jsonb) - 'link_url'))
       end)
      || coalesce((select jsonb_build_object('payment_reminder', jsonb_build_object(
            'n', e.payload -> 'reminder_no', 'kind', e.payload ->> 'reminder_kind',
            'cancel_if_unpaid', coalesce((e.payload ->> 'cancel_if_unpaid')::boolean, false),
            'due_at', e.payload -> 'due_at'))
          from booking.email_outbox e where e.id = (z.item->>'id')::bigint), '{}'::jsonb)
    else case when z.item->>'kind' = 'order_confirmation' then
      z.item || coalesce((
        select jsonb_build_object('order', coalesce(z.item->'order', '{}'::jsonb) || jsonb_build_object(
          'deposit', true,
          'training', jsonb_build_object(
            'course_price', tp.course_price, 'addons_total', tp.addons_total, 'total', tp.total,
            'deposit_paid', tp.deposit_paid, 'remaining', tp.remaining, 'addons', tp.addons,
            'segments', tp.segments)))
          from booking.email_outbox e
          join booking.training_participants tp on tp.order_id = e.order_id
         where e.id = (z.item->>'id')::bigint
         order by tp.id limit 1
      ), '{}'::jsonb)
    else z.item end end
  order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(v_rows) with ordinality as z(item, ord)
  where exists (select 1 from booking.email_outbox e where e.id=(z.item->>'id')::bigint and e.status='sending')
  );
end $function$;

drop function if exists booking._reservation_cancelled_mail(bigint);
drop function if exists booking._enqueue_reservation_cancelled(bigint, uuid, bigint[], jsonb, jsonb, boolean);
alter table booking.email_outbox drop constraint email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check CHECK ((kind = ANY (ARRAY['newsletter'::text, 'payment_link_reminder'::text, 'event_message'::text, 'waitlist_joined'::text, 'order_confirmation'::text, 'payment_link'::text, 'receipt'::text, 'refund_receipt'::text, 'cancel_request_ack'::text, 'order_change'::text, 'gift_card_buyer'::text, 'gift_card_recipient'::text, 'voucher_claim_received'::text, 'voucher_claim_problem'::text, 'business_quote_ack'::text, 'business_quote_notify'::text, 'invoice_pdf'::text, 'product_message'::text, 'waitlist_spot_freed'::text, 'annual_card_code'::text, 'staff_shift_notice'::text, 'unpaid_booking_cancelled'::text])));
notify pgrst, 'reload schema';
