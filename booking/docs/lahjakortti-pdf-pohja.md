# Lahjakortin PDF-pohja (suunnitelma ja mockup)

Tila: **suunnittelu valmis, toteutus myöhemmin** (edge function `gift-card-pdf`, vaihe 2, Bottiavustus). Tämä dokumentti on pohja toteutukselle; kauppa ei vielä lataa PDF:ää (ks. "Kytkentä kauppaan" alla).

Mockupit (HTML + PNG, 2× tarkkuus): `lahjakortti-pdf-pohja.html`, `lahjakortti-pdf-pohja-fi.png` (paketti + tervehdys), `lahjakortti-pdf-pohja-en.png` (avoin kortti, ei tervehdystä), `lahjakortti-pdf-pohja-fi-pitka-tervehdys.png` (300 merkin tervehdys mahtuu).

![FI](lahjakortti-pdf-pohja-fi.png)
![EN](lahjakortti-pdf-pohja-en.png)

## Muoto
- **A5 vaaka** (210 × 148 mm), yksi sivu, tulostettava ja näytöllä luettava. Marginaali 11,5 mm (44 px mockupissa); katkoviivakehys vain mockupissa (ei PDF:ään, tai halutessa hienona leikkausviivana).
- Rakenne ylhäältä alas: **tummanvihreä yläpalkki** (`#2B3A30`, kultainen alaviiva `#C49A6C`) jossa nimi ja otsikko "Lahjakortti" / "Gift card"; **sisältö** kahdessa sarakkeessa; **alapalkki** (`#F3ECE1`) myyjän tiedoilla.
- Vasen sarake: kicker ("Lahjakorttipaketti" / "Avoin lahjakortti"), **paketin nimi**, **arvo** (kulta `#7A5530`), saaja, **tervehdys** (kursiivi, kultainen vasen reunaviiva), lahjoittaja.
- Oikea sarake: **koodilaatikko** (hiekka `#EDE3D0`, koodi tasalevyisellä fontilla `HHxx-xxxx-xxxx`), voimassaolo, henkilömäärä, myöntöpäivä, käyttöohje.
- Ei sinistä. Tekstikontrastit ≥ 4,5:1 (mitattu: kulta #7A5530 / #FAF7F1 = 6,2:1; muted #6B5E52 / #F3ECE1 = 5,35:1; vaalea #F3ECE1 / vihreä = 10,2:1; kultainen kicker #E3C79A / vihreä = 7,4:1; koodi vihreä / hiekka = 9,4:1).
- Fontit (sivuston omat, `public/fonts`): Playfair Display (nimi), Cormorant Garamond (otsikot, arvo, tervehdys), Montserrat (kickerit), Lato (leipäteksti). `pdf-lib` + `fontkit` voi upottaa woff2:sta muunnetut TTF:t; **varafontit** `StandardFonts` (Helvetica/TimesRoman) riittävät ä/ö/å/€-merkeille (WinAnsi), jos upotus jätetään pois (kuten `receipt-pdf`).

## Tietolähde: `public_get_gift_card(p_public_token)` (sopimus §13.2)
| PDF-kenttä | RPC-kenttä | Huomio |
|---|---|---|
| Koodi | `code` (`XXXX-XXXX-XXXX`) | jo viivallinen; ei normalisoida uudelleen |
| Otsikko | `locale` (`fi`/`en`) | valitsee kielen: "Lahjakortti" / "Gift card" |
| Kicker | `kind`, `package_code` | `open` → "Avoin lahjakortti"; muuten "Lahjakorttipaketti" |
| Paketin nimi | `package.name` / `package.name_en` | avoimella kortilla: "Käy kaikkiin palveluihimme" / "Valid for all our services" |
| Sisältö / kuvaus | `package.items`, `package.description(_en)` | näytetään jos ei tyhjä (tuotannossa osa tyhjiä) |
| Arvo | `initial_amount`, `currency` | avoin kortti: arvo euroina; paketti: paketin hinta |
| Saldo | `balance` | vain jos `balance ≠ initial_amount` (esim. uudelleentulostus osittain käytetystä) |
| Saaja | `recipient_name` | rivi piilotetaan jos tyhjä |
| Tervehdys | `greeting` (≤ 300 merkkiä) | rivinvaihdot säilytetään; **tyhjä → koko tervehdysosa piiloon** |
| Lahjoittaja | `buyer_name` | piilotetaan jos tyhjä |
| Voimassa | `valid_to` | Helsingin päivä; "asti" / "Valid until"; kortti käy koko päättymispäivän |
| Henkilömäärä | `package.persons` | vain paketeille |
| Myönnetty | `issued_at` | Helsingin päivä |
| Alapalkki | `seller` (`_seller()`) | nimi, osoite, puhelin, sähköposti |
| Tila | `status` | PDF vain `active`/`used`; `not_ready` (maksamaton) → ei PDF:ää; `expired` → "Vanhentunut"-leima |

## Tervehdyksen mahtuminen
Tervehdys ≤ 300 merkkiä: mockupissa 17,5 px / 1,3 rivikorkeus, sarakkeen leveys ≈ 370 px → noin 7 riviä (mockup testattu täsmälleen 300 merkillä, ei leikkaannu). PDF:ssä rivitys tehdään sanatasolla (`pdf-lib`: `widthOfTextAtSize`); jos 7 riviä ylittyy (hyvin leveät merkit), fontti pienennetään 17,5 → 15 pt:aan ennen leikkausta. Merkit joita fontti ei osaa (esim. emoji) korvataan `?`:lla tai poistetaan PDF:ssä; web-lomake sallii ne (laskuri laskee koodipisteet).

## Kytkentä kauppaan (jo valmiina)
- Tilaussivu (`/tilaus/?t=…`): kortin kohdalla **"Lataa PDF"** -painike näkyy vain kun `config.js`:ssä on `giftCardPdf: true` (tai edge functionin nimi) ja kortti on valmis (`ready`). Oletus `false` → painiketta ei ole, eikä sivulla ole "tulossa" -tekstiä. Asetus vaihdetaan julkaisussa `booking/config.js`:ssä (ei uudelleenrakennusta) tai rakennusajossa `BOOKING_GIFT_CARD_PDF=1`.
- Linkki: `GET <functions>/gift-card-pdf?t=<kortin public_token>` (sama käytäntö kuin `receipt-pdf?t=…`: `verify_jwt=false`, vain UUID-tokeni; **ehdotus, vahvistettava toteutuksen yhteydessä**). Toteutuksen pitää hakea sisältö `public_get_gift_card`-logiikalla palvelinpuolella (service role) ja palauttaa `application/pdf`.
- Hallintaan (Lahjakortit-yksityiskohta) voi myöhemmin lisätä saman PDF-latauksen `fnBlob`-apurilla (JWT).

## Avoimet kysymykset toteutukselle
1. Logo: käytetäänkö kuvallista logoa nimen sijaan (SVG → PDF)? Mockup käyttää tekstinimeä.
2. Ehdot/pienellä: tarvitaanko alapalkkiin lyhyt ehtoteksti (siirrettävyys, rahaksi vaihto, voimassaolon jatko "maksutta pyydettäessä") – teksti tulee Joonakselta, ei keksitä tässä.
3. Saajan sivu (`public_get_gift_card` toimii myös siihen): halutaanko sama sisältö verkkosivuna (`/lahjakortti/kortti/?t=…`)?
