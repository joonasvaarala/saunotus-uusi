-- ROLLBACK booking_155: palauttaa booking_153:n tilan. Uudelleenajettava (toinen ajo ei tee mitään).
-- Poistaa "jo mennyt" -sähköpostikopion triggerin, palauttaa shift_offer_email_drain- ja shift_staff_page-funktiot booking_153:n muotoon
-- (sama pg_get_functiondef kuin booking_153:n jälkeen) ja asetuksen shift_offer.already_taken_message arvoon false.
-- Jo jonoon menneet sähköpostit (email_outbox, dedupe b153:at-mail:*) jäävät; niitä ei poisteta.
set local lock_timeout = '5s';

drop trigger if exists shift_offer_already_taken_mail_trg on booking.shift_offer_notices;
drop function if exists booking._shift_offer_already_taken_mail();

update booking.settings
   set value = 'false'::jsonb,
       description = 'booking_153: lähetetäänkö myöhäiselle hyväksyjälle erillinen "vuoro on jo mennyt" -viesti. Oletus pois (sivu ja WhatsApp-vastaus kertovat sen joka tapauksessa).'
 where key = 'shift_offer.already_taken_message' and description like 'booking_155:%';

create or replace function booking.shift_offer_email_drain(p_limit int default 50) returns int
language plpgsql volatile security definer set search_path = '' as $$
declare m record; v_out bigint; v_n int := 0; v_subj text;
begin
  if not booking.shift_offer_cfg_bool('email_enabled', false) then return 0; end if;
  for m in
    select x.*, mm.subkind from public.shift_offer_messages x
      left join booking.shift_offer_message_meta mm on mm.message_id = x.id
     where x.status = 'queued' and x.channel = 'email' and x.wamid is null and x.next_attempt_at <= now()
       and not public.shift_offer_is_bot_staff(x.staff_id)
     order by x.id limit greatest(1, least(coalesce(p_limit, 50), 200))
     for update of x skip locked
  loop
    v_subj := case
      when m.subkind = 'day_digest' then 'Vuoroasiat yhdellä viestillä'
      when m.kind = 'offer' then 'Vapaa työvuoro'
      when m.kind = 'reminder' then 'Muistutus työvuorosta'
      when m.kind = 'filled' then 'Vuoro on jo mennyt'
      when m.kind = 'cancelled' then 'Työvuoro peruttu'
      else 'Työvuoroilmoitus' end;
    v_out := booking.shift_offer_email(m.staff_id, v_subj || ' – Tapio', m.body, 'msg:' || m.id::text,
                                       case when m.subkind = 'day_digest' then booking.shift_staff_page_url(m.staff_id) end);
    if v_out is null then
      update public.shift_offer_messages set status = 'failed_no_contact', last_error = 'email_unavailable', locked_at = null where id = m.id;
    else
      update public.shift_offer_messages set status = 'sent', sent_at = now(), to_address = coalesce(to_address, (select payload->>'to_email' from booking.email_outbox where id = v_out)),
             last_error = 'email_outbox:' || v_out::text, locked_at = null where id = m.id;
      if m.recipient_id is not null and m.kind in ('offer','reminder') then perform booking.shift_offer_extend_deadline(m.recipient_id, now()); end if;
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function booking.shift_staff_page(p_token text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_staff uuid; v_name text; v_open jsonb; v_done jsonb;
begin
  v_staff := booking._shift_staff_page_verify(p_token);
  if v_staff is null then return jsonb_build_object('ok', false, 'error', 'bad_token'); end if;
  update booking.shift_staff_page_tokens set last_used_at = now() where staff_id = v_staff;
  select split_part(btrim(st.name), ' ', 1) into v_name from public.staff st where st.id = v_staff;
  with x as (
    select o.id as offer_id, o.role_type, coalesce(o.window_starts_at, w.starts_at) as starts_at, coalesce(o.window_ends_at, w.ends_at) as ends_at,
           rec.status as my_status, rec.deadline_at, rec.responded_at, o.status as offer_status,
           (o.status in ('active','paused','escalated') and rec.status in ('pending','snoozed','declined')) as can_accept,
           (o.status in ('active','paused','escalated') and rec.status in ('pending','snoozed')) as can_decline
      from public.shift_offer_recipients rec
      join public.shift_offers o on o.id = rec.offer_id
      join public.work_shifts w on w.id = o.shift_id
     where rec.staff_id = v_staff and rec.status not in ('queued','withdrawn') and rec.round_no < 100
       and coalesce(o.window_ends_at, w.ends_at) > now() and o.status <> 'cancelled' and w.status = 'active')
  select coalesce(jsonb_agg(jsonb_build_object('offer_id', offer_id, 'role_type', role_type, 'starts_at', starts_at, 'ends_at', ends_at,
           'deadline_at', deadline_at, 'my_status', my_status, 'can_accept', can_accept, 'can_decline', can_decline) order by starts_at, offer_id)
           filter (where my_status in ('pending','snoozed') and can_decline), '[]'::jsonb),
         coalesce(jsonb_agg(jsonb_build_object('offer_id', offer_id, 'role_type', role_type, 'starts_at', starts_at, 'ends_at', ends_at,
           'responded_at', responded_at,
           'my_status', case when my_status = 'pending' or my_status = 'snoozed' then 'closed' else my_status end,
           'can_accept', can_accept, 'can_decline', false) order by starts_at, offer_id)
           filter (where not (my_status in ('pending','snoozed') and can_decline)), '[]'::jsonb)
    into v_open, v_done from x;
  return jsonb_build_object('ok', true, 'name', v_name, 'open', v_open, 'answered', v_done);
end $$;
