# kb ↔ Johku -ristiriidat, vuorosääntöjen tulkinnat ja avoimet kysymykset

Periaate: **kb on totuus**. Kun Johku ja kb eroavat, järjestelmä noudattaa kb:ta (hinnat luetaan suoraan kb:stä); alla ristiriidat, jotka Joonaksen pitää vahvistaa. Sääntödata on `supabase/migrations/…_08_seed_rules.sql`.

## A. Ristiriidat kb ↔ Johku (havaittu)

| # | Asia | kb | Johku | Mitä tein |
|---|---|---|---|---|
| 1 | Tunnin vuoro (la–su 14 ja 18) paikat | omistajan ohje: 6 hlöä sisällä | resurssi "Tunnin vuoro 1800": 10 paikkaa | 6 (jakaa viikonlopun 6 hengen poolin) |
| 2 | Viikonlopun yleisten vuorojen tarkat alkuajat | vain "klo 14–19, saunomisaika 2 h" | 14:00, 14:30, 15:00, 16:00, 16:30, 17:00 (+ 15:30 vain kesä 2026) | Johkun ajat käytössä; 15:30 vain 13.6.–31.8.2026 (`valid_from/to`) |
| 3 | Hintarivien "sisältää N hlöä" (yksityisvuoro, jälkilöylyt) | arvo tyhjä (`included_persons` NULL) | 8 tai 11 (rivistä riippuen) | oletus 8 yksityisvuorolle (kb 25) ja 6 jälkilöylyille (kb 26, 49) – **vahvista** |
| 4 | Perjantain Jälkilöylyt | kb:ssä pe-variantti (19–22) | aloitusaika vain yksittäiselle päivälle 16.1.2026 | sääntö pe 19–22 luotu kb:n mukaan |
| 5 | Uudenvuodenaatto 31.12.2026 -variantti | variantti olemassa | ei aloitusaikaa | sääntö luotu mutta **ei käytössä** (`active=false`) |
| 6 | Myynnin sulkeutumisajat (`deadline_minutes`) | – | Johku: tuote 132 → 15 min, 152 → 30 min, 16 → 12 h, 17 → 24 h; muille ei tietoa | nuo käytössä; ma–ke-vuorot 0 min, jälkilöylyt 2 h ovat **oletuksia** |
| 7 | Morsiussauna | alkaen 390 € | 549 € | ei ole kaupan tuotekonfiguraatiossa (ei varattavissa verkossa); kb on totuus, hinta tarkistettava |
| 8 | Johkun "ma–to 3 h" -hintarivi sisältää myös perjantain | – | kyllä | sääntö ma–pe 16–19 yksityisvuorolle (vastaa Johkua) |
| 9 | Yksityisvuoron enimmäishenkilömäärä | ei määritelty | – | oletus 16 (sama kuin yleinen) |

## B. Vuorosääntöjen tulkinnat

1. **Yksityisvuoro vs. yleinen vuoro** – eivät voi olla yhtä aikaa (vaatimus B). Toteutettu DB-tasolla (ks. README). Yksityinen varaus poistaa päällekkäiset yleiset vuorot myynnistä; yksikin yleisen vuoron varaus estää päällekkäisen yksityisvuoron. Myös odottava (maksamaton, pito voimassa) varaus estää, vanhentunut ei.
2. **Viikonloppu: "6 henkilöä sisällä yhtä aikaa", vuorot 2 h ja alkavat 14:00, 14:30, 15:00 …** – tulkinta: kapasiteetti on **samanaikaisten henkilöiden määrä** kaikkien päällekkäisten vuorojen yli (esim. 14:00-vuoro 3 hlö + 14:30-vuoro 3 hlö = 6 sisällä klo 14:30–16:00 → 15:00-vuoro on täynnä). Vuoro, jonka alkaessa edellinen on päättynyt (esim. 16:00 vs 14:00-vuoro) vapauttaa paikat. Tunnin vuorot (14, 18) jakavat saman poolin. **Vaihtoehtoinen tulkinta**: "6 per alkamisaika" (jokaisella alkamisajalla oma 6 hengen kiintiö) – silloin sama sauna olisi 6+6+… yhtä aikaa. → **Avoin kysymys 1.**
3. **Torstai** – turvesauna 16–17 (max 8) ja yleinen vuoro 17–19; **yhteensä max 16** turvesaunalaiset mukaan lukien. Toteutus: turvetorstain tuote kuluttaa kaksi poolia (`yleinen_arki` 16 + `turve` 8) ajalle 16–19; torstain yleinen vuoro 17–19 käyttää `yleinen_arki`-poolia → turvesaunalaiset vähentävät yleisen vuoron paikkoja.
4. **ma–ke** 16 hlöä / vuoro (ma miehet, ti naiset, ke hiljainen).
5. **Maksamattomat pidot**: 15 min (asetus). `pay_later`-tilassa pitoa ei tarvita (vahvistuu heti).
6. **Hinnoittelutavat**: `per_person` (kb-hinta × hlömäärä), `fixed` (kiinteä), `fixed_plus_extra` (perushinta sisältää N hlöä + lisähenkilömaksu). Hinnat luetaan live kb:stä; hinnanmuutos ei muuta vanhoja tilauksia (rivihinta tallennetaan).

## C. Avoimet kysymykset Joonakselle

1. **Viikonlopun kapasiteetti**: onko 6 = samanaikaisia henkilöitä kaikissa limittäisissä vuoroissa (nykyinen toteutus), vai 6 / alkamisaika? Tai onko tarkoitus että limittäiset vuorot ovat eri saunakierroksia?
2. **Yksityisvuoron enimmäishenkilömäärä** ja hinnan "sisältää" -rajat (8? 6?) sekä lisähenkilön hinta kaikille variantteille.
3. **Myynnin sulkeutumisajat** (deadline) jokaiselle tuotteelle: kuinka pitkään ennen vuoroa verkosta saa varata (nyt yleiset 15–30 min; yksityisvuorot 12 h; jälkilöylyt 2 h; yritys 24 h)?
4. **Peruutusehdot verkossa**: saako asiakas peruuttaa itse vahvistetun varauksen (nyt vain maksamattoman pidon voi peruuttaa itse; vahvistetun peruu henkilökunta)?
5. **Maksutapa alkuvaiheessa**: jatketaanko `pay_later` (maksu paikan päällä) kunnes Visma Pay on valmis? Vai otetaanko käyttöön vasta kun verkkomaksu toimii?
6. **Henkilökunnan oikeudet**: saako staff muokata hintoja? (Ehdotus: ei, vain admin. Ks. roolit-ja-kb.md.)
7. **Sähköpostivahvistukset**: millä palvelulla (SMTP/Resend/Supabase)? Tarvitaan ennen tuotantokäyttöä – nyt vahvistus näkyy vain sivulla.
8. **Yritysvuorot ja jälkilöylyt** verkkoon heti vai vain tarjouspyyntönä (nyt mukana kaikki 10 savusaunatuotetta; `bookable`-lippu hallinnasta).
9. **Englanti**: tuotteiden `name_en/description_en` puuttuvat osin kb:stä – täydennetäänkö ennen julkaisua?
10. **Hoidot / tapahtumat / lahjakortit**: aikataulu seuraaville vaiheille ja se, linkittyvätkö ne tilapäisesti vielä Johkuun (nyt hoito- ja tapahtumatuotteet näyttävät "ota yhteyttä", lahjakortit/yritykset-linkit jäävät Johkuun).
11. **Markkinointilupateksti**: lopullinen teksti (nyt versio `v1`: "Haluan vastaanottaa … uutiskirjeitä ja tarjouksia") ja milloin tuodaan Johku-luvat (`allowmarketing=1`).
12. **Tuotantojulkaisun portti**: käytetäänkö hallinnalle erillistä osoitetta (ehdotus `/hallinta/`, noindex) ja otetaanko 2FA Supabase Authissa käyttöön admin-tileille?
