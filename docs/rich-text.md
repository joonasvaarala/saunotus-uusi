# Rich-teksti hallinnassa

Hallinnan Viestit-kentät ja tuotekuvaukset (FI ja EN) käyttävät Quillin Snow-teeman omaa kompaktia kuvakeriviä (yksi rivi myös 390 px leveällä puhelimella; rivittyy ryhmittäin tarvittaessa). Omistaja voi lihavoida, kursivoida, lisätä otsikon tai alaotsikon, luettelon ja linkin, poistaa muotoilun sekä kumota ja tehdä uudelleen. Jokaisella kuvakkeella on suomenkielinen aria-label ja title. Muita muotoiluja ei ole. Linkki lisätään ja poistetaan omassa suomenkielisessä osoitekentässä (Quillin englanninkielinen tooltip on piilotettu). Värit #2B3A30 / #F4EFE7 / #7A5530; Quillin oletussininen #06c ohitetaan. Jos Quill ei lataudu, kenttä jää tavalliseksi tekstikentäksi ohjeteksteineen. Tallennusmuoto (puhdistettu HTML) ei muuttunut.

## Kirjasto

[Quill](https://quilljs.com) 2.0.3 (Slab, **BSD-3-Clause**, ei MIT). Tiedostot ovat `booking/admin/vendor/quill/`: `quill.js` (UMD-nippu npm-paketin `dist/`-hakemistosta, 209 241 tavua, gzip 58 986), `quill.snow.css` (24 565 tavua, gzip 3 729), `LICENSE` ja `quill.js.LICENSE.txt`. Source map -viittaukset on poistettu, muuten tiedostot ovat npm-paketin `quill@2.0.3` tavut. Ei CDN:ää: hallinta lataa skriptin ja CSS:n omasta kansiostaan vasta, kun tuotteen tai viestin lomake, jossa on aktiivinen `textarea[data-rich]`, aukeaa. Tyhjä lomake tai pois käytöstä oleva kenttä ei lataa mitään. Aiempi Trix 2.1.19 (`vendor/trix/`) on poistettu (paketti 08).

Päivitys: `npm pack quill@<versio>`, kopioi `dist/quill.js`, `dist/quill.snow.css`, `dist/quill.js.LICENSE.txt` ja `LICENSE`, poista `sourceMappingURL`-rivit ja päivitä testi `booking/tests/rich-text.test.mjs`.

### XSS ja sanitointi

Quill 2.0.3:ssa on julkaistu haavoittuvuus CVE-2025-15056 (GHSA-v3m3-f69x-jf25): `getSemanticHTML()` ei escapeta formula- ja video-upotusten arvoja. Korjattua versiota ei ole. Tässä käytössä:

- Editori sallii vain formaatit `bold`, `italic`, `header`, `list` ja `link` (`formats`-lista). Formula, video, kuva, koodilohko, värit ja tyylit eivät ole käytössä.
- Liimauksessa `img`, `video`, `audio`, `iframe`, `object`, `embed`, `script`, `style`, `template`, `noscript`, `svg` ja `math` hylätään. Tiedostojen pudotus ja liitteiden liimaus estetään.
- Linkin osoite tarkistetaan samalla allowlistilla kuin tallennus (`http`, `https`, `mailto`, tarkka `{tilaus_linkki}` tai `{linkki}`). Muut osoitteet Quill muuttaa muotoon `about:blank`, ja allowlist poistaa ne.
- Editorin HTML ei koskaan mene sellaisenaan eteenpäin: `getSemanticHTML()` → `normalizeStored()` (sama allowlist kuin alla) → piilokenttä → FormData. Palvelin tarkistaa vielä tallennuksessa (`booking._rich_text_check`), ja kauppa sekä sähköposti puhdistavat näytettäessä.
- Quill muuttaa välilyönnit muotoon `&nbsp;`. Allowlist muuttaa ne takaisin tavallisiksi välilyönneiksi, joten teksti rivittyy kaupassa ja sähköpostissa kuten ennen.

Sama kapea allowlist ajetaan tallennuksessa, kaupan renderöinnissä ja sähköpostissa. Sähköpostipohja ei voi ottaa DOM-kirjastoa, joten palvelin käyttää funktiota `booking/shared/rich-text.js`. Sama tiedosto on kopioitu hallintaan, kauppaan ja `send-emails`-funktion `_shared`-kansioon. Testi vaatii, että kopiot ovat tavulleen samat. (Kopioiden kommentti mainitsee vielä Trixin. Sitä ei muutettu, jotta edge-funktion `_shared`-kopio ei muutu.)

Rich-teksti tallentuu tuotteen kuvaukseen ja viestipohjiin, ei `site_texts`-tauluun. Työkalurivin sanat ovat `ui.admin.rich.*`-avaimia (`pending-import-30`), eikä niissä ole `<`-merkkiä.

## Kentät

- Viestit: lyhyt ohje FI/EN (`short_fi`, `short_en`) ja teksti FI/EN (`body_fi`, `body_en`). Aihe ja linkkikenttä pysyvät tavallisina.
- Tuote: kuvaus FI/EN (`description`, `description_en`), sekä muokkaus että uusi tuote.

Paikkamerkit `{asiakas_nimi}`, `{tilaus_linkki}`, `{tuote}`, `{saapumisaika}` ja `{linkki}` kirjoitetaan viestin tekstin sekaan. Ne eivät toimi tuotekuvauksessa. Linkin osoitteeksi kelpaa `http`, `https`, `mailto` sekä tarkka `{tilaus_linkki}` tai `{linkki}`.

## Mitä asiakas näkee

Sallitut tagit: `p`, `br`, `strong`, `b`, `em`, `i`, `h2`, `h3`, `ul`, `ol`, `li`, `a`. Ei tyylejä, skriptejä eikä kuvia. `h1` näytetään otsikkona (`h2`), `div` kappaleena.

Vanha pelkkä teksti ei ole HTML:ää. Kauppa ja tilaussivu näyttävät sen kuten ennen, rivinvaihdot mukana. Kortin ja päivänäkymän ote on näkyvää tekstiä, jotta tagi ei katkea keskeltä. Tuotesivulla ja tilaussivun ohjeessa muotoilu näkyy. Sivun fokus ei siirry kuvauksen otsikkoon. Markkinointisivun kortit tulevat yhä `cards.json`-teksteistä, ei kb-kuvauksesta.

Sähköpostissa rich-teksti saa inline-tyylit (Arial, tumma vihreä). Tekstiversio tekee otsikosta rivin, luettelosta `•` tai `1.` ja linkistä `teksti (osoite)`. Paikkamerkit täytetään tietokannassa ennen lähetystä. Arvo on dataa: `<`, `>` ja `"` muutetaan merkeiksi, jotka eivät avaa tagia. Rich- vai pelkkä teksti päätetään täyttämättömästä pohjasta, ei täytetystä merkkijonosta. Asiakkaan nimi ei siis muutu linkiksi tai tagiksi sähköpostissa eikä tilaussivulla.

## Tietokanta

Migraatio `20261021171915_booking_122_rich_text.sql` lisää lajin `rich` ja asettaa olemassa olevien tuotekuvausten (`kb.products.description` / `description_en`) lajiksi `rich` ja enimmäispituudeksi 8000. Julkaistua tekstiä, hintoja, ALV:tä ja osoitteita ei muuteta. Uusi tuotekuvaus rekisteröityy samalla lajilla. `admin_update_product` ja `admin_product_create` kutsuvat samaa tarkistusta, kun kuvauksessa on `<`. Muut tekstikentät hylkäävät HTML:n kuten ennen. Rich-kenttä hylkää skriptin, `on*`-attribuutin, allowlistin ulkopuolisen tagin ja `javascript:`- tai `data:`-osoitteen href-attribuutissa. Pelkkä teksti `personal data:` on sallittu.

Rollback: `booking/supabase/rollbacks/20261021171915_booking_122_ROLLBACK.sql`.

## Käyttöönotto

Ei ajeta tästä haarasta tuotantoon.

1. Aja migraatio `booking_122`.
2. Julkaise edge-funktio `send-emails` uudelleen (pohja puhdistaa rich-tekstin ennen lähetystä).
3. Tuo `content/site-texts.pending-import-30.json` (28 riviä, 14 avainta × fi/en). Ne ovat vain hallinnan työkalurivin sanoja. Uudet kuvakenimet `ui.admin.rich.clean` ja `ui.admin.rich.toolbar` tulevat repon oletuksista (`RICH_EXTRA_TEXTS`), eivät tästä tuonnista. Tuotekuvauksen ohje ei mainitse paikkamerkkejä. Tuonti ei ylikirjoita olemassa olevia rivejä. Ennen tuontia hallinta käyttää repon sanakirjaa.

Kaupan build kopioi `invoice-validate.js` julkaisuun, koska `shop.js` tuo sen. Ilman tiedostoa kaupan moduuli ei lataudu.
