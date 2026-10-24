-- kb_texts_en_sources: englanninkieliset lähdesarakkeet UKK:lle, sijainneille, aukioloille, vuorojen nimille, tapahtuma-ajoille ja yrityskuvaukselle.
-- Malli kuten kb_products_duration_text_en (20261024121904): nullable _en-sarake suomenkieliselle riville + rekisteröinti _texts_register_sources:iin
-- -> tyhjät en-rivit (status empty, versio 0) samoilla avaimilla kuin fi-rivit. Julkaisu kirjoittaa vain _en-sarakkeeseen.
-- Ei uusia kb-rivejä (frontend ei näe tyhjiä), olemassa olevat en-UKK-rivit (19–23) ennallaan. policy.* ei mukana.
-- Rollback: rb.sql
set local lock_timeout = '5s';
alter table kb.faq add column if not exists question_en text, add column if not exists answer_en text;
alter table kb.locations add column if not exists name_en text, add column if not exists description_en text, add column if not exists directions_en text, add column if not exists parking_en text, add column if not exists public_transport_en text, add column if not exists accessibility_en text;
alter table kb.opening_hours add column if not exists session_name_en text, add column if not exists swimsuit_rule_en text;
alter table kb.event_dates add column if not exists time_text_en text;
alter table kb.businesses add column if not exists description_en text;
alter table booking.schedule_rules add column if not exists label_en text;
comment on column kb.faq.question_en is 'Englanninkielinen teksti (site_texts [en], kb_texts_en_sources)';
comment on column kb.faq.answer_en is 'Englanninkielinen teksti (site_texts [en], kb_texts_en_sources)';
comment on column kb.locations.name_en is 'Englanninkielinen teksti (site_texts [en], kb_texts_en_sources)';
comment on column kb.locations.description_en is 'Englanninkielinen teksti (site_texts [en], kb_texts_en_sources)';
comment on column kb.locations.directions_en is 'Englanninkielinen teksti (site_texts [en], kb_texts_en_sources)';
comment on column kb.locations.parking_en is 'Englanninkielinen teksti (site_texts [en], kb_texts_en_sources)';
comment on column kb.locations.public_transport_en is 'Englanninkielinen teksti (site_texts [en], kb_texts_en_sources)';
comment on column kb.locations.accessibility_en is 'Englanninkielinen teksti (site_texts [en], kb_texts_en_sources)';
comment on column kb.opening_hours.session_name_en is 'Englanninkielinen teksti (site_texts [en], kb_texts_en_sources)';
comment on column kb.opening_hours.swimsuit_rule_en is 'Englanninkielinen teksti (site_texts [en], kb_texts_en_sources)';
comment on column kb.event_dates.time_text_en is 'Englanninkielinen teksti (site_texts [en], kb_texts_en_sources)';
comment on column kb.businesses.description_en is 'Englanninkielinen teksti (site_texts [en], kb_texts_en_sources)';
comment on column booking.schedule_rules.label_en is 'Englanninkielinen teksti (site_texts [en], kb_texts_en_sources)';
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
do $do$
declare n integer := 0; c text; pc text := $c$case when lower(coalesce(s.category, '')) in ('hinnat','varaaminen','booking','maksaminen','opening_hours','aukioloajat','käytännöt','practical','payment','cancellation','safety','accessibility','privacy','gift_card','season_card','training_terms','house_rules','dress_code') then 'protected' else 'normal' end$c$;
begin
  foreach c in array array['name', 'description', 'directions', 'parking', 'public_transport', 'accessibility'] loop
    n := n + booking._texts_reg('kb.locations', 'id', 'location', c, c || '_en', $$'en'$$, $$'protected'$$, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 3000);  -- kb_texts_en_sources
  end loop;
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'question', 'question_en', $$'en'$$, pc, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 500);
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'answer', 'answer_en', $$'en'$$, pc, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 6000);
  n := n + booking._texts_reg('booking.schedule_rules', 'id', 'schedule', 'label', 'label_en', $$'en'$$, $$'protected'$$, 's.active', 200);  -- kb_texts_en_sources (nimissä kellonajat/kestot)
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'session_name', 'session_name_en', $$'en'$$, $$'protected'$$, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 200);  -- kb_texts_en_sources
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'swimsuit_rule', 'swimsuit_rule_en', $$'en'$$, $$'protected'$$, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 500);  -- kb_texts_en_sources
  n := n + booking._texts_reg('kb.event_dates', 'id', 'event', 'time_text', 'time_text_en', $$'en'$$, $$'protected'$$, 's.active', 200);  -- kb_texts_en_sources
  n := n + booking._texts_reg('kb.businesses', 'id', 'business', 'description', 'description_en', $$'en'$$, $$'protected'$$, $$s.active and coalesce(nullif(s.language, ''), 'fi') = 'fi'$$, 4000);  -- kb_texts_en_sources
  raise notice 'kb_texts_en_sources: % en-riviä', n;
end $do$;
