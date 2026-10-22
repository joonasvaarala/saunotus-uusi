-- PALUU: purkaa 20261022180000_whatsapp_inbound.sql.
-- Ei pudota public.whatsapp_messages-taulua: se on tuotannossa jo ennen tätä migraatiota.
-- Uudet sarakkeet, itsepalvelutaulut, funktiot ja whatsapp_inbound_enabled poistetaan.

drop function if exists public.whatsapp_inbound_act(uuid, jsonb);
drop function if exists public.whatsapp_store_outbound(uuid, text, text, text, uuid);
drop function if exists public.whatsapp_mark_handled(uuid, text, text);
drop function if exists public.whatsapp_store_inbound(text, text, timestamptz, text, text, text);
drop function if exists public._whatsapp_match_staff(text);
drop function if exists public._whatsapp_open_offers(uuid);
drop function if exists public._whatsapp_save_context(uuid, uuid[], uuid[], text);
drop function if exists public._whatsapp_actor_access(uuid);
drop function if exists public._whatsapp_when(timestamptz, timestamptz);
drop function if exists public._whatsapp_role(text);
drop function if exists public._whatsapp_clean(text);
drop function if exists public._whatsapp_silent();
drop function if exists public._whatsapp_reply(text, jsonb, uuid);

drop table if exists public.whatsapp_pending_actions;
drop table if exists public.whatsapp_staff_context;

drop index if exists public.whatsapp_messages_unhandled_idx;
alter table public.whatsapp_messages
  drop column if exists intent,
  drop column if exists button_id,
  drop column if exists message_type,
  drop column if exists handled_by,
  drop column if exists handled_at,
  drop column if exists phone_e164;

alter table public.shift_offer_engine_settings
  drop column if exists whatsapp_inbound_enabled;
