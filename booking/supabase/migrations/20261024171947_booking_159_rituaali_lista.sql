-- booking_159: paketin "Saunarituaali ja savusaunavuoro (la & su)" (kb 7) mainosotsikko "Saunarituaali-ilta" → "Saunarituaali ja savusaunavuoro" (FI) ja
-- "Sauna ritual evening" → "Sauna ritual and smoke sauna session" (EN; sama muoto kuin paketin muissa EN-teksteissä, esim. page.booking_info.rec.1.title ja faq.18).
-- Joonas 24.10.2026. Vain sivutekstejä (booking.site_texts) tekstijärjestelmän omalla polulla: booking.texts_propose → booking.admin_texts_approve(…, true),
-- eli versiohistoria, audit-loki ja hours.*-riveillä lähdetaulun (kb.opening_hours.session_name / session_name_en, rivit 9 ja 10) päivitys kuten hallinnan Tekstit-näkymästä.
-- Versio 20261024171947 = tuotannon migraatioversio (ajettu tuotantoon 24.10.2026 Bottiavustus: 8 tekstiä + kb.opening_hours 9/10).
-- Muutettavat avaimet (fi + en):
--   page.front.ritual.title   etusivun "Saunarituaali-ilta"-nosto (normal)
--   ui.session.ritual          etusivun viikko-ohjelman rivin nimi (normal)
--   hours.9.session_name       kb.opening_hours 9 (la), protected
--   hours.10.session_name      kb.opening_hours 10 (su), protected
-- Ajojärjestys: ajetaan sellaisenaan (yksi transaktio). Uudelleenajettava: rivi, jonka teksti on jo uusi, ohitetaan; puuttuva avain ohitetaan (NOTICE).
-- Jos julkaistu teksti on jokin muu kuin vanha tai uusi (joku on muokannut sitä), ajo keskeytyy eikä mitään muuteta.
-- needs_translation: fi ja en päivitetään yhdessä toistensa käännöksiksi, joten muutetuilta riveiltä lippu nollataan lopuksi
-- (_text_publish nostaisi muuten vastakielen lipun).
-- Ei hintoja, ALV:tä, slugeja, URL:eja, tuotteita eikä public-skeemaa. Ei skeemamuutoksia.
-- Saunotusrituaalin (kb 8) poisto hoito- ja rituaalilistoilta tehdään koodissa (src/render.mjs, booking/shop/src/treatments.js), ei tässä.
-- Rollback: rollbacks/20261024171947_booking_159_ROLLBACK.sql
set local lock_timeout = '5s';

do $m$
declare
  r record; t booking.site_texts; v jsonb; n int := 0; v_changed text[] := '{}';
begin
  for r in select * from (values
      (1, 'page.front.ritual.title', 'fi', 'Saunarituaali-ilta',   'Saunarituaali ja savusaunavuoro'),
      (2, 'page.front.ritual.title', 'en', 'Sauna ritual evening', 'Sauna ritual and smoke sauna session'),
      (3, 'ui.session.ritual',       'fi', 'Saunarituaali-ilta',   'Saunarituaali ja savusaunavuoro'),
      (4, 'ui.session.ritual',       'en', 'Sauna ritual evening', 'Sauna ritual and smoke sauna session'),
      (5, 'hours.9.session_name',    'fi', 'Saunarituaali-ilta',   'Saunarituaali ja savusaunavuoro'),
      (6, 'hours.9.session_name',    'en', 'Sauna ritual evening', 'Sauna ritual and smoke sauna session'),
      (7, 'hours.10.session_name',   'fi', 'Saunarituaali-ilta',   'Saunarituaali ja savusaunavuoro'),
      (8, 'hours.10.session_name',   'en', 'Sauna ritual evening', 'Sauna ritual and smoke sauna session')
    ) x(ord, key, lang, old_text, new_text) order by ord
  loop
    select * into t from booking.site_texts s where s.key = r.key and s.lang = r.lang for update;
    if not found then raise notice 'booking_159: avainta % [%] ei ole, ohitetaan', r.key, r.lang; continue; end if;
    if t.published_text = r.new_text then raise notice 'booking_159: % [%] on jo uusi, ohitetaan', r.key, r.lang; continue; end if;
    if t.published_text is distinct from r.old_text then
      raise exception 'booking_159: % [%] odottamaton julkaistu teksti %, odotettiin %; mitään ei muutettu', r.key, r.lang, quote_nullable(t.published_text), quote_literal(r.old_text);
    end if;
    v := booking.texts_propose(r.key, r.lang, r.new_text, 'booking_159: paketin otsikko Saunarituaali ja savusaunavuoro (Joonas 24.10.2026)');
    perform booking.admin_texts_approve((v ->> 'version_id')::bigint, 'booking_159 (Joonas 24.10.2026)', true);
    n := n + 1; v_changed := v_changed || r.key;
  end loop;
  update booking.site_texts set needs_translation = false
   where key = any (v_changed) and lang in ('fi', 'en') and published_text in ('Saunarituaali ja savusaunavuoro', 'Sauna ritual and smoke sauna session');
  raise notice 'booking_159: julkaistu % tekstiä', n;
end $m$;
