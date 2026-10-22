-- PALUU: purkaa 20261022021000_shift_offer_engine.sql.
-- Palauttaa shift_offer_waitin tuotantoversioon (20261021234616): kaikille-hetki on vuoro − all_by_before, ilman previous_evening-siirtoa.
-- Ei koske sääntötauluja, tarjouksia eikä closure-mallia. Aja ennen 20261021234616_shift_offer_rules_DOWN.sql jos koko tarjousmalli puretaan.

drop function if exists public.shift_offer_tick(boolean, timestamptz);
drop function if exists public.shift_offer_service_closures(timestamptz, boolean);
drop function if exists public.shift_offer_cancel_for_closure(timestamptz, boolean);
drop function if exists public.shift_offer_sender_drain(int);
drop function if exists public.shift_offer_engine_respond(uuid, uuid, text, timestamptz, text);
drop function if exists public.shift_offer_ensure(uuid, timestamptz, boolean);
drop function if exists public.shift_offer_on_exhausted(uuid, timestamptz, boolean);
drop function if exists public.shift_offer_issue_recipients(uuid, text, timestamptz, timestamptz, timestamptz, int, text, uuid[], text[], int[]);
drop function if exists public.shift_offer_round_deadline(text, timestamptz, timestamptz, text, boolean);
drop function if exists public.shift_offer_pick_staff(text, date, int, text, timestamptz, timestamptz, boolean);
drop function if exists public.shift_offer_ensure_closure(text, date, text, boolean);
drop function if exists public.shift_offer_compose(text, uuid, uuid, text, timestamptz, timestamptz, timestamptz, int);
drop function if exists public.shift_offer_link(uuid, uuid, timestamptz, text);
drop function if exists public.shift_offer_queue_message(uuid, bigint, uuid, text, text, text);
drop function if exists public.shift_offer_role_label(text);
drop function if exists public.shift_offer_verify_token(text);
drop function if exists public.shift_offer_sign_token(uuid, uuid, timestamptz);
drop function if exists public.shift_offer_token_key();
drop function if exists public.shift_offer_b64url(bytea);
drop function if exists public.shift_offer_blocked_by_closure(text, timestamptz, timestamptz, text);
drop function if exists public.shift_treatments_closed(timestamptz, timestamptz);
drop function if exists public.shift_offer_all_by_at(text, timestamptz);
drop function if exists public.shift_offer_wait(text, timestamptz, timestamptz, boolean);

create or replace function public.shift_offer_wait(p_role text, p_shift_starts timestamptz, p_now timestamptz default now(), p_last_round boolean default false)
returns table (tier_id bigint, direct_to_all boolean, wait interval, deadline_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  s public.shift_offer_settings%rowtype;
  t public.shift_offer_response_tiers%rowtype;
  v_wait interval; v_dl timestamptz;
begin
  select * into s from public.shift_offer_settings x where x.role_type = p_role;
  if not found then raise exception 'Roolille % ei ole shift_offer_settings-riviä', p_role using errcode = 'P0002'; end if;
  select x.* into t from public.shift_offer_response_tiers x
   where (x.role_type = p_role or x.role_type is null) and p_now + x.min_lead <= p_shift_starts
   order by x.min_lead desc, (x.role_type is not null) desc limit 1;
  if not found or t.direct_to_all or p_shift_starts - s.all_by_before <= p_now then
    return query select t.id, true, null::interval, null::timestamptz; return;
  end if;
  v_wait := case when p_last_round then coalesce(t.wait_last_round, t.wait) else t.wait end;
  v_dl := public.shift_add_active_time(p_now, v_wait, p_role);
  if not p_last_round then v_dl := least(v_dl, p_shift_starts - s.all_by_before); end if;
  return query select t.id, false, v_wait, v_dl;
end $$;

revoke all on function public.shift_offer_wait(text, timestamptz, timestamptz, boolean) from public, anon, authenticated;
grant execute on function public.shift_offer_wait(text, timestamptz, timestamptz, boolean) to service_role;

drop table if exists public.shift_offer_messages;
drop table if exists public.shift_offer_engine_settings;

alter table public.shift_offers drop column if exists exhausted_asks;
alter table public.shift_offer_settings drop constraint if exists shift_offer_settings_all_by_quiet_chk;
alter table public.shift_offer_settings drop column if exists all_by_quiet;
