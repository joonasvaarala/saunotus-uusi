-- Rollback booking_62: poistaa admin_texts_import ja palauttaa public_get_site_texts-version ilman placeholders-kenttää. Tuoduista vapaista teksteistä (source_table null) poistetaan rivit versioineen.
set local lock_timeout = '5s';
delete from booking.site_texts where source_table is null;
drop function if exists booking.admin_texts_import(jsonb);
create or replace function booking.public_get_site_texts(p_lang text default null) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true, 'generated_at', now(), 'texts', coalesce(jsonb_agg(jsonb_build_object('key', t.key, 'lang', t.lang, 'text', t.published_text, 'version', t.published_version)
                                                                                           order by t.key, t.lang), '[]'::jsonb))
    from booking.site_texts t
   where t.published_version > 0 and t.published_text <> '' and t.class <> 'locked' and (p_lang is null or t.lang = lower(btrim(p_lang))) $$;
