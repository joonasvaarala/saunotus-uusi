-- booking_319 jälkitarkistukset (aja vasta migraation jälkeen, ei erillisenä migraationa).
-- Ensimmäisellä ajolla odotettu: 14 aktiivista booking_319-hintariviä ja 28 sääntöä
-- (14 yhdistelmää × 2 voimassaoloikkunaa). Deaktivoituja: 3 hintariviä ja 5 sääntöä
-- (25 pe 14–21 ja 16–21, kaksi ikkunaa kumpikin; 48 pe 16–21 yksi rivi).
-- Uudelleenajo on idempotentti.

-- 1) Rivimäärät
SELECT 'new_variants' AS k, count(*) AS n
  FROM kb.product_price_variants v
 WHERE v.active
   AND coalesce(v.notes, '') LIKE '%booking_319%'
   AND coalesce(v.notes, '') NOT LIKE '%booking_319_deactivated%'
UNION ALL
SELECT 'new_rules', count(*)
  FROM booking.schedule_rules sr
 WHERE sr.active
   AND coalesce(sr.notes, '') LIKE '%booking_319%'
   AND coalesce(sr.notes, '') NOT LIKE '%booking_319_deactivated%'
UNION ALL
SELECT 'deact_variants', count(*)
  FROM kb.product_price_variants v
 WHERE coalesce(v.notes, '') LIKE '%booking_319_deactivated%'
UNION ALL
SELECT 'deact_rules', count(*)
  FROM booking.schedule_rules sr
 WHERE coalesce(sr.notes, '') LIKE '%booking_319_deactivated%';

-- 2) to 7.1.2027 ja pe 8.1.2027 odotetut hinnat (p8 = perushinta, p10 = +20 € uusilla fixed_plus_extra -riveillä)
-- 25 to 7.1.: 14–16 250, 16–19 420, 14–19 650, 16–21 600, 14–21 820
-- 48 to 7.1.: 14–16 350 (VANHA fixed; p8=p10=350), 16–19 500, 14–19 790, 16–21 720, 14–21 990
-- 25 pe 8.1.: 14–16 300, 16–19 420, 14–19 720, 16–21 650, 14–21 900  (vanhat 550/650 poissa)
-- 48 pe 8.1.: 12–21 850 (VANHA fixed), 14–16 380, 16–19 500, 14–19 850, 16–21 780, 14–21 1080
-- 31.12.2026 16–21 500 € ennallaan, jos tarkistetaan erikseen.
SELECT sr.product_id,
       to_char(a.starts_at AT TIME ZONE 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') AS start_hel,
       to_char(a.ends_at   AT TIME ZONE 'Europe/Helsinki', 'HH24:MI') AS end_hel,
       a.status, a.base_price, sr.price_mode,
       (SELECT total FROM booking._rule_price(a.rule_id, 8))  AS p8,
       (SELECT total FROM booking._rule_price(a.rule_id, 10)) AS p10
  FROM (
    SELECT * FROM booking.public_availability(25, DATE '2027-01-07', DATE '2027-01-08')
    UNION ALL
    SELECT * FROM booking.public_availability(48, DATE '2027-01-07', DATE '2027-01-08')
  ) a
  JOIN booking.schedule_rules sr ON sr.id = a.rule_id
 ORDER BY sr.product_id, a.starts_at, a.ends_at;

-- 3) Vanhat hinnat eivät ole enää aktiivisessa tarjonnassa pe-päivinä
SELECT sr.id, sr.product_id, v.price, sr.start_time, sr.duration_minutes, sr.active, sr.valid_from, sr.valid_to
  FROM booking.schedule_rules sr
  JOIN kb.product_price_variants v ON v.id = sr.price_variant_id
 WHERE sr.product_id IN (25, 48)
   AND sr.weekdays = ARRAY[5]::smallint[]
   AND (
         (sr.product_id = 25 AND sr.start_time = '14:00' AND sr.duration_minutes = 420 AND v.price = 650)
      OR (sr.product_id = 25 AND sr.start_time = '16:00' AND sr.duration_minutes = 300 AND v.price = 550)
      OR (sr.product_id = 48 AND sr.start_time = '16:00' AND sr.duration_minutes = 300 AND v.price = 500)
       );
-- Odotus: rivit näkyvät, mutta active = false.

-- 4) Ennalleen jääneet
-- 25 ma–to 14–16 250, pe 14–16 300, ma–pe 16–19 420, active true
-- 48 ma–to 14–16 350 fixed, pe 12–21 850 fixed, active true
-- 25 to 31.12.2026 16–21 500, active true
