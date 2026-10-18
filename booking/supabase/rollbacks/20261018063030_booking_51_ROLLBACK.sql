-- ROLLBACK booking_51_articles (poistaa myös artikkelidatan; Storage-tiedostot poistetaan erikseen Storage-API:lla)
drop function if exists booking.public_list_articles(text, integer, integer, text), booking.public_get_article(text, text), booking.public_articles_sitemap(),
  booking.admin_list_articles(text, text, integer, integer), booking.admin_get_article(bigint), booking.admin_upsert_article(bigint, jsonb), booking.admin_publish_article(bigint, timestamptz),
  booking.admin_unpublish_article(bigint), booking.admin_delete_article(bigint), booking.admin_restore_article(bigint),
  booking.admin_register_article_image(bigint, text, integer, integer, text, text, text, text, integer, text, integer, boolean), booking.admin_update_article_image(bigint, jsonb), booking.admin_remove_article_image(bigint);
drop function if exists booking._article_admin_json(booking.articles), booking._article_assert_live_ok(bigint), booking._article_auth(), booking._article_visible(booking.articles, text), booking._article_card(booking.articles, text),
  booking._article_alts(booking.articles), booking._article_img_json(booking.article_images, text), booking._article_abs(text, text), booking._article_path(text), booking._article_words(text),
  booking._article_issues(booking.articles), booking._article_en_started(booking.articles), booking._article_lang_complete(booking.articles, text), booking._article_img_url(text), booking._article_md_check(text);
drop table if exists booking.article_slug_history;
alter table if exists booking.articles drop constraint if exists articles_hero_fk;
drop table if exists booking.article_images;
drop table if exists booking.articles;
drop function if exists booking._articles_touch_trg();
drop policy if exists article_images_read on storage.objects; drop policy if exists article_images_insert on storage.objects;
drop policy if exists article_images_update on storage.objects; drop policy if exists article_images_delete on storage.objects;
-- Bucketin ja tiedostojen poisto: Supabase estää suoran DELETEn storage-tauluihin -> poista tiedostot ja bucket Storage-API:lla / dashboardilta (bucket: article-images)
delete from booking.role_permissions where permission = 'articles.manage';
delete from booking.settings where key in ('articles_path_fi', 'articles_path_en', 'articles_label_fi', 'articles_label_en');
