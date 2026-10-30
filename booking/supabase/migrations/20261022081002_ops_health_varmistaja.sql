-- HISTORY-SYNC: tämä migraatio on jo ajettu tuotannossa (Supabase sxbofnuisemspgquoxyv) 22.10.2026, versio 20261022081002 (ops_health_varmistaja).
-- Lisätty repoon jälkikäteen 25.10.2026, jotta repopohjainen rakennus luo public.ops_health():n (Varmistaja-valvonta).
-- Alla olevat lauseet ovat sellaisenaan tuotannon migraatiohistoriasta (supabase_migrations.schema_migrations.statements). Älä aja uudelleen tuotantoon.
-- Varmistaja-valvonta (Hetzner-palvelin): vain ei-arkaluonteiset terveystiedot anon-roolille.
-- Ei virhetekstejä, ei tunnuksia, ei henkilötietoja. Peruutus: drop function if exists public.ops_health();
-- Tyhjä kanta: pg_cron- ja pg_net-taulut eivät ole mukana. Tuotannossa ne ovat jo, create/add if not exists ei muuta niitä.
create schema if not exists cron;
create table if not exists cron.job (
  jobid bigint generated always as identity primary key,
  jobname text,
  schedule text,
  command text,
  active boolean not null default true
);
alter table cron.job add column if not exists active boolean not null default true;
create table if not exists cron.job_run_details (
  jobid bigint,
  runid bigint generated always as identity,
  start_time timestamptz,
  status text
);
create schema if not exists net;
create table if not exists net._http_response (
  id bigint generated always as identity primary key,
  status_code integer,
  timed_out boolean,
  created timestamptz default now()
);

create or replace function public.ops_health()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with r as (
    select d.jobid,
           max(d.start_time) as last_start,
           max(d.start_time) filter (where d.status = 'succeeded') as last_ok,
           count(*) filter (where d.status = 'failed' and d.start_time > now() - interval '1 hour') as fails_1h,
           (array_agg(d.status order by d.start_time desc))[1] as last_status
      from cron.job_run_details d
     where d.start_time > now() - interval '8 days'
     group by d.jobid
  )
  select jsonb_build_object(
    'generated_at', now(),
    'cron_latest_start', (select max(last_start) from r),
    'cron', coalesce((
      select jsonb_agg(jsonb_build_object(
        'job', j.jobname,
        'active', j.active,
        'schedule', j.schedule,
        'last_start', r.last_start,
        'last_status', r.last_status,
        'last_ok', r.last_ok,
        'fails_1h', coalesce(r.fails_1h, 0)
      ) order by j.jobname)
      from cron.job j left join r on r.jobid = j.jobid
    ), '[]'::jsonb),
    'closure_sync', coalesce((
      select jsonb_agg(jsonb_build_object(
        'calendar', c.calendar_code,
        'last_run', c.last_run,
        'last_outcome', c.last_outcome,
        'last_ok', c.last_ok
      ) order by c.calendar_code)
      from (
        select s.calendar_code,
               max(s.started_at) as last_run,
               (array_agg(s.outcome order by s.started_at desc))[1] as last_outcome,
               max(s.started_at) filter (where s.outcome = 'ok') as last_ok
          from booking.closure_sync_runs s
         where s.started_at > now() - interval '7 days'
         group by s.calendar_code
      ) c
    ), '[]'::jsonb),
    'shift_sync', coalesce((
      select jsonb_agg(jsonb_build_object(
        'n', x.n,
        'last_success_at', x.last_success_at,
        'last_attempt_at', x.last_attempt_at,
        'consecutive_failures', coalesce(x.consecutive_failures, 0),
        'has_error', coalesce(x.last_error, '') <> '',
        'full_sync_required', coalesce(x.full_sync_required, false)
      ) order by x.n)
      from (select row_number() over (order by s.calendar_source_id) as n, s.*
              from public.sync_state s) x
    ), '[]'::jsonb),
    'shift_outbox_stuck', (select count(*) from public.shift_outbox o
       where (o.status in ('pending', 'blocked') and o.next_attempt_at < now() - interval '30 minutes')
          or o.status in ('failed', 'dead', 'error')),
    'closure_outbox_stuck', (select count(*) from booking.closure_outbox o
       where o.status not in ('done', 'skipped', 'cancelled')
         and o.next_attempt_at < now() - interval '30 minutes'),
    'email_outbox_stuck', (select count(*) from booking.email_outbox o
       where (o.status in ('pending', 'failed') and o.next_attempt_at < now() - interval '30 minutes')
          or (o.status = 'sending' and o.locked_at < now() - interval '30 minutes')),
    'net_errors_1h', (select count(*) from net._http_response h
       where h.created > now() - interval '1 hour'
         and (h.timed_out or h.status_code is null or h.status_code >= 400)),
    'net_ok_1h', (select count(*) from net._http_response h
       where h.created > now() - interval '1 hour' and h.status_code between 200 and 399),
    'johku_last_import', (select max(o.created_at) from booking.orders o where o.external_source = 'johku')
  );
$$;

revoke all on function public.ops_health() from public;
revoke all on function public.ops_health() from anon, authenticated;
grant execute on function public.ops_health() to anon, service_role;

comment on function public.ops_health() is
  'Varmistaja-valvonta: vain ei-arkaluonteiset terveysaikaleimat ja tilat (ei virhetekstejä, ei tunnuksia). Peruutus: drop function if exists public.ops_health();';
