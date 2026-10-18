# Sivutekstit tietokannasta (sopimus §18)

Päätös (Joonas 18.10.2026): kaikki asiakkaalle näkyvät tekstit ovat tietokannassa (`booking.site_texts`), eivät koodissa. Tämä dokumentti kuvaa, miten repo lukee ne. Sopimus: `booking/docs/KOODARI_talous_A_D_fi.md` §18 (avaimet, paikkamerkit, luokat, versiot, RPC:t `public_get_site_texts` / `admin_texts_import`).

## Miten tekstit päätyvät sivulle

| Missä | Miten | Milloin |
|---|---|---|
| Staattiset sivut (Pages-build, esirenderöinti) | `scripts/build.mjs` → `loadSiteTexts()` + `setSiteTexts()`; sivupohjat kutsuvat `tx(avain, kieli)` (`src/site-texts.mjs`) | build-aikana; teksti on valmiissa HTML:ssä (ei JS:ää, SEO) |
| Verkkokauppa (`/varaa/`, `/en/book/`) | `booking/shop/build.mjs` kirjoittaa `dist/booking/site-texts.json` (vain `ui.*`-avainalue); kauppa lataa sen (`siteTextsUrl`) ja täyttää paikkamerkit **ajoajan** katalogista ja `public_settings`-asetuksista (`booking/shop/src/site-texts.js`) | build + selaimessa |
| Tuotteet (nimi, kuvaus, kesto, voucher_note, aikajana) | kauppa lukee ne suoraan `public_catalog()`-vastauksesta (booking_61) – ei tekstitiedostoa | ajoaika |

Miksi kauppa täyttää paikkamerkit ajoaikana: hinta/kesto tulevat samasta katalogista kuin ostoskorin summa, joten välimuistissa oleva sivu ei voi näyttää eri hintaa kuin kassa. Build tarkistaa silti, että **kaikki** paikkamerkit ovat täytettävissä.

## Haku ja vikasietoisuus (`src/site-texts.mjs`)

1. live: `public_get_site_texts` (+ `public_catalog`, `public_settings` paikkamerkkien dataksi). Vain anon/publishable-avain, vain luku; `sb_secret` ja service_role hylätään.
2. epäonnistuu → `.cache/site-texts/snapshot.json` (edellinen onnistunut haku; `actions/cache` CI:ssä)
3. ei välimuistia → `content/site-texts.fallback.json` (repossa; päivitys `node scripts/site-texts-sync.mjs`, vain luku)
4. ei mitään → build jatkaa ja `tx()` käyttää kutsujan varatekstiä tai heittää `MissingTextError` (ei koskaan tyhjää eikä raakaa avainta)

Haun epäonnistuminen **ei kaada** buildia (varoitus lokiin; `SITE_TEXTS_STRICT=1` kaataa). **Tuntematon paikkamerkki kaataa buildin aina** (`PAIKKAMERKKIVIRHE: avain [kieli]: …`), samoin puuttuva arvo (`{{price:99}}`, `{{setting:ei_ole}}`). EN puuttuu → FI-teksti (lokitetaan). Testeille: `SITE_TEXTS_FIXTURE=1` (`tests/fixtures/site-texts/rpc.json`) tai polku omaan fixtureen.

Paikkamerkit (§18.3): `{{price:<tuote-id>}}`, `{{duration:<tuote-id>}}`, `{{setting:<julkinen asetus>}}`. Lukuja ei kirjoiteta käsin tekstiin.

## Rebuild kun tekstit muuttuvat

`pages.yml` käynnistyy myös `repository_dispatch`-tapahtumalla `site-texts-changed` (esim. `admin_texts_import`n tai Tekstit-näkymän tallennuksen jälkeen: `POST /repos/{owner}/{repo}/dispatches {"event_type":"site-texts-changed"}`) sekä tunnin ajastuksella.

## Kaupan kovakoodatut tekstit (osa 3, PR 1): avaimet ja peitto

Joonaksen päätös: kaikki asiakasnäkyvät tekstit tietokantaan. Kaupan sanakirjat (`i18n.js`, `order-texts.js`, `gift-texts.js`, `hold-texts.js`, `pay-choices-texts.js`, `mobilepay-texts.js`, `options-texts.js`) ja varaus-/tilaussivujen otsikot (`booking/shop/build.mjs` → `shop-page-texts.js`) ovat nyt avaimia:

- `booking/shop/src/text-registry.js` muuntaa sanakirjan lehdet avaimiksi (`ui.<alue>.<nimi>`; `i18n.js`: ylätaso `ui.shop.*`, `tr.*` → `ui.treatment.*`, `tr.errors.<koodi>` → `ui.checkout.error_<koodi>`, `errors.<koodi>` → `ui.shop.error_<koodi>`; `order-texts` → `ui.order.*`, `gift-texts` → `ui.gift.*`, `hold-texts` → `ui.hold.*`, `pay-choices-texts` → `ui.paychoice.*`, `mobilepay-texts` → `ui.mobilepay.*`, `options-texts` → `ui.option.*`; sivut `page.<sivu>.*` / `seo.<sivu>.*`).
- Paikkamerkit: `{n}` → `{{var:n}}` (**uusi laji `var`** = kutsuparametri, arvo tulee koodista käyttöhetkellä; ei hinta/kesto/asetus), `{{var:phone}}` = sivuston puhelinnumero (S.phone). Funktiolehdet (esim. `daySessions(n)`) ovat malleja: `ui.shop.day_sessions.one` / `.other` (monikko), argumentit `{{var:n}}`.
- **Tuontitiedosto** `content/site-texts.pending-import.json` generoidaan koodista: `node scripts/site-texts-extract-shop.mjs --prod <public_get_site_texts-vastaus.json>`; mukaan vain avaimet, joita ei ole tuotannossa (ei ylikirjoitusta). Tuonti `admin_texts_import` ≤ 500 riviä/kutsu (`jq -c '[.[range(0;500)]]' …`, `range(500;1000)`, `range(1000;1500)`).
- **Peitto** (`applySiteTexts`, kutsutaan `applyShopTexts(S, …)`): kauppa-, tilaus- ja lahjakorttisivu lataavat `booking/site-texts.json`n ja peittävät sanakirjat DB-teksteillä. Saman kielen rivi puuttuu / paikkamerkki ei täyty / JSON virheellinen → repon oletusteksti **samalla kielellä** (ulkoasu ei muutu; en-sivulle ei koskaan fi-tekstiä). Osa 5 poistaa oletukset vasta kun avaimet on vahvistettu tuotannossa.
- Ei tuoda: `T.directionsUrl` (tekninen URL-polku), `gift-logic.js` SOURCE_LABELS (varaetiketti: nimet tulevat palvelimelta), ICS-tiedoston `LOCATION` (osoite; ei avainta lähdedatassa) ja `PRODID`/`UID` (tekninen), mock-/testitekstit, hallinnan (admin) käyttöliittymä.

## Uuden tekstin lisääminen (§18.9, jokaisessa PR:ssä)

1. Avain `<alue>.<osa>.<nimi>` (virheet: `ui.<alue>.error_<RPC-koodi>`), FI + EN, luokka `normal`/`protected`.
2. Teksti **ei** mene koodiin. Lisää rivi tuontilistaan (esim. `content/site-texts.imported.json` on 18.10. tuotu erä) → tuonti kantaan (`admin_texts_import`, Bottiavustus/ylläpito) **ennen** mergeä.
3. Varatekstiin (`content/site-texts.fallback.json`) tulee vain kannassa jo oleva teksti (`site-texts-sync`).
4. Koodi lukee tekstin `tx()`:llä (build) tai kaupan `texts.tx()`:llä; puuttuessa ketju on site_text → palvelimen `message` → vanha yleisteksti.

Testit: `node --test booking/tests/sivutekstit.test.mjs booking/tests/sivutekstit-kauppa.test.mjs`; e2e: `booking/scripts/e2e-tuote7-kentat.mjs`, `booking/scripts/e2e-sivutekstit-kauppa.mjs` (rakentaa fixture-dist:n itse).
