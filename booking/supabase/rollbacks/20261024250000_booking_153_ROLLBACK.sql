-- ROLLBACK booking_153_shift_offer_rules: vuorotarjousmoottorin sääntömuutokset ja henkilökunnan oma sivu pois.
-- Palauttaa korvatut public-funktiot tuotantomuotoon (pg_get_functiondef-md5 = .work/prod/prod_md5.json) ja
-- email_outbox_kind_check-rajoitteen booking_146:n listaan. Uudelleenajettava (toinen ajo ei tee mitään).
-- HUOM: poistaa staff_shift_notice-rivit email_outboxista, booking_153:n taulut (ilmoitusloki, viestien meta,
-- omien sivujen linkit, WhatsApp-suostumukset) ja shift_offer.* -asetukset. Moottorin viestit ja tarjoukset säilyvät.
set local lock_timeout = '5s';
CREATE OR REPLACE FUNCTION public.shift_offer_round_deadline(p_role text, p_starts timestamp with time zone, p_now timestamp with time zone, p_kind text, p_last boolean)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  t record; s public.shift_offer_settings%rowtype; v_dl timestamptz; v_wait interval;
begin
  select * into s from public.shift_offer_settings x where x.role_type = p_role;
  select * into t from public.shift_offer_wait(p_role, p_starts, p_now, p_last) w;
  if t.direct_to_all or t.deadline_at is null then
    v_wait := least(coalesce(s.all_round_wait, interval '6 hours'), greatest(p_starts - p_now, interval '1 hour'));
    v_dl := public.shift_add_active_time(p_now, v_wait, p_role);
  else
    v_dl := t.deadline_at;
  end if;
  if p_kind = 'rotation' then
    v_dl := least(v_dl, public.shift_add_active_time(p_now, coalesce(s.group_max_wait, interval '24 hours'), p_role));
  end if;
  return least(v_dl, p_starts);
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_respond(p_offer_id uuid, p_staff_id uuid, p_response text, p_snooze_until timestamp with time zone DEFAULT NULL::timestamp with time zone, p_apply boolean DEFAULT true, p_actor text DEFAULT 'tyovuoro-tapio'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o   public.shift_offers%rowtype;
  r   public.shift_offer_recipients%rowtype;
  s   public.shift_offer_settings%rowtype;
  v_starts timestamptz; v_until timestamptz; v_res jsonb; v_notify jsonb; v_open int;
begin
  if p_response is null or p_response not in ('accept','decline','snooze') then
    raise exception 'Tuntematon vastaus % (accept, decline, snooze)', p_response using errcode = '22023';
  end if;
  select * into o from public.shift_offers x where x.id = p_offer_id for update;
  if not found then raise exception 'Tarjousta ei löytynyt' using errcode = 'P0002'; end if;
  select * into r from public.shift_offer_recipients x where x.offer_id = p_offer_id and x.staff_id = p_staff_id for update;
  if not found or r.status in ('queued','withdrawn') then
    return jsonb_build_object('result', 'not_recipient');
  end if;

  if o.status = 'filled' then
    if o.accepted_staff_id = p_staff_id then return jsonb_build_object('result', 'already_yours'); end if;
    if r.status in ('pending','snoozed','declined') and p_response = 'accept' then
      update public.shift_offer_recipients set status = 'filled_other', snooze_until = null, responded_at = coalesce(responded_at, now())
       where id = r.id;
    end if;
    return jsonb_build_object('result', 'already_filled', 'winner_staff_id', o.accepted_staff_id, 'accepted_at', o.accepted_at);
  end if;
  if o.status not in ('active','paused','escalated') then
    return jsonb_build_object('result', 'offer_closed', 'offer_status', o.status);
  end if;

  if p_response = 'accept' then
    if r.status not in ('pending','snoozed','declined') then
      return jsonb_build_object('result', 'invalid_state', 'recipient_status', r.status);
    end if;
    update public.shift_offer_recipients set status = 'accepted', responded_at = now(), snooze_until = null where id = r.id;
    with x as (
      update public.shift_offer_recipients set status = case when sent_at is null then 'withdrawn' else 'filled_other' end,
             snooze_until = null
       where offer_id = o.id and id <> r.id and status in ('queued','pending','snoozed')
      returning staff_id, sent_at)
    select coalesce(jsonb_agg(staff_id), '[]'::jsonb) into v_notify from x where sent_at is not null;
    -- myös aiemmin kieltäytyneet, joille tarjous lähti, saavat "täytetty"-tiedon
    v_notify := v_notify || coalesce((select jsonb_agg(x.staff_id) from public.shift_offer_recipients x
                  where x.offer_id = o.id and x.status = 'declined' and x.sent_at is not null), '[]'::jsonb);
    update public.shift_offers set status = 'filled', accepted_staff_id = p_staff_id, accepted_recipient_id = r.id,
           accepted_at = now(), next_action_at = null, updated_at = now() where id = o.id;
    if p_apply and o.scenario = 'vacant_shift' then
      begin
        v_res := public.shift_apply_change('assign', o.shift_id, p_staff_id, null, null, null, 'offer_engine', p_actor, p_staff_id,
                                           'Tarjous ' || o.id::text, null);
        update public.shift_offers set assignment_result = v_res where id = o.id;
      exception when others then
        update public.shift_offers set assignment_error = sqlstate || ': ' || sqlerrm where id = o.id;
        v_res := jsonb_build_object('error', sqlstate || ': ' || sqlerrm);
      end;
    end if;
    return jsonb_build_object('result', 'accepted', 'offer_id', o.id, 'shift_id', o.shift_id, 'staff_id', p_staff_id,
                              'notify_filled_staff_ids', v_notify, 'assignment', v_res);
  end if;

  if p_response = 'decline' then
    if r.status not in ('pending','snoozed') then
      return jsonb_build_object('result', 'invalid_state', 'recipient_status', r.status);
    end if;
    update public.shift_offer_recipients set status = 'declined', responded_at = now(), snooze_until = null where id = r.id;
    select count(*) into v_open from public.shift_offer_recipients x
     where x.offer_id = o.id and x.round_no = o.current_round_no and x.status in ('pending','snoozed');
    update public.shift_offers set updated_at = now() where id = o.id;
    return jsonb_build_object('result', 'declined', 'round_all_declined', v_open = 0,
      'any_open', exists (select 1 from public.shift_offer_recipients x where x.offer_id = o.id and x.status in ('pending','snoozed')));
  end if;

  -- snooze ("Palaan asiaan <pvm>")
  select * into s from public.shift_offer_settings x where x.role_type = o.role_type;
  if not (coalesce(s.snooze_any_recipient, false) or p_staff_id = any (coalesce(s.snooze_staff_ids, '{}'))) then
    return jsonb_build_object('result', 'snooze_not_allowed', 'reason', 'staff');
  end if;
  if r.status not in ('pending','snoozed') or p_snooze_until is null or p_snooze_until <= now() then
    return jsonb_build_object('result', 'invalid_state', 'recipient_status', r.status);
  end if;
  select coalesce(o.window_starts_at, w.starts_at) into v_starts from public.work_shifts w where w.id = o.shift_id;
  v_until := least(p_snooze_until, v_starts - s.snooze_min_left);
  if v_until <= now() then return jsonb_build_object('result', 'snooze_not_allowed', 'reason', 'too_close'); end if;
  update public.shift_offer_recipients set status = 'snoozed', snooze_until = v_until, responded_at = now() where id = r.id;
  return jsonb_build_object('result', 'snoozed', 'snooze_until', v_until, 'shortened', v_until < p_snooze_until);
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_compose(p_kind text, p_staff uuid, p_offer uuid, p_role text, p_starts timestamp with time zone, p_ends timestamp with time zone, p_deadline timestamp with time zone, p_ask_no integer DEFAULT NULL::integer)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  s public.shift_offer_settings%rowtype;
  v_name text; v_tz text; v_wd text; v_date text; v_a text; v_b text; v_label text;
  v_acc text; v_dec text; v_snz text; v_when text; v_snooze boolean;
begin
  select * into s from public.shift_offer_settings x where x.role_type = p_role;
  v_tz := coalesce(s.timezone, 'Europe/Helsinki');
  select st.name into v_name from public.staff st where st.id = p_staff;
  v_wd := (array['ma','ti','ke','to','pe','la','su'])[extract(isodow from (p_starts at time zone v_tz)::date)];
  v_date := to_char(p_starts at time zone v_tz, 'DD.MM.YYYY');
  v_a := to_char(p_starts at time zone v_tz, 'HH24:MI');
  v_b := to_char(p_ends at time zone v_tz, 'HH24:MI');
  v_label := public.shift_offer_role_label(p_role);
  v_when := v_wd || ' ' || v_date || ' klo ' || v_a || coalesce('–' || v_b, '');
  v_acc := public.shift_offer_link(p_offer, p_staff, p_starts, 'accept');
  v_dec := public.shift_offer_link(p_offer, p_staff, p_starts, 'decline');
  v_snooze := coalesce(s.snooze_any_recipient, false) or p_staff = any (coalesce(s.snooze_staff_ids, '{}'));
  if v_snooze and p_starts - coalesce(s.snooze_min_left, interval '14 days') > now() then
    v_snz := public.shift_offer_link(p_offer, p_staff, p_starts, 'snooze');
  end if;
  if p_kind = 'filled' then
    return 'Hei ' || coalesce(v_name, '') || E'.\nVuoro on täytetty (' || v_label || ' ' || v_wd || ' ' || v_date || ' klo ' || v_a || E').\n\n–Tapio';
  elsif p_kind = 'cancelled' then
    return 'Hei ' || coalesce(v_name, '') || E'.\n' || v_label || ' ' || v_wd || ' ' || v_date || E' peruttiin, koska hoidot ovat kiinni sinä päivänä.\n\n–Tapio';
  elsif p_kind = 'alert' then
    return 'Hei ' || coalesce(v_name, '') || E'.\n' || v_label || ' ' || v_when || E' on ilman tekijää.\n\n–Tapio';
  elsif p_kind = 'exhausted_ask' then
    return 'Hei ' || coalesce(v_name, '') || E'.\nHoitajavuoro ' || v_when || ' on yhä ilman tekijää (kysymys ' || coalesce(p_ask_no, 1)::text || '/' || coalesce(s.exhausted_ask_count, 3)::text || E'). Mitä tehdään?\n\nHyväksy vuoro: ' || coalesce(v_acc, '(linkki puuttuu)') || E'\nKieltäydy: ' || coalesce(v_dec, '(linkki puuttuu)') || E'\n\n–Tapio';
  elsif p_kind = 'reminder' then
    return 'Hei ' || coalesce(v_name, '') || E'.\nMuistutus: vapaa ' || v_label || ' ' || v_when || E'. Palasit asiaan tänään.\nVastaa viimeistään ' || coalesce(to_char(p_deadline at time zone v_tz, 'DD.MM.YYYY HH24:MI'), 'pian') || E'.\n\nHyväksy: ' || coalesce(v_acc, '(linkki puuttuu)') || E'\nKieltäydy: ' || coalesce(v_dec, '(linkki puuttuu)') || E'\n\n–Tapio';
  end if;
  return 'Hei ' || coalesce(v_name, '') || E'.\nVapaa ' || v_label || ' ' || v_when || E'.\nVastaa viimeistään ' || coalesce(to_char(p_deadline at time zone v_tz, 'DD.MM.YYYY HH24:MI'), 'pian') || E'.\n\nHyväksy: ' || coalesce(v_acc, '(linkki puuttuu)') || E'\nKieltäydy: ' || coalesce(v_dec, '(linkki puuttuu)')
    || case when v_snz is not null then E'\nPalaan asiaan: ' || v_snz else '' end
    || E'\n\n–Tapio';
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_on_exhausted(p_offer uuid, p_now timestamp with time zone, p_dry boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o public.shift_offers%rowtype;
  w public.work_shifts%rowtype;
  s public.shift_offer_settings%rowtype;
  st record; v_last timestamptz; v_date date; v_id bigint; v_close jsonb; v_staff uuid;
begin
  select * into o from public.shift_offers x where x.id = p_offer;
  select * into w from public.work_shifts x where x.id = o.shift_id;
  select * into s from public.shift_offer_settings x where x.role_type = o.role_type;
  select max(m.created_at) into v_last from public.shift_offer_messages m where m.offer_id = o.id and m.kind = 'exhausted_ask';
  select * into st from public.shift_exhausted_next_step(o.role_type, w.starts_at, o.exhausted_asks, v_last, p_now) q;
  v_date := (w.starts_at at time zone s.timezone)::date;
  if st.action = 'ask' and st.due_at <= p_now and s.exhausted_ask_staff_id is not null then
    if p_dry then return jsonb_build_object('action', 'would_ask', 'ask_no', st.ask_no, 'offer_id', o.id); end if;
    select r.id into v_id from public.shift_offer_recipients r where r.offer_id = o.id and r.staff_id = s.exhausted_ask_staff_id;
    if v_id is null then
      insert into public.shift_offer_recipients (offer_id, staff_id, round_no, round_kind, status, sent_at, deadline_at)
      values (o.id, s.exhausted_ask_staff_id, 100 + coalesce(st.ask_no, 1), 'owner_ask', 'pending', p_now,
              public.shift_offer_round_deadline(o.role_type, w.starts_at, p_now, 'named', true))
      returning id into v_id;
    else
      update public.shift_offer_recipients set status = 'pending', round_no = 100 + coalesce(st.ask_no, 1), round_kind = 'owner_ask',
             snooze_until = null, responded_at = null, sent_at = coalesce(sent_at, p_now),
             deadline_at = public.shift_offer_round_deadline(o.role_type, w.starts_at, p_now, 'named', true)
       where id = v_id;
    end if;
    perform public.shift_offer_queue_message(o.id, v_id, s.exhausted_ask_staff_id, 'exhausted_ask',
      public.shift_offer_compose('exhausted_ask', s.exhausted_ask_staff_id, o.id, o.role_type, w.starts_at, w.ends_at, null, st.ask_no),
      'offer:' || o.id::text || ':ask:' || coalesce(st.ask_no, 1)::text);
    update public.shift_offers set exhausted_asks = coalesce(st.ask_no, o.exhausted_asks + 1), status = 'escalated',
           current_round_no = 100 + coalesce(st.ask_no, 1), next_action_at = (
             select q.due_at from public.shift_exhausted_next_step(o.role_type, w.starts_at, coalesce(st.ask_no, 1), p_now, p_now) q),
           updated_at = p_now
     where id = o.id;
    return jsonb_build_object('action', 'asked', 'ask_no', st.ask_no, 'offer_id', o.id);
  end if;
  if st.action = 'ask' then
    if not p_dry then update public.shift_offers set status = 'escalated', next_action_at = st.due_at, updated_at = p_now where id = o.id; end if;
    return jsonb_build_object('action', 'ask_scheduled', 'due_at', st.due_at, 'offer_id', o.id);
  end if;
  -- close | wait_owner
  if st.due_at > p_now then
    if not p_dry then update public.shift_offers set status = 'escalated', next_action_at = st.due_at, updated_at = p_now where id = o.id; end if;
    return jsonb_build_object('action', 'close_scheduled', 'due_at', st.due_at, 'offer_id', o.id);
  end if;
  if st.action = 'close' and s.auto_close_enabled and o.role_type = 'therapist' then
    v_close := public.shift_offer_ensure_closure('hoidot', v_date, 'Tarjousmoottori: hoitajavuoro tyhjä, hoidot kiinni', p_dry);
    if not p_dry then update public.shift_offers set status = 'closed', next_action_at = null, updated_at = p_now, note = 'auto_close' where id = o.id; end if;
    return jsonb_build_object('action', 'closed', 'offer_id', o.id, 'closure', v_close);
  end if;
  if not p_dry then
    update public.shift_offers set status = 'escalated', next_action_at = null, updated_at = p_now where id = o.id;
    foreach v_staff in array coalesce(s.alert_staff_ids, '{}') loop
      perform public.shift_offer_queue_message(o.id, null, v_staff, 'alert',
        public.shift_offer_compose('alert', v_staff, o.id, o.role_type, w.starts_at, w.ends_at, null, null),
        'offer:' || o.id::text || ':alert:' || v_staff::text);
    end loop;
  end if;
  return jsonb_build_object('action', 'wait_owner', 'offer_id', o.id);
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
  if w.staffing_status is distinct from 'open' then return jsonb_build_object('action', 'skip', 'reason', 'staffing'); end if;
  if exists (select 1 from public.shift_assignments a where a.shift_id = w.id and a.status in ('assigned','confirmed')) then
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
    if o.next_action_at is not null and o.next_action_at > p_now then
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

CREATE OR REPLACE FUNCTION public.shift_offer_issue_recipients(p_offer uuid, p_role text, p_starts timestamp with time zone, p_ends timestamp with time zone, p_now timestamp with time zone, p_round integer, p_kind text, p_staff uuid[], p_names text[], p_sorts integer[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  i int; v_dl timestamptz; v_last boolean; v_id bigint; v_n int := 0; v_max int;
  v_tz text; v_date date;
begin
  select s.timezone into v_tz from public.shift_offer_settings s where s.role_type = p_role;
  if v_tz is null then
    raise exception 'Roolille % ei ole shift_offer_settings-riviä', p_role using errcode = 'P0002';
  end if;
  v_date := (p_starts at time zone v_tz)::date;
  select max(rnd.round_no) into v_max from public.shift_offer_rounds rnd
    join public.shift_offers o on o.id = p_offer
   where rnd.role_type = o.role_type and rnd.scenario = o.scenario
     and extract(isodow from v_date)::smallint = any (rnd.weekdays)
     and v_date >= rnd.valid_from and (rnd.valid_to is null or v_date <= rnd.valid_to);
  v_last := p_kind = 'all' or p_round >= coalesce(v_max, p_round);
  v_dl := public.shift_offer_round_deadline(p_role, p_starts, p_now, p_kind, v_last);
  for i in 1 .. coalesce(cardinality(p_staff), 0) loop
    v_id := null;
    insert into public.shift_offer_recipients (offer_id, staff_id, round_no, round_kind, status, sent_at, deadline_at)
    values (p_offer, p_staff[i], p_round, p_kind, 'pending', p_now, v_dl)
    on conflict (offer_id, staff_id) do nothing
    returning id into v_id;
    if v_id is null then continue; end if;
    perform public.shift_offer_queue_message(p_offer, v_id, p_staff[i], 'offer',
      public.shift_offer_compose('offer', p_staff[i], p_offer, p_role, p_starts, p_ends, v_dl, null),
      'offer:' || p_offer::text || ':staff:' || p_staff[i]::text || ':offer');
    v_n := v_n + 1;
  end loop;
  if p_kind = 'rotation' and v_n > 0 then
    update public.shift_offer_settings set rotation_last_staff_id = p_staff[cardinality(p_staff)], updated_at = now()
     where role_type = p_role;
  end if;
  update public.shift_offers set current_round_no = p_round, round_started_at = p_now, next_action_at = v_dl,
         all_sent_at = case when p_kind = 'all' then p_now else all_sent_at end,
         status = 'active', updated_at = p_now
   where id = p_offer;
  return v_n;
end $function$;

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
     where ws.status = 'active' and ws.staffing_status = 'open' and ws.starts_at > v_now and ws.starts_at <= v_now + s.start_before
     order by ws.starts_at
  loop
    v_row := public.shift_offer_ensure(w.id, v_now, v_dry);
    if v_row->>'action' not in ('skip', 'waiting') then v_actions := v_actions || v_row; end if;
  end loop;
  -- myös avoimet tarjoukset, joiden vuoro ei enää ole haussa (esim. ikkuna), mutta kierros on erääntynyt
  for w in
    select o.shift_id as id from public.shift_offers o
     where o.status in ('active','paused','escalated') and (o.next_action_at is null or o.next_action_at <= v_now)
       and not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'shift_id' = o.shift_id::text)
  loop
    v_row := public.shift_offer_ensure(w.id, v_now, v_dry);
    if v_row->>'action' not in ('skip', 'waiting') then v_actions := v_actions || v_row; end if;
  end loop;
  return jsonb_build_object('ok', true, 'dry_run', v_dry, 'now', v_now, 'cancel', v_cancel, 'service_closures', v_svc, 'actions', v_actions);
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_sender_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  e public.shift_offer_engine_settings%rowtype;
  v_limit int;
  v_messages jsonb;
begin
  select * into e from public.shift_offer_engine_settings where id;
  update public.shift_offer_messages m
     set status = 'bot_channel',
         channel = 'bot',
         to_address = null,
         locked_at = null,
         last_error = null
   where m.wamid is null
     and m.status in ('queued', 'sending')
     and public.shift_offer_is_bot_staff(m.staff_id);
  if not coalesce(e.sender_enabled, false) then
    return jsonb_build_object('ok', true, 'sender_enabled', false, 'messages', '[]'::jsonb);
  end if;
  update public.shift_offer_messages
     set status = 'unknown',
         locked_at = null,
         last_error = 'unknown_delivery'
   where status = 'sending' and wamid is null and locked_at is not null
     and locked_at < now() - interval '10 minutes'
     and not public.shift_offer_is_bot_staff(staff_id);
  v_limit := greatest(1, least(coalesce(p_limit, 20), 50));
  with picked as (
    select m.id
      from public.shift_offer_messages m
      left join public.staff st on st.id = m.staff_id
     where m.status = 'queued' and m.next_attempt_at <= now() and m.wamid is null
       and m.channel is distinct from 'bot'
       and not public.shift_offer_is_bot_staff(m.staff_id)
       and (
         m.channel = 'none'
         or (coalesce(st.whatsapp_enabled, false) and public.shift_offer_phone_e164(st.phone_e164) is not null)
       )
     order by m.id
     limit v_limit
     for update of m skip locked
  ), upd as (
    update public.shift_offer_messages m
       set status = 'sending', locked_at = now()
      from picked
     where m.id = picked.id
    returning m.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', u.id,
    'kind', u.kind,
    'channel', u.channel,
    'staff_id', u.staff_id,
    'attempts', u.attempts,
    'wamid', u.wamid,
    'status', u.status,
    'phone_raw', st.phone_e164,
    'email', st.email,
    'staff_whatsapp_enabled', coalesce(st.whatsapp_enabled, false),
    'bot_channel', public.shift_offer_is_bot_staff(u.staff_id),
    'role_type', o.role_type,
    'starts_at', w.starts_at,
    'ends_at', w.ends_at,
    'deadline_at', r.deadline_at,
    'ask_no', case when u.kind = 'exhausted_ask' then nullif(substring(u.dedupe_key from ':ask:([0-9]+)$'), '')::int else null end,
    'ask_count', s.exhausted_ask_count,
    'token', public.shift_offer_sign_token(u.offer_id, u.staff_id, coalesce(w.starts_at, now() + interval '14 days'))
  ) order by u.id), '[]'::jsonb)
    into v_messages
    from upd u
    left join public.staff st on st.id = u.staff_id
    left join public.shift_offers o on o.id = u.offer_id
    left join public.work_shifts w on w.id = o.shift_id
    left join public.shift_offer_recipients r on r.id = u.recipient_id
    left join public.shift_offer_settings s on s.role_type = o.role_type;
  v_messages := coalesce(v_messages, '[]'::jsonb);
  return jsonb_build_object(
    'ok', true,
    'sender_enabled', true,
    'whatsapp_enabled', e.whatsapp_enabled,
    'whatsapp_dry_run', e.whatsapp_dry_run,
    'allow_staff_ids', to_jsonb(e.whatsapp_allow_staff_ids),
    'messages', v_messages);
end $function$;

-- uudet funktiot pois (korvatut funktiot on palautettu yllä, joten näihin ei enää viitata)
drop function if exists booking.admin_shift_staff_link(uuid, text);
drop function if exists booking.admin_shift_staff_overview();
drop function if exists booking.shift_staff_welcome(uuid);
drop function if exists booking.shift_staff_page_respond(text, uuid, text);
drop function if exists booking.shift_staff_page(text);
drop function if exists booking.shift_offer_email_drain(integer);
drop function if exists booking.shift_offer_merge_same_day(timestamptz);
drop function if exists booking.shift_offer_extend_deadline(bigint, timestamptz);
drop function if exists booking.shift_offer_round_reminders(uuid, timestamptz, boolean);
drop function if exists booking.shift_offer_therapist_step(uuid, timestamptz, boolean);
drop function if exists booking.shift_offer_vacant_step(uuid, timestamptz, boolean);
drop function if exists booking.shift_offer_email(uuid, text, text, text, text);
drop function if exists booking.shift_offer_notice(uuid, uuid, text, text, text, text, text, bigint, jsonb);
drop function if exists booking.shift_offer_text153(text, uuid, uuid, jsonb);
drop function if exists booking._shift_staff_page_verify(text);
drop function if exists booking.shift_staff_page_url(uuid);
drop function if exists booking.shift_staff_page_token(uuid, boolean);
drop function if exists booking._shift_staff_page_sig(text);
drop function if exists booking.shift_offer_cap_label(text);
drop function if exists booking.shift_offer_when(timestamptz, timestamptz);
drop function if exists booking.shift_offer_day_treatments(date);
drop function if exists booking.shift_offer_is_vacant(uuid);
drop function if exists booking.shift_offer_last_round_cap(text, timestamptz, timestamptz);
drop function if exists booking.shift_offer_wa_next_open(timestamptz);
drop function if exists booking.shift_offer_wa_open(timestamptz);
drop function if exists booking.shift_offer_cfg_uuids(text, text);
drop function if exists booking.shift_offer_cfg_interval(text, text, interval);
drop function if exists booking.shift_offer_cfg_bool(text, boolean);
drop function if exists booking.shift_offer_cfg(text);
drop function if exists booking.email_staff_notice_payload(bigint[]);
drop table if exists booking.shift_offer_notices;
drop table if exists booking.shift_offer_message_meta;
drop table if exists booking.shift_staff_page_tokens;
drop table if exists booking.shift_staff_whatsapp_consent;
delete from booking.email_outbox where kind = 'staff_shift_notice';
alter table booking.email_outbox drop constraint if exists email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check
  check (kind in ('order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change', 'gift_card_buyer', 'gift_card_recipient', 'voucher_claim_received', 'voucher_claim_problem', 'business_quote_ack', 'business_quote_notify', 'invoice_pdf', 'product_message', 'waitlist_spot_freed', 'annual_card_code'));
delete from booking.settings where key in ('shift_offer.last_round_before', 'shift_offer.last_round_min_lead', 'shift_offer.round_reminder_before',
  'shift_offer.vacant_notice', 'shift_offer.therapist_notice', 'shift_offer.email_enabled', 'shift_offer.offer_uncertain_shifts',
  'shift_offer.unavailability_frees_shift', 'shift_offer.whatsapp_hours', 'shift_offer.welcome_enabled', 'shift_offer.already_taken_message',
  'shift_offer.wa_templates', 'shift_offer.staff_page_url');
-- Moottorin viestien merged-tila: yhdistetyt alkuperäiset (status skipped, last_error merged:<id>) jäävät skipped-tilaan.
