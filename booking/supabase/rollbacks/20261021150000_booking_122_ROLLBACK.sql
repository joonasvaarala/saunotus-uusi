-- booking_122 rollback: tuotekuvaukset takaisin plain / 4000.
-- Ei kirjoita published_text-arvoja. Aja vain jos booking_122 on käytössä.

set local lock_timeout = '5s';

update booking.site_texts
   set kind = 'plain', max_len = 4000
 where source_table = 'kb.products'
   and source_column in ('description', 'description_en');

alter table booking.site_texts drop constraint if exists site_texts_kind_check;
alter table booking.site_texts add constraint site_texts_kind_check check (kind in ('plain', 'lite'));
comment on column booking.site_texts.kind is null;

create or replace function booking._text_validate(p_class text, p_kind text, p_max integer, p_placeholders text[], p_text text) returns void
language plpgsql immutable set search_path = '' as $$
declare m text[]; v_clean text; v_set text[];
begin
  if p_text is null or btrim(p_text) = '' then perform booking._err('text_empty', 'Teksti ei voi olla tyhjä'); end if;
  if char_length(p_text) > p_max then perform booking._err('too_long', format('Teksti on liian pitkä (%s > %s merkkiä)', char_length(p_text), p_max)); end if;
  if p_text ~ '[\x01-\x08\x0B\x0C\x0E-\x1F]' then perform booking._err('invalid_text', 'Tekstissä on kiellettyjä ohjausmerkkejä'); end if;
  if p_text ~ '<\s*/?\s*[A-Za-z!?]' or p_text ~* 'javascript:' or p_text ~* '\mon[a-z]+\s*=\s*["'']' then perform booking._err('html_not_allowed', 'Raaka HTML tai skripti ei ole sallittu (vain tekstiä)'); end if;
  if p_kind = 'plain' and p_text ~ '\]\(' then perform booking._err('markup_not_allowed', 'Linkkimerkintä ei ole sallittu tässä tekstikentässä'); end if;
  select coalesce(array_agg(distinct x[1] order by x[1]), '{}') into v_set from regexp_matches(p_text, '(\{\{[^{}]*\}\})', 'g') x;
  if exists (select 1 from unnest(v_set) s where s !~ '^\{\{[a-z_]+(:[A-Za-z0-9_]+)?\}\}$') then perform booking._err('placeholder_invalid', 'Virheellinen paikkamerkki'); end if;
  v_clean := regexp_replace(p_text, '\{\{[^{}]*\}\}', '', 'g');
  if v_clean ~ '\{\{|\}\}' then perform booking._err('placeholder_invalid', 'Virheellinen paikkamerkki'); end if;
  if v_set is distinct from (select coalesce(array_agg(distinct s order by s), '{}') from unnest(p_placeholders) s) then
    perform booking._err('placeholder_mismatch', 'Paikkamerkkien pitää vastata tämän tekstin sallittuja paikkamerkkejä');
  end if;
end $$;

create or replace function booking._texts_reg(p_table text, p_pk_col text, p_prefix text, p_field text, p_column text, p_lang_sql text, p_class_sql text, p_where text, p_max integer) returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  execute format($q$insert into booking.site_texts(key, lang, class, kind, max_len, source_table, source_pk_col, source_pk, source_column, published_text, published_version, latest_version, status)
    select %1$L || '.' || s.%2$I::text || '.' || %3$L, %4$s, %5$s, 'plain', %6$s, %7$L, %2$L, s.%2$I::text, %8$L, coalesce(s.%8$I, ''),
           case when btrim(coalesce(s.%8$I, '')) <> '' then 1 else 0 end, case when btrim(coalesce(s.%8$I, '')) <> '' then 1 else 0 end,
           case when btrim(coalesce(s.%8$I, '')) <> '' then 'published' else 'empty' end
      from %7$s s where %9$s on conflict do nothing$q$, p_prefix, p_pk_col, p_field, p_lang_sql, p_class_sql, p_max, p_table, p_column, p_where);
  get diagnostics n = row_count;
  return n;
end $$;


-- booking_122 lisäsi kuvauksen HTML-tarkistuksen. Palautetaan aiemmat funktiot ennen _rich_text_checkin poistoa.
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

create or replace function booking.admin_product_create(p_data jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
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
$fn$;


drop function if exists booking._rich_text_check(text);

-- booking_121:n alkuperäinen täyttö (arvo sellaisenaan, ei HTML-suodatusta).
create or replace function booking._message_fill(p_text text, p_vars jsonb)
returns text language plpgsql immutable set search_path = '' as $$
declare s text := coalesce(p_text, ''); k text;
begin
  if s = '' then return ''; end if;
  foreach k in array array['asiakas_nimi', 'tilaus_linkki', 'tuote', 'saapumisaika', 'linkki'] loop
    s := replace(s, '{' || k || '}', coalesce(p_vars ->> k, ''));
  end loop;
  return s;
end $$;

create or replace function booking._order_message_rows(p_order_id bigint, p_locale text, p_full boolean)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_loc text := case when p_locale = 'en' then 'en' else 'fi' end;
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id,
      'title', booking._message_fill(coalesce(booking._message_pick(m.subject_fi, m.subject_en, v_loc), ''), booking._message_vars(p_order_id, m.id, v_loc)),
      'body', case when p_full then booking._message_fill(coalesce(booking._message_pick(m.body_fi, m.body_en, v_loc), ''), booking._message_vars(p_order_id, m.id, v_loc)) else null end,
      'text', case when not p_full then booking._message_fill(coalesce(booking._message_pick(m.short_fi, m.short_en, v_loc), ''), booking._message_vars(p_order_id, m.id, v_loc)) else null end,
      'link_url', case when m.link_url ~ '^https://[^[:space:]]+$' then m.link_url end
    ) order by m.id)
    from booking.messages m
    where m.active and m.category = 'instruction'
      and exists (
        select 1 from booking.message_products mp
         where mp.message_id = m.id and mp.product_id = any (booking._order_product_ids(p_order_id)))
      and (
        (p_full and booking._message_pick(m.body_fi, m.body_en, v_loc) is not null)
        or (not p_full and booking._message_pick(m.short_fi, m.short_en, v_loc) is not null)
      )
  ), '[]'::jsonb);
end $$;

create or replace function booking._product_message_mail(p_outbox_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  e booking.email_outbox;
  m booking.messages;
  o booking.orders;
  v_loc text;
  v_vars jsonb;
  v_body text;
  v_subject text;
  v_unsub text;
  v_token uuid;
  v_consent boolean := false;
begin
  select * into e from booking.email_outbox where id = p_outbox_id;
  if not found then return jsonb_build_object('active', false); end if;
  select * into m from booking.messages where id = nullif(e.payload ->> 'message_id', '')::bigint;
  select * into o from booking.orders where id = e.order_id;
  if o.customer_id is not null then
    select cu.unsubscribe_token, cu.marketing_consent into v_token, v_consent
      from booking.customers cu where cu.id = o.customer_id;
  end if;
  v_loc := case when coalesce(nullif(e.locale, ''), o.locale, 'fi') = 'en' then 'en' else 'fi' end;
  if m.id is null then
    return jsonb_build_object('active', false, 'order_status', o.status, 'payment_status', o.payment_status);
  end if;
  v_vars := booking._message_vars(o.id, m.id, v_loc);
  v_subject := booking._message_fill(coalesce(booking._message_pick(m.subject_fi, m.subject_en, v_loc), ''), v_vars);
  v_body := booking._message_fill(coalesce(booking._message_pick(m.body_fi, m.body_en, v_loc), ''), v_vars);
  if m.category = 'after_marketing' and v_token is not null then
    v_unsub := coalesce(booking._setting('site_base_url') #>> '{}', '')
      || case when v_loc = 'en' then '/en/order/' else coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/') end
      || '?u=' || v_token::text;
  end if;
  return jsonb_build_object(
    'id', m.id,
    'category', m.category,
    'active', m.active,
    'subject', v_subject,
    'text', v_body,
    'link_url', case when m.link_url ~ '^https://[^[:space:]]+$' then m.link_url end,
    'unsubscribe_url', case when v_unsub ~ '^https://[^[:space:]]+$' then v_unsub end,
    'marketing_consent', case when m.category = 'after_marketing' then coalesce(v_consent, false) else true end,
    'order_status', o.status,
    'payment_status', o.payment_status);
end $$;

drop function if exists booking._message_is_rich(text);
