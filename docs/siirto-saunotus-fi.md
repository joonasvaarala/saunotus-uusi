# Siirto saunotus.fi:hin (1.11.2026) – ajokirja

**Päätös (Joonas 24.10.2026):** uusi sivusto on 1.11.2026 alkaen osoitteessa **https://saunotus.fi**. `www.saunotus.fi` ja `saunotus.com`
ohjataan sinne (301). Vanha WordPress-kehityssivusto (`uusi.saunotus.com`) oli olemassa jo ennen tätä projektia, eikä se kuulu uuteen
sivustoon. Se poistetaan käytöstä vasta vaiheessa C, ja vain Joonasin erillisellä luvalla.

Tämän PR:n jälkeen repossa ei ole viittauksia vanhaan kehitysosoitteeseen seuraavia poikkeuksia lukuun ottamatta (lista ja perustelut:
vartijatesti `booking/tests/osoite-saunotus-fi-170.test.mjs`):
- booking_170-migraatio, sen rollback ja SQL-testi t170, koska ne korvaavat juuri sen osoitteen tietokannassa, sekä tämä ajokirja.
- Jo ajetut migraatiot booking_29, booking_161 ja booking_163 sekä 161:n ja 163:n rollbackit ja testit. Ajetut migraatiot ovat muuttumatonta historiaa, joten niitä
  ei muuteta (ne ovat identtiset mainin kanssa).
- `content/kb/kb.json`: tuotannon tilannekuva. Se päivittyy seuraavassa tilannekuvassa booking_170:n ajon jälkeen.
- `booking/shop/src/johku-links.js` (`LEGACY_CANONICAL`) ja `src/lib.mjs` (`SHOP_CANON`): koodi tunnistaa vanhan osoitteen ja ohjaa sen
  sivuston omaan polkuun. Näin sivustolle ei päädy linkkiä vanhalle kehityssivulle, vaikka tiedoissa olisi vielä vanha osoite.
- `booking/supabase/functions/send-emails/golden-cases.mjs`: sähköpostien kultaisten tiivisteiden (`golden-email.json`) syöte,
  joka otettiin ennen tekstien siirtoa. Osoitteen vaihto muuttaisi tiivisteet, joten tiedostoa ei muuteta.

Merkinnät: 🗄️ = tuotantotietokannan muutos, 🖥️ = palvelin-, DNS- tai hosting-muutos. Kumpikin tarvitsee Joonasin OK:n ennen ajoa.

## A. Nyt (ennen siirtoa): koodi ja tietokanta samaan aikaan

1. 🗄️ **`booking/supabase/migrations/20261024201634_booking_170_osoite_saunotus_fi.sql` ajettu tuotantoon 24.10.2026 (versio 20261024201634) tämän PR:n yhdistämisen yhteydessä.**
   Koodin kanoninen osoite on tämän jälkeen `https://saunotus.fi` (`booking/shop/src/johku-links.js` CANONICAL, `src/lib.mjs` SHOP_CANON).
   Koodi tunnistaa myös vanhan kehitysosoitteen ja ohjaa sen sivuston omaan polkuun, joten ajojärjestys ei riko linkkejä. Tietokannan
   tekstit on silti tarkoitus korjata samana päivänä.
   - Kohde (tuotanto 24.10.2026, SELECT): 11 kenttää 6 tuotteessa (1, 7, 25, 26, 38: `description`/`description_en`; 50: `source_url`), yhteensä 31 osoitetta.
   - Vartija: jokaisen kentän md5 on oltava täsmälleen odotettu, muuten migraatio pysähtyy ennen yhtään muutosta. Migraation voi ajaa uudelleen.
   - Lähdetauluun sidotut sivutekstit (`product.<id>.description` [fi/en]) saavat uuden version triggerin `zz_site_text_sync` kautta
     (tuotannossa 10 versiota: tuotteet 1, 7, 25, 26, 38 × fi/en).
   - `needs_translation`: trigger nollaisi muutetun kieliversion lipun ja nostaisi toisen kieliversion lipun. Tuotannossa se nostaisi
     tuotteiden 1, 7 ja 38 fi-lipun ja nollaisi niiden en-lipun. Osoitevaihto ei muuta sisältöä, joten migraatio ottaa näiden rivien
     liput talteen ennen päivitystä ja palauttaa ne täsmälleen päivityksen jälkeen. Palautus koskee vain tuotteita, joiden kenttiä ajo
     muutti, ja vain rivejä, joiden julkaistu teksti on täsmälleen tämän migraation tulos. Muuten migraatio pysähtyy, eikä mitään muuteta.
     Lopputulos: kaikkien rivien `needs_translation` on sama kuin ennen ajoa. Rollback tekee saman.
   - Rollback: `booking/supabase/rollbacks/20261024201634_booking_170_ROLLBACK.sql` palauttaa tekstit täsmälleen, ja liput jäävät ennalleen.
   - SQL-testi `booking/supabase/tests/kb/t170_osoite_saunotus_fi.sql` (paikallinen PG17, tuotannon tekstit ja liput 24.10.2026):
     ajo, uudelleenajo, rollback (md5 täsmää alkuperäiseen), rollbackin uudelleenajo, vartijat (poikkeava teksti → pysähtyy, ei muutoksia)
     ja `needs_translation` ennallaan jokaisen vaiheen jälkeen. Tulos: pass=26 fail=0.
   - Tarkistus ajon jälkeen (pelkkä SELECT):
     `select count(*) from kb.products where concat_ws(' ', description, description_en, short_description, short_description_en, booking_url, source_url) like '%uusi.saunotus%';` → 0
2. Jo ajettuja migraatioita booking_29, booking_161 ja booking_163 (sekä niiden rollbackeja ja testejä t161/t163) ei muuteta, koska ajetut migraatiot
   ovat muuttumatonta historiaa. Ne kirjoittavat vanhan kehitysosoitteen, ja booking_170 korjaa sen tuotannossa. Huom: booking_163 on
   peruttu tuotannossa (`kb.products.booking_url` on taas Johku-osoitteissa), ja se jätetään sellaiseksi. Jos 163 joskus ajetaan uudelleen,
   se kirjoittaa vanhan kehitysosoitteen. Koodi ohjaa sen sivuston omaan polkuun, mutta osoite on silloin korjattava uudella migraatiolla.

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
4. Tarkistus: `rg 'uusi\.saunotus\.com'` repossa löytää vain yllä luetellut poikkeukset (`booking/tests/osoite-saunotus-fi-170.test.mjs`).
   Kun kehityssivu poistetaan, `LEGACY_CANONICAL`-tunnistus voidaan poistaa vasta, kun tietokannassa ei ole vanhaa osoitetta.
5. Joonas valitsee: poistetaanko kehityssivu kokonaan vai ohjataanko `uusi.saunotus.com` → `https://saunotus.fi` (301) siirtymäajan.
