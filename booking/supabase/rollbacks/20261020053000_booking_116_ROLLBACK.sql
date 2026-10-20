-- ROLLBACK booking_116_calendar_day.
-- Palauttaa päiväpalkin tilalle booking_114:n yksittäistapahtumat ja esikatselun,
-- sekä booking_115:n viimeistelyn (last_reconcile_at säilyy).
-- Päiväpalkkirivit jätetään tauluun, jotta seuraava ajo poistaa ne kalenterista
-- (ne ovat mapped mutta eivät enää haluttuja). Rajaus kavennetaan vain, jos rivejä ei ole.

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
         last_reconcile_at = case
           when coalesce(v_mode, 'off') = 'live' and p -> 'reconcile' = 'true'::jsonb and nullif(p ->> 'error', '') is null then now()
           else s.last_reconcile_at end,
         locked_at = case when p ->> 'run_id' is null or s.locked_by is not distinct from p ->> 'run_id' then null else s.locked_at end,
         locked_by = case when p ->> 'run_id' is null or s.locked_by is not distinct from p ->> 'run_id' then null else s.locked_by end
   where s.id = 1;
  return jsonb_build_object('ok', true, 'upserted', n_up, 'deleted', n_del);
end $$;

comment on function booking._booking_calendar_desired() is
  'Vientikelpoiset tapahtumat. Jaettu varaus = yksi palkki, yksinoikeus = yksi tapahtuma. booking_114.';
comment on function booking.admin_booking_calendar_preview() is
  'Esikatselu: yksityiset tapahtumat ja vuoropalkit. Ei lähetä. booking_114.';

do $rb$
begin
  if not exists (
    select 1 from booking.booking_calendar_events e
     where e.kind = 'day' or e.event_key like 'd:%'
  ) then
    alter table booking.booking_calendar_events drop constraint if exists booking_calendar_events_kind_check;
    alter table booking.booking_calendar_events add constraint booking_calendar_events_kind_check
      check (kind in ('reservation', 'shift'));
    alter table booking.booking_calendar_events drop constraint if exists booking_calendar_events_event_key_check;
    alter table booking.booking_calendar_events add constraint booking_calendar_events_event_key_check
      check (event_key ~ '^[rs]:[A-Za-z0-9_.:|-]+$');
  end if;
end $rb$;
