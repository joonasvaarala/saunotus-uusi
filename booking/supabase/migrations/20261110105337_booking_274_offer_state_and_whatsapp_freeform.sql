-- booking_274 (Joonas t1570u): tarjouksen tila vastaajalle (jo mennyt / päättynyt / peruttu / ei enää tarjolla),
-- WhatsAppin vapaamuotoiset vastaukset ja reaktiot.

CREATE OR REPLACE FUNCTION public.shift_offer_short_when(p_role text, p_starts timestamptz, p_ends timestamptz)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  -- "Lämmitysvuoro ke 18.11. klo 10–16" (minuutit vain jos eivät ole :00)
  select case p_role when 'heater' then 'Lämmitysvuoro' when 'reception' then 'Vastaanottovuoro'
                     when 'therapist' then 'Hoitajavuoro' else 'Vuoro' end
    || ' ' || case extract(isodow from (p_starts at time zone 'Europe/Helsinki'))
           when 1 then 'ma' when 2 then 'ti' when 3 then 'ke' when 4 then 'to'
           when 5 then 'pe' when 6 then 'la' else 'su' end
    || ' ' || to_char(p_starts at time zone 'Europe/Helsinki', 'FMDD.FMMM.')
    || ' klo ' || case when to_char(p_starts at time zone 'Europe/Helsinki', 'MI') = '00'
                       then to_char(p_starts at time zone 'Europe/Helsinki', 'FMHH24')
                       else to_char(p_starts at time zone 'Europe/Helsinki', 'FMHH24.MI') end
    || coalesce('–' || case when to_char(p_ends at time zone 'Europe/Helsinki', 'MI') = '00'
                       then to_char(p_ends at time zone 'Europe/Helsinki', 'FMHH24')
                       else to_char(p_ends at time zone 'Europe/Helsinki', 'FMHH24.MI') end, '')
$function$;

CREATE OR REPLACE FUNCTION public.shift_offer_recipient_state(p_staff uuid, p_offer uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- Palauttaa: state (open | yours | filled_other | expired | withdrawn | cancelled | declined | not_recipient),
-- title, text (näytettävä teksti; open-tilassa null) sekä vuoron tiedot. Ei paljasta, kuka vuoron sai.
declare
  rec public.shift_offer_recipients%rowtype; so public.shift_offers%rowtype; ws public.work_shifts%rowtype;
  v_state text; v_starts timestamptz; v_ends timestamptz; v_what text; v_text text; v_title text;
begin
  select * into so from public.shift_offers x where x.id = p_offer;
  if not found then return jsonb_build_object('state', 'not_recipient', 'offer_id', p_offer); end if;
  select * into ws from public.work_shifts x where x.id = so.shift_id;
  v_starts := coalesce(so.window_starts_at, ws.starts_at);
  v_ends := coalesce(so.window_ends_at, ws.ends_at);
  select * into rec from public.shift_offer_recipients x where x.offer_id = p_offer and x.staff_id = p_staff
   order by (x.status = 'pending') desc, x.id desc limit 1;
  if not found or rec.status = 'queued' then
    v_state := 'not_recipient';
  elsif so.status = 'filled' then
    v_state := case when so.accepted_staff_id = p_staff then 'yours' else 'filled_other' end;
  elsif so.status = 'cancelled' then
    v_state := 'cancelled';
  elsif rec.status = 'withdrawn' then
    v_state := 'withdrawn';
  elsif rec.status = 'declined' then
    v_state := 'declined';
  elsif rec.status = 'filled_other' then
    v_state := 'filled_other';
  elsif rec.status = 'accepted' then
    v_state := 'yours';
  elsif so.status in ('closed', 'exhausted') or v_ends <= now()
        or (rec.deadline_at is not null and rec.deadline_at <= now()) then
    v_state := 'expired';
  else
    v_state := 'open';
  end if;
  v_what := public.shift_offer_short_when(so.role_type, v_starts, v_ends);
  v_title := case v_state
    when 'yours' then 'Vuoro on sinun'
    when 'filled_other' then 'Tämä vuoro on jo mennyt'
    when 'expired' then 'Vastausaika on päättynyt'
    when 'withdrawn' then 'Vuoroa ei enää tarjota sinulle'
    when 'cancelled' then 'Vuoro on peruttu'
    when 'declined' then 'Kieltäytyminen kirjattu'
    when 'not_recipient' then 'Tähän vuoroon ei voi vastata'
    else null end;
  v_text := case v_state
    when 'yours' then v_what || ' on sinun. Kiitos!'
    when 'filled_other' then v_what || ' on jo täytetty. Kiitos!'
    when 'expired' then v_what || ': vastausaika on päättynyt. Kiitos!'
    when 'withdrawn' then v_what || ' ei ole enää tarjolla sinulle. Kiitos!'
    when 'cancelled' then v_what || ' on peruttu.'
    when 'declined' then v_what || ': kieltäytymisesi on kirjattu. Kiitos!'
    when 'not_recipient' then 'Tätä vuoroa ei ole tarjottu sinulle.'
    else null end;
  return jsonb_build_object('state', v_state, 'title', v_title, 'text', v_text,
    'offer_id', so.id, 'role_type', so.role_type, 'starts_at', v_starts, 'ends_at', v_ends,
    'deadline_at', rec.deadline_at, 'when', v_what);
end $function$;

CREATE OR REPLACE FUNCTION public._whatsapp_closed_offer_reply(p_staff uuid, p_offer uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- WhatsApp-vastaus suljetusta tarjouksesta. p_offer null -> viimeisin tälle henkilölle 14 vrk sisällä lähetetty tarjous,
-- jonka vuoro ei ole vielä alkanut. null, jos sopivaa tarjousta ei ole tai se on yhä auki.
declare v_offer uuid := p_offer; v jsonb;
begin
  if v_offer is null then
    select rec.offer_id into v_offer
      from public.shift_offer_recipients rec
      join public.shift_offers so on so.id = rec.offer_id
      join public.work_shifts ws on ws.id = so.shift_id
     where rec.staff_id = p_staff and rec.sent_at is not null and rec.sent_at > now() - interval '14 days'
       and coalesce(so.window_starts_at, ws.starts_at) > now()
     order by rec.sent_at desc, rec.id desc
     limit 1;
  end if;
  if v_offer is null then return null; end if;
  v := public.shift_offer_recipient_state(p_staff, v_offer);
  if v->>'state' in ('open', 'not_recipient') or v->>'text' is null then return null; end if;
  return public._whatsapp_reply(v->>'text');
end $function$;

CREATE OR REPLACE FUNCTION public._whatsapp_freeform(p_message_id uuid, p_staff uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- Tunnistamaton viesti: reaktio -> ei vastausta. "En pääse" / "ei käy" -> kieltäytyminen.
-- "Käy" / "pääsen" -> kysytään vahvistus napeilla (ei kirjata hyväksyntää suoraan). Muu -> null.
declare v_type text; v_text text; v_ids uuid[]; v_n int; v_res jsonb; v_what text;
begin
  select m.message_type, m.message_text into v_type, v_text
    from public.whatsapp_messages m where m.id = p_message_id and m.direction = 'inbound';
  if not found then return null; end if;
  if v_type = 'reaction' then return public._whatsapp_silent(); end if;
  v_text := btrim(regexp_replace(regexp_replace(lower(coalesce(v_text, '')), '[^a-z0-9åäöé]+', ' ', 'g'), '\s+', ' ', 'g'));
  if v_text = '' or length(v_text) > 200 then return null; end if;
  select coalesce(array_agg(o.offer_id order by o.starts_at, o.offer_id), '{}') into v_ids
    from public._whatsapp_open_offers(p_staff) o;
  v_n := coalesce(cardinality(v_ids), 0);
  if v_text ~ '\m(en|ei)\s+(pääse|paase|pääsekään|pysty|ehdi|voi|käy|kay|sovi|onnistu|ota|tule|valitettavasti)\M' then
    if v_n = 0 then
      return coalesce(public._whatsapp_closed_offer_reply(p_staff, null),
                      public._whatsapp_reply('Kiitos tiedosta! Sinulla ei ole avointa vuorotarjousta.'));
    end if;
    if v_n = 1 then
      return public.whatsapp_inbound_act(p_message_id, jsonb_build_object('op', 'decline', 'offer_id', v_ids[1]));
    end if;
    return public.whatsapp_inbound_act(p_message_id, jsonb_build_object('op', 'decline'));
  end if;
  if v_text ~ '^(käy|kay|käy se|kay se|pääsen|paasen|voin|sopii|onnistuu|tulen|otan sen|joo käy|joo kay|kyllä käy|kylla kay)(\s|$)'
     or v_text ~ '\m(pääsen|paasen|voin tulla|käy hyvin|kay hyvin|käy mulle|käy minulle|sopii mulle|sopii minulle)\M' then
    if v_n = 0 then
      return coalesce(public._whatsapp_closed_offer_reply(p_staff, null),
                      public._whatsapp_reply('Kiitos! Sinulla ei ole avointa vuorotarjousta.'));
    end if;
    if v_n = 1 then
      select public.shift_offer_short_when(o.role_type, o.starts_at, o.ends_at) into v_what
        from public._whatsapp_open_offers(p_staff) o where o.offer_id = v_ids[1];
      return public._whatsapp_reply('Otatko vuoron: ' || coalesce(v_what, 'vuoro') || '? Vahvista napista.',
        jsonb_build_array(
          jsonb_build_object('id', 'a:' || v_ids[1]::text, 'title', 'Hyväksy'),
          jsonb_build_object('id', 'd:' || v_ids[1]::text, 'title', 'En ota')));
    end if;
    return public.whatsapp_inbound_act(p_message_id, jsonb_build_object('op', 'accept'));
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_open_for_token(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  -- booking_274: 'focus' = linkin tarjouksen tila tälle henkilölle (state, title, text, vuoron tiedot)
  return jsonb_build_object(
    'ok', true,
    'staff_id', v_staff,
    'focus_offer_id', v_focus,
    'focus', public.shift_offer_recipient_state(v_staff, v_focus),
    'offers', coalesce(v_offers, '[]'::jsonb));
end $function$;
CREATE OR REPLACE FUNCTION public.whatsapp_inbound_act(p_message_id uuid, p_intent jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_staff uuid;
  v_own boolean;
  v_all boolean;
  v_edit boolean;
  v_op text;
  v_body text := '';
  v_n int := 0;
  v_ids uuid[] := '{}';
  v_offer_ids uuid[] := '{}';
  v_buttons jsonb := '[]'::jsonb;
  v_shift uuid;
  v_offer uuid;
  v_index int;
  v_name text;
  v_summary text;
  v_who text;
  v_target uuid;
  v_target_name text;
  v_matches int;
  v_action uuid;
  v_kind text;
  v_starts timestamptz;
  v_ends timestamptz;
  v_res jsonb;
  v_pending public.whatsapp_pending_actions%rowtype;
  v_offer_n int;
  v_line text;
  r record;
  q record;
begin
  if not coalesce((select e.whatsapp_inbound_enabled from public.shift_offer_engine_settings e where e.id), false) then
    return public._whatsapp_silent();
  end if;
  select m.staff_id into v_staff
    from public.whatsapp_messages m
   where m.id = p_message_id and m.direction = 'inbound';
  if v_staff is null then
    return public._whatsapp_silent();
  end if;

  select a.view_own, a.view_all, a.can_edit into v_own, v_all, v_edit
    from public._whatsapp_actor_access(v_staff) a;
  v_op := coalesce(p_intent->>'op', 'unknown');

  if v_op = 'help' then
    v_body := E'Hei, tässä Tapio.\nKirjoita vuorot, niin näytän tulevat vuorosi.\nAvoimeen tarjoukseen: hyväksy tai en ota.';
    if v_edit then
      v_body := v_body || E'\nKaikkien vuorot: kaikki vuorot\nYhden henkilön vuorot: vuorot Maija\nMuutos vahvistetaan erikseen: peru 2, anna 2 Maija, pois 2 Maija, aika 2 25.10.2026 16:00-20:00';
    end if;
    return public._whatsapp_reply(v_body);
  end if;

  if v_op = 'own_shifts' then
    if not coalesce(v_own, false) then
      return public._whatsapp_reply('Sinulla ei ole oikeutta katsoa vuoroja.');
    end if;
    for r in
      select w.id, w.role_type, w.starts_at, w.ends_at
        from public.shift_assignments sa
        join public.work_shifts w on w.id = sa.shift_id
       where sa.staff_id = v_staff
         and sa.status in ('assigned', 'confirmed')
         and w.status = 'active'
         and w.ends_at > now()
         and w.starts_at < now() + interval '62 days'
       order by w.starts_at, w.id
       limit 12
    loop
      v_n := v_n + 1;
      v_ids := v_ids || r.id;
      v_body := v_body || v_n::text || '. ' || public._whatsapp_when(r.starts_at, r.ends_at) || ' ' || public._whatsapp_role(r.role_type) || E'\n';
    end loop;
    if v_n = 0 then
      v_body := E'Tulevia vuoroja ei ole.\n';
    else
      v_body := E'Tulevat vuorosi:\n' || v_body;
    end if;
    v_offer_n := 0;
    for q in select * from public._whatsapp_open_offers(v_staff) loop
      v_offer_n := v_offer_n + 1;
      v_offer_ids := v_offer_ids || q.offer_id;
      if v_offer_n = 1 then
        v_body := v_body || E'\nAvoin tarjous:\n';
      end if;
      v_body := v_body || v_offer_n::text || '. ' || public._whatsapp_when(q.starts_at, q.ends_at) || ' ' || public._whatsapp_role(q.role_type) || E'\n';
    end loop;
    if v_offer_n = 1 then
      v_buttons := jsonb_build_array(
        jsonb_build_object('id', 'a:' || v_offer_ids[1]::text, 'title', 'Hyväksy'),
        jsonb_build_object('id', 'd:' || v_offer_ids[1]::text, 'title', 'En ota'));
    elsif v_offer_n > 1 then
      v_body := v_body || E'Kirjoita hyväksy ja numero.\n';
      v_buttons := '[]'::jsonb;
      for v_n in 1..least(v_offer_n, 3) loop
        v_buttons := v_buttons || jsonb_build_array(jsonb_build_object('id', 'a:' || v_offer_ids[v_n]::text, 'title', 'Hyväksy ' || v_n::text));
      end loop;
    end if;
    perform public._whatsapp_save_context(v_staff, v_ids, v_offer_ids, 'both');
    return public._whatsapp_reply(v_body, v_buttons);
  end if;

  if v_op in ('all_shifts', 'person_shifts') then
    if not coalesce(v_all, false) then
      if coalesce(v_own, false) then
        return public._whatsapp_reply('Näet vain omat vuorosi. Kirjoita vuorot.');
      end if;
      return public._whatsapp_reply('Sinulla ei ole oikeutta katsoa vuoroja.');
    end if;
    v_target := null;
    if v_op = 'person_shifts' then
      v_name := public._whatsapp_clean(p_intent->>'name');
      select count(*) into v_matches from public._whatsapp_match_staff(v_name);
      if v_matches = 0 then
        return public._whatsapp_reply('En löytänyt työntekijää tällä nimellä.');
      end if;
      if v_matches > 1 then
        select string_agg(public._whatsapp_clean(s.name), ', ' order by s.name) into v_who
          from public._whatsapp_match_staff(v_name) s;
        return public._whatsapp_reply('Useita työntekijöitä: ' || coalesce(v_who, '') || '. Tarkenna nimeä.');
      end if;
      select s.id, public._whatsapp_clean(s.name) into v_target, v_target_name
        from public._whatsapp_match_staff(v_name) s;
    end if;
    for r in
      select w.id, w.role_type, w.starts_at, w.ends_at,
             coalesce((
               select string_agg(public._whatsapp_clean(s.name), ', ' order by s.name)
                 from public.shift_assignments sa
                 join public.staff s on s.id = sa.staff_id
                where sa.shift_id = w.id and sa.status in ('assigned', 'confirmed')
             ), 'ei tekijää') as who
        from public.work_shifts w
       where w.status = 'active'
         and w.ends_at > now()
         and w.starts_at < now() + interval '62 days'
         and (v_target is null or exists (
               select 1 from public.shift_assignments sa
                where sa.shift_id = w.id and sa.staff_id = v_target and sa.status in ('assigned', 'confirmed')))
       order by w.starts_at, w.role_type, w.id
       limit 12
    loop
      v_n := v_n + 1;
      v_ids := v_ids || r.id;
      v_line := v_n::text || '. ' || public._whatsapp_when(r.starts_at, r.ends_at) || ' ' || public._whatsapp_role(r.role_type);
      if v_op = 'all_shifts' then
        v_line := v_line || ' – ' || r.who;
      end if;
      v_body := v_body || v_line || E'\n';
    end loop;
    if v_op = 'person_shifts' then
      v_body := case when v_n = 0
        then v_target_name || E' ei ole tulevia vuoroja.\n'
        else v_target_name || E' tulevat vuorot:\n' || v_body end;
    else
      v_body := case when v_n = 0 then E'Tulevia vuoroja ei ole.\n' else E'Tulevat vuorot:\n' || v_body end;
    end if;
    perform public._whatsapp_save_context(v_staff, v_ids, null, 'shifts');
    return public._whatsapp_reply(v_body);
  end if;

  if v_op in ('accept', 'decline') then
    begin
      v_offer := nullif(p_intent->>'offer_id', '')::uuid;
    exception when invalid_text_representation then
      return public._whatsapp_reply('Tätä tarjousta ei ole sinulle.');
    end;
    if v_offer is null and nullif(p_intent->>'index', '') is not null then
      begin
        v_index := (p_intent->>'index')::int;
      exception when invalid_text_representation then
        v_index := null;
      end;
      select c.offer_ids into v_offer_ids
        from public.whatsapp_staff_context c
       where c.staff_id = v_staff and c.expires_at > now();
      if v_index is null or v_offer_ids is null or v_index < 1 or v_index > coalesce(cardinality(v_offer_ids), 0) then
        return public._whatsapp_reply('En löytänyt tarjousta tällä numerolla. Kirjoita vuorot.');
      end if;
      v_offer := v_offer_ids[v_index];
    end if;
    if v_offer is null then
      select coalesce(array_agg(o.offer_id order by o.starts_at, o.offer_id), '{}') into v_offer_ids
        from public._whatsapp_open_offers(v_staff) o;
      v_offer_n := coalesce(cardinality(v_offer_ids), 0);
      if v_offer_n = 0 then
        -- booking_274: kerro suljetun tarjouksen tila (jo mennyt, päättynyt, peruttu)
        return coalesce(public._whatsapp_closed_offer_reply(v_staff, null),
                        public._whatsapp_reply('Sinulla ei ole avointa vuorotarjousta.'));
      end if;
      if v_offer_n > 1 then
        v_body := E'Sinulla on useita tarjouksia:\n';
        v_n := 0;
        for q in select * from public._whatsapp_open_offers(v_staff) loop
          v_n := v_n + 1;
          v_body := v_body || v_n::text || '. ' || public._whatsapp_when(q.starts_at, q.ends_at) || ' ' || public._whatsapp_role(q.role_type) || E'\n';
        end loop;
        v_body := v_body || 'Kirjoita hyväksy ja numero.';
        perform public._whatsapp_save_context(v_staff, null, v_offer_ids, 'offers');
        v_buttons := '[]'::jsonb;
        for v_n in 1..least(v_offer_n, 3) loop
          v_buttons := v_buttons || jsonb_build_array(jsonb_build_object(
            'id', case when v_op = 'decline' then 'd:' else 'a:' end || v_offer_ids[v_n]::text,
            'title', case when v_op = 'decline' then 'En ota ' else 'Hyväksy ' end || v_n::text));
        end loop;
        return public._whatsapp_reply(v_body, v_buttons);
      end if;
      v_offer := v_offer_ids[1];
    end if;
    if not exists (
      select 1 from public.shift_offer_recipients rec
       where rec.offer_id = v_offer and rec.staff_id = v_staff
    ) then
      return public._whatsapp_reply('Tätä tarjousta ei ole sinulle.');
    end if;
    v_res := public.shift_offer_respond(v_offer, v_staff, case when v_op = 'decline' then 'decline' else 'accept' end,
                                         null, true, 'whatsapp');
    if v_res->>'result' = 'accepted' then
      for r in
        select distinct x.val::uuid as staff_id
          from jsonb_array_elements_text(coalesce(v_res->'notify_filled_staff_ids', '[]'::jsonb)) as x(val)
      loop
        perform public.shift_offer_queue_message(
          v_offer, null, r.staff_id, 'filled',
          public.shift_offer_compose('filled', r.staff_id, v_offer,
            (select o.role_type from public.shift_offers o where o.id = v_offer),
            (select w.starts_at from public.work_shifts w join public.shift_offers o on o.shift_id = w.id where o.id = v_offer),
            (select w.ends_at from public.work_shifts w join public.shift_offers o on o.shift_id = w.id where o.id = v_offer),
            null, null),
          'offer:' || v_offer::text || ':staff:' || r.staff_id::text || ':filled');
        update public.shift_offer_recipients set filled_notified_at = now()
         where offer_id = v_offer and staff_id = r.staff_id and filled_notified_at is null;
      end loop;
      select public._whatsapp_when(coalesce(o.window_starts_at, w.starts_at), coalesce(o.window_ends_at, w.ends_at))
             || ' ' || public._whatsapp_role(o.role_type), o.shift_id
        into v_summary, v_shift
        from public.shift_offers o
        join public.work_shifts w on w.id = o.shift_id
       where o.id = v_offer;
      return public._whatsapp_reply('Vuoro on sinun: ' || coalesce(v_summary, 'vuoro') || '.', '[]'::jsonb, v_shift);
    end if;
    if v_res->>'result' = 'declined' then
      return public._whatsapp_reply('Tarjous on hylätty.');
    end if;
    if v_res->>'result' in ('already_filled', 'already_taken') then
      return coalesce(public._whatsapp_closed_offer_reply(v_staff, v_offer),
                      public._whatsapp_reply('Kiitos! Vuoro on jo mennyt toiselle.'));
    end if;
    if v_res->>'result' = 'already_yours' then
      return public._whatsapp_reply('Vuoro on jo sinun.');
    end if;
    if v_res->>'result' = 'not_recipient' then
      return public._whatsapp_reply('Tätä tarjousta ei ole sinulle.');
    end if;
    return coalesce(public._whatsapp_closed_offer_reply(v_staff, v_offer),
                    public._whatsapp_reply('Tähän tarjoukseen ei voi enää vastata.'));
  end if;

  if v_op in ('prepare_cancel', 'prepare_assign', 'prepare_unassign', 'prepare_time') then
    if not coalesce(v_edit, false) then
      return public._whatsapp_reply('Vain ylläpitäjä voi muuttaa vuoroja.');
    end if;
    if not public._shift_db_first_enabled() then
      return public._whatsapp_reply('Vuorojen muokkaus ei ole juuri nyt käytössä.');
    end if;
    begin
      v_index := (p_intent->>'index')::int;
    exception when invalid_text_representation then
      v_index := null;
    end;
    select c.shift_ids into v_ids
      from public.whatsapp_staff_context c
     where c.staff_id = v_staff and c.expires_at > now();
    if v_index is null or v_ids is null or v_index < 1 or v_index > coalesce(cardinality(v_ids), 0) then
      return public._whatsapp_reply('Numero ei ole viimeisimmällä listalla. Kirjoita kaikki vuorot ja yritä uudelleen.');
    end if;
    v_shift := v_ids[v_index];
    select public._whatsapp_role(w.role_type) || ' ' || public._whatsapp_when(w.starts_at, w.ends_at)
           || ' (' || coalesce((
             select string_agg(public._whatsapp_clean(s.name), ', ' order by s.name)
               from public.shift_assignments sa
               join public.staff s on s.id = sa.staff_id
              where sa.shift_id = w.id and sa.status in ('assigned', 'confirmed')
           ), 'ei tekijää') || ')'
      into v_summary
      from public.work_shifts w
     where w.id = v_shift and w.status = 'active' and w.ends_at > now();
    if v_summary is null then
      return public._whatsapp_reply('Vuoroa ei voi muokata. Listaa vuorot uudelleen.');
    end if;
    v_target := null;
    v_starts := null;
    v_ends := null;
    if v_op = 'prepare_cancel' then
      v_kind := 'cancel';
      v_body := 'Vahvistatko peruutuksen: ' || v_summary || '?';
    elsif v_op in ('prepare_assign', 'prepare_unassign') then
      v_kind := case when v_op = 'prepare_assign' then 'assign' else 'unassign' end;
      v_name := public._whatsapp_clean(p_intent->>'name');
      select count(*) into v_matches from public._whatsapp_match_staff(v_name);
      if v_matches = 0 then
        return public._whatsapp_reply('En löytänyt työntekijää tällä nimellä.');
      end if;
      if v_matches > 1 then
        select string_agg(public._whatsapp_clean(s.name), ', ' order by s.name) into v_who
          from public._whatsapp_match_staff(v_name) s;
        return public._whatsapp_reply('Useita työntekijöitä: ' || coalesce(v_who, '') || '. Tarkenna nimeä.');
      end if;
      select s.id, public._whatsapp_clean(s.name) into v_target, v_target_name
        from public._whatsapp_match_staff(v_name) s;
      v_body := case when v_kind = 'assign'
        then 'Vahvistatko: laitan ' || v_target_name || ' vuoroon ' || v_summary || '?'
        else 'Vahvistatko: poistan henkilön ' || v_target_name || ' vuorosta ' || v_summary || '?' end;
    else
      v_kind := 'change_time';
      begin
        v_starts := (to_date(p_intent->>'date', 'FMDD.FMMM.YYYY') + (p_intent->>'start')::time) at time zone 'Europe/Helsinki';
        v_ends := (to_date(p_intent->>'date', 'FMDD.FMMM.YYYY') + (p_intent->>'end')::time) at time zone 'Europe/Helsinki';
      exception when others then
        return public._whatsapp_reply('Aika ei kelpaa. Käytä muotoa 25.10.2026 16:00-20:00.');
      end;
      if v_ends <= v_starts then
        return public._whatsapp_reply('Loppuajan pitää olla alun jälkeen.');
      end if;
      v_body := 'Vahvistatko siirron: ' || v_summary || ' → ' || public._whatsapp_when(v_starts, v_ends) || '?';
    end if;
    begin
      perform public._shift_validate_change(v_kind, v_shift, v_target, null, v_starts, v_ends);
    exception when others then
      return public._whatsapp_reply('Muutos ei kelpaa: ' || public._whatsapp_clean(sqlerrm));
    end;
    update public.whatsapp_pending_actions
       set consumed_at = now(), result = jsonb_build_object('replaced', true)
     where staff_id = v_staff and consumed_at is null;
    insert into public.whatsapp_pending_actions (staff_id, kind, shift_id, target_staff_id, new_starts, new_ends, summary, expires_at)
    values (v_staff, v_kind, v_shift, v_target, v_starts, v_ends, v_summary, now() + interval '15 minutes')
    returning id into v_action;
    v_buttons := jsonb_build_array(
      jsonb_build_object('id', 'y:' || v_action::text, 'title', 'Vahvista'),
      jsonb_build_object('id', 'n:' || v_action::text, 'title', 'Peruuta'));
    return public._whatsapp_reply(v_body, v_buttons, v_shift);
  end if;

  if v_op = 'confirm' then
    begin
      v_action := nullif(p_intent->>'action_id', '')::uuid;
    exception when invalid_text_representation then
      v_action := null;
    end;
    if v_action is not null and not coalesce(v_edit, false) then
      return public._whatsapp_reply('Vain ylläpitäjä voi muuttaa vuoroja.');
    end if;
    if v_action is null and coalesce(v_edit, false) then
      select p.id into v_action
        from public.whatsapp_pending_actions p
       where p.staff_id = v_staff and p.consumed_at is null and p.expires_at > now()
       order by p.created_at desc
       limit 1;
    end if;
    if v_action is null then
      select coalesce(array_agg(o.offer_id order by o.starts_at, o.offer_id), '{}') into v_offer_ids
        from public._whatsapp_open_offers(v_staff) o;
      if coalesce(cardinality(v_offer_ids), 0) = 1 then
        return public.whatsapp_inbound_act(p_message_id, jsonb_build_object('op', 'accept', 'offer_id', v_offer_ids[1]));
      end if;
      return public._whatsapp_reply('Ei ole vahvistettavaa muutosta. Avoimeen tarjoukseen kirjoita hyväksy.');
    end if;
    if not coalesce(v_edit, false) or not public._shift_db_first_enabled() then
      return public._whatsapp_reply('Vain ylläpitäjä voi muuttaa vuoroja.');
    end if;
    select * into v_pending
      from public.whatsapp_pending_actions p
     where p.id = v_action and p.staff_id = v_staff and p.consumed_at is null
     for update;
    if not found or v_pending.expires_at <= now() then
      return public._whatsapp_reply('Vahvistus ei ole enää voimassa. Pyydä muutos uudelleen.');
    end if;
    begin
      v_res := public.shift_apply_change(
        v_pending.kind, v_pending.shift_id, v_pending.target_staff_id, null,
        v_pending.new_starts, v_pending.new_ends, 'hallinta', 'whatsapp', v_staff, 'WhatsApp-vahvistus', null);
      update public.whatsapp_pending_actions
         set consumed_at = now(), result = v_res
       where id = v_pending.id;
    exception when others then
      update public.whatsapp_pending_actions
         set consumed_at = now(), result = jsonb_build_object('error', sqlstate)
       where id = v_pending.id;
      return public._whatsapp_reply('Muutos ei onnistunut: ' || public._whatsapp_clean(sqlerrm));
    end;
    v_body := case v_pending.kind
      when 'cancel' then 'Peruin vuoron: '
      when 'assign' then 'Kirjasin henkilön vuoroon: '
      when 'unassign' then 'Poistin henkilön vuorosta: '
      when 'change_time' then 'Siirsin vuoron: '
      else 'Muutos tehty: ' end || v_pending.summary || '.';
    return public._whatsapp_reply(v_body, '[]'::jsonb, v_pending.shift_id);
  end if;

  if v_op = 'abort' then
    if not coalesce(v_edit, false) then
      return public._whatsapp_reply('Ei ole peruttavaa vahvistusta.');
    end if;
    begin
      v_action := nullif(p_intent->>'action_id', '')::uuid;
    exception when invalid_text_representation then
      v_action := null;
    end;
    if v_action is null then
      select p.id into v_action
        from public.whatsapp_pending_actions p
       where p.staff_id = v_staff and p.consumed_at is null and p.expires_at > now()
       order by p.created_at desc
       limit 1;
    end if;
    update public.whatsapp_pending_actions
       set consumed_at = now(), result = jsonb_build_object('aborted', true)
     where id = v_action and staff_id = v_staff and consumed_at is null;
    if not found then
      return public._whatsapp_reply('Ei ole peruttavaa vahvistusta.');
    end if;
    return public._whatsapp_reply('Muutosta ei tehty.');
  end if;

  -- booking_274: reaktiot hiljaa, vapaamuotoiset "en pääse" / "käy" -vastaukset tarjoukseen
  v_res := public._whatsapp_freeform(p_message_id, v_staff);
  if v_res is not null then
    return v_res;
  end if;
  return public._whatsapp_reply('En ymmärtänyt. Kirjoita apua, niin kerron komennot.');
end $function$;
