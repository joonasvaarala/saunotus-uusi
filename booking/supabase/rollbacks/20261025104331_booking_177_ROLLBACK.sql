-- booking_177 ROLLBACK: poistaa julkisen maksulinkin yhteenveto-RPC:n booking.public_payment_link_info(uuid) (oikeudet ensin pois). Muita määrittelyjä ei muutettu.
-- Rollbackin jälkeen /maksa/- ja /en/pay/-sivu toimii edelleen: RPC:n 404 → sivu näyttää yleisen maksulinkkikortin ja painikkeen (ei yhteenvetoa).
--   booking.public_payment_link_info(uuid): 1fb6153b39daa6f1055c93cac7cb4563 -> (poistettu)
set local lock_timeout = '5s';

do $g$
declare v text := md5(pg_get_functiondef(to_regprocedure('booking.public_payment_link_info(uuid)')));
begin
  if v is not null and v <> '1fb6153b39daa6f1055c93cac7cb4563' then raise exception 'booking_177 ROLLBACK: public_payment_link_info md5 % ei vastaa booking_177:ää. Ei muutoksia.', v; end if;
end $g$;

do $r$
begin
  if to_regprocedure('booking.public_payment_link_info(uuid)') is not null then
    revoke all on function booking.public_payment_link_info(uuid) from public, anon, authenticated, service_role;
  end if;
end $r$;
drop function if exists booking.public_payment_link_info(uuid);

do $v$
begin
  if to_regprocedure('booking.public_payment_link_info(uuid)') is not null then raise exception 'booking_177 ROLLBACK: funktio jäi'; end if;
end $v$;
