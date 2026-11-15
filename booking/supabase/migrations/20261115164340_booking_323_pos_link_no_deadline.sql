-- booking_323: pikakassan maksulinkki ilman takarajaa (Joonas 15.11.2026 klo 18.42, vastaus t1820s7648 "Pikakassan linkillä ei takarajaa").
-- admin_pos_send_link kutsui _create_link_payment(o.id, 1, 'pikakassa') eli linkki vanheni 24 h:ssa.
-- Nyt p_expires_days = null: link_expires_at null ja raw.paylink = 'no_deadline' (booking_184-logiikka).
-- _counter_expire ei vanhenna tilausta, jolla on avoin takarajaton linkki.
do $m$
declare
  v_def text := pg_get_functiondef('booking.admin_pos_send_link(bigint,text,boolean)'::regprocedure);
  v_old text := 'booking._create_link_payment(o.id, 1, ''pikakassa'')';
  v_new text := 'booking._create_link_payment(o.id, null, ''pikakassa'')';
begin
  if position(v_new in v_def) > 0 then
    raise notice 'booking_323: jo ajettu';
    return;
  end if;
  if position(v_old in v_def) = 0 then
    raise exception 'booking_323: odotettua kutsua ei löytynyt admin_pos_send_link-funktiosta';
  end if;
  execute replace(v_def, v_old, v_new);
end $m$;
