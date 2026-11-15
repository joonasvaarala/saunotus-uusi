-- booking_320 rollback: poistaa uudet booking_320-säännöt ja -hintarivit
-- ja palauttaa deaktivoidut yrityksen ma–to 14–16 350 € ja pe 12–21 850 € (fixed).
-- Jos uusiin sääntöihin on varauksia tai jonoja, rollback keskeytyy.
-- booking_319:n deaktivoimaa pe 16–21 500 € -riviä ei muuteta.

DO $booking_320_rb$
DECLARE
  n_res integer;
  n_wl integer;
BEGIN
  SELECT count(*) INTO n_res
    FROM booking.reservations r
    JOIN booking.schedule_rules sr ON sr.id = r.rule_id
   WHERE coalesce(sr.notes, '') LIKE '%booking_320%'
     AND coalesce(sr.notes, '') NOT LIKE '%booking_320_deactivated%';

  SELECT count(*) INTO n_wl
    FROM booking.waitlist_entries w
    JOIN booking.schedule_rules sr ON sr.id = w.rule_id
   WHERE coalesce(sr.notes, '') LIKE '%booking_320%'
     AND coalesce(sr.notes, '') NOT LIKE '%booking_320_deactivated%';

  IF n_res > 0 OR n_wl > 0 THEN
    RAISE EXCEPTION 'booking_320 rollback keskeytetty: uusiin sääntöihin liittyy % varausta ja % jonotusta. Rivejä ei poisteta.', n_res, n_wl;
  END IF;

  DELETE FROM booking.schedule_rules sr
   WHERE coalesce(sr.notes, '') LIKE '%booking_320%'
     AND coalesce(sr.notes, '') NOT LIKE '%booking_320_deactivated%';

  DELETE FROM kb.product_price_variants v
   WHERE coalesce(v.notes, '') LIKE '%booking_320%'
     AND coalesce(v.notes, '') NOT LIKE '%booking_320_deactivated%'
     AND NOT EXISTS (
       SELECT 1 FROM booking.schedule_rules sr WHERE sr.price_variant_id = v.id
     );

  UPDATE booking.schedule_rules sr
     SET active = true,
         updated_at = now(),
         notes = nullif(btrim(replace(coalesce(sr.notes, ''), ' | booking_320_deactivated', '')), '')
   WHERE coalesce(sr.notes, '') LIKE '%booking_320_deactivated%'
     AND sr.product_id = 48
     AND sr.price_mode = 'fixed'
     AND (
           (sr.start_time = '14:00' AND sr.duration_minutes = 120 AND sr.weekdays = ARRAY[1,2,3,4]::smallint[])
        OR (sr.start_time = '12:00' AND sr.duration_minutes = 540 AND sr.weekdays = ARRAY[5]::smallint[])
         );

  UPDATE kb.product_price_variants v
     SET active = true,
         updated_at = now(),
         notes = nullif(btrim(replace(coalesce(v.notes, ''), ' | booking_320_deactivated', '')), '')
   WHERE coalesce(v.notes, '') LIKE '%booking_320_deactivated%'
     AND v.product_id = 48
     AND (
           (v.price = 350 AND v.duration_minutes = 120 AND v.time_start = '14:00' AND v.time_end = '16:00' AND v.weekdays = ARRAY[1,2,3,4]::smallint[])
        OR (v.price = 850 AND v.duration_minutes = 540 AND v.time_start = '12:00' AND v.time_end = '21:00' AND v.weekdays = ARRAY[5]::smallint[])
         );
END
$booking_320_rb$;
