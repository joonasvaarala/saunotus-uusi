-- t181: saunotusrituaali alkaa vain klo 16.00, 16.30 tai 17.00 (booking_181, migraatio 20261025230602, tuotannossa 20261025230602).
-- A aikasääntö _ritual_addon_starts (vuorot la–su 14.00–17.00 ja tunnin vuorot; kesäajan vaihtopäivä; ei allowed_starts-listaa → vanha sääntö),
-- B lisäpalvelun näytetyt ajat (public_ritual_addon, myös anon), C varaus: vain sallitut ajat (muut ritual_addon_time, koko varaus kumoutuu),
-- D aikaikkuna-trigger + henkilökunnan siirto (rituaali ei voi siirtyä 17.30:een), E paketti kb 7 ja rituaali kb 8 (saatavuus, upsell, varaus),
-- F vartija (vieras md5 → keskeytys, mitään ei muutettu) + rollback (tuotannon md5) + migraatio uudelleen.
-- Ajo (psql, paikallinen PG17 tai testikanta; migraatiot ja fixtures/10_test_helpers.sql ajettu):
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=0 -f t181_ritual_start_times.sql
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=0 -v tz=Europe/Helsinki -f t181_ritual_start_times.sql
-- Testipäivät 2027 (la 6.3., la 13.3., su 28.3. kesäaika); horisontit nostetaan vain tämän transaktion sisällä.
-- Testi ei poista eikä muuta olemassa olevia sulkuja (space_blocks; kalenterisulkuja ei voi poistaa, closure_managed): varauspäivät d1/d2
-- ovat ensimmäinen lauantaipari alkaen la 6.3.2027, jolle ei osu yhtään aktiivista sulkua eikä aktiivista varausta (pg_temp.free_sat).
-- Kaikki yhdessä transaktiossa; lopussa tahallinen poikkeus "TESTRESULT pass=… fail=…" kumoaa kaiken. Ei tuotantoon.
\if :{?tz}
\else
\set tz UTC
\endif
begin;
set local timezone = :'tz';
set local lock_timeout = '3s';
set local statement_timeout = '180s';
create temp table t181_r(ok boolean, label text);
grant all on t181_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t181_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.as_(p_user uuid, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb; d text;
begin
  perform test.login(p_user);
  begin
    execute p_sql into v;
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(nullif(d, ''), sqlstate), 'msg', sqlerrm);
  end;
  perform test.logout();
  return v;
end $$;
create function pg_temp.book(p_rule bigint, p_date date, p_persons int, p_addons jsonb) returns jsonb language sql as $$
  select booking.public_create_booking(p_rule, p_date, p_persons, 'Testi Asiakas', 'asiakas' || nextval('test.seq') || '@t181.example', '0401234567',
                                       false, 'fi', null, 'private', null, p_addons) $$;
create function pg_temp.hel(p_date date, p_hm text) returns timestamptz language sql immutable as $$ select (p_date + p_hm::time) at time zone 'Europe/Helsinki' $$;
create function pg_temp.rit(p_date date, p_hm text) returns jsonb language sql immutable as $$
  select jsonb_build_array(jsonb_build_object('ritual_start', pg_temp.hel(p_date, p_hm), 'quantity', 1)) $$;
-- _ritual_addon_starts(vuoro) HH:MI-listana
create function pg_temp.st(p_date date, p_from text, p_to text) returns text language sql as $$
  select coalesce(string_agg(to_char(t at time zone 'Europe/Helsinki', 'HH24:MI'), ',' order by t), '')
    from booking._ritual_addon_starts(pg_temp.hel(p_date, p_from), pg_temp.hel(p_date, p_to)) t $$;
create function pg_temp.labels(p jsonb) returns text language sql as $$
  select coalesce(string_agg(to_char((x ->> 'starts_at')::timestamptz at time zone 'Europe/Helsinki', 'HH24:MI'), ',' order by (x ->> 'starts_at')::timestamptz), '')
    from jsonb_array_elements(coalesce(p -> 'times', '[]'::jsonb)) x $$;
-- ensimmäinen lauantai p_from:sta (7 pv välein, enintään vuosi), jonka päiville p_from + p_offsets ei osu aktiivista sulkua
-- (space_blocks, myös kalenterisulut) eikä aktiivista varausta ja jonka päivät ovat samassa UTC-poikkeamassa (ei kesäajan vaihdetta välissä);
-- testi ei siis poista mitään, mikä ei ole sen omaa
create function pg_temp.free_sat(p_from date, p_offsets int[]) returns date language sql stable as $$
  select s::date from generate_series(p_from::timestamp, (p_from + 364)::timestamp, interval '7 days') s
   where not exists (select 1 from unnest(p_offsets) o join booking.space_blocks b
                       on b.active and b.during && tstzrange(pg_temp.hel(s::date + o, '00:00'), pg_temp.hel(s::date + o + 1, '00:00')))
     and not exists (select 1 from unnest(p_offsets) o join booking.reservations r
                       on booking._res_active(r.status, r.hold_expires_at)
                      and r.starts_at < pg_temp.hel(s::date + o + 1, '00:00') and r.ends_at > pg_temp.hel(s::date + o, '00:00'))
     and (select count(distinct (s::date + o + time '12:00') - (pg_temp.hel(s::date + o, '12:00') at time zone 'UTC')) from unnest(p_offsets) o) = 1
   order by s limit 1 $$;
grant execute on all functions in schema pg_temp to public;

-- F0: migraatio ajetaan heti alussa (uudelleenajettava: ajettu tai ei)
\ir ../migrations/20261025230602_booking_181_ritual_start_times.sql
select pg_temp.ck(md5(pg_get_functiondef('booking._ritual_addon_starts(timestamptz,timestamptz)'::regprocedure)) = 'acbdc2afdf6412c547067aec78f03414', 'F0: migraatio ajettu (md5 acbdc2af…)');
select pg_temp.ck(not has_function_privilege('anon', 'booking._ritual_addon_starts(timestamptz,timestamptz)', 'execute')
                  and not has_function_privilege('authenticated', 'booking._ritual_addon_starts(timestamptz,timestamptz)', 'execute')
                  and has_function_privilege('service_role', 'booking._ritual_addon_starts(timestamptz,timestamptz)', 'execute'), 'F0b: oikeudet ennallaan (vain service_role)');

update booking.settings set value = '900'::jsonb where key = 'booking_horizon_days';
update booking.settings set value = '900'::jsonb where key = 'public_treatment_horizon_days';
update booking.settings set value = '"pay_later"'::jsonb where key = 'public_payment_mode';

do $t$
declare
  r14 bigint := test.rule('Yleinen vuoro la–su 14:00%'); r1430 bigint := test.rule('Yleinen vuoro la–su 14:30%'); r15 bigint := test.rule('Yleinen vuoro la–su 15:00%');
  r16 bigint := test.rule('Yleinen vuoro la–su 16:00%'); r1630 bigint := test.rule('Yleinen vuoro la–su 16:30%'); r17 bigint := test.rule('Yleinen vuoro la–su 17:00%');
  h14 bigint := test.rule('Tunnin saunavuoro la–su 14:00%'); h18 bigint := test.rule('Tunnin saunavuoro la–su 18:00%');
  d1 date := pg_temp.free_sat('2027-03-06', array[0, 7]); d2 date := d1 + 7; ddst date := '2027-03-28'; dmon date := '2027-03-08';
  u_adm uuid := test.mk_staff('adm@t181.example', 'admin');
  v jsonb; b jsonb; pr booking.reservations; ch booking.reservations; v_txt text; v_n int; hm text; v_code text;
begin
  perform pg_temp.ck(d1 is not null and extract(isodow from d1) = 6, 'P0: varauspäivät ilman sulkuja ja varauksia: ' || coalesce(d1::text, 'ei löytynyt') || ', ' || coalesce(d2::text, ''));
  -- ---------- A aikasääntö ----------
  perform pg_temp.ck(pg_temp.st(d1, '14:00', '16:00') = '16:00', 'A1: 14.00–16.00 → 16.00 (' || pg_temp.st(d1, '14:00', '16:00') || ')');
  perform pg_temp.ck(pg_temp.st(d1, '14:30', '16:30') = '16:00,16:30', 'A2: 14.30–16.30 → 16.00, 16.30 (' || pg_temp.st(d1, '14:30', '16:30') || ')');
  perform pg_temp.ck(pg_temp.st(d1, '15:00', '17:00') = '16:00,16:30,17:00', 'A3: 15.00–17.00 (' || pg_temp.st(d1, '15:00', '17:00') || ')');
  perform pg_temp.ck(pg_temp.st(d1, '16:00', '18:00') = '16:00,16:30,17:00', 'A4: 16.00–18.00 (' || pg_temp.st(d1, '16:00', '18:00') || ')');
  perform pg_temp.ck(pg_temp.st(d1, '16:30', '18:30') = '16:00,16:30,17:00', 'A5: 16.30–18.30 (' || pg_temp.st(d1, '16:30', '18:30') || ')');
  perform pg_temp.ck(pg_temp.st(d1, '17:00', '19:00') = '16:30,17:00', 'A6: 17.00–19.00 → 16.30, 17.00 (' || pg_temp.st(d1, '17:00', '19:00') || ')');
  perform pg_temp.ck(pg_temp.st(d1, '14:00', '15:00') = '' and pg_temp.st(d1, '18:00', '19:00') = '', 'A7: tunnin vuorot 14.00 ja 18.00 → ei aikoja');
  perform pg_temp.ck(pg_temp.st(ddst, '16:00', '18:00') = '16:00,16:30,17:00', 'A8: kesäajan vaihtopäivä (' || pg_temp.st(ddst, '16:00', '18:00') || ')');
  perform pg_temp.ck(pg_temp.st(dmon, '16:00', '19:00') = '16:00,16:30,17:00', 'A9: arkipäivä: weekday-lista (' || pg_temp.st(dmon, '16:00', '19:00') || ')');
  perform pg_temp.ck((select bool_and(test.hel_hm(t) in ('16:00', '16:30', '17:00'))
                        from generate_series(0, 20) i, booking._ritual_addon_starts(pg_temp.hel(d1, '12:00') + i * interval '30 minutes', pg_temp.hel(d1, '13:00') + i * interval '30 minutes') t)
                     is not false, 'A10: mikään vuoro 12.00–22.00 ei tuota muita aikoja');
  update booking.settings set value = value || '{"at_end": false}'::jsonb where key = 'ritual_addon';
  perform pg_temp.ck(pg_temp.st(d1, '14:30', '16:30') = '16:00', 'A11: at_end false → loppuhetki 16.30 pois');
  update booking.settings set value = value || '{"at_end": true}'::jsonb where key = 'ritual_addon';
  update booking.time_window_rules set allowed_starts = null where class = 'ritual' and day_type = 'weekend';
  perform pg_temp.ck(pg_temp.st(d1, '16:00', '18:00') = '15:30,16:00,16:30,17:30,18:00', 'A12: ilman allowed_starts-listaa vanha sääntö (' || pg_temp.st(d1, '16:00', '18:00') || ')');
  update booking.time_window_rules set allowed_starts = array['16:00', '16:30', '17:00']::time[] where class = 'ritual' and day_type = 'weekend';

  -- ---------- B näytetyt ajat ----------
  perform pg_temp.ck(pg_temp.labels(booking.public_ritual_addon(r14, d1, 2)) = '16:00', 'B1: vuoro 14.00 → 16.00 (' || pg_temp.labels(booking.public_ritual_addon(r14, d1, 2)) || ')');
  perform pg_temp.ck(pg_temp.labels(booking.public_ritual_addon(r1430, d1, 2)) = '16:00,16:30', 'B2: vuoro 14.30 (' || pg_temp.labels(booking.public_ritual_addon(r1430, d1, 2)) || ')');
  perform pg_temp.ck(pg_temp.labels(booking.public_ritual_addon(r15, d1, 2)) = '16:00,16:30,17:00', 'B3: vuoro 15.00 (' || pg_temp.labels(booking.public_ritual_addon(r15, d1, 2)) || ')');
  perform pg_temp.ck(pg_temp.labels(booking.public_ritual_addon(r16, d1, 2)) = '16:00,16:30,17:00', 'B4: vuoro 16.00 (' || pg_temp.labels(booking.public_ritual_addon(r16, d1, 2)) || ')');
  perform pg_temp.ck(pg_temp.labels(booking.public_ritual_addon(r1630, d1, 2)) = '16:00,16:30,17:00', 'B5: vuoro 16.30 (' || pg_temp.labels(booking.public_ritual_addon(r1630, d1, 2)) || ')');
  perform pg_temp.ck(pg_temp.labels(booking.public_ritual_addon(r17, d1, 2)) = '16:30,17:00', 'B6: vuoro 17.00 (' || pg_temp.labels(booking.public_ritual_addon(r17, d1, 2)) || ')');
  v := booking.public_ritual_addon(h14, d1, 2);
  perform pg_temp.ck(not (v ->> 'available')::boolean and jsonb_array_length(v -> 'times') = 0, 'B7: tunnin vuoro 14.00 → lisäpalvelu ei näy (' || coalesce(v ->> 'reason', '') || ')');
  v := booking.public_ritual_addon(h18, d1, 2);
  perform pg_temp.ck(not (v ->> 'available')::boolean and jsonb_array_length(v -> 'times') = 0, 'B8: tunnin vuoro 18.00 → lisäpalvelu ei näy');
  perform test.anon();
  v := booking.public_ritual_addon(r16, d1, 2);
  perform test.logout();
  perform pg_temp.ck((v ->> 'available')::boolean and pg_temp.labels(v) = '16:00,16:30,17:00', 'B9: anon: vuoro 16.00 (' || pg_temp.labels(v) || ')');
  perform pg_temp.ck((v -> 'times' -> 0 ->> 'position') = 'start' and (v -> 'times' -> 2 ->> 'position') = 'during', 'B10: positiot (start, during)');

  -- ---------- C varaus ----------
  select count(*) into v_n from booking.reservations;
  foreach hm in array array['15:30', '17:30', '18:00', '16:15'] loop
    b := pg_temp.book(r16, d1, 2, pg_temp.rit(d1, hm));
    perform pg_temp.ck(b ->> 'code' = 'ritual_addon_time', 'C1: vuoro 16.00 + rituaali ' || hm || ' hylätään (' || coalesce(b ->> 'code', 'ok') || ')');
  end loop;
  b := pg_temp.book(r14, d1, 2, pg_temp.rit(d1, '13:30'));
  perform pg_temp.ck(b ->> 'code' = 'ritual_addon_time', 'C2: vuoro 14.00 + rituaali 13.30 hylätään (' || coalesce(b ->> 'code', 'ok') || ')');
  b := pg_temp.book(r17, d1, 2, pg_temp.rit(d1, '19:00'));
  perform pg_temp.ck(b ->> 'code' = 'ritual_addon_time', 'C3: vuoro 17.00 + rituaali 19.00 hylätään (' || coalesce(b ->> 'code', 'ok') || ')');
  b := booking.public_create_booking_code(r16, d1, 2, 'Testi', 'koodi@t181.example', '0401234567', false, 'fi', null, 'private', null, pg_temp.rit(d1, '17:30'), null);
  perform pg_temp.ck(b ->> 'code' = 'ritual_addon_time', 'C4: koodivaraus + 17.30 hylätään (' || coalesce(b ->> 'code', 'ok') || ')');
  perform pg_temp.ck((select count(*) from booking.reservations) = v_n, 'C5: hylätyt eivät jättäneet varauksia');
  foreach hm in array array['16:00', '16:30', '17:00'] loop
    b := pg_temp.book(r16, d1, 2, pg_temp.rit(d1, hm));
    select * into ch from booking.reservations where order_id = (select id from booking.orders where public_token = (b ->> 'token')::uuid) and parent_reservation_id is not null;
    perform pg_temp.ck((b ->> 'ok')::boolean and ch.product_id = 8 and test.hel_hm(ch.starts_at) = hm, 'C6: vuoro 16.00 + rituaali ' || hm || ' ok ' || coalesce(b ->> 'code', ''));
  end loop;
  b := pg_temp.book(r14, d1, 2, pg_temp.rit(d1, '16:00'));
  perform pg_temp.ck((b ->> 'ok')::boolean, 'C7: vuoro 14.00 + rituaali 16.00 (vuoron lopussa) ok ' || coalesce(b ->> 'code', ''));

  -- ---------- D trigger + siirto ----------
  -- ch = vuoro 16.00 + rituaali 17.00 (C6 viimeinen)
  select * into pr from booking.reservations where id = ch.parent_reservation_id;
  v_code := test.code(format('update booking.reservations set starts_at = %L, ends_at = %L where id = %s', pg_temp.hel(d1, '17:30'), pg_temp.hel(d1, '17:50'), ch.id));
  perform pg_temp.ck(v_code = 'ritual_start', 'D1: rituaalin suora siirto 17.30:een estetty (' || v_code || ')');
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, %s, %L, null)', pr.id, r1630, d1));   -- rituaali 17.00 → 17.30
  perform pg_temp.ck(v ->> 'err' = 'ritual_addon_move' and test.hel_hm((select starts_at from booking.reservations where id = ch.id)) = '17:00'
                     and test.hel_hm((select starts_at from booking.reservations where id = pr.id)) = '16:00', 'D2: siirto, jossa rituaali 17.30 → koko siirto kumoutui (' || coalesce(v ->> 'err', 'ok') || ')');
  b := pg_temp.book(r16, d2, 2, pg_temp.rit(d2, '16:00'));
  select * into pr from booking.reservations where order_id = (select id from booking.orders where public_token = (b ->> 'token')::uuid) and parent_reservation_id is null;
  v := pg_temp.as_(u_adm, format('select booking.admin_change_booking(%s, %s, %L, null)', pr.id, r1630, d2));   -- rituaali 16.00 → 16.30
  perform pg_temp.ck(coalesce(v ->> 'err', '') = '' and test.hel_hm((select starts_at from booking.reservations where parent_reservation_id = pr.id)) = '16:30',
                     'D3: siirto, jossa rituaali 16.30 → ok ' || coalesce(v ->> 'msg', ''));

  -- ---------- E paketti kb 7 ja rituaali kb 8 ----------
  select coalesce(string_agg(distinct test.hel_hm(a.starts_at), ','), '') into v_txt from booking._treatment_availability_core(7, d1, d2, 2, false, false) a;
  perform pg_temp.ck(v_txt = '16:00,16:30,17:00', 'E1: paketti kb 7: saatavuus vain 16.00/16.30/17.00 (' || v_txt || ')');
  select coalesce(string_agg(distinct test.hel_hm(a.starts_at), ','), '') into v_txt from booking._treatment_availability_core(8, d1, d2, 1, false, false) a;
  perform pg_temp.ck(v_txt = '16:00,16:30,17:00', 'E2: rituaali kb 8: saatavuus vain 16.00/16.30/17.00 (' || v_txt || ')');
  select coalesce(string_agg(distinct test.hel_hm(u.starts_at), ','), '') into v_txt from booking._upsell_day_slots(7, d2, 2) u;
  perform pg_temp.ck(v_txt <> '' and not exists (select 1 from booking._upsell_day_slots(7, d2, 2) u where test.hel_hm(u.starts_at) not in ('16:00', '16:30', '17:00')),
                     'E3: upsell kb 7 vain sallitut (' || v_txt || ')');
  perform pg_temp.ck(not exists (select 1 from booking._upsell_day_slots(8, d2, 1) u where test.hel_hm(u.starts_at) not in ('16:00', '16:30', '17:00')), 'E4: upsell kb 8 vain sallitut');
  foreach hm in array array['15:30', '17:30', '18:00'] loop
    v_code := test.code(format('select booking._treatment_slot_check(7, %L, 2, false)', pg_temp.hel(d2, hm)));
    perform pg_temp.ck(v_code = 'ritual_start', 'E5: paketti kb 7 ' || hm || ' hylätään (' || v_code || ')');
    v_code := test.code(format('select booking._treatment_slot_check(8, %L, 1, false)', pg_temp.hel(d2, hm)));
    perform pg_temp.ck(v_code = 'ritual_start', 'E6: rituaali kb 8 ' || hm || ' hylätään (' || v_code || ')');
    v_code := test.code(format($q$select booking._create_legs_booking('current', 7, %L, null, 2, null, 'admin', null, null, null, null, false, null, false, null)$q$, pg_temp.hel(d2, hm)));
    perform pg_temp.ck(v_code in ('ritual_start', 'no_pool_for_start'), 'E7: henkilökunnan paketti kb 7 ' || hm || ' estetty (' || v_code || ')');
  end loop;
  v_code := test.code(format('select booking._treatment_slot_check(7, %L, 2, false)', pg_temp.hel(d2, '17:00')));
  perform pg_temp.ck(v_code = 'ok', 'E8: paketti kb 7 17.00 kelpaa (' || v_code || ')');
  v_code := test.code(format($q$select booking._create_legs_booking('current', 7, %L, null, 2, null, 'admin', null, null, null, null, false, null, false, null)$q$, pg_temp.hel(d2, '17:00')));
  perform pg_temp.ck(v_code = 'ok', 'E9: henkilökunnan paketti kb 7 17.00 ok (' || v_code || ')');
end $t$;

-- ---------- F vartija + rollback + migraatio uudelleen ----------
-- vieras funktio / vieras data → migraatio ja rollback keskeytyvät (tulokset talteen \gset, sitten savepoint kumotaan)
savepoint f0;
create or replace function booking._ritual_addon_starts(p_start timestamptz, p_end timestamptz) returns setof timestamptz
  language sql stable security definer set search_path to '' as $$ select p_start $$;
savepoint f1;
\ir ../migrations/20261025230602_booking_181_ritual_start_times.sql
rollback to savepoint f1;
select pg_get_functiondef('booking._ritual_addon_starts(timestamptz,timestamptz)'::regprocedure) like '%select p_start %' as f1ok \gset
savepoint f2;
\ir ../rollbacks/20261025230602_booking_181_ROLLBACK.sql
rollback to savepoint f2;
select pg_get_functiondef('booking._ritual_addon_starts(timestamptz,timestamptz)'::regprocedure) like '%select p_start %' as f2ok \gset
rollback to savepoint f0;
savepoint f3;
update booking.time_window_rules set allowed_starts = array['16:00', '17:00']::time[] where class = 'ritual' and day_type = 'weekend';
\ir ../rollbacks/20261025230602_booking_181_ROLLBACK.sql
savepoint f3b;
\ir ../migrations/20261025230602_booking_181_ritual_start_times.sql
rollback to savepoint f3b;
select md5(pg_get_functiondef('booking._ritual_addon_starts(timestamptz,timestamptz)'::regprocedure)) = '622d94213b88d532b415e9d548785019' as f3ok \gset
rollback to savepoint f0;
select pg_temp.ck(:'f1ok'::boolean, 'F1: vieras _ritual_addon_starts → migraatio keskeytyi, mitään ei muutettu');
select pg_temp.ck(:'f2ok'::boolean, 'F2: vieras _ritual_addon_starts → rollback keskeytyi');
select pg_temp.ck(:'f3ok'::boolean, 'F3: allowed_starts poikkeaa tuotannosta → migraatio keskeytyi');

\ir ../rollbacks/20261025230602_booking_181_ROLLBACK.sql
select pg_temp.ck(md5(pg_get_functiondef('booking._ritual_addon_starts(timestamptz,timestamptz)'::regprocedure)) = '622d94213b88d532b415e9d548785019', 'F4: rollback palautti tuotannon md5:n 622d9421…');
select pg_temp.ck(pg_temp.st('2027-03-06', '16:00', '18:00') = '15:30,16:00,16:30,17:30,18:00', 'F5: rollbackin jälkeen vanha sääntö');
select pg_temp.ck(not has_function_privilege('anon', 'booking._ritual_addon_starts(timestamptz,timestamptz)', 'execute')
                  and has_function_privilege('service_role', 'booking._ritual_addon_starts(timestamptz,timestamptz)', 'execute'), 'F6: oikeudet ennallaan rollbackin jälkeen');
\ir ../rollbacks/20261025230602_booking_181_ROLLBACK.sql
\ir ../migrations/20261025230602_booking_181_ritual_start_times.sql
select pg_temp.ck(md5(pg_get_functiondef('booking._ritual_addon_starts(timestamptz,timestamptz)'::regprocedure)) = 'acbdc2afdf6412c547067aec78f03414'
                  and pg_temp.st('2027-03-06', '16:00', '18:00') = '16:00,16:30,17:00', 'F7: rollback uudelleen + migraatio uudelleen');

select label from t181_r where not ok;
do $$ declare p int; f int; begin
  select count(*) filter (where ok), count(*) filter (where not ok) into p, f from t181_r;
  raise exception 'TESTRESULT pass=% fail=%', p, f;
end $$;
