-- booking_179 ROLLBACK. Poistaa ehdotustaulut, tapahtumahistorian, funktiot, triggerit ja oletusasetuksen,
-- jos asetus on yhä migraation alkuperäinen arvo. Vaatii, ettei uudempi migraatio riipu näistä objekteista.
-- Aja vasta varmuuskopion jälkeen, jos upsell_events-historiaa on jo kertynyt.
set local lock_timeout = '5s';

drop trigger if exists zz_upsell_paid_update on booking.payments;
drop trigger if exists zz_upsell_paid_insert on booking.payments;
drop function if exists booking._upsell_paid_trg();
drop function if exists booking.admin_upsell_report(date, date);
drop function if exists booking.public_upsell_add(uuid, jsonb, uuid, bigint);
drop function if exists booking.public_upsell_checkout_attach(uuid, jsonb, uuid);
drop function if exists booking._upsell_attach_reservation(bigint, bigint, timestamptz, integer, date);
drop function if exists booking.public_upsell_event(uuid, text, bigint, text, bigint, bigint);
drop function if exists booking.public_upsell_for_order(uuid);
drop function if exists booking.public_upsell_suggestions(bigint[], date, integer, timestamptz);
drop function if exists booking._upsell_options(bigint[], bigint[], date, integer, integer);
drop function if exists booking._upsell_day_slots(bigint, date, integer);
drop function if exists booking.admin_get_product_suggestions(bigint);
drop function if exists booking.admin_set_product_suggestions(bigint, jsonb);
drop function if exists booking._upsell_cutoff();
drop table if exists booking.upsell_events;
drop table if exists booking.product_suggestions;
delete from booking.settings where key = 'upsell_cutoff_minutes' and value = '120'::jsonb
  and description = 'Upsell additions must be at least this many minutes before first booking start';
