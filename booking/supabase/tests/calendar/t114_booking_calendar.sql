-- t114: varauskalenterin vienti (booking_114).
-- Aja SAMASSA transaktiossa kuin migraatio, kun booking.skip_cron = on on asetettu ennen migraatiota.
-- Lopuksi tahallinen poikkeus: ei cron-ajoa, ei Googlea, ei pysyvää riviä eikä sekvenssikulutusta.
-- Esimerkki:
--   select set_config('booking.skip_cron','on', true);
--   \i booking/supabase/migrations/20261019161000_booking_114_calendar_export.sql
--   \i booking/supabase/tests/calendar/t114_booking_calendar.sql
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('booking.skip_audit', 'on', true);
select set_config('t114.log', '', true);
create or replace function public.t114_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t114.log', coalesce(current_setting('t114.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create or replace function public.t114_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 180) end;
end $$;
create or replace function public.t114_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text; h text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text, s = returned_sqlstate, h = pg_exception_hint;
  return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 180) end, 'hint', h);
end $$;
create or replace function public.t114_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create or replace function public.t114_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on function public.t114_ck(boolean, text), public.t114_try(text), public.t114_call(text), public.t114_login(uuid), public.t114_logout() to public;

do $t$
declare
  u_mgr uuid := gen_random_uuid();
  u_staff uuid := gen_random_uuid();
  cal text := 'varaukset-t114@group.calendar.google.com';
  cal_savu text := 'savu-t114-cal';
  v_closure text;
  v_base text;
  nq bigint;
  seq_cust bigint; seq_ord bigint; seq_no bigint; seq_res bigint;
  seq_cust2 bigint; seq_ord2 bigint; seq_no2 bigint; seq_res2 bigint;
  c_priv bigint := 99011401; c_co bigint := 99011402; c_sh bigint := 99011403;
  o_priv bigint := 99011431; o_co bigint := 99011432; o_a bigint := 99011433; o_b bigint := 99011434;
  o_hide bigint := 99011435; o_pend bigint := 99011436; o_ns bigint := 99011437; o_far bigint := 99011438;
  o_unpaid bigint := 99011439; o_fail bigint := 99011440; o_anon bigint := 99011441; o_treat bigint := 99011442;
  r_priv bigint := 99011451; r_co bigint := 99011452; r_a bigint := 99011453; r_b bigint := 99011454;
  r_hide bigint := 99011455; r_pend bigint := 99011456; r_ns bigint := 99011457; r_far bigint := 99011458;
  r_unpaid bigint := 99011459; r_fail bigint := 99011460; r_anon bigint := 99011461; r_treat bigint := 99011462;
  t0 timestamptz := timestamptz '2026-12-01 03:17:00+02';
  t1 timestamptz := timestamptz '2026-12-01 06:20:00+02';
  v_shift text;
  d jsonb; ev jsonb; plan jsonb; fin jsonb; bad jsonb;
  log text; npass int; nfail int;
  savu_name text; rauni_name text; treat_name text;
begin
  perform public.t114_ck(coalesce(current_setting('booking.skip_cron', true), '') = 'on', 'C0 skip_cron on');
  perform public.t114_ck(not has_function_privilege('anon', 'booking.admin_get_booking_calendar()', 'execute'), 'G1 anon ei lue');
  perform public.t114_ck(not has_function_privilege('authenticated', 'booking.booking_calendar_export_plan()', 'execute'), 'G2 authenticated ei suunnittele');
  perform public.t114_ck(has_function_privilege('authenticated', 'booking.admin_set_booking_calendar(jsonb)', 'execute'), 'G3 authenticated saa asettaa');
  perform public.t114_ck(not exists (select 1 from cron.job where jobname = 'booking_calendar_export'), 'C1 cron ei ajastettu');

  perform public.t114_ck(booking._calendar_scrub('Maija 0401234567 maija@example.test') = 'Maija', 'S1 nimi siistitään');
  perform public.t114_ck(booking._calendar_scrub('040 123 4567') is null, 'S2 pelkkä puhelin katoaa');
  perform public.t114_ck(booking._calendar_scrub(E'Tilaus #88011401\nHallinta: https://example.test/hallinta/#/varaukset?q=88011401') like '%#88011401%', 'S3 tilausnumero säilyy');
  perform public.t114_ck(position('@' in booking._calendar_scrub(E'Tilaus #88011401\nHallinta: https://example.test/hallinta/#/varaukset?q=88011401')) = 0, 'S4 osoitteessa ei ole sähköpostia');
  perform public.t114_ck(position('0401234567' in booking._calendar_scrub('Tilaus #88011401 0401234567')) = 0, 'S5 puhelin ei syö tilausnumeroa');
  perform public.t114_ck(booking._calendar_scrub('Tilaus #88011401 0401234567') like '%#88011401%', 'S6 numero säilyy puhelimen vieressä');

  select last_value into seq_cust from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.customers', 'id'), '.', 2);
  select last_value into seq_ord from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.orders', 'id'), '.', 2);
  select last_value into seq_no from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.orders', 'order_no'), '.', 2);
  select last_value into seq_res from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.reservations', 'id'), '.', 2);
  select count(*) into nq from net.http_request_queue;
  perform booking.booking_calendar_dispatch();
  perform public.t114_ck((select count(*) from net.http_request_queue) = nq, 'D1 pois-tila ei kutsu verkkoa');

  insert into auth.users(id, email) values (u_mgr, 't114-mgr@example.test'), (u_staff, 't114-staff@example.test');
  insert into booking.staff(user_id, email, name, role) values
    (u_mgr, 't114-mgr@example.test', 't114 manager', 'manager'),
    (u_staff, 't114-staff@example.test', 't114 staff', 'staff');

  perform public.t114_login(u_staff);
  perform public.t114_ck(public.t114_try($$select booking.admin_get_booking_calendar()$$) = 'forbidden', 'P1 työntekijä ei näe');
  perform public.t114_logout();

  select c.google_calendar_id into v_closure from booking.closure_calendars c where c.google_calendar_id is not null order by c.code limit 1;
  perform public.t114_login(u_mgr);
  perform public.t114_ck((booking.admin_get_booking_calendar() ->> 'mode') = 'off', 'A1 oletus pois');
  perform public.t114_ck(coalesce(booking.admin_get_booking_calendar() ->> 'shared_calendar_id', '') = '', 'A2 yhteinen kalenteri tyhjä');
  bad := public.t114_call(format('select booking.admin_set_booking_calendar(%L::jsonb)', jsonb_build_object('api_key', 'ei')::text));
  perform public.t114_ck(bad ->> 'err' = 'secrets_not_allowed', 'A3 salaisuus hylätään');
  bad := public.t114_call(format('select booking.admin_set_booking_calendar(%L::jsonb)', jsonb_build_object('shared_calendar_id', v_closure)::text));
  perform public.t114_ck(bad ->> 'err' = 'closure_calendar', 'A4 sulkukalenteri hylätään');
  bad := public.t114_call(format('select booking.admin_set_booking_calendar(%L::jsonb)', jsonb_build_object('shared_calendar_id', 'on väli')::text));
  perform public.t114_ck(bad ->> 'err' = 'invalid_calendar', 'A5 kelvoton tunnus');
  perform public.t114_ck((booking.admin_get_booking_calendar() ->> 'mode') = 'off', 'A6 hylkäys ei vaihda tilaa');
  perform public.t114_logout();
  plan := booking.booking_calendar_export_plan();
  perform public.t114_ck(plan ->> 'mode' = 'off' and jsonb_array_length(plan -> 'events') = 0, 'P0 pois ei palauta tapahtumia');

  select r.name into savu_name from booking.resources r where r.code = 'savusauna';
  select r.name into rauni_name from booking.resources r where r.code = 'rauni';
  select p.name into treat_name from kb.products p where p.id = 10;

  insert into booking.customers(id, name, email, phone) overriding system value
  values (c_priv, 'Maija 0401234567 maija@example.test', 'maija@example.test', '0401234567');
  insert into booking.customers(id, name, email, phone, company, customer_kind, business_id) overriding system value
  values (c_co, 'Pekka Piilo 0409999999', 'pekka@example.test', '0409999999', 'Havu Testi Zz Oy', 'company', '9999999-2');
  insert into booking.customers(id, name) overriding system value values (c_sh, 'Vuoro Testi');

  insert into booking.orders(id, order_no, customer_id, status, payment_status, total_gross, currency, source_channel, locale, customer_kind)
  overriding system value values
    (o_priv, o_priv, c_priv, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_co, o_co, c_co, 'completed', 'invoiced', 0, 'EUR', 'admin', 'fi', 'company'),
    (o_a, o_a, c_sh, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_b, o_b, c_sh, 'completed', 'unpaid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_hide, o_hide, c_sh, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_pend, o_pend, c_sh, 'completed', 'pending', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_ns, o_ns, c_sh, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_far, o_far, c_sh, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_unpaid, o_unpaid, c_priv, 'completed', 'unpaid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_fail, o_fail, c_sh, 'completed', 'failed', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_anon, o_anon, c_priv, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_treat, o_treat, c_priv, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private');
  update booking.orders set billing = jsonb_build_object('company', 'Havu Testi Zz Oy') where id = o_co;
  update booking.customers set anonymized_at = now() where id = c_priv and id = c_priv;
  -- anonymisointi vain anon-varauksen asiakkaalle tehtäisiin tässä, mutta sama asiakas on myös yksityisvarauksessa.
  -- Palautetaan nimi ja merkitään anonymisointi erillisellä päivityksellä vain kuvauksen testissä funktion haarassa:
  update booking.customers set anonymized_at = null where id = c_priv;

  insert into booking.reservations(id, order_id, product_id, space_id, mode, starts_at, ends_at, persons, status)
  overriding system value values
    (r_priv, o_priv, 25, 1, 'exclusive', timestamptz '2026-12-01 08:00:00+02', timestamptz '2026-12-01 11:00:00+02', 8, 'completed'),
    (r_co, o_co, 25, 12, 'exclusive', timestamptz '2026-12-01 14:00:00+02', timestamptz '2026-12-01 17:00:00+02', 6, 'completed'),
    (r_a, o_a, 1, 1, 'shared', t0, t1, 2, 'completed'),
    (r_b, o_b, 1, 1, 'shared', t0, t1, 3, 'completed'),
    (r_hide, o_hide, 1, 1, 'shared', t0, t1, 9, 'completed'),
    (r_pend, o_pend, 1, 1, 'shared', t0, t1, 4, 'completed'),
    (r_fail, o_fail, 1, 1, 'shared', t0, t1, 4, 'completed'),
    (r_ns, o_ns, 25, 12, 'exclusive', timestamptz '2026-10-16 10:00:00+03', timestamptz '2026-10-16 12:00:00+03', 1, 'no_show'),
    (r_far, o_far, 25, 12, 'exclusive', timestamptz '2027-12-01 10:00:00+02', timestamptz '2027-12-01 12:00:00+02', 1, 'completed'),
    (r_unpaid, o_unpaid, 25, 12, 'exclusive', timestamptz '2026-12-02 18:00:00+02', timestamptz '2026-12-02 21:00:00+02', 1, 'completed'),
    (r_anon, o_anon, 25, 1, 'exclusive', timestamptz '2026-12-03 08:00:00+02', timestamptz '2026-12-03 10:00:00+02', 2, 'completed'),
    (r_treat, o_treat, 10, 1, 'exclusive', timestamptz '2026-12-01 12:00:00+02', timestamptz '2026-12-01 13:30:00+02', 2, 'completed');
  update booking.reservations set hidden_at = now() where id = r_hide;
  update booking.reservations set status = 'cancelled' where id = r_hide;
  insert into booking.reservations(id, order_id, product_id, space_id, mode, starts_at, ends_at, persons, status)
  overriding system value values
    (99011463, o_hide, 1, 1, 'shared', t0, t1, 7, 'cancelled');

  perform public.t114_ck((select count(*) from net.http_request_queue) = nq, 'D2 lisäys ei kutsu verkkoa');
  perform public.t114_ck((select nudge_at is not null from booking.booking_calendar_state where id = 1), 'D3 nudge merkitsee ajan');

  d := booking._booking_calendar_desired();
  v_shift := 's:savusauna|' || to_char(t0 at time zone 'UTC', 'YYYYMMDDHH24MISSUS') || '|' || to_char(t1 at time zone 'UTC', 'YYYYMMDDHH24MISSUS');
  select x into ev from jsonb_array_elements(d -> 'events') x where (x ->> 'event_key') = 'r:' || r_priv::text;
  perform public.t114_ck(ev ->> 'summary' = savu_name || ' – yksityisvaraus, 8 hlö', 'E1 yksityisvarauksen otsikko');
  perform public.t114_ck(position('Maija' in (ev ->> 'description')) > 0, 'E2 nimi jää');
  perform public.t114_ck(position('040' in (ev ->> 'description')) = 0, 'E3 puhelin ei jää');
  perform public.t114_ck(position('@' in (ev ->> 'description')) = 0, 'E4 sähköposti ei jää');
  perform public.t114_ck((ev ->> 'description') like '%#' || o_priv::text || '%', 'E5 tilausnumero');
  perform public.t114_ck((ev ->> 'description') like '%/hallinta/#/varaukset?q=' || o_priv::text || '%', 'E6 hallintalinkki');
  perform public.t114_ck((ev ->> 'google_event_id') = 'bkr' || lpad(r_priv::text, 8, '0'), 'E7 tapahtumatunnus');
  perform public.t114_ck(ev ->> 'google_calendar_id' is null, 'E8 ilman tunnusta ei kohdetta');

  select x into ev from jsonb_array_elements(d -> 'events') x where (x ->> 'event_key') = 'r:' || r_co::text;
  perform public.t114_ck(ev ->> 'summary' = rauni_name || ' – yritysvaraus, 6 hlö', 'E9 yritysvaraus');
  perform public.t114_ck(position('Havu Testi Zz Oy' in (ev ->> 'description')) > 0, 'E10 yrityksen nimi');
  perform public.t114_ck(position('Pekka' in coalesce(ev ->> 'description', '')) = 0, 'E11 yhteyshenkilö ei näy');

  select x into ev from jsonb_array_elements(d -> 'events') x where (x ->> 'event_key') = 'r:' || r_treat::text;
  perform public.t114_ck(ev ->> 'summary' = savu_name || ' – ' || treat_name || ', 2 hlö', 'E12 hoito');

  select x into ev from jsonb_array_elements(d -> 'events') x where (x ->> 'event_key') = v_shift;
  perform public.t114_ck(ev is not null, 'E13 vuoropalkki');
  perform public.t114_ck((ev ->> 'summary') like '%Yleinen vuoro 03:17–06:20 · 5 hlö (2 varausta)%', 'E14 vuoron otsikko');
  perform public.t114_ck(position('Vuoro Testi' in coalesce(ev ->> 'description', '')) = 0, 'E15 vuorossa ei nimiä');
  perform public.t114_ck((ev ->> 'description') like '%#' || o_a::text || '%', 'E16 vuoron tilaukset');
  perform public.t114_ck((ev ->> 'persons')::int = 5, 'E17 henkilömäärä');
  perform public.t114_ck(not exists (select 1 from jsonb_array_elements(d -> 'events') x where (x ->> 'event_key') = 'r:' || r_pend::text), 'E18 kesken oleva maksu pois');
  perform public.t114_ck(not exists (select 1 from jsonb_array_elements(d -> 'events') x where (x ->> 'event_key') = 'r:' || r_fail::text), 'E19 epäonnistunut maksu pois');
  perform public.t114_ck(not exists (select 1 from jsonb_array_elements(d -> 'events') x where (x ->> 'event_key') = 'r:' || r_far::text), 'E20 ikkunan ulkopuolinen pois');
  perform public.t114_ck(exists (select 1 from jsonb_array_elements(d -> 'events') x where (x ->> 'event_key') = 'r:' || r_ns::text), 'E21 no-show ikkunassa');
  perform public.t114_ck(exists (select 1 from jsonb_array_elements(d -> 'events') x where (x ->> 'event_key') = 'r:' || r_unpaid::text), 'E22 maksamaton vahvistettu mukana');

  update booking.customers set anonymized_at = now() where id = c_priv;
  d := booking._booking_calendar_desired();
  select x into ev from jsonb_array_elements(d -> 'events') x where (x ->> 'event_key') = 'r:' || r_anon::text;
  perform public.t114_ck(position('Maija' in coalesce(ev ->> 'description', '')) = 0, 'E23 anonymisoitu nimi pois');
  perform public.t114_ck(position('040' in coalesce(ev ->> 'description', '')) = 0, 'E24 anonymisoidusta ei puhelinta');
  update booking.customers set anonymized_at = null where id = c_priv;

  perform public.t114_login(u_mgr);
  ev := booking.admin_set_booking_calendar(jsonb_build_object(
    'mode', 'dry_run', 'shared_calendar_id', cal,
    'resource_calendars', jsonb_build_object('savusauna', cal_savu),
    'fast_nudge', false));
  perform public.t114_ck(ev ->> 'mode' = 'dry_run', 'A7 harjoitusajo');
  perform public.t114_logout();

  d := booking._booking_calendar_desired();
  select x into ev from jsonb_array_elements(d -> 'events') x where (x ->> 'event_key') = 'r:' || r_priv::text;
  perform public.t114_ck(ev ->> 'google_calendar_id' = cal_savu, 'E25 savusauna omaan kalenteriin');
  select x into ev from jsonb_array_elements(d -> 'events') x where (x ->> 'event_key') = 'r:' || r_co::text;
  perform public.t114_ck(ev ->> 'google_calendar_id' = cal, 'E26 rauni yhteiseen');

  plan := booking.booking_calendar_export_plan();
  perform public.t114_ck(plan ->> 'mode' = 'dry_run' and coalesce(plan ->> 'busy', 'false') = 'false', 'P2 harjoitus ei lukitse');
  perform public.t114_ck(jsonb_array_length(plan -> 'events') > 0, 'P3 tapahtumat mukana');
  select count(*) into nq from net.http_request_queue;
  perform booking.booking_calendar_dispatch();
  perform public.t114_ck((select count(*) from net.http_request_queue) = nq, 'D4 harjoitusajo ei kutsu verkkoa kun skip_cron');

  fin := booking.booking_calendar_export_finish(jsonb_build_object(
    'upserts', jsonb_build_array(jsonb_build_object(
      'event_key', 'r:' || r_priv::text, 'kind', 'reservation', 'reservation_id', r_priv,
      'resource_code', 'savusauna', 'google_calendar_id', cal_savu, 'google_event_id', 'bkr' || lpad(r_priv::text, 8, '0'),
      'content_hash', 'abc', 'starts_at', '2026-12-01T06:00:00Z', 'ends_at', '2026-12-01T09:00:00Z')),
    'deletes', '[]'::jsonb));
  perform public.t114_ck((fin ->> 'upserted')::int = 1, 'M1 kuvaus tallentuu');
  fin := booking.booking_calendar_export_finish(jsonb_build_object(
    'upserts', jsonb_build_array(jsonb_build_object(
      'event_key', 'r:' || r_priv::text, 'kind', 'reservation', 'reservation_id', r_priv,
      'resource_code', 'savusauna', 'google_calendar_id', cal_savu, 'google_event_id', 'bkr' || lpad(r_priv::text, 8, '0'),
      'content_hash', 'def', 'starts_at', '2026-12-01T06:00:00Z', 'ends_at', '2026-12-01T09:00:00Z')),
    'deletes', '[]'::jsonb));
  perform public.t114_ck((select count(*) from booking.booking_calendar_events where event_key = 'r:' || r_priv::text) = 1, 'M2 ei kaksoiskappaletta');
  perform public.t114_ck((select content_hash from booking.booking_calendar_events where event_key = 'r:' || r_priv::text) = 'def', 'M3 päivitys');
  bad := public.t114_call(format('select booking.booking_calendar_export_finish(%L::jsonb)', jsonb_build_object('upserts', jsonb_build_array(jsonb_build_object(
      'event_key', 'r:1', 'kind', 'reservation', 'resource_code', 'savusauna', 'google_calendar_id', v_closure,
      'google_event_id', 'bkr00000001', 'content_hash', 'x', 'starts_at', '2026-12-01T06:00:00Z', 'ends_at', '2026-12-01T09:00:00Z')))::text));
  perform public.t114_ck(bad ->> 'err' = 'closure_calendar', 'M4 sulkukalenteriin ei kirjoiteta');
  fin := booking.booking_calendar_export_finish(jsonb_build_object('upserts', '[]'::jsonb, 'deletes', jsonb_build_array('r:' || r_priv::text)));
  perform public.t114_ck((select count(*) from booking.booking_calendar_events where event_key = 'r:' || r_priv::text) = 0, 'M5 poisto');

  update booking.reservations set status = 'cancelled' where id = r_a;
  d := booking._booking_calendar_desired();
  select x into ev from jsonb_array_elements(d -> 'events') x where (x ->> 'event_key') = v_shift;
  perform public.t114_ck((ev ->> 'summary') like '%3 hlö (1 varaus)%', 'E27 yksi varaus päivittää palkin');
  update booking.reservations set status = 'cancelled' where id = r_b;
  d := booking._booking_calendar_desired();
  perform public.t114_ck(not exists (select 1 from jsonb_array_elements(d -> 'events') x where (x ->> 'event_key') = v_shift), 'E28 viimeinen peruutus poistaa palkin');

  perform public.t114_login(u_mgr);
  perform booking.admin_set_booking_calendar(jsonb_build_object('mode', 'live', 'fast_nudge', false));
  bad := booking.admin_booking_calendar_preview();
  perform public.t114_ck(bad ->> 'sent' = 'false', 'A8 esikatselu ei lähetä');
  perform public.t114_logout();
  perform public.t114_login(u_mgr);
  perform public.t114_ck(public.t114_try($$select booking.booking_calendar_export_plan()$$) like '42501%', 'P4 kirjautunut ei saa suunnitelmaa');
  perform public.t114_logout();
  plan := booking.booking_calendar_export_plan();
  perform public.t114_ck(plan ->> 'mode' = 'live' and plan ->> 'busy' = 'false' and plan ->> 'run_id' is not null, 'P5 live lukitsee');
  bad := booking.booking_calendar_export_plan();
  perform public.t114_ck(bad ->> 'busy' = 'true', 'P6 toinen ajo odottaa');
  perform booking.booking_calendar_export_finish(jsonb_build_object('run_id', plan ->> 'run_id', 'upserts', '[]'::jsonb, 'deletes', '[]'::jsonb, 'stats', jsonb_build_object('dry_run', false)));
  perform public.t114_ck((select locked_at is null from booking.booking_calendar_state where id = 1), 'P7 lukko vapautuu');
  select count(*) into nq from net.http_request_queue;
  perform booking.booking_calendar_dispatch();
  perform public.t114_ck((select count(*) from net.http_request_queue) = nq, 'D5 live ei kutsu verkkoa kun skip_cron');

  select last_value into seq_cust2 from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.customers', 'id'), '.', 2);
  select last_value into seq_ord2 from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.orders', 'id'), '.', 2);
  select last_value into seq_no2 from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.orders', 'order_no'), '.', 2);
  select last_value into seq_res2 from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.reservations', 'id'), '.', 2);
  perform public.t114_ck(seq_cust2 = seq_cust and seq_ord2 = seq_ord and seq_no2 = seq_no and seq_res2 = seq_res, 'N0 sekvenssit eivät kuluneet');

  v_base := booking._booking_calendar_admin_base((select settings from booking.integration_config where key = 'booking_calendar'));
  perform public.t114_ck(v_base like '%/hallinta', 'A9 hallinnan oletusosoite');

  log := current_setting('t114.log', true);
  npass := (length(log) - length(replace(log, 'P ', ''))) / 2;
  nfail := (length(log) - length(replace(log, 'F ', ''))) / 2;
  raise exception 'TESTRESULT pass=% fail=%\n%', npass, nfail, log;
end $t$;
