-- t226: koulutuksen ilmoittautuminen (booking_226).
-- Ajo (psql, migraatiot ja fixtures/10_test_helpers.sql ajettu):
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=0 -f t226_training_signup.sql
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=0 -v tz=Europe/Helsinki -f t226_training_signup.sql
-- Lopussa tahallinen poikkeus kumoaa testidatan ja rollback-kokeilun. Ei tuotantoon.
\if :{?tz}
\else
\set tz UTC
\endif
begin;
set local timezone = :'tz';
set local lock_timeout = '3s';
set local statement_timeout = '180s';
create temp table t226_r(ok boolean, label text);
grant all on t226_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t226_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare d text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics d = pg_exception_detail;
  return coalesce(nullif(d, ''), sqlstate);
end $$;
grant execute on all functions in schema pg_temp to public;

-- uudelleenajo ei muuta mitään
\ir ../migrations/20261101143000_booking_226_training_signup.sql

do $t$
declare
  u_mgr uuid := test.mk_staff('t226-mgr@example.test', 'manager');
  d_near date := date '2027-02-22';   -- ma, horisontin sisällä (120 pv 1.11.2026:sta)
  d_far date := date '2027-06-07';    -- ma, yli 120 pv
  d_aug date := date '2027-08-02';    -- ma, retriitti
  d_sep date := date '2027-09-06';    -- ma, ei leikkaa elokuuta
  v_shift bigint := test.rule('Miesten sauna ma%');
  v_pid bigint; v_far bigint; v_ret bigint; v_full bigint; v_sep bigint;
  v_rule bigint; v_rule2 bigint; v_far_rule bigint; v_ret_rule bigint; v_full_rule bigint; v_sep_rule bigint;
  v_slug text; res jsonb; i int; v_tok uuid; v_left int;
  v_blocks int;
begin
  update booking.settings set value = 'true'::jsonb where key = 'events.sale_enabled';
  update booking.integration_config set mode = 'dry_run' where key = 'montonio';

  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_product_by_slug(text)', 'execute')
    and has_function_privilege('anon', 'booking.public_create_training_signup(bigint, date, text, text, text, text, text, text, text, boolean, boolean, text[])', 'execute')
    and not has_function_privilege('anon', 'booking.admin_training_addons_set(bigint, jsonb)', 'execute'), 'A1: anon saa julkiset, ei hallintaa');
  perform pg_temp.ck((select relrowsecurity from pg_class where oid = 'booking.training_participants'::regclass)
    and (select relrowsecurity from pg_class where oid = 'booking.training_addon_offers'::regclass), 'A2: RLS päällä');

  perform test.login(u_mgr);
  res := booking.admin_product_create('{"name":"Sauna healing","name_en":"Sauna healing","price":"200","vat_rate":"25.5","category":"training","active":true}'::jsonb);
  v_pid := (res ->> 'id')::bigint;
  v_slug := res -> 'product' ->> 'slug';
  perform booking.admin_update_product_config(v_pid, '{"bookable":true,"shop_visible":false,"course_price":1500,"deposit_amount":200}'::jsonb);
  perform booking.admin_training_addons_set(v_pid, '[{"code":"single_room","price":200,"active":true},{"code":"internship","price":500,"active":true}]'::jsonb);
  v_rule := (booking.admin_event_rule_upsert(null, v_pid, jsonb_build_object('date', d_near, 'start_time', '10:00', 'duration_minutes', 7200, 'max_persons', 6)) ->> 'id')::bigint;
  v_rule2 := (booking.admin_event_rule_upsert(null, v_pid, jsonb_build_object('date', d_near + 14, 'start_time', '10:00', 'duration_minutes', 7200, 'max_persons', 6)) ->> 'id')::bigint;

  v_far := (booking.admin_product_create('{"name":"Intro kurssi","name_en":"Intro course","price":"200","vat_rate":"25.5","category":"training","active":true}'::jsonb) ->> 'id')::bigint;
  perform booking.admin_update_product_config(v_far, '{"bookable":true,"shop_visible":false,"course_price":890,"deposit_amount":200}'::jsonb);
  v_far_rule := (booking.admin_event_rule_upsert(null, v_far, jsonb_build_object('date', d_far, 'start_time', '10:00', 'duration_minutes', 2880, 'max_persons', 6)) ->> 'id')::bigint;

  v_ret := (booking.admin_product_create('{"name":"Retriitti elokuu","name_en":"August retreat","price":"200","vat_rate":"25.5","category":"training","active":true}'::jsonb) ->> 'id')::bigint;
  perform booking.admin_update_product_config(v_ret, '{"bookable":true,"shop_visible":false,"course_price":1500}'::jsonb);
  perform booking.admin_training_addons_set(v_ret, '[{"code":"single_room","price":200,"active":true}]'::jsonb);
  v_ret_rule := (booking.admin_event_rule_upsert(null, v_ret, jsonb_build_object('date', d_aug, 'start_time', '10:00', 'duration_minutes', 7200, 'max_persons', 6, 'single_room_max', 2)) ->> 'id')::bigint;

  v_full := (booking.admin_product_create('{"name":"15 paivaa","name_en":"15 days","price":"200","vat_rate":"25.5","category":"training","active":true}'::jsonb) ->> 'id')::bigint;
  perform booking.admin_update_product_config(v_full, '{"bookable":true,"shop_visible":false,"course_price":4200}'::jsonb);
  perform booking.admin_training_addons_set(v_full, '[{"code":"single_room","price":200,"active":true}]'::jsonb);
  v_full_rule := (booking.admin_event_rule_upsert(null, v_full, jsonb_build_object('date', d_aug, 'start_time', '10:00', 'duration_minutes', 21600, 'max_persons', 6, 'single_room_max', 2)) ->> 'id')::bigint;

  v_sep := (booking.admin_product_create('{"name":"Intro syyskuu","name_en":"September intro","price":"200","vat_rate":"25.5","category":"training","active":true}'::jsonb) ->> 'id')::bigint;
  perform booking.admin_update_product_config(v_sep, '{"bookable":true,"shop_visible":false,"course_price":890}'::jsonb);
  perform booking.admin_training_addons_set(v_sep, '[{"code":"single_room","price":200,"active":true}]'::jsonb);
  v_sep_rule := (booking.admin_event_rule_upsert(null, v_sep, jsonb_build_object('date', d_sep, 'start_time', '10:00', 'duration_minutes', 2880, 'max_persons', 6)) ->> 'id')::bigint;
  perform test.logout();

  perform pg_temp.ck((select channels = array['link'] and max_persons = 6 and deposit_amount = 200 and course_price = 1500 and bookable and not shop_visible
                        from booking.product_config where product_id = v_pid), 'B1: uusi koulutus on link, max 6, varausmaksu 200');
  perform pg_temp.ck((select single_room_max = 2 and max_persons = 6 from booking.schedule_rules where id = v_rule), 'B2: kerran yhden hengen huoneet oletus 2');
  perform pg_temp.ck((select price = 200 and price_type = 'deposit' from kb.products where id = v_pid), 'B3: tuotteen hinta on varausmaksu');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(booking.public_catalog()) x where (x->>'id')::bigint = v_pid), 'C1: ei public_catalog');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(booking.public_catalog_for('consumer')) x where (x->>'id')::bigint = v_pid), 'C2: ei public_catalog_for');
  perform pg_temp.ck(not exists (select 1 from booking.public_availability_all(d_near, d_near) where product_id = v_pid), 'C3: ei public_availability_all');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(booking.public_events(d_near, 'shop')) x where (x->>'product_id')::bigint = v_pid)
    and not exists (select 1 from jsonb_array_elements(booking.public_events(d_near, 'widget')) x where (x->>'product_id')::bigint = v_pid), 'C4: ei public_events shop eikä widget');
  perform pg_temp.ck((booking.public_product_by_slug(v_slug) ->> 'listed') = 'false'
    and (booking.public_product_by_slug(v_slug) ->> 'deposit') = 'true'
    and (booking.public_product_by_slug(v_slug) ->> 'course_price') = '1500.00'
    and jsonb_array_length(booking.public_product_by_slug(v_slug) -> 'training_addons') = 2, 'C5: suora linkki palauttaa tuotteen');
  perform pg_temp.ck((select count(*) from booking.public_availability(v_pid, d_near, d_near + 20) where status = 'available') = 2, 'C6: molemmat kerrat saatavilla');
  perform pg_temp.ck((select count(*) from booking.event_resource_blocks e where e.rule_id in (v_rule, v_rule2)) = 0, 'C7: ei resurssiblokkeja');

  perform test.anon('10.226.1.1');
  res := booking.public_create_training_signup(v_rule, d_near, 'Maja Testi', 'maja226@example.test', '+46 70 123 4567', 'SE', 'en', 'en', 'viesti', true, true, array['single_room','internship']);
  perform test.logout();
  v_tok := (res ->> 'token')::uuid;
  perform pg_temp.ck((res ->> 'ok') = 'true' and (res ->> 'total')::numeric = 200 and (res ->> 'status') = 'pending'
    and (res -> 'training' ->> 'total')::numeric = 2200
    and (res -> 'training' ->> 'remaining')::numeric = 2000
    and (res -> 'training' ->> 'deposit_paid')::numeric = 200
    and (res -> 'training' ->> 'addons_total')::numeric = 700
    and (res ->> 'checkout_state') = 'awaiting_payment', 'D1: verkossa vain 200, loppusumma 2200, jäljellä 2000');
  perform pg_temp.ck((select o.status = 'pending' and o.total_gross = 200 and o.hold_kind = 'checkout' and o.payment_status = 'unpaid'
                        from booking.orders o where o.public_token = v_tok), 'D2: tilaus pending 200');
  perform pg_temp.ck((select tp.country = 'SE' and tp.language = 'en' and tp.is_foreign and tp.single_room
                        and tp.course_price = 1500 and tp.total = 2200 and tp.deposit_paid = 200 and tp.remaining = 2000
                        and (tp.addons @> '[{"code":"internship","price":500.00}]'::jsonb)
                        from booking.training_participants tp
                        join booking.reservations r on r.id = tp.reservation_id
                        join booking.orders o on o.id = r.order_id
                       where o.public_token = v_tok), 'D3: osallistujarivi, ulkomainen, snapshot');
  perform pg_temp.ck((select (i.price_breakdown ->> 'deposit') = 'true' and (i.price_breakdown ->> 'deposit_amount')::numeric = 200
                        from booking.order_items i join booking.orders o on o.id = i.order_id
                       where o.public_token = v_tok and i.kind = 'reservation'), 'D4: rivin price_breakdown on varausmaksu');
  perform test.login(u_mgr);
  perform pg_temp.ck((select (x ->> 'country') = 'SE' and (x ->> 'is_foreign') = 'true' and (x ->> 'participant_total')::numeric = 2200 and (x ->> 'remaining')::numeric = 2000
                        from jsonb_array_elements(booking.admin_event_participants(v_pid, v_rule)) x
                       where x ->> 'email' = 'maja226@example.test'), 'D5: hallinnan lista');
  perform test.logout();

  perform test.anon('10.226.1.2');
  res := booking.public_create_training_signup(v_rule, d_near, 'Ei Suostu', 'ei226@example.test', '0401234567', 'FI', 'fi', 'fi', null, false, false, '{}');
  perform pg_temp.ck((res ->> 'code') = 'privacy_required', 'D6: tietosuoja vaaditaan');
  res := booking.public_create_training_signup(v_far_rule, d_far, 'Kauas Testi', 'kauas226@example.test', '0401234567', 'FI', 'fi', 'fi', null, false, true, '{}');
  perform pg_temp.ck((res ->> 'ok') = 'true' and (res ->> 'total')::numeric = 200 and (res -> 'training' ->> 'total')::numeric = 890
    and (res -> 'training' ->> 'remaining')::numeric = 690, 'E1: intro yli 120 pv, verkossa 200, loppu 690');
  res := booking.public_create_booking(v_shift, d_far, 1, 'Horisontti', 'horisontti226@example.test', '0401234567', false, 'fi', null);
  perform pg_temp.ck((res ->> 'code') = 'invalid_date', 'E2: tavallinen varaus yli 120 pv yhä invalid_date');
  res := booking.public_create_booking(v_rule, d_near, 2, 'Yritys', 'yritys226@example.test', '0401234567', false, 'fi', null, 'company', '{"company_name":"Oy","business_id":"1234567-8"}'::jsonb);
  perform pg_temp.ck((res ->> 'code') = 'training_signup_only', 'E3: koulutusta ei voi varata tavallisella polulla');
  res := booking.public_create_training_signup(v_shift, d_near, 'Vaara', 'vaara226@example.test', '0401234567', 'FI', 'fi', 'fi', null, false, true, '{}');
  perform pg_temp.ck((res ->> 'code') = 'not_training', 'E4: ei-koulutus hylätään');
  perform test.logout();

  -- paikat: 1 jo käytössä (Maja). Viisi lisää = täynnä, seitsemäs hylätään.
  for i in 1..5 loop
    perform test.anon('10.226.2.' || i);
    res := booking.public_create_training_signup(v_rule, d_near, 'Paikka ' || i, 'paikka' || i || '@t226.example', '040123450' || i, 'FI', 'fi', 'fi', null, false, true, '{}');
    perform test.logout();
    perform pg_temp.ck((res ->> 'ok') = 'true', 'F' || i || ': paikka');
  end loop;
  perform test.anon('10.226.2.9');
  res := booking.public_create_training_signup(v_rule, d_near, 'Liikaa', 'liikaa226@example.test', '0401234599', 'FI', 'fi', 'fi', null, false, true, '{}');
  perform test.logout();
  perform pg_temp.ck((res ->> 'ok') = 'false' and (res ->> 'code') in ('capacity_exceeded', 'full'), 'F7: seitsemäs paikka hylätään (' || coalesce(res ->> 'code','') || ')');
  perform pg_temp.ck((select remaining = 0 and status = 'full' from booking.public_availability(v_pid, d_near, d_near) where rule_id = v_rule), 'F8: kerta täynnä');
  perform pg_temp.ck((select remaining = 6 from booking.public_availability(v_pid, d_near + 14, d_near + 14) where rule_id = v_rule2), 'F9: toinen kerta yhä tyhjä');

  update booking.reservations set hold_expires_at = now() - interval '1 minute'
   where id = (select r.id from booking.reservations r join booking.orders o on o.id = r.order_id where o.public_token = v_tok);
  perform pg_temp.ck((select remaining = 1 and status = 'available' from booking.public_availability(v_pid, d_near, d_near) where rule_id = v_rule), 'G1: vanhentunut pito vapauttaa paikan');
  perform test.anon('10.226.3.1');
  res := booking.public_create_training_signup(v_rule, d_near, 'Ehti', 'ehti226@example.test', '0401234500', 'FI', 'fi', 'fi', null, false, true, '{}');
  perform test.logout();
  perform pg_temp.ck((res ->> 'ok') = 'true', 'G2: vapautunut paikka voidaan varata');

  -- yhden hengen huoneet: kaksi onnistuu, kolmas ei. Ilman huonetta onnistuu.
  perform test.anon('10.226.4.1');
  res := booking.public_create_training_signup(v_ret_rule, d_aug, 'Huone 1', 'huone1@t226.example', '0401111111', 'FI', 'fi', 'fi', null, false, true, array['single_room']);
  perform test.logout();
  perform pg_temp.ck((res ->> 'ok') = 'true' and (res ->> 'total')::numeric = 200 and (res -> 'training' ->> 'total')::numeric = 1700, 'H1: huone 1, verkko 200, loppu 1700');
  perform test.anon('10.226.4.2');
  res := booking.public_create_training_signup(v_ret_rule, d_aug, 'Huone 2', 'huone2@t226.example', '0401111112', 'DE', 'en', 'en', null, false, true, array['single_room']);
  perform test.logout();
  perform pg_temp.ck((res ->> 'ok') = 'true', 'H2: huone 2');
  perform test.anon('10.226.4.3');
  res := booking.public_create_training_signup(v_ret_rule, d_aug, 'Huone 3', 'huone3@t226.example', '0401111113', 'FI', 'fi', 'fi', null, false, true, array['single_room']);
  perform test.logout();
  perform pg_temp.ck((res ->> 'code') = 'single_room_full', 'H3: kolmas yhden hengen huone hylätään');
  perform test.anon('10.226.4.4');
  res := booking.public_create_training_signup(v_ret_rule, d_aug, 'Ilman', 'ilman@t226.example', '0401111114', 'FI', 'fi', 'fi', null, false, true, '{}');
  perform test.logout();
  perform pg_temp.ck((res ->> 'ok') = 'true' and (res -> 'training' ->> 'total')::numeric = 1500 and (res -> 'training' ->> 'remaining')::numeric = 1300, 'H4: ilman huonetta paikka auki, loppu 1300');
  perform pg_temp.ck((booking.public_training_checkout(v_ret_rule, d_aug) ->> 'single_rooms_remaining')::int = 0, 'H5: kassa näyttää huoneet täynnä');

  -- 15 päivän kurssi leikkaa retriitin: huone ei mahdu, vaikka omalla kerralla olisi tilaa.
  perform test.anon('10.226.5.1');
  res := booking.public_create_training_signup(v_full_rule, d_aug, 'Pitka', 'pitka@t226.example', '0402222221', 'FI', 'fi', 'fi', null, false, true, array['single_room']);
  perform test.logout();
  perform pg_temp.ck((res ->> 'code') = 'single_room_full', 'I1: päällekkäinen 15 pv ei saa huonetta täydeltä retriitiltä');

  -- tyhjä syyskuun intro ei kärsi elokuun täydestä huonepoolista
  perform test.anon('10.226.5.2');
  res := booking.public_create_training_signup(v_sep_rule, d_sep, 'Syys', 'syys@t226.example', '0402222222', 'FI', 'fi', 'fi', null, false, true, array['single_room']);
  perform test.logout();
  perform pg_temp.ck((res ->> 'ok') = 'true', 'I2: erillinen kerta saa yhden hengen huoneen');

  -- oma kurssi ei sulje savusaunan vuoroa
  perform pg_temp.ck(exists (select 1 from booking.public_availability((select product_id from booking.schedule_rules where id = v_shift), d_near, d_near) s
                             where s.rule_id = v_shift and s.status = 'available'), 'J1: tavallinen vuoro yhä vapaa');
  v_blocks := (select count(*) from booking.space_blocks b join booking.event_resource_blocks e on e.id = b.event_block_id where e.rule_id = v_rule);
  perform pg_temp.ck(v_blocks = 0, 'J2: koulutus ei materialisoi sulkuja');

  perform test.anon('10.226.9.1');
  perform pg_temp.ck(pg_temp.err(format('select booking.admin_event_participants(%s, null)', v_pid)) in ('forbidden', '42501'), 'K1: anon ei näe osallistujia');
  perform test.logout();
end $t$;

-- rollback kahdesti (md5) ja migraatio uudelleen
\ir ../rollbacks/20261101143000_booking_226_ROLLBACK.sql
\ir ../rollbacks/20261101143000_booking_226_ROLLBACK.sql
do $t$
declare v text;
begin
  select md5(pg_get_functiondef('booking.public_catalog()'::regprocedure)) into v;
  perform pg_temp.ck(v = '2294bbb6675677aea1dc813b151fe8e4', 'R1: public_catalog md5');
  select md5(pg_get_functiondef('booking.public_create_booking(bigint, date, integer, text, text, text, boolean, text, text, text, jsonb, jsonb)'::regprocedure)) into v;
  perform pg_temp.ck(v = '6bf51ffd45c259ef5546aa19f63f5066', 'R2: public_create_booking md5');
  perform pg_temp.ck(to_regclass('booking.training_participants') is null, 'R3: taulu poissa');
end $t$;
\ir ../migrations/20261101143000_booking_226_training_signup.sql
do $t$
begin
  perform pg_temp.ck(to_regprocedure('booking.public_create_training_signup(bigint, date, text, text, text, text, text, text, text, boolean, boolean, text[])') is not null, 'R4: funktio palautui');
end $t$;

do $t$
declare n_ok int; n_bad int; msg text;
begin
  select count(*) filter (where ok), count(*) filter (where not ok) into n_ok, n_bad from t226_r;
  select string_agg(label, ' | ') into msg from t226_r where not ok;
  raise exception 'TESTRESULT pass=% fail=% tz=% bad=%', n_ok, n_bad, current_setting('TimeZone'), coalesce(msg, '');
end $t$;
