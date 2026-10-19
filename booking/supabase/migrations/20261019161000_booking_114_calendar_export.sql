-- booking_114_calendar_export (19.10.2026)
-- Yksisuuntainen vienti: vahvistetut varaukset -> erillinen Google-kalenteri.
-- Sulkukalenterit (booking-closure-sync) eivät muutu. Kalenterissa tehty muutos ei muuta varausta;
-- seuraava ajo kirjoittaa tapahtuman uudelleen varausjärjestelmän tiedoista.
-- Kohde on konfiguroitava (integration_config.key = booking_calendar). Oletus mode = off:
-- ajastus on olemassa, mutta se ei kutsu Edgeä eikä Googlea ennen kuin tila on dry_run tai live.
-- Kalenteri-id:t ja tili vaihdetaan asetuksesta, ei koodista.
-- Ei salaisuuksia. Google-palvelutili on sama kuin sulkusynkassa (Edge-salaisuus).
-- Rollback: rollbacks/20261019161000_booking_114_ROLLBACK.sql
set local lock_timeout = '5s';

alter table booking.integration_config drop constraint if exists integration_config_key_check;
alter table booking.integration_config add constraint integration_config_key_check
  check (key in ('resend', 'vismapay', 'procountor', 'mobilepay', 'booking_calendar'));

insert into booking.integration_config(key, mode, settings, notes)
values (
  'booking_calendar',
  'off',
  jsonb_build_object(
    'timezone', 'Europe/Helsinki',
    'window_back_days', 7,
    'window_forward_days', 180,
    'admin_base_url', '',
    'shared_calendar_id', '',
    'resource_calendars', '{}'::jsonb,
    'fast_nudge', false),
  'Yksi yhteinen Varaukset-kalenteri (shared_calendar_id) ja resurssin nimi otsikossa. resource_calendars ohittaa yhteisen kalenterin resurssikohtaisesti. Tyhjät tunnisteet eivät kirjoita. Älä käytä sulkukalenterien id:tä. mode off ei vie mitään.')
on conflict (key) do nothing;

create table if not exists booking.booking_calendar_state (
  id              smallint primary key check (id = 1),
  nudge_at        timestamptz,
  last_attempt_at timestamptz,
  last_success_at timestamptz,
  last_error      text,
  last_stats      jsonb,
  locked_at       timestamptz,
  locked_by       text
);
insert into booking.booking_calendar_state(id) values (1) on conflict (id) do nothing;

create table if not exists booking.booking_calendar_events (
  id                 bigint generated always as identity primary key,
  event_key          text not null unique,
  kind               text not null check (kind in ('reservation', 'shift')),
  reservation_id     bigint references booking.reservations(id) on delete set null,
  resource_code      text not null,
  google_calendar_id text not null,
  google_event_id    text not null,
  content_hash       text not null,
  starts_at          timestamptz not null,
  ends_at            timestamptz not null,
  updated_at         timestamptz not null default now(),
  unique (google_calendar_id, google_event_id),
  check (google_event_id ~ '^[a-v0-9]{5,128}$'),
  check (event_key ~ '^[rs]:[A-Za-z0-9_.:|-]+$')
);
create index if not exists booking_calendar_events_window_idx on booking.booking_calendar_events(starts_at, ends_at);

alter table booking.booking_calendar_state enable row level security;
alter table booking.booking_calendar_events enable row level security;
revoke all on booking.booking_calendar_state, booking.booking_calendar_events from public, anon, authenticated;
grant all on booking.booking_calendar_state, booking.booking_calendar_events to service_role;

-- Nimi tai yrityksen nimi kalenteriin. Sähköposti ja puhelin poistetaan. Uutta riviä ei luoda asiakkaasta.
create or replace function booking._calendar_scrub(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(btrim(regexp_replace(regexp_replace(regexp_replace(coalesce(p_text, ''),
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '', 'g'),
    '(^|[[:space:]])((\+|00|0)[0-9][0-9 .()-]{5,20}[0-9])', '\1', 'g'),
    '[ \t]{2,}', ' ', 'g')), '')
$$;

create or replace function booking._calendar_id_ok(p_id text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_id is null or btrim(p_id) = '' or (
    char_length(btrim(p_id)) between 8 and 200
    and btrim(p_id) !~ '[[:space:]/\\]'
    and (btrim(p_id) ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
      or btrim(p_id) ~ '^[A-Za-z0-9_-]{8,200}$'))
$$;

create or replace function booking._calendar_hm(p_ts timestamptz, p_tz text)
returns text
language sql
stable
set search_path = ''
as $$
  select case when to_char(p_ts at time zone p_tz, 'MI') = '00'
              then to_char(p_ts at time zone p_tz, 'HH24')
              else to_char(p_ts at time zone p_tz, 'HH24:MI') end
$$;

create or replace function booking._calendar_span(p_start timestamptz, p_end timestamptz, p_tz text)
returns text
language sql
stable
set search_path = ''
as $$
  select booking._calendar_hm(p_start, p_tz) || '–' || booking._calendar_hm(p_end, p_tz)
$$;

create or replace function booking._booking_calendar_target(p_code text, p_settings jsonb)
returns text
language sql
stable
set search_path = ''
as $$
  select nullif(btrim(coalesce(
    nullif(btrim(p_settings #>> array['resource_calendars', p_code]), ''),
    nullif(btrim(p_settings ->> 'shared_calendar_id'), ''))), '')
$$;

create or replace function booking._booking_calendar_admin_base(p_settings jsonb)
returns text
language sql
stable
set search_path = ''
as $$
  select regexp_replace(coalesce(
    nullif(btrim(p_settings ->> 'admin_base_url'), ''),
    rtrim(coalesce(booking._setting('site_base_url') #>> '{}', ''), '/') || '/hallinta'), '/+$', '')
$$;

-- Vientikelpoiset tapahtumat ikkunassa. Jaettu varaus = yksi palkki per resurssi ja tarkka alku+loppu.
-- Yksinoikeus (yksityinen, yritys, hoito, saunotus) = yksi tapahtuma. Piilotetut lisäpalvelut ja virtuaaliresurssit eivät lähde.
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
  with base as (
    select r.id as reservation_id, r.mode, r.persons, r.starts_at, r.ends_at,
           sp.code as resource_code, sp.name as resource_name,
           pc.sale_kind, left(p.name, 80) as product_name, o.order_no, o.customer_kind,
           case when c.anonymized_at is not null then null
                when o.customer_kind <> 'private' then booking._calendar_scrub(coalesce(o.billing ->> 'company', c.company))
                else booking._calendar_scrub(c.name) end as who,
           case when exists (select 1 from booking.closure_calendars cc where cc.google_calendar_id = booking._booking_calendar_target(sp.code, cfg))
                then null else booking._booking_calendar_target(sp.code, cfg) end as calendar_id
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
  ), priv as (
    select 'reservation'::text as kind, 'r:' || b.reservation_id::text as event_key, b.reservation_id,
           b.resource_code, b.calendar_id, b.starts_at, b.ends_at,
           b.persons,
           booking._calendar_scrub(left(b.resource_name || ' – ' || case
             when b.sale_kind = 'other' and nullif(b.product_name, '') is not null then b.product_name
             when b.customer_kind <> 'private' then 'yritysvaraus'
             else 'yksityisvaraus' end || ', ' || b.persons::text || ' hlö', 180)) as summary,
           booking._calendar_scrub(concat_ws(E'\n',
             'Tilaus #' || b.order_no::text,
             b.who,
             'Hallinta: ' || v_base || '/#/varaukset?q=' || b.order_no::text)) as description
      from base b where b.mode = 'exclusive'
  ), grp as (
    select b.resource_code, min(b.resource_name) as resource_name, b.starts_at, b.ends_at,
           sum(b.persons)::int as persons, count(*)::int as n,
           case when count(distinct coalesce(b.sale_kind, '')) = 1 and min(b.sale_kind) = 'other' and count(distinct coalesce(b.product_name, '')) = 1
                then min(b.product_name) else null end as event_label,
           (array_agg(b.calendar_id))[1] as calendar_id,
           string_agg('#' || b.order_no::text, ', ' order by b.order_no) as orders
      from base b where b.mode = 'shared'
     group by b.resource_code, b.starts_at, b.ends_at
  ), shifts as (
    select 'shift'::text as kind,
           's:' || g.resource_code || '|' || to_char(g.starts_at at time zone 'UTC', 'YYYYMMDDHH24MISSUS') || '|' || to_char(g.ends_at at time zone 'UTC', 'YYYYMMDDHH24MISSUS') as event_key,
           null::bigint as reservation_id, g.resource_code, g.calendar_id, g.starts_at, g.ends_at, g.persons,
           booking._calendar_scrub(left(g.resource_name || ' · ' || coalesce(g.event_label, 'Yleinen vuoro') || ' ' || booking._calendar_span(g.starts_at, g.ends_at, v_tz)
             || ' · ' || g.persons::text || ' hlö (' || g.n::text || case when g.n = 1 then ' varaus)' else ' varausta)' end, 180)) as summary,
           booking._calendar_scrub(concat_ws(E'\n',
             g.persons::text || ' hlö, ' || g.n::text || case when g.n = 1 then ' varaus' else ' varausta' end,
             'Tilaukset: ' || g.orders,
             'Hallinta: ' || v_base || '/#/?d=' || to_char(g.starts_at at time zone v_tz, 'YYYY-MM-DD'))) as description
      from grp g
  ), all_rows as (
    select * from priv union all select * from shifts
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'event_key', a.event_key, 'kind', a.kind, 'reservation_id', a.reservation_id,
           'resource_code', a.resource_code, 'google_calendar_id', a.calendar_id,
           'google_event_id', case when a.kind = 'reservation' then 'bkr' || lpad(a.reservation_id::text, 8, '0')
                                   else 'bks' || substr(md5(a.event_key), 1, 24) end,
           'summary', a.summary, 'description', a.description,
           'starts_at', a.starts_at, 'ends_at', a.ends_at,
           'content_hash', md5(concat_ws('|', a.summary, a.description, a.starts_at::text, a.ends_at::text, coalesce(a.calendar_id, ''))),
           'timezone', v_tz, 'persons', a.persons) order by a.starts_at, a.event_key), '[]'::jsonb)
    into v_out from all_rows a;
  return jsonb_build_object('timezone', v_tz, 'window_from', v_from, 'window_to', v_to, 'events', v_out);
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

create or replace function booking.admin_get_booking_calendar()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare c booking.integration_config; s booking.booking_calendar_state; resources jsonb;
begin
  perform booking._require_permission('settings.edit');
  select * into c from booking.integration_config where key = 'booking_calendar';
  select * into s from booking.booking_calendar_state where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', r.code, 'name', r.name,
           'calendar_id', coalesce(c.settings #>> array['resource_calendars', r.code], '')) order by r.sort_order), '[]'::jsonb)
    into resources
    from booking.resources r
   where r.kind = 'space' and r.active and r.code not in ('ei_resurssia', 'perinnesaunotus_ryhma');
  return jsonb_build_object(
    'ok', true,
    'mode', coalesce(c.mode, 'off'),
    'timezone', coalesce(c.settings ->> 'timezone', 'Europe/Helsinki'),
    'window_back_days', coalesce((c.settings ->> 'window_back_days')::int, 7),
    'window_forward_days', coalesce((c.settings ->> 'window_forward_days')::int, 180),
    'admin_base_url', coalesce(c.settings ->> 'admin_base_url', ''),
    'shared_calendar_id', coalesce(c.settings ->> 'shared_calendar_id', ''),
    'fast_nudge', coalesce(c.settings ->> 'fast_nudge', 'false') = 'true',
    'resources', resources,
    'last', case when s.last_attempt_at is null and s.last_success_at is null then null else jsonb_build_object(
      'attempt_at', s.last_attempt_at, 'success_at', s.last_success_at, 'error', s.last_error, 'stats', s.last_stats) end);
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
           'shift_bars', count(*) filter (where x ->> 'kind' = 'shift'),
           'unconfigured', count(*) filter (where nullif(x ->> 'google_calendar_id', '') is null),
           'shift_persons', coalesce(sum((x ->> 'persons')::int) filter (where x ->> 'kind' = 'shift'), 0))
    into ev
    from jsonb_array_elements(d -> 'events') x;
  return jsonb_build_object('ok', true, 'sent', false, 'window_from', d -> 'window_from', 'window_to', d -> 'window_to') || coalesce(ev, '{}'::jsonb);
end $$;

create or replace function booking._booking_calendar_should_nudge()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(current_setting('booking.skip_cron', true), '') <> 'on'
     and exists (
       select 1 from booking.integration_config c
        where c.key = 'booking_calendar' and c.mode in ('dry_run', 'live')
          and coalesce(c.settings ->> 'fast_nudge', 'false') = 'true')
     and exists (
       select 1 from booking.booking_calendar_state s
        where s.id = 1 and (s.last_attempt_at is null or s.last_attempt_at < now() - interval '60 seconds')
          and (s.locked_at is null or s.locked_at < now() - interval '4 minutes'))
$$;

create or replace function booking.booking_calendar_dispatch()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_mode text; v_secret text; v_url text;
begin
  if coalesce(current_setting('booking.skip_cron', true), '') = 'on' then
    return;
  end if;
  select c.mode into v_mode from booking.integration_config c where c.key = 'booking_calendar';
  if coalesce(v_mode, 'off') = 'off' then
    return;
  end if;
  select s.decrypted_secret into v_secret from vault.decrypted_secrets s where s.name = 'calendar_sync_cron_secret';
  if v_secret is null or v_secret = '' then
    raise notice 'booking calendar: calendar_sync_cron_secret puuttuu, ajo ohitetaan';
    return;
  end if;
  v_url := rtrim(coalesce(booking._setting('functions_base_url') #>> '{}', ''), '/') || '/booking-calendar-sync';
  if v_url = '/booking-calendar-sync' then
    raise notice 'booking calendar: functions_base_url puuttuu, ajo ohitetaan';
    return;
  end if;
  perform net.http_post(
    url := v_url,
    body := '{}'::jsonb,
    headers := jsonb_build_object('content-type', 'application/json', 'x-sync-secret', v_secret),
    timeout_milliseconds := 50000);
exception when undefined_function then
  raise notice 'booking calendar: pg_net puuttuu, ajo ohitetaan';
end $$;

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

drop trigger if exists booking_calendar_nudge_res on booking.reservations;
create trigger booking_calendar_nudge_res
  after insert or update or delete on booking.reservations
  for each statement execute function booking.booking_calendar_nudge();

drop trigger if exists booking_calendar_nudge_ord on booking.orders;
create trigger booking_calendar_nudge_ord
  after update of status, payment_status on booking.orders
  for each statement execute function booking.booking_calendar_nudge();

comment on table booking.booking_calendar_events is 'Varauskalenterin Google-tapahtumat. Ei asiakkaan puhelinta tai sähköpostia. booking_114.';
comment on function booking.booking_calendar_export_plan() is 'Edge: halutut tapahtumat ja lukitus, kun mode on live. off ei palauta tapahtumia. dry_run ei lukitse eikä kirjoita. booking_114.';
comment on function booking.admin_set_booking_calendar(jsonb) is 'Asetukset: vienti off/dry_run/live ja kalenteritunnisteet. Sulkukalenterin id hylätään. Oletus off. booking_114.';
comment on function booking.booking_calendar_dispatch() is 'pg_cron: kutsuu booking-calendar-synciä vain kun mode ei ole off. x-sync-secret = calendar_sync_cron_secret. booking_114.';

revoke all on function
  booking._calendar_scrub(text),
  booking._calendar_id_ok(text),
  booking._calendar_hm(timestamptz, text),
  booking._calendar_span(timestamptz, timestamptz, text),
  booking._booking_calendar_target(text, jsonb),
  booking._booking_calendar_admin_base(jsonb),
  booking._booking_calendar_desired(),
  booking._booking_calendar_should_nudge(),
  booking.booking_calendar_export_plan(),
  booking.booking_calendar_export_finish(jsonb),
  booking.booking_calendar_dispatch(),
  booking.booking_calendar_nudge(),
  booking.admin_get_booking_calendar(),
  booking.admin_set_booking_calendar(jsonb),
  booking.admin_booking_calendar_preview()
from public, anon, authenticated;

grant execute on function booking._calendar_scrub(text), booking._calendar_id_ok(text), booking._calendar_hm(timestamptz, text),
  booking._calendar_span(timestamptz, timestamptz, text), booking._booking_calendar_target(text, jsonb),
  booking._booking_calendar_admin_base(jsonb), booking._booking_calendar_desired(), booking._booking_calendar_should_nudge(),
  booking.booking_calendar_export_plan(), booking.booking_calendar_export_finish(jsonb), booking.booking_calendar_dispatch()
  to service_role;
grant execute on function booking.admin_get_booking_calendar(), booking.admin_set_booking_calendar(jsonb), booking.admin_booking_calendar_preview()
  to authenticated, service_role;

do $$ begin
  if coalesce(current_setting('booking.skip_cron', true), '') = 'on' then
    raise notice 'booking calendar: cron ohitettu (testi)';
    return;
  end if;
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and not exists (select 1 from cron.job where jobname = 'booking_calendar_export') then
    perform cron.schedule('booking_calendar_export', '*/5 * * * *', 'select booking.booking_calendar_dispatch()');
  end if;
exception when others then
  raise notice 'pg_cron-ajastus ohitettu: %', sqlerrm;
end $$;
