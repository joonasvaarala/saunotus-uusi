-- t121: tuoteviestit (booking_121). Rollback-transaktio: lopuksi tahallinen poikkeus.
-- Oikeudet, tallennus, ajastuspäätös, kytkin pois, yksi viesti per tilaus, ohitus.
-- Ei CI:ssä. GitHub Pages -työnkulussa ei ole Postgresia, ja booking/supabase/tests/run.sh ajaa vain juuren [0-9]*.test.sql.
-- Bottiavustus ajaa tämän psql:llä migraatioiden jälkeen. Ei tuotantoon.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t121.log', '', true);
create function public.t121_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t121.log', coalesce(current_setting('t121.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create function public.t121_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 160) end;
end $$;
create function public.t121_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create function public.t121_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on all functions in schema public to public;

do $t$
declare
  u_staff uuid := gen_random_uuid();
  u_mgr uuid := gen_random_uuid();
  res jsonb;
  dec jsonb;
  pid bigint;
  pid2 bigint;
  pid_late bigint;
  mid bigint;
  mid_wait bigint;
  mid_late bigint;
  mid_miss bigint;
  mid_off bigint;
  mid_guide bigint;
  c_id bigint;
  o_due bigint;
  o_refund bigint;
  o_part bigint;
  o_ext bigint;
  o_cancel bigint;
  o_wait bigint;
  o_late bigint;
  o_miss bigint;
  o_nomail bigint;
  space_id bigint;
  n int;
  n2 int;
  log text;
  npass int;
  nfail int;
  tok uuid;
begin
  perform public.t121_ck(not has_function_privilege('anon', 'booking.admin_save_message(bigint, jsonb)', 'execute'), 'G1 anon ei tallenna');
  perform public.t121_ck(not has_function_privilege('public', 'booking.admin_list_messages()', 'execute'), 'G2 public ei listaa');
  perform public.t121_ck(has_function_privilege('authenticated', 'booking.admin_save_message(bigint, jsonb)', 'execute'), 'G3 authenticated saa tallentaa');
  perform public.t121_ck(not has_function_privilege('authenticated', 'booking.messages_dispatch(integer)', 'execute'), 'G4 authenticated ei aja ajastusta');
  perform public.t121_ck(not has_function_privilege('public', 'booking._message_decision(timestamptz, timestamptz[], integer, text, text, text, timestamptz, text, text, boolean)', 'execute'), 'G5 public ei päätä');
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    perform public.t121_ck(has_function_privilege('service_role', 'booking.messages_dispatch(integer)', 'execute'), 'G6 service_role ajaa ajastuksen');
  else
    perform public.t121_ck(false, 'G6 service_role puuttuu');
  end if;
  perform public.t121_ck(exists (select 1 from booking.role_permissions where role_code = 'admin' and permission = 'messages.edit'), 'G7 admin');
  perform public.t121_ck(exists (select 1 from booking.role_permissions where role_code = 'manager' and permission = 'messages.edit'), 'G8 manager');
  perform public.t121_ck(not exists (select 1 from booking.role_permissions where role_code = 'staff' and permission = 'messages.edit'), 'G9 staff ei');
  perform public.t121_ck(booking._setting('messages.timed_enabled', 'false'::jsonb) = 'false'::jsonb, 'S1 kytkin oletus pois');
  perform public.t121_ck((select count(*) from booking.messages where name like '[ESIMERKKI EI KÄYTÖSSÄ]%' and active) = 0, 'S2 esimerkit pois');
  perform public.t121_ck(not exists (select 1 from booking.message_products mp join booking.messages m on m.id = mp.message_id where m.name like '[ESIMERKKI EI KÄYTÖSSÄ]%'), 'S3 esimerkeillä ei tuotteita');

  dec := booking._message_decision(timestamptz '2026-10-21 12:00:00+00', array[timestamptz '2026-10-23 12:00:00+00'], 1, 'minutes', 'after', 'booking', timestamptz '2026-10-21 12:02:00+00', 'confirmed', 'paid', true);
  perform public.t121_ck(dec ->> 'reason' = 'external_import', 'D1 tuonti');
  dec := booking._message_decision(timestamptz '2026-10-21 12:00:00+00', '{}', 1, 'minutes', 'after', 'booking', timestamptz '2026-10-21 12:02:00+00', 'cancelled', 'paid', false);
  perform public.t121_ck(dec ->> 'reason' = 'order_status', 'D2 peruttu');
  dec := booking._message_decision(timestamptz '2026-10-21 12:00:00+00', '{}', 1, 'minutes', 'after', 'booking', timestamptz '2026-10-21 12:02:00+00', 'confirmed', 'refunded', false);
  perform public.t121_ck(dec ->> 'reason' = 'refunded', 'D3 hyvitetty');
  dec := booking._message_decision(timestamptz '2026-10-21 12:00:00+00', '{}', 1, 'minutes', 'after', 'booking', timestamptz '2026-10-21 12:02:00+00', 'confirmed', 'partially_refunded', false);
  perform public.t121_ck(dec ->> 'action' = 'send' and dec ->> 'reason' = 'due', 'D4 osahyvitys lähtee');
  dec := booking._message_decision(timestamptz '2026-10-21 12:00:00+00', '{}', null, null, null, null, timestamptz '2026-10-21 12:02:00+00', 'confirmed', 'paid', false);
  perform public.t121_ck(dec ->> 'reason' = 'no_timing', 'D5 ei ajastusta');
  dec := booking._message_decision(timestamptz '2026-10-21 12:00:00+00', '{}', 1, 'minutes', 'after', 'booking', timestamptz '2026-10-21 12:00:30+00', 'confirmed', 'paid', false);
  perform public.t121_ck(dec ->> 'action' = 'wait' and dec ->> 'reason' = 'not_due', 'D6 ei vielä');
  dec := booking._message_decision(timestamptz '2026-10-21 12:00:00+00', array[timestamptz '2026-10-22 12:00:00+00'], 2, 'days', 'before', 'arrival', timestamptz '2026-10-21 12:05:00+00', 'confirmed', 'paid', false);
  perform public.t121_ck(dec ->> 'reason' = 'missed_at_booking', 'D7 ikkuna oli jo ohi tilatessa');
  dec := booking._message_decision(timestamptz '2026-10-01 00:00:00+00', '{}', 1, 'minutes', 'after', 'booking', timestamptz '2026-10-01 00:01:00+00' + interval '36 hours', 'confirmed', 'paid', false);
  perform public.t121_ck(dec ->> 'action' = 'send', 'D8 tasan 36 h lähtee');
  dec := booking._message_decision(timestamptz '2026-10-01 00:00:00+00', '{}', 1, 'minutes', 'after', 'booking', timestamptz '2026-10-01 00:01:00+00' + interval '36 hours' + interval '1 second', 'confirmed', 'paid', false);
  perform public.t121_ck(dec ->> 'reason' = 'too_late', 'D9 yli 36 h ohitetaan');
  dec := booking._message_decision(timestamptz '2026-10-20 12:00:00+00', array[timestamptz '2026-10-28 15:00:00+00', timestamptz '2026-10-25 15:00:00+00'], 1, 'days', 'before', 'arrival', timestamptz '2026-10-20 13:00:00+00', 'confirmed', 'paid', false);
  perform public.t121_ck((dec ->> 'send_at')::timestamptz = timestamptz '2026-10-24 15:00:00+00', 'D10 ennen = aikaisin');
  dec := booking._message_decision(timestamptz '2026-10-20 12:00:00+00', array[timestamptz '2026-10-28 15:00:00+00', timestamptz '2026-10-25 15:00:00+00'], 1, 'days', 'after', 'arrival', timestamptz '2026-10-20 13:00:00+00', 'confirmed', 'paid', false);
  perform public.t121_ck((dec ->> 'send_at')::timestamptz = timestamptz '2026-10-29 15:00:00+00', 'D11 jälkeen = myöhäisin');
  dec := booking._message_decision(timestamptz '2026-10-21 12:00:00+00', '{}', 1, 'days', 'after', 'booking', timestamptz '2026-10-21 13:00:00+00', 'confirmed', 'paid', false);
  perform public.t121_ck((dec ->> 'send_at')::timestamptz = timestamptz '2026-10-21 12:00:00+00' + interval '24 hours', 'D12 päivä on 24 h');
  dec := booking._message_decision(timestamptz '2026-10-21 12:00:00+00', '{}', 1, 'days', 'before', 'arrival', timestamptz '2026-10-21 13:00:00+00', 'confirmed', 'paid', false);
  perform public.t121_ck(dec ->> 'reason' = 'no_arrival', 'D13 ei saapumista');
  perform public.t121_ck(booking._message_fill('Hei {asiakas_nimi} {tuntematon}', '{"asiakas_nimi":"Aada"}'::jsonb) = 'Hei Aada {tuntematon}', 'F1 paikkamerkki');
  perform public.t121_ck(booking._message_fill('x {linkki}', '{}'::jsonb) = 'x ', 'F2 tyhjä merkki');

  insert into auth.users(id, email) values (u_staff, 't121-staff@example.test'), (u_mgr, 't121-mgr@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_staff, 't121-staff@example.test', 't121 staff', 'staff'),
    (u_mgr, 't121-mgr@example.test', 't121 manager', 'manager');

  perform public.t121_login(u_staff);
  perform public.t121_ck(public.t121_try($q$select booking.admin_list_messages()$q$) = 'forbidden', 'R1 staff ei listaa');
  perform public.t121_ck(public.t121_try($q$select booking.admin_save_message(null, '{"name":"T121","category":"instruction"}'::jsonb)$q$) = 'forbidden', 'R2 staff ei tallenna');
  perform public.t121_logout();

  perform public.t121_login(u_mgr);
  perform public.t121_ck(public.t121_try($q$select booking.admin_save_message(null, '{"name":"","category":"instruction"}'::jsonb)$q$) = 'invalid_name', 'E1 nimi');
  perform public.t121_ck(public.t121_try($q$select booking.admin_save_message(null, '{"name":"T121","category":"muu"}'::jsonb)$q$) = 'invalid_category', 'E2 luokka');
  perform public.t121_ck(public.t121_try($q$select booking.admin_save_message(null, '{"name":"T121","category":"feedback","active":true,"subject_fi":"A","body_fi":"B"}'::jsonb)$q$) = 'invalid_timing', 'E3 palautepyyntö tarvitsee ajastuksen');
  perform public.t121_ck(public.t121_try($q$select booking.admin_save_message(null, '{"name":"T121","category":"instruction","active":true,"subject_fi":"A","body_fi":"B"}'::jsonb)$q$) = 'invalid_text', 'E4 ohje tarvitsee lyhyen');
  perform public.t121_ck(public.t121_try($q$select booking.admin_save_message(null, '{"name":"T121","category":"instruction","link_url":"http://example.test"}'::jsonb)$q$) = 'invalid_link', 'E5 vain https');
  perform public.t121_ck(public.t121_try($q$select booking.admin_save_message(null, '{"name":"T121","category":"instruction","send_amount":1}'::jsonb)$q$) = 'invalid_timing', 'E6 ajastus kokonaan');
  perform public.t121_ck(public.t121_try($q$select booking.admin_save_message(null, '{"name":"T121","category":"instruction","slug":"x"}'::jsonb)$q$) = 'unknown_field', 'E7 tuntematon kenttä');
  perform public.t121_ck(public.t121_try($q$select booking.admin_save_message(null, '{"name":"T121","category":"instruction","product_ids":[999999999]}'::jsonb)$q$) = 'invalid_product', 'E8 tuntematon tuote');

  res := booking.admin_product_create(jsonb_build_object('name', 'T121 viestituote', 'price', 1, 'vat_rate', 25.5, 'active', false));
  pid := (res ->> 'id')::bigint;
  res := booking.admin_product_create(jsonb_build_object('name', 'T121 viestituote 2', 'price', 1, 'vat_rate', 25.5, 'active', false));
  pid2 := (res ->> 'id')::bigint;
  res := booking.admin_product_create(jsonb_build_object('name', 'T121 myohastuote', 'price', 1, 'vat_rate', 25.5, 'active', false));
  pid_late := (res ->> 'id')::bigint;
  perform public.t121_ck(pid is not null and pid2 is not null and pid_late is not null, 'P1 tuotteet');

  res := booking.admin_save_message(null, jsonb_build_object(
    'name', 'T121 muistutus', 'category', 'after_marketing', 'active', true,
    'subject_fi', 'Hei {asiakas_nimi}', 'body_fi', 'Linkki {tilaus_linkki} tuote {tuote}',
    'send_amount', 1, 'send_unit', 'minutes', 'send_direction', 'after', 'send_anchor', 'booking',
    'product_ids', jsonb_build_array(pid, pid2)));
  mid := (res ->> 'id')::bigint;
  perform public.t121_ck(res ->> 'ok' = 'true' and mid is not null, 'P2 tallennus');
  perform public.t121_ck((select count(*) from booking.message_products where message_id = mid) = 2, 'P3 kaksi tuotetta');

  res := booking.admin_save_message(null, jsonb_build_object(
    'name', 'T121 odotus', 'category', 'feedback', 'active', true,
    'subject_fi', 'Palaute', 'body_fi', 'Kerro {linkki}', 'link_url', 'https://example.test/palaute',
    'send_amount', 2, 'send_unit', 'days', 'send_direction', 'before', 'send_anchor', 'arrival',
    'product_ids', jsonb_build_array(pid)));
  mid_wait := (res ->> 'id')::bigint;

  res := booking.admin_save_message(null, jsonb_build_object(
    'name', 'T121 myohassa', 'category', 'after_marketing', 'active', true,
    'subject_fi', 'Myöhässä', 'body_fi', 'Vanha',
    'send_amount', 1, 'send_unit', 'minutes', 'send_direction', 'after', 'send_anchor', 'booking',
    'product_ids', jsonb_build_array(pid_late)));
  mid_late := (res ->> 'id')::bigint;

  res := booking.admin_save_message(null, jsonb_build_object(
    'name', 'T121 ohi', 'category', 'instruction', 'active', true,
    'subject_fi', 'Ohje', 'short_fi', 'Lyhyt {asiakas_nimi}', 'body_fi', 'Täysi ohje',
    'send_amount', 2, 'send_unit', 'days', 'send_direction', 'before', 'send_anchor', 'arrival',
    'product_ids', jsonb_build_array(pid)));
  mid_miss := (res ->> 'id')::bigint;

  res := booking.admin_save_message(null, jsonb_build_object(
    'name', 'T121 pois', 'category', 'after_marketing', 'active', false,
    'subject_fi', 'Pois', 'body_fi', 'Ei lähde',
    'send_amount', 1, 'send_unit', 'minutes', 'send_direction', 'after', 'send_anchor', 'booking',
    'product_ids', jsonb_build_array(pid)));
  mid_off := (res ->> 'id')::bigint;

  res := booking.admin_save_message(null, jsonb_build_object(
    'name', 'T121 ohje', 'category', 'instruction', 'active', true,
    'subject_fi', 'Ennen käyntiä', 'subject_en', 'Before',
    'short_fi', 'Lyhyt {asiakas_nimi}', 'body_fi', 'Täysi {tuote}', 'body_en', 'Full {tuote}',
    'product_ids', jsonb_build_array(pid)));
  mid_guide := (res ->> 'id')::bigint;
  perform public.t121_ck((res -> 'message' ->> 'send_amount') is null, 'P4 ohje ilman ajastusta');

  perform public.t121_ck((booking.admin_set_messages_timed(false) ->> 'timed_enabled') = 'false', 'S4 kytkin tallentuu pois');
  perform public.t121_logout();

  insert into booking.resources(code, name, kind) values ('t121-space', 'T121 tila', 'space') returning id into space_id;
  insert into booking.customers(name, email) values ('T121 Aada', 't121-aada@example.test') returning id into c_id;

  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, created_at)
  values (c_id, 'completed', 'paid', 10, 'admin', 'fi', now() - interval '5 minutes') returning id, public_token into o_due, tok;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_due, pid, 'T121 viestituote', 'product', 1, 10, 10, 25.5),
         (o_due, pid2, 'T121 viestituote 2', 'product', 1, 1, 1, 25.5);

  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, created_at)
  values (c_id, 'completed', 'refunded', 10, 'admin', 'fi', now() - interval '5 minutes') returning id into o_refund;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_refund, pid, 'T121 viestituote', 'product', 1, 10, 10, 25.5);

  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, created_at)
  values (c_id, 'completed', 'partially_refunded', 10, 'admin', 'fi', now() - interval '5 minutes') returning id into o_part;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_part, pid, 'T121 viestituote', 'product', 1, 10, 10, 25.5);

  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, external_source, external_id, created_at)
  values (c_id, 'completed', 'paid', 10, 'johku_import', 'fi', 'johku', 't121-ext', now() - interval '5 minutes') returning id into o_ext;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_ext, pid, 'T121 viestituote', 'product', 1, 10, 10, 25.5);

  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, created_at)
  values (c_id, 'cancelled', 'paid', 10, 'admin', 'fi', now() - interval '5 minutes') returning id into o_cancel;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_cancel, pid, 'T121 viestituote', 'product', 1, 10, 10, 25.5);

  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale)
  values (c_id, 'completed', 'paid', 10, 'admin', 'fi') returning id into o_wait;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_wait, pid, 'T121 viestituote', 'reservation', 1, 10, 10, 25.5);
  insert into booking.reservations(order_id, product_id, space_id, mode, starts_at, ends_at, persons, status)
  values (o_wait, pid, space_id, 'exclusive', now() + interval '10 days', now() + interval '10 days 2 hours', 1, 'completed');

  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, created_at)
  values (c_id, 'completed', 'paid', 10, 'admin', 'fi', now() - interval '10 days') returning id into o_late;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_late, pid_late, 'T121 myohastuote', 'product', 1, 10, 10, 25.5);

  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale)
  values (c_id, 'completed', 'paid', 10, 'admin', 'en') returning id into o_miss;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_miss, pid, 'T121 viestituote', 'reservation', 1, 10, 10, 25.5);
  insert into booking.reservations(order_id, product_id, space_id, mode, starts_at, ends_at, persons, status)
  values (o_miss, pid, space_id, 'exclusive', now() + interval '1 hour', now() + interval '2 hours', 1, 'completed');

  insert into booking.orders(status, payment_status, total_gross, source_channel, locale, created_at)
  values ('completed', 'paid', 10, 'admin', 'fi', now() - interval '5 minutes') returning id into o_nomail;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (o_nomail, pid, 'T121 viestituote', 'product', 1, 10, 10, 25.5);

  perform public.t121_ck(exists (select 1 from jsonb_array_elements(booking._order_short_instructions(o_due, 'fi')) e where e ->> 'text' like '%T121 Aada%'), 'I1 lyhyt ohje');
  perform public.t121_ck(exists (select 1 from jsonb_array_elements(booking._order_full_instructions(o_due, 'fi')) e where e ->> 'body' like '%T121 viestituote%'), 'I2 täysi ohje');
  perform public.t121_ck(booking._order_short_instructions(o_miss, 'en') -> 0 ->> 'text' like '%T121 Aada%', 'I3 englanti puuttuu, suomi kelpaa');
  perform public.t121_ck((select booking._setting('messages.timed_enabled') = 'false'::jsonb), 'S5 yhä pois');

  perform public.t121_ck(booking.messages_dispatch() = 0, 'J1 kytkin pois ei jonota');
  perform public.t121_ck(not exists (select 1 from booking.email_outbox e where e.kind = 'product_message' and e.order_id in (o_due, o_refund, o_part, o_ext, o_cancel, o_wait, o_late, o_miss, o_nomail)), 'J2 ei rivejä');

  perform public.t121_login(u_mgr);
  perform booking.admin_set_messages_timed(true);
  perform public.t121_logout();

  n := booking.messages_dispatch();
  perform public.t121_ck(n > 0, 'J3 kytkin päällä käsittelee');

  perform public.t121_ck((select count(*) from booking.email_outbox e where e.dedupe_key = 'product_message:' || mid::text || ':' || o_due::text) = 1, 'J4 yksi viesti kahdesta tuotteesta');
  perform public.t121_ck((select status from booking.email_outbox e where e.dedupe_key = 'product_message:' || mid::text || ':' || o_due::text) in ('pending', 'skipped')
    and (select last_error from booking.email_outbox e where e.dedupe_key = 'product_message:' || mid::text || ':' || o_due::text) is null, 'J5 lähetys tai resend off');
  perform public.t121_ck((select count(*) from booking.email_outbox e where e.dedupe_key = 'product_message:' || mid::text || ':' || o_due::text and e.last_error is null) = 1, 'J6 sama viesti kerran');
  perform public.t121_ck((select last_error from booking.email_outbox e where e.dedupe_key = 'product_message:' || mid::text || ':' || o_refund::text) = 'refunded', 'J7 hyvitetty ohitetaan');
  perform public.t121_ck((select last_error from booking.email_outbox e where e.dedupe_key = 'product_message:' || mid::text || ':' || o_part::text) is null, 'J8 osahyvitys lähtee');
  perform public.t121_ck(not exists (select 1 from booking.email_outbox e where e.order_id = o_ext and e.kind = 'product_message'), 'J9 tuonti ei saa riviä');
  perform public.t121_ck(not exists (select 1 from booking.email_outbox e where e.order_id = o_cancel and e.kind = 'product_message'), 'J10 peruttu ei saa riviä');
  perform public.t121_ck(not exists (select 1 from booking.email_outbox e where e.dedupe_key = 'product_message:' || mid_wait::text || ':' || o_wait::text), 'J11 odotus ei kirjoita');
  perform public.t121_ck((select last_error from booking.email_outbox e where e.dedupe_key = 'product_message:' || mid_late::text || ':' || o_late::text) = 'too_late', 'J12 liian myöhään');
  perform public.t121_ck((select last_error from booking.email_outbox e where e.dedupe_key = 'product_message:' || mid_miss::text || ':' || o_miss::text) = 'missed_at_booking', 'J13 ohi tilatessa');
  perform public.t121_ck(not exists (select 1 from booking.email_outbox e where e.dedupe_key like 'product_message:' || mid_off::text || ':%'), 'J14 pois päältä ei lähde');
  perform public.t121_ck(not exists (select 1 from booking.email_outbox e where e.dedupe_key like 'product_message:' || mid_guide::text || ':%'), 'J15 ohje ilman ajastusta ei jonotu');
  perform public.t121_ck((select last_error from booking.email_outbox e where e.dedupe_key = 'product_message:' || mid::text || ':' || o_nomail::text) = 'no_email', 'J16 ei osoitetta');

  n2 := booking.messages_dispatch();
  perform public.t121_ck(n2 = 0, 'J17 toinen ajo ei lisää');
  perform public.t121_ck((select count(*) from booking.email_outbox e where e.dedupe_key = 'product_message:' || mid::text || ':' || o_due::text) = 1, 'J18 dedupe');

  res := booking.public_get_order(tok);
  perform public.t121_ck(exists (select 1 from jsonb_array_elements(res -> 'instructions') e where e ->> 'body' like '%T121 viestituote%'), 'I4 tilaussivu');
  perform public.t121_ck(jsonb_array_length(res -> 'instructions') = 2, 'I5 molemmat ohjeet');

  log := current_setting('t121.log', true);
  select count(*) filter (where l like 'P %'), count(*) filter (where l like 'F %') into npass, nfail from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l;
  raise exception 'TESTRESULT pass=% fail=% :: %', npass, nfail, coalesce((select string_agg(l, ' | ') from unnest(string_to_array(trim(both E'\n' from log), E'\n')) l where l like 'F %'), 'ALL OK');
end $t$;
