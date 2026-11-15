-- booking_319 rollback: poistaa uudet booking_319-säännöt ja -hintarivit
-- ja palauttaa deaktivoidut pe 14–21 / 16–21 -rivit (25: 650/550, 48: 500).
-- Jos uusiin sääntöihin on varauksia tai jonoja, rollback keskeytyy.
-- Ma–to esilöylyjä, ma–pe 16–19 420 €, yrityksen ma–to 14–16 350 €,
-- pe 12–21 850 € tai 31.12. erikoissääntöä ei muuteta.

DO $booking_319_rb$
DECLARE
  n_res integer;
  n_wl integer;
BEGIN
  SELECT count(*) INTO n_res
    FROM booking.reservations r
    JOIN booking.schedule_rules sr ON sr.id = r.rule_id
   WHERE coalesce(sr.notes, '') LIKE '%booking_319%'
     AND coalesce(sr.notes, '') NOT LIKE '%booking_319_deactivated%';

  SELECT count(*) INTO n_wl
    FROM booking.waitlist_entries w
    JOIN booking.schedule_rules sr ON sr.id = w.rule_id
   WHERE coalesce(sr.notes, '') LIKE '%booking_319%'
     AND coalesce(sr.notes, '') NOT LIKE '%booking_319_deactivated%';

  IF n_res > 0 OR n_wl > 0 THEN
    RAISE EXCEPTION 'booking_319 rollback keskeytetty: uusiin sääntöihin liittyy % varausta ja % jonotusta. Rivejä ei poisteta.', n_res, n_wl;
  END IF;

  DELETE FROM booking.schedule_rules sr
   WHERE coalesce(sr.notes, '') LIKE '%booking_319%'
     AND coalesce(sr.notes, '') NOT LIKE '%booking_319_deactivated%';

  DELETE FROM kb.product_price_variants v
   WHERE coalesce(v.notes, '') LIKE '%booking_319%'
     AND coalesce(v.notes, '') NOT LIKE '%booking_319_deactivated%'
     AND NOT EXISTS (
       SELECT 1 FROM booking.schedule_rules sr WHERE sr.price_variant_id = v.id
     );

  UPDATE booking.schedule_rules sr
     SET active = true,
         updated_at = now(),
         notes = nullif(btrim(replace(coalesce(sr.notes, ''), ' | booking_319_deactivated', '')), '')
   WHERE coalesce(sr.notes, '') LIKE '%booking_319_deactivated%'
     AND sr.product_id IN (25, 48)
     AND sr.weekdays = ARRAY[5]::smallint[]
     AND (
           (sr.product_id = 25 AND sr.start_time = '14:00' AND sr.duration_minutes = 420)
        OR (sr.product_id = 25 AND sr.start_time = '16:00' AND sr.duration_minutes = 300)
        OR (sr.product_id = 48 AND sr.start_time = '16:00' AND sr.duration_minutes = 300)
         );

  UPDATE kb.product_price_variants v
     SET active = true,
         updated_at = now(),
         notes = nullif(btrim(replace(coalesce(v.notes, ''), ' | booking_319_deactivated', '')), '')
   WHERE coalesce(v.notes, '') LIKE '%booking_319_deactivated%'
     AND v.product_id IN (25, 48)
     AND v.weekdays = ARRAY[5]::smallint[]
     AND (
           (v.product_id = 25 AND v.price = 650 AND v.duration_minutes = 420 AND v.time_start = '14:00' AND v.time_end = '21:00')
        OR (v.product_id = 25 AND v.price = 550 AND v.duration_minutes = 300 AND v.time_start = '16:00' AND v.time_end = '21:00')
        OR (v.product_id = 48 AND v.price = 500 AND v.duration_minutes = 300 AND v.time_start = '16:00' AND v.time_end = '21:00')
         );
END
$booking_319_rb$;
