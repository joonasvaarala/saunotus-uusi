-- t116: yksi päiväpalkki (booking_116).
-- Aja SAMASSA transaktiossa kuin migraatio, kun booking.skip_cron = on.
-- Tyhjä päivä poistuu, aikaisempi varaus leventää palkkia, vanhat r:/s:-rivit poistuvat kahdesti ajettuna.
--   select set_config('booking.skip_cron','on', true);
--   \i booking/supabase/migrations/20261020053000_booking_116_calendar_day.sql
--   \i booking/supabase/tests/calendar/t116_booking_calendar_day.sql
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('booking.skip_audit', 'on', true);
select set_config('t116.log', '', true);
create or replace function public.t116_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t116.log', coalesce(current_setting('t116.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;

do $t$
declare
  cal text := 'varaukset-t116@group.calendar.google.com';
  v_closure text;
  savu_name text; rauni_name text;
  c_priv bigint := 99011601; c_co bigint := 99011602; c_sh bigint := 99011603;
  o_priv bigint := 99011631; o_co bigint := 99011632; o_a bigint := 99011633; o_b bigint := 99011634;
  o_next bigint := 99011635; o_pend bigint := 99011636; o_fail bigint := 99011637; o_can bigint := 99011638;
  r_priv bigint := 99011651; r_co bigint := 99011652; r_a bigint := 99011653; r_b bigint := 99011654;
  r_next bigint := 99011655; r_pend bigint := 99011656; r_fail bigint := 99011657; r_can bigint := 99011658;
  seq_cust bigint; seq_ord bigint; seq_res bigint;
  seq_cust2 bigint; seq_ord2 bigint; seq_res2 bigint;
  d jsonb; ev jsonb; ev2 jsonb; plan jsonb; fin jsonb;
  log text; npass int; nfail int;
begin
  perform public.t116_ck(coalesce(current_setting('booking.skip_cron', true), '') = 'on', 'C0 skip_cron on');
  select r.name into savu_name from booking.resources r where r.code = 'savusauna';
  select r.name into rauni_name from booking.resources r where r.code = 'rauni';
  select c.google_calendar_id into v_closure from booking.closure_calendars c where c.google_calendar_id is not null order by c.code limit 1;
  perform public.t116_ck(v_closure is not null, 'C9 sulkukalenteri löytyy');

  update booking.integration_config
     set mode = 'dry_run',
         settings = jsonb_set(
           jsonb_set(
             jsonb_set(coalesce(settings, '{}'::jsonb), '{fast_nudge}', 'false'::jsonb),
             '{shared_calendar_id}', to_jsonb(cal)),
           '{resource_calendars}', jsonb_build_object('savusauna', 'savu-t116-cal'))
   where key = 'booking_calendar';

  select last_value into seq_cust from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.customers', 'id'), '.', 2);
  select last_value into seq_ord from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.orders', 'id'), '.', 2);
  select last_value into seq_res from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.reservations', 'id'), '.', 2);

  insert into booking.customers(id, name, email, phone) overriding system value
  values (c_priv, 'Maija 0401234567 maija@example.test', 't116-maija@example.test', '0401234567');
  insert into booking.customers(id, name, email, phone, company, customer_kind, business_id) overriding system value
  values (c_co, 'Pekka Piilo 0409999999', 't116-pekka@example.test', '0409999999', 'Havu Paiva Oy', 'company', '9999999-2');
  insert into booking.customers(id, name) overriding system value values (c_sh, 'Vuoro Testi');

  insert into booking.orders(id, order_no, customer_id, status, payment_status, total_gross, currency, source_channel, locale, customer_kind)
  overriding system value values
    (o_priv, o_priv, c_priv, 'completed', 'unpaid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_co, o_co, c_co, 'completed', 'invoiced', 0, 'EUR', 'admin', 'fi', 'company'),
    (o_a, o_a, c_sh, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_b, o_b, c_sh, 'completed', 'unpaid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_next, o_next, c_priv, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_pend, o_pend, c_priv, 'completed', 'pending', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_fail, o_fail, c_priv, 'completed', 'failed', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_can, o_can, c_priv, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private');
  update booking.orders set billing = jsonb_build_object('company', 'Havu Paiva Oy') where id = o_co;

  insert into booking.reservations(id, order_id, product_id, space_id, mode, starts_at, ends_at, persons, status)
  overriding system value values
    (r_priv, o_priv, 25, 1, 'exclusive', timestamptz '2026-11-10 16:00:00+02', timestamptz '2026-11-10 19:00:00+02', 8, 'completed'),
    (r_a, o_a, 1, 1, 'shared', timestamptz '2026-11-10 17:00:00+02', timestamptz '2026-11-10 21:00:00+02', 2, 'completed'),
    (r_b, o_b, 1, 1, 'shared', timestamptz '2026-11-10 17:00:00+02', timestamptz '2026-11-10 21:00:00+02', 3, 'completed'),
    (r_next, o_next, 25, 1, 'exclusive', timestamptz '2026-11-17 10:00:00+02', timestamptz '2026-11-17 12:00:00+02', 2, 'completed'),
    (r_pend, o_pend, 25, 1, 'exclusive', timestamptz '2026-11-10 15:00:00+02', timestamptz '2026-11-10 16:00:00+02', 1, 'completed'),
    (r_fail, o_fail, 25, 1, 'exclusive', timestamptz '2026-11-10 08:00:00+02', timestamptz '2026-11-10 09:00:00+02', 1, 'completed'),
    (r_can, o_can, 25, 1, 'exclusive', timestamptz '2026-11-10 12:00:00+02', timestamptz '2026-11-10 13:00:00+02', 4, 'cancelled');

  d := booking._booking_calendar_desired();
  perform public.t116_ck(d ->> 'timezone' = 'Europe/Helsinki', 'T0 aikavyöhyke');
  perform public.t116_ck((select count(*) from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' in ('d:2026-11-10', 'd:2026-11-17')) = 2, 'D1 molemmat testipäivät');
  perform public.t116_ck((select count(*) from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' ~ '^[rs]:') = 0, 'D2 ei yksittäistapahtumia');
  select x into ev from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 'd:2026-11-10';
  perform public.t116_ck(ev ->> 'summary' = 'Varaukset 16–21 · 3 varausta', 'E1 otsikko ensimmäisestä alusta');
  perform public.t116_ck((ev ->> 'bookings')::int = 3 and (ev ->> 'persons')::int = 13, 'E2 kolme varausta');
  perform public.t116_ck(ev ->> 'google_event_id' = 'bkd20261110' and ev ->> 'kind' = 'day' and ev ->> 'resource_code' = 'all', 'E3 tunniste');
  perform public.t116_ck(ev ->> 'google_calendar_id' = cal, 'E4 yhteinen kalenteri, ei resurssin tunnusta');
  perform public.t116_ck(position('Maija' in (ev ->> 'description')) > 0, 'E5 nimi jää');
  perform public.t116_ck(position('040' in (ev ->> 'description')) = 0, 'E6 puhelin ei jää');
  perform public.t116_ck(position('@' in (ev ->> 'description')) = 0, 'E7 sähköposti ei jää');
  perform public.t116_ck(strpos(ev ->> 'description', '#' || o_priv::text) > 0, 'E8 yksityisen tilausnumero');
  perform public.t116_ck(position(savu_name || ' · yksityisvaraus · 8 hlö' in (ev ->> 'description')) > 0, 'E9 yksityinen rivi');
  perform public.t116_ck(position('Yleinen vuoro · 5 hlö (2 varausta)' in (ev ->> 'description')) > 0, 'E10 vuoro vain määrinä');
  perform public.t116_ck(position('Vuoro Testi' in (ev ->> 'description')) = 0, 'E11 vuorossa ei nimeä');
  perform public.t116_ck(strpos(ev ->> 'description', '#' || o_a::text) = 0 and strpos(ev ->> 'description', '#' || o_b::text) = 0, 'E12 vuorossa ei tilausnumeroita');
  perform public.t116_ck((ev ->> 'description') like '%/#/?d=2026-11-10%', 'E13 hallintalinkki');
  select x into ev2 from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 'd:2026-11-17';
  perform public.t116_ck(ev2 ->> 'summary' = 'Varaukset 10–12 · 1 varaus', 'E14 yhden varauksen päivä');
  perform public.t116_ck((select x ->> 'content_hash' from jsonb_array_elements(booking._booking_calendar_desired() -> 'events') x where x ->> 'event_key' = 'd:2026-11-10') = (ev ->> 'content_hash'), 'E15 tarkiste on vakaa');

  insert into booking.reservations(id, order_id, product_id, space_id, mode, starts_at, ends_at, persons, status)
  overriding system value values
    (r_co, o_co, 25, 12, 'exclusive', timestamptz '2026-11-10 14:00:00+02', timestamptz '2026-11-10 15:00:00+02', 6, 'completed');
  d := booking._booking_calendar_desired();
  select x into ev from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 'd:2026-11-10';
  perform public.t116_ck(ev ->> 'summary' = 'Varaukset 14–21 · 4 varausta', 'E16 aikaisempi varaus leventää alun');
  perform public.t116_ck(position('Havu Paiva Oy' in (ev ->> 'description')) > 0, 'E17 yrityksen nimi');
  perform public.t116_ck(position('Pekka' in (ev ->> 'description')) = 0, 'E18 yhteyshenkilö ei näy');
  perform public.t116_ck(position(rauni_name || ' · yritysvaraus · 6 hlö · #' || o_co::text in (ev ->> 'description')) > 0, 'E19 yritysvarauksen rivi');
  perform public.t116_ck(position('14–15' in (ev ->> 'description')) < position('16–19' in (ev ->> 'description')), 'E20 rivit aikajärjestyksessä');

  update booking.reservations set status = 'cancelled'
   where id in (r_priv, r_co, r_a, r_b);
  d := booking._booking_calendar_desired();
  perform public.t116_ck((select count(*) from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 'd:2026-11-10') = 0, 'E21 tyhjä päivä poistuu');
  perform public.t116_ck((select count(*) from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 'd:2026-11-17') = 1, 'E22 toinen päivä jää');

  update booking.integration_config
     set settings = jsonb_set(settings, '{shared_calendar_id}', to_jsonb(v_closure))
   where key = 'booking_calendar';
  d := booking._booking_calendar_desired();
  perform public.t116_ck((select x ->> 'google_calendar_id' is null from jsonb_array_elements(d -> 'events') x limit 1), 'E23 sulkukalenteri ei ole kohde');
  update booking.integration_config
     set settings = jsonb_set(settings, '{shared_calendar_id}', to_jsonb(cal))
   where key = 'booking_calendar';

  insert into booking.booking_calendar_events(event_key, kind, reservation_id, resource_code, google_calendar_id, google_event_id, content_hash, starts_at, ends_at)
  values
    ('r:' || r_priv::text, 'reservation', r_priv, 'savusauna', cal, 'bkr0099011651', 'old', timestamptz '2026-11-10 16:00:00+02', timestamptz '2026-11-10 19:00:00+02'),
    ('s:savusauna|20261110150000|20261110190000', 'shift', null, 'savusauna', cal, 'bksaaaabbbbccccddddeeee01', 'old', timestamptz '2026-11-10 17:00:00+02', timestamptz '2026-11-10 21:00:00+02');
  plan := booking.booking_calendar_export_plan();
  perform public.t116_ck(plan ->> 'mode' = 'dry_run', 'P1 harjoitusajo');
  perform public.t116_ck((select count(*) from jsonb_array_elements(plan -> 'events') x where x ->> 'kind' <> 'day') = 0, 'P2 suunnitelmassa vain päivät');
  perform public.t116_ck((select count(*) from jsonb_array_elements(plan -> 'mapped') m where m ->> 'event_key' like 'r:%' or m ->> 'event_key' like 's:%') = 2, 'P3 vanhat rivit näkyvät');
  fin := booking.booking_calendar_export_finish(jsonb_build_object('deletes', jsonb_build_array('r:' || r_priv::text, 's:savusauna|20261110150000|20261110190000'), 'upserts', '[]'::jsonb));
  perform public.t116_ck((fin ->> 'deleted')::int = 2 and (select count(*) from booking.booking_calendar_events where event_key like 'r:%' or event_key like 's:%') = 0, 'C1 vanhat rivit poistuvat');
  fin := booking.booking_calendar_export_finish(jsonb_build_object('deletes', jsonb_build_array('r:' || r_priv::text, 's:savusauna|20261110150000|20261110190000'), 'upserts', '[]'::jsonb));
  perform public.t116_ck((fin ->> 'deleted')::int = 0, 'C2 toinen poisto ei tee mitään');

  select x into ev from jsonb_array_elements(booking._booking_calendar_desired() -> 'events') x where x ->> 'event_key' = 'd:2026-11-17';
  fin := booking.booking_calendar_export_finish(jsonb_build_object('upserts', jsonb_build_array(ev), 'deletes', '[]'::jsonb));
  perform public.t116_ck((fin ->> 'upserted')::int = 1, 'C3 päiväpalkki kirjautuu');
  fin := booking.booking_calendar_export_finish(jsonb_build_object('upserts', jsonb_build_array(ev), 'deletes', '[]'::jsonb));
  perform public.t116_ck((fin ->> 'upserted')::int = 1 and (select count(*) from booking.booking_calendar_events where event_key = 'd:2026-11-17') = 1, 'C4 sama palkki ei kahdennu');

  select last_value into seq_cust2 from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.customers', 'id'), '.', 2);
  select last_value into seq_ord2 from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.orders', 'id'), '.', 2);
  select last_value into seq_res2 from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.reservations', 'id'), '.', 2);
  perform public.t116_ck(seq_cust2 is not distinct from seq_cust and seq_ord2 is not distinct from seq_ord and seq_res2 is not distinct from seq_res, 'S0 sekvenssit eivät kuluneet');

  log := current_setting('t116.log', true);
  npass := (length(log) - length(replace(log, 'P ', ''))) / 2;
  nfail := (length(log) - length(replace(log, 'F ', ''))) / 2;
  raise exception 'TESTRESULT pass=% fail=%\n%', npass, nfail, log;
end $t$;
