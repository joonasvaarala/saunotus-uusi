-- ============================================================
-- booking_72_business_quotes: yritysten tarjouspyyntö (työntekijä- / työhyvinvointipäivä).
--  * Taulu booking.business_quote_requests. Ei uutta maksua eikä varausta.
--  * Anon luo yhden rivin vain RPC:llä public_create_business_quote. Rate limit + honeypot.
--    Virheet palautetaan jsonbina (ei poikkeusta), jotta rate limit -kirjaus säilyy.
--  * Lukeminen: vain admin ja manager (RLS + quotes.manage). Staff ei näe.
--  * Sähköposti: email_outbox-rivit business_quote_ack (asiakas, allekirjoitus Tapio mallissa) ja
--    business_quote_notify (asetus business_quote_notify_email, oletus savusauna@saunotus.fi).
--    Lähetyslogiikkaa ei muuteta: send-emails kunnioittaa dry_runia. email_outbox_claimia ei kirjoiteta uusiksi
--    (vastaanottaja on payload.to_email / to_name, kuten booking_50 jo lukee).
-- Rollback: rollbacks/20261018193000_booking_72_ROLLBACK.sql (aja ennen 71:n purkua).
-- ============================================================
set local lock_timeout = '5s';

create table booking.business_quote_requests (
  id               bigint generated always as identity primary key,
  status           text not null default 'new' check (status in ('new', 'handled', 'offered', 'closed')),
  company_name     text not null check (char_length(company_name) between 2 and 160),
  contact_name     text not null check (char_length(contact_name) between 2 and 120),
  email            text not null check (char_length(email) between 3 and 254),
  phone            text not null check (char_length(phone) between 6 and 30),
  preferred_when   text not null check (char_length(preferred_when) between 2 and 160),
  persons          integer not null check (persons between 1 and 300),
  offerings        text[] not null check (
                     cardinality(offerings) >= 1
                     and offerings <@ array['ritual','forest_yoga','campfire_meal','sauna','vihta_workshop','other']::text[]
                   ),
  offering_other   text check (offering_other is null or char_length(offering_other) between 2 and 200),
  message          text check (message is null or char_length(message) <= 2000),
  locale           text not null default 'fi' check (locale in ('fi', 'en')),
  privacy_accepted boolean not null default false check (privacy_accepted),
  created_at       timestamptz not null default now(),
  handled_by       uuid,
  handled_at       timestamptz,
  admin_note       text check (admin_note is null or char_length(admin_note) <= 2000),
  check (not ('other' = any (offerings)) or offering_other is not null)
);
create index business_quote_requests_status_idx on booking.business_quote_requests(status, created_at desc);
comment on table booking.business_quote_requests is
  'Yrityksen tarjouspyyntö (työntekijäpäivä). Luonti vain public_create_business_quote. Lukee admin/manager.';

select booking._add_audit('booking.business_quote_requests'::regclass);

alter table booking.business_quote_requests enable row level security;
revoke all on booking.business_quote_requests from public, anon, authenticated;
revoke all on sequence booking.business_quote_requests_id_seq from public, anon, authenticated;
grant select on booking.business_quote_requests to authenticated;
create policy quotes_staff_read on booking.business_quote_requests
  for select to authenticated
  using (booking.is_staff() and booking.current_staff_role() in ('admin', 'manager'));

insert into booking.role_permissions(role_code, permission) values
  ('admin', 'quotes.manage'),
  ('manager', 'quotes.manage')
on conflict do nothing;

insert into booking.settings(key, value, description, is_public) values
  ('business_quote_rl_ip_per_10min', '5'::jsonb, 'Tarjouspyyntö: enintään näin monta yritystä samasta IP:stä 10 minuutissa', false),
  ('business_quote_rl_email_per_hour', '3'::jsonb, 'Tarjouspyyntö: enintään näin monta yritystä samasta sähköpostista tunnissa', false),
  ('business_quote_notify_email', to_jsonb('savusauna@saunotus.fi'::text), 'Tarjouspyynnön sisäinen ilmoitus. Tyhjä = ei ilmoitusta. Ei julkinen.', false),
  ('business_quote_notify_name', to_jsonb('Joonas'::text), 'Sisäisen ilmoituksen vastaanottajan nimi (tervehdys). Ei julkinen.', false)
on conflict (key) do nothing;

alter table booking.email_outbox drop constraint email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check
  check (kind in ('order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change',
                  'gift_card_buyer', 'gift_card_recipient', 'voucher_claim_received', 'voucher_claim_problem',
                  'business_quote_ack', 'business_quote_notify'));

create or replace function booking.public_create_business_quote(
  p_company_name text,
  p_contact_name text,
  p_email text,
  p_phone text,
  p_preferred_when text,
  p_persons integer,
  p_offerings jsonb default '[]'::jsonb,
  p_offering_other text default null,
  p_message text default null,
  p_locale text default 'fi',
  p_privacy boolean default false,
  p_company_website text default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_company text := btrim(coalesce(p_company_name, ''));
  v_contact text := btrim(coalesce(p_contact_name, ''));
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_phone text := btrim(coalesce(p_phone, ''));
  v_when text := btrim(coalesce(p_preferred_when, ''));
  v_other text := btrim(coalesce(p_offering_other, ''));
  v_message text := nullif(btrim(coalesce(p_message, '')), '');
  v_locale text := case when lower(btrim(coalesce(p_locale, ''))) = 'en' then 'en' else 'fi' end;
  v_web text := btrim(coalesce(p_company_website, ''));
  v_ip text := booking._client_ip();
  v_ip_max int := coalesce((booking._setting('business_quote_rl_ip_per_10min', '5'::jsonb) #>> '{}')::int, 5);
  v_em_max int := coalesce((booking._setting('business_quote_rl_email_per_hour', '3'::jsonb) #>> '{}')::int, 3);
  v_allowed text[] := array['ritual','forest_yoga','campfire_meal','sauna','vihta_workshop','other'];
  v_raw text[]; v_bad int; v_off text[]; v_id bigint;
  v_notify text; v_nname text;
begin
  -- Honeypot: ei riviä, ei sähköpostia. Rate limit kirjataan, vastaus on sama kuin onnistuminen.
  if v_web <> '' then
    if v_ip is not null then perform booking._rate_limit('bq:ip:' || v_ip, v_ip_max, interval '10 minutes'); end if;
    if v_email <> '' then perform booking._rate_limit('bq:email:' || v_email, v_em_max, interval '1 hour'); end if;
    return jsonb_build_object('ok', true, 'code', 'ok');
  end if;
  if v_ip is not null and not booking._rate_limit('bq:ip:' || v_ip, v_ip_max, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;
  if v_email <> '' and not booking._rate_limit('bq:email:' || v_email, v_em_max, interval '1 hour') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;

  if char_length(v_company) < 2 or char_length(v_company) > 160 then return jsonb_build_object('ok', false, 'code', 'invalid_company'); end if;
  if char_length(v_contact) < 2 or char_length(v_contact) > 120 then return jsonb_build_object('ok', false, 'code', 'invalid_contact'); end if;
  if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email'); end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone'); end if;
  if char_length(v_when) < 2 or char_length(v_when) > 160 then return jsonb_build_object('ok', false, 'code', 'invalid_when'); end if;
  if p_persons is null or p_persons < 1 or p_persons > 300 then return jsonb_build_object('ok', false, 'code', 'invalid_persons'); end if;
  if p_offerings is null or jsonb_typeof(p_offerings) is distinct from 'array' then return jsonb_build_object('ok', false, 'code', 'invalid_offerings'); end if;
  select coalesce(array_agg(distinct x), '{}') into v_raw from jsonb_array_elements_text(p_offerings) x;
  select count(*) into v_bad from unnest(v_raw) x where not (x = any (v_allowed));
  if v_bad > 0 or cardinality(v_raw) < 1 then return jsonb_build_object('ok', false, 'code', 'invalid_offerings'); end if;
  select array_agg(a order by array_position(v_allowed, a)) into v_off from unnest(v_allowed) a where a = any (v_raw);
  if 'other' = any (v_off) then
    if char_length(v_other) < 2 or char_length(v_other) > 200 then return jsonb_build_object('ok', false, 'code', 'invalid_offering_other'); end if;
  else
    v_other := null;
  end if;
  if v_message is not null and char_length(v_message) > 2000 then return jsonb_build_object('ok', false, 'code', 'invalid_message'); end if;
  if p_privacy is distinct from true then return jsonb_build_object('ok', false, 'code', 'privacy_required'); end if;

  insert into booking.business_quote_requests(company_name, contact_name, email, phone, preferred_when, persons, offerings, offering_other, message, locale, privacy_accepted)
  values (v_company, v_contact, v_email, v_phone, v_when, p_persons, v_off, nullif(v_other, ''), v_message, v_locale, true)
  returning id into v_id;

  insert into booking.email_outbox(kind, locale, dedupe_key, payload)
  values ('business_quote_ack', v_locale, 'business_quote_ack:' || v_id,
          jsonb_build_object('to_email', v_email, 'to_name', v_contact, 'quote_id', v_id));

  v_notify := nullif(btrim(coalesce(booking._setting('business_quote_notify_email', to_jsonb('savusauna@saunotus.fi'::text)) #>> '{}', '')), '');
  v_nname := coalesce(nullif(btrim(coalesce(booking._setting('business_quote_notify_name', to_jsonb('Joonas'::text)) #>> '{}', '')), ''), 'Joonas');
  if v_notify is not null and booking._valid_email(lower(v_notify)) then
    insert into booking.email_outbox(kind, locale, dedupe_key, payload)
    values ('business_quote_notify', 'fi', 'business_quote_notify:' || v_id,
            jsonb_build_object('to_email', lower(v_notify), 'to_name', v_nname, 'quote_id', v_id));
  end if;

  return jsonb_build_object('ok', true, 'code', 'ok');
end $$;

revoke all on function booking.public_create_business_quote(text, text, text, text, text, integer, jsonb, text, text, text, boolean, text) from public;
grant execute on function booking.public_create_business_quote(text, text, text, text, text, integer, jsonb, text, text, text, boolean, text) to anon, authenticated, service_role;

create or replace function booking.admin_list_business_quotes(p_status text default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_status text := nullif(lower(btrim(coalesce(p_status, ''))), '');
begin
  perform booking._require_permission('quotes.manage');
  if v_status is not null and v_status not in ('new', 'handled', 'offered', 'closed') then
    perform booking._err('invalid_status', 'Tila on new, handled, offered tai closed');
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', q.id, 'status', q.status, 'company_name', q.company_name, 'contact_name', q.contact_name,
      'email', q.email, 'phone', q.phone, 'preferred_when', q.preferred_when, 'persons', q.persons,
      'offerings', to_jsonb(q.offerings), 'offering_other', q.offering_other, 'message', q.message,
      'locale', q.locale, 'created_at', q.created_at, 'handled_at', q.handled_at, 'admin_note', q.admin_note
    ) order by q.created_at desc, q.id desc)
    from (
      select * from booking.business_quote_requests
       where v_status is null or status = v_status
       order by created_at desc, id desc
       limit 200
    ) q
  ), '[]'::jsonb);
end $$;

create or replace function booking.admin_set_business_quote_status(p_id bigint, p_status text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_status text := lower(btrim(coalesce(p_status, ''))); v_note text;
begin
  perform booking._require_permission('quotes.manage');
  if v_status not in ('new', 'handled', 'offered', 'closed') then
    perform booking._err('invalid_status', 'Tila on new, handled, offered tai closed');
  end if;
  if p_note is not null and char_length(btrim(p_note)) > 2000 then
    perform booking._err('invalid_note', 'Muistiinpano on liian pitkä');
  end if;
  v_note := case when p_note is null then null else nullif(btrim(p_note), '') end;
  update booking.business_quote_requests set
    status = v_status,
    admin_note = case when p_note is null then admin_note else v_note end,
    handled_by = auth.uid(),
    handled_at = now()
   where id = p_id;
  if not found then perform booking._err('not_found', 'Tarjouspyyntöä ei löydy'); end if;
  return jsonb_build_object('ok', true, 'id', p_id, 'status', v_status);
end $$;

revoke all on function booking.admin_list_business_quotes(text) from public;
revoke all on function booking.admin_set_business_quote_status(bigint, text, text) from public;
grant execute on function booking.admin_list_business_quotes(text) to authenticated, service_role;
grant execute on function booking.admin_set_business_quote_status(bigint, text, text) to authenticated, service_role;
