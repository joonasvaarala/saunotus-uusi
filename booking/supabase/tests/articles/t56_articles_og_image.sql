do $t$
declare r jsonb; aid bigint; h bigint; o bigint; res text := ''; v jsonb; ok boolean;
begin
  r := booking.admin_upsert_article(null, jsonb_build_object('slug_fi','t56-testi-artikkeli','title_fi','T','summary_fi','s','content_fi','c','meta_description_fi','m'));
  aid := (r->'article'->>'id')::bigint;
  insert into booking.article_images(article_id,path,alt_fi,width,height,sort_order,mime) values (aid,'articles/'||aid||'/1-aaaaaa11.jpg','a',1600,1067,0,'image/jpeg') returning id into h;
  insert into booking.article_images(article_id,path,alt_fi,width,height,sort_order,mime) values (aid,'articles/'||aid||'/2-bbbbbb22.jpg','b',1200,630,1,'image/jpeg') returning id into o;
  update booking.articles set hero_image_id = h, status='published', published_at = now() - interval '1 minute' where id = aid;
  v := booking.public_get_article('t56-testi-artikkeli','fi');
  res := res || 'T1 ok=' || (v->>'ok') || ' og=hero:' || ((v->'seo'->'og_image'->>'id')::bigint = h) || E'\n';
  v := booking.admin_set_article_og_image(aid, o);
  res := res || 'T2 admin og_image_id=o:' || ((v->'article'->>'og_image_id')::bigint = o) || E'\n';
  v := booking.public_get_article('t56-testi-artikkeli','fi');
  res := res || 'T3 og=share:' || ((v->'seo'->'og_image'->>'id')::bigint = o) || ' jsonld_imgs=' || jsonb_array_length(v->'seo'->'json_ld'->'image') || E'\n';
  begin perform booking.admin_set_article_og_image(aid, 999999999); res := res || 'T4 FAIL no error' || E'\n';
  exception when others then res := res || 'T4 foreign image rejected: ' || coalesce(sqlerrm,'') || E'\n'; end;
  delete from booking.article_images where id = o;
  res := res || 'T5 after delete og null=' || ((select og_image_id is null from booking.articles where id=aid)) || ' og falls back hero=' || ((booking.public_get_article('t56-testi-artikkeli','fi')->'seo'->'og_image'->>'id')::bigint = h) || E'\n';
  v := booking.admin_set_article_og_image(aid, null);
  res := res || 'T6 clear ok=' || (v->>'ok') || E'\n';
  res := res || 'T7 anon_exec=' || has_function_privilege('anon','booking.admin_set_article_og_image(bigint,bigint)','execute') || ' auth_exec=' || has_function_privilege('authenticated','booking.admin_set_article_og_image(bigint,bigint)','execute') || E'\n';
  raise exception 'TESTRESULT %', res;
end $t$;
