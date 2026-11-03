CREATE OR REPLACE FUNCTION booking.public_create_business_quote(p_company_name text, p_contact_name text, p_email text, p_phone text, p_preferred_when text, p_persons integer, p_offerings jsonb DEFAULT '[]'::jsonb, p_offering_other text DEFAULT NULL::text, p_message text DEFAULT NULL::text, p_locale text DEFAULT 'fi'::text, p_privacy boolean DEFAULT false, p_company_website text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  v_notify text; v_nname text; v_created timestamptz;
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
  returning id, created_at into v_id, v_created;

  insert into booking.email_outbox(kind, locale, dedupe_key, payload)
  values ('business_quote_ack', v_locale, 'business_quote_ack:' || v_id,
          jsonb_build_object('to_email', v_email, 'to_name', v_contact, 'quote_id', v_id));

  v_notify := nullif(btrim(coalesce(booking._setting('business_quote_notify_email', to_jsonb('savusauna@saunotus.fi'::text)) #>> '{}', '')), '');
  v_nname := coalesce(nullif(btrim(coalesce(booking._setting('business_quote_notify_name', to_jsonb('Joonas'::text)) #>> '{}', '')), ''), 'Joonas');
  if v_notify is not null and booking._valid_email(lower(v_notify)) then
    insert into booking.email_outbox(kind, locale, dedupe_key, payload)
    values ('business_quote_notify', 'fi', 'business_quote_notify:' || v_id,
            jsonb_build_object(
              'to_email', lower(v_notify), 'to_name', v_nname, 'quote_id', v_id, 'reply_to', v_email,
              'company_name', v_company, 'contact_name', v_contact, 'email', v_email, 'phone', v_phone,
              'persons', p_persons, 'offerings', to_jsonb(v_off), 'offering_other', nullif(v_other, ''),
              'preferred_when', v_when, 'message', v_message, 'locale', v_locale, 'created_at', v_created));
  end if;

  return jsonb_build_object('ok', true, 'code', 'ok');
end $function$
;
