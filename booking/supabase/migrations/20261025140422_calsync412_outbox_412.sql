-- calsync412 (25.10.2026): Google 412 / jaettu sarjan etag ei saa kuluttaa vientiyrityksiä. versio 20261025140422:
-- ajettu tuotantoon 25.10.2026 (schema_migrations 20261025140422, guardit täsmäsivät); tiedosto nimetty todelliseen versioon (history sync).
-- Tausta: toistuvan sarjan muuttamattomat instanssit jakavat sarjan etagin (tuotanto: 887 tulevaa instanssia, 29 etagia; 53 instanssin sarja,
-- 1 etag). Jokainen instanssi-PATCH vaihtaa sisarten etagin -> 412 -> shift_outbox_fail(p_conflict) -> 1 min ja attempts kasvaa -> 8. yrityksen
-- jälkeen error (25.10.: 48/52 maanantaivuoroa, outbox 126–175, shift_sync_conflicts 1–48).
--   * public.shift_outbox.conflict_attempts (uusi sarake, int not null default 0): 412-/konfliktikerrat erikseen.
--   * shift_outbox_fail: p_conflict käsitellään ENNEN push_max_attempts-tarkistusta; claimin attempts+1 palautetaan (attempts - 1, min 0),
--     conflict_attempts + 1, uusi yritys 1 min (3 ensimmäistä) ja sitten 10 min (= calendar-sync-incremental-10m-väli, jolloin lukusynkka ehtii
--     päivittää peilin ja etagin). Turvaraja: 24. konflikti -> error + shift_sync_conflicts push_failed (details.reason = conflict_cap),
--     n. 3 + 21 x 10 min = ~3,5 h ja yli 20 lukusynkkaa: jos konflikti ei ratkea niissä, vika on systemaattinen (esim. jatkuva ulkoinen kirjoittaja)
--     eikä sitä pidä yrittää loputtomiin. p_conflict tyhjentää work_shifts.google_etag (ei lähetetä samaa vanhaa etagia uudelleen;
--     edge (v7, head 258872ad) hakee tuoreen etagin ennen kirjoitusta). p_blocked / p_missing / muut virheet: kuten ennen.
--   * shift_outbox_claim: itemiin lisätään 'mirror' (calendar_title, cal_starts_at, cal_ends_at, cal_status, google_updated_at),
--     jotta edge erottaa ihmisen muutoksen (kentät eroavat peilistä ja tavoitteesta) pelkästä etagin vaihtumisesta. Muuten ennallaan.
--     Vanha edge (v5) ohittaa tuntemattoman avaimen.
--   muutetut funktiot (tuotanto sxbofnuisemspgquoxyv ennen, luettu SELECTillä 25.10.2026 -> tämän jälkeen):
--     public.shift_outbox_claim(uuid,integer,boolean): 68a6d646f7606faef829b8990ce84031 -> 72f2467fa9561a727795e16564bf4496
--     public.shift_outbox_fail(bigint,text,boolean,boolean,boolean): 18ff3b26879cbd1a271dd5d4ab43f164 -> 4058beac69368354d2ff55aebc491653
--   riippuvuudet, ei muuteta (tuotanto = vaadittu):
--     public.shift_outbox_complete(bigint,text,timestamptz,text) 59338520abe08983748b9020736fcab7
--     public._shift_enqueue(uuid) 6ee44c5badf73a180a4ff673c1ad5be9
--     public._shift_desired_title(uuid) 7d374c0c379f4e70a281570dfcdf5599
--     public._shift_title_norm(text) ef6a215bdbbbfaa7773482109de590cb
--     public.apply_calendar_changes_v2(uuid,jsonb,text,text,jsonb,text,boolean) db79abf5bbc39404752ff4de400da105
-- Rollback: rollbacks/20261025140422_calsync412_outbox_412_ROLLBACK.sql. Testi: tests/calendar/tcalsync412_shift_outbox_fail.sql (BEGIN … ROLLBACK).
-- Ajojärjestys: SHIFT_PUSH_DISABLED=1 -> tämä migraatio -> calendar-sync-v2 deploy (tuotannossa v7) -> SHIFT_PUSH_DISABLED pois (ks. PR).
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_outbox_claim(uuid,integer,boolean)')));
  if v is null or v <> '68a6d646f7606faef829b8990ce84031' then ok := false; msg := msg || ' shift_outbox_claim=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_outbox_fail(bigint,text,boolean,boolean,boolean)')));
  if v is null or v <> '18ff3b26879cbd1a271dd5d4ab43f164' then ok := false; msg := msg || ' shift_outbox_fail=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_outbox_complete(bigint,text,timestamptz,text)')));
  if v is null or v <> '59338520abe08983748b9020736fcab7' then ok := false; msg := msg || ' shift_outbox_complete=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public._shift_enqueue(uuid)')));
  if v is null or v <> '6ee44c5badf73a180a4ff673c1ad5be9' then ok := false; msg := msg || ' _shift_enqueue=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public._shift_desired_title(uuid)')));
  if v is null or v <> '7d374c0c379f4e70a281570dfcdf5599' then ok := false; msg := msg || ' _shift_desired_title=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public._shift_title_norm(text)')));
  if v is null or v <> 'ef6a215bdbbbfaa7773482109de590cb' then ok := false; msg := msg || ' _shift_title_norm=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.apply_calendar_changes_v2(uuid,jsonb,text,text,jsonb,text,boolean)')));
  if v is null or v <> 'db79abf5bbc39404752ff4de400da105' then ok := false; msg := msg || ' apply_calendar_changes_v2=' || coalesce(v, 'puuttuu'); end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'shift_outbox' and column_name = 'conflict_attempts') then
    ok := false; msg := msg || ' shift_outbox.conflict_attempts on jo olemassa';
  end if;
  if not ok then raise exception 'calsync412: tuotannon määrittelyt eivät vastaa odotettua:%. Ei muutoksia.', msg; end if;
end $g$;

alter table public.shift_outbox add column conflict_attempts integer not null default 0;
comment on column public.shift_outbox.conflict_attempts is
  'calsync412: 412-/konfliktikerrat (eivät kuluta attempts-yrityksiä). shift_outbox_fail: katto 24 -> error + push_failed (conflict_cap).';

CREATE OR REPLACE FUNCTION public.shift_outbox_claim(p_calendar_source_id uuid, p_limit integer DEFAULT 25, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r     public.shift_outbox;
  w     public.work_shifts%rowtype;
  c     public.calendar_sources%rowtype;
  v_ids bigint[];
  v_out jsonb := '[]'::jsonb;
  v_op  text; v_title text; v_tc boolean; v_mc boolean; v_item jsonb; v_skip text;
begin
  select * into c from public.calendar_sources where id = p_calendar_source_id;
  if not found then raise exception 'unknown calendar source %', p_calendar_source_id; end if;
  if not p_dry_run then
    perform set_config('sipoo.shift_source', 'push', true);
    delete from public.shift_outbox where status in ('done','skipped') and processed_at < now() - interval '60 days';
  end if;
  select coalesce(array_agg(q.id order by q.id), '{}') into v_ids from (
    select o.id from public.shift_outbox o
     where o.calendar_source_id = p_calendar_source_id
       and ((o.status in ('pending','blocked') and o.next_attempt_at <= now())
            or (o.status = 'processing' and o.locked_at < now() - interval '10 minutes'))
     order by o.id limit greatest(1, least(coalesce(p_limit, 25), 100))
     for update skip locked) q;

  for r in select * from public.shift_outbox where id = any (v_ids) order by id loop
    v_skip := null; v_op := null;
    select * into w from public.work_shifts where id = r.shift_id for update;
    if not found then v_skip := 'shift_gone';
    elsif w.db_version <= w.pushed_version then v_skip := 'already_synced';
    elsif w.status = 'cancelled' then
      if w.google_updated_at is null and w.google_recurring_event_id is null then v_skip := 'never_pushed';
      elsif w.cal_status = 'cancelled' then v_skip := 'already_cancelled';
      else v_op := 'delete'; end if;
    elsif w.google_updated_at is null and w.google_recurring_event_id is null then v_op := 'insert';
    else v_op := 'patch';
    end if;

    if v_op is not null then
      v_title := public._shift_desired_title(w.id);
      v_tc := public._shift_title_norm(v_title) is distinct from public._shift_title_norm(w.calendar_title);
      v_mc := (w.starts_at, w.ends_at) is distinct from (w.cal_starts_at, w.cal_ends_at);
      if v_op = 'patch' and not v_tc and not v_mc and coalesce(w.cal_status, 'active') = 'active' then
        v_skip := 'unchanged'; v_op := null;   -- esim. lisättiin ja poistettiin sama henkilö
      end if;
    end if;

    if v_skip is not null then
      if not p_dry_run then
        if w.id is not null and v_skip in ('never_pushed','already_cancelled','unchanged') then
          update public.work_shifts set pushed_version = db_version where id = w.id;
        end if;
        update public.shift_outbox set status = 'skipped', result = v_skip, processed_at = now(), locked_at = null where id = r.id;
      end if;
      continue;
    end if;

    v_item := jsonb_build_object(
      'id', r.id, 'op', v_op, 'shift_id', w.id, 'version', w.db_version,
      'google_calendar_id', c.google_calendar_id, 'calendar_name', c.calendar_name, 'event_id', w.google_event_id,
      'etag', w.google_etag, 'timezone', 'Europe/Helsinki', 'summary', v_title,
      'starts_at', w.starts_at, 'ends_at', w.ends_at, 'title_changed', v_tc, 'time_changed', v_mc,
      'reactivate', v_op = 'patch' and w.cal_status = 'cancelled',
      'recurring', w.google_recurring_event_id is not null, 'attempt', r.attempts + 1,
      -- calsync412: peilitila (viimeksi luettu / kirjoitettu) 412-luokittelua varten
      'mirror', jsonb_build_object('title', w.calendar_title, 'starts_at', w.cal_starts_at, 'ends_at', w.cal_ends_at,
                                   'status', w.cal_status, 'updated', w.google_updated_at));
    if not p_dry_run then
      update public.shift_outbox set status = 'processing', attempts = attempts + 1, locked_at = now(),
             shift_version = w.db_version, g_op = v_op, request = v_item
       where id = r.id;
    end if;
    v_out := v_out || v_item;
  end loop;
  return v_out;
end $function$;

CREATE OR REPLACE FUNCTION public.shift_outbox_fail(p_id bigint, p_error text, p_blocked boolean DEFAULT false, p_conflict boolean DEFAULT false, p_missing boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- p_conflict = Google 412 (If-Match ei täsmää) tai edge havaitsi ihmisen muutoksen ennen kirjoitusta.
-- calsync412: konflikti EI kuluta push_max_attempts-yrityksiä (claimin lisäys palautetaan), vaan omaa conflict_attempts-laskuria
-- (katto 24: 3 x 1 min, sitten 10 min = lukusynkan väli -> n. 3,5 h ja >= 20 lukusynkkaa). Katon jälkeen error + push_failed.
-- 412:ssa work_shifts.google_etag tyhjennetään: vanhaa etagia ei lähetetä uudelleen; edge hakee tuoreen etagin (GET) ennen kirjoitusta.
declare r public.shift_outbox; v_max int; v_conflict_cap constant int := 24;
begin
  perform set_config('sipoo.shift_source', 'push', true);
  select * into r from public.shift_outbox where id = p_id for update;
  if not found then return; end if;
  select s.push_max_attempts into v_max from public.shift_sync_settings s where s.id;
  if p_blocked then
    update public.shift_outbox set status = 'blocked', last_error = left(p_error, 200), next_attempt_at = now() + interval '1 hour', locked_at = null where id = p_id;
  elsif p_missing then
    update public.shift_outbox set status = 'error', last_error = left(p_error, 200), locked_at = null, processed_at = now() where id = p_id;
    update public.work_shifts set push_error = left(p_error, 200) where id = r.shift_id;
    insert into public.shift_sync_conflicts (shift_id, kind, winner, db_state, details)
    values (r.shift_id, 'push_target_missing', 'none', r.request,
            jsonb_build_object('error', left(p_error, 200), 'attempts', r.attempts, 'outbox_id', r.id));
  elsif p_conflict then
    update public.work_shifts set google_etag = null where id = r.shift_id and google_etag is not null;
    if r.conflict_attempts + 1 >= v_conflict_cap then
      update public.shift_outbox set status = 'error', last_error = left(p_error, 200), locked_at = null, processed_at = now(),
             attempts = greatest(r.attempts - 1, 0), conflict_attempts = r.conflict_attempts + 1 where id = p_id;
      update public.work_shifts set push_error = left(p_error, 200) where id = r.shift_id;
      insert into public.shift_sync_conflicts (shift_id, kind, winner, db_state, details)
      values (r.shift_id, 'push_failed', 'none', r.request,
              jsonb_build_object('error', left(p_error, 200), 'attempts', greatest(r.attempts - 1, 0), 'conflict_attempts', r.conflict_attempts + 1,
                                 'reason', 'conflict_cap', 'outbox_id', r.id));
    else
      update public.shift_outbox set status = 'pending', last_error = left(p_error, 200), locked_at = null,
             attempts = greatest(r.attempts - 1, 0), conflict_attempts = r.conflict_attempts + 1,
             next_attempt_at = now() + case when r.conflict_attempts < 3 then interval '1 minute' else interval '10 minutes' end
       where id = p_id;
    end if;
  elsif r.attempts >= coalesce(v_max, 8) then
    update public.shift_outbox set status = 'error', last_error = left(p_error, 200), locked_at = null, processed_at = now() where id = p_id;
    update public.work_shifts set push_error = left(p_error, 200) where id = r.shift_id;
    insert into public.shift_sync_conflicts (shift_id, kind, winner, db_state, details)
    values (r.shift_id, 'push_failed', 'none', r.request,
            jsonb_build_object('error', left(p_error, 200), 'attempts', r.attempts, 'outbox_id', r.id));
  else
    update public.shift_outbox set status = 'pending', last_error = left(p_error, 200), locked_at = null,
           next_attempt_at = now() + make_interval(mins => least(360, 5 * r.attempts * r.attempts)) where id = p_id;
  end if;
end $function$;

do $g$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_outbox_claim(uuid,integer,boolean)')));
  if v is distinct from '72f2467fa9561a727795e16564bf4496' then raise exception 'calsync412: shift_outbox_claim md5 % <> 72f2467fa9561a727795e16564bf4496', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_outbox_fail(bigint,text,boolean,boolean,boolean)')));
  if v is distinct from '4058beac69368354d2ff55aebc491653' then raise exception 'calsync412: shift_outbox_fail md5 % <> 4058beac69368354d2ff55aebc491653', v; end if;
  if not has_function_privilege('service_role', 'public.shift_outbox_claim(uuid,integer,boolean)', 'execute') or has_function_privilege('anon', 'public.shift_outbox_claim(uuid,integer,boolean)', 'execute')
     or has_function_privilege('authenticated', 'public.shift_outbox_claim(uuid,integer,boolean)', 'execute') then
    raise exception 'calsync412: public.shift_outbox_claim(uuid,integer,boolean) oikeudet muuttuivat';
  end if;
  if not has_function_privilege('service_role', 'public.shift_outbox_fail(bigint,text,boolean,boolean,boolean)', 'execute') or has_function_privilege('anon', 'public.shift_outbox_fail(bigint,text,boolean,boolean,boolean)', 'execute')
     or has_function_privilege('authenticated', 'public.shift_outbox_fail(bigint,text,boolean,boolean,boolean)', 'execute') then
    raise exception 'calsync412: public.shift_outbox_fail(bigint,text,boolean,boolean,boolean) oikeudet muuttuivat';
  end if;
end $g$;
