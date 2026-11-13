-- ROLLBACK: booking_287 svc_raise_order_price_to_voucher_value. Poistaa funktion (se oli uusi, ei aiempaa versiota).
-- Lähtöhashvartija: ajetaan vain, jos nykyinen määrittely on täsmälleen booking_287 (PROD/DEV md5 42550cac09b3741e1a398db1754c5921, luettu 13.11.2026).
-- Ei koske dataan: funktiolla jo nostetut tilaushinnat, historia ja audit_log jäävät ennalleen.
do $pre$
declare v text := md5(pg_get_functiondef(to_regprocedure('booking.svc_raise_order_price_to_voucher_value(bigint,bigint,numeric,text,text,text)')));
begin
  if v is null then raise notice 'rollback 287: funktiota ei ole, ei muutoksia'; return; end if;
  if v <> '42550cac09b3741e1a398db1754c5921' then
    raise exception 'rollback 287: svc_raise_order_price_to_voucher_value md5 % ei ole booking_287-versio. Ei muutoksia.', v;
  end if;
end $pre$;

drop function if exists booking.svc_raise_order_price_to_voucher_value(bigint, bigint, numeric, text, text, text);

notify pgrst, 'reload schema';
