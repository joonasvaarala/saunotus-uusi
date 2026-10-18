-- ROLLBACK booking_54_checkout_cancel
set local lock_timeout = '5s';

CREATE OR REPLACE FUNCTION booking.public_cancel_booking(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; n int;
  v_hours integer := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
begin
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  update booking.reservations set status = 'cancelled', cancelled_at = now(), cancel_reason = 'customer_cancelled_pending'
   where order_id = o.id and status = 'pending';
  get diagnostics n = row_count;
  if n = 0 then
    return jsonb_build_object('ok', false, 'code', 'not_cancellable',
      'message', format('Vahvistetun varauksen peruutus tehdään sähköpostitse henkilökunnalle. Varausta voi muuttaa itse viimeistään %s tuntia ennen vuoron alkua.', v_hours));
  end if;
  update booking.orders set status = 'cancelled', cancelled_at = now() where id = o.id and status = 'pending';
  update booking.payments set status = 'cancelled' where order_id = o.id and status = 'pending';
  return jsonb_build_object('ok', true);
end $function$;
