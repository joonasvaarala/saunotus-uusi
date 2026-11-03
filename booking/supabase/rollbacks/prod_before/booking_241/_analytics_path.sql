CREATE OR REPLACE FUNCTION booking._analytics_path(p_path text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v text;
  m text[];
begin
  v := lower(left(coalesce(p_path, ''), 300));
  v := split_part(split_part(v, '#', 1), '?', 1);
  v := regexp_replace(v, '/{2,}', '/', 'g');
  v := regexp_replace(v, '/index\.html?$', '/');
  if v = '' or left(v, 1) <> '/' then return '/muu'; end if;
  if right(v, 1) <> '/' then v := v || '/'; end if;
  if v ~ '^/(en/)?(hallinta|admin)/' then return null; end if;
  -- Sivuston reitit (content/site.json pages + tilaussivu + Saunatietoa-listaus, content/articles.json path).
  if v in ('/', '/en/', '/saunavuorot/', '/en/sauna/', '/hoidot-rituaalit/', '/en/treatments-rituals/', '/lahjakortti/', '/en/gift-card/',
           '/varaa/', '/en/book/', '/info/', '/en/info/', '/yritykset/', '/en/companies/', '/ehdot/', '/en/terms/', '/tietosuoja/',
           '/tilaus/', '/en/order/', '/saunatietoa/', '/en/sauna-knowledge/') then
    return v;
  end if;
  if v ~ '^/saunatietoa/tagi/' then return '/saunatietoa/tagi/'; end if;
  if v ~ '^/en/sauna-knowledge/tag/' then return '/en/sauna-knowledge/tag/'; end if;
  if v ~ '^/saunatietoa/sivu/[0-9]{1,3}/$' then return '/saunatietoa/'; end if;
  if v ~ '^/en/sauna-knowledge/page/[0-9]{1,3}/$' then return '/en/sauna-knowledge/'; end if;
  m := regexp_match(v, '^/saunatietoa/([a-z0-9]+(?:-[a-z0-9]+)*)/$');
  if m is not null and exists (select 1 from booking.articles a where a.slug_fi = m[1] and a.status = 'published'
                                 and a.published_at <= now() and a.deleted_at is null) then
    return v;
  end if;
  m := regexp_match(v, '^/en/sauna-knowledge/([a-z0-9]+(?:-[a-z0-9]+)*)/$');
  if m is not null and exists (select 1 from booking.articles a where a.slug_en = m[1] and a.status = 'published'
                                 and a.published_at <= now() and a.deleted_at is null) then
    return v;
  end if;
  return '/muu';
end $function$
;
