-- booking_322 jälkitarkistukset (aja vasta migraation jälkeen, ei erillisenä migraationa).
-- Ei luo tilauksia. Live-testi tehdään erikseen DEVissä ja perutaan.
-- Odotetut md5:t: _counter_lines=2d9eb2ff3efaca26c77aa67479c7a522
--                 _counter_checkout=c330df1b8d7b0b3d580f8facedb1331e
--                 admin_pos_checkout=caecad15c91d17baea0f112afb5723ef (ennallaan)

CREATE TEMP TABLE IF NOT EXISTS booking_322_chk (k text, v text);

INSERT INTO booking_322_chk
SELECT 'lines_has_unbooked',
       (position('unbooked' in pg_get_functiondef('booking._counter_lines(jsonb,text)'::regprocedure)) > 0)::text
UNION ALL
SELECT 'checkout_has_unbooked',
       (position('unbooked' in pg_get_functiondef('booking._counter_checkout(text,jsonb,text,text,text)'::regprocedure)) > 0)::text
UNION ALL
SELECT 'lines_md5', md5(pg_get_functiondef('booking._counter_lines(jsonb,text)'::regprocedure))
UNION ALL
SELECT 'checkout_md5', md5(pg_get_functiondef('booking._counter_checkout(text,jsonb,text,text,text)'::regprocedure))
UNION ALL
SELECT 'admin_pos_checkout_unchanged',
       (md5(pg_get_functiondef('booking.admin_pos_checkout(jsonb,text,text)'::regprocedure)) = 'caecad15c91d17baea0f112afb5723ef')::text
UNION ALL
SELECT 'admin_pos_checkout_still_pos_use',
       (position('pos.use' in pg_get_functiondef('booking.admin_pos_checkout(jsonb,text,text)'::regprocedure)) > 0)::text
UNION ALL
SELECT 'lines_not_granted_authenticated',
       (NOT has_function_privilege('authenticated', 'booking._counter_lines(jsonb,text)', 'EXECUTE'))::text
UNION ALL
SELECT 'checkout_not_granted_authenticated',
       (NOT has_function_privilege('authenticated', 'booking._counter_checkout(text,jsonb,text,text,text)', 'EXECUTE'))::text
UNION ALL
SELECT 'admin_granted_authenticated',
       has_function_privilege('authenticated', 'booking.admin_pos_checkout(jsonb,text,text)', 'EXECUTE')::text;

INSERT INTO booking_322_chk
SELECT 'unbooked_ok',
       (l.product_id = 10 AND l.unit_price = 99 AND l.vat_rate = 25.5
        AND l.line_total = 99 AND l.unbooked IS TRUE AND l.note = '16.11.2026, 1 hlö'
        AND l.product_name = 'Saunahoito')::text
  FROM booking._counter_lines(
        jsonb_build_array(jsonb_build_object(
          'product_id', 10, 'quantity', 1, 'unbooked', true, 'note', '16.11.2026, 1 hlö')),
        'pos') l;

INSERT INTO booking_322_chk
SELECT 'pos_product_still_ok',
       (l.product_id = 44 AND l.unit_price = 13 AND l.unbooked IS FALSE AND l.note IS NULL)::text
  FROM booking._counter_lines(
        jsonb_build_array(jsonb_build_object('product_id', 44, 'quantity', 1)),
        'pos') l;

DO $e$
DECLARE
  v_code text;
BEGIN
  BEGIN
    PERFORM * FROM booking._counter_lines(
      jsonb_build_array(jsonb_build_object('product_id', 10, 'quantity', 1)),
      'pos');
    INSERT INTO booking_322_chk VALUES ('without_unbooked_rejected', 'UNEXPECTED_SUCCESS');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_code = PG_EXCEPTION_DETAIL;
    INSERT INTO booking_322_chk VALUES ('without_unbooked_rejected', (v_code = 'not_counter_product')::text);
  END;

  BEGIN
    PERFORM * FROM booking._counter_lines(
      jsonb_build_array(jsonb_build_object('product_id', 10, 'quantity', 1, 'unbooked', true, 'unit_price', 1)),
      'pos');
    INSERT INTO booking_322_chk VALUES ('price_locked', 'UNEXPECTED_SUCCESS');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_code = PG_EXCEPTION_DETAIL;
    INSERT INTO booking_322_chk VALUES ('price_locked', (v_code = 'price_locked')::text);
  END;
END $e$;

SELECT k, v FROM booking_322_chk ORDER BY 1;
