-- shift_db_first_api: DB-kirjoitus-RPC:t (bottien, hallinnan, tarjousmoottorin ja Oton työntekijäbotin) + vientijonon claim/complete/fail.
-- Vaatii 20261022013000_shift_db_first_core.sql.

-- ---------- yhteinen validointi (palauttaa roolin) ----------
create or replace function public._shift_validate_change(
  p_action text, p_shift_id uuid, p_target_staff_id uuid, p_role text, p_new_starts timestamptz, p_new_ends timestamptz)
returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_shift public.work_shifts%rowtype;
  v_role  text;
begin
  if p_action is null or p_action not in ('assign','unassign','change_time','create','cancel') then
    raise exception 'Tuntematon toiminto % (assign, unassign, change_time, create, cancel)', p_action using errcode = '22023';
  end if;
  if p_action = 'create' then
    if p_shift_id is not null then raise exception 'create ei ota p_shift_id:tä' using errcode = '22023'; end if;
    if p_role is null or p_role not in ('heater','reception','therapist') then
      raise exception 'create vaatii roolin (heater, reception, therapist)' using errcode = '22023';
    end if;
    v_role := p_role;
  else
    if p_shift_id is null then raise exception '% vaatii p_shift_id:n', p_action using errcode = '22023'; end if;
    select * into v_shift from public.work_shifts w where w.id = p_shift_id;
    if not found then raise exception 'Vuoroa ei löytynyt' using errcode = 'P0002'; end if;
    if v_shift.status <> 'active' then raise exception 'Vuoro on peruttu' using errcode = '22023'; end if;
    if v_shift.ends_at <= now() then raise exception 'Vuoro on jo päättynyt' using errcode = '22023'; end if;
    if p_role is not null and p_role <> v_shift.role_type then
      raise exception 'Rooli ei vastaa vuoron roolia (%)', v_shift.role_type using errcode = '22023';
    end if;
    if p_action in ('assign','unassign') and v_shift.staffing_status = 'unresolved' then
      raise exception 'Vuoron kalenteriotsikkoa ei voi tulkita (%); korjaa otsikko kalenterissa ensin', v_shift.calendar_title using errcode = '22023';
    end if;
    v_role := v_shift.role_type;
  end if;

  if p_action in ('create','change_time') then
    if p_new_starts is null or p_new_ends is null then raise exception '% vaatii alun ja lopun', p_action using errcode = '22023'; end if;
    if p_new_ends <= p_new_starts then raise exception 'Lopun pitää olla alun jälkeen' using errcode = '22023'; end if;
    if p_new_ends - p_new_starts > interval '24 hours' then raise exception 'Vuoro voi olla enintään 24 h' using errcode = '22023'; end if;
    if p_new_starts < now() then raise exception 'Alku on menneisyydessä' using errcode = '22023'; end if;
    if p_new_starts > now() + interval '400 days' then raise exception 'Enintään 400 päivää eteenpäin' using errcode = '22023'; end if;
  elsif p_new_starts is not null or p_new_ends is not null then
    raise exception '% ei ota uusia aikoja', p_action using errcode = '22023';
  end if;

  if p_action in ('assign','unassign') and p_target_staff_id is null then
    raise exception '% vaatii p_target_staff_id:n', p_action using errcode = '22023';
  end if;
  if p_action in ('change_time','cancel') and p_target_staff_id is not null then
    raise exception '% ei ota p_target_staff_id:tä', p_action using errcode = '22023';
  end if;
  if p_target_staff_id is not null and p_action in ('assign','create') then
    if not exists (select 1 from public.staff s where s.id = p_target_staff_id and s.active and nullif(btrim(s.calendar_name), '') is not null) then
      raise exception 'Henkilöä ei löytynyt, hän ei ole aktiivinen tai häneltä puuttuu kalenterinimi' using errcode = '22023';
    end if;
    if not exists (select 1 from public.staff_roles r where r.staff_id = p_target_staff_id and r.role_type = v_role and r.active) then
      raise exception 'Henkilöllä ei ole roolia %', v_role using errcode = '22023';
    end if;
  end if;
  if p_action = 'assign' and exists (select 1 from public.shift_assignments sa
       where sa.shift_id = p_shift_id and sa.staff_id = p_target_staff_id and sa.status in ('assigned','confirmed')) then
    raise exception 'Henkilö on jo tässä vuorossa' using errcode = '22023';
  end if;
  if p_action = 'unassign' and not exists (select 1 from public.shift_assignments sa
       where sa.shift_id = p_shift_id and sa.staff_id = p_target_staff_id and sa.status in ('assigned','confirmed')) then
    raise exception 'Henkilö ei ole tässä vuorossa' using errcode = '22023';
  end if;
  return v_role;
end $$;

-- ---------- ydin: muutos tietokantaan + vientijono (service_role: Tapio, muut botit, hallinta, tarjousmoottori) ----------
create or replace function public.shift_apply_change(
  p_action          text,
  p_shift_id        uuid default null,
  p_target_staff_id uuid default null,
  p_role            text default null,
  p_new_starts      timestamptz default null,
  p_new_ends        timestamptz default null,
  p_source          text default 'bot',
  p_actor           text default null,
  p_actor_staff_id  uuid default null,
  p_note            text default null,
  p_request_id      uuid default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_role  text;
  v_shift uuid := p_shift_id;
  v_cal   uuid;
  v_note  text := nullif(btrim(p_note), '');
  w       public.work_shifts%rowtype;
begin
  if not public._shift_db_first_enabled() then
    raise exception 'DB-first-vuorosynkka ei ole käytössä (shift_sync_settings.db_first_enabled)' using errcode = '55000';
  end if;
  if p_source is null or p_source not in ('staff_bot','bot','hallinta','offer_engine') then
    raise exception 'Tuntematon lähde % (staff_bot, bot, hallinta, offer_engine)', p_source using errcode = '22023';
  end if;
  if v_note is not null and length(v_note) > 500 then raise exception 'Huomautus enintään 500 merkkiä' using errcode = '22023'; end if;
  v_role := public._shift_validate_change(p_action, p_shift_id, p_target_staff_id, p_role, p_new_starts, p_new_ends);

  perform set_config('sipoo.shift_source', p_source, true);
  perform set_config('sipoo.shift_actor', coalesce(left(p_actor, 100), p_source), true);
  perform set_config('sipoo.shift_actor_staff', coalesce(p_actor_staff_id::text, ''), true);
  perform set_config('sipoo.shift_request_id', coalesce(p_request_id::text, ''), true);

  if p_action = 'create' then
    select c.id into v_cal from public.calendar_sources c where c.role_type = v_role and c.active order by c.created_at limit 1;
    if v_cal is null then raise exception 'Roolille % ei ole aktiivista kalenteria', v_role using errcode = '22023'; end if;
    v_shift := gen_random_uuid();
    insert into public.work_shifts (id, google_event_id, calendar_source_id, calendar_title, role_type, starts_at, ends_at,
                                    status, staffing_status, last_synced_at)
    values (v_shift, public._shift_new_event_id(v_shift), v_cal, '', v_role, p_new_starts, p_new_ends,
            'active', case when p_target_staff_id is null then 'open' else 'assigned' end, now());
    if p_target_staff_id is not null then
      insert into public.shift_assignments (shift_id, staff_id, status, source, notes)
      values (v_shift, p_target_staff_id, 'assigned', p_source, v_note);
    end if;
  elsif p_action = 'assign' then
    insert into public.shift_assignments (shift_id, staff_id, status, source, notes)
    values (v_shift, p_target_staff_id, 'assigned', p_source, v_note)
    on conflict (shift_id, staff_id) do update
      set status = 'assigned', source = excluded.source, notes = coalesce(excluded.notes, public.shift_assignments.notes);
  elsif p_action = 'unassign' then
    update public.shift_assignments set status = 'cancelled'
     where shift_id = v_shift and staff_id = p_target_staff_id and status in ('assigned','confirmed');
  elsif p_action = 'change_time' then
    update public.work_shifts set starts_at = p_new_starts, ends_at = p_new_ends where id = v_shift;
  elsif p_action = 'cancel' then
    update public.work_shifts set status = 'cancelled', cancelled_at = now() where id = v_shift;
  end if;

  select * into w from public.work_shifts where id = v_shift;
  return jsonb_build_object(
    'shift_id', w.id, 'google_event_id', w.google_event_id, 'status', w.status, 'staffing_status', w.staffing_status,
    'desired_title', public._shift_desired_title(w.id), 'db_version', w.db_version, 'pushed_version', w.pushed_version,
    'outbox_id', (select o.id from public.shift_outbox o where o.shift_id = w.id and o.status = 'pending'));
end $$;
revoke all on function public.shift_apply_change(text, uuid, uuid, text, timestamptz, timestamptz, text, text, uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.shift_apply_change(text, uuid, uuid, text, timestamptz, timestamptz, text, text, uuid, text, uuid) to service_role;
revoke all on function public._shift_validate_change(text, uuid, uuid, text, timestamptz, timestamptz) from public, anon, authenticated;

-- ---------- Oton työntekijäbotti: sama allekirjoitus; DB-first päällä -> kirjoitus suoraan, pyyntö jää historiaksi (applied) ----------
create or replace function public.staff_bot_request_shift_change(
  p_action text,
  p_shift_id uuid default null,
  p_target_staff_id uuid default null,
  p_role text default null,
  p_new_starts timestamptz default null,
  p_new_ends timestamptz default null,
  p_note text default null)
returns uuid
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_own  uuid := public._staff_bot_staff_id('shifts.manage');
  v_role text;
  v_note text := nullif(btrim(p_note), '');
  v_id   uuid;
  v_res  jsonb;
begin
  if v_note is not null and length(v_note) > 500 then raise exception 'Huomautus enintään 500 merkkiä' using errcode = '22023'; end if;
  v_role := public._shift_validate_change(p_action, p_shift_id, p_target_staff_id, p_role, p_new_starts, p_new_ends);

  if not public._shift_db_first_enabled() then
    -- vanha toiminta: jono, jonka Työvuoro-Tapio käsittelee käsin
    select r.id into v_id from public.shift_change_requests r
     where r.status = 'pending' and r.requested_by_auth = auth.uid() and r.action = p_action
       and r.shift_id is not distinct from p_shift_id and r.target_staff_id is not distinct from p_target_staff_id
       and r.role is not distinct from v_role and r.new_starts_at is not distinct from p_new_starts
       and r.new_ends_at is not distinct from p_new_ends
     limit 1;
    if v_id is not null then return v_id; end if;
    insert into public.shift_change_requests (requested_by_auth, requested_by_staff, action, shift_id, role, target_staff_id,
                                              new_starts_at, new_ends_at, note)
    values (auth.uid(), v_own, p_action, p_shift_id, v_role, p_target_staff_id, p_new_starts, p_new_ends, v_note)
    returning id into v_id;
    return v_id;
  end if;

  insert into public.shift_change_requests (requested_by_auth, requested_by_staff, action, shift_id, role, target_staff_id,
                                            new_starts_at, new_ends_at, note, status, processed_by, processed_at)
  values (auth.uid(), v_own, p_action, p_shift_id, v_role, p_target_staff_id, p_new_starts, p_new_ends, v_note,
          'applied', 'db-first', now())
  returning id into v_id;
  v_res := public.shift_apply_change(p_action, p_shift_id, p_target_staff_id, v_role, p_new_starts, p_new_ends,
                                     'staff_bot', 'staff_bot:' || v_own::text, v_own, v_note, v_id);
  update public.shift_change_requests
     set shift_id = coalesce(shift_id, (v_res->>'shift_id')::uuid), calendar_event_id = v_res->>'google_event_id'
   where id = v_id;
  return v_id;
end $$;
revoke all on function public.staff_bot_request_shift_change(text, uuid, uuid, text, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.staff_bot_request_shift_change(text, uuid, uuid, text, timestamptz, timestamptz, text) to authenticated, service_role;

-- ---------- edge-funktion asetukset ----------
create or replace function public.shift_sync_config() returns jsonb
language sql stable security definer set search_path = '' as $$
  select to_jsonb(s) - 'id' from public.shift_sync_settings s where s.id
$$;
revoke all on function public.shift_sync_config() from public, anon, authenticated;
grant execute on function public.shift_sync_config() to service_role;

-- ---------- vientijono: claim (p_dry_run = vain suunnitelma, ei muutoksia) ----------
create or replace function public.shift_outbox_claim(p_calendar_source_id uuid, p_limit int default 25, p_dry_run boolean default false)
returns jsonb
language plpgsql security definer set search_path = '' as $$
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
end $$;

create or replace function public.shift_outbox_complete(p_id bigint, p_result text default 'ok', p_g_updated timestamptz default null, p_etag text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare r public.shift_outbox;
begin
  perform set_config('sipoo.shift_source', 'push', true);
  select * into r from public.shift_outbox where id = p_id for update;
  if not found or r.status <> 'processing' then return; end if;
  if r.g_op = 'delete' or p_result in ('deleted','gone') then
    update public.work_shifts
       set cal_status = 'cancelled', pushed_version = greatest(pushed_version, r.shift_version),
           google_updated_at = coalesce(p_g_updated, google_updated_at), google_etag = coalesce(p_etag, google_etag),
           last_pushed_at = now(), push_error = null
     where id = r.shift_id;
  else
    update public.work_shifts
       set calendar_title = r.request->>'summary',
           cal_starts_at = (r.request->>'starts_at')::timestamptz, cal_ends_at = (r.request->>'ends_at')::timestamptz,
           cal_status = 'active', pushed_version = greatest(pushed_version, r.shift_version),
           google_updated_at = coalesce(p_g_updated, google_updated_at), google_etag = coalesce(p_etag, google_etag),
           last_pushed_at = now(), push_error = null
     where id = r.shift_id;
  end if;
  update public.shift_outbox
     set status = 'done', result = left(p_result, 40), g_updated = p_g_updated, g_etag = p_etag,
         last_error = null, processed_at = now(), locked_at = null
   where id = p_id;
  perform public._shift_enqueue(r.shift_id);   -- uudempi DB-muutos viennin aikana -> uusi jonorivi (no-op muuten)
end $$;

-- p_conflict = Google 412 (If-Match etag ei täsmää: kalenteria muutettiin) -> seuraava lukusynkka ratkaisee, sitten uusi yritys
create or replace function public.shift_outbox_fail(p_id bigint, p_error text, p_blocked boolean default false, p_conflict boolean default false, p_missing boolean default false)
returns void
language plpgsql security definer set search_path = '' as $$
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
end $$;

revoke all on function public.shift_outbox_claim(uuid, int, boolean), public.shift_outbox_complete(bigint, text, timestamptz, text),
  public.shift_outbox_fail(bigint, text, boolean, boolean, boolean) from public, anon, authenticated;
grant execute on function public.shift_outbox_claim(uuid, int, boolean), public.shift_outbox_complete(bigint, text, timestamptz, text),
  public.shift_outbox_fail(bigint, text, boolean, boolean, boolean) to service_role;
