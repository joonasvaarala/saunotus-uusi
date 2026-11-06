-- booking_256: training space blocks use the existing booking-calendar exporter/mapping.
-- Bottiavustus must apply DEV then PROD before merge. No remote migration/deployment from this branch.
-- No row backfill: existing blocks 11–16 are exported on the next live run.
-- No public schema DDL, prices, tax, URLs, capacity, shifts or closure changes.
set local lock_timeout = '5s';

-- Verified against production with SELECT only, 6 Nov 2026. Fail rather than overwrite drift.
do $$ begin
  if md5(pg_get_functiondef('booking._booking_calendar_desired()'::regprocedure)) <> '93062c8b4ea9168819afba434a27dff0'
     or md5(pg_get_functiondef('booking.booking_calendar_export_plan()'::regprocedure)) <> '69a915c18f1684771d2a877e6390bb59' then
    raise exception 'booking_256: calendar function baseline changed; review before applying';
  end if;
end $$;

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
  ), training_blocks as (
    -- Stable identity per block, not per rule/day. Only these rows bypass the forward window.
    select 'event'::text as kind, 'e:block:' || b.id::text as event_key,
           null::bigint as reservation_id, sp.code as resource_code,
           case when not booking._booking_calendar_blocked(cfg #>> array['resource_calendars', sp.code])
                     and booking._calendar_id_ok(cfg #>> array['resource_calendars', sp.code])
                     and (select count(*) from jsonb_each_text(coalesce(cfg -> 'resource_calendars', '{}'::jsonb)) c
                           where btrim(c.value) = btrim(cfg #>> array['resource_calendars', sp.code])) = 1
                then nullif(btrim(cfg #>> array['resource_calendars', sp.code]), '') end as calendar_id,
           lower(x.rg) as starts_at, upper(x.rg) as ends_at,
           null::int as persons, null::int as bookings,
           booking._calendar_scrub(left(sp.name || ' – ' || p.name || ' · ' || coalesce(sr.label, ''), 180)) as summary,
           booking._calendar_scrub(concat_ws(E'\n', 'Koulutuksen tilavaraus · ' || sp.name,
             'Aikaa voi muuttaa ja tilavarauksen poistaa kalenterissa. Uusi tilavaraus luodaan vain jakson Tilat-kohdasta.',
             'Hallinta: ' || v_base || '/#/?d=' || to_char(lower(x.rg) at time zone v_tz, 'YYYY-MM-DD'))) as description
      from booking.event_resource_blocks b
      join booking.schedule_rules sr on sr.id = b.rule_id and sr.kind = 'event' and sr.active and sr.cancelled_at is null
      join kb.products p on p.id = sr.product_id and p.category = 'training'
      join booking.resources sp on sp.id = b.resource_id and sp.kind = 'space' and sp.code in ('savusauna', 'rauni', 'lovi')
      cross join lateral (select booking._event_block_range(sr.valid_from, sr.start_time, b) as rg) x
     where b.mode = 'exclusive' and upper(x.rg) > v_from
  ), all_rows as (
    select * from exclusive_events
    union all select * from ritual_events
    union all select * from event_rows
    union all select * from training_blocks
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


-- Inbound runs under the existing export lease, BEFORE any Google writes/reconciliation.
-- Only a previously exported mapping can change/delete a block. Never INSERT a block here.
create function booking.apply_training_calendar_events(p_run_id text, p_events jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  ev jsonb; m booking.booking_calendar_events; b booking.event_resource_blocks; r booking.schedule_rules;
  rg tstzrange; s timestamptz; e timestamptz; ls timestamp; le timestamp;
  n_changed int := 0; n_deleted int := 0; n_ignored int := 0; cfg jsonb;
begin
  if coalesce(booking._jwt_role(), 'service_role') <> 'service_role' then
    perform booking._err('forbidden', 'Vain palvelurooli'); end if;
  if jsonb_typeof(p_events) is distinct from 'array' or jsonb_array_length(p_events) > 1000 then
    perform booking._err('bad_payload', 'Tapahtumat ovat taulukko (enintään 1000)'); end if;
  select c.settings into cfg from booking.integration_config c where c.key = 'booking_calendar' and c.mode = 'live';
  if not found then perform booking._err('not_live', 'Synkka ei ole käytössä'); end if;
  perform 1 from booking.booking_calendar_state st where st.id = 1 and st.locked_by = p_run_id
    and st.locked_at > now() - interval '4 minutes' for update;
  if not found then perform booking._err('stale_run', 'Synkka-ajo on vanhentunut'); end if;
  for ev in select value from jsonb_array_elements(p_events) loop
    select * into m from booking.booking_calendar_events
     where event_key = ev ->> 'event_key' and event_key ~ '^e:block:[0-9]+$'
       and google_calendar_id = ev ->> 'google_calendar_id'
       and google_event_id = ev ->> 'google_event_id' and content_hash = ev ->> 'content_hash';
    if not found or booking._booking_calendar_blocked(m.google_calendar_id) then
      n_ignored := n_ignored + 1; continue; end if;
    select sr.* into r from booking.schedule_rules sr
      join booking.event_resource_blocks eb on eb.rule_id = sr.id
      join kb.products p on p.id = sr.product_id and p.category = 'training'
     where eb.id = substr(m.event_key, 9)::bigint and sr.kind = 'event' and sr.active and sr.cancelled_at is null
     for update of sr;
    if not found then n_ignored := n_ignored + 1; continue; end if;
    select * into b from booking.event_resource_blocks where id = substr(m.event_key, 9)::bigint and rule_id = r.id;
    if not found or b.mode <> 'exclusive' or not exists (
      select 1 from booking.resources sp where sp.id = b.resource_id and sp.kind = 'space'
        and sp.code in ('savusauna', 'rauni', 'lovi') and sp.code = m.resource_code
        and btrim(cfg #>> array['resource_calendars', sp.code]) = m.google_calendar_id
        and (select count(*) from jsonb_each_text(coalesce(cfg -> 'resource_calendars', '{}'::jsonb)) c
              where btrim(c.value) = m.google_calendar_id) = 1
    ) then n_ignored := n_ignored + 1; continue; end if;
    perform booking._lock_resources(array[b.resource_id]);
    select * into b from booking.event_resource_blocks where id = b.id for update;
    if not found then n_ignored := n_ignored + 1; continue; end if;
    rg := booking._event_block_range(r.valid_from, r.start_time, b);
    if ev ->> 'status' = 'cancelled' then
      delete from booking.event_resource_blocks where id = b.id;
      -- Existing FK cascade + zz_event_sync removes space_blocks (no closure outbox echo).
      n_deleted := n_deleted + 1; continue;
    end if;
    -- Explicit deletion wins; for competing TIME edits Hallinta wins. Also protects retries.
    if lower(rg) is distinct from m.starts_at or upper(rg) is distinct from m.ends_at then
      n_ignored := n_ignored + 1; continue; end if;
    if ev ->> 'status' is distinct from 'confirmed' then
      perform booking._err('bad_payload', 'Virheellinen tapahtuman tila'); end if;
    if ev ->> 'booking_source' is distinct from 'booking_calendar' or ev ->> 'booking_key' is distinct from m.event_key then
      perform booking._err('unowned_event', 'Tapahtuman alkuperä ei vastaa vientiä'); end if;
    if coalesce(ev ->> 'starts_at', '') !~* '(Z|[+-][0-9]{2}:[0-9]{2})$'
       or coalesce(ev ->> 'ends_at', '') !~* '(Z|[+-][0-9]{2}:[0-9]{2})$' then
      perform booking._err('bad_time', 'Anna kellonajat aikavyöhykkeineen'); end if;
    s := (ev ->> 'starts_at')::timestamptz; e := (ev ->> 'ends_at')::timestamptz;
    if not isfinite(s) or not isfinite(e) or e <= s then perform booking._err('bad_time', 'Virheellinen aikaväli'); end if;
    if s = m.starts_at and e = m.ends_at then continue; end if;
    ls := s at time zone booking._tz(); le := e at time zone booking._tz();
    if ls::date - r.valid_from not between -1 and 14 or le::date - r.valid_from not between -1 and 14
       or le <= ls
       or (ls at time zone booking._tz()) <> s or (le at time zone booking._tz()) <> e then
      -- Reject ambiguous DST instants not representable by the existing wall-clock block model.
      perform booking._err('bad_time', 'Tilavarauksen on pysyttävä jakson lähellä (-1..14 päivää); tarkista kesäaika'); end if;
    perform booking._expire_holds(b.resource_id);
    if exists (select 1 from booking.space_blocks sb where sb.space_id = b.resource_id and sb.active
                 and sb.event_block_id is distinct from b.id and sb.during && tstzrange(s,e,'[)'))
       or exists (select 1 from booking.v_claims c where c.resource_id = b.resource_id
                    and booking._res_active(c.status,c.hold_expires_at)
                    and not booking._event_block_is_own(b.id,c.reservation_id,c.pool_ids)
                    and tstzrange(c.claim_start,c.claim_end,'[)') && tstzrange(s,e,'[)')) then
      perform booking._err('conflict', 'Tila on jo varattu tai suljettu tälle ajalle'); end if;
    update booking.event_resource_blocks set offset_min = null, minutes = null,
      start_day = ls::date - r.valid_from, start_clock = ls::time,
      end_day = le::date - r.valid_from, end_clock = le::time where id = b.id;
    -- zz_event_sync materializes the new range; managed space_blocks are never edited directly.
    n_changed := n_changed + 1;
  end loop;
  return jsonb_build_object('ok',true,'changed',n_changed,'deleted',n_deleted,'ignored',n_ignored,
    'events',booking._booking_calendar_desired() -> 'events');
end $$;
revoke all on function booking.apply_training_calendar_events(text,jsonb) from public, anon, authenticated;
grant execute on function booking.apply_training_calendar_events(text,jsonb) to service_role;
comment on function booking.apply_training_calendar_events(text,jsonb) is
  'booking_256: mapped training space blocks only; Google time edits/deletion, no creation. Existing export lease and resource locks.';

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
  -- Migration-before-Edge rollout: old Edge callers must neither write nor delete two-way blocks.
  if coalesce(current_setting('booking.training_calendar_sync', true), '') <> 'on' then
    v_desired := jsonb_set(v_desired, '{events}', coalesce((select jsonb_agg(x) from jsonb_array_elements(v_desired -> 'events') x
      where x ->> 'event_key' !~ '^e:block:[0-9]+$'), '[]'::jsonb));
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'event_key', e.event_key, 'google_calendar_id', e.google_calendar_id, 'google_event_id', e.google_event_id,
           'content_hash', e.content_hash, 'starts_at', e.starts_at, 'ends_at', e.ends_at)), '[]'::jsonb)
    into v_mapped from booking.booking_calendar_events e
      where coalesce(current_setting('booking.training_calendar_sync', true), '') = 'on' or e.event_key !~ '^e:block:[0-9]+$';
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

-- New Edge entry point, same exporter/outbox/lease. No competing scheduler.
create function booking.booking_calendar_training_export_plan() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare result jsonb; previous text := coalesce(current_setting('booking.training_calendar_sync',true),'');
begin
  if coalesce(booking._jwt_role(), 'service_role') <> 'service_role' then
    perform booking._err('forbidden', 'Vain palvelurooli'); end if;
  perform set_config('booking.training_calendar_sync','on',true);
  result := booking.booking_calendar_export_plan();
  perform set_config('booking.training_calendar_sync',previous,true);
  return result;
end $$;
revoke all on function booking.booking_calendar_training_export_plan() from public, anon, authenticated;
grant execute on function booking.booking_calendar_training_export_plan() to service_role;
