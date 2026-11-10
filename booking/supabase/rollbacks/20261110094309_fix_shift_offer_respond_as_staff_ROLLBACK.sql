-- fix_shift_offer_respond_as_staff_ambiguous_alias ROLLBACK: palauttaa public.shift_offer_respond_as_staff
-- edelliseen migraatiohistorian määritelmään: PROD 20261022022221 shift_offer_response_page
-- (HUOM: tämä versio sisältää korjatun virheen "column reference w.id is ambiguous").
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
