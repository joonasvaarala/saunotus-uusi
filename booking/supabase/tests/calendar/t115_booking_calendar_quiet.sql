-- t115: hiljainen nudge ja tunnin täysi kirjoitus (booking_115).
-- Aja SAMASSA transaktiossa kuin migraatio, kun booking.skip_cron = on.
-- Tyhjät lauseet laukaisevat triggerin eivätkä muuta rivejä. Lopuksi tahallinen poikkeus.
--   select set_config('booking.skip_cron','on', true);
--   \i booking/supabase/migrations/20261019221500_booking_115_calendar_quiet.sql
--   \i booking/supabase/tests/calendar/t115_booking_calendar_quiet.sql
set local lock_timeout = '3s';
set local statement_timeout = '120s';
select set_config('booking.skip_audit', 'on', true);
select set_config('t115.log', '', true);
create or replace function public.t115_ck(p_ok boolean, p_label text) returns void language sql as $$
  select set_config('t115.log', coalesce(current_setting('t115.log', true), '') || case when coalesce(p_ok, false) then 'P ' else 'F ' end || coalesce(p_label, 'NULL-LABEL') || E'\n', true) $$;

do $t$
declare
  v_nudge timestamptz; v_nudge2 timestamptz; v_rec timestamptz;
  nq bigint; seq_res bigint; seq_res2 bigint;
  plan jsonb; fin jsonb;
  log text; npass int; nfail int;
  t_start timestamptz := now();
begin
  perform public.t115_ck(coalesce(current_setting('booking.skip_cron', true), '') = 'on', 'C0 skip_cron on');
  update booking.integration_config
     set mode = 'off',
         settings = jsonb_set(coalesce(settings, '{}'::jsonb), '{fast_nudge}', 'false'::jsonb)
   where key = 'booking_calendar';
  update booking.booking_calendar_state
     set last_reconcile_at = null, nudge_at = timestamptz '2000-01-01+00'
   where id = 1;

  select s.nudge_at into v_nudge from booking.booking_calendar_state s where s.id = 1 for update;
  select count(*) into nq from net.http_request_queue;
  update booking.reservations set notes = notes where false;
  update booking.orders set payment_status = payment_status where false;
  delete from booking.reservations where false;
  select s.nudge_at into v_nudge2 from booking.booking_calendar_state s where s.id = 1;
  perform public.t115_ck(v_nudge2 = v_nudge and v_nudge2 = timestamptz '2000-01-01+00', 'N1 pois-tila ei kirjoita tilariviä');
  perform public.t115_ck((select count(*) from net.http_request_queue) = nq, 'N2 pois-tila ei kutsu verkkoa');

  update booking.integration_config set mode = 'dry_run' where key = 'booking_calendar';
  update booking.booking_calendar_state set last_reconcile_at = now() where id = 1;
  plan := booking.booking_calendar_export_plan();
  perform public.t115_ck(plan ->> 'mode' = 'dry_run' and plan ->> 'reconcile' = 'false' and coalesce(plan ->> 'busy', 'false') = 'false', 'R1 tuore täysi kirjoitus ei toistu');
  update booking.booking_calendar_state set last_reconcile_at = null where id = 1;
  plan := booking.booking_calendar_export_plan();
  perform public.t115_ck(plan ->> 'reconcile' = 'true', 'R2 puuttuva leima pyytää täyden kirjoituksen');
  update booking.booking_calendar_state set last_reconcile_at = now() - interval '2 hours' where id = 1;
  plan := booking.booking_calendar_export_plan();
  perform public.t115_ck(plan ->> 'reconcile' = 'true', 'R3 yli tunti vanha leima pyytää täyden kirjoituksen');

  update booking.booking_calendar_state set nudge_at = timestamptz '2000-01-01+00' where id = 1;
  update booking.reservations set notes = notes where false;
  select s.nudge_at into v_nudge2 from booking.booking_calendar_state s where s.id = 1;
  perform public.t115_ck(v_nudge2 = t_start, 'N3 harjoitusajo merkitsee nudge-ajan');
  perform public.t115_ck((select count(*) from net.http_request_queue) = nq, 'N4 harjoitusajo ei kutsu verkkoa kun skip_cron');

  update booking.integration_config set mode = 'live' where key = 'booking_calendar';
  update booking.booking_calendar_state set last_reconcile_at = now() - interval '2 hours', locked_at = null, locked_by = null where id = 1;
  plan := booking.booking_calendar_export_plan();
  perform public.t115_ck(plan ->> 'mode' = 'live' and plan ->> 'busy' = 'false' and plan ->> 'reconcile' = 'true' and plan ->> 'run_id' is not null, 'P1 live lukitsee ja pyytää täyden kirjoituksen');
  v_rec := now() - interval '2 hours';
  fin := booking.booking_calendar_export_finish(jsonb_build_object('run_id', plan ->> 'run_id', 'reconcile', true, 'error', 'google_http_403', 'upserts', '[]'::jsonb, 'deletes', '[]'::jsonb));
  perform public.t115_ck((fin ->> 'ok') = 'true', 'F1 virheellinen ajo viimeistellään');
  perform public.t115_ck((select last_reconcile_at < t_start and locked_at is null from booking.booking_calendar_state where id = 1), 'F2 virhe ei leimaa täyttä kirjoitusta ja lukko aukeaa');

  plan := booking.booking_calendar_export_plan();
  fin := booking.booking_calendar_export_finish(jsonb_build_object('run_id', plan ->> 'run_id', 'reconcile', true, 'upserts', '[]'::jsonb, 'deletes', '[]'::jsonb));
  perform public.t115_ck((select last_reconcile_at >= t_start and locked_at is null from booking.booking_calendar_state where id = 1), 'F3 onnistunut täysi kirjoitus leimataan');

  update booking.integration_config set mode = 'dry_run' where key = 'booking_calendar';
  update booking.booking_calendar_state set last_reconcile_at = v_rec where id = 1;
  perform booking.booking_calendar_export_finish(jsonb_build_object('reconcile', true, 'upserts', '[]'::jsonb, 'deletes', '[]'::jsonb));
  perform public.t115_ck((select last_reconcile_at = v_rec from booking.booking_calendar_state where id = 1), 'F4 harjoitusajo ei leimaa täyttä kirjoitusta');

  select last_value into seq_res from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.reservations', 'id'), '.', 2);
  select last_value into seq_res2 from pg_sequences where schemaname = 'booking' and sequencename = split_part(pg_get_serial_sequence('booking.reservations', 'id'), '.', 2);
  perform public.t115_ck(seq_res2 = seq_res, 'S0 sekvenssi ei kulunut');

  log := current_setting('t115.log', true);
  npass := (length(log) - length(replace(log, 'P ', ''))) / 2;
  nfail := (length(log) - length(replace(log, 'F ', ''))) / 2;
  raise exception 'TESTRESULT pass=% fail=%\n%', npass, nfail, log;
end $t$;
