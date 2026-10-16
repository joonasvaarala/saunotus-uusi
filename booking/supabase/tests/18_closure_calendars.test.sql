-- booking_18 (sulkukalenterit): rekisteri + luokittelusäännöt, apply_closure_events (idempotenssi, muutos, poisto, massapoistosuoja, dry-run, ikkuna), ohitus (admin_set_closure_override),
-- hallinta-esto (closure_managed), validaattorit lukevat kalenterisulut, konfliktit, Laura-resurssi ja sen legit. Pohjana Bottiavustuksen booking_18_tests_DRAFT.sql (tulokset pgTAP-riveinä; kaikki kumotaan).
-- Dataa ei kosketa muuten kuin transaktion sisällä: saunottajafunktiot korvataan kuvitteellisilla vain tässä transaktiossa. Tulevat päivät 2027.
begin;
set local search_path = extensions, booking, public;
select no_plan();
set local lock_timeout = '5s';
select test.mk_staff('admin18@example.com', 'admin') as adm18 \gset
select set_config('t18.adm', :'adm18', false);
create temp table _res(n serial, kind text, ok boolean, msg text, ms numeric);
create function pg_temp.cust() returns bigint language sql as $$ select id from booking.customers where name = 'Kuivaajo-testiasiakas (rollback)' $$;
insert into booking.customers(name) values ('Kuivaajo-testiasiakas (rollback)');
set local jit = off;
-- ---------- testien apufunktiot (pehmeä epäonnistuminen: kirjaa tuloksen _res-tauluun, ei keskeytä) ----------
create function pg_temp.t_ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin insert into pg_temp._res(kind, ok, msg) values ('T', p_cond is true, p_msg); end $$;
create function pg_temp.t_err(p_sql text, p_code text, p_msg text) returns void language plpgsql as $$
declare v_code text; v_state text;
begin
  begin
    execute p_sql;
  exception
    when sqlstate 'BK001' then get stacked diagnostics v_code = pg_exception_detail;
    when exclusion_violation then v_code := 'exclude';
    when others then v_code := 'SQLSTATE ' || sqlstate || ': ' || sqlerrm;
  end;
  insert into pg_temp._res(kind, ok, msg) values ('T', v_code is not distinct from p_code, p_msg || case when v_code is distinct from p_code then ' (odotettu ' || p_code || ', saatu ' || coalesce(v_code, 'ei virhettä') || ')' else ' [' || p_code || ']' end);
end $$;
create function pg_temp.ts(p text) returns timestamptz language sql as $$ select (p::timestamp) at time zone 'Europe/Helsinki' $$;
create function pg_temp.rid(p_code text) returns bigint language sql as $$ select id from booking.resources where code = p_code $$;
create function pg_temp.mk(p_space text, p_mode text, p_start text, p_end text, p_persons int, p_pools text[] default '{}', p_status text default 'confirmed', p_product bigint default 1) returns bigint language plpgsql as $$
declare v_o bigint; v_r bigint;
begin
  insert into booking.orders(status, total_gross) values ('confirmed', 0) returning id into v_o;
  insert into booking.reservations(order_id, product_id, space_id, mode, starts_at, ends_at, persons, pool_ids, status)
  values (v_o, p_product, pg_temp.rid(p_space), p_mode, pg_temp.ts(p_start), pg_temp.ts(p_end), p_persons,
          coalesce((select array_agg(id) from booking.resources where code = any (p_pools)), '{}'), p_status) returning id into v_r;
  return v_r;
end $$;
create function pg_temp.mk2(p_product bigint, p_start text, p_persons int, p_space bigint default null, p_override boolean default false, p_reason text default null, p_end text default null) returns bigint language plpgsql as $$
begin
  return (booking._create_legs_booking(null, p_product, pg_temp.ts(p_start), case when p_end is null then null else pg_temp.ts(p_end) end, p_persons,
          pg_temp.cust(), 'admin', null, null, null, p_space, p_override, p_reason, false, null) ->> 'reservation_id')::bigint;
end $$;

-- ---------- fikstuurit: kuvitteelliset saunottajat korvaavat TRANSAKTION SISÄLLÄ therapist_skills/therapist_on_duty-funktiot (public.* ei kosketa; rollback palauttaa alkuperäiset) ----------
create table booking._fx_staff(k text primary key, id uuid not null default gen_random_uuid());
create table booking._fx_skills(staff_id uuid, skill text);
create table booking._fx_shifts(shift_id uuid not null default gen_random_uuid(), staff_id uuid, starts_at timestamptz, ends_at timestamptz);
insert into booking._fx_staff(k) values ('T1'), ('T2'), ('T3'), ('LAURA');
insert into booking._fx_skills select s.id, v.skill from booking._fx_staff s join (values ('T1','yleinen'),('T1','saunotus'),('T1','morsiussauna'),('T2','yleinen'),('T2','morsiussauna'),('T3','yleinen'),('LAURA','laura')) v(k, skill) on v.k = s.k;
create or replace function booking.therapist_skills() returns table(staff_id uuid, skill text) language sql stable security definer set search_path to '' as $$
  select f.staff_id, f.skill from booking._fx_skills f join booking.skills k on k.code = f.skill and k.active $$;
create or replace function booking.therapist_on_duty(p_from timestamptz, p_to timestamptz) returns table(shift_id uuid, staff_id uuid, starts_at timestamptz, ends_at timestamptz, skills text[]) language sql stable security definer set search_path to '' as $$
  select s.shift_id, s.staff_id, s.starts_at, s.ends_at, coalesce((select array_agg(ts.skill order by ts.skill) from booking.therapist_skills() ts where ts.staff_id = s.staff_id), '{}'::text[])
    from booking._fx_shifts s where s.starts_at < p_to and s.ends_at > p_from $$;
create function pg_temp.shift(p_k text, p_from text, p_to text) returns void language plpgsql as $$
begin insert into booking._fx_shifts(staff_id, starts_at, ends_at) select id, pg_temp.ts(p_from), pg_temp.ts(p_to) from booking._fx_staff where k = p_k; end $$;
create function pg_temp.sh(p_date text) returns void language plpgsql as $$
begin
  perform pg_temp.shift('T1', p_date || ' 14:00', p_date || ' 20:00');
  perform pg_temp.shift('T2', p_date || ' 16:00', p_date || ' 20:00');
  perform pg_temp.shift('T3', p_date || ' 16:00', p_date || ' 20:00');
end $$;
select pg_temp.sh(d) from unnest(array['2027-01-23','2027-01-30','2027-02-06','2027-02-13','2027-02-27','2027-03-06','2027-03-13','2027-03-20','2027-04-03']) d;

select set_config('request.jwt.claims','',true);
-- ---------- booking_18 testit (kaikki rollbackiin; pehmeä epäonnistuminen: tulokset _res-tauluun) ----------
create function pg_temp.ev(p_id text, p_title text, p_s text, p_e text) returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'status', 'confirmed', 'summary', p_title, 'updated', '2027-01-01T00:00:00Z',
                            'start', jsonb_build_object('dateTime', pg_temp.ts(p_s)), 'end', jsonb_build_object('dateTime', pg_temp.ts(p_e))) $$;
create function pg_temp.evd(p_id text, p_title text, p_s text, p_e text) returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'status', 'confirmed', 'summary', p_title, 'updated', '2027-01-01T00:00:00Z',
                            'start', jsonb_build_object('date', p_s), 'end', jsonb_build_object('date', p_e)) $$;
create function pg_temp.ap(p_cal text, p_events jsonb, p_dry boolean default false, p_force boolean default false) returns jsonb language sql as $$
  select booking.apply_closure_events(p_cal, p_events, timestamptz '2027-01-01 00:00+02', timestamptz '2028-06-01 00:00+03', p_dry, p_force, 'test') $$;
create function pg_temp.st(p jsonb, k text) returns integer language sql as $$ select (p -> 'stats' ->> k)::integer $$;
create function pg_temp.nb(p_cal text) returns integer language sql as $$
  select count(*)::int from booking.space_blocks b join booking.closure_events e on e.id = b.closure_event_id where e.calendar_code = p_cal $$;
create function pg_temp.nev(p_cal text, p_status text) returns integer language sql as $$
  select count(*)::int from booking.closure_events where calendar_code = p_cal and status = p_status $$;

create function pg_temp.snap_sav() returns jsonb language sql as $$
  select jsonb_build_array(
    pg_temp.ev('e1', 'Huolto', '2027-02-20 10:00', '2027-02-20 12:00'),
    pg_temp.evd('e2', 'Loma', '2027-02-21', '2027-02-22'),
    pg_temp.ev('e3', '[AUTO-JOHKU] Perinnesaunotus: Esimerkki', '2027-02-20 14:00', '2027-02-20 16:00'),
    pg_temp.ev('e4', 'Kekri', '2027-02-24 14:00', '2027-02-24 20:00'),
    jsonb_build_object('id', 'e5', 'status', 'cancelled'),
    pg_temp.ev('e6', 'Koulutus', '2027-02-23 08:00', '2027-02-23 16:00'),
    pg_temp.ev('e7', 'Pitkä huoltojakso', '2027-03-01 08:00', '2027-03-14 19:00'),
    pg_temp.ev('e9', 'Koulutus', '2027-03-01 08:00', '2027-03-14 19:00'),
    pg_temp.ev('e8', 'Virheellinen', '2027-02-25 10:00', '2027-02-25 10:00')) $$;


-- ================= S. rakenne ja oikeudet =================
do $$ begin
  perform pg_temp.t_ok((select count(*) from booking.closure_calendars) = 4
    and (select count(*) from booking.closure_calendars c join booking.resources r on r.id = c.resource_id
          where (c.code, r.code) in (('hoidot','saunottaja'), ('rauni','rauni'), ('perinnesaunotus','perinnesaunotus_ryhma'), ('savusauna','savusauna'))) = 4, 'S1 neljä kalenteria oikeilla kohderesursseilla');
  perform pg_temp.t_ok((select count(*) from booking.closure_event_rules where active) = 5, 'S2 viisi oletussääntöä');
  perform pg_temp.t_ok((select kind from booking.resources where code = 'laura') = 'person', 'S3 laura-resurssi (person)');
  perform pg_temp.t_ok((select action from booking.closure_event_rules where pattern = 'Koulutus') = 'ignore' and (select extra_resource_code from booking.closure_event_rules where pattern = 'Koulutus') is null and not exists (select 1 from booking.closure_event_rules where action = 'block'), 'S3b Koulutus-sääntö = ohita (ei sulje mitään); oletussäännöissä ei block-sääntöjä');
  perform pg_temp.t_ok(not has_function_privilege('authenticated', 'booking.apply_closure_events(text,jsonb,timestamptz,timestamptz,boolean,boolean,text)', 'execute')
    and not has_function_privilege('anon', 'booking.apply_closure_events(text,jsonb,timestamptz,timestamptz,boolean,boolean,text)', 'execute')
    and not has_function_privilege('authenticated', 'booking.closure_sync_targets()', 'execute')
    and has_function_privilege('service_role', 'booking.apply_closure_events(text,jsonb,timestamptz,timestamptz,boolean,boolean,text)', 'execute'), 'S4 apply/targets vain service_role');
  perform pg_temp.t_ok(not has_column_privilege('authenticated', 'booking.closure_calendars', 'google_calendar_id', 'select')
    and has_column_privilege('authenticated', 'booking.closure_calendars', 'name', 'select')
    and not has_table_privilege('anon', 'booking.closure_events', 'select')
    and not has_table_privilege('authenticated', 'booking.closure_events', 'insert'), 'S5 google_calendar_id ei näy; anon ei lue; authenticated vain luku');
  perform pg_temp.t_ok((select relrowsecurity from pg_class where oid = 'booking.closure_events'::regclass), 'S6 RLS päällä (closure_events)');
  begin update booking.closure_calendars set active = true where code = 'rauni'; perform pg_temp.t_ok(false, 'S7 aktivointi ilman google_calendar_id estetty');
  exception when check_violation then perform pg_temp.t_ok(true, 'S7 aktivointi ilman google_calendar_id estetty'); end;
  perform pg_temp.t_ok(jsonb_array_length(booking.closure_sync_targets() -> 'calendars') = 0, 'S8 targets: ei aktiivisia kalentereita ennen rekisteröintiä');
  update booking.closure_calendars set google_calendar_id = 'testi@group.calendar.google.com', active = true where code = 'rauni';
  perform pg_temp.t_ok(jsonb_array_length(booking.closure_sync_targets() -> 'calendars') = 1 and (booking.closure_sync_targets() -> 'config' ->> 'max_timed_hours') = '36', 'S9 targets: rekisteröity kalenteri + asetukset');
  update booking.closure_calendars set google_calendar_id = null, active = false where code = 'rauni';
exception when others then insert into pg_temp._res(kind,ok,msg) values ('T', false, 'RYHMÄ S KESKEYTYI: ' || sqlstate || ' ' || sqlerrm);
end $$;

-- ================= A–E. synkka: alkuajo, idempotenssi, muutos, poisto, paluu =================
do $$ declare ev jsonb; r jsonb; n0 integer; begin
  ev := pg_temp.snap_sav();
  r := pg_temp.ap('savusauna', ev);
  perform pg_temp.t_ok((r ->> 'ok')::boolean and pg_temp.st(r, 'events_seen') = 8 and pg_temp.st(r, 'inserted') = 3 and pg_temp.st(r, 'ignored_mirror') = 1
    and pg_temp.st(r, 'ignored_marker') = 1 and pg_temp.st(r, 'ignored_training') = 2 and pg_temp.st(r, 'rough') = 1 and pg_temp.st(r, 'invalid') = 1, 'A1 alkuajo: 3 uutta (closure, kokopäivä, rough); peili/merkintä/Koulutus/virheellinen ohitettu');
  perform pg_temp.t_ok(pg_temp.st(r, 'blocks_inserted') = 2 and pg_temp.nb('savusauna') = 2, 'A2 sulkuja 2 (huolto + loma)');
  perform pg_temp.t_ok((select count(*) from booking.closure_events where external_id in ('e6', 'e9')) = 0 and not exists (select 1 from booking.space_blocks b where b.reason ilike '%koulutus%') and pg_temp.nb('savusauna') = 2
    and not exists (select 1 from booking.space_blocks b where b.closure_event_id is not null and b.space_id = pg_temp.rid('laura')), 'A3 Koulutus-tapahtuma ei luo kirjanpitoa eikä sulkua (ei kalenterille eikä Lauralle)');
  perform pg_temp.t_ok((select b.starts_at = pg_temp.ts('2027-02-21 00:00') and b.ends_at = pg_temp.ts('2027-02-22 00:00') from booking.space_blocks b
                         join booking.closure_events e on e.id = b.closure_event_id where e.external_id = 'e2' and b.space_id = pg_temp.rid('savusauna')), 'A4 kokopäivätapahtuma = Helsingin vuorokausi [alku, seuraava pv)');
  perform pg_temp.t_ok((select count(*) from booking.closure_events where external_id in ('e3', 'e4', 'e5', 'e8')) = 0, 'A5 peiliä/merkintää/peruttua/virheellistä ei tallenneta');
  perform pg_temp.t_ok((select count(*) from booking.closure_events where external_id = 'e7' and class = 'rough') = 1 and (select count(*) from booking.space_blocks b join booking.closure_events e on e.id = b.closure_event_id where e.external_id = 'e7') = 0, 'A6 karkea jakso (>36 h) tallennetaan mutta ei sulje');
  perform pg_temp.t_ok((select last_success_at is not null and last_error is null and consecutive_failures = 0 from booking.closure_calendars where code = 'savusauna')
    and (select count(*) from booking.closure_sync_runs where calendar_code = 'savusauna' and outcome = 'ok') = 1, 'A7 kalenterin tila + ajoloki');
  -- DST: kokopäivä 28.3.2027 (kellonsiirto) = 23 h
  r := pg_temp.ap('rauni', jsonb_build_array(pg_temp.evd('d1', 'Kellonsiirto', '2027-03-28', '2027-03-29')));
  perform pg_temp.t_ok((select b.ends_at - b.starts_at = interval '23 hours' from booking.space_blocks b join booking.closure_events e on e.id = b.closure_event_id where e.external_id = 'd1'), 'A8 kellonsiirtopäivän kokopäivä = 23 h');
  r := pg_temp.ap('rauni', '[]'::jsonb);
  perform pg_temp.t_ok(pg_temp.st(r, 'deleted') = 1 and pg_temp.nb('rauni') = 0, 'A9 (siivous) poistunut tapahtuma poistaa sulun');

  -- B idempotenssi
  r := pg_temp.ap('savusauna', ev);
  perform pg_temp.t_ok(pg_temp.st(r, 'inserted') = 0 and pg_temp.st(r, 'updated') = 0 and pg_temp.st(r, 'deleted') = 0 and pg_temp.st(r, 'unchanged') = 3
    and pg_temp.st(r, 'blocks_inserted') = 0 and pg_temp.st(r, 'blocks_updated') = 0 and pg_temp.st(r, 'blocks_deleted') = 0, 'B1 toinen ajo samalla datalla: ei muutoksia');
  -- C muutos
  ev := jsonb_set(ev, '{0}', pg_temp.ev('e1', 'Huolto (siirretty)', '2027-02-20 11:00', '2027-02-20 13:00'));
  r := pg_temp.ap('savusauna', ev);
  perform pg_temp.t_ok(pg_temp.st(r, 'updated') = 1 and pg_temp.st(r, 'inserted') = 0 and pg_temp.st(r, 'blocks_updated') = 1 and pg_temp.nb('savusauna') = 2
    and (select b.starts_at = pg_temp.ts('2027-02-20 11:00') and b.reason like '%siirretty%' from booking.space_blocks b join booking.closure_events e on e.id = b.closure_event_id where e.external_id = 'e1'), 'C1 muutettu tapahtuma päivittää saman sulkurivin (ei duplikaattia)');
  -- D poisto
  n0 := pg_temp.nb('savusauna');
  r := pg_temp.ap('savusauna', ev - 1);                                      -- e2 pois
  perform pg_temp.t_ok(pg_temp.st(r, 'deleted') = 1 and pg_temp.nb('savusauna') = n0 - 1 and pg_temp.nev('savusauna', 'deleted') = 1, 'D1 poistunut tapahtuma poistaa sulun, kirjanpitoon tombstone');
  -- E paluu
  r := pg_temp.ap('savusauna', ev);
  perform pg_temp.t_ok(pg_temp.st(r, 'blocks_inserted') = 1 and pg_temp.nb('savusauna') = n0 and pg_temp.nev('savusauna', 'deleted') = 0, 'E1 palannut tapahtuma (sama id) aktivoituu ja sulku syntyy uudelleen');
exception when others then insert into pg_temp._res(kind,ok,msg) values ('T', false, 'RYHMÄ A–E KESKEYTYI: ' || sqlstate || ' ' || sqlerrm);
end $$;

-- ================= F–G. massapoistosuoja, dry-run, ikkunan rajaus =================
do $$ declare ev jsonb := '[]'::jsonb; r jsonb; i int; c1 int; c2 int; begin
  for i in 1..8 loop ev := ev || pg_temp.ev('h' || i, 'Hoitosulku ' || i, '2027-03-0' || i || ' 10:00', '2027-03-0' || i || ' 12:00'); end loop;
  r := pg_temp.ap('hoidot', ev);
  perform pg_temp.t_ok(pg_temp.st(r, 'inserted') = 8 and pg_temp.nb('hoidot') = 8, 'F0 hoidot: 8 sulkua');
  r := pg_temp.ap('hoidot', '[]'::jsonb);
  perform pg_temp.t_ok(not (r ->> 'ok')::boolean and (r ->> 'guard')::boolean and pg_temp.nb('hoidot') = 8 and pg_temp.nev('hoidot', 'active') = 8
    and (select last_error from booking.closure_calendars where code = 'hoidot') = 'mass_delete_guard'
    and (select count(*) from booking.closure_sync_runs where calendar_code = 'hoidot' and outcome = 'guard') = 1, 'F1 tyhjä snapshot + 8 poistoa -> massapoistosuoja, mitään ei poistu');
  -- dry-run ei muuta mitään
  select count(*) into c1 from booking.space_blocks; select count(*) into c2 from booking.closure_sync_runs;
  r := pg_temp.ap('hoidot', ev || pg_temp.ev('h9', 'Uusi', '2027-03-09 10:00', '2027-03-09 12:00'), true);
  perform pg_temp.t_ok((r ->> 'ok')::boolean and pg_temp.st(r, 'inserted') = 1 and pg_temp.st(r, 'blocks_inserted') = 1 and (select count(*) from booking.space_blocks) = c1
    and (select count(*) from booking.closure_sync_runs) = c2 and pg_temp.nev('hoidot', 'active') = 8, 'G1 dry-run palauttaa tilastot mutta ei kirjoita (sulut, kirjanpito, loki ennallaan)');
  r := pg_temp.ap('hoidot', '[]'::jsonb, false, true);
  perform pg_temp.t_ok((r ->> 'ok')::boolean and pg_temp.st(r, 'deleted') = 8 and pg_temp.nb('hoidot') = 0, 'F2 force ohittaa suojan (tarkoituksellinen tyhjennys)');
  -- ikkunan ulkopuolinen tapahtuma ei poistu kapealla ikkunalla
  perform pg_temp.ap('hoidot', jsonb_build_array(pg_temp.ev('far', 'Kaukana', '2028-03-01 10:00', '2028-03-01 12:00')));
  r := booking.apply_closure_events('hoidot', '[]'::jsonb, timestamptz '2027-01-01 00:00+02', timestamptz '2028-01-01 00:00+02', false, false, 'test');
  perform pg_temp.t_ok(pg_temp.st(r, 'deleted') = 0 and pg_temp.nb('hoidot') = 1, 'G2 ikkunan ulkopuolella olevaa tapahtumaa ei poisteta');
  r := pg_temp.ap('hoidot', '[]'::jsonb);
  perform pg_temp.t_ok(pg_temp.st(r, 'deleted') = 1 and pg_temp.nb('hoidot') = 0, 'G3 sama tapahtuma poistuu kun ikkuna kattaa sen');
exception when others then insert into pg_temp._res(kind,ok,msg) values ('T', false, 'RYHMÄ F–G KESKEYTYI: ' || sqlstate || ' ' || sqlerrm);
end $$;

-- ================= H. ohitus (override), sääntömuokkaus, hallinta-esto =================
do $$ declare r jsonb; v_e1 bigint; v_e7 bigint; v_b bigint; begin
  -- tila: savusauna-kalenterissa e1 (sulku) ja e7 (rough) edellisestä ryhmästä
  select id into v_e1 from booking.closure_events where calendar_code = 'savusauna' and external_id = 'e1';
  select id into v_e7 from booking.closure_events where calendar_code = 'savusauna' and external_id = 'e7';
  -- hallinta-esto: ylläpidon kautta ei voi poistaa/muokata kalenterisulkua (GUC nollataan, koska testit ovat yhdessä transaktiossa)
  select b.id into v_b from booking.space_blocks b where b.closure_event_id = v_e1 limit 1;
  perform set_config('booking.closure_sync', 'off', true);
  perform pg_temp.t_err(format('update booking.space_blocks set active = false where id = %s', v_b), 'closure_managed', 'H1 kalenterisulun muokkaus/poisto estetty (trigger)');
  perform pg_temp.t_err(format('delete from booking.space_blocks where id = %s', v_b), 'closure_managed', 'H2 kalenterisulun suora poisto estetty');
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('t18.adm'), 'role', 'authenticated')::text, true);
  perform pg_temp.t_err(format('select booking.admin_delete_block(%s::bigint)', v_b), 'closure_managed', 'H3 admin_delete_block (ylläpidon poisto) estetty kalenterisululle');
  perform set_config('request.jwt.claims', '', true);
  insert into booking.space_blocks(space_id, starts_at, ends_at, reason) values (pg_temp.rid('savusauna'), pg_temp.ts('2027-06-01 10:00'), pg_temp.ts('2027-06-01 12:00'), 'käsin tehty');
  update booking.space_blocks set active = false where reason = 'käsin tehty';
  perform pg_temp.t_ok(true, 'H4 käsin tehtyä sulkua voi edelleen muokata');
exception when others then insert into pg_temp._res(kind,ok,msg) values ('T', false, 'RYHMÄ H KESKEYTYI: ' || sqlstate || ' ' || sqlerrm);
end $$;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('t18.adm'), 'role', 'authenticated')::text, true);

-- override ylläpitäjänä (state: savusauna e1 sulku, e2 sulku, e7 rough)
do $$ declare r jsonb; v_e1 bigint; v_e7 bigint; ev jsonb := jsonb_set(pg_temp.snap_sav(), '{0}', pg_temp.ev('e1', 'Huolto (siirretty)', '2027-02-20 11:00', '2027-02-20 13:00')); begin
  select id into v_e1 from booking.closure_events where calendar_code = 'savusauna' and external_id = 'e1';
  select id into v_e7 from booking.closure_events where calendar_code = 'savusauna' and external_id = 'e7';
  perform pg_temp.t_ok(pg_temp.nb('savusauna') = 2, 'H5 lähtötila: 2 sulkua');
  r := booking.admin_set_closure_override(v_e1, 'ignore', 'kirjattu käsin varauksena');
  perform pg_temp.t_ok((r ->> 'ok')::boolean and (r ->> 'blocks_deleted')::int = 1 and not exists (select 1 from booking.space_blocks where closure_event_id = v_e1), 'H6 override ignore poistaa sulun');
  perform set_config('request.jwt.claims', '', true);
  r := pg_temp.ap('savusauna', ev);
  perform pg_temp.t_ok(pg_temp.st(r, 'updated') = 0 and pg_temp.st(r, 'blocks_inserted') = 0 and (select override from booking.closure_events where id = v_e1) = 'ignore' and not exists (select 1 from booking.space_blocks where closure_event_id = v_e1), 'H7 synkka säilyttää ohituksen eikä luo sulkua uudelleen');
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('t18.adm'), 'role', 'authenticated')::text, true);
  r := booking.admin_set_closure_override(v_e7, 'block');
  perform pg_temp.t_ok((r ->> 'blocks_inserted')::int = 1 and pg_temp.nb('savusauna') = 2, 'H8 override block muuttaa rough-jakson sulkevaksi');
  perform set_config('request.jwt.claims', '', true);
  r := pg_temp.ap('savusauna', ev);
  perform pg_temp.t_ok(pg_temp.st(r, 'blocks_inserted') = 0 and pg_temp.st(r, 'blocks_deleted') = 0 and pg_temp.st(r, 'updated') = 0, 'H9 synkka säilyttää block-ohituksen');
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('t18.adm'), 'role', 'authenticated')::text, true);
  r := booking.admin_set_closure_override(v_e7, null);
  perform pg_temp.t_ok((r ->> 'blocks_deleted')::int = 1, 'H10 ohituksen poisto palauttaa oletuksen (rough ei sulje)');
  r := booking.admin_set_closure_override(v_e1, null);
  perform pg_temp.t_ok((r ->> 'blocks_inserted')::int = 1 and pg_temp.nb('savusauna') = 2, 'H11 ohituksen poisto palauttaa sulun');
  perform pg_temp.t_err('select booking.admin_set_closure_override(-1, ''block'')', 'not_found', 'H12 tuntematon tapahtuma');
  perform pg_temp.t_err(format('select booking.admin_set_closure_override(%s, ''foo'')', v_e1), 'bad_override', 'H13 virheellinen ohitusarvo');
  perform pg_temp.t_ok(jsonb_array_length(booking.admin_closure_overview(400) -> 'calendars') = 4 and jsonb_array_length(booking.admin_closure_overview(400) -> 'events') >= 3, 'H14 admin_closure_overview: 4 kalenteria + tulevat tapahtumat');
  perform pg_temp.t_err('select booking.apply_closure_events(''savusauna'', ''[]''::jsonb, now(), now() + interval ''1 day'')', 'forbidden', 'H15 kirjautunut käyttäjä (authenticated) ei voi ajaa synkkaa');
  perform pg_temp.t_err('select booking.closure_sync_targets()', 'forbidden', 'H16 targets vain service_role');
  perform set_config('request.jwt.claims', '', true);
exception when others then insert into pg_temp._res(kind,ok,msg) values ('T', false, 'RYHMÄ H2 KESKEYTYI: ' || sqlstate || ' ' || sqlerrm);
end $$;

-- ================= I. validaattorit lukevat kalenterisulut (17b) =================
do $$ declare r jsonb; begin
  -- hoidot kiinni (saunottaja): Saunahoito (kb 10) estyy, mutta Lauran tuote (kb 9) ei
  r := pg_temp.ap('hoidot', jsonb_build_array(pg_temp.ev('hk', 'Hoidot kiinni', '2027-03-06 13:00', '2027-03-06 20:00')));
  perform pg_temp.t_ok((r ->> 'ok')::boolean and pg_temp.nb('hoidot') = 1, 'I0 hoidot-sulku syntyi');
  perform pg_temp.mk2(10, '2027-03-13 15:00', 1);
  perform pg_temp.t_ok(true, 'I1 vertailu: kb 10 onnistuu ilman sulkua (13.3.)');
  perform pg_temp.t_err($q$select pg_temp.mk2(10, '2027-03-06 15:00', 1)$q$, 'therapist_closed', 'I2 hoidot kiinni estää Saunahoidon (therapist_closed)');
  perform pg_temp.mk2(9, '2027-03-06 19:00', 3);
  perform pg_temp.t_ok(true, 'I3 hoidot kiinni EI sulje Lauran tuotetta (kb 9)');
  -- Koulutus perinne-kalenterissa: sulkee ryhmäresurssin ja Lauran
  r := pg_temp.ap('perinnesaunotus', jsonb_build_array(pg_temp.ev('k1', 'Koulutus', '2027-03-20 12:00', '2027-03-20 22:00'),
                                                       pg_temp.evd('p1', 'Perinne kiinni', '2027-04-03', '2027-04-04')));
  perform pg_temp.t_ok(pg_temp.st(r, 'blocks_inserted') = 1 and pg_temp.st(r, 'ignored_training') = 1, 'I4 perinne: Koulutus ohitettu, kokopäiväsulku 1');
  perform pg_temp.mk2(9, '2027-03-20 19:00', 3);
  perform pg_temp.t_ok(true, 'I5 Koulutus-tapahtuma EI sulje Lauraa (kb 9 onnistuu Koulutuksen aikana)');
  -- koulutussulku käsin Laura-resurssille (admin_create_block) sulkee Lauran tuotteet mutta ei hoitoja
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('t18.adm'), 'role', 'authenticated')::text, true);
  perform booking.admin_create_block(pg_temp.rid('laura'), pg_temp.ts('2027-03-27 18:00'), pg_temp.ts('2027-03-27 22:00'), 'Koulutus (käsin)');
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.t_err($q$select pg_temp.mk2(9, '2027-03-27 19:00', 3)$q$, 'therapist_closed', 'I5b käsin tehty Laura-sulku estää Lauran tuotteen (therapist_closed)');
  perform pg_temp.t_ok(not exists (select 1 from booking.space_blocks b where b.space_id = pg_temp.rid('saunottaja') and b.during && tstzrange(pg_temp.ts('2027-03-27 18:00'), pg_temp.ts('2027-03-27 22:00'))), 'I5c Laura-sulku ei sulje saunottajaa (hoidot)');
  perform pg_temp.t_err($q$select pg_temp.mk2(23, '2027-04-03 14:00', 1)$q$, 'space_closed', 'I6 perinnesaunotus kiinni sulkee perinnesaunotustuotteet (ryhmäleg -> space_closed)');
  perform pg_temp.mk2(23, '2027-02-06 14:00', 1);
  perform pg_temp.t_ok(true, 'I7 vertailu: kb 23 onnistuu ilman sulkua (6.2.)');
  -- rauni / savusauna: tilasulku
  perform pg_temp.ap('rauni', jsonb_build_array(pg_temp.evd('r1', 'Rauni huolto', '2027-04-10', '2027-04-11')));
  perform pg_temp.t_err($q$select pg_temp.mk('rauni', 'exclusive', '2027-04-10 12:00', '2027-04-10 14:00', 2)$q$, 'space_closed', 'I8 Rauni kiinni -> space_closed');
  perform pg_temp.ap('savusauna', jsonb_build_array(pg_temp.evd('s1', 'Savusauna kiinni', '2027-04-11', '2027-04-12')));
  perform pg_temp.t_err($q$select pg_temp.mk('savusauna', 'exclusive', '2027-04-11 12:00', '2027-04-11 14:00', 2)$q$, 'space_closed', 'I9 Savusauna kiinni -> space_closed');
  perform pg_temp.t_err($q$select pg_temp.mk('savusauna', 'exclusive', '2027-04-11 23:00', '2027-04-12 01:00', 2)$q$, 'space_closed', 'I10 sulku ulottuu vuorokauden loppuun (23–01 osuu)');
  perform pg_temp.mk('savusauna', 'exclusive', '2027-04-12 00:00', '2027-04-12 02:00', 2);
  perform pg_temp.t_ok(true, 'I11 puoliavoin väli: seuraavan päivän 00:00 alkava vuoro sallittu');
exception when others then insert into pg_temp._res(kind,ok,msg) values ('T', false, 'RYHMÄ I KESKEYTYI: ' || sqlstate || ' ' || sqlerrm);
end $$;

-- ================= J. konfliktit olemassa oleviin varauksiin + sääntömuokkaus =================
select set_config('request.jwt.claims', json_build_object('sub', current_setting('t18.adm'), 'role', 'authenticated')::text, true);

do $$ declare r jsonb; v_res bigint; begin
  perform set_config('request.jwt.claims', '', true);
  v_res := pg_temp.mk('savusauna', 'exclusive', '2027-05-01 12:00', '2027-05-01 14:00', 2);
  r := pg_temp.ap('savusauna', pg_temp.snap_sav() || pg_temp.ev('c1', 'Päällekkäinen sulku', '2027-05-01 13:00', '2027-05-01 15:00'));
  perform pg_temp.t_ok((r ->> 'ok')::boolean and pg_temp.st(r, 'conflicting_reservations') >= 1 and (r -> 'conflicts') @> jsonb_build_array(jsonb_build_object('reservation_id', v_res)) is not null, 'J1 päällekkäinen sulku raportoi konfliktin (sulku kirjoitetaan silti)');
  perform pg_temp.t_ok(exists (select 1 from booking.space_blocks b join booking.closure_events e on e.id = b.closure_event_id where e.external_id = 'c1'), 'J2 sulku on voimassa varauksesta huolimatta');
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('t18.adm'), 'role', 'authenticated')::text, true);
  perform pg_temp.t_ok(booking.admin_review_list()::text like '%block_conflicts%' and booking.admin_review_list() -> 'block_conflicts' @> jsonb_build_array(jsonb_build_object('reservation_id', v_res)) is not null
    and exists (select 1 from jsonb_array_elements(booking.admin_review_list() -> 'block_conflicts') x where (x ->> 'reservation_id')::bigint = v_res), 'J3 admin_review_list näyttää kalenterisulun konfliktin');
  perform pg_temp.t_ok(exists (select 1 from jsonb_array_elements(booking.admin_closure_overview(400) -> 'conflicts') x where (x ->> 'reservation_id')::bigint = v_res), 'J4 admin_closure_overview näyttää konfliktin');
  perform set_config('request.jwt.claims', '', true);
  -- sääntömuokkaus: uusi ignore-sääntö vaikuttaa seuraavaan ajoon ilman koodimuutosta
  insert into booking.closure_event_rules(calendar_code, sort_order, match_type, pattern, action, class, note) values ('rauni', 5, 'regex', '^Ohita ', 'ignore', 'marker', 'testi');
  r := pg_temp.ap('rauni', jsonb_build_array(pg_temp.evd('r1', 'Rauni huolto', '2027-04-10', '2027-04-11'), pg_temp.ev('o1', 'Ohita tämä', '2027-04-20 10:00', '2027-04-20 12:00')));
  perform pg_temp.t_ok(pg_temp.st(r, 'ignored_marker') = 1 and pg_temp.st(r, 'inserted') = 0 and pg_temp.st(r, 'deleted') = 0, 'J5 sääntötaulun uusi ignore-sääntö toimii (regex, kalenterikohtainen)');
  -- block-sääntö + lisäresurssi (mekanismi säilyy mutta ei ole käytössä oletussäännöissä)
  insert into booking.closure_event_rules(calendar_code, sort_order, match_type, pattern, action, class, extra_resource_code, note) values ('rauni', 6, 'equals', 'Sulje myös Laura', 'block', 'closure', 'laura', 'testi');
  r := pg_temp.ap('rauni', jsonb_build_array(pg_temp.evd('r1', 'Rauni huolto', '2027-04-10', '2027-04-11'), pg_temp.ev('x1', 'Sulje myös Laura', '2027-04-21 10:00', '2027-04-21 12:00')));
  perform pg_temp.t_ok(pg_temp.st(r, 'inserted') = 1 and pg_temp.st(r, 'blocks_inserted') = 2 and (select count(*) from booking.space_blocks b join booking.closure_events e on e.id = b.closure_event_id where e.external_id = 'x1' and b.space_id in (pg_temp.rid('rauni'), pg_temp.rid('laura'))) = 2, 'J5b sääntö extra_resource_code luo sulun myös lisäresurssille');
  r := pg_temp.ap('rauni', jsonb_build_array(pg_temp.evd('r1', 'Rauni huolto', '2027-04-10', '2027-04-11')));
  perform pg_temp.t_ok(pg_temp.st(r, 'deleted') = 1 and pg_temp.st(r, 'blocks_deleted') = 2, 'J5c poistuva tapahtuma poistaa molemmat sulut');
  -- tapahtuma muuttuu peiliksi -> sulku poistuu
  r := pg_temp.ap('rauni', jsonb_build_array(pg_temp.ev('r1', '[AUTO-JOHKU] Jokin: Varaus', '2027-04-10 10:00', '2027-04-10 12:00')));
  perform pg_temp.t_ok(pg_temp.st(r, 'deleted') = 1 and pg_temp.nb('rauni') = 0 and pg_temp.st(r, 'ignored_mirror') = 1, 'J6 sulkutapahtuma jonka otsikko muuttuu peiliksi poistaa sulun');
exception when others then insert into pg_temp._res(kind,ok,msg) values ('T', false, 'RYHMÄ J KESKEYTYI: ' || sqlstate || ' ' || sqlerrm);
end $$;

-- ================= K. Lauran legit omalle resurssille (18c) =================
do $$ declare a bigint; b bigint; begin
  a := pg_temp.mk2(9, '2027-03-06 19:00', 2);
  b := pg_temp.mk2(10, '2027-03-13 17:30', 1);
  perform pg_temp.t_ok((select r.code from booking.reservation_legs l join booking.resources r on r.id = l.resource_id where l.reservation_id = a and l.role = 'therapist') = 'laura', 'K1 Lauran tuotteen therapist-leg on laura-resurssilla');
  perform pg_temp.t_ok((select r.code from booking.reservation_legs l join booking.resources r on r.id = l.resource_id where l.reservation_id = b and l.role = 'therapist') = 'saunottaja', 'K2 vuoropohjaisen taidon therapist-leg on saunottaja-resurssilla');
  perform pg_temp.t_ok(booking._skill_block_resource('laura') = pg_temp.rid('laura') and booking._skill_block_resource('yleinen') = pg_temp.rid('saunottaja') and booking._skill_block_resource(null) = pg_temp.rid('saunottaja'), 'K3 _skill_block_resource');
  -- Lauran koulutus syntyy vasta varauksen jälkeen -> konflikti näkyy (laura-resurssin leg)
  insert into booking.space_blocks(space_id, starts_at, ends_at, reason) values (pg_temp.rid('laura'), pg_temp.ts('2027-03-06 18:00'), pg_temp.ts('2027-03-06 22:00'), 'Koulutus (käsin)');
  perform pg_temp.t_ok(exists (select 1 from booking.v_claims c join booking.space_blocks bl on bl.active and bl.space_id = c.resource_id and bl.during && tstzrange(c.claim_start, c.claim_end, '[)')
                                where c.reservation_id = a), 'K4 myöhemmin tehty käsin-Laura-sulku osuu olemassa olevan Laura-varauksen legiin (näkyy konfliktina)');
exception when others then insert into pg_temp._res(kind,ok,msg) values ('T', false, 'RYHMÄ K KESKEYTYI: ' || sqlstate || ' ' || sqlerrm);
end $$;

-- ================= L. admin_day_view: blocks-rivien closure_event_id ja resource_code (UI: Kalenterisulku-merkki, vain luettava) =================
do $$ declare v jsonb; ev bigint; begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.ap('savusauna', jsonb_build_array(pg_temp.ev('dv1', 'Huolto (päivänäkymä)', '2027-07-01 10:00', '2027-07-01 12:00')));
  select id into ev from booking.closure_events where calendar_code = 'savusauna' and external_id = 'dv1';
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('t18.adm'), 'role', 'authenticated')::text, true);
  perform booking.admin_create_block(pg_temp.rid('laura'), pg_temp.ts('2027-07-01 13:00'), pg_temp.ts('2027-07-01 15:00'), 'Koulutus (käsin)');
  perform set_config('booking.closure_sync', 'off', true);   -- synkka asettaa GUC:n transaktioksi; tuotannossa jokainen kutsu on oma transaktionsa
  v := booking.admin_day_view('2027-07-01');
  perform pg_temp.t_ok(jsonb_array_length(v -> 'blocks') = 2, 'L1 päivänäkymässä kaksi sulkua (kalenteri + käsin)');
  perform pg_temp.t_ok((select (b ->> 'closure_event_id')::bigint = ev and b ->> 'resource_code' = 'savusauna' from jsonb_array_elements(v -> 'blocks') b where b ->> 'reason' like 'Kalenteri (%'),
    'L2 kalenterisulun rivillä closure_event_id (= closure_events.id) ja resource_code');
  perform pg_temp.t_ok((select b -> 'closure_event_id' = 'null'::jsonb and b ->> 'resource_code' = 'laura' from jsonb_array_elements(v -> 'blocks') b where b ->> 'reason' = 'Koulutus (käsin)'),
    'L3 käsin tehdyllä Laura-sululla closure_event_id on null (muokattavissa) ja resource_code laura');
  perform pg_temp.t_err(format('select booking.admin_delete_block(%s)', (select (b ->> 'id')::bigint from jsonb_array_elements(v -> 'blocks') b where b ->> 'closure_event_id' is not null)),
    'closure_managed', 'L4 päivänäkymän kalenterisulun poisto estetty (closure_managed)');
  perform booking.admin_delete_block((select (b ->> 'id')::bigint from jsonb_array_elements(v -> 'blocks') b where b ->> 'resource_code' = 'laura'));
  perform pg_temp.t_ok(jsonb_array_length(booking.admin_day_view('2027-07-01') -> 'blocks') = 1, 'L5 käsin tehty Laura-sulku voidaan poistaa');
  perform set_config('request.jwt.claims', '', true);
exception when others then insert into pg_temp._res(kind,ok,msg) values ('T', false, 'RYHMÄ L KESKEYTYI: ' || sqlstate || ' ' || sqlerrm);
end $$;

select ok(ok, msg) from pg_temp._res order by n;
select * from finish();
rollback;
