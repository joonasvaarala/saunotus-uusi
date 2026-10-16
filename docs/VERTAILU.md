# Vertailu: alkuperäinen (uusi.saunotus.com) vs. uusi staattinen sivusto

Mitattu 16.10.2026 (Lighthouse 13.5, Chrome headless; uusi sivusto paikallisesta tuotantotyylisestä rakennuksesta, alkuperäinen livenä).

## Sivut

| Sivu | Alkuperäinen (WordPress/Elementor) | Uusi |
|---|---|---|
| Etusivu FI / EN | ✔ / ✔ | ✔ / ✔ |
| Saunavuorot, Hoidot ja rituaalit, Lahjakortit, Varaa, Info FI+EN | ✔ | ✔ |
| Yritykset FI+EN | ✔ | ✔ |
| Ehdot FI+EN, Tietosuoja FI | – (Johkussa) | lisätty (kb.policies, ei internal) |
| 404, sitemap.xml, robots.txt, hreflang, OG-kuvat, JSON-LD | osin | ✔ |

Uusi sivusto: 18 HTML-sivua (9 sivua × FI/EN, ei EN-tietosuojaa) + 404.

## Linkit ja kuvat

- `npm run check`: 1122 sisäistä viitettä (linkit, kuvat, srcset, fontit, ankkurit), 0 rikkinäistä; kaikilla kuvilla `alt` ja mitat; yksilölliset title/description; yksi h1 per sivu.
- Ulkoiset linkit (77): Johku, Instagram/Facebook/YouTube, Maps, HSL, Elämyslahjat. Johku vastaa botille ajoittain 403 (nopeusrajoitus); uudelleenyrityksillä kaikki 69 Johku-osoitetta 200, paitsi kaksi tuotesivua, jotka palauttavat 404 (opiskelijahoito FI+EN; perinnesaunotus ryhmälle EN; yritysten jälkilöylyt EN). Näihin linkitetään Johkun listaussivulle (ks. KORJAUSRAPORTTI #58, #19).
- Alkuperäisen EN-sivun Johku-linkit käyttivät osin eri slugeja (esim. /en_US/public-sauna/peat-thursday); uusi sivusto käyttää kb:n tuoteosoitteita (en_US-versio), jotka tarkistettiin yksitellen.
- Kuvat: kaikki avif/webp-muodossa useina leveyksinä, 8,2 MB yhteensä kaikissa leveyksissä; yksittäinen sivu lataa 0,2–0,6 MB.

## Lighthouse

| Sivu | Suorituskyky mobiili | desktop | Saavutettavuus | Parhaat käytännöt | SEO | Siirto | Pyyntöjä |
|---|---|---|---|---|---|---|---|
| Alkuperäinen etusivu | 59 | 89 | 92 / 89 | 73 | 61 | 2,2 MB | 146 |
| Alkuperäinen saunavuorot | 66 | 89 | 95 | 73 | 61 | 0,9 MB | 84 |
| **Uusi etusivu** | **96** | **100** | 100 | 100 | 100 | 0,34 MB (mob) | 19 |
| Uusi saunavuorot | 96 | 100 | 100 | 100 | 100 | 0,36 MB | 14 |
| Uusi hoidot ja rituaalit | 97 | 100 | 100 | 100 | 100 | 0,35 MB | 13 |
| Uusi lahjakortit | 99 | 100 | 100 | 100 | 100 | 0,40 MB | 15 |
| Uusi info | 97 | 100 | 100 | 100 | 100 | 0,24 MB | 13 |
| Uusi etusivu EN | 96 | 100 | 100 | 100 | 100 | 0,34 MB | 19 |

Alkuperäisen LCP mobiilissa 6,5–7,8 s, uuden 2,1–2,6 s. Huom.: uuden sivuston SEO-pisteet mitattiin tuotantotilassa (ilman noindexia); testiversio on tarkoituksella `noindex`.

## Sisältöerot (tarkoituksellisia)

- Hinnat/ajat kb:stä ja omistajan päätösten mukaan (ei 14.30, ei Lovi, ei lopetettuja lisähoitoja, ei väärää alk.-hintaa).
- Ei Instagram-feediä upotettuna (vain linkki), ei Elementor/WP-skriptejä, ei evästebanneria (ei evästeitä).
- Johku-upotukset korvattu linkeillä Johkun kauppaan (upotuksia ei ollut saatavilla ilman WP-pääsyä).
