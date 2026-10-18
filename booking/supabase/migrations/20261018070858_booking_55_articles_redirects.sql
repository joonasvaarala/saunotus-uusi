-- ============================================================
-- booking_55_articles_redirects: public_articles_redirects() – slug-ohjaukset yhdellä kutsulla (ei riipu välimuistista)
-- Koodari pyysi 18.10.2026. Palauttaa article_slug_history-rivit (vanha slug -> artikkelin NYKYINEN slug samalla kielellä) vain
-- julkaistuille artikkeleille (_article_visible: ei luonnos, ei poistettu, ei ajastettu tulevaisuuteen, kieliversio täydellinen).
-- Ei vuoda luonnoksia: jos artikkeli ei ole julkinen kyseisellä kielellä, riviä ei palauteta (sama sääntö kuin public_get_article 'moved').
-- Sopimus: docs/KOODARI_talous_A_D_fi.md §16.3. Rollback: rollbacks/ARTICLES_booking_55_ROLLBACK.sql
-- ============================================================
set local lock_timeout = '5s';

create or replace function booking.public_articles_redirects()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true, 'items', coalesce(jsonb_agg(jsonb_build_object(
           'lang', q.lang,
           'from_slug', q.old_slug, 'from_path', booking._article_path(q.lang) || q.old_slug || '/', 'from_loc', booking._article_abs(q.lang, q.old_slug),
           'to_slug', q.new_slug,   'to_path', booking._article_path(q.lang) || q.new_slug || '/',   'to_loc', booking._article_abs(q.lang, q.new_slug),
           'status', 301) order by q.lang, q.old_slug), '[]'::jsonb))
  from (
    select hh.lang, hh.slug as old_slug, case when hh.lang = 'en' then a.slug_en else a.slug_fi end as new_slug
      from booking.article_slug_history hh
      join booking.articles a on a.id = hh.article_id
     where booking._article_visible(a, hh.lang)
       and hh.slug is distinct from (case when hh.lang = 'en' then a.slug_en else a.slug_fi end)
       -- vanha osoite ei saa olla nyt jonkin toisen (poistamattoman) artikkelin oma osoite
       and not exists (select 1 from booking.articles x where x.deleted_at is null and x.id <> a.id
                        and (case when hh.lang = 'en' then x.slug_en else x.slug_fi end) = hh.slug)
  ) q
$$;
revoke all on function booking.public_articles_redirects() from public;
grant execute on function booking.public_articles_redirects() to anon, authenticated, service_role;
