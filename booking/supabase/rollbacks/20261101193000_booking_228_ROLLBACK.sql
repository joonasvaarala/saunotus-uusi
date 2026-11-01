-- ROLLBACK booking_228_calendar_export_v2.
-- Palauttaa halutut tapahtumat booking_116:n päiväpalkkiin, suunnitelman booking_115:een
-- ja asetusten tarkistuksen booking_114:ään (vain sulkukalenteri).
-- Uuden lajin rivit poistetaan, jotta tarkistus voidaan kaventaa.
-- Viikonlopun Google-tunnus on bkv + YYYYMMDD. Etuliite ei ole bkw, koska w ei kuulu a–v.
-- modea ei muuteta. Googleen ei kirjoiteta.
set local lock_timeout = '5s';

delete from booking.booking_calendar_events
 where kind not in ('reservation', 'shift', 'day')
    or event_key !~ '^[rsd]:[A-Za-z0-9_.:|-]+$';

alter table booking.booking_calendar_events drop constraint if exists booking_calendar_events_kind_check;
alter table booking.booking_calendar_events add constraint booking_calendar_events_kind_check
  check (kind in ('reservation', 'shift', 'day'));

alter table booking.booking_calendar_events drop constraint if exists booking_calendar_events_event_key_check;
alter table booking.booking_calendar_events add constraint booking_calendar_events_event_key_check
  check (event_key ~ '^[rsd]:[A-Za-z0-9_.:|-]+$');

drop function if exists booking._booking_calendar_blocked(text);

create or replace function booking._booking_calendar_desired()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cfg jsonb; v_tz text; v_from timestamptz; v_to timestamptz; v_base text; v_cal text; v_out jsonb;
begin
  select c.settings into cfg from booking.integration_config c where c.key = 'booking_calendar';
  cfg := coalesce(cfg, '{}'::jsonb);
  v_tz := coalesce(nullif(btrim(cfg ->> 'timezone'), ''), 'Europe/Helsinki');
  v_from := now() - make_interval(days => least(greatest(coalesce((cfg ->> 'window_back_days')::int, 7), 0), 60));
  v_to := now() + make_interval(days => least(greatest(coalesce((cfg ->> 'window_forward_days')::int, 180), 1), 366));
  v_base := booking._booking_calendar_admin_base(cfg);
  v_cal := nullif(btrim(cfg ->> 'shared_calendar_id'), '');
  if v_cal is not null and exists (select 1 from booking.closure_calendars cc where cc.google_calendar_id = v_cal) then
    v_cal := null;
  end if;
  with base as (
    select r.id as reservation_id, r.mode, r.persons, r.starts_at, r.ends_at,
           (r.starts_at at time zone v_tz)::date as day,
           sp.code as resource_code, sp.name as resource_name,
           pc.sale_kind, left(p.name, 80) as product_name, o.order_no, o.customer_kind,
           case when c.anonymized_at is not null then null
                when o.customer_kind <> 'private' then booking._calendar_scrub(coalesce(o.billing ->> 'company', c.company))
                else booking._calendar_scrub(c.name) end as who,
           case when exists (select 1 from booking.closure_calendars cc where cc.google_calendar_id = booking._booking_calendar_target(sp.code, cfg))
                then null else booking._booking_calendar_target(sp.code, cfg) end as calendar_id,
           case when pc.sale_kind = 'other' and nullif(left(p.name, 80), '') is not null then left(p.name, 80)
                when o.customer_kind <> 'private' then 'yritysvaraus'
                else 'yksityisvaraus' end as type_label
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
       and sp.code not in ('ei_resurssia', 'perinnesaunotus_ryhma')
  ), priv_events as (
    select 'reservation'::text as kind,
           'r:' || b.reservation_id::text as event_key,
           b.reservation_id,
           b.resource_code,
           b.calendar_id,
           b.starts_at,
           b.ends_at,
           b.persons,
           null::int as bookings,
           booking._calendar_scrub(left(b.resource_name || ' – ' || b.type_label || ', ' || b.persons::text || ' hlö', 180)) as summary,
           booking._calendar_scrub(concat_ws(E'\n',
             'Tilaus #' || b.order_no::text,
             b.who,
             'Hallinta: ' || v_base || '/#/varaukset?q=' || b.order_no::text)) as description
      from base b where b.mode = 'exclusive'
  ), priv_lines as (
    select b.day, b.starts_at, b.resource_code, b.reservation_id as sort_id,
           booking._calendar_scrub(concat_ws(' · ',
             booking._calendar_span(b.starts_at, b.ends_at, v_tz),
             b.resource_name,
             b.type_label,
             b.persons::text || ' hlö')) as line
      from base b where b.mode = 'exclusive'
  ), grp as (
    select b.day, b.resource_code, min(b.resource_name) as resource_name, b.starts_at, b.ends_at,
           sum(b.persons)::int as persons, count(*)::int as n,
           case when count(distinct coalesce(b.sale_kind, '')) = 1 and min(b.sale_kind) = 'other' and count(distinct coalesce(b.product_name, '')) = 1
                then min(b.product_name) else null end as event_label
      from base b where b.mode = 'shared'
     group by b.day, b.resource_code, b.starts_at, b.ends_at
  ), shift_lines as (
    select g.day, g.starts_at, g.resource_code, 0::bigint as sort_id,
           booking._calendar_scrub(concat_ws(' · ',
             booking._calendar_span(g.starts_at, g.ends_at, v_tz),
             g.resource_name,
             coalesce(g.event_label, 'Yleinen vuoro'),
             g.persons::text || ' hlö (' || g.n::text || case when g.n = 1 then ' varaus)' else ' varausta)' end)) as line
      from grp g
  ), lined as (
    select day, starts_at, resource_code, sort_id, line from priv_lines
    union all
    select day, starts_at, resource_code, sort_id, line from shift_lines
  ), body as (
    select day, string_agg(line, E'\n' order by starts_at, resource_code, sort_id, line) as lines
      from lined group by day
  ), days as (
    select b.day, min(b.starts_at) as starts_at, max(b.ends_at) as ends_at,
           count(*)::int as bookings, sum(b.persons)::int as persons
      from base b
     group by b.day
  ), shaped as (
    select d.day, d.starts_at, d.ends_at, d.bookings, d.persons,
           booking._calendar_scrub(left('Varaukset ' ||
             case
               when (d.ends_at at time zone v_tz)::date > d.day
                and to_char(d.ends_at at time zone v_tz, 'HH24MI') = '0000'
               then booking._calendar_hm(d.starts_at, v_tz) || '–24'
               when (d.ends_at at time zone v_tz)::date > d.day
               then booking._calendar_span(d.starts_at, d.ends_at, v_tz) || ' +1'
               else booking._calendar_span(d.starts_at, d.ends_at, v_tz)
             end
             || ' · ' || d.persons::text || ' hlö (' || d.bookings::text
             || case when d.bookings = 1 then ' varaus)' else ' varausta)' end, 180)) as summary,
           booking._calendar_scrub(left(concat_ws(E'\n',
             b.lines,
             'Hallinta: ' || v_base || '/#/?d=' || to_char(d.day, 'YYYY-MM-DD')), 7000)) as description
      from days d
      left join body b on b.day = d.day
  ), day_events as (
    select 'day'::text as kind,
           'd:' || to_char(s.day, 'YYYY-MM-DD') as event_key,
           null::bigint as reservation_id,
           'all'::text as resource_code,
           v_cal as calendar_id,
           s.starts_at,
           s.ends_at,
           s.persons,
           s.bookings,
           s.summary,
           s.description
      from shaped s
  ), all_rows as (
    select * from priv_events
    union all
    select * from day_events
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'event_key', a.event_key,
           'kind', a.kind,
           'reservation_id', a.reservation_id,
           'resource_code', a.resource_code,
           'google_calendar_id', a.calendar_id,
           'google_event_id', case when a.kind = 'reservation' then 'bkr' || lpad(a.reservation_id::text, 8, '0')
                                   else 'bkd' || replace(substr(a.event_key, 3), '-', '') end,
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
           'day_bars', count(*) filter (where x ->> 'kind' = 'day'),
           'bookings', coalesce(sum((x ->> 'bookings')::int) filter (where x ->> 'kind' = 'day'), 0),
           'persons', coalesce(sum((x ->> 'persons')::int) filter (where x ->> 'kind' = 'day'), 0),
           'unconfigured', count(*) filter (where nullif(x ->> 'google_calendar_id', '') is null))
    into ev
    from jsonb_array_elements(d -> 'events') x;
  return jsonb_build_object('ok', true, 'sent', false, 'window_from', d -> 'window_from', 'window_to', d -> 'window_to') || coalesce(ev, '{}'::jsonb);
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
      if v_key !~ '^[rsd]:[A-Za-z0-9_.:|-]+$' or v_eid !~ '^[a-v0-9]{5,128}$' or not booking._calendar_id_ok(v_cal) or v_cal = '' then
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
         last_reconcile_at = case
           when coalesce(v_mode, 'off') = 'live' and p -> 'reconcile' = 'true'::jsonb and nullif(p ->> 'error', '') is null then now()
           else s.last_reconcile_at end,
         locked_at = case when p ->> 'run_id' is null or s.locked_by is not distinct from p ->> 'run_id' then null else s.locked_at end,
         locked_by = case when p ->> 'run_id' is null or s.locked_by is not distinct from p ->> 'run_id' then null else s.locked_by end
   where s.id = 1;
  return jsonb_build_object('ok', true, 'upserted', n_up, 'deleted', n_del);
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
  if v_mode = 'dry_run' then
    return jsonb_build_object('ok', true, 'mode', 'dry_run', 'busy', false, 'reconcile', v_reconcile,
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
  return jsonb_build_object('ok', true, 'mode', 'live', 'busy', false, 'run_id', v_run, 'reconcile', v_reconcile,
    'timezone', v_desired ->> 'timezone', 'window_from', v_desired -> 'window_from', 'window_to', v_desired -> 'window_to',
    'events', v_desired -> 'events', 'mapped', v_mapped,
    'closure_calendar_ids', coalesce((select jsonb_agg(c.google_calendar_id) from booking.closure_calendars c where c.google_calendar_id is not null), '[]'::jsonb));
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
   set notes = 'Yksi yhteinen Varaukset-kalenteri (shared_calendar_id) ja resurssin nimi otsikossa. resource_calendars ohittaa yhteisen kalenterin resurssikohtaisesti. Tyhjät tunnisteet eivät kirjoita. Älä käytä sulkukalenterien id:tä. mode off ei vie mitään.'
 where key = 'booking_calendar';

comment on function booking._booking_calendar_desired() is
  'Päiväpalkki jokaiselle päivälle, jolla on ≥1 vahvistettu varaus. booking_116.';
comment on function booking.admin_booking_calendar_preview() is
  'Esikatselu: yksityiset tapahtumat ja päiväpalkit. Ei lähetä. booking_116.';
comment on function booking.booking_calendar_export_plan() is
  'Edge: halutut tapahtumat. reconcile=true kun täydestä kirjoituksesta on yli tunti. booking_115.';
comment on function booking.admin_set_booking_calendar(jsonb) is
  'Asetukset: vienti off/dry_run/live ja kalenteritunnisteet. Sulkukalenterin id hylätään. Oletus off. booking_114.';
