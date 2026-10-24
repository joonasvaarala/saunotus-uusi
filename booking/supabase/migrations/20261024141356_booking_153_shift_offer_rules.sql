-- booking_153: vuorotarjousmoottorin sääntömuutokset (SPEC 24.10.2026 16.15 / 16.23 / 16.26) ja henkilökunnan oma sivu.
-- Uudelleenajettava. Moottori pysyy pois päältä (public.shift_offer_settings.enabled / engine_settings ennallaan).
-- Public-skeeman TAULUJEN rakennetta ei muuteta. Uusi tila on booking-skeemassa. Public-moottorin funktioista
-- korvataan create or replace -lauseella: shift_offer_round_deadline, shift_offer_respond, shift_offer_compose,
-- shift_offer_on_exhausted, shift_offer_ensure, shift_offer_issue_recipients, shift_offer_tick, shift_offer_sender_claim.
-- Rollback: booking/supabase/rollbacks/20261024141356_booking_153_ROLLBACK.sql palauttaa ne tuotantomuotoon.
--
-- Säännöt:
--  1 Täytetystä vuorosta ei viestiä muille (respond palauttaa notify_filled_staff_ids = []). Myöhäinen hyväksyjä saa
--    sivulla / WhatsApp-vastauksena tiedon "vuoro on jo mennyt". Erillinen lähtevä viesti vain asetuksella
--    shift_offer.already_taken_message (oletus pois).
--  2 Viimeisen kierroksen takaraja: lämmittäjä 14 pv, hoitaja 21 pv ennen vuoroa, vastaanotto asetus (oletus 14 pv).
--    Vain kun tarjous alkoi vähintään shift_offer.last_round_min_lead (21 pv) ennen vuoroa; muuten portaat.
--  3 Lämmittäjä/vastaanotto ilman tekijää: chat-ilmoitus (Joonas, bot_channel) + sähköposti (Otto, jos
--    shift_offer.email_enabled). Muistutus 3 pv päästä tai viimeistään 7 pv ennen, siitä alkaen päivittäin.
--  4 Saman päivän viestit yhdistetään yhdeksi viestiksi vastaanottajaa kohden (booking.shift_offer_merge_same_day).
--  5 Hoitaja puuttuu, ei varauksia: viesti 3 vk ennen, 3 pv myöhemmin varoitus "suljetaan 6 h kuluessa", sitten sulku.
--  6 Hoitaja puuttuu ja varauksia on: heti, viikoittain, 3 vk ennen alkaen päivittäin. Ei sulkua.
--  7 Kierroksen loppumuistutus vastaamattomille (shift_offer.round_reminder_before, oletus 12 h).
--  8 Kieltäytyjälle ei uusia viestejä saman päivän samasta roolista; oma sivu (pysyvä linkki) näyttää avoimet ja
--    vastatut päivät, vastausta voi muuttaa.
--  a Otto sähköpostin allowlistille vain erillisellä käsin ajettavalla tiedostolla (ei tässä).
--  d WhatsApp vain 08–21 Europe/Helsinki; vastausaika lasketaan lähetyshetkestä (claim jatkaa takarajaa).
--  e '?'-vuorot (staffing_status 'uncertain') tarjolle vain asetuksella shift_offer.offer_uncertain_shifts (oletus pois).
--  f staff_unavailability vapauttaa vuoron (shift_offer.unavailability_frees_shift, oletus päällä).
--  h exhausted_ask-viestin roolinimi oikein.
set local lock_timeout = '5s';

-- ---------------------------------------------------------------- asetukset
insert into booking.settings (key, value, description, is_public) values
  ('shift_offer.last_round_before', '{"heater":"14 days","therapist":"21 days","reception":"14 days"}', 'booking_153: viimeisen kierroksen takaraja ennen vuoroa roolittain (vastaanotto vahvistettava)', false),
  ('shift_offer.last_round_min_lead', '"21 days"', 'booking_153: takarajasääntö vain, jos tarjous alkoi vähintään tämän verran ennen vuoroa; muuten portaat', false),
  ('shift_offer.round_reminder_before', '"12 hours"', 'booking_153: kierroksen loppumuistutus vastaamattomille näin paljon ennen takarajaa (enintään puolet kierroksesta)', false),
  ('shift_offer.vacant_notice', '{"chat_staff_ids":["5ab2ba62-97b2-4712-b500-a47a898036a5"],"email_staff_ids":["2975633f-c53f-48d6-8a38-41cae0be5a83"],"first_reminder_after":"3 days","daily_from":"7 days"}', 'booking_153: lämmittäjä/vastaanotto ilman tekijää: chat (Joonas) + sähköposti (Otto), muistutukset', false),
  ('shift_offer.therapist_notice', '{"staff_ids":["5ab2ba62-97b2-4712-b500-a47a898036a5","040e1780-554c-4842-bc7d-b53053de9e5f"],"three_weeks":"21 days","warn_after":"3 days","close_after":"6 hours","weekly":"7 days"}', 'booking_153: hoitaja puuttuu: ilmoitukset Joonas + Laura, varoitus ja sulku', false),
  ('shift_offer.email_enabled', 'false', 'booking_153: moottorin sähköpostit (email_outbox staff_shift_notice). Oletus pois.', false),
  ('shift_offer.offer_uncertain_shifts', 'false', 'booking_153: tarjotaanko ?-vuoroja (staffing_status uncertain). Oletus pois.', false),
  ('shift_offer.unavailability_frees_shift', 'true', 'booking_153: poissaolo (staff_unavailability) vapauttaa vuoron tarjolle', false),
  ('shift_offer.whatsapp_hours', '{"start":"08:00","end":"21:00"}', 'booking_153: WhatsApp-lähetykset vain tällä välillä (Europe/Helsinki). Sähköposti milloin vain.', false),
  ('shift_offer.welcome_enabled', 'false', 'booking_153: tervetuloviesti henkilökunnan ensimmäiseen WhatsApp-viestiin (24 h ikkuna). Oletus pois.', false),
  ('shift_offer.already_taken_message', 'false', 'booking_153: lähetetäänkö myöhäiselle hyväksyjälle erillinen "vuoro on jo mennyt" -viesti. Oletus pois (sivu ja WhatsApp-vastaus kertovat sen joka tapauksessa).', false),
  ('shift_offer.wa_templates', '{"offer":{"name":"tyovuoro_kysely","approved":false,"fallback":"vuorotarjous"},"round_reminder":{"name":"tyovuoro_muistutus","approved":false},"already_taken":{"name":"tyovuoro_jo_mennyt","approved":false},"day_digest":{"name":"tyovuoro_paivan_kooste","approved":false}}', 'booking_153: WhatsApp-pohjien nimet ja hyväksyntä. Hyväksymätön pohja: varapohja, 24 h ikkunan vapaa viesti tai sähköposti.', false),
  ('shift_offer.staff_page_url', '"https://joonasvaarala.github.io/saunotus-uusi/vuoro/oma/"', 'booking_153: henkilökunnan oman vuorosivun osoite (linkki = osoite + ?token=...)', false)
on conflict (key) do nothing;

-- ---------------------------------------------------------------- taulut (booking, ei viiteavaimia public-skeemaan)
create table if not exists booking.shift_offer_notices (
  id bigint generated always as identity primary key,
  offer_id uuid not null,
  shift_id uuid,
  staff_id uuid,
  stage text not null,
  message_id bigint,
  email_outbox_id bigint,
  created_at timestamptz not null default now(),
  dedupe_key text not null unique
);
create index if not exists shift_offer_notices_offer_idx on booking.shift_offer_notices (offer_id, stage);
alter table booking.shift_offer_notices enable row level security;
revoke all on booking.shift_offer_notices from public, anon, authenticated;
grant all on booking.shift_offer_notices to service_role;

create table if not exists booking.shift_offer_message_meta (
  message_id bigint primary key,
  subkind text not null,
  digest_key text,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists shift_offer_message_meta_digest_idx on booking.shift_offer_message_meta (digest_key);
alter table booking.shift_offer_message_meta enable row level security;
revoke all on booking.shift_offer_message_meta from public, anon, authenticated;
grant all on booking.shift_offer_message_meta to service_role;

create table if not exists booking.shift_staff_page_tokens (
  staff_id uuid primary key,
  nonce text not null,
  version int not null default 1,
  created_at timestamptz not null default now(),
  rotated_at timestamptz,
  revoked_at timestamptz,
  last_used_at timestamptz
);
alter table booking.shift_staff_page_tokens enable row level security;
revoke all on booking.shift_staff_page_tokens from public, anon, authenticated;
grant all on booking.shift_staff_page_tokens to service_role;

create table if not exists booking.shift_staff_whatsapp_consent (
  staff_id uuid primary key,
  first_inbound_at timestamptz not null,
  first_message_id uuid,
  welcome_sent_at timestamptz,
  suggestion_dismissed_at timestamptz,
  created_at timestamptz not null default now()
);
alter table booking.shift_staff_whatsapp_consent enable row level security;
revoke all on booking.shift_staff_whatsapp_consent from public, anon, authenticated;
grant all on booking.shift_staff_whatsapp_consent to service_role;

-- sähköpostityyppi staff_shift_notice (booking_146:n lista + uusi)
alter table booking.email_outbox drop constraint if exists email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check
  check (kind in ('order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change', 'gift_card_buyer', 'gift_card_recipient', 'voucher_claim_received', 'voucher_claim_problem', 'business_quote_ack', 'business_quote_notify', 'invoice_pdf', 'product_message', 'waitlist_spot_freed', 'annual_card_code', 'staff_shift_notice'));

-- booking_154 muuttaa email_outbox_claim-funktiota, joten sitä ei kääritä tässä. send-emails hakee staff_shift_notice-rivien
-- otsikon ja tekstin tällä erillisellä funktiolla (vain service_role).
create or replace function booking.email_staff_notice_payload(p_ids bigint[]) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(e.id::text, jsonb_build_object('subject', e.payload->>'subject', 'text', e.payload->>'text', 'link_url', e.payload->>'link_url')), '{}'::jsonb)
    from booking.email_outbox e where e.id = any (coalesce(p_ids, '{}')) and e.kind = 'staff_shift_notice';
$$;
revoke all on function booking.email_staff_notice_payload(bigint[]) from public, anon, authenticated;
grant execute on function booking.email_staff_notice_payload(bigint[]) to service_role;
-- ---------------------------------------------------------------- apufunktiot
create or replace function booking.shift_offer_cfg(p_key text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select booking._setting('shift_offer.' || p_key, null::jsonb);
$$;

create or replace function booking.shift_offer_cfg_bool(p_key text, p_default boolean) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := booking.shift_offer_cfg(p_key);
begin
  if v is null or jsonb_typeof(v) <> 'boolean' then return p_default; end if;
  return (v #>> '{}')::boolean;
end $$;

create or replace function booking.shift_offer_cfg_interval(p_key text, p_path text, p_default interval) returns interval
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := booking.shift_offer_cfg(p_key); t text;
begin
  if v is null then return p_default; end if;
  t := case when p_path is null then v #>> '{}' else v ->> p_path end;
  if t is null or btrim(t) = '' then return p_default; end if;
  return t::interval;
exception when others then return p_default;
end $$;

create or replace function booking.shift_offer_cfg_uuids(p_key text, p_path text) returns uuid[]
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := booking.shift_offer_cfg(p_key); a uuid[];
begin
  if v is null or jsonb_typeof(v -> p_path) <> 'array' then return '{}'; end if;
  select coalesce(array_agg(x::uuid), '{}') into a from jsonb_array_elements_text(v -> p_path) x
   where x ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  return a;
end $$;

-- WhatsApp-lähetysikkuna (oletus 08–21 Europe/Helsinki)
create or replace function booking.shift_offer_wa_open(p_at timestamptz default now()) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := booking.shift_offer_cfg('whatsapp_hours'); a time; b time; t time;
begin
  begin
    a := coalesce(v ->> 'start', '08:00')::time; b := coalesce(v ->> 'end', '21:00')::time;
  exception when others then a := time '08:00'; b := time '21:00';
  end;
  t := (p_at at time zone 'Europe/Helsinki')::time;
  return t >= a and t < b;
end $$;

create or replace function booking.shift_offer_wa_next_open(p_at timestamptz default now()) returns timestamptz
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := booking.shift_offer_cfg('whatsapp_hours'); a time; d date; t time;
begin
  if booking.shift_offer_wa_open(p_at) then return p_at; end if;
  begin a := coalesce(v ->> 'start', '08:00')::time; exception when others then a := time '08:00'; end;
  d := (p_at at time zone 'Europe/Helsinki')::date; t := (p_at at time zone 'Europe/Helsinki')::time;
  if t >= a then d := d + 1; end if;
  return (d + a) at time zone 'Europe/Helsinki';
end $$;

-- 2: viimeisen kierroksen takaraja. null = käytä portaita.
create or replace function booking.shift_offer_last_round_cap(p_role text, p_starts timestamptz, p_now timestamptz) returns timestamptz
language plpgsql stable security definer set search_path = '' as $$
declare v_before interval; v_min interval; v_created timestamptz; v_cap timestamptz;
begin
  v_before := booking.shift_offer_cfg_interval('last_round_before', p_role, null);
  if v_before is null or p_starts is null then return null; end if;
  v_min := booking.shift_offer_cfg_interval('last_round_min_lead', null, interval '21 days');
  select min(o.created_at) into v_created
    from public.shift_offers o join public.work_shifts w on w.id = o.shift_id
   where o.role_type = p_role and o.scenario = 'vacant_shift' and coalesce(o.window_starts_at, w.starts_at) = p_starts
     and o.status in ('active','paused','escalated');
  v_created := least(coalesce(v_created, p_now), p_now);
  if p_starts - v_created < v_min then return null; end if;
  v_cap := p_starts - v_before;
  if v_cap <= p_now + interval '1 hour' then return null; end if;
  return v_cap;
end $$;

-- e/f: onko vuoro tarjottavissa
create or replace function booking.shift_offer_is_vacant(p_shift uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare w public.work_shifts%rowtype; v_n int; v_free int;
begin
  select * into w from public.work_shifts x where x.id = p_shift;
  if not found or w.status <> 'active' then return false; end if;
  select count(*), count(*) filter (where exists (
           select 1 from public.staff_unavailability u
            where u.staff_id = a.staff_id and u.starts_at < w.ends_at and u.ends_at > w.starts_at))
    into v_n, v_free
    from public.shift_assignments a where a.shift_id = w.id and a.status in ('assigned','confirmed');
  if v_n = 0 then
    return w.staffing_status = 'open'
        or (w.staffing_status = 'uncertain' and booking.shift_offer_cfg_bool('offer_uncertain_shifts', false));
  end if;
  return v_n = v_free and booking.shift_offer_cfg_bool('unavailability_frees_shift', true);
end $$;

-- 5/6: hoitovaraukset päivälle (Europe/Helsinki)
create or replace function booking.shift_offer_day_treatments(p_date date) returns int
language sql stable security definer set search_path = '' as $$
  select count(distinct r.id)::int
    from booking.reservations r
   where r.status in ('pending','confirmed','completed')
     and (r.starts_at at time zone 'Europe/Helsinki')::date = p_date
     and (coalesce(r.therapist_missing, false)
          or exists (select 1 from booking.reservation_legs l where l.reservation_id = r.id and l.role = 'therapist'));
$$;

create or replace function booking.shift_offer_when(p_starts timestamptz, p_ends timestamptz) returns text
language sql stable security definer set search_path = '' as $$
  select (array['ma','ti','ke','to','pe','la','su'])[extract(isodow from (p_starts at time zone 'Europe/Helsinki')::date)]
      || ' ' || to_char(p_starts at time zone 'Europe/Helsinki', 'DD.MM.YYYY') || ' klo '
      || to_char(p_starts at time zone 'Europe/Helsinki', 'HH24:MI') || coalesce('–' || to_char(p_ends at time zone 'Europe/Helsinki', 'HH24:MI'), '');
$$;

create or replace function booking.shift_offer_cap_label(p_role text) returns text
language sql stable security definer set search_path = '' as $$
  select upper(left(l, 1)) || substr(l, 2) from (select coalesce(public.shift_offer_role_label(p_role), 'vuoro') l) x;
$$;

-- ---------------------------------------------------------------- oma sivu: pysyvä henkilökohtainen linkki
create or replace function booking._shift_staff_page_sig(p_payload text) returns text
language plpgsql stable security definer set search_path = '' as $$
declare v_key text := public.shift_offer_token_key();
begin
  if v_key is null or v_key = '' then return null; end if;
  return public.shift_offer_b64url(extensions.hmac(convert_to(p_payload, 'UTF8'), convert_to(v_key || ':staff_page', 'UTF8'), 'sha256'));
end $$;

create or replace function booking.shift_staff_page_token(p_staff uuid, p_issue boolean default true) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare t booking.shift_staff_page_tokens%rowtype; v_payload text; v_sig text;
begin
  if p_staff is null or not exists (select 1 from public.staff s where s.id = p_staff) then return null; end if;
  select * into t from booking.shift_staff_page_tokens x where x.staff_id = p_staff;
  if not found then
    if not p_issue then return null; end if;
    insert into booking.shift_staff_page_tokens (staff_id, nonce)
    values (p_staff, encode(extensions.gen_random_bytes(24), 'hex'))
    on conflict (staff_id) do nothing;
    select * into t from booking.shift_staff_page_tokens x where x.staff_id = p_staff;
  end if;
  if t.revoked_at is not null then return null; end if;
  v_payload := public.shift_offer_b64url(convert_to(jsonb_build_object('p', p_staff, 'n', t.nonce)::text, 'UTF8'));
  v_sig := booking._shift_staff_page_sig(v_payload);
  if v_sig is null then return null; end if;
  return v_payload || '.' || v_sig;
end $$;

create or replace function booking.shift_staff_page_url(p_staff uuid) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare v_tok text := booking.shift_staff_page_token(p_staff, true); v_base text;
begin
  if v_tok is null then return null; end if;
  v_base := coalesce(booking.shift_offer_cfg('staff_page_url') #>> '{}', 'https://joonasvaarala.github.io/saunotus-uusi/vuoro/oma/');
  return v_base || case when position('?' in v_base) > 0 then '&' else '?' end || 'token=' || v_tok;
end $$;

-- palauttaa staff_id tai null. Vakioaikavertailu, nonce ja peruutus tarkistetaan.
create or replace function booking._shift_staff_page_verify(p_token text) returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v_parts text[]; v_json jsonb; v_staff uuid; t booking.shift_staff_page_tokens%rowtype; v_sig text; v_b64 text;
begin
  if p_token is null or length(p_token) > 600 or p_token !~ '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$' then return null; end if;
  v_parts := string_to_array(p_token, '.');
  v_sig := booking._shift_staff_page_sig(v_parts[1]);
  if v_sig is null or not public.shift_offer_ct_eq(v_sig, v_parts[2]) then return null; end if;
  begin
    v_b64 := translate(v_parts[1], '-_', '+/');
    v_b64 := v_b64 || repeat('=', (4 - length(v_b64) % 4) % 4);
    v_json := convert_from(decode(v_b64, 'base64'), 'UTF8')::jsonb;
    v_staff := (v_json ->> 'p')::uuid;
  exception when others then return null;
  end;
  select * into t from booking.shift_staff_page_tokens x where x.staff_id = v_staff;
  if not found or t.revoked_at is not null or not public.shift_offer_ct_eq(t.nonce, coalesce(v_json ->> 'n', '')) then return null; end if;
  if not exists (select 1 from public.staff s where s.id = v_staff and s.active) then return null; end if;
  return v_staff;
end $$;
-- ---------------------------------------------------------------- uudet viestitekstit (allekirjoitus Tapio)
create or replace function booking.shift_offer_text153(p_kind text, p_staff uuid, p_offer uuid, p_extra jsonb default '{}'::jsonb) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  o public.shift_offers%rowtype; w public.work_shifts%rowtype; v_name text; v_when text; v_role text; v_label text;
  v_starts timestamptz; v_ends timestamptz; v_dl text; v_n int := coalesce((p_extra ->> 'bookings')::int, 0);
begin
  select st.name into v_name from public.staff st where st.id = p_staff;
  v_name := coalesce(split_part(btrim(v_name), ' ', 1), '');
  select * into o from public.shift_offers x where x.id = p_offer;
  select * into w from public.work_shifts x where x.id = o.shift_id;
  v_starts := coalesce(o.window_starts_at, w.starts_at); v_ends := coalesce(o.window_ends_at, w.ends_at);
  v_when := booking.shift_offer_when(v_starts, v_ends);
  v_role := booking.shift_offer_cap_label(o.role_type);
  v_label := coalesce(public.shift_offer_role_label(o.role_type), 'vuoro');
  v_dl := to_char((p_extra ->> 'deadline_at')::timestamptz at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI');
  if p_kind = 'round_reminder' then
    return 'Hei ' || v_name || E'.\nMuistutus: ' || v_label || ' ' || v_when || ' odottaa vielä vastaustasi. Vastaa viimeistään ' || coalesce(v_dl, 'pian') || E'.\n\n'
      || 'Hyväksy: ' || coalesce(public.shift_offer_link(o.id, p_staff, v_starts, 'accept'), '(linkki puuttuu)') || E'\n'
      || 'Kieltäydy: ' || coalesce(public.shift_offer_link(o.id, p_staff, v_starts, 'decline'), '(linkki puuttuu)') || E'\n\n–Tapio';
  elsif p_kind = 'already_taken' then
    return 'Hei ' || v_name || E'.\n' || v_role || ' ' || v_when || E' on jo mennyt toiselle. Kiitos, että vastasit.\n\n–Tapio';
  elsif p_kind = 'vacant' then
    return 'Hei ' || v_name || E'.\n' || v_role || ' ' || v_when || ' on ilman tekijää. Kukaan ei ottanut vuoroa tarjouskierroksilla. Vuoroon tarvitaan tekijä.'
      || E'\n\n–Tapio';
  elsif p_kind = 'vacant_reminder' then
    return 'Hei ' || v_name || E'.\nMuistutus: ' || v_label || ' ' || v_when || ' on yhä ilman tekijää.' || E'\n\n–Tapio';
  elsif p_kind = 'therapist_exhausted' then
    return 'Hei ' || v_name || E'.\nHoitajavuoro ' || v_when || ' ei mennyt kenellekään: kaikki kieltäytyivät tai kierrokset päättyivät. '
      || case when v_n > 0 then 'Päivälle on ' || v_n || ' hoitovarausta.' else 'Päivälle ei ole hoitovarauksia.' end || E'\n\n–Tapio';
  elsif p_kind = 'therapist_3wk' then
    return 'Hei ' || v_name || E'.\nHoitajavuoro ' || v_when || ' on yhä ilman hoitajaa, ja vuoroon on kolme viikkoa. Päivälle ei ole hoitovarauksia.' || E'\n\n–Tapio';
  elsif p_kind = 'therapist_warn' then
    return 'Hei ' || v_name || E'.\nHoitajavuoro ' || v_when || ' on yhä ilman hoitajaa. Vuoro suljetaan, jos siihen ei ilmoiteta ketään 6 h kuluessa.' || E'\n\n–Tapio';
  elsif p_kind = 'therapist_booked' then
    return 'Hei ' || v_name || E'.\nHoitajavuorolla ' || v_when || ' on ' || greatest(v_n, 1) || ' hoitovarausta, mutta hoitajaa ei ole. Vuoroon tarvitaan hoitaja.' || E'\n\n–Tapio';
  elsif p_kind = 'therapist_booked_reminder' then
    return 'Hei ' || v_name || E'.\nMuistutus: hoitajavuorolla ' || v_when || ' on ' || greatest(v_n, 1) || ' hoitovarausta, mutta hoitajaa ei ole.' || E'\n\n–Tapio';
  end if;
  return null;
end $$;

-- Lähettää yhden ilmoituksen (moottorin outbox, kind 'alert' tai annettu) ja kirjaa sen. Dedupe estää tuplat.
create or replace function booking.shift_offer_notice(p_offer uuid, p_staff uuid, p_stage text, p_subkind text, p_kind text,
  p_body text, p_dedupe text, p_recipient bigint default null, p_payload jsonb default '{}'::jsonb) returns bigint
language plpgsql volatile security definer set search_path = '' as $$
declare v_id bigint; o public.shift_offers%rowtype; w public.work_shifts%rowtype; v_date date;
begin
  if p_body is null or p_staff is null then return null; end if;
  if exists (select 1 from booking.shift_offer_notices n where n.dedupe_key = p_dedupe) then return null; end if;
  select * into o from public.shift_offers x where x.id = p_offer;
  select * into w from public.work_shifts x where x.id = o.shift_id;
  v_date := (coalesce(o.window_starts_at, w.starts_at) at time zone 'Europe/Helsinki')::date;
  v_id := public.shift_offer_queue_message(p_offer, p_recipient, p_staff, coalesce(p_kind, 'alert'), p_body, 'b153:' || p_dedupe);
  if v_id is not null then
    insert into booking.shift_offer_message_meta (message_id, subkind, digest_key, payload)
    values (v_id, p_subkind, p_staff::text || ':' || v_date::text, coalesce(p_payload, '{}'::jsonb))
    on conflict (message_id) do nothing;
  end if;
  insert into booking.shift_offer_notices (offer_id, shift_id, staff_id, stage, message_id, dedupe_key)
  values (p_offer, o.shift_id, p_staff, p_stage, v_id, p_dedupe)
  on conflict (dedupe_key) do nothing;
  return v_id;
end $$;

-- Sähköposti henkilökunnalle (esim. Otto). Vain kun shift_offer.email_enabled; Resendin mode off → skipped.
-- Allowlist (integration_config.resend.settings.test_recipients) ratkaisee testitilassa, saako viesti lähteä.
create or replace function booking.shift_offer_email(p_staff uuid, p_subject text, p_text text, p_dedupe text, p_link text default null) returns bigint
language plpgsql volatile security definer set search_path = '' as $$
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
end $$;

-- ---------------------------------------------------------------- 3: lämmittäjä / vastaanotto ilman tekijää
create or replace function booking.shift_offer_vacant_step(p_offer uuid, p_now timestamptz, p_dry boolean) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  o public.shift_offers%rowtype; w public.work_shifts%rowtype; v_starts timestamptz;
  v_first timestamptz; v_last timestamptz; v_n int; v_next timestamptz; v_due timestamptz; v_stage text; v_staff uuid;
  v_first_after interval := booking.shift_offer_cfg_interval('vacant_notice', 'first_reminder_after', interval '3 days');
  v_daily interval := booking.shift_offer_cfg_interval('vacant_notice', 'daily_from', interval '7 days');
  v_body text; v_sent int := 0; v_out bigint;
begin
  select * into o from public.shift_offers x where x.id = p_offer;
  select * into w from public.work_shifts x where x.id = o.shift_id;
  v_starts := coalesce(o.window_starts_at, w.starts_at);
  if v_starts <= p_now then
    if not p_dry then update public.shift_offers set status = 'escalated', next_action_at = null, updated_at = p_now where id = o.id; end if;
    return jsonb_build_object('action', 'vacant_over', 'offer_id', o.id);
  end if;
  select min(n.created_at), max(n.created_at), count(distinct n.stage) into v_first, v_last, v_n
    from booking.shift_offer_notices n where n.offer_id = o.id and n.stage like 'vacant%';
  if v_first is null then
    v_due := p_now; v_stage := 'vacant';
  else
    if v_n = 1 then v_next := least(v_first + v_first_after, v_starts - v_daily);
    elsif v_last < v_starts - v_daily then v_next := v_starts - v_daily;
    else v_next := v_last + interval '1 day';
    end if;
    v_next := greatest(v_next, v_last + interval '1 hour');
    v_due := v_next; v_stage := 'vacant_r' || v_n::text;
  end if;
  if v_due > p_now then
    if not p_dry then update public.shift_offers set status = 'escalated', next_action_at = case when v_due < v_starts then v_due end, updated_at = p_now where id = o.id; end if;
    return jsonb_build_object('action', 'vacant_scheduled', 'offer_id', o.id, 'due_at', v_due);
  end if;
  if p_dry then return jsonb_build_object('action', 'would_vacant_notice', 'offer_id', o.id, 'stage', v_stage); end if;
  foreach v_staff in array booking.shift_offer_cfg_uuids('vacant_notice', 'chat_staff_ids') loop
    v_body := booking.shift_offer_text153(case when v_stage = 'vacant' then 'vacant' else 'vacant_reminder' end, v_staff, o.id, '{}');
    if booking.shift_offer_notice(o.id, v_staff, v_stage, v_stage, 'alert', v_body, o.id::text || ':' || v_stage || ':' || v_staff::text) is not null then v_sent := v_sent + 1; end if;
  end loop;
  foreach v_staff in array booking.shift_offer_cfg_uuids('vacant_notice', 'email_staff_ids') loop
    v_body := booking.shift_offer_text153(case when v_stage = 'vacant' then 'vacant' else 'vacant_reminder' end, v_staff, o.id, '{}');
    v_out := booking.shift_offer_email(v_staff, booking.shift_offer_cap_label(o.role_type) || ' ilman tekijää: ' || booking.shift_offer_when(v_starts, coalesce(o.window_ends_at, w.ends_at)),
                                       v_body, o.id::text || ':' || v_stage || ':mail:' || v_staff::text);
    insert into booking.shift_offer_notices (offer_id, shift_id, staff_id, stage, email_outbox_id, dedupe_key)
    values (o.id, o.shift_id, v_staff, v_stage, v_out, o.id::text || ':' || v_stage || ':mail:' || v_staff::text)
    on conflict (dedupe_key) do nothing;
    if v_out is not null then v_sent := v_sent + 1; end if;
  end loop;
  -- notice-rivi syntyy myös, kun vastaanottajia ei ole (aikataulu etenee)
  insert into booking.shift_offer_notices (offer_id, shift_id, stage, dedupe_key, created_at)
  values (o.id, o.shift_id, v_stage, o.id::text || ':' || v_stage || ':mark', p_now) on conflict (dedupe_key) do nothing;
  update booking.shift_offer_notices set created_at = p_now where offer_id = o.id and stage = v_stage;
  -- seuraava hetki
  if v_stage = 'vacant' then v_next := least(p_now + v_first_after, v_starts - v_daily);
  elsif p_now < v_starts - v_daily then v_next := v_starts - v_daily;
  else v_next := p_now + interval '1 day';
  end if;
  v_next := greatest(v_next, p_now + interval '1 hour');
  update public.shift_offers set status = 'escalated', next_action_at = case when v_next < v_starts then v_next end, updated_at = p_now where id = o.id;
  return jsonb_build_object('action', 'vacant_notice', 'offer_id', o.id, 'stage', v_stage, 'sent', v_sent, 'next_at', case when v_next < v_starts then v_next end);
end $$;

-- ---------------------------------------------------------------- 5/6: hoitaja puuttuu
create or replace function booking.shift_offer_therapist_step(p_offer uuid, p_now timestamptz, p_dry boolean) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  o public.shift_offers%rowtype; w public.work_shifts%rowtype; s public.shift_offer_settings%rowtype;
  v_starts timestamptz; v_date date; v_book int; v_staff uuid; v_stage text; v_kind text; v_next timestamptz;
  v_3wk interval := booking.shift_offer_cfg_interval('therapist_notice', 'three_weeks', interval '21 days');
  v_warn_after interval := booking.shift_offer_cfg_interval('therapist_notice', 'warn_after', interval '3 days');
  v_close_after interval := booking.shift_offer_cfg_interval('therapist_notice', 'close_after', interval '6 hours');
  v_weekly interval := booking.shift_offer_cfg_interval('therapist_notice', 'weekly', interval '7 days');
  v_exh timestamptz; v_exh_book boolean; v_3 timestamptz; v_warn timestamptz; v_last_book timestamptz; v_nbook int;
  v_base timestamptz; v_close jsonb; v_sent int := 0;
begin
  select * into o from public.shift_offers x where x.id = p_offer;
  select * into w from public.work_shifts x where x.id = o.shift_id;
  select * into s from public.shift_offer_settings x where x.role_type = o.role_type;
  v_starts := coalesce(o.window_starts_at, w.starts_at);
  v_date := (v_starts at time zone 'Europe/Helsinki')::date;
  if v_starts <= p_now then
    if not p_dry then update public.shift_offers set next_action_at = null, updated_at = p_now where id = o.id; end if;
    return jsonb_build_object('action', 'therapist_over', 'offer_id', o.id);
  end if;
  v_book := booking.shift_offer_day_treatments(v_date);
  select min(n.created_at) filter (where n.stage = 'th_exhausted'),
         bool_or(n.stage = 'th_exhausted_booked'),
         min(n.created_at) filter (where n.stage = 'th_3wk'),
         min(n.created_at) filter (where n.stage = 'th_warn'),
         max(n.created_at) filter (where n.stage like 'th_booked%' or n.stage = 'th_exhausted_booked'),
         count(distinct n.stage) filter (where n.stage like 'th_booked%')
    into v_exh, v_exh_book, v_3, v_warn, v_last_book, v_nbook
    from booking.shift_offer_notices n where n.offer_id = o.id;
  v_stage := null;
  if v_exh is null then
    v_stage := 'th_exhausted'; v_kind := 'therapist_exhausted';
  elsif v_book > 0 then
    -- 6: varauksia on. Heti, sitten viikoittain, 3 vk ennen alkaen päivittäin. Ei sulkua.
    if v_last_book is null then
      v_stage := 'th_booked0'; v_kind := 'therapist_booked';
    else
      v_next := v_last_book + case when v_starts - v_last_book <= v_3wk then interval '1 day' else v_weekly end;
      if v_starts - v_3wk > v_last_book then v_next := least(v_next, greatest(v_starts - v_3wk, v_last_book + interval '1 hour')); end if;
      if v_next <= p_now then v_stage := 'th_booked' || (v_nbook + 1)::text; v_kind := 'therapist_booked_reminder'; end if;
    end if;
  else
    -- 5: ei varauksia.
    if v_starts - p_now > v_3wk then
      v_next := v_starts - v_3wk;
    elsif v_3 is null and v_exh < v_starts - v_3wk then
      v_stage := 'th_3wk'; v_kind := 'therapist_3wk';
    else
      v_base := coalesce(v_3, v_exh);
      if v_warn is null then
        v_next := greatest(least(v_base + v_warn_after, v_starts - v_close_after - interval '1 hour'), v_base);
        if v_next <= p_now then v_stage := 'th_warn'; v_kind := 'therapist_warn'; end if;
      else
        v_next := v_warn + v_close_after;
        if v_next <= p_now then
          if not coalesce(s.auto_close_enabled, false) then
            if not p_dry then update public.shift_offers set status = 'escalated', next_action_at = null, updated_at = p_now where id = o.id; end if;
            return jsonb_build_object('action', 'close_disabled', 'offer_id', o.id);
          end if;
          if p_dry then return jsonb_build_object('action', 'would_close', 'offer_id', o.id); end if;
          v_close := public.shift_offer_ensure_closure('hoidot', v_date, 'Tarjousmoottori: hoitajavuoro tyhjä, hoidot kiinni', false);
          update public.shift_offers set status = 'closed', next_action_at = null, updated_at = p_now, note = 'auto_close' where id = o.id;
          insert into booking.shift_offer_notices (offer_id, shift_id, stage, dedupe_key, created_at)
          values (o.id, o.shift_id, 'th_closed', o.id::text || ':th_closed', p_now) on conflict (dedupe_key) do nothing;
          return jsonb_build_object('action', 'closed', 'offer_id', o.id, 'closure', v_close);
        end if;
      end if;
    end if;
  end if;
  if v_stage is null then
    if not p_dry then update public.shift_offers set status = 'escalated', next_action_at = least(coalesce(v_next, v_starts), p_now + interval '1 hour'), updated_at = p_now where id = o.id; end if;
    return jsonb_build_object('action', 'therapist_waiting', 'offer_id', o.id, 'due_at', v_next);
  end if;
  if p_dry then return jsonb_build_object('action', 'would_therapist_notice', 'offer_id', o.id, 'stage', v_stage); end if;
  foreach v_staff in array booking.shift_offer_cfg_uuids('therapist_notice', 'staff_ids') loop
    if booking.shift_offer_notice(o.id, v_staff, v_stage, v_kind, 'alert',
         booking.shift_offer_text153(v_kind, v_staff, o.id, jsonb_build_object('bookings', v_book)),
         o.id::text || ':' || v_stage || ':' || v_staff::text, null, jsonb_build_object('bookings', v_book)) is not null then
      v_sent := v_sent + 1;
    end if;
  end loop;
  insert into booking.shift_offer_notices (offer_id, shift_id, stage, dedupe_key, created_at)
  values (o.id, o.shift_id, v_stage, o.id::text || ':' || v_stage || ':mark', p_now) on conflict (dedupe_key) do nothing;
  update booking.shift_offer_notices set created_at = p_now where offer_id = o.id and stage = v_stage;
  if v_stage = 'th_exhausted' and v_book > 0 then
    insert into booking.shift_offer_notices (offer_id, shift_id, stage, dedupe_key, created_at)
    values (o.id, o.shift_id, 'th_exhausted_booked', o.id::text || ':th_exhausted_booked', p_now) on conflict (dedupe_key) do nothing;
  end if;
  -- ajastus: tick ajaa hoitajan escaloidut tarjoukset joka kerta (uusi varaus → heti), next_action_at on vihje
  update public.shift_offers set status = 'escalated', next_action_at = least(v_starts, p_now + interval '1 hour'), updated_at = p_now where id = o.id;
  return jsonb_build_object('action', 'therapist_notice', 'offer_id', o.id, 'stage', v_stage, 'sent', v_sent, 'bookings', v_book);
end $$;
-- ---------------------------------------------------------------- 7: kierroksen loppumuistutus vastaamattomille
create or replace function booking.shift_offer_round_reminders(p_offer uuid, p_now timestamptz, p_dry boolean) returns int
language plpgsql volatile security definer set search_path = '' as $$
declare o public.shift_offers%rowtype; r record; v_before interval; v_n int := 0;
begin
  v_before := booking.shift_offer_cfg_interval('round_reminder_before', null, interval '12 hours');
  if v_before is null or v_before <= interval '0' then return 0; end if;
  select * into o from public.shift_offers x where x.id = p_offer;
  if not found or o.status not in ('active','paused') then return 0; end if;
  for r in
    select x.* from public.shift_offer_recipients x
     where x.offer_id = o.id and x.round_no = o.current_round_no and x.status = 'pending' and x.round_no < 100
       and x.sent_at is not null and x.deadline_at is not null and x.deadline_at > p_now
       and x.deadline_at - x.sent_at >= interval '2 hours'
       and p_now >= x.deadline_at - least(v_before, (x.deadline_at - x.sent_at) / 2)
       and not exists (select 1 from booking.shift_offer_notices n where n.dedupe_key = 'rr:' || x.id::text || ':' || x.round_no::text)
  loop
    if p_dry then v_n := v_n + 1; continue; end if;
    perform booking.shift_offer_notice(o.id, r.staff_id, 'round_reminder', 'round_reminder', 'reminder',
      booking.shift_offer_text153('round_reminder', r.staff_id, o.id, jsonb_build_object('deadline_at', r.deadline_at)),
      'rr:' || r.id::text || ':' || r.round_no::text, r.id, jsonb_build_object('deadline_at', r.deadline_at));
    update public.shift_offer_recipients set reminder_sent_at = p_now where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- ---------------------------------------------------------------- d: vastausaika lähetyshetkestä
create or replace function booking.shift_offer_extend_deadline(p_recipient bigint, p_at timestamptz default now()) returns timestamptz
language plpgsql volatile security definer set search_path = '' as $$
declare r public.shift_offer_recipients%rowtype; o public.shift_offers%rowtype; w public.work_shifts%rowtype;
        v_max int; v_last boolean; v_dl timestamptz; v_date date; v_starts timestamptz;
begin
  select * into r from public.shift_offer_recipients x where x.id = p_recipient;
  if not found or r.status <> 'pending' or r.round_no >= 100 or r.deadline_at is null then return null; end if;
  select * into o from public.shift_offers x where x.id = r.offer_id;
  if o.status not in ('active','paused') then return r.deadline_at; end if;
  select * into w from public.work_shifts x where x.id = o.shift_id;
  v_starts := coalesce(o.window_starts_at, w.starts_at);
  v_date := (v_starts at time zone 'Europe/Helsinki')::date;
  select max(rnd.round_no) into v_max from public.shift_offer_rounds rnd
   where rnd.role_type = o.role_type and rnd.scenario = o.scenario and extract(isodow from v_date)::smallint = any (rnd.weekdays)
     and v_date >= rnd.valid_from and (rnd.valid_to is null or v_date <= rnd.valid_to);
  v_last := r.round_kind = 'all' or r.round_no >= coalesce(v_max, r.round_no);
  v_dl := public.shift_offer_round_deadline(o.role_type, v_starts, p_at, r.round_kind, v_last);
  if v_dl is null or v_dl <= r.deadline_at then return r.deadline_at; end if;
  update public.shift_offer_recipients set deadline_at = v_dl where id = r.id;
  if o.current_round_no = r.round_no then
    update public.shift_offers set next_action_at = greatest(coalesce(next_action_at, v_dl), v_dl), updated_at = p_at where id = o.id;
  end if;
  return v_dl;
end $$;

-- ---------------------------------------------------------------- 4: saman päivän viestit yhdeksi
create or replace function booking.shift_offer_merge_same_day(p_now timestamptz default now()) returns int
language plpgsql volatile security definer set search_path = '' as $$
declare g record; v_body text; v_id bigint; v_name text; v_link text; v_items text; v_n int := 0; v_first uuid;
begin
  for g in
    select m.staff_id, (coalesce(o.window_starts_at, w.starts_at) at time zone 'Europe/Helsinki')::date as d,
           array_agg(m.id order by coalesce(o.window_starts_at, w.starts_at), m.id) as ids,
           array_agg(m.recipient_id order by m.id) filter (where m.recipient_id is not null) as recs
      from public.shift_offer_messages m
      join public.shift_offers o on o.id = m.offer_id
      join public.work_shifts w on w.id = o.shift_id
      left join booking.shift_offer_message_meta mm on mm.message_id = m.id
     where m.status = 'queued' and m.wamid is null and m.next_attempt_at <= p_now
       and m.channel in ('whatsapp','email')
       and m.kind in ('offer','reminder','filled')
       and coalesce(mm.subkind, '') <> 'day_digest'
       and not public.shift_offer_is_bot_staff(m.staff_id)
     group by m.staff_id, 2
    having count(distinct m.offer_id) > 1
  loop
    select split_part(btrim(st.name), ' ', 1) into v_name from public.staff st where st.id = g.staff_id;
    select string_agg(x.line, '; ' order by x.st, x.ord) into v_items from (
      select distinct on (m.offer_id) k.ord, coalesce(o.window_starts_at, w.starts_at) as st, booking.shift_offer_cap_label(o.role_type) || ' ' || booking.shift_offer_when(coalesce(o.window_starts_at, w.starts_at), coalesce(o.window_ends_at, w.ends_at))
             || case when m.kind = 'filled' then ' (jo mennyt)'
                     when r.deadline_at is not null then ' (vastaa viimeistään ' || to_char(r.deadline_at at time zone 'Europe/Helsinki', 'DD.MM. HH24:MI') || ')'
                     else '' end as line
        from unnest(g.ids) with ordinality k(id, ord)
        join public.shift_offer_messages m on m.id = k.id
        join public.shift_offers o on o.id = m.offer_id
        join public.work_shifts w on w.id = o.shift_id
        left join public.shift_offer_recipients r on r.id = m.recipient_id
       order by m.offer_id, k.ord desc) x;
    v_link := booking.shift_staff_page_url(g.staff_id);
    v_body := 'Hei ' || coalesce(v_name, '') || E'.\nSinulle on useampi vuoroasia ' || to_char(g.d, 'DD.MM.YYYY') || ': ' || v_items
           || E'.\nVastaa omalla sivullasi: ' || coalesce(v_link, '(linkki puuttuu)') || E'\n\n–Tapio';
    select m.offer_id into v_first from public.shift_offer_messages m where m.id = g.ids[1];
    v_id := public.shift_offer_queue_message(v_first, null, g.staff_id, 'alert', v_body,
              'b153:digest:' || g.staff_id::text || ':' || g.d::text || ':' || g.ids[1]::text);
    if v_id is null then continue; end if;
    insert into booking.shift_offer_message_meta (message_id, subkind, digest_key, payload)
    values (v_id, 'day_digest', g.staff_id::text || ':' || g.d::text,
            jsonb_build_object('merged_ids', to_jsonb(g.ids), 'recipient_ids', to_jsonb(coalesce(g.recs, '{}')), 'date', g.d,
                               'date_label', to_char(g.d, 'DD.MM.YYYY'), 'items', v_items))
    on conflict (message_id) do nothing;
    update public.shift_offer_messages set status = 'skipped', last_error = 'merged:' || v_id::text, locked_at = null
     where id = any (g.ids) and status = 'queued';
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- ---------------------------------------------------------------- sähköpostikanava (WhatsApp-kelvoton henkilö)
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
-- ---------------------------------------------------------------- 8: oma sivu (edge: GET /api/my, POST /api/my/respond)
-- Näyttää vain token-haltijan omat tarjoukset. Ei muiden nimiä eikä voittajan tietoja.
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

create or replace function booking.shift_staff_page_respond(p_token text, p_offer uuid, p_response text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_staff uuid; v jsonb;
begin
  v_staff := booking._shift_staff_page_verify(p_token);
  if v_staff is null then return jsonb_build_object('ok', false, 'result', 'bad_token'); end if;
  if p_response is null or p_response not in ('accept','decline') then return jsonb_build_object('ok', false, 'result', 'bad_response'); end if;
  if p_offer is null or not exists (select 1 from public.shift_offer_recipients r where r.offer_id = p_offer and r.staff_id = v_staff and r.round_no < 100) then
    return jsonb_build_object('ok', false, 'result', 'not_owner');
  end if;
  v := public.shift_offer_respond(p_offer, v_staff, p_response, null, true, 'staff_page');
  if v->>'result' = 'already_filled' then v := jsonb_build_object('result', 'already_taken'); end if;
  -- ei palauteta voittajan tunnistetta eikä muiden tietoja
  v := v - 'winner_staff_id' - 'notify_filled_staff_ids' - 'assignment' - 'accepted_at';
  return jsonb_build_object('ok', v->>'result' in ('accepted','declined','already_yours'), 'result', v->>'result') || jsonb_build_object('page', booking.shift_staff_page(p_token));
end $$;

-- ---------------------------------------------------------------- tervetuloviesti ja suostumus
-- Edge kutsuu saapuvan viestin tallennuksen jälkeen. Kirjaa ensimmäisen viestin suostumukseksi aina (tunnettu henkilö).
-- Palauttaa {send:true, body, to}, kun tervetuloviesti saa lähteä: asetus päällä, tämä on henkilön ensimmäinen viesti,
-- viesti on 24 h ikkunassa, tervetuloviestiä ei ole lähetetty, ei bottikanavan henkilö. Tuntematon numero → send:false.
create or replace function booking.shift_staff_welcome(p_message_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
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
end $$;

-- ---------------------------------------------------------------- hallinta (staff.manage)
create or replace function booking.admin_shift_staff_overview() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform booking._require_permission('staff.manage');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'staff_id', s.id, 'name', s.name, 'active', s.active, 'whatsapp_enabled', coalesce(s.whatsapp_enabled, false),
      'bot_channel', public.shift_offer_is_bot_staff(s.id), 'has_phone', public.shift_offer_phone_e164(s.phone_e164) is not null,
      'has_email', nullif(btrim(s.email), '') is not null,
      'link_status', case when t.staff_id is null then 'none' when t.revoked_at is not null then 'revoked' else 'active' end,
      'link_created_at', coalesce(t.rotated_at, t.created_at), 'link_last_used_at', t.last_used_at,
      'consent_at', c.first_inbound_at, 'welcome_sent_at', c.welcome_sent_at,
      'suggest_whatsapp', c.staff_id is not null and not coalesce(s.whatsapp_enabled, false) and c.suggestion_dismissed_at is null
                          and not public.shift_offer_is_bot_staff(s.id)
    ) order by s.active desc, s.name)
    from public.staff s
    left join booking.shift_staff_page_tokens t on t.staff_id = s.id
    left join booking.shift_staff_whatsapp_consent c on c.staff_id = s.id
    where s.active or t.staff_id is not null), '[]'::jsonb);
end $$;

-- p_action: 'issue' (näytä / luo linkki), 'renew' (uusi linkki, vanha lakkaa toimimasta), 'revoke' (linkki pois),
-- 'dismiss_suggestion' (piilota WhatsApp-ehdotus). whatsapp_enabled-kenttää ei muuteta täältä.
create or replace function booking.admin_shift_staff_link(p_staff uuid, p_action text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform booking._require_permission('staff.manage');
  if p_staff is null or not exists (select 1 from public.staff s where s.id = p_staff) then
    raise exception 'Henkilöä ei löytynyt' using errcode = 'P0002';
  end if;
  if p_action = 'issue' then
    update booking.shift_staff_page_tokens set revoked_at = null, nonce = encode(extensions.gen_random_bytes(24), 'hex'), version = version + 1, rotated_at = now()
     where staff_id = p_staff and revoked_at is not null;
  elsif p_action = 'renew' then
    insert into booking.shift_staff_page_tokens (staff_id, nonce) values (p_staff, encode(extensions.gen_random_bytes(24), 'hex'))
    on conflict (staff_id) do update set nonce = excluded.nonce, version = booking.shift_staff_page_tokens.version + 1, rotated_at = now(), revoked_at = null;
  elsif p_action = 'revoke' then
    update booking.shift_staff_page_tokens set revoked_at = now() where staff_id = p_staff and revoked_at is null;
    return jsonb_build_object('ok', true, 'link_status', 'revoked');
  elsif p_action = 'dismiss_suggestion' then
    update booking.shift_staff_whatsapp_consent set suggestion_dismissed_at = now() where staff_id = p_staff;
    return jsonb_build_object('ok', true);
  else
    raise exception 'Tuntematon toiminto %', p_action using errcode = '22023';
  end if;
  return jsonb_build_object('ok', true, 'link_status', 'active', 'url', booking.shift_staff_page_url(p_staff));
end $$;
-- ---------------------------------------------------------------- korvatut public-moottorin funktiot

CREATE OR REPLACE FUNCTION public.shift_offer_round_deadline(p_role text, p_starts timestamp with time zone, p_now timestamp with time zone, p_kind text, p_last boolean)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  t record; s public.shift_offer_settings%rowtype; v_dl timestamptz; v_wait interval; v_cap timestamptz;
begin
  select * into s from public.shift_offer_settings x where x.role_type = p_role;
  select * into t from public.shift_offer_wait(p_role, p_starts, p_now, p_last) w;
  if t.direct_to_all or t.deadline_at is null then
    v_wait := least(coalesce(s.all_round_wait, interval '6 hours'), greatest(p_starts - p_now, interval '1 hour'));
    v_dl := public.shift_add_active_time(p_now, v_wait, p_role);
  else
    v_dl := t.deadline_at;
  end if;
  if p_kind = 'rotation' then
    v_dl := least(v_dl, public.shift_add_active_time(p_now, coalesce(s.group_max_wait, interval '24 hours'), p_role));
  end if;
  -- booking_153 sääntö 2: viimeinen kierros päättyy roolin takarajaan (14 / 21 pv ennen); aiemmat kierrokset puoliväliin.
  v_cap := booking.shift_offer_last_round_cap(p_role, p_starts, p_now);
  if v_cap is not null then
    if p_last then v_dl := v_cap; else v_dl := least(v_dl, p_now + (v_cap - p_now) / 2); end if;
  end if;
  return least(v_dl, p_starts);
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_respond(p_offer_id uuid, p_staff_id uuid, p_response text, p_snooze_until timestamp with time zone DEFAULT NULL::timestamp with time zone, p_apply boolean DEFAULT true, p_actor text DEFAULT 'tyovuoro-tapio'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o   public.shift_offers%rowtype;
  r   public.shift_offer_recipients%rowtype;
  s   public.shift_offer_settings%rowtype;
  v_starts timestamptz; v_until timestamptz; v_res jsonb; v_notify jsonb; v_open int; v_other uuid;
begin
  if p_response is null or p_response not in ('accept','decline','snooze') then
    raise exception 'Tuntematon vastaus % (accept, decline, snooze)', p_response using errcode = '22023';
  end if;
  select * into o from public.shift_offers x where x.id = p_offer_id for update;
  if not found then raise exception 'Tarjousta ei löytynyt' using errcode = 'P0002'; end if;
  select * into r from public.shift_offer_recipients x where x.offer_id = p_offer_id and x.staff_id = p_staff_id for update;
  if not found or r.status in ('queued','withdrawn') then
    return jsonb_build_object('result', 'not_recipient');
  end if;

  if o.status = 'filled' then
    if o.accepted_staff_id = p_staff_id then return jsonb_build_object('result', 'already_yours'); end if;
    if r.status in ('pending','snoozed','declined') and p_response = 'accept' then
      update public.shift_offer_recipients set status = 'filled_other', snooze_until = null, responded_at = coalesce(responded_at, now())
       where id = r.id;
    end if;
    -- booking_153 sääntö 1: erillinen "vuoro on jo mennyt" -viesti vain asetuksella (oletus pois), kerran
    if p_response = 'accept' and booking.shift_offer_cfg_bool('already_taken_message', false) then
      perform booking.shift_offer_notice(o.id, p_staff_id, 'already_taken', 'already_taken', 'filled',
        booking.shift_offer_text153('already_taken', p_staff_id, o.id, '{}'), 'at:' || o.id::text || ':' || p_staff_id::text);
    end if;
    return jsonb_build_object('result', 'already_filled', 'winner_staff_id', o.accepted_staff_id, 'accepted_at', o.accepted_at);
  end if;
  if o.status not in ('active','paused','escalated') then
    return jsonb_build_object('result', 'offer_closed', 'offer_status', o.status);
  end if;

  if p_response = 'accept' then
    if r.status not in ('pending','snoozed','declined') then
      return jsonb_build_object('result', 'invalid_state', 'recipient_status', r.status);
    end if;
    update public.shift_offer_recipients set status = 'accepted', responded_at = now(), snooze_until = null where id = r.id;
    update public.shift_offer_recipients set status = case when sent_at is null then 'withdrawn' else 'filled_other' end,
           snooze_until = null
     where offer_id = o.id and id <> r.id and status in ('queued','pending','snoozed');
    -- booking_153 sääntö 1: muille ei lähetetä "täytetty"-viestiä
    v_notify := '[]'::jsonb;
    update public.shift_offers set status = 'filled', accepted_staff_id = p_staff_id, accepted_recipient_id = r.id,
           accepted_at = now(), next_action_at = null, updated_at = now() where id = o.id;
    if p_apply and o.scenario = 'vacant_shift' then
      begin
        v_res := public.shift_apply_change('assign', o.shift_id, p_staff_id, null, null, null, 'offer_engine', p_actor, p_staff_id,
                                           'Tarjous ' || o.id::text, null);
        update public.shift_offers set assignment_result = v_res where id = o.id;
        -- booking_153 f: poissaolon vuoksi vapautunut vuoro: poissaolevat pois vuorosta
        if booking.shift_offer_cfg_bool('unavailability_frees_shift', true) then
          for v_other in
            select a.staff_id from public.shift_assignments a join public.work_shifts w on w.id = a.shift_id
             where a.shift_id = o.shift_id and a.staff_id <> p_staff_id and a.status in ('assigned','confirmed')
               and exists (select 1 from public.staff_unavailability u where u.staff_id = a.staff_id and u.starts_at < w.ends_at and u.ends_at > w.starts_at)
          loop
            perform public.shift_apply_change('unassign', o.shift_id, v_other, null, null, null, 'offer_engine', p_actor, p_staff_id,
                                              'Poissaolo, tarjous ' || o.id::text, null);
          end loop;
        end if;
      exception when others then
        update public.shift_offers set assignment_error = sqlstate || ': ' || sqlerrm where id = o.id;
        v_res := jsonb_build_object('error', sqlstate || ': ' || sqlerrm);
      end;
    end if;
    return jsonb_build_object('result', 'accepted', 'offer_id', o.id, 'shift_id', o.shift_id, 'staff_id', p_staff_id,
                              'notify_filled_staff_ids', v_notify, 'assignment', v_res);
  end if;

  if p_response = 'decline' then
    if r.status not in ('pending','snoozed') then
      return jsonb_build_object('result', 'invalid_state', 'recipient_status', r.status);
    end if;
    update public.shift_offer_recipients set status = 'declined', responded_at = now(), snooze_until = null where id = r.id;
    select count(*) into v_open from public.shift_offer_recipients x
     where x.offer_id = o.id and x.round_no = o.current_round_no and x.status in ('pending','snoozed');
    update public.shift_offers set updated_at = now() where id = o.id;
    return jsonb_build_object('result', 'declined', 'round_all_declined', v_open = 0,
      'any_open', exists (select 1 from public.shift_offer_recipients x where x.offer_id = o.id and x.status in ('pending','snoozed')));
  end if;

  -- snooze ("Palaan asiaan <pvm>")
  select * into s from public.shift_offer_settings x where x.role_type = o.role_type;
  if not (coalesce(s.snooze_any_recipient, false) or p_staff_id = any (coalesce(s.snooze_staff_ids, '{}'))) then
    return jsonb_build_object('result', 'snooze_not_allowed', 'reason', 'staff');
  end if;
  if r.status not in ('pending','snoozed') or p_snooze_until is null or p_snooze_until <= now() then
    return jsonb_build_object('result', 'invalid_state', 'recipient_status', r.status);
  end if;
  select coalesce(o.window_starts_at, w.starts_at) into v_starts from public.work_shifts w where w.id = o.shift_id;
  v_until := least(p_snooze_until, v_starts - s.snooze_min_left);
  if v_until <= now() then return jsonb_build_object('result', 'snooze_not_allowed', 'reason', 'too_close'); end if;
  update public.shift_offer_recipients set status = 'snoozed', snooze_until = v_until, responded_at = now() where id = r.id;
  return jsonb_build_object('result', 'snoozed', 'snooze_until', v_until, 'shortened', v_until < p_snooze_until);
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_compose(p_kind text, p_staff uuid, p_offer uuid, p_role text, p_starts timestamp with time zone, p_ends timestamp with time zone, p_deadline timestamp with time zone, p_ask_no integer DEFAULT NULL::integer)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    return 'Hei ' || coalesce(v_name, '') || E'.\n' || upper(left(v_label, 1)) || substr(v_label, 2) || ' ' || v_when || ' on yhä ilman tekijää (kysymys ' || coalesce(p_ask_no, 1)::text || '/' || coalesce(s.exhausted_ask_count, 3)::text || E'). Mitä tehdään?\n\nHyväksy vuoro: ' || coalesce(v_acc, '(linkki puuttuu)') || E'\nKieltäydy: ' || coalesce(v_dec, '(linkki puuttuu)') || E'\n\n–Tapio';
  elsif p_kind = 'reminder' then
    return 'Hei ' || coalesce(v_name, '') || E'.\nMuistutus: vapaa ' || v_label || ' ' || v_when || E'. Palasit asiaan tänään.\nVastaa viimeistään ' || coalesce(to_char(p_deadline at time zone v_tz, 'DD.MM.YYYY HH24:MI'), 'pian') || E'.\n\nHyväksy: ' || coalesce(v_acc, '(linkki puuttuu)') || E'\nKieltäydy: ' || coalesce(v_dec, '(linkki puuttuu)') || E'\n\n–Tapio';
  end if;
  return 'Hei ' || coalesce(v_name, '') || E'.\nVapaa ' || v_label || ' ' || v_when || E'.\nVastaa viimeistään ' || coalesce(to_char(p_deadline at time zone v_tz, 'DD.MM.YYYY HH24:MI'), 'pian') || E'.\n\nHyväksy: ' || coalesce(v_acc, '(linkki puuttuu)') || E'\nKieltäydy: ' || coalesce(v_dec, '(linkki puuttuu)')
    || case when v_snz is not null then E'\nPalaan asiaan: ' || v_snz else '' end
    || E'\n\n–Tapio';
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_on_exhausted(p_offer uuid, p_now timestamp with time zone, p_dry boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o public.shift_offers%rowtype;
  w public.work_shifts%rowtype;
  s public.shift_offer_settings%rowtype;
  st record; v_last timestamptz; v_date date; v_id bigint; v_close jsonb; v_staff uuid;
begin
  select * into o from public.shift_offers x where x.id = p_offer;
  select * into w from public.work_shifts x where x.id = o.shift_id;
  select * into s from public.shift_offer_settings x where x.role_type = o.role_type;
  -- booking_153: lämmittäjä / vastaanotto → sääntö 3, hoitaja → säännöt 5–6 (korvaavat 3 kysymyksen kierron)
  if o.role_type in ('heater','reception') then
    return booking.shift_offer_vacant_step(o.id, p_now, p_dry);
  elsif o.role_type = 'therapist' then
    return booking.shift_offer_therapist_step(o.id, p_now, p_dry);
  end if;
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
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_issue_recipients(p_offer uuid, p_role text, p_starts timestamp with time zone, p_ends timestamp with time zone, p_now timestamp with time zone, p_round integer, p_kind text, p_staff uuid[], p_names text[], p_sorts integer[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  i int; v_dl timestamptz; v_last boolean; v_id bigint; v_n int := 0; v_max int;
  v_tz text; v_date date;
begin
  select s.timezone into v_tz from public.shift_offer_settings s where s.role_type = p_role;
  if v_tz is null then
    raise exception 'Roolille % ei ole shift_offer_settings-riviä', p_role using errcode = 'P0002';
  end if;
  v_date := (p_starts at time zone v_tz)::date;
  select max(rnd.round_no) into v_max from public.shift_offer_rounds rnd
    join public.shift_offers o on o.id = p_offer
   where rnd.role_type = o.role_type and rnd.scenario = o.scenario
     and extract(isodow from v_date)::smallint = any (rnd.weekdays)
     and v_date >= rnd.valid_from and (rnd.valid_to is null or v_date <= rnd.valid_to);
  v_last := p_kind = 'all' or p_round >= coalesce(v_max, p_round);
  v_dl := public.shift_offer_round_deadline(p_role, p_starts, p_now, p_kind, v_last);
  for i in 1 .. coalesce(cardinality(p_staff), 0) loop
    v_id := null;
    -- booking_153 sääntö 8: saman päivän saman roolin vuorosta kieltäytynyt ei saa uusia tarjouksia
    if exists (select 1 from public.shift_offer_recipients x2 join public.shift_offers o2 on o2.id = x2.offer_id
                 join public.work_shifts w2 on w2.id = o2.shift_id
                where x2.staff_id = p_staff[i] and x2.status = 'declined' and o2.id <> p_offer and o2.role_type = p_role
                  and (coalesce(o2.window_starts_at, w2.starts_at) at time zone 'Europe/Helsinki')::date = (p_starts at time zone 'Europe/Helsinki')::date) then
      continue;
    end if;
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

CREATE OR REPLACE FUNCTION public.shift_offer_tick(p_dry_run boolean DEFAULT false, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
     where ws.status = 'active' and ws.starts_at > v_now and ws.starts_at <= v_now + s.start_before
       and booking.shift_offer_is_vacant(ws.id)
     order by ws.starts_at
  loop
    v_row := public.shift_offer_ensure(w.id, v_now, v_dry);
    if v_row->>'action' not in ('skip', 'waiting') then v_actions := v_actions || v_row; end if;
  end loop;
  -- myös avoimet tarjoukset, joiden vuoro ei enää ole haussa (esim. ikkuna), mutta kierros on erääntynyt
  for w in
    select o.shift_id as id from public.shift_offers o
     where o.status in ('active','paused','escalated')
       and (o.next_action_at is null or o.next_action_at <= v_now or (o.status = 'escalated' and o.role_type = 'therapist')
            or (o.status = 'active' and exists (select 1 from public.shift_offer_recipients x where x.offer_id = o.id and x.status = 'pending')))
       and not exists (select 1 from jsonb_array_elements(v_actions) a where a->>'shift_id' = o.shift_id::text)
  loop
    v_row := public.shift_offer_ensure(w.id, v_now, v_dry);
    if v_row->>'action' not in ('skip', 'waiting') then v_actions := v_actions || v_row; end if;
  end loop;
  return jsonb_build_object('ok', true, 'dry_run', v_dry, 'now', v_now, 'cancel', v_cancel, 'service_closures', v_svc, 'actions', v_actions);
end $function$;

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
-- ---------------------------------------------------------------- oikeudet
do $$
declare f text;
begin
  foreach f in array array[
    'booking.shift_offer_cfg(text)', 'booking.shift_offer_cfg_bool(text, boolean)', 'booking.shift_offer_cfg_interval(text, text, interval)',
    'booking.shift_offer_cfg_uuids(text, text)', 'booking.shift_offer_wa_open(timestamptz)', 'booking.shift_offer_wa_next_open(timestamptz)',
    'booking.shift_offer_last_round_cap(text, timestamptz, timestamptz)', 'booking.shift_offer_is_vacant(uuid)', 'booking.shift_offer_day_treatments(date)',
    'booking.shift_offer_when(timestamptz, timestamptz)', 'booking.shift_offer_cap_label(text)', 'booking._shift_staff_page_sig(text)',
    'booking.shift_staff_page_token(uuid, boolean)', 'booking.shift_staff_page_url(uuid)', 'booking._shift_staff_page_verify(text)',
    'booking.shift_offer_text153(text, uuid, uuid, jsonb)', 'booking.shift_offer_notice(uuid, uuid, text, text, text, text, text, bigint, jsonb)',
    'booking.shift_offer_email(uuid, text, text, text, text)', 'booking.shift_offer_vacant_step(uuid, timestamptz, boolean)',
    'booking.shift_offer_therapist_step(uuid, timestamptz, boolean)', 'booking.shift_offer_round_reminders(uuid, timestamptz, boolean)',
    'booking.shift_offer_extend_deadline(bigint, timestamptz)', 'booking.shift_offer_merge_same_day(timestamptz)', 'booking.shift_offer_email_drain(integer)',
    'booking.shift_staff_page(text)', 'booking.shift_staff_page_respond(text, uuid, text)', 'booking.shift_staff_welcome(uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
revoke all on function booking.admin_shift_staff_overview() from public, anon, authenticated;
grant execute on function booking.admin_shift_staff_overview() to authenticated, service_role;
revoke all on function booking.admin_shift_staff_link(uuid, text) from public, anon, authenticated;
grant execute on function booking.admin_shift_staff_link(uuid, text) to authenticated, service_role;
