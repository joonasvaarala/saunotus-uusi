-- booking_319: oma saunavuoro ma–pe yhdistelmät, lopulliset hinnat (t1805u, Joonas 15.11.2026 16.24)
-- Kuluttaja (tuote 25) ja yritys (tuote 48). Uudet yritysrivit: fixed_plus_extra, 8 hlö + 10 €.
-- Hinnat sis. ALV 25,5 %.
--
-- Uudet / korvaavat vuorot:
--   25 ma–to: 14–19 650, 16–21 600, 14–21 820
--   25 pe:    14–19 720; pe 16–21 550→650 ja pe 14–21 650→900 (vanha deaktivoidaan, uusi luodaan)
--   48 ma–to: 16–19 500, 14–19 790, 16–21 720, 14–21 990
--   48 pe:    14–16 380 (uusi), 16–19 500, 14–19 850, 16–21 500→780, 14–21 1080 (uusi)
--
-- Ennalleen:
--   25 ma–to 14–16 250, pe 14–16 300, ma–pe 16–19 420
--   48 ma–to 14–16 350 (fixed, ei +20 %), pe 12–21 850 (fixed)
--   to 31.12.2026 erikoissääntö 16–21 500 € ei kosketa
--
-- Vanhoja rivejä ei poisteta. Jos deaktivoitaviin sääntöihin liittyy varauksia, myyty hinta jää
-- tilausriville ja vanhaan sääntöön (kuten booking_318 / varaus 12385).
-- Voimassaolot kuten tuotteella 25: valid_to 2026-12-17, jatkuu 2027-01-02.
-- Nykyiset yrityksen fixed-rivit (ma–to 14–16 ja pe 12–21) jätetään fixed-tilaan.

DO $booking_319$
DECLARE
  v_note text := 'booking_319 t1805u Joonas 15.11.2026: arkiyhdistelmät lopulliset hinnat, pe 14–21/16–21 päivitetty';
  v_deact_mark text := ' | booking_319_deactivated';
  v_windows record;
  v_slot record;
  v_variant_id bigint;
  n_rules int := 0;
  n_variants int := 0;
BEGIN
  -- Pe 14–21 650 € pois tarjonnasta (tuote 25). Rivejä ei poisteta. Ei koske 31.12. sääntöä.
  UPDATE kb.product_price_variants v
     SET active = false,
         updated_at = now(),
         notes = CASE
                   WHEN coalesce(v.notes, '') LIKE '%booking_319_deactivated%' THEN v.notes
                   ELSE coalesce(v.notes, '') || v_deact_mark
                 END
   WHERE v.product_id = 25
     AND v.active
     AND v.price = 650
     AND v.duration_minutes = 420
     AND v.time_start = '14:00'
     AND v.time_end = '21:00'
     AND v.weekdays = ARRAY[5]::smallint[];
  UPDATE booking.schedule_rules sr
     SET active = false,
         updated_at = now(),
         notes = CASE
                   WHEN coalesce(sr.notes, '') LIKE '%booking_319_deactivated%' THEN sr.notes
                   ELSE coalesce(sr.notes, '') || v_deact_mark
                 END
   WHERE sr.product_id = 25
     AND sr.active
     AND sr.mode = 'exclusive'
     AND sr.start_time = '14:00'
     AND sr.duration_minutes = 420
     AND sr.weekdays = ARRAY[5]::smallint[]
     AND sr.price_variant_id IN (
           SELECT v.id FROM kb.product_price_variants v
            WHERE v.product_id = 25
              AND v.price = 650
              AND v.duration_minutes = 420
              AND v.time_start = '14:00'
              AND v.time_end = '21:00'
              AND v.weekdays = ARRAY[5]::smallint[]
         );

  -- Pe 16–21 550 € pois tarjonnasta (tuote 25).
  UPDATE kb.product_price_variants v
     SET active = false,
         updated_at = now(),
         notes = CASE
                   WHEN coalesce(v.notes, '') LIKE '%booking_319_deactivated%' THEN v.notes
                   ELSE coalesce(v.notes, '') || v_deact_mark
                 END
   WHERE v.product_id = 25
     AND v.active
     AND v.price = 550
     AND v.duration_minutes = 300
     AND v.time_start = '16:00'
     AND v.time_end = '21:00'
     AND v.weekdays = ARRAY[5]::smallint[];
  UPDATE booking.schedule_rules sr
     SET active = false,
         updated_at = now(),
         notes = CASE
                   WHEN coalesce(sr.notes, '') LIKE '%booking_319_deactivated%' THEN sr.notes
                   ELSE coalesce(sr.notes, '') || v_deact_mark
                 END
   WHERE sr.product_id = 25
     AND sr.active
     AND sr.mode = 'exclusive'
     AND sr.start_time = '16:00'
     AND sr.duration_minutes = 300
     AND sr.weekdays = ARRAY[5]::smallint[]
     AND sr.price_variant_id IN (
           SELECT v.id FROM kb.product_price_variants v
            WHERE v.product_id = 25
              AND v.price = 550
              AND v.duration_minutes = 300
              AND v.time_start = '16:00'
              AND v.time_end = '21:00'
              AND v.weekdays = ARRAY[5]::smallint[]
         );

  -- Yritys pe 16–21 500 € pois tarjonnasta. Ei koske tuotteen 25 to 31.12. 16–21 500 € -sääntöä.
  UPDATE kb.product_price_variants v
     SET active = false,
         updated_at = now(),
         notes = CASE
                   WHEN coalesce(v.notes, '') LIKE '%booking_319_deactivated%' THEN v.notes
                   ELSE coalesce(v.notes, '') || v_deact_mark
                 END
   WHERE v.product_id = 48
     AND v.active
     AND v.price = 500
     AND v.duration_minutes = 300
     AND v.time_start = '16:00'
     AND v.time_end = '21:00'
     AND v.weekdays = ARRAY[5]::smallint[];

  UPDATE booking.schedule_rules sr
     SET active = false,
         updated_at = now(),
         notes = CASE
                   WHEN coalesce(sr.notes, '') LIKE '%booking_319_deactivated%' THEN sr.notes
                   ELSE coalesce(sr.notes, '') || v_deact_mark
                 END
   WHERE sr.product_id = 48
     AND sr.active
     AND sr.mode = 'exclusive'
     AND sr.start_time = '16:00'
     AND sr.duration_minutes = 300
     AND sr.weekdays = ARRAY[5]::smallint[]
     AND sr.price_variant_id IN (
           SELECT v.id FROM kb.product_price_variants v
            WHERE v.product_id = 48
              AND v.price = 500
              AND v.duration_minutes = 300
              AND v.time_start = '16:00'
              AND v.time_end = '21:00'
              AND v.weekdays = ARRAY[5]::smallint[]
         );

  CREATE TEMP TABLE booking_319_slots (
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

  INSERT INTO booking_319_slots (
    product_id, weekdays, start_time, end_time, duration_minutes, price,
    included_persons, extra_person_price, max_persons, deadline_minutes, sort_order,
    variant_label, rule_label, rule_label_en
  ) VALUES
    (25, '{1,2,3,4}'::smallint[], '14:00'::time, '19:00'::time, 300, 650.00::numeric, 8, 10.00::numeric, 18, 720, 210,
     'Ma–to klo 14–19', 'Oma savusaunavuoro ma–to 14–19 (5 h)', 'Private smoke sauna Mon–Thu 14–19 (5 h)'),
    (25, '{1,2,3,4}'::smallint[], '16:00'::time, '21:00'::time, 300, 600.00::numeric, 8, 10.00::numeric, 18, 720, 211,
     'Ma–to klo 16–21', 'Oma savusaunavuoro ma–to 16–21 (5 h)', 'Private smoke sauna Mon–Thu 16–21 (5 h)'),
    (25, '{1,2,3,4}'::smallint[], '14:00'::time, '21:00'::time, 420, 820.00::numeric, 8, 10.00::numeric, 18, 720, 212,
     'Ma–to klo 14–21', 'Oma savusaunavuoro ma–to 14–21 (7 h)', 'Private smoke sauna Mon–Thu 14–21 (7 h)'),
    (25, '{5}'::smallint[], '14:00'::time, '19:00'::time, 300, 720.00::numeric, 8, 10.00::numeric, 18, 720, 213,
     'Pe klo 14–19', 'Oma savusaunavuoro pe 14–19 (5 h)', 'Private smoke sauna Fri 14–19 (5 h)'),
    (25, '{5}'::smallint[], '16:00'::time, '21:00'::time, 300, 650.00::numeric, 8, 10.00::numeric, 18, 720, 214,
     'Pe klo 16–21', 'Oma savusaunavuoro pe 16–21 (5 h)', 'Private smoke sauna Fri 16–21 (5 h)'),
    (25, '{5}'::smallint[], '14:00'::time, '21:00'::time, 420, 900.00::numeric, 8, 10.00::numeric, 18, 720, 215,
     'Pe klo 14–21', 'Oma savusaunavuoro pe 14–21 (7 h)', 'Private smoke sauna Fri 14–21 (7 h)'),
    (48, '{5}'::smallint[], '14:00'::time, '16:00'::time, 120, 380.00::numeric, 8, 10.00::numeric, 20, 1440, 220,
     'Pe klo 14–16', 'Savusaunavuoro yrityksille pe 14–16 (2 h)', 'Smoke sauna for companies Fri 14–16 (2 h)'),
    (48, '{1,2,3,4,5}'::smallint[], '16:00'::time, '19:00'::time, 180, 500.00::numeric, 8, 10.00::numeric, 20, 1440, 221,
     'Ma–pe klo 16–19', 'Savusaunavuoro yrityksille ma–pe 16–19 (3 h)', 'Smoke sauna for companies Mon–Fri 16–19 (3 h)'),
    (48, '{1,2,3,4}'::smallint[], '14:00'::time, '19:00'::time, 300, 790.00::numeric, 8, 10.00::numeric, 20, 1440, 222,
     'Ma–to klo 14–19', 'Savusaunavuoro yrityksille ma–to 14–19 (5 h)', 'Smoke sauna for companies Mon–Thu 14–19 (5 h)'),
    (48, '{5}'::smallint[], '14:00'::time, '19:00'::time, 300, 850.00::numeric, 8, 10.00::numeric, 20, 1440, 223,
     'Pe klo 14–19', 'Savusaunavuoro yrityksille pe 14–19 (5 h)', 'Smoke sauna for companies Fri 14–19 (5 h)'),
    (48, '{1,2,3,4}'::smallint[], '16:00'::time, '21:00'::time, 300, 720.00::numeric, 8, 10.00::numeric, 20, 1440, 224,
     'Ma–to klo 16–21', 'Savusaunavuoro yrityksille ma–to 16–21 (5 h)', 'Smoke sauna for companies Mon–Thu 16–21 (5 h)'),
    (48, '{5}'::smallint[], '16:00'::time, '21:00'::time, 300, 780.00::numeric, 8, 10.00::numeric, 20, 1440, 225,
     'Pe klo 16–21', 'Savusaunavuoro yrityksille pe 16–21 (5 h)', 'Smoke sauna for companies Fri 16–21 (5 h)'),
    (48, '{1,2,3,4}'::smallint[], '14:00'::time, '21:00'::time, 420, 990.00::numeric, 8, 10.00::numeric, 20, 1440, 226,
     'Ma–to klo 14–21', 'Savusaunavuoro yrityksille ma–to 14–21 (7 h)', 'Smoke sauna for companies Mon–Thu 14–21 (7 h)'),
    (48, '{5}'::smallint[], '14:00'::time, '21:00'::time, 420, 1080.00::numeric, 8, 10.00::numeric, 20, 1440, 227,
     'Pe klo 14–21', 'Savusaunavuoro yrityksille pe 14–21 (7 h)', 'Smoke sauna for companies Fri 14–21 (7 h)');

  FOR v_slot IN
    SELECT * FROM booking_319_slots s
     WHERE NOT EXISTS (
       SELECT 1 FROM kb.product_price_variants v
        WHERE v.product_id = s.product_id
          AND v.time_start = s.start_time
          AND v.time_end = s.end_time
          AND v.weekdays = s.weekdays
          AND v.duration_minutes = s.duration_minutes
          AND v.price = s.price
          AND coalesce(v.notes, '') LIKE '%booking_319%'
          AND coalesce(v.notes, '') NOT LIKE '%booking_319_deactivated%'
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
    FOR v_slot IN SELECT * FROM booking_319_slots LOOP
      SELECT v.id INTO v_variant_id
        FROM kb.product_price_variants v
       WHERE v.product_id = v_slot.product_id
         AND v.time_start = v_slot.start_time
         AND v.time_end = v_slot.end_time
         AND v.weekdays = v_slot.weekdays
         AND v.duration_minutes = v_slot.duration_minutes
         AND v.price = v_slot.price
         AND v.active
         AND coalesce(v.notes, '') LIKE '%booking_319%'
         AND coalesce(v.notes, '') NOT LIKE '%booking_319_deactivated%'
       ORDER BY v.id DESC
       LIMIT 1;

      IF v_variant_id IS NULL THEN
        RAISE EXCEPTION 'booking_319: hintariviä ei löydy (%) % %–%', v_slot.product_id, v_slot.weekdays, v_slot.start_time, v_slot.end_time;
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
           AND coalesce(sr.notes, '') LIKE '%booking_319%'
           AND coalesce(sr.notes, '') NOT LIKE '%booking_319_deactivated%'
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

  RAISE NOTICE 'booking_319: lisätty % hintariviä ja % sääntöä', n_variants, n_rules;
END
$booking_319$;
