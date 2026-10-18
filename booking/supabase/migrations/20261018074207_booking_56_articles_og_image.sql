-- ============================================================
-- booking_56_articles_og_image: artikkelille erillinen jakokuva (og:image), esim. 1200x630
-- articles.og_image_id (valinn., FK article_images, on delete set null) + admin_set_article_og_image(article_id, image_id|null).
-- Ei asetettu => seo.og_image = pääkuva (kuten ennen). public_get_article: seo.og_image = jakokuva, json_ld.image = [pääkuva, jakokuva].
-- admin_upsert_article-kenttiin ei kosketa; _article_admin_json palauttaa og_image_id automaattisesti (to_jsonb(a)).
-- Sopimus: docs/KOODARI_talous_A_D_fi.md §16.4. Rollback: rollbacks/ARTICLES_booking_56_ROLLBACK.sql
-- ============================================================
set local lock_timeout = '5s';

alter table booking.articles add column if not exists og_image_id bigint;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'articles_og_fk') then
    alter table booking.articles add constraint articles_og_fk foreign key (og_image_id) references booking.article_images(id) on delete set null;
  end if;
end $$;

create or replace function booking.admin_set_article_og_image(p_article_id bigint, p_image_id bigint default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare a booking.articles;
begin
  perform booking._article_auth();
  select * into a from booking.articles where id = p_article_id for update;
  if not found then perform booking._err('not_found', 'Artikkelia ei löydy'); end if;
  if a.deleted_at is not null then perform booking._err('deleted', 'Artikkeli on poistettu'); end if;
  if p_image_id is not null and not exists (select 1 from booking.article_images where id = p_image_id and article_id = p_article_id) then
    perform booking._err('image_not_found', 'Jakokuvan pitää olla tämän artikkelin rekisteröity kuva');
  end if;
  update booking.articles set og_image_id = p_image_id, updated_by = auth.uid() where id = p_article_id returning * into a;
  return jsonb_build_object('ok', true, 'article', booking._article_admin_json(a));
end $$;

create or replace function booking.public_get_article(p_slug text, p_lang text default 'fi')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_lang text := case when lower(btrim(coalesce(p_lang, 'fi'))) = 'en' then 'en' else 'fi' end;
        v_slug text := lower(btrim(coalesce(p_slug, ''))); a booking.articles; h booking.article_images; og booking.article_images; v_canon text; v_title text; v_desc text; v_pub text; v_logo text;
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
  select * into og from booking.article_images where id = a.og_image_id and article_id = a.id;
  if og.id is null then og := h; end if;   -- ei erillistä jakokuvaa: käytetään pääkuvaa
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
    'image', case when h.id is not null then jsonb_build_array(booking._article_img_url(h.path)) || case when og.id is not null and og.id <> h.id then jsonb_build_array(booking._article_img_url(og.path)) else '[]'::jsonb end end,
    'author', case when a.author_name is not null then jsonb_build_object('@type', 'Person', 'name', a.author_name) else jsonb_build_object('@type', 'Organization', 'name', coalesce(v_pub, 'Sipoonjoen Perinnesauna')) end,
    'publisher', jsonb_build_object('@type', 'Organization', 'name', coalesce(v_pub, 'Sipoonjoen Perinnesauna'), 'logo', case when v_logo is not null then jsonb_build_object('@type', 'ImageObject', 'url', v_logo) end),
    'keywords', case when cardinality(a.tags) > 0 then array_to_string(a.tags, ', ') end, 'articleSection', a.category));
  return jsonb_build_object('ok', true, 'article', booking._article_card(a, v_lang) || jsonb_build_object(
      'content_md', case when v_lang = 'en' then a.content_en else a.content_fi end, 'images', v_imgs),
    'seo', jsonb_build_object('title', coalesce(nullif(case when v_lang = 'en' then a.meta_title_en else a.meta_title_fi end, ''), v_title), 'description', v_desc,
      'canonical', v_canon, 'robots', case when a.noindex then 'noindex,follow' else 'index,follow' end, 'alternates', v_hrefs,
      'og_image', case when og.id is not null then booking._article_img_json(og, v_lang) end, 'og_type', 'article', 'json_ld', v_ld));
end $$;

revoke all on function booking.admin_set_article_og_image(bigint, bigint) from public, anon;
grant execute on function booking.admin_set_article_og_image(bigint, bigint) to authenticated, service_role;
