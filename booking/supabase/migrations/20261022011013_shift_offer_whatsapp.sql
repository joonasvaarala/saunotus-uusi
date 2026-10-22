-- WhatsApp-lähettäjä vuorotarjousjonolle. EI ajettu tuotantoon. EI deployta. EI lähetä viestejä.
-- Tuotannon shift_offer_engine on versio 20261022003917 (repon aiempi nimi 20261022021000). Tätä tiedostoa ei ajeta sen päälle käsin tässä haarassa.
-- Kytkimet oletuksena kiinni: sender_enabled false, whatsapp_enabled false, allowlist tyhjä, whatsapp_dry_run true.
-- Edge-funktio shift-offer-engine soittaa Metalle. Tämä migraatio ei käytä pg_netiä eikä http_postia.

alter table public.shift_offer_engine_settings
  add column whatsapp_enabled boolean not null default false,
  add column whatsapp_dry_run boolean not null default true,
  add column whatsapp_allow_staff_ids uuid[] not null default '{}';

comment on column public.shift_offer_engine_settings.sender_enabled is
  'Yleinen lähettäjäkytkin. false: jonoa ei käsitellä eikä Metalle soiteta. Oletus false.';
comment on column public.shift_offer_engine_settings.whatsapp_enabled is
  'WhatsApp-kanavan kytkin. false: Metalle ei soiteta, vaikka yleinen lähettäjä olisi päällä. Oletus false.';
comment on column public.shift_offer_engine_settings.whatsapp_dry_run is
  'true: edge-funktio lokittaa tarkan API-rungon eikä kutsu Metan rajapintaa. Oletus true.';
comment on column public.shift_offer_engine_settings.whatsapp_allow_staff_ids is
  'Pilotti. Vain nämä public.staff.id-arvot voivat saada oikean WhatsApp-viestin, kun kanava on päällä ja kuivaharjoitus on pois. Oletus tyhjä: kukaan ei saa viestiä.';

alter table public.shift_offer_messages
  add column wamid text,
  add column locked_at timestamptz,
  add column delivered_at timestamptz,
  add column read_at timestamptz,
  add column provider_status text,
  add column last_payload jsonb;

alter table public.shift_offer_messages drop constraint shift_offer_messages_status_check;
alter table public.shift_offer_messages add constraint shift_offer_messages_status_check
  check (status in ('queued','sending','sent','delivered','read','skipped','failed','failed_no_contact'));
alter table public.shift_offer_messages add constraint shift_offer_messages_provider_status_check
  check (provider_status is null or provider_status in ('sent','delivered','read','failed'));
create unique index shift_offer_messages_wamid_uq on public.shift_offer_messages (wamid) where wamid is not null;

comment on column public.shift_offer_messages.wamid is
  'Metan viestitunnus. Kun tämä on asetettu, riviä ei lähetetä uudelleen.';
comment on column public.shift_offer_messages.status is
  'queued/sending/sent/delivered/read/skipped/failed/failed_no_contact. failed_no_contact jää tauluun näkyviin: puuttuvaa puhelinnumeroa ei piiloteta eikä riviä poisteta.';
comment on column public.shift_offer_messages.last_payload is
  'Viimeisin Metalle tarkoitettu JSON-runko (kuivaharjoitus tai lähetys). Ei sisällä Authorization-otsaketta.';

-- Sama sääntö kuin edge-funktion normalizeFinnishPhone: 040… → +35840…, vain matkapuhelin (4… tai 50…).
create or replace function public.shift_offer_phone_e164(p_raw text)
returns text
language plpgsql immutable set search_path = '' as $$
declare
  s text; digits text; national text;
begin
  s := regexp_replace(btrim(coalesce(p_raw, '')), '[[:space:]\-().]', '', 'g');
  if s = '' then return null; end if;
  if left(s, 2) = '00' then s := '+' || substr(s, 3); end if;
  if left(s, 1) = '+' then
    digits := substr(s, 2);
  elsif left(s, 1) = '0' then
    digits := '358' || substr(s, 2);
  elsif left(s, 3) = '358' then
    digits := s;
  else
    return null;
  end if;
  if digits !~ '^[0-9]+$' or left(digits, 3) <> '358' then return null; end if;
  national := substr(digits, 4);
  if length(national) < 6 or length(national) > 12 then return null; end if;
  if left(national, 1) <> '4' and left(national, 2) <> '50' then return null; end if;
  return '+' || digits;
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
    if v_phone is not null then
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

-- Ei lähetä eikä merkitse rivejä skipped-tilaan. Edge-funktio tekee lähetyksen.
create or replace function public.shift_offer_sender_drain(p_limit int default 50)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_on boolean;
begin
  select sender_enabled into v_on from public.shift_offer_engine_settings where id;
  if not coalesce(v_on, false) then
    return jsonb_build_object('ok', true, 'sender_enabled', false, 'sent', 0, 'skipped', 0);
  end if;
  return jsonb_build_object('ok', true, 'sender_enabled', true, 'sent', 0, 'skipped', 0, 'transport', 'edge', 'limit', p_limit);
end $$;

-- Lukitsee erääntyneet rivit (status sending). Riviä, jolla on wamid, ei varata.
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
     set status = 'queued', locked_at = null
   where status = 'sending' and wamid is null and locked_at is not null
     and locked_at < now() - interval '10 minutes';
  v_limit := greatest(1, least(coalesce(p_limit, 20), 50));
  with picked as (
    select m.id
      from public.shift_offer_messages m
      left join public.staff st on st.id = m.staff_id
     where m.status = 'queued' and m.next_attempt_at <= now() and m.wamid is null
       and (
         m.channel in ('whatsapp', 'none')
         or public.shift_offer_phone_e164(st.phone_e164) is not null
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

-- Kirjaa yhden varatun rivin lopputulos. wamidia ei korvata, eikä sent onnistu ilman lukkoa.
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

-- Webhookin tila. Sama järjestys kuin edge-funktion nextOutboxStatus.
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
  if v.status in ('read', 'failed_no_contact', 'failed') then
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

revoke all on function public.shift_offer_phone_e164(text), public.shift_offer_sender_claim(int),
  public.shift_offer_sender_complete(jsonb), public.shift_offer_whatsapp_apply_status(text, text, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.shift_offer_phone_e164(text), public.shift_offer_sender_claim(int),
  public.shift_offer_sender_complete(jsonb), public.shift_offer_whatsapp_apply_status(text, text, text, timestamptz)
  to service_role;
