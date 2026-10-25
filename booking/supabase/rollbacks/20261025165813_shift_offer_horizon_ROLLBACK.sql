-- ROLLBACK 20261025165813_shift_offer_horizon.sql (tuotannossa ajettu 25.10.2026 klo 18.58 Europe/Helsinki): palauttaa funktiot public.shift_offer_tick,
-- public.shift_offer_ensure, public.shift_offer_service_closures, public.shift_offer_cancel_for_closure ja booking.shift_offer_report_issues
-- migraatiota edeltäviin tuotannon määrittelyihin, poistaa booking.shift_offer_horizon_until / booking.shift_offer_in_horizon ja asetuksen
-- 'shift_offer.offer_horizon_until'. Kytkimiin ei kosketa. Ajetaan vain Joonaksen luvalla ja vain, jos migraatio on ajettu.
-- Lähde: Bottiavustuksen 20261025165813_shift_offer_horizon_rollback.sql (md5 4836f50f647e8dba8551b1a9174cfc04), sanatarkasti rivien begin; ja commit; välissä.
begin;
-- Rollback for migration 20261025165813_shift_offer_horizon (applied 25.10.2026 18:58 Europe/Helsinki). Bodies = definitions as of just before the migration (md5-verified).
-- rollback for shift_offer_horizon: restore previous function bodies, drop helpers, remove setting
CREATE OR REPLACE FUNCTION public.shift_offer_tick(p_dry_run boolean DEFAULT false, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_dry boolean; v_now timestamptz; w record; v_row jsonb;
  v_actions jsonb := '[]'::jsonb; v_cancel jsonb; v_svc jsonb;
begin
  v_now := coalesce(p_now, now());
  select coalesce(p_dry_run, false) or e.dry_run into v_dry from public.shift_offer_engine_settings e where e.id;
  v_dry := coalesce(v_dry, p_dry_run, false);
  v_cancel := public.shift_offer_cancel_for_closure(v_now, v_dry);
  v_svc := public.shift_offer_service_closures(v_now, v_dry);
  for w in
    select ws.id from public.work_shifts ws
      join public.shift_offer_settings s on s.role_type = ws.role_type and s.enabled
     where ws.status = 'active' and ws.starts_at > v_now and ws.starts_at <= v_now + s.start_before
       and booking.shift_offer_is_vacant(ws.id)
     order by ws.starts_at
  loop
    v_row := public.shift_offer_ensure(w.id, v_now, v_dry);
    if v_row->>'action' not in ('skip', 'waiting') then v_actions := v_actions || v_row; end if;
  end loop;
  -- myös avoimet tarjoukset, joiden vuoro ei enää ole haussa (esim. ikkuna), mutta kierros on erääntynyt
  for w in
    select o.shift_id as id from public.shift_offers o
     where o.status in ('active','paused','escalated')
       and (o.next_action_at is null or o.next_action_at <= v_now or (o.status = 'escalated' and o.role_type = 'therapist')
            or (o.status = 'active' and exists (select 1 from public.shift_offer_recipients x where x.offer_id = o.id and x.status = 'pending')))
       and not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'shift_id' = o.shift_id::text)
  loop
    v_row := public.shift_offer_ensure(w.id, v_now, v_dry);
    if v_row->>'action' not in ('skip', 'waiting') then v_actions := v_actions || v_row; end if;
  end loop;
  return jsonb_build_object('ok', true, 'dry_run', v_dry, 'now', v_now, 'cancel', v_cancel, 'service_closures', v_svc, 'actions', v_actions);
end $function$;

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
  if not found or not s.enabled then return jsonb_build_object('action', 'skip', 'reason', 'disabled'); end if;
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

CREATE OR REPLACE FUNCTION public.shift_offer_service_closures(p_now timestamp with time zone, p_dry boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  s public.shift_offer_settings%rowtype;
  v_from date; v_to date; v_date date; v_wd smallint; v_th uuid; v_need jsonb; v_res jsonb; v_out jsonb := '[]'::jsonb;
begin
  select * into s from public.shift_offer_settings x where x.role_type = 'therapist';
  if not found or not s.enabled then return jsonb_build_object('skipped', true, 'reason', 'disabled'); end if;
  v_from := (p_now at time zone s.timezone)::date;
  v_to := ((p_now + s.start_before) at time zone s.timezone)::date;
  v_date := v_from;
  while v_date <= v_to loop
    v_wd := extract(isodow from v_date)::smallint;
    if exists (select 1 from public.shift_service_date_overrides o where o.service_code = 'perinnesaunotus' and o.on_date = v_date and o.mode = 'closed')
       or exists (select 1 from public.shift_service_allowed_therapists a where a.service_code = 'perinnesaunotus' and a.weekday = v_wd
                    and v_date >= a.valid_from and (a.valid_to is null or v_date <= a.valid_to)) then
      select a.staff_id into v_th from public.work_shifts w
        join public.shift_assignments a on a.shift_id = w.id and a.status in ('assigned','confirmed')
       where w.role_type = 'therapist' and w.status = 'active' and (w.starts_at at time zone s.timezone)::date = v_date
       limit 1;
      v_need := public.shift_service_closure_needed('perinnesaunotus', v_date, v_th);
      if coalesce(v_need->>'needs_closure', 'false') = 'true' and coalesce(v_need->>'reason', '') <> 'no_rule' then
        v_res := public.shift_offer_ensure_closure('perinnesaunotus', v_date, 'Tarjousmoottori: perinnesaunotus kiinni (' || coalesce(v_need->>'reason', '') || ')', p_dry);
        if v_res->>'action' in ('closed', 'would_close') then v_out := v_out || v_res; end if;
      end if;
    end if;
    v_date := v_date + 1;
  end loop;
  return jsonb_build_object('closures', v_out);
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_cancel_for_closure(p_now timestamp with time zone, p_dry boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o public.shift_offers%rowtype; w public.work_shifts%rowtype; r record; v_out jsonb := '[]'::jsonb; v_n int := 0;
begin
  for o in select x.* from public.shift_offers x where x.status in ('active','paused','escalated') order by x.created_at loop
    select * into w from public.work_shifts s where s.id = o.shift_id;
    if not found then continue; end if;
    if not public.shift_offer_blocked_by_closure(o.role_type, coalesce(o.window_starts_at, w.starts_at), coalesce(o.window_ends_at, w.ends_at), o.scenario) then
      continue;
    end if;
    v_out := v_out || jsonb_build_object('offer_id', o.id, 'shift_id', w.id, 'role_type', o.role_type);
    v_n := v_n + 1;
    if p_dry then continue; end if;
    for r in select * from public.shift_offer_recipients x where x.offer_id = o.id and x.sent_at is not null and x.status in ('pending','snoozed','declined','queued') loop
      perform public.shift_offer_queue_message(o.id, r.id, r.staff_id, 'cancelled',
        public.shift_offer_compose('cancelled', r.staff_id, o.id, o.role_type, w.starts_at, w.ends_at, null, null),
        'offer:' || o.id::text || ':staff:' || r.staff_id::text || ':cancelled');
    end loop;
    update public.shift_offer_recipients set status = 'withdrawn', snooze_until = null
     where offer_id = o.id and status in ('queued','pending','snoozed');
    update public.shift_offers set status = 'cancelled', next_action_at = null, updated_at = p_now, note = 'hoidot_kiinni' where id = o.id;
  end loop;
  return jsonb_build_object('cancelled', v_n, 'offers', v_out);
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_offer_report_issues(p_since timestamp with time zone DEFAULT (now() - '1 day'::interval))
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- soefix B3/C2/B7: Työvuoro-Tapion päiväraportin koonti. Ei puhelinnumeroita, osoitteita eikä viestien sisältöä.
  select jsonb_build_object(
    'since', p_since,
    'no_rounds', coalesce((select jsonb_agg(jsonb_build_object('shift_id', k.shift_id, 'role_type', k.role_type, 'shift_date', k.shift_date,
                                                               'first_seen_at', k.first_seen_at, 'last_seen_at', k.last_seen_at)
                                            order by k.shift_date, k.role_type)
                             from booking.shift_offer_skips k join public.work_shifts w on w.id = k.shift_id
                            where k.reason = 'no_rounds' and k.last_seen_at >= p_since and w.starts_at > now()), '[]'::jsonb),
    'no_working_channel', coalesce((select jsonb_agg(jsonb_build_object('staff_id', q.staff_id, 'name', q.name, 'roles', q.roles, 'offers_skipped', q.n) order by q.name)
                                      from (select m.staff_id, st.name, count(distinct coalesce(m.offer_id::text, m.id::text)) n,
                                                   coalesce(jsonb_agg(distinct o.role_type) filter (where o.role_type is not null), '[]'::jsonb) roles
                                              from public.shift_offer_messages m
                                              left join public.staff st on st.id = m.staff_id
                                              left join public.shift_offers o on o.id = m.offer_id
                                             where m.status = 'failed_no_contact' and m.last_error like 'no_working_channel%' and m.created_at >= p_since
                                             group by m.staff_id, st.name) q), '[]'::jsonb),
    'skipped_inactive', (select count(*) from public.shift_offer_messages m where m.last_error = 'skipped_inactive' and m.created_at >= p_since),
    'lost_not_resent', (select count(*) from public.shift_offer_messages m where m.status in ('unknown', 'failed') and m.resent_message_id is null and m.created_at >= p_since),
    'resent', (select count(*) from public.shift_offer_messages m where m.dedupe_key like 'resend:%' and m.created_at >= p_since),
    'bot_unacked_over_2h', (select count(*) from public.shift_offer_messages m
                             where m.status = 'bot_channel' and m.bot_acked_at is null and m.created_at < now() - interval '2 hours' and m.created_at >= p_since
                               and not exists (select 1 from botgw.inbox_ack a where a.message_id = m.id)),
    'bot_email_copies', (select count(*) from public.shift_offer_messages m where m.bot_email_outbox_id is not null and m.created_at >= p_since))
$function$;

drop function if exists booking.shift_offer_in_horizon(timestamptz);
drop function if exists booking.shift_offer_horizon_until();
delete from booking.settings where key = 'shift_offer.offer_horizon_until';
commit;
