-- APPLIED 2026-10-17 (Europe/Helsinki ~01:2x): version 20261016221825 (booking_18b_sync) via apply_migration; sama SQL kuin alla (otsikkorivi lisätty tiedostoon ajon jälkeen).
-- ===================================================================================================================
-- booking_18b_sync: toivotut sulut -> space_blocks (idempotentti täsmäytys), apply_closure_events, ylläpitofunktiot
-- ===================================================================================================================
set local search_path = booking, extensions, public;

-- toivotut sulut kirjanpidosta (kalenterin resurssi + mahdollinen säännön lisäresurssi; ei käytössä oletussäännöissä)
create or replace view booking.v_closure_wanted_blocks as
select ev.id as closure_event_id, ev.calendar_code, cal.resource_id as space_id, ev.starts_at, ev.ends_at,
       left('Kalenteri (' || cal.name || '): ' || coalesce(nullif(ev.reason, ''), '(ei otsikkoa)'), 300) as reason
  from booking.closure_events ev join booking.closure_calendars cal on cal.code = ev.calendar_code
 where ev.status = 'active' and (ev.override = 'block' or (ev.override is null and ev.class = 'closure'))
union all
select ev.id, ev.calendar_code, ev.extra_resource_id, ev.starts_at, ev.ends_at,
       left('Kalenteri (' || cal.name || '): ' || coalesce(nullif(ev.reason, ''), '(ei otsikkoa)') || ' [' || xr.code || ']', 300)
  from booking.closure_events ev join booking.closure_calendars cal on cal.code = ev.calendar_code
  join booking.resources xr on xr.id = ev.extra_resource_id
 where ev.status = 'active' and ev.extra_resource_id is not null
   and (ev.override = 'block' or (ev.override is null and ev.class = 'closure'));
revoke all on booking.v_closure_wanted_blocks from public, anon, authenticated;
grant select on booking.v_closure_wanted_blocks to service_role;

-- ---------- _reconcile_closure_blocks: space_blocks = toivotut sulut (poista/päivitä/lisää) ----------
create or replace function booking._reconcile_closure_blocks(p_calendar text)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare cal booking.closure_calendars; v_ins integer := 0; v_upd integer := 0; v_del integer := 0;
begin
  select * into cal from booking.closure_calendars where code = p_calendar;
  if not found then perform booking._err('calendar_not_found', 'Sulkukalenteria ei löydy'); end if;
  perform set_config('booking.closure_sync', 'on', true);          -- sallii synkan muokata kalenterisulkuja (space_blocks_managed_guard)
  -- samat resurssilukot kuin validaattoreissa -> sulun kirjoitus ja varauksen validointi serialisoituvat
  perform booking._lock_resources(array(select cal.resource_id union
                                        select e.extra_resource_id from booking.closure_events e where e.calendar_code = p_calendar and e.extra_resource_id is not null));

  delete from booking.space_blocks b using booking.closure_events ev
   where b.closure_event_id = ev.id and ev.calendar_code = p_calendar
     and not exists (select 1 from booking.v_closure_wanted_blocks w where w.closure_event_id = b.closure_event_id and w.space_id = b.space_id);
  get diagnostics v_del = row_count;

  update booking.space_blocks b set starts_at = w.starts_at, ends_at = w.ends_at, reason = w.reason, active = true
    from booking.v_closure_wanted_blocks w
   where w.calendar_code = p_calendar and b.closure_event_id = w.closure_event_id and b.space_id = w.space_id
     and (b.starts_at, b.ends_at, b.reason, b.active) is distinct from (w.starts_at, w.ends_at, w.reason, true);
  get diagnostics v_upd = row_count;

  insert into booking.space_blocks(space_id, starts_at, ends_at, reason, closure_event_id)
  select w.space_id, w.starts_at, w.ends_at, w.reason, w.closure_event_id
    from booking.v_closure_wanted_blocks w
   where w.calendar_code = p_calendar
     and not exists (select 1 from booking.space_blocks b where b.closure_event_id = w.closure_event_id and b.space_id = w.space_id);
  get diagnostics v_ins = row_count;

  return jsonb_build_object('blocks_inserted', v_ins, 'blocks_updated', v_upd, 'blocks_deleted', v_del);
end $function$;

-- ---------- apply_closure_events: yhden kalenterin koko ikkuna-snapshot -> kirjanpito + sulut (idempotentti) ----------
-- p_events = Google events.list -items (singleEvents=true, showDeleted=false) -taulukko sellaisenaan; cancelled-tilaiset ohitetaan.
-- p_dry_run: laskee ja palauttaa tilastot, mutta peruu kaiken (sisäinen alitransaktio).
-- Massapoistosuoja: jos poistuvia tapahtumia > max(guard_min_deletes, guard_ratio * aktiiviset ikkunassa) eikä p_force -> ei kirjoiteta, outcome 'guard'.
create or replace function booking.apply_closure_events(p_calendar text, p_events jsonb, p_window_from timestamptz, p_window_to timestamptz,
                                                        p_dry_run boolean default false, p_force boolean default false, p_source text default 'edge')
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  cal booking.closure_calendars; cfg jsonb; v_max_h numeric; v_gmin integer; v_gratio numeric; v_tomb integer;
  v_stats jsonb; v_detail text; v_blocks jsonb; v_active integer; v_del integer; v_ins integer := 0; v_upd integer := 0; v_cand integer;
  v_seen integer; v_mirror integer; v_marker integer; v_train integer; v_invalid integer; v_rough integer; v_conf integer; v_conf_list jsonb;
begin
  if coalesce(booking._jwt_role(), 'service_role') <> 'service_role' then perform booking._err('forbidden', 'Vain palvelurooli'); end if;
  select * into cal from booking.closure_calendars where code = p_calendar;
  if not found then perform booking._err('calendar_not_found', 'Sulkukalenteria ei löydy'); end if;
  if p_events is null or jsonb_typeof(p_events) <> 'array' then perform booking._err('bad_events', 'p_events on oltava JSON-taulukko'); end if;
  if p_window_from is null or p_window_to is null or p_window_to <= p_window_from or p_window_to - p_window_from > interval '5 years' then
    perform booking._err('bad_window', 'Virheellinen synkkaikkuna');
  end if;
  select value into cfg from booking.settings where key = 'closure_sync';
  v_max_h := coalesce((cfg ->> 'max_timed_hours')::numeric, 36);
  v_gmin := coalesce((cfg ->> 'guard_min_deletes')::integer, 5);
  v_gratio := coalesce((cfg ->> 'guard_ratio')::numeric, 0.5);
  v_tomb := coalesce((cfg ->> 'tombstone_days')::integer, 90);
  perform pg_advisory_xact_lock(hashtextextended('booking:closure_sync:' || p_calendar, 0));   -- yksi ajo kerrallaan / kalenteri

  -- 1) jäsennys (nollataan väliaikaistaulu; sama transaktio voi kutsua useasti)
  create temp table if not exists _ce(external_id text primary key, title text, all_day boolean, starts_at timestamptz, ends_at timestamptz, g_updated timestamptz,
                                      act text, cls text, extra_code text, reason text, hash text) on commit drop;
  delete from pg_temp._ce where true;
  insert into pg_temp._ce(external_id, title, all_day, starts_at, ends_at, g_updated)
  select x ->> 'id', nullif(btrim(x ->> 'summary'), ''), (x -> 'start') ? 'date',
         case when (x -> 'start') ? 'date' then ((x -> 'start' ->> 'date')::date)::timestamp at time zone cal.timezone else (x -> 'start' ->> 'dateTime')::timestamptz end,
         case when (x -> 'end') ? 'date' then ((x -> 'end' ->> 'date')::date)::timestamp at time zone cal.timezone else (x -> 'end' ->> 'dateTime')::timestamptz end,
         nullif(x ->> 'updated', '')::timestamptz
    from jsonb_array_elements(p_events) x
   where coalesce(x ->> 'status', 'confirmed') <> 'cancelled' and nullif(x ->> 'id', '') is not null
  on conflict (external_id) do nothing;
  select count(*) into v_seen from pg_temp._ce;

  -- 2) luokittelu sääntötaulun mukaan (ensimmäinen osuva sort_order-järjestyksessä); oletus = sulku
  update pg_temp._ce c set act = coalesce(r.action, 'block'), cls = coalesce(r.class, 'closure'), extra_code = r.extra_resource_code
    from (select c2.external_id, rr.action, rr.class, rr.extra_resource_code
            from pg_temp._ce c2
            left join lateral (select ru.* from booking.closure_event_rules ru
                                where ru.active and (ru.calendar_code is null or ru.calendar_code = p_calendar)
                                  and case ru.match_type when 'prefix' then left(coalesce(c2.title, ''), length(ru.pattern)) = ru.pattern
                                                         when 'equals' then coalesce(c2.title, '') = ru.pattern
                                                         else coalesce(c2.title, '') ~ ru.pattern end
                                order by ru.sort_order, ru.id limit 1) rr on true) r
   where r.external_id = c.external_id;
  update pg_temp._ce set act = 'invalid', cls = 'invalid' where starts_at is null or ends_at is null or ends_at <= starts_at;
  update pg_temp._ce set cls = 'rough'
   where act = 'block' and cls = 'closure' and not all_day and ends_at - starts_at > make_interval(secs => v_max_h * 3600);
  update pg_temp._ce set reason = left(title, 200) where act = 'block';
  update pg_temp._ce set hash = md5(concat_ws('|', cls, extract(epoch from starts_at)::text, extract(epoch from ends_at)::text, all_day::text,
                                              coalesce(reason, ''), coalesce(extra_code, ''))) where act = 'block';
  select count(*) filter (where cls = 'mirror'), count(*) filter (where act = 'ignore' and cls not in ('mirror', 'training')), count(*) filter (where cls = 'training'),
         count(*) filter (where act = 'invalid'), count(*) filter (where cls = 'rough'), count(*) filter (where act = 'block')
    into v_mirror, v_marker, v_train, v_invalid, v_rough, v_cand from pg_temp._ce;

  -- 3) massapoistosuoja
  select count(*) into v_active from booking.closure_events e
   where e.calendar_code = p_calendar and e.status = 'active' and e.ends_at > p_window_from and e.starts_at < p_window_to;
  select count(*) into v_del from booking.closure_events e
   where e.calendar_code = p_calendar and e.status = 'active' and e.ends_at > p_window_from and e.starts_at < p_window_to
     and not exists (select 1 from pg_temp._ce c where c.external_id = e.external_id and c.act = 'block');
  if not p_force and v_del > greatest(v_gmin, ceil(v_gratio * v_active)) then
    v_stats := jsonb_build_object('calendar', p_calendar, 'guard', true, 'would_delete', v_del, 'active_in_window', v_active, 'events_seen', v_seen);
    if not p_dry_run then
      insert into booking.closure_sync_runs(calendar_code, outcome, stats, error, source) values (p_calendar, 'guard', v_stats, 'mass_delete_guard', p_source);
      update booking.closure_calendars set last_attempt_at = now(), last_error = 'mass_delete_guard', consecutive_failures = consecutive_failures + 1, last_stats = v_stats, updated_at = now() where code = p_calendar;
    end if;
    return jsonb_build_object('ok', false, 'guard', true, 'stats', v_stats);
  end if;

  begin
    -- 4) kirjanpito: upsert (vain muuttuneet rivit kirjoitetaan) + poistuneet tombstoneiksi
    with up as (
      insert into booking.closure_events(calendar_code, external_id, class, reason, all_day, starts_at, ends_at, extra_resource_id, g_updated, content_hash)
      select p_calendar, c.external_id, c.cls, c.reason, c.all_day, c.starts_at, c.ends_at, (select r.id from booking.resources r where r.code = c.extra_code), c.g_updated, c.hash
        from pg_temp._ce c where c.act = 'block'
      on conflict (calendar_code, external_id) do update
         set class = excluded.class, reason = excluded.reason, all_day = excluded.all_day, starts_at = excluded.starts_at, ends_at = excluded.ends_at,
             extra_resource_id = excluded.extra_resource_id, g_updated = excluded.g_updated, content_hash = excluded.content_hash,
             status = 'active', deleted_at = null, updated_at = now()
       where booking.closure_events.content_hash is distinct from excluded.content_hash or booking.closure_events.status <> 'active'
      returning (xmax = 0) as ins)
    select count(*) filter (where ins), count(*) filter (where not ins) into v_ins, v_upd from up;

    update booking.closure_events e set status = 'deleted', deleted_at = now(), updated_at = now()
     where e.calendar_code = p_calendar and e.status = 'active' and e.ends_at > p_window_from and e.starts_at < p_window_to
       and not exists (select 1 from pg_temp._ce c where c.external_id = e.external_id and c.act = 'block');

    -- 5) sulut = toivotut sulut
    v_blocks := booking._reconcile_closure_blocks(p_calendar);
    delete from booking.closure_events e where e.status = 'deleted' and e.deleted_at < now() - make_interval(days => v_tomb);

    -- 6) konfliktit olemassa oleviin varauksiin (vain tulevat; vain tunnisteita, ei henkilötietoja)
    select count(distinct c.reservation_id), coalesce(jsonb_agg(jsonb_build_object('reservation_id', c.reservation_id, 'block_id', b.id, 'starts_at', c.claim_start)) filter (where rn <= 50), '[]'::jsonb)
      into v_conf, v_conf_list
      from (select c.*, row_number() over (order by c.claim_start) rn from booking.v_claims c where booking._res_active(c.status, c.hold_expires_at) and c.claim_end > now()) c
      join booking.space_blocks b on b.active and b.closure_event_id is not null and b.space_id = c.resource_id and b.during && tstzrange(c.claim_start, c.claim_end, '[)')
      join booking.closure_events ev on ev.id = b.closure_event_id and ev.calendar_code = p_calendar;

    v_stats := jsonb_build_object('calendar', p_calendar, 'guard', false, 'dry_run', p_dry_run, 'events_seen', v_seen, 'ignored_mirror', v_mirror, 'ignored_marker', v_marker, 'ignored_training', v_train,
                'invalid', v_invalid, 'rough', v_rough, 'candidates', v_cand, 'inserted', v_ins, 'updated', v_upd, 'unchanged', v_cand - v_ins - v_upd,
                'deleted', v_del) || v_blocks || jsonb_build_object('conflicting_reservations', v_conf);
    if not p_dry_run then
      insert into booking.closure_sync_runs(calendar_code, outcome, stats, source) values (p_calendar, 'ok', v_stats, p_source);
      update booking.closure_calendars set last_attempt_at = now(), last_success_at = now(), last_error = null, consecutive_failures = 0, last_stats = v_stats, updated_at = now() where code = p_calendar;
    else
      raise exception 'dry_run' using errcode = 'BKDRY', detail = jsonb_build_object('ok', true, 'stats', v_stats, 'conflicts', v_conf_list)::text;
    end if;
  exception when sqlstate 'BKDRY' then
    get stacked diagnostics v_detail = pg_exception_detail;
    return v_detail::jsonb;
  end;
  return jsonb_build_object('ok', true, 'stats', v_stats, 'conflicts', v_conf_list);
end $function$;

-- ---------- synkan apufunktiot edge-funktiolle ----------
create or replace function booking.closure_sync_targets()
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
begin
  if coalesce(booking._jwt_role(), 'service_role') <> 'service_role' then perform booking._err('forbidden', 'Vain palvelurooli'); end if;
  return jsonb_build_object(
    'config', (select value from booking.settings where key = 'closure_sync'),
    'calendars', coalesce((select jsonb_agg(jsonb_build_object('code', c.code, 'google_calendar_id', c.google_calendar_id, 'timezone', c.timezone) order by c.sort_order)
                             from booking.closure_calendars c where c.active and c.google_calendar_id is not null), '[]'::jsonb));
end $function$;

create or replace function booking.record_closure_sync_failure(p_calendar text, p_error text, p_source text default 'edge')
 returns void language plpgsql security definer set search_path to ''
as $function$
begin
  if coalesce(booking._jwt_role(), 'service_role') <> 'service_role' then perform booking._err('forbidden', 'Vain palvelurooli'); end if;
  insert into booking.closure_sync_runs(calendar_code, outcome, error, source) values (p_calendar, 'error', left(p_error, 300), p_source);
  update booking.closure_calendars set last_attempt_at = now(), last_error = left(p_error, 300), consecutive_failures = consecutive_failures + 1, updated_at = now() where code = p_calendar;
end $function$;

-- ---------- ylläpito: yleiskuva + yksittäisen tapahtuman ohitus ----------
create or replace function booking.admin_closure_overview(p_days integer default 60)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
begin
  perform booking._require_permission('blocks.manage');
  return jsonb_build_object(
    'calendars', coalesce((select jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name, 'resource_code', r.code, 'active', c.active, 'configured', c.google_calendar_id is not null,
                    'last_success_at', c.last_success_at, 'last_attempt_at', c.last_attempt_at, 'last_error', c.last_error, 'consecutive_failures', c.consecutive_failures,
                    'last_stats', c.last_stats) order by c.sort_order)
                  from booking.closure_calendars c join booking.resources r on r.id = c.resource_id), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'calendar_code', e.calendar_code, 'class', e.class, 'reason', e.reason, 'all_day', e.all_day, 'starts_at', e.starts_at,
                    'ends_at', e.ends_at, 'override', e.override, 'override_note', e.override_note,
                    'effective_block', (e.override = 'block' or (e.override is null and e.class = 'closure'))) order by e.starts_at)
                  from (select * from booking.closure_events where status = 'active' and ends_at > now() and starts_at < now() + make_interval(days => greatest(p_days, 1))
                         order by starts_at limit 500) e), '[]'::jsonb),
    'conflicts', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', c.reservation_id, 'leg_id', c.leg_id, 'resource_id', c.resource_id, 'block_id', b.id, 'starts_at', c.claim_start) order by c.claim_start)
                  from booking.v_claims c join booking.space_blocks b on b.active and b.closure_event_id is not null and b.space_id = c.resource_id and b.during && tstzrange(c.claim_start, c.claim_end, '[)')
                 where booking._res_active(c.status, c.hold_expires_at) and c.claim_end > now()), '[]'::jsonb),
    'runs', coalesce((select jsonb_agg(jsonb_build_object('calendar_code', x.calendar_code, 'started_at', x.started_at, 'outcome', x.outcome, 'error', x.error, 'stats', x.stats) order by x.started_at desc)
                  from (select * from booking.closure_sync_runs order by started_at desc limit 12) x), '[]'::jsonb));
end $function$;

create or replace function booking.admin_set_closure_override(p_event_id bigint, p_override text, p_note text default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare ev booking.closure_events; v_blocks jsonb;
begin
  perform booking._require_permission('blocks.manage');
  if p_override is not null and p_override not in ('ignore', 'block') then perform booking._err('bad_override', 'Ohitus: ignore, block tai tyhjä'); end if;
  select * into ev from booking.closure_events where id = p_event_id;
  if not found then perform booking._err('not_found', 'Tapahtumaa ei löydy'); end if;
  update booking.closure_events set override = p_override, override_note = left(p_note, 300), override_by = auth.uid(), override_at = now(), updated_at = now() where id = p_event_id;
  v_blocks := booking._reconcile_closure_blocks(ev.calendar_code);
  return jsonb_build_object('ok', true) || v_blocks;
end $function$;

-- ---------- oikeudet ----------
revoke all on function booking._reconcile_closure_blocks(text) from public, anon, authenticated;
revoke all on function booking.apply_closure_events(text, jsonb, timestamptz, timestamptz, boolean, boolean, text) from public, anon, authenticated;
revoke all on function booking.closure_sync_targets() from public, anon, authenticated;
revoke all on function booking.record_closure_sync_failure(text, text, text) from public, anon, authenticated;
revoke all on function booking.admin_closure_overview(integer) from public, anon;
revoke all on function booking.admin_set_closure_override(bigint, text, text) from public, anon;
revoke all on function booking.space_blocks_managed_guard() from public, anon, authenticated;
grant execute on function booking._reconcile_closure_blocks(text) to service_role;
grant execute on function booking.apply_closure_events(text, jsonb, timestamptz, timestamptz, boolean, boolean, text) to service_role;
grant execute on function booking.closure_sync_targets() to service_role;
grant execute on function booking.record_closure_sync_failure(text, text, text) to service_role;
grant execute on function booking.admin_closure_overview(integer) to authenticated, service_role;
grant execute on function booking.admin_set_closure_override(bigint, text, text) to authenticated, service_role;
