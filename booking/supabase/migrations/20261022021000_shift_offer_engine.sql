-- Vuorotarjousmoottori (SPEC.md, Joonas 22.10.2026). EI ajettu tuotantoon tästä haarasta.
-- Tick on public.shift_offer_tick: pg_cron kutsuu edge-funktiota shift-offer-engine (cron-SQL on funktion kommentissa, ei tässä).
-- Viestit vain public.shift_offer_messages -jonoon. Lähettäjäkytkin sender_enabled oletus false: mitään ei lähde.
-- Uutta: all_by_quiet = previous_evening (oletus, odottaa Joonaksen vahvistusta). Jos "kaikille viimeistään
-- all_by_before" osuu hiljaiseen aikaan 21:00–08:00, lähetys siirtyy edellisen illan quiet_startiin (21:00).
-- Hoidot kiinni -kalenteri (booking.closure_events, code hoidot) estää hoitaja- ja heidän vastaanottovuoronsa
-- tarjouksen. Myöhemmin ilmestynyt sulku peruu avoimen tarjouksen ja jonottaa ilmoituksen.

alter table public.shift_offer_settings
  add column all_by_quiet text not null default 'previous_evening';
alter table public.shift_offer_settings
  add constraint shift_offer_settings_all_by_quiet_chk
  check (all_by_quiet in ('previous_evening', 'exact'));
comment on column public.shift_offer_settings.all_by_quiet is
  'Kaikille-hetki (vuoro − all_by_before). previous_evening (oletus, Joonaksen vahvistus kesken): jos hetki osuu [quiet_start, quiet_end) eli 21:00–08:00, lähetys on edellisen illan quiet_start (21:00). exact = ei siirtoa.';

alter table public.shift_offers
  add column exhausted_asks smallint not null default 0 check (exhausted_asks >= 0);

create table public.shift_offer_engine_settings (
  id               boolean primary key default true check (id),
  dry_run          boolean not null default false,   -- true = tick ei kirjoita, vaikka kutsu ei pyydä dry_runia
  sender_enabled   boolean not null default false,   -- lähettäjästubi. false = viestit jäävät jonoon, mitään ei lähetetä
  public_base_url  text not null default 'https://sxbofnuisemspgquoxyv.supabase.co',
  updated_at       timestamptz not null default now()
);
insert into public.shift_offer_engine_settings default values;
comment on table public.shift_offer_engine_settings is
  'Tarjousmoottorin kytkimet. dry_run ja sender_enabled ovat oletuksena pois päältä kirjoituksen ja lähetyksen osalta: dry_run pakottaa kuivaharjoituksen, sender_enabled päästää vain stubin merkitsemään jonon (ei verkkoa).';

create table public.shift_offer_messages (
  id              bigint generated always as identity primary key,
  offer_id        uuid references public.shift_offers(id) on delete cascade,
  recipient_id    bigint references public.shift_offer_recipients(id) on delete set null,
  staff_id        uuid references public.staff(id) on delete set null,
  kind            text not null check (kind in ('offer','reminder','filled','cancelled','exhausted_ask','alert')),
  channel         text not null check (channel in ('whatsapp','email','none')),
  to_address      text,
  body            text not null,
  status          text not null default 'queued' check (status in ('queued','sending','sent','skipped','failed')),
  attempts        int not null default 0,
  last_error      text,
  dedupe_key      text not null,
  next_attempt_at timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  sent_at         timestamptz,
  constraint shift_offer_messages_dedupe_uq unique (dedupe_key)
);
create index shift_offer_messages_queued_idx on public.shift_offer_messages (next_attempt_at) where status = 'queued';
create index shift_offer_messages_offer_idx on public.shift_offer_messages (offer_id);
comment on table public.shift_offer_messages is
  'Tarjousviestien outbox. status queued kunnes erillinen lähettäjä (oletus pois) käsittelee rivin. Moottori ei soita WhatsAppiin eikä sähköpostiin.';

alter table public.shift_offer_engine_settings enable row level security;
alter table public.shift_offer_messages enable row level security;
revoke all on table public.shift_offer_engine_settings, public.shift_offer_messages from public, anon, authenticated;
grant select, insert, update, delete on table public.shift_offer_engine_settings, public.shift_offer_messages to service_role;
grant usage, select on sequence public.shift_offer_messages_id_seq to service_role;

-- ---------- kaikille-hetki ----------
create or replace function public.shift_offer_all_by_at(p_role text, p_shift_starts timestamptz)
returns timestamptz
language plpgsql stable security definer set search_path = '' as $$
declare
  s public.shift_offer_settings%rowtype;
  v timestamp;
begin
  select * into s from public.shift_offer_settings x where x.role_type = p_role;
  if not found then raise exception 'Roolille % ei ole shift_offer_settings-riviä', p_role using errcode = 'P0002'; end if;
  v := (p_shift_starts - s.all_by_before) at time zone s.timezone;
  if s.all_by_quiet = 'previous_evening' then
    if v::time >= s.quiet_start then
      v := v::date + s.quiet_start;
    elsif v::time < s.quiet_end then
      v := (v::date - 1) + s.quiet_start;
    end if;
  end if;
  return v at time zone s.timezone;
end $$;

-- Korvaa tuotannon shift_offer_wait: direct_to_all ja kierroksen katto käyttävät siirrettyä kaikille-hetkeä.
create or replace function public.shift_offer_wait(p_role text, p_shift_starts timestamptz, p_now timestamptz default now(), p_last_round boolean default false)
returns table (tier_id bigint, direct_to_all boolean, wait interval, deadline_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  s public.shift_offer_settings%rowtype;
  t public.shift_offer_response_tiers%rowtype;
  v_wait interval; v_dl timestamptz; v_all_by timestamptz;
begin
  select * into s from public.shift_offer_settings x where x.role_type = p_role;
  if not found then raise exception 'Roolille % ei ole shift_offer_settings-riviä', p_role using errcode = 'P0002'; end if;
  v_all_by := public.shift_offer_all_by_at(p_role, p_shift_starts);
  select x.* into t from public.shift_offer_response_tiers x
   where (x.role_type = p_role or x.role_type is null) and p_now + x.min_lead <= p_shift_starts
   order by x.min_lead desc, (x.role_type is not null) desc limit 1;
  if not found or t.direct_to_all or v_all_by <= p_now then
    return query select t.id, true, null::interval, null::timestamptz; return;
  end if;
  v_wait := case when p_last_round then coalesce(t.wait_last_round, t.wait) else t.wait end;
  v_dl := public.shift_add_active_time(p_now, v_wait, p_role);
  if not p_last_round then v_dl := least(v_dl, v_all_by); end if;
  return query select t.id, false, v_wait, v_dl;
end $$;

-- ---------- hoidot kiinni ----------
create or replace function public.shift_treatments_closed(p_starts timestamptz, p_ends timestamptz)
returns boolean
language sql stable security definer set search_path = '' as $$
  select p_starts is not null and exists (
    select 1 from booking.closure_events e
     where e.calendar_code = 'hoidot' and e.status = 'active'
       and (e.override = 'block' or (e.override is null and e.class = 'closure'))
       and e.starts_at < coalesce(p_ends, p_starts + interval '1 minute')
       and e.ends_at > p_starts)
$$;

-- Hoitajavuoro sekä vastaanotto, joka seuraa hoitajaa (follow_role) tai on reception_extra.
-- Viikonlopun vastaanotto (oma vakitekijä, ei follow_role) ei ole "heidän vastaanottonsa".
create or replace function public.shift_offer_blocked_by_closure(
  p_role text, p_starts timestamptz, p_ends timestamptz, p_scenario text default 'vacant_shift')
returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_tz text; v_date date; v_via text;
begin
  if not public.shift_treatments_closed(p_starts, p_ends) then return false; end if;
  if p_role = 'therapist' then return true; end if;
  if p_role <> 'reception' then return false; end if;
  if p_scenario = 'reception_extra' then return true; end if;
  select s.timezone into v_tz from public.shift_offer_settings s where s.role_type = 'reception';
  v_date := (p_starts at time zone coalesce(v_tz, 'Europe/Helsinki'))::date;
  select o.via_role into v_via from public.shift_default_owner('reception', v_date) o;
  return v_via = 'therapist';
end $$;

-- ---------- token (HMAC, canonical JSON). Avain: set_config sipoo.shift_offer_token_key tai vault shift_offer_token_secret. ----------
create or replace function public.shift_offer_b64url(p_data bytea)
returns text
language sql immutable set search_path = '' as $$
  select rtrim(translate(replace(replace(encode(p_data, 'base64'), E'\n', ''), E'\r', ''), '+/', '-_'), '=')
$$;

create or replace function public.shift_offer_token_key()
returns text
language plpgsql stable security definer set search_path = '' as $$
declare v text;
begin
  v := nullif(current_setting('sipoo.shift_offer_token_key', true), '');
  if v is not null then return v; end if;
  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
      into v using 'shift_offer_token_secret';
  exception when others then
    v := null;
  end;
  return nullif(v, '');
end $$;

create or replace function public.shift_offer_sign_token(p_offer_id uuid, p_staff_id uuid, p_exp timestamptz)
returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_key text; v_raw text; v_payload text; v_sig text;
begin
  v_key := public.shift_offer_token_key();
  if v_key is null or p_offer_id is null or p_staff_id is null or p_exp is null then return null; end if;
  v_raw := '{"o":"' || p_offer_id::text || '","s":"' || p_staff_id::text || '","e":' || floor(extract(epoch from p_exp))::bigint::text || '}';
  v_payload := public.shift_offer_b64url(convert_to(v_raw, 'utf8'));
  v_sig := public.shift_offer_b64url(extensions.hmac(convert_to(v_payload, 'utf8'), convert_to(v_key, 'utf8'), 'sha256'));
  return v_payload || '.' || v_sig;
end $$;

create or replace function public.shift_offer_verify_token(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_key text; v_payload text; v_sig text; v_expect text; v_raw text; v_json jsonb; v_exp timestamptz;
begin
  if p_token is null or position('.' in p_token) = 0 then
    return jsonb_build_object('ok', false, 'error', 'bad_token');
  end if;
  v_key := public.shift_offer_token_key();
  if v_key is null then return jsonb_build_object('ok', false, 'error', 'no_key'); end if;
  v_payload := split_part(p_token, '.', 1);
  v_sig := split_part(p_token, '.', 2);
  if v_payload = '' or v_sig = '' or split_part(p_token, '.', 3) <> '' then
    return jsonb_build_object('ok', false, 'error', 'bad_token');
  end if;
  v_expect := public.shift_offer_b64url(extensions.hmac(convert_to(v_payload, 'utf8'), convert_to(v_key, 'utf8'), 'sha256'));
  if v_expect is distinct from v_sig then return jsonb_build_object('ok', false, 'error', 'bad_token'); end if;
  begin
    v_raw := convert_from(decode(rpad(translate(v_payload, '-_', '+/'), (4 - length(translate(v_payload, '-_', '+/')) % 4) % 4 + length(translate(v_payload, '-_', '+/')), '='), 'base64'), 'utf8');
    v_json := v_raw::jsonb;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_token');
  end;
  v_exp := to_timestamp((v_json->>'e')::double precision);
  if v_exp <= now() then return jsonb_build_object('ok', false, 'error', 'expired'); end if;
  return jsonb_build_object('ok', true, 'offer_id', v_json->>'o', 'staff_id', v_json->>'s', 'exp', v_exp);
end $$;

-- ---------- viestit ----------
create or replace function public.shift_offer_role_label(p_role text)
returns text
language sql immutable set search_path = '' as $$
  select case p_role when 'heater' then 'lämmitysvuoro' when 'reception' then 'vastaanottovuoro' when 'therapist' then 'hoitajavuoro' else 'vuoro' end
$$;

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

create or replace function public.shift_offer_link(p_offer uuid, p_staff uuid, p_exp timestamptz, p_response text)
returns text
language plpgsql stable security definer set search_path = '' as $$
declare v_tok text; v_base text;
begin
  v_tok := public.shift_offer_sign_token(p_offer, p_staff, p_exp);
  if v_tok is null then return null; end if;
  select public_base_url into v_base from public.shift_offer_engine_settings where id;
  return rtrim(coalesce(v_base, ''), '/') || '/functions/v1/shift-offer-engine?token=' || v_tok || '&r=' || p_response;
end $$;

create or replace function public.shift_offer_compose(
  p_kind text, p_staff uuid, p_offer uuid, p_role text, p_starts timestamptz, p_ends timestamptz,
  p_deadline timestamptz, p_ask_no int default null)
returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  s public.shift_offer_settings%rowtype;
  v_name text; v_tz text; v_wd text; v_date text; v_a text; v_b text; v_label text;
  v_acc text; v_dec text; v_snz text; v_when text; v_snooze boolean;
begin
  select * into s from public.shift_offer_settings x where x.role_type = p_role;
  v_tz := coalesce(s.timezone, 'Europe/Helsinki');
  select st.name into v_name from public.staff st where st.id = p_staff;
  v_wd := (array['ma','ti','ke','to','pe','la','su'])[extract(isodow from (p_starts at time zone v_tz)::date)];
  v_date := to_char(p_starts at time zone v_tz, 'DD.MM.YYYY');
  v_a := to_char(p_starts at time zone v_tz, 'HH24:MI');
  v_b := to_char(p_ends at time zone v_tz, 'HH24:MI');
  v_label := public.shift_offer_role_label(p_role);
  v_when := v_wd || ' ' || v_date || ' klo ' || v_a || coalesce('–' || v_b, '');
  v_acc := public.shift_offer_link(p_offer, p_staff, p_starts, 'accept');
  v_dec := public.shift_offer_link(p_offer, p_staff, p_starts, 'decline');
  v_snooze := coalesce(s.snooze_any_recipient, false) or p_staff = any (coalesce(s.snooze_staff_ids, '{}'));
  if v_snooze and p_starts - coalesce(s.snooze_min_left, interval '14 days') > now() then
    v_snz := public.shift_offer_link(p_offer, p_staff, p_starts, 'snooze');
  end if;
  if p_kind = 'filled' then
    return 'Hei ' || coalesce(v_name, '') || E'.\nVuoro on täytetty (' || v_label || ' ' || v_wd || ' ' || v_date || ' klo ' || v_a || E').\n\n–Tapio';
  elsif p_kind = 'cancelled' then
    return 'Hei ' || coalesce(v_name, '') || E'.\n' || v_label || ' ' || v_wd || ' ' || v_date || E' peruttiin, koska hoidot ovat kiinni sinä päivänä.\n\n–Tapio';
  elsif p_kind = 'alert' then
    return 'Hei ' || coalesce(v_name, '') || E'.\n' || v_label || ' ' || v_when || E' on ilman tekijää.\n\n–Tapio';
  elsif p_kind = 'exhausted_ask' then
    return 'Hei ' || coalesce(v_name, '') || E'.\nHoitajavuoro ' || v_when || ' on yhä ilman tekijää (kysymys ' || coalesce(p_ask_no, 1)::text || '/' || coalesce(s.exhausted_ask_count, 3)::text || E'). Mitä tehdään?\n\nHyväksy vuoro: ' || coalesce(v_acc, '(linkki puuttuu)') || E'\nKieltäydy: ' || coalesce(v_dec, '(linkki puuttuu)') || E'\n\n–Tapio';
  elsif p_kind = 'reminder' then
    return 'Hei ' || coalesce(v_name, '') || E'.\nMuistutus: vapaa ' || v_label || ' ' || v_when || E'. Palasit asiaan tänään.\nVastaa viimeistään ' || coalesce(to_char(p_deadline at time zone v_tz, 'DD.MM.YYYY HH24:MI'), 'pian') || E'.\n\nHyväksy: ' || coalesce(v_acc, '(linkki puuttuu)') || E'\nKieltäydy: ' || coalesce(v_dec, '(linkki puuttuu)') || E'\n\n–Tapio';
  end if;
  return 'Hei ' || coalesce(v_name, '') || E'.\nVapaa ' || v_label || ' ' || v_when || E'.\nVastaa viimeistään ' || coalesce(to_char(p_deadline at time zone v_tz, 'DD.MM.YYYY HH24:MI'), 'pian') || E'.\n\nHyväksy: ' || coalesce(v_acc, '(linkki puuttuu)') || E'\nKieltäydy: ' || coalesce(v_dec, '(linkki puuttuu)')
    || case when v_snz is not null then E'\nPalaan asiaan: ' || v_snz else '' end
    || E'\n\n–Tapio';
end $$;

-- ---------- sulku olemassa olevaan malliin (space_blocks -> closure_outbox -> booking-closure-sync) ----------
create or replace function public.shift_offer_ensure_closure(p_calendar text, p_date date, p_reason text, p_dry boolean default false)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_space bigint; v_tz text; v_start timestamptz; v_end timestamptz; v_id bigint;
begin
  select c.resource_id, c.timezone into v_space, v_tz from booking.closure_calendars c where c.code = p_calendar;
  if v_space is null then return jsonb_build_object('action', 'no_calendar', 'calendar', p_calendar); end if;
  v_start := (p_date::timestamp) at time zone v_tz;
  v_end := ((p_date + 1)::timestamp) at time zone v_tz;
  if exists (select 1 from booking.space_blocks b where b.space_id = v_space and b.active and b.starts_at < v_end and b.ends_at > v_start)
     or exists (select 1 from booking.closure_events e where e.calendar_code = p_calendar and e.status = 'active'
                  and (e.override = 'block' or (e.override is null and e.class = 'closure'))
                  and e.starts_at < v_end and e.ends_at > v_start) then
    return jsonb_build_object('action', 'already_closed', 'calendar', p_calendar, 'on_date', p_date);
  end if;
  if p_dry then return jsonb_build_object('action', 'would_close', 'calendar', p_calendar, 'on_date', p_date); end if;
  insert into booking.space_blocks (space_id, starts_at, ends_at, reason)
  values (v_space, v_start, v_end, left(coalesce(p_reason, 'Tarjousmoottori'), 300))
  returning id into v_id;
  return jsonb_build_object('action', 'closed', 'calendar', p_calendar, 'on_date', p_date, 'block_id', v_id);
end $$;

-- ---------- ehdokkaat kierrokselle. direct = kaikille yhdellä kertaa (myös named_last). ----------
create or replace function public.shift_offer_pick_staff(
  p_role text, p_date date, p_round int, p_scenario text,
  p_starts timestamptz, p_ends timestamptz, p_direct boolean)
returns table (staff_id uuid, staff_name text, round_kind text, round_no int, sort_order int)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_kind text; v_lim int; v_all int; v_max int; v_use int; v_gs int;
begin
  select s.group_size into v_gs from public.shift_offer_settings s where s.role_type = p_role;
  v_gs := coalesce(v_gs, 3);
  select max(r.round_no) into v_max from public.shift_offer_rounds r
   where r.role_type = p_role and r.scenario = p_scenario and extract(isodow from p_date)::smallint = any (r.weekdays)
     and p_date >= r.valid_from and (r.valid_to is null or p_date <= r.valid_to);
  if v_max is null then return; end if;
  if p_direct then
    select r.round_no into v_all from public.shift_offer_rounds r
     where r.role_type = p_role and r.scenario = p_scenario and r.kind = 'all'
       and extract(isodow from p_date)::smallint = any (r.weekdays)
       and p_date >= r.valid_from and (r.valid_to is null or p_date <= r.valid_to)
     order by r.round_no limit 1;
    v_use := coalesce(v_all, v_max);
    return query
    select distinct on (q.staff_id) q.staff_id, q.staff_name, 'all'::text, v_use, q.sort_order
      from (
        select c.staff_id, c.staff_name, c.sort_order, r.round_no
          from public.shift_offer_rounds r
          cross join lateral public.shift_offer_candidates(p_role, p_date, r.round_no, p_scenario, p_starts, p_ends) c
         where r.role_type = p_role and r.scenario = p_scenario
           and extract(isodow from p_date)::smallint = any (r.weekdays)
           and p_date >= r.valid_from and (r.valid_to is null or p_date <= r.valid_to)
           and (v_all is null or r.kind = 'named_last' or r.round_no = v_all)
      ) q
     order by q.staff_id, q.round_no, q.sort_order;
    return;
  end if;
  select r.kind into v_kind from public.shift_offer_rounds r
   where r.role_type = p_role and r.scenario = p_scenario and r.round_no = p_round
     and extract(isodow from p_date)::smallint = any (r.weekdays)
     and p_date >= r.valid_from and (r.valid_to is null or p_date <= r.valid_to)
   order by r.valid_from desc limit 1;
  if v_kind is null then return; end if;
  v_lim := case when v_kind = 'rotation' then v_gs else 10000 end;
  return query
  select c.staff_id, c.staff_name, c.round_kind, p_round, c.sort_order
    from public.shift_offer_candidates(p_role, p_date, p_round, p_scenario, p_starts, p_ends) c
   order by c.sort_order, c.staff_name
   limit v_lim;
end $$;

create or replace function public.shift_offer_round_deadline(
  p_role text, p_starts timestamptz, p_now timestamptz, p_kind text, p_last boolean)
returns timestamptz
language plpgsql stable security definer set search_path = '' as $$
declare
  t record; s public.shift_offer_settings%rowtype; v_dl timestamptz; v_wait interval;
begin
  select * into s from public.shift_offer_settings x where x.role_type = p_role;
  select * into t from public.shift_offer_wait(p_role, p_starts, p_now, p_last) w;
  if t.direct_to_all or t.deadline_at is null then
    v_wait := least(interval '6 hours', greatest(p_starts - p_now, interval '1 hour'));
    v_dl := public.shift_add_active_time(p_now, v_wait, p_role);
  else
    v_dl := t.deadline_at;
  end if;
  if p_kind = 'rotation' then
    v_dl := least(v_dl, public.shift_add_active_time(p_now, coalesce(s.group_max_wait, interval '24 hours'), p_role));
  end if;
  return least(v_dl, p_starts);
end $$;

create or replace function public.shift_offer_issue_recipients(
  p_offer uuid, p_role text, p_starts timestamptz, p_ends timestamptz, p_now timestamptz,
  p_round int, p_kind text, p_staff uuid[], p_names text[], p_sorts int[])
returns int
language plpgsql security definer set search_path = '' as $$
declare
  i int; v_dl timestamptz; v_last boolean; v_id bigint; v_n int := 0; v_max int;
begin
  select max(r.round_no) into v_max from public.shift_offer_rounds r
    join public.shift_offers o on o.id = p_offer
   where r.role_type = o.role_type and r.scenario = o.scenario
     and extract(isodow from (p_starts at time zone 'Europe/Helsinki'))::smallint = any (r.weekdays);
  v_last := p_kind = 'all' or p_round >= coalesce(v_max, p_round);
  v_dl := public.shift_offer_round_deadline(p_role, p_starts, p_now, p_kind, v_last);
  for i in 1 .. coalesce(cardinality(p_staff), 0) loop
    v_id := null;
    insert into public.shift_offer_recipients (offer_id, staff_id, round_no, round_kind, status, sent_at, deadline_at)
    values (p_offer, p_staff[i], p_round, p_kind, 'pending', p_now, v_dl)
    on conflict (offer_id, staff_id) do nothing
    returning id into v_id;
    if v_id is null then continue; end if;
    perform public.shift_offer_queue_message(p_offer, v_id, p_staff[i], 'offer',
      public.shift_offer_compose('offer', p_staff[i], p_offer, p_role, p_starts, p_ends, v_dl, null),
      'offer:' || p_offer::text || ':staff:' || p_staff[i]::text || ':offer');
    v_n := v_n + 1;
  end loop;
  if p_kind = 'rotation' and v_n > 0 then
    update public.shift_offer_settings set rotation_last_staff_id = p_staff[cardinality(p_staff)], updated_at = now()
     where role_type = p_role;
  end if;
  update public.shift_offers set current_round_no = p_round, round_started_at = p_now, next_action_at = v_dl,
         all_sent_at = case when p_kind = 'all' then p_now else all_sent_at end,
         status = 'active', updated_at = p_now
   where id = p_offer;
  return v_n;
end $$;

create or replace function public.shift_offer_on_exhausted(p_offer uuid, p_now timestamptz, p_dry boolean)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  o public.shift_offers%rowtype;
  w public.work_shifts%rowtype;
  s public.shift_offer_settings%rowtype;
  st record; v_last timestamptz; v_date date; v_id bigint; v_close jsonb; v_staff uuid;
begin
  select * into o from public.shift_offers x where x.id = p_offer;
  select * into w from public.work_shifts x where x.id = o.shift_id;
  select * into s from public.shift_offer_settings x where x.role_type = o.role_type;
  select max(m.created_at) into v_last from public.shift_offer_messages m where m.offer_id = o.id and m.kind = 'exhausted_ask';
  select * into st from public.shift_exhausted_next_step(o.role_type, w.starts_at, o.exhausted_asks, v_last, p_now) q;
  v_date := (w.starts_at at time zone s.timezone)::date;
  if st.action = 'ask' and st.due_at <= p_now and s.exhausted_ask_staff_id is not null then
    if p_dry then return jsonb_build_object('action', 'would_ask', 'ask_no', st.ask_no, 'offer_id', o.id); end if;
    select r.id into v_id from public.shift_offer_recipients r where r.offer_id = o.id and r.staff_id = s.exhausted_ask_staff_id;
    if v_id is null then
      insert into public.shift_offer_recipients (offer_id, staff_id, round_no, round_kind, status, sent_at, deadline_at)
      values (o.id, s.exhausted_ask_staff_id, 100 + coalesce(st.ask_no, 1), 'owner_ask', 'pending', p_now,
              public.shift_offer_round_deadline(o.role_type, w.starts_at, p_now, 'named', true))
      returning id into v_id;
    else
      update public.shift_offer_recipients set status = 'pending', round_no = 100 + coalesce(st.ask_no, 1), round_kind = 'owner_ask',
             snooze_until = null, responded_at = null, sent_at = coalesce(sent_at, p_now),
             deadline_at = public.shift_offer_round_deadline(o.role_type, w.starts_at, p_now, 'named', true)
       where id = v_id;
    end if;
    perform public.shift_offer_queue_message(o.id, v_id, s.exhausted_ask_staff_id, 'exhausted_ask',
      public.shift_offer_compose('exhausted_ask', s.exhausted_ask_staff_id, o.id, o.role_type, w.starts_at, w.ends_at, null, st.ask_no),
      'offer:' || o.id::text || ':ask:' || coalesce(st.ask_no, 1)::text);
    update public.shift_offers set exhausted_asks = coalesce(st.ask_no, o.exhausted_asks + 1), status = 'escalated',
           current_round_no = 100 + coalesce(st.ask_no, 1), next_action_at = (
             select q.due_at from public.shift_exhausted_next_step(o.role_type, w.starts_at, coalesce(st.ask_no, 1), p_now, p_now) q),
           updated_at = p_now
     where id = o.id;
    return jsonb_build_object('action', 'asked', 'ask_no', st.ask_no, 'offer_id', o.id);
  end if;
  if st.action = 'ask' then
    if not p_dry then update public.shift_offers set status = 'escalated', next_action_at = st.due_at, updated_at = p_now where id = o.id; end if;
    return jsonb_build_object('action', 'ask_scheduled', 'due_at', st.due_at, 'offer_id', o.id);
  end if;
  -- close | wait_owner
  if st.due_at > p_now then
    if not p_dry then update public.shift_offers set status = 'escalated', next_action_at = st.due_at, updated_at = p_now where id = o.id; end if;
    return jsonb_build_object('action', 'close_scheduled', 'due_at', st.due_at, 'offer_id', o.id);
  end if;
  if st.action = 'close' and s.auto_close_enabled and o.role_type = 'therapist' then
    v_close := public.shift_offer_ensure_closure('hoidot', v_date, 'Tarjousmoottori: hoitajavuoro tyhjä, hoidot kiinni', p_dry);
    if not p_dry then update public.shift_offers set status = 'closed', next_action_at = null, updated_at = p_now, note = 'auto_close' where id = o.id; end if;
    return jsonb_build_object('action', 'closed', 'offer_id', o.id, 'closure', v_close);
  end if;
  if not p_dry then
    update public.shift_offers set status = 'escalated', next_action_at = null, updated_at = p_now where id = o.id;
    foreach v_staff in array coalesce(s.alert_staff_ids, '{}') loop
      perform public.shift_offer_queue_message(o.id, null, v_staff, 'alert',
        public.shift_offer_compose('alert', v_staff, o.id, o.role_type, w.starts_at, w.ends_at, null, null),
        'offer:' || o.id::text || ':alert:' || v_staff::text);
    end loop;
  end if;
  return jsonb_build_object('action', 'wait_owner', 'offer_id', o.id);
end $$;

-- Luo tai edistää yhtä vuoron tarjousta. p_dry ei kirjoita.
create or replace function public.shift_offer_ensure(p_shift_id uuid, p_now timestamptz default now(), p_dry boolean default false)
returns jsonb
language plpgsql security definer set search_path = '' as $$
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
  if w.staffing_status is distinct from 'open' then return jsonb_build_object('action', 'skip', 'reason', 'staffing'); end if;
  if exists (select 1 from public.shift_assignments a where a.shift_id = w.id and a.status in ('assigned','confirmed')) then
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
    if o.next_action_at is not null and o.next_action_at > p_now then
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
end $$;

-- Vastaus + täytetty-ilmoitukset samassa transaktiossa. already_filled -> already_taken.
create or replace function public.shift_offer_engine_respond(
  p_offer_id uuid, p_staff_id uuid, p_response text,
  p_snooze_until timestamptz default null, p_token text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v jsonb; v_tok jsonb; w public.work_shifts%rowtype; o public.shift_offers%rowtype; v_staff uuid;
begin
  if p_token is not null then
    v_tok := public.shift_offer_verify_token(p_token);
    if coalesce(v_tok->>'ok', 'false') <> 'true' or v_tok->>'offer_id' is distinct from p_offer_id::text
       or v_tok->>'staff_id' is distinct from p_staff_id::text then
      return jsonb_build_object('result', 'bad_token');
    end if;
  end if;
  v := public.shift_offer_respond(p_offer_id, p_staff_id, p_response, p_snooze_until, true, 'tyovuoro-tapio');
  if v->>'result' = 'already_filled' then
    v := v || jsonb_build_object('result', 'already_taken');
  end if;
  if v->>'result' = 'accepted' then
    select * into o from public.shift_offers x where x.id = p_offer_id;
    select * into w from public.work_shifts x where x.id = o.shift_id;
    for v_staff in select distinct t::uuid from jsonb_array_elements_text(coalesce(v->'notify_filled_staff_ids', '[]'::jsonb)) t loop
      perform public.shift_offer_queue_message(o.id, null, v_staff, 'filled',
        public.shift_offer_compose('filled', v_staff, o.id, o.role_type, w.starts_at, w.ends_at, null, null),
        'offer:' || o.id::text || ':staff:' || v_staff::text || ':filled');
      update public.shift_offer_recipients set filled_notified_at = now()
       where offer_id = o.id and staff_id = v_staff and filled_notified_at is null;
    end loop;
  end if;
  return v;
end $$;

-- Lähettäjästubi: ei verkkoa. Kytkin pois -> ei tee mitään. Kytkin päällä -> merkitsee jonon lähetetyksi stubina.
create or replace function public.shift_offer_sender_drain(p_limit int default 50)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_on boolean; v_n int;
begin
  select sender_enabled into v_on from public.shift_offer_engine_settings where id;
  if not coalesce(v_on, false) then
    return jsonb_build_object('ok', true, 'sender_enabled', false, 'sent', 0);
  end if;
  with u as (
    update public.shift_offer_messages set status = case when channel = 'none' then 'skipped' else 'sent' end,
           sent_at = now(), last_error = 'stub', attempts = attempts + 1
     where id in (
       select m.id from public.shift_offer_messages m where m.status = 'queued' and m.next_attempt_at <= now()
        order by m.id limit greatest(1, least(coalesce(p_limit, 50), 200))
     )
    returning 1)
  select count(*) into v_n from u;
  return jsonb_build_object('ok', true, 'sender_enabled', true, 'sent', v_n, 'transport', 'stub');
end $$;

create or replace function public.shift_offer_cancel_for_closure(p_now timestamptz, p_dry boolean)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  o public.shift_offers%rowtype; w public.work_shifts%rowtype; r record; v_out jsonb := '[]'::jsonb; v_n int := 0;
begin
  for o in select x.* from public.shift_offers x where x.status in ('active','paused','escalated') order by x.created_at loop
    select * into w from public.work_shifts s where s.id = o.shift_id;
    if not found then continue; end if;
    if not public.shift_offer_blocked_by_closure(o.role_type, coalesce(o.window_starts_at, w.starts_at), coalesce(o.window_ends_at, w.ends_at), o.scenario) then
      continue;
    end if;
    v_out := v_out || jsonb_build_object('offer_id', o.id, 'shift_id', w.id, 'role_type', o.role_type);
    v_n := v_n + 1;
    if p_dry then continue; end if;
    for r in select * from public.shift_offer_recipients x where x.offer_id = o.id and x.sent_at is not null and x.status in ('pending','snoozed','declined','queued') loop
      perform public.shift_offer_queue_message(o.id, r.id, r.staff_id, 'cancelled',
        public.shift_offer_compose('cancelled', r.staff_id, o.id, o.role_type, w.starts_at, w.ends_at, null, null),
        'offer:' || o.id::text || ':staff:' || r.staff_id::text || ':cancelled');
    end loop;
    update public.shift_offer_recipients set status = 'withdrawn', snooze_until = null
     where offer_id = o.id and status in ('queued','pending','snoozed');
    update public.shift_offers set status = 'cancelled', next_action_at = null, updated_at = p_now, note = 'hoidot_kiinni' where id = o.id;
  end loop;
  return jsonb_build_object('cancelled', v_n, 'offers', v_out);
end $$;

create or replace function public.shift_offer_service_closures(p_now timestamptz, p_dry boolean)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s public.shift_offer_settings%rowtype;
  v_from date; v_to date; v_date date; v_wd smallint; v_th uuid; v_need jsonb; v_res jsonb; v_out jsonb := '[]'::jsonb;
begin
  select * into s from public.shift_offer_settings x where x.role_type = 'therapist';
  if not found or not s.enabled then return jsonb_build_object('skipped', true, 'reason', 'disabled'); end if;
  v_from := (p_now at time zone s.timezone)::date;
  v_to := ((p_now + s.start_before) at time zone s.timezone)::date;
  v_date := v_from;
  while v_date <= v_to loop
    v_wd := extract(isodow from v_date)::smallint;
    if exists (select 1 from public.shift_service_date_overrides o where o.service_code = 'perinnesaunotus' and o.on_date = v_date and o.mode = 'closed')
       or exists (select 1 from public.shift_service_allowed_therapists a where a.service_code = 'perinnesaunotus' and a.weekday = v_wd
                    and v_date >= a.valid_from and (a.valid_to is null or v_date <= a.valid_to)) then
      select a.staff_id into v_th from public.work_shifts w
        join public.shift_assignments a on a.shift_id = w.id and a.status in ('assigned','confirmed')
       where w.role_type = 'therapist' and w.status = 'active' and (w.starts_at at time zone s.timezone)::date = v_date
       limit 1;
      v_need := public.shift_service_closure_needed('perinnesaunotus', v_date, v_th);
      if coalesce(v_need->>'needs_closure', 'false') = 'true' and coalesce(v_need->>'reason', '') <> 'no_rule' then
        v_res := public.shift_offer_ensure_closure('perinnesaunotus', v_date, 'Tarjousmoottori: perinnesaunotus kiinni (' || coalesce(v_need->>'reason', '') || ')', p_dry);
        if v_res->>'action' in ('closed', 'would_close') then v_out := v_out || v_res; end if;
      end if;
    end if;
    v_date := v_date + 1;
  end loop;
  return jsonb_build_object('closures', v_out);
end $$;

-- Yksi tick. Idempotentti. p_dry_run tai engine_settings.dry_run estää kirjoitukset.
create or replace function public.shift_offer_tick(p_dry_run boolean default false, p_now timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_dry boolean; v_now timestamptz; w record; v_row jsonb;
  v_actions jsonb := '[]'::jsonb; v_cancel jsonb; v_svc jsonb;
begin
  v_now := coalesce(p_now, now());
  select coalesce(p_dry_run, false) or e.dry_run into v_dry from public.shift_offer_engine_settings e where e.id;
  v_dry := coalesce(v_dry, p_dry_run, false);
  v_cancel := public.shift_offer_cancel_for_closure(v_now, v_dry);
  v_svc := public.shift_offer_service_closures(v_now, v_dry);
  for w in
    select ws.id from public.work_shifts ws
      join public.shift_offer_settings s on s.role_type = ws.role_type and s.enabled
     where ws.status = 'active' and ws.staffing_status = 'open' and ws.starts_at > v_now and ws.starts_at <= v_now + s.start_before
     order by ws.starts_at
  loop
    v_row := public.shift_offer_ensure(w.id, v_now, v_dry);
    if v_row->>'action' not in ('skip', 'waiting') then v_actions := v_actions || v_row; end if;
  end loop;
  -- myös avoimet tarjoukset, joiden vuoro ei enää ole haussa (esim. ikkuna), mutta kierros on erääntynyt
  for w in
    select o.shift_id as id from public.shift_offers o
     where o.status in ('active','paused','escalated') and (o.next_action_at is null or o.next_action_at <= v_now)
       and not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'shift_id' = o.shift_id::text)
  loop
    v_row := public.shift_offer_ensure(w.id, v_now, v_dry);
    if v_row->>'action' not in ('skip', 'waiting') then v_actions := v_actions || v_row; end if;
  end loop;
  return jsonb_build_object('ok', true, 'dry_run', v_dry, 'now', v_now, 'cancel', v_cancel, 'service_closures', v_svc, 'actions', v_actions);
end $$;

revoke all on function public.shift_offer_b64url(bytea), public.shift_offer_token_key(), public.shift_offer_sign_token(uuid, uuid, timestamptz),
  public.shift_offer_verify_token(text), public.shift_offer_role_label(text), public.shift_offer_queue_message(uuid, bigint, uuid, text, text, text),
  public.shift_offer_link(uuid, uuid, timestamptz, text), public.shift_offer_compose(text, uuid, uuid, text, timestamptz, timestamptz, timestamptz, int),
  public.shift_offer_all_by_at(text, timestamptz), public.shift_offer_wait(text, timestamptz, timestamptz, boolean),
  public.shift_treatments_closed(timestamptz, timestamptz), public.shift_offer_blocked_by_closure(text, timestamptz, timestamptz, text),
  public.shift_offer_ensure_closure(text, date, text, boolean), public.shift_offer_pick_staff(text, date, int, text, timestamptz, timestamptz, boolean),
  public.shift_offer_round_deadline(text, timestamptz, timestamptz, text, boolean), public.shift_offer_issue_recipients(uuid, text, timestamptz, timestamptz, timestamptz, int, text, uuid[], text[], int[]),
  public.shift_offer_on_exhausted(uuid, timestamptz, boolean), public.shift_offer_ensure(uuid, timestamptz, boolean),
  public.shift_offer_engine_respond(uuid, uuid, text, timestamptz, text), public.shift_offer_sender_drain(int),
  public.shift_offer_cancel_for_closure(timestamptz, boolean), public.shift_offer_service_closures(timestamptz, boolean),
  public.shift_offer_tick(boolean, timestamptz)
  from public, anon, authenticated;
grant execute on function public.shift_offer_b64url(bytea), public.shift_offer_token_key(), public.shift_offer_sign_token(uuid, uuid, timestamptz),
  public.shift_offer_verify_token(text), public.shift_offer_role_label(text), public.shift_offer_queue_message(uuid, bigint, uuid, text, text, text),
  public.shift_offer_link(uuid, uuid, timestamptz, text), public.shift_offer_compose(text, uuid, uuid, text, timestamptz, timestamptz, timestamptz, int),
  public.shift_offer_all_by_at(text, timestamptz), public.shift_offer_wait(text, timestamptz, timestamptz, boolean),
  public.shift_treatments_closed(timestamptz, timestamptz), public.shift_offer_blocked_by_closure(text, timestamptz, timestamptz, text),
  public.shift_offer_ensure_closure(text, date, text, boolean), public.shift_offer_pick_staff(text, date, int, text, timestamptz, timestamptz, boolean),
  public.shift_offer_round_deadline(text, timestamptz, timestamptz, text, boolean), public.shift_offer_issue_recipients(uuid, text, timestamptz, timestamptz, timestamptz, int, text, uuid[], text[], int[]),
  public.shift_offer_on_exhausted(uuid, timestamptz, boolean), public.shift_offer_ensure(uuid, timestamptz, boolean),
  public.shift_offer_engine_respond(uuid, uuid, text, timestamptz, text), public.shift_offer_sender_drain(int),
  public.shift_offer_cancel_for_closure(timestamptz, boolean), public.shift_offer_service_closures(timestamptz, boolean),
  public.shift_offer_tick(boolean, timestamptz)
  to service_role;
