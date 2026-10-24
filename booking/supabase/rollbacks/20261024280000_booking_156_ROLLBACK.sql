-- ROLLBACK booking_156 (migraatio 20261024280000_booking_156_product_short_description.sql). Uudelleenajettava (toinen ajo ei tee mitään).
-- HUOM: poistaa sarakkeet kb.products.short_description / short_description_en sekä niiden site_texts-rivit ja versiot pysyvästi.
-- Ota ennen ajoa talteen: select id, short_description, short_description_en from kb.products where short_description is not null or short_description_en is not null;
-- Palauttaa funktiot täsmälleen tuotannon muotoon ennen booking_156:ta (pg_get_functiondef-tuloste sellaisenaan). Odotetut md5(pg_get_functiondef) ajon jälkeen:
--   booking._texts_reg: 957899c59fa87e65994a9ffacb59ab8f
--   booking._texts_register_sources: 288af591eefb49d9ad48a7958c44ef14
--   booking.admin_update_product: 3cca4125054a32111235a25a5b8402de
--   booking.admin_product_create: 0516c7f53b7eae66b04522382ed1c1fb
--   booking.admin_list_products: a78891b910ae65a7ea7583979ede71d4
--   booking.public_catalog: a55b3a8bf0d3e8820f83b139b58f6057
-- Tarkistus: select p.proname, md5(pg_get_functiondef(p.oid)) from pg_proc p where p.pronamespace = 'booking'::regnamespace
--   and p.proname in ('_texts_reg','_texts_register_sources','admin_update_product','admin_product_create','admin_list_products','public_catalog') order by 1;
set local lock_timeout = '5s';

delete from booking.site_text_versions where text_id in (select id from booking.site_texts where source_table = 'kb.products' and source_column in ('short_description', 'short_description_en'));
delete from booking.site_texts where source_table = 'kb.products' and source_column in ('short_description', 'short_description_en');

CREATE OR REPLACE FUNCTION booking._texts_reg(p_table text, p_pk_col text, p_prefix text, p_field text, p_column text, p_lang_sql text, p_class_sql text, p_where text, p_max integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n integer; v_kind text := 'plain'; v_max integer;
begin
  if p_table = 'kb.products' and p_field = 'description' then v_kind := 'rich'; v_max := 8000; else v_max := p_max; end if;
  execute format($q$insert into booking.site_texts(key, lang, class, kind, max_len, source_table, source_pk_col, source_pk, source_column, published_text, published_version, latest_version, status)
    select %1$L || '.' || s.%2$I::text || '.' || %3$L, %4$s, %5$s, %10$L, %6$s, %7$L, %2$L, s.%2$I::text, %8$L, coalesce(s.%8$I, ''),
           case when btrim(coalesce(s.%8$I, '')) <> '' then 1 else 0 end, case when btrim(coalesce(s.%8$I, '')) <> '' then 1 else 0 end,
           case when btrim(coalesce(s.%8$I, '')) <> '' then 'published' else 'empty' end
      from %7$s s where %9$s on conflict do nothing$q$, p_prefix, p_pk_col, p_field, p_lang_sql, p_class_sql, v_max, p_table, p_column, p_where, v_kind);
  get diagnostics n = row_count;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION booking._texts_register_sources()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n integer := 0; c text; pc text := $c$case when lower(coalesce(s.category, '')) in ('hinnat','varaaminen','booking','maksaminen','opening_hours','aukioloajat','käytännöt','practical','payment','cancellation','safety','accessibility','privacy','gift_card','season_card','training_terms','house_rules','dress_code') then 'protected' else 'normal' end$c$;
begin
  -- kb.products (aktiiviset): nimet/kuvaukset normal; kesto protected; hinta/slug/URL locked
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'name', 'name', $$'fi'$$, $$'normal'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'name', 'name_en', $$'en'$$, $$'normal'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'description', 'description', $$'fi'$$, $$'normal'$$, 's.active', 4000);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'description', 'description_en', $$'en'$$, $$'normal'$$, 's.active', 4000);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'duration_text', 'duration_text', $$'fi'$$, $$'protected'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'duration_text', 'duration_text_en', $$'en'$$, $$'protected'$$, 's.active', 200);  -- kb_products_duration_text_en
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'price_text', 'price_text', $$'fi'$$, $$'locked'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'slug', 'slug', $$'all'$$, $$'locked'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'booking_url', 'booking_url', $$'all'$$, $$'locked'$$, 's.active', 500);
  -- UKK
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'question', 'question', $$coalesce(nullif(s.language, ''), 'fi')$$, pc, 's.active', 500);
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'answer', 'answer', $$coalesce(nullif(s.language, ''), 'fi')$$, pc, 's.active', 6000);
  -- kb_texts_en_sources: en-käännös suomenkielisen UKK-rivin _en-sarakkeisiin (samat avaimet faq.<fi-id>.*); erilliset en-rivit ennallaan
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'question', 'question_en', $$'en'$$, pc, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 500);
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'answer', 'answer_en', $$'en'$$, pc, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 6000);
  -- ehdot ja käytännöt (kaikki protected)
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'title', 'title', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false)$$, 300);
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'body', 'body', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false)$$, 20000);
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'title', 'title_en', $$'en'$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false) and coalesce(nullif(s.language, ''), 'fi') = 'fi' and s.id <> 7 and lower(coalesce(s.category, '')) <> 'privacy' and s.title !~* '(tietosuoja|privacy)'$$, 300);  -- kb_policies_en_source (ei tietosuojaselostetta, id 7)
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'body', 'body_en', $$'en'$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false) and coalesce(nullif(s.language, ''), 'fi') = 'fi' and s.id <> 7 and lower(coalesce(s.category, '')) <> 'privacy' and s.title !~* '(tietosuoja|privacy)'$$, 20000);  -- kb_policies_en_source
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
  n := n + booking._texts_reg('booking.schedule_rules', 'id', 'schedule', 'label', 'label_en', $$'en'$$, $$'protected'$$, 's.active', 200);  -- kb_texts_en_sources (nimissä kellonajat/kestot)
  -- sijainnit, aukioloajat, tapahtumat, yritys (kaikki protected: tosiasiat)
  foreach c in array array['name', 'description', 'directions', 'parking', 'public_transport', 'accessibility'] loop
    n := n + booking._texts_reg('kb.locations', 'id', 'location', c, c, $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 3000);
    n := n + booking._texts_reg('kb.locations', 'id', 'location', c, c || '_en', $$'en'$$, $$'protected'$$, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 3000);  -- kb_texts_en_sources
  end loop;
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'session_name', 'session_name', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'swimsuit_rule', 'swimsuit_rule', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 500);
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'session_name', 'session_name_en', $$'en'$$, $$'protected'$$, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 200);  -- kb_texts_en_sources
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'swimsuit_rule', 'swimsuit_rule_en', $$'en'$$, $$'protected'$$, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 500);  -- kb_texts_en_sources
  n := n + booking._texts_reg('kb.event_dates', 'id', 'event', 'time_text', 'time_text', $$'fi'$$, $$'protected'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.event_dates', 'id', 'event', 'time_text', 'time_text_en', $$'en'$$, $$'protected'$$, 's.active', 200);  -- kb_texts_en_sources
  n := n + booking._texts_reg('kb.businesses', 'id', 'business', 'description', 'description', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 4000);
  n := n + booking._texts_reg('kb.businesses', 'id', 'business', 'description', 'description_en', $$'en'$$, $$'protected'$$, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 4000);  -- kb_texts_en_sources
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
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_update_product(p_product_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  allowed text[] := array['name','name_en','description','description_en','price','price_text','vat_rate','active'];
  k text; o kb.products; n kb.products; v_price numeric; v_vat numeric;
begin
  perform booking._require_permission('catalog.edit');
  select * into o from kb.products where id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotetta ei löydy'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  if p_patch ? 'name' and char_length(btrim(coalesce(p_patch ->> 'name', ''))) = 0 then perform booking._err('invalid_name', 'Nimi ei voi olla tyhjä'); end if;
  if p_patch ? 'price' then
    v_price := (p_patch ->> 'price')::numeric;
    if v_price is null or v_price < 0 or v_price > 100000 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  end if;
  if p_patch ? 'vat_rate' then
    v_vat := (p_patch ->> 'vat_rate')::numeric;
    if v_vat is null or not booking._vat_active(v_vat) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu (sallitut: ks. vat_rates)'); end if;
  end if;
  if p_patch ? 'description' and position('<' in coalesce(p_patch ->> 'description', '')) > 0 then
    perform booking._rich_text_check(p_patch ->> 'description');
  end if;
  if p_patch ? 'description_en' and position('<' in coalesce(p_patch ->> 'description_en', '')) > 0 then
    perform booking._rich_text_check(p_patch ->> 'description_en');
  end if;
  update kb.products set
    name           = case when p_patch ? 'name' then btrim(p_patch ->> 'name') else name end,
    name_en        = case when p_patch ? 'name_en' then nullif(btrim(p_patch ->> 'name_en'), '') else name_en end,
    description    = case when p_patch ? 'description' then nullif(p_patch ->> 'description', '') else description end,
    description_en = case when p_patch ? 'description_en' then nullif(p_patch ->> 'description_en', '') else description_en end,
    price          = case when p_patch ? 'price' then v_price else price end,
    price_text     = case when p_patch ? 'price_text' then nullif(p_patch ->> 'price_text', '') else price_text end,
    vat_rate       = case when p_patch ? 'vat_rate' then v_vat else vat_rate end,
    active         = case when p_patch ? 'active' then (p_patch ->> 'active')::boolean else active end,
    updated_at     = now()
   where id = p_product_id returning * into n;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'kb.products', p_product_id::text, 'ADMIN_UPDATE', to_jsonb(o), to_jsonb(n));
  insert into kb.change_log(table_name, row_id, action, actor, old_data, new_data)
  values ('products', p_product_id, 'update', 'booking-admin:' || coalesce(auth.uid()::text, 'unknown'), to_jsonb(o), to_jsonb(n));
  return jsonb_build_object('ok', true, 'id', n.id);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_product_create(p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  allowed text[] := array['name','name_en','description','description_en','price','price_text','vat_rate','category','active','age_restricted'];
  cats text[] := array['public_sauna','treatment','ritual','private_sauna','ceremony','event','training','gift_card','season_card','add_on','product_rental','corporate','other'];
  k text;
  v_name text;
  v_name_en text;
  v_desc text;
  v_desc_en text;
  v_price numeric;
  v_vat numeric;
  v_price_text text;
  v_cat text;
  v_active boolean;
  v_age boolean;
  v_slug text;
  v_base text;
  v_n integer;
  v_sort integer;
  v_biz bigint;
  n kb.products;
  v_key text;
begin
  perform booking._require_permission('catalog.edit');
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform booking._err('invalid_param', 'Tuotteen tiedot puuttuvat');
  end if;
  for k in select jsonb_object_keys(p_data) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;

  v_name := btrim(coalesce(p_data ->> 'name', ''));
  if v_name = '' or char_length(v_name) > 200 then
    perform booking._err('invalid_name', 'Nimi ei voi olla tyhjä');
  end if;
  v_name_en := nullif(btrim(coalesce(p_data ->> 'name_en', '')), '');
  if v_name_en is null then v_name_en := v_name; end if;
  if char_length(v_name_en) > 200 then
    perform booking._err('invalid_name', 'Englanninkielinen nimi on liian pitkä');
  end if;

  v_desc := nullif(btrim(coalesce(p_data ->> 'description', '')), '');
  v_desc_en := nullif(btrim(coalesce(p_data ->> 'description_en', '')), '');
  if v_desc is not null and char_length(v_desc) > 4000 then perform booking._err('invalid_param', 'Kuvaus on liian pitkä'); end if;
  if v_desc_en is not null and char_length(v_desc_en) > 4000 then perform booking._err('invalid_param', 'Kuvaus on liian pitkä'); end if;
  if v_desc is not null and position('<' in v_desc) > 0 then perform booking._rich_text_check(v_desc); end if;
  if v_desc_en is not null and position('<' in v_desc_en) > 0 then perform booking._rich_text_check(v_desc_en); end if;

  if jsonb_typeof(p_data -> 'price') not in ('number', 'string')
     or coalesce(p_data ->> 'price', '') !~ '^\d{1,6}([.,]\d{1,2})?$' then
    perform booking._err('invalid_price', 'Virheellinen hinta');
  end if;
  v_price := replace(p_data ->> 'price', ',', '.')::numeric;
  if v_price < 0 or v_price > 100000 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;

  if jsonb_typeof(p_data -> 'vat_rate') not in ('number', 'string')
     or coalesce(p_data ->> 'vat_rate', '') !~ '^\d{1,2}([.,]\d{1,2})?$' then
    perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu');
  end if;
  v_vat := replace(p_data ->> 'vat_rate', ',', '.')::numeric;
  if not booking._vat_active(v_vat) then
    perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu (sallitut: ks. vat_rates)');
  end if;

  v_cat := coalesce(nullif(btrim(coalesce(p_data ->> 'category', '')), ''), 'product_rental');
  if not (v_cat = any (cats)) then perform booking._err('invalid_category', 'Kategoria ei kelpaa'); end if;

  if not (p_data ? 'active') then
    v_active := true;
  elsif jsonb_typeof(p_data -> 'active') = 'boolean' then
    v_active := (p_data ->> 'active')::boolean;
  elsif jsonb_typeof(p_data -> 'active') = 'string' and lower(btrim(p_data ->> 'active')) in ('true', 'false', 't', 'f') then
    v_active := lower(btrim(p_data ->> 'active')) in ('true', 't');
  else
    perform booking._err('invalid_param', 'Aktiivinen-kenttä on virheellinen');
  end if;

  if not (p_data ? 'age_restricted') then
    v_age := false;
  elsif jsonb_typeof(p_data -> 'age_restricted') = 'boolean' then
    v_age := (p_data ->> 'age_restricted')::boolean;
  elsif jsonb_typeof(p_data -> 'age_restricted') = 'string' and lower(btrim(p_data ->> 'age_restricted')) in ('true', 'false', 't', 'f') then
    v_age := lower(btrim(p_data ->> 'age_restricted')) in ('true', 't');
  else
    perform booking._err('invalid_param', 'Ikäraja-kenttä on virheellinen');
  end if;

  v_price_text := nullif(btrim(coalesce(p_data ->> 'price_text', '')), '');
  if v_price_text is null then
    v_price_text := replace(to_char(v_price, 'FM999990.00'), '.', ',') || ' €';
  end if;
  if char_length(v_price_text) > 200 then perform booking._err('invalid_param', 'Hintateksti on liian pitkä'); end if;

  if v_active and exists (
    select 1 from kb.products p
     where p.active and lower(btrim(p.name)) = lower(v_name)
  ) then
    perform booking._err('duplicate_name', 'Samanniminen aktiivinen tuote on jo olemassa');
  end if;

  v_base := trim(both '-' from regexp_replace(lower(translate(v_name, 'ÄÖÅäöåÉé', 'AOAaoaEe')), '[^a-z0-9]+', '-', 'g'));
  if v_base = '' then v_base := 'tuote'; end if;
  if char_length(v_base) > 80 then v_base := left(v_base, 80); end if;
  v_slug := v_base;
  v_n := 2;
  while exists (select 1 from kb.products p where p.slug = v_slug) loop
    v_slug := v_base || '-' || v_n;
    v_n := v_n + 1;
    if v_n > 200 then perform booking._err('invalid_name', 'Tuotteelle ei löydy vapaata osoitetta'); end if;
  end loop;

  select b.id into v_biz from kb.businesses b order by b.id limit 1;
  if v_biz is null then perform booking._err('no_business', 'Yritystä ei löydy'); end if;

  select coalesce(max(pc.sort_order), 100) + 10 into v_sort from booking.product_config pc;

  insert into kb.products (
    business_id, name, name_en, description, description_en, category,
    price, price_type, price_text, vat_rate, price_includes_vat,
    slug, active, external_system, external_id
  ) values (
    v_biz, v_name, v_name_en, v_desc, v_desc_en, v_cat,
    v_price, 'per_unit', v_price_text, v_vat, true,
    v_slug, v_active, null, null
  ) returning * into n;

  insert into booking.product_config (
    product_id, sale_kind, bookable, shop_visible, sort_order, min_persons, max_persons,
    lifecycle, resource_class, closure_group, duration_minutes,
    audience, pos_enabled, pos_sort, fridge_sale, age_restricted, public_slots
  ) values (
    n.id, 'other', false, false, v_sort, 1, null,
    'current', 'none', null, null,
    'consumer', false, 100, false, v_age, false
  );

  v_key := 'product.' || n.id::text || '.name';
  insert into booking.site_texts (
    key, lang, class, kind, max_len, source_table, source_pk_col, source_pk, source_column,
    published_text, published_version, latest_version, status, published_at
  ) values
    (v_key, 'fi', 'normal', 'plain', 200, 'kb.products', 'id', n.id::text, 'name', v_name, 1, 1, 'published', now()),
    (v_key, 'en', 'normal', 'plain', 200, 'kb.products', 'id', n.id::text, 'name_en', v_name_en, 1, 1, 'published', now())
  on conflict (key, lang) do nothing;
  -- Rekisteröi myös kuvauksen, hintatekstin ja slugin (aktiiviset) ja versiot. Ei ylikirjoita juuri lisättyjä nimiä.
  perform booking._texts_register_sources();

  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'kb.products', n.id::text, 'ADMIN_CREATE', null, to_jsonb(n));
  insert into kb.change_log(table_name, row_id, action, actor, old_data, new_data)
  values ('products', n.id, 'insert', 'booking-admin:' || coalesce(auth.uid()::text, 'unknown'), null, to_jsonb(n));

  return jsonb_build_object(
    'ok', true,
    'id', n.id,
    'product', jsonb_build_object(
      'id', n.id, 'slug', n.slug, 'name', n.name, 'name_en', n.name_en,
      'description', n.description, 'description_en', n.description_en, 'category', n.category,
      'price', n.price, 'price_type', n.price_type, 'price_text', n.price_text, 'vat_rate', n.vat_rate,
      'active', n.active,
      'config', (select to_jsonb(pc) - 'updated_at' from booking.product_config pc where pc.product_id = n.id),
      'variants', '[]'::jsonb
    )
  );
end
$function$;

CREATE OR REPLACE FUNCTION booking.admin_list_products()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'external_id', p.external_id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
      'description', p.description, 'description_en', p.description_en, 'category', p.category,
      'price', p.price, 'price_type', p.price_type, 'price_text', p.price_text, 'vat_rate', p.vat_rate,
      'duration_minutes', p.duration_minutes, 'duration_text', p.duration_text, 'duration_text_en', p.duration_text_en,
      'active', p.active, 'updated_at', p.updated_at,
      'config', (select to_jsonb(pc) - 'updated_at' from booking.product_config pc where pc.product_id = p.id),
      'variants', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'label', v.label, 'price', v.price,
                   'duration_minutes', v.duration_minutes, 'weekdays', v.weekdays, 'time_start', v.time_start, 'time_end', v.time_end,
                   'included_persons', v.included_persons, 'extra_person_price', v.extra_person_price,
                   'valid_from', v.valid_from, 'valid_to', v.valid_to, 'notes', v.notes, 'active', v.active) order by v.id)
                   from kb.product_price_variants v where v.product_id = p.id), '[]'::jsonb)
    ) order by (pc2.product_id is null), pc2.sort_order, p.id)
    from kb.products p left join booking.product_config pc2 on pc2.product_id = p.id), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION booking.public_catalog()
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
      'duration_text', p.duration_text, 'duration_text_en', p.duration_text_en, 'duration_minutes', p.duration_minutes,
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
    and (pc.public_slots or exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active)) $function$;

alter table kb.products drop constraint if exists kb_products_short_description_rich_check;
drop function if exists booking._short_description_check(text);
alter table kb.products drop column if exists short_description;
alter table kb.products drop column if exists short_description_en;
