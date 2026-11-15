-- booking_323 ROLLBACK: pikakassan maksulinkki takaisin 1 päivän takarajaan.
do $m$
declare
  v_def text := pg_get_functiondef('booking.admin_pos_send_link(bigint,text,boolean)'::regprocedure);
  v_old text := 'booking._create_link_payment(o.id, null, ''pikakassa'')';
  v_new text := 'booking._create_link_payment(o.id, 1, ''pikakassa'')';
begin
  if position(v_old in v_def) = 0 then raise notice 'booking_323 rollback: ei mitään palautettavaa'; return; end if;
  execute replace(v_def, v_old, v_new);
end $m$;
