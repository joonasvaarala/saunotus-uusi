-- PALUU (aja vain jos DB-first puretaan kokonaan). Ensin: shift_sync_settings.db_first_enabled=false, cron takaisin calendar-sync v1:een.
-- Palauttaa staff_bot_request_shift_change:n vanhan jonoversion (20261021213132_staff_bot_shift_change_queue.sql) -> aja se tiedosto tämän jälkeen.
drop trigger if exists work_shifts_db_first_before on public.work_shifts;
drop trigger if exists work_shifts_db_first_after on public.work_shifts;
drop trigger if exists shift_assignments_db_first_after on public.shift_assignments;
drop function if exists public.apply_calendar_changes_v2(uuid, jsonb, text, text, jsonb, text, boolean);
drop function if exists public.shift_outbox_claim(uuid, int, boolean);
drop function if exists public.shift_outbox_complete(bigint, text, timestamptz, text);
drop function if exists public.shift_outbox_fail(bigint, text, boolean, boolean, boolean);
drop function if exists public.shift_sync_config();
drop function if exists public.shift_apply_change(text, uuid, uuid, text, timestamptz, timestamptz, text, text, uuid, text, uuid);
-- staff_bot_request_shift_change riippuu _shift_validate_change:sta -> palauta vanha versio ennen dropia
-- (aja 20261021213132_staff_bot_shift_change_queue.sql:n create or replace function -osa tässä kohtaa)
drop function if exists public._shift_validate_change(text, uuid, uuid, text, timestamptz, timestamptz);
drop function if exists public._shift_ws_before(); drop function if exists public._shift_ws_after(); drop function if exists public._shift_sa_after();
drop function if exists public._shift_enqueue(uuid); drop function if exists public._shift_log(uuid, text, uuid, jsonb, jsonb, bigint);
drop function if exists public._shift_desired_title(uuid); drop function if exists public._shift_new_event_id(uuid);
drop function if exists public._shift_title_norm(text); drop function if exists public._shift_db_first_enabled(); drop function if exists public._shift_ctx(text);
drop table if exists public.shift_open_events, public.shift_sync_conflicts, public.shift_outbox, public.shift_change_log, public.shift_sync_settings;
drop index if exists public.work_shifts_push_pending_idx;
alter table public.work_shifts drop column if exists push_pending, drop column if exists db_version, drop column if exists pushed_version,
  drop column if exists cal_starts_at, drop column if exists cal_ends_at, drop column if exists cal_status, drop column if exists google_etag,
  drop column if exists last_change_at, drop column if exists last_change_source, drop column if exists last_pushed_at, drop column if exists push_error;
