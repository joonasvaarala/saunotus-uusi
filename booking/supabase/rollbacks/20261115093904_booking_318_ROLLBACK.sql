-- booking_318 rollback: poistaa tämän migraation uudet la/su-säännöt ja hintarivit
-- ja palauttaa vanhan 13–14 250 €- sekä 13–15 420 € -tarjonnan.
-- Ei koske varauksiin liittyviä rivejä: jos uusiin sääntöihin on varauksia, rollback keskeytyy.
-- Ma–to esilöylyjä (14–16, 250 €) ei muuteta.

DO $booking_318_rb$
DECLARE
  n_res integer;
  n_wl integer;
BEGIN
  SELECT count(*) INTO n_res
    FROM booking.reservations r
    JOIN booking.schedule_rules sr ON sr.id = r.rule_id
   WHERE coalesce(sr.notes, '') LIKE '%booking_318%'
     AND coalesce(sr.notes, '') NOT LIKE '%booking_318_deactivated%';

  SELECT count(*) INTO n_wl
    FROM booking.waitlist_entries w
    JOIN booking.schedule_rules sr ON sr.id = w.rule_id
   WHERE coalesce(sr.notes, '') LIKE '%booking_318%'
     AND coalesce(sr.notes, '') NOT LIKE '%booking_318_deactivated%';

  IF n_res > 0 OR n_wl > 0 THEN
    RAISE EXCEPTION 'booking_318 rollback keskeytetty: uusiin sääntöihin liittyy % varausta ja % jonotusta. Rivejä ei poisteta.', n_res, n_wl;
  END IF;

  DELETE FROM booking.schedule_rules sr
   WHERE coalesce(sr.notes, '') LIKE '%booking_318%'
     AND coalesce(sr.notes, '') NOT LIKE '%booking_318_deactivated%';

  DELETE FROM kb.product_price_variants v
   WHERE coalesce(v.notes, '') LIKE '%booking_318%'
     AND coalesce(v.notes, '') NOT LIKE '%booking_318_deactivated%'
     AND NOT EXISTS (
       SELECT 1 FROM booking.schedule_rules sr WHERE sr.price_variant_id = v.id
     );

  UPDATE booking.schedule_rules sr
     SET active = true,
         updated_at = now(),
         notes = nullif(btrim(replace(coalesce(sr.notes, ''), ' | booking_318_deactivated', '')), '')
   WHERE coalesce(sr.notes, '') LIKE '%booking_318_deactivated%'
     AND sr.product_id = 25
     AND sr.start_time = '13:00'
     AND sr.weekdays @> ARRAY[6,7]::smallint[]
     AND cardinality(sr.weekdays) = 2
     AND sr.duration_minutes IN (60, 120);

  UPDATE kb.product_price_variants v
     SET active = true,
         updated_at = now(),
         notes = nullif(btrim(replace(coalesce(v.notes, ''), ' | booking_318_deactivated', '')), '')
   WHERE coalesce(v.notes, '') LIKE '%booking_318_deactivated%'
     AND v.product_id = 25
     AND v.time_start = '13:00'
     AND (
           (v.price = 420 AND v.duration_minutes = 120 AND v.time_end = '15:00')
        OR (v.price = 250 AND v.duration_minutes = 60  AND v.time_end = '14:00')
         );
END
$booking_318_rb$;
