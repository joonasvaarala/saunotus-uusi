-- Rollback booking_68_admin_day_extras: poistaa vain lukufunktion. Ei taulumuutoksia, ei datan poistoa.
set local lock_timeout = '5s';
drop function if exists booking.admin_day_extras(date);
