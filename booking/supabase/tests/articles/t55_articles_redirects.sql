-- t55: public_articles_redirects(). Kumoutuu lopuksi (tahallinen poikkeus). Ajo: begin; <migraatio>; <tämä>;
set local lock_timeout = '3s';
set local statement_timeout = '30s';
create temp table t55_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t55_r values (coalesce(p_ok, false), p_label) $$;
do $t$
declare r jsonb; a_pub bigint; a_draft bigint; a_future bigint; a_del bigint; a_enpart bigint; a_conf bigint; n0 int;
begin
  n0 := jsonb_array_length(booking.public_articles_redirects() -> 'items');
  -- julkaistu fi+en
  insert into booking.articles(status, published_at, slug_fi, title_fi, summary_fi, content_fi, meta_description_fi, slug_en, title_en, summary_en, content_en, meta_description_en)
  values ('published', now() - interval '1 day', 't55-uusi', 'T', 'S', 'C', 'M', 't55-new', 'T', 'S', 'C', 'M') returning id into a_pub;
  insert into booking.article_slug_history(article_id, lang, slug) values (a_pub, 'fi', 't55-vanha'), (a_pub, 'fi', 't55-vanhempi'), (a_pub, 'en', 't55-old');
  -- luonnos (historiassa vanha osoite) – ei saa vuotaa
  insert into booking.articles(status, published_at, slug_fi, title_fi, summary_fi, content_fi, meta_description_fi)
  values ('draft', now() - interval '2 days', 't55-luonnos-uusi', 'T', 'S', 'C', 'M') returning id into a_draft;
  insert into booking.article_slug_history(article_id, lang, slug) values (a_draft, 'fi', 't55-luonnos-vanha');
  -- ajastettu tulevaisuuteen
  insert into booking.articles(status, published_at, slug_fi, title_fi, summary_fi, content_fi, meta_description_fi)
  values ('published', now() + interval '3 days', 't55-tuleva-uusi', 'T', 'S', 'C', 'M') returning id into a_future;
  insert into booking.article_slug_history(article_id, lang, slug) values (a_future, 'fi', 't55-tuleva-vanha');
  -- poistettu
  insert into booking.articles(status, published_at, deleted_at, slug_fi, title_fi, summary_fi, content_fi, meta_description_fi)
  values ('draft', now() - interval '2 days', now(), 't55-poistettu-uusi', 'T', 'S', 'C', 'M') returning id into a_del;
  insert into booking.article_slug_history(article_id, lang, slug) values (a_del, 'fi', 't55-poistettu-vanha');
  -- fi julkinen, en vaillinen (en-historia ei saa näkyä)
  insert into booking.articles(status, published_at, slug_fi, title_fi, summary_fi, content_fi, meta_description_fi, slug_en, title_en)
  values ('published', now() - interval '1 day', 't55-enosa-uusi', 'T', 'S', 'C', 'M', 't55-enpart-new', 'T') returning id into a_enpart;
  insert into booking.article_slug_history(article_id, lang, slug) values (a_enpart, 'en', 't55-enpart-old'), (a_enpart, 'fi', 't55-enosa-vanha');
  -- vanha osoite on nyt toisen artikkelin oma osoite (ei ohjausta)
  insert into booking.articles(status, published_at, slug_fi, title_fi, summary_fi, content_fi, meta_description_fi)
  values ('published', now() - interval '1 day', 't55-konflikti-a', 'T', 'S', 'C', 'M') returning id into a_conf;
  insert into booking.article_slug_history(article_id, lang, slug) values (a_conf, 'fi', 't55-uusi');   -- sama kuin a_pub:n nykyinen slug (ei sallita ohjausta)

  r := booking.public_articles_redirects();
  perform pg_temp.ck((r ->> 'ok')::boolean, 'R1: ok');
  perform pg_temp.ck(jsonb_array_length(r -> 'items') - n0 = 4, 'R2: täsmälleen 4 uutta ohjausta (fi vanha, fi vanhempi, en old, fi enosa-vanha): ' || (jsonb_array_length(r -> 'items') - n0));
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'lang' = 'fi' and e ->> 'from_slug' = 't55-vanha' and e ->> 'to_slug' = 't55-uusi'
                              and e ->> 'to_path' = booking._article_path('fi') || 't55-uusi/' and e ->> 'from_path' = booking._article_path('fi') || 't55-vanha/' and (e ->> 'status')::int = 301
                              and e ->> 'to_loc' = booking._article_abs('fi', 't55-uusi') and e ->> 'from_loc' = booking._article_abs('fi', 't55-vanha')), 'R3: fi-ohjaus kentät oikein (path/loc/301)');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'lang' = 'en' and e ->> 'from_slug' = 't55-old' and e ->> 'to_slug' = 't55-new' and e ->> 'to_path' = booking._article_path('en') || 't55-new/'), 'R4: en-ohjaus oikealla kielellä ja polulla');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'from_slug' = 't55-vanhempi' and e ->> 'to_slug' = 't55-uusi'), 'R5: useampi vanha slug osoittaa nykyiseen (ei ketjuja)');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'from_slug' like 't55-luonnos%' or e ->> 'to_slug' like 't55-luonnos%'), 'R6: luonnos ei vuoda');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'from_slug' like 't55-tuleva%'), 'R7: ajastettu (tulevaisuus) ei vuoda');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'from_slug' like 't55-poistettu%'), 'R8: poistettu ei vuoda');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'from_slug' = 't55-enpart-old'), 'R9: vaillinen en-versio ei vuoda en-ohjausta');
  perform pg_temp.ck(exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'from_slug' = 't55-enosa-vanha' and e ->> 'to_slug' = 't55-enosa-uusi'), 'R10: fi-versio täydellinen => fi-ohjaus näkyy');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'from_slug' = 't55-uusi' and e ->> 'lang' = 'fi' and e ->> 'to_slug' <> 't55-uusi'), 'R11: toisen artikkelin oma slug ei ole ohjauksen lähde');
  -- yhdenmukaisuus public_get_article 'moved' kanssa
  perform pg_temp.ck(booking.public_get_article('t55-vanha', 'fi') ->> 'code' = 'moved' and booking.public_get_article('t55-vanha', 'fi') ->> 'slug' = 't55-uusi', 'R12: täsmää public_get_article moved -vastaukseen');
  perform pg_temp.ck(booking.public_get_article('t55-luonnos-vanha', 'fi') ->> 'code' = 'not_found', 'R13: luonnoksen vanha osoite on not_found (kuten listassa puuttuu)');
  -- anon
  execute 'set local role anon';
  r := booking.public_articles_redirects();
  execute 'reset role';
  perform pg_temp.ck((r ->> 'ok')::boolean and jsonb_array_length(r -> 'items') - n0 = 4, 'R14: anon voi kutsua, sama tulos');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_articles_redirects()', 'execute') and not has_table_privilege('anon', 'booking.article_slug_history', 'select'), 'R15: anon execute, ei suoraa taulukäyttöä');
  -- järjestys deterministinen
  perform pg_temp.ck((select array_agg((e ->> 'lang') || (e ->> 'from_slug')) from jsonb_array_elements(booking.public_articles_redirects() -> 'items') e) = (select array_agg(x order by x) from (select (e ->> 'lang') || (e ->> 'from_slug') x from jsonb_array_elements(booking.public_articles_redirects() -> 'items') e) s), 'R16: järjestys lang, from_slug');
  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t55_r where ok), (select count(*) from t55_r where not ok), coalesce((select string_agg(label, ' | ') from t55_r where not ok), 'ALL OK');
end $t$;
