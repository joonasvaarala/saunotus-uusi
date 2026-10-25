-- HISTORY-SYNC: tämä migraatio on jo ajettu tuotannossa (Supabase sxbofnuisemspgquoxyv) 25.10.2026, versio 20261025113918 (ops_health_light).
-- Lisätty repoon jälkikäteen 25.10.2026, jotta repopohjainen rakennus luo public.ops_health():n (Varmistaja-valvonta).
-- Alla olevat lauseet ovat sellaisenaan tuotannon migraatiohistoriasta; tiedoston lopussa erikseen merkitty käsin ajettu lisälause. Älä aja uudelleen tuotantoon.
-- ops_health_light (2026-10-25): kevyempi public.ops_health() Varmistaja-valvontaan.
-- Sama JSON-rakenne ja avaimet kuin ennen. Ennen: koko 8 vrk cron-historian aggregointi + array_agg-lajittelu
-- (levylle valuva sort), mikä anonin 3 s statement_timeoutilla aiheutti satunnaisia HTTP 500 -vastauksia.
-- Nyt: viimeisin ajo ja viimeisin onnistunut ajo per työ LATERAL ... ORDER BY runid DESC LIMIT 1 -haulla
-- (pkey-indeksi), 8 vrk raja vain jotta viikkotyö (calendar-sync-full-weekly) näkyy kuten ennen;
-- fails_1h vain viimeisistä 10000 ajosta (pkey-väli). Ei koko taulun seq scania eikä lajittelua.
-- Indeksiä (jobid, start_time) ei voi luoda: cron.job_run_details omistaa supabase_admin.
-- Lisäksi päivittäinen siivous: cron.job_run_details yli 7 vrk vanhat rivit pois (ops_cron_history_cleanup).
-- Peruutus: aja /workspace/ops_health/ops_health_before.sql (vanha määritelmä) ja
--   select cron.unschedule('ops_cron_history_cleanup');
create or replace function public.ops_health()
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  with recent_fails as (
    -- epäonnistumiset viim. 1 h: vain viimeiset 10000 ajoa (runid-pkey-väli, nyt ~1,5 vrk);
    -- oikein niin kauan kuin ajoja on < 10000/h
    select d.jobid, count(*) as n
      from cron.job_run_details d
     where d.runid > (select max(d2.runid) from cron.job_run_details d2) - 10000
       and d.status = 'failed'
       and d.start_time > now() - interval '1 hour'
     group by d.jobid
  ), r as (
    select j.jobname, j.active, j.schedule,
           l.start_time as last_start,
           l.status as last_status,
           case when l.status = 'succeeded' then l.start_time else ok.start_time end as last_ok,
           coalesce(f.n, 0) as fails_1h
      from cron.job j
      -- viimeisin ajo per työ: pkey (runid) taaksepäin, LIMIT 1; 8 vrk raja kattaa viikkotyön
      left join lateral (
        select d.start_time, d.status
          from cron.job_run_details d
         where d.jobid = j.jobid and d.start_time > now() - interval '8 days'
         order by d.runid desc
         limit 1
      ) l on true
      left join lateral (
        select d.start_time
          from cron.job_run_details d
         where l.status is distinct from 'succeeded'   -- haetaan vain jos viimeisin ajo ei onnistunut
           and d.jobid = j.jobid and d.status = 'succeeded' and d.start_time > now() - interval '8 days'
         order by d.runid desc
         limit 1
      ) ok on true
      left join recent_fails f on f.jobid = j.jobid
  )
  select jsonb_build_object(
    'generated_at', now(),
    'cron_latest_start', (select max(r.last_start) from r),
    'cron', coalesce((
      select jsonb_agg(jsonb_build_object(
        'job', r.jobname,
        'active', r.active,
        'schedule', r.schedule,
        'last_start', r.last_start,
        'last_status', r.last_status,
        'last_ok', r.last_ok,
        'fails_1h', r.fails_1h
      ) order by r.jobname)
      from r
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
$function$;

comment on function public.ops_health() is 'Varmistaja-valvonta: vain ei-arkaluonteiset terveysaikaleimat ja tilat (ei virhetekstejä, ei tunnuksia). Kevennetty 2026-10-25 (ops_health_light). Peruutus: drop function if exists public.ops_health();';

-- Päivittäinen cron-historian siivous klo 03:40 Europe/Helsinki (pg_cron ajaa UTC:nä: 01:40 UTC talviaikaan).
select cron.unschedule(jobid) from cron.job where jobname = 'ops_cron_history_cleanup';
select cron.schedule('ops_cron_history_cleanup', '40 1 * * *',
  $$delete from cron.job_run_details where start_time < now() - interval '7 days'$$);

-- LISÄYS (ei tuotannon migraatiohistoriassa): Bottiavustus ajoi tämän tuotantoon käsin 25.10.2026 migraation 20261025113918 jälkeen.
-- Funktiokohtainen 10 s aikaraja (anon-roolin oletus 3 s aiheutti satunnaisia HTTP 500 -vastauksia). Tuotannon proconfig: {search_path="",statement_timeout=10s}.
alter function public.ops_health() set statement_timeout = '10s';
