-- t159: booking_159 (paketin otsikko "Saunarituaali-ilta" → "Saunarituaali ja savusaunavuoro" / "Sauna ritual and smoke sauna session") + rollback.
-- psql-skripti (käyttää \ir), ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n JÄLKEEN:  psql -X -v ON_ERROR_STOP=1 -f tests/texts/t159_rituaali_lista.sql
-- Kaikki yhdessä transaktiossa, joka lopuksi perutaan (rollback): testi ei jätä mitään kantaan. Virhe → psql pysähtyy (ON_ERROR_STOP).
-- Siemen kuten tuotannossa 24.10.2026 (SELECT): page.front.ritual.title + ui.session.ritual (normal, tuontitiedostosta) ja kb.opening_hours 9/10 → hours.9/10.session_name (protected).
-- Tarkistaa: a) 8 riviä uusiksi, versio + audit, lähdetaulu (session_name / session_name_en) päivittyy, needs_translation false, muut tekstit ennallaan
-- b) toinen ajo ei muuta mitään  c) odottamaton teksti → poikkeus, ei osittaista muutosta  d) rollback palauttaa tekstit, lähderivit ja liput; toinen rollback-ajo ei muuta mitään.
begin;
set local lock_timeout = '3s';

insert into kb.opening_hours (id, session_name, session_name_en, swimsuit_rule, language, active) overriding system value values
  (9, 'Saunarituaali-ilta', 'Sauna ritual evening', null, 'fi', true), (10, 'Saunarituaali-ilta', 'Sauna ritual evening', null, 'fi', true),
  (11, 'Perinnesaunotusilta', 'Traditional saunotus evening', null, 'fi', true);
select booking._texts_register_sources();
select booking.admin_texts_import('[
  {"key":"page.front.ritual.title","lang":"fi","text":"Saunarituaali-ilta"},{"key":"page.front.ritual.title","lang":"en","text":"Sauna ritual evening"},
  {"key":"ui.session.ritual","lang":"fi","text":"Saunarituaali-ilta"},{"key":"ui.session.ritual","lang":"en","text":"Sauna ritual evening"},
  {"key":"ui.session.traditional","lang":"fi","text":"Perinnesaunotusilta"},{"key":"ui.session.traditional","lang":"en","text":"Traditional saunotus evening"}]'::jsonb);
-- tuotannon lähtötila: hours.9/10 fi needs_translation = true, muut false
update booking.site_texts set needs_translation = (key in ('hours.9.session_name', 'hours.10.session_name') and lang = 'fi')
 where key in ('page.front.ritual.title', 'ui.session.ritual', 'hours.9.session_name', 'hours.10.session_name');

create temp table t159_keys(key text, lang text, old_text text, new_text text) on commit drop;
insert into t159_keys values
  ('page.front.ritual.title', 'fi', 'Saunarituaali-ilta', 'Saunarituaali ja savusaunavuoro'), ('page.front.ritual.title', 'en', 'Sauna ritual evening', 'Sauna ritual and smoke sauna session'),
  ('ui.session.ritual', 'fi', 'Saunarituaali-ilta', 'Saunarituaali ja savusaunavuoro'), ('ui.session.ritual', 'en', 'Sauna ritual evening', 'Sauna ritual and smoke sauna session'),
  ('hours.9.session_name', 'fi', 'Saunarituaali-ilta', 'Saunarituaali ja savusaunavuoro'), ('hours.9.session_name', 'en', 'Sauna ritual evening', 'Sauna ritual and smoke sauna session'),
  ('hours.10.session_name', 'fi', 'Saunarituaali-ilta', 'Saunarituaali ja savusaunavuoro'), ('hours.10.session_name', 'en', 'Sauna ritual evening', 'Sauna ritual and smoke sauna session');
create temp table t159_before on commit drop as
  select key, lang, published_text, published_version, needs_translation, class from booking.site_texts;
do $$ begin
  if (select count(*) from booking.site_texts s join t159_keys k using (key, lang) where s.published_text = k.old_text and s.published_version > 0) <> 8 then
    raise exception 't159 A0: siemen puuttuu'; end if;
  if (select string_agg(class, ',' order by key, lang) from booking.site_texts where key in ('hours.9.session_name', 'hours.10.session_name')) <> 'protected,protected,protected,protected' then
    raise exception 't159 A0: hours.* ei protected'; end if;
end $$;

\ir ../../migrations/20261024310000_booking_159_rituaali_lista.sql

do $$ declare n int; begin
  select count(*) into n from booking.site_texts s join t159_keys k using (key, lang) join t159_before b using (key, lang)
   where s.published_text = k.new_text and s.published_version = b.published_version + 1 and not s.needs_translation and s.class = b.class;
  if n <> 8 then raise exception 't159 A1: uusia tekstejä % / 8', n; end if;
  if exists (select 1 from booking.site_texts s join t159_before b using (key, lang) where (key, lang) not in (select key, lang from t159_keys)
             and (s.published_text, s.published_version, s.needs_translation) is distinct from (b.published_text, b.published_version, b.needs_translation)) then
    raise exception 't159 A2: muita tekstejä muuttui'; end if;
  if (select string_agg(id || ':' || session_name || '/' || session_name_en, ' | ' order by id) from kb.opening_hours)
     <> '9:Saunarituaali ja savusaunavuoro/Sauna ritual and smoke sauna session | 10:Saunarituaali ja savusaunavuoro/Sauna ritual and smoke sauna session | 11:Perinnesaunotusilta/Traditional saunotus evening' then
    raise exception 't159 A3: kb.opening_hours ei päivittynyt oikein'; end if;
  select count(*) into n from booking.site_text_versions v join booking.site_texts s on s.id = v.text_id join t159_keys k using (key, lang)
   where v.status = 'published' and v.text = k.new_text and v.approved_by_kind = 'system' and v.reason like 'booking_159:%';
  if n <> 8 then raise exception 't159 A4: julkaistuja versioita % / 8', n; end if;
  if (select count(*) from booking.site_text_versions v join booking.site_texts s on s.id = v.text_id join t159_keys k using (key, lang) where v.protected) <> 4 then
    raise exception 't159 A5: protected-versioita pitäisi olla 4 (hours.*)'; end if;
end $$;

-- b) toinen ajo: ei muutoksia
create temp table t159_after on commit drop as select key, lang, published_text, published_version, needs_translation from booking.site_texts;
\ir ../../migrations/20261024310000_booking_159_rituaali_lista.sql
do $$ begin
  if exists (select 1 from booking.site_texts s full join t159_after a using (key, lang)
             where (s.published_text, s.published_version, s.needs_translation) is distinct from (a.published_text, a.published_version, a.needs_translation)) then
    raise exception 't159 B1: toinen ajo muutti jotain'; end if;
end $$;

-- d) rollback + toinen rollback-ajo
\ir ../../rollbacks/20261024310000_booking_159_ROLLBACK.sql
\ir ../../rollbacks/20261024310000_booking_159_ROLLBACK.sql
do $$ declare n int; begin
  select count(*) into n from booking.site_texts s join t159_keys k using (key, lang) join t159_before b using (key, lang)
   where s.published_text = k.old_text and s.published_version = b.published_version + 2 and s.needs_translation = b.needs_translation;
  if n <> 8 then raise exception 't159 D1: palautettuja % / 8', n; end if;
  if (select string_agg(id || ':' || session_name || '/' || session_name_en, ' | ' order by id) from kb.opening_hours)
     <> '9:Saunarituaali-ilta/Sauna ritual evening | 10:Saunarituaali-ilta/Sauna ritual evening | 11:Perinnesaunotusilta/Traditional saunotus evening' then
    raise exception 't159 D2: kb.opening_hours ei palautunut'; end if;
  if exists (select 1 from booking.site_texts s join t159_before b using (key, lang) where (key, lang) not in (select key, lang from t159_keys)
             and (s.published_text, s.published_version, s.needs_translation) is distinct from (b.published_text, b.published_version, b.needs_translation)) then
    raise exception 't159 D3: muita tekstejä muuttui'; end if;
end $$;

-- c) odottamaton teksti → poikkeus, ei osittaista muutosta (savepoint)
update booking.site_texts set published_text = 'Joku muu' where key = 'hours.10.session_name' and lang = 'en';
create temp table t159_pre_c on commit drop as select key, lang, published_text, published_version from booking.site_texts;
savepoint c;
\set ON_ERROR_STOP 0
\ir ../../migrations/20261024310000_booking_159_rituaali_lista.sql
\set ON_ERROR_STOP 1
rollback to savepoint c;
do $$ begin
  if exists (select 1 from booking.site_texts s full join t159_pre_c a using (key, lang) where (s.published_text, s.published_version) is distinct from (a.published_text, a.published_version)) then
    raise exception 't159 C1: osittainen muutos'; end if;
  raise notice 't159: KAIKKI OK';
end $$;
rollback;
