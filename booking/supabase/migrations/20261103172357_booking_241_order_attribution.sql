-- booking_241_order_attribution
-- Tilaus <-> käynti -linkki: selaimen sessionStorage-istunto (session_key) ja käynnin lähde tallennetaan tilaukselle.
--  * booking.orders.analytics_session_key uuid null  = sama session_key kuin public_track_eventissä
--  * booking.orders.attribution jsonb null           = {source_category, referrer_domain, utm_source, utm_medium, utm_campaign, landing_path, device_type, locale}
--    (source_category lasketaan aina palvelimella booking._analytics_source:lla, kuten public_track_event)
--  * Julkiset tilauksen luovat funktiot saavat valinnaisen p_attribution jsonb DEFAULT NULL -parametrin.
--    Alkuperäiset rungot nimetään uudelleen booking._<nimi>_impl (muuttumattomina, ei anon-oikeutta) ja julkinen nimi
--    on ohut kääre, joten vanhat kutsut toimivat sellaisenaan eikä overload-ristiriitaa synny (yksi signatuuri per nimi).
--  * Virheellinen/tuntematon attribuutiodata pudotetaan kenttä kerrallaan; se ei koskaan kaada tilausta.
--  * admin_analytics_summary: vain lisäyksiä (ks. alla).
-- Ei henkilötietoja: kentät validoidaan samoin säännöin kuin public_track_event (ei emailia, ei pitkiä numerosarjoja).

alter table booking.orders add column if not exists analytics_session_key uuid;
alter table booking.orders add column if not exists attribution jsonb;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'orders_attribution_shape_chk' and conrelid = 'booking.orders'::regclass) then
    alter table booking.orders add constraint orders_attribution_shape_chk
      check (attribution is null or (jsonb_typeof(attribution) = 'object' and octet_length(attribution::text) <= 1024));
  end if;
end $$;
comment on column booking.orders.analytics_session_key is 'booking_241: selaimen analytiikkaistunto (sessionStorage), = analytics_events.session_key. Ei henkilötieto.';
comment on column booking.orders.attribution is 'booking_241: käynnin lähde tilaushetkellä (validoitu, ks. booking._analytics_attribution_clean).';

create or replace function booking._analytics_attribution_clean(p jsonb)
 returns jsonb language plpgsql stable set search_path to '' as $function$
declare
  v_sk text; v_dom text; v_us text; v_um text; v_uc text; v_path text; v_dev text; v_loc text;
begin
  if p is null or jsonb_typeof(p) <> 'object' or octet_length(p::text) > 4096 then return null; end if;
  begin
    v_sk := lower(btrim(case when jsonb_typeof(p->'session_key') = 'string' then p->>'session_key' end));
    if v_sk is null or v_sk !~ '^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$' then v_sk := null; end if;

    v_dom := lower(nullif(btrim(case when jsonb_typeof(p->'referrer_domain') = 'string' then p->>'referrer_domain' end), ''));
    if v_dom is not null and (char_length(v_dom) > 180 or v_dom !~ '^[a-z0-9.-]+$' or position('.' in v_dom) = 0
        or position('..' in v_dom) > 0 or left(v_dom, 1) = '.' or right(v_dom, 1) = '.' or position('@' in v_dom) > 0) then
      v_dom := null;
    end if;

    v_us := lower(nullif(btrim(case when jsonb_typeof(p->'utm_source') = 'string' then p->>'utm_source' end), ''));
    if v_us is not null and not coalesce(booking._analytics_utm_ok(v_us, 40), false) then v_us := null; end if;
    v_um := lower(nullif(btrim(case when jsonb_typeof(p->'utm_medium') = 'string' then p->>'utm_medium' end), ''));
    if v_um is not null and not coalesce(booking._analytics_utm_ok(v_um, 40), false) then v_um := null; end if;
    v_uc := lower(nullif(btrim(case when jsonb_typeof(p->'utm_campaign') = 'string' then p->>'utm_campaign' end), ''));
    if v_uc is not null and not coalesce(booking._analytics_utm_ok(v_uc, 60), false) then v_uc := null; end if;

    if jsonb_typeof(p->'landing_path') = 'string' then v_path := booking._analytics_path(p->>'landing_path'); end if;
    v_dev := case when p->>'device_type' in ('mobile','desktop','tablet') then p->>'device_type' end;
    v_loc := case when p->>'locale' in ('fi','en') then p->>'locale' end;

    if coalesce(v_sk, v_dom, v_us, v_um, v_uc, v_path, v_dev, v_loc) is null then return null; end if;
    return jsonb_strip_nulls(jsonb_build_object(
      'session_key', v_sk,
      'source_category', booking._analytics_source(v_dom, v_us, v_uc),
      'referrer_domain', v_dom, 'utm_source', v_us, 'utm_medium', v_um, 'utm_campaign', v_uc,
      'landing_path', v_path, 'device_type', v_dev, 'locale', v_loc));
  exception when others then
    return null;
  end;
end $function$;
revoke all on function booking._analytics_attribution_clean(jsonb) from public, anon, authenticated;

create or replace function booking._order_attach_attribution(p_res jsonb, p_attribution jsonb)
 returns jsonb language plpgsql volatile security definer set search_path to '' as $function$
declare v_tok uuid; v_clean jsonb; v_sk uuid;
begin
  -- Palauttaa AINA p_res muuttumattomana; liitos on paras yritys eikä koskaan kaada tilausta.
  if p_attribution is null or p_res is null or jsonb_typeof(p_res) <> 'object' or (p_res->>'ok') is distinct from 'true' then
    return p_res;
  end if;
  begin
    if coalesce(p_res->>'token', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return p_res; end if;
    v_tok := (p_res->>'token')::uuid;
    v_clean := booking._analytics_attribution_clean(p_attribution);
    if v_clean is null then return p_res; end if;
    v_sk := (v_clean->>'session_key')::uuid;
    v_clean := v_clean - 'session_key';
    update booking.orders o
       set analytics_session_key = v_sk,
           attribution = case when v_clean = '{}'::jsonb then null else v_clean end
     where o.public_token = v_tok
       and o.analytics_session_key is null and o.attribution is null
       and o.created_at > now() - interval '15 minutes';
  exception when others then
    null;
  end;
  return p_res;
end $function$;
revoke all on function booking._order_attach_attribution(jsonb, jsonb) from public, anon, authenticated;

-- Sama "maksettu verkkokauppatilaus" -määritelmä kuin booking_240. linked = tilauksen istunto löytyy analytics_eventsistä
-- (booking_241) tai tilaukselle on purchase-tapahtuma (booking_240).
create or replace function booking._analytics_paid_orders(p_from date, p_to date)
 returns table(buyers integer, orders integer, gross numeric(12,2), linked integer, orders_all integer, gross_all numeric(12,2))
 language sql stable set search_path to '' as $function$
  with o as (
    select o.id, o.total_gross, o.source_channel, o.analytics_session_key from booking.orders o
     where o.created_at >= (p_from::timestamp at time zone 'Europe/Helsinki')
       and o.created_at <  ((p_to + 1)::timestamp at time zone 'Europe/Helsinki')
       and o.payment_status in ('paid','partially_refunded')
       and o.status not in ('cancelled','expired','pending')
       and o.external_source is null and o.johku_order_no is null
       and o.source_channel is distinct from 'johku_import')
  select count(*) filter (where o.source_channel = 'web')::int,
         count(*) filter (where o.source_channel = 'web')::int,
         coalesce(sum(o.total_gross) filter (where o.source_channel = 'web'), 0)::numeric(12,2),
         count(*) filter (where o.source_channel = 'web' and (
             (o.analytics_session_key is not null and exists (select 1 from booking.analytics_events e
                where e.session_key = o.analytics_session_key::text and e.event_date between p_from - 1 and p_to + 1))
          or exists (select 1 from booking.analytics_events e where e.event_type = 'purchase' and e.order_id = o.id)))::int,
         count(*)::int,
         coalesce(sum(o.total_gross), 0)::numeric(12,2)
  from o
$function$;
revoke all on function booking._analytics_paid_orders(date, date) from public, anon, authenticated;

create or replace function booking._analytics_orders_breakdown(p_from date, p_to date)
 returns jsonb language sql stable set search_path to '' as $function$
  with o as (
    select o.attribution, o.locale from booking.orders o
     where o.created_at >= (p_from::timestamp at time zone 'Europe/Helsinki')
       and o.created_at <  ((p_to + 1)::timestamp at time zone 'Europe/Helsinki')
       and o.payment_status in ('paid','partially_refunded')
       and o.status not in ('cancelled','expired','pending')
       and o.external_source is null and o.johku_order_no is null
       and o.source_channel = 'web')
  select jsonb_build_object(
    'source', coalesce((select jsonb_object_agg(k, n) from (select attribution->>'source_category' k, count(*)::int n from o
                         where attribution ? 'source_category' group by 1) x), '{}'::jsonb),
    'device', coalesce((select jsonb_object_agg(k, n) from (select attribution->>'device_type' k, count(*)::int n from o
                         where attribution ? 'device_type' group by 1) x), '{}'::jsonb),
    'locale', coalesce((select jsonb_object_agg(k, n) from (select coalesce(attribution->>'locale', locale) k, count(*)::int n from o
                         where coalesce(attribution->>'locale', locale) is not null group by 1) x), '{}'::jsonb),
    'attributed', (select count(*)::int from o where attribution ? 'source_category'),
    'unattributed', (select count(*)::int from o where not coalesce(attribution ? 'source_category', false)))
$function$;
revoke all on function booking._analytics_orders_breakdown(date, date) from public, anon, authenticated;

-- public_create_booking: alkuperäinen runko säilyy muuttumattomana nimellä booking._public_create_booking_impl; julkinen nimi = ohut kääre + p_attribution.
alter function booking.public_create_booking(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb) rename to _public_create_booking_impl;
revoke all on function booking._public_create_booking_impl(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb) from public, anon, authenticated;
grant execute on function booking._public_create_booking_impl(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb) to service_role;
create function booking.public_create_booking(p_rule_id bigint, p_date date, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_addons jsonb DEFAULT NULL::jsonb, p_attribution jsonb DEFAULT NULL::jsonb)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
begin
  -- booking_241: p_attribution on valinnainen eikä koskaan kaada tilausta (ks. booking._order_attach_attribution).
  return booking._order_attach_attribution(booking._public_create_booking_impl(p_rule_id => p_rule_id, p_date => p_date, p_persons => p_persons, p_name => p_name, p_email => p_email, p_phone => p_phone, p_marketing_consent => p_marketing_consent, p_locale => p_locale, p_note => p_note, p_customer_kind => p_customer_kind, p_company => p_company, p_addons => p_addons), p_attribution);
end $function$;
revoke all on function booking.public_create_booking(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb, jsonb) from public;
grant execute on function booking.public_create_booking(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb, jsonb) to anon, authenticated, service_role;
comment on function booking.public_create_booking(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb, jsonb) is 'booking_241: kääre booking._public_create_booking_impl:lle; valinnainen p_attribution (ks. migrations/booking_241/KOODARILLE.md).';

-- public_create_booking_code: alkuperäinen runko säilyy muuttumattomana nimellä booking._public_create_booking_code_impl; julkinen nimi = ohut kääre + p_attribution.
alter function booking.public_create_booking_code(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb,text) rename to _public_create_booking_code_impl;
revoke all on function booking._public_create_booking_code_impl(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb,text) from public, anon, authenticated;
grant execute on function booking._public_create_booking_code_impl(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb,text) to service_role;
create function booking.public_create_booking_code(p_rule_id bigint, p_date date, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_addons jsonb DEFAULT NULL::jsonb, p_code text DEFAULT NULL::text, p_attribution jsonb DEFAULT NULL::jsonb)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
begin
  -- booking_241: p_attribution on valinnainen eikä koskaan kaada tilausta (ks. booking._order_attach_attribution).
  return booking._order_attach_attribution(booking._public_create_booking_code_impl(p_rule_id => p_rule_id, p_date => p_date, p_persons => p_persons, p_name => p_name, p_email => p_email, p_phone => p_phone, p_marketing_consent => p_marketing_consent, p_locale => p_locale, p_note => p_note, p_customer_kind => p_customer_kind, p_company => p_company, p_addons => p_addons, p_code => p_code), p_attribution);
end $function$;
revoke all on function booking.public_create_booking_code(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb,text, jsonb) from public;
grant execute on function booking.public_create_booking_code(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb,text, jsonb) to anon, authenticated, service_role;
comment on function booking.public_create_booking_code(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb,text, jsonb) is 'booking_241: kääre booking._public_create_booking_code_impl:lle; valinnainen p_attribution (ks. migrations/booking_241/KOODARILLE.md).';

-- public_create_treatment_booking: alkuperäinen runko säilyy muuttumattomana nimellä booking._public_create_treatment_booking_impl; julkinen nimi = ohut kääre + p_attribution.
alter function booking.public_create_treatment_booking(bigint,timestamp with time zone,integer,text,text,text,boolean,text,text,text,jsonb,text,jsonb) rename to _public_create_treatment_booking_impl;
revoke all on function booking._public_create_treatment_booking_impl(bigint,timestamp with time zone,integer,text,text,text,boolean,text,text,text,jsonb,text,jsonb) from public, anon, authenticated;
grant execute on function booking._public_create_treatment_booking_impl(bigint,timestamp with time zone,integer,text,text,text,boolean,text,text,text,jsonb,text,jsonb) to service_role;
create function booking.public_create_treatment_booking(p_product_id bigint, p_start timestamp with time zone, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_option_code text DEFAULT NULL::text, p_addons jsonb DEFAULT NULL::jsonb, p_attribution jsonb DEFAULT NULL::jsonb)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
begin
  -- booking_241: p_attribution on valinnainen eikä koskaan kaada tilausta (ks. booking._order_attach_attribution).
  return booking._order_attach_attribution(booking._public_create_treatment_booking_impl(p_product_id => p_product_id, p_start => p_start, p_persons => p_persons, p_name => p_name, p_email => p_email, p_phone => p_phone, p_marketing_consent => p_marketing_consent, p_locale => p_locale, p_note => p_note, p_customer_kind => p_customer_kind, p_company => p_company, p_option_code => p_option_code, p_addons => p_addons), p_attribution);
end $function$;
revoke all on function booking.public_create_treatment_booking(bigint,timestamp with time zone,integer,text,text,text,boolean,text,text,text,jsonb,text,jsonb, jsonb) from public;
grant execute on function booking.public_create_treatment_booking(bigint,timestamp with time zone,integer,text,text,text,boolean,text,text,text,jsonb,text,jsonb, jsonb) to anon, authenticated, service_role;
comment on function booking.public_create_treatment_booking(bigint,timestamp with time zone,integer,text,text,text,boolean,text,text,text,jsonb,text,jsonb, jsonb) is 'booking_241: kääre booking._public_create_treatment_booking_impl:lle; valinnainen p_attribution (ks. migrations/booking_241/KOODARILLE.md).';

-- public_buy_gift_card: alkuperäinen runko säilyy muuttumattomana nimellä booking._public_buy_gift_card_impl; julkinen nimi = ohut kääre + p_attribution.
alter function booking.public_buy_gift_card(jsonb,text,text,text,boolean,text,text,text,text,text,text,text,text) rename to _public_buy_gift_card_impl;
revoke all on function booking._public_buy_gift_card_impl(jsonb,text,text,text,boolean,text,text,text,text,text,text,text,text) from public, anon, authenticated;
grant execute on function booking._public_buy_gift_card_impl(jsonb,text,text,text,boolean,text,text,text,text,text,text,text,text) to service_role;
create function booking.public_buy_gift_card(p_items jsonb, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_recipient_name text DEFAULT NULL::text, p_recipient_email text DEFAULT NULL::text, p_greeting text DEFAULT NULL::text, p_delivery_to text DEFAULT NULL::text, p_cover_message text DEFAULT NULL::text, p_deliver_on text DEFAULT NULL::text, p_deliver_time text DEFAULT NULL::text, p_attribution jsonb DEFAULT NULL::jsonb)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
begin
  -- booking_241: p_attribution on valinnainen eikä koskaan kaada tilausta (ks. booking._order_attach_attribution).
  return booking._order_attach_attribution(booking._public_buy_gift_card_impl(p_items => p_items, p_name => p_name, p_email => p_email, p_phone => p_phone, p_marketing_consent => p_marketing_consent, p_locale => p_locale, p_recipient_name => p_recipient_name, p_recipient_email => p_recipient_email, p_greeting => p_greeting, p_delivery_to => p_delivery_to, p_cover_message => p_cover_message, p_deliver_on => p_deliver_on, p_deliver_time => p_deliver_time), p_attribution);
end $function$;
revoke all on function booking.public_buy_gift_card(jsonb,text,text,text,boolean,text,text,text,text,text,text,text,text, jsonb) from public;
grant execute on function booking.public_buy_gift_card(jsonb,text,text,text,boolean,text,text,text,text,text,text,text,text, jsonb) to anon, authenticated, service_role;
comment on function booking.public_buy_gift_card(jsonb,text,text,text,boolean,text,text,text,text,text,text,text,text, jsonb) is 'booking_241: kääre booking._public_buy_gift_card_impl:lle; valinnainen p_attribution (ks. migrations/booking_241/KOODARILLE.md).';

-- public_buy_annual_card: alkuperäinen runko säilyy muuttumattomana nimellä booking._public_buy_annual_card_impl; julkinen nimi = ohut kääre + p_attribution.
alter function booking.public_buy_annual_card(text,text,text,boolean,text) rename to _public_buy_annual_card_impl;
revoke all on function booking._public_buy_annual_card_impl(text,text,text,boolean,text) from public, anon, authenticated;
grant execute on function booking._public_buy_annual_card_impl(text,text,text,boolean,text) to service_role;
create function booking.public_buy_annual_card(p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_attribution jsonb DEFAULT NULL::jsonb)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
begin
  -- booking_241: p_attribution on valinnainen eikä koskaan kaada tilausta (ks. booking._order_attach_attribution).
  return booking._order_attach_attribution(booking._public_buy_annual_card_impl(p_name => p_name, p_email => p_email, p_phone => p_phone, p_marketing_consent => p_marketing_consent, p_locale => p_locale), p_attribution);
end $function$;
revoke all on function booking.public_buy_annual_card(text,text,text,boolean,text, jsonb) from public;
grant execute on function booking.public_buy_annual_card(text,text,text,boolean,text, jsonb) to anon, authenticated, service_role;
comment on function booking.public_buy_annual_card(text,text,text,boolean,text, jsonb) is 'booking_241: kääre booking._public_buy_annual_card_impl:lle; valinnainen p_attribution (ks. migrations/booking_241/KOODARILLE.md).';

-- public_create_training_signup: alkuperäinen runko säilyy muuttumattomana nimellä booking._public_create_training_signup_impl; julkinen nimi = ohut kääre + p_attribution.
alter function booking.public_create_training_signup(bigint,date,text,text,text,text,text,text,text,boolean,boolean,text[]) rename to _public_create_training_signup_impl;
revoke all on function booking._public_create_training_signup_impl(bigint,date,text,text,text,text,text,text,text,boolean,boolean,text[]) from public, anon, authenticated;
grant execute on function booking._public_create_training_signup_impl(bigint,date,text,text,text,text,text,text,text,boolean,boolean,text[]) to service_role;
create function booking.public_create_training_signup(p_rule_id bigint, p_date date, p_name text, p_email text, p_phone text, p_country text, p_language text, p_locale text, p_note text, p_marketing_consent boolean, p_privacy_consent boolean, p_addons text[] DEFAULT '{}'::text[], p_attribution jsonb DEFAULT NULL::jsonb)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
begin
  -- booking_241: p_attribution on valinnainen eikä koskaan kaada tilausta (ks. booking._order_attach_attribution).
  return booking._order_attach_attribution(booking._public_create_training_signup_impl(p_rule_id => p_rule_id, p_date => p_date, p_name => p_name, p_email => p_email, p_phone => p_phone, p_country => p_country, p_language => p_language, p_locale => p_locale, p_note => p_note, p_marketing_consent => p_marketing_consent, p_privacy_consent => p_privacy_consent, p_addons => p_addons), p_attribution);
end $function$;
revoke all on function booking.public_create_training_signup(bigint,date,text,text,text,text,text,text,text,boolean,boolean,text[], jsonb) from public;
grant execute on function booking.public_create_training_signup(bigint,date,text,text,text,text,text,text,text,boolean,boolean,text[], jsonb) to anon, authenticated, service_role;
comment on function booking.public_create_training_signup(bigint,date,text,text,text,text,text,text,text,boolean,boolean,text[], jsonb) is 'booking_241: kääre booking._public_create_training_signup_impl:lle; valinnainen p_attribution (ks. migrations/booking_241/KOODARILLE.md).';

-- admin_analytics_summary: vain lisäyksiä (purchases/conversion_pct tilauksista, vanhat *_events-avaimissa).
CREATE OR REPLACE FUNCTION booking.admin_analytics_summary(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb; v_today date := (now() at time zone 'Europe/Helsinki')::date; v_ob jsonb;
begin
  perform booking._require_staff();
  if not (booking.has_permission('reports.view') or booking.has_permission('reports.daily')) then
    perform booking._err('forbidden','Raporttien tarkasteluoikeus puuttuu');
  end if;
  -- booking_157: menneisyyteen osuva pitkä aikaväli luetaan kuukausikoosteesta (enintään 3661 päivää); muuten enintään 367 päivää.
  if p_from is null or p_to is null or p_from > p_to or (p_to - p_from > 366 and (p_to > v_today or p_to - p_from > 3660)) then
    perform booking._err('invalid_range','Aikaväli saa olla enintään 367 päivää (menneisyydessä enintään 3661 päivää)');
  end if;
  -- booking_241: maksetut verkkotilaukset lähteittäin/laitteittain/kielittäin tilauksen attribuutiosta (booking.orders.attribution).
  v_ob := booking._analytics_orders_breakdown(p_from, p_to);
  if not exists (select 1 from booking.analytics_monthly m where m.month between date_trunc('month', p_from)::date and p_to) then
    -- Ei koostekuukausia: täsmälleen booking_150:n kysely.
    with e as materialized (
      select * from booking.analytics_events where event_date between p_from and p_to
    ), f as (
      select count(distinct session_key) filter(where event_type='page_view')::int visitors,
             count(distinct session_key) filter(where event_type='product_view')::int product_viewers,
             count(distinct session_key) filter(where event_type='checkout_start')::int checkout_starters,
             count(distinct session_key) filter(where event_type='purchase')::int buyers,
             count(*) filter(where event_type='page_view')::int page_view_events,
             count(*) filter(where event_type='product_view')::int product_view_events,
             count(*) filter(where event_type='checkout_start')::int checkout_events,
             count(*) filter(where event_type='purchase')::int purchase_events
      from e
    ), paid as (
      select count(*)::int orders,coalesce(sum(amount_gross),0)::numeric(12,2) gross from
         (select distinct on(order_id) order_id,amount_gross from e where event_type='purchase' and order_id is not null order by order_id,created_at desc) p
    ), visits as (
      select distinct on (session_key) session_key,source_category,utm_campaign,referrer_domain,device_type,locale
         from e where event_type='page_view' order by session_key,created_at,id
    ), buyer_sessions as (
      select distinct session_key from e where event_type='purchase'
    ), checkout_sessions as (
      select distinct session_key from e where event_type='checkout_start'
    ), sources as (
      select v.source_category, count(*)::int visits,
             count(c.session_key)::int checkouts,count(b.session_key)::int purchases,
             round(100.0*count(b.session_key)/nullif(count(*),0),2) conversion_pct
         from visits v left join checkout_sessions c using(session_key) left join buyer_sessions b using(session_key)
         group by v.source_category
    ), top_campaign as (
       select source_category,utm_campaign,count(*)::int n from visits where utm_campaign is not null group by 1,2
    ), top_ref as (
       select source_category,referrer_domain,count(*)::int n from visits where referrer_domain is not null group by 1,2
    ), products as (
      select coalesce(e.product_id,-1) product_id,e.product_slug,
        count(*) filter (where e.event_type='product_view')::int views,
        count(*) filter (where e.event_type='checkout_start')::int checkouts,
        count(*) filter (where e.event_type='purchase')::int purchases
      from e where e.product_id is not null or e.product_slug is not null group by coalesce(e.product_id,-1),e.product_slug
    ), devices as (
       select device_type,count(*)::int visits,count(b.session_key)::int purchases from visits v left join buyer_sessions b using(session_key) group by device_type
    ), locales as (
       select locale,count(*)::int visits,count(b.session_key)::int purchases from visits v left join buyer_sessions b using(session_key) group by locale
    ), days as (
       select d::date as d_day from generate_series(p_from,p_to,interval '1 day') d
    ), daily as (
       -- booking_150: yksi kooste päivittäin (GROUP BY), ei päiväkohtaisia alikyselyitä. Indeksi analytics_events_date_type_session_idx.
       select a.event_date,
              count(distinct a.session_key) filter (where a.event_type='page_view') visitors,
              count(*) filter (where a.event_type='product_view') product_views,
              count(*) filter (where a.event_type='checkout_start') checkouts,
              count(*) filter (where a.event_type='purchase') purchases
         from booking.analytics_events a
        where a.event_date between p_from and p_to
        group by a.event_date
    )
    select jsonb_build_object(
      'from',p_from,'to',p_to,
      'funnel', (select to_jsonb(f) || jsonb_build_object('paid_orders',ow.orders,'amount_gross',ow.gross,'conversion_pct',coalesce(round(100.0*ow.buyers/nullif(f.visitors,0),2),0),
        -- booking_240: Ostaneet ja maksetut tilaukset booking.ordersista (ks. booking._analytics_paid_orders). Vanhat mittausarvot *_events-avaimissa.
        'buyers',ow.buyers,'buyers_source','orders','buyers_linked',ow.linked,
        'buyers_events',f.buyers,'paid_orders_events',paid.orders,'amount_gross_events',paid.gross,
        'paid_orders_all_channels',ow.orders_all,'amount_gross_all_channels',ow.gross_all,
        'buyers_attributed',coalesce((v_ob->>'attributed')::int,0),'buyers_unattributed',coalesce((v_ob->>'unattributed')::int,0))
        from f cross join paid cross join booking._analytics_paid_orders(p_from,p_to) ow),
      'sources',coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object(
       'purchases',coalesce((v_ob->'source'->>s.source_category)::int,0),'purchases_events',s.purchases,'purchases_source','orders',
       'conversion_pct',coalesce(round(100.0*coalesce((v_ob->'source'->>s.source_category)::int,0)/nullif(s.visits,0),2),0),'conversion_pct_events',s.conversion_pct,
       
         'top_utm_campaign',(select t.utm_campaign from top_campaign t where t.source_category=s.source_category order by n desc,utm_campaign limit 1),
         'top_referrer_domain',(select t.referrer_domain from top_ref t where t.source_category=s.source_category order by n desc,referrer_domain limit 1)) order by s.visits desc) from sources s),'[]'::jsonb),
      'top_products',coalesce((select jsonb_agg(jsonb_build_object('product_id',nullif(p.product_id,-1),'product_slug',p.product_slug,'name',coalesce(k.name,p.product_slug,'Tuntematon tuote'),
        'views',p.views,'checkouts',p.checkouts,'purchases',p.purchases,
        'conversion_pct',coalesce(round(p.purchases*100.0/nullif(p.views,0),2),0)) order by p.views desc)
        from products p left join kb.products k on k.id=p.product_id or (p.product_id=-1 and k.slug=p.product_slug)),'[]'::jsonb),
      'devices_and_locales',jsonb_build_object(
         'devices',coalesce((select jsonb_agg(to_jsonb(d) || jsonb_build_object('purchases',coalesce((v_ob->'device'->>d.device_type)::int,0),'purchases_events',d.purchases,'purchases_source','orders') order by d.visits desc) from devices d),'[]'::jsonb),
         'locales',coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object('purchases',coalesce((v_ob->'locale'->>l.locale)::int,0),'purchases_events',l.purchases,'purchases_source','orders') order by l.visits desc) from locales l),'[]'::jsonb)),
      'daily_series',coalesce((select jsonb_agg(jsonb_build_object('date',d.d_day,
         'visitors',coalesce(x.visitors,0),
         'product_views',coalesce(x.product_views,0),
         'checkouts',coalesce(x.checkouts,0),
         'purchases',coalesce(x.purchases,0)) order by d.d_day) from days d left join daily x on x.event_date=d.d_day),'[]'::jsonb)
    ) into result;
    return result;
  end if;
  -- Koostekuukausia mukana: raakadata (vielä säilytetyt päivät) + kooste (poistetut päivät). Jokainen tapahtuma on vain toisessa,
  -- joten tuplalaskentaa ei ole. Koostekuukausi sisältyy kokonaisena; uniikit istunnot ovat päiväkohtaisten summa.
  with e as materialized (
    select * from booking.analytics_events where event_date between p_from and p_to
  ), ag as materialized (
    select * from booking.analytics_monthly m where m.month between date_trunc('month', p_from)::date and p_to
  ), fr as (
    select count(distinct session_key) filter(where event_type='page_view')::int visitors,
           count(distinct session_key) filter(where event_type='product_view')::int product_viewers,
           count(distinct session_key) filter(where event_type='checkout_start')::int checkout_starters,
           count(distinct session_key) filter(where event_type='purchase')::int buyers,
           count(*) filter(where event_type='page_view')::int page_view_events,
           count(*) filter(where event_type='product_view')::int product_view_events,
           count(*) filter(where event_type='checkout_start')::int checkout_events,
           count(*) filter(where event_type='purchase')::int purchase_events
    from e
  ), fa as (
    select coalesce(sum(events) filter(where kind='unique' and event_type='page_view'),0)::int visitors,
           coalesce(sum(events) filter(where kind='unique' and event_type='product_view'),0)::int product_viewers,
           coalesce(sum(events) filter(where kind='unique' and event_type='checkout_start'),0)::int checkout_starters,
           coalesce(sum(events) filter(where kind='unique' and event_type='purchase'),0)::int buyers,
           coalesce(sum(events) filter(where kind='event' and event_type='page_view'),0)::int page_view_events,
           coalesce(sum(events) filter(where kind='event' and event_type='product_view'),0)::int product_view_events,
           coalesce(sum(events) filter(where kind='event' and event_type='checkout_start'),0)::int checkout_events,
           coalesce(sum(events) filter(where kind='event' and event_type='purchase'),0)::int purchase_events,
           coalesce(sum(orders) filter(where kind='unique' and event_type='purchase'),0)::int orders,
           coalesce(sum(amount_gross_sum) filter(where kind='unique' and event_type='purchase'),0)::numeric(12,2) gross
    from ag
  ), f as (
    select fr.visitors+fa.visitors visitors, fr.product_viewers+fa.product_viewers product_viewers,
           fr.checkout_starters+fa.checkout_starters checkout_starters, fr.buyers+fa.buyers buyers,
           fr.page_view_events+fa.page_view_events page_view_events, fr.product_view_events+fa.product_view_events product_view_events,
           fr.checkout_events+fa.checkout_events checkout_events, fr.purchase_events+fa.purchase_events purchase_events
    from fr cross join fa
  ), paid_raw as (
    select count(*)::int orders,coalesce(sum(amount_gross),0)::numeric(12,2) gross from
       (select distinct on(order_id) order_id,amount_gross from e where event_type='purchase' and order_id is not null order by order_id,created_at desc) p
  ), paid as (
    select paid_raw.orders+fa.orders orders, (paid_raw.gross+fa.gross)::numeric(12,2) gross from paid_raw cross join fa
  ), visits as (
    select distinct on (session_key) session_key,source_category,utm_campaign,referrer_domain,device_type,locale
       from e where event_type='page_view' order by session_key,created_at,id
  ), buyer_sessions as (
    select distinct session_key from e where event_type='purchase'
  ), checkout_sessions as (
    select distinct session_key from e where event_type='checkout_start'
  ), src_all as (
    select v.source_category, count(*) visits, count(c.session_key) checkouts, count(b.session_key) purchases
       from visits v left join checkout_sessions c using(session_key) left join buyer_sessions b using(session_key)
       group by v.source_category
    union all
    select source_category, sum(events), sum(checkouts), sum(purchases) from ag where kind='visit' group by source_category
  ), sources as (
    select source_category, sum(visits)::int visits, sum(checkouts)::int checkouts, sum(purchases)::int purchases,
           round(100.0*sum(purchases)/nullif(sum(visits),0),2) conversion_pct
      from src_all group by source_category
  ), top_campaign as (
     select source_category,utm_campaign,count(*)::int n from visits where utm_campaign is not null group by 1,2
  ), top_ref as (
     select source_category,referrer_domain,count(*)::int n from visits where referrer_domain is not null group by 1,2
  ), prod_all as (
    select coalesce(e.product_id,-1) product_id,e.product_slug,
      count(*) filter (where e.event_type='product_view') views,
      count(*) filter (where e.event_type='checkout_start') checkouts,
      count(*) filter (where e.event_type='purchase') purchases
    from e where e.product_id is not null or e.product_slug is not null group by coalesce(e.product_id,-1),e.product_slug
    union all
    select m.product_id, null::text,
      sum(m.events) filter (where m.event_type='product_view'),
      sum(m.events) filter (where m.event_type='checkout_start'),
      sum(m.events) filter (where m.event_type='purchase')
    from ag m where m.kind='event' and m.product_id <> 0 group by m.product_id
  ), products as (
    select min(product_id) product_id, max(product_slug) product_slug,
           coalesce(sum(views),0)::int views, coalesce(sum(checkouts),0)::int checkouts, coalesce(sum(purchases),0)::int purchases
      from prod_all
     group by case when product_id > 0 then product_id::text else 'slug:' || coalesce(product_slug, '') end
  ), dev_all as (
     select device_type,count(*) visits,count(b.session_key) purchases from visits v left join buyer_sessions b using(session_key) group by device_type
     union all select device_type, sum(events), sum(purchases) from ag where kind='visit' group by device_type
  ), devices as (
     select device_type, sum(visits)::int visits, sum(purchases)::int purchases from dev_all group by device_type
  ), loc_all as (
     select locale,count(*) visits,count(b.session_key) purchases from visits v left join buyer_sessions b using(session_key) group by locale
     union all select locale, sum(events), sum(purchases) from ag where kind='visit' group by locale
  ), locales as (
     select locale, sum(visits)::int visits, sum(purchases)::int purchases from loc_all group by locale
  ), days as (
     select d::date as d_day from generate_series(p_from,p_to,interval '1 day') d
  ), daily as (
     select a.event_date,
            count(distinct a.session_key) filter (where a.event_type='page_view') visitors,
            count(*) filter (where a.event_type='product_view') product_views,
            count(*) filter (where a.event_type='checkout_start') checkouts,
            count(*) filter (where a.event_type='purchase') purchases
       from booking.analytics_events a
      where a.event_date between p_from and p_to
      group by a.event_date
  ), months as (
     select m::date as m_month from generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month') m
  ), monthly as (
     select x.m, sum(x.visitors)::int visitors, sum(x.product_views)::int product_views, sum(x.checkouts)::int checkouts, sum(x.purchases)::int purchases
       from (select date_trunc('month', event_date)::date m, visitors, product_views, checkouts, purchases from daily
             union all
             select month,
                    coalesce(sum(events) filter (where kind='unique' and event_type='page_view'),0),
                    coalesce(sum(events) filter (where kind='event' and event_type='product_view'),0),
                    coalesce(sum(events) filter (where kind='event' and event_type='checkout_start'),0),
                    coalesce(sum(events) filter (where kind='event' and event_type='purchase'),0)
               from ag group by month) x
      group by x.m
  )
  select jsonb_build_object(
    'from',p_from,'to',p_to,
    'funnel', (select to_jsonb(f) || jsonb_build_object('paid_orders',ow.orders,'amount_gross',ow.gross,'conversion_pct',coalesce(round(100.0*ow.buyers/nullif(f.visitors,0),2),0),
        -- booking_240: Ostaneet ja maksetut tilaukset booking.ordersista (ks. booking._analytics_paid_orders). Vanhat mittausarvot *_events-avaimissa.
        'buyers',ow.buyers,'buyers_source','orders','buyers_linked',ow.linked,
        'buyers_events',f.buyers,'paid_orders_events',paid.orders,'amount_gross_events',paid.gross,
        'paid_orders_all_channels',ow.orders_all,'amount_gross_all_channels',ow.gross_all,
        'buyers_attributed',coalesce((v_ob->>'attributed')::int,0),'buyers_unattributed',coalesce((v_ob->>'unattributed')::int,0))
        from f cross join paid cross join booking._analytics_paid_orders(p_from,p_to) ow),
    'sources',coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object(
       'purchases',coalesce((v_ob->'source'->>s.source_category)::int,0),'purchases_events',s.purchases,'purchases_source','orders',
       'conversion_pct',coalesce(round(100.0*coalesce((v_ob->'source'->>s.source_category)::int,0)/nullif(s.visits,0),2),0),'conversion_pct_events',s.conversion_pct,
       
       'top_utm_campaign',(select t.utm_campaign from top_campaign t where t.source_category=s.source_category order by n desc,utm_campaign limit 1),
       'top_referrer_domain',(select t.referrer_domain from top_ref t where t.source_category=s.source_category order by n desc,referrer_domain limit 1)) order by s.visits desc) from sources s),'[]'::jsonb),
    'top_products',coalesce((select jsonb_agg(jsonb_build_object('product_id',nullif(p.product_id,-1),'product_slug',p.product_slug,
      'name',coalesce(k.name,p.product_slug,case when p.product_id=-1 then 'Muut tuotteet (kuukausikooste)' end,'Tuntematon tuote'),
      'views',p.views,'checkouts',p.checkouts,'purchases',p.purchases,
      'conversion_pct',coalesce(round(p.purchases*100.0/nullif(p.views,0),2),0)) order by p.views desc)
      from products p left join kb.products k on k.id=p.product_id or (p.product_id=-1 and k.slug=p.product_slug)),'[]'::jsonb),
    'devices_and_locales',jsonb_build_object(
       'devices',coalesce((select jsonb_agg(to_jsonb(d) || jsonb_build_object('purchases',coalesce((v_ob->'device'->>d.device_type)::int,0),'purchases_events',d.purchases,'purchases_source','orders') order by d.visits desc) from devices d),'[]'::jsonb),
       'locales',coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object('purchases',coalesce((v_ob->'locale'->>l.locale)::int,0),'purchases_events',l.purchases,'purchases_source','orders') order by l.visits desc) from locales l),'[]'::jsonb)),
    'daily_series',coalesce((select jsonb_agg(jsonb_build_object('date',d.d_day,
       'visitors',coalesce(x.visitors,0),
       'product_views',coalesce(x.product_views,0),
       'checkouts',coalesce(x.checkouts,0),
       'purchases',coalesce(x.purchases,0)) order by d.d_day) from days d left join daily x on x.event_date=d.d_day),'[]'::jsonb),
    'monthly_series',coalesce((select jsonb_agg(jsonb_build_object('month',mo.m_month,
       'visitors',coalesce(y.visitors,0),'product_views',coalesce(y.product_views,0),
       'checkouts',coalesce(y.checkouts,0),'purchases',coalesce(y.purchases,0)) order by mo.m_month) from months mo left join monthly y on y.m=mo.m_month),'[]'::jsonb),
    'aggregated_months',coalesce((select jsonb_agg(z.m order by z.m) from (select distinct to_char(ag.month,'YYYY-MM') m from ag) z),'[]'::jsonb)
  ) into result;
  return result;
end $function$
;

notify pgrst, 'reload schema';
