-- tcalsync412: shift_outbox_fail 412 / konflikti (migraatio 20261025160000_calsync412_outbox_412, väliaikainen versio).
-- Kanta: paikallinen PG17, jossa tuotannon määrittelyt (repo-migraatiot; md5:t tarkistetaan alussa tuotannon SELECT-arvoja vastaan) + tämä migraatio.
-- A 412 ei kuluta yrityksiä (attempts palautuu, conflict_attempts kasvaa, google_etag tyhjenee, ei konfliktiriviä), B porrastus 1 min x3 -> 10 min
-- ja turvaraja 24 -> error + push_failed (conflict_cap), C konflikti yrityskaton (8) kohdalla ei enää ole error, D tavalliset virheet kuluttavat
-- yrityksiä kuten ennen (8 -> error), E p_missing / p_blocked ennallaan, F claim: mirror + tyhjennetty etag, G complete 412:n jälkeen,
-- H oikeudet (anon/authenticated 42501), I NOT NULL 23502 ja tuntematon id, J rollback (md5 takaisin tuotantoon) + migraatio uudelleen + guard P0001.
-- Ajo: cd booking/supabase/tests/calendar && psql -X -v ON_ERROR_STOP=1 -f tcalsync412_shift_outbox_fail.sql
-- Kaikki yhdessä transaktiossa; lopussa tahallinen poikkeus "TESTRESULT pass=… fail=…" kumoaa kaiken. Ei tuotantoon.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table tr(ok boolean, label text);
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into tr values (coalesce(p_ok, false), p_label) $$;
-- SQLSTATE: suorittaa lauseen alitransaktiossa (valinnaisesti roolina) ja palauttaa tilakoodin ('00000' = ok)
create function pg_temp.state(p_sql text, p_role text default null) returns text language plpgsql as $$
begin
  if p_role is not null then execute format('set local role %I', p_role); end if;
  execute p_sql;
  if p_role is not null then reset role; end if;
  return '00000';
exception when others then
  return sqlstate;
end $$;
create function pg_temp.ob(p_id bigint) returns public.shift_outbox language sql as $$ select * from public.shift_outbox where id = p_id $$;
create function pg_temp.due(p_id bigint) returns void language sql as $$
  update public.shift_outbox set next_attempt_at = now() - interval '1 second' where id = p_id $$;

-- 0. lähtötila = tuotanto + migraatio (md5)
select pg_temp.ck(md5(pg_get_functiondef('public.shift_outbox_fail(bigint,text,boolean,boolean,boolean)'::regprocedure)) = '4058beac69368354d2ff55aebc491653', '0 shift_outbox_fail = migraation md5');
select pg_temp.ck(md5(pg_get_functiondef('public.shift_outbox_claim(uuid,integer,boolean)'::regprocedure)) = '72f2467fa9561a727795e16564bf4496', '0 shift_outbox_claim = migraation md5');
select pg_temp.ck(md5(pg_get_functiondef('public.shift_outbox_complete(bigint,text,timestamptz,text)'::regprocedure)) = '59338520abe08983748b9020736fcab7', '0 shift_outbox_complete = tuotanto');
select pg_temp.ck(md5(pg_get_functiondef('public._shift_enqueue(uuid)'::regprocedure)) = '6ee44c5badf73a180a4ff673c1ad5be9', '0 _shift_enqueue = tuotanto');
select pg_temp.ck(md5(pg_get_functiondef('public._shift_ws_before()'::regprocedure)) = '327b55defe7df53604c91e6d050b36bd', '0 _shift_ws_before = tuotanto');
select pg_temp.ck(md5(pg_get_functiondef('public._shift_ws_after()'::regprocedure)) = '8fd938700e065df5ad84e2e43e7e2fcb', '0 _shift_ws_after = tuotanto');
select pg_temp.ck(md5(pg_get_functiondef('public.apply_calendar_changes_v2(uuid,jsonb,text,text,jsonb,text,boolean)'::regprocedure)) = 'db79abf5bbc39404752ff4de400da105', '0 apply_calendar_changes_v2 = tuotanto');

-- kiinnikkeet: tuotannon asetukset (db_first + push päällä, 8 yritystä), oma kalenterilähde, toistuva maanantaivuoro kuten 25.10.
update public.shift_sync_settings set db_first_enabled = true, push_enabled = true, push_max_attempts = 8 where id;
-- yksi lähde per skenaario: claim ottaa kaikki lähteen erääntyneet rivit (kuten tuotannossa), joten skenaariot eivät häiritse toisiaan
insert into public.calendar_sources (id, google_calendar_id, calendar_name, role_type)
select ('41200000-0000-0000-0000-00000000000' || n)::uuid, 'calsync412-' || n || '@group.calendar.google.com', 'Saunottaja-t412-' || n, 'heater'
  from generate_series(1, 6) n;

-- vuoro syntyy lukusynkasta (source=calendar, ei jonoa), sitten DB-muutos (source=bot) -> trigger -> shift_outbox
create function pg_temp.mkshift(p_n int, p_src int) returns uuid language plpgsql as $$
declare v uuid; s timestamptz := timestamptz '2026-11-02 09:00 Europe/Helsinki' + make_interval(days => 7 * p_n);
begin
  perform set_config('sipoo.shift_source', 'calendar', true);
  insert into public.work_shifts (google_event_id, calendar_source_id, calendar_title, role_type, starts_at, ends_at, google_updated_at,
                                  google_etag, status, staffing_status, google_recurring_event_id, original_start_at,
                                  cal_starts_at, cal_ends_at, cal_status)
  values ('ksenia_mon_' || to_char(s at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"'), ('41200000-0000-0000-0000-00000000000' || p_src)::uuid, 'Ksenia', 'heater',
          s, s + interval '6 hours', timestamptz '2026-10-25 12:00+00', '"series-etag-1"', 'active', 'unresolved', 'ksenia_mon', s,
          s, s + interval '6 hours', 'active')
  returning id into v;
  perform set_config('sipoo.shift_source', 'bot', true);
  update public.work_shifts set ends_at = starts_at + interval '7 hours' where id = v;   -- 09–15 -> 09–16
  perform set_config('sipoo.shift_source', '', true);
  return v;
end $$;
create function pg_temp.outbox_of(p_shift uuid) returns bigint language sql as $$
  select id from public.shift_outbox where shift_id = p_shift and status in ('pending','blocked','processing') order by id desc limit 1 $$;
-- claim kuten edge (p_limit 25, ei kuivaharjoitus); palauttaa itemin tälle riville
create function pg_temp.claim_one(p_id bigint) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.due(p_id);
  select e into v from jsonb_array_elements(public.shift_outbox_claim((select calendar_source_id from public.shift_outbox where id = p_id), 25, false)) e
   where (e ->> 'id')::bigint = p_id;
  return v;
end $$;

create temp table ids(k text primary key, shift uuid, ob bigint);
insert into ids select 'a', s, pg_temp.outbox_of(s) from pg_temp.mkshift(0, 1) s;
insert into ids select 'b', s, pg_temp.outbox_of(s) from pg_temp.mkshift(1, 2) s;
insert into ids select 'c', s, pg_temp.outbox_of(s) from pg_temp.mkshift(2, 3) s;
insert into ids select 'd', s, pg_temp.outbox_of(s) from pg_temp.mkshift(3, 4) s;
insert into ids select 'e', s, pg_temp.outbox_of(s) from pg_temp.mkshift(4, 5) s;
insert into ids select 'g', s, pg_temp.outbox_of(s) from pg_temp.mkshift(5, 6) s;
select pg_temp.ck((select count(*) from ids where ob is not null) = 6, 'kiinnike: trigger loi 6 jonoriviä');
select pg_temp.ck((select bool_and(o.status = 'pending' and o.attempts = 0 and o.conflict_attempts = 0) from ids join public.shift_outbox o on o.id = ids.ob), 'kiinnike: pending, attempts 0, conflict_attempts 0');

-- F claim: mirror ja etag
create temp table it as select pg_temp.claim_one((select ob from ids where k = 'a')) as j;
select pg_temp.ck((select j ->> 'op' = 'patch' and (j ->> 'recurring')::boolean and j ->> 'etag' = '"series-etag-1"' and (j ->> 'attempt')::int = 1 from it), 'F claim: patch, recurring, tallennettu etag, attempt 1');
select pg_temp.ck((select j -> 'mirror' ->> 'title' = 'Ksenia'
                          and (j -> 'mirror' ->> 'starts_at')::timestamptz = timestamptz '2026-11-02 09:00 Europe/Helsinki'
                          and (j -> 'mirror' ->> 'ends_at')::timestamptz = timestamptz '2026-11-02 15:00 Europe/Helsinki'
                          and j -> 'mirror' ->> 'status' = 'active'
                          and (j -> 'mirror' ->> 'updated')::timestamptz = timestamptz '2026-10-25 12:00+00'
                          and (j ->> 'ends_at')::timestamptz = timestamptz '2026-11-02 16:00 Europe/Helsinki' from it), 'F claim: mirror = cal_* + google_updated_at, tavoite 16:00');
select pg_temp.ck((select (request -> 'mirror') is not null and status = 'processing' and attempts = 1 from public.shift_outbox where id = (select ob from ids where k = 'a')), 'F claim: request tallentaa mirrorin, processing, attempts 1');

-- A 412 ei kuluta yritystä
select public.shift_outbox_fail((select ob from ids where k = 'a'), 'google_http_412', false, true, false);
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'a'))).status = 'pending', 'A 412 -> pending');
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'a'))).attempts = 0, 'A 412 -> attempts palautuu 0:aan');
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'a'))).conflict_attempts = 1, 'A 412 -> conflict_attempts 1');
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'a'))).next_attempt_at between now() + interval '59 seconds' and now() + interval '61 seconds', 'A 412 -> uusi yritys 1 min');
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'a'))).last_error = 'google_http_412' and (pg_temp.ob((select ob from ids where k = 'a'))).locked_at is null, 'A 412 -> last_error, lukko vapaa');
select pg_temp.ck((select google_etag is null and push_error is null from public.work_shifts where id = (select shift from ids where k = 'a')), 'A 412 -> work_shifts.google_etag tyhjä, push_error ei asetettu');
select pg_temp.ck(not exists (select 1 from public.shift_sync_conflicts where shift_id = (select shift from ids where k = 'a')), 'A 412 -> ei konfliktiriviä');
select pg_temp.ck((select db_version > pushed_version from public.work_shifts where id = (select shift from ids where k = 'a')), 'A 412 -> vuoro yhä viemättä');
-- F seuraava claim: etag null (edge hakee tuoreen), attempt taas 1
truncate it; insert into it select pg_temp.claim_one((select ob from ids where k = 'a'));
select pg_temp.ck((select j -> 'etag' = 'null'::jsonb and (j ->> 'attempt')::int = 1 from it), 'F claim 412:n jälkeen: etag null, attempt 1');

-- B porrastus ja turvaraja: konfliktit 2..23 pending (1 min kunnes 3, sitten 10 min), 24. -> error
do $$
declare v_ob bigint := (select ob from ids where k = 'a'); o public.shift_outbox; n int;
begin
  for n in 2..23 loop
    if n > 2 then perform pg_temp.claim_one(v_ob); end if;   -- n = 2: claim tehty jo yllä
    perform public.shift_outbox_fail(v_ob, 'google_http_412', false, true, false);
    o := pg_temp.ob(v_ob);
    if o.status <> 'pending' or o.attempts <> 0 or o.conflict_attempts <> n then
      raise exception 'B kierros %: % % %', n, o.status, o.attempts, o.conflict_attempts;
    end if;
    if n <= 3 and o.next_attempt_at > now() + interval '61 seconds' then raise exception 'B kierros %: odotettiin 1 min', n; end if;
    if n >= 4 and o.next_attempt_at not between now() + interval '599 seconds' and now() + interval '601 seconds' then
      raise exception 'B kierros %: odotettiin 10 min, %', n, o.next_attempt_at - now();
    end if;
  end loop;
end $$;
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'a'))).conflict_attempts = 23 and (pg_temp.ob((select ob from ids where k = 'a'))).status = 'pending', 'B 23 konfliktia: yhä pending (ei 8 yrityksen rajaa)');
select pg_temp.ck(not exists (select 1 from public.shift_sync_conflicts where shift_id = (select shift from ids where k = 'a')), 'B 23 konfliktia: ei konfliktiriviä');
select pg_temp.claim_one((select ob from ids where k = 'a'));
select public.shift_outbox_fail((select ob from ids where k = 'a'), 'google_http_412', false, true, false);
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'a'))).status = 'error' and (pg_temp.ob((select ob from ids where k = 'a'))).conflict_attempts = 24
                  and (pg_temp.ob((select ob from ids where k = 'a'))).attempts = 0 and (pg_temp.ob((select ob from ids where k = 'a'))).processed_at is not null, 'B 24. konflikti -> error (turvaraja)');
select pg_temp.ck((select count(*) = 1 and bool_and(kind = 'push_failed' and winner = 'none' and details ->> 'reason' = 'conflict_cap'
                          and (details ->> 'conflict_attempts')::int = 24 and (details ->> 'attempts')::int = 0 and db_state ? 'mirror')
                     from public.shift_sync_conflicts where shift_id = (select shift from ids where k = 'a')), 'B turvaraja -> yksi push_failed (conflict_cap)');
select pg_temp.ck((select push_error = 'google_http_412' from public.work_shifts where id = (select shift from ids where k = 'a')), 'B turvaraja -> push_error');
select pg_temp.ck(pg_temp.claim_one((select ob from ids where k = 'a')) is null, 'B error-riviä ei enää claimata');

-- C konflikti yrityskaton kohdalla: vanha koodi teki errorin, nyt pending
update public.shift_outbox set attempts = 7 where id = (select ob from ids where k = 'b');
select pg_temp.ck((pg_temp.claim_one((select ob from ids where k = 'b')) ->> 'attempt')::int = 8, 'C claim -> 8. yritys');
select public.shift_outbox_fail((select ob from ids where k = 'b'), 'google_http_412', false, true, false);
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'b'))).status = 'pending' and (pg_temp.ob((select ob from ids where k = 'b'))).attempts = 7, 'C 412 8. yrityksellä -> pending, attempts 7');
select pg_temp.ck(not exists (select 1 from public.shift_sync_conflicts where shift_id = (select shift from ids where k = 'b')), 'C ei push_failed-riviä');

-- D tavallinen virhe kuluttaa yrityksen kuten ennen; konfliktit välissä eivät
select pg_temp.claim_one((select ob from ids where k = 'c'));
select public.shift_outbox_fail((select ob from ids where k = 'c'), 'google_http_500', false, false, false);
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'c'))).attempts = 1 and (pg_temp.ob((select ob from ids where k = 'c'))).conflict_attempts = 0
                  and (pg_temp.ob((select ob from ids where k = 'c'))).next_attempt_at between now() + interval '299 seconds' and now() + interval '301 seconds', 'D 500 -> attempts 1, 5 min');
select pg_temp.ck((select google_etag = '"series-etag-1"' from public.work_shifts where id = (select shift from ids where k = 'c')), 'D 500 -> etag ennallaan');
do $$
declare v_ob bigint := (select ob from ids where k = 'c'); n int;
begin
  for n in 2..7 loop
    perform pg_temp.claim_one(v_ob);
    perform public.shift_outbox_fail(v_ob, 'google_http_412', false, true, false);   -- konflikti välissä
    perform pg_temp.claim_one(v_ob);
    perform public.shift_outbox_fail(v_ob, 'google_http_500', false, false, false);
  end loop;
end $$;
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'c'))).status = 'pending' and (pg_temp.ob((select ob from ids where k = 'c'))).attempts = 7
                  and (pg_temp.ob((select ob from ids where k = 'c'))).conflict_attempts = 6, 'D 7 virhettä + 6 konfliktia -> pending, attempts 7');
select pg_temp.claim_one((select ob from ids where k = 'c'));
select public.shift_outbox_fail((select ob from ids where k = 'c'), 'google_http_500', false, false, false);
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'c'))).status = 'error', 'D 8. tavallinen virhe -> error');
select pg_temp.ck((select count(*) = 1 and bool_and(kind = 'push_failed' and (details ->> 'attempts')::int = 8 and not details ? 'reason')
                     from public.shift_sync_conflicts where shift_id = (select shift from ids where k = 'c')), 'D push_failed attempts 8 (ei conflict_cap)');

-- E p_missing ja p_blocked ennallaan
select pg_temp.claim_one((select ob from ids where k = 'd'));
select public.shift_outbox_fail((select ob from ids where k = 'd'), 'no_write_access', true, false, false);
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'd'))).status = 'blocked' and (pg_temp.ob((select ob from ids where k = 'd'))).attempts = 1
                  and (pg_temp.ob((select ob from ids where k = 'd'))).next_attempt_at between now() + interval '3599 seconds' and now() + interval '3601 seconds', 'E blocked -> 1 h, attempts 1');
select pg_temp.ck((select google_etag = '"series-etag-1"' from public.work_shifts where id = (select shift from ids where k = 'd')), 'E blocked -> etag ennallaan');
select pg_temp.claim_one((select ob from ids where k = 'e'));
select public.shift_outbox_fail((select ob from ids where k = 'e'), 'google_http_404_notFound', false, false, true);
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'e'))).status = 'error', 'E missing -> error');
select pg_temp.ck((select count(*) = 1 and bool_and(kind = 'push_target_missing') from public.shift_sync_conflicts where shift_id = (select shift from ids where k = 'e')), 'E missing -> push_target_missing');
-- missing voittaa conflictin (sama järjestys kuin ennen: missing ennen konfliktia)
select pg_temp.claim_one((select ob from ids where k = 'd'));
select public.shift_outbox_fail((select ob from ids where k = 'd'), 'x', false, true, true);
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'd'))).status = 'error' and (pg_temp.ob((select ob from ids where k = 'd'))).conflict_attempts = 0, 'E missing + conflict -> error (missing)');

-- G complete 412:n jälkeen: tuore etag talteen, done
select pg_temp.claim_one((select ob from ids where k = 'g'));
select public.shift_outbox_fail((select ob from ids where k = 'g'), 'google_http_412', false, true, false);
select pg_temp.claim_one((select ob from ids where k = 'g'));
select public.shift_outbox_complete((select ob from ids where k = 'g'), 'converged', timestamptz '2026-10-25 13:34:47+00', '"fresh-etag"');
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'g'))).status = 'done' and (pg_temp.ob((select ob from ids where k = 'g'))).result = 'converged', 'G complete converged -> done');
select pg_temp.ck((select google_etag = '"fresh-etag"' and pushed_version = db_version and cal_ends_at = ends_at and push_error is null
                     from public.work_shifts where id = (select shift from ids where k = 'g')), 'G tuore etag + peili = tavoite + pushed_version');
select pg_temp.ck((select count(*) = 0 from public.shift_outbox where shift_id = (select shift from ids where k = 'g') and status in ('pending','processing')), 'G ei uutta jonoriviä');

-- H oikeudet
select pg_temp.ck(pg_temp.state('select public.shift_outbox_fail(1, ''x'', false, true, false)', 'anon') = '42501', 'H anon -> 42501');
select pg_temp.ck(pg_temp.state('select public.shift_outbox_fail(1, ''x'', false, true, false)', 'authenticated') = '42501', 'H authenticated -> 42501');
select pg_temp.ck(pg_temp.state('select public.shift_outbox_claim(''41200000-0000-0000-0000-000000000001'', 25, true)', 'anon') = '42501', 'H anon claim -> 42501');
select pg_temp.ck(pg_temp.state('select public.shift_outbox_fail(-1, ''x'', false, true, false)', 'service_role') = '00000', 'H service_role + tuntematon id -> ok');

-- I rajoitteet ja tuntematon id
select pg_temp.ck(pg_temp.state('update public.shift_outbox set conflict_attempts = null where id = ' || (select ob from ids where k = 'b')) = '23502', 'I conflict_attempts NOT NULL -> 23502');
select pg_temp.ck(pg_temp.state('select public.shift_outbox_fail(-1, ''x'')') = '00000', 'I tuntematon id -> ei virhettä');
select pg_temp.ck(pg_temp.state('select public.shift_outbox_claim(''41200000-0000-0000-0000-0000000000ff'', 25, false)') = 'P0001', 'I claim tuntematon lähde -> P0001');

-- J rollback -> tuotannon md5:t, sarake pois; migraatio uudelleen -> uudet md5:t; toinen ajo -> guard P0001
\ir ../../rollbacks/20261025160000_calsync412_outbox_412_ROLLBACK.sql
select pg_temp.ck(md5(pg_get_functiondef('public.shift_outbox_fail(bigint,text,boolean,boolean,boolean)'::regprocedure)) = '18ff3b26879cbd1a271dd5d4ab43f164', 'J rollback: fail = tuotanto');
select pg_temp.ck(md5(pg_get_functiondef('public.shift_outbox_claim(uuid,integer,boolean)'::regprocedure)) = '68a6d646f7606faef829b8990ce84031', 'J rollback: claim = tuotanto');
select pg_temp.ck(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'shift_outbox' and column_name = 'conflict_attempts'), 'J rollback: sarake poistettu');
-- vanha käytös palautui: 412 kuluttaa yrityksen
select pg_temp.claim_one((select ob from ids where k = 'b'));
select public.shift_outbox_fail((select ob from ids where k = 'b'), 'google_http_412', false, true, false);
select pg_temp.ck((pg_temp.ob((select ob from ids where k = 'b'))).status = 'error', 'J rollback: vanha käytös (412 8. yrityksellä -> error)');
\ir ../../migrations/20261025160000_calsync412_outbox_412.sql
select pg_temp.ck(md5(pg_get_functiondef('public.shift_outbox_fail(bigint,text,boolean,boolean,boolean)'::regprocedure)) = '4058beac69368354d2ff55aebc491653', 'J migraatio uudelleen: fail');
select pg_temp.ck(md5(pg_get_functiondef('public.shift_outbox_claim(uuid,integer,boolean)'::regprocedure)) = '72f2467fa9561a727795e16564bf4496', 'J migraatio uudelleen: claim');
-- guard-lohkot tiedostoista sellaisenaan (ensimmäinen do $g$ … end $g$; -lohko)
\set mig_guard `awk '/^do \$g\$/{f=1} f{print} /^end \$g\$;/{if(f)exit}' ../../migrations/20261025160000_calsync412_outbox_412.sql`
\set rb_guard `awk '/^do \$g\$/{f=1} f{print} /^end \$g\$;/{if(f)exit}' ../../rollbacks/20261025160000_calsync412_outbox_412_ROLLBACK.sql`
select pg_temp.ck(pg_temp.state(:'mig_guard') = 'P0001', 'J migraation guard toisella ajolla -> P0001 (ei muutoksia)');
select pg_temp.ck(pg_temp.state(:'rb_guard') = '00000', 'J rollbackin guard hyväksyy migraation jälkeisen tilan');
select pg_temp.ck(position('md5(pg_get_functiondef' in :'mig_guard') > 0 and position('18ff3b26879cbd1a271dd5d4ab43f164' in :'mig_guard') > 0, 'J guard-lohko luettu tiedostosta');

-- tulos: kumoa kaikki
do $$
declare p int; f int; l text;
begin
  select count(*) filter (where ok), count(*) filter (where not ok), string_agg(label, '; ') filter (where not ok) into p, f, l from tr;
  raise notice 'TESTRESULT pass=% fail=%', p, f;
  if f > 0 then raise exception 'TESTRESULT pass=% fail=% :: %', p, f, l; end if;
  raise exception 'TESTRESULT pass=% fail=0 (rollback)', p using errcode = 'TRBK0';
end $$;
