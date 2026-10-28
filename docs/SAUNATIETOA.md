# Saunatietoa – sisältöosio (julkinen puoli)

Työnimi **Saunatietoa** (FI `/saunatietoa/`, EN "Sauna knowledge" `/en/sauna-knowledge/`). Artikkelit kirjoitetaan ja tallennetaan botilla tietokantaan (`booking.articles`, sopimus §16 tiedostossa `KOODARI_talous_A_D_fi.md`). Sivusto ei sisällä editoria. Tämä dokumentti kuvaa vain julkisen sivuston: miten artikkelit haetaan, esirenderöidään ja päätyvät sivulle.

## Periaate

- Kaikki sivut ovat **esirenderöityjä staattisia HTML-tiedostoja** (ei hash-reittejä, ei selaimessa ajettavaa hakua). Listaus, tagisivut, artikkelit, siirretyn slugin ohjaussivut, sitemap ja robots syntyvät `scripts/build.mjs`-rakennuksessa.
- Rakennus hakee artikkelit RPC:illä `public_list_articles`, `public_get_article`, `public_articles_sitemap`, `public_articles_redirects` (skeema `booking`, `content-profile: booking`). Käytössä on vain julkinen anon/publishable-avain, sama kuin repon nykyisessä konfiguraatiossa (`BOOKING_SUPABASE_URL`, `BOOKING_ANON_KEY`). `sb_secret_`- ja `service_role`-avaimet hylätään rakennuksessa. Repoon ei tallenneta salaisuuksia. Sivusto vain **lukee** tietokantaa; `public`-skeemaan ei kosketa.

## Nimi ja polut yhdessä paikassa

`content/articles.json`: `label` (FI/EN nimi), `path` (FI/EN polku), `tagSegment`, `pageSegment`, `pageSize`, `widths`, `nav.showWhenEmpty` ja kaikki UI-tekstit. Nimen tai polun vaihto = muokkaa tiedostoa ja rakenna uudelleen. Sivuston URL:t lasketaan aina tämän tiedoston ja `SITE_URL`:in perusteella. Tietokannan palauttamia isäntänimiä tai polkuja ei käytetä. Jos tietokannan `booking.settings`-arvot `articles_path_*` / `articles_label_*` poikkeavat, rakennus kirjoittaa varoituksen. Pidä ne samoina. Tuotannossa: FI "Saunatietoa" `/saunatietoa/`, EN "Sauna knowledge" `/en/sauna-knowledge/`.

## Miten uusi artikkeli päätyy sivulle

1. Botti tallentaa ja julkaisee artikkelin (`status = published`, `published_at <= now()`).
2. Sivusto rakennetaan uudelleen ja deployataan **main-haarasta** workflow'lla `.github/workflows/pages.yml`. Käynnistäjiä on neljä:
   - `repository_dispatch` tyyppiä `articles-changed`. Botti tai tietokannan webhook kutsuu `POST /repos/joonasvaarala/saunotus-uusi/dispatches` bodyllä `{"event_type":"articles-changed"}`. Kutsu vaatii tokenin, jolla on oikeus Actionsiin (`gh api repos/joonasvaarala/saunotus-uusi/dispatches -f event_type=articles-changed`).
   - `workflow_dispatch` käsin: `gh workflow run pages.yml --ref main`.
   - **Tunneittainen ajastus** (`15 * * * *`). Tämä toimii varmistuksena ja hoitaa ajastetut julkaisut (`published_at` tulevaisuudessa). Viive on enintään tunti, vaikka kukaan ei kutsuisi mitään.
   - `push` → `main` (koodimuutokset).
3. Build hakee julkaistut artikkelit, tekee kuvista avif/webp-versiot (`sharp`), kirjoittaa sivut, sitemapin ja tarkistaa tuloksen (`scripts/check.mjs` + `scripts/check-articles.mjs`). Rikkinäinen sisäinen linkki artikkelissa tai virheellinen JSON-LD pysäyttää deployn (ei tuhoa vanhaa julkaisua).

Tuotantojulkaisua ei tehdä tässä työssä. Testisivusto (GitHub Pages, `SITE_ENV=test`) on noindex.

## Blogisarja ennen tietokantatuontia

Kuusi suomenkielistä artikkelia on tiedostossa `content/articles.pending-import-blogisarja.json`. Rakennus **ei kirjoita tietokantaan**. Kun `ARTICLES_FIXTURE` ei ole päällä ja julkinen RPC ei vielä palauta slugia, rakennus liittää artikkelin mukaan listaukseen, sivuksi ja sitemapiin ja varoittaa. Silloin suomen `publishedArticleCount` on suurempi kuin nolla, ja etusivun Saunatietoa-nauha (linkki listaukseen, ei artikkelikortteja) renderöityy. Kun sama slug on julkaistu (`public_get_article`), tietokannan teksti voittaa. Jos artikkeli myöhemmin piilotetaan tietokannassa, poista se myös tästä tiedostosta. Muuten rakennus näyttää sen uudelleen.

**Osoite pysyy slugissa.** Nykyinen polku on `/saunatietoa/<slug>/` (testisivusto `https://joonasvaarala.github.io/saunotus-uusi/saunatietoa/<slug>/`). Tuotannon canonical on `https://saunotus.fi/saunatietoa/<slug>/`, koska `SITE_URL` on siellä `https://saunotus.fi`. Testisivuston canonical on testisivuston oma osoite (sivut ovat `noindex`). Jos osio myöhemmin siirtyy toisen polun alle, vanha polku lisätään `content/articles.json` → `legacyPaths`-listaan. Silloin rakennus tekee ohjaussivut. Slugia ei vaihdeta.

**Kuvat.** Tiedostot ovat kansiossa `content/article-images/`. Pääkuva on `<slug>-hero.jpg` ja `<slug>-hero.webp`. Välikuva, jos artikkelilla on sellainen, on `<slug>-2.jpg` ja `<slug>-2.webp` (savusaunan-loyly: vain pääkuva). Rakennus kopioi ne osoitteeseen `/img/articles/` samalla nimellä. Sivulla `<picture>` tarjoaa webp-version ja jpg-varakuvan, `width`/`height` mukana. Pääkuva ladataan heti, välikuva laiskasti. Välikuva tulee tekstin puoliväliin. Alt-teksti on tuontitiedoston `images[].alt_fi`. Rakennus lukee pikselikoon jpg-tiedostosta. Paikallinen pääkuva peittää tietokannan pääkuvan niin kauan kuin tiedosto on kansiossa. Tietokantaan viedään hero-jpg (Storage, enintään 5 Mt). Välikuva jää repossa olevaksi tiedostoksi.

**Tuonti hallintaan** (ylläpitäjä, ei CI): jokaiselle artikkelille `admin_upsert_article(null, upsert)` luonnoksena, lataa hero-jpg Storageen polkuun `articles/<id>/<aikaleima>-<tunnus>.jpg`, kutsu `admin_register_article_image(..., alt_fi, p_set_hero := true)` ja `admin_publish_article(id, publish_at)`. Kentät `publish_at`, `source_url` ja `images` eivät kuulu `upsert`-objektiin. `source_url` on Instagram-lähde, eikä sitä renderöidä sivulle. Tarkat arvot ja järjestys ovat tuontitiedoston `_doc`-kentässä.

## Vikasietoisuus

- RPC ei vastaa tai palauttaa virheen: build **ei kaadu**. Se käyttää edellistä snapshotia (`.cache/articles/snapshot.json`, CI:ssä `actions/cache`). Jos snapshotia ei ole, RPC:stä tulevat artikkelit jäävät pois ja rakennus varoittaa. Tuontitiedoston slugit liitetään silti mukaan (ks. yllä), ja etusivun nauha näkyy kun niitä on. Per artikkeli sama: yksittäisen artikkelin haun epäonnistuessa käytetään sen edellistä versiota.
- `ARTICLES_STRICT=1` tekee RPC-virheestä rakennusvirheen (esim. kun halutaan varmistaa tuotantodeploy).
- Sitemap: jos `public_articles_sitemap` ei vastaa, rivit johdetaan haetuista artikkeleista.
- Nav-linkki (FI/EN) näytetään vain, kun julkaistuja artikkeleita on (§16.6). `nav.showWhenEmpty` voi pakottaa sen näkyviin. Tyhjä listaus on siisti ("Artikkeleita julkaistaan pian") ja `noindex`, eikä se ole sitemapissa.

## Siirretyt slugit (redirect)

Rakennus hakee kaikki slug-ohjaukset **yhdellä kutsulla**: `public_articles_redirects()` (booking_55, sopimus §16.3) palauttaa `{ok, items:[{lang, from_slug, from_path, from_loc, to_slug, to_path, to_loc, status:301}]}`. Rivi on vain julkiselle artikkelille ja osoittaa suoraan nykyiseen slugiin (ei ketjuja); luonnokset, poistetut, ajastetut ja vaillinaiset kieliversiot eivät vuoda. Sivusto käyttää riveistä vain `lang`, `from_slug` ja `to_slug` (polut ja isäntänimet lasketaan repon asetuksista) ja ohittaa virheelliset rivit, omat osoitteet ja duplikaatit. Jokaiselle riville generoidaan ohjaussivu: `<meta http-equiv="refresh" content="0; url=…">`, `rel=canonical` uuteen osoitteeseen, näkyvä linkki, ei sitemapissa.

**Varakeino** (kun `public_articles_redirects` ei vastaa tai palauttaa virheen; rakennus varoittaa): tunnetut slugit (edellisen onnistuneen haun snapshot `.cache/articles/snapshot.json`, `content/articles-slugs.json`, edellisen haun RPC-ohjaukset) kysytään yksitellen `public_get_article`-RPC:llä (`moved` → ohjaussivu). Jos koko RPC on poissa, käytetään edellisen snapshotin ohjauksia. RPC:n antamat vanhat slugit tallentuvat snapshotin `known`-listaan, joten varakeino toimii myös ilman committattua listaa.

**Vanha osion polku:** `content/articles.json` → `legacyPaths` (nyt `en: ["/en/sauna-guide/"]`, joka oli ensimmäisen version EN-polku). Sille generoidaan ohjaussivut nykyiseen osoitteeseen: listaus, jokainen julkaistu artikkeli ja vanhat slugit (suoraan nykyiseen). `check-articles.mjs` varmistaa, että legacy-polun sivut ovat pelkkiä ohjaussivuja. Sivutus- ja tagisivuja legacy-polulle ei ohjata. Poista legacy-polku listasta, kun sitä ei enää tarvita.

## Etusivun nauha

Etusivulla (FI `/`, EN `/en/`) **Saunatietoa** / **Sauna knowledge** on kompakti nauha: lyhyt teksti ja linkki listaukseen (`/saunatietoa/`, EN `/en/sauna-knowledge/`). Artikkelikortteja ei upoteta etusivulle. Nauha renderöidään vain, kun kyseisellä kielellä on julkaistuja artikkeleita (sama laskuri kuin valikon linkillä, `publishedArticleCount`). Tyhjä lista ei lisää nauhaa eikä osoitetta etusivulle. Nauhan teksti on sivuteksti `ui.site.home_info_lead` (varateksti `src/home-front.mjs`, tuonti `content/site-texts.pending-import-85.json`).

Kolmen uusimman artikkelin korttirenderöinti (`homeSectionHtml`, `pickHomeItems`) jää käyttöön listauksen ja testien tarpeisiin, mutta `R.home()` ei upota sitä eikä etusivulle tule `src/articles/home.css`. `scripts/check-articles.mjs` vaatii nauhan listauslinkin, kun kielellä on artikkeleita, eikä salli vanhaa korttiosiota (`home-art`) kun artikkeleita ei ole. Valikon linkki noudattaa edelleen `nav.showWhenEmpty`.

**Esikatselu testisivustolla:** kun `SITE_ENV=test`, build luo yhä noindex-sivut `/esikatselu/etusivu-artikkelit/` ja `/en/preview/home-articles/` (ei sitemapissa). Ne ovat sama lyhyt etusivu, eivät kolmea feikkikorttia.

## Ympäristömuuttujat

| Muuttuja | Merkitys |
|---|---|
| `SITE_ENV=test` | noindex,nofollow + robots Disallow kaikkialla. Tuotannossa (ei `test`) käytetään `seo.robots`-asetusta. |
| `SITE_URL` | canonicalien, hreflangien, OG-kuvien ja sitemapin juuri |
| `BOOKING_SUPABASE_URL`, `BOOKING_ANON_KEY` | RPC-osoite ja julkinen avain (CI:ssä jo `pages.yml`:ssä) |
| `ARTICLES_FIXTURE=1` tai polku JSON:iin | käyttää fixture-dataa (ei verkkoa), esim. `tests/articles/fixtures/rpc.json` tai `rpc-empty.json` |
| `ARTICLES_STRICT=1` | RPC-virhe pysäyttää rakennuksen |
| `ARTICLES_IMAGES=0` | ohita kuvien muunnos (nopea paikallinen build) |
| `ARTICLES_CACHE_DIR` | snapshotin ja kuvavälimuistin sijainti (oletus `.cache/articles`, gitignoressa) |

## Sivut ja SEO

- Listaus (sivutus 12/sivu), tagisivut (`/saunatietoa/tagi/<tagi>/`, noindex, ei sitemapissa), artikkeli.
- Artikkelissa: `<title>`/description, `canonical` (RPC:n `canonical_url`-ylikirjoitus huomioidaan), `hreflang` fi/en/x-default vain kun käännös on olemassa, Open Graph + Twitter-kortti (`og:type=article`, `article:published_time`, tagit), JSON-LD `Article` (headline, datePublished/dateModified, image, author, publisher, inLanguage, mainEntityOfPage) ja `BreadcrumbList`, `<` escapataan JSON-LD:ssä.
- Markdown (§16.2) renderöidään omalla turvallisella renderöijällä: kaikki HTML escapataan, vain turvalliset linkit (`https:`, `mailto:`, sisäiset polut), `img:<id>`-viittaukset artikkelin kuviin, `:::cta`-lohko varauskutsulle ja `:::author`-lohko kirjoittajalaatikolle. H2 "Usein kysyttyä" ja sen jälkeiset H3-kysymykset tuottavat myös JSON-LD `FAQPage`-lohkon. Jakaminen on vain `mailto:`-linkki (ei kolmannen osapuolen skriptejä).
- Kuvat: `<picture>` avif + webp, `srcset` 480/800/1200/1600 (ei suurempaa kuin alkuperäinen), `sizes`, `width`/`height`, `alt`, `loading=lazy` (hero eager + `fetchpriority=high`). Jos `sharp` puuttuu tai kuvan lataus epäonnistuu, käytetään alkuperäistä Storage-URL:ia.
- Varauskutsu (CTA) artikkelin lopussa linkittää varauskauppaan (`/varaa/`, `/en/book/`).
- Sitemap: olemassa oleva `sitemap.xml` + artikkelirivit (`hreflang`-alternates, `lastmod`). Robots kuten muualla (`SITE_ENV`).

## Testit ja tarkistukset

```
npm ci
node --test tests/articles/*.test.mjs            # markdown, lähde/RPC/cache, sivupohjat, build-check (mutaatiotestit)
ARTICLES_FIXTURE=1 SITE_ENV=test SITE_URL=http://localhost:4180 DIST=/tmp/d node scripts/build.mjs
DIST=/tmp/d SITE_ENV=test SITE_URL=http://localhost:4180 node scripts/check-articles.mjs
node scripts/serve.mjs /tmp/d 4180 &             # + selaintarkistus ja kuvakaappaukset:
PW_DIR=<playwright node_modules> node scripts/articles-shots.mjs
```

`scripts/check-articles.mjs` validoi dististä JSON-LD:n, canonicalit, hreflangit (vastavuoroisuus), sitemapin, robotsin, kuvien mitat/alt-tekstit, ohjaussivut ja navigaation. `scripts/articles-shots.mjs` mittaa selaimessa vaakavierityksen (360/390/430/768/1024/1280), kosketuskohteet (≥44 px), kontrastin (≥4,5:1), otsikkohierarkian ja kuvien latautumisen sekä tallentaa kuvakaappaukset.

Testidata: `docs/saunatietoa-testidata.sql` luo feikkiartikkelit **vain testiprojektiin** (`jztczwrqtnpuolhcmktb`; vaatii migraation booking_51). Tuotantoon ei kirjoiteta.

## Koodikartta

`content/articles.json` (asetukset) · `content/articles.pending-import-blogisarja.json` (tuonti, ei tietokantakirjoitusta) · `content/article-images/` (paikkakuvat) · `src/articles/` (`config`, `source` RPC + cache, `pending`, `markdown`, `images`, `pages`, `index`, `articles.css`, `home.css` etusivun osio, `runtime`) · `src/render.mjs` (`layout()`: SEO-ylikirjoitukset, nav) · `scripts/build.mjs` (kytkentä, sitemap) · `scripts/check-articles.mjs`, `scripts/articles-shots.mjs` · `tests/articles/`.
