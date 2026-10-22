-- Vastaussivu: tokenin henkilön avoimet tarjoukset ja vastaus vain omaan vuoroon.
-- EI ajettu tuotantoon. EI deployta. EI lähetä viestejä.
-- Henkilö tulee vain poletista. Toisen henkilön offer_id palauttaa not_owner eikä muuta riviä.

create or replace function public.shift_offer_open_for_token(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_tok jsonb; v_staff uuid; v_focus uuid; v_offers jsonb;
begin
  v_tok := public.shift_offer_verify_token(p_token);
  if coalesce(v_tok->>'ok', 'false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', 'bad_token');
  end if;
  v_staff := (v_tok->>'staff_id')::uuid;
  v_focus := (v_tok->>'offer_id')::uuid;
  select coalesce(jsonb_agg(jsonb_build_object(
           'offer_id', o.id,
           'role_type', o.role_type,
           'starts_at', coalesce(o.window_starts_at, w.starts_at),
           'ends_at', coalesce(o.window_ends_at, w.ends_at),
           'deadline_at', rec.deadline_at,
           'snooze_allowed',
             (coalesce(s.snooze_any_recipient, false) or v_staff = any (coalesce(s.snooze_staff_ids, '{}')))
             and coalesce(o.window_starts_at, w.starts_at) - coalesce(s.snooze_min_left, interval '14 days') > now()
         ) order by coalesce(o.window_starts_at, w.starts_at), o.id), '[]'::jsonb)
    into v_offers
    from public.shift_offer_recipients rec
    join public.shift_offers o on o.id = rec.offer_id
    join public.work_shifts w on w.id = o.shift_id
    left join public.shift_offer_settings s on s.role_type = o.role_type
   where rec.staff_id = v_staff
     and rec.status = 'pending'
     and o.status in ('active', 'paused', 'escalated')
     and (rec.deadline_at is null or rec.deadline_at > now())
     and coalesce(o.window_ends_at, w.ends_at) > now();
  return jsonb_build_object(
    'ok', true,
    'staff_id', v_staff,
    'focus_offer_id', v_focus,
    'offers', coalesce(v_offers, '[]'::jsonb));
end $$;

-- Poletti todistaa staff_id:n. p_offer_id kelpaa vain, jos sillä on tämän henkilön vastaanottajarivi.
create or replace function public.shift_offer_respond_as_staff(
  p_token text, p_offer_id uuid, p_response text, p_snooze_until timestamptz)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_tok jsonb; v_staff uuid; v jsonb;
  o public.shift_offers%rowtype; w public.work_shifts%rowtype;
  v_role text; v_starts timestamptz; v_ends timestamptz; v_deadline timestamptz;
  v_notify uuid;
begin
  v_tok := public.shift_offer_verify_token(p_token);
  if coalesce(v_tok->>'ok', 'false') <> 'true' then
    return jsonb_build_object('result', 'bad_token');
  end if;
  v_staff := (v_tok->>'staff_id')::uuid;
  if p_offer_id is null or not exists (
    select 1 from public.shift_offer_recipients rec
     where rec.offer_id = p_offer_id and rec.staff_id = v_staff
  ) then
    return jsonb_build_object('result', 'not_owner');
  end if;
  select o.role_type, coalesce(o.window_starts_at, w.starts_at), coalesce(o.window_ends_at, w.ends_at), rec.deadline_at
    into v_role, v_starts, v_ends, v_deadline
    from public.shift_offers o
    join public.work_shifts w on w.id = o.shift_id
    join public.shift_offer_recipients rec on rec.offer_id = o.id and rec.staff_id = v_staff
   where o.id = p_offer_id;
  v := public.shift_offer_respond(p_offer_id, v_staff, p_response, p_snooze_until, true, 'tyovuoro-tapio');
  if v->>'result' = 'already_filled' then
    v := v || jsonb_build_object('result', 'already_taken');
  end if;
  if v->>'result' = 'accepted' then
    select * into o from public.shift_offers x where x.id = p_offer_id;
    select * into w from public.work_shifts x where x.id = o.shift_id;
    for v_notify in
      select distinct t::uuid from jsonb_array_elements_text(coalesce(v->'notify_filled_staff_ids', '[]'::jsonb)) t
    loop
      perform public.shift_offer_queue_message(o.id, null, v_notify, 'filled',
        public.shift_offer_compose('filled', v_notify, o.id, o.role_type, w.starts_at, w.ends_at, null, null),
        'offer:' || o.id::text || ':staff:' || v_notify::text || ':filled');
      update public.shift_offer_recipients set filled_notified_at = now()
       where offer_id = o.id and staff_id = v_notify and filled_notified_at is null;
    end loop;
  end if;
  return v || jsonb_build_object(
    'offer_id', p_offer_id,
    'role_type', v_role,
    'starts_at', v_starts,
    'ends_at', v_ends,
    'deadline_at', v_deadline);
end $$;

revoke all on function public.shift_offer_open_for_token(text),
  public.shift_offer_respond_as_staff(text, uuid, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.shift_offer_open_for_token(text),
  public.shift_offer_respond_as_staff(text, uuid, text, timestamptz)
  to service_role;
