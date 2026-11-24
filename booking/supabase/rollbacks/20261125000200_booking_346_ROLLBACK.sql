-- booking_346 ROLLBACK: uusi 6-parametrinen funktio pois, vanha 3-parametrinen tavu-identtisenä takaisin.
drop function if exists booking.svc_mark_order_paid_external(bigint, text, numeric, date, text, text);
CREATE OR REPLACE FUNCTION booking.svc_mark_order_paid_external(p_order_no bigint, p_note text, p_actor text DEFAULT 'asiakaspalvelu-bot'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o booking.orders;
  v_actor text;
  v_note text;
  v_line text;
  v_pay_n integer;
  v_mail_n integer;
  v_status text;
begin
  v_actor := coalesce(nullif(btrim(p_actor), ''), 'asiakaspalvelu-bot');
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  if p_order_no is null then
    perform booking._err('not_found', 'Tilausta ei löydy');
  end if;
  if v_note is null then
    perform booking._err('note_required', 'Anna syy (p_note)');
  end if;

  select * into o from booking.orders where order_no = p_order_no for update;
  if not found then
    perform booking._err('not_found', 'Tilausta ei löydy');
  end if;
  if o.status in ('cancelled', 'expired') then
    perform booking._err('order_cancelled', 'Peruttua tilausta ei merkitä maksetuksi');
  end if;
  if o.payment_status in ('paid', 'refunded', 'partially_refunded') then
    perform booking._err('already_paid', 'Tilaus on jo maksettu tai hyvitetty');
  end if;
  if o.status not in ('confirmed', 'completed') then
    perform booking._err('not_changeable', 'Vain vahvistetun tilauksen voi merkitä maksetuksi');
  end if;
  if o.payment_status = 'invoiced' or booking._order_invoice_locked(o.id) then
    perform booking._err('order_invoiced', 'Laskutettua tilausta ei merkitä maksetuksi; maksu kirjataan laskulle');
  end if;

  select count(*) into v_pay_n from booking.payments where order_id = o.id;
  select count(*) into v_mail_n from booking.email_outbox where order_id = o.id;
  v_line := to_char(now() at time zone booking._tz(), 'YYYY-MM-DD HH24:MI') || ' ' || v_actor || ': ' || v_note;
  update booking.orders
     set payment_status = 'paid',
         internal_note = concat_ws(E'\n', internal_note, v_line)
   where id = o.id
  returning payment_status into v_status;

  if (select count(*) from booking.payments where order_id = o.id) is distinct from v_pay_n then
    perform booking._err('payment_row', 'Ulkoista maksua ei kirjata maksujen tauluun');
  end if;
  if (select count(*) from booking.email_outbox where order_id = o.id) is distinct from v_mail_n then
    perform booking._err('email_queued', 'Maksun merkintä ei lähetä asiakkaalle viestiä');
  end if;

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (
    auth.uid(),
    coalesce(booking._jwt_role(), 'service_role'),
    'orders',
    o.id::text,
    'SVC_MARK_ORDER_PAID_EXTERNAL',
    jsonb_build_object('order_no', o.order_no, 'payment_status', o.payment_status),
    jsonb_build_object('order_no', o.order_no, 'payment_status', v_status, 'note', v_note, 'actor', v_actor)
  );

  return jsonb_build_object(
    'ok', true,
    'order_no', o.order_no,
    'payment_status', v_status
  );
end
$function$;
revoke all on function booking.svc_mark_order_paid_external(bigint, text, text) from public, anon, authenticated;
grant execute on function booking.svc_mark_order_paid_external(bigint, text, text) to service_role;
