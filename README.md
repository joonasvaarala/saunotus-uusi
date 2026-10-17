# Sipoonjoen Perinnesauna – uusi sivusto (staattinen, FI/EN)

Kevyt staattinen kopio sivustosta https://uusi.saunotus.com (alkuperäinen on WordPress + Kadence + Elementor, ei Nuxt). Sisältöä ylläpitää Koodari. **Tämä on testiversio – ei tuotantokäytössä, ei hakukoneille (noindex).**

## Teknologiavalinta ja perustelut

Pieni oma Node-generaattori (`scripts/build.mjs` + `src/`), ei kehystä.

- **Nopeus:** 0 kB ajonaikaista kirjastoa. Sivut ovat esirenderöityä HTML:ää, CSS inline, fontit omasta palvelimesta (woff2, `font-display: swap`), kuvat avif/webp usealla leveydellä (`srcset`, `lazy`). Ainoa JS on 300 merkin rivi, joka korostaa viikko-ohjelmasta tämän päivän.
- **Yksinkertaisuus ja ylläpidettävyys:** ei Astro/Eleventy/Nuxt-versiopäivityksiä eikä riippuvuuspuuta. Ainoa kehitysriippuvuus on `sharp` (kuvien optimointi, ajetaan vain kun kuvat vaihtuvat). Rakennus tarvitsee vain Node 20:n.
- **Sisältö erillään koodista:** tekstit JSON-tiedostoissa, hinnat/ajat/tapahtumat Supabasen `kb`-snapshotissa. Koodari voi muokata tekstejä koskematta HTML-pohjiin.
- **Pienet tekniset kustannukset:** hostataan mihin tahansa staattiseen palveluun (GitHub Pages, Cloudflare Pages, Netlify, nginx).
- Hylätyt vaihtoehdot: Astro/Eleventy olisivat toimineet, mutta tässä koossa (9 sivua × 2 kieltä) generaattori on ~400 riviä, ja jokainen lisäosa olisi lisännyt ylläpitoa.

## Rakenne

```
content/
  site.json            yleiset asetukset, UI-tekstit (FI/EN), sivujen polut, yhteystiedot, chatbot-lippu
  pages/*.json         sivukohtaiset tekstit (fi + en samassa tiedostossa)
  reviews.json         Google-arvostelut (osio 'Arvostelut / Testimonials')
  cards.json           tuotekortit (viittaa kb-tuotteen slugiin; show/over ohjaa mitä kenttiä näytetään)
  kb/kb.json           Supabase kb -snapshot (vain julkiset kentät)
  alts.json            kuvien alt-tekstit (fi/en)
  images.manifest.json lähdekuvat → tulokuvat; images.json = generoidut mitat
  hero.json            etusivun herokuvan mitat (generoi scripts/optimize-hero.mjs)
src/
  lib.mjs              apufunktiot (escape, hinnat, kuvat, linkit)
  render.mjs           sivupohjat ja komponentit
  reviews-sort.mjs     arvostelujen lajittelu (uusin ensin, published)
  styles.css           tyylit (inline-minifioidaan rakennuksessa)
scripts/
  build.mjs            rakentaa dist/ (sivut, sitemap.xml, robots.txt, 404.html)
  check.mjs            linkki-, resurssi-, ankkuri-, alt-, title-tarkistus (--external: ulkoiset linkit)
  build-pages.mjs      GitHub Pages -koonti: perussivusto + varauskauppa (/varaa/) + hallinta (/hallinta/) yhteen dist/-kansioon
  smoke-pages.mjs      Playwright-savutesti alipolulle (/saunotus-uusi/): sivut, kauppa, hallinta, kutsun hyväksyntä (Supabase mockattu)
  serve.mjs            paikallinen esikatselu
  fetch-assets.mjs     lataa lähdekuvat live-sivustolta ja Johku-CDN:stä (assets-src/, ei gitissä)
  optimize-images.mjs  avif/webp + OG-kuvat → public/img
  optimize-hero.mjs    etusivun herokuva (ovi): desktop + mobiili avif/webp, OG-kuva ja content/hero.json (npm run hero)
  kb-snapshot.mjs      kb-vienti → content/kb/kb.json (allowlist)
  update-reviews.mjs   Google Places -arvostelut → content/reviews.json (npm run reviews:update)
public/                fontit, kuvat, favicon (kopioidaan sellaisenaan)
docs/kb-export.sql     SELECT-kysely snapshotin päivitykseen
.github/workflows/pages.yml  GitHub Pages -julkaisu (testi) + päivittäinen ajastettu rakennus
KORJAUSRAPORTTI.md     korjauslistan käsittely
```

## Ajaminen

```bash
npm install                 # vain jos kuvat ajetaan uudelleen (sharp)
npm run preview             # rakentaa testiversion → dist/, palvelee http://localhost:4173/
npm run build:test          # GitHub Pages -testi (SITE_ENV=test, osoite https://joonasvaarala.github.io/saunotus-uusi)
npm run build:prod          # tuotanto (canonical https://uusi.saunotus.com, indeksoitavissa, ei noindexia)
npm run check               # linkki-/resurssitarkistus dist/-kansioon (check:external tarkistaa myös ulkoiset)
```

Ympäristömuuttujat: `SITE_ENV=test` (noindex-meta + `robots.txt` Disallow), `SITE_URL=...` (ohittaa osoitteen), `DIST=...` (tulostekansio), `SAUNABOT=on` (chatbot päälle testissä).

## Sisällön muuttaminen

- **Teksti:** muokkaa `content/pages/<sivu>.json` (fi ja en) tai `content/cards.json` (kortit). Rakenna uudelleen.
- **Hinta, kesto, aukioloajat, tapahtumapäivät:** tulevat kb:stä. Älä kirjoita niitä käsin teksteihin. Päivitys: aja `docs/kb-export.sql` (vain SELECT) Supabasessa, tallenna tulos JSON:iin ja aja `node scripts/kb-snapshot.mjs export.json`. Tapahtumat, joiden päivä on mennyt, poistuvat sivulta automaattisesti rakennuksessa (ajastettu daily build).
- **Kortin poikkeama:** `cards.json`-kortin `over` ohittaa kb-kentän (esim. kesto "2–3 h"), `show` valitsee näytettävät kentät, `exact: true` näyttää hinnan ilman "alk.".
- **Uusi kuva:** lisää rivi `content/images.manifest.json`, aja `npm run assets && npm run images`, lisää alt-teksti `content/alts.json`.
- **Etusivun herokuva (ovi):** `<picture>`, jossa mobiili (<720 px, 4:5, `hero-ovi-uusi-mobiili-*`) ja desktop (leveä 2560x1200, `hero-ovi-uusi-*`), avif + webp, `object-position: center 40%`, media-ehdolliset preloadit (`heroPicture`/`heroPreload` in `src/lib.mjs`). Alt-tekstit: `content/alts.json` (`hero-ovi-uusi`). Uudet tiedostot: `HERO_DESKTOP=… HERO_MOBILE=… npm run hero` (lähdekuvat eivät ole repossa; tuottaa myös `og-hero-ovi-uusi.jpg` 1200x630). Kuvankäsittelyn muistiinpanot: lähde Google Drive > Okon kuvat kesä 2026 > `_DSC3826_SRGB_LARGE.jpg`. Tummennus: `.hero.home::after` (`src/styles.css`).
- **Varaus- ja kauppalinkit** osoittavat Johkuun (`https://sipoonjoenperinnesauna.johku.com/`). Johkua ei muuteta tästä repostosta; EN-sivut linkittävät `/en_US/`-polkuihin.

## Arvostelut / Testimonials

Asiakaskokemukset-osio rakennetaan Google-arvosteluista **rakennusvaiheessa puhtaana HTML+CSS:nä** (ei JS:ää, ei ulkoisia pyyntöjä sivua ladattaessa; ainoa ulkoinen asia on linkki Google-listaukseen). Ei schema.org Review/AggregateRating -merkintöjä (omien arvostelujen itse-merkintä on Googlen ohjeiden vastaista).

- **Data:** `content/reviews.json` → `place` (nimi, `rating`, `count`, `url`, `captured_at`), `min_per_lang` (3), `max_per_lang` (4), `reviews[]`: `{author, stars, lang: "fi"|"en", published, text}`. `published` on ISO-aikaleima (Places API:n `publishTime`); jos se on arvio (ei API:sta), mukana on `published_approx: true`, ja päivityskomento korvaa sen oikealla ajalla heti kun API palauttaa kyseisen arvostelun. Lista lajitellaan aina uusin ensin `published`-kentän mukaan (sekä päivityskomennossa että renderöinnissä; ilman `published`-arvoa oleva katsotaan uusimmaksi ja pysyy tiedostojärjestyksessä). Teksti tallennetaan **sanasta sanaan** (ei muokata, käännetä tai lyhennetä; emojit säilyvät). Suhteellisia päiväyksiä ("viikko sitten") ei tallenneta, vain `captured_at`. UI-tekstit: `content/site.json` → `ui.<kieli>.reviews`.
- **Säännöt (render.mjs `reviewsSection`):** sivun kielen mukaiset (`lang`), `stars >= 4`, teksti ei tyhjä, tiedoston järjestyksessä, enintään `max_per_lang`. Jos kielelle on alle `min_per_lang` arvostelua, **osiota ei renderöidä lainkaan** (nyt FI: 3 → näkyy, EN: 1 → ei näy, ennen kuin englanninkielisiä on lisätty ≥ 3). Yli 280 merkin tekstit rajataan CSS:llä (`line-clamp`, 5 riviä) ja avataan natiivilla `<details>` "Lue lisää" -napilla; koko teksti on aina DOM:ssa.
- **Suhteellinen aika:** jokaisen arvostelun nimen/Google-merkin vieressä on `<time datetime="YYYY-MM-DD" title="päivä">` ja suhteellinen ikä (FI: tänään, eilen, 3 päivää sitten, 2 viikkoa sitten, 1 kuukausi sitten, 1 vuosi sitten; EN vastaavasti). Säännöt: < 7 pv → päiviä (tänään/eilen), < 5 vk → viikkoja, < 12 kk → kuukausia, muuten vuosia. Lasketaan **rakennushetken** päivästä (Helsingin aika) `published`-kentästä, joten ajastettu päivittäinen rakennus pitää ne ajan tasalla. Myös arvioidut (`published_approx`) näytetään. Merkkijonot: `content/site.json` → `ui.<kieli>.reviews.age`. Testaus: `REVIEWS_NOW=2026-12-31 DIST=/tmp/x node scripts/build.mjs` ohittaa "tämän päivän".
- **Sijoitus:** etusivu (FI/EN) heti "Suosittelemme"-osion jälkeen, ennen "Mitä on saunotus?" -osiota; varaussivulla (`book`) kompakti versio (arvosana + 2 uusinta) varauslinkkirivin (Saunavuorot… ) alapuolella, ennen suositeltuja – ei varauspolun edellä.
- **Arvostelun lisääminen käsin:** kopioi uusin arvostelu Google-listauksesta (kirjautuneena näkyy enemmän kuin 5), lisää se `reviews`-listaan sanasta sanaan (`published` = julkaisupäivä ISO-muodossa, arvioituna lisää `"published_approx": true`; ilman sitä arvostelu näytetään uusimpana), päivitä `place.rating`, `place.count` ja `captured_at`. Rakenna uudelleen.
- **Päivityskomento:** `GOOGLE_PLACES_API_KEY=... npm run reviews:update` (`--dry-run` ei kirjoita). `GOOGLE_PLACE_ID` on valinnainen: jos sitä ei anneta, paikka haetaan Text Searchilla (`POST places:searchText`, kysely "Sipoonjoen perinnesauna Sipoo"), valitaan tulos jonka nimi sisältää "Sipoonjoen perinnesauna" ja löydetty id/nimi/osoite tulostetaan; jos osumaa ei ole, skripti päättyy selkeään virheeseen muuttamatta mitään. Hakee Places API (New) -rajapinnasta (`GET places/{id}`, kentät `rating,userRatingCount,reviews`) erikseen `languageCode=fi` ja `en`, päivittää `place.rating`/`count`, ja lisää **uudet** arvostelut (≥ 4 tähteä, teksti, `originalText.languageCode` fi/en, teksti = `originalText.text`, `published` = `publishTime`); koko lista lajitellaan uusin ensin, duplikaatit tunnistetaan tekijä + tekstin alku -avaimella eikä mitään koskaan poisteta. Jos mitään ei muutu, tiedostoon ei kosketa (ei aikaleimamuutoksia); arvosana/määrä kirjoitetaan vain jos ne muuttuivat. Onnistuneen ajon viimeinen rivi on `REVIEWS_CHANGED=<uusien arvostelujen määrä>` (0 = ei uusia; sopii ajastettuun ajoon: rakenna/julkaise vain kun > 0). Viikkoajo uudessa shellissä: `cd /workspace/saunotus-uusi && GOOGLE_PLACES_API_KEY=... npm run reviews:update`. Ilman avaimia skripti kertoo syyn ja poistuu muuttamatta mitään. **Huom:** Places API palauttaa enintään 5 arvostelua / kutsu, joten osio kasvaa ajan myötä ajamalla komentoa säännöllisesti; sitä voi täydentää myös käsin (ks. yllä).
- **Testaus:** `REVIEWS_FILE=/polku/kopio.json npm run build` käyttää vaihtoehtoista datatiedostoa (esim. kopio, jossa on 3 testi-EN-arvostelua), oikeaa tiedostoa ei muuteta.

## Chatbot-widget (valmius, POIS PÄÄLTÄ)

Upotus on HTML-kommenttina jokaisen sivun lopussa. Se ei lataa mitään. Käyttöönotto: `content/site.json` → `chatbot.enabled: true` (tai testissä `SAUNABOT=on npm run build`). Lisää silloin `<script src=".../saunabot/widget.js" defer>` ja `<div data-saunabot-quiz>`. **Ei tuotantoon** ennen OpenAI-avainta ja päätöstä.

## Testiversion julkaisu (GitHub Pages)

Osoitteet (testi, noindex kaikkialla – myös `/varaa/` ja `/hallinta/`):

| Osoite | Sisältö |
|---|---|
| https://joonasvaarala.github.io/saunotus-uusi/ | perussivusto (FI/EN); Johku-linkit korvattu sisäisellä varauskaupalla |
| https://joonasvaarala.github.io/saunotus-uusi/varaa/ (EN: `/en/book/`) | varauskauppa (Supabase `booking`-skeema) |
| https://joonasvaarala.github.io/saunotus-uusi/hallinta/ | hallinta (kirjautuminen, kutsun hyväksyntä, salasanan asetus) |

**Miten se toimii.** Workflow `.github/workflows/pages.yml` ajaa `node scripts/build-pages.mjs`, joka tuottaa YHDEN `dist/`-artifactin: kauppa-build (`booking/shop/build.mjs`) rakentaa koko perussivuston + kaupan, ja hallinta (`booking/admin` + `booking/shared/sb.js`) kopioidaan polkuun `hallinta/` generoidulla `config.js`:llä (`url` + julkinen avain). Kaikki polut lasketaan `SITE_URL`:in polusta (`/saunotus-uusi/`), joten linkit, importit ja `config.js` toimivat alipolulla. Skripti ajaa linkkitarkistuksen, varmistaa noindexin kaikilla sivuilla ja kieltäytyy `service_role`/`sb_secret`-avaimista (tarkistaa myös, ettei dist sisällä niitä).

| Tapahtuma | Mitä tapahtuu |
|---|---|
| `push` → `main`, `workflow_dispatch` main-haarasta, ajastus (03:15 UTC) | build + check + **deploy** (Pages-ympäristö `github-pages`) |
| `pull_request` (esim. PR #1, haara `booking`) | vain build + tarkistukset + yksikkötestit (CI-tarkistus), **ei deployta** |
| `workflow_dispatch` muusta haarasta | vain build, ei deployta |

Julkaisu siis tapahtuu vasta kun `booking`-haara on yhdistetty `main`iin (Pages-asetus: Settings → Pages → Source = GitHub Actions). PR:n esikatselua ei julkaista.

**Rakennusajan muuttujat** (workflow'n `env`): `SITE_ENV=test`, `SITE_URL=https://joonasvaarala.github.io/saunotus-uusi`, `BOOKING_SUPABASE_URL=https://sxbofnuisemspgquoxyv.supabase.co`, `BOOKING_ANON_KEY=<julkinen publishable-avain>`. Avain on frontend-avain ja saa olla repossa; **`service_role`-avainta ei koskaan** viedä workflow'hun, repoon tai frontendiin. Avaimen vaihto: muokkaa `BOOKING_ANON_KEY` workflow'ssa.

Paikallinen ajo ja savutesti:

```bash
SITE_ENV=test SITE_URL=https://joonasvaarala.github.io/saunotus-uusi BOOKING_SUPABASE_URL=https://<ref>.supabase.co \
  BOOKING_ANON_KEY=<publishable> node scripts/build-pages.mjs        # → dist/
# alipolun simulointi: palvele dist/ polun /saunotus-uusi/ alla (esim. python3 -m http.server kansiosta, jossa saunotus-uusi -> dist)
PW_DIR=<polku playwright node_modules> BASE_URL=http://127.0.0.1:4190/saunotus-uusi node scripts/smoke-pages.mjs
```

**Kuka asettaa mitä (kertaluonteisesti, ennen kuin kutsut toimivat):**

| Kuka | Mitä |
|---|---|
| Bottiavustus | ajaa migraation 10 (`20261016150010_booking_10_rls_initplan.sql`); halutessa deployaa `admin-users`-funktion uudelleen (ei pakollinen, ks. `booking/docs/bottiavustus-pyynto.md`) |
| Joonas (Supabase Dashboard) | Edge Function -salaisuudet: `INVITE_REDIRECT_URL=https://joonasvaarala.github.io/saunotus-uusi/hallinta/` ja `ALLOWED_ORIGINS` sisältämään `https://joonasvaarala.github.io` (vain origin, ei polkua; ei jokerimerkkiä) |
| Joonas (Supabase Dashboard) | Authentication → URL Configuration → *Redirect URLs*: lisää `https://joonasvaarala.github.io/saunotus-uusi/hallinta/` (muuten kutsulinkki ohjautuu Site URL:iin) |
| Joonas (GitHub) | Pages-lähteeksi *GitHub Actions* (jo asetettu); PR #1:n yhdistäminen `main`iin käynnistää julkaisun |

**Moduulien lataus (välimuisti).** GitHub Pages välimuistittaa tiedostoja noin 10 minuuttia, joten selain voi hetkellisesti yhdistää uuden `index.html`:n ja vanhan moduulin. Siksi `build-pages.mjs` lisää hallinnan kaikkiin importteihin ja resursseihin saman versiotunnuksen (`?v=<commit sha>`; yksi moduuli-instanssi per tiedosto). Lisäksi `admin.js` yrittää epäonnistuneen näkymämoduulin latausta kerran uudelleen cache-bust-parametrilla (`?r=…`); jos sekin epäonnistuu, näytetään virhe ja "Lataa uudelleen" -painike. Paikallisessa kehityksessä tunnus on tyhjä (tiedostot sellaisenaan).

Kutsun hyväksyntä: kutsusähköpostin linkki avaa `/hallinta/#access_token=…&type=invite`; hallinta ottaa istunnon talteen, siivoaa tunnisteen osoiteriviltä ja pyytää asettamaan salasanan.

## Päätökset ja rajaukset

- Hinnat ja ajat: kb (omistajan päätökset 9.–11.10.2026): la–su 14–19; Johkun hinnat oikein; hoidot vain Raunissa; hoitoja vain kolme (+ opiskelijahoito, saunotusrituaali, perinnesaunotus ryhmälle); lahjakortin jatko ilmainen.
- Sisäisiä (`internal=true`) policy-rivejä ja kb:n sisäisiä huomautuksia ei ole snapshotissa.
- Auki olevia omistajapäätöksiä ei arvata. Katso `KORJAUSRAPORTTI.md`.
- **EN-tekstit on käännetty/korjattu koneellisesti live-sivun pohjalta** ja kannattaa antaa natiivin tarkistettavaksi.
- Saavutettavuus: semanttinen HTML, skip-linkki, näkyvät fokukset, kontrastit ≥ 4,5:1, ulkoiset linkit merkitty ruudunlukijalle, valikko `<details>` (ei JS).
- SEO: title/description/canonical/hreflang (+ x-default), Open Graph (1200×630), JSON-LD (LocalBusiness), `sitemap.xml`, `robots.txt`, `404.html`.
- Tietosuoja: sivusto ei aseta evästeitä eikä lataa kolmansien osapuolten skriptejä (Johku/Instagram/Maps ovat vain linkkejä). Analytiikkaa ei ole lisätty.
- Repo sisältää julkisen kb-snapshotin ja korjausraportin (sisältää yrityksen sisäisiä viittauksia): **suosittele yksityistä repoa** tai poista KORJAUSRAPORTTI.md ennen julkistamista.
