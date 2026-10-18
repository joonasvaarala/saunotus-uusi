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
- **Tuontitiedosto** (PR 1, tuotu 18.10. → `content/site-texts.imported-pr61.json`, 1336 riviä, published v1) generoitiin koodista: `node scripts/site-texts-extract-shop.mjs --prod <public_get_site_texts-vastaus.json>`; mukaan vain avaimet, joita ei ole tuotannossa (ei ylikirjoitusta). Tuonti `admin_texts_import` ≤ 500 riviä/kutsu (`jq -c '[.[range(0;500)]]' …`, `range(500;1000)`, `range(1000;1500)`).
- **Peitto** (`applySiteTexts`, kutsutaan `applyShopTexts(S, …)`): kauppa-, tilaus- ja lahjakorttisivu lataavat `booking/site-texts.json`n ja peittävät sanakirjat DB-teksteillä. Saman kielen rivi puuttuu / paikkamerkki ei täyty / JSON virheellinen → repon oletusteksti **samalla kielellä** (ulkoasu ei muutu; en-sivulle ei koskaan fi-tekstiä). Osa 5 poistaa oletukset vasta kun avaimet on vahvistettu tuotannossa.
- Ei tuoda: `T.directionsUrl` (tekninen URL-polku), `gift-logic.js` SOURCE_LABELS (varaetiketti: nimet tulevat palvelimelta), ICS-tiedoston `LOCATION` (osoite; ei avainta lähdedatassa) ja `PRODID`/`UID` (tekninen), mock-/testitekstit, hallinnan (admin) käyttöliittymä.

## Staattisten sivujen tekstit (osa 3, PR 2): avaimet ja peitto

Etusivu, sivupohjat (sauna, hoidot, lahjakortti, varaa-info, info, yrityksille, ehdot, tietosuoja), kortit, kuvien alt-tekstit, navigaatio, alatunniste, SEO/meta ja Saunatietoa-osion kiinteät tekstit ovat edelleen repon JSON-tiedostoissa (`content/site.json` ui, `pages/*.json`, `cards.json`, `alts.json`, `articles.json` ui) = **varateksti**. `src/content-texts.mjs`:

- listaa jokaisen lehtitekstin avaimena (`collectContentDefaults`): `page.<sivu>.<polku>`, `seo.<sivu>.title|description`, `nav.main.<id>`, `nav.info.<id>`, `ui.site.*`, `ui.footer.*`, `ui.reviews.*`, `ui.training_banner.*`, `ui.articles.*`, `ui.card.<ryhmä>.<id>.<kenttä>`, `ui.alt.<kuva>`, `ui.session.<id>`. Etusivu = `front`, staattinen varaa-sivu = `booking_info` (kaupan `page.book.*` on jo tuotannossa kaupan teksteillä).
- peittää DB-tekstit samojen olioiden päälle rakennuksessa (`applyContentTexts`, kutsutaan `scripts/build.mjs`:ssä ja kaupan `build.mjs`:ssä heti `loadSiteTexts()`:n jälkeen), joten `render.mjs`/`articles/*` toimivat sellaisinaan eikä HTML muutu. Saman kielen rivi puuttuu → repon oletus (ei fi→en-ristiin). Paikkamerkki ei täyty → build kaatuu (§18.3, kuten ennenkin).
- **Tuontitiedosto** (tuotu 18.10., PR #64 → `content/site-texts.imported-pr64.json`; testit vertaavat ennen tuontia otettuun varatekstiin `tests/fixtures/site-texts/fallback-pre-pr64.json`): `node scripts/site-texts-extract-pages.mjs --prod <public_get_site_texts-vastaus.json>`; vain avaimet, joita ei ole tuotannossa; ei päällekkäisyyttä `imported-pr61`:n kanssa. Tuonti ≤ 500 riviä/kutsu (`range(0;500)`, `range(500;1000)`, `range(1000;1500)`).
- Paikkamerkit: `{n}` → `{{var:n}}` (peitto palauttaa `{n}`:n, sivupohja täyttää luvun), hinnat/kestot vain selvissä kohdissa (`{{price:48}}`, `{{price:49}}`, `{{duration:10|11|12}}`, `{{setting:customer_change_hours_before}}` kohdassa `page.info.cancel_text`; ks. `BINDINGS`). Muut summat/kellonajat jäävät tekstiin ja ovat `protected`.
- **HTML**: kantaan ei saa tuoda HTML:ää (booking_60). Info-sivun kuusi `<strong>`-kohtaa ovat kannassa muodossa `**lihavointi**` (kind `lite`); peitto muuntaa ne `<strong>`-merkinnäksi vain kentissä, jotka tulostetaan sellaisenaan (`info` p/note), ja kaikki muu `<`/`>` escapataan.
- Uudet `site.json`-kentät (tekstit ennallaan, aiemmin koodissa): `extraGuest`, `approx`, `directions`, `businessId`, `openInMaps`.
- Ei tuoda: tekniset kentät (img, og, url, to, kb, card, icon, id, show, policies, exact), käyttämättömät `ui`-kentät (`brandKicker`, `rights`, `externalNote`, `privateAndEvents`, `termsTitle`, `privacyTitle`, `privatePrompt`, `articles.pageTitle`, `articles.readArticleAbout`), pelkät numerot (vuosiluvut, "/ 5"), `articles.json` `label` (= `settings.articles_label_*`), testisivun `home.previewNote`, asiakasarvostelut (`reviews.json`), tuote-/kuvaus-/käytäntötekstit (`kb.json` → `product.*`, `policy.*`, `faq.*` … ovat jo lähdetaulusta), `contact` (osoite/puhelin/sähköposti ovat rakenteista dataa) ja JSON-LD/sitemap-merkkijonot.
- Kaupan datakuorma (`booking/site-texts.json`) sisältää vain kaupan `ui.*`-alueet (`SHOP_EXCLUDE` rajaa staattisen sivuston alueet pois).
- **`ui.shop.error_generic`**: palvelimen raaka `message` ei enää näy asiakkaalle kaupassa (`shop.js`, `order.js`, `mobilepay-ui.js`, `treatment-ui.js`); tunnetut koodit omilla teksteillään, muuten `T.<kieli>.errorGeneric` (= `ui.shop.error_generic`).

## Edge-funktioiden tekstit (osa 3, PR 3): sähköpostit, PDF:t, MobilePay-virhesivu

- **Avaimet:** `email.<pohja>.<kohta>` (`send-emails`: common, order_block, order_confirmation, payment_link, receipt, refund_receipt, cancel_request_ack, order_change, gift_card, voucher), `email.gift_card_pdf.*`, `email.receipt_pdf.*`, `ui.mobilepay.start_error_*` (maksulinkin GET-virhesivu ja JSON-`message`).
- **Oletukset = varateksti:** `booking/supabase/functions/<funktio>/texts.ts` (`EMAIL_TEXTS`, `GIFT_CARD_PDF_TEXTS`, `RECEIPT_PDF_TEXTS`, `MOBILEPAY_START_TEXTS`; `cls: "protected"` = suojattu luokka). Tuontitiedosto generoidaan niistä: `node scripts/site-texts-extract-functions.mjs --prod <tuore public_get_site_texts> --out content/site-texts.pending-import-3.json` (Node 22.18+; vain tuotannosta puuttuvat rivit).
- **Haku ajoaikana:** `_shared/site_texts.ts` – `fetchSiteTexts` (anon-avain, vain luku: `public_get_site_texts` + `public_settings`, 4 s aikaraja, 5 min välimuisti isolaatissa) ja `makeT` (DB-rivi → muuten repon oletus). Haku epäonnistuu / rivi puuttuu / DB-rivin paikkamerkki ei täyty → repon oletus (+ lokivaroitus), **raakaa `{{…}}` ei koskaan viestiin**. `send-emails` hakee tekstit vain kun jonossa on lähetettävää; `dry_run` ja muu lähetyslogiikka ennallaan.
- **Paikkamerkit:** `{{var:nimi}}` (koodi täyttää: name, no, amount, date, time, n, phone, email, from, who, when, label, what, code, id, ref, web, contact), `{{setting:business_name}}`. Yritysnimi/puhelin/osoite/sähköposti *arvot* tulevat koodin vakioista (kuten ennen), tekstissä vain lauseet. Teksti on aina escapattu (HTML) tai san()-siivottu (PDF, WinAnsi) – DB-teksti ei voi rikkoa viestiä eikä PDF:ää.
- **Ei HTML:ää kantaan:** rakenne (taulukot, painikkeet, lihavoinnit) on koodissa; kantaan vain tekstit.
- **Kuitti-PDF** tallennetaan Storageen ensimmäisellä haulla (muuttumaton tosite): tekstimuutos ei muuta jo luotuja kuitteja. Kuitin kentät ovat luokkaa `protected`.
- **Testit:** `node --test booking/supabase/functions/send-emails/templates.test.mjs booking/tests/sivutekstit-funktiot.test.mjs` (Node 22; 96 sähköpostitapausta samat tavut kuin ennen siirtoa: `send-emails/golden-email.json`), `deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/pdf-golden.test.ts booking/supabase/functions/_tests/site_texts_test.ts booking/supabase/functions/_tests/mobilepay_test.ts` (22 PDF-tapausta samat tavut: `pdf-golden.json`).
- **Tunnettu poikkeama oletuksissa:** FI-monikko "Lahjakorttit ovat valmiit" / "lahjakorttit toimitetaan" (oikein "Lahjakortit") on säilytetty sellaisenaan (tavu tavulta -vaatimus); korjaus kuuluu hyväksyntäprosessiin (`texts_propose`).
- Ei siirretty: raportti-PDF (`report-pdf`, sisäinen), `vismapay-start` (runko, ei asiakaskäytössä), tietokantafunktioiden tuottama teksti (kuitin `text_body`, MobilePay-maksun kuvaus `mobilepay_payment_prepare`, `email_outbox_claim`-data), kumppanien nimet ovat avaimina (`email.voucher.partner_*`) mutta samat FI/EN.

## Uuden tekstin lisääminen (§18.9, jokaisessa PR:ssä)

1. Avain `<alue>.<osa>.<nimi>` (virheet: `ui.<alue>.error_<RPC-koodi>`), FI + EN, luokka `normal`/`protected`.
2. Teksti **ei** mene koodiin. Lisää rivi tuontilistaan (esim. `content/site-texts.imported.json` on 18.10. tuotu erä) → tuonti kantaan (`admin_texts_import`, Bottiavustus/ylläpito) **ennen** mergeä.
3. Varatekstiin (`content/site-texts.fallback.json`) tulee vain kannassa jo oleva teksti (`site-texts-sync`).
4. Koodi lukee tekstin `tx()`:llä (build) tai kaupan `texts.tx()`:llä; puuttuessa ketju on site_text → repon oletus → `ui.shop.error_generic` (palvelimen raaka `message` ei koskaan asiakkaalle).

Testit: `node --test booking/tests/sivutekstit.test.mjs booking/tests/sivutekstit-kauppa.test.mjs booking/tests/sivutekstit-sivut.test.mjs`; e2e: `booking/scripts/e2e-tuote7-kentat.mjs`, `booking/scripts/e2e-sivutekstit-kauppa.mjs` (rakentaa fixture-dist:n itse).
