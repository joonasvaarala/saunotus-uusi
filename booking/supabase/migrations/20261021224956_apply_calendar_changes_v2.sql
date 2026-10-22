-- apply_calendar_changes_v2: kalenteri -> DB muutoksina (ei täyttä ylikirjoitusta), kaiunesto ja ristiriitakäsittely.
-- Sama allekirjoitus kuin v1 (public.apply_calendar_changes), joten calendar-sync-v2 voi kutsua sitä suoraan. v1 jää ennalleen (paluu).
--
-- Säännöt per tapahtuma (rivi = work_shifts calendar_source_id + google_event_id):
--  1. updated <= google_updated_at  -> jo nähty (oma vienti tai muuttumaton instanssi): ohitetaan (etag päivitetään).
--  2. Kalenterin muutos lasketaan peilitilaa vasten (calendar_title, cal_starts_at, cal_ends_at, cal_status):
--     * henkilöt: delta (lisätyt/poistetut nimet) sovelletaan DB:hen -> DB:n viemättömät henkilömuutokset säilyvät (merge)
--     * aika / tila: jos DB:ssä on viemätön muutos samaan kenttään -> uudempi voittaa (last_change_at vs. updated)
--  3. Jos rivillä oli viemätön muutos ja kalenteri muuttui -> shift_sync_conflicts-rivi (ilmoitettavaksi).
--  4. Jos DB ja kalenteri ovat yhdenmukaiset -> pushed_version = db_version ja odottava vienti ohitetaan ('converged').
--  5. Täsmäytys (full/series scope) ei peru rivejä, joilla on viemätön muutos.
create or replace function public.apply_calendar_changes_v2(
  p_source_id uuid, p_events jsonb, p_new_sync_token text, p_mode text default 'incremental',
  p_scopes jsonb default '[]'::jsonb, p_run_id text default null, p_dry_run boolean default false)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_role text; ev jsonb; sc jsonb;
  v_id text; v_title text; v_rec text; v_etag text;
  v_start timestamptz; v_end timestamptz; v_orig timestamptz; v_upd timestamptz;
  w public.work_shifts%rowtype; v_found boolean; v_pending boolean; v_db_newer boolean;
  v_status text; v_ids uuid[]; v_old_status text; v_old_ids uuid[];
  v_new_start timestamptz; v_new_end timestamptz; v_new_state text; v_staffing text; v_has boolean;
  v_adds uuid[]; v_removes uuid[]; x uuid;
  v_det jsonb; v_dbsnap jsonb; v_winner text; v_shift_id uuid; v_changed boolean;
  r record;
  c_created int := 0; c_changed int := 0; c_cancelled int := 0; c_reactivated int := 0; c_unchanged int := 0;
  c_echo int := 0; c_scope_cancelled int := 0; c_unresolved int := 0; c_conflicts int := 0; c_converged int := 0;
  c_kept_db int := 0; c_scope_kept int := 0;
  v_summary jsonb;
begin
  if p_mode not in ('incremental','full','recovery') then raise exception 'invalid mode %', p_mode; end if;
  if p_new_sync_token is null or btrim(p_new_sync_token) = '' then
    raise exception 'p_new_sync_token is required; the old token is kept on any failure';
  end if;
  select c.role_type into v_role from public.calendar_sources c where c.id = p_source_id and c.active;
  if not found then raise exception 'unknown or inactive calendar source %', p_source_id; end if;
  perform 1 from public.sync_state s where s.calendar_source_id = p_source_id for update;
  if not found then raise exception 'no sync_state row for %', p_source_id; end if;

  begin  -- sub-block: dry run rolls back everything but keeps the counters
    perform set_config('sipoo.shift_source', 'calendar', true);
    perform set_config('sipoo.shift_actor', 'calendar-sync-v2', true);
    perform set_config('sipoo.shift_run_id', coalesce(p_run_id, ''), true);
    create temp table if not exists _cal_seen_v2 (google_event_id text primary key) on commit drop;
    truncate pg_temp._cal_seen_v2;

    for ev in select value from jsonb_array_elements(coalesce(p_events, '[]'::jsonb)) loop
      v_id := ev->>'id';
      if v_id is null then raise exception 'event without id'; end if;
      insert into pg_temp._cal_seen_v2 values (v_id) on conflict do nothing;
      v_upd  := nullif(ev->>'updated', '')::timestamptz;
      v_etag := nullif(ev->>'etag', '');

      select * into w from public.work_shifts ws
       where ws.calendar_source_id = p_source_id and ws.google_event_id = v_id for update;
      v_found := found;
      v_pending := v_found and w.db_version > w.pushed_version;

      -- 1. jo nähty (oma vienti = kaiku, tai muuttumaton)
      if v_found and v_upd is not null and w.google_updated_at is not null and v_upd <= w.google_updated_at then
        if v_etag is not null and v_upd = w.google_updated_at and w.google_etag is distinct from v_etag then
          update public.work_shifts set google_etag = v_etag where id = w.id;
        end if;
        if ev->'extendedProperties'->'private'->>'sipoo_shift_id' is not null then c_echo := c_echo + 1; else c_unchanged := c_unchanged + 1; end if;
        continue;
      end if;

      v_db_newer := v_pending and w.last_change_at is not null and (v_upd is null or w.last_change_at > v_upd);
      v_dbsnap := case when v_found then jsonb_build_object('starts_at', w.starts_at, 'ends_at', w.ends_at, 'status', w.status,
                    'desired_title', public._shift_desired_title(w.id), 'last_change_at', w.last_change_at,
                    'last_change_source', w.last_change_source, 'db_version', w.db_version, 'pushed_version', w.pushed_version) end;

      -- 2a. poistettu / peruttu kalenterissa
      if ev->>'status' = 'cancelled' then
        if not v_found or (w.status = 'cancelled' and w.cal_status = 'cancelled') then
          if v_found then update public.work_shifts set google_updated_at = coalesce(v_upd, google_updated_at), last_synced_at = now() where id = w.id; end if;
          c_unchanged := c_unchanged + 1; continue;
        end if;
        if v_pending and v_db_newer and w.status = 'active' then
          -- DB:n muutos on uudempi kuin poisto -> DB voittaa, vienti palauttaa tapahtuman
          update public.work_shifts set cal_status = 'cancelled', google_updated_at = coalesce(v_upd, google_updated_at),
                 google_etag = coalesce(v_etag, google_etag), last_synced_at = now() where id = w.id;
          insert into public.shift_sync_conflicts (shift_id, kind, winner, db_state, calendar_state, details, run_id)
          values (w.id, 'deleted_in_calendar', 'db', v_dbsnap, jsonb_build_object('status', 'cancelled', 'updated', v_upd), '{"status":"db"}', p_run_id);
          c_conflicts := c_conflicts + 1; c_kept_db := c_kept_db + 1;
        else
          if v_pending then
            insert into public.shift_sync_conflicts (shift_id, kind, winner, db_state, calendar_state, details, run_id)
            values (w.id, 'deleted_in_calendar', 'calendar', v_dbsnap, jsonb_build_object('status', 'cancelled', 'updated', v_upd), '{"status":"calendar"}', p_run_id);
            c_conflicts := c_conflicts + 1;
            update public.shift_outbox set status = 'skipped', result = 'superseded_by_calendar', processed_at = now()
             where shift_id = w.id and status in ('pending','blocked');
          end if;
          update public.work_shifts
             set status = 'cancelled', cancelled_at = coalesce(cancelled_at, now()), cal_status = 'cancelled',
                 google_updated_at = coalesce(v_upd, google_updated_at), google_etag = coalesce(v_etag, google_etag),
                 last_synced_at = now(), pushed_version = db_version
           where id = w.id;
          if w.status <> 'cancelled' then c_cancelled := c_cancelled + 1; end if;
        end if;
        continue;
      end if;

      v_title := coalesce(ev->>'summary', '');
      v_start := coalesce((ev->'start'->>'dateTime')::timestamptz, ((ev->'start'->>'date')::date)::timestamp at time zone 'Europe/Helsinki');
      v_end   := coalesce((ev->'end'->>'dateTime')::timestamptz, ((ev->'end'->>'date')::date)::timestamp at time zone 'Europe/Helsinki');
      if v_start is null then raise exception 'event % has no start', v_id; end if;
      v_rec  := ev->>'recurringEventId';
      v_orig := coalesce((ev->'originalStartTime'->>'dateTime')::timestamptz,
                         ((ev->'originalStartTime'->>'date')::date)::timestamp at time zone 'Europe/Helsinki');
      select p.staffing_status, p.staff_ids into v_status, v_ids from public.parse_shift_title(v_title) p;
      if v_status = 'unresolved' then c_unresolved := c_unresolved + 1; end if;

      -- 2b. uusi tapahtuma kalenterissa
      if not v_found then
        insert into public.work_shifts (google_event_id, calendar_source_id, calendar_title, role_type, starts_at, ends_at,
                                        google_updated_at, google_etag, last_synced_at, status, staffing_status,
                                        google_recurring_event_id, original_start_at, cal_starts_at, cal_ends_at, cal_status)
        values (v_id, p_source_id, v_title, v_role, v_start, v_end, v_upd, v_etag, now(), 'active', v_status,
                v_rec, v_orig, v_start, v_end, 'active')
        returning id into v_shift_id;
        insert into public.shift_assignments (shift_id, staff_id, status, source)
        select v_shift_id, u, 'assigned', 'calendar' from unnest(v_ids) u
        on conflict (shift_id, staff_id) do nothing;
        c_created := c_created + 1;
        continue;
      end if;

      -- 2c. muuttunut tapahtuma: kenttäkohtainen yhdistäminen peilitilaa vasten
      v_det := '{}'::jsonb; v_changed := false;
      select p.staffing_status, p.staff_ids into v_old_status, v_old_ids from public.parse_shift_title(w.calendar_title) p;

      v_new_start := w.starts_at; v_new_end := w.ends_at;
      if (v_start, v_end) is distinct from (w.cal_starts_at, w.cal_ends_at) then
        v_changed := true;
        if v_pending and (w.starts_at, w.ends_at) is distinct from (w.cal_starts_at, w.cal_ends_at) then
          if v_db_newer then v_det := v_det || '{"time":"db"}';
          else v_new_start := v_start; v_new_end := v_end; v_det := v_det || '{"time":"calendar"}'; end if;
        else
          v_new_start := v_start; v_new_end := v_end;
        end if;
      end if;

      v_new_state := w.status;
      if coalesce(w.cal_status, 'active') = 'cancelled' then   -- kalenterissa palautettu
        v_changed := true;
        if v_pending and w.status = 'cancelled' and v_db_newer then v_det := v_det || '{"status":"db"}';
        else
          if w.status = 'cancelled' then v_new_state := 'active'; c_reactivated := c_reactivated + 1; end if;
          if v_pending and w.status = 'cancelled' then v_det := v_det || '{"status":"calendar"}'; end if;
        end if;
      end if;

      if v_status = 'unresolved' then
        v_adds := '{}'; v_removes := '{}';
      elsif v_old_status = 'unresolved' then
        v_adds := array(select unnest(v_ids) except
                        select a.staff_id from public.shift_assignments a where a.shift_id = w.id and a.status in ('assigned','confirmed'));
        v_removes := array(select a.staff_id from public.shift_assignments a where a.shift_id = w.id and a.status in ('assigned','confirmed')
                           except select unnest(v_ids));
      else
        v_adds := array(select unnest(v_ids) except select unnest(v_old_ids));
        v_removes := array(select unnest(v_old_ids) except select unnest(v_ids));
      end if;
      if public._shift_title_norm(v_title) is distinct from public._shift_title_norm(w.calendar_title) then v_changed := true; end if;
      foreach x in array v_removes loop
        update public.shift_assignments set status = 'cancelled'
         where shift_id = w.id and staff_id = x and status in ('assigned','confirmed');
      end loop;
      foreach x in array v_adds loop
        insert into public.shift_assignments (shift_id, staff_id, status, source) values (w.id, x, 'assigned', 'calendar')
        on conflict (shift_id, staff_id) do update set status = 'assigned', source = 'calendar'
          where public.shift_assignments.status not in ('assigned','confirmed');
      end loop;
      if v_pending and cardinality(v_adds) + cardinality(v_removes) > 0 then v_det := v_det || '{"people":"merged"}'; end if;

      select exists (select 1 from public.shift_assignments a where a.shift_id = w.id and a.status in ('assigned','confirmed')) into v_has;
      v_staffing := case when v_status = 'unresolved' then 'unresolved' when v_has then 'assigned'
                         when v_status = 'uncertain' then 'uncertain'
                         else 'open' end;

      update public.work_shifts
         set calendar_title = v_title, cal_starts_at = v_start, cal_ends_at = v_end, cal_status = 'active',
             starts_at = v_new_start, ends_at = v_new_end, status = v_new_state,
             cancelled_at = case when v_new_state = 'active' then null else cancelled_at end,
             staffing_status = v_staffing, role_type = v_role,
             google_updated_at = coalesce(v_upd, google_updated_at), google_etag = coalesce(v_etag, google_etag),
             last_synced_at = now(),
             google_recurring_event_id = coalesce(v_rec, google_recurring_event_id),
             original_start_at = coalesce(v_orig, original_start_at)
       where id = w.id;
      if v_changed then c_changed := c_changed + 1; else c_unchanged := c_unchanged + 1; end if;

      if v_pending then
        select * into w from public.work_shifts where id = w.id;
        if public._shift_title_norm(public._shift_desired_title(w.id)) = public._shift_title_norm(w.calendar_title)
           and (w.starts_at, w.ends_at) is not distinct from (w.cal_starts_at, w.cal_ends_at)
           and w.status = coalesce(w.cal_status, 'active') then
          update public.work_shifts set pushed_version = db_version where id = w.id;
          update public.shift_outbox set status = 'skipped', result = 'converged', processed_at = now()
           where shift_id = w.id and status in ('pending','blocked');
          c_converged := c_converged + 1;
        end if;
        if v_det <> '{}'::jsonb then
          select case when count(distinct e.value) = 1 then min(e.value #>> '{}') else 'merged' end into v_winner
            from jsonb_each(v_det) e;
          v_winner := case when v_winner in ('calendar','db') then v_winner else 'merged' end;
          if v_winner = 'db' then c_kept_db := c_kept_db + 1; end if;
          insert into public.shift_sync_conflicts (shift_id, kind, winner, db_state, calendar_state, details, run_id)
          values (w.id, 'concurrent_edit', v_winner, v_dbsnap,
                  jsonb_build_object('title', v_title, 'starts_at', v_start, 'ends_at', v_end, 'updated', v_upd), v_det, p_run_id);
          c_conflicts := c_conflicts + 1;
        end if;
      end if;
    end loop;

    -- täsmäytys: perutaan aktiiviset rivit, joita Google ei enää palauta (paitsi viemättömät DB-muutokset)
    for sc in select value from jsonb_array_elements(coalesce(p_scopes, '[]'::jsonb)) loop
      if sc->>'type' not in ('calendar','series') or sc->>'from' is null or sc->>'to' is null then raise exception 'invalid scope %', sc; end if;
      if sc->>'type' = 'calendar' and p_mode = 'incremental' then
        raise exception 'calendar-wide scope is only allowed in full/recovery mode';
      end if;
      for r in
        select ws.* from public.work_shifts ws
         where ws.calendar_source_id = p_source_id and ws.status = 'active'
           and ws.starts_at >= (sc->>'from')::timestamptz and ws.starts_at < (sc->>'to')::timestamptz
           and (sc->>'type' = 'calendar' or ws.google_recurring_event_id = sc->>'recurring_event_id')
           and not exists (select 1 from pg_temp._cal_seen_v2 s where s.google_event_id = ws.google_event_id)
         for update
      loop
        if r.db_version > r.pushed_version then c_scope_kept := c_scope_kept + 1; continue; end if;
        update public.work_shifts set status = 'cancelled', cancelled_at = now(), cal_status = 'cancelled', last_synced_at = now() where id = r.id;
        c_scope_cancelled := c_scope_cancelled + 1;
      end loop;
    end loop;

    v_summary := jsonb_build_object(
      'version', 2, 'mode', p_mode, 'dry_run', p_dry_run, 'run_id', p_run_id,
      'events_received', jsonb_array_length(coalesce(p_events, '[]'::jsonb)),
      'created', c_created, 'changed', c_changed, 'cancelled', c_cancelled, 'reactivated', c_reactivated,
      'unchanged', c_unchanged, 'own_echo', c_echo, 'cancelled_by_reconciliation', c_scope_cancelled,
      'kept_pending_in_reconciliation', c_scope_kept, 'unresolved_titles', c_unresolved,
      'conflicts', c_conflicts, 'kept_db_value', c_kept_db, 'converged', c_converged);
    if p_mode in ('full','recovery') then
      insert into public.audit_log (actor_kind, actor_name, action, entity_type, entity_id, new_data)
      values ('tapio', 'calendar-sync-v2', 'calendar_' || p_mode || '_reconciliation', 'sync_state', p_source_id::text, v_summary);
    end if;
    update public.sync_state
       set sync_token = p_new_sync_token, last_success_at = now(), last_attempt_at = now(), last_error = null,
           consecutive_failures = 0, last_sync_kind = p_mode,
           full_sync_required = case when p_mode in ('full','recovery') then false else full_sync_required end,
           last_full_sync_at = case when p_mode in ('full','recovery') then now() else last_full_sync_at end
     where calendar_source_id = p_source_id;
    if p_dry_run then raise exception using errcode = 'TDRY2', message = v_summary::text; end if;
  exception when sqlstate 'TDRY2' then
    return v_summary;
  end;
  return v_summary;
end $$;
revoke all on function public.apply_calendar_changes_v2(uuid, jsonb, text, text, jsonb, text, boolean) from public, anon, authenticated;
grant execute on function public.apply_calendar_changes_v2(uuid, jsonb, text, text, jsonb, text, boolean) to service_role;
