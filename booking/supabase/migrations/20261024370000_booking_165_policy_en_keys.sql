-- booking_165: tietosuojaselosteen (kb.policies id 7) EN-tekstiavaimet + needs_translation pois neljältä fi-tekstiltä.
-- Väliaikainen versio 20261024370000 (tuotannon versio voi olla eri; Bottiavustus ajaa). Ei public-skeemaa, ei skeemamuutoksia, ei julkaise tekstejä.
--
-- 1) policy.7.title [en] -> kb.policies.title_en ja policy.7.body [en] -> kb.policies.body_en tekstijärjestelmään (class protected, max 300 / 20000).
--    kb_policies_en_source (20261024123109) rajasi tietosuojaselosteen pois (s.id <> 7, category privacy, otsikko tietosuoja/privacy), koska
--    EN-tietosuojasivua ei silloin ollut (se tuli myöhemmin PR #145: /en/privacy/ rakennetaan vain, kun policy 7:llä on title_en JA body_en).
--    Rajaus ei johtunut tyhjistä arvoista: kaikki muutkin en-rivit luotiin tyhjinä (status empty, versio 0).
--    Nyt: booking._texts_register_sources-ehto sallii id 7:n (muut privacy-rivit edelleen pois) ja rivit luodaan suoraan booking._texts_reg-kutsulla
--    vain id 7:lle. Rivit ovat tyhjiä (published_text '', versio 0, status empty), kuten muut en-rivit: public_get_site_texts ei palauta niitä,
--    kb.policies ei muutu. texts_propose -> texts_submit -> admin_texts_approve toimii ja hyväksyntä kirjoittaa kb.policies 7 title_en / body_en
--    (_text_publish). Huom: EN-version julkaisu nostaa tavalliseen tapaan fi-rivin (policy.7.title/body [fi]) needs_translation-lipun.
-- 2) needs_translation = false neljälle fi-tekstille, joiden EN-versio päivitettiin samassa julkaisussa (tuotanto 24.10.2026: fi ja en v2,
--    published_at sama). Suora, kapea päivitys (tekstijärjestelmässä ei ole omaa funktiota lipun poistoon; booking_159 teki samoin).
--    Vartijat per avain: fi-lippu on true, en-rivi julkaistu (published_version > 0, teksti ei tyhjä), en.published_at >= fi.published_at, ja
--    fi/en julkaistu versio + md5(published_text) = tarkistetut arvot. Muuten avain ohitetaan (NOTICE), mitään ei muuteta.
--
-- Vartija: md5(pg_get_functiondef(booking._texts_register_sources)) on oltava tuotannon 6e5d43c7dbbc13c75830cd492d94eddd (tai jo tämän migraation ff8a4cb6fd632d1d967f03c16b0101b1),
-- muuten ajo keskeytyy eikä mitään muuteta. Uudelleenajettava: toinen ajo ei muuta mitään.
-- Tuotannon md5(pg_get_functiondef) ennen tätä migraatiota (luettu sxbofnuisemspgquoxyv 24.10.2026; rollback palauttaa tämän täsmälleen):
--   booking._texts_register_sources: 6e5d43c7dbbc13c75830cd492d94eddd
-- Tämän migraation jälkeen: booking._texts_register_sources: ff8a4cb6fd632d1d967f03c16b0101b1
-- Muita funktioita ei korvata (_texts_reg 028865c7d39e267063c336dcd8b54c11, texts_propose, texts_submit, admin_texts_approve, _text_publish ennallaan).
-- Rollback: rollbacks/20261024370000_booking_165_ROLLBACK.sql. Testi: tests/t165_policy_en_keys.sql (paikallinen PG17).
set local lock_timeout = '5s';

do $g$
declare v_md5 text := (select md5(pg_get_functiondef('booking._texts_register_sources()'::regprocedure)));
begin
  if v_md5 not in ('6e5d43c7dbbc13c75830cd492d94eddd', 'ff8a4cb6fd632d1d967f03c16b0101b1') then
    raise exception 'booking_165: booking._texts_register_sources md5 % ei ole odotettu (6e5d43c7dbbc13c75830cd492d94eddd / ff8a4cb6fd632d1d967f03c16b0101b1); mitään ei muutettu', v_md5;
  end if;
end $g$;

CREATE OR REPLACE FUNCTION booking._texts_register_sources()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n integer := 0; c text; pc text := $c$case when lower(coalesce(s.category, '')) in ('hinnat','varaaminen','booking','maksaminen','opening_hours','aukioloajat','käytännöt','practical','payment','cancellation','safety','accessibility','privacy','gift_card','season_card','training_terms','house_rules','dress_code') then 'protected' else 'normal' end$c$;
begin
  -- kb.products (aktiiviset): nimet/kuvaukset normal; kesto protected; hinta/slug/URL locked
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'name', 'name', $$'fi'$$, $$'normal'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'name', 'name_en', $$'en'$$, $$'normal'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'description', 'description', $$'fi'$$, $$'normal'$$, 's.active', 4000);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'description', 'description_en', $$'en'$$, $$'normal'$$, 's.active', 4000);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'short_description', 'short_description', $$'fi'$$, $$'normal'$$, 's.active', 1000);  -- booking_156
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'short_description', 'short_description_en', $$'en'$$, $$'normal'$$, 's.active', 1000);  -- booking_156
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'duration_text', 'duration_text', $$'fi'$$, $$'protected'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'duration_text', 'duration_text_en', $$'en'$$, $$'protected'$$, 's.active', 200);  -- kb_products_duration_text_en
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'price_text', 'price_text', $$'fi'$$, $$'locked'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'slug', 'slug', $$'all'$$, $$'locked'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'booking_url', 'booking_url', $$'all'$$, $$'locked'$$, 's.active', 500);
  -- UKK
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'question', 'question', $$coalesce(nullif(s.language, ''), 'fi')$$, pc, 's.active', 500);
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'answer', 'answer', $$coalesce(nullif(s.language, ''), 'fi')$$, pc, 's.active', 6000);
  -- kb_texts_en_sources: en-käännös suomenkielisen UKK-rivin _en-sarakkeisiin (samat avaimet faq.<fi-id>.*); erilliset en-rivit ennallaan
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'question', 'question_en', $$'en'$$, pc, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 500);
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'answer', 'answer_en', $$'en'$$, pc, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 6000);
  -- ehdot ja käytännöt (kaikki protected)
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'title', 'title', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false)$$, 300);
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'body', 'body', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false)$$, 20000);
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'title', 'title_en', $$'en'$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false) and coalesce(nullif(s.language, ''), 'fi') = 'fi' and (s.id = 7 or (lower(coalesce(s.category, '')) <> 'privacy' and s.title !~* '(tietosuoja|privacy)'))$$, 300);  -- kb_policies_en_source; booking_165: tietosuojaseloste id 7 mukana
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'body', 'body_en', $$'en'$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false) and coalesce(nullif(s.language, ''), 'fi') = 'fi' and (s.id = 7 or (lower(coalesce(s.category, '')) <> 'privacy' and s.title !~* '(tietosuoja|privacy)'))$$, 20000);  -- kb_policies_en_source; booking_165
  -- lisäpalvelut, tuotevalinnat, lahjakorttipaketit, vuorojen nimet
  foreach c in array array['name', 'description'] loop
    n := n + booking._texts_reg('booking.addons', 'id', 'addon', c, c, $$'fi'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.addons', 'id', 'addon', c, c || '_en', $$'en'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.product_options', 'id', 'option', c, c, $$'fi'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.product_options', 'id', 'option', c, c || '_en', $$'en'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', c, c, $$'fi'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', c, c || '_en', $$'en'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
  end loop;
  n := n + booking._texts_reg('booking.schedule_rules', 'id', 'schedule', 'label', 'label', $$'fi'$$, $$'normal'$$, 's.active', 200);
  n := n + booking._texts_reg('booking.schedule_rules', 'id', 'schedule', 'label', 'label_en', $$'en'$$, $$'protected'$$, 's.active', 200);  -- kb_texts_en_sources (nimissä kellonajat/kestot)
  -- sijainnit, aukioloajat, tapahtumat, yritys (kaikki protected: tosiasiat)
  foreach c in array array['name', 'description', 'directions', 'parking', 'public_transport', 'accessibility'] loop
    n := n + booking._texts_reg('kb.locations', 'id', 'location', c, c, $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 3000);
    n := n + booking._texts_reg('kb.locations', 'id', 'location', c, c || '_en', $$'en'$$, $$'protected'$$, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 3000);  -- kb_texts_en_sources
  end loop;
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'session_name', 'session_name', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'swimsuit_rule', 'swimsuit_rule', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 500);
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'session_name', 'session_name_en', $$'en'$$, $$'protected'$$, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 200);  -- kb_texts_en_sources
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'swimsuit_rule', 'swimsuit_rule_en', $$'en'$$, $$'protected'$$, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 500);  -- kb_texts_en_sources
  n := n + booking._texts_reg('kb.event_dates', 'id', 'event', 'time_text', 'time_text', $$'fi'$$, $$'protected'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.event_dates', 'id', 'event', 'time_text', 'time_text_en', $$'en'$$, $$'protected'$$, 's.active', 200);  -- kb_texts_en_sources
  n := n + booking._texts_reg('kb.businesses', 'id', 'business', 'description', 'description', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 4000);
  n := n + booking._texts_reg('kb.businesses', 'id', 'business', 'description', 'description_en', $$'en'$$, $$'protected'$$, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 4000);  -- kb_texts_en_sources
  -- booking_61: tuotteen lahjakorttihuomautus (product_config) ja aikajanan osavaiheiden nimet
  n := n + booking._texts_reg('booking.product_config', 'product_id', 'product_voucher', 'note', 'voucher_note', $$'fi'$$, $$'protected'$$, $$s.voucher_note is not null or s.voucher_note_en is not null$$, 600);
  n := n + booking._texts_reg('booking.product_config', 'product_id', 'product_voucher', 'note', 'voucher_note_en', $$'en'$$, $$'protected'$$, $$s.voucher_note is not null or s.voucher_note_en is not null$$, 600);
  n := n + booking._texts_reg('booking.product_timeline_segments', 'id', 'timeline', 'label', 'label', $$'fi'$$, $$'normal'$$, 's.customer_visible', 60);
  n := n + booking._texts_reg('booking.product_timeline_segments', 'id', 'timeline', 'label', 'label_en', $$'en'$$, $$'normal'$$, 's.customer_visible', 60);
  -- seed-versiot (versio 1 = nykyinen lähdeteksti)
  insert into booking.site_text_versions(text_id, version, text, status, base_version, author_kind, author_label, reason, published_at, escalation, protected)
  select t.id, 1, t.published_text, 'published', 0, 'system', 'seed booking_60', 'Alkutila lähdetaulusta', now(), '{}', false
    from booking.site_texts t where t.published_version = 1 and not exists (select 1 from booking.site_text_versions v where v.text_id = t.id);
  return n;
end $function$;

-- policy.7.title / policy.7.body [en]: vain id 7 (olemassa olevia rivejä ei kosketa: on conflict do nothing)
select booking._texts_reg('kb.policies', 'id', 'policy', 'title', 'title_en', $$'en'$$, $$'protected'$$, $$s.id = 7 and s.status = 'active' and not coalesce(s.internal, false) and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 300);
select booking._texts_reg('kb.policies', 'id', 'policy', 'body', 'body_en', $$'en'$$, $$'protected'$$, $$s.id = 7 and s.status = 'active' and not coalesce(s.internal, false) and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 20000);
-- seed-versio vain, jos lähdesarakkeessa oli jo tekstiä (sama sääntö kuin _texts_register_sources; tuotannossa title_en/body_en ovat null -> ei versiota)
insert into booking.site_text_versions(text_id, version, text, status, base_version, author_kind, author_label, reason, published_at, escalation, protected)
select t.id, 1, t.published_text, 'published', 0, 'system', 'seed booking_165', 'Alkutila lähdetaulusta', now(), '{}', false
  from booking.site_texts t
 where t.source_table = 'kb.policies' and t.source_pk = '7' and t.source_column in ('title_en', 'body_en') and t.lang = 'en'
   and t.published_version = 1 and not exists (select 1 from booking.site_text_versions v where v.text_id = t.id);

do $m$
declare r record; f booking.site_texts; e booking.site_texts; n int := 0;
begin
  if exists (select 1 from kb.policies where id = 7 and status = 'active' and not coalesce(internal, false))
     and (select count(*) from booking.site_texts where key in ('policy.7.title', 'policy.7.body') and lang = 'en') <> 2 then
    raise exception 'booking_165: policy.7.title/body [en] -rivejä ei syntynyt; mitään ei muutettu';
  end if;
  for r in select * from (values
      ('ui.site.privacy_analytics_text', 2, 'e9cc50625f6d01b023c0322bdad083ba', 2, '3e21bd16fd3771a62e68b1921339fc5a'),
      ('page.booking_info.note',         2, '980e5c5d517f47e77ac9c833b389359f', 2, '2ee9d493aeff66f1333956c2081928b3'),
      ('page.terms.note',                2, '3edfc6733fb636d729af638054287cc7', 2, 'f36370fedc3ad4234f9a63b2e8dcf57f'),
      ('seo.booking_info.description',   2, 'e53dc5e4bacee6ad80da9a5b6c9893eb', 2, '77061ef3c9f19e9e6b872246bfbab3c1')
    ) x(key, fi_ver, fi_md5, en_ver, en_md5)
  loop
    select * into f from booking.site_texts where key = r.key and lang = 'fi' for update;
    if not found then raise notice 'booking_165: % [fi] puuttuu, ohitetaan', r.key; continue; end if;
    select * into e from booking.site_texts where key = r.key and lang = 'en' for update;
    if not found then raise notice 'booking_165: % [en] puuttuu, ohitetaan', r.key; continue; end if;
    if not f.needs_translation then raise notice 'booking_165: % [fi] needs_translation on jo false, ohitetaan', r.key; continue; end if;
    if e.published_version < 1 or e.published_text = '' or e.published_at is null or f.published_at is null or e.published_at < f.published_at then
      raise notice 'booking_165: % [en] ei ole julkaistu samaan aikaan tai fi:n jälkeen (fi %, en %), ohitetaan', r.key, f.published_at, e.published_at; continue;
    end if;
    if f.published_version <> r.fi_ver or md5(f.published_text) <> r.fi_md5 or e.published_version <> r.en_ver or md5(e.published_text) <> r.en_md5 then
      raise notice 'booking_165: % julkaistu teksti on muuttunut tarkistuksen jälkeen (fi v% %, en v% %), ohitetaan',
        r.key, f.published_version, md5(f.published_text), e.published_version, md5(e.published_text);
      continue;
    end if;
    update booking.site_texts set needs_translation = false where id = f.id and lang = 'fi' and needs_translation;
    n := n + 1;
  end loop;
  raise notice 'booking_165: needs_translation poistettu % fi-tekstiltä', n;
end $m$;
