-- ROLLBACK booking_115_calendar_quiet.
-- Palauttaa nudge-, suunnitelma- ja viimeistelyfunktiot booking_114-runkoon ja poistaa last_reconcile_at-sarakkeen.
-- Taulut, ajastus ja booking_calendar-asetus jäävät.

create or replace function booking.booking_calendar_nudge()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update booking.booking_calendar_state set nudge_at = now() where id = 1;
  if booking._booking_calendar_should_nudge() then
    perform booking.booking_calendar_dispatch();
  end if;
  return null;
end $$;

create or replace function booking.booking_calendar_export_plan()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_mode text; v_run text; v_locked text; v_desired jsonb; v_mapped jsonb;
begin
  if coalesce(booking._jwt_role(), 'service_role') <> 'service_role' then perform booking._err('forbidden', 'Vain palvelurooli'); end if;
  select c.mode into v_mode from booking.integration_config c where c.key = 'booking_calendar';
  v_mode := coalesce(v_mode, 'off');
  if v_mode = 'off' then
    return jsonb_build_object('ok', true, 'mode', 'off', 'events', '[]'::jsonb, 'mapped', '[]'::jsonb);
  end if;
  if v_mode not in ('dry_run', 'live') then perform booking._err('invalid_setting', 'Tila on off, dry_run tai live'); end if;
  v_desired := booking._booking_calendar_desired();
  select coalesce(jsonb_agg(jsonb_build_object(
           'event_key', e.event_key, 'google_calendar_id', e.google_calendar_id, 'google_event_id', e.google_event_id,
           'content_hash', e.content_hash, 'starts_at', e.starts_at, 'ends_at', e.ends_at)), '[]'::jsonb)
    into v_mapped from booking.booking_calendar_events e;
  if v_mode = 'dry_run' then
    return jsonb_build_object('ok', true, 'mode', 'dry_run', 'busy', false,
      'timezone', v_desired ->> 'timezone', 'window_from', v_desired -> 'window_from', 'window_to', v_desired -> 'window_to',
      'events', v_desired -> 'events', 'mapped', v_mapped,
      'closure_calendar_ids', coalesce((select jsonb_agg(c.google_calendar_id) from booking.closure_calendars c where c.google_calendar_id is not null), '[]'::jsonb));
  end if;
  v_run := gen_random_uuid()::text;
  update booking.booking_calendar_state s
     set locked_at = now(), locked_by = v_run
   where s.id = 1 and (s.locked_at is null or s.locked_at < now() - interval '4 minutes')
  returning s.locked_by into v_locked;
  if v_locked is null then
    return jsonb_build_object('ok', true, 'mode', 'live', 'busy', true);
  end if;
  return jsonb_build_object('ok', true, 'mode', 'live', 'busy', false, 'run_id', v_run,
    'timezone', v_desired ->> 'timezone', 'window_from', v_desired -> 'window_from', 'window_to', v_desired -> 'window_to',
    'events', v_desired -> 'events', 'mapped', v_mapped,
    'closure_calendar_ids', coalesce((select jsonb_agg(c.google_calendar_id) from booking.closure_calendars c where c.google_calendar_id is not null), '[]'::jsonb));
end $$;

create or replace function booking.booking_calendar_export_finish(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  u jsonb; v_key text; v_cal text; v_eid text; n_up int := 0; n_del int := 0;
begin
  if coalesce(booking._jwt_role(), 'service_role') <> 'service_role' then perform booking._err('forbidden', 'Vain palvelurooli'); end if;
  if p is null or jsonb_typeof(p) <> 'object' then perform booking._err('bad_payload', 'Viimeistely on objekti'); end if;
  if coalesce(jsonb_array_length(p -> 'upserts'), 0) > 0 then
    for u in select value from jsonb_array_elements(p -> 'upserts') loop
      v_key := u ->> 'event_key'; v_cal := btrim(u ->> 'google_calendar_id'); v_eid := u ->> 'google_event_id';
      if v_key !~ '^[rs]:[A-Za-z0-9_.:|-]+$' or v_eid !~ '^[a-v0-9]{5,128}$' or not booking._calendar_id_ok(v_cal) or v_cal = '' then
        perform booking._err('bad_payload', 'Tapahtuman tunniste ei kelpaa');
      end if;
      if exists (select 1 from booking.closure_calendars c where c.google_calendar_id = v_cal) then
        perform booking._err('closure_calendar', 'Sulkukalenteriin ei kirjoiteta');
      end if;
      insert into booking.booking_calendar_events(event_key, kind, reservation_id, resource_code, google_calendar_id, google_event_id, content_hash, starts_at, ends_at)
      values (v_key, u ->> 'kind', nullif(u ->> 'reservation_id', '')::bigint, u ->> 'resource_code', v_cal, v_eid,
              left(coalesce(u ->> 'content_hash', ''), 64), (u ->> 'starts_at')::timestamptz, (u ->> 'ends_at')::timestamptz)
      on conflict (event_key) do update set
        kind = excluded.kind, reservation_id = excluded.reservation_id, resource_code = excluded.resource_code,
        google_calendar_id = excluded.google_calendar_id, google_event_id = excluded.google_event_id,
        content_hash = excluded.content_hash, starts_at = excluded.starts_at, ends_at = excluded.ends_at, updated_at = now();
      n_up := n_up + 1;
    end loop;
  end if;
  if coalesce(jsonb_array_length(p -> 'deletes'), 0) > 0 then
    delete from booking.booking_calendar_events e
     where e.event_key in (select value from jsonb_array_elements_text(p -> 'deletes'));
    get diagnostics n_del = row_count;
  end if;
  update booking.booking_calendar_state s
     set last_attempt_at = now(),
         last_success_at = case when nullif(p ->> 'error', '') is null then now() else s.last_success_at end,
         last_error = left(nullif(p ->> 'error', ''), 300),
         last_stats = coalesce(p -> 'stats', s.last_stats),
         locked_at = case when p ->> 'run_id' is null or s.locked_by is not distinct from p ->> 'run_id' then null else s.locked_at end,
         locked_by = case when p ->> 'run_id' is null or s.locked_by is not distinct from p ->> 'run_id' then null else s.locked_by end
   where s.id = 1;
  return jsonb_build_object('ok', true, 'upserted', n_up, 'deleted', n_del);
end $$;

alter table booking.booking_calendar_state drop column if exists last_reconcile_at;

comment on function booking.booking_calendar_nudge() is
  'Lause-triggeri: merkitsee nudge_at ja kutsuu lähetyksen, jos nopea päivitys on päällä. booking_114.';
comment on function booking.booking_calendar_export_plan() is
  'Edge: halutut tapahtumat ja lukitus, kun mode on live. off ei palauta tapahtumia. dry_run ei lukitse eikä kirjoita. booking_114.';
