-- booking_320 jälkitarkistukset (aja vasta migraation jälkeen, ei erillisenä migraationa).
-- Ensimmäisellä ajolla odotettu: 2 uutta hintariviä ja 2 uutta sääntöä,
-- 2 deaktivoitua hintariviä ja 2 deaktivoitua sääntöä.
-- Uudelleenajo on idempotentti.

-- 1) Rivimäärät
SELECT 'new_variants' AS k, count(*) AS n
  FROM kb.product_price_variants v
 WHERE v.active
   AND coalesce(v.notes, '') LIKE '%booking_320%'
   AND coalesce(v.notes, '') NOT LIKE '%booking_320_deactivated%'
UNION ALL
SELECT 'new_rules', count(*)
  FROM booking.schedule_rules sr
 WHERE sr.active
   AND coalesce(sr.notes, '') LIKE '%booking_320%'
   AND coalesce(sr.notes, '') NOT LIKE '%booking_320_deactivated%'
UNION ALL
SELECT 'deact_variants', count(*)
  FROM kb.product_price_variants v
 WHERE coalesce(v.notes, '') LIKE '%booking_320_deactivated%'
UNION ALL
SELECT 'deact_rules', count(*)
  FROM booking.schedule_rules sr
 WHERE coalesce(sr.notes, '') LIKE '%booking_320_deactivated%'
UNION ALL
SELECT 'active_fixed_48', count(*)
  FROM booking.schedule_rules sr
 WHERE sr.product_id = 48 AND sr.active AND sr.price_mode = 'fixed'
UNION ALL
SELECT 'still_fixed_319_pe_16_21', count(*)
  FROM booking.schedule_rules sr
 WHERE sr.product_id = 48
   AND sr.price_mode = 'fixed'
   AND sr.start_time = '16:00'
   AND sr.duration_minutes = 300
   AND sr.weekdays = ARRAY[5]::smallint[]
   AND coalesce(sr.notes, '') LIKE '%booking_319_deactivated%'
   AND NOT sr.active;

-- 2) to 7.1.2027 ja pe 8.1.2027, tuote 48
-- 14–16: 350 €, fixed_plus_extra, p8=350, p10=370, valid_from/to NULL
-- 12–21: 850 €, fixed_plus_extra, p8=850, p10=870, valid_from/to NULL
-- Muut booking_319-hinnat ennallaan.
SELECT sr.product_id,
       to_char(a.starts_at AT TIME ZONE 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') AS start_hel,
       to_char(a.ends_at   AT TIME ZONE 'Europe/Helsinki', 'HH24:MI') AS end_hel,
       a.status, a.base_price, sr.price_mode, sr.valid_from, sr.valid_to,
       (SELECT total FROM booking._rule_price(a.rule_id, 8))  AS p8,
       (SELECT total FROM booking._rule_price(a.rule_id, 10)) AS p10
  FROM booking.public_availability(48, DATE '2027-01-07', DATE '2027-01-08') a
  JOIN booking.schedule_rules sr ON sr.id = a.rule_id
 ORDER BY a.starts_at, a.ends_at;
