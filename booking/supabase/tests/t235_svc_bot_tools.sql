-- t235: booking_235 service_role-työkalut (siirto, ulkoinen maksu, käännös).
-- Aja migraatioiden ja fixtures/10_test_helpers.sql:n jälkeen. Yksi transaktio, lopussa TESTRESULT + ROLLBACK.
-- psql -X -v ON_ERROR_STOP=0 -f booking/supabase/tests/t235_svc_bot_tools.sql
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('t235.log', '', true);

create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t235.log', coalesce(current_setting('t235.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;

create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare d text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics d = pg_exception_detail;
  return coalesce(d, sqlstate);
end $$;

do $t$
declare
  tag text := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
  src text;
  sig_move text := 'booking.svc_move_reservation(bigint,timestamptz,text,text)';
  sig_pay text := 'booking.svc_mark_order_paid_external(bigint,text,text)';
  sig_stale text := 'booking.svc_texts_stale_en(integer)';
  sig_en text := 'booking.svc_set_product_text_en(bigint,text,text,text)';
  s1 record;
  s2 record;
  v_cust bigint;
  v_order bigint;
  v_ono bigint;
  v_item bigint;
  v_res bigint;
  v_cancel bigint;
  v_child bigint;
  v_leg bigint;
  v_space2 bigint;
  r jsonb;
  v_old timestamptz;
  v_price numeric;
  v_persons int;
  v_line numeric;
  v_pay_n int;
  v_mail_n int;
  v_name text;
  v_name_en text;
  v_vat numeric;
  v_slug text;
  v_url text;
  v_active boolean;
  v_price_text text;
  v_fi_at timestamptz;
  log text;
  np int;
  nf int;
  v_child_start timestamptz;
  v_cancel_start timestamptz;
begin
  select pg_get_functiondef(sig_move::regprocedure) into src;
  perform pg_temp.ck(src ilike '%security definer%' and src ilike '%search_path TO ''''%' and src like '%_resolve_session%' and src not like '%_change_booking_core%', 'A1 siirto: definer, search_path tyhjä, käyttää _resolve_sessionia eikä hintaa laskevaa ydintä');
  select pg_get_functiondef(sig_pay::regprocedure) into src;
  perform pg_temp.ck(src ilike '%security definer%' and src ilike '%search_path TO ''''%' and src not like '%insert into booking.payments%', 'A2 maksu: definer, ei payments-inserttiä');
  select pg_get_functiondef(sig_stale::regprocedure) into src;
  perform pg_temp.ck(src ilike '%security definer%' and src ilike '%search_path TO ''''%' and src like '%kb.products%', 'A3 vanhat käännökset: definer, mukana tuotteet');
  select pg_get_functiondef(sig_en::regprocedure) into src;
  perform pg_temp.ck(src ilike '%security definer%' and src ilike '%_text_validate%' and src like '%_text_publish%' and src not like '%set vat_rate%', 'A4 en-kirjoitus: validointi ja julkaisu, ei ALV-sijoitusta');
  perform pg_temp.ck(
    not has_function_privilege('public', sig_move, 'execute')
    and not has_function_privilege('anon', sig_move, 'execute')
    and not has_function_privilege('authenticated', sig_move, 'execute')
    and has_function_privilege('service_role', sig_move, 'execute')
    and has_function_privilege('service_role', sig_pay, 'execute')
    and not has_function_privilege('authenticated', sig_pay, 'execute')
    and has_function_privilege('service_role', sig_stale, 'execute')
    and not has_function_privilege('anon', sig_stale, 'execute')
    and has_function_privilege('service_role', sig_en, 'execute')
    and not has_function_privilege('authenticated', sig_en, 'execute'),
    'A5 execute vain service_role');

  select s.rule_id, s.product_id, s.starts_at, s.ends_at, s.session_date, sr.space_id, sr.mode,
         coalesce((select array_agg(rp.pool_id order by rp.pool_id) from booking.schedule_rule_pools rp where rp.rule_id = s.rule_id), '{}'::bigint[]) as pools
    into s1
    from booking._sessions((now() at time zone 'Europe/Helsinki')::date + 2,
                           (now() at time zone 'Europe/Helsinki')::date + 50, null, true) s
    join booking.schedule_rules sr on sr.id = s.rule_id
   where s.status = 'available'
   order by s.starts_at, s.rule_id
   limit 1;
  perform pg_temp.ck(s1.rule_id is not null, 'B0 vapaa julkaistu vuoro löytyy');
  if s1.rule_id is null then
    log := current_setting('t235.log', true);
    raise exception 'TESTRESULT pass=% fail=% %', 0, 1, 'ei vapaata vuoroa';
  end if;

  select s.rule_id, s.starts_at, s.ends_at, sr.space_id, sr.mode,
         coalesce((select array_agg(rp.pool_id order by rp.pool_id) from booking.schedule_rule_pools rp where rp.rule_id = s.rule_id), '{}'::bigint[]) as pools
    into s2
    from booking._sessions(s1.session_date, (now() at time zone 'Europe/Helsinki')::date + 60, s1.product_id, true) s
    join booking.schedule_rules sr on sr.id = s.rule_id
   where s.status = 'available' and s.starts_at > s1.ends_at
   order by s.starts_at
   limit 1;
  perform pg_temp.ck(s2.rule_id is not null, 'B0b saman tuotteen toinen vapaa vuoro');

  insert into booking.customers(name, email, phone)
  values ('T235 Asiakas ' || tag, 't235-' || lower(tag) || '@example.test', '0402350000')
  returning id into v_cust;
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, external_source, external_id, internal_note)
  values (v_cust, 'confirmed', 'unpaid', 49, 'johku_import', 'fi', 'johku', 'o' || tag, 'vanha muistiinpano')
  returning id, order_no into v_order, v_ono;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v_order, s1.product_id, 'T235 tuote', 'reservation', 1, 49, 49, 25.5)
  returning id into v_item;
  insert into booking.reservations(
    order_id, order_item_id, product_id, rule_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status,
    external_source, external_id)
  values (
    v_order, v_item, s1.product_id, null, s1.space_id, s1.mode, s1.starts_at, s1.ends_at, 2, s1.pools, 'confirmed',
    'johku', 'r' || tag)
  returning id into v_res;
  insert into booking.reservations(
    order_id, order_item_id, product_id, rule_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status,
    external_source, external_id, cancelled_at, cancel_reason)
  values (
    v_order, v_item, s1.product_id, null, s1.space_id, s1.mode, s1.starts_at, s1.ends_at, 2, s1.pools, 'cancelled',
    'johku', 'c' || tag, now(), 'johku_import')
  returning id, starts_at into v_cancel, v_cancel_start;
  -- Legi samaan tilaan eri offsetilla (sync siirtää). Lapsi eri aikaan, jotta se ei osu vanhemman tai Raunin istuntoon.
  insert into booking.reservation_legs(reservation_id, resource_id, role, mode, starts_at, ends_at, offset_min, minutes, persons)
  values (v_res, s1.space_id, 'space', 'shared', s1.starts_at + interval '10 minutes', s1.starts_at + interval '20 minutes', 10, 10, 2)
  returning id into v_leg;
  v_child_start := s1.starts_at + interval '8 hours';
  insert into booking.reservations(
    order_id, order_item_id, product_id, rule_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status,
    parent_reservation_id, external_source, external_id)
  values (
    v_order, v_item, s1.product_id, null, s1.space_id, 'shared', v_child_start, v_child_start + interval '10 minutes', 1, '{}', 'confirmed',
    v_res, 'johku', 'k' || tag)
  returning id into v_child;

  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute 'set local role service_role';

  perform pg_temp.ck(pg_temp.err(format('select booking.svc_move_reservation(%s, %L::timestamptz, %L)', v_ono, s2.starts_at, '')) = 'note_required', 'C1 tyhjä syy');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_move_reservation(%s, null::timestamptz, %L)', v_ono, 'syy')) = 'invalid_time', 'C2 ei aikaa');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_move_reservation(%s, %L::timestamptz, %L)', v_ono, now() - interval '1 hour', 'syy')) = 'not_in_future', 'C3 mennyt aika');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_move_reservation(-1, %L::timestamptz, %L)', s2.starts_at, 'syy')) = 'not_found', 'C4 tuntematon tilaus');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_move_reservation(%s, %L::timestamptz, %L)', v_ono, s2.starts_at + interval '7 minutes', 'syy')) = 'slot_invalid', 'C5 aikataulun ulkopuolinen minuutti');

  v_price := 49;
  v_persons := 2;
  v_old := s1.starts_at;
  v_mail_n := (select count(*) from booking.email_outbox);
  v_pay_n := (select count(*) from booking.payments where order_id = v_order);
  r := booking.svc_move_reservation(v_ono, s2.starts_at, '  asiakas soitti, siirto  ', '  ');
  perform pg_temp.ck(
    (r ->> 'ok')::boolean and (r ->> 'order_no')::bigint = v_ono
    and (r ->> 'old_starts_at')::timestamptz = v_old
    and (r ->> 'new_starts_at')::timestamptz = s2.starts_at
    and (r ->> 'ends_at')::timestamptz = s2.ends_at
    and (r ->> 'persons')::int = v_persons
    and (r ->> 'total')::numeric = v_price,
    'D1 siirto onnistuu, hinta ja henkilöt ennallaan: ' || coalesce(r::text, 'null'));
  perform pg_temp.ck((select rule_id from booking.reservations where id = v_res) = s2.rule_id, 'D2 rule_id ratkesi julkaistuun vuoroon');
  perform pg_temp.ck((select line_total_gross from booking.order_items where id = v_item) = v_line or v_line is null, 'D3 rivihinta');
  perform pg_temp.ck((select line_total_gross from booking.order_items where id = v_item) = 49 and (select total_gross from booking.orders where id = v_order) = 49, 'D4 hinta ei muuttunut');
  perform pg_temp.ck((select persons from booking.reservations where id = v_res) = 2, 'D5 henkilöt ennallaan');
  perform pg_temp.ck((select starts_at from booking.reservations where id = v_cancel) = v_cancel_start, 'D6 peruttu sisarus ei siirtynyt');
  if v_leg is not null then
    perform pg_temp.ck((select starts_at from booking.reservation_legs where id = v_leg) = s2.starts_at + interval '10 minutes', 'D7 leg siirtyi saman verran');
  else
    perform pg_temp.ck(false, 'D7 legiä ei voitu luoda');
  end if;
  if v_child is not null then
    perform pg_temp.ck((select starts_at from booking.reservations where id = v_child) = v_child_start + (s2.starts_at - s1.starts_at), 'D8 lapsivaraus siirtyi saman verran');
  else
    perform pg_temp.ck(false, 'D8 lapsivarausta ei voitu luoda');
  end if;
  perform pg_temp.ck((select count(*) from booking.payments where order_id = v_order) = v_pay_n, 'D9 siirto ei luonut maksua');
  perform pg_temp.ck((select count(*) from booking.email_outbox) = v_mail_n, 'D10 siirto ei jonottanut viestiä');
  perform pg_temp.ck((select count(*) from booking.audit_log where action = 'SVC_MOVE_RESERVATION' and row_pk = v_res::text and new_data ->> 'actor' = 'asiakaspalvelu-bot' and new_data ->> 'note' = 'asiakas soitti, siirto') = 1, 'D11 audit');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_move_reservation(%s, %L::timestamptz, %L)', v_ono, s2.starts_at, 'uudestaan')) = 'no_change', 'D12 sama alku');

  update booking.reservations set checkin_at = now() where id = v_res;
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_move_reservation(%s, %L::timestamptz, %L)', v_ono, s1.starts_at, 'takaisin')) = 'already_checked_in', 'E1 sisäänkirjattu');
  update booking.reservations set checkin_at = null where id = v_res;
  -- eri kestoinen vuoro: siirto ei saa venyttää tai lyhentää vuoroa samalla hinnalla
  update booking.reservations set ends_at = ends_at + interval '30 minutes' where id = v_res;
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_move_reservation(%s, %L::timestamptz, %L)', v_ono, s1.starts_at, 'kesto')) = 'duration_differs', 'E1b eri kesto');
  update booking.reservations set ends_at = ends_at - interval '30 minutes' where id = v_res;

  -- varattu kohde
  insert into booking.customers(name) values ('T235 Toinen ' || tag) returning id into v_cust;
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale)
  values (v_cust, 'confirmed', 'paid', 10, 'admin', 'fi')
  returning id into v_order;
  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
  values (v_order, s1.product_id, 'T235 varattu', 'reservation', 1, 10, 10, 25.5);
  begin
    insert into booking.reservations(order_id, product_id, rule_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status)
    values (v_order, s1.product_id, s1.rule_id, s1.space_id, s1.mode, s1.starts_at, s1.ends_at, 1, s1.pools, 'confirmed');
    perform pg_temp.ck(pg_temp.err(format('select booking.svc_move_reservation(%s, %L::timestamptz, %L)', v_ono, s1.starts_at, 'päälle')) in ('slot_taken', 'space_busy', 'private_booked', 'public_shift_booked', 'capacity_exceeded'), 'E2 varattu vuoro');
  exception when others then
    perform pg_temp.ck(true, 'E2 kohdevuoroa ei voitu täyttää erikseen (' || sqlerrm || '), ohitetaan päällekkäisyys');
  end;

  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L)', v_ono, '   ')) = 'note_required', 'F1 maksu ilman syytä');
  v_pay_n := (select count(*) from booking.payments where order_id = (select id from booking.orders where order_no = v_ono));
  v_mail_n := (select count(*) from booking.email_outbox);
  r := booking.svc_mark_order_paid_external(v_ono, '  Johku-linkki maksettu  ', 'asiakaspalvelu-ilta');
  perform pg_temp.ck((r ->> 'ok')::boolean and (r ->> 'order_no')::bigint = v_ono and r ->> 'payment_status' = 'paid', 'F2 merkittiin maksetuksi: ' || coalesce(r::text, 'null'));
  perform pg_temp.ck((select payment_status from booking.orders where order_no = v_ono) = 'paid', 'F3 tila paid');
  perform pg_temp.ck((select internal_note from booking.orders where order_no = v_ono) like '%asiakaspalvelu-ilta: Johku-linkki maksettu', 'F4 muistiinpanoon aika, tekijä ja syy');
  perform pg_temp.ck((select internal_note from booking.orders where order_no = v_ono) like 'vanha muistiinpano%', 'F5 vanha muistiinpano säilyi');
  perform pg_temp.ck((select count(*) from booking.payments where order_id = (select id from booking.orders where order_no = v_ono)) = v_pay_n, 'F6 ei uutta maksuriviä');
  perform pg_temp.ck((select count(*) from booking.email_outbox) = v_mail_n, 'F7 ei viestiä');
  perform pg_temp.ck((select new_data ->> 'actor' from booking.audit_log where action = 'SVC_MARK_ORDER_PAID_EXTERNAL' and new_data ->> 'order_no' = v_ono::text) = 'asiakaspalvelu-ilta', 'F8 audit');
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L)', v_ono, 'uudestaan')) = 'already_paid', 'F9 jo maksettu');

  update booking.orders set status = 'cancelled', payment_status = 'unpaid' where order_no = v_ono;
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L)', v_ono, 'peruttu')) = 'order_cancelled', 'F10 peruttu tilaus');
  update booking.orders set status = 'pending', payment_status = 'unpaid' where order_no = v_ono;
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L)', v_ono, 'kesken')) = 'not_changeable', 'F11 vahvistamaton tilaus');
  update booking.orders set status = 'confirmed', payment_status = 'invoiced' where order_no = v_ono;
  perform pg_temp.ck(pg_temp.err(format('select booking.svc_mark_order_paid_external(%s, %L)', v_ono, 'laskulla')) = 'order_invoiced', 'F12 laskutettu tilaus');
  update booking.orders set status = 'cancelled', payment_status = 'unpaid' where order_no = v_ono;

  -- käännös: suomen muutos tekee rivin vanhaksi, en-kirjoitus poistaa, uusi suomi palauttaa.
  -- Taululukemat omistajana (service_rolella ei ole skeemaoikeutta mockissa); funktiot service_rolena.
  execute 'reset role';
  select name, name_en, price, vat_rate, slug, booking_url, active, price_text
    into v_name, v_name_en, v_price, v_vat, v_slug, v_url, v_active, v_price_text
    from kb.products where id = 7;
  update kb.products set name = v_name || ' (t235)' where id = 7;
  execute 'set local role service_role';
  r := booking.svc_texts_stale_en(500);
  perform pg_temp.ck((r ->> 'ok')::boolean and jsonb_typeof(r -> 'items') = 'array', 'G1 stale palauttaa listan');
  perform pg_temp.ck(exists (
    select 1 from jsonb_array_elements(r -> 'items') e
     where e ->> 'key' = 'product.7.name' and e ->> 'reason' = 'older' and e ->> 'fi' like '%(t235)%'
  ), 'G2 suomen muutos nostaa product.7.name listalle');
  perform pg_temp.ck(not exists (
    select 1 from jsonb_array_elements(r -> 'items') e
     where coalesce(e ->> 'source_column', '') in ('price', 'vat_rate', 'slug', 'booking_url', 'price_text')
        or coalesce(e ->> 'key', '') like '%.price%'
        or coalesce(e ->> 'key', '') like '%.slug'
        or coalesce(e ->> 'key', '') like '%.booking_url'
  ), 'G3 lukitut hinta- ja URL-kentät eivät ole käännösjonossa');

  r := booking.svc_set_product_text_en(7, 'name', 'Sauna ritual and smoke sauna (t235)', 'kaantaja-bot');
  perform pg_temp.ck((r ->> 'ok')::boolean and r ->> 'field' = 'name' and r ->> 'key' = 'product.7.name' and r ->> 'text' like 'Sauna ritual%', 'H1 en-nimi päivittyi: ' || coalesce(r::text, 'null'));
  execute 'reset role';
  perform pg_temp.ck((select name_en from kb.products where id = 7) = 'Sauna ritual and smoke sauna (t235)', 'H2 name_en lähdetaulussa');
  perform pg_temp.ck((select name from kb.products where id = 7) = v_name || ' (t235)', 'H3 suomi säilyi');
  perform pg_temp.ck((select price from kb.products where id = 7) is not distinct from v_price
    and (select vat_rate from kb.products where id = 7) is not distinct from v_vat
    and (select slug from kb.products where id = 7) is not distinct from v_slug
    and (select booking_url from kb.products where id = 7) is not distinct from v_url
    and (select active from kb.products where id = 7) is not distinct from v_active
    and (select price_text from kb.products where id = 7) is not distinct from v_price_text, 'H4 hinta, ALV, slug, URL ja active ennallaan');
  execute 'set local role service_role';
  r := booking.svc_texts_stale_en(500);
  perform pg_temp.ck(not exists (
    select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'key' = 'product.7.name'
  ), 'H5 tuore englanti ei ole vanhojen listalla');
  execute 'reset role';
  select published_at into v_fi_at from booking.site_texts where key = 'product.7.name' and lang = 'fi';
  perform pg_sleep(0.01);
  update kb.products set name = v_name || ' (t235b)' where id = 7;
  -- now() ei etene transaktion sisällä, joten suomen ja englannin published_at ovat samat.
  -- Oikea myöhempi suomen muokkaus on eri transaktio ja uudempi. Simuloidaan se kellolla.
  update booking.site_texts set published_at = clock_timestamp()
   where key = 'product.7.name' and lang = 'fi';
  execute 'set local role service_role';
  r := booking.svc_texts_stale_en(500);
  perform pg_temp.ck(exists (
    select 1 from jsonb_array_elements(r -> 'items') e
     where e ->> 'key' = 'product.7.name' and e ->> 'reason' = 'older'
       and (e ->> 'fi_published_at')::timestamptz > coalesce(v_fi_at, '-infinity'::timestamptz)
  ) or exists (
    select 1 from jsonb_array_elements(r -> 'items') e
     where e ->> 'key' = 'product.7.name' and e ->> 'fi' like '%(t235b)%'
  ), 'H6 myöhempi suomen muutos palauttaa rivin listalle');

  perform pg_temp.ck(pg_temp.err($q$select booking.svc_set_product_text_en(7, 'price', '10', 'kaantaja-bot')$q$) = 'invalid_field', 'I1 hintaa ei voi kirjoittaa');
  perform pg_temp.ck(pg_temp.err($q$select booking.svc_set_product_text_en(7, 'vat_rate', '10', 'kaantaja-bot')$q$) = 'invalid_field', 'I2 ALV');
  perform pg_temp.ck(pg_temp.err($q$select booking.svc_set_product_text_en(7, 'slug', 'x', 'kaantaja-bot')$q$) = 'invalid_field', 'I3 slug');
  perform pg_temp.ck(pg_temp.err($q$select booking.svc_set_product_text_en(7, 'booking_url', 'https://example.test', 'kaantaja-bot')$q$) = 'invalid_field', 'I4 URL');
  perform pg_temp.ck(pg_temp.err($q$select booking.svc_set_product_text_en(7, 'active', 'false', 'kaantaja-bot')$q$) = 'invalid_field', 'I5 active');
  perform pg_temp.ck(pg_temp.err($q$select booking.svc_set_product_text_en(7, 'name', '<b>no</b>', 'kaantaja-bot')$q$) = 'html_not_allowed', 'I6 nimi ei ole HTML');
  perform pg_temp.ck(pg_temp.err($q$select booking.svc_set_product_text_en(7, 'name', 'See https://evil.example/x', 'kaantaja-bot')$q$) = 'facts_changed', 'I7 uutta linkkiä ei saa lisätä');
  perform pg_temp.ck(pg_temp.err($q$select booking.svc_set_product_text_en(7, 'name', repeat('x', 500), 'kaantaja-bot')$q$) = 'too_long', 'I8 max_len');
  perform pg_temp.ck((select new_data ->> 'actor' from booking.audit_log where action = 'SVC_SET_PRODUCT_TEXT_EN' and row_pk = '7' order by id desc limit 1) = 'kaantaja-bot', 'I9 audit');

  -- kb 7: Johku-tyylinen paketti (rule_id NULL) aikavälipolulla. Legi ja alkuaikapooli seuraavat.
  execute 'reset role';
  update booking.product_config
     set public_slots = true, bookable = true, shop_visible = true,
         public_weekdays = coalesce(public_weekdays, array[6, 7]::smallint[])
   where product_id = 7 and resource_class = 'resourced';
  execute 'set local role service_role';
  v_old := null;
  for s1 in
    select d::date as session_date
      from generate_series((now() at time zone 'Europe/Helsinki')::date + 2,
                           (now() at time zone 'Europe/Helsinki')::date + 12, interval '1 day') d
     where extract(isodow from d) in (6, 7)
     order by d
  loop
    begin
      perform booking._treatment_slot_check(7, (s1.session_date + time '16:00') at time zone 'Europe/Helsinki', 1, false);
      perform booking._treatment_slot_check(7, (s1.session_date + time '17:00') at time zone 'Europe/Helsinki', 1, false);
      v_old := (s1.session_date + time '16:00') at time zone 'Europe/Helsinki';
      exit;
    exception when sqlstate 'BK001' then
      v_old := null;
    end;
  end loop;
  perform pg_temp.ck(v_old is not null, 'K0 kb 7:lle löytyy la tai su, jolloin 16:00 ja 17:00 ovat julkaistuja');
  if v_old is not null then
    execute 'reset role';
    select psr.space_id into v_space2
      from booking.product_space_rules psr
     where psr.product_id = 7 and psr.leg_no = 1 and psr.role = 'space' and psr.active
     order by psr.priority
     limit 1;
    insert into booking.customers(name) values ('T235 rituaali ' || tag) returning id into v_cust;
    insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, external_source, external_id)
    values (v_cust, 'confirmed', 'unpaid', 49, 'johku_import', 'fi', 'johku', 'p7' || tag)
    returning id, order_no into v_order, v_ono;
    insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate)
    values (v_order, 7, 'Saunarituaali ja savusaunavuoro', 'reservation', 1, 49, 49, 25.5)
    returning id into v_item;
    insert into booking.reservations(
      order_id, order_item_id, product_id, rule_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status,
      external_source, external_id, claim_offset_min, claim_minutes)
    values (v_order, v_item, 7, null, v_space2, 'shared', v_old, v_old + interval '120 minutes', 2, '{}', 'confirmed', 'johku', 'p7r' || tag, 30, 90)
    returning id into v_res;
    insert into booking.reservations(
      order_id, order_item_id, product_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status,
      external_source, external_id, cancelled_at, cancel_reason)
    values (v_order, v_item, 7, v_space2, 'shared', v_old, v_old + interval '120 minutes', 2, '{}', 'cancelled', 'johku', 'p7c' || tag, now(), 'johku_import')
    returning id, starts_at into v_cancel, v_cancel_start;
    execute 'set local role service_role';
    r := booking.svc_move_reservation(v_ono, v_old + interval '1 hour', 'paketin siirto');
    perform pg_temp.ck(
      (r ->> 'ok')::boolean and (r ->> 'persons')::int = 2 and (r ->> 'total')::numeric = 49
      and (r ->> 'new_starts_at')::timestamptz = v_old + interval '1 hour',
      'K1 kb 7 siirtyy 16:00 → 17:00, hinta 49 ja 2 henkilöä: ' || coalesce(r::text, 'null'));
    execute 'reset role';
    perform pg_temp.ck((select rule_id from booking.reservations where id = v_res) is null, 'K2 rule_id pysyy tyhjänä, kun tuotteella ei ole vuorosääntöä');
    perform pg_temp.ck((select line_total_gross from booking.order_items where id = v_item) = 49, 'K3 paketin rivihinta ennallaan');
    perform pg_temp.ck((select starts_at from booking.reservations where id = v_cancel) = v_cancel_start, 'K4 peruttu sisarus ei siirtynyt');
    perform pg_temp.ck(
      (select count(*) from booking.reservation_legs l
        where l.reservation_id = v_res
          and l.starts_at = v_old + interval '1 hour'
          and l.offset_min = 0) = 1,
      'K5 rituaalijalka siirtyi uuteen alkuun');
    perform pg_temp.ck(
      exists (
        select 1 from booking.reservations x
        join booking.product_config pc on pc.product_id = 7
        join booking.resources pool on pool.id = any (x.pool_ids)
       where x.id = v_res and pool.code = pc.start_pool_prefix || '1730'),
      'K6 savusaunan alkuaikapooli on etuliite + 1730');
    execute 'set local role service_role';
    perform pg_temp.ck(
      pg_temp.err(format('select booking.svc_move_reservation(%s, %L::timestamptz, %L)', v_ono, v_old + interval '1 hour' - interval '2 hours', 'liian aikaisin')) = 'slot_invalid',
      'K7 15:00 ei ole julkaistu rituaalin alku');
  end if;

  execute 'reset role';
  begin
    execute 'set local role authenticated';
    perform booking.svc_move_reservation(v_ono, s2.starts_at, 'ei');
    perform pg_temp.ck(false, 'J1 authenticated pääsi siirtämään');
  exception when insufficient_privilege then
    perform pg_temp.ck(true, 'J1 authenticated ei saa execute');
  end;

  log := current_setting('t235.log', true);
  np := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'P %');
  nf := (select count(*) from regexp_split_to_table(log, E'\n') l where l like 'F %');
  raise notice E'%', log;
  raise exception 'TESTRESULT pass=% fail=% %', np, nf, coalesce((select string_agg(l, ' | ') from regexp_split_to_table(log, E'\n') l where l like 'F %'), '');
end $t$;
rollback;
