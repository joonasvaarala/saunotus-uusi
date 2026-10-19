-- ============================================================
-- booking_111_admin_product_create: hallinnan "Lisää tuote".
-- Uusi funktio booking.admin_product_create. Ei muuta olemassa olevia funktioita.
-- Oikeus: booking._require_permission('catalog.edit') (admin ja ylläpitäjä), sama kuin admin_update_product.
-- Grant: authenticated ja service_role. Ei anonille eikä publicille.
-- Luo kb.products- ja booking.product_config-rivin samassa funktiossa, kirjaa audit-lokin
-- ja synkronoi tuotenimen site_texts-rivit (fi + en). Hintoja ja ALV:tä ei kirjoiteta irtoteksteihin.
-- Rollback: rollbacks/20261019081000_booking_111_ROLLBACK.sql
-- Tätä tiedostoa ei ajeta tästä repossa. Bottiavustus ajaa migraation.
-- ============================================================
set local lock_timeout = '5s';

create function booking.admin_product_create(p_data jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
declare
  allowed text[] := array['name','name_en','description','description_en','price','price_text','vat_rate','category','active','shop_visible','age_restricted'];
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
  v_shop boolean;
  v_age boolean;
  v_slug text;
  v_base text;
  v_n integer;
  v_sort integer;
  v_seq text;
  v_last bigint;
  v_max bigint;
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

  if not (p_data ? 'shop_visible') then
    v_shop := false;
  elsif jsonb_typeof(p_data -> 'shop_visible') = 'boolean' then
    v_shop := (p_data ->> 'shop_visible')::boolean;
  elsif jsonb_typeof(p_data -> 'shop_visible') = 'string' and lower(btrim(p_data ->> 'shop_visible')) in ('true', 'false', 't', 'f') then
    v_shop := lower(btrim(p_data ->> 'shop_visible')) in ('true', 't');
  else
    perform booking._err('invalid_param', 'Verkkokauppa-kenttä on virheellinen');
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

  -- Tuotantotunnus on voitu lisätä OVERRIDING SYSTEM VALUE -tavalla ilman, että identiteetti seurasi perässä.
  -- Nostetaan sarjaa vain eteenpäin, ei koskaan taaksepäin.
  v_seq := pg_catalog.pg_get_serial_sequence('kb.products', 'id');
  if v_seq is not null then
    select coalesce(ps.last_value, 0) into v_last
      from pg_catalog.pg_sequences ps
     where ps.schemaname = split_part(v_seq, '.', 1)
       and ps.sequencename = split_part(v_seq, '.', 2);
    select coalesce(max(p.id), 0) into v_max from kb.products p;
    if coalesce(v_last, 0) < v_max then
      perform pg_catalog.setval(v_seq::regclass, v_max, true);
    end if;
  end if;

  select coalesce(max(pc.sort_order), 100) + 10 into v_sort from booking.product_config pc;

  insert into kb.products (
    name, name_en, description, description_en, category,
    price, price_type, price_text, vat_rate, price_includes_vat,
    slug, active, external_system, external_id
  ) values (
    v_name, v_name_en, v_desc, v_desc_en, v_cat,
    v_price, 'per_unit', v_price_text, v_vat, true,
    v_slug, v_active, null, null
  ) returning * into n;

  insert into booking.product_config (
    product_id, sale_kind, bookable, shop_visible, sort_order, min_persons, max_persons,
    lifecycle, resource_class, closure_group, duration_minutes,
    audience, pos_enabled, pos_sort, fridge_sale, age_restricted, public_slots
  ) values (
    n.id, 'other', v_shop, v_shop, v_sort, 1, null,
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

revoke all on function booking.admin_product_create(jsonb) from public, anon;
grant execute on function booking.admin_product_create(jsonb) to authenticated, service_role;

comment on function booking.admin_product_create(jsonb) is
  'Hallinta: luo tuotteen ja product_config-rivin. Oikeus catalog.edit. Nimi, hinta ja ALV validoidaan. Tuotenimi synkronoidaan site_texts-riveihin.';

-- ---------- rollback (ei ajeta; ks. rollbacks/20261019081000_booking_111_ROLLBACK.sql) ----------
-- revoke all on function booking.admin_product_create(jsonb) from authenticated, service_role;
-- drop function if exists booking.admin_product_create(jsonb);
