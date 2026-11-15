-- booking_318: oma saunavuoro la/su uudet ajat (t1785u / tarkennus 15.11.2026)
-- Kuluttaja (tuote 25) ja yritys (tuote 48 = kuluttajahinta +20 % brutto).
-- Aloitus vain klo 13 tai 14. 13–14: la 350 €, su 300 € (yritys 420 / 360).
-- Vanha la–su 13–14 250 € deaktivoidaan; ma–to esilöylyt 14–16 250 € jätetään.
-- Muut paketit: 13–15 la 600 / su 550 jne.; 13–22 la 2300 / su 2000.
-- Ei 17-, 18-alkuisia vuoroja (17–19, 18–19, 18–22).
-- Voimassaolot kuten nykyiset la/su-säännöt: valid_to 2026-12-17, jatkuu 2027-01-02.
-- Vanha 13–15 420 € ja vanha 13–14 250 € deaktivoidaan (ei poisteta).
-- DEV: ensimmäinen 318 ajettiin ja peruttiin; tämä tiedosto on lopullinen muoto.
-- DEV-korjaus ajettiin tästä tiedostosta nimellä booking_318b_oma_saunavuoro_weekend.
-- PRODiin ajetaan tämä tiedosto yhtenä migraationa (booking_318), kun Joonas hyväksyy.

DO $booking_318$
DECLARE
  v_note text := 'booking_318 t1785u Joonas 15.11.2026: la/su omat vuorot, aloitus 13 tai 14, 13–14 la 350 / su 300';
  v_deact_mark text := ' | booking_318_deactivated';
  v_windows record;
  v_slot record;
  v_variant_id bigint;
  n_rules int := 0;
  n_variants int := 0;
BEGIN
  -- Vanha 13–15 420 € pois tarjonnasta. Rivejä ei poisteta.
  UPDATE kb.product_price_variants v
     SET active = false,
         updated_at = now(),
         notes = CASE
                   WHEN coalesce(v.notes, '') LIKE '%booking_318_deactivated%' THEN v.notes
                   ELSE coalesce(v.notes, '') || v_deact_mark
                 END
   WHERE v.product_id = 25
     AND v.active
     AND v.price = 420
     AND v.duration_minutes = 120
     AND v.time_start = '13:00'
     AND v.time_end = '15:00'
     AND v.weekdays @> ARRAY[6,7]::smallint[]
     AND cardinality(v.weekdays) = 2;

  UPDATE booking.schedule_rules sr
     SET active = false,
         updated_at = now(),
         notes = CASE
                   WHEN coalesce(sr.notes, '') LIKE '%booking_318_deactivated%' THEN sr.notes
                   ELSE coalesce(sr.notes, '') || v_deact_mark
                 END
   WHERE sr.product_id = 25
     AND sr.active
     AND sr.mode = 'exclusive'
     AND sr.start_time = '13:00'
     AND sr.duration_minutes = 120
     AND sr.weekdays @> ARRAY[6,7]::smallint[]
     AND cardinality(sr.weekdays) = 2
     AND sr.price_variant_id IN (
           SELECT v.id FROM kb.product_price_variants v
            WHERE v.product_id = 25
              AND v.price = 420
              AND v.duration_minutes = 120
              AND v.time_start = '13:00'
              AND v.time_end = '15:00'
         );

  -- Vanha la–su 13–14 250 € pois. Ei kosketa ma–to esilöylyjä (variantti 9, 14–16).
  UPDATE kb.product_price_variants v
     SET active = false,
         updated_at = now(),
         notes = CASE
                   WHEN coalesce(v.notes, '') LIKE '%booking_318_deactivated%' THEN v.notes
                   ELSE coalesce(v.notes, '') || v_deact_mark
                 END
   WHERE v.product_id = 25
     AND v.active
     AND v.price = 250
     AND v.duration_minutes = 60
     AND v.time_start = '13:00'
     AND v.time_end = '14:00'
     AND v.weekdays @> ARRAY[6,7]::smallint[]
     AND cardinality(v.weekdays) = 2;

  UPDATE booking.schedule_rules sr
     SET active = false,
         updated_at = now(),
         notes = CASE
                   WHEN coalesce(sr.notes, '') LIKE '%booking_318_deactivated%' THEN sr.notes
                   ELSE coalesce(sr.notes, '') || v_deact_mark
                 END
   WHERE sr.product_id = 25
     AND sr.active
     AND sr.mode = 'exclusive'
     AND sr.start_time = '13:00'
     AND sr.duration_minutes = 60
     AND sr.weekdays @> ARRAY[6,7]::smallint[]
     AND cardinality(sr.weekdays) = 2
     AND sr.price_variant_id IN (
           SELECT v.id FROM kb.product_price_variants v
            WHERE v.product_id = 25
              AND v.price = 250
              AND v.duration_minutes = 60
              AND v.time_start = '13:00'
              AND v.time_end = '14:00'
         );

  CREATE TEMP TABLE booking_318_slots (
    product_id bigint,
    weekdays smallint[],
    start_time time,
    end_time time,
    duration_minutes integer,
    price numeric(10,2),
    included_persons integer,
    extra_person_price numeric(10,2),
    max_persons integer,
    deadline_minutes integer,
    sort_order integer,
    variant_label text,
    rule_label text,
    rule_label_en text
  ) ON COMMIT DROP;

  INSERT INTO booking_318_slots (
    product_id, weekdays, start_time, end_time, duration_minutes, price,
    included_persons, extra_person_price, max_persons, deadline_minutes, sort_order,
    variant_label, rule_label, rule_label_en
  ) VALUES
    (25, '{6}'::smallint[], '13:00'::time, '14:00'::time, 60, 350.00::numeric, 8, 10.00::numeric, 18, 720, 130, 'La klo 13–14', 'Oma savusaunavuoro la 13–14 (1 h)', 'Private smoke sauna Sat 13–14 (1 h)'),
    (25, '{7}'::smallint[], '13:00'::time, '14:00'::time, 60, 300.00::numeric, 8, 10.00::numeric, 18, 720, 130, 'Su klo 13–14', 'Oma savusaunavuoro su 13–14 (1 h)', 'Private smoke sauna Sun 13–14 (1 h)'),
    (48, '{6}'::smallint[], '13:00'::time, '14:00'::time, 60, 420.00::numeric, 8, 10.00::numeric, 20, 1440, 150, 'La klo 13–14', 'Savusaunavuoro yrityksille la 13–14 (1 h)', 'Smoke sauna for companies Sat 13–14 (1 h)'),
    (48, '{7}'::smallint[], '13:00'::time, '14:00'::time, 60, 360.00::numeric, 8, 10.00::numeric, 20, 1440, 150, 'Su klo 13–14', 'Savusaunavuoro yrityksille su 13–14 (1 h)', 'Smoke sauna for companies Sun 13–14 (1 h)'),
    (25, '{6}'::smallint[], '13:00'::time, '15:00'::time, 120, 600.00::numeric, 8, 10.00::numeric, 18, 720, 131, 'La klo 13–15', 'Oma savusaunavuoro la 13–15 (2 h)', 'Private smoke sauna Sat 13–15 (2 h)'),
    (25, '{7}'::smallint[], '13:00'::time, '15:00'::time, 120, 550.00::numeric, 8, 10.00::numeric, 18, 720, 131, 'Su klo 13–15', 'Oma savusaunavuoro su 13–15 (2 h)', 'Private smoke sauna Sun 13–15 (2 h)'),
    (48, '{6}'::smallint[], '13:00'::time, '15:00'::time, 120, 720.00::numeric, 8, 10.00::numeric, 20, 1440, 151, 'La klo 13–15', 'Savusaunavuoro yrityksille la 13–15 (2 h)', 'Smoke sauna for companies Sat 13–15 (2 h)'),
    (48, '{7}'::smallint[], '13:00'::time, '15:00'::time, 120, 660.00::numeric, 8, 10.00::numeric, 20, 1440, 151, 'Su klo 13–15', 'Savusaunavuoro yrityksille su 13–15 (2 h)', 'Smoke sauna for companies Sun 13–15 (2 h)'),
    (25, '{6}'::smallint[], '13:00'::time, '16:00'::time, 180, 950.00::numeric, 8, 10.00::numeric, 18, 720, 132, 'La klo 13–16', 'Oma savusaunavuoro la 13–16 (3 h)', 'Private smoke sauna Sat 13–16 (3 h)'),
    (25, '{7}'::smallint[], '13:00'::time, '16:00'::time, 180, 850.00::numeric, 8, 10.00::numeric, 18, 720, 132, 'Su klo 13–16', 'Oma savusaunavuoro su 13–16 (3 h)', 'Private smoke sauna Sun 13–16 (3 h)'),
    (48, '{6}'::smallint[], '13:00'::time, '16:00'::time, 180, 1140.00::numeric, 8, 10.00::numeric, 20, 1440, 152, 'La klo 13–16', 'Savusaunavuoro yrityksille la 13–16 (3 h)', 'Smoke sauna for companies Sat 13–16 (3 h)'),
    (48, '{7}'::smallint[], '13:00'::time, '16:00'::time, 180, 1020.00::numeric, 8, 10.00::numeric, 20, 1440, 152, 'Su klo 13–16', 'Savusaunavuoro yrityksille su 13–16 (3 h)', 'Smoke sauna for companies Sun 13–16 (3 h)'),
    (25, '{6}'::smallint[], '13:00'::time, '17:00'::time, 240, 1300.00::numeric, 8, 10.00::numeric, 18, 720, 133, 'La klo 13–17', 'Oma savusaunavuoro la 13–17 (4 h)', 'Private smoke sauna Sat 13–17 (4 h)'),
    (25, '{7}'::smallint[], '13:00'::time, '17:00'::time, 240, 1150.00::numeric, 8, 10.00::numeric, 18, 720, 133, 'Su klo 13–17', 'Oma savusaunavuoro su 13–17 (4 h)', 'Private smoke sauna Sun 13–17 (4 h)'),
    (48, '{6}'::smallint[], '13:00'::time, '17:00'::time, 240, 1560.00::numeric, 8, 10.00::numeric, 20, 1440, 153, 'La klo 13–17', 'Savusaunavuoro yrityksille la 13–17 (4 h)', 'Smoke sauna for companies Sat 13–17 (4 h)'),
    (48, '{7}'::smallint[], '13:00'::time, '17:00'::time, 240, 1380.00::numeric, 8, 10.00::numeric, 20, 1440, 153, 'Su klo 13–17', 'Savusaunavuoro yrityksille su 13–17 (4 h)', 'Smoke sauna for companies Sun 13–17 (4 h)'),
    (25, '{6}'::smallint[], '13:00'::time, '18:00'::time, 300, 1650.00::numeric, 8, 10.00::numeric, 18, 720, 134, 'La klo 13–18', 'Oma savusaunavuoro la 13–18 (5 h)', 'Private smoke sauna Sat 13–18 (5 h)'),
    (25, '{7}'::smallint[], '13:00'::time, '18:00'::time, 300, 1450.00::numeric, 8, 10.00::numeric, 18, 720, 134, 'Su klo 13–18', 'Oma savusaunavuoro su 13–18 (5 h)', 'Private smoke sauna Sun 13–18 (5 h)'),
    (48, '{6}'::smallint[], '13:00'::time, '18:00'::time, 300, 1980.00::numeric, 8, 10.00::numeric, 20, 1440, 154, 'La klo 13–18', 'Savusaunavuoro yrityksille la 13–18 (5 h)', 'Smoke sauna for companies Sat 13–18 (5 h)'),
    (48, '{7}'::smallint[], '13:00'::time, '18:00'::time, 300, 1740.00::numeric, 8, 10.00::numeric, 20, 1440, 154, 'Su klo 13–18', 'Savusaunavuoro yrityksille su 13–18 (5 h)', 'Smoke sauna for companies Sun 13–18 (5 h)'),
    (25, '{6}'::smallint[], '13:00'::time, '19:00'::time, 360, 2000.00::numeric, 8, 10.00::numeric, 18, 720, 135, 'La klo 13–19', 'Oma savusaunavuoro la 13–19 (6 h)', 'Private smoke sauna Sat 13–19 (6 h)'),
    (25, '{7}'::smallint[], '13:00'::time, '19:00'::time, 360, 1750.00::numeric, 8, 10.00::numeric, 18, 720, 135, 'Su klo 13–19', 'Oma savusaunavuoro su 13–19 (6 h)', 'Private smoke sauna Sun 13–19 (6 h)'),
    (48, '{6}'::smallint[], '13:00'::time, '19:00'::time, 360, 2400.00::numeric, 8, 10.00::numeric, 20, 1440, 155, 'La klo 13–19', 'Savusaunavuoro yrityksille la 13–19 (6 h)', 'Smoke sauna for companies Sat 13–19 (6 h)'),
    (48, '{7}'::smallint[], '13:00'::time, '19:00'::time, 360, 2100.00::numeric, 8, 10.00::numeric, 20, 1440, 155, 'Su klo 13–19', 'Savusaunavuoro yrityksille su 13–19 (6 h)', 'Smoke sauna for companies Sun 13–19 (6 h)'),
    (25, '{6}'::smallint[], '13:00'::time, '22:00'::time, 540, 2300.00::numeric, 8, 10.00::numeric, 18, 720, 136, 'La klo 13–22', 'Oma savusaunavuoro la 13–22 (9 h)', 'Private smoke sauna Sat 13–22 (9 h)'),
    (25, '{7}'::smallint[], '13:00'::time, '22:00'::time, 540, 2000.00::numeric, 8, 10.00::numeric, 18, 720, 136, 'Su klo 13–22', 'Oma savusaunavuoro su 13–22 (9 h)', 'Private smoke sauna Sun 13–22 (9 h)'),
    (48, '{6}'::smallint[], '13:00'::time, '22:00'::time, 540, 2760.00::numeric, 8, 10.00::numeric, 20, 1440, 156, 'La klo 13–22', 'Savusaunavuoro yrityksille la 13–22 (9 h)', 'Smoke sauna for companies Sat 13–22 (9 h)'),
    (48, '{7}'::smallint[], '13:00'::time, '22:00'::time, 540, 2400.00::numeric, 8, 10.00::numeric, 20, 1440, 156, 'Su klo 13–22', 'Savusaunavuoro yrityksille su 13–22 (9 h)', 'Smoke sauna for companies Sun 13–22 (9 h)'),
    (25, '{6}'::smallint[], '14:00'::time, '15:00'::time, 60, 350.00::numeric, 8, 10.00::numeric, 18, 720, 137, 'La klo 14–15', 'Oma savusaunavuoro la 14–15 (1 h)', 'Private smoke sauna Sat 14–15 (1 h)'),
    (25, '{7}'::smallint[], '14:00'::time, '15:00'::time, 60, 300.00::numeric, 8, 10.00::numeric, 18, 720, 137, 'Su klo 14–15', 'Oma savusaunavuoro su 14–15 (1 h)', 'Private smoke sauna Sun 14–15 (1 h)'),
    (48, '{6}'::smallint[], '14:00'::time, '15:00'::time, 60, 420.00::numeric, 8, 10.00::numeric, 20, 1440, 157, 'La klo 14–15', 'Savusaunavuoro yrityksille la 14–15 (1 h)', 'Smoke sauna for companies Sat 14–15 (1 h)'),
    (48, '{7}'::smallint[], '14:00'::time, '15:00'::time, 60, 360.00::numeric, 8, 10.00::numeric, 20, 1440, 157, 'Su klo 14–15', 'Savusaunavuoro yrityksille su 14–15 (1 h)', 'Smoke sauna for companies Sun 14–15 (1 h)'),
    (25, '{6}'::smallint[], '14:00'::time, '16:00'::time, 120, 600.00::numeric, 8, 10.00::numeric, 18, 720, 138, 'La klo 14–16', 'Oma savusaunavuoro la 14–16 (2 h)', 'Private smoke sauna Sat 14–16 (2 h)'),
    (25, '{7}'::smallint[], '14:00'::time, '16:00'::time, 120, 550.00::numeric, 8, 10.00::numeric, 18, 720, 138, 'Su klo 14–16', 'Oma savusaunavuoro su 14–16 (2 h)', 'Private smoke sauna Sun 14–16 (2 h)'),
    (48, '{6}'::smallint[], '14:00'::time, '16:00'::time, 120, 720.00::numeric, 8, 10.00::numeric, 20, 1440, 158, 'La klo 14–16', 'Savusaunavuoro yrityksille la 14–16 (2 h)', 'Smoke sauna for companies Sat 14–16 (2 h)'),
    (48, '{7}'::smallint[], '14:00'::time, '16:00'::time, 120, 660.00::numeric, 8, 10.00::numeric, 20, 1440, 158, 'Su klo 14–16', 'Savusaunavuoro yrityksille su 14–16 (2 h)', 'Smoke sauna for companies Sun 14–16 (2 h)'),
    (25, '{6}'::smallint[], '14:00'::time, '17:00'::time, 180, 950.00::numeric, 8, 10.00::numeric, 18, 720, 139, 'La klo 14–17', 'Oma savusaunavuoro la 14–17 (3 h)', 'Private smoke sauna Sat 14–17 (3 h)'),
    (25, '{7}'::smallint[], '14:00'::time, '17:00'::time, 180, 850.00::numeric, 8, 10.00::numeric, 18, 720, 139, 'Su klo 14–17', 'Oma savusaunavuoro su 14–17 (3 h)', 'Private smoke sauna Sun 14–17 (3 h)'),
    (48, '{6}'::smallint[], '14:00'::time, '17:00'::time, 180, 1140.00::numeric, 8, 10.00::numeric, 20, 1440, 159, 'La klo 14–17', 'Savusaunavuoro yrityksille la 14–17 (3 h)', 'Smoke sauna for companies Sat 14–17 (3 h)'),
    (48, '{7}'::smallint[], '14:00'::time, '17:00'::time, 180, 1020.00::numeric, 8, 10.00::numeric, 20, 1440, 159, 'Su klo 14–17', 'Savusaunavuoro yrityksille su 14–17 (3 h)', 'Smoke sauna for companies Sun 14–17 (3 h)'),
    (25, '{6}'::smallint[], '14:00'::time, '18:00'::time, 240, 1300.00::numeric, 8, 10.00::numeric, 18, 720, 140, 'La klo 14–18', 'Oma savusaunavuoro la 14–18 (4 h)', 'Private smoke sauna Sat 14–18 (4 h)'),
    (25, '{7}'::smallint[], '14:00'::time, '18:00'::time, 240, 1150.00::numeric, 8, 10.00::numeric, 18, 720, 140, 'Su klo 14–18', 'Oma savusaunavuoro su 14–18 (4 h)', 'Private smoke sauna Sun 14–18 (4 h)'),
    (48, '{6}'::smallint[], '14:00'::time, '18:00'::time, 240, 1560.00::numeric, 8, 10.00::numeric, 20, 1440, 160, 'La klo 14–18', 'Savusaunavuoro yrityksille la 14–18 (4 h)', 'Smoke sauna for companies Sat 14–18 (4 h)'),
    (48, '{7}'::smallint[], '14:00'::time, '18:00'::time, 240, 1380.00::numeric, 8, 10.00::numeric, 20, 1440, 160, 'Su klo 14–18', 'Savusaunavuoro yrityksille su 14–18 (4 h)', 'Smoke sauna for companies Sun 14–18 (4 h)'),
    (25, '{6}'::smallint[], '14:00'::time, '19:00'::time, 300, 1650.00::numeric, 8, 10.00::numeric, 18, 720, 141, 'La klo 14–19', 'Oma savusaunavuoro la 14–19 (5 h)', 'Private smoke sauna Sat 14–19 (5 h)'),
    (25, '{7}'::smallint[], '14:00'::time, '19:00'::time, 300, 1450.00::numeric, 8, 10.00::numeric, 18, 720, 141, 'Su klo 14–19', 'Oma savusaunavuoro su 14–19 (5 h)', 'Private smoke sauna Sun 14–19 (5 h)'),
    (48, '{6}'::smallint[], '14:00'::time, '19:00'::time, 300, 1980.00::numeric, 8, 10.00::numeric, 20, 1440, 161, 'La klo 14–19', 'Savusaunavuoro yrityksille la 14–19 (5 h)', 'Smoke sauna for companies Sat 14–19 (5 h)'),
    (48, '{7}'::smallint[], '14:00'::time, '19:00'::time, 300, 1740.00::numeric, 8, 10.00::numeric, 20, 1440, 161, 'Su klo 14–19', 'Savusaunavuoro yrityksille su 14–19 (5 h)', 'Smoke sauna for companies Sun 14–19 (5 h)');

  FOR v_slot IN
    SELECT * FROM booking_318_slots s
     WHERE NOT EXISTS (
       SELECT 1 FROM kb.product_price_variants v
        WHERE v.product_id = s.product_id
          AND v.time_start = s.start_time
          AND v.time_end = s.end_time
          AND v.weekdays = s.weekdays
          AND v.duration_minutes = s.duration_minutes
          AND v.price = s.price
          AND coalesce(v.notes, '') LIKE '%booking_318%'
          AND coalesce(v.notes, '') NOT LIKE '%booking_318_deactivated%'
     )
  LOOP
    INSERT INTO kb.product_price_variants (
      product_id, label, price, currency, duration_minutes, weekdays,
      time_start, time_end, included_persons, extra_person_price,
      valid_from, valid_to, notes, confidence, needs_review, active, created_at, updated_at
    ) VALUES (
      v_slot.product_id, v_slot.variant_label, v_slot.price, 'EUR', v_slot.duration_minutes, v_slot.weekdays,
      v_slot.start_time, v_slot.end_time, v_slot.included_persons, v_slot.extra_person_price,
      NULL, NULL, v_note, 'medium', false, true, now(), now()
    );
    n_variants := n_variants + 1;
  END LOOP;

  FOR v_windows IN
    SELECT * FROM (VALUES
      (NULL::date, DATE '2026-12-17'),
      (DATE '2027-01-02', NULL::date)
    ) AS w(valid_from, valid_to)
  LOOP
    FOR v_slot IN SELECT * FROM booking_318_slots LOOP
      SELECT v.id INTO v_variant_id
        FROM kb.product_price_variants v
       WHERE v.product_id = v_slot.product_id
         AND v.time_start = v_slot.start_time
         AND v.time_end = v_slot.end_time
         AND v.weekdays = v_slot.weekdays
         AND v.duration_minutes = v_slot.duration_minutes
         AND v.price = v_slot.price
         AND v.active
         AND coalesce(v.notes, '') LIKE '%booking_318%'
         AND coalesce(v.notes, '') NOT LIKE '%booking_318_deactivated%'
       ORDER BY v.id DESC
       LIMIT 1;

      IF v_variant_id IS NULL THEN
        RAISE EXCEPTION 'booking_318: hintariviä ei löydy (%) % %–%', v_slot.product_id, v_slot.weekdays, v_slot.start_time, v_slot.end_time;
      END IF;

      IF EXISTS (
        SELECT 1 FROM booking.schedule_rules sr
         WHERE sr.product_id = v_slot.product_id
           AND sr.start_time = v_slot.start_time
           AND sr.duration_minutes = v_slot.duration_minutes
           AND sr.weekdays = v_slot.weekdays
           AND sr.price_variant_id = v_variant_id
           AND sr.valid_from IS NOT DISTINCT FROM v_windows.valid_from
           AND sr.valid_to IS NOT DISTINCT FROM v_windows.valid_to
           AND coalesce(sr.notes, '') LIKE '%booking_318%'
           AND coalesce(sr.notes, '') NOT LIKE '%booking_318_deactivated%'
      ) THEN
        CONTINUE;
      END IF;

      INSERT INTO booking.schedule_rules (
        product_id, label, label_en, mode, space_id, weekdays, start_time, duration_minutes,
        valid_from, valid_to, min_persons, max_persons, price_mode, price_variant_id,
        included_persons, extra_person_price, deadline_minutes, active, sort_order, notes,
        kind, training_segment_only, closure_exempt, created_at, updated_at
      ) VALUES (
        v_slot.product_id, v_slot.rule_label, v_slot.rule_label_en, 'exclusive', 1,
        v_slot.weekdays, v_slot.start_time, v_slot.duration_minutes,
        v_windows.valid_from, v_windows.valid_to, 1, v_slot.max_persons, 'fixed_plus_extra', v_variant_id,
        v_slot.included_persons, NULL, v_slot.deadline_minutes, true, v_slot.sort_order, v_note,
        'regular', false, false, now(), now()
      );
      n_rules := n_rules + 1;
    END LOOP;
  END LOOP;

  RAISE NOTICE 'booking_318: lisätty % hintariviä ja % sääntöä', n_variants, n_rules;
END
$booking_318$;
