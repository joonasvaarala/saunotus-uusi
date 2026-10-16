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
  cards.json           tuotekortit (viittaa kb-tuotteen slugiin; show/over ohjaa mitä kenttiä näytetään)
  kb/kb.json           Supabase kb -snapshot (vain julkiset kentät)
  alts.json            kuvien alt-tekstit (fi/en)
  images.manifest.json lähdekuvat → tulokuvat; images.json = generoidut mitat
src/
  lib.mjs              apufunktiot (escape, hinnat, kuvat, linkit)
  render.mjs           sivupohjat ja komponentit
  styles.css           tyylit (inline-minifioidaan rakennuksessa)
scripts/
  build.mjs            rakentaa dist/ (sivut, sitemap.xml, robots.txt, 404.html)
  check.mjs            linkki-, resurssi-, ankkuri-, alt-, title-tarkistus (--external: ulkoiset linkit)
  serve.mjs            paikallinen esikatselu
  fetch-assets.mjs     lataa lähdekuvat live-sivustolta ja Johku-CDN:stä (assets-src/, ei gitissä)
  optimize-images.mjs  avif/webp + OG-kuvat → public/img
  kb-snapshot.mjs      kb-vienti → content/kb/kb.json (allowlist)
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
- **Varaus- ja kauppalinkit** osoittavat Johkuun (`https://sipoonjoenperinnesauna.johku.com/`). Johkua ei muuteta tästä repostosta; EN-sivut linkittävät `/en_US/`-polkuihin.

## Chatbot-widget (valmius, POIS PÄÄLTÄ)

Upotus on HTML-kommenttina jokaisen sivun lopussa. Se ei lataa mitään. Käyttöönotto: `content/site.json` → `chatbot.enabled: true` (tai testissä `SAUNABOT=on npm run build`). Lisää silloin `<script src=".../saunabot/widget.js" defer>` ja `<div data-saunabot-quiz>`. **Ei tuotantoon** ennen OpenAI-avainta ja päätöstä.

## Päätökset ja rajaukset

- Hinnat ja ajat: kb (omistajan päätökset 9.–11.10.2026): la–su 14–19; Johkun hinnat oikein; hoidot vain Raunissa; hoitoja vain kolme (+ opiskelijahoito, saunotusrituaali, perinnesaunotus ryhmälle); lahjakortin jatko ilmainen.
- Sisäisiä (`internal=true`) policy-rivejä ja kb:n sisäisiä huomautuksia ei ole snapshotissa.
- Auki olevia omistajapäätöksiä ei arvata. Katso `KORJAUSRAPORTTI.md`.
- **EN-tekstit on käännetty/korjattu koneellisesti live-sivun pohjalta** ja kannattaa antaa natiivin tarkistettavaksi.
- Saavutettavuus: semanttinen HTML, skip-linkki, näkyvät fokukset, kontrastit ≥ 4,5:1, ulkoiset linkit merkitty ruudunlukijalle, valikko `<details>` (ei JS).
- SEO: title/description/canonical/hreflang (+ x-default), Open Graph (1200×630), JSON-LD (LocalBusiness), `sitemap.xml`, `robots.txt`, `404.html`.
- Tietosuoja: sivusto ei aseta evästeitä eikä lataa kolmansien osapuolten skriptejä (Johku/Instagram/Maps ovat vain linkkejä). Analytiikkaa ei ole lisätty.
- Repo sisältää julkisen kb-snapshotin ja korjausraportin (sisältää yrityksen sisäisiä viittauksia): **suosittele yksityistä repoa** tai poista KORJAUSRAPORTTI.md ennen julkistamista.
