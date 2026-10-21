# Rich-teksti hallinnassa

Hallinnan Viestit-kentät ja tuotekuvaukset käyttävät pientä työkaluriviä. Omistaja voi lihavoida, kursivoida, lisätä otsikon tai alaotsikon, luettelon ja linkin. Muita muotoiluja ei ole.

## Kirjasto

[Trix](https://github.com/basecamp/trix) 2.1.15 (37signals, MIT). Tiedostot ovat `booking/admin/vendor/trix/` (`trix.esm.min.js` 203 040 tavua, gzip 50 963; `trix.css` 19 638 tavua, gzip 4 274). Editori ladataan vasta, kun tuotteen tai viestin lomake aukeaa. Sivustolla ei ole bundleria, joten TipTap (ProseMirror-nippu) ja Quill eivät sovi yhtä kevyesti. Trix on yksi ESM-tiedosto ja oma CSS.

Trix 2 puhdistaa liimauksen mukana tulevalla DOMPurifylla ja hylkää `javascript:`-osoitteet linkkivalinnassa. Sama kapea allowlist ajetaan vielä tallennuksessa, kaupan renderöinnissä ja sähköpostissa. Sähköpostipohja ei voi ottaa DOM-kirjastoa, joten palvelin käyttää funktiota `booking/shared/rich-text.js`. Sama tiedosto on kopioitu hallintaan, kauppaan ja `send-emails`-funktion `_shared`-kansioon. Testi vaatii, että kopiot ovat tavulleen samat.

## Kentät

- Viestit: lyhyt ohje FI/EN (`short_fi`, `short_en`) ja teksti FI/EN (`body_fi`, `body_en`). Aihe ja linkkikenttä pysyvät tavallisina.
- Tuote: kuvaus FI/EN (`description`, `description_en`), sekä muokkaus että uusi tuote.

Paikkamerkit `{asiakas_nimi}`, `{tilaus_linkki}`, `{tuote}`, `{saapumisaika}` ja `{linkki}` kirjoitetaan tekstin sekaan. Linkin osoitteeksi kelpaa `http`, `https`, `mailto` sekä tarkka `{tilaus_linkki}` tai `{linkki}`.

## Mitä asiakas näkee

Sallitut tagit: `p`, `br`, `strong`, `b`, `em`, `i`, `h2`, `h3`, `ul`, `ol`, `li`, `a`. Ei tyylejä, skriptejä eikä kuvia. `h1` näytetään otsikkona (`h2`), `div` kappaleena.

Vanha pelkkä teksti ei ole HTML:ää. Kauppa ja tilaussivu näyttävät sen kuten ennen, rivinvaihdot mukana. Kortin ja päivänäkymän ote on näkyvää tekstiä, jotta tagi ei katkea keskeltä. Tuotesivulla ja tilaussivun ohjeessa muotoilu näkyy. Sivun fokus ei siirry kuvauksen otsikkoon. Markkinointisivun kortit tulevat yhä `cards.json`-teksteistä, ei kb-kuvauksesta.

Sähköpostissa rich-teksti saa inline-tyylit (Arial, tumma vihreä). Tekstiversio tekee otsikosta rivin, luettelosta `•` tai `1.` ja linkistä `teksti (osoite)`. Paikkamerkit täytetään tietokannassa ennen lähetystä. Sen jälkeen sama allowlist ajetaan uudestaan, joten asiakkaan nimessä oleva skripti ei lähde viestiin.

## Tietokanta

Migraatio `20261021150000_booking_122_rich_text.sql` lisää lajin `rich` ja asettaa olemassa olevien tuotekuvausten (`kb.products.description` / `description_en`) lajiksi `rich` ja enimmäispituudeksi 8000. Julkaistua tekstiä, hintoja, ALV:tä ja osoitteita ei muuteta. Uusi tuotekuvaus rekisteröityy samalla lajilla. Muut tekstikentät hylkäävät HTML:n kuten ennen. Rich-kenttä hylkää skriptin, `on*`-attribuutin, `javascript:`-osoitteen ja allowlistin ulkopuolisen tagin.

Rollback: `booking/supabase/rollbacks/20261021150000_booking_122_ROLLBACK.sql`.

## Käyttöönotto

Ei ajeta tästä haarasta tuotantoon.

1. Aja migraatio `booking_122`.
2. Julkaise edge-funktio `send-emails` uudelleen (pohja puhdistaa rich-tekstin ennen lähetystä).
3. Tuo `content/site-texts.pending-import-30.json` (26 riviä, 13 avainta × fi/en). Ne ovat vain hallinnan työkalurivin sanoja. Tuonti ei ylikirjoita olemassa olevia rivejä. Ennen tuontia hallinta käyttää repon sanakirjaa.

Kaupan build kopioi `invoice-validate.js` julkaisuun, koska `shop.js` tuo sen. Ilman tiedostoa kaupan moduuli ei lataudu.
