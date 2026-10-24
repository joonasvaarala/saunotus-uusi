-- ROLLBACK booking_165 (migraatio 20261024192515_booking_165_policy_en_keys.sql). Uudelleenajettava (toinen ajo ei tee mitään).
-- 1) Poistaa site_texts-rivit policy.7.title [en] ja policy.7.body [en] (ja niiden versiot). Keskeytyy eikä muuta mitään, jos jompikumpi
--    on jo julkaistu (published_version > 0: kb.policies 7 title_en/body_en on kirjoitettu -> päätetään erikseen) tai sillä on avoin
--    luonnos/ehdotus/hyväksytty versio (hylkää ensin: booking.admin_texts_reject).
-- 2) needs_translation = true takaisin niille neljälle fi-tekstille, joilta migraatio sen poisti (vain jos fi/en julkaistu versio ja teksti
--    ovat yhä samat kuin migraation tarkistuksessa; muuten lippu on jo muuttunut tavallisen julkaisun kautta eikä sitä kosketa).
-- 3) Palauttaa booking._texts_register_sources-funktion täsmälleen tuotannon muotoon ennen booking_165:tä (pg_get_functiondef-tuloste sellaisenaan).
--    Odotettu md5(pg_get_functiondef) ajon jälkeen:
--   booking._texts_register_sources: 6e5d43c7dbbc13c75830cd492d94eddd
-- Tarkistus: select md5(pg_get_functiondef('booking._texts_register_sources()'::regprocedure));
-- Vartija: funktion md5 ennen ajoa on oltava ff8a4cb6fd632d1d967f03c16b0101b1 (booking_165) tai jo 6e5d43c7dbbc13c75830cd492d94eddd; muuten keskeytyy.
set local lock_timeout = '5s';

do $rb$
declare v_md5 text := (select md5(pg_get_functiondef('booking._texts_register_sources()'::regprocedure))); v_ids bigint[]; r record; n int := 0;
begin
  if v_md5 not in ('ff8a4cb6fd632d1d967f03c16b0101b1', '6e5d43c7dbbc13c75830cd492d94eddd') then
    raise exception 'booking_165 rollback: booking._texts_register_sources md5 % ei ole odotettu; mitään ei muutettu', v_md5;
  end if;
  select coalesce(array_agg(id order by id), '{}') into v_ids from booking.site_texts
   where key in ('policy.7.title', 'policy.7.body') and lang = 'en' and source_table = 'kb.policies' and source_column in ('title_en', 'body_en');
  perform 1 from booking.site_texts where id = any (v_ids) for update;
  if exists (select 1 from booking.site_texts where id = any (v_ids) and published_version > 0) then
    raise exception 'booking_165 rollback: policy.7 [en] on jo julkaistu (kb.policies 7 title_en/body_en kirjoitettu); mitään ei muutettu';
  end if;
  if exists (select 1 from booking.site_text_versions where text_id = any (v_ids) and status in ('draft', 'proposed', 'approved', 'published')) then
    raise exception 'booking_165 rollback: policy.7 [en] -riveillä on avoimia versioita (hylkää ensin admin_texts_reject); mitään ei muutettu';
  end if;
  delete from booking.site_text_versions where text_id = any (v_ids);
  delete from booking.site_texts where id = any (v_ids);
  for r in select * from (values
      ('ui.site.privacy_analytics_text', 2, 'e9cc50625f6d01b023c0322bdad083ba', 2, '3e21bd16fd3771a62e68b1921339fc5a'),
      ('page.booking_info.note',         2, '980e5c5d517f47e77ac9c833b389359f', 2, '2ee9d493aeff66f1333956c2081928b3'),
      ('page.terms.note',                2, '3edfc6733fb636d729af638054287cc7', 2, 'f36370fedc3ad4234f9a63b2e8dcf57f'),
      ('seo.booking_info.description',   2, 'e53dc5e4bacee6ad80da9a5b6c9893eb', 2, '77061ef3c9f19e9e6b872246bfbab3c1')
    ) x(key, fi_ver, fi_md5, en_ver, en_md5)
  loop
    update booking.site_texts f set needs_translation = true
     where f.key = r.key and f.lang = 'fi' and not f.needs_translation and f.published_version = r.fi_ver and md5(f.published_text) = r.fi_md5
       and exists (select 1 from booking.site_texts e where e.key = r.key and e.lang = 'en' and e.published_version = r.en_ver and md5(e.published_text) = r.en_md5);
    if found then n := n + 1; end if;
  end loop;
  raise notice 'booking_165 rollback: poistettu % en-riviä, needs_translation palautettu % fi-tekstille', cardinality(v_ids), n;
end $rb$;

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
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'title', 'title_en', $$'en'$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false) and coalesce(nullif(s.language, ''), 'fi') = 'fi' and s.id <> 7 and lower(coalesce(s.category, '')) <> 'privacy' and s.title !~* '(tietosuoja|privacy)'$$, 300);  -- kb_policies_en_source (ei tietosuojaselostetta, id 7)
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'body', 'body_en', $$'en'$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false) and coalesce(nullif(s.language, ''), 'fi') = 'fi' and s.id <> 7 and lower(coalesce(s.category, '')) <> 'privacy' and s.title !~* '(tietosuoja|privacy)'$$, 20000);  -- kb_policies_en_source
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
