-- booking_282 ROLLBACK: palauttaa admin_change_booking 8 arg (md5 fe20541b…) ja _on_refund_done (md5 83f32b69…), pudottaa esikatselun ja apufunktiot,
-- refunds.notify_customer -sarakkeen ja asetuksen partial_refunds_enabled. Aja VASTA kun 283 ja 284 on rullattu takaisin (ne käyttävät näitä).
-- Koko tiedosto yhtenä transaktiona (psql -1).
set local lock_timeout = '5s';
do $pre0$ begin
  if to_regprocedure('booking.admin_cancel_order(bigint,text,jsonb,boolean,boolean)') is not null or to_regprocedure('booking._reduce_eval(bigint,bigint,bigint,date,integer)') is not null then
    raise exception 'rollback booking_282: aja ensin booking_283 ja booking_284 rollback. Ei muutoksia.';
  end if;
end $pre0$;
do $pre$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_change_booking(bigint,bigint,date,integer,boolean,boolean,timestamptz,timestamptz,numeric,text,boolean)')));
  if v is distinct from '80cd08f2a84d016bc66a6a8593960a41' then raise exception 'rollback 282: % md5 % ei vastaa booking_282-versiota (80cd08f2a84d016bc66a6a8593960a41). Ei muutoksia.', 'booking.admin_change_booking(bigint,bigint,date,integer,boolean,boolean,timestamptz,timestamptz,numeric,text,boolean)', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_change_booking_preview(bigint,bigint,date,integer,timestamptz)')));
  if v is distinct from 'fbce846328a4ccaf64a7e9e5dd179940' then raise exception 'rollback 282: % md5 % ei vastaa booking_282-versiota (fbce846328a4ccaf64a7e9e5dd179940). Ei muutoksia.', 'booking.admin_change_booking_preview(bigint,bigint,date,integer,timestamptz)', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._on_refund_done(bigint)')));
  if v is distinct from '38b48bcd53ae5afe77ba51c6273752a8' then raise exception 'rollback 282: % md5 % ei vastaa booking_282-versiota (38b48bcd53ae5afe77ba51c6273752a8). Ei muutoksia.', 'booking._on_refund_done(bigint)', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._order_refund_info(bigint,numeric)')));
  if v is distinct from '8c6cb16cb3cee2c1b93bc5bd2ec1670a' then raise exception 'rollback 282: % md5 % ei vastaa booking_282-versiota (8c6cb16cb3cee2c1b93bc5bd2ec1670a). Ei muutoksia.', 'booking._order_refund_info(bigint,numeric)', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._refund_allocate(bigint,numeric,bigint,bigint[],numeric,boolean)')));
  if v is distinct from 'd6d5da3dc9c44e195a473b01e0825b69' then raise exception 'rollback 282: % md5 % ei vastaa booking_282-versiota (d6d5da3dc9c44e195a473b01e0825b69). Ei muutoksia.', 'booking._refund_allocate(bigint,numeric,bigint,bigint[],numeric,boolean)', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._do_refunds(jsonb,text,boolean)')));
  if v is distinct from 'd6136adbafc2d1ddbcc4d5ff46863808' then raise exception 'rollback 282: % md5 % ei vastaa booking_282-versiota (d6136adbafc2d1ddbcc4d5ff46863808). Ei muutoksia.', 'booking._do_refunds(jsonb,text,boolean)', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._change_price_preview(bigint,bigint,integer)')));
  if v is distinct from '3e8c5c9492825437710ebacbb885d8be' then raise exception 'rollback 282: % md5 % ei vastaa booking_282-versiota (3e8c5c9492825437710ebacbb885d8be). Ei muutoksia.', 'booking._change_price_preview(bigint,bigint,integer)', v; end if;
end $pre$;

drop function if exists booking.admin_change_booking_preview(bigint, bigint, date, integer, timestamptz);
drop function if exists booking.admin_change_booking(bigint, bigint, date, integer, boolean, boolean, timestamptz, timestamptz, numeric, text, boolean);
CREATE OR REPLACE FUNCTION booking.admin_change_booking(p_reservation_id bigint, p_rule_id bigint DEFAULT NULL::bigint, p_date date DEFAULT NULL::date, p_persons integer DEFAULT NULL::integer, p_allow_overbook boolean DEFAULT false, p_allow_off_schedule boolean DEFAULT false, p_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_permission('bookings.manage');
  if p_rule_id is null and p_date is null and p_persons is null and p_start is null then perform booking._err('invalid_change', 'Ei muutettavaa'); end if;
  perform booking._arm_staff_overrides(p_allow_overbook, p_allow_off_schedule, p_start, p_end);
  return booking._change_booking_core(p_reservation_id, p_rule_id, p_date, p_persons, false, null, auth.uid(), 'ADMIN_CHANGE')
         || jsonb_build_object('ok', true);
end $function$;
CREATE OR REPLACE FUNCTION booking._on_refund_done(p_refund_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id bigint; v_order bigint; v_pay bigint;
begin
  if exists (select 1 from booking.refunds f join booking.payments p on p.id = f.payment_id where f.id = p_refund_id and p.method = 'invoice') then return; end if;
  v_id := booking._issue_refund_receipt(p_refund_id);
  if v_id is not null then
    select order_id, payment_id into v_order, v_pay from booking.refunds where id = p_refund_id;
    perform booking._enqueue_email('refund_receipt', v_order, v_id, v_pay, 'receipt:' || v_id);
  end if;
end $function$;

revoke all on function booking.admin_change_booking(bigint, bigint, date, integer, boolean, boolean, timestamptz, timestamptz) from public, anon;
grant execute on function booking.admin_change_booking(bigint, bigint, date, integer, boolean, boolean, timestamptz, timestamptz) to authenticated, service_role;

drop function if exists booking._do_refunds(jsonb, text, boolean);
drop function if exists booking._refund_allocate(bigint, numeric, bigint, bigint[], numeric, boolean);
drop function if exists booking._order_refund_info(bigint, numeric);
drop function if exists booking._change_price_preview(bigint, bigint, integer);
drop function if exists booking._pl_cap(bigint);
drop function if exists booking._flag_on(text);
alter table booking.refunds drop column if exists notify_customer;
delete from booking.settings where key = 'partial_refunds_enabled';

notify pgrst, 'reload schema';
