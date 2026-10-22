-- PALUU: purkaa 20261022013104_shift_offer_whatsapp.sql.
-- Palauttaa lähettäjän stubiksi (skipped, ei verkkoa) ja kanavavalinnan staff.whatsapp_enabled-lippuun.
-- Aja ennen 20261022003917_shift_offer_engine_DOWN.sql jos koko moottori puretaan.

update public.shift_offer_messages set status = 'sent' where status in ('delivered', 'read');
update public.shift_offer_messages set status = 'failed' where status = 'failed_no_contact';

drop function if exists public.shift_offer_whatsapp_apply_status(text, text, text, timestamptz);
drop function if exists public.shift_offer_sender_complete(jsonb);
drop function if exists public.shift_offer_sender_claim(int);
drop function if exists public.shift_offer_phone_e164(text);

create or replace function public.shift_offer_queue_message(
  p_offer uuid, p_recipient bigint, p_staff uuid, p_kind text, p_body text, p_dedupe text)
returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_id bigint; v_channel text; v_to text; st public.staff%rowtype;
begin
  if p_body is null or p_dedupe is null then return null; end if;
  select * into st from public.staff s where s.id = p_staff;
  if st.whatsapp_enabled and nullif(btrim(st.phone_e164), '') is not null then
    v_channel := 'whatsapp'; v_to := btrim(st.phone_e164);
  elsif nullif(btrim(st.email), '') is not null then
    v_channel := 'email'; v_to := btrim(st.email);
  else
    v_channel := 'none'; v_to := null;
  end if;
  insert into public.shift_offer_messages (offer_id, recipient_id, staff_id, kind, channel, to_address, body, dedupe_key)
  values (p_offer, p_recipient, p_staff, p_kind, v_channel, v_to, p_body, p_dedupe)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.shift_offer_sender_drain(p_limit int default 50)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_on boolean; v_n int;
begin
  select sender_enabled into v_on from public.shift_offer_engine_settings where id;
  if not coalesce(v_on, false) then
    return jsonb_build_object('ok', true, 'sender_enabled', false, 'sent', 0, 'skipped', 0);
  end if;
  with u as (
    update public.shift_offer_messages set status = 'skipped',
           last_error = 'stub', attempts = attempts + 1
     where id in (
       select m.id from public.shift_offer_messages m where m.status = 'queued' and m.next_attempt_at <= now()
        order by m.id limit greatest(1, least(coalesce(p_limit, 50), 200))
     )
    returning 1)
  select count(*) into v_n from u;
  return jsonb_build_object('ok', true, 'sender_enabled', true, 'sent', 0, 'skipped', v_n, 'transport', 'stub');
end $$;

alter table public.shift_offer_messages drop constraint if exists shift_offer_messages_provider_status_check;
drop index if exists shift_offer_messages_wamid_uq;
alter table public.shift_offer_messages drop column if exists last_payload;
alter table public.shift_offer_messages drop column if exists provider_status;
alter table public.shift_offer_messages drop column if exists read_at;
alter table public.shift_offer_messages drop column if exists delivered_at;
alter table public.shift_offer_messages drop column if exists locked_at;
alter table public.shift_offer_messages drop column if exists wamid;

alter table public.shift_offer_messages drop constraint if exists shift_offer_messages_status_check;
alter table public.shift_offer_messages add constraint shift_offer_messages_status_check
  check (status in ('queued','sending','sent','skipped','failed'));

alter table public.shift_offer_engine_settings drop column if exists whatsapp_allow_staff_ids;
alter table public.shift_offer_engine_settings drop column if exists whatsapp_dry_run;
alter table public.shift_offer_engine_settings drop column if exists whatsapp_enabled;
