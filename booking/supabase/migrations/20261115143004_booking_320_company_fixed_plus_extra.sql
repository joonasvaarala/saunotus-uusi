-- booking_320: yrityksen tuote 48 jäljellä olevat fixed-rivit → fixed_plus_extra (t1807u, Joonas 15.11.2026 16.28)
-- Vain nämä kaksi aktiivista riviä:
--   ma–to 14–16 350 € (sääntö tähän asti fixed)
--   pe 12–21 850 € (sääntö tähän asti fixed)
-- Perushinnat pysyvät. Uudet rivit: fixed_plus_extra, 8 hlö sisältyy, lisähenkilö +10 €.
-- Voimassaoloikkunat ennallaan (ei joulukatkoa, valid_from/valid_to NULL), kuten nykyiset rivit.
-- Vanhaa booking_319:n deaktivoimaa pe 16–21 500 € -riviä (edelleen fixed) EI muuteta.
-- Vanhoja rivejä ei poisteta. Varaukset ja tilaukset jätetään ennalleen.

DO $booking_320$
DECLARE
  v_note text := 'booking_320 t1807u Joonas 15.11.2026: yritys 48 ma–to 14–16 ja pe 12–21 fixed_plus_extra, 8 hlö + 10 €';
  v_deact_mark text := ' | booking_320_deactivated';
  v_slot record;
  v_variant_id bigint;
  n_rules int := 0;
  n_variants int := 0;
BEGIN
  -- Ma–to 14–16 350 € pois tarjonnasta. Rivejä ei poisteta.
  UPDATE kb.product_price_variants v
     SET active = false,
         updated_at = now(),
         notes = CASE
                   WHEN coalesce(v.notes, '') LIKE '%booking_320_deactivated%' THEN v.notes
                   ELSE coalesce(v.notes, '') || v_deact_mark
                 END
   WHERE v.product_id = 48
     AND v.active
     AND v.price = 350
     AND v.duration_minutes = 120
     AND v.time_start = '14:00'
     AND v.time_end = '16:00'
     AND v.weekdays = ARRAY[1,2,3,4]::smallint[];

  UPDATE booking.schedule_rules sr
     SET active = false,
         updated_at = now(),
         notes = CASE
                   WHEN coalesce(sr.notes, '') LIKE '%booking_320_deactivated%' THEN sr.notes
                   ELSE coalesce(sr.notes, '') || v_deact_mark
                 END
   WHERE sr.product_id = 48
     AND sr.active
     AND sr.price_mode = 'fixed'
     AND sr.mode = 'exclusive'
     AND sr.start_time = '14:00'
     AND sr.duration_minutes = 120
     AND sr.weekdays = ARRAY[1,2,3,4]::smallint[]
     AND sr.price_variant_id IN (
           SELECT v.id FROM kb.product_price_variants v
            WHERE v.product_id = 48
              AND v.price = 350
              AND v.duration_minutes = 120
              AND v.time_start = '14:00'
              AND v.time_end = '16:00'
              AND v.weekdays = ARRAY[1,2,3,4]::smallint[]
         );

  -- Pe 12–21 850 € pois tarjonnasta. Ei koske booking_319 pe 14–19 850 € -riviä.
  UPDATE kb.product_price_variants v
     SET active = false,
         updated_at = now(),
         notes = CASE
                   WHEN coalesce(v.notes, '') LIKE '%booking_320_deactivated%' THEN v.notes
                   ELSE coalesce(v.notes, '') || v_deact_mark
                 END
   WHERE v.product_id = 48
     AND v.active
     AND v.price = 850
     AND v.duration_minutes = 540
     AND v.time_start = '12:00'
     AND v.time_end = '21:00'
     AND v.weekdays = ARRAY[5]::smallint[];

  UPDATE booking.schedule_rules sr
     SET active = false,
         updated_at = now(),
         notes = CASE
                   WHEN coalesce(sr.notes, '') LIKE '%booking_320_deactivated%' THEN sr.notes
                   ELSE coalesce(sr.notes, '') || v_deact_mark
                 END
   WHERE sr.product_id = 48
     AND sr.active
     AND sr.price_mode = 'fixed'
     AND sr.mode = 'exclusive'
     AND sr.start_time = '12:00'
     AND sr.duration_minutes = 540
     AND sr.weekdays = ARRAY[5]::smallint[]
     AND sr.price_variant_id IN (
           SELECT v.id FROM kb.product_price_variants v
            WHERE v.product_id = 48
              AND v.price = 850
              AND v.duration_minutes = 540
              AND v.time_start = '12:00'
              AND v.time_end = '21:00'
              AND v.weekdays = ARRAY[5]::smallint[]
         );

  CREATE TEMP TABLE booking_320_slots (
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

  INSERT INTO booking_320_slots (
    product_id, weekdays, start_time, end_time, duration_minutes, price,
    included_persons, extra_person_price, max_persons, deadline_minutes, sort_order,
    variant_label, rule_label, rule_label_en
  ) VALUES
    (48, '{1,2,3,4}'::smallint[], '14:00'::time, '16:00'::time, 120, 350.00::numeric, 8, 10.00::numeric, 20, 1440, 230,
     'Ma–to klo 14–16', 'Savusaunavuoro yrityksille ma–to 14–16 (2 h)', 'Smoke sauna for companies Mon–Thu 14–16 (2 h)'),
    (48, '{5}'::smallint[], '12:00'::time, '21:00'::time, 540, 850.00::numeric, 8, 10.00::numeric, 20, 1440, 231,
     'Pe klo 12–21 (9 h)', 'Savusaunavuoro yrityksille pe 12–21 (9 h)', 'Smoke sauna for companies Fri 12–21 (9 h)');

  FOR v_slot IN
    SELECT * FROM booking_320_slots s
     WHERE NOT EXISTS (
       SELECT 1 FROM kb.product_price_variants v
        WHERE v.product_id = s.product_id
          AND v.time_start = s.start_time
          AND v.time_end = s.end_time
          AND v.weekdays = s.weekdays
          AND v.duration_minutes = s.duration_minutes
          AND v.price = s.price
          AND coalesce(v.notes, '') LIKE '%booking_320%'
          AND coalesce(v.notes, '') NOT LIKE '%booking_320_deactivated%'
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

  FOR v_slot IN SELECT * FROM booking_320_slots LOOP
    SELECT v.id INTO v_variant_id
      FROM kb.product_price_variants v
     WHERE v.product_id = v_slot.product_id
       AND v.time_start = v_slot.start_time
       AND v.time_end = v_slot.end_time
       AND v.weekdays = v_slot.weekdays
       AND v.duration_minutes = v_slot.duration_minutes
       AND v.price = v_slot.price
       AND v.active
       AND coalesce(v.notes, '') LIKE '%booking_320%'
       AND coalesce(v.notes, '') NOT LIKE '%booking_320_deactivated%'
     ORDER BY v.id DESC
     LIMIT 1;

    IF v_variant_id IS NULL THEN
      RAISE EXCEPTION 'booking_320: hintariviä ei löydy (%) % %–%', v_slot.product_id, v_slot.weekdays, v_slot.start_time, v_slot.end_time;
    END IF;

    IF EXISTS (
      SELECT 1 FROM booking.schedule_rules sr
       WHERE sr.product_id = v_slot.product_id
         AND sr.start_time = v_slot.start_time
         AND sr.duration_minutes = v_slot.duration_minutes
         AND sr.weekdays = v_slot.weekdays
         AND sr.price_variant_id = v_variant_id
         AND sr.valid_from IS NULL
         AND sr.valid_to IS NULL
         AND coalesce(sr.notes, '') LIKE '%booking_320%'
         AND coalesce(sr.notes, '') NOT LIKE '%booking_320_deactivated%'
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
      NULL, NULL, 1, v_slot.max_persons, 'fixed_plus_extra', v_variant_id,
      v_slot.included_persons, NULL, v_slot.deadline_minutes, true, v_slot.sort_order, v_note,
      'regular', false, false, now(), now()
    );
    n_rules := n_rules + 1;
  END LOOP;

  RAISE NOTICE 'booking_320: lisätty % hintariviä ja % sääntöä', n_variants, n_rules;
END
$booking_320$;
