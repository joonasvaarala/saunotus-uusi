-- booking_51_articles: testit (ajetaan tuotantokannassa yhtenä eränä; päättyy tarkoituksella poikkeukseen = täysi rollback, ei pysyvää dataa)
-- Ajo: begin; set local lock_timeout='3s'; set local statement_timeout='30s'; <migraatio>; <tämä tiedosto>;
create function pg_temp.code(p_sql text) returns text language plpgsql as $f$
declare d text;
begin execute p_sql; return 'ok';
exception when sqlstate 'BK001' then get stacked diagnostics d = pg_exception_detail; return d;
          when others then return 'E' || sqlstate;
end $f$;
create function pg_temp.msg(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return 'ok';
exception when others then return sqlerrm;
end $f$;
create function pg_temp.j(p_sql text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin execute p_sql into r; return r; end $f$;

do $$
declare
  _t jsonb := '[]'::jsonb; v_fail int := 0; v_total int := 0;
  v_admin uuid; v_staff uuid; v_out uuid := gen_random_uuid();
  r jsonb; r2 jsonb; id1 bigint; id2 bigint; id3 bigint; img1 bigint; img2 bigint; img3 bigint; p1 text; p2 text; p3 text; c text;
begin
  -- ---- apurit ----
  -- (rekisteröidään tulos listaan)
  select user_id into v_admin from booking.staff where role = 'admin' and active order by created_at limit 1;
  select user_id into v_staff from booking.staff where role = 'staff' and active order by created_at limit 1;
  if v_admin is null then raise exception 'testi vaatii admin-käyttäjän (booking.staff)'; end if;

  -- T1 rakenne
  _t := _t || jsonb_build_object('ok', to_regclass('booking.articles') is not null and to_regclass('booking.article_images') is not null and to_regclass('booking.article_slug_history') is not null, 'n', 'T1a taulut olemassa');
  _t := _t || jsonb_build_object('ok', (select count(*) from pg_class where oid in ('booking.articles'::regclass, 'booking.article_images'::regclass, 'booking.article_slug_history'::regclass) and relrowsecurity) = 3, 'n', 'T1b RLS päällä kaikissa');
  _t := _t || jsonb_build_object('ok', exists (select 1 from storage.buckets where id = 'article-images' and public and file_size_limit = 5242880 and allowed_mime_types = array['image/jpeg','image/png','image/webp']), 'n', 'T1c bucket article-images: julkinen, 5 Mt, jpeg/png/webp');
  _t := _t || jsonb_build_object('ok', (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'article_images_%') = 4
                                      and (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'article_images_%' and cmd <> 'SELECT' and coalesce(qual, '') || coalesce(with_check, '') !~ 'articles.manage') = 0, 'n', 'T1d 4 storage-policya, kirjoitus vaatii articles.manage');
  _t := _t || jsonb_build_object('ok', exists (select 1 from booking.role_permissions where role_code = 'admin' and permission = 'articles.manage') and exists (select 1 from booking.role_permissions where role_code = 'manager' and permission = 'articles.manage')
                                      and not exists (select 1 from booking.role_permissions where role_code = 'staff' and permission = 'articles.manage'), 'n', 'T1e oikeus articles.manage: admin+manager, ei staff');
  _t := _t || jsonb_build_object('ok', (select count(*) from booking.settings where key in ('articles_path_fi','articles_path_en','articles_label_fi','articles_label_en')) = 4, 'n', 'T1f asetukset polku/nimi');
  _t := _t || jsonb_build_object('ok', not has_function_privilege('anon', 'booking.admin_list_articles(text,text,integer,integer)', 'execute') and has_function_privilege('authenticated', 'booking.admin_list_articles(text,text,integer,integer)', 'execute')
                                      and has_function_privilege('anon', 'booking.public_get_article(text,text)', 'execute') and not has_function_privilege('anon', 'booking._article_issues(booking.articles)', 'execute'), 'n', 'T1g funktio-oikeudet (anon vain public_*)');
  _t := _t || jsonb_build_object('ok', not has_table_privilege('anon', 'booking.articles', 'select') and not has_table_privilege('authenticated', 'booking.articles', 'select'), 'n', 'T1h taulut eivät luettavissa suoraan');

  -- T2 oikeudet
  execute 'set local role anon';
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_list_articles()') = 'E42501', 'n', 'T2a anon ei voi kutsua admin_list_articles (42501)');
  _t := _t || jsonb_build_object('ok', pg_temp.code('select * from booking.articles') = 'E42501', 'n', 'T2b anon ei voi lukea taulua');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_out, 'role', 'authenticated')::text, true); perform set_config('request.jwt.claim.sub', v_out::text, true);
  execute 'set local role authenticated';
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_list_articles()') = 'forbidden', 'n', 'T2c ei-henkilöstö: forbidden');
  execute 'reset role';
  if v_staff is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_staff, 'role', 'authenticated')::text, true); perform set_config('request.jwt.claim.sub', v_staff::text, true);
    execute 'set local role authenticated';
    _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_upsert_article(null, ''{"slug_fi":"abc-def","title_fi":"x"}'')') = 'forbidden', 'n', 'T2d staff ilman oikeutta: forbidden');
    execute 'reset role';
  end if;

  -- palvelurooli / bottikäyttö
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true); perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role service_role';
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_list_articles()') = 'ok', 'n', 'T2e service_role (JWT) pääsee admin_*-RPC:ihin ilman henkilöstötunnusta');
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true);
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_list_articles()') = 'ok', 'n', 'T2f suora tietokantayhteys (postgres, ei JWT:tä) pääsee admin_*-RPC:ihin');
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_list_articles()') = 'forbidden', 'n', 'T2g anon-JWT ei pääse (forbidden, vaikka session_user=postgres)');
  perform set_config('request.jwt.claims', json_build_object('sub', v_out, 'role', 'authenticated')::text, true); perform set_config('request.jwt.claim.sub', v_out::text, true);
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_list_articles()') = 'forbidden', 'n', 'T2h authenticated-JWT ilman henkilöstöä ei pääse');
  -- admin-istunto
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true); perform set_config('request.jwt.claim.sub', v_admin::text, true);
  execute 'set local role authenticated';

  -- T3 luonti ja validointi
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_upsert_article(null, ''{"title_fi":"x"}'')') = 'invalid_param', 'n', 'T3a luonti ilman slugia -> invalid_param');
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_upsert_article(null, ''{"slug_fi":"Huono Slug","title_fi":"x"}'')') = 'invalid_slug', 'n', 'T3b väärä slug -> invalid_slug');
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_upsert_article(null, ''{"slug_fi":"ab","title_fi":"x"}'')') = 'invalid_slug', 'n', 'T3c liian lyhyt slug');
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_upsert_article(null, ''{"slug_fi":"abc-def","title_fi":"x","outo":1}'')') = 'invalid_param', 'n', 'T3d tuntematon kenttä');
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_upsert_article(null, ''{"slug_fi":"abc-def","title_fi":"x","tags":"a"}'')') = 'invalid_param', 'n', 'T3e tags väärä tyyppi');
  r := booking.admin_upsert_article(null, jsonb_build_object('slug_fi', 'testi-sauna-a', 'title_fi', 'Testiartikkeli A', 'tags', jsonb_build_array(' Sauna ', 'LÖYLY', 'sauna', ''), 'category', 'perusteet', 'author_name', 'Testi Kirjoittaja', 'sort_order', 5));
  id1 := (r -> 'article' ->> 'id')::bigint;
  _t := _t || jsonb_build_object('ok', r ->> 'ok' = 'true' and r ->> 'created' = 'true' and r -> 'article' ->> 'status' = 'draft' and r -> 'article' -> 'tags' = '["sauna","löyly"]'::jsonb, 'n', 'T3f luonti: luonnos, tagit normalisoitu ja deduplikoitu');
  _t := _t || jsonb_build_object('ok', r -> 'article' ->> 'effective_status' = 'draft' and (r -> 'article' -> 'issues') @> '["summary_fi","content_fi","meta_description_fi","hero_image"]'::jsonb and r -> 'article' ->> 'publishable' = 'false', 'n', 'T3g issues-lista puuttuvista kentistä');
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_upsert_article(null, ''{"slug_fi":"testi-sauna-a","title_fi":"toinen"}'')') = 'slug_taken', 'n', 'T3h sama slug -> slug_taken');
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_upsert_article(' || id1 || ', ''{"canonical_fi":"http://x.fi"}'')') = 'invalid_param', 'n', 'T3i canonical vain https');
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_upsert_article(' || id1 || ', ''{"meta_description_fi":"' || repeat('a', 171) || '"}'')') = 'invalid_param', 'n', 'T3j meta_description max 170');
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_upsert_article(999999999, ''{"title_fi":"x"}'')') = 'not_found', 'n', 'T3k tuntematon id -> not_found');

  -- T4 sisällön turvallisuus
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('content_fi', 'Moi <script>alert(1)</script>')::text)) = 'invalid_content', 'n', 'T4a <script> hylätään');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('content_fi', 'Moi <b>lihava</b>')::text)) = 'invalid_content', 'n', 'T4b raaka HTML hylätään');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('content_fi', '[klik](javascript:alert(1))')::text)) = 'invalid_content', 'n', 'T4c javascript:-linkki hylätään');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('content_fi', '[klik](JaVaScRiPt:alert(1))')::text)) = 'invalid_content', 'n', 'T4d javascript: kirjainkoosta riippumatta');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('content_fi', '![x](https://evil.example/a.png)')::text)) = 'invalid_content', 'n', 'T4e ulkoinen kuva hylätään');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('content_fi', '[x](data:text/html;base64,AAAA)')::text)) = 'invalid_content', 'n', 'T4f data:-osoite hylätään');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('content_fi', '[x](ftp://a.fi)')::text)) = 'invalid_content', 'n', 'T4g ftp-linkki hylätään');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('content_fi', '![x](img:999999999)')::text)) = 'invalid_image', 'n', 'T4h tuntematon img-viite -> invalid_image');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('content_fi', E'# Otsikko\n\n[a](https://a.fi) [b](/polku/) [c](#kohta) [d](mailto:a@b.fi) **lihava**')::text)) = 'ok', 'n', 'T4i sallitut linkit (https, /polku, #ankkuri, mailto) hyväksytään');

  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('content_fi', E'Teksti\n\n[1]: javascript:alert(1)')::text)) = 'invalid_content', 'n', 'T4j viittausmuotoinen linkkimääritys hylätään');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('content_fi', 'Kirjoita profile: nimi ja metadata: arvo, file: ei ole linkki.')::text)) = 'ok', 'n', 'T4k tavallinen teksti kaksoispisteineen ei kaadu (ei väärää hälytystä)');

  -- T5 kuvat
  p1 := 'articles/' || id1 || '/1760000000-abcdef12.webp'; p2 := 'articles/' || id1 || '/1760000001-abcdef13.jpg'; p3 := 'articles/' || id1 || '/1760000002-abcdef14.png';
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_register_article_image(%s, %L, 1200, 800)', id1, p1)) = 'file_not_uploaded', 'n', 'T5a tiedostoa ei Storagessa -> file_not_uploaded');
  execute 'reset role';
  insert into storage.objects(bucket_id, name) values ('article-images', p1), ('article-images', p2), ('article-images', p3);
  execute 'set local role authenticated';
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_register_article_image(%s, %L, 1200, 800)', id1, 'articles/999/1760000000-abcdef12.webp')) = 'invalid_image', 'n', 'T5b väärän artikkelin polku -> invalid_image');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_register_article_image(%s, %L, 1200, 800)', id1, '../x.png')) = 'invalid_image', 'n', 'T5c väärä polku');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_register_article_image(%s, %L, null, 800)', id1, p1)) = 'invalid_image', 'n', 'T5d mitat vaaditaan');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_register_article_image(%s, %L, 1200, 800, null, null, null, null, null, %L)', id1, p1, 'image/png')) = 'invalid_image', 'n', 'T5e MIME ei vastaa päätettä');
  r := booking.admin_register_article_image(id1, p1, 1600, 900, 'Sauna jään yllä', null, 'Kuvateksti', null, 123456, 'image/webp', 0, true);
  img1 := (r -> 'image' ->> 'id')::bigint;
  _t := _t || jsonb_build_object('ok', r ->> 'ok' = 'true' and (r -> 'article' ->> 'hero_image_id')::bigint = img1 and r -> 'image' ->> 'url' like '%/storage/v1/object/public/article-images/articles/%', 'n', 'T5f rekisteröinti + pääkuva + julkinen URL');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_register_article_image(%s, %L, 1600, 900)', id1, p1)) = 'invalid_image', 'n', 'T5g sama kuva ei rekisteröidy kahdesti');
  r := booking.admin_register_article_image(id1, p2, 800, 600, 'Toinen kuva', 'Second image', null, null, null, null, 1, false);
  img2 := (r -> 'image' ->> 'id')::bigint;
  r := booking.admin_register_article_image(id1, p3, 800, 600, null, null, null, null, null, null, 2, false);
  img3 := (r -> 'image' ->> 'id')::bigint;
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('hero_image_id', 999999999)::text)) = 'hero_not_found', 'n', 'T5h vieras hero_image_id -> hero_not_found');

  -- T6 julkaisuvaatimukset
  _t := _t || jsonb_build_object('ok', pg_temp.msg(format('select booking.admin_publish_article(%s)', id1)) like '%summary_fi%' and pg_temp.code(format('select booking.admin_publish_article(%s)', id1)) = 'not_publishable', 'n', 'T6a julkaisu vaillinaisena -> not_publishable (+lista)');
  r := booking.admin_upsert_article(id1, jsonb_build_object('summary_fi', 'Lyhyt tiivistelmä sivun listaukseen.', 'meta_description_fi', 'Meta-kuvaus hakukoneelle, enintään 170 merkkiä.', 'meta_title_fi', 'Testiartikkeli A | Sauna',
     'content_fi', E'# Testi\n\nAlku ![Toinen kuva](img:' || img2 || E')\n\n[linkki](https://example.com)', 'featured', true));
  _t := _t || jsonb_build_object('ok', r -> 'article' -> 'issues' = '[]'::jsonb and r -> 'article' ->> 'fi_complete' = 'true', 'n', 'T6b fi-täydellinen: ei puutteita');
  r := booking.admin_update_article_image(img1, jsonb_build_object('alt_fi', ''));
  _t := _t || jsonb_build_object('ok', r -> 'article' -> 'issues' @> '["hero_alt_fi"]'::jsonb, 'n', 'T6c pääkuvan alt puuttuu -> issues hero_alt_fi');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_publish_article(%s)', id1)) = 'not_publishable', 'n', 'T6d julkaisu ilman pääkuvan alt-tekstiä estetty');
  perform booking.admin_update_article_image(img1, jsonb_build_object('alt_fi', 'Sauna jään yllä'));
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('title_en', 'Only a title')::text)) = 'ok'
                                      and pg_temp.code(format('select booking.admin_publish_article(%s)', id1)) = 'not_publishable', 'n', 'T6e vain osittainen en-versio estää julkaisun (kaikki en-kentät tai ei mitään)');
  perform booking.admin_upsert_article(id1, jsonb_build_object('title_en', null));
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_publish_article(%s, %L)', id1, (now() + interval '3 years')::text)) = 'invalid_param', 'n', 'T6f julkaisuaika yli 2 v tulevaisuudessa hylätään');

  -- T7 julkinen näkyvyys
  execute 'reset role'; execute 'set local role anon'; perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true);
  r := booking.public_list_articles('fi');
  _t := _t || jsonb_build_object('ok', r ->> 'ok' = 'true' and not exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'slug' = 'testi-sauna-a'), 'n', 'T7a luonnos ei näy listassa (anon)');
  _t := _t || jsonb_build_object('ok', booking.public_get_article('testi-sauna-a', 'fi') ->> 'code' = 'not_found', 'n', 'T7b luonnos -> not_found');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true); perform set_config('request.jwt.claim.sub', v_admin::text, true);
  execute 'set local role authenticated';
  r := booking.admin_publish_article(id1);
  _t := _t || jsonb_build_object('ok', r -> 'article' ->> 'effective_status' = 'live' and r -> 'article' ->> 'published_at' is not null, 'n', 'T7c julkaisu onnistuu');
  execute 'reset role'; execute 'set local role anon'; perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true);
  r := booking.public_list_articles('fi');
  _t := _t || jsonb_build_object('ok', exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'slug' = 'testi-sauna-a' and e -> 'image' ->> 'alt' = 'Sauna jään yllä' and (e -> 'image' ->> 'width')::int = 1600 and (e ->> 'reading_minutes')::int >= 1 and e ->> 'lang' = 'fi'), 'n', 'T7d julkaistu näkyy listassa: kuva, alt, mitat, lukuaika');
  r := booking.public_get_article('testi-sauna-a', 'fi');
  _t := _t || jsonb_build_object('ok', r ->> 'ok' = 'true' and r -> 'article' ->> 'content_md' like '%img:%' and jsonb_array_length(r -> 'article' -> 'images') = 3 and r -> 'seo' ->> 'robots' = 'index,follow'
                                      and r -> 'seo' ->> 'title' = 'Testiartikkeli A | Sauna' and r -> 'seo' ->> 'canonical' like '%/saunatietoa/testi-sauna-a/' and r -> 'seo' -> 'json_ld' ->> '@type' = 'Article'
                                      and r -> 'seo' -> 'json_ld' ->> 'headline' = 'Testiartikkeli A' and r -> 'seo' -> 'json_ld' -> 'author' ->> 'name' = 'Testi Kirjoittaja' and r -> 'seo' -> 'og_image' ->> 'path' = p1
                                      and r -> 'seo' -> 'alternates' = '[]'::jsonb, 'n', 'T7e public_get_article: seo (title, canonical, robots, JSON-LD Article, og_image), ei hreflangia kun vain fi');
  _t := _t || jsonb_build_object('ok', booking.public_get_article('testi-sauna-a', 'en') ->> 'code' = 'not_found', 'n', 'T7f en-versiota ei ole -> not_found');
  _t := _t || jsonb_build_object('ok', booking.public_get_article('TESTI-SAUNA-A', 'fi') ->> 'ok' = 'true' and booking.public_get_article('x y', 'fi') ->> 'code' = 'not_found' and booking.public_get_article(null, 'fi') ->> 'code' = 'not_found', 'n', 'T7g slug kirjainkoosta riippumaton; virheellinen slug -> not_found');
  r := booking.public_articles_sitemap();
  _t := _t || jsonb_build_object('ok', exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'slug' = 'testi-sauna-a' and e ->> 'lang' = 'fi' and e ->> 'loc' like '%/saunatietoa/testi-sauna-a/' and e ->> 'updated_at' is not null and e -> 'alternates' = '[]'::jsonb), 'n', 'T7h sitemap sisältää julkaistun (ei hreflang-paria)');
  _t := _t || jsonb_build_object('ok', jsonb_array_length(booking.public_list_articles('fi', 1000, -5) -> 'items') <= 50 and (booking.public_list_articles('fi', 0) ->> 'limit')::int = 1 and booking.public_list_articles('xx') ->> 'lang' = 'fi', 'n', 'T7i limit/offset rajataan, tuntematon kieli -> fi');
  r := booking.public_list_articles('fi', 20, 0, 'LÖYLY');
  _t := _t || jsonb_build_object('ok', (r ->> 'total')::int >= 1 and r -> 'tags' @> '[{"tag":"sauna"}]'::jsonb, 'n', 'T7j tagisuodatus (kirjainkoosta riippumaton) + tagifasetti');
  _t := _t || jsonb_build_object('ok', (booking.public_list_articles('fi', 20, 0, 'ei-ole-tagi') ->> 'total')::int = 0, 'n', 'T7k tuntematon tagi -> 0');

  -- T8 en-versio, hreflang, noindex, ajastus
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true); perform set_config('request.jwt.claim.sub', v_admin::text, true);
  execute 'set local role authenticated';
  perform booking.admin_update_article_image(img1, jsonb_build_object('alt_en', 'Sauna above the ice'));
  perform booking.admin_update_article_image(img2, jsonb_build_object('alt_en', 'Second image'));
  r := booking.admin_upsert_article(id1, jsonb_build_object('slug_en', 'test-sauna-a', 'title_en', 'Test article A', 'summary_en', 'Short summary.', 'meta_description_en', 'Meta description for search engines.', 'content_en', E'# Test\n\n![Second image](img:' || img2 || ')'));
  _t := _t || jsonb_build_object('ok', r -> 'article' ->> 'en_complete' = 'true' and r -> 'article' -> 'issues' = '[]'::jsonb, 'n', 'T8a en-versio täydellinen julkaistulle artikkelille');
  execute 'reset role'; execute 'set local role anon'; perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true);
  r := booking.public_get_article('test-sauna-a', 'en');
  _t := _t || jsonb_build_object('ok', r ->> 'ok' = 'true' and r -> 'article' ->> 'title' = 'Test article A' and r -> 'seo' ->> 'canonical' like '%/en/sauna-knowledge/test-sauna-a/' and jsonb_array_length(r -> 'seo' -> 'alternates') = 3
                                      and r -> 'seo' -> 'alternates' @> '[{"hreflang":"fi"},{"hreflang":"en"},{"hreflang":"x-default"}]'::jsonb and r -> 'article' -> 'image' ->> 'alt' = 'Sauna above the ice', 'n', 'T8b en-sivu: hreflang fi+en+x-default, en alt-teksti');
  r := booking.public_articles_sitemap();
  _t := _t || jsonb_build_object('ok', (select count(*) from jsonb_array_elements(r -> 'items') e where e ->> 'slug' in ('testi-sauna-a', 'test-sauna-a')) = 2
                                      and exists (select 1 from jsonb_array_elements(r -> 'items') e where e ->> 'slug' = 'test-sauna-a' and jsonb_array_length(e -> 'alternates') = 3), 'n', 'T8c sitemap: molemmat kielet + hreflang-parit');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true); perform set_config('request.jwt.claim.sub', v_admin::text, true);
  execute 'set local role authenticated';
  perform booking.admin_upsert_article(id1, jsonb_build_object('noindex', true));
  execute 'reset role'; execute 'set local role anon'; perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true);
  _t := _t || jsonb_build_object('ok', booking.public_get_article('testi-sauna-a', 'fi') -> 'seo' ->> 'robots' = 'noindex,follow' and not exists (select 1 from jsonb_array_elements(booking.public_articles_sitemap() -> 'items') e where e ->> 'slug' in ('testi-sauna-a', 'test-sauna-a')), 'n', 'T8d noindex: robots noindex,follow, pois sitemapista');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true); perform set_config('request.jwt.claim.sub', v_admin::text, true);
  execute 'set local role authenticated';
  perform booking.admin_upsert_article(id1, jsonb_build_object('noindex', false, 'canonical_fi', 'https://example.org/alkuperainen/'));
  execute 'reset role'; execute 'set local role anon'; perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true);
  _t := _t || jsonb_build_object('ok', booking.public_get_article('testi-sauna-a', 'fi') -> 'seo' ->> 'canonical' = 'https://example.org/alkuperainen/' and not exists (select 1 from jsonb_array_elements(booking.public_articles_sitemap() -> 'items') e where e ->> 'slug' = 'testi-sauna-a' and e ->> 'lang' = 'fi'), 'n', 'T8e canonical-ohitus: canonical vaihtuu, fi pois sitemapista');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true); perform set_config('request.jwt.claim.sub', v_admin::text, true);
  execute 'set local role authenticated';
  perform booking.admin_upsert_article(id1, jsonb_build_object('canonical_fi', null));

  -- T9 slug-vaihto, uudelleenohjaus, toinen artikkeli
  r := booking.admin_upsert_article(null, jsonb_build_object('slug_fi', 'toinen-artikkeli', 'title_fi', 'Toinen'));
  id2 := (r -> 'article' ->> 'id')::bigint;
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id2, jsonb_build_object('slug_fi', 'testi-sauna-a')::text)) = 'slug_taken'
                                      and pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id2, jsonb_build_object('slug_en', 'test-sauna-a')::text)) = 'slug_taken', 'n', 'T9a slug (fi ja en) uniikki muihin nähden');
  perform booking.admin_upsert_article(id1, jsonb_build_object('slug_fi', 'testi-sauna-uusi'));
  execute 'reset role'; execute 'set local role anon'; perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true);
  r := booking.public_get_article('testi-sauna-a', 'fi');
  _t := _t || jsonb_build_object('ok', r ->> 'code' = 'moved' and r ->> 'slug' = 'testi-sauna-uusi' and r ->> 'path' = '/saunatietoa/testi-sauna-uusi/' and booking.public_get_article('testi-sauna-uusi', 'fi') ->> 'ok' = 'true', 'n', 'T9b vanha slug -> moved (uusi slug), uusi toimii');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true); perform set_config('request.jwt.claim.sub', v_admin::text, true);
  execute 'set local role authenticated';
  perform booking.admin_upsert_article(id1, jsonb_build_object('slug_fi', 'testi-sauna-a'));
  execute 'reset role'; execute 'set local role anon'; perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true);
  _t := _t || jsonb_build_object('ok', booking.public_get_article('testi-sauna-a', 'fi') ->> 'ok' = 'true' and booking.public_get_article('testi-sauna-uusi', 'fi') ->> 'code' = 'moved', 'n', 'T9c slugin palautus vapauttaa vanhan historiasta');

  -- T10 julkaistun artikkelin suojaus muokkauksessa
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true); perform set_config('request.jwt.claim.sub', v_admin::text, true);
  execute 'set local role authenticated';
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('summary_fi', null)::text)) = 'not_publishable', 'n', 'T10a julkaistun tiivistelmää ei voi tyhjentää');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_remove_article_image(%s)', img1)) = 'image_in_use', 'n', 'T10b julkaistun pääkuvaa ei voi poistaa');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_remove_article_image(%s)', img2)) = 'image_in_use', 'n', 'T10c sisällössä viitattua kuvaa ei voi poistaa');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_update_article_image(%s, %L)', img2, jsonb_build_object('alt_fi', '')::text)) = 'not_publishable', 'n', 'T10d sisältökuvan alt-tekstiä ei voi poistaa julkaistulta');
  r := booking.admin_remove_article_image(img3);
  _t := _t || jsonb_build_object('ok', r ->> 'removed_path' = p3 and r ->> 'bucket' = 'article-images', 'n', 'T10e käyttämätön kuva poistuu, polku palautuu Storage-poistoa varten');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('hero_image_id', null)::text)) = 'not_publishable', 'n', 'T10f julkaistulta ei voi poistaa pääkuvaa');

  -- T11 julkaisun peruutus, ajastus, poisto, palautus
  r := booking.admin_unpublish_article(id1);
  _t := _t || jsonb_build_object('ok', r -> 'article' ->> 'status' = 'draft' and r -> 'article' ->> 'published_at' is not null, 'n', 'T11a unpublish: luonnos, julkaisupäivä säilyy');
  execute 'reset role'; execute 'set local role anon'; perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true);
  _t := _t || jsonb_build_object('ok', booking.public_get_article('testi-sauna-a', 'fi') ->> 'code' = 'not_found' and booking.public_get_article('testi-sauna-a', 'en') ->> 'code' = 'not_found', 'n', 'T11b julkaisematon ei näy');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true); perform set_config('request.jwt.claim.sub', v_admin::text, true);
  execute 'set local role authenticated';
  r := booking.admin_publish_article(id1, now() + interval '30 days');
  _t := _t || jsonb_build_object('ok', r -> 'article' ->> 'effective_status' = 'scheduled', 'n', 'T11c tulevaisuuden julkaisuaika = scheduled');
  execute 'reset role'; execute 'set local role anon'; perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true);
  _t := _t || jsonb_build_object('ok', booking.public_get_article('testi-sauna-a', 'fi') ->> 'code' = 'not_found' and not exists (select 1 from jsonb_array_elements(booking.public_list_articles('fi') -> 'items') e where e ->> 'slug' = 'testi-sauna-a'), 'n', 'T11d ajastettu ei näy ennen aikaa');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true); perform set_config('request.jwt.claim.sub', v_admin::text, true);
  execute 'set local role authenticated';
  perform booking.admin_publish_article(id1, now() - interval '1 minute');
  r := booking.admin_delete_article(id1);
  _t := _t || jsonb_build_object('ok', r -> 'article' ->> 'effective_status' = 'deleted' and r -> 'article' ->> 'deleted_at' is not null, 'n', 'T11e pehmeä poisto (rivi säilyy)');
  _t := _t || jsonb_build_object('ok', pg_temp.code(format('select booking.admin_upsert_article(%s, %L)', id1, jsonb_build_object('title_fi', 'x')::text)) = 'deleted' and pg_temp.code(format('select booking.admin_publish_article(%s)', id1)) = 'deleted', 'n', 'T11f poistettua ei voi muokata/julkaista');
  execute 'reset role'; execute 'set local role anon'; perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true);
  _t := _t || jsonb_build_object('ok', booking.public_get_article('testi-sauna-a', 'fi') ->> 'code' = 'not_found', 'n', 'T11g poistettu ei näy');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true); perform set_config('request.jwt.claim.sub', v_admin::text, true);
  execute 'set local role authenticated';
  r := booking.admin_list_articles(null, 'deleted');
  _t := _t || jsonb_build_object('ok', (r ->> 'total')::int >= 1 and not exists (select 1 from jsonb_array_elements(booking.admin_list_articles() -> 'items') e where (e ->> 'id')::bigint = id1), 'n', 'T11h admin_list: poistetut vain status=deleted -suodattimella');
  r := booking.admin_restore_article(id1);
  _t := _t || jsonb_build_object('ok', r -> 'article' ->> 'effective_status' = 'draft', 'n', 'T11i palautus -> luonnos (ei automaattisesti julkinen)');
  r := booking.admin_list_articles('Toinen', null, 10, 0);
  _t := _t || jsonb_build_object('ok', (r ->> 'total')::int = 1 and r -> 'items' -> 0 ->> 'slug_fi' = 'toinen-artikkeli', 'n', 'T11j admin_list haku');
  r := booking.admin_get_article(id1);
  _t := _t || jsonb_build_object('ok', jsonb_array_length(r -> 'article' -> 'images') = 2 and r -> 'article' -> 'urls' ->> 'fi' like '%/saunatietoa/testi-sauna-a/', 'n', 'T11k admin_get_article: kuvat + osoitteet');
  _t := _t || jsonb_build_object('ok', pg_temp.code('select booking.admin_list_articles(null, ''outo'')') = 'invalid_param', 'n', 'T11l virheellinen status-suodatin');

  -- T12 storage-policyt (admin vs ei-oikeutta)
  begin
    insert into storage.objects(bucket_id, name) values ('article-images', 'articles/' || id1 || '/1760009999-zzzzzz99.png');
    _t := _t || jsonb_build_object('ok', true, 'n', 'T12a admin voi ladata kuvan oikeaan polkuun');
  exception when others then _t := _t || jsonb_build_object('ok', false, 'n', 'T12a admin voi ladata kuvan oikeaan polkuun (' || sqlstate || ')'); end;
  _t := _t || jsonb_build_object('ok', pg_temp.code($q$insert into storage.objects(bucket_id, name) values ('article-images', 'muu/kuva.png')$q$) = 'E42501', 'n', 'T12b väärä polku estetty');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_out, 'role', 'authenticated')::text, true); perform set_config('request.jwt.claim.sub', v_out::text, true);
  execute 'set local role authenticated';
  _t := _t || jsonb_build_object('ok', pg_temp.code($q$insert into storage.objects(bucket_id, name) values ('article-images', 'articles/1/1760009999-qqqqqq99.png')$q$) = 'E42501', 'n', 'T12c ei-henkilöstö ei voi ladata');
  execute 'reset role'; execute 'set local role anon'; perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true);
  _t := _t || jsonb_build_object('ok', pg_temp.code($q$insert into storage.objects(bucket_id, name) values ('article-images', 'articles/1/1760009999-qqqqqq99.png')$q$) = 'E42501', 'n', 'T12d anon ei voi ladata');
  _t := _t || jsonb_build_object('ok', (select count(*) from storage.objects where bucket_id = 'article-images') >= 3, 'n', 'T12e anon voi lukea bucketin');
  execute 'reset role';

  -- T13 audit
  _t := _t || jsonb_build_object('ok', (select count(*) from booking.audit_log where table_name like '%articles' and row_pk = id1::text) >= 5 and (select count(*) from booking.audit_log where table_name like '%article_images') >= 3 and exists (select 1 from booking.audit_log where table_name like '%articles' and row_pk = id1::text and actor = v_admin), 'n', 'T13 audit-loki: articles + article_images (actor = käyttäjä)');

  -- raportti
  for r in select e from jsonb_array_elements(_t) e loop
    v_total := v_total + 1; if r ->> 'ok' is distinct from 'true' then v_fail := v_fail + 1; end if;
  end loop;
  raise exception E'ARTICLES_TESTS fail=% total=%\n%', v_fail, v_total,
    (select string_agg(case when e ->> 'ok' = 'true' then 'ok   ' else 'FAIL ' end || (e ->> 'n'), E'\n') from jsonb_array_elements(_t) e);
end $$;
