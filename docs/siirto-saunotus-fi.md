# Siirto saunotus.fi:hin (1.11.2026) – ajokirja

**Päätös (Joonas 24.10.2026):** uusi sivusto on 1.11.2026 alkaen osoitteessa **https://saunotus.fi**. `www.saunotus.fi` ja `saunotus.com`
ohjataan sinne (301). Vanha WordPress-kehityssivusto (`uusi.saunotus.com`) oli olemassa jo ennen tätä projektia, eikä se kuulu uuteen
sivustoon. Se poistetaan käytöstä vasta vaiheessa C, ja vain Joonasin erillisellä luvalla.

Tämän PR:n jälkeen repossa ei ole yhtään viittausta vanhaan kehitysosoitteeseen. Poikkeuksena ovat booking_170-migraatio ja sen rollback,
koska ne korvaavat juuri sen osoitteen tietokannassa, sekä tämä ajokirja. Vartijatesti on `booking/tests/osoite-saunotus-fi-170.test.mjs`.

Merkinnät: 🗄️ = tuotantotietokannan muutos, 🖥️ = palvelin-, DNS- tai hosting-muutos. Kumpikin tarvitsee Joonasin OK:n ennen ajoa.

## A. Nyt (ennen siirtoa): koodi ja tietokanta samaan aikaan

1. 🗄️ **Aja `booking/supabase/migrations/20261024194500_booking_170_osoite_saunotus_fi.sql` tuotantoon samana päivänä, kun tämä PR yhdistetään.**
   Koodi tunnistaa tämän jälkeen kanonisiksi vain `https://saunotus.fi/…`-osoitteet (`booking/shop/src/johku-links.js` CANONICAL,
   `src/lib.mjs` SHOP_CANON). Siksi tietokannan kuvauksissa olevat vanhat osoitteet täytyy päivittää samaan aikaan. Muuten testisivun
   tuotekuvausten linkit ohjautuisivat vanhalle kehityssivulle.
   - Kohde (tuotanto 24.10.2026, SELECT): 11 kenttää 7 tuotteessa (1, 7, 25, 26, 38: `description`/`description_en`; 50: `source_url`), yhteensä 31 osoitetta.
   - Vartija: jokaisen kentän md5 on oltava täsmälleen odotettu, muuten migraatio pysähtyy ennen yhtään muutosta. Migraation voi ajaa uudelleen.
   - Lukitut sivutekstit (`product.<id>.description`) päivittyvät triggerin `zz_site_text_sync` kautta.
   - Rollback: `booking/supabase/rollbacks/20261024194500_booking_170_ROLLBACK.sql` palauttaa tekstit täsmälleen. Paikallisesti testattu
     tuotannon teksteillä: ajo, uudelleenajo, rollback (md5 täsmää alkuperäiseen) ja poikkeava teksti (pysähtyy, ei muutoksia).
   - Tarkistus ajon jälkeen (pelkkä SELECT):
     `select count(*) from kb.products where concat_ws(' ', description, description_en, booking_url, source_url) like '%uusi.saunotus%';` → 0
2. Repoon jo ajetut migraatiot booking_161 ja booking_163 (sekä niiden rollbackit ja testit t161/t163) on päivitetty kirjoittamaan suoraan
   `https://saunotus.fi`-osoitteita, ja niiden md5-vartijat on laskettu uudelleen. Tyhjässä kannassa tulos on siis heti oikea. Tuotannossa
   booking_170 korjaa jo kirjoitetut arvot, ja tämän jälkeen 161/163-rollbackien vartijat vastaavat taas tuotannon tilaa.
   Huom: booking_163 näkyy ajettujen migraatioiden listassa, mutta `kb.products.booking_url` oli 24.10.2026 klo 22.40 (UTC+3) taas
   Johku-osoitteissa (163:n rollback ajettu?). Jos 163 ajetaan uudelleen, se kirjoittaa nyt suoraan `https://saunotus.fi/varaa/#/…`.

## B. Siirtopäivä 1.11.2026

1. 🖥️ `saunotus.fi` osoittamaan uuteen sivustoon (hosting/DNS). Sivusto rakennetaan tuotantotilassa: `SITE_ENV` pois tai `prod`,
   `SITE_URL=https://saunotus.fi` (`content/site.json` → `canonicalBase` on jo `https://saunotus.fi`). Tuotantobuild ei käytä noindexiä.
2. 🖥️ `www.saunotus.fi` ja `saunotus.com` (+ `www.saunotus.com`) → 301 `https://saunotus.fi/` (polku säilyy).
3. 🗄️ `booking.settings.site_base_url` → `"https://saunotus.fi"`. Nyt arvo on `https://joonasvaarala.github.io/saunotus-uusi`.
   Sähköpostien, tilaussivun, QR-koodien ja kalenterin linkit rakentuvat tästä asetuksesta.
4. 🖥️ Edge-funktion ympäristömuuttuja `SHIFT_OFFER_PAGE_BASE=https://saunotus.fi` (shift-offer-engine; oletus on testisivu).
   `https://saunotus.fi` ja `https://www.saunotus.fi` ovat jo sallittujen originien listassa.
5. 🖥️ Supabase Auth: lisää Site URL / Redirect URLs -asetuksiin `https://saunotus.fi/hallinta/` ja muut tarvittavat osoitteet, jos hallinnan
   kirjautuminen käyttää uudelleenohjausta.
6. 🖥️ WhatsApp/Meta: Business infon verkkosivuksi `https://saunotus.fi` (docs/whatsapp-setup.md).
7. Tarkistukset: `npm run check`, `node scripts/check.mjs --external`, etusivun canonical/hreflang/sitemap (`https://saunotus.fi/…`),
   tilaussivun linkki testitilauksen sähköpostissa ja juomien QR-osoite (`https://saunotus.fi/juomat/?laite=…`).

## C. Vanhan kehityssivuston `uusi.saunotus.com` poisto: 🖥️ PALVELINMUUTOS, VAATII JOONASIN NIMENOMAISEN OK:N

**Tätä vaihetta ei tehdä automaattisesti, eikä sitä tehdä tämän PR:n osana.** DNS-tietuetta, WordPress-asennusta tai hostingia ei poisteta,
ennen kuin Joonas on erikseen kirjoittanut OK:n juuri tälle muutokselle. Ennen OK:n pyytämistä:

1. Vaiheet A ja B on tehty, ja B7:n tarkistukset ovat vihreät.
2. Alkuperäiset lähdekuvat on arkistoitu. `scripts/fetch-assets.mjs`:n `uusi:`-kuvat (28 kpl, `wp-content/uploads/2026/05/…`) ovat
   vain kehityssivulla, eivät saunotus.fi:n nykyisessä WordPressissä (24.10.2026 tarkistettu: 28/28 → 404). Käsitellyt kuvat ovat jo
   repossa (`public/img`). Väliaikainen kopio on botin työkoneella: `/workspace/uusi-saunotus-com-alkuperaiset/` (46 Mt).
   Joonas päättää säilytyspaikan (esim. Drive).
3. Tietokannan historia- ja lähdetiedot viittaavat yhä vanhaan osoitteeseen. Ne eivät näy asiakkaalle, eikä booking_170 muuta niitä:
   `kb.sources.url` (12), `kb.faq/opening_hours/policies/locations/businesses.source_url` (10/10/9/2/1), `kb.review_items.fix_url` (28),
   `booking.site_text_versions` (versiohistoria) ja audit-/change-logit. Päätettävä erikseen, jätetäänkö ne historiaksi.
4. Tarkistus: `rg 'uusi\.saunotus\.com'` repossa löytää vain booking_170-migraation, sen rollbackin ja tämän ajokirjan.
5. Joonas valitsee: poistetaanko kehityssivu kokonaan vai ohjataanko `uusi.saunotus.com` → `https://saunotus.fi` (301) siirtymäajan.
