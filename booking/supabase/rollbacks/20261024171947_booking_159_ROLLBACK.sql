-- ROLLBACK booking_159 (migraatio 20261024171947_booking_159_rituaali_lista.sql). Palauttaa paketin otsikon "Saunarituaali-ilta" / "Sauna ritual evening"
-- samalla tekstijärjestelmän polulla (texts_propose → admin_texts_approve), joten versiohistoria ja audit säilyvät ja hours.*-riveillä myös
-- kb.opening_hours 9/10 session_name / session_name_en palautuvat. Uudelleenajettava: rivi, jonka teksti on jo vanha, ohitetaan.
-- Jos julkaistu teksti on jokin muu kuin booking_159:n uusi tai vanha, ajo keskeytyy eikä mitään muuteta.
-- needs_translation palautetaan tuotannon arvoihin ennen booking_159:ää (hours.9/10 fi = true, muut false; tarkistettu 24.10.2026).
-- Ei hintoja, ALV:tä, slugeja, URL:eja eikä public-skeemaa. Koodimuutokset (Saunotusrituaalin listapiilotus) perutaan revertoimalla PR.
set local lock_timeout = '5s';

do $m$
declare
  r record; t booking.site_texts; v jsonb; n int := 0;
begin
  for r in select * from (values
      (1, 'page.front.ritual.title', 'fi', 'Saunarituaali ja savusaunavuoro',      'Saunarituaali-ilta',   false),
      (2, 'page.front.ritual.title', 'en', 'Sauna ritual and smoke sauna session', 'Sauna ritual evening', false),
      (3, 'ui.session.ritual',       'fi', 'Saunarituaali ja savusaunavuoro',      'Saunarituaali-ilta',   false),
      (4, 'ui.session.ritual',       'en', 'Sauna ritual and smoke sauna session', 'Sauna ritual evening', false),
      (5, 'hours.9.session_name',    'fi', 'Saunarituaali ja savusaunavuoro',      'Saunarituaali-ilta',   true),
      (6, 'hours.9.session_name',    'en', 'Sauna ritual and smoke sauna session', 'Sauna ritual evening', false),
      (7, 'hours.10.session_name',   'fi', 'Saunarituaali ja savusaunavuoro',      'Saunarituaali-ilta',   true),
      (8, 'hours.10.session_name',   'en', 'Sauna ritual and smoke sauna session', 'Sauna ritual evening', false)
    ) x(ord, key, lang, cur_text, old_text, old_nt) order by ord
  loop
    select * into t from booking.site_texts s where s.key = r.key and s.lang = r.lang for update;
    if not found then raise notice 'booking_159 rollback: avainta % [%] ei ole, ohitetaan', r.key, r.lang; continue; end if;
    if t.published_text = r.old_text then raise notice 'booking_159 rollback: % [%] on jo vanha, ohitetaan', r.key, r.lang; continue; end if;
    if t.published_text is distinct from r.cur_text then
      raise exception 'booking_159 rollback: % [%] odottamaton julkaistu teksti %; mitään ei muutettu', r.key, r.lang, quote_nullable(t.published_text);
    end if;
    v := booking.texts_propose(r.key, r.lang, r.old_text, 'booking_159 ROLLBACK: paketin otsikko takaisin');
    perform booking.admin_texts_approve((v ->> 'version_id')::bigint, 'booking_159 ROLLBACK', true);
    n := n + 1;
  end loop;
  for r in select * from (values
      ('page.front.ritual.title', 'fi', false), ('page.front.ritual.title', 'en', false), ('ui.session.ritual', 'fi', false), ('ui.session.ritual', 'en', false),
      ('hours.9.session_name', 'fi', true), ('hours.9.session_name', 'en', false), ('hours.10.session_name', 'fi', true), ('hours.10.session_name', 'en', false)
    ) x(key, lang, nt)
  loop
    update booking.site_texts set needs_translation = r.nt where key = r.key and lang = r.lang and published_text in ('Saunarituaali-ilta', 'Sauna ritual evening');
  end loop;
  raise notice 'booking_159 rollback: palautettu % tekstiä', n;
end $m$;
