-- ROLLBACK 20261025200000_soefix_engine_fixes.sql: palauttaa tuotannon määrittelyt tavu tavulta (pg_get_functiondef, luettu SELECTillä 25.10.2026),
-- poistaa uudet funktiot, triggerin, sarakkeet, taulun booking.shift_offer_skips, palauttaa wa_templates.offer.fallbackin ja
-- tervetulotekstin version 1 (versio 2 poistetaan). Moottorin kytkimiin ei kosketa. Ajetaan vain, jos migraatio on ajettu.
-- HUOM: poistaa uusien sarakkeiden arvot (deadline_extended_at, bot_acked_at, resent_message_id, bot_email_outbox_id, welcome_claimed_at,
-- welcome_wamid) ja no_rounds-kirjaukset. resend:/botcopy:-rivit jäävät tavallisiksi viesti- ja sähköpostiriveiksi.
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_sender_claim(integer)')));
  if v is null or v <> 'd6a47aa43feb0445f0bf00d549b60905' then ok := false; msg := msg || ' shift_offer_sender_claim=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_sender_complete(jsonb)')));
  if v is null or v <> 'c29ed4d23f8ede7d1ae2ef1c283f9e03' then ok := false; msg := msg || ' shift_offer_sender_complete=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email_drain(integer)')));
  if v is null or v <> '0d8df86310ad86b3a6f43429274478ed' then ok := false; msg := msg || ' shift_offer_email_drain=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email(uuid,text,text,text,text)')));
  if v is null or v <> 'f17b064c82f56f3221cc0ea3570114e1' then ok := false; msg := msg || ' shift_offer_email=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_queue_message(uuid,bigint,uuid,text,text,text)')));
  if v is null or v <> '0982a948c9e5fbe882f094c269afe31c' then ok := false; msg := msg || ' shift_offer_queue_message=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_ensure(uuid,timestamptz,boolean)')));
  if v is null or v <> 'c5d3d5a5d4048fcd4d525f5daa045893' then ok := false; msg := msg || ' shift_offer_ensure=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_staff_welcome(uuid)')));
  if v is null or v <> 'c20b901d3e21cb27814a7c2b160af97e' then ok := false; msg := msg || ' shift_staff_welcome=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.parse_shift_title(text)')));
  if v is null or v <> 'a894b3c7f749ca2cca559198ba92a42b' then ok := false; msg := msg || ' parse_shift_title=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_deadline_preview(bigint,timestamptz)')));
  if v is null or v <> '0b48a1eab2bb8df1a5393ba9978dd40e' then ok := false; msg := msg || ' shift_offer_deadline_preview=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_deadline_on_sent(bigint,timestamptz)')));
  if v is null or v <> '103efa77f733a3c5d42bac53d49a4b4e' then ok := false; msg := msg || ' shift_offer_deadline_on_sent=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email_sent_trg()')));
  if v is null or v <> '5eacac6985c8f8b2d0efc3e888994965' then ok := false; msg := msg || ' shift_offer_email_sent_trg=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_wa_ready(uuid,text,text)')));
  if v is null or v <> 'd7148175ce2c9768ca8b807571f5fb72' then ok := false; msg := msg || ' shift_offer_wa_ready=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_resend_lost(timestamptz)')));
  if v is null or v <> 'f73ac1325a2228d61fffe4ae42ca193d' then ok := false; msg := msg || ' shift_offer_resend_lost=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_bot_ack(bigint[])')));
  if v is null or v <> '7357790f5d1eae7bb1fd50bcd7fe91e1' then ok := false; msg := msg || ' shift_offer_bot_ack=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_staff_welcome_mark_sent(uuid,text)')));
  if v is null or v <> '5a5bdaa5020efbc5b7a5f54587fd41b4' then ok := false; msg := msg || ' shift_staff_welcome_mark_sent=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_staff_welcome_release(uuid)')));
  if v is null or v <> '836d7590612932497a3571875d8a5ea8' then ok := false; msg := msg || ' shift_staff_welcome_release=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_report_issues(timestamptz)')));
  if v is null or v <> 'edc1f3bda7fcd6c40e7ed9767a0c895a' then ok := false; msg := msg || ' shift_offer_report_issues=' || coalesce(v, 'puuttuu'); end if;
  if (select md5(published_text) || ':' || published_version || ':' || latest_version from booking.site_texts
       where key = 'shift_offer.whatsapp.welcome' and lang = 'fi') is distinct from '39a46e1a5db5a3c4e550535fd56928dc:2:2' then
    ok := false; msg := msg || ' tervetuloteksti ei ole soefix-versio 2 (muokattu migraation jälkeen?)';
  end if;
  if not ok then raise exception 'soefix rollback: tila ei vastaa migraation jälkeistä:%. Ei muutoksia.', msg; end if;
end $g$;

drop trigger shift_offer_email_sent on booking.email_outbox;

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
  v_open boolean; v_merged int := 0; v_emailed int := 0;
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
  -- booking_153: saman päivän viestit yhdeksi (4), sähköpostikanava (asetus), WhatsApp vain 08–21 (d)
  v_merged := booking.shift_offer_merge_same_day(now());
  v_emailed := booking.shift_offer_email_drain(50);
  v_open := booking.shift_offer_wa_open(now());
  with picked as (
    select m.id
      from public.shift_offer_messages m
      left join public.staff st on st.id = m.staff_id
     where m.status = 'queued' and m.next_attempt_at <= now() and m.wamid is null
       and m.channel is distinct from 'bot'
       and not public.shift_offer_is_bot_staff(m.staff_id)
       and (
         m.channel = 'none'
         or (v_open and coalesce(st.whatsapp_enabled, false) and public.shift_offer_phone_e164(st.phone_e164) is not null)
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
    'deadline_at', case when u.recipient_id is not null and u.kind in ('offer','reminder') then booking.shift_offer_extend_deadline(u.recipient_id, now()) else r.deadline_at end,
    'subkind', mm.subkind,
    'digest_key', mm.digest_key,
    'digest', case when mm.subkind = 'day_digest' then mm.payload end,
    'body', u.body,
    'session_open', exists (select 1 from public.whatsapp_messages wm where wm.staff_id = u.staff_id and wm.direction = 'inbound'
                             and coalesce(wm.received_at, wm.created_at) > now() - interval '23 hours 50 minutes'),
    'page_token', case when mm.subkind = 'day_digest' then booking.shift_staff_page_token(u.staff_id, true) end,
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
    left join public.shift_offer_settings s on s.role_type = o.role_type
    left join booking.shift_offer_message_meta mm on mm.message_id = u.id;
  v_messages := coalesce(v_messages, '[]'::jsonb);
  return jsonb_build_object(
    'ok', true,
    'sender_enabled', true,
    'whatsapp_enabled', e.whatsapp_enabled,
    'whatsapp_dry_run', e.whatsapp_dry_run,
    'allow_staff_ids', to_jsonb(e.whatsapp_allow_staff_ids),
    'templates', coalesce(booking.shift_offer_cfg('wa_templates'), '{}'::jsonb),
    'whatsapp_hours_open', v_open,
    'merged', v_merged,
    'emailed', v_emailed,
    'messages', v_messages);
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_sender_complete(p_result jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v public.shift_offer_messages%rowtype;
  v_action text; v_wamid text; v_err text; v_channel text; v_to text;
  v_attempts int; v_retry timestamptz; v_payload jsonb; v_status text;
begin
  if p_result is null or jsonb_typeof(p_result) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'bad_result');
  end if;
  if coalesce(p_result->>'id', '') !~ '^[0-9]+$' then
    return jsonb_build_object('ok', false, 'error', 'bad_id');
  end if;
  v_action := p_result->>'action';
  if v_action not in ('sent','retry','fail','fail_no_contact','release','already_sent','bot_channel') then
    return jsonb_build_object('ok', false, 'error', 'bad_action');
  end if;
  select * into v from public.shift_offer_messages where id = (p_result->>'id')::bigint for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'missing'); end if;
  if public.shift_offer_is_bot_staff(v.staff_id) and v.wamid is null then
    update public.shift_offer_messages set
      status = 'bot_channel', channel = 'bot', to_address = null,
      locked_at = null, last_error = null, last_payload = null
     where id = v.id and wamid is null;
    return jsonb_build_object('ok', true, 'status', 'bot_channel');
  end if;
  v_wamid := nullif(p_result->>'wamid', '');
  if v_action = 'already_sent' or (v.wamid is not null and v_action = 'sent') then
    return jsonb_build_object('ok', true, 'duplicate', v.wamid is not null, 'status', v.status, 'wamid', v.wamid);
  end if;
  if v.status is distinct from 'sending' or v.wamid is not null then
    return jsonb_build_object('ok', false, 'error', 'not_locked', 'status', v.status, 'wamid', v.wamid);
  end if;
  v_err := left(nullif(p_result->>'error', ''), 500);
  v_channel := case when p_result->>'channel' in ('whatsapp','email','none') then p_result->>'channel' else null end;
  v_to := nullif(p_result->>'to', '');
  v_payload := p_result->'payload';
  if jsonb_typeof(v_payload) = 'null' then v_payload := null; end if;
  v_payload := public.shift_offer_mask_payload(v_payload);
  if coalesce(p_result->>'attempts', '') ~ '^[0-9]+$' then
    v_attempts := (p_result->>'attempts')::int;
  else
    v_attempts := v.attempts;
  end if;
  if coalesce(p_result->>'retry_at', '') <> '' then
    v_retry := (p_result->>'retry_at')::timestamptz;
  end if;
  if v_action = 'sent' then
    if v_wamid is null then return jsonb_build_object('ok', false, 'error', 'no_wamid'); end if;
    update public.shift_offer_messages set
      status = 'sent', wamid = v_wamid, sent_at = now(), provider_status = 'sent',
      channel = coalesce(v_channel, 'whatsapp'), to_address = coalesce(v_to, to_address),
      attempts = v_attempts, last_error = null, last_payload = v_payload, locked_at = null
     where id = v.id and status = 'sending' and wamid is null;
    if not found then return jsonb_build_object('ok', false, 'error', 'not_locked'); end if;
    v_status := 'sent';
  elsif v_action = 'fail_no_contact' then
    update public.shift_offer_messages set
      status = 'failed_no_contact', channel = 'none', to_address = null,
      last_error = coalesce(v_err, 'no_phone'), locked_at = null, last_payload = null
     where id = v.id and status = 'sending' and wamid is null;
    v_status := 'failed_no_contact';
  elsif v_action = 'fail' then
    update public.shift_offer_messages set
      status = 'failed', provider_status = 'failed',
      channel = coalesce(v_channel, channel), to_address = coalesce(v_to, to_address),
      attempts = v_attempts, last_error = coalesce(v_err, 'failed'), last_payload = v_payload, locked_at = null
     where id = v.id and status = 'sending' and wamid is null;
    v_status := 'failed';
  elsif v_action = 'retry' then
    update public.shift_offer_messages set
      status = 'queued', attempts = v_attempts, last_error = v_err,
      next_attempt_at = coalesce(v_retry, now() + interval '1 minute'),
      channel = coalesce(v_channel, channel), to_address = coalesce(v_to, to_address),
      last_payload = v_payload, locked_at = null
     where id = v.id and status = 'sending' and wamid is null;
    v_status := 'queued';
  else
    update public.shift_offer_messages set
      status = 'queued', last_error = v_err,
      next_attempt_at = coalesce(v_retry, now() + interval '15 minutes'),
      channel = coalesce(v_channel, channel), to_address = case when v_channel = 'none' then null else coalesce(v_to, to_address) end,
      last_payload = v_payload, locked_at = null
     where id = v.id and status = 'sending' and wamid is null;
    v_status := 'queued';
  end if;
  return jsonb_build_object('ok', true, 'status', v_status, 'wamid', case when v_action = 'sent' then v_wamid else null end);
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_offer_email_drain(p_limit integer DEFAULT 50)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    -- booking_155: "jo mennyt" -ilmoituksesta lähti jo sähköpostikopio (trigger), joten WhatsAppin sähköpostivarapolku ei lähetä toista
    if m.subkind = 'already_taken' and m.offer_id is not null and exists (
         select 1 from booking.email_outbox e where e.dedupe_key = 'b153:at-mail:' || m.offer_id::text || ':' || m.staff_id::text) then
      update public.shift_offer_messages set status = 'skipped', last_error = 'email_copy_sent', locked_at = null where id = m.id;
      v_n := v_n + 1;
      continue;
    end if;
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
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_offer_email(p_staff uuid, p_subject text, p_text text, p_dedupe text, p_link text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare st public.staff%rowtype; v_mode text; v_id bigint;
begin
  if not booking.shift_offer_cfg_bool('email_enabled', false) then return null; end if;
  select * into st from public.staff s where s.id = p_staff;
  if not found or not booking._valid_email(btrim(coalesce(st.email, ''))) then return null; end if;
  select mode into v_mode from booking.integration_config where key = 'resend';
  insert into booking.email_outbox (kind, locale, dedupe_key, status, payload)
  values ('staff_shift_notice', 'fi', 'b153:' || p_dedupe,
          case when coalesce(v_mode, 'off') = 'off' then 'skipped' else 'pending' end,
          jsonb_build_object('to_email', btrim(st.email), 'to_name', st.name, 'subject', left(p_subject, 200), 'text', p_text, 'link_url', p_link))
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_queue_message(p_offer uuid, p_recipient bigint, p_staff uuid, p_kind text, p_body text, p_dedupe text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id bigint; v_channel text; v_to text; v_phone text; st public.staff%rowtype;
begin
  if p_body is null or p_dedupe is null then return null; end if;
  select * into st from public.staff s where s.id = p_staff;
  if not found then
    v_channel := 'none'; v_to := null;
  elsif public.shift_offer_is_bot_staff(p_staff) then
    insert into public.shift_offer_messages (offer_id, recipient_id, staff_id, kind, channel, to_address, body, dedupe_key, status)
    values (p_offer, p_recipient, p_staff, p_kind, 'bot', null, p_body, p_dedupe, 'bot_channel')
    on conflict (dedupe_key) do nothing
    returning id into v_id;
    return v_id;
  else
    v_phone := public.shift_offer_phone_e164(st.phone_e164);
    if st.whatsapp_enabled and v_phone is not null then
      v_channel := 'whatsapp'; v_to := v_phone;
    elsif nullif(btrim(st.email), '') is not null then
      v_channel := 'email'; v_to := btrim(st.email);
    else
      v_channel := 'none'; v_to := null;
    end if;
  end if;
  insert into public.shift_offer_messages (offer_id, recipient_id, staff_id, kind, channel, to_address, body, dedupe_key)
  values (p_offer, p_recipient, p_staff, p_kind, v_channel, v_to, p_body, p_dedupe)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  return v_id;
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

CREATE OR REPLACE FUNCTION booking.shift_staff_welcome(p_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m public.whatsapp_messages%rowtype; st public.staff%rowtype; c booking.shift_staff_whatsapp_consent%rowtype;
        v_first timestamptz; v_text text; v_link text; v_name text;
begin
  select * into m from public.whatsapp_messages x where x.id = p_message_id and x.direction = 'inbound';
  if not found or m.staff_id is null then return jsonb_build_object('send', false, 'reason', 'unknown'); end if;
  select * into st from public.staff s where s.id = m.staff_id and s.active;
  if not found then return jsonb_build_object('send', false, 'reason', 'unknown'); end if;
  select min(coalesce(x.received_at, x.created_at)) into v_first from public.whatsapp_messages x where x.staff_id = st.id and x.direction = 'inbound';
  insert into booking.shift_staff_whatsapp_consent (staff_id, first_inbound_at, first_message_id)
  values (st.id, coalesce(v_first, m.received_at, now()), case when coalesce(m.received_at, m.created_at) <= coalesce(v_first, m.received_at) then m.id end)
  on conflict (staff_id) do nothing;
  select * into c from booking.shift_staff_whatsapp_consent x where x.staff_id = st.id for update;
  if not booking.shift_offer_cfg_bool('welcome_enabled', false) then return jsonb_build_object('send', false, 'reason', 'disabled'); end if;
  if public.shift_offer_is_bot_staff(st.id) then return jsonb_build_object('send', false, 'reason', 'bot_channel'); end if;
  if c.welcome_sent_at is not null then return jsonb_build_object('send', false, 'reason', 'already_sent'); end if;
  if c.first_message_id is distinct from m.id then return jsonb_build_object('send', false, 'reason', 'not_first'); end if;
  if coalesce(m.received_at, m.created_at) < now() - interval '24 hours' then return jsonb_build_object('send', false, 'reason', 'window_closed'); end if;
  if m.phone_e164 is null then return jsonb_build_object('send', false, 'reason', 'no_phone'); end if;
  v_link := booking.shift_staff_page_url(st.id);
  if v_link is null then return jsonb_build_object('send', false, 'reason', 'no_link'); end if;
  v_name := split_part(btrim(st.name), ' ', 1);
  select t.published_text into v_text from booking.site_texts t
   where t.key = 'shift_offer.whatsapp.welcome' and t.lang = 'fi' and nullif(btrim(t.published_text), '') is not null;
  v_text := coalesce(v_text, E'Hei {{var:name}}. Tässä Tapio, Saunotuksen työvuorojen apuri. Kun sinulle on vapaa vuoro, saat viestin, johon vastaat painikkeella tai linkillä. Omat avoimet ja vastatut vuorosi näet täältä: {{var:link}}\n\n–Tapio');
  v_text := replace(replace(v_text, '{{var:name}}', coalesce(v_name, '')), '{{var:link}}', v_link);
  update booking.shift_staff_whatsapp_consent set welcome_sent_at = now() where staff_id = st.id;
  return jsonb_build_object('send', true, 'body', v_text, 'to', m.phone_e164, 'staff_id', st.id);
end $function$;

CREATE OR REPLACE FUNCTION public.parse_shift_title(p_title text, OUT staffing_status text, OUT staff_ids uuid[])
 RETURNS record
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  t text := btrim(coalesce(p_title, ''));
  parts text[];
  part text;
  sid uuid;
  ids uuid[] := '{}';
begin
  if t = '' or t = '-' then
    staffing_status := 'open'; staff_ids := '{}'; return;
  elsif t = '?' then
    staffing_status := 'uncertain'; staff_ids := '{}'; return;
  end if;

  select id into sid from public.staff where calendar_name = t;
  if found then
    staffing_status := 'assigned'; staff_ids := array[sid]; return;
  end if;

  if position('&' in t) > 0 then
    parts := string_to_array(t, '&');
    foreach part in array parts loop
      sid := null;
      select id into sid from public.staff where calendar_name = btrim(part);
      if sid is null then
        staffing_status := 'unresolved'; staff_ids := '{}'; return;
      end if;
      if not sid = any(ids) then ids := ids || sid; end if;
    end loop;
    staffing_status := 'assigned'; staff_ids := ids; return;
  end if;

  staffing_status := 'unresolved'; staff_ids := '{}';
end $function$;

drop function booking.shift_offer_report_issues(timestamptz);
drop function booking.shift_staff_welcome_release(uuid);
drop function booking.shift_staff_welcome_mark_sent(uuid,text);
drop function public.shift_offer_bot_ack(bigint[]);
drop function booking.shift_offer_resend_lost(timestamptz);
drop function booking.shift_offer_wa_ready(uuid,text,text);
drop function booking.shift_offer_email_sent_trg();
drop function booking.shift_offer_deadline_on_sent(bigint,timestamptz);
drop function booking.shift_offer_deadline_preview(bigint,timestamptz);

drop table booking.shift_offer_skips;
drop index public.shift_offer_messages_lost_idx;
alter table public.shift_offer_messages
  drop column deadline_extended_at, drop column bot_acked_at, drop column resent_message_id, drop column bot_email_outbox_id;
alter table booking.shift_staff_whatsapp_consent drop column welcome_claimed_at, drop column welcome_wamid;

update booking.settings set value = jsonb_set(value, '{offer,fallback}', '"vuorotarjous"')
 where key = 'shift_offer.wa_templates' and not (value -> 'offer' ? 'fallback');

do $t$
declare t booking.site_texts;
begin
  select * into t from booking.site_texts where key = 'shift_offer.whatsapp.welcome' and lang = 'fi' for update;
  delete from booking.site_text_versions where text_id = t.id and version = 2;
  update booking.site_text_versions set status = 'published' where text_id = t.id and version = 1;
  update booking.site_texts s set max_len = 280, published_text = v.text, published_version = 1, published_at = v.published_at
    from booking.site_text_versions v where s.id = t.id and v.text_id = t.id and v.version = 1;
  update booking.site_texts set needs_translation = false where key = t.key and lang = 'en';
  perform booking._text_refresh(t.id);
end $t$;

do $p$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_sender_claim(integer)')));
  if v is null or v <> 'ddec4116885b70df02f4a1157440c2b3' then ok := false; msg := msg || ' shift_offer_sender_claim=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_sender_complete(jsonb)')));
  if v is null or v <> 'ce3424851a62060686be6f72926c4fb6' then ok := false; msg := msg || ' shift_offer_sender_complete=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email_drain(integer)')));
  if v is null or v <> '2aeb4adbd0e247f1880d1451d7c09501' then ok := false; msg := msg || ' shift_offer_email_drain=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email(uuid,text,text,text,text)')));
  if v is null or v <> '04e72c0cc48dde09eedab67aeaae8639' then ok := false; msg := msg || ' shift_offer_email=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_queue_message(uuid,bigint,uuid,text,text,text)')));
  if v is null or v <> '8705686f1c19fb67b5c15a702719de9d' then ok := false; msg := msg || ' shift_offer_queue_message=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_ensure(uuid,timestamptz,boolean)')));
  if v is null or v <> 'c11363b4820dded38d99e2424af9a5e5' then ok := false; msg := msg || ' shift_offer_ensure=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_staff_welcome(uuid)')));
  if v is null or v <> 'e615d22aea9ff2a7e822f53b2ffd179d' then ok := false; msg := msg || ' shift_staff_welcome=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.parse_shift_title(text)')));
  if v is null or v <> 'c74e01c1ac62eaca941cd0fabfaa33c0' then ok := false; msg := msg || ' parse_shift_title=' || coalesce(v, 'puuttuu'); end if;
  if to_regprocedure('booking.shift_offer_deadline_preview(bigint,timestamptz)') is not null then ok := false; msg := msg || ' shift_offer_deadline_preview jäi'; end if;
  if to_regprocedure('booking.shift_offer_deadline_on_sent(bigint,timestamptz)') is not null then ok := false; msg := msg || ' shift_offer_deadline_on_sent jäi'; end if;
  if to_regprocedure('booking.shift_offer_email_sent_trg()') is not null then ok := false; msg := msg || ' shift_offer_email_sent_trg jäi'; end if;
  if to_regprocedure('booking.shift_offer_wa_ready(uuid,text,text)') is not null then ok := false; msg := msg || ' shift_offer_wa_ready jäi'; end if;
  if to_regprocedure('booking.shift_offer_resend_lost(timestamptz)') is not null then ok := false; msg := msg || ' shift_offer_resend_lost jäi'; end if;
  if to_regprocedure('public.shift_offer_bot_ack(bigint[])') is not null then ok := false; msg := msg || ' shift_offer_bot_ack jäi'; end if;
  if to_regprocedure('booking.shift_staff_welcome_mark_sent(uuid,text)') is not null then ok := false; msg := msg || ' shift_staff_welcome_mark_sent jäi'; end if;
  if to_regprocedure('booking.shift_staff_welcome_release(uuid)') is not null then ok := false; msg := msg || ' shift_staff_welcome_release jäi'; end if;
  if to_regprocedure('booking.shift_offer_report_issues(timestamptz)') is not null then ok := false; msg := msg || ' shift_offer_report_issues jäi'; end if;
  if (select value from booking.settings where key = 'shift_offer.wa_templates') is distinct from '{"offer": {"name": "tyovuoro_kysely", "approved": false, "fallback": "vuorotarjous"}, "day_digest": {"name": "tyovuoro_paivan_kooste", "approved": false}, "already_taken": {"name": "tyovuoro_jo_mennyt", "approved": false}, "round_reminder": {"name": "tyovuoro_muistutus", "approved": false}}'::jsonb then ok := false; msg := msg || ' wa_templates'; end if;
  if (select md5(published_text) || ':' || published_version || ':' || latest_version || ':' || max_len from booking.site_texts
       where key = 'shift_offer.whatsapp.welcome' and lang = 'fi') is distinct from '51ae254f911b802cb2d969640d73201b:1:1:280' then ok := false; msg := msg || ' tervetuloteksti'; end if;
  if not ok then raise exception 'soefix rollback: jälkitarkistus epäonnistui:%', msg; end if;
end $p$;
