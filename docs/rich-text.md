# Rich-teksti hallinnassa

Hallinnan Viestit-kentät ja tuotekuvaukset käyttävät pientä työkaluriviä. Omistaja voi lihavoida, kursivoida, lisätä otsikon tai alaotsikon, luettelon ja linkin. Muita muotoiluja ei ole.

## Kirjasto

[Trix](https://github.com/basecamp/trix) 2.1.19 (37signals, MIT). Tiedostot ovat `booking/admin/vendor/trix/` (`trix.esm.min.js` 207 593 tavua, gzip 52 012; `trix.css` 19 638 tavua, gzip 4 274). Versio 2.1.15 jätettiin pois tunnettujen XSS-aukkojen takia (GHSA-g9jg-w8vm-g96v, GHSA-53g2-mvcc-q9x3, GHSA-53p3-c7vp-4mcc). Editori ladataan vasta, kun tuotteen tai viestin lomake aukeaa. Sivustolla ei ole bundleria, joten TipTap (ProseMirror-nippu) ja Quill eivät sovi yhtä kevyesti. Trix on yksi ESM-tiedosto ja oma CSS.

Trix 2 puhdistaa liimauksen mukana tulevalla DOMPurifylla ja hylkää `javascript:`-osoitteet linkkivalinnassa. Sama kapea allowlist ajetaan vielä tallennuksessa, kaupan renderöinnissä ja sähköpostissa. Sähköpostipohja ei voi ottaa DOM-kirjastoa, joten palvelin käyttää funktiota `booking/shared/rich-text.js`. Sama tiedosto on kopioitu hallintaan, kauppaan ja `send-emails`-funktion `_shared`-kansioon. Testi vaatii, että kopiot ovat tavulleen samat.

## Kentät

- Viestit: lyhyt ohje FI/EN (`short_fi`, `short_en`) ja teksti FI/EN (`body_fi`, `body_en`). Aihe ja linkkikenttä pysyvät tavallisina.
- Tuote: kuvaus FI/EN (`description`, `description_en`), sekä muokkaus että uusi tuote.

Paikkamerkit `{asiakas_nimi}`, `{tilaus_linkki}`, `{tuote}`, `{saapumisaika}` ja `{linkki}` kirjoitetaan viestin tekstin sekaan. Ne eivät toimi tuotekuvauksessa. Linkin osoitteeksi kelpaa `http`, `https`, `mailto` sekä tarkka `{tilaus_linkki}` tai `{linkki}`.

## Mitä asiakas näkee

Sallitut tagit: `p`, `br`, `strong`, `b`, `em`, `i`, `h2`, `h3`, `ul`, `ol`, `li`, `a`. Ei tyylejä, skriptejä eikä kuvia. `h1` näytetään otsikkona (`h2`), `div` kappaleena.

Vanha pelkkä teksti ei ole HTML:ää. Kauppa ja tilaussivu näyttävät sen kuten ennen, rivinvaihdot mukana. Kortin ja päivänäkymän ote on näkyvää tekstiä, jotta tagi ei katkea keskeltä. Tuotesivulla ja tilaussivun ohjeessa muotoilu näkyy. Sivun fokus ei siirry kuvauksen otsikkoon. Markkinointisivun kortit tulevat yhä `cards.json`-teksteistä, ei kb-kuvauksesta.

Sähköpostissa rich-teksti saa inline-tyylit (Arial, tumma vihreä). Tekstiversio tekee otsikosta rivin, luettelosta `•` tai `1.` ja linkistä `teksti (osoite)`. Paikkamerkit täytetään tietokannassa ennen lähetystä. Arvo on dataa: `<`, `>` ja `"` muutetaan merkeiksi, jotka eivät avaa tagia. Rich- vai pelkkä teksti päätetään täyttämättömästä pohjasta, ei täytetystä merkkijonosta. Asiakkaan nimi ei siis muutu linkiksi tai tagiksi sähköpostissa eikä tilaussivulla.

## Tietokanta

Migraatio `20261021150000_booking_122_rich_text.sql` lisää lajin `rich` ja asettaa olemassa olevien tuotekuvausten (`kb.products.description` / `description_en`) lajiksi `rich` ja enimmäispituudeksi 8000. Julkaistua tekstiä, hintoja, ALV:tä ja osoitteita ei muuteta. Uusi tuotekuvaus rekisteröityy samalla lajilla. `admin_update_product` ja `admin_product_create` kutsuvat samaa tarkistusta, kun kuvauksessa on `<`. Muut tekstikentät hylkäävät HTML:n kuten ennen. Rich-kenttä hylkää skriptin, `on*`-attribuutin, allowlistin ulkopuolisen tagin ja `javascript:`- tai `data:`-osoitteen href-attribuutissa. Pelkkä teksti `personal data:` on sallittu.

Rollback: `booking/supabase/rollbacks/20261021150000_booking_122_ROLLBACK.sql`.

## Käyttöönotto

Ei ajeta tästä haarasta tuotantoon.

1. Aja migraatio `booking_122`.
2. Julkaise edge-funktio `send-emails` uudelleen (pohja puhdistaa rich-tekstin ennen lähetystä).
3. Tuo `content/site-texts.pending-import-30.json` (28 riviä, 14 avainta × fi/en). Ne ovat vain hallinnan työkalurivin sanoja. Tuotekuvauksen ohje ei mainitse paikkamerkkejä. Tuonti ei ylikirjoita olemassa olevia rivejä. Ennen tuontia hallinta käyttää repon sanakirjaa.

Kaupan build kopioi `invoice-validate.js` julkaisuun, koska `shop.js` tuo sen. Ilman tiedostoa kaupan moduuli ei lataudu.
