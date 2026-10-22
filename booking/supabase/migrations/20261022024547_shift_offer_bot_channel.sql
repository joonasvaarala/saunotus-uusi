-- Joonas ja Otto saavat vuoroviestit botilta, eivät WhatsAppista.
-- EI ajettu tuotantoon. EI deployta. EI lähetä viestejä.
-- Henkilö tunnistetaan tuotannon id:stä, nimestä Joonas/Otto ja bot_channel-lipusta.
-- Lippu pakottaa staff.whatsapp_enabled = false. Lähettäjä ei poimi eikä lähetä näitä rivejä.

alter table public.staff add column if not exists bot_channel boolean not null default false;
alter table public.staff drop constraint if exists staff_bot_channel_no_whatsapp;
alter table public.staff add constraint staff_bot_channel_no_whatsapp
  check (not bot_channel or not whatsapp_enabled);
comment on column public.staff.bot_channel is
  'true: vuoroviestit jäävät bot-kanavalle (status bot_channel). WhatsAppia ei lähetetä. Joonas ja Otto ovat aina tässä.';

create or replace function public.shift_offer_is_bot_staff(p_staff uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.staff s
     where s.id = p_staff
       and (
         s.bot_channel
         or s.id in (
           '5ab2ba62-97b2-4712-b500-a47a898036a5'::uuid,
           '2975633f-c53f-48d6-8a38-41cae0be5a83'::uuid)
         or lower(btrim(s.name)) in ('joonas', 'otto')
       )
  )
$$;

create or replace function public.shift_offer_staff_bot_guard()
returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.id in (
       '5ab2ba62-97b2-4712-b500-a47a898036a5'::uuid,
       '2975633f-c53f-48d6-8a38-41cae0be5a83'::uuid)
     or lower(btrim(coalesce(new.name, ''))) in ('joonas', 'otto') then
    new.bot_channel := true;
  end if;
  if new.bot_channel then
    new.whatsapp_enabled := false;
  end if;
  return new;
end $$;

drop trigger if exists shift_offer_staff_bot_guard_trg on public.staff;
create trigger shift_offer_staff_bot_guard_trg
  before insert or update of name, whatsapp_enabled, bot_channel
  on public.staff
  for each row execute function public.shift_offer_staff_bot_guard();

update public.staff
   set bot_channel = true,
       whatsapp_enabled = false
 where id in (
         '5ab2ba62-97b2-4712-b500-a47a898036a5'::uuid,
         '2975633f-c53f-48d6-8a38-41cae0be5a83'::uuid)
    or lower(btrim(name)) in ('joonas', 'otto');

alter table public.shift_offer_messages drop constraint if exists shift_offer_messages_channel_check;
alter table public.shift_offer_messages add constraint shift_offer_messages_channel_check
  check (channel in ('whatsapp', 'email', 'none', 'bot'));
alter table public.shift_offer_messages drop constraint shift_offer_messages_status_check;
alter table public.shift_offer_messages add constraint shift_offer_messages_status_check
  check (status in ('queued','sending','sent','delivered','read','skipped','failed','failed_no_contact','unknown','bot_channel'));
comment on column public.shift_offer_messages.status is
  'queued/sending/sent/delivered/read/skipped/failed/failed_no_contact/unknown/bot_channel. bot_channel = Joonas tai Otto, viesti jää botille eikä lähde WhatsAppiin. unknown = sending jäi ilman wamidia.';

create or replace function public.shift_offer_queue_message(
  p_offer uuid, p_recipient bigint, p_staff uuid, p_kind text, p_body text, p_dedupe text)
returns bigint
language plpgsql security definer set search_path = '' as $$
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
end $$;

create or replace function public.shift_offer_sender_claim(p_limit int default 20)
returns jsonb
language plpgsql security definer set search_path = '' as $$
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
end $$;

create or replace function public.shift_offer_sender_complete(p_result jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
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
end $$;

revoke all on function public.shift_offer_is_bot_staff(uuid), public.shift_offer_staff_bot_guard()
  from public, anon, authenticated;
grant execute on function public.shift_offer_is_bot_staff(uuid) to service_role;
