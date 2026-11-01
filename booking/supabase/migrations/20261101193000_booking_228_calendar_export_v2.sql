-- booking_228_calendar_export_v2 (1.11.2026)
-- Yksisuuntainen vienti kolmeen resurssikalenteriin: Savusauna, Rauni, Lovi
-- (integration_config booking_calendar.settings.resource_calendars). shared_calendar_id on vain varalla.
-- Ei kind_calendars-karttaa.
-- Tapahtumat:
--   r:  yksityisvaraus tai hoito (oma tapahtuma, bkr)
--   l:  20 min Raunin rituaali (kb 7 ja kb 8), ryhmitelty alun mukaan (bkl)
--   e:  tapahtumakerta, myös ei_resurssia (bke). Ilman Rauni/Lovi-kotia → Savusauna.
--   s:  arjen yleinen vuoro, vain jos vähintään yksi varaus, koko vuoro säännön mukaan (bks).
--       Turvetorstai 16–17 on oma tapahtuma, erillään torstain yleisestä vuorosta.
--   w:  la–su yksi palkki Savusaunan kalenterissa ensimmäisestä varatusta yleisestä vuorosta
--       viimeisen loppuun (bkv + YYYYMMDD; w ei kelpaa Google-tunnukseen). Mukana kb 7:n savusaunaosa. Ei tapahtumia, rituaaleja,
--       yksityisvarauksia eikä hoitoja.
-- Vanhaa d:/bkd-päiväpalkkia ei enää haluta. Seuraava ajo poistaa sen.
-- Sulkukalenterin ja vuorokalenterin (public.calendar_sources) tunnusta ei hyväksytä kohteeksi.
-- modea ei muuteta. Oletus pysyy off. Googleen ei kirjoiteta tästä migraatiosta.
-- Rollback: rollbacks/20261101193000_booking_228_ROLLBACK.sql
set local lock_timeout = '5s';

alter table booking.booking_calendar_events drop constraint if exists booking_calendar_events_kind_check;
alter table booking.booking_calendar_events add constraint booking_calendar_events_kind_check
  check (kind in ('reservation', 'shift', 'day', 'ritual', 'event', 'weekend'));

alter table booking.booking_calendar_events drop constraint if exists booking_calendar_events_event_key_check;
alter table booking.booking_calendar_events add constraint booking_calendar_events_event_key_check
  check (event_key ~ '^[rleswd]:[A-Za-z0-9_.:|-]+$');

create or replace function booking._booking_calendar_blocked(p_id text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(btrim(p_id), '') <> '' and (
    exists (select 1 from booking.closure_calendars c where c.google_calendar_id = btrim(p_id))
    or exists (select 1 from public.calendar_sources s where s.google_calendar_id = btrim(p_id))
  )
$$;

-- Kelpoisuus on sama kuin booking_114. Ajat tulevat vuorosäännöstä, tapahtumakerrasta
-- tai claimista, ei Johkun 30 minuutin ends_at-arvosta. Yhteystiedot siivotaan.
create or replace function booking._booking_calendar_desired()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cfg jsonb; v_tz text; v_from timestamptz; v_to timestamptz; v_base text; v_out jsonb;
begin
  select c.settings into cfg from booking.integration_config c where c.key = 'booking_calendar';
  cfg := coalesce(cfg, '{}'::jsonb);
  v_tz := coalesce(nullif(btrim(cfg ->> 'timezone'), ''), 'Europe/Helsinki');
  v_from := now() - make_interval(days => least(greatest(coalesce((cfg ->> 'window_back_days')::int, 7), 0), 60));
  v_to := now() + make_interval(days => least(greatest(coalesce((cfg ->> 'window_forward_days')::int, 180), 1), 366));
  v_base := booking._booking_calendar_admin_base(cfg);
  with elig as (
    select r.id, r.product_id, r.rule_id, r.mode, r.persons, r.starts_at, r.ends_at, r.pool_ids,
           (r.starts_at at time zone v_tz)::date as day,
           (r.starts_at at time zone v_tz)::time as start_tod,
           extract(isodow from r.starts_at at time zone v_tz)::int as isodow,
           sp.code as space_code, sp.name as space_name,
           pc.sale_kind, p.category, left(p.name, 80) as product_name,
           o.order_no, o.customer_kind,
           case when c.anonymized_at is not null then null
                when o.customer_kind <> 'private' then booking._calendar_scrub(coalesce(o.billing ->> 'company', c.company))
                else booking._calendar_scrub(c.name) end as who
      from booking.reservations r
      join booking.orders o on o.id = r.order_id
      join booking.resources sp on sp.id = r.space_id
      left join booking.customers c on c.id = o.customer_id
      left join booking.product_config pc on pc.product_id = r.product_id
      left join kb.products p on p.id = r.product_id
     where r.hidden_at is null
       and r.status in ('confirmed', 'completed', 'no_show')
       and o.status in ('confirmed', 'completed')
       and o.payment_status not in ('pending', 'failed')
       and r.starts_at < v_to and r.ends_at > v_from
  ), cal as (
    select code, case when booking._booking_calendar_blocked(booking._booking_calendar_target(code, cfg))
                      then null else booking._booking_calendar_target(code, cfg) end as calendar_id
      from (values ('savusauna'), ('rauni'), ('lovi')) as t(code)
  ), matched as (
    select distinct on (e.id)
           e.*, sr.id as sched_id, sr.duration_minutes, sr.start_time as rule_start,
           left(rp.name, 80) as rule_name,
           case when exists (
                  select 1 from booking.schedule_rule_pools spj
                  join booking.resources pr on pr.id = spj.pool_id
                 where spj.rule_id = sr.id and pr.code = 'turve')
                then 'turve'
                else coalesce((
                  select pr.code from booking.schedule_rule_pools spj
                  join booking.resources pr on pr.id = spj.pool_id
                 where spj.rule_id = sr.id
                 order by pr.sort_order, pr.id limit 1), 'vuoro')
           end as pool_code
      from elig e
      join booking.schedule_rules sr
        on sr.active and sr.mode = 'shared' and coalesce(sr.kind, 'regular') = 'regular'
       and e.sale_kind = 'public_shift' and e.mode = 'shared' and e.space_code = 'savusauna'
       and e.isodow = any (sr.weekdays) and e.start_tod = sr.start_time
      join booking.resources rsp on rsp.id = sr.space_id and rsp.code = 'savusauna'
      join kb.products rp on rp.id = sr.product_id
     order by e.id,
              (sr.product_id = e.product_id) desc,
              (coalesce(e.pool_ids, '{}'::bigint[]) && coalesce((select array_agg(spj.pool_id) from booking.schedule_rule_pools spj where spj.rule_id = sr.id), '{}'::bigint[])) desc,
              sr.id
  ), clip as (
    select sr.id as sched_id,
           (select min(n.start_time)
              from booking.schedule_rules n
             where n.id <> sr.id and n.active and n.mode = 'shared' and coalesce(n.kind, 'regular') = 'regular'
               and n.weekdays && sr.weekdays
               and n.start_time > sr.start_time
               and n.start_time < sr.start_time + make_interval(mins => sr.duration_minutes)) as next_start
      from booking.schedule_rules sr
     where exists (
       select 1 from booking.schedule_rule_pools spj
       join booking.resources pr on pr.id = spj.pool_id
      where spj.rule_id = sr.id and pr.code = 'turve')
  ), shifts as (
    select m.day, m.isodow, m.sched_id, m.pool_code, min(m.rule_name) as rule_name,
           ((m.day + m.rule_start) at time zone v_tz) as starts_at,
           ((m.day + m.rule_start) at time zone v_tz)
             + make_interval(mins => case
                  when m.pool_code = 'turve' and cl.next_start is not null
                  then (extract(epoch from (cl.next_start - m.rule_start)) / 60)::int
                  else m.duration_minutes end) as ends_at,
           sum(m.persons)::int as persons, count(*)::int as n
      from matched m
      left join clip cl on cl.sched_id = m.sched_id
     group by m.day, m.isodow, m.sched_id, m.pool_code, m.rule_start, m.duration_minutes, cl.next_start
  ), weekday_events as (
    select 'shift'::text as kind,
           's:' || s.pool_code || ':' || to_char(s.starts_at at time zone v_tz, 'YYYY-MM-DD"T"HH24:MI') as event_key,
           null::bigint as reservation_id, 'savusauna'::text as resource_code,
           (select calendar_id from cal where code = 'savusauna') as calendar_id,
           s.starts_at, s.ends_at, s.persons, s.n as bookings,
           booking._calendar_scrub(left(s.rule_name || ' ' || booking._calendar_span(s.starts_at, s.ends_at, v_tz)
             || ' · ' || s.persons::text || ' hlö (' || s.n::text
             || case when s.n = 1 then ' varaus)' else ' varausta)' end, 180)) as summary,
           booking._calendar_scrub(left(concat_ws(E'\n',
             s.persons::text || ' hlö, ' || s.n::text || case when s.n = 1 then ' varaus' else ' varausta' end,
             'Hallinta: ' || v_base || '/#/?d=' || to_char(s.day, 'YYYY-MM-DD')), 7000)) as description
      from shifts s
     where s.isodow between 1 and 5
  ),   kb7 as (
    select distinct on (e.id)
           e.id, e.persons, e.product_name,
           e.starts_at + make_interval(mins => savu.offset_min) as savu_start,
           e.starts_at + make_interval(mins => savu.offset_min + savu.minutes) as savu_end
      from elig e
      join booking.product_space_rules savu
        on savu.product_id = e.product_id and savu.active and savu.role = 'space' and savu.minutes is not null
      join booking.resources ssp on ssp.id = savu.space_id and ssp.code = 'savusauna'
      join booking.product_space_rules ritu
        on ritu.product_id = e.product_id and ritu.active and ritu.role = 'space' and ritu.minutes = 20
      join booking.resources rsp on rsp.id = ritu.space_id and rsp.code = 'rauni'
     where e.category = 'ritual' and e.mode = 'shared'
     order by e.id, savu.leg_no, ritu.leg_no
  ), weekend_parts as (
    select s.day, s.starts_at, s.ends_at, s.persons, s.n as bookings, s.rule_name as label
      from shifts s
     where s.isodow in (6, 7)
    union all
    select (k.savu_start at time zone v_tz)::date, k.savu_start, k.savu_end, k.persons, 1, k.product_name
      from kb7 k
     where extract(isodow from k.savu_start at time zone v_tz) in (6, 7)
  ), weekend_body as (
    select day, string_agg(booking._calendar_scrub(booking._calendar_span(starts_at, ends_at, v_tz) || ' · ' || label || ' · ' || persons::text || ' hlö'),
                           E'\n' order by starts_at, label) as lines
      from weekend_parts
     group by day
  ), weekend_events as (
    select 'weekend'::text as kind,
           'w:' || to_char(p.day, 'YYYY-MM-DD') as event_key,
           null::bigint as reservation_id, 'savusauna'::text as resource_code,
           (select calendar_id from cal where code = 'savusauna') as calendar_id,
           min(p.starts_at) as starts_at, max(p.ends_at) as ends_at,
           sum(p.persons)::int as persons, sum(p.bookings)::int as bookings,
           booking._calendar_scrub(left('Yleiset vuorot ' || booking._calendar_span(min(p.starts_at), max(p.ends_at), v_tz)
             || ' · ' || sum(p.persons)::int::text || ' hlö (' || sum(p.bookings)::int::text
             || case when sum(p.bookings) = 1 then ' varaus)' else ' varausta)' end, 180)) as summary,
           booking._calendar_scrub(left(concat_ws(E'\n',
             b.lines,
             'Hallinta: ' || v_base || '/#/?d=' || to_char(p.day, 'YYYY-MM-DD')), 7000)) as description
      from weekend_parts p
      left join weekend_body b on b.day = p.day
     group by p.day, b.lines
  ),   ritual_rules as (
    select distinct on (psr.product_id)
           psr.product_id, coalesce(psr.offset_min, 0) as offset_min, psr.minutes
      from booking.product_space_rules psr
      join booking.resources sp on sp.id = psr.space_id and sp.code = 'rauni'
      left join booking.resources pool on pool.id = psr.pool_id
     where psr.active and psr.role = 'space' and psr.minutes = 20
       and (pool.code = 'rauni_rituaali' or pool.id is null)
     order by psr.product_id, (pool.code = 'rauni_rituaali') desc, psr.id
  ), ritual_claims as (
    select distinct on (c.reservation_id, date_trunc('minute', c.claim_start))
           c.reservation_id, date_trunc('minute', c.claim_start) as claim_start, e.persons
      from booking.v_claims c
      join elig e on e.id = c.reservation_id and e.category = 'ritual'
      join booking.resources sp on sp.id = c.resource_id and sp.code = 'rauni'
     where c.role = 'space'
       and extract(epoch from (c.claim_end - c.claim_start)) between 19 * 60 and 21 * 60
     order by c.reservation_id, date_trunc('minute', c.claim_start), c.leg_id nulls last
  ), ritual_rows as (
    select reservation_id, claim_start, persons from ritual_claims
    union all
    select e.id, date_trunc('minute', e.starts_at + make_interval(mins => rr.offset_min)), e.persons
      from elig e
      join ritual_rules rr on rr.product_id = e.product_id
     where e.category = 'ritual'
       and not exists (select 1 from ritual_claims c where c.reservation_id = e.id)
  ), ritual_sessions as (
    select claim_start as starts_at, claim_start + interval '20 minutes' as ends_at,
           sum(persons)::int as persons, count(*)::int as n
      from ritual_rows
     group by claim_start
  ), ritual_events as (
    select 'ritual'::text as kind,
           'l:rauni:' || to_char(s.starts_at at time zone v_tz, 'YYYY-MM-DD"T"HH24:MI') as event_key,
           null::bigint as reservation_id, 'rauni'::text as resource_code,
           (select calendar_id from cal where code = 'rauni') as calendar_id,
           s.starts_at, s.ends_at, s.persons, s.n as bookings,
           booking._calendar_scrub(left('Saunotusrituaali ' || booking._calendar_span(s.starts_at, s.ends_at, v_tz)
             || ' · ' || s.persons::text || ' hlö (' || s.n::text
             || case when s.n = 1 then ' varaus)' else ' varausta)' end, 180)) as summary,
           booking._calendar_scrub(left(concat_ws(E'\n',
             s.persons::text || ' hlö, ' || s.n::text || case when s.n = 1 then ' varaus' else ' varausta' end,
             'Hallinta: ' || v_base || '/#/?d=' || to_char(s.starts_at at time zone v_tz, 'YYYY-MM-DD')), 7000)) as description
      from ritual_sessions s
     where s.starts_at < v_to and s.ends_at > v_from
  ), event_rules as (
    select sr.id as rule_id, sr.product_id, sr.valid_from, sr.start_time, sr.duration_minutes,
           left(p.name, 80) as event_name,
           ((sr.valid_from + sr.start_time) at time zone v_tz) as starts_at,
           ((sr.valid_from + sr.start_time) at time zone v_tz) + make_interval(mins => sr.duration_minutes) as ends_at
      from booking.schedule_rules sr
      join kb.products p on p.id = sr.product_id and p.category = 'event'
     where sr.active and sr.kind = 'event' and sr.valid_from is not null
  ), event_home as (
    select er.rule_id,
           case
             when coalesce(s.spaces, '{}'::text[]) = array['lovi']::text[] then 'lovi'
             when coalesce(s.spaces, '{}'::text[]) = array['rauni']::text[] then 'rauni'
             when coalesce(cardinality(s.spaces), 0) = 0 and coalesce(b.spaces, '{}'::text[]) = array['lovi']::text[] then 'lovi'
             when coalesce(cardinality(s.spaces), 0) = 0 and coalesce(b.spaces, '{}'::text[]) = array['rauni']::text[] then 'rauni'
             else 'savusauna'
           end as resource_code
      from event_rules er
      left join lateral (
        select array_agg(distinct sp.code order by sp.code) as spaces
          from booking.product_space_rules psr
          join booking.resources sp on sp.id = psr.space_id
         where psr.product_id = er.product_id and psr.active and psr.role = 'space'
           and sp.kind = 'space' and sp.code in ('rauni', 'lovi', 'savusauna')
      ) s on true
      left join lateral (
        select array_agg(distinct sp.code order by sp.code) as spaces
          from booking.event_resource_blocks eb
          join booking.resources sp on sp.id = eb.resource_id
         where eb.rule_id = er.rule_id and sp.kind = 'space' and sp.code in ('rauni', 'lovi', 'savusauna')
      ) b on true
  ), event_people as (
    select distinct on (e.id) e.id, er.rule_id, e.persons
      from elig e
      join event_rules er on e.category = 'event' and (
            e.rule_id = er.rule_id
         or (e.product_id = er.product_id and e.day = er.valid_from and e.start_tod = er.start_time)
         or coalesce(e.pool_ids, '{}'::bigint[]) && array[(select pr.id from booking.resources pr where pr.code = 'event_rule_' || er.rule_id::text)])
     order by e.id, (e.rule_id = er.rule_id) desc, er.rule_id
  ), event_counts as (
    select rule_id, coalesce(sum(persons), 0)::int as persons, count(*)::int as n
      from event_people
     group by rule_id
  ), event_rows as (
    select 'event'::text as kind,
           'e:' || er.rule_id::text || ':' || to_char(er.valid_from, 'YYYY-MM-DD') as event_key,
           null::bigint as reservation_id, h.resource_code,
           (select calendar_id from cal where code = h.resource_code) as calendar_id,
           er.starts_at, er.ends_at,
           coalesce(ec.persons, 0) as persons, coalesce(ec.n, 0) as bookings,
           booking._calendar_scrub(left(er.event_name || ' ' || booking._calendar_span(er.starts_at, er.ends_at, v_tz)
             || ' · ' || coalesce(ec.persons, 0)::text || ' hlö (' || coalesce(ec.n, 0)::text
             || case when coalesce(ec.n, 0) = 1 then ' varaus)' else ' varausta)' end, 180)) as summary,
           booking._calendar_scrub(left(concat_ws(E'\n',
             coalesce(ec.persons, 0)::text || ' hlö, ' || coalesce(ec.n, 0)::text
             || case when coalesce(ec.n, 0) = 1 then ' varaus' else ' varausta' end,
             'Hallinta: ' || v_base || '/#/?d=' || to_char(er.valid_from, 'YYYY-MM-DD')), 7000)) as description
      from event_rules er
      join event_home h on h.rule_id = er.rule_id
      left join event_counts ec on ec.rule_id = er.rule_id
     where er.starts_at < v_to and er.ends_at > v_from
  ), exclusive_events as (
    select 'reservation'::text as kind,
           'r:' || e.id::text as event_key,
           e.id as reservation_id, e.space_code as resource_code,
           case when booking._booking_calendar_blocked(booking._booking_calendar_target(e.space_code, cfg))
                then null else booking._booking_calendar_target(e.space_code, cfg) end as calendar_id,
           e.starts_at, e.ends_at, e.persons, null::int as bookings,
           booking._calendar_scrub(left(e.space_name || ' – ' || case
             when e.sale_kind = 'other' and nullif(e.product_name, '') is not null then e.product_name
             when e.customer_kind <> 'private' then 'yritysvaraus'
             else 'yksityisvaraus' end || ', ' || e.persons::text || ' hlö', 180)) as summary,
           booking._calendar_scrub(concat_ws(E'\n',
             'Tilaus #' || e.order_no::text,
             e.who,
             'Hallinta: ' || v_base || '/#/varaukset?q=' || e.order_no::text)) as description
      from elig e
     where e.mode = 'exclusive'
       and e.space_code not in ('ei_resurssia', 'perinnesaunotus_ryhma')
       and coalesce(e.category, '') not in ('event', 'ritual')
  ), all_rows as (
    select * from exclusive_events
    union all select * from ritual_events
    union all select * from event_rows
    union all select * from weekday_events
    union all select * from weekend_events
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'event_key', a.event_key,
           'kind', a.kind,
           'reservation_id', a.reservation_id,
           'resource_code', a.resource_code,
           'google_calendar_id', a.calendar_id,
           'google_event_id', case
             when a.kind = 'reservation' then 'bkr' || lpad(a.reservation_id::text, 8, '0')
             when a.kind = 'weekend' then 'bkv' || replace(substr(a.event_key, 3), '-', '')
             when a.kind = 'ritual' then 'bkl' || substr(md5(a.event_key), 1, 24)
             when a.kind = 'event' then 'bke' || substr(md5(a.event_key), 1, 24)
             else 'bks' || substr(md5(a.event_key), 1, 24) end,
           'summary', a.summary,
           'description', a.description,
           'starts_at', a.starts_at,
           'ends_at', a.ends_at,
           'content_hash', md5(concat_ws('|', a.summary, a.description, a.starts_at::text, a.ends_at::text, coalesce(a.calendar_id, ''))),
           'timezone', v_tz,
           'persons', a.persons,
           'bookings', a.bookings) order by a.starts_at, a.event_key), '[]'::jsonb)
    into v_out
    from all_rows a;
  return jsonb_build_object('timezone', v_tz, 'window_from', v_from, 'window_to', v_to, 'events', v_out);
end $$;

create or replace function booking.admin_booking_calendar_preview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare d jsonb; ev jsonb;
begin
  perform booking._require_permission('settings.edit');
  d := booking._booking_calendar_desired();
  select jsonb_build_object(
           'private_events', count(*) filter (where x ->> 'kind' = 'reservation'),
           'ritual_sessions', count(*) filter (where x ->> 'kind' = 'ritual'),
           'events', count(*) filter (where x ->> 'kind' = 'event'),
           'weekday_shifts', count(*) filter (where x ->> 'kind' = 'shift'),
           'weekend_bars', count(*) filter (where x ->> 'kind' = 'weekend'),
           'day_bars', count(*) filter (where x ->> 'kind' = 'day'),
           'unconfigured', count(*) filter (where nullif(x ->> 'google_calendar_id', '') is null))
    into ev
    from jsonb_array_elements(d -> 'events') x;
  return jsonb_build_object('ok', true, 'sent', false, 'window_from', d -> 'window_from', 'window_to', d -> 'window_to') || coalesce(ev, '{}'::jsonb);
end $$;

create or replace function booking.booking_calendar_export_plan()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_mode text; v_run text; v_locked text; v_desired jsonb; v_mapped jsonb; v_reconcile boolean;
  v_closure jsonb; v_shift jsonb;
begin
  if coalesce(booking._jwt_role(), 'service_role') <> 'service_role' then perform booking._err('forbidden', 'Vain palvelurooli'); end if;
  select c.mode into v_mode from booking.integration_config c where c.key = 'booking_calendar';
  v_mode := coalesce(v_mode, 'off');
  if v_mode = 'off' then
    return jsonb_build_object('ok', true, 'mode', 'off', 'events', '[]'::jsonb, 'mapped', '[]'::jsonb);
  end if;
  if v_mode not in ('dry_run', 'live') then perform booking._err('invalid_setting', 'Tila on off, dry_run tai live'); end if;
  select coalesce(s.last_reconcile_at < now() - interval '1 hour', true)
    into v_reconcile
    from booking.booking_calendar_state s where s.id = 1;
  v_reconcile := coalesce(v_reconcile, true);
  v_desired := booking._booking_calendar_desired();
  select coalesce(jsonb_agg(jsonb_build_object(
           'event_key', e.event_key, 'google_calendar_id', e.google_calendar_id, 'google_event_id', e.google_event_id,
           'content_hash', e.content_hash, 'starts_at', e.starts_at, 'ends_at', e.ends_at)), '[]'::jsonb)
    into v_mapped from booking.booking_calendar_events e;
  select coalesce(jsonb_agg(c.google_calendar_id), '[]'::jsonb) into v_closure
    from booking.closure_calendars c where c.google_calendar_id is not null;
  select coalesce(jsonb_agg(s.google_calendar_id), '[]'::jsonb) into v_shift
    from public.calendar_sources s where s.google_calendar_id is not null;
  if v_mode = 'dry_run' then
    return jsonb_build_object('ok', true, 'mode', 'dry_run', 'busy', false, 'reconcile', v_reconcile,
      'timezone', v_desired ->> 'timezone', 'window_from', v_desired -> 'window_from', 'window_to', v_desired -> 'window_to',
      'events', v_desired -> 'events', 'mapped', v_mapped,
      'closure_calendar_ids', v_closure, 'shift_calendar_ids', v_shift);
  end if;
  v_run := gen_random_uuid()::text;
  update booking.booking_calendar_state s
     set locked_at = now(), locked_by = v_run
   where s.id = 1 and (s.locked_at is null or s.locked_at < now() - interval '4 minutes')
  returning s.locked_by into v_locked;
  if v_locked is null then
    return jsonb_build_object('ok', true, 'mode', 'live', 'busy', true);
  end if;
  return jsonb_build_object('ok', true, 'mode', 'live', 'busy', false, 'run_id', v_run, 'reconcile', v_reconcile,
    'timezone', v_desired ->> 'timezone', 'window_from', v_desired -> 'window_from', 'window_to', v_desired -> 'window_to',
    'events', v_desired -> 'events', 'mapped', v_mapped,
    'closure_calendar_ids', v_closure, 'shift_calendar_ids', v_shift);
end $$;

create or replace function booking.booking_calendar_export_finish(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  u jsonb; v_key text; v_cal text; v_eid text; n_up int := 0; n_del int := 0; v_mode text;
begin
  if coalesce(booking._jwt_role(), 'service_role') <> 'service_role' then perform booking._err('forbidden', 'Vain palvelurooli'); end if;
  if p is null or jsonb_typeof(p) <> 'object' then perform booking._err('bad_payload', 'Viimeistely on objekti'); end if;
  select c.mode into v_mode from booking.integration_config c where c.key = 'booking_calendar';
  if coalesce(jsonb_array_length(p -> 'upserts'), 0) > 0 then
    for u in select value from jsonb_array_elements(p -> 'upserts') loop
      v_key := u ->> 'event_key'; v_cal := btrim(u ->> 'google_calendar_id'); v_eid := u ->> 'google_event_id';
      if coalesce(u ->> 'kind', '') not in ('reservation', 'shift', 'day', 'ritual', 'event', 'weekend')
         or v_key !~ '^[rleswd]:[A-Za-z0-9_.:|-]+$' or v_eid !~ '^[a-v0-9]{5,128}$' or not booking._calendar_id_ok(v_cal) or v_cal = '' then
        perform booking._err('bad_payload', 'Tapahtuman tunniste ei kelpaa');
      end if;
      if exists (select 1 from booking.closure_calendars c where c.google_calendar_id = v_cal) then
        perform booking._err('closure_calendar', 'Sulkukalenteriin ei kirjoiteta');
      end if;
      if exists (select 1 from public.calendar_sources s where s.google_calendar_id = v_cal) then
        perform booking._err('shift_calendar', 'Vuorokalenteriin ei kirjoiteta');
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
         last_reconcile_at = case
           when coalesce(v_mode, 'off') = 'live' and p -> 'reconcile' = 'true'::jsonb and nullif(p ->> 'error', '') is null then now()
           else s.last_reconcile_at end,
         locked_at = case when p ->> 'run_id' is null or s.locked_by is not distinct from p ->> 'run_id' then null else s.locked_at end,
         locked_by = case when p ->> 'run_id' is null or s.locked_by is not distinct from p ->> 'run_id' then null else s.locked_by end
   where s.id = 1;
  return jsonb_build_object('ok', true, 'upserted', n_up, 'deleted', n_del);
end $$;

create or replace function booking.admin_set_booking_calendar(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  cur booking.integration_config;
  v_mode text; v_tz text; v_back int; v_fwd int; v_admin text; v_shared text; v_fast boolean;
  src jsonb; k text; v text; cleaned jsonb := '{}'::jsonb;
begin
  perform booking._require_permission('settings.edit');
  if p is null or jsonb_typeof(p) <> 'object' then perform booking._err('invalid_setting', 'Asetusten pitää olla objekti'); end if;
  if booking._json_has_secret_key(p) then perform booking._err('secrets_not_allowed', 'Salaisuuksia ei tallenneta asetuksiin'); end if;
  select * into cur from booking.integration_config where key = 'booking_calendar';
  if not found then perform booking._err('not_configured', 'booking_calendar-asetus puuttuu'); end if;
  v_mode := coalesce(nullif(btrim(p ->> 'mode'), ''), cur.mode);
  if v_mode not in ('off', 'dry_run', 'live') then perform booking._err('invalid_setting', 'Tila on off, dry_run tai live'); end if;
  v_tz := coalesce(nullif(btrim(p ->> 'timezone'), ''), nullif(btrim(cur.settings ->> 'timezone'), ''), 'Europe/Helsinki');
  begin
    perform now() at time zone v_tz;
  exception when others then
    perform booking._err('invalid_setting', 'Aikavyöhyke ei kelpaa');
  end;
  if p ? 'window_back_days' then
    if jsonb_typeof(p -> 'window_back_days') <> 'number' then perform booking._err('invalid_setting', 'Ikkuna taaksepäin on luku'); end if;
    v_back := (p ->> 'window_back_days')::int;
  else v_back := coalesce((cur.settings ->> 'window_back_days')::int, 7); end if;
  if p ? 'window_forward_days' then
    if jsonb_typeof(p -> 'window_forward_days') <> 'number' then perform booking._err('invalid_setting', 'Ikkuna eteenpäin on luku'); end if;
    v_fwd := (p ->> 'window_forward_days')::int;
  else v_fwd := coalesce((cur.settings ->> 'window_forward_days')::int, 180); end if;
  if v_back < 0 or v_back > 60 or v_fwd < 1 or v_fwd > 366 then perform booking._err('invalid_setting', 'Ikkuna on 0–60 päivää taakse ja 1–366 eteen'); end if;
  if p ? 'admin_base_url' then v_admin := btrim(coalesce(p ->> 'admin_base_url', ''));
  else v_admin := btrim(coalesce(cur.settings ->> 'admin_base_url', '')); end if;
  if v_admin <> '' and (v_admin !~ '^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?/?$' or v_admin ~ '://[^/]*@' or char_length(v_admin) > 300) then
    perform booking._err('invalid_setting', 'Hallinnan osoite on https-osoite ilman tunnuksia');
  end if;
  if p ? 'shared_calendar_id' then v_shared := btrim(coalesce(p ->> 'shared_calendar_id', ''));
  else v_shared := btrim(coalesce(cur.settings ->> 'shared_calendar_id', '')); end if;
  if not booking._calendar_id_ok(v_shared) then perform booking._err('invalid_calendar', 'Yhteisen kalenterin tunnus ei kelpaa'); end if;
  if v_shared <> '' and exists (select 1 from booking.closure_calendars c where c.google_calendar_id = v_shared) then
    perform booking._err('closure_calendar', 'Sulkukalenteria ei käytetä varauksille');
  end if;
  if v_shared <> '' and exists (select 1 from public.calendar_sources s where s.google_calendar_id = v_shared) then
    perform booking._err('shift_calendar', 'Vuorokalenteria ei käytetä varauksille');
  end if;
  if p ? 'fast_nudge' and jsonb_typeof(p -> 'fast_nudge') is distinct from 'boolean' then
    perform booking._err('invalid_setting', 'Nopea päivitys on totuusarvo');
  end if;
  v_fast := case when p ? 'fast_nudge' then (p ->> 'fast_nudge')::boolean else coalesce((cur.settings ->> 'fast_nudge')::boolean, false) end;
  src := case when p ? 'resource_calendars' then p -> 'resource_calendars' else coalesce(cur.settings -> 'resource_calendars', '{}'::jsonb) end;
  if jsonb_typeof(src) <> 'object' then perform booking._err('invalid_setting', 'Resurssikalenterit ovat objekti'); end if;
  for k, v in select key, btrim(value) from jsonb_each_text(src) loop
    if v = '' then continue; end if;
    if not exists (select 1 from booking.resources r where r.code = k and r.kind = 'space' and r.code not in ('ei_resurssia', 'perinnesaunotus_ryhma')) then
      perform booking._err('unknown_resource', 'Tuntematon resurssi');
    end if;
    if not booking._calendar_id_ok(v) then perform booking._err('invalid_calendar', 'Kalenterin tunnus ei kelpaa'); end if;
    if exists (select 1 from booking.closure_calendars c where c.google_calendar_id = v) then
      perform booking._err('closure_calendar', 'Sulkukalenteria ei käytetä varauksille');
    end if;
    if exists (select 1 from public.calendar_sources s where s.google_calendar_id = v) then
      perform booking._err('shift_calendar', 'Vuorokalenteria ei käytetä varauksille');
    end if;
    cleaned := cleaned || jsonb_build_object(k, v);
  end loop;
  update booking.integration_config
     set mode = v_mode,
         settings = jsonb_strip_nulls(jsonb_build_object(
           'timezone', v_tz,
           'window_back_days', v_back,
           'window_forward_days', v_fwd,
           'admin_base_url', nullif(v_admin, ''),
           'shared_calendar_id', nullif(v_shared, ''),
           'resource_calendars', cleaned,
           'fast_nudge', v_fast)),
         updated_at = now(),
         updated_by = auth.uid()
   where key = 'booking_calendar';
  return booking.admin_get_booking_calendar();
end $$;

update booking.integration_config
   set notes = 'booking_228: kolme resurssikalenteria (resource_calendars: savusauna, rauni, lovi). shared_calendar_id on vain varalla. Sulku- ja vuorokalenterien tunnuksia ei hyväksytä. mode off ei vie mitään.'
 where key = 'booking_calendar';

revoke all on function booking._booking_calendar_blocked(text) from public, anon, authenticated;
grant execute on function booking._booking_calendar_blocked(text) to service_role;

comment on function booking._booking_calendar_blocked(text) is
  'Tosi, jos tunnus on sulkukalenteri tai vuorokalenteri (public.calendar_sources). booking_228.';
comment on function booking._booking_calendar_desired() is
  'Resurssikalenterien vienti: hoidot, yksityiset, rituaalit, tapahtumat, arjen vuorot ja viikonlopun palkki. Ei päiväpalkkia. booking_228.';
comment on function booking.admin_booking_calendar_preview() is
  'Esikatselu lajeittain. Ei lähetä. booking_228.';
comment on function booking.booking_calendar_export_plan() is
  'Edge: halutut tapahtumat. closure_calendar_ids ja shift_calendar_ids ovat kiellettyjä kohteita. booking_228.';
comment on function booking.admin_set_booking_calendar(jsonb) is
  'Asetukset. Sulku- ja vuorokalenterin tunnus hylätään. Oletus off. booking_228.';
