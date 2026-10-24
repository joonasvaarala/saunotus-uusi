-- t165: tietosuojaselosteen EN-avaimet + needs_translation (booking_165, väliaikainen versio 20261024192515).
-- A lähtötila = tuotanto (rollback palauttaa _texts_register_sources-funktion tuotannon md5:een): policy.7.title/body [en] puuttuvat, texts_propose -> not_found,
-- B migraatio: funktion md5, tyhjät protected-rivit vain id 7:lle (muut privacy-rivit edelleen pois), ei julkista tekstiä, kb.policies ennallaan,
--   needs_translation pois vain vartijat täyttäviltä fi-riveiltä (en vanhempi tai teksti muuttunut -> ei), muut site_texts-rivit ennallaan,
-- C uudelleenajo (vartijat korjattu -> loputkin pois, rivejä ei lisää), D rollback x2 (md5 tuotantoon, rivit pois, liput takaisin) + migraatio uudelleen,
-- E ketju texts_propose(draft) -> texts_submit -> admin_texts_approve kirjoittaa kb.policies 7 title_en/body_en; rollback kieltäytyy avoimen ehdotuksen
--   ja julkaistun EN-tekstin jälkeen (ERROR-rivit "booking_165 rollback: ..." tulosteessa ovat odotettuja).
-- Ajo (psql, paikallinen PG17 tai testikanta, migraatiot ja fixtures/10_test_helpers.sql ajettu):
--   cd booking/supabase/tests && psql -X -v ON_ERROR_STOP=0 -f t165_policy_en_keys.sql
-- Fixtuurien neljä tekstiä = tuotannon julkaistut v2-tekstit (md5 = migraation vartijat). Kaikki yhdessä transaktiossa; lopussa tahallinen
-- poikkeus "TESTRESULT pass=… fail=…" ja rollback kumoavat kaiken. Ei tuotantoon.
begin;
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table t165_r(ok boolean, label text);
grant all on t165_r to public;
create temp sequence t165_after_rb;
grant all on t165_after_rb to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t165_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.fmd5() returns text language sql as $$ select md5(pg_get_functiondef('booking._texts_register_sources()'::regprocedure)) $$;
create function pg_temp.nt(p_key text, p_lang text) returns boolean language sql as $$ select needs_translation from booking.site_texts where key = p_key and lang = p_lang $$;
-- muiden tekstirivien sormenjälki (pois lukien policy.7 [en] ja neljän avaimen fi-liput)
create function pg_temp.fp_texts() returns text language sql as $$
  select md5(string_agg(concat_ws('|', key, lang, class, kind, max_len, published_text, published_version, latest_version, status,
                                  case when lang = 'fi' and key in ('ui.site.privacy_analytics_text', 'page.booking_info.note', 'page.terms.note', 'seo.booking_info.description') then null else needs_translation end),
                        ',' order by key, lang))
    from booking.site_texts where not (key in ('policy.7.title', 'policy.7.body') and lang = 'en') $$;
create function pg_temp.fp_kb() returns text language sql as $$ select md5(string_agg(p::text, ',' order by p.id)) from kb.policies p $$;

-- ---------- fixtuurit ----------
insert into kb.policies(id, title, body, language, status, internal, category) overriding system value values
  (7, 'Tietosuojaseloste (asiakasrekisteri)', 'Rekisterinpitäjä: Havuhattu Oy' || chr(10) || 'Kävijämittaus ilman evästeitä.', 'fi', 'active', false, 'privacy'),
  (916501, 'T165 Maksuehdot', 'Maksu varauksen yhteydessä.', 'fi', 'active', false, 'payment'),
  (916502, 'T165 Tietosuoja: kameravalvonta', 'Kameravalvonta.', 'fi', 'active', false, 'privacy')
on conflict (id) do update set title = excluded.title, body = excluded.body, language = excluded.language, status = excluded.status,
  internal = excluded.internal, category = excluded.category, title_en = null, body_en = null;
create temp table t165_ts as select now() - interval '1 hour' ts;
insert into booking.site_texts(key, lang, class, kind, max_len, published_text, published_version, latest_version, status, needs_translation, published_at)
select x.key, x.lang, x.class, x.kind, x.max_len, x.txt, 2, 2, 'published', x.lang = 'fi', (select ts from t165_ts) from (values
  ('page.booking_info.note', 'en', 'normal', 'plain', 200, $tx$Bookings and payment are made in our online shop.$tx$),
  ('page.booking_info.note', 'fi', 'normal', 'plain', 200, $tx$Varaukset ja maksu tehdään verkkokaupassamme.$tx$),
  ('page.terms.note', 'en', 'protected', 'plain', 250, $tx$Bookings and payments are made in our online shop, whose terms apply at the time of purchase.$tx$),
  ('page.terms.note', 'fi', 'protected', 'plain', 250, $tx$Varaukset ja maksut tehdään verkkokaupassamme, jonka ehdot ovat voimassa ostohetkellä.$tx$),
  ('seo.booking_info.description', 'en', 'normal', 'plain', 400, $tx$Book a public sauna session, open ritual, sauna treatment, saunotus or private session at Sipoonjoen Perinnesauna. Bookings are made in our online shop.$tx$),
  ('seo.booking_info.description', 'fi', 'normal', 'plain', 400, $tx$Varaa yleinen saunavuoro, avoin rituaali, saunahoito, saunotus tai yksityisvuoro Sipoonjoen Perinnesaunalle. Varaukset tehdään verkkokaupassamme.$tx$),
  ('ui.site.privacy_analytics_text', 'en', 'protected', 'plain', 3000, $tx$When the website's visitor analytics is enabled, it works without cookies: nothing is stored in your browser. Controller and contact details as above.
Data: pages opened (address without URL parameters), product and checkout page views and the related product, the referring website's domain, campaign tags (utm), device type and language, and a random session identifier that is valid for a single page load only. When an order has been paid, the visit is linked to the order (the order, its product and total), so the data is pseudonymous rather than anonymous.
Purpose and legal basis: developing the service and measuring marketing; the legal basis is the controller's legitimate interest.
IP address: IP addresses are not stored. The IP address is used momentarily to limit abuse (number of requests); for this, a daily hash, not the address itself, is kept for at most two days.
Retention: individual analytics events are kept for 13 months. After that they are automatically combined into monthly summaries containing only counts and totals, and deleted. The summaries are kept indefinitely. The data is stored in the booking system within the EU (processor Supabase) and is not disclosed to third parties.
Your rights: you may object to the analytics; the Do Not Track or Global Privacy Control setting of your browser blocks it completely. You may lodge a complaint with the Data Protection Ombudsman. More details in section 7 of the privacy policy.$tx$),
  ('ui.site.privacy_analytics_text', 'fi', 'protected', 'plain', 3000, $tx$Kun sivuston kävijämittaus on käytössä, se toimii ilman evästeitä: selaimeen ei tallenneta mitään. Rekisterinpitäjä ja yhteystiedot kuten yllä.
Tiedot: avatut sivut (osoite ilman URL-parametreja), tuote- ja kassasivujen avaukset ja niihin liittyvä tuote, viittaavan sivuston verkkotunnus, kampanjatunnisteet (utm), laitetyyppi ja kieli sekä satunnainen istuntotunniste, joka on voimassa vain yhden sivunlatauksen ajan. Kun tilaus on maksettu, käynti linkitetään tilaukseen (tilaus, sen tuote ja summa), joten tiedot ovat pseudonyymejä eivätkä anonyymejä.
Tarkoitus ja oikeusperuste: palvelun kehittäminen ja markkinoinnin seuranta; oikeusperuste on rekisterinpitäjän oikeutettu etu.
IP-osoite: IP-osoitetta ei tallenneta. Sitä käytetään hetkellisesti väärinkäytön rajoittamiseen (pyyntöjen määrä); tätä varten säilytetään enintään kaksi vuorokautta päiväkohtainen tiiviste, ei itse osoitetta.
Säilytys: yksittäiset mittaustapahtumat säilytetään 13 kuukautta. Sen jälkeen ne yhdistetään automaattisesti kuukausittaisiksi yhteenvedoiksi, joissa on vain lukumääriä ja summia, ja poistetaan. Yhteenvedot säilytetään toistaiseksi. Tiedot tallennetaan varausjärjestelmään EU-alueella (käsittelijä Supabase), eikä niitä luovuteta eteenpäin.
Oikeudet: voit vastustaa mittausta; selaimen Do Not Track- tai Global Privacy Control -asetus estää sen kokonaan. Voit tehdä valituksen tietosuojavaltuutetulle. Lisätietoja tietosuojaselosteen kohdassa 7.$tx$)
) x(key, lang, class, kind, max_len, txt)
on conflict (key, lang) do update set class = excluded.class, kind = excluded.kind, max_len = excluded.max_len, published_text = excluded.published_text,
  published_version = 2, latest_version = 2, status = 'published', needs_translation = excluded.needs_translation, published_at = excluded.published_at;
-- vartijatapaukset: page.terms.note [en] julkaistu ennen fi:tä; seo.booking_info.description [fi] eri versio kuin tarkistettu
update booking.site_texts set published_at = (select ts from t165_ts) - interval '1 minute' where key = 'page.terms.note' and lang = 'en';
update booking.site_texts set published_version = 3, latest_version = 3 where key = 'seo.booking_info.description' and lang = 'fi';

-- ---------- A: tuotannon lähtötila ----------
\ir ../rollbacks/20261024192515_booking_165_ROLLBACK.sql
select booking._texts_register_sources();
do $a$
begin
  perform pg_temp.ck(pg_temp.fmd5() = '6e5d43c7dbbc13c75830cd492d94eddd', 'A1: rollback palautti _texts_register_sources tuotannon md5:een: ' || pg_temp.fmd5());
  perform pg_temp.ck((select count(*) from booking.site_texts where key in ('policy.7.title', 'policy.7.body') and lang = 'fi') = 2, 'A2: policy.7.title/body [fi] olemassa');
  perform pg_temp.ck((select count(*) from booking.site_texts where key in ('policy.7.title', 'policy.7.body') and lang = 'en') = 0, 'A3: policy.7.title/body [en] puuttuvat (tuotannon tila)');
  perform pg_temp.ck(test.code($q$select booking.texts_propose('policy.7.title', 'en', 'Privacy policy', 't165')$q$) = 'not_found', 'A4: texts_propose policy.7.title [en] -> not_found');
  perform pg_temp.ck((select count(*) from booking.site_texts where key in ('policy.916501.title', 'policy.916501.body') and lang = 'en') = 2, 'A5: tavallisen ehdon en-rivit olemassa');
  perform pg_temp.ck((select count(*) from booking.site_texts where key like 'policy.916502.%' and lang = 'en') = 0, 'A6: muu privacy-rivi ilman en-rivejä');
end $a$;
create temp table t165_before as select pg_temp.fp_texts() fp, pg_temp.fp_kb() kb;

-- ---------- B: migraatio ----------
\ir ../migrations/20261024192515_booking_165_policy_en_keys.sql
do $b$
declare t booking.site_texts; e jsonb;
begin
  perform pg_temp.ck(pg_temp.fmd5() = 'ff8a4cb6fd632d1d967f03c16b0101b1', 'B1: _texts_register_sources md5 migraation jälkeen: ' || pg_temp.fmd5());
  select * into t from booking.site_texts where key = 'policy.7.title' and lang = 'en';
  perform pg_temp.ck(found and t.class = 'protected' and t.kind = 'plain' and t.max_len = 300 and t.source_table = 'kb.policies' and t.source_pk_col = 'id' and t.source_pk = '7'
                     and t.source_column = 'title_en' and t.published_text = '' and t.published_version = 0 and t.latest_version = 0 and t.status = 'empty' and not t.needs_translation,
                     'B2: policy.7.title [en] tyhjä protected-rivi -> kb.policies.title_en');
  select * into t from booking.site_texts where key = 'policy.7.body' and lang = 'en';
  perform pg_temp.ck(found and t.class = 'protected' and t.max_len = 20000 and t.source_column = 'body_en' and t.source_pk = '7' and t.published_text = '' and t.published_version = 0 and t.status = 'empty',
                     'B3: policy.7.body [en] tyhjä protected-rivi -> kb.policies.body_en');
  perform pg_temp.ck(not exists (select 1 from booking.site_text_versions v join booking.site_texts s on s.id = v.text_id where s.key like 'policy.7.%' and s.lang = 'en'), 'B4: ei versioita (ei julkaistu mitään)');
  e := booking.public_get_site_texts('en');
  perform pg_temp.ck(not exists (select 1 from jsonb_array_elements(e -> 'texts') x where x ->> 'key' like 'policy.7.%'), 'B5: public_get_site_texts(en) ei palauta policy.7-avaimia');
  perform pg_temp.ck(pg_temp.fp_kb() = (select kb from t165_before), 'B6: kb.policies ennallaan');
  perform pg_temp.ck(pg_temp.fp_texts() = (select fp from t165_before), 'B7: muut site_texts-rivit ja en-liput ennallaan');
  perform pg_temp.ck(pg_temp.nt('ui.site.privacy_analytics_text', 'fi') = false and pg_temp.nt('page.booking_info.note', 'fi') = false, 'B8: needs_translation pois (en julkaistu samaan aikaan, tekstit tarkistetut)');
  perform pg_temp.ck(pg_temp.nt('page.terms.note', 'fi') = true, 'B9: en julkaistu ennen fi:tä -> lippu jää');
  perform pg_temp.ck(pg_temp.nt('seo.booking_info.description', 'fi') = true, 'B10: fi-versio muuttunut tarkistuksesta -> lippu jää');
  perform booking._texts_register_sources();
  perform pg_temp.ck((select count(*) from booking.site_texts where key like 'policy.916502.%' and lang = 'en') = 0, 'B11: muut privacy-rivit edelleen pois myös _texts_register_sources-ajossa');
  perform pg_temp.ck((select count(*) from booking.site_texts where key in ('policy.7.title', 'policy.7.body') and lang = 'en') = 2, 'B12: _texts_register_sources pitää id 7:n rivit');
end $b$;

-- ---------- C: vartijat kunnossa + uudelleenajo ----------
update booking.site_texts set published_at = (select ts from t165_ts) where key = 'page.terms.note' and lang = 'en';
update booking.site_texts set published_version = 2, latest_version = 2 where key = 'seo.booking_info.description' and lang = 'fi';
create temp table t165_c as select count(*) n, pg_temp.fp_texts() fp from booking.site_texts;
\ir ../migrations/20261024192515_booking_165_policy_en_keys.sql
do $c$
begin
  perform pg_temp.ck(pg_temp.nt('page.terms.note', 'fi') = false and pg_temp.nt('seo.booking_info.description', 'fi') = false, 'C1: uudelleenajo poisti loputkin liput (en = fi-aika)');
  perform pg_temp.ck((select count(*) from booking.site_texts) = (select n from t165_c) and pg_temp.fmd5() = 'ff8a4cb6fd632d1d967f03c16b0101b1', 'C2: uudelleenajo ei lisännyt rivejä, md5 sama');
  perform pg_temp.ck(not pg_temp.nt('ui.site.privacy_analytics_text', 'en') and not pg_temp.nt('page.terms.note', 'en'), 'C3: en-liput ennallaan (false)');
end $c$;

-- ---------- D: rollback x2 + migraatio uudelleen ----------
\ir ../rollbacks/20261024192515_booking_165_ROLLBACK.sql
\ir ../rollbacks/20261024192515_booking_165_ROLLBACK.sql
do $d$
begin
  perform pg_temp.ck(pg_temp.fmd5() = '6e5d43c7dbbc13c75830cd492d94eddd', 'D1: rollback palauttaa tuotannon md5:n 6e5d43c7dbbc13c75830cd492d94eddd');
  perform pg_temp.ck((select count(*) from booking.site_texts where key in ('policy.7.title', 'policy.7.body') and lang = 'en') = 0, 'D2: policy.7 [en] -rivit pois');
  perform pg_temp.ck(pg_temp.nt('ui.site.privacy_analytics_text', 'fi') and pg_temp.nt('page.booking_info.note', 'fi') and pg_temp.nt('page.terms.note', 'fi') and pg_temp.nt('seo.booking_info.description', 'fi'), 'D3: fi-liput palautettu (true)');
  perform pg_temp.ck(pg_temp.fp_texts() = (select fp from t165_c) and pg_temp.fp_kb() = (select kb from t165_before), 'D4: muut tekstit ja kb.policies ennallaan');
  perform pg_temp.ck((select count(*) from booking.site_texts where key in ('policy.7.title', 'policy.7.body') and lang = 'fi') = 2, 'D5: fi-rivit ennallaan');
end $d$;
\ir ../migrations/20261024192515_booking_165_policy_en_keys.sql

-- ---------- E: propose -> submit -> approve ----------
create temp table t165_e(version_id bigint, body_vid bigint);
grant all on t165_e to public;
do $e1$
declare u_ed uuid := test.mk_user('t165-bot@example.test'); v jsonb; w jsonb;
begin
  -- tekstibotti (kuten Kääntäjä): booking.text_bots -> text_editor-roolin oikeudet
  insert into booking.text_bots(user_id, role_code, label) values (u_ed, 'text_editor', 'T165 botti') on conflict (user_id) do nothing;
  perform test.login(u_ed);
  v := booking.texts_propose('policy.7.title', 'en', 'Privacy policy (customer register)', 't165 EN', true);
  perform pg_temp.ck(v ->> 'status' = 'draft' and (v ->> 'protected')::boolean, 'E1: texts_propose (botti, luonnos) toimii, protected');
  perform pg_temp.ck(booking.texts_submit((v ->> 'version_id')::bigint) ->> 'status' = 'proposed', 'E2: texts_submit -> proposed');
  w := booking.texts_propose('policy.7.body', 'en', 'Controller: Havuhattu Oy' || chr(10) || 'Cookieless visitor analytics.', 't165 EN');
  perform test.logout();
  insert into t165_e values ((v ->> 'version_id')::bigint, (w ->> 'version_id')::bigint);
end $e1$;
savepoint t165_rb1;
\ir ../rollbacks/20261024192515_booking_165_ROLLBACK.sql
select nextval('t165_after_rb');
rollback to savepoint t165_rb1;
do $e2$
declare u_mgr uuid := test.mk_staff('t165-mgr@example.test', 'manager'); r jsonb; p kb.policies;
begin
  perform pg_temp.ck((select last_value from t165_after_rb) = 1 and not (select is_called from t165_after_rb), 'E3: rollback kieltäytyy avoimen ehdotuksen kanssa');
  perform pg_temp.ck(pg_temp.fmd5() = 'ff8a4cb6fd632d1d967f03c16b0101b1' and (select count(*) from booking.site_texts where key like 'policy.7.%' and lang = 'en') = 2, 'E4: kieltäytynyt rollback ei muuttanut mitään');
  perform test.login(u_mgr);
  r := booking.admin_texts_approve((select version_id from t165_e), 't165', true);
  r := booking.admin_texts_approve((select body_vid from t165_e), 't165', true);
  perform test.logout();
  select * into p from kb.policies where id = 7;
  perform pg_temp.ck(p.title_en = 'Privacy policy (customer register)' and p.body_en = 'Controller: Havuhattu Oy' || chr(10) || 'Cookieless visitor analytics.', 'E5: hyväksyntä kirjoitti kb.policies 7 title_en/body_en');
  perform pg_temp.ck(p.title = 'Tietosuojaseloste (asiakasrekisteri)' and p.body like 'Rekisterinpitäjä: Havuhattu Oy%', 'E6: fi title/body ennallaan');
  perform pg_temp.ck((select published_version from booking.site_texts where key = 'policy.7.title' and lang = 'en') = 1
                     and exists (select 1 from jsonb_array_elements(booking.public_get_site_texts('en') -> 'texts') x where x ->> 'key' = 'policy.7.body'), 'E7: julkaistu v1, public_get_site_texts(en) palauttaa');
  perform pg_temp.ck(pg_temp.nt('policy.7.title', 'fi') and pg_temp.nt('policy.7.body', 'fi'), 'E8: EN-julkaisu nostaa fi-rivin needs_translation (järjestelmän tavallinen käytös)');
  perform pg_temp.ck(not pg_temp.nt('ui.site.privacy_analytics_text', 'fi'), 'E9: neljän avaimen liput eivät muutu');
end $e2$;
select setval('t165_after_rb', 1, false);
savepoint t165_rb2;
\ir ../rollbacks/20261024192515_booking_165_ROLLBACK.sql
select nextval('t165_after_rb');
rollback to savepoint t165_rb2;
do $f$
declare v_fail int; v_pass int; v_list text;
begin
  perform pg_temp.ck(not (select is_called from t165_after_rb) and pg_temp.fmd5() = 'ff8a4cb6fd632d1d967f03c16b0101b1'
                     and (select title_en from kb.policies where id = 7) = 'Privacy policy (customer register)', 'F1: rollback kieltäytyy julkaistun EN-tekstin jälkeen, mitään ei muutettu');
  select count(*) filter (where not ok), count(*) filter (where ok), string_agg(label, ' | ') filter (where not ok) into v_fail, v_pass, v_list from t165_r;
  raise exception 'TESTRESULT pass=% fail=% :: %', v_pass, v_fail, coalesce(v_list, 'ALL OK');
end $f$;
rollback;
