-- ROLLBACK booking_102_business_quote_notify_payload.
-- Palauttaa public_create_business_quote-funktion booking_75:n payloadiin (vain to_email, to_name, quote_id)
-- ja email_outbox_claim-funktion booking_50:n muotoon (ei quote-lohkoa eikä reply_to-kenttää).
-- Ei tyhjennä business_quote_notify_email / _name -asetusta eikä poista jo täydennettyjä payload-avaimia:
-- vanha claim ei lue niitä. Taulu, RLS ja julkinen vastaanotto säilyvät.
-- Aja ennen booking_101:n rollbackia.

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

CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_ids bigint[]; v_site text := coalesce(booking._setting('site_base_url') #>> '{}', ''); v_op text := coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/');
        v_pp text := coalesce(booking._setting('payment_link_path') #>> '{}', '/maksa/'); v_res jsonb;
begin
  update booking.email_outbox set status = 'pending', locked_at = null where status = 'sending' and locked_at < now() - interval '10 minutes';
  select coalesce(array_agg(id), '{}') into v_ids from (
    select id from booking.email_outbox where status in ('pending','failed') and next_attempt_at <= now() order by id limit greatest(least(coalesce(p_limit, 20), 50), 1) for update skip locked) q;
  update booking.email_outbox set status = 'sending', locked_at = now(), attempts = attempts + 1 where id = any (v_ids);
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'kind', e.kind, 'locale', e.locale, 'attempts', e.attempts, 'max_attempts', e.max_attempts, 'to', coalesce(nullif(e.payload ->> 'to_email', ''), c.email), 'to_name', coalesce(nullif(e.payload ->> 'to_name', ''), c.name),
      'order', case when o.id is null or e.kind = 'gift_card_recipient' then null else jsonb_build_object('order_no', o.order_no, 'order_url', v_site || v_op || '?t=' || o.public_token, 'total', o.total_gross, 'status', o.status,
          'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.product_name, 'quantity', i.quantity, 'line_total', i.line_total_gross, 'vat_rate', i.vat_rate, 'kind', i.kind) order by i.id) from booking.order_items i where i.order_id = o.id), '[]'::jsonb),
          'reservations', coalesce((select jsonb_agg(jsonb_build_object('product_name', it.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'status', r.status, 'option', booking._option_json(r.product_option_id)) order by r.starts_at)
              from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id), '[]'::jsonb)) end,
      'gift_cards', case when e.kind like 'gift_card\_%' then (select coalesce(jsonb_agg(jsonb_build_object('public_token', g.public_token, 'package_code', g.package_code, 'package_name', pk.name, 'package_name_en', pk.name_en,
            'kind', g.kind, 'amount', g.initial_amount, 'valid_to', g.valid_to, 'recipient_name', g.recipient_name, 'greeting', g.greeting, 'buyer_name', g.buyer_name, 'persons', pk.persons,
            'locale', g.locale, 'status', g.status, 'delivery_to', g.delivery_to, 'deliver_on', g.deliver_on, 'deliver_time', to_char(g.deliver_time, 'HH24:MI'),
            'deliver_at', booking._gc_deliver_ts(g.deliver_on, g.deliver_time), 'delivered_at', g.delivered_at,
            'recipient_email', case when e.kind = 'gift_card_buyer' then g.recipient_email end, 'cover_message', case when e.kind = 'gift_card_recipient' then g.cover_message end) order by g.id), '[]'::jsonb)
          from booking.gift_cards g left join booking.gift_card_packages pk on pk.code = g.package_code
         where g.id in (select (x)::bigint from jsonb_array_elements_text(coalesce(e.payload -> 'card_ids', '[]'::jsonb)) x)) end,
      'voucher_claim', case when e.kind like 'voucher\_claim\_%' then (select jsonb_build_object('claim_id', vc.id, 'status', vc.status, 'source', vc.source, 'code_masked', booking._vc_mask(vc.code), 'problem_code', vc.problem_code,
            'hold_until', vc.hold_until, 'created_at', vc.created_at, 'customer_name', vc.customer_name) from booking.voucher_claims vc where vc.id = (e.payload ->> 'claim_id')::bigint) end,
      'receipt', case when rc.id is null then null else jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'text_body', rc.text_body, 'public_token', rc.public_token, 'total', rc.total_gross, 'issued_at', rc.issued_at) end,
      'payment', case when p.id is null then null else jsonb_build_object('id', p.id, 'amount', p.amount, 'link_url', case when p.provider <> 'manual' and p.status = 'pending' then v_site || v_pp || '?p=' || p.link_token end,
          'link_expires_at', p.link_expires_at) end) order by e.id), '[]'::jsonb)
    into v_res
    from booking.email_outbox e left join booking.orders o on o.id = e.order_id left join booking.customers c on c.id = o.customer_id
    left join booking.receipts rc on rc.id = e.receipt_id left join booking.payments p on p.id = e.payment_id
   where e.id = any (v_ids);
  return v_res;
end $function$;

revoke all on function booking.email_outbox_claim(integer) from public, anon, authenticated;
grant execute on function booking.email_outbox_claim(integer) to service_role;
