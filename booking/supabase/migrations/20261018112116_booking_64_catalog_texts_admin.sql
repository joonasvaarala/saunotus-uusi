-- ============================================================
-- booking_64_catalog_hidden_break_addons_texts_admin: PR #59 -jatko (Koodari) + päätös t125u
--  a) "tauko" on vain sisäinen: product_timeline_segments.customer_visible (oletus true). Piilotettu jakso lasketaan kestoon ja aikoihin (start_min/end_min), mutta EI näy
--     timeline[]-, timeline_text-, timeline_text_en-kentissä eikä site_texts-/public_get_site_texts-vastauksessa. Tuotteen 7 duration_text ilman sanaa tauko.
--  b) public_catalog(): addons_enabled (boolean) + allowed_addons (koodit). Slot-tuotteilla sallitut lisäpalvelut ovat taulussa booking.product_addon_allow (tuote 7: pyyhe),
--     public_create_treatment_booking hylkää muut (addon_not_allowed). Sääntöpohjaisilla tuotteilla johdetaan aktiivisten vuorosääntöjen tilasta (kuten ennen).
--  c) admin_texts_import: valinnainen needs_review / review_note riviä kohti.
--  d) Tekstit-näkymän admin-funktiot: admin_texts_list (kaikki tekstit, suodattimet) ja admin_texts_versions (versiohistoria nimineen).
--  Hintoja, ALV:tä tai URL:eja ei muuteta. Rollback: rollbacks/TEXTS_booking_64_ROLLBACK.sql
-- ============================================================
set local lock_timeout = '5s';

-- ---------- a) sisäinen tauko ----------
alter table booking.product_timeline_segments add column if not exists customer_visible boolean not null default true;
comment on column booking.product_timeline_segments.customer_visible is 'false = sisäinen jakso (esim. tauko): lasketaan kestoon, ei näy asiakkaalle (timeline, timeline_text, site_texts).';

create or replace function booking._timeline_json(p_product_id bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_dur integer; v_sum integer; v_n integer; v_segs jsonb; v_txt text; v_txt_en text; v_en_ok boolean;
begin
  select count(*), coalesce(sum(minutes), 0) into v_n, v_sum from booking.product_timeline_segments where product_id = p_product_id;
  if v_n = 0 then return null; end if;
  select duration_minutes into v_dur from booking.product_config where product_id = p_product_id;
  if v_dur is distinct from v_sum then return null; end if;
  select jsonb_agg(jsonb_build_object('seq', x.seq, 'kind', x.kind, 'label', x.label, 'label_en', x.label_en, 'minutes', x.minutes, 'start_min', x.st, 'end_min', x.st + x.minutes) order by x.seq),
         string_agg(x.label || ' ' || booking._fmt_minutes(x.minutes), ' · ' order by x.seq),
         string_agg(x.label_en || ' ' || booking._fmt_minutes(x.minutes), ' · ' order by x.seq),
         bool_and(x.label_en is not null)
    into v_segs, v_txt, v_txt_en, v_en_ok
    from (select s.*, coalesce(sum(s.minutes) over (order by s.seq rows between unbounded preceding and 1 preceding), 0)::int st
            from booking.product_timeline_segments s where s.product_id = p_product_id) x
   where x.customer_visible;
  if v_segs is null then return null; end if;
  return jsonb_build_object('segments', v_segs, 'text', v_txt, 'text_en', case when v_en_ok then v_txt_en end, 'total_minutes', v_sum);
end $$;

create or replace function booking._texts_register_sources() returns integer
language plpgsql security definer set search_path = '' as $fn$
declare n integer := 0; c text; pc text := $c$case when lower(coalesce(s.category, '')) in ('hinnat','varaaminen','booking','maksaminen','opening_hours','aukioloajat','käytännöt','practical','payment','cancellation','safety','accessibility','privacy','gift_card','season_card','training_terms','house_rules','dress_code') then 'protected' else 'normal' end$c$;
begin
  -- kb.products (aktiiviset): nimet/kuvaukset normal; kesto protected; hinta/slug/URL locked
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'name', 'name', $$'fi'$$, $$'normal'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'name', 'name_en', $$'en'$$, $$'normal'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'description', 'description', $$'fi'$$, $$'normal'$$, 's.active', 4000);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'description', 'description_en', $$'en'$$, $$'normal'$$, 's.active', 4000);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'duration_text', 'duration_text', $$'fi'$$, $$'protected'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'price_text', 'price_text', $$'fi'$$, $$'locked'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'slug', 'slug', $$'all'$$, $$'locked'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'booking_url', 'booking_url', $$'all'$$, $$'locked'$$, 's.active', 500);
  -- UKK
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'question', 'question', $$coalesce(nullif(s.language, ''), 'fi')$$, pc, 's.active', 500);
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'answer', 'answer', $$coalesce(nullif(s.language, ''), 'fi')$$, pc, 's.active', 6000);
  -- ehdot ja käytännöt (kaikki protected)
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'title', 'title', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false)$$, 300);
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'body', 'body', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false)$$, 20000);
  -- lisäpalvelut, tuotevalinnat, lahjakorttipaketit, vuorojen nimet
  foreach c in array array['name', 'description'] loop
    n := n + booking._texts_reg('booking.addons', 'id', 'addon', c, c, $$'fi'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.addons', 'id', 'addon', c, c || '_en', $$'en'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.product_options', 'id', 'option', c, c, $$'fi'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.product_options', 'id', 'option', c, c || '_en', $$'en'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', c, c, $$'fi'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', c, c || '_en', $$'en'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
  end loop;
  n := n + booking._texts_reg('booking.schedule_rules', 'id', 'schedule', 'label', 'label', $$'fi'$$, $$'normal'$$, 's.active', 200);
  -- sijainnit, aukioloajat, tapahtumat, yritys (kaikki protected: tosiasiat)
  foreach c in array array['name', 'description', 'directions', 'parking', 'public_transport', 'accessibility'] loop
    n := n + booking._texts_reg('kb.locations', 'id', 'location', c, c, $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 3000);
  end loop;
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'session_name', 'session_name', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'swimsuit_rule', 'swimsuit_rule', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 500);
  n := n + booking._texts_reg('kb.event_dates', 'id', 'event', 'time_text', 'time_text', $$'fi'$$, $$'protected'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.businesses', 'id', 'business', 'description', 'description', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 4000);
  -- booking_61: tuotteen lahjakorttihuomautus (product_config) ja aikajanan osavaiheiden nimet
  n := n + booking._texts_reg('booking.product_config', 'product_id', 'product_voucher', 'note', 'voucher_note', $$'fi'$$, $$'protected'$$, $$s.voucher_note is not null or s.voucher_note_en is not null$$, 600);
  n := n + booking._texts_reg('booking.product_config', 'product_id', 'product_voucher', 'note', 'voucher_note_en', $$'en'$$, $$'protected'$$, $$s.voucher_note is not null or s.voucher_note_en is not null$$, 600);
  n := n + booking._texts_reg('booking.product_timeline_segments', 'id', 'timeline', 'label', 'label', $$'fi'$$, $$'normal'$$, 's.customer_visible', 60);
  n := n + booking._texts_reg('booking.product_timeline_segments', 'id', 'timeline', 'label', 'label_en', $$'en'$$, $$'normal'$$, 's.customer_visible', 60);
  -- seed-versiot (versio 1 = nykyinen lähdeteksti)
  insert into booking.site_text_versions(text_id, version, text, status, base_version, author_kind, author_label, reason, published_at, escalation, protected)
  select t.id, 1, t.published_text, 'published', 0, 'system', 'seed booking_60', 'Alkutila lähdetaulusta', now(), '{}', false
    from booking.site_texts t where t.published_version = 1 and not exists (select 1 from booking.site_text_versions v where v.text_id = t.id);
  return n;
end $fn$;

create or replace function booking.admin_set_product_timeline(p_product_id bigint, p_segments jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare e jsonb; i int := 0; v_sum int := 0; v_dur int;
begin
  perform booking._require_permission('catalog.edit');
  if p_segments is null or jsonb_typeof(p_segments) <> 'array' then perform booking._err('invalid_segments', 'Osavaiheet väärässä muodossa'); end if;
  select duration_minutes into v_dur from booking.product_config where product_id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotetta ei löydy'); end if;
  for e in select * from jsonb_array_elements(p_segments) loop v_sum := v_sum + coalesce((e ->> 'minutes')::int, 0); end loop;
  if jsonb_array_length(p_segments) > 0 and v_sum <> v_dur then perform booking._err('timeline_sum', format('Osavaiheiden summa (%s min) ei vastaa tuotteen kestoa (%s min)', v_sum, v_dur)); end if;
  delete from booking.site_texts where source_table = 'booking.product_timeline_segments' and source_pk in (select id::text from booking.product_timeline_segments where product_id = p_product_id);
  delete from booking.product_timeline_segments where product_id = p_product_id;
  for e in select * from jsonb_array_elements(p_segments) loop
    i := i + 1;
    insert into booking.product_timeline_segments(product_id, seq, kind, label, label_en, minutes, customer_visible)
    values (p_product_id, i, e ->> 'kind', e ->> 'label', nullif(btrim(coalesce(e ->> 'label_en', '')), ''), (e ->> 'minutes')::int, coalesce((e ->> 'customer_visible')::boolean, true));
  end loop;
  perform booking._texts_register_sources();
  return jsonb_build_object('ok', true, 'segments', i);
end $$;

create or replace function booking.public_get_site_texts(p_lang text default null) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true, 'generated_at', now(), 'texts', coalesce(jsonb_agg(jsonb_build_object('key', t.key, 'lang', t.lang, 'text', t.published_text, 'version', t.published_version, 'placeholders', to_jsonb(t.placeholders))
                                                                                           order by t.key, t.lang), '[]'::jsonb))
    from booking.site_texts t
   where t.published_version > 0 and t.published_text <> '' and t.class <> 'locked' and (p_lang is null or t.lang = lower(btrim(p_lang)))
     and not (t.source_table = 'booking.product_timeline_segments' and exists (select 1 from booking.product_timeline_segments s where s.id::text = t.source_pk and not s.customer_visible)) $$;


-- ---------- b) lisäpalvelut tuotekohtaisesti ----------
create table booking.product_addon_allow (
  product_id bigint not null references kb.products(id) on delete cascade,
  addon_id bigint not null references booking.addons(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (product_id, addon_id)
);
alter table booking.product_addon_allow enable row level security;
revoke all on booking.product_addon_allow from anon, authenticated;

create or replace function booking._product_addon_codes(p_product_id bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare pc booking.product_config; v_cat text; v_modes text[];
begin
  select * into pc from booking.product_config where product_id = p_product_id;
  if not found then return '[]'::jsonb; end if;
  select category into v_cat from kb.products where id = p_product_id;
  if v_cat = 'event' then return '[]'::jsonb; end if;
  if pc.public_slots or (pc.sale_kind = 'other' and pc.resource_class = 'resourced') then
    return coalesce((select jsonb_agg(a.code order by a.sort_order, a.id) from booking.product_addon_allow pa join booking.addons a on a.id = pa.addon_id
                      where pa.product_id = p_product_id and a.active and 'resource' = any (a.applies_modes)), '[]'::jsonb);
  end if;
  select array_agg(distinct r.mode::text) into v_modes from booking.schedule_rules r where r.product_id = p_product_id and r.active;
  return coalesce((select jsonb_agg(a.code order by a.sort_order, a.id) from booking.addons a where a.active and a.applies_modes && coalesce(v_modes, '{}'::text[])), '[]'::jsonb);
end $$;
revoke all on function booking._product_addon_codes(bigint) from public, anon, authenticated;

create or replace function booking.public_catalog() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
      'description', p.description, 'description_en', p.description_en,
      'category', p.category, 'sale_kind', pc.sale_kind,
      'price', p.price, 'price_type', p.price_type, 'price_text', p.price_text,
      'duration_text', p.duration_text, 'duration_minutes', p.duration_minutes,
      'min_persons', pc.min_persons, 'max_persons', case when pc.public_slots then booking._treatment_max_persons(p.id) else pc.max_persons end,
      'booking_kind', case when pc.public_slots then 'slots' else 'rules' end, 'slot_grid_minutes', case when pc.public_slots then 30 end,
      'options', booking._product_options_json(p.id, true), 'option_required', (pc.option_required and exists (select 1 from booking.product_options x where x.product_id = p.id and x.active)),
      'option_label', pc.option_label, 'option_label_en', pc.option_label_en,
      'voucher_note', pc.voucher_note, 'voucher_note_en', pc.voucher_note_en,
      'addons_enabled', (jsonb_array_length(booking._product_addon_codes(p.id)) > 0), 'allowed_addons', booking._product_addon_codes(p.id),
      'timeline', booking._timeline_json(p.id) -> 'segments', 'timeline_text', booking._timeline_json(p.id) ->> 'text', 'timeline_text_en', booking._timeline_json(p.id) ->> 'text_en'
    ) order by pc.sort_order, p.id), '[]'::jsonb)
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
    and (pc.public_slots or exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active)) $$;

drop function if exists booking.public_create_treatment_booking(bigint, timestamptz, integer, text, text, text, boolean, text, text, text, jsonb, text, jsonb);
create or replace function booking.public_create_treatment_booking(p_product_id bigint, p_start timestamp with time zone, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_option_code text DEFAULT NULL::text, p_addons jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '3s'
AS $function$
declare
  v_ip text := booking._client_ip();
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private'))); v_is_company boolean; v_company jsonb;
  v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}'; v_invoice boolean; v_hold_mode boolean; v_group boolean; v_hmin int; v_thr int := booking._checkout_cfg_int('checkout_group_threshold_persons', 0, 0, 1000);
  v_cust bigint; v_res jsonb; v_end timestamptz; v_total numeric; v_token uuid; v_detail text; v_msg text; v_pay_method text; v_order bigint; v_opt bigint; v_add numeric := 0;
begin
  if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
    return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
  end if;
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select k.is_company into v_is_company from booking.customer_kinds k where k.code = v_kind and k.active;
  if v_is_company is null then return jsonb_build_object('ok', false, 'code', 'invalid_customer_kind', 'message', 'Valitse asiakastyyppi (yksityinen / yritys)'); end if;
  v_invoice := v_is_company and coalesce((booking._setting('checkout_company_invoice_enabled', 'true'::jsonb) #>> '{}')::boolean, true);
  v_hold_mode := v_mode <> 'pay_later' and not v_invoice;                        -- booking_53: pitotila
  v_group := v_hold_mode and v_thr > 0 and coalesce(p_persons, 0) >= v_thr;
  if v_hold_mode and not v_group and not booking._checkout_online_available() then
    return jsonb_build_object('ok', false, 'code', 'online_payment_unavailable', 'message', 'Verkkomaksu ei ole tilapäisesti käytettävissä – varausta ei voi tehdä juuri nyt');
  end if;
  v_hmin := case when not v_hold_mode then 0 when v_group then booking._checkout_cfg_int('checkout_group_hold_days', 7, 1, 60) * 1440 else booking._checkout_hold_minutes() end;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', case when v_is_company then 'Anna yhteyshenkilön nimi' else 'Anna nimi' end);
  end if;
  if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
  if p_note is not null and char_length(p_note) > 1000 then return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä'); end if;
  -- suojakatkaisimet: pay_later ei vaadi maksua -> rajataan väärinkäyttö (sähköposti / kokonaismäärä)
  if (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id join booking.reservations r on r.order_id = o.id
        join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots
       where lower(c.email) = v_email and o.source_channel = 'web' and o.status = 'confirmed' and r.status = 'confirmed' and r.starts_at > now()
         and o.payment_status = 'unpaid') >= coalesce((booking._setting('public_treatment_max_open_per_email', '5'::jsonb) #>> '{}')::int, 5) then
    return jsonb_build_object('ok', false, 'code', 'too_many_open', 'message', 'Sinulla on jo useita tulevia varauksia – ota yhteyttä sähköpostitse');
  end if;
  if v_hold_mode and (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id
       where lower(c.email) = v_email and o.status = 'pending' and o.created_at > now() - interval '1 hour') >= 3 then
    return jsonb_build_object('ok', false, 'code', 'too_many_pending', 'message', 'Sinulla on jo useita keskeneräisiä varauksia');
  end if;
  if (select count(*) from booking.orders o join booking.reservations r on r.order_id = o.id join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots
       where o.source_channel = 'web' and o.created_at > now() - interval '1 hour') >= coalesce((booking._setting('public_treatment_global_per_hour', '30'::jsonb) #>> '{}')::int, 30) then
    return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'Verkkovarauksia tehdään nyt poikkeuksellisen paljon – yritä myöhemmin uudelleen');
  end if;

  begin  -- alitransaktio: virhe kumoaa asiakkaan/tilauksen/varauksen luonnin mutta rate limit -kirjaus säilyy
    v_end := booking._treatment_slot_check(p_product_id, p_start, p_persons, true);       -- uudelleenvalidointi luontihetkellä (päivä, aikaikkuna, ruudukko, henkilömäärä)
    v_opt := booking._resolve_product_option(p_product_id, p_option_code, true);          -- booking_50: tuotevalinta (option_required / invalid_option)
    if v_is_company then v_company := booking._clean_company(p_company); end if;
    if v_is_company then
      v_cust := booking._upsert_company_customer(v_kind, v_name, v_email, v_phone, v_company, p_marketing_consent, 'web_booking', p_locale, (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    else
      v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale, (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    end if;
    v_total := booking._treatment_price(p_product_id, p_persons);
    -- ei override-polkua; ei vapaata saunottajaa -> therapist_missing (booking_22) ellei päivä ole suljettu (therapist_closed nousee virheenä)
    perform set_config('booking.checkout_hold_minutes', v_hmin::text, true);
    perform set_config('booking.checkout_hold_kind', case when v_group then 'preliminary' else 'checkout' end, true);
    v_res := booking._create_legs_booking('current', p_product_id, p_start, v_end, p_persons, v_cust, 'web', null, p_note, v_total, null, false, null, false, null, null, p_option_code);
    perform set_config('booking.checkout_hold_minutes', '', true);
    perform set_config('booking.checkout_hold_kind', '', true);
    v_order := (v_res ->> 'order_id')::bigint;
    perform booking._stamp_order_billing(v_order, v_cust, v_company);
    v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);      -- booking_61: lisäpalvelut (resurssivaraus: esim. pyyhe); virheet BK001 -> addon_* -koodit
    v_total := v_total + v_add;
    if exists (select 1 from booking.order_items it where it.order_id = v_order and it.kind = 'addon' and it.addon_id is not null
                and it.addon_id not in (select pa.addon_id from booking.product_addon_allow pa where pa.product_id = p_product_id)) then
      perform booking._err('addon_not_allowed', 'Lisäpalvelu ei ole saatavilla tälle tuotteelle');   -- booking_64: tuotekohtainen sallittujen lisäpalvelujen lista
    end if;
    v_pay_method := case when v_is_company then 'invoice' else 'pay_later' end;
    if not v_hold_mode then   -- pitotilassa ei paikkaajamaksua
      insert into booking.payments(order_id, method, provider, status, amount) values (v_order, v_pay_method, 'manual', 'pending', v_total);
    end if;
    update booking.orders set payment_status = 'unpaid' where id = v_order returning public_token into v_token;
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return booking._public_slot_error(v_detail, v_msg);
    when exclusion_violation then
      return booking._public_slot_error('slot_unavailable', null);
    when lock_not_available then
      return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'Järjestelmä on hetkellä kiireinen, yritä hetken kuluttua uudelleen');
  end;

  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_token, 'status', case when v_hold_mode then 'pending' else 'confirmed' end, 'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at',
                            'persons', p_persons, 'total', v_total, 'addons_total', v_add, 'payment_mode', case when v_hold_mode then v_mode else 'pay_later' end, 'payment_url', null, 'hold_expires_at', v_res -> 'hold_expires_at',
                            'product_name', v_res -> 'product_name', 'customer_kind', v_kind, 'booking_kind', 'slots', 'option', booking._option_json(v_opt))
         || booking._checkout_state_json(v_order);
end $function$;
revoke all on function booking.public_create_treatment_booking(bigint, timestamptz, integer, text, text, text, boolean, text, text, text, jsonb, text, jsonb) from public;
grant execute on function booking.public_create_treatment_booking(bigint, timestamptz, integer, text, text, text, boolean, text, text, text, jsonb, text, jsonb) to anon, authenticated, service_role;

-- ---------- c) tuonti: needs_review ----------
create or replace function booking.admin_texts_import(p_items jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare e jsonb; v_key text; v_lang text; v_class text; v_kind text; v_max int; v_ph text[]; v_text text; v_rev boolean; v_id bigint; v_res jsonb := '[]'::jsonb; n_new int := 0; n_exist int := 0; v_status text; v_msg text; v_detail text;
begin
  perform booking._text_perm('texts.manage');
  if p_items is null or jsonb_typeof(p_items) <> 'array' then perform booking._err('invalid_items', 'p_items pitää olla taulukko'); end if;
  if jsonb_array_length(p_items) > 500 then perform booking._err('too_many', 'Enintään 500 riviä / kutsu'); end if;
  for e in select * from jsonb_array_elements(p_items) loop
    begin  -- yksi virheellinen rivi ei kaada muita
      v_key := lower(btrim(coalesce(e ->> 'key', ''))); v_lang := lower(btrim(coalesce(e ->> 'lang', ''))); v_class := coalesce(nullif(e ->> 'class', ''), 'normal');
      v_kind := coalesce(nullif(e ->> 'kind', ''), 'plain'); v_max := coalesce(nullif(e ->> 'max_len', '')::int, 4000); v_text := e ->> 'text'; v_rev := coalesce((e ->> 'needs_review')::boolean, false);
      v_ph := coalesce((select array_agg(distinct x order by x) from jsonb_array_elements_text(coalesce(e -> 'placeholders', '[]'::jsonb)) x), '{}');
      if v_key !~ '^[a-z0-9_]+(\.[a-z0-9_-]+)+$' or char_length(v_key) > 120 then perform booking._err('invalid_key', 'Virheellinen avain'); end if;
      if v_key ~ '^(product|faq|policy|addon|option|giftpkg|schedule|location|hours|event|business|timeline|product_voucher)\.[0-9a-z_-]+\.' then perform booking._err('reserved_key', 'Avainprefiksi on varattu lähdetaulupohjaisille teksteille'); end if;
      if v_lang not in ('fi', 'en') then perform booking._err('invalid_lang', 'Kieli fi tai en'); end if;
      if v_class not in ('normal', 'protected') then perform booking._err('invalid_class', 'Luokka normal tai protected (locked-rivit vain lähdetauluista)'); end if;
      if v_kind not in ('plain', 'lite') then perform booking._err('invalid_kind', 'kind plain tai lite'); end if;
      if v_max not between 1 and 100000 then perform booking._err('invalid_max_len', 'max_len 1–100000'); end if;
      perform booking._text_validate(v_class, v_kind, v_max, v_ph, v_text);
      if exists (select 1 from booking.site_texts where key = v_key and lang = v_lang) then
        n_exist := n_exist + 1; v_res := v_res || jsonb_build_array(jsonb_build_object('key', v_key, 'lang', v_lang, 'result', 'exists'));
      else
        insert into booking.site_texts(key, lang, class, kind, max_len, placeholders, published_text, published_version, latest_version, status, published_at, needs_review, review_note)
        values (v_key, v_lang, v_class, v_kind, v_max, v_ph, v_text, 1, 1, 'published', now(), v_rev, case when v_rev then coalesce(nullif(btrim(coalesce(e ->> 'review_note', '')), ''), 'Tarkistettava (tuonti)') end) returning id into v_id;
        insert into booking.site_text_versions(text_id, version, text, status, base_version, author, author_kind, author_label, reason, published_by, published_at, escalation, protected)
        values (v_id, 1, v_text, 'published', 0, auth.uid(), booking._text_actor_kind(), coalesce(auth.uid()::text, 'sql'), coalesce(nullif(btrim(coalesce(e ->> 'reason', '')), ''), 'Tuonti (admin_texts_import)'), auth.uid(), now(), '{}', v_class = 'protected');
        perform booking._text_audit('TEXT_IMPORT', v_id, 1, jsonb_build_object('key', v_key, 'lang', v_lang, 'class', v_class));
        n_new := n_new + 1; v_res := v_res || jsonb_build_array(jsonb_build_object('key', v_key, 'lang', v_lang, 'result', 'created'));
      end if;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      v_res := v_res || jsonb_build_array(jsonb_build_object('key', e ->> 'key', 'lang', e ->> 'lang', 'result', 'error', 'code', v_detail, 'message', v_msg));
    end;
  end loop;
  return jsonb_build_object('ok', true, 'created', n_new, 'existing', n_exist, 'errors', jsonb_array_length(v_res) - n_new - n_exist, 'items', v_res);
end $$;

-- ---------- d) Tekstit-näkymän admin-funktiot ----------
create or replace function booking.admin_texts_list(p_prefix text default null, p_lang text default null, p_status text default null, p_class text default null, p_q text default null,
                                                    p_needs_review boolean default null, p_missing boolean default false, p_pending boolean default false,
                                                    p_limit integer default 100, p_offset integer default 0) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_lim int := least(greatest(coalesce(p_limit, 100), 1), 500); v_off int := greatest(coalesce(p_offset, 0), 0); v_q text := lower(btrim(coalesce(p_q, ''))); v_total int; v_items jsonb;
begin
  perform booking._text_perm_any(array['texts.approve', 'texts.approve_protected', 'texts.manage']);
  select count(*) into v_total from booking.site_texts t
   where (p_prefix is null or t.key like lower(btrim(p_prefix)) || '%') and (p_lang is null or t.lang = p_lang) and (p_status is null or t.status = p_status) and (p_class is null or t.class = p_class)
     and (v_q = '' or position(v_q in lower(t.key)) > 0 or position(v_q in lower(t.published_text)) > 0) and (p_needs_review is null or t.needs_review = p_needs_review)
     and (not coalesce(p_missing, false) or (t.published_text = '' and t.class <> 'locked'))
     and (not coalesce(p_pending, false) or exists (select 1 from booking.site_text_versions v where v.text_id = t.id and v.status in ('draft', 'proposed', 'approved')));
  select coalesce(jsonb_agg(x.j order by x.key, x.lang), '[]'::jsonb) into v_items from (
    select t.key, t.lang, jsonb_build_object('key', t.key, 'lang', t.lang, 'class', t.class, 'kind', t.kind, 'max_len', t.max_len, 'placeholders', to_jsonb(t.placeholders),
             'text', t.published_text, 'version', t.published_version, 'latest_version', t.latest_version, 'status', t.status, 'needs_translation', t.needs_translation,
             'needs_review', t.needs_review, 'review_note', t.review_note, 'published_at', t.published_at, 'updated_at', t.updated_at,
             'source', case when t.source_table is null then null else t.source_table || '.' || t.source_column end,
             'pending_count', (select count(*) from booking.site_text_versions v where v.text_id = t.id and v.status in ('draft', 'proposed', 'approved')),
             'pending_protected', exists (select 1 from booking.site_text_versions v where v.text_id = t.id and v.status in ('proposed', 'approved') and v.protected),
             'editable', t.class <> 'locked') j
      from booking.site_texts t
     where (p_prefix is null or t.key like lower(btrim(p_prefix)) || '%') and (p_lang is null or t.lang = p_lang) and (p_status is null or t.status = p_status) and (p_class is null or t.class = p_class)
       and (v_q = '' or position(v_q in lower(t.key)) > 0 or position(v_q in lower(t.published_text)) > 0) and (p_needs_review is null or t.needs_review = p_needs_review)
       and (not coalesce(p_missing, false) or (t.published_text = '' and t.class <> 'locked'))
       and (not coalesce(p_pending, false) or exists (select 1 from booking.site_text_versions v where v.text_id = t.id and v.status in ('draft', 'proposed', 'approved')))
     order by t.key, t.lang limit v_lim offset v_off) x;
  return jsonb_build_object('ok', true, 'total', v_total, 'limit', v_lim, 'offset', v_off, 'items', v_items);
end $$;

create or replace function booking.admin_texts_versions(p_key text, p_lang text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare t booking.site_texts;
begin
  perform booking._text_perm_any(array['texts.approve', 'texts.approve_protected', 'texts.manage']);
  select * into t from booking.site_texts where key = lower(btrim(coalesce(p_key, ''))) and lang = lower(btrim(coalesce(p_lang, '')));
  if not found then perform booking._err('not_found', 'Tekstiä ei löydy'); end if;
  return jsonb_build_object('ok', true,
    'text', jsonb_build_object('key', t.key, 'lang', t.lang, 'class', t.class, 'kind', t.kind, 'max_len', t.max_len, 'placeholders', to_jsonb(t.placeholders), 'text', t.published_text,
             'version', t.published_version, 'status', t.status, 'needs_review', t.needs_review, 'review_note', t.review_note, 'needs_translation', t.needs_translation, 'editable', t.class <> 'locked'),
    'versions', (select coalesce(jsonb_agg(jsonb_build_object('version_id', v.id, 'version', v.version, 'status', v.status, 'text', v.text, 'base_version', v.base_version, 'protected', v.protected,
                   'escalation', to_jsonb(v.escalation), 'author_kind', v.author_kind, 'proposed_by', booking._text_user_label(v.author), 'proposed_at', v.created_at, 'reason', v.reason, 'note', v.note,
                   'approved_by', booking._text_user_label(v.approved_by), 'approved_at', v.approved_at, 'published_by', booking._text_user_label(v.published_by), 'published_at', v.published_at,
                   'rejected_by', booking._text_user_label(v.rejected_by), 'rejected_at', v.rejected_at,
                   'can_rollback', v.status in ('published', 'superseded') and v.version <> t.published_version and t.class <> 'locked',
                   'is_current', v.version = t.published_version and v.status = 'published') order by v.version desc), '[]'::jsonb)
                   from booking.site_text_versions v where v.text_id = t.id));
end $$;
revoke all on function booking.admin_texts_list(text, text, text, text, text, boolean, boolean, boolean, integer, integer), booking.admin_texts_versions(text, text) from public, anon, authenticated;
grant execute on function booking.admin_texts_list(text, text, text, text, text, boolean, boolean, boolean, integer, integer), booking.admin_texts_versions(text, text) to authenticated, service_role;

-- ---------- sisältö ----------
insert into booking.product_addon_allow(product_id, addon_id) select 7, id from booking.addons where code = 'pyyhe' on conflict do nothing;
-- tauko sisäiseksi (jakso säilyy kestossa ja aikalaskennassa); asiakasnäkyvät tekstit ilman sanaa tauko
update booking.product_timeline_segments set customer_visible = false where product_id = 7 and kind = 'break';
delete from booking.site_texts where source_table = 'booking.product_timeline_segments' and source_pk in (select id::text from booking.product_timeline_segments where not customer_visible);
update kb.products set duration_text = 'rituaali 20 min + savusauna 1 h 30 min (yhteensä 2 h)' where id = 7 and duration_text ~* 'tauko';
