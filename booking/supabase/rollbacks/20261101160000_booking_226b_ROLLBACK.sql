-- ROLLBACK booking_226b. Palauttaa booking_226:n funktiot (uudelleenajo) ja poistaa osakerrat.
-- Ei poista booking_226:ta. Uudelleenajettava.
set local lock_timeout = '5s';

\ir ../migrations/20261101143000_booking_226_training_signup.sql

drop function if exists booking._training_hold_segment(bigint, bigint, timestamptz);
drop function if exists booking._training_segment_json(bigint);
drop function if exists booking._training_segment_ids(bigint);
drop function if exists booking._training_segments_of(bigint);
drop function if exists booking.admin_training_segments_get(bigint);
drop function if exists booking.admin_training_segments_set(bigint, bigint[]);
drop table if exists booking.training_segments;
alter table booking.training_participants drop column if exists segments;
alter table booking.schedule_rules drop column if exists training_segment_only;
