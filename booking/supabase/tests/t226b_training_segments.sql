-- t226b: osakerrat (booking_226b). Jaettu paikka ja yhden hengen huone, kaikki tai ei mitään.
-- Ajo: psql -X -v ON_ERROR_STOP=0 -f t226b_training_segments.sql
-- Lopun poikkeus kumoaa testidatan. Ei tuotantoon.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '180s';
create temp table t226b_r(ok boolean, label text);
grant all on t226b_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t226b_r values (coalesce(p_ok, false), p_label) $$;
grant execute on all functions in schema pg_temp to public;

\ir ../migrations/20261101160000_booking_226b_training_segments.sql

do $t$
declare
  u_mgr uuid := test.mk_staff('t226b-mgr@example.test', 'manager');
  d1 date := date '2027-03-01';
  d2 date := date '2027-05-03';
  d3 date := date '2027-07-05';
  d_follow date := date '2027-03-08';
  d_w date;
  v_r1 bigint; v_r2 bigint; v_r3 bigint; v_full bigint; v_long bigint; v_intro bigint; v_school bigint;
  v_a1 bigint; v_a2 bigint; v_a3 bigint; v_full_rule bigint; v_anchor bigint; v_follow bigint; v_intro_rule bigint;
  v_w bigint[] := '{}'; v_wd date[] := '{}'; v_id bigint;
  v_slug text; res jsonb; i int; v_left int; v_n int;
begin
  update booking.settings set value = 'true'::jsonb where key = 'events.sale_enabled';
  update booking.integration_config set mode = 'dry_run' where key = 'montonio';

  perform test.login(u_mgr);
  v_r1 := (booking.admin_product_create('{"name":"Retreat 1","name_en":"Retreat 1","price":"200","vat_rate":"25.5","category":"training","active":true}'::jsonb) ->> 'id')::bigint;
  perform booking.admin_update_product_config(v_r1, '{"bookable":true,"shop_visible":false,"course_price":1500,"deposit_amount":200}'::jsonb);
  perform booking.admin_training_addons_set(v_r1, '[{"code":"single_room","price":200,"active":true}]'::jsonb);
  v_a1 := (booking.admin_event_rule_upsert(null, v_r1, jsonb_build_object('date', d1, 'start_time', '10:00', 'duration_minutes', 7200, 'max_persons', 6, 'single_room_max', 2, 'label', 'Retreat 1')) ->> 'id')::bigint;

  v_r2 := (booking.admin_product_create('{"name":"Retreat 2","name_en":"Retreat 2","price":"200","vat_rate":"25.5","category":"training","active":true}'::jsonb) ->> 'id')::bigint;
  perform booking.admin_update_product_config(v_r2, '{"bookable":true,"shop_visible":false,"course_price":1500,"deposit_amount":200}'::jsonb);
  perform booking.admin_training_addons_set(v_r2, '[{"code":"single_room","price":200,"active":true}]'::jsonb);
  v_a2 := (booking.admin_event_rule_upsert(null, v_r2, jsonb_build_object('date', d2, 'start_time', '10:00', 'duration_minutes', 7200, 'max_persons', 6, 'single_room_max', 2, 'label', 'Retreat 2')) ->> 'id')::bigint;

  v_r3 := (booking.admin_product_create('{"name":"Retreat 3","name_en":"Retreat 3","price":"200","vat_rate":"25.5","category":"training","active":true}'::jsonb) ->> 'id')::bigint;
  perform booking.admin_update_product_config(v_r3, '{"bookable":true,"shop_visible":false,"course_price":1500,"deposit_amount":200}'::jsonb);
  perform booking.admin_training_addons_set(v_r3, '[{"code":"single_room","price":200,"active":true}]'::jsonb);
  v_a3 := (booking.admin_event_rule_upsert(null, v_r3, jsonb_build_object('date', d3, 'start_time', '10:00', 'duration_minutes', 7200, 'max_persons', 6, 'single_room_max', 2, 'label', 'Retreat 3')) ->> 'id')::bigint;

  res := booking.admin_product_create('{"name":"Full training 3","name_en":"Full training 3","price":"200","vat_rate":"25.5","category":"training","active":true}'::jsonb);
  v_full := (res ->> 'id')::bigint;
  v_slug := res -> 'product' ->> 'slug';
  perform booking.admin_update_product_config(v_full, '{"bookable":true,"shop_visible":false,"course_price":4200,"deposit_amount":200}'::jsonb);
  perform booking.admin_training_addons_set(v_full, '[{"code":"single_room","price":600,"active":true}]'::jsonb);
  v_full_rule := (booking.admin_event_rule_upsert(null, v_full, jsonb_build_object('date', d1, 'start_time', '10:00', 'duration_minutes', 1440, 'max_persons', 6, 'label', 'Full 3')) ->> 'id')::bigint;
  perform booking.admin_training_segments_set(v_full_rule, array[v_a1, v_a2, v_a3]);

  v_long := (booking.admin_product_create('{"name":"15 days","name_en":"15 days","price":"200","vat_rate":"25.5","category":"training","active":true}'::jsonb) ->> 'id')::bigint;
  perform booking.admin_update_product_config(v_long, '{"bookable":true,"shop_visible":false,"course_price":4200,"deposit_amount":200}'::jsonb);
  perform booking.admin_training_addons_set(v_long, '[{"code":"single_room","price":500,"active":true}]'::jsonb);
  v_anchor := (booking.admin_event_rule_upsert(null, v_long, jsonb_build_object('date', d1, 'start_time', '10:00', 'duration_minutes', 1440, 'max_persons', 6, 'label', '15 days start')) ->> 'id')::bigint;
  v_follow := (booking.admin_event_rule_upsert(null, v_long, jsonb_build_object('date', d_follow, 'start_time', '10:00', 'duration_minutes', 7200, 'max_persons', 6, 'single_room_max', 2, 'label', 'Follow-up')) ->> 'id')::bigint;
  perform booking.admin_training_segments_set(v_anchor, array[v_a1, v_follow]);

  v_intro := (booking.admin_product_create('{"name":"Intro","name_en":"Intro","price":"200","vat_rate":"25.5","category":"training","active":true}'::jsonb) ->> 'id')::bigint;
  perform booking.admin_update_product_config(v_intro, '{"bookable":true,"shop_visible":false,"course_price":890,"deposit_amount":200}'::jsonb);
  perform booking.admin_training_addons_set(v_intro, '[{"code":"single_room","price":170,"active":true}]'::jsonb);
  v_intro_rule := (booking.admin_event_rule_upsert(null, v_intro, jsonb_build_object('date', d2, 'start_time', '10:00', 'duration_minutes', 2880, 'max_persons', 6, 'single_room_max', 2)) ->> 'id')::bigint;

  v_school := (booking.admin_product_create('{"name":"Saunottajakoulutus","name_en":"Host training","price":"200","vat_rate":"25.5","category":"training","active":true}'::jsonb) ->> 'id')::bigint;
  perform booking.admin_update_product_config(v_school, '{"bookable":true,"shop_visible":false,"course_price":2400,"deposit_amount":200}'::jsonb);
  for i in 1..6 loop
    d_w := date '2027-01-22' + ((i - 1) * 42);
    v_id := (booking.admin_event_rule_upsert(null, v_school, jsonb_build_object('date', d_w, 'start_time', '10:00', 'duration_minutes', 2880, 'max_persons', 6, 'label', 'Weekend ' || i)) ->> 'id')::bigint;
    v_w := v_w || v_id;
    v_wd := v_wd || d_w;
  end loop;
  perform booking.admin_training_segments_set(v_w[1], v_w);
  perform test.logout();

  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_training_segments_set(bigint, bigint[])', 'execute'), 'A1: anon ei aseta osakertoja');
  perform test.anon('10.226.80.1');
  res := booking.public_product_by_slug(v_slug);
  perform test.logout();
  perform pg_temp.ck(res -> 'allowed_addons' = '[]'::jsonb and res -> 'addons_enabled' = 'false'::jsonb, 'A2: koulutus ei paljasta kaupan lisiä');
  perform pg_temp.ck((select training_segment_only from booking.schedule_rules where id = v_follow), 'A3: jatkopäivät piilotettu');
  perform pg_temp.ck(not (select training_segment_only from booking.schedule_rules where id = v_a1), 'A4: retriitti pysyy myynnissä');
  perform pg_temp.ck(not (select training_segment_only from booking.schedule_rules where id = v_w[1])
    and (select training_segment_only from booking.schedule_rules where id = v_w[2]), 'A5: vain ensimmäinen viikonloppu on valinta');

  perform test.anon('10.226.80.2');
  res := booking.public_create_training_signup(v_full_rule, d1, 'Fanni', 'fanni@t226b.example', '0403000001', 'FI', 'fi', 'fi', null, false, true, '{}');
  perform test.logout();
  perform pg_temp.ck((res ->> 'ok') = 'true' and (res #>> '{training,total}')::numeric = 4200 and (res ->> 'total')::numeric = 200, 'B1: Full-3 maksaa vain varausmaksun');
  select s.remaining into v_left from booking.public_availability(v_r1, d1, d1) s where s.rule_id = v_a1;
  perform pg_temp.ck(v_left = 5, 'B2: Full-3 kuluttaa retriitin 1 paikan');
  select s.remaining into v_left from booking.public_availability(v_r2, d2, d2) s where s.rule_id = v_a2;
  perform pg_temp.ck(v_left = 5, 'B3: Full-3 kuluttaa retriitin 2 paikan');
  select s.remaining into v_left from booking.public_availability(v_r3, d3, d3) s where s.rule_id = v_a3;
  perform pg_temp.ck(v_left = 5, 'B4: Full-3 kuluttaa retriitin 3 paikan');

  perform test.anon('10.226.80.3');
  res := booking.public_create_training_signup(v_intro_rule, d2, 'Iida', 'iida@t226b.example', '0403000002', 'FI', 'fi', 'fi', null, false, true, array['single_room']);
  perform test.logout();
  perform pg_temp.ck((res ->> 'ok') = 'true' and (res #>> '{training,addons,0,price}')::numeric = 170 and (res #>> '{training,total}')::numeric = 1060, 'C1: huoneen hinta on tuotekohtainen');

  for i in 1..2 loop
    perform test.anon('10.226.81.' || i);
    res := booking.public_create_training_signup(v_a2, d2, 'R' || i, 'room' || i || '@t226b.example', '040300001' || i, 'FI', 'fi', 'fi', null, false, true, array['single_room']);
    perform test.logout();
    perform pg_temp.ck((res ->> 'ok') = 'true', 'D' || i || ': retriitin 2 huone');
  end loop;
  perform test.anon('10.226.81.9');
  res := booking.public_create_training_signup(v_full_rule, d1, 'Fulla', 'fulla@t226b.example', '0403000099', 'FI', 'en', 'en', null, false, true, array['single_room']);
  perform test.logout();
  perform pg_temp.ck((res ->> 'code') = 'single_room_full', 'D3: Full-3 ei saa huonetta kun retriitti 2 on täynnä');
  select count(*) into v_n from booking.reservations x
   where x.rule_id = v_a1 and x.notes = 'training_segment' and booking._res_active(x.status, x.hold_expires_at);
  perform pg_temp.ck(v_n = 1, 'D4: epäonnistunut huonevaraus ei lisännyt toista paikkaa retriitille 1');

  for i in 1..5 loop
    perform test.anon('10.226.82.' || i);
    res := booking.public_create_training_signup(v_a3, d3, 'T' || i, 'seat' || i || '@t226b.example', '040300002' || i, 'FI', 'fi', 'fi', null, false, true, '{}');
    perform test.logout();
    perform pg_temp.ck((res ->> 'ok') = 'true', 'E' || i || ': retriitin 3 paikka');
  end loop;
  select count(*) into v_n from booking.reservations x where x.rule_id = v_a1 and booking._res_active(x.status, x.hold_expires_at);
  perform test.anon('10.226.82.9');
  res := booking.public_create_training_signup(v_full_rule, d1, 'Esto', 'esto@t226b.example', '0403000088', 'SE', 'en', 'en', null, false, true, '{}');
  perform test.logout();
  perform pg_temp.ck((res ->> 'code') = 'capacity_exceeded', 'E6: täysi osakerta estää koko ilmoittautumisen');
  perform pg_temp.ck((select count(*) from booking.reservations x where x.rule_id = v_a1 and booking._res_active(x.status, x.hold_expires_at)) = v_n, 'E7: retriitin 1 paikat eivät muuttuneet');

  perform test.anon('10.226.83.1');
  res := booking.public_create_training_signup(v_anchor, d1, 'Pitka', 'pitka@t226b.example', '0403000077', 'FI', 'fi', 'fi', null, false, true, '{}');
  perform test.logout();
  perform pg_temp.ck((res ->> 'ok') = 'true', 'F1: 15 päivän aloitus');
  select s.remaining into v_left from booking.public_availability(v_r1, d1, d1) s where s.rule_id = v_a1;
  perform pg_temp.ck(v_left = 4, 'F2: 15 päivää kuluttaa retriitin 1 paikan');
  perform pg_temp.ck((select count(*) from booking.reservations x where x.rule_id = v_follow and booking._res_active(x.status, x.hold_expires_at)) = 1, 'F3: jatkopäivillä on oma paikka');
  perform pg_temp.ck(not exists (select 1 from booking.public_availability(v_long, d_follow, d_follow) s where s.rule_id = v_follow), 'F4: jatkopäiviä ei myydä erikseen');

  perform test.anon('10.226.84.1');
  res := booking.public_create_training_signup(v_w[1], v_wd[1], 'Viivi', 'viivi@t226b.example', '0403000066', 'FI', 'fi', 'fi', null, false, true, '{}');
  perform test.logout();
  perform pg_temp.ck((res ->> 'ok') = 'true' and jsonb_array_length(res -> 'training' -> 'segments') = 6, 'G1: kuusi viikonloppua yhdellä ilmoittautumisella');
  select count(*) into v_n from unnest(v_w) u(id)
   where (select count(*) from booking.reservations x where x.rule_id = u.id and booking._res_active(x.status, x.hold_expires_at)) = 1;
  perform pg_temp.ck(v_n = 6, 'G2: jokainen viikonloppu menetti yhden paikan');
  perform test.anon('10.226.84.2');
  res := booking.public_create_training_signup(v_w[2], v_wd[2], 'Piilo', 'piilo@t226b.example', '0403000055', 'FI', 'fi', 'fi', null, false, true, '{}');
  perform test.logout();
  perform pg_temp.ck((res ->> 'ok') = 'false', 'G3: piilotettua viikonloppua ei voi varata yksin');
end $t$;

\ir ../rollbacks/20261101160000_booking_226b_ROLLBACK.sql
do $t$
begin
  perform pg_temp.ck(to_regclass('booking.training_segments') is null, 'R1: osakertataulu poissa');
  perform pg_temp.ck(not exists (select 1 from information_schema.columns where table_schema = 'booking' and table_name = 'schedule_rules' and column_name = 'training_segment_only'), 'R2: sarake poissa');
  perform pg_temp.ck(pg_get_functiondef('booking._training_single_room_pools(bigint)'::regprocedure) like '%&&%', 'R3: huonepooli on taas booking_226:n versio');
end $t$;
\ir ../migrations/20261101160000_booking_226b_training_segments.sql
do $t$
begin
  perform pg_temp.ck(to_regclass('booking.training_segments') is not null, 'R4: osakerrat palautuivat');
end $t$;

do $t$
declare n_ok int; n_bad int; msg text;
begin
  select count(*) filter (where ok), count(*) filter (where not ok) into n_ok, n_bad from t226b_r;
  select string_agg(label, ' | ') into msg from t226b_r where not ok;
  raise exception 'TESTRESULT pass=% fail=% bad=%', n_ok, n_bad, coalesce(msg, '');
end $t$;
