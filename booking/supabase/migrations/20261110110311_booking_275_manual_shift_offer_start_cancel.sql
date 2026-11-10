-- booking_275 (Joonas t1572u): Työvuoro-Tapio voi käynnistää ja perua vuorotarjouksen käsin.

CREATE OR REPLACE FUNCTION public._shift_offer_trigger_tick()
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- Sama kutsu kuin cron shift-offer-engine-5m: moottorin tavallinen ajo heti (lähettää jonossa olevat viestit).
declare v_id bigint;
begin
  select net.http_post(
    url := 'https://sxbofnuisemspgquoxyv.supabase.co/functions/v1/shift-offer-engine',
    body := '{}'::jsonb,
    headers := jsonb_build_object('content-type', 'application/json',
      'x-sync-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'calendar_sync_cron_secret')),
    timeout_milliseconds := 50000) into v_id;
  return v_id;
exception when others then
  return null;
end $function$;

CREATE OR REPLACE FUNCTION public.svc_shift_offer_start(
  p_shift_id uuid,
  p_mode text DEFAULT 'auto',
  p_skip_staff_ids uuid[] DEFAULT '{}',
  p_note text DEFAULT NULL,
  p_actor text DEFAULT 'tyovuoro-tapio',
  p_preview boolean DEFAULT true,
  p_send_now boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- p_mode: 'auto' = normaalit kierrokset (alle 10 vrk -> kaikille), 'broadcast' = heti kaikille.
-- p_preview = true (oletus): ei kirjoita mitään, palauttaa vastaanottajat ja kanavat. Käynnistys vaatii p_preview => false.
declare
  w public.work_shifts%rowtype; s public.shift_offer_settings%rowtype; o public.shift_offers%rowtype;
  v_now timestamptz := now(); v_date date; v_mode text := lower(btrim(coalesce(p_mode, 'auto')));
  v_skip uuid[] := coalesce(p_skip_staff_ids, '{}'); v_direct boolean; v_max int; v_round int; v_kind text;
  v_staff uuid[]; v_names text[]; v_sorts int[]; v_dl timestamptz; v_last boolean; v_n int; v_list jsonb; v_req bigint;
  v_actor text := left(coalesce(nullif(btrim(p_actor), ''), 'tyovuoro-tapio'), 60);
begin
  if v_mode not in ('auto', 'broadcast') then
    return jsonb_build_object('ok', false, 'error', 'bad_mode', 'hint', 'auto tai broadcast');
  end if;
  select * into w from public.work_shifts x where x.id = p_shift_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'shift_not_found'); end if;
  if w.status <> 'active' then return jsonb_build_object('ok', false, 'error', 'shift_not_active', 'status', w.status); end if;
  if w.starts_at <= v_now then return jsonb_build_object('ok', false, 'error', 'shift_in_past'); end if;
  select * into s from public.shift_offer_settings x where x.role_type = w.role_type;
  if not found then return jsonb_build_object('ok', false, 'error', 'role_not_configured', 'role_type', w.role_type); end if;
  v_date := (w.starts_at at time zone s.timezone)::date;

  select * into o from public.shift_offers x
   where x.shift_id = w.id and x.scenario = 'vacant_shift' and x.status in ('active','paused','escalated')
   order by x.created_at desc limit 1;
  if found then
    return jsonb_build_object('ok', true, 'action', 'already_open', 'offer_id', o.id, 'status', o.status,
      'round_no', o.current_round_no, 'created_by', o.created_by,
      'next_action_at', o.next_action_at, 'recipients', (
        select coalesce(jsonb_agg(jsonb_build_object('name', st.name, 'round_no', r.round_no, 'status', r.status,
                 'deadline_at', r.deadline_at) order by r.round_no, st.name), '[]'::jsonb)
          from public.shift_offer_recipients r join public.staff st on st.id = r.staff_id where r.offer_id = o.id));
  end if;

  if not booking.shift_offer_is_vacant(w.id) then return jsonb_build_object('ok', false, 'error', 'shift_not_vacant'); end if;
  if not public.shift_offer_allowed(w.role_type, v_date) then return jsonb_build_object('ok', false, 'error', 'not_offered_on_this_day'); end if;
  if w.starts_at > v_now + s.start_before then
    return jsonb_build_object('ok', false, 'error', 'too_far_ahead', 'start_before', s.start_before);
  end if;
  if not booking.shift_offer_in_horizon(w.starts_at) then return jsonb_build_object('ok', false, 'error', 'outside_horizon'); end if;
  if public.shift_offer_blocked_by_closure(w.role_type, w.starts_at, w.ends_at, 'vacant_shift') then
    return jsonb_build_object('ok', false, 'error', 'treatment_closed');
  end if;

  if v_mode = 'broadcast' then
    v_direct := true;
  else
    select q.direct_to_all into v_direct from public.shift_offer_wait(w.role_type, w.starts_at, v_now, false) q;
  end if;
  select coalesce(max(rnd.round_no), 0) into v_max from public.shift_offer_rounds rnd
   where rnd.role_type = w.role_type and rnd.scenario = 'vacant_shift' and extract(isodow from v_date)::smallint = any (rnd.weekdays)
     and v_date >= rnd.valid_from and (rnd.valid_to is null or v_date <= rnd.valid_to);
  if v_max = 0 and not v_direct then return jsonb_build_object('ok', false, 'error', 'no_rounds'); end if;

  v_staff := '{}';
  if v_direct then
    select array_agg(p.staff_id order by p.sort_order, p.staff_name), array_agg(p.staff_name order by p.sort_order, p.staff_name),
           array_agg(p.sort_order order by p.sort_order, p.staff_name), min(p.round_no), coalesce(min(p.round_kind), 'all')
      into v_staff, v_names, v_sorts, v_round, v_kind
      from public.shift_offer_pick_staff(w.role_type, v_date, 1, 'vacant_shift', w.starts_at, w.ends_at, true) p
     where not (p.staff_id = any (v_skip));
    v_kind := 'all';
  else
    for v_round in 1 .. v_max loop
      select array_agg(p.staff_id order by p.sort_order, p.staff_name), array_agg(p.staff_name order by p.sort_order, p.staff_name),
             array_agg(p.sort_order order by p.sort_order, p.staff_name), min(p.round_kind)
        into v_staff, v_names, v_sorts, v_kind
        from public.shift_offer_pick_staff(w.role_type, v_date, v_round, 'vacant_shift', w.starts_at, w.ends_at, false) p
       where not (p.staff_id = any (v_skip));
      exit when coalesce(cardinality(v_staff), 0) > 0;
    end loop;
  end if;
  v_round := coalesce(v_round, 1);
  if coalesce(cardinality(v_staff), 0) = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_recipients', 'mode', v_mode, 'skipped', to_jsonb(v_skip));
  end if;
  v_last := v_kind = 'all' or v_round >= v_max;
  v_dl := public.shift_offer_round_deadline(w.role_type, w.starts_at, v_now, v_kind, v_last);

  select jsonb_agg(jsonb_build_object(
           'name', st.name,
           'channel', case
             when public.shift_offer_is_bot_staff(st.id) then 'bot'
             when booking.shift_offer_wa_ready(st.id, 'offer') then 'whatsapp'
             when booking._valid_email(btrim(coalesce(st.email, ''))) then 'email'
             else 'none' end,
           'skipped_same_day_decline', exists (
             select 1 from public.shift_offer_recipients x2 join public.shift_offers o2 on o2.id = x2.offer_id
               join public.work_shifts w2 on w2.id = o2.shift_id
              where x2.staff_id = st.id and x2.status = 'declined' and o2.role_type = w.role_type
                and (coalesce(o2.window_starts_at, w2.starts_at) at time zone 'Europe/Helsinki')::date = v_date))
         order by u.ord)
    into v_list
    from unnest(v_staff) with ordinality u(id, ord) join public.staff st on st.id = u.id;

  if coalesce(p_preview, true) then
    return jsonb_build_object('ok', true, 'action', 'preview', 'shift_id', w.id, 'role_type', w.role_type,
      'starts_at', w.starts_at, 'ends_at', w.ends_at, 'mode', v_mode, 'direct_to_all', v_direct,
      'round_no', v_round, 'round_kind', v_kind, 'deadline_at', v_dl,
      'role_auto_enabled', s.enabled, 'skipped', to_jsonb(v_skip), 'recipients', v_list,
      'note', 'WhatsApp lähtee vain klo 8–21; muuna aikana se odottaa aamuun (sähköposti lähtee heti).');
  end if;

  begin
    insert into public.shift_offers (shift_id, role_type, scenario, status, current_round_no, round_started_at, created_by, note)
    values (w.id, w.role_type, 'vacant_shift', 'active', v_round, v_now, 'manual:' || v_actor, left(p_note, 500))
    returning * into o;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'concurrent');
  end;
  -- ohitettavat: withdrawn-rivi, jotta myöhemmät kierrokset ja kaikille-kierros eivät ota heitä mukaan
  insert into public.shift_offer_recipients (offer_id, staff_id, round_no, round_kind, status)
  select o.id, x, 1, 'named', 'withdrawn' from unnest(v_skip) x
   where exists (select 1 from public.staff st where st.id = x)
  on conflict (offer_id, staff_id) do nothing;
  v_n := public.shift_offer_issue_recipients(o.id, w.role_type, w.starts_at, w.ends_at, v_now, v_round, v_kind, v_staff, v_names, v_sorts);
  update public.shift_open_events set status = 'done', processed_at = v_now where shift_id = w.id and status in ('new','processing');
  if coalesce(p_send_now, true) then v_req := public._shift_offer_trigger_tick(); end if;
  return jsonb_build_object('ok', true, 'action', 'started', 'offer_id', o.id, 'shift_id', w.id, 'role_type', w.role_type,
    'mode', v_mode, 'round_no', v_round, 'round_kind', v_kind, 'deadline_at', v_dl, 'recipients_issued', v_n,
    'recipients', v_list, 'send_now', v_req is not null);
end $function$;

drop function if exists public.svc_shift_offer_cancel(uuid, boolean, text, boolean);
CREATE OR REPLACE FUNCTION public.svc_shift_offer_cancel(
  p_offer_id uuid,
  p_actor text DEFAULT 'tyovuoro-tapio',
  p_preview boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- Peruu avoimen tarjouksen. EI lähetä viestiä vastaanottajille: olemassa oleva peruutusviesti (pohja tarjous_peruttu
-- ja sähköpostiteksti) kertoo syyksi "hoidot ovat kiinni", joten se ei sovi käsin perumiseen.
-- Avoimet vastaanottajat -> withdrawn; heidän linkkinsä näyttää tilan cancelled.
declare o public.shift_offers%rowtype; v_list jsonb;
begin
  select * into o from public.shift_offers x where x.id = p_offer_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'offer_not_found'); end if;
  if o.status not in ('active','paused','escalated') then
    return jsonb_build_object('ok', false, 'error', 'offer_not_open', 'status', o.status);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('name', st.name, 'status', x.status) order by st.name), '[]'::jsonb) into v_list
    from public.shift_offer_recipients x join public.staff st on st.id = x.staff_id
   where x.offer_id = o.id and x.sent_at is not null and x.status in ('pending','snoozed');
  if coalesce(p_preview, true) then
    return jsonb_build_object('ok', true, 'action', 'preview_cancel', 'offer_id', o.id, 'shift_id', o.shift_id,
      'messages', 0, 'open_recipients', v_list);
  end if;
  update public.shift_offer_messages set status = 'skipped', last_error = 'offer_cancelled', locked_at = null
   where offer_id = o.id and status = 'queued' and wamid is null;
  update public.shift_offer_recipients set status = 'withdrawn', snooze_until = null
   where offer_id = o.id and status in ('queued','pending','snoozed');
  update public.shift_offers set status = 'cancelled', next_action_at = null, updated_at = now(),
         note = left(coalesce(note || ' | ', '') || 'peruttu käsin: ' || left(coalesce(p_actor, 'tyovuoro-tapio'), 60), 500)
   where id = o.id;
  return jsonb_build_object('ok', true, 'action', 'cancelled', 'offer_id', o.id, 'messages', 0, 'open_recipients', v_list);
end $function$;

revoke all on function public._shift_offer_trigger_tick() from public, anon, authenticated;
revoke all on function public.svc_shift_offer_start(uuid, text, uuid[], text, text, boolean, boolean) from public, anon, authenticated;
revoke all on function public.svc_shift_offer_cancel(uuid, text, boolean) from public, anon, authenticated;
grant execute on function public._shift_offer_trigger_tick() to service_role;
grant execute on function public.svc_shift_offer_start(uuid, text, uuid[], text, text, boolean, boolean) to service_role;
grant execute on function public.svc_shift_offer_cancel(uuid, text, boolean) to service_role;
CREATE OR REPLACE FUNCTION public.shift_offer_ensure(p_shift_id uuid, p_now timestamp with time zone DEFAULT now(), p_dry boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  w public.work_shifts%rowtype;
  s public.shift_offer_settings%rowtype;
  o public.shift_offers%rowtype;
  v_date date; v_direct boolean; v_round int; v_max int; v_kind text;
  v_staff uuid[]; v_names text[]; v_sorts int[]; v_n int; v_pending int; v_snooze timestamptz;
  v_declined boolean; v_due boolean; r record; v_dl timestamptz;
begin
  select * into w from public.work_shifts x where x.id = p_shift_id;
  if not found or w.status <> 'active' then return jsonb_build_object('action', 'skip', 'reason', 'shift'); end if;
  select * into s from public.shift_offer_settings x where x.role_type = w.role_type;
  -- booking_275: käsin käynnistetty tarjous (created_by 'manual%') etenee, vaikka roolin automaattinen tarjous on pois
  if not found or (not s.enabled and not exists (
        select 1 from public.shift_offers mo where mo.shift_id = w.id and mo.status in ('active','paused','escalated')
           and mo.created_by like 'manual%')) then
    return jsonb_build_object('action', 'skip', 'reason', 'disabled');
  end if;
  v_date := (w.starts_at at time zone s.timezone)::date;
  if not public.shift_offer_allowed(w.role_type, v_date) then return jsonb_build_object('action', 'skip', 'reason', 'not_allowed'); end if;
  -- booking_153 e/f: ?-vuoro asetuksella, poissaolo vapauttaa vuoron
  if not booking.shift_offer_is_vacant(w.id) then
    if w.staffing_status is distinct from 'open' and not exists (select 1 from public.shift_assignments a where a.shift_id = w.id and a.status in ('assigned','confirmed')) then
      return jsonb_build_object('action', 'skip', 'reason', 'staffing');
    end if;
    return jsonb_build_object('action', 'skip', 'reason', 'assigned');
  end if;
  if w.starts_at <= p_now or w.starts_at > p_now + s.start_before then
    return jsonb_build_object('action', 'skip', 'reason', 'window');
  end if;
  -- horizon (shift_offer.offer_horizon_until, moved manually only): no rounds, reminders, alerts, warnings
  -- or automatic treatment closures for shifts after the horizon. Missing/invalid setting = fail closed.
  if not booking.shift_offer_in_horizon(w.starts_at) then
    return jsonb_build_object('action', 'skip', 'reason', 'horizon', 'shift_id', w.id);
  end if;
  if public.shift_offer_blocked_by_closure(w.role_type, w.starts_at, w.ends_at, 'vacant_shift') then
    return jsonb_build_object('action', 'skip', 'reason', 'treatment_closed');
  end if;

  select * into o from public.shift_offers x
   where x.shift_id = w.id and x.scenario = 'vacant_shift' and x.status in ('active','paused','escalated')
   for update;
  if not found then
    if exists (select 1 from public.shift_offers x where x.shift_id = w.id and x.scenario = 'vacant_shift' and x.status in ('filled','closed')) then
      return jsonb_build_object('action', 'skip', 'reason', 'finished');
    end if;
    select q.direct_to_all into v_direct from public.shift_offer_wait(w.role_type, w.starts_at, p_now, false) q;
    select coalesce(max(rnd.round_no), 0) into v_max from public.shift_offer_rounds rnd
     where rnd.role_type = w.role_type and rnd.scenario = 'vacant_shift' and extract(isodow from v_date)::smallint = any (rnd.weekdays)
       and v_date >= rnd.valid_from and (rnd.valid_to is null or v_date <= rnd.valid_to);
    -- soefix B3: roolille ja viikonpäivälle ei ole kierroksia → ei eskalointia, vaan skip no_rounds (kirjataan raporttia varten).
    -- Hoitajavuoro (therapist) ei kuulu tähän: sen eskalointi/varoitus/6 h sulku pysyy ennallaan (B6 pudotettu, Joonas 25.10. 16:59).
    if coalesce(v_max, 0) = 0 and w.role_type <> 'therapist' then
      if not p_dry then
        insert into booking.shift_offer_skips (shift_id, reason, role_type, shift_date, first_seen_at, last_seen_at, seen_count)
        values (w.id, 'no_rounds', w.role_type, v_date, p_now, p_now, 1)
        on conflict (shift_id, reason) do update set last_seen_at = excluded.last_seen_at, seen_count = booking.shift_offer_skips.seen_count + 1;
      end if;
      return jsonb_build_object('action', 'skip', 'reason', 'no_rounds', 'shift_id', w.id, 'role_type', w.role_type, 'shift_date', v_date);
    end if;
    v_staff := '{}'; v_names := '{}'; v_sorts := '{}'; v_round := 1; v_kind := null;
    if v_direct then
      select array_agg(p.staff_id), array_agg(p.staff_name), array_agg(p.sort_order), min(p.round_no), min(p.round_kind)
        into v_staff, v_names, v_sorts, v_round, v_kind
        from public.shift_offer_pick_staff(w.role_type, v_date, 1, 'vacant_shift', w.starts_at, w.ends_at, true) p;
    else
      for v_round in 1 .. v_max loop
        select array_agg(p.staff_id order by p.sort_order, p.staff_name), array_agg(p.staff_name order by p.sort_order, p.staff_name),
               array_agg(p.sort_order order by p.sort_order, p.staff_name), min(p.round_kind)
          into v_staff, v_names, v_sorts, v_kind
          from public.shift_offer_pick_staff(w.role_type, v_date, v_round, 'vacant_shift', w.starts_at, w.ends_at, false) p;
        exit when coalesce(cardinality(v_staff), 0) > 0;
      end loop;
    end if;
    if coalesce(cardinality(v_staff), 0) = 0 then
      if p_dry then return jsonb_build_object('action', 'would_exhaust', 'shift_id', w.id); end if;
      insert into public.shift_offers (shift_id, role_type, scenario, status, current_round_no, created_by)
      values (w.id, w.role_type, 'vacant_shift', 'escalated', coalesce(v_max, 1), 'tyovuoro-tapio')
      returning * into o;
      return public.shift_offer_on_exhausted(o.id, p_now, false) || jsonb_build_object('shift_id', w.id);
    end if;
    if p_dry then
      return jsonb_build_object('action', 'would_offer', 'shift_id', w.id, 'role_type', w.role_type, 'starts_at', w.starts_at,
        'round_no', v_round, 'round_kind', v_kind, 'staff_ids', to_jsonb(v_staff), 'staff_names', to_jsonb(v_names));
    end if;
    begin
      insert into public.shift_offers (shift_id, role_type, scenario, status, current_round_no, round_started_at, created_by)
      values (w.id, w.role_type, 'vacant_shift', 'active', v_round, p_now, 'tyovuoro-tapio')
      returning * into o;
    exception when unique_violation then
      return jsonb_build_object('action', 'skip', 'reason', 'concurrent', 'shift_id', w.id);
    end;
    v_n := public.shift_offer_issue_recipients(o.id, w.role_type, w.starts_at, w.ends_at, p_now, v_round, v_kind, v_staff, v_names, v_sorts);
    update public.shift_open_events set status = 'done', processed_at = p_now where shift_id = w.id and status in ('new','processing');
    return jsonb_build_object('action', 'offered', 'shift_id', w.id, 'offer_id', o.id, 'round_no', v_round, 'round_kind', v_kind, 'recipients', v_n);
  end if;

  -- tyhjä kierros on jo kysytty Joonakselta / sulku on ajastettu: älä etene tavallisia kierroksia
  if o.status = 'escalated' then
    if o.next_action_at is not null and o.next_action_at > p_now and o.role_type <> 'therapist' then
      return jsonb_build_object('action', 'waiting', 'offer_id', o.id, 'shift_id', w.id);
    end if;
    if p_dry then return jsonb_build_object('action', 'would_exhausted_step', 'offer_id', o.id, 'shift_id', w.id); end if;
    return public.shift_offer_on_exhausted(o.id, p_now, false) || jsonb_build_object('shift_id', w.id);
  end if;

  for r in select * from public.shift_offer_recipients x where x.offer_id = o.id and x.status = 'snoozed' and x.snooze_until <= p_now loop
    v_dl := public.shift_offer_round_deadline(w.role_type, w.starts_at, p_now, r.round_kind, false);
    if p_dry then return jsonb_build_object('action', 'would_remind', 'offer_id', o.id, 'staff_id', r.staff_id); end if;
    update public.shift_offer_recipients set status = 'pending', snooze_until = null, deadline_at = v_dl, reminder_sent_at = p_now where id = r.id;
    perform public.shift_offer_queue_message(o.id, r.id, r.staff_id, 'reminder',
      public.shift_offer_compose('reminder', r.staff_id, o.id, w.role_type, w.starts_at, w.ends_at, v_dl, null),
      'offer:' || o.id::text || ':staff:' || r.staff_id::text || ':reminder:' || to_char(p_now at time zone 'UTC', 'YYYYMMDDHH24MI'));
  end loop;

  -- Kaikille-hetki on ohitettu: älä etene kierros kerrallaan (se saisi 6 h / all_round_wait jokaiselle).
  -- Hyppää suoraan all-kierrokseen ja named_lastiin, jätä aiemmat vastaanottajat voimaan.
  if o.all_sent_at is null and public.shift_offer_all_by_at(w.role_type, w.starts_at) <= p_now then
    v_staff := null; v_names := null; v_sorts := null; v_round := null; v_kind := null;
    select array_agg(p.staff_id order by p.sort_order, p.staff_name),
           array_agg(p.staff_name order by p.sort_order, p.staff_name),
           array_agg(p.sort_order order by p.sort_order, p.staff_name),
           min(p.round_no), min(p.round_kind)
      into v_staff, v_names, v_sorts, v_round, v_kind
      from public.shift_offer_pick_staff(w.role_type, v_date, 1, o.scenario, w.starts_at, w.ends_at, true) p
     where not exists (
       select 1 from public.shift_offer_recipients x where x.offer_id = o.id and x.staff_id = p.staff_id);
    if coalesce(cardinality(v_staff), 0) > 0 then
      if p_dry then
        return jsonb_build_object('action', 'would_advance', 'offer_id', o.id, 'shift_id', w.id,
          'round_no', v_round, 'round_kind', coalesce(v_kind, 'all'), 'staff_ids', to_jsonb(v_staff));
      end if;
      v_n := public.shift_offer_issue_recipients(o.id, w.role_type, w.starts_at, w.ends_at, p_now,
        v_round, coalesce(v_kind, 'all'), v_staff, v_names, v_sorts);
      return jsonb_build_object('action', 'advanced', 'offer_id', o.id, 'shift_id', w.id,
        'round_no', v_round, 'round_kind', coalesce(v_kind, 'all'), 'recipients', v_n);
    end if;
    if not p_dry then
      update public.shift_offers set all_sent_at = p_now, updated_at = p_now where id = o.id and all_sent_at is null;
    end if;
    o.all_sent_at := p_now;
  end if;

  select count(*) filter (where status = 'pending'), min(snooze_until) filter (where status = 'snoozed' and snooze_until > p_now)
    into v_pending, v_snooze
    from public.shift_offer_recipients where offer_id = o.id and round_no = o.current_round_no;
  if v_pending = 0 and v_snooze is not null then
    if not p_dry then update public.shift_offers set status = 'paused', next_action_at = v_snooze, updated_at = p_now where id = o.id; end if;
    return jsonb_build_object('action', 'paused', 'offer_id', o.id, 'until', v_snooze);
  end if;

  v_declined := v_pending = 0 and v_snooze is null and exists (
    select 1 from public.shift_offer_recipients x where x.offer_id = o.id and x.round_no = o.current_round_no);
  v_due := o.next_action_at is not null and o.next_action_at <= p_now
        or exists (select 1 from public.shift_offer_recipients x where x.offer_id = o.id and x.round_no = o.current_round_no and x.status = 'pending' and x.deadline_at <= p_now);
  if not v_declined and not v_due then
    -- booking_153 sääntö 7: loppumuistutus vastaamattomille
    v_n := booking.shift_offer_round_reminders(o.id, p_now, p_dry);
    if v_n > 0 then
      return jsonb_build_object('action', case when p_dry then 'would_round_remind' else 'round_reminded' end, 'offer_id', o.id, 'shift_id', w.id, 'count', v_n);
    end if;
    return jsonb_build_object('action', 'waiting', 'offer_id', o.id, 'shift_id', w.id);
  end if;

  select coalesce(max(rnd.round_no), o.current_round_no) into v_max from public.shift_offer_rounds rnd
   where rnd.role_type = w.role_type and rnd.scenario = o.scenario and extract(isodow from v_date)::smallint = any (rnd.weekdays)
     and v_date >= rnd.valid_from and (rnd.valid_to is null or v_date <= rnd.valid_to);
  v_round := o.current_round_no;
  loop
    v_round := v_round + 1;
    if v_round > v_max then
      if p_dry then return jsonb_build_object('action', 'would_exhaust', 'offer_id', o.id, 'shift_id', w.id); end if;
      return public.shift_offer_on_exhausted(o.id, p_now, false) || jsonb_build_object('shift_id', w.id);
    end if;
    select array_agg(p.staff_id order by p.sort_order, p.staff_name), array_agg(p.staff_name order by p.sort_order, p.staff_name),
           array_agg(p.sort_order order by p.sort_order, p.staff_name), min(p.round_kind)
      into v_staff, v_names, v_sorts, v_kind
      from public.shift_offer_pick_staff(w.role_type, v_date, v_round, o.scenario, w.starts_at, w.ends_at, false) p
     where not exists (select 1 from public.shift_offer_recipients x where x.offer_id = o.id and x.staff_id = p.staff_id);
    if coalesce(cardinality(v_staff), 0) = 0 then continue; end if;
    if p_dry then
      return jsonb_build_object('action', 'would_advance', 'offer_id', o.id, 'shift_id', w.id, 'round_no', v_round, 'round_kind', v_kind, 'staff_ids', to_jsonb(v_staff));
    end if;
    v_n := public.shift_offer_issue_recipients(o.id, w.role_type, w.starts_at, w.ends_at, p_now, v_round, v_kind, v_staff, v_names, v_sorts);
    return jsonb_build_object('action', 'advanced', 'offer_id', o.id, 'shift_id', w.id, 'round_no', v_round, 'recipients', v_n);
  end loop;
end $function$;
