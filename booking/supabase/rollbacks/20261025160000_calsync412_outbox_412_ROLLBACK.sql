-- calsync412 ROLLBACK: palauttaa shift_outbox_claim- ja shift_outbox_fail-funktiot täsmälleen tuotannon tilaan ennen 20261025160000:aa
-- ja poistaa sarakkeen public.shift_outbox.conflict_attempts (laskurin arvot häviävät).
--   public.shift_outbox_claim(uuid,integer,boolean): 72f2467fa9561a727795e16564bf4496 -> 68a6d646f7606faef829b8990ce84031
--   public.shift_outbox_fail(bigint,text,boolean,boolean,boolean): 4058beac69368354d2ff55aebc491653 -> 18ff3b26879cbd1a271dd5d4ab43f164
-- Huom: shift_outbox.request-jsoniin jo tallennettu 'mirror'-avain jää riveille (vanha koodi ei lue sitä). Tyhjennettyjä google_etag-arvoja
-- ei palauteta: seuraava lukusynkka kirjoittaa ne uudelleen. Jos edge v6 on jo tuotannossa, palauta ensin v5 (tai pidä SHIFT_PUSH_DISABLED=1):
-- v6 toimii myös vanhan claimin kanssa (ilman peiliä ei esitarkistusta; 412 -> GET -> vain tavoitetila kuitataan, muuten conflict).
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_outbox_claim(uuid,integer,boolean)')));
  if v is null or v <> '72f2467fa9561a727795e16564bf4496' then ok := false; msg := msg || ' shift_outbox_claim=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_outbox_fail(bigint,text,boolean,boolean,boolean)')));
  if v is null or v <> '4058beac69368354d2ff55aebc491653' then ok := false; msg := msg || ' shift_outbox_fail=' || coalesce(v, 'puuttuu'); end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'shift_outbox' and column_name = 'conflict_attempts') then
    ok := false; msg := msg || ' shift_outbox.conflict_attempts puuttuu';
  end if;
  if not ok then raise exception 'calsync412 ROLLBACK: määrittelyt eivät vastaa 20261025160000:aa:%. Ei muutoksia.', msg; end if;
end $g$;

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
      'recurring', w.google_recurring_event_id is not null, 'attempt', r.attempts + 1);
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
declare r public.shift_outbox; v_max int;
begin
  perform set_config('sipoo.shift_source', 'push', true);
  select * into r from public.shift_outbox where id = p_id for update;
  if not found then return; end if;
  select s.push_max_attempts into v_max from public.shift_sync_settings s where s.id;
  if p_blocked then
    update public.shift_outbox set status = 'blocked', last_error = left(p_error, 200), next_attempt_at = now() + interval '1 hour', locked_at = null where id = p_id;
  elsif p_missing or r.attempts >= coalesce(v_max, 8) then
    update public.shift_outbox set status = 'error', last_error = left(p_error, 200), locked_at = null, processed_at = now() where id = p_id;
    update public.work_shifts set push_error = left(p_error, 200) where id = r.shift_id;
    insert into public.shift_sync_conflicts (shift_id, kind, winner, db_state, details)
    values (r.shift_id, case when p_missing then 'push_target_missing' else 'push_failed' end, 'none', r.request,
            jsonb_build_object('error', left(p_error, 200), 'attempts', r.attempts, 'outbox_id', r.id));
  elsif p_conflict then
    update public.shift_outbox set status = 'pending', last_error = left(p_error, 200), locked_at = null,
           next_attempt_at = now() + interval '1 minute' where id = p_id;
  else
    update public.shift_outbox set status = 'pending', last_error = left(p_error, 200), locked_at = null,
           next_attempt_at = now() + make_interval(mins => least(360, 5 * r.attempts * r.attempts)) where id = p_id;
  end if;
end $function$;

alter table public.shift_outbox drop column conflict_attempts;

do $g$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_outbox_claim(uuid,integer,boolean)')));
  if v is distinct from '68a6d646f7606faef829b8990ce84031' then raise exception 'calsync412 ROLLBACK: shift_outbox_claim md5 % <> 68a6d646f7606faef829b8990ce84031', v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_outbox_fail(bigint,text,boolean,boolean,boolean)')));
  if v is distinct from '18ff3b26879cbd1a271dd5d4ab43f164' then raise exception 'calsync412 ROLLBACK: shift_outbox_fail md5 % <> 18ff3b26879cbd1a271dd5d4ab43f164', v; end if;
  if not has_function_privilege('service_role', 'public.shift_outbox_claim(uuid,integer,boolean)', 'execute') or has_function_privilege('anon', 'public.shift_outbox_claim(uuid,integer,boolean)', 'execute')
     or has_function_privilege('authenticated', 'public.shift_outbox_claim(uuid,integer,boolean)', 'execute') then
    raise exception 'calsync412 ROLLBACK: public.shift_outbox_claim(uuid,integer,boolean) oikeudet muuttuivat';
  end if;
  if not has_function_privilege('service_role', 'public.shift_outbox_fail(bigint,text,boolean,boolean,boolean)', 'execute') or has_function_privilege('anon', 'public.shift_outbox_fail(bigint,text,boolean,boolean,boolean)', 'execute')
     or has_function_privilege('authenticated', 'public.shift_outbox_fail(bigint,text,boolean,boolean,boolean)', 'execute') then
    raise exception 'calsync412 ROLLBACK: public.shift_outbox_fail(bigint,text,boolean,boolean,boolean) oikeudet muuttuivat';
  end if;
end $g$;
