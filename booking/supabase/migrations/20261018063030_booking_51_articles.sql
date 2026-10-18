-- ============================================================
-- booking_51_articles: sisältöosio (artikkelit; näkyvä nimi esim. "Saunatietoa" voi vaihtua – kannassa neutraali `articles`)
--  * taulut: articles (fi/en samalla rivillä, sisältö Markdown-osajoukkona), article_images (kuvat + alt-tekstit), article_slug_history (vanhat osoitteet → uudelleenohjaus)
--  * Storage-bucket `article-images` (julkinen luku; kirjoitus vain oikeudella articles.manage)
--  * julkiset RPC:t (anon): public_list_articles, public_get_article, public_articles_sitemap  – vain julkaistut (published_at <= now())
--  * hallinta (service_role / suora tietokantayhteys = bottikäyttö, tai authenticated + articles.manage; EI editori-UI:ta): admin_list_articles, admin_get_article, admin_upsert_article, admin_publish_article, admin_unpublish_article,
--    admin_delete_article (pehmeä) + admin_restore_article, admin_register_article_image, admin_update_article_image, admin_remove_article_image
--  * audit-loki (audit_trg), RLS päällä ilman policyja (kaikki pääsy RPC:iden kautta), uusi oikeus articles.manage (admin, manager)
--  * EI sisältöä, EI julkaisua. Sopimus: docs/KOODARI_talous_A_D_fi.md §16. Rollback: rollbacks/…_booking_51_ROLLBACK.sql
-- ============================================================

-- ---------- 1) oikeus ja asetukset ----------
insert into booking.role_permissions(role_code, permission) values ('admin', 'articles.manage'), ('manager', 'articles.manage') on conflict do nothing;

insert into booking.settings(key, value, description, is_public) values
  ('articles_path_fi', to_jsonb('/saunatietoa/'::text), 'Artikkelien polku (fi): {site_base_url}{polku}{slug}/ ; osion näkyvä nimi/polku voi vaihtua – vaihda tässä ja rakenna sivusto uudelleen', true),
  ('articles_path_en', to_jsonb('/en/sauna-knowledge/'::text), 'Artikkelien polku (en)', true),
  ('articles_label_fi', to_jsonb('Saunatietoa'::text), 'Osion näkyvä nimi (fi)', true),
  ('articles_label_en', to_jsonb('Sauna knowledge'::text), 'Osion näkyvä nimi (en)', true)
on conflict (key) do nothing;

-- ---------- 2) taulut ----------
create table booking.articles (
  id                    bigint generated always as identity primary key,
  status                text not null default 'draft' check (status in ('draft', 'published')),
  published_at          timestamptz,                       -- julkaisuhetki; tulevaisuudessa = ajastettu (julkinen näkee vasta kun published_at <= now())
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz,                       -- pehmeä poisto
  slug_fi               text not null,
  slug_en               text,
  title_fi              text not null,
  title_en              text,
  summary_fi            text,
  summary_en            text,
  content_fi            text,                              -- Markdown-osajoukko (ks. §16.2); ei raakaa HTML:ää
  content_en            text,
  meta_title_fi         text,
  meta_title_en         text,
  meta_description_fi   text,
  meta_description_en   text,
  hero_image_id         bigint,                            -- pääkuva (article_images.id; FK lisätään taulun jälkeen)
  category              text,
  tags                  text[] not null default '{}',
  author_name           text,
  sort_order            integer not null default 0,
  featured              boolean not null default false,
  canonical_fi          text,                              -- canonical-ohitus (https-osoite); null = oma osoite
  canonical_en          text,
  noindex               boolean not null default false,
  created_by            uuid,
  updated_by            uuid,
  constraint articles_slug_fi_fmt check (slug_fi ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug_fi) between 3 and 90),
  constraint articles_slug_en_fmt check (slug_en is null or (slug_en ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug_en) between 3 and 90)),
  constraint articles_title_len check (char_length(title_fi) between 1 and 120 and (title_en is null or char_length(title_en) between 1 and 120)),
  constraint articles_summary_len check ((summary_fi is null or char_length(summary_fi) <= 300) and (summary_en is null or char_length(summary_en) <= 300)),
  constraint articles_content_len check ((content_fi is null or char_length(content_fi) <= 100000) and (content_en is null or char_length(content_en) <= 100000)),
  constraint articles_meta_len check ((meta_title_fi is null or char_length(meta_title_fi) <= 70) and (meta_title_en is null or char_length(meta_title_en) <= 70)
                                   and (meta_description_fi is null or char_length(meta_description_fi) <= 170) and (meta_description_en is null or char_length(meta_description_en) <= 170)),
  constraint articles_canonical_https check ((canonical_fi is null or canonical_fi ~ '^https://[^\s<>"]+$') and (canonical_en is null or canonical_en ~ '^https://[^\s<>"]+$')),
  constraint articles_category_len check (category is null or char_length(category) between 1 and 60),
  constraint articles_author_len check (author_name is null or char_length(author_name) between 1 and 120),
  constraint articles_tags_ok check (cardinality(tags) <= 10),
  constraint articles_published_has_time check (status = 'draft' or published_at is not null)
);
create unique index articles_slug_fi_uq on booking.articles (slug_fi) where deleted_at is null;
create unique index articles_slug_en_uq on booking.articles (slug_en) where deleted_at is null and slug_en is not null;
create index articles_pub_idx on booking.articles (status, published_at desc) where deleted_at is null;
create index articles_tags_idx on booking.articles using gin (tags);

create table booking.article_images (
  id          bigint generated always as identity primary key,
  article_id  bigint not null references booking.articles(id) on delete cascade,
  path        text not null unique,                        -- Storage-polku bucketissa article-images: articles/<artikkeli-id>/<aikaleima>-<tunnus>.<pääte>
  alt_fi      text,
  alt_en      text,
  caption_fi  text,
  caption_en  text,
  width       integer not null check (width between 1 and 10000),
  height      integer not null check (height between 1 and 10000),
  bytes       integer check (bytes is null or bytes between 1 and 5242880),
  mime        text not null check (mime in ('image/jpeg', 'image/png', 'image/webp')),
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  constraint article_images_path_fmt check (path ~ '^articles/[0-9]{1,18}/[0-9]{1,18}-[a-z0-9]{6,32}\.(jpg|jpeg|png|webp)$'),
  constraint article_images_alt_len check ((alt_fi is null or char_length(alt_fi) between 1 and 200) and (alt_en is null or char_length(alt_en) between 1 and 200)),
  constraint article_images_cap_len check ((caption_fi is null or char_length(caption_fi) <= 300) and (caption_en is null or char_length(caption_en) <= 300))
);
create index article_images_article_idx on booking.article_images (article_id, sort_order, id);
alter table booking.articles add constraint articles_hero_fk foreign key (hero_image_id) references booking.article_images(id) on delete set null;

create table booking.article_slug_history (
  article_id bigint not null references booking.articles(id) on delete cascade,
  lang       text not null check (lang in ('fi', 'en')),
  slug       text not null,
  created_at timestamptz not null default now(),
  primary key (lang, slug)
);

alter table booking.articles enable row level security;
alter table booking.article_images enable row level security;
alter table booking.article_slug_history enable row level security;
revoke all on booking.articles, booking.article_images, booking.article_slug_history from public, anon, authenticated;
select booking._add_audit('booking.articles');
select booking._add_audit('booking.article_images');

create or replace function booking._articles_touch_trg() returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;
create trigger articles_touch before update on booking.articles for each row execute function booking._articles_touch_trg();

-- ---------- 3) Storage ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('article-images', 'article-images', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists article_images_read   on storage.objects;
drop policy if exists article_images_insert on storage.objects;
drop policy if exists article_images_update on storage.objects;
drop policy if exists article_images_delete on storage.objects;
create policy article_images_read on storage.objects for select to anon, authenticated using (bucket_id = 'article-images');
create policy article_images_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'article-images' and name ~ '^articles/[0-9]{1,18}/[0-9]{1,18}-[a-z0-9]{6,32}\.(jpg|jpeg|png|webp)$' and (select booking.has_permission('articles.manage')));
create policy article_images_update on storage.objects for update to authenticated
  using (bucket_id = 'article-images' and (select booking.has_permission('articles.manage')))
  with check (bucket_id = 'article-images' and name ~ '^articles/[0-9]{1,18}/[0-9]{1,18}-[a-z0-9]{6,32}\.(jpg|jpeg|png|webp)$' and (select booking.has_permission('articles.manage')));
create policy article_images_delete on storage.objects for delete to authenticated
  using (bucket_id = 'article-images' and (select booking.has_permission('articles.manage')));

-- ---------- 4) apufunktiot ----------
-- Markdown-osajoukon tarkistus: palauttaa virheen kuvauksen tai null. Ei raakaa HTML:ää; linkit vain https/http/mailto/suhteellinen/#; kuvat vain img:<id> (artikkelin omat kuvat).
create or replace function booking._article_md_check(p_md text) returns text language plpgsql immutable set search_path = '' as $$
declare m text[]; t text;
begin
  if p_md is null then return null; end if;
  if p_md ~ '[\x00-\x08\x0b\x0c\x0e-\x1f]' then return 'sisältö sisältää ohjausmerkkejä'; end if;
  if p_md ~ '<[A-Za-z/!?]' then return 'raaka HTML ei ole sallittu (käytä Markdownia)'; end if;
  if p_md ~ '(^|\n)[ ]{0,3}\[[^\]]+\]:' then return 'viittausmuotoiset linkit ([x]: osoite) eivät ole sallittuja; käytä [teksti](osoite)'; end if;
  for m in select regexp_matches(p_md, '(!?)\[[^\]]*\]\(\s*([^)\s]*)', 'g') loop
    t := m[2];
    if m[1] = '!' then
      if t !~ '^img:[0-9]{1,18}$' then return 'kuva pitää viitata muodossa ![alt](img:<kuvan id>) – ulkoiset kuvaosoitteet eivät ole sallittuja'; end if;
    elsif t !~* '^(https?://[^\s]+|mailto:[^\s]+|/[^\s]*|#[^\s]*)$' then
      return 'linkin osoite ei kelpaa: sallittuja ovat https://, http://, mailto:, /polku ja #ankkuri';
    end if;
  end loop;
  return null;
end $$;

create or replace function booking._article_img_url(p_path text) returns text language sql stable set search_path = '' as $$
  select case when p_path is null then null
    else regexp_replace(coalesce(booking._setting('functions_base_url') #>> '{}', ''), '/functions/v1/?$', '') || '/storage/v1/object/public/article-images/' || p_path end
$$;

-- onko kieli (fi/en) julkaistavissa/näkyvissä: kaikki pakolliset kentät täynnä
create or replace function booking._article_lang_complete(a booking.articles, p_lang text) returns boolean language sql immutable set search_path = '' as $$
  select case when p_lang = 'en'
    then coalesce(btrim(a.slug_en), '') <> '' and coalesce(btrim(a.title_en), '') <> '' and coalesce(btrim(a.summary_en), '') <> '' and coalesce(btrim(a.content_en), '') <> '' and coalesce(btrim(a.meta_description_en), '') <> ''
    else coalesce(btrim(a.slug_fi), '') <> '' and coalesce(btrim(a.title_fi), '') <> '' and coalesce(btrim(a.summary_fi), '') <> '' and coalesce(btrim(a.content_fi), '') <> '' and coalesce(btrim(a.meta_description_fi), '') <> ''
  end
$$;

create or replace function booking._article_en_started(a booking.articles) returns boolean language sql immutable set search_path = '' as $$
  select coalesce(btrim(a.slug_en), '') <> '' or coalesce(btrim(a.title_en), '') <> '' or coalesce(btrim(a.summary_en), '') <> '' or coalesce(btrim(a.content_en), '') <> '' or coalesce(btrim(a.meta_description_en), '') <> ''
$$;

-- julkaisuvaatimusten puutteet (tyhjä = julkaistavissa)
create or replace function booking._article_issues(a booking.articles) returns text[] language plpgsql stable set search_path = '' as $$
declare v text[] := '{}'; h booking.article_images; en_on boolean := booking._article_en_started(a); r text; mid bigint; bad text;
begin
  if coalesce(btrim(a.summary_fi), '') = '' then v := array_append(v, 'summary_fi'::text); end if;
  if coalesce(btrim(a.content_fi), '') = '' then v := array_append(v, 'content_fi'::text); end if;
  if coalesce(btrim(a.meta_description_fi), '') = '' then v := array_append(v, 'meta_description_fi'::text); end if;
  if en_on then
    if coalesce(btrim(a.slug_en), '') = '' then v := array_append(v, 'slug_en'::text); end if;
    if coalesce(btrim(a.title_en), '') = '' then v := array_append(v, 'title_en'::text); end if;
    if coalesce(btrim(a.summary_en), '') = '' then v := array_append(v, 'summary_en'::text); end if;
    if coalesce(btrim(a.content_en), '') = '' then v := array_append(v, 'content_en'::text); end if;
    if coalesce(btrim(a.meta_description_en), '') = '' then v := array_append(v, 'meta_description_en'::text); end if;
  end if;
  select * into h from booking.article_images where id = a.hero_image_id and article_id = a.id;
  if not found then v := array_append(v, 'hero_image'::text);
  else
    if coalesce(btrim(h.alt_fi), '') = '' then v := array_append(v, 'hero_alt_fi'::text); end if;
    if en_on and coalesce(btrim(h.alt_en), '') = '' then v := array_append(v, 'hero_alt_en'::text); end if;
  end if;
  -- sisältökuvien alt-tekstit
  for mid in select distinct (regexp_matches(coalesce(a.content_fi, '') || ' ' || coalesce(a.content_en, ''), 'img:([0-9]{1,18})', 'g'))[1]::bigint loop
    if not exists (select 1 from booking.article_images where id = mid and article_id = a.id) then v := array_append(v, 'img_ref_' || mid::text);
    elsif exists (select 1 from booking.article_images where id = mid and (coalesce(btrim(alt_fi), '') = '' or (en_on and coalesce(btrim(alt_en), '') = ''))) then v := array_append(v, 'img_alt_' || mid::text); end if;
  end loop;
  bad := coalesce(booking._article_md_check(a.content_fi), booking._article_md_check(a.content_en));
  if bad is not null then v := array_append(v, 'content_markdown'::text); end if;
  return v;
end $$;

create or replace function booking._article_words(p text) returns integer language sql immutable set search_path = '' as $$
  select case when btrim(coalesce(p, '')) = '' then 0 else array_length(regexp_split_to_array(btrim(p), '\s+'), 1) end
$$;

create or replace function booking._article_path(p_lang text) returns text language sql stable set search_path = '' as $$
  select coalesce(booking._setting('articles_path_' || p_lang) #>> '{}', case when p_lang = 'en' then '/en/sauna-knowledge/' else '/saunatietoa/' end)
$$;
create or replace function booking._article_abs(p_lang text, p_slug text) returns text language sql stable set search_path = '' as $$
  select regexp_replace(coalesce(booking._setting('site_base_url') #>> '{}', ''), '/+$', '') || booking._article_path(p_lang) || p_slug || '/'
$$;

-- kuva JSONina (julkinen/hallinta)
create or replace function booking._article_img_json(i booking.article_images, p_lang text) returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('id', i.id, 'path', i.path, 'url', booking._article_img_url(i.path),
    'alt', case when p_lang = 'en' then coalesce(nullif(i.alt_en, ''), i.alt_fi) else i.alt_fi end,
    'caption', case when p_lang = 'en' then coalesce(nullif(i.caption_en, ''), i.caption_fi) else i.caption_fi end,
    'width', i.width, 'height', i.height, 'mime', i.mime, 'bytes', i.bytes)
$$;

-- kortti (listaus) ja hreflang-vaihtoehdot
create or replace function booking._article_alts(a booking.articles) returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('lang', l.lang, 'slug', l.slug, 'path', booking._article_path(l.lang) || l.slug || '/', 'url', booking._article_abs(l.lang, l.slug)) order by l.lang), '[]'::jsonb)
  from (select 'fi' lang, a.slug_fi slug where booking._article_lang_complete(a, 'fi')
        union all select 'en', a.slug_en where booking._article_lang_complete(a, 'en')) l
$$;

create or replace function booking._article_card(a booking.articles, p_lang text) returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('slug', case when p_lang = 'en' then a.slug_en else a.slug_fi end, 'lang', p_lang,
    'title', case when p_lang = 'en' then a.title_en else a.title_fi end,
    'summary', case when p_lang = 'en' then a.summary_en else a.summary_fi end,
    'published_at', a.published_at, 'updated_at', a.updated_at, 'category', a.category, 'tags', to_jsonb(a.tags), 'author', a.author_name,
    'featured', a.featured, 'noindex', a.noindex,
    'reading_minutes', greatest(1, ceil(booking._article_words(case when p_lang = 'en' then a.content_en else a.content_fi end) / 200.0)::int),
    'image', (select booking._article_img_json(i, p_lang) from booking.article_images i where i.id = a.hero_image_id and i.article_id = a.id),
    'alternates', booking._article_alts(a))
$$;

-- julkinen näkyvyys: julkaistu, ei poistettu, aika käynyt, kieli täydellinen
create or replace function booking._article_visible(a booking.articles, p_lang text) returns boolean language sql stable set search_path = '' as $$
  select a.deleted_at is null and a.status = 'published' and a.published_at <= now() and booking._article_lang_complete(a, p_lang)
$$;

create or replace function booking.public_list_articles(p_lang text default 'fi', p_limit integer default 20, p_offset integer default 0, p_tag text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_lang text := case when lower(btrim(coalesce(p_lang, 'fi'))) = 'en' then 'en' else 'fi' end;
        v_lim int := least(greatest(coalesce(p_limit, 20), 1), 50); v_off int := greatest(coalesce(p_offset, 0), 0);
        v_tag text := nullif(lower(btrim(coalesce(p_tag, ''))), '');
        v_total int; v_items jsonb; v_tags jsonb;
begin
  select count(*) into v_total from booking.articles a
   where booking._article_visible(a, v_lang) and (v_tag is null or v_tag = any (a.tags) or lower(a.category) = v_tag);
  select coalesce(jsonb_agg(booking._article_card(x, v_lang) order by x.featured desc, x.sort_order, x.published_at desc, x.id desc), '[]'::jsonb) into v_items
    from (select a.* from booking.articles a
           where booking._article_visible(a, v_lang) and (v_tag is null or v_tag = any (a.tags) or lower(a.category) = v_tag)
           order by a.featured desc, a.sort_order, a.published_at desc, a.id desc limit v_lim offset v_off) x;
  select coalesce(jsonb_agg(jsonb_build_object('tag', t.tag, 'count', t.n) order by t.n desc, t.tag), '[]'::jsonb) into v_tags
    from (select tg tag, count(*) n from booking.articles a, unnest(a.tags) tg where booking._article_visible(a, v_lang) group by tg) t;
  return jsonb_build_object('ok', true, 'lang', v_lang, 'total', v_total, 'limit', v_lim, 'offset', v_off, 'tag', v_tag, 'items', v_items, 'tags', v_tags,
    'label', booking._setting('articles_label_' || v_lang) #>> '{}', 'path', booking._article_path(v_lang));
end $$;

create or replace function booking.public_get_article(p_slug text, p_lang text default 'fi')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_lang text := case when lower(btrim(coalesce(p_lang, 'fi'))) = 'en' then 'en' else 'fi' end;
        v_slug text := lower(btrim(coalesce(p_slug, ''))); a booking.articles; h booking.article_images; v_canon text; v_title text; v_desc text; v_pub text; v_logo text;
        v_alts jsonb; v_hrefs jsonb; v_imgs jsonb; v_ld jsonb; v_url text; v_new text;
begin
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into a from booking.articles x where x.deleted_at is null and (case when v_lang = 'en' then x.slug_en else x.slug_fi end) = v_slug;
  if not found or not booking._article_visible(a, v_lang) then
    select case when v_lang = 'en' then x.slug_en else x.slug_fi end into v_new from booking.article_slug_history hh join booking.articles x on x.id = hh.article_id
     where hh.lang = v_lang and hh.slug = v_slug and booking._article_visible(x, v_lang);
    if v_new is not null then return jsonb_build_object('ok', false, 'code', 'moved', 'slug', v_new, 'lang', v_lang, 'path', booking._article_path(v_lang) || v_new || '/'); end if;
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into h from booking.article_images where id = a.hero_image_id and article_id = a.id;
  v_title := case when v_lang = 'en' then a.title_en else a.title_fi end;
  v_desc := case when v_lang = 'en' then a.meta_description_en else a.meta_description_fi end;
  v_url := booking._article_abs(v_lang, v_slug);
  v_canon := coalesce(case when v_lang = 'en' then a.canonical_en else a.canonical_fi end, v_url);
  v_alts := booking._article_alts(a);
  v_hrefs := (select coalesce(jsonb_agg(jsonb_build_object('hreflang', e ->> 'lang', 'href', e ->> 'url') order by e ->> 'lang'), '[]'::jsonb) from jsonb_array_elements(v_alts) e);
  if jsonb_array_length(v_alts) > 1 or exists (select 1 from jsonb_array_elements(v_alts) e where e ->> 'lang' = 'fi') then
    v_hrefs := v_hrefs || coalesce((select jsonb_build_array(jsonb_build_object('hreflang', 'x-default', 'href', e ->> 'url')) from jsonb_array_elements(v_alts) e where e ->> 'lang' = 'fi'), '[]'::jsonb);
  end if;
  if jsonb_array_length(v_alts) < 2 then v_hrefs := '[]'::jsonb; end if;   -- hreflang vain kun molemmat kieliversiot ovat julkaistuja
  v_imgs := (select coalesce(jsonb_agg(booking._article_img_json(i, v_lang) order by i.sort_order, i.id), '[]'::jsonb) from booking.article_images i where i.article_id = a.id);
  select coalesce(value ->> 'trade_name', value ->> 'name', 'Sipoonjoen Perinnesauna'), value ->> 'logo_url' into v_pub, v_logo from booking.settings where key = 'seller';
  v_ld := jsonb_strip_nulls(jsonb_build_object('@context', 'https://schema.org', '@type', 'Article', 'headline', left(v_title, 110), 'description', v_desc,
    'datePublished', a.published_at, 'dateModified', a.updated_at, 'inLanguage', v_lang, 'mainEntityOfPage', jsonb_build_object('@type', 'WebPage', '@id', v_canon),
    'image', case when h.id is not null then jsonb_build_array(booking._article_img_url(h.path)) end,
    'author', case when a.author_name is not null then jsonb_build_object('@type', 'Person', 'name', a.author_name) else jsonb_build_object('@type', 'Organization', 'name', coalesce(v_pub, 'Sipoonjoen Perinnesauna')) end,
    'publisher', jsonb_build_object('@type', 'Organization', 'name', coalesce(v_pub, 'Sipoonjoen Perinnesauna'), 'logo', case when v_logo is not null then jsonb_build_object('@type', 'ImageObject', 'url', v_logo) end),
    'keywords', case when cardinality(a.tags) > 0 then array_to_string(a.tags, ', ') end, 'articleSection', a.category));
  return jsonb_build_object('ok', true, 'article', booking._article_card(a, v_lang) || jsonb_build_object(
      'content_md', case when v_lang = 'en' then a.content_en else a.content_fi end, 'images', v_imgs),
    'seo', jsonb_build_object('title', coalesce(nullif(case when v_lang = 'en' then a.meta_title_en else a.meta_title_fi end, ''), v_title), 'description', v_desc,
      'canonical', v_canon, 'robots', case when a.noindex then 'noindex,follow' else 'index,follow' end, 'alternates', v_hrefs,
      'og_image', case when h.id is not null then booking._article_img_json(h, v_lang) end, 'og_type', 'article', 'json_ld', v_ld));
end $$;

create or replace function booking.public_articles_sitemap()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true, 'items', coalesce(jsonb_agg(item order by (item ->> 'lang'), (item ->> 'published_at') desc), '[]'::jsonb))
  from (
    select jsonb_build_object('lang', l.lang, 'slug', l.slug, 'path', booking._article_path(l.lang) || l.slug || '/', 'loc', booking._article_abs(l.lang, l.slug),
      'updated_at', (l.a).updated_at, 'published_at', (l.a).published_at,
      'alternates', (select coalesce(jsonb_agg(jsonb_build_object('hreflang', e ->> 'lang', 'href', e ->> 'url') order by e ->> 'lang'), '[]'::jsonb) from jsonb_array_elements(booking._article_alts(l.a)) e
                      where jsonb_array_length(booking._article_alts(l.a)) > 1)
        || (select coalesce(jsonb_agg(jsonb_build_object('hreflang', 'x-default', 'href', e ->> 'url')), '[]'::jsonb) from jsonb_array_elements(booking._article_alts(l.a)) e
              where e ->> 'lang' = 'fi' and jsonb_array_length(booking._article_alts(l.a)) > 1)) as item
    from (select a, 'fi' lang, a.slug_fi slug from booking.articles a where booking._article_visible(a, 'fi') and not a.noindex and a.canonical_fi is null
          union all select a, 'en', a.slug_en from booking.articles a where booking._article_visible(a, 'en') and not a.noindex and a.canonical_en is null) l
  ) q
$$;

-- ---------- 6) hallinta: apurit ----------
-- hallinnan pääsy: palvelurooli (bottikäyttö: service_role-avain tai suora tietokantayhteys) TAI kirjautunut henkilöstö jolla articles.manage. Ei omaa editori-UI:ta: sisältö tuodaan botin kautta.
create or replace function booking._article_auth() returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if coalesce(booking._jwt_role(), '') = 'service_role' or (booking._jwt_role() is null and session_user in ('postgres', 'supabase_admin', 'service_role')) then return; end if;
  perform booking._require_permission('articles.manage');
end $$;

create or replace function booking._article_admin_json(a booking.articles) returns jsonb language sql stable set search_path = '' as $$
  select to_jsonb(a) || jsonb_build_object(
    'effective_status', case when a.deleted_at is not null then 'deleted' when a.status = 'draft' then 'draft' when a.published_at > now() then 'scheduled' else 'live' end,
    'fi_complete', booking._article_lang_complete(a, 'fi'), 'en_complete', booking._article_lang_complete(a, 'en'), 'en_started', booking._article_en_started(a),
    'issues', to_jsonb(booking._article_issues(a)), 'publishable', cardinality(booking._article_issues(a)) = 0,
    'images', (select coalesce(jsonb_agg(to_jsonb(i) || jsonb_build_object('url', booking._article_img_url(i.path)) order by i.sort_order, i.id), '[]'::jsonb) from booking.article_images i where i.article_id = a.id),
    'urls', jsonb_build_object('fi', case when a.slug_fi is not null then booking._article_abs('fi', a.slug_fi) end, 'en', case when a.slug_en is not null then booking._article_abs('en', a.slug_en) end))
$$;

-- julkaistun artikkelin pitää pysyä julkaisukelpoisena (ei rikota elävää sivua muokkauksella)
create or replace function booking._article_assert_live_ok(p_id bigint) returns void language plpgsql set search_path = '' as $$
declare a booking.articles; v text[];
begin
  select * into a from booking.articles where id = p_id;
  if found and a.status = 'published' and a.deleted_at is null then
    v := booking._article_issues(a);
    if cardinality(v) > 0 then perform booking._err('not_publishable', 'Julkaistu artikkeli ei saa jäädä vaillinaiseksi. Puuttuu: ' || array_to_string(v, ', ')); end if;
  end if;
end $$;

-- ---------- 7) hallinta: RPC:t (service_role / articles.manage) ----------
create or replace function booking.admin_list_articles(p_search text default null, p_status text default null, p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_lim int := least(greatest(coalesce(p_limit, 50), 1), 200); v_off int := greatest(coalesce(p_offset, 0), 0); v_q text := nullif(btrim(coalesce(p_search, '')), ''); v_st text := nullif(btrim(coalesce(p_status, '')), '');
        v_total int; v_items jsonb;
begin
  perform booking._article_auth();
  if v_st is not null and v_st not in ('draft', 'published', 'scheduled', 'deleted') then perform booking._err('invalid_param', 'status: draft | published | scheduled | deleted'); end if;
  select count(*) into v_total from booking.articles a
   where (case when v_st = 'deleted' then a.deleted_at is not null else a.deleted_at is null end)
     and (v_st is null or v_st = 'deleted' or (v_st = 'draft' and a.status = 'draft') or (v_st = 'published' and a.status = 'published' and a.published_at <= now()) or (v_st = 'scheduled' and a.status = 'published' and a.published_at > now()))
     and (v_q is null or a.title_fi ilike '%' || v_q || '%' or a.title_en ilike '%' || v_q || '%' or a.slug_fi ilike '%' || v_q || '%' or a.slug_en ilike '%' || v_q || '%');
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'status', x.status, 'effective_status', case when x.deleted_at is not null then 'deleted' when x.status = 'draft' then 'draft' when x.published_at > now() then 'scheduled' else 'live' end,
      'slug_fi', x.slug_fi, 'slug_en', x.slug_en, 'title_fi', x.title_fi, 'title_en', x.title_en, 'published_at', x.published_at, 'updated_at', x.updated_at, 'deleted_at', x.deleted_at,
      'category', x.category, 'tags', to_jsonb(x.tags), 'featured', x.featured, 'sort_order', x.sort_order, 'noindex', x.noindex,
      'fi_complete', booking._article_lang_complete(x, 'fi'), 'en_complete', booking._article_lang_complete(x, 'en'), 'en_started', booking._article_en_started(x),
      'hero_path', (select i.path from booking.article_images i where i.id = x.hero_image_id), 'images', (select count(*) from booking.article_images i where i.article_id = x.id)) order by x.updated_at desc, x.id desc), '[]'::jsonb) into v_items
    from (select a.* from booking.articles a
           where (case when v_st = 'deleted' then a.deleted_at is not null else a.deleted_at is null end)
             and (v_st is null or v_st = 'deleted' or (v_st = 'draft' and a.status = 'draft') or (v_st = 'published' and a.status = 'published' and a.published_at <= now()) or (v_st = 'scheduled' and a.status = 'published' and a.published_at > now()))
             and (v_q is null or a.title_fi ilike '%' || v_q || '%' or a.title_en ilike '%' || v_q || '%' or a.slug_fi ilike '%' || v_q || '%' or a.slug_en ilike '%' || v_q || '%')
           order by a.updated_at desc, a.id desc limit v_lim offset v_off) x;
  return jsonb_build_object('ok', true, 'total', v_total, 'limit', v_lim, 'offset', v_off, 'items', v_items);
end $$;

create or replace function booking.admin_get_article(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a booking.articles;
begin
  perform booking._article_auth();
  select * into a from booking.articles where id = p_id;
  if not found then perform booking._err('not_found', 'Artikkelia ei löydy'); end if;
  return jsonb_build_object('ok', true, 'article', booking._article_admin_json(a));
end $$;

create or replace function booking.admin_upsert_article(p_id bigint default null, p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare a booking.articles; n booking.articles; k text; v_new boolean := p_id is null; msg text; mid bigint;
  v_allowed text[] := array['slug_fi','slug_en','title_fi','title_en','summary_fi','summary_en','content_fi','content_en','meta_title_fi','meta_title_en','meta_description_fi','meta_description_en',
                            'hero_image_id','category','tags','author_name','sort_order','featured','canonical_fi','canonical_en','noindex'];
begin
  perform booking._article_auth();
  if p_data is null or jsonb_typeof(p_data) <> 'object' then perform booking._err('invalid_param', 'p_data pitää olla JSON-objekti'); end if;
  for k in select jsonb_object_keys(p_data) loop
    if not (k = any (v_allowed)) then perform booking._err('invalid_param', 'Tuntematon kenttä: ' || k); end if;
  end loop;
  if v_new then
    a.id := null; a.status := 'draft'; a.tags := '{}'; a.sort_order := 0; a.featured := false; a.noindex := false;
    if coalesce(btrim(p_data ->> 'slug_fi'), '') = '' or coalesce(btrim(p_data ->> 'title_fi'), '') = '' then perform booking._err('invalid_param', 'Uudelle artikkelille vaaditaan slug_fi ja title_fi'); end if;
  else
    select * into a from booking.articles where id = p_id for update;
    if not found then perform booking._err('not_found', 'Artikkelia ei löydy'); end if;
    if a.deleted_at is not null then perform booking._err('deleted', 'Artikkeli on poistettu; palauta se ensin'); end if;
  end if;
  n := a;
  -- tekstikentät (tyhjä merkkijono / null = tyhjennä; slug_fi ja title_fi eivät voi olla tyhjiä)
  if p_data ? 'slug_fi' then n.slug_fi := lower(nullif(btrim(p_data ->> 'slug_fi'), '')); end if;
  if p_data ? 'slug_en' then n.slug_en := lower(nullif(btrim(p_data ->> 'slug_en'), '')); end if;
  if p_data ? 'title_fi' then n.title_fi := nullif(btrim(p_data ->> 'title_fi'), ''); end if;
  if p_data ? 'title_en' then n.title_en := nullif(btrim(p_data ->> 'title_en'), ''); end if;
  if p_data ? 'summary_fi' then n.summary_fi := nullif(btrim(p_data ->> 'summary_fi'), ''); end if;
  if p_data ? 'summary_en' then n.summary_en := nullif(btrim(p_data ->> 'summary_en'), ''); end if;
  if p_data ? 'content_fi' then n.content_fi := nullif(btrim(p_data ->> 'content_fi'), ''); end if;
  if p_data ? 'content_en' then n.content_en := nullif(btrim(p_data ->> 'content_en'), ''); end if;
  if p_data ? 'meta_title_fi' then n.meta_title_fi := nullif(btrim(p_data ->> 'meta_title_fi'), ''); end if;
  if p_data ? 'meta_title_en' then n.meta_title_en := nullif(btrim(p_data ->> 'meta_title_en'), ''); end if;
  if p_data ? 'meta_description_fi' then n.meta_description_fi := nullif(btrim(p_data ->> 'meta_description_fi'), ''); end if;
  if p_data ? 'meta_description_en' then n.meta_description_en := nullif(btrim(p_data ->> 'meta_description_en'), ''); end if;
  if p_data ? 'category' then n.category := nullif(btrim(p_data ->> 'category'), ''); end if;
  if p_data ? 'author_name' then n.author_name := nullif(btrim(p_data ->> 'author_name'), ''); end if;
  if p_data ? 'canonical_fi' then n.canonical_fi := nullif(btrim(p_data ->> 'canonical_fi'), ''); end if;
  if p_data ? 'canonical_en' then n.canonical_en := nullif(btrim(p_data ->> 'canonical_en'), ''); end if;
  if p_data ? 'featured' then if jsonb_typeof(p_data -> 'featured') <> 'boolean' then perform booking._err('invalid_param', 'featured: true/false'); end if; n.featured := (p_data ->> 'featured')::boolean; end if;
  if p_data ? 'noindex' then if jsonb_typeof(p_data -> 'noindex') <> 'boolean' then perform booking._err('invalid_param', 'noindex: true/false'); end if; n.noindex := (p_data ->> 'noindex')::boolean; end if;
  if p_data ? 'sort_order' then
    if jsonb_typeof(p_data -> 'sort_order') <> 'number' or (p_data ->> 'sort_order') !~ '^-?[0-9]{1,6}$' then perform booking._err('invalid_param', 'sort_order: kokonaisluku'); end if;
    n.sort_order := (p_data ->> 'sort_order')::int;
  end if;
  if p_data ? 'tags' then
    if jsonb_typeof(p_data -> 'tags') <> 'array' then perform booking._err('invalid_param', 'tags: taulukko merkkijonoja'); end if;
    if exists (select 1 from jsonb_array_elements(p_data -> 'tags') e where jsonb_typeof(e) <> 'string') then perform booking._err('invalid_param', 'tags: taulukko merkkijonoja'); end if;
    n.tags := coalesce((select array_agg(t order by o) from (select lower(btrim(e.x)) t, min(e.o) o from jsonb_array_elements_text(p_data -> 'tags') with ordinality e(x, o) where btrim(e.x) <> '' group by 1) q), '{}');
    if cardinality(n.tags) > 10 then perform booking._err('invalid_param', 'Enintään 10 tagia'); end if;
    if exists (select 1 from unnest(n.tags) t where char_length(t) > 40) then perform booking._err('invalid_param', 'Tagi on enintään 40 merkkiä'); end if;
  end if;
  if p_data ? 'hero_image_id' then
    if p_data -> 'hero_image_id' = 'null'::jsonb then n.hero_image_id := null;
    else
      if jsonb_typeof(p_data -> 'hero_image_id') <> 'number' or (p_data ->> 'hero_image_id') !~ '^[0-9]{1,18}$' then perform booking._err('invalid_param', 'hero_image_id: kuvan id tai null'); end if;
      n.hero_image_id := (p_data ->> 'hero_image_id')::bigint;
      if v_new or not exists (select 1 from booking.article_images where id = n.hero_image_id and article_id = p_id) then perform booking._err('hero_not_found', 'Pääkuvan pitää olla tämän artikkelin rekisteröity kuva'); end if;
    end if;
  end if;
  -- validoinnit
  if n.slug_fi is null or n.slug_fi !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or char_length(n.slug_fi) not between 3 and 90 then perform booking._err('invalid_slug', 'slug_fi: pienet kirjaimet, numerot ja yhdysmerkit, 3–90 merkkiä'); end if;
  if n.slug_en is not null and (n.slug_en !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or char_length(n.slug_en) not between 3 and 90) then perform booking._err('invalid_slug', 'slug_en: pienet kirjaimet, numerot ja yhdysmerkit, 3–90 merkkiä'); end if;
  if n.title_fi is null then perform booking._err('invalid_param', 'title_fi ei voi olla tyhjä'); end if;
  if char_length(n.title_fi) > 120 or char_length(coalesce(n.title_en, '')) > 120 then perform booking._err('invalid_param', 'Otsikko on enintään 120 merkkiä'); end if;
  if char_length(coalesce(n.summary_fi, '')) > 300 or char_length(coalesce(n.summary_en, '')) > 300 then perform booking._err('invalid_param', 'Tiivistelmä on enintään 300 merkkiä'); end if;
  if char_length(coalesce(n.meta_title_fi, '')) > 70 or char_length(coalesce(n.meta_title_en, '')) > 70 then perform booking._err('invalid_param', 'meta_title on enintään 70 merkkiä'); end if;
  if char_length(coalesce(n.meta_description_fi, '')) > 170 or char_length(coalesce(n.meta_description_en, '')) > 170 then perform booking._err('invalid_param', 'meta_description on enintään 170 merkkiä'); end if;
  if char_length(coalesce(n.category, '')) > 60 or char_length(coalesce(n.author_name, '')) > 120 then perform booking._err('invalid_param', 'category ≤ 60, author_name ≤ 120 merkkiä'); end if;
  if coalesce(n.canonical_fi, 'https://x') !~ '^https://[^\s<>"]+$' or coalesce(n.canonical_en, 'https://x') !~ '^https://[^\s<>"]+$' then perform booking._err('invalid_param', 'canonical: https-osoite'); end if;
  if char_length(coalesce(n.content_fi, '')) > 100000 or char_length(coalesce(n.content_en, '')) > 100000 then perform booking._err('invalid_content', 'Sisältö on enintään 100 000 merkkiä'); end if;
  msg := coalesce(booking._article_md_check(n.content_fi), booking._article_md_check(n.content_en));
  if msg is not null then perform booking._err('invalid_content', 'Sisältö: ' || msg); end if;
  if v_new then
    if coalesce(n.content_fi, '') ~ 'img:[0-9]' or coalesce(n.content_en, '') ~ 'img:[0-9]' then perform booking._err('invalid_image', 'Kuvaviitteet voi lisätä vasta kun artikkeli on luotu ja kuvat rekisteröity'); end if;
  else
    for mid in select distinct (regexp_matches(coalesce(n.content_fi, '') || ' ' || coalesce(n.content_en, ''), 'img:([0-9]{1,18})', 'g'))[1]::bigint loop
      if not exists (select 1 from booking.article_images where id = mid and article_id = p_id) then perform booking._err('invalid_image', 'Sisältö viittaa kuvaan, joka ei kuulu artikkeliin: img:' || mid); end if;
    end loop;
  end if;
  begin
    if v_new then
      insert into booking.articles(slug_fi, slug_en, title_fi, title_en, summary_fi, summary_en, content_fi, content_en, meta_title_fi, meta_title_en, meta_description_fi, meta_description_en,
                                   category, tags, author_name, sort_order, featured, canonical_fi, canonical_en, noindex, created_by, updated_by)
      values (n.slug_fi, n.slug_en, n.title_fi, n.title_en, n.summary_fi, n.summary_en, n.content_fi, n.content_en, n.meta_title_fi, n.meta_title_en, n.meta_description_fi, n.meta_description_en,
              n.category, n.tags, n.author_name, n.sort_order, n.featured, n.canonical_fi, n.canonical_en, n.noindex, auth.uid(), auth.uid()) returning * into n;
    else
      update booking.articles set slug_fi = n.slug_fi, slug_en = n.slug_en, title_fi = n.title_fi, title_en = n.title_en, summary_fi = n.summary_fi, summary_en = n.summary_en,
             content_fi = n.content_fi, content_en = n.content_en, meta_title_fi = n.meta_title_fi, meta_title_en = n.meta_title_en, meta_description_fi = n.meta_description_fi, meta_description_en = n.meta_description_en,
             hero_image_id = n.hero_image_id, category = n.category, tags = n.tags, author_name = n.author_name, sort_order = n.sort_order, featured = n.featured,
             canonical_fi = n.canonical_fi, canonical_en = n.canonical_en, noindex = n.noindex, updated_by = auth.uid()
       where id = p_id returning * into n;
    end if;
  exception when unique_violation then
    perform booking._err('slug_taken', 'Osoite (slug) on jo käytössä toisella artikkelilla');
  end;
  -- vanhat osoitteet uudelleenohjauksia varten (vain jos artikkeli on joskus julkaistu); uusi osoite vapautetaan historiasta
  if not v_new then
    if a.slug_fi is distinct from n.slug_fi and a.published_at is not null then insert into booking.article_slug_history(article_id, lang, slug) values (n.id, 'fi', a.slug_fi) on conflict (lang, slug) do update set article_id = excluded.article_id; end if;
    if a.slug_en is distinct from n.slug_en and a.slug_en is not null and a.published_at is not null then insert into booking.article_slug_history(article_id, lang, slug) values (n.id, 'en', a.slug_en) on conflict (lang, slug) do update set article_id = excluded.article_id; end if;
  end if;
  delete from booking.article_slug_history where (lang = 'fi' and slug = n.slug_fi) or (lang = 'en' and slug = n.slug_en);
  perform booking._article_assert_live_ok(n.id);
  select * into n from booking.articles where id = n.id;
  return jsonb_build_object('ok', true, 'created', v_new, 'article', booking._article_admin_json(n));
end $$;

create or replace function booking.admin_publish_article(p_id bigint, p_published_at timestamptz default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare a booking.articles; v text[];
begin
  perform booking._article_auth();
  select * into a from booking.articles where id = p_id for update;
  if not found then perform booking._err('not_found', 'Artikkelia ei löydy'); end if;
  if a.deleted_at is not null then perform booking._err('deleted', 'Artikkeli on poistettu; palauta se ensin'); end if;
  if p_published_at is not null and p_published_at > now() + interval '2 years' then perform booking._err('invalid_param', 'published_at on liian kaukana tulevaisuudessa'); end if;
  v := booking._article_issues(a);
  if cardinality(v) > 0 then perform booking._err('not_publishable', 'Julkaisu ei onnistu. Puuttuu: ' || array_to_string(v, ', ')); end if;
  update booking.articles set status = 'published', published_at = coalesce(p_published_at, a.published_at, now()), updated_by = auth.uid() where id = p_id returning * into a;
  return jsonb_build_object('ok', true, 'article', booking._article_admin_json(a));
end $$;

create or replace function booking.admin_unpublish_article(p_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare a booking.articles;
begin
  perform booking._article_auth();
  update booking.articles set status = 'draft', updated_by = auth.uid() where id = p_id returning * into a;   -- published_at säilyy (alkuperäinen julkaisupäivä)
  if not found then perform booking._err('not_found', 'Artikkelia ei löydy'); end if;
  return jsonb_build_object('ok', true, 'article', booking._article_admin_json(a));
end $$;

create or replace function booking.admin_delete_article(p_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare a booking.articles;
begin
  perform booking._article_auth();
  update booking.articles set deleted_at = coalesce(deleted_at, now()), status = 'draft', updated_by = auth.uid() where id = p_id returning * into a;
  if not found then perform booking._err('not_found', 'Artikkelia ei löydy'); end if;
  return jsonb_build_object('ok', true, 'article', booking._article_admin_json(a));
end $$;

create or replace function booking.admin_restore_article(p_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare a booking.articles;
begin
  perform booking._article_auth();
  begin
    update booking.articles set deleted_at = null, status = 'draft', updated_by = auth.uid() where id = p_id returning * into a;
  exception when unique_violation then perform booking._err('slug_taken', 'Osoite (slug) on nyt toisen artikkelin käytössä; vaihda se ennen palautusta');
  end;
  if not found then perform booking._err('not_found', 'Artikkelia ei löydy'); end if;
  return jsonb_build_object('ok', true, 'article', booking._article_admin_json(a));
end $$;

-- kuvat: 1) asiakas lataa tiedoston Storageen (article-images, polku articles/<artikkeli-id>/<aikaleima>-<tunnus>.<pääte>), 2) rekisteröi sen tällä
create or replace function booking.admin_register_article_image(p_article_id bigint, p_path text, p_width integer, p_height integer, p_alt_fi text default null, p_alt_en text default null,
                                                                p_caption_fi text default null, p_caption_en text default null, p_bytes integer default null, p_mime text default null,
                                                                p_sort integer default 0, p_set_hero boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare a booking.articles; i booking.article_images; v_path text := btrim(coalesce(p_path, '')); v_ext text; v_mime text;
begin
  perform booking._article_auth();
  select * into a from booking.articles where id = p_article_id for update;
  if not found then perform booking._err('not_found', 'Artikkelia ei löydy'); end if;
  if a.deleted_at is not null then perform booking._err('deleted', 'Artikkeli on poistettu'); end if;
  if v_path !~ '^articles/[0-9]{1,18}/[0-9]{1,18}-[a-z0-9]{6,32}\.(jpg|jpeg|png|webp)$' then perform booking._err('invalid_image', 'Kuvan polku ei kelpaa (articles/<artikkeli-id>/<aikaleima>-<tunnus>.jpg|png|webp)'); end if;
  if split_part(v_path, '/', 2) <> p_article_id::text then perform booking._err('invalid_image', 'Kuvan polun pitää alkaa artikkelin tunnuksella: articles/' || p_article_id || '/'); end if;
  v_ext := lower(substring(v_path from '\.([a-z]+)$'));
  v_mime := case v_ext when 'png' then 'image/png' when 'webp' then 'image/webp' else 'image/jpeg' end;
  if p_mime is not null and p_mime <> v_mime then perform booking._err('invalid_image', 'MIME-tyyppi ei vastaa tiedostopäätettä'); end if;
  if p_width is null or p_height is null or p_width not between 1 and 10000 or p_height not between 1 and 10000 then perform booking._err('invalid_image', 'Kuvan leveys ja korkeus (px) vaaditaan'); end if;
  if p_bytes is not null and p_bytes not between 1 and 5242880 then perform booking._err('invalid_image', 'Kuva on enintään 5 Mt'); end if;
  if not exists (select 1 from storage.objects where bucket_id = 'article-images' and name = v_path) then perform booking._err('file_not_uploaded', 'Tiedostoa ei löydy Storagesta; lataa se ensin'); end if;
  if char_length(coalesce(p_alt_fi, '')) > 200 or char_length(coalesce(p_alt_en, '')) > 200 then perform booking._err('invalid_param', 'Alt-teksti on enintään 200 merkkiä'); end if;
  begin
    insert into booking.article_images(article_id, path, alt_fi, alt_en, caption_fi, caption_en, width, height, bytes, mime, sort_order, created_by)
    values (p_article_id, v_path, nullif(btrim(coalesce(p_alt_fi, '')), ''), nullif(btrim(coalesce(p_alt_en, '')), ''), nullif(btrim(coalesce(p_caption_fi, '')), ''), nullif(btrim(coalesce(p_caption_en, '')), ''),
            p_width, p_height, p_bytes, v_mime, coalesce(p_sort, 0), auth.uid()) returning * into i;
  exception when unique_violation then perform booking._err('invalid_image', 'Kuva on jo rekisteröity');
  end;
  if coalesce(p_set_hero, false) then update booking.articles set hero_image_id = i.id, updated_by = auth.uid() where id = p_article_id; end if;
  select * into a from booking.articles where id = p_article_id;
  return jsonb_build_object('ok', true, 'image', to_jsonb(i) || jsonb_build_object('url', booking._article_img_url(i.path)), 'article', booking._article_admin_json(a));
end $$;

create or replace function booking.admin_update_article_image(p_image_id bigint, p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare i booking.article_images; k text; a booking.articles;
begin
  perform booking._article_auth();
  if p_data is null or jsonb_typeof(p_data) <> 'object' then perform booking._err('invalid_param', 'p_data pitää olla JSON-objekti'); end if;
  for k in select jsonb_object_keys(p_data) loop
    if k not in ('alt_fi', 'alt_en', 'caption_fi', 'caption_en', 'sort_order') then perform booking._err('invalid_param', 'Tuntematon kenttä: ' || k); end if;
  end loop;
  select * into i from booking.article_images where id = p_image_id for update;
  if not found then perform booking._err('not_found', 'Kuvaa ei löydy'); end if;
  if p_data ? 'alt_fi' then i.alt_fi := nullif(btrim(p_data ->> 'alt_fi'), ''); end if;
  if p_data ? 'alt_en' then i.alt_en := nullif(btrim(p_data ->> 'alt_en'), ''); end if;
  if p_data ? 'caption_fi' then i.caption_fi := nullif(btrim(p_data ->> 'caption_fi'), ''); end if;
  if p_data ? 'caption_en' then i.caption_en := nullif(btrim(p_data ->> 'caption_en'), ''); end if;
  if p_data ? 'sort_order' then
    if jsonb_typeof(p_data -> 'sort_order') <> 'number' or (p_data ->> 'sort_order') !~ '^-?[0-9]{1,6}$' then perform booking._err('invalid_param', 'sort_order: kokonaisluku'); end if;
    i.sort_order := (p_data ->> 'sort_order')::int;
  end if;
  if char_length(coalesce(i.alt_fi, '')) > 200 or char_length(coalesce(i.alt_en, '')) > 200 then perform booking._err('invalid_param', 'Alt-teksti on enintään 200 merkkiä'); end if;
  if char_length(coalesce(i.caption_fi, '')) > 300 or char_length(coalesce(i.caption_en, '')) > 300 then perform booking._err('invalid_param', 'Kuvateksti on enintään 300 merkkiä'); end if;
  update booking.article_images set alt_fi = i.alt_fi, alt_en = i.alt_en, caption_fi = i.caption_fi, caption_en = i.caption_en, sort_order = i.sort_order where id = p_image_id returning * into i;
  perform booking._article_assert_live_ok(i.article_id);
  select * into a from booking.articles where id = i.article_id;
  return jsonb_build_object('ok', true, 'image', to_jsonb(i) || jsonb_build_object('url', booking._article_img_url(i.path)), 'article', booking._article_admin_json(a));
end $$;

-- poistaa rekisteröinnin; Storage-tiedoston poistaa asiakas (Storage-API, oikeus articles.manage). Palauttaa polun.
create or replace function booking.admin_remove_article_image(p_image_id bigint)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare i booking.article_images; a booking.articles;
begin
  perform booking._article_auth();
  select * into i from booking.article_images where id = p_image_id for update;
  if not found then perform booking._err('not_found', 'Kuvaa ei löydy'); end if;
  select * into a from booking.articles where id = i.article_id;
  if coalesce(a.content_fi, '') ~ ('img:' || i.id || '([^0-9]|$)') or coalesce(a.content_en, '') ~ ('img:' || i.id || '([^0-9]|$)') then
    perform booking._err('image_in_use', 'Kuvaan viitataan artikkelin sisällössä (img:' || i.id || '); poista viite ensin');
  end if;
  if a.hero_image_id = i.id and a.status = 'published' and a.deleted_at is null then perform booking._err('image_in_use', 'Julkaistun artikkelin pääkuvaa ei voi poistaa; vaihda pääkuva ensin'); end if;
  delete from booking.article_images where id = i.id;
  select * into a from booking.articles where id = i.article_id;
  return jsonb_build_object('ok', true, 'removed_path', i.path, 'bucket', 'article-images', 'article', booking._article_admin_json(a));
end $$;

-- ---------- 8) oikeudet ----------
revoke all on function booking._article_md_check(text), booking._article_img_url(text), booking._article_lang_complete(booking.articles, text), booking._article_en_started(booking.articles),
  booking._article_issues(booking.articles), booking._article_words(text), booking._article_path(text), booking._article_abs(text, text), booking._article_img_json(booking.article_images, text),
  booking._article_alts(booking.articles), booking._article_card(booking.articles, text), booking._article_visible(booking.articles, text), booking._article_admin_json(booking.articles),
  booking._article_assert_live_ok(bigint), booking._article_auth(), booking._articles_touch_trg() from public, anon, authenticated;
revoke all on function booking.public_list_articles(text, integer, integer, text), booking.public_get_article(text, text), booking.public_articles_sitemap() from public;
grant execute on function booking.public_list_articles(text, integer, integer, text), booking.public_get_article(text, text), booking.public_articles_sitemap() to anon, authenticated, service_role;
revoke all on function booking.admin_list_articles(text, text, integer, integer), booking.admin_get_article(bigint), booking.admin_upsert_article(bigint, jsonb), booking.admin_publish_article(bigint, timestamptz),
  booking.admin_unpublish_article(bigint), booking.admin_delete_article(bigint), booking.admin_restore_article(bigint),
  booking.admin_register_article_image(bigint, text, integer, integer, text, text, text, text, integer, text, integer, boolean), booking.admin_update_article_image(bigint, jsonb), booking.admin_remove_article_image(bigint) from public, anon;
grant execute on function booking.admin_list_articles(text, text, integer, integer), booking.admin_get_article(bigint), booking.admin_upsert_article(bigint, jsonb), booking.admin_publish_article(bigint, timestamptz),
  booking.admin_unpublish_article(bigint), booking.admin_delete_article(bigint), booking.admin_restore_article(bigint),
  booking.admin_register_article_image(bigint, text, integer, integer, text, text, text, text, integer, text, integer, boolean), booking.admin_update_article_image(bigint, jsonb), booking.admin_remove_article_image(bigint) to authenticated, service_role;
