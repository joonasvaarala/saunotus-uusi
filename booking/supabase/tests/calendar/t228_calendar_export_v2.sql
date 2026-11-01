-- t228: varauskalenterin vienti v2 (booking_228).
-- Aja SAMASSA transaktiossa kuin migraatio, kun booking.skip_cron = on.
-- Lopuksi tahallinen poikkeus: ei Googlea, ei pysyvää riviä.
--   select set_config('booking.skip_cron','on', true);
--   \i booking/supabase/migrations/20261101193000_booking_228_calendar_export_v2.sql
--   \i booking/supabase/tests/calendar/t228_calendar_export_v2.sql
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('booking.skip_audit', 'on', true);
select set_config('t228.log', '', true);
create or replace function public.t228_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t228.log', coalesce(current_setting('t228.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;
create or replace function public.t228_try(p_sql text) returns text language plpgsql as $$
declare d text; m text; s text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text; s := sqlstate; return case when s = 'BK001' then d else s || ':' || left(m, 180) end;
end $$;
create or replace function public.t228_call(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb; d text; m text; s text; h text;
begin execute 'select (' || p_sql || ')' into r; return r;
exception when others then get stacked diagnostics d = pg_exception_detail, m = message_text, s = returned_sqlstate, h = pg_exception_hint;
  return jsonb_build_object('err', case when s = 'BK001' then d else s || ':' || left(m, 180) end, 'hint', h);
end $$;
create or replace function public.t228_login(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $$;
create or replace function public.t228_logout() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $$;
grant execute on function public.t228_ck(boolean, text), public.t228_try(text), public.t228_call(text), public.t228_login(uuid), public.t228_logout() to public;

do $t$
declare
  u_mgr uuid := gen_random_uuid();
  cal text := 'varaukset-t228@group.calendar.google.com';
  cal_savu text := 'savu-t228-calendar';
  cal_rauni text := 'rauni-t228-calendar';
  cal_lovi text := 'lovi-t228-calendar';
  v_closure text; v_shift text;
  c1 bigint := 99022801; c2 bigint := 99022802;
  o_wd bigint := 99022811; o_tu bigint := 99022812; o_tu2 bigint := 99022813;
  o_we bigint := 99022814; o_we2 bigint := 99022815; o_priv bigint := 99022816; o_tr bigint := 99022817;
  o_ev bigint := 99022818; o_rit bigint := 99022819;
  r_wd bigint := 99022831; r_tu bigint := 99022832; r_tu2 bigint := 99022833;
  r_we bigint := 99022834; r_we2 bigint := 99022835; r_priv bigint := 99022836; r_tr bigint := 99022837;
  r_ev bigint := 99022838; r_rit bigint := 99022839; leg bigint := 99022871;
  rule_ev bigint := 99022881;
  savu bigint; rauni bigint; ei bigint; rit_pool bigint;
  p_tue bigint[]; p_turve bigint[]; p_thu bigint[]; p_1500 bigint[]; p_1700 bigint[];
  tue_name text; turve_name text; yle_name text; savu_name text; rauni_name text; treat_name text; ev_name text;
  d jsonb; ev jsonb; plan jsonb; fin jsonb; bad jsonb; resources jsonb;
  seq_cust bigint; seq_ord bigint; seq_res bigint;
  seq_cust2 bigint; seq_ord2 bigint; seq_res2 bigint;
  log text; npass int; nfail int;
  day_empty boolean;
begin
  perform public.t228_ck(coalesce(current_setting('booking.skip_cron', true), '') = 'on', 'C0 skip_cron on');
  perform public.t228_ck((select mode from booking.integration_config where key = 'booking_calendar') = 'off', 'C1 vienti pysyy pois ennen testiä');
  select id into savu from booking.resources where code = 'savusauna';
  select id into rauni from booking.resources where code = 'rauni';
  select id into ei from booking.resources where code = 'ei_resurssia';
  select id into rit_pool from booking.resources where code = 'rauni_rituaali';
  select r.name into savu_name from booking.resources r where r.code = 'savusauna';
  select r.name into rauni_name from booking.resources r where r.code = 'rauni';
  select p.name into treat_name from kb.products p where p.id = 10;
  select p.name into ev_name from kb.products p where p.id = 113;
  select c.google_calendar_id into v_closure from booking.closure_calendars c where c.google_calendar_id is not null order by c.code limit 1;
  select s.google_calendar_id into v_shift from public.calendar_sources s where s.google_calendar_id is not null order by s.role_type limit 1;
  perform public.t228_ck(v_closure is not null, 'C2 sulkukalenteri löytyy');
  perform public.t228_ck(v_shift is not null, 'C3 vuorokalenteri löytyy');
  perform public.t228_ck(booking._calendar_id_ok(v_shift), 'C4 vuorokalenterin tunnus on muodoltaan kelvollinen');

  select not exists (
    select 1 from booking.reservations r
     where r.hidden_at is null
       and (r.starts_at at time zone 'Europe/Helsinki')::date in (date '2027-01-05', date '2027-01-07', date '2027-01-09', date '2027-01-17')
  ) into day_empty;
  perform public.t228_ck(day_empty, 'C5 testipäivät ovat tyhjiä');
  perform public.t228_ck(exists (
    select 1 from booking.schedule_rules sr
     where sr.active and sr.mode = 'shared' and coalesce(sr.kind, 'regular') = 'regular'
       and sr.start_time = time '14:00' and 6 = any (sr.weekdays)), 'C6 lauantain 14:00 vuoro on olemassa');

  select array_agg(srp.pool_id) into p_tue
    from booking.schedule_rules sr
    join booking.schedule_rule_pools srp on srp.rule_id = sr.id
    join kb.products p on p.id = sr.product_id
   where sr.active and coalesce(sr.kind, 'regular') = 'regular' and sr.mode = 'shared'
     and sr.space_id = savu and sr.start_time = time '16:00' and 2 = any (sr.weekdays);
  select p.name into tue_name
    from booking.schedule_rules sr join kb.products p on p.id = sr.product_id
   where sr.active and coalesce(sr.kind, 'regular') = 'regular' and sr.mode = 'shared'
     and sr.space_id = savu and sr.start_time = time '16:00' and 2 = any (sr.weekdays)
   order by sr.id limit 1;
  select array_agg(srp.pool_id), min(p.name) into p_turve, turve_name
    from booking.schedule_rules sr
    join booking.schedule_rule_pools srp on srp.rule_id = sr.id
    join kb.products p on p.id = sr.product_id
    join booking.resources pool on pool.id = srp.pool_id
   where sr.active and coalesce(sr.kind, 'regular') = 'regular' and sr.mode = 'shared'
     and sr.space_id = savu and sr.start_time = time '16:00' and 4 = any (sr.weekdays)
     and pool.code = 'turve';
  select array_agg(srp.pool_id) into p_thu
    from booking.schedule_rules sr
    join booking.schedule_rule_pools srp on srp.rule_id = sr.id
   where sr.active and coalesce(sr.kind, 'regular') = 'regular' and sr.mode = 'shared'
     and sr.product_id = 1 and sr.space_id = savu and sr.start_time = time '17:00' and 4 = any (sr.weekdays);
  select p.name into yle_name from kb.products p where p.id = 1;
  select array_agg(srp.pool_id) into p_1500
    from booking.schedule_rules sr join booking.schedule_rule_pools srp on srp.rule_id = sr.id
   where sr.active and coalesce(sr.kind, 'regular') = 'regular' and sr.mode = 'shared'
     and sr.product_id = 1 and sr.space_id = savu and sr.start_time = time '15:00' and 6 = any (sr.weekdays);
  select array_agg(srp.pool_id) into p_1700
    from booking.schedule_rules sr join booking.schedule_rule_pools srp on srp.rule_id = sr.id
   where sr.active and coalesce(sr.kind, 'regular') = 'regular' and sr.mode = 'shared'
     and sr.product_id = 1 and sr.space_id = savu and sr.start_time = time '17:00' and 6 = any (sr.weekdays);
  perform public.t228_ck(tue_name is not null and turve_name is not null and p_1500 is not null and p_1700 is not null, 'C7 vuorosäännöt löytyvät');

  insert into auth.users(id, email) values (u_mgr, 't228-mgr@example.test');
  insert into booking.staff(user_id, email, name, role) values (u_mgr, 't228-mgr@example.test', 't228 manager', 'manager');
  perform public.t228_login(u_mgr);
  resources := booking.admin_get_booking_calendar() -> 'resources';
  perform public.t228_ck((select count(*) from jsonb_array_elements(resources) x where x ->> 'code' in ('savusauna', 'rauni', 'lovi')) = 3, 'U1 kolme resurssikalenteria');
  bad := public.t228_call(format('select booking.admin_set_booking_calendar(%L::jsonb)', jsonb_build_object('shared_calendar_id', v_closure)::text));
  perform public.t228_ck(bad ->> 'err' = 'closure_calendar', 'G1 sulkukalenteri hylätään');
  bad := public.t228_call(format('select booking.admin_set_booking_calendar(%L::jsonb)', jsonb_build_object('shared_calendar_id', v_shift)::text));
  perform public.t228_ck(bad ->> 'err' = 'shift_calendar', 'G2 vuorokalenteri hylätään jaetusta');
  bad := public.t228_call(format('select booking.admin_set_booking_calendar(%L::jsonb)', jsonb_build_object('resource_calendars', jsonb_build_object('savusauna', v_shift))::text));
  perform public.t228_ck(bad ->> 'err' = 'shift_calendar', 'G3 vuorokalenteri hylätään resurssista');
  perform public.t228_ck((booking.admin_get_booking_calendar() ->> 'mode') = 'off', 'G4 hylkäys ei käynnistä vientiä');
  perform booking.admin_set_booking_calendar(jsonb_build_object(
    'mode', 'dry_run', 'fast_nudge', false, 'shared_calendar_id', cal,
    'resource_calendars', jsonb_build_object('savusauna', cal_savu, 'rauni', cal_rauni, 'lovi', cal_lovi)));
  perform public.t228_logout();

  select last_value into seq_cust from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.customers', 'id'), '.', 2);
  select last_value into seq_ord from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.orders', 'id'), '.', 2);
  select last_value into seq_res from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.reservations', 'id'), '.', 2);

  insert into booking.customers(id, name, email, phone) overriding system value values
    (c1, 'Maija 0401234567 maija@example.test', 't228-maija@example.test', '0401234567'),
    (c2, 'Vuoro Testi', 't228-vuoro@example.test', '0407654321');
  insert into booking.orders(id, order_no, customer_id, status, payment_status, total_gross, currency, source_channel, locale, customer_kind)
  overriding system value values
    (o_wd, o_wd, c2, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_tu, o_tu, c2, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_tu2, o_tu2, c2, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_we, o_we, c2, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_we2, o_we2, c2, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_priv, o_priv, c1, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_tr, o_tr, c1, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_ev, o_ev, c2, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private'),
    (o_rit, o_rit, c2, 'completed', 'paid', 0, 'EUR', 'admin', 'fi', 'private');

  insert into booking.schedule_rules(id, product_id, label, mode, space_id, weekdays, start_time, duration_minutes, valid_from, valid_to, kind, active)
  overriding system value values
    (rule_ev, 113, 'Testi joulusauna', 'shared', ei, array[extract(isodow from date '2027-01-09')::smallint], time '12:00', 120, date '2027-01-09', date '2027-01-09', 'event', true);

  insert into booking.reservations(id, order_id, product_id, space_id, mode, starts_at, ends_at, persons, status, pool_ids, claim_offset_min, rule_id)
  overriding system value values
    (r_wd, o_wd, 1, savu, 'shared', timestamptz '2027-01-05 16:00:00+02', timestamptz '2027-01-05 16:30:00+02', 2, 'confirmed', p_tue, 0, null),
    (r_tu, o_tu, 5, savu, 'shared', timestamptz '2027-01-07 16:00:00+02', timestamptz '2027-01-07 19:00:00+02', 2, 'confirmed', p_turve, 0, null),
    (r_tu2, o_tu2, 1, savu, 'shared', timestamptz '2027-01-07 17:00:00+02', timestamptz '2027-01-07 17:30:00+02', 1, 'confirmed', p_thu, 0, null),
    (r_we, o_we, 1, savu, 'shared', timestamptz '2027-01-09 15:00:00+02', timestamptz '2027-01-09 15:30:00+02', 2, 'confirmed', p_1500, 0, null),
    (r_we2, o_we2, 1, savu, 'shared', timestamptz '2027-01-09 17:00:00+02', timestamptz '2027-01-09 17:30:00+02', 3, 'confirmed', p_1700, 0, null),
    (r_priv, o_priv, 25, savu, 'exclusive', timestamptz '2027-01-09 13:00:00+02', timestamptz '2027-01-09 15:00:00+02', 4, 'confirmed', '{}'::bigint[], 0, null),
    (r_tr, o_tr, 10, rauni, 'exclusive', timestamptz '2027-01-09 11:00:00+02', timestamptz '2027-01-09 12:30:00+02', 1, 'confirmed', '{}'::bigint[], 0, null),
    (r_ev, o_ev, 113, ei, 'shared', timestamptz '2027-01-09 12:00:00+02', timestamptz '2027-01-09 12:30:00+02', 4, 'confirmed', '{}'::bigint[], 0, rule_ev),
    (r_rit, o_rit, 7, savu, 'shared', timestamptz '2027-01-17 16:00:00+02', timestamptz '2027-01-17 16:30:00+02', 2, 'confirmed', '{}'::bigint[], 30, null);
  insert into booking.reservation_legs(id, reservation_id, resource_id, role, mode, starts_at, ends_at, persons, offset_min, minutes, pool_ids)
  overriding system value values
    (leg, r_rit, rauni, 'space', 'shared', timestamptz '2027-01-17 16:00:00+02', timestamptz '2027-01-17 16:20:00+02', 2, 0, 20,
     case when rit_pool is null then '{}'::bigint[] else array[rit_pool] end);

  d := booking._booking_calendar_desired();
  perform public.t228_ck((select count(*) from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' like 'd:%') = 0, 'D0 ei vanhaa päiväpalkkia');

  select x into ev from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 'w:2027-01-09';
  perform public.t228_ck(ev ->> 'kind' = 'weekend', 'W1 viikonloppu on yksi palkki');
  perform public.t228_ck(ev ->> 'summary' = 'Yleiset vuorot 15–19 · 5 hlö (2 varausta)', 'W2 palkki 15–19 kun 14:00 on tyhjä');
  perform public.t228_ck((ev ->> 'starts_at')::timestamptz = timestamptz '2027-01-09 15:00:00+02', 'W3 alku on 15');
  perform public.t228_ck((ev ->> 'ends_at')::timestamptz = timestamptz '2027-01-09 19:00:00+02', 'W4 loppu on 19 eikä Johkun 15:30');
  perform public.t228_ck(ev ->> 'google_calendar_id' = cal_savu, 'W5 palkki Savusaunan kalenterissa');
  perform public.t228_ck(ev ->> 'google_event_id' = 'bkw20270109', 'W6 tunniste');
  perform public.t228_ck(position('Maija' in coalesce(ev ->> 'description', '')) = 0 and position('040' in coalesce(ev ->> 'description', '')) = 0 and position('@' in coalesce(ev ->> 'description', '')) = 0, 'W7 palkissa ei yhteystietoja');
  perform public.t228_ck(position('12–14' in coalesce(ev ->> 'description', '')) = 0 and position('13–15' in coalesce(ev ->> 'summary', '')) = 0, 'W8 tapahtuma ja yksityinen eivät levitä palkkia');

  select x into ev from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 's:yleinen_arki:2027-01-05T16:00';
  perform public.t228_ck(ev ->> 'kind' = 'shift', 'A1 arki on koko vuoro');
  perform public.t228_ck(ev ->> 'summary' = tue_name || ' 16–19 · 2 hlö (1 varaus)', 'A2 otsikko säännön nimellä');
  perform public.t228_ck((ev ->> 'ends_at')::timestamptz = timestamptz '2027-01-05 19:00:00+02', 'J1 Johkun 30 min ei ole loppu');
  perform public.t228_ck((select ends_at from booking.reservations where id = r_wd) = timestamptz '2027-01-05 16:30:00+02', 'J2 rivin ends_at on yhä 30 min');
  perform public.t228_ck(ev ->> 'google_calendar_id' = cal_savu and ev ->> 'google_event_id' ~ '^[a-v0-9]+$', 'A3 tunnus ja kalenteri');

  select x into ev from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 's:turve:2027-01-07T16:00';
  perform public.t228_ck(ev ->> 'summary' = turve_name || ' 16–17 · 2 hlö (1 varaus)', 'T1 turvetorstai on 16–17');
  perform public.t228_ck((ev ->> 'ends_at')::timestamptz = timestamptz '2027-01-07 17:00:00+02', 'T2 turve loppuu ennen yleistä vuoroa');
  select x into ev from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 's:yleinen_arki:2027-01-07T17:00';
  perform public.t228_ck(ev ->> 'summary' = yle_name || ' 17–19 · 1 hlö (1 varaus)', 'T3 torstain yleinen vuoro on erillään');
  perform public.t228_ck((ev ->> 'ends_at')::timestamptz = timestamptz '2027-01-07 19:00:00+02', 'T4 yleisen vuoron loppu tulee säännöstä');
  perform public.t228_ck((select count(*) from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' like 's:%2027-01-07%') = 2, 'T5 kaksi erillistä tapahtumaa');

  select x into ev from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 'l:rauni:2027-01-17T16:00';
  perform public.t228_ck(ev ->> 'kind' = 'ritual' and (ev ->> 'persons')::int = 2, 'R1 20 min rituaali');
  perform public.t228_ck((ev ->> 'starts_at')::timestamptz = timestamptz '2027-01-17 16:00:00+02' and (ev ->> 'ends_at')::timestamptz = timestamptz '2027-01-17 16:20:00+02', 'R2 kesto on 20 min');
  perform public.t228_ck(ev ->> 'google_calendar_id' = cal_rauni and ev ->> 'summary' like 'Saunotusrituaali 16–16:20%', 'R3 Raunin kalenteri');
  perform public.t228_ck(position('040' in coalesce(ev ->> 'description', '')) = 0 and position('@' in coalesce(ev ->> 'description', '')) = 0, 'R4 rituaalissa ei yhteystietoja');
  select x into ev from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 'w:2027-01-17';
  perform public.t228_ck(ev ->> 'summary' = 'Yleiset vuorot 16:30–18 · 2 hlö (1 varaus)', 'R5 kb 7:n savusaunaosa on palkissa');
  perform public.t228_ck((ev ->> 'starts_at')::timestamptz = timestamptz '2027-01-17 16:30:00+02', 'R6 palkki ei ala rituaalista');
  perform public.t228_ck((select count(*) from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 'r:' || r_rit::text) = 0, 'R7 paketti ei ole yksityinen tapahtuma');

  select x into ev from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 'e:' || rule_ev::text || ':2027-01-09';
  perform public.t228_ck(ev ->> 'kind' = 'event', 'E1 tapahtumakerta');
  perform public.t228_ck(ev ->> 'google_calendar_id' = cal_savu, 'E2 ei_resurssia menee Savusaunaan');
  perform public.t228_ck(ev ->> 'google_calendar_id' is distinct from cal_rauni, 'E3 ei Raunin kalenteriin');
  perform public.t228_ck((ev ->> 'starts_at')::timestamptz = timestamptz '2027-01-09 12:00:00+02' and (ev ->> 'ends_at')::timestamptz = timestamptz '2027-01-09 14:00:00+02', 'E4 aika tulee kerrasta eikä 30 min rivistä');
  perform public.t228_ck((ev ->> 'persons')::int = 4 and ev ->> 'summary' = ev_name || ' 12–14 · 4 hlö (1 varaus)', 'E5 osallistujat');
  perform public.t228_ck((select space_id from booking.reservations where id = r_ev) = ei, 'E6 varaus on yhä ei_resurssia');

  select x into ev from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 'r:' || r_priv::text;
  perform public.t228_ck(ev ->> 'summary' = savu_name || ' – yksityisvaraus, 4 hlö', 'P1 yksityisvaraus');
  perform public.t228_ck(ev ->> 'google_calendar_id' = cal_savu and ev ->> 'google_event_id' = 'bkr' || lpad(r_priv::text, 8, '0'), 'P2 yksityisen tunnus');
  perform public.t228_ck(position('Maija' in (ev ->> 'description')) > 0 and position('040' in (ev ->> 'description')) = 0 and position('@' in (ev ->> 'description')) = 0, 'P3 nimi jää, puhelin ja sähköposti eivät');
  select x into ev from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 'r:' || r_tr::text;
  perform public.t228_ck(ev ->> 'summary' = rauni_name || ' – ' || treat_name || ', 1 hlö' and ev ->> 'google_calendar_id' = cal_rauni, 'P4 hoito Raunin kalenterissa');

  plan := booking.booking_calendar_export_plan();
  perform public.t228_ck(plan ->> 'mode' = 'dry_run', 'S1 harjoitusajo');
  perform public.t228_ck(plan -> 'shift_calendar_ids' ? v_shift, 'S2 suunnitelma palauttaa vuorokalenterit');
  perform public.t228_ck(plan -> 'closure_calendar_ids' ? v_closure, 'S3 suunnitelma palauttaa sulkukalenterit');
  perform public.t228_ck((select count(*) from jsonb_array_elements(plan -> 'events') x where x ->> 'event_key' like 'd:%') = 0, 'S4 suunnitelmassa ei päiväpalkkia');

  insert into booking.booking_calendar_events(event_key, kind, reservation_id, resource_code, google_calendar_id, google_event_id, content_hash, starts_at, ends_at)
  values ('d:2027-01-09', 'day', null, 'all', cal, 'bkd20270109', 'old', timestamptz '2027-01-09 14:00:00+02', timestamptz '2027-01-09 19:00:00+02');
  fin := booking.booking_calendar_export_finish(jsonb_build_object('deletes', jsonb_build_array('d:2027-01-09'), 'upserts', '[]'::jsonb));
  perform public.t228_ck((fin ->> 'deleted')::int = 1, 'S5 vanha päiväpalkki poistuu');

  select x into ev from jsonb_array_elements(booking._booking_calendar_desired() -> 'events') x where x ->> 'event_key' = 'w:2027-01-09';
  fin := booking.booking_calendar_export_finish(jsonb_build_object('upserts', jsonb_build_array(ev), 'deletes', '[]'::jsonb));
  perform public.t228_ck((fin ->> 'upserted')::int = 1, 'S6 viikonlopun palkki kirjautuu');
  bad := public.t228_call(format('select booking.booking_calendar_export_finish(%L::jsonb)', jsonb_build_object('upserts', jsonb_build_array(jsonb_build_object(
    'event_key', 'w:2027-01-09', 'kind', 'weekend', 'resource_code', 'savusauna',
    'google_calendar_id', v_shift, 'google_event_id', 'bkw20270109', 'content_hash', 'x',
    'starts_at', '2027-01-09 15:00:00+02', 'ends_at', '2027-01-09 19:00:00+02')))::text));
  perform public.t228_ck(bad ->> 'err' = 'shift_calendar', 'S7 viimeistely ei kirjoita vuorokalenteriin');

  update booking.integration_config
     set settings = jsonb_set(settings, '{resource_calendars,savusauna}', to_jsonb(v_shift))
   where key = 'booking_calendar';
  d := booking._booking_calendar_desired();
  perform public.t228_ck((select x ->> 'google_calendar_id' is null from jsonb_array_elements(d -> 'events') x where x ->> 'event_key' = 'w:2027-01-09'), 'S8 vuorokalenteri ei jää kohteeksi');

  select last_value into seq_cust2 from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.customers', 'id'), '.', 2);
  select last_value into seq_ord2 from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.orders', 'id'), '.', 2);
  select last_value into seq_res2 from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.reservations', 'id'), '.', 2);
  perform public.t228_ck(seq_cust2 is not distinct from seq_cust and seq_ord2 is not distinct from seq_ord and seq_res2 is not distinct from seq_res, 'S0 sekvenssit eivät kuluneet');

  log := current_setting('t228.log', true);
  npass := (length(log) - length(replace(log, 'P ', ''))) / 2;
  nfail := (length(log) - length(replace(log, 'F ', ''))) / 2;
  raise exception 'TESTRESULT pass=% fail=%\n%', npass, nfail, log;
end $t$;
