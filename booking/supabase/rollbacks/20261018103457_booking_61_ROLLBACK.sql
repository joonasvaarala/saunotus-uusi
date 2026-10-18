-- Rollback booking_61: palauttaa public_catalog / public_create_treatment_booking / _public_slot_error / tekstijärjestelmän funktiot booking_60/58-tilaan, poistaa aikajanataulun ja uudet kentät,
-- palauttaa tuotteen 7 kuvauksen (lahjakorttihuomautus takaisin kuvauksen loppuun, EN tyhjä). Hintoja ei kosketa. Ostoikkuna-asetus palautetaan yksityiseksi.
set local lock_timeout = '5s';
-- 1) tuotteen 7 sisältö takaisin (ei kirjata uutena julkaisuna: booking.text_apply)
select set_config('booking.text_apply', 'on', true);
update kb.products set description = $d$Avoin saunarituaali lauantaisin ja sunnuntaisin: vuoro alkaa 20 minuutin saunotusrituaalilla hoitosauna Raunissa (pienryhmä, enintään 6 osallistujaa), josta siirrytään savusaunaan. Sisältää löylyntervehdyksen, kevyttä lämmittelyvihdontaa ja vuodenkierron mukaisen minihoidon sekä pääsyn sauna-alueelle, altaisiin ja laavulle. Rituaaliin voi tulla alasti, mutta savusaunassa ja paljuissa käytetään uima-asua. Ohjelma vaihtuu vuodenaikojen mukaan. Elämyslahjojen lahjakortilla: varaa ensin yleinen vuoro ja osta rituaali erikseen.$d$, description_en = null where id = 7;
select set_config('booking.text_apply', '', true);
update booking.site_texts set published_text = $d$Avoin saunarituaali lauantaisin ja sunnuntaisin: vuoro alkaa 20 minuutin saunotusrituaalilla hoitosauna Raunissa (pienryhmä, enintään 6 osallistujaa), josta siirrytään savusaunaan. Sisältää löylyntervehdyksen, kevyttä lämmittelyvihdontaa ja vuodenkierron mukaisen minihoidon sekä pääsyn sauna-alueelle, altaisiin ja laavulle. Rituaaliin voi tulla alasti, mutta savusaunassa ja paljuissa käytetään uima-asua. Ohjelma vaihtuu vuodenaikojen mukaan. Elämyslahjojen lahjakortilla: varaa ensin yleinen vuoro ja osta rituaali erikseen.$d$, published_version = published_version where key = 'product.7.description' and lang = 'fi';
delete from booking.site_text_versions where text_id in (select id from booking.site_texts where key = 'product.7.description' and lang = 'en');
update booking.site_texts set published_text = '', published_version = 0, latest_version = 0, status = 'empty', needs_translation = false where key = 'product.7.description' and lang = 'en';
-- FI-version 2 (puhdistettu) poistetaan historiasta; v1 palautetaan julkaistuksi
delete from booking.site_text_versions where text_id = (select id from booking.site_texts where key = 'product.7.description' and lang = 'fi') and version > 1;
update booking.site_text_versions set status = 'published' where text_id = (select id from booking.site_texts where key = 'product.7.description' and lang = 'fi') and version = 1;
update booking.site_texts set published_version = 1, latest_version = 1, status = 'published' where key = 'product.7.description' and lang = 'fi';
-- 2) uudet lähderivit pois (versiot kaskadina)
delete from booking.site_texts where source_table in ('booking.product_config', 'booking.product_timeline_segments');
-- 3) triggerit ja oikeudet pois, funktiot takaisin
drop trigger if exists zz_site_text_sync on booking.product_config;
drop trigger if exists zz_site_text_sync on booking.product_timeline_segments;
drop function if exists booking.admin_set_product_timeline(bigint, jsonb);
drop function if exists booking.admin_texts_review_queue(integer);
drop function if exists booking.admin_texts_mark_reviewed(text, text, text);
create or replace function booking.public_catalog()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
      'description', p.description, 'description_en', p.description_en,
      'category', p.category, 'sale_kind', pc.sale_kind,
      'price', p.price, 'price_type', p.price_type, 'price_text', p.price_text,
      'duration_text', p.duration_text, 'duration_minutes', p.duration_minutes,
      'min_persons', pc.min_persons, 'max_persons', case when pc.public_slots then booking._treatment_max_persons(p.id) else pc.max_persons end,
      'booking_kind', case when pc.public_slots then 'slots' else 'rules' end, 'slot_grid_minutes', case when pc.public_slots then 30 end,
      'options', booking._product_options_json(p.id, true), 'option_required', (pc.option_required and exists (select 1 from booking.product_options x where x.product_id = p.id and x.active)),
      'option_label', pc.option_label, 'option_label_en', pc.option_label_en
    ) order by pc.sort_order, p.id), '[]'::jsonb)
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
    and (pc.public_slots or exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active))
$function$;

drop function if exists booking._timeline_json(bigint);
drop function if exists booking._fmt_minutes(integer);
drop table if exists booking.product_timeline_segments;
alter table booking.product_config drop column if exists voucher_note, drop column if exists voucher_note_en;
create or replace function booking._public_slot_error(p_detail text, p_msg text) returns jsonb
language sql immutable set search_path = '' as $$
  select case when p_detail in ('not_bookable', 'invalid_persons', 'bad_slot', 'too_soon', 'too_far', 'invalid_date', 'not_offered_day', 'ritual_start', 'time_window',
                                'change_too_late', 'price_change_requires_staff', 'vat_missing', 'option_required', 'invalid_option')
              then jsonb_build_object('ok', false, 'code', p_detail, 'message', p_msg)
              else jsonb_build_object('ok', false, 'code', 'slot_unavailable', 'message', 'Valittu aika ei ole enää varattavissa – valitse toinen aika') end $$;

drop function if exists booking.public_create_treatment_booking(bigint, timestamptz, integer, text, text, text, boolean, text, text, text, jsonb, text, jsonb);
create or replace function booking.public_create_treatment_booking(p_product_id bigint, p_start timestamp with time zone, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_option_code text DEFAULT NULL::text)
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
  v_cust bigint; v_res jsonb; v_end timestamptz; v_total numeric; v_token uuid; v_detail text; v_msg text; v_pay_method text; v_order bigint; v_opt bigint;
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
                            'persons', p_persons, 'total', v_total, 'payment_mode', case when v_hold_mode then v_mode else 'pay_later' end, 'payment_url', null, 'hold_expires_at', v_res -> 'hold_expires_at',
                            'product_name', v_res -> 'product_name', 'customer_kind', v_kind, 'booking_kind', 'slots', 'option', booking._option_json(v_opt))
         || booking._checkout_state_json(v_order);
end $function$;

revoke all on function booking.public_create_treatment_booking(bigint, timestamptz, integer, text, text, text, boolean, text, text, text, jsonb, text) from public;
grant execute on function booking.public_create_treatment_booking(bigint, timestamptz, integer, text, text, text, boolean, text, text, text, jsonb, text) to anon, authenticated, service_role;
update booking.settings set is_public = false where key = 'public_treatment_horizon_days';
create or replace function booking._text_publish(p_version_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare v booking.site_text_versions; t booking.site_texts; n int;
begin
  select * into v from booking.site_text_versions where id = p_version_id for update;
  select * into t from booking.site_texts where id = v.text_id for update;
  if t.source_table is not null then
    perform set_config('booking.text_apply', 'on', true);
    execute format('update %s set %I = $1 where %I::text = $2', t.source_table, t.source_column, t.source_pk_col) using v.text, t.source_pk;
    get diagnostics n = row_count;
    perform set_config('booking.text_apply', '', true);
    if n <> 1 then perform booking._err('source_missing', 'Lähderiviä ei löydy tekstille ' || t.key); end if;
  end if;
  update booking.site_text_versions set status = 'superseded' where text_id = t.id and status = 'published' and id <> v.id;
  update booking.site_text_versions set status = 'stale', note = coalesce(note || ' | ', '') || 'vanhentunut: toinen versio julkaistiin'
   where text_id = t.id and id <> v.id and status in ('draft', 'proposed', 'approved') and version < v.version;
  update booking.site_text_versions set status = 'published', published_by = auth.uid(), published_at = now() where id = v.id;
  update booking.site_texts set published_text = v.text, published_version = v.version, published_at = now(), needs_translation = false where id = t.id;
  if t.lang in ('fi', 'en') then
    update booking.site_texts set needs_translation = true where key = t.key and lang in ('fi', 'en') and lang <> t.lang and published_version > 0;
  end if;
  perform booking._text_refresh(t.id);
  perform booking._text_audit('TEXT_PUBLISH', t.id, v.version, jsonb_build_object('key', t.key, 'lang', t.lang, 'protected', v.protected, 'escalation', v.escalation));
end $$;
create or replace function booking._text_json(t booking.site_texts) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', t.id, 'key', t.key, 'lang', t.lang, 'class', t.class, 'kind', t.kind, 'max_len', t.max_len, 'placeholders', to_jsonb(t.placeholders),
    'text', t.published_text, 'version', t.published_version, 'status', t.status, 'needs_translation', t.needs_translation, 'published_at', t.published_at,
    'pending', (select coalesce(jsonb_agg(jsonb_build_object('version_id', v.id, 'version', v.version, 'status', v.status, 'text', v.text, 'protected', v.protected, 'escalation', to_jsonb(v.escalation),
                  'author_kind', v.author_kind, 'author_label', v.author_label, 'reason', v.reason, 'created_at', v.created_at) order by v.version), '[]'::jsonb)
                  from booking.site_text_versions v where v.text_id = t.id and v.status in ('draft', 'proposed', 'approved'))) $$;


create or replace function booking._text_source_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r booking.site_texts; v_new text; v_ver int; v_pk text := coalesce(to_jsonb(new) ->> 'id', to_jsonb(new) ->> 'code');
begin
  if coalesce(current_setting('booking.text_apply', true), '') = 'on' then return null; end if;
  for r in select * from booking.site_texts t where t.source_table = tg_table_schema || '.' || tg_table_name and t.source_pk = v_pk loop
    v_new := coalesce(to_jsonb(new) ->> r.source_column, '');
    continue when v_new = r.published_text;
    select coalesce(max(version), 0) + 1 into v_ver from booking.site_text_versions where text_id = r.id;
    update booking.site_text_versions set status = 'superseded' where text_id = r.id and status = 'published';
    update booking.site_text_versions set status = 'stale', note = 'vanhentunut: lähdetaulua muokattu suoraan' where text_id = r.id and status in ('draft', 'proposed', 'approved');
    insert into booking.site_text_versions(text_id, version, text, status, base_version, author, author_kind, author_label, reason, published_by, published_at, escalation, protected)
    values (r.id, v_ver, v_new, 'published', r.published_version, auth.uid(), case when auth.uid() is null then 'system' else 'human' end, coalesce(auth.uid()::text, 'sql'),
            'Muokattu suoraan lähdetaulussa (' || tg_table_schema || '.' || tg_table_name || ')', auth.uid(), now(), booking._text_escalation(r.published_text, v_new), false);
    update booking.site_texts set published_text = v_new, published_version = v_ver, published_at = now(),
           needs_translation = false where id = r.id;
    if r.lang in ('fi', 'en') then update booking.site_texts set needs_translation = true where key = r.key and lang in ('fi', 'en') and lang <> r.lang and published_version > 0; end if;
    perform booking._text_refresh(r.id);
    perform booking._text_audit('TEXT_DIRECT_EDIT', r.id, v_ver, jsonb_build_object('key', r.key, 'table', tg_table_schema || '.' || tg_table_name));
  end loop;
  return null;
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
  -- seed-versiot (versio 1 = nykyinen lähdeteksti)
  insert into booking.site_text_versions(text_id, version, text, status, base_version, author_kind, author_label, reason, published_at, escalation, protected)
  select t.id, 1, t.published_text, 'published', 0, 'system', 'seed booking_60', 'Alkutila lähdetaulusta', now(), '{}', false
    from booking.site_texts t where t.published_version = 1 and not exists (select 1 from booking.site_text_versions v where v.text_id = t.id);
  return n;
end $fn$;


alter table booking.site_texts drop constraint if exists site_texts_source_table_check;
alter table booking.site_texts add constraint site_texts_source_table_check check (source_table in ('kb.products', 'kb.faq', 'kb.policies', 'kb.locations', 'kb.opening_hours', 'kb.event_dates', 'kb.businesses', 'booking.addons', 'booking.product_options', 'booking.gift_card_packages', 'booking.schedule_rules'));
alter table booking.site_texts drop constraint if exists site_texts_source_pk_col_check;
alter table booking.site_texts add constraint site_texts_source_pk_col_check check (source_pk_col in ('id', 'code'));
alter table booking.site_texts drop column if exists needs_review, drop column if exists review_note;
