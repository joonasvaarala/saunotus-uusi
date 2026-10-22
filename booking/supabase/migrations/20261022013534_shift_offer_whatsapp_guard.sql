-- WhatsApp-lähettäjän tarkennukset. EI ajettu tuotantoon. EI deployta. EI lähetä viestejä.
-- Tuotannon WhatsApp-migraatio on versio 20261022013104 (repon aiempi nimi 20261022011013, tavut ennallaan).
-- Tätä tiedostoa ei ajeta sen päälle käsin tässä haarassa.
-- 1) sending ilman wamidia ei palaa jonoon 10 min jälkeen, vaan tilaan unknown.
-- 2) last_payload peittää puhelinnumeron ja vastauspoletin.
-- 3) WhatsApp-kanava vain jos staff.whatsapp_enabled ja numero normalisoituu. Allowlist on lisäksi.

alter table public.shift_offer_messages drop constraint shift_offer_messages_status_check;
alter table public.shift_offer_messages add constraint shift_offer_messages_status_check
  check (status in ('queued','sending','sent','delivered','read','skipped','failed','failed_no_contact','unknown'));

comment on column public.shift_offer_messages.status is
  'queued/sending/sent/delivered/read/skipped/failed/failed_no_contact/unknown. unknown = sending jäi ilman wamidia ja vaatii käsintarkistuksen. Riviä ei lähetetä uudelleen automaattisesti.';
comment on column public.shift_offer_messages.last_payload is
  'Viimeisin Metalle tarkoitettu JSON-runko. Puhelinnumero ja vastauspoletti on peitetty. Ei sisällä Authorization-otsaketta.';

-- +358401234567 → +358*******67. Tähtiä sisältävä arvo jätetään.
create or replace function public.shift_offer_mask_phone(p_phone text)
returns text
language sql immutable set search_path = '' as $$
  select case
    when p_phone is null or btrim(p_phone) = '' then p_phone
    when position('*' in p_phone) > 0 then p_phone
    when char_length(p_phone) < 6 then '***'
    else left(p_phone, 4) || repeat('*', char_length(p_phone) - 6) || right(p_phone, 2)
  end
$$;

create or replace function public.shift_offer_mask_payload(p_payload jsonb)
returns jsonb
language plpgsql immutable set search_path = '' as $$
declare
  v jsonb; comps jsonb; i int; c jsonb; params jsonb; j int; param jsonb;
begin
  if p_payload is null or jsonb_typeof(p_payload) is distinct from 'object' then
    return p_payload;
  end if;
  v := p_payload;
  if p_payload->>'to' is not null then
    v := jsonb_set(v, '{to}', to_jsonb(public.shift_offer_mask_phone(p_payload->>'to')), true);
  end if;
  comps := v #> '{template,components}';
  if jsonb_typeof(comps) is distinct from 'array' then
    return v;
  end if;
  for i in 0 .. jsonb_array_length(comps) - 1 loop
    c := comps -> i;
    if c->>'type' = 'button' and jsonb_typeof(c->'parameters') = 'array' then
      params := c->'parameters';
      for j in 0 .. jsonb_array_length(params) - 1 loop
        param := params -> j;
        if param->>'type' = 'text' then
          param := jsonb_set(param, '{text}', to_jsonb('***'::text), true);
          params := jsonb_set(params, array[j::text], param, true);
        end if;
      end loop;
      c := jsonb_set(c, '{parameters}', params, true);
      comps := jsonb_set(comps, array[i::text], c, true);
    end if;
  end loop;
  return jsonb_set(v, '{template,components}', comps, true);
end $$;

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

-- Lukitsee erääntyneet rivit. Vanhaa sending-lukkoa ilman wamidia ei palauteta jonoon.
create or replace function public.shift_offer_sender_claim(p_limit int default 20)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  e public.shift_offer_engine_settings%rowtype;
  v_limit int;
  v_messages jsonb;
begin
  select * into e from public.shift_offer_engine_settings where id;
  if not coalesce(e.sender_enabled, false) then
    return jsonb_build_object('ok', true, 'sender_enabled', false, 'messages', '[]'::jsonb);
  end if;
  update public.shift_offer_messages
     set status = 'unknown',
         locked_at = null,
         last_error = 'unknown_delivery'
   where status = 'sending' and wamid is null and locked_at is not null
     and locked_at < now() - interval '10 minutes';
  v_limit := greatest(1, least(coalesce(p_limit, 20), 50));
  with picked as (
    select m.id
      from public.shift_offer_messages m
      left join public.staff st on st.id = m.staff_id
     where m.status = 'queued' and m.next_attempt_at <= now() and m.wamid is null
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

-- Kirjaa yhden varatun rivin lopputulos. wamidia ei korvata. last_payload peitetään.
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
  if v_action not in ('sent','retry','fail','fail_no_contact','release','already_sent') then
    return jsonb_build_object('ok', false, 'error', 'bad_action');
  end if;
  select * into v from public.shift_offer_messages where id = (p_result->>'id')::bigint for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'missing'); end if;
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

-- Webhookin tila. unknown ei liiku, sama järjestys kuin nextOutboxStatus.
create or replace function public.shift_offer_whatsapp_apply_status(
  p_wamid text, p_status text, p_error text, p_at timestamptz)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v public.shift_offer_messages%rowtype;
  v_next text;
begin
  if p_wamid is null or btrim(p_wamid) = '' then
    return jsonb_build_object('ok', true, 'matched', false);
  end if;
  if p_status not in ('sent','delivered','read','failed') then
    return jsonb_build_object('ok', true, 'matched', false, 'ignored', true);
  end if;
  select * into v from public.shift_offer_messages where wamid = p_wamid for update;
  if not found then return jsonb_build_object('ok', true, 'matched', false); end if;
  if v.status in ('read', 'failed_no_contact', 'failed', 'unknown') then
    return jsonb_build_object('ok', true, 'matched', true, 'status', v.status, 'unchanged', true);
  end if;
  if p_status = 'failed' then
    v_next := 'failed';
  elsif p_status = 'read' then
    v_next := 'read';
  elsif p_status = 'delivered' and v.status in ('queued','sending','sent') then
    v_next := 'delivered';
  elsif p_status = 'sent' and v.status in ('queued','sending') then
    v_next := 'sent';
  else
    return jsonb_build_object('ok', true, 'matched', true, 'status', v.status, 'unchanged', true);
  end if;
  update public.shift_offer_messages set
    status = v_next,
    provider_status = p_status,
    last_error = case when p_status = 'failed' then left(coalesce(p_error, 'failed'), 500) else last_error end,
    delivered_at = case when v_next = 'delivered' then coalesce(p_at, now()) else delivered_at end,
    read_at = case when v_next = 'read' then coalesce(p_at, now()) else read_at end,
    sent_at = coalesce(sent_at, case when v_next = 'sent' then coalesce(p_at, now()) else null end),
    locked_at = null
   where id = v.id;
  return jsonb_build_object('ok', true, 'matched', true, 'status', v_next);
end $$;

revoke all on function public.shift_offer_mask_phone(text), public.shift_offer_mask_payload(jsonb)
  from public, anon, authenticated;
grant execute on function public.shift_offer_mask_phone(text), public.shift_offer_mask_payload(jsonb)
  to service_role;
