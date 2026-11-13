-- rollback booking_271_shift_offer_ignore_otto_unavailability
CREATE OR REPLACE FUNCTION booking.shift_offer_is_vacant(p_shift uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare w public.work_shifts%rowtype; v_n int; v_free int;
begin
  select * into w from public.work_shifts x where x.id = p_shift;
  if not found or w.status <> 'active' then return false; end if;
  select count(*), count(*) filter (where exists (
           select 1 from public.staff_unavailability u
            where u.staff_id = a.staff_id and u.starts_at < w.ends_at and u.ends_at > w.starts_at))
    into v_n, v_free
    from public.shift_assignments a where a.shift_id = w.id and a.status in ('assigned','confirmed');
  if v_n = 0 then
    return w.staffing_status = 'open'
        or (w.staffing_status = 'uncertain' and booking.shift_offer_cfg_bool('offer_uncertain_shifts', false));
  end if;
  return v_n = v_free and booking.shift_offer_cfg_bool('unavailability_frees_shift', true);
end $function$
;

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
  v_starts timestamptz; v_until timestamptz; v_res jsonb; v_notify jsonb; v_open int; v_other uuid;
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
    -- booking_153 sääntö 1: erillinen "vuoro on jo mennyt" -viesti vain asetuksella (oletus pois), kerran
    if p_response = 'accept' and booking.shift_offer_cfg_bool('already_taken_message', false) then
      perform booking.shift_offer_notice(o.id, p_staff_id, 'already_taken', 'already_taken', 'filled',
        booking.shift_offer_text153('already_taken', p_staff_id, o.id, '{}'), 'at:' || o.id::text || ':' || p_staff_id::text);
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
    update public.shift_offer_recipients set status = case when sent_at is null then 'withdrawn' else 'filled_other' end,
           snooze_until = null
     where offer_id = o.id and id <> r.id and status in ('queued','pending','snoozed');
    -- booking_153 sääntö 1: muille ei lähetetä "täytetty"-viestiä
    v_notify := '[]'::jsonb;
    update public.shift_offers set status = 'filled', accepted_staff_id = p_staff_id, accepted_recipient_id = r.id,
           accepted_at = now(), next_action_at = null, updated_at = now() where id = o.id;
    if p_apply and o.scenario = 'vacant_shift' then
      begin
        v_res := public.shift_apply_change('assign', o.shift_id, p_staff_id, null, null, null, 'offer_engine', p_actor, p_staff_id,
                                           'Tarjous ' || o.id::text, null);
        update public.shift_offers set assignment_result = v_res where id = o.id;
        -- booking_153 f: poissaolon vuoksi vapautunut vuoro: poissaolevat pois vuorosta
        if booking.shift_offer_cfg_bool('unavailability_frees_shift', true) then
          for v_other in
            select a.staff_id from public.shift_assignments a join public.work_shifts w on w.id = a.shift_id
             where a.shift_id = o.shift_id and a.staff_id <> p_staff_id and a.status in ('assigned','confirmed')
               and exists (select 1 from public.staff_unavailability u where u.staff_id = a.staff_id and u.starts_at < w.ends_at and u.ends_at > w.starts_at)
          loop
            perform public.shift_apply_change('unassign', o.shift_id, v_other, null, null, null, 'offer_engine', p_actor, p_staff_id,
                                              'Poissaolo, tarjous ' || o.id::text, null);
          end loop;
        end if;
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
end $function$
;

delete from booking.settings where key = 'shift_offer.unavailability_ignore_staff_ids';
drop function if exists booking.shift_offer_unavail_ignored();
