# UX- ja laatuanalyysi: julkinen sivusto, varauskauppa ja hallinta

Päivämäärä: 12.11.2026, päivitetty 13.11.2026 (Joonaksen palaute, PR:t #346–#354, työmääräarvio) · Haara: `claude/ux-analyysi-0atsd7` · Tekijä: Claude (tutkija, ei toteuttaja; koodia ei muutettu)

**Lukuohje.** Luku 1 kertoo tärkeimmät havainnot ja suositellun järjestyksen. Luku 2 ehdottaa yhteistä ulkoasujärjestelmää. Luku 3 käy läpi jokaisen sivun ja hallinnan näkymän: ensin nykytila lyhyesti, sitten numeroidut parannusehdotukset. Luku 4 on koontitaulukko kaikista kohdista koon mukaan. Jokaisessa havainnossa on merkintä **VARMA** (nähty koodista tai ruudulta) tai **OLETUS** (päättely, tarkistettava). Tietokantaa koskevat johtopäätökset on tarkistettu vain repon migraatioista; tuotanto voi olla repoa edellä (esim. booking_287 ja booking_288).

**Koot.** PIENI = alle tunti, vain käyttöliittymä. KESKI = useampi tiedosto tai pieni tietokantamuutos. SUURI = uusi toiminto tai laaja uudistus.

## Menetelmä ja rajaukset

- Koko kokonaisuus (sivusto, kauppa, hallinta, juomasivu, vuorosivu) rakennettiin paikallisesti komennolla `scripts/build-pages.mjs` ilman Supabase-yhteyttä (Supabase-osoite osoitti paikalliseen porttiin, joten build käytti repon varatekstejä). Supabaseen ei otettu yhteyttä, eikä mitään kirjoitettu.
- Kauppa ja hallinta ajettiin kokeilutilassa (`?mock=1`, selaimen oma esimerkkidata, ei verkkokutsuja). Kaikki näkymät kuvattiin Playwrightilla leveyksillä 1280, 820 (tabletti) ja 390 px, ja työnkulut klikattiin läpi.
- Läpikäynnin tukena oli viisi rinnakkaista tutkijaa (tilaukset ja asiakkaat; kassa, talous ja lahjakortit; päivittäinen työ; tuotteet, viestit ja asetukset; kauppa). Niiden tärkeimmät väitteet tarkistettiin erikseen koodista ennen raporttiin ottamista.
- Rajaukset: kokeilutila ei avaa tilausnäkymää, asiakasnäkymää, Resursseja eikä Käyttäjiä (ks. YHT-08). Ne arvioitiin koodista ja selaimeen syötetyllä väliaikaisella mock-datalla (repoon ei tehty muutoksia). Kokeilutilan datasta johtuvia ilmiöitä (esim. asiakaslistan "0 / 0 asiakasta" ja "undefined tilausta") ei raportoida tuotantovikoina: tuotannon `admin_list_customers` palauttaa kentät oikein (booking_11:655–676).
- Verrokkitiedot (Timma, Fresha, Bókun, FareHarbor) ovat yleistietoa näiden palvelujen julkisista toiminnoista, eikä niitä testattu tätä raporttia varten (OLETUS).
- Kuvakaappauksia ei lisätty repoon. Raportissa ei käytetä asiakkaiden henkilötietoja; esimerkit ovat kokeilutilan keksittyjä nimiä tai yleisiä.

## 1. Yhteenveto

**Vastaus lyhyesti.** Julkinen sivusto on jo valmiin tuntuinen, kauppa on lähellä ja hallinta on toiminnoiltaan laaja mutta ei vielä yhtenäinen eikä itsepalveluna riittävä. Hallinnasta puuttuu yhteinen ulkoasujärjestelmä, navigaatio on kasvanut näkymä kerrallaan, ja kolme asiaa vaatii yhä kehittäjää: aukiolot ja vuorot, sivuston ja viestien tekstit sekä tuotannon julkaisu. Lisäksi löytyi viisi pientä mutta kiireellistä virhettä, jotka kannattaa korjata heti.

**Vahvuudet, jotka kannattaa säilyttää:** tilausnäkymä v3 (selkein näkymä, "Seuraava askel" -palkki), lahjakortin voimassaolon pikajatko, hiljaisten aikojen hinnoittelu, ALV- ja kirjanpitoraportit, kaupan 15 minuutin pito saavutettavine laskureineen, lahjakoodin tunnistus kassalla sekä julkisen sivuston nopeus ja saavutettavuuden perusta.

### 1.1 Tärkeimmät 10 havaintoa

1. **Viisi pientä virhettä, jotka asiakas tai kirjanpitäjä huomaa (VARMA).** Korjattu PR:ssä #350 13.11.2026 (ks. luku 1.7).
   - Juomien QR-maksusivu `/juomat/` jää paikallisessa koonnissa tyhjäksi, koska julkaisu ei kopioi kahta tarvittavaa moduulia; tuotannon tila on OLETUS, mutta sama julkaisuskripti tekee myös tuotannon (SIVU-JUOMAT-01).
   - Julkaisu jättää hallinnan dynaamiset importit versioimatta, jolloin "← Takaisin" ei palaa lähtönäkymään ja vanhat moduulit voivat jäädä välimuistiin (HALL-TILAUS-02).
   - Maksutaparaportin sarake "Veroton" näyttää bruttosumman (HALL-TALOUS-01).
   - "Lasku tilauksesta" kysyy tilausnumeroa mutta hakee sisäisellä tunnisteella (HALL-LASKUT-01).
   - Täyden tapahtuman jonotuslinkki rikkoutuu sivun päivityksessä (KAUPPA-JONO-01).
2. **Uusi tilausnäkymä vei henkilökunnalta toimintoja (VARMA).** "Ei saapunut", maksamattoman tilauksen poisto, asiakkaan peruutuspyynnön näkyminen, yrityksen laskutustiedot, vuosikorttikoodi ja hyvityksen uudelleenyritys ovat vain vanhassa kortissa, johon ei enää käytännössä pääse (HALL-TILAUS-01).
3. **Aukioloja, vuoroja ja poikkeuspäiviä ei voi muuttaa ilman kehittäjää (VARMA).** Vuorosäännöstä voi muokata vain nimeä, päällä/pois-tilaa, henkilömääriä, takarajaa ja voimassaoloa; uusi vuoro tai alkuajan muutos vaatii migraation. Tämä on suurin ero verrokkeihin (HALL-TILAT-01).
4. **Tekstien muokkaukseen on valmis tietokantatyönkulku, mutta ei käyttöliittymää (VARMA).** Ehdotus, hyväksyntä, versiot ja palautus ovat olemassa (booking_60/64), samoin artikkelien RPC:t (booking_51). Tuotantosivuston julkaisu on käsin tehtävä SFTP-vienti (SIVU-YHT-03).
5. **Navigaatio on liian syvä ja päällekkäinen (VARMA).** 11 pääkohtaa, raporttiin neljä tasoa, sama tilauslista kahdessa paikassa, kumppanikoodeilla kolme käyttöliittymää, ryhmä "Kassa ja talous" aukeaa kassalle (HALL-KUORI-01, HALL-TILAUKSET-02, HALL-LAHJAKORTIT-03).
6. **Hallinnan ulkoasu ei ole yhtenäinen (VARMA).** Kahdeksan välilehtitoteutusta, 74 käsin kirjoitettua väriä, 38 fonttikokoa, kolme erilaista päälle/pois-ohjainta, otsikko toistuu kolmesti ("Tuotteet / Tuotteet / Tuotteet") ja kortit ovat samassa näkymässä eri levyisiä (luku 2, YHT-01–YHT-07).
7. **Mobiilikassa piilottaa kokonaishinnan ja 15 minuutin ehdon lähetysnapin alle, ja lomakevirheet ovat geneerisiä (VARMA).** Virheilmoitus jää mobiilissa ruudun ulkopuolelle (KAUPPA-KASSA-01, KAUPPA-KASSA-02).
8. **Asiakkaalle näkyy vanhentuneita ja ristiriitaisia maksutekstejä (VARMA).** "Verkkomaksu (Visma Pay) otetaan käyttöön myöhemmin", laskutetulla yritystilauksella maksunappi ja "maksu paikan päällä", vahvistussivulla toistuvat otsikot ja kaksi kilpailevaa toimintoa (KAUPPA-MAKSU-01, KAUPPA-TILAUS-01, KAUPPA-VAHVISTUS-01).
9. **Tuote-editori hävittää työtä (VARMA).** 3 200 px:n dialogi, 4–5 erillistä tallennusta, tallennus sulkee dialogin ja hävittää muut muutokset; neljä päällekkäistä asetusta päättää, näkyykö tuote kaupassa (HALL-TUOTTEET-01, HALL-TUOTTEET-02).
10. **Vastaanoton työkalut eivät ole vielä valmiita (VARMA).** Päivän Valmistelu (henkilöt ja lisäpalvelut) on näkymän alaosassa, näkymä ei päivity itsestään, tabletilla valikossa on pelkät ikonit, asiakkaan siirto vaatii kaksi näkymänvaihtoa, eikä pikakassalla voi myydä tavallisella korttipäätteellä (HALL-PAIVA-01, -03, -04, HALL-KUORI-02, HALL-KASSA-02).

### 1.2 Suositeltu toteutusjärjestys

**Vaihe 0: heti (kaikki PIENI, ei tietokantamuutoksia).** SIVU-JUOMAT-01, HALL-TILAUS-02, HALL-LASKUT-01 ja KAUPPA-JONO-01 ovat valmiita (PR #350), HALL-TALOUS-01 ja KAUPPA-MAKSU-01 osittain. Jäljellä: HALL-TALOUS-01:n ja KAUPPA-MAKSU-01:n loput, KAUPPA-TILAUS-01, HALL-TILAUS-03 ja KAUPPA-SELAUS-01, yhteensä noin puolen päivän työ.

**Vaihe 1: perusta (ei tietokantamuutoksia).** YHT-08 (kokeilutila kattamaan kaikki näkymät, jotta seuraavat muutokset voi testata), YHT-01 (tokenit), YHT-04 ja YHT-05 (sanasto ja muodot), YHT-06 (dialogit), YHT-02 ja YHT-03 (komponentit ja välilehdet), HALL-KUORI-01 (navigaatio) ja HALL-KUORI-02 (tabletti). Tämän jälkeen jokainen näkymä siirretään yhteisiin komponentteihin samalla, kun sitä muutetaan muutenkin.

**Vaihe 2: arjen työkalut (pääosin ei tietokantamuutoksia).** HALL-TILAUS-01, HALL-PAIVA-01–05, HALL-ASIAKKAAT-01, HALL-TUOTTEET-01 ja -02, HALL-ASETUKSET-01, KAUPPA-KASSA-01 ja -02, KAUPPA-VAHVISTUS-01, HALL-KASSA-01, HALL-AVOIMET-01, HALL-LAHJAKORTIT-01.

**Vaihe 3: itsepalvelu (tietokantamuutokset Bottiavustuksen kautta, ensin DEV, sitten PROD).** SIVU-YHT-03 (Tekstit-näkymä ilman tietokantamuutosta, julkaisun automaatio erillisellä päätöksellä), HALL-TILAT-01 (aukiolot ja poikkeuspäivät), HALL-KALENTERI-01, HALL-SULUT-01, HALL-TUOTTEET-04, HALL-TAPAHTUMAT-01, HALL-TILAUS-05 ja -06, HALL-KASSA-02, HALL-VIESTIT-01, HALL-KAYTTAJAT-01.

**Vaihe 4: laajemmat kokonaisuudet.** HALL-TALOUS-02 (päivän tilitys), HALL-ASIAKKAAT-02 ja -03 (yhdistäminen, anonymisointi, tagit), HALL-KALENTERI-02 (resurssiaikajana), SIVU-EN-01 (natiivitarkistus) ja vanhan koodin siivous HALL-TILAUS-09.

### 1.3 Mitä henkilökunta ei nyt pysty tekemään itse, mutta tarvitsisi

| Tarve | Nyt | Kohta |
|---|---|---|
| Uusi vuoro, alkuajan, viikonpäivien tai keston muutos, kertavuoro, yhden päivän kapasiteetti | migraatio (Bottiavustus) | HALL-TILAT-01 |
| Sivuston, kaupan ja sähköpostien tekstit, artikkelit | tuontitiedosto ja Koodari; tuotanto julkaistaan käsin | SIVU-YHT-03 |
| Merkitä "Ei saapunut", poistaa virheellinen maksamaton tilaus, nähdä asiakkaan peruutuspyyntö | vain vanhassa kortissa | HALL-TILAUS-01 |
| Lähettää vahvistus uudelleen tai kirjoittaa yksittäiselle asiakkaalle | oma sähköposti, ei näy historiassa | HALL-TILAUS-06 |
| Yhdistää asiakkaan kaksoiskappaleet, anonymisoida asiakas (GDPR) | toteutettu kytkimien takana PR:ssä #349, ei vielä päällä | HALL-ASIAKKAAT-02 |
| Avata tapahtumien myynti | ei kytkintä | HALL-TAPAHTUMAT-01 |
| Luoda tapahtuma, koulutus tai hoito-/vuorotuote tyhjästä myyntikuntoon | vain kopiointi, luonti jättää tuotteen pois myynnistä | HALL-TUOTTEET-03 |
| Lisätä hintavariantti (kausihinta), muuttaa tuotteen kestoa | ei käyttöliittymää | HALL-TUOTTEET-04 |
| Muokata sulkua, tehdä usean päivän sulku, nähdä mitkä varaukset estävät sulun | vain poisto ja uusi | HALL-SULUT-01 |
| Myydä tiskillä tavallisella korttipäätteellä, tehdä päivän tilitys | ei mahdollista | HALL-KASSA-02, HALL-TALOUS-02 |
| Muokata laskuluonnosta | mitätöinti ja uusi | HALL-LASKUT-02 |
| Myydä lahjakortti puhelimessa maksulinkillä tai englanniksi | 12+ vaihetta, vain suomeksi | HALL-LAHJAKORTIT-01 |
| Vaihtaa salasana itse | pääkäyttäjä kutsuu uudelleen | HALL-KUORI-03 |
| Lähettää kutsu uudelleen, muokata työntekijän nimeä | ei mahdollista | HALL-KAYTTAJAT-01 |
| Vaihtaa kuittilogo, muokata provisiosääntöä | ei mahdollista | HALL-ASETUKSET-02 |
| Nähdä alennuskoodin käyttö ja myynti | vain käyttökertojen määrä | HALL-ALENNUS-02 |

### 1.4 Turhat, päällekkäiset tai sekavat näkymät ja asetukset

| Päällekkäisyys | Ehdotus | Kohta |
|---|---|---|
| Tilauslista sekä Tilauksissa että Talous › Tilauksissa | vain Tilauksissa | HALL-TILAUKSET-02 |
| Hyvitysten seuranta sekä välilehtenä että raporttivalintana; Seurattavat maksut ja Hyvitysten seuranta erillisinä | yksi "Avoimet maksut" -jono Tilauksissa | HALL-AVOIMET-01, HALL-TALOUS-01 |
| Kumppanikoodeilla kolme käyttöliittymää ja kolme nimeä | yksi rivikomponentti, nimi "Kumppanikoodit" | HALL-LAHJAKORTIT-03 |
| Lahjakorttien kytkimet sekä Asetuksissa että Lahjakortit-näkymässä (jossa ne ovat vain luku -merkkejä) | yksi paikka | HALL-LAHJAKORTIT-02 |
| Koulutukset sekä päävalikossa että Tuotteet › Tapahtumat ("Tapahtumat ja koulutukset") | Koulutukset jää omaksi päävalikon kohdakseen (Joonas 13.11.); Tapahtumat-välilehdeltä koulutukset pois | HALL-KUORI-01 |
| Vuosikortit alennuskoodien sivulla | Lahjakortit ja koodit › Vuosikortit | HALL-KUORI-01 |
| Neljä näkyvyysasetusta tuotteella | yksi kolmiportainen valinta | HALL-TUOTTEET-02 |
| Kaksi lisäosto-, maksulinkki-, maksunkirjaus- ja peruutusdialogia | yksi kustakin | HALL-TILAUS-04, HALL-TILAUS-09 |
| Kaksi varauslomaketta (saunavuoro vs. hoito/tila/jälkikirjaus) | yksi lomakerunko | HALL-UUSI-01 |
| Asetuksissa 10 välilehteä, noin puolet korteista vain luku -tilatietoa; QR-tulostus "ei ole asetus" | 5 välilehteä, tilatiedot adminin Järjestelmä-välilehdelle | HALL-ASETUKSET-01 |
| Kolme viestityökalua eri kielituella ja eri paikkamerkeillä | yksi viestikomponentti | HALL-VIESTIT-01 |
| Tarkista-painike sekä yläpalkissa että Varaukset-välilehdellä, eri luvuilla | vain yläpalkissa, sama luku | HALL-KUORI-05 |
| FI/EN-kytkin neljässä näkymässä, vaikuttaa koko hallintaan | käyttäjävalikkoon tai pois | HALL-KUORI-04 |
| "+ Uusi varaus" sekä yläpalkissa että päivänäkymän työkaluissa | vain yläpalkissa | HALL-PAIVA-01 |

### 1.5 Verrokit: mitä niissä on ja miten Saunotus vertautuu

Verrokkien sarakkeet ovat yleistietoa (OLETUS, ei testattu tätä raporttia varten). ✔ = on, ◐ = osittain, – = ei.

| Toiminto | Timma | Fresha | Bókun | FareHarbor | Saunotus nyt | Kohta |
|---|---|---|---|---|---|---|
| Aukiolot, kertavuorot ja päiväkohtainen kapasiteetti henkilökunnan muokattavissa | ✔ | ✔ | ✔ | ✔ | – (migraatio) | HALL-TILAT-01 |
| Resurssisarakkeinen päiväkalenteri, siirto vetämällä | ✔ | ✔ | ◐ | ◐ | – (lista) | HALL-KALENTERI-02 |
| Kalenterin täyttöaste | ✔ | ✔ | ✔ | ✔ | – | HALL-KALENTERI-01 |
| Näkyvä check-in ja no-show | ✔ | ✔ | ✔ | ✔ | ◐ (sisäänkirjausympyrä toimii, no-show vain vanhassa kortissa) | HALL-PAIVA-02 |
| Tulostettava päivälista / manifesti | ◐ | ◐ | ✔ | ✔ | – | HALL-PAIVA-04 |
| Vahvistuksen uudelleenlähetys, viesti yksittäiselle asiakkaalle | ✔ | ✔ | ✔ | ✔ | – | HALL-TILAUS-06 |
| Muokattavat viestipohjat ja testilähetys | ✔ | ✔ | ✔ | ✔ | ◐ | HALL-VIESTIT-01, SIVU-YHT-03 |
| Asiakaskortti: muistiinpanot, tagit, historia, yhdistäminen | ✔ | ✔ | ◐ | ◐ | ◐ | HALL-ASIAKKAAT-01–03 |
| Kassa korttipäätteellä ja päivän tilitys | ✔ | ✔ | ◐ | ◐ | – | HALL-KASSA-02, HALL-TALOUS-02 |
| Lahjakortit ja alennuskoodit | ✔ | ✔ | ✔ | ✔ | ✔ (vahva) | – |
| ALV- ja kirjanpitoraportit | ✔ | ✔ | ✔ | ✔ | ✔ (vahva, Procountor) | HALL-TALOUS-01 |
| Dynaaminen hinnoittelu tyhjille vuoroille | – | ◐ | ◐ | – | ✔ (Hiljaiset ajat) | – |
| Mobiilikassassa kiinteä summa ja maksupainike | ✔ | ✔ | ✔ | ✔ | – | KAUPPA-KASSA-01 |
| "Seuraava vapaa aika" palvelulistassa | ✔ | ✔ | ◐ | ◐ | – (päivänäkymä ehdottaa) | KAUPPA-SELAUS-02 |
| Asiakkaan itsepalvelu: siirto ja peruutus | ✔ | ✔ | ✔ | ✔ | ◐ (siirto ✔, peruutus pyyntönä) | KAUPPA-VAHVISTUS-01 |
| Jonotuslista täysiin | ◐ | ✔ | ◐ | ◐ | ✔ (tapahtumat) | KAUPPA-JONO-01 |
| Salasanan palautus itse | ✔ | ✔ | ✔ | ✔ | – | HALL-KUORI-03 |

### 1.6 Luonnokset

Kymmenestä eniten muuttuvasta ja tärkeimmästä näkymästä on klikattavat HTML-luonnokset kansiossa `docs/mockups/uudistus/` (hakemisto `index.html`, kuvat kansiossa `kuvat/`). Ne käyttävät luvun 2 ehdotettua tyylijärjestelmää (`tokens.css`, `ui.css`), ja jokaisen alalaidassa on numeroitu selitys muutoksista raportin tunnisteineen.

| Nro | Luonnos | Leveys | Kohdat |
|---|---|---|---|
| 01 | Päivänäkymä vastaanoton tabletilla | 820 px | HALL-PAIVA-01–05, HALL-KUORI-01–02 |
| 02 | Tilausnäkymä | 1280 px | HALL-TILAUS-01–08 |
| 03 | Aukiolot ja poikkeuspäivät (uusi) | 1280 px | HALL-TILAT-01–02 |
| 04 | Tuotteen muokkaus | 1280 px | HALL-TUOTTEET-01–06 |
| 05 | Pikakassa tabletilla | 1180 px | HALL-KASSA-01–02 |
| 06 | Asetukset puhelimella | 390 px | HALL-ASETUKSET-01–02, HALL-TAPAHTUMAT-01 |
| 07 | Tekstit (uusi) | 1280 px | SIVU-YHT-03, HALL-VIESTIT-01 |
| 08 | Varauslomake puhelimella | 390 px | KAUPPA-KASSA-01–03, KAUPPA-YHT-01 |
| 09 | Vahvistussivu, kaksi tilaa | 390 px | KAUPPA-VAHVISTUS-01, KAUPPA-MAKSU-01 |
| 10 | Sivuston etusivu ja yleisilme | 390 ja 1280 px | SIVU-YHT-01–05, SIVU-ETUSIVU-01–02, SIVU-SAUNAVUOROT-01 |

### 1.7 Tilanne 13.11.2026: mainiin tulleet muutokset ja päällekkäisyydet

Raportti tehtiin mainin tilasta `2120304` (12.11.). Sen jälkeen mainiin yhdistettiin PR:t #346–#354 (main `fb0e543`). Ne on käyty läpi ja huomioitu raportin kohdissa ("Tila 13.11.2026" -rivit ja luvun 4 Tila-sarake). Ristiriitoja luonnosten kanssa ei ole; kolmessa kohdassa ehdotus on jo toteutettu tai sen tietokantaosa on tarpeeton.

| PR | Mitä toi | Vaikutus raporttiin |
|---|---|---|
| #350 | Raportin vaihe 0: juomasivun moduulit, lasku tilausnumerolla, dynaamisten importtien versio, Veroton-sarake, Visma Pay -lause, jonotuslinkki | SIVU-JUOMAT-01, HALL-TILAUS-02, HALL-LASKUT-01 ja KAUPPA-JONO-01 valmiita; HALL-TALOUS-01 ja KAUPPA-MAKSU-01 osittain |
| #347 | Osahyvitys, ylisuorituksen hyvitys, atominen koko tilauksen peruutus, muutoksen hinnan esikatselu ja asiakasilmoitus (booking_282–283), asiakkaan oma henkilömäärän pienennys (booking_284); kaikki lippujen takana | HALL-TILAUS-05 pääosin valmis (migraatioluonnos poistettu), HALL-TILAUS-01 osittain; KAUPPA-VAHVISTUS-01:een lisätty huomio asiakkaan omasta pienennyksestä |
| #349 | Asiakkaiden yhdistäminen ja anonymisointi (booking_285), kytkimien takana | HALL-ASIAKKAAT-02 valmis (migraatioluonnos poistettu); jäljellä testaus ja kytkentä |
| #346 | Saatavuushakujen nopeutus (booking_289, `product-months.js`) | KAUPPA-SELAUS-02 rakennetaan uuden hakukerroksen päälle |
| #348 | booking_287 ja booking_288 sekä vanhat PROD-migraatiot repoon | Ei vaikutusta ehdotuksiin |
| #351–#354 | Uutiskirjeen tilanne, sivutekstien varatekstit | Ei vaikutusta ehdotuksiin |

Joonaksen palaute 13.11. on huomioitu raportissa ja luonnoksissa:

- **Valmistelu (henkilöt ja lisäpalvelut lajeittain) näkyy päivänäkymässä kerralla ylimpänä** (HALL-PAIVA-01, luonnos 01).
- **Varauksen siirto onnistuu myös vapaasti valittavaan ajankohtaan.** Toiminto on jo nykyisessä dialogissa, ja se säilyy ja tuodaan päivän pikatoimintoihin (HALL-PAIVA-03, HALL-TILAUS-05, luonnos 02).
- **Erillistä Saapui-painiketta ei tehdä.** Vihreäreunainen sisäänkirjausympyrä säilyy (HALL-PAIVA-02, luonnos 01).
- **Koulutukset on oma päävalikon kohtansa ja oma työtilansa** (HALL-KUORI-01, HALL-KOULUTUKSET-01, kaikkien hallintaluonnosten valikko).

### 1.8 Työmääräarvio: muutokset testisivulle

**Mitä "testisivulle" tarkoittaa tässä repossa.** Testisivu (GitHub Pages, Supabase DEV) julkaistaan automaattisesti `main`-haarasta (`.github/workflows/pages.yml`). Muutos näkyy testisivulla, kun Koodari on yhdistänyt sen mainiin, ja tietokantamuutokset ajaa Bottiavustus ensin DEViin. Tuotanto julkaistaan erikseen SFTP:llä. Koska main on myös tuotannon lähde, ulkoasu- ja navigaatiomuutokset kannattaa tehdä kytkimen taakse, kuten #347 ja #349 tekivät. Esimerkiksi hallinnan "Kokeile uutta ulkoasua" -valinta käyttäjävalikossa: silloin testisivulla voi kokeilla uutta, ja tuotanto pysyy ennallaan, kunnes uusi hyväksytään.

**A. Luonnosten 10 näkymää ja niiden pohjana oleva yhteinen ulkoasu** (arvio kehittäjäpäivinä sisältäen testit ja kokeilutilan datan; ±50 %):

| Kokonaisuus | Kohdat | Tietokanta | Kehittäjäpäiviä | PR:iä |
|---|---|---|---|---|
| Perusta: tokenit, komponentit, välilehdet, sanasto, muodot, dialogit, kokeilutila | YHT-01–08 | ei | 5–7 | 3–4 |
| 01 Päivänäkymä ja uusi valikko | HALL-KUORI-01–02, HALL-PAIVA-01–05 | ei (asiakastagit erikseen, pieni) | 5–7 | 2–3 |
| 02 Tilausnäkymä | HALL-TILAUS-01, -03, -04, -05 (loput), -06, -07, -08 | pieni (vahvistuksen uudelleenlähetys, viesti asiakkaalle) | 6–8 | 3 |
| 03 Aukiolot ja poikkeuspäivät | HALL-TILAT-01–02 | suuri (vuorosäännöt, poikkeukset, saatavuuslaskenta) | 8–12 | 2–3 |
| 04 Tuote-editori | HALL-TUOTTEET-01, -02, -04, -06 | pieni (hintavariantin luonti) | 4–6 | 2 |
| 05 Pikakassa | HALL-KASSA-01–02 | pieni (päätemaksun kuittaus) + liiketoimintapäätös | 2–4 | 1–2 |
| 06 Asetukset | HALL-ASETUKSET-01–02, HALL-TAPAHTUMAT-01 | pieni (tapahtumien myyntikytkin, logo) | 3–4 | 2 |
| 07 Tekstit | SIVU-YHT-03 (a) | ei (RPC:t valmiina) | 4–6 | 2 |
| 08 Varauslomake | KAUPPA-KASSA-01–03, KAUPPA-YHT-01, KAUPPA-TUOTE-01 | ei | 3–5 | 2 |
| 09 Vahvistussivu | KAUPPA-VAHVISTUS-01, KAUPPA-MAKSU-01 (loput), KAUPPA-TILAUS-01 | ei | 1–2 | 1 |
| 10 Etusivu ja yleisilme | SIVU-YHT-01, -02, -05, SIVU-ETUSIVU-01–02, SIVU-SAUNAVUOROT-01 | ei | 2–3 | 1–2 |
| **Yhteensä** | | 6 kohdassa tietokantamuutos | **43–64** | **21–28** |

Yhdelle kehittäjälle tämä on noin 9–13 viikkoa. Jos koodin tekee Claude Code ja Koodari katselmoi (repon nykyinen tapa: esimerkiksi #347 toi kolme migraatiota ja käyttöliittymän yhdessä PR:ssä), pullonkaula on katselmointi, testisivulla kokeilu ja DEV-migraatiot, ei koodaus. Arvio on silloin noin 4–6 viikkoa kalenteriaikaa, jos 1–2 PR:ää ehditään katselmoida päivässä. Suurin epävarmuus on Aukiolot, koska se muuttaa saatavuuslaskentaa, jota kauppa, hallinta ja varausmoottori käyttävät.

**B. Koko raportti.** Avoimia kohtia on 97 (PIENI 56, KESKI 37, SUURI 4). Karkea arvio on 65–130 kehittäjäpäivää, kun PIENI on 1–2 tuntia testeineen, KESKI 1–2 päivää ja SUURI 5–10 päivää. Luonnosten kattama osuus A on noin puolet tästä, ja se sisältää näkyvimmät ja arjen kannalta tärkeimmät muutokset.

**Suositeltu järjestys testisivulle:**
1. Vaiheen 0 loput (puoli päivää).
2. Perusta, 01 Päivä ja 10 Etusivu: näkyvin muutos, ei tietokantaa.
3. 02 Tilaus, 04 Tuote, 06 Asetukset, 08 Varauslomake ja 09 Vahvistus.
4. 07 Tekstit.
5. 03 Aukiolot ja 05 Pikakassa, joihin tarvitaan tietokantamuutokset ja päätökset.

## 2. Yhteinen ulkoasujärjestelmä

### 2.1 Nykytila lyhyesti (varmat havainnot)

| Asia | Julkinen sivusto `src/styles.css` | Kauppa `booking/shop/src/shop.css` | Hallinta `booking/admin/admin.css` (+ `calendar.css`) |
|---|---|---|---|
| Väritokenit | `:root` rivi 7: `--ink --text --muted --gold --accent --green --card --tint --bg --line` | **ei omia tokeneita**; perii sivuston `:root`in, mutta kirjoittaa värit käsin (48 eri heksaa, esim. `#2b3a30` 42 kertaa = `--green`) | `:root` rivi 2: samat perusvärit + `--ok --okbg --err --errbg --warnbg --unpaidbg`; lisäksi 74 eri käsin kirjoitettua heksaa (`#fff` 91 kertaa) |
| Kirjasimet | Cormorant Garamond + Playfair Display (kaksi eri serif-otsikkokirjasinta) + Montserrat (nappien ja yläotsikoiden versaalit) + Lato (leipä) | sama kuin sivusto | `system-ui` (rivi 5); 38 eri `font-size`-arvoa (px, rem ja `clamp` sekaisin) |
| Painike | `.btn` vihreä, versaali Montserrat 12 px, varjo; `.btn.sm` pyöreä 30 px, `.btn.gold` liukuväri, `.btn.ghost`, `.btn.light` | sivuston `.btn` + yli 10 paikallista kokomääritystä (46–52 px korkeus) | `.btn` valkoinen + vihreä reuna, `.primary`, `.danger` (`#b3392b`, eri kuin `--err`), `.ghost`, `.danger-ghost`, `.sm`, `.lg`, `.cap`, `.slot`, `.daychip`; yli 40 näkymäkohtaista `.btn`-ohitusta |
| Kulmat | `--r:12px`, napit 8 px tai 30 px | 8–30 px | `--r:12px`, napit 8 px, rivit 10 px |
| Välilehdet | – | segmenttipainike "Selaa kategorioittain / päivän mukaan" | vähintään 8 eri toteutusta: `nav-group` (harmaa täyttö + alaviiva), `.tl-tabs` (Talous), `.set-tabs` (Asetusten pillerit), `.ev-tabs` (Tapahtumat), `.training-tabs` (tumma täyttö), Viestit (alleviivatut linkit), Lahjakortit, Tilaukset |
| Kellonaika | "16.00–19.00" (suomen kielen suositus) | "klo 13.00" | "16:00–17:30": `booking/admin/ui.js:21` vaihtaa pisteen kaksoispisteeksi; Tapahtumat-näkymässä samalla rivillä "klo 17.00" ja "17:00–19:30" |
| Murtokohdat | muutama | useita | 699, 700, 800, 900 px, 75em, 80em sekaisin |

Johtopäätös: sivusto on huoliteltu ja yhtenäinen, kauppa on lähes yhtenäinen sivuston kanssa, mutta hallinta on kasvanut näkymä kerrallaan. Jokainen näkymä on sinänsä siisti, mutta niiden väliset erot (otsikkokoot, välilehtityylit, on/off-ohjaimet, tallennustapa, kortin leveys) tekevät kokonaisuudesta keskeneräisen tuntuisen. Tämä on raportin tärkein yksittäinen ulkoasuhavainto.

### 2.2 Ehdotus: yksi tokenitiedosto ja pieni komponenttikirjasto

Ei kehystä eikä build-vaihetta (repon periaate säilyy). Yksi CSS-tiedosto `booking/shared/tokens.css`, jonka sivuston build upottaa `styles.css`:n alkuun ja hallinta lataa `index.html`:ssä ennen `admin.css`:ää. Kauppa saa tokenit sivuston kautta.

**Värit (nimet merkityksen mukaan, ei sävyn):**

| Token | Arvo | Käyttö |
|---|---|---|
| `--c-ink` | #2F2923 | otsikot |
| `--c-text` | #4F443A | leipäteksti |
| `--c-muted` | #6B5E52 | toissijainen teksti (≥ 4,5:1 `--c-bg`:tä vasten) |
| `--c-brand` | #2B3A30 | ensisijainen painike, yläpalkki, aktiivinen valinta |
| `--c-accent` | #7A5530 | linkit, fokusrengas, korostus |
| `--c-gold` | #C49A6C → #A87B45 | vain markkinoinnin CTA sivustolla (ei hallinnassa) |
| `--c-bg` | #F4EFE7 | sivun tausta |
| `--c-surface` | #FFFFFF (hallinta) / #FAF7F1 (sivusto) | kortit |
| `--c-line` | rgba(63,53,44,.18) | reunat |
| `--c-ok` / `--c-ok-bg` | #1D4D2B / #E8F3EA | maksettu, vahvistettu, voimassa |
| `--c-warn` / `--c-warn-bg` | #6B4B00 / #FDF1D8 | odottaa, vaatii toimenpiteitä |
| `--c-danger` / `--c-danger-bg` | #7B1D12 / #FBEAEA | virhe, peruttu, poista |
| `--c-info` / `--c-info-bg` | #2B3A30 / #E4EBE5 | neutraali tieto |

Hallinnan 74 ja kaupan 48 käsin kirjoitettua heksaa korvataan näillä. Hyväksymiskriteeri: `grep -o '#[0-9a-fA-F]\{3,6\}'` löytää hallinnan ja kaupan CSS:stä enintään 10 arvoa (kuvat, logot, tulostus).

**Typografia:**
- Sivusto: yksi serif-otsikkokirjasin (Cormorant Garamond **tai** Playfair Display, ei molempia), Montserrat vain pieniin versaaliotsikoihin, Lato leipään. Säästää yhden fonttilatauksen ja poistaa kahden serifin ristiriidan (hero Playfair, osio-otsikot Cormorant).
- Hallinta: pysyy `system-ui`-kirjasimessa (nopea, luettava taulukoissa, tabulaariset numerot), mutta kokoasteikko lukitaan: 12 / 14 / 16 / 18 / 22 / 28 px (`--fs-xs … --fs-2xl`). Nykyiset 38 arvoa → 6. Summille `font-variant-numeric: tabular-nums`.
- Kellonaika ja päivämäärä yhdellä tavalla: suomeksi "16.00–17.30" ja "to 12.11.2026", englanniksi "16:00–17:30" ja "Thu 12 Nov 2026". Muutos `booking/admin/ui.js:21` (`fmtTime`) ja kaupan `clock.js`.

**Välistys ja muoto:** 4 px:n asteikko `--sp-1 … --sp-8` (4, 8, 12, 16, 20, 24, 32, 48). Kulmat `--r-sm 6px` (merkit), `--r-md 10px` (painikkeet, kentät), `--r-lg 14px` (kortit). Pyöreä pilleri vain suodatinsiruille. Yksi varjo kortille, yksi dialogille.

**Murtokohdat:** 600 px (puhelin), 900 px (tabletti → sivupalkki), 1200 px (leveä). Hallinnan nykyiset 699/700/800/75em/80em yhdistetään näihin.

### 2.3 Komponentit, joita sekä sivusto että hallinta käyttävät

Jokainen komponentti on CSS-luokka (sivusto ja kauppa) ja hallinnassa lisäksi pieni tehdasfunktio tiedostossa `booking/admin/ui.js` (nykyiset `h`, `badge`, `field`, `empty`, `dialog`, `toast` laajennetaan).

| Komponentti | Luokka | Säännöt |
|---|---|---|
| Painike | `.btn` + `--primary`, `--secondary`, `--ghost`, `--danger`, `--sm` | Yksi ensisijainen painike näkymää tai korttia kohden. Hallinnassa lauseenalkuinen teksti, sivustolla versaalit saavat jäädä brändin mukaan. Korkeus 44 px (sm 36 px vain työpöydän taulukoissa). Vaarallinen toiminto aina punainen reunus, ei koskaan ensisijainen. |
| Sivun otsikko | `.page-head` | H1 + valinnainen kuvaus + oikeaan reunaan yksi ensisijainen toiminto ("Lisää tuote"). Välilehden nimeä ei toisteta H2:na. |
| Välilehdet | `.tabs` (`role=tablist`) | Yksi tyyli kaikkialla: alleviivattu aktiivinen, vaakavieritys kapealla näytöllä ilman katkeamista. Korvaa 8 nykyistä toteutusta. Sisäkkäisiä välilehtiä enintään 2 tasoa. |
| Segmentti | `.seg` | 2–4 toisensa poissulkevaa valintaa (Päivä/Kuukausi, Lista/Kalenteri, Kategoriat/Päivä). |
| Suodatinsiru | `.chip` (`aria-pressed`) | Monivalinta näkyy valintamerkkinä, yksivalinta segmenttinä. "Kaikki" aina ensimmäisenä tai ei lainkaan. |
| Tilamerkki | `.badge --ok/--warn/--danger/--info/--neutral` | Sama sanasto ja väri joka paikassa (Vahvistettu, Odottaa, Peruttu, Maksettu, Maksamatta, Osittain maksettu). Tekstit yhdestä sanakirjasta (`ui.js` `STATUS`/`PAY` → tekstitaulu, myös EN). |
| Kortti ja listarivi | `.card`, `.row-card` | Sama maksimileveys koko näkymässä. Listarivillä vasemmalla tunniste ja nimi, keskellä tiedot, oikealla summa ja tila, rivi on kokonaan klikattava linkki. |
| Lomakekenttä | `.field` | Nimi yläpuolella, ohje alla 14 px (ei 11 px), virhe punaisena kentän alla ja `aria-describedby`. Numerokentillä yksikkö kentän sisällä. |
| Kytkin | `.switch` (`role=switch`) | Ainoa on/off-ohjain. Korvaa nykyiset "Ota käyttöön" -napit, valintaruudut ja "Lunastus: päällä" -sirut. Tallentuu heti ja näyttää toastin, tai kuuluu lomakkeeseen, mutta ei koskaan molempia samassa näkymässä. |
| Tallennuspalkki | `.savebar` | Lomakesivulla yksi "Tallenna muutokset" -palkki alareunassa, joka ilmestyy kun jokin muuttuu. Korvaa korttikohtaiset Tallenna-napit Asetuksissa. |
| Tyhjä tila | `.empty` | Ikoni + yksi lause + ensisijainen toiminto ("Ei laskuja. Luo ensimmäinen lasku"). |
| Lataus | `.skeleton` | Harmaat paikanvaraajarivit listan muodossa, ei pelkkää "Ladataan…"-tekstiä. |
| Virhe | `.alert --danger` | Selkokielinen syy + "Yritä uudelleen". Ei teknisiä tunnisteita (esim. `select:schedule_rules`). Virhe näkyy välilehden sisällä, välilehtipalkki jää näkyviin. |
| Ilmoitus | `.toast` | Vahvistus onnistuneesta tallennuksesta; peruttavissa ("Kumoa") silloin kun mahdollista. |
| Dialogi ja sivupaneeli | `dialog`, `.drawer` | Lyhyt päätös → dialogi. Muokkauslomake → oikealta liukuva paneeli työpöydällä, koko näytön näkymä puhelimessa. |
| Taulukko | `.table` | Työpöydällä taulukko, alle 600 px kortit (sama data). Summat oikealle tasattuina. |

### 2.4 Toteutustapa

1. Lisää `booking/shared/tokens.css` ja ota se käyttöön ilman visuaalisia muutoksia (aliakset vanhoille muuttujille: `--green: var(--c-brand)` jne.).
2. Rakenna `ui.js`:ään komponenttifunktiot (`button`, `tabs`, `pageHead`, `switchField`, `emptyState`, `skeleton`, `alert`) ja `admin.css`:ään niitä vastaavat luokat.
3. Siirrä näkymät yksi kerrallaan (yksi PR / näkymäryhmä). Jokaisen PR:n hyväksymiskriteeri on, että näkymässä ei ole enää omaa välilehti-, painike- tai on/off-tyyliä.
4. Lisää `scripts/`-hakemistoon kevyt tyylitarkistus (esim. `scripts/check-admin-css.mjs`), joka varoittaa uusista heksaväreistä ja `font-size`-arvoista asteikon ulkopuolelta.

Kauppa ja sivusto tarvitsevat vain vaiheen 1 ja painikkeiden yhtenäistämisen; hallinta tarvitsee kaikki vaiheet.

### 2.5 Yhteisen ulkoasun parannusehdotukset

1. **YHT-01 · KESKI · Yhteinen tokenitiedosto**
   - Ongelma (VARMA): kolme tyylitiedostoa määrittelee värit erikseen; kauppa ja hallinta kirjoittavat värit käsin (48 ja 74 eri heksaa), ja sama vihreä esiintyy kaupassa 42 kertaa käsin kirjoitettuna (luku 2.1). Värin vaihto tai kontrastikorjaus pitää tehdä kymmeniin kohtiin.
   - Ratkaisu: `booking/shared/tokens.css` (värit, kirjasimet, kokoasteikko, välistys, kulmat, varjot, murtokohdat, luku 2.2); vanhat muuttujat aliaksina, jotta mikään ei muutu ensimmäisessä vaiheessa.
   - Hyväksymiskriteerit: sivusto, kauppa ja hallinta lataavat saman tiedoston; ensimmäisen vaiheen jälkeen kuvakaappaukset ovat ennallaan; lopuksi hallinnan ja kaupan CSS:ssä enintään 10 käsin kirjoitettua väriä.
   - Tiedostot: uusi `booking/shared/tokens.css`, `src/styles.css`, `scripts/build.mjs` (upotus), `booking/shop/src/shop.css`, `booking/admin/admin.css`, `booking/admin/index.html`, `scripts/build-pages.mjs` (kopio hallintaan).
   - Tietokanta: ei.
   - Riippuvuudet: –

2. **YHT-02 · KESKI · Hallinnan komponenttikirjasto**
   - Ongelma (VARMA): hallinnassa on yli 40 näkymäkohtaista painikeohitusta, neljä listamallia (laajeneva rivi, kortti, taulukko, `listrow`), neljä suodatinsirutyyppiä (`filter-chip`, `paylink-chip`, `btn`/`btn primary`, `vcr-chip`), kolme on/off-ohjainta (kytkin + Tallenna, heti tallentuva valintaruutu, "Ota käyttöön" + `confirm()`) ja tyhjät tilat pelkkänä tekstinä ("Ei laskuja"). Lataus on kaikkialla teksti "Ladataan…".
   - Ratkaisu: `booking/admin/ui.js`:ään funktiot `button`, `pageHead`, `card`, `rowCard`, `chip`, `switchField`, `saveBar`, `emptyState`, `skeleton`, `alert` ja niitä vastaavat luokat `admin.css`:ään (luku 2.3); näkymät siirretään ryhmä kerrallaan.
   - Hyväksymiskriteerit: jokainen siirretty näkymä käyttää vain yhteisiä komponentteja; tyylitarkistus (`scripts/check-admin-css.mjs`) varoittaa uusista heksaväreistä ja asteikon ulkopuolisista fonttikoista.
   - Tiedostot: `booking/admin/ui.js`, `booking/admin/admin.css`, näkymät `booking/admin/views/`, uusi `scripts/check-admin-css.mjs`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-01.

3. **YHT-03 · KESKI · Yksi välilehtikomponentti ja yksi H1 sivulla**
   - Ongelma (VARMA): vähintään kahdeksan välilehtitoteutusta (`nav-group.js`, `talous.js` `.tl-tabs`, `settings.js` `.set-tabs`, `events.js` `.ev-tabs`, `koulutukset.js` `.training-tabs`, Viestit alleviivattuina linkkeinä, `lahjakortit.js`, `orders.js`), joista osalla `role=tab` ja nuolinäppäimet, osalla pelkkä `active`-luokka (`koulutukset.js:41–42`, `customer-message-panel.js:35–38`). Ryhmän H1 ja näkymän oma H1/H2 toistavat saman nimen ("Tuotteet / Tuotteet / Tuotteet", "Asetukset / Asetukset / Asetukset", `nav-group.js:12` + näkymät). Mobiilissa ryhmän välilehdet menevät päällekkäin tai kahdelle riville.
   - Ratkaisu: `nav-group.js`:n toteutus yhteiseksi `tabs()`-funktioksi (role=tablist, nuolinäppäimet, `aria-controls`), vaakavieritys kapealla näytöllä; näkymät eivät piirrä omaa H1:tä ryhmän sisällä.
   - Hyväksymiskriteerit: yksi välilehtityyli koko hallinnassa; jokaisella sivulla yksi H1; 390 px:llä välilehdet eivät mene päällekkäin.
   - Tiedostot: `booking/admin/views/nav-group.js`, `booking/admin/ui.js`, yllä luetellut näkymät, `booking/admin/admin.css`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-02.

4. **YHT-04 · PIENI · Yksi tilasanasto ja monikot**
   - Ongelma (VARMA): `booking/admin/ui.js:35–36` (`STATUS`, `PAY`) käyttää sanoja "Palautettu" ja "Toteutunut", tilausnäkymä "Hyvitetty" ja "Saapunut"; "Maksamatta" on listalla harmaa (`admin.css:71`), tilausnäkymässä punainen; termit vaihtelevat (Lisäpalvelu/Lisäosto, Hyvitys/Palautus, Lunastuspyyntö/Kumppanin lahjakortti); monikot puuttuvat ("1 varausta", "1 tilausta", EN "1 bookings", "1 guests"). Kaupassa on jo monikkoapuri `booking/shop/src/plural.js`.
   - Ratkaisu: yksi sanasto (FI/EN) tiloille ja termeille, yksi väri jokaiselle tilalle (luku 2.2); `plural.js` jaetuksi (`booking/shared/`).
   - Hyväksymiskriteerit: sama tila näyttää samalta ja kuulostaa samalta kaikissa näkymissä; yksikkötesti monikoille.
   - Tiedostot: `booking/admin/ui.js`, `booking/admin/order-view-texts.js`, `booking/admin/orders-texts.js`, `booking/shop/src/plural.js`, `booking/shop/src/i18n.js`.
   - Tietokanta: ei (tekstit tuontitiedostona).
   - Riippuvuudet: –

5. **YHT-05 · PIENI · Kellonajat, päivämäärät, rahat ja ALV yhdellä tavalla**
   - Ongelma (VARMA): sivusto ja kauppa "16.00", hallinta "16:00" (`booking/admin/ui.js:21` vaihtaa pisteen kaksoispisteeksi); Tapahtumat-listalla samalla rivillä "klo 17.00" ja "17:00–19:30"; ALV paikoin "25.5 %", paikoin "25,5 %"; laskuissa ISO-päivämääriä.
   - Ratkaisu: yhteinen muotoilumoduuli: FI "16.00–17.30", "to 12.11.2026", "25,5 %", "1 234,50 €"; EN "16:00–17:30", "Thu 12 Nov 2026".
   - Hyväksymiskriteerit: hallinnassa, kaupassa ja sivustolla sama muoto; yksikkötesti.
   - Tiedostot: `booking/admin/ui.js`, `booking/shop/src/clock.js`, `booking/admin/talous-i18n.js`, uusi `booking/shared/format.js`.
   - Tietokanta: ei.
   - Riippuvuudet: –

6. **YHT-06 · PIENI · Selaimen `confirm()` pois, dialogit kuntoon**
   - Ongelma (VARMA): `confirm()`-ikkunoita on hallinnassa (`quiet.js:32, 49`, `settings.js:63–64`, `users.js:30`, `products.js:276`, `shift-staff-panel.js:84–85`, `discounts.js:36, 59–60`, `customers.js:88–89`) ja kaupassa (`shop.js:1268–1273`, `order.js:412`); kaikilla dialogeilla on sama `id="dlg-title"` (`ui.js:133–134`); avoin dialogi jää auki reitinvaihdon jälkeen (`admin.js` `route` ei sulje sitä); Esc sulkee lomakedialogin ja hävittää muutokset.
   - Ratkaisu: yhteinen `confirmDialog` (`booking/admin/confirm.js` on jo olemassa) kaikkialle, kaupalle oma vastaava; dialogeille yksilölliset id:t; reitinvaihto sulkee dialogit tai varoittaa tallentamattomista muutoksista.
   - Hyväksymiskriteerit: `grep -n "confirm(" booking/admin booking/shop/src` ei löydä selaimen `confirm()`-kutsuja; tallentamaton lomake kysyy ennen sulkemista.
   - Tiedostot: yllä luetellut, `booking/admin/ui.js`, `booking/admin/admin.js`.
   - Tietokanta: ei.
   - Riippuvuudet: –

7. **YHT-07 · PIENI · Lomakekentät, virheet ja fokus yhdenmukaisiksi**
   - Ongelma (VARMA): julkisen sivuston lomakkeen (Yrityksille-sivun tarjouspyyntö, `.co-form`) kenttäreunus on `--line` (kontrasti noin 1,3:1, ei täytä WCAG 1.4.11:tä; `src/styles.css:341`, virheviesti `:350`), kaupassa #8b7f73 (`shop.css:8, 100`); virheväri kolmella sävyllä (#5c241c, #7b1d12, #c0392b); fokusreunus sininen sivustolla (`src/styles.css:15`), tumma kaupassa, kultainen hallinnassa (`admin.css:7`); hallinnan kenttien ohjeteksti on 11–12 px.
   - Ratkaisu: kaupan kenttätyyli kaikkialle (reunus #8b7f73, pyöristys `--r-md`); yksi virheväri ja kenttäkohtainen virhe (`aria-describedby`, `aria-invalid`); yksi fokusväri (`--c-accent`, kontrasti ≥ 3:1 kaikilla taustoilla); ohjetekstit vähintään 14 px.
   - Hyväksymiskriteerit: axe- ja kontrastitarkistus läpi sivustolla, kaupassa ja hallinnassa; sama kenttä näyttää samalta kaikissa kolmessa.
   - Tiedostot: `src/styles.css`, `booking/shop/src/shop.css`, `booking/admin/admin.css`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-01.

8. **YHT-08 · PIENI · Kokeilutila kattamaan kaikki näkymät**
   - Ongelma (VARMA): kokeilutila (`?mock=1`) ei avaa tilausnäkymää, asiakasnäkymää, Resursseja eikä Käyttäjiä (puuttuvat `admin_order_lookup`, `admin_get_customer`, `select:schedule_rules`, `admin_list_staff`; `booking/admin/options-mock.js`), kokeilutilan pääkäyttäjältä puuttuu `blocks.manage` (`options-mock.js:101`), ja kaupan mock ei luo yksityisvuoroa (`ritual-addon-mock.js:109`). Tämän vuoksi savutestit eivät kata hallinnan tärkeimpiä näkymiä, ja tässäkin analyysissä osa näkymistä arvioitiin vain koodista.
   - Ratkaisu: puuttuvat RPC:t mockiin, yksi yhteinen mock-aineisto listalle ja tilausnäkymälle (`options-mock.js`, `talous-mock.js`), pääkäyttäjälle tuotannon oikeudet; `scripts/smoke-pages.mjs` käy läpi jokaisen reitin (myös `/juomat/?mock=1`).
   - Hyväksymiskriteerit: jokainen hallinnan reitti ja kaupan kulku avautuu kokeilutilassa ilman virhettä; savutesti kattaa ne.
   - Tiedostot: `booking/admin/options-mock.js`, `booking/admin/talous-mock.js`, `booking/shop/src/shop-mock.js`, `booking/shop/src/ritual-addon-mock.js`, `booking/shop/src/product-cards-live.js`, `scripts/smoke-pages.mjs`.
   - Tietokanta: ei.
   - Riippuvuudet: –

## 3. Osiot: sivut ja näkymät

### 3.1 Julkinen sivusto (src/, content/)

Yleisarvio: sivusto on kokonaisuuden viimeistellyin osa. Typografia, kuvat, rytmi ja saavutettavuuden perusteet (skip-linkki, yksi H1, alt-tekstit, kontrastit) ovat kunnossa, ja Lighthouse-tulokset ovat erinomaiset (`docs/VERTAILU.md`). Parannettavaa on lähinnä yhtenäisyydessä, mobiilin varauspolun alussa ja siinä, että henkilökunta ei pysty päivittämään sivuston sisältöä itse.

#### SIVU-YHT: kaikille sivuille yhteiset osat (ylätunniste, alatunniste, painikkeet, sisällön päivitys)

Nykytila: ylätunnisteessa logo, kuusi päävalikon kohtaa, FI/EN ja "Varaa"-painike. Mobiilissa logo, FI/EN ja "Valikko". Alatunnisteessa palvelut, käytännön info, yhteystiedot ja maksutapalogot. Tekstit tulevat tietokannasta buildissa (`src/site-texts.mjs`), viikko-ohjelma, tapahtumat ja tuotekuvat päivittyvät selaimessa (`booking/shop/src/week-live.js`, `product-cards-live.js`).

1. **SIVU-YHT-01 · KESKI · Varaa-painike puuttuu mobiilin ylätunnisteesta**
   - Ongelma (VARMA, kuva 390 px): mobiilissa ylätunnisteessa on vain FI/EN ja "Valikko". Sivuston tärkein toiminto, varaaminen, on valikon takana tai sivun sisällössä. Verrokit (FareHarbor, Bókun, Fresha) pitävät "Book now" -painikkeen aina näkyvissä mobiilissa.
   - Ratkaisu: mobiilissa ylätunnisteeseen pieni "Varaa"-painike ja FI/EN siirretään valikon sisään, tai sivun alareunaan kiinteä varauspalkki, joka piiloutuu kauppasivuilla (`/varaa/`, `/tilaus/`, `/maksa/`).
   - Hyväksymiskriteerit: 360–430 px leveydellä "Varaa" näkyy jokaisella sisältösivulla ilman vieritystä ja valikon avaamista; kosketuskohde ≥ 44 px; ei vaakavieritystä; kauppasivuilla palkkia ei ole.
   - Tiedostot: `src/render.mjs` (`layout`, rivi ~310), `src/styles.css`.
   - Tietokanta: ei.
   - Riippuvuudet: –

2. **SIVU-YHT-02 · KESKI · Kaksi serif-otsikkokirjasinta ja kolme painiketyyliä**
   - Ongelma (VARMA): sivu-heroissa on Playfair Display ("Savusauna Sipoossa", "Varaa saunaelämys"), osio-otsikoissa Cormorant Garamond ("Valitse elämys"). Painikkeita on kultainen liukuväri (`.btn.gold`), vihreä 8 px (`.btn`), vihreä pilleri 30 px (`.btn.sm`), ruskea täytetty pilleri (viikko-ohjelman "tänään") ja läpinäkyvä (`.btn.ghost`, `.btn.light`) (`src/styles.css`). Neljä fonttiperhettä kasvattaa latausta ja kaksi serifiä näyttää vahingolta, ei valinnalta.
   - Ratkaisu: yksi otsikkoserif (suositus Cormorant Garamond, koska se kantaa jo suurinta osaa otsikoista), kolme painiketta: ensisijainen (vihreä), markkinointi-CTA (kulta, vain hero ja tarjouslaatikot), toissijainen (ääriviiva). Kulmat yhteen arvoon (ks. luku 2).
   - Hyväksymiskriteerit: `styles.css` ei lataa Playfair Displayta; jokainen sivun painike kuuluu yhteen kolmesta luokasta; Lighthouse-tulokset eivät heikkene.
   - Tiedostot: `src/styles.css`, `src/render.mjs`, `public/fonts/`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-01.

3. **SIVU-YHT-03 · SUURI · Henkilökunta ei voi muuttaa sivuston tekstejä eikä julkaista muutosta itse**
   - Ongelma (VARMA): asiakkaalle näkyvät tekstit ovat taulussa `booking.site_texts`. Tietokannassa on jo valmis muokkaustyönkulku: `texts_list`, `texts_propose`, `admin_texts_queue`, `admin_texts_approve`, `admin_texts_reject`, `admin_texts_versions`, `admin_texts_rollback`, `admin_texts_publish` (booking_60 ja booking_64), roolit (tekstieditori ehdottaa, manager hyväksyy, admin suojatut). Hallinnassa ei kuitenkaan ole tekstinäkymää (`booking/admin/admin.js:61–76`, `admin-navigation.js:6–31`), joten uudet tekstit kulkevat tiedostoina `content/site-texts.pending-import-<nro>.json`, ja Koodari tuo ne. Sähköpostitekstit (`email.*`) haetaan ajonaikaisesti (5 min välimuisti, `docs/SIVUTEKSTIT.md`), joten niiden muutos näkyisi heti. Sivujen ja kaupan tekstit leivotaan buildiin, ja tuotantosivusto saunotus.fi rakennetaan ja viedään SFTP:llä käsin (`README.md`, "Testi ja tuotanto"): tekstimuutos, uusi artikkeli tai arvostelu näkyy tuotannossa vasta seuraavassa käsin tehdyssä julkaisussa. GitHub Pagesin tunneittainen ajo koskee vain testiä (`.github/workflows/pages.yml:16`). Artikkeleille on valmiit RPC:t (booking_51), mutta ei editoria (`docs/SAUNATIETOA.md:3`).
   - Miksi tärkeää: poikkeusilmoituksen, kausitekstin tai vahvistusviestin sanamuodon vaihto vaatii nyt kehittäjän. Verrokeissa (Bókun, FareHarbor) tuote-, sivu- ja viestitekstit ovat henkilökunnan muokattavissa.
   - Ratkaisu: (a) hallintaan näkymä "Tekstit" valmiiden RPC:iden päälle: haku avaimella tai tekstillä, ryhmittely (Sähköpostit · Kauppa · Sivusto), FI ja EN rinnakkain, paikkamerkkien tarkistus ennen tallennusta, ehdotus–hyväksyntä–julkaisu, versiohistoria ja palautus. Ensimmäinen vaihe: sähköpostit (näkyvät heti). Toinen vaihe: sivu- ja kauppatekstit tilalla "julkaistaan seuraavassa sivustopäivityksessä". (b) Saunatietoa-editori booking_51:n RPC:iden päälle. (c) Automaattinen tuotantojulkaisu, joka rakentaa ja vie sivuston, kun tekstit muuttuvat ja kerran yössä. Kohta (c) vaatii Joonaksen ja Koodarin päätöksen, koska nykyinen sääntö on, että vain Koodari julkaisee.
   - Hyväksymiskriteerit: manager muuttaa vahvistussähköpostin lauseen hallinnasta ja seuraava vahvistus käyttää uutta tekstiä; virheellinen paikkamerkki estää tallennuksen selkeällä viestillä; jokainen muutos näkyy historiassa (kuka, milloin, vanha arvo) ja on palautettavissa; vaiheen (c) jälkeen sivutekstin muutos on saunotus.fi:ssä ilman kehittäjää.
   - Tiedostot: uudet `booking/admin/views/texts.js` ja `booking/admin/views/articles.js`, `booking/admin/admin-navigation.js`, `src/site-texts.mjs` (paikkamerkkien validointi jaetuksi moduuliksi), julkaisuskripti (c).
   - Tietokanta: ei vaiheisiin (a) ja (b): RPC:t ovat olemassa. Tarkista ennen toteutusta, että tekstieditorin rooli ja oikeudet ovat tuotannossa (OLETUS) ja että tuotannon funktiot vastaavat repoa.
   - Riippuvuudet: HALL-KUORI-01 (paikka valikossa).

4. **SIVU-YHT-04 · PIENI · "Koulutukset" päävalikossa avautuu ulkoiselle sivustolle uuteen välilehteen**
   - Ongelma (VARMA): päävalikon "Koulutukset" vie osoitteeseen saunakoulutus.fi uuteen välilehteen (`content/site.json:45`), ruudunlukijalle "(avautuu uuteen välilehteen)". Muut päävalikon kohdat ovat sivuston sisäisiä. Kävijä poistuu kesken varauspolun.
   - Ratkaisu: näytä ulkoisen linkin merkki (↗) myös näkyvästi tai siirrä linkki alatunnisteeseen ja Yrityksille-sivulle. Päätös Joonakselle.
   - Hyväksymiskriteerit: kävijä näkee ennen klikkausta, että linkki vie toiselle sivustolle.
   - Tiedostot: `src/render.mjs`, `content/site.json`.
   - Tietokanta: ei.
   - Riippuvuudet: –

5. **SIVU-YHT-05 · PIENI · Pikkuvirheet teksteissä ja muodoissa**
   - Ongelma (VARMA): etusivun kortin otsikko "Yleinen vuoro (to, la-su)" käyttää yhdysmerkkiä, muualla ajatusviivaa (`content/site-texts.fallback.json:6827` vs. `:3673`); alatunnisteessa "Avoinna Ma–To 16–19, La–Su 14–19" isoilla alkukirjaimilla lauseen keskellä; EN-korteissa on tietoa, jota FI-kortissa ei ole ("from €180 · 2 h (Mon–Thu 19–21), 3 h (Fri–Sun 19–22)" vs. "alk. 180 € · 2 h"); "Oma savusaunavuoro" -kortin hintarivillä irrallinen sana "vaihtoehdot"/"options".
   - Ratkaisu: korjaa tekstit tietokannassa (tuontitiedosto Koodarille), yhtenäistä viikonpäivien lyhenteet pieniksi kirjaimiksi lauseen sisällä, sama sisältö molemmilla kielillä.
   - Hyväksymiskriteerit: FI- ja EN-etusivun kortit kertovat saman tiedon; ajatusviiva kaikissa väleissä.
   - Tiedostot: `content/site-texts.pending-import-<uusi>.json`.
   - Tietokanta: vain tekstien tuonti (ei skeemamuutosta).
   - Riippuvuudet: SIVU-YHT-03 helpottaa jatkossa.

#### SIVU-ETUSIVU (`/`, `/en/`)

Nykytila: hero (ovikuva, kaksi CTA:ta), "Valitse elämys" (5 korttia), viikko-ohjelma, Saunarituaali-ilta, arvostelut, tapahtumat, Saunatietoa-nauha, yrityksille-nauha, UKK. Työpöydällä noin 5 700 px, mobiilissa noin 8 600 px.

1. **SIVU-ETUSIVU-01 · PIENI · "Valitse elämys" -kortit ovat epätasaisia**
   - Ongelma (VARMA, kuva 1280 px): viidestä kortista kahdella (Yleinen vuoro, Oma savusaunavuoro) ei ole kuvaa, kolmella on; korttien tekstiosat ja hintarivit ovat eri korkeuksilla, ja kuvattomissa korteissa on suuri tyhjä alue. "Saunahoito ja saunotus" -kortissa on kaksi sisäkorttia, muissa ei.
   - Ratkaisu: kuva jokaiselle kortille (henkilökunta voi lisätä tuotekuvan hallinnan Tuotteet-näkymästä; toimituksellinen varakuva `cards.json`-kortille niille, joilla tuotekuvaa ei ole), hinta ja painike samalle tasolle (`margin-top:auto`), sisäkortit muutetaan samaksi hinta- ja linkkiriviksi kuin muissa.
   - Hyväksymiskriteerit: 1280 px:llä kaikkien korttien kuva, otsikko, hinta ja painike ovat samoilla korkeuksilla; 390 px:llä karuselli näyttää seuraavan kortin reunan (nykyinen toimiva ratkaisu säilyy).
   - Tiedostot: `src/render.mjs` (`card`, rivi 104), `src/styles.css`, `content/cards.json`.
   - Tietokanta: ei (kuvat ladataan hallinnasta).
   - Riippuvuudet: –

2. **SIVU-ETUSIVU-02 · PIENI · Hero ja ensimmäinen näkymä mobiilissa**
   - Ongelma (VARMA): mobiilissa hero vie koko ensimmäisen näytön ja painikkeet ovat sen alaosassa, mikä on hyvä, mutta toinen painike "Anna lahjaksi" on yhtä painava kuin varaus. Kortit alkavat vasta toisella näytöllä.
   - Ratkaisu: toissijainen CTA tekstilinkiksi tai pienemmäksi; lisää heron alle yhden rivin luottamusmerkki (★ 4,6 · 177 Google-arvostelua), joka on jo sivulla alempana.
   - Hyväksymiskriteerit: 390 × 844 näytöllä näkyy ilman vieritystä otsikko, yksi pääpainike ja arvosana.
   - Tiedostot: `src/home-front.mjs`, `src/render.mjs`, `src/styles.css`.
   - Tietokanta: ei.
   - Riippuvuudet: SIVU-YHT-01.

#### SIVU-SAUNAVUOROT (`/saunavuorot/`, `/en/sauna/`)

Nykytila: hero, viikko-ohjelma, yksityisvuorot, jälkilöylyt, UKK. Viikko-ohjelma päivittyy selaimessa (`week-live.js`) ja korostaa tämän päivän.

1. **SIVU-SAUNAVUOROT-01 · PIENI · Viikko-ohjelman painikkeet ja vapaat paikat**
   - Ongelma (VARMA): "Varaa"-painikkeet ovat ääriviivapillereitä, paitsi kuluvan päivän, joka on täytetty ruskea pilleri; ruskea täyttö ei ole muualla käytetty painikeväri. Vapaiden paikkojen määrää ei näytetä, vaikka sama data (`public_availability_all`) haetaan jo; täysi vuoro piilotetaan kokonaan.
   - Ratkaisu: tämän päivän korostus taustalla ja "Tänään"-merkillä (on jo), painike sama kuin muissa; vuoron alle "4 paikkaa vapaana" kun alle 5 jäljellä ja "Täynnä – katso seuraava" täyden vuoron kohdalla piilottamisen sijaan.
   - Hyväksymiskriteerit: kaikki viikko-ohjelman painikkeet samaa tyyliä; vähissä olevat paikat näkyvät; täysi vuoro ei katoa, vaan näkyy himmennettynä.
   - Tiedostot: `src/render.mjs` (`week`, rivi 128), `booking/shop/src/week-live.js`, `src/styles.css`.
   - Tietokanta: ei.
   - Riippuvuudet: –

#### SIVU-HOIDOT (`/hoidot-rituaalit/`, `/en/treatments-rituals/`)

Nykytila: pisin sivu (työpöydällä noin 8 400 px, mobiilissa noin 14 100 px): johdanto, "Mistä aloittaa", hoidot ja saunotukset, avoimet rituaalit, rituaalit ryhmille, "Näin saunotus etenee", "Sopiiko tämä minulle", arvostelut, UKK.

1. **SIVU-HOIDOT-01 · KESKI · Sivu on liian pitkä ilman sisäistä navigaatiota**
   - Ongelma (VARMA): mobiilissa 14 000 px, eikä sivulla ole hyppylinkkejä kuten Info-sivulla (`/info/`, jossa toimiva välilehtirivi heron alla). "Mistä aloittaa?" -osio yrittää ohjata, mutta linkkien jälkeen kävijä on silti pitkällä sivulla.
   - Ratkaisu: Info-sivun hyppyrivi myös tänne (Hoidot · Avoimet rituaalit · Ryhmille · Näin se etenee · UKK); arvostelut ja "Sopiiko tämä minulle" lyhyemmiksi; korttien kuvasuhteet samoiksi (nyt "Hoidot ja saunotukset" -ruudukossa yksi kortti ilman kuvaa ja eri korkeuksia).
   - Hyväksymiskriteerit: jokaiseen osioon pääsee yhdellä napautuksella heron alta; mobiilin kokonaispituus lyhenee vähintään 25 %.
   - Tiedostot: `src/treatments-page.mjs`, `src/styles.css`, `content/pages/treatments.json`.
   - Tietokanta: ei (tekstimuutokset tuontitiedostona).
   - Riippuvuudet: –

#### SIVU-YRITYKSET (`/yritykset/`, `/en/companies/`)

Nykytila: hero kolmella painikkeella (Yleiset vuorot, Yksityisvuorot, Pyydä tarjous), "Mitä haluatte tehdä?" kahdella valintakortilla ja kolme linkkikorttia.

1. **SIVU-YRITYKSET-01 · PIENI · Sama valinta kolmeen kertaan**
   - Ongelma (VARMA): kävijä näkee kolme kertaa saman jaon (heron painikkeet, kaksi valintakorttia, kolme linkkikorttia). Yritysasiakas ei tarvitse kolmea reittiä samaan paikkaan.
   - Ratkaisu: heroon yksi painike ("Pyydä tarjous"), valintakortit jäävät, alin linkkikorttirivi korvataan referensseillä tai yritysasiakkaan käytännön tiedoilla (laskutus, ryhmäkoko, tarjoilu).
   - Hyväksymiskriteerit: sivulla on yksi ensisijainen polku kumpaankin tarpeeseen.
   - Tiedostot: `src/render.mjs` (`companies`, rivi 490), `content/pages/companies.json`.
   - Tietokanta: ei.
   - Riippuvuudet: –

#### SIVU-INFO (`/info/`, `/en/info/`)

Nykytila: hyvä rakenne: hyppyrivi, neljä osiota ikoneineen, kartta, UKK ja peruutusehtojen nosto.

1. **SIVU-INFO-01 · PIENI · Peruutusohje ei kerro, miten peruutetaan**
   - Ongelma (VARMA/OLETUS): nosto sanoo "Yleisen vuoron voi perua maksutta vähintään 48 tuntia ennen alkua", mutta asiakas ei voi perua vahvistettua varausta itse verkossa (`booking/README.md`, Arkkitehtuuri: peruutus sähköpostilla). Teksti käyttää asetusta `customer_change_hours_before`, joka on nimeltään muutosraja (`docs/SIVUTEKSTIT.md`, `BINDINGS`) (OLETUS: peruutus- ja muutosraja ovat sama luku tarkoituksella).
   - Ratkaisu: lisää lauseeseen tapa ("Peru vastaamalla vahvistusviestiin tai sähköpostilla savusauna@saunotus.fi") tai, jos HALL/KAUPPA-ehdotus asiakkaan omasta peruutuksesta toteutetaan, linkki tilaussivulle.
   - Hyväksymiskriteerit: ohje kertoo sekä aikarajan että tavan.
   - Tiedostot: tekstituonti (`page.info.cancel_text`).
   - Tietokanta: vain teksti.
   - Riippuvuudet: KAUPPA-TILAUS-kohdat (luku 3.2).

#### SIVU-SAUNATIETOA (`/saunatietoa/`, tagisivut)

Nykytila: listaus, tagisuodattimet, artikkelikortit, "Muut aiheet" -tagipilvi. Tässä koonnissa 6 artikkelia ja 22 tagisivua.

1. **SIVU-SAUNATIETOA-01 · PIENI · Tagisivuja on enemmän kuin sisältöä**
   - Ongelma (VARMA, paikallinen koonti): 22 tagisivusta 20 sisältää vain yhden artikkelin. Ohuet sivut eivät auta kävijää ja voivat heikentää hakukonenäkyvyyttä. Tagit ovat pienellä kirjaimella, muut sirut versaalilla.
   - Ratkaisu: luo tagisivu ja näytä tagi vain, kun sillä on vähintään 2 julkaistua artikkelia; muut tagit `noindex` tai pois. Sirujen kirjainkoko yhtenäiseksi.
   - Hyväksymiskriteerit: jokaisella indeksoitavalla tagisivulla ≥ 2 artikkelia; sitemapissa ei yhden artikkelin tagisivuja.
   - Tiedostot: `src/articles/` (tagisivujen generointi), `scripts/build.mjs`.
   - Tietokanta: ei.
   - Riippuvuudet: –

#### SIVU-JUOMAT (`/juomat/`, `/en/drinks/`: kylmälaitteen QR-maksu)

Nykytila: QR-koodilla avattava itsepalvelusivu juomien maksuun.

1. **SIVU-JUOMAT-01 · PIENI · Sivu jää tyhjäksi: koonnista puuttuu kaksi moduulia**
   - **Tila 13.11.2026:** Valmis, PR #350. Puuttuvat moduulit lisätty, ja `scripts/module-imports.mjs` tarkistaa importit buildissa.
   - Ongelma (VARMA paikallisessa koonnissa): `/juomat/` ja `/en/drinks/` lataavat `gift-texts.js`:n, joka tuo `plural.js`:n ja `hold-texts.js`:n (`booking/shop/src/gift-texts.js:1–2`, lisätty muutoksessa #293). `scripts/build-pages.mjs:108` (`DRINK_PAY_UI`) ei kopioi niitä sivun viereen, joten selain saa 404:n ja koko moduulipuu kaatuu: sivulla näkyy vain testibanneri. OLETUS: sama vika on tuotannossa, jos saunotus.fi on rakennettu muutoksen #293 jälkeen. Linkkitarkistus (`scripts/check.mjs`) ei seuraa ES-moduulien importteja, joten vika ei näy buildissa.
   - Ratkaisu: lisää `plural.js` ja `hold-texts.js` listaan `DRINK_PAY_UI` (tai kopioi koko importtipuu automaattisesti); lisää `scripts/smoke-pages.mjs`:ään juomasivun lataus ilman 404:ää; näytä sivulla virheteksti, jos moduuli tai verkko ei vastaa.
   - Hyväksymiskriteerit: `node scripts/smoke-pages.mjs` lataa `/juomat/?mock=1` ja `/en/drinks/?mock=1` ilman 404:ää ja näyttää tuotteen; tuotannon QR-koodi avaa toimivan sivun.
   - Tiedostot: `scripts/build-pages.mjs`, `scripts/smoke-pages.mjs`, `booking/drinks/drinks.js`.
   - Tietokanta: ei.
   - Riippuvuudet: – (kiireellinen).

#### SIVU-404, SIVU-EHDOT, SIVU-TIETOSUOJA

1. **SIVU-404-01 · PIENI · 404-sivu kahdella kielellä päällekkäin**
   - Ongelma (VARMA): sivulla on suomi ja englanti allekkain, kaksi samannäköistä painiketta. Teksti kehottaa "tutustu saunavuoroihin", mutta linkkiä saunavuoroihin ei ole.
   - Ratkaisu: kieli polun mukaan (`/en/…` → EN), kolme suoraa linkkiä (Saunavuorot, Varaa, Yhteystiedot).
   - Hyväksymiskriteerit: `/en/olematon` näyttää englanninkielisen 404:n; jokaisessa kehotuksessa on linkki.
   - Tiedostot: `src/render.mjs` (`notFound`, rivi 549), palvelimen 404-asetus (EN-polulle oma tiedosto).
   - Tietokanta: ei.
   - Riippuvuudet: –

Ehdot ja tietosuoja (`/ehdot/`, `/tietosuoja/`): rakenne kunnossa; ei omia ehdotuksia. Huom.: EN-tietosuoja puuttuu (`docs/VERTAILU.md`), mikä on kansainvälisille asiakkaille puute (sisältyy kohtaan SIVU-EN-01).

#### SIVU-EN (englanninkieliset sivut)

1. **SIVU-EN-01 · KESKI · Englanninkielinen sisältö on koneellisesti käännetty ja osin eri kuin suomeksi**
   - Ongelma (VARMA): `README.md` toteaa EN-tekstit koneellisesti käännetyiksi. Esimerkkejä: "Sauna Treatment and Saunotus", "After Session Sauna (jälkilöylyt) in the Smoke Sauna"; korttien tiedot poikkeavat FI-versiosta (SIVU-YHT-05); EN-tietosuojaa ei ole; arvosteluosio puuttuu EN-sivulta, koska englanninkielisiä arvosteluja on alle 3 (`README.md`, Arvostelut).
   - Ratkaisu: natiivitarkistus kerralla koko sanastolle (sanasto: saunotus = "guided sauna ritual (saunotus)", jälkilöylyt = "after-sauna session", yleinen vuoro = "public session"); EN-tietosuoja; EN-arvosteluosio näyttää suomenkieliset arvostelut käännösmerkinnällä tai vain arvosanan.
   - Hyväksymiskriteerit: natiivi lukija hyväksyy etusivun, varaussivun, hoidot, infon ja ehdot; samaa termiä käytetään joka paikassa.
   - Tiedostot: tekstituonti, `content/pages/privacy.json`.
   - Tietokanta: vain tekstit.
   - Riippuvuudet: SIVU-YHT-03.

### 3.2 Varauskauppa (booking/shop/)

Yleisarvio: polku on toimiva ja paikoin hyvin viimeistelty. Hinnat näkyvät heti, 15 minuutin paikanpidon laskuri on selkeä ja saavutettava (`role=timer`, portaittaiset ilmoitukset, `hold-ui.js`), Montonion maksutavat näkyvät logoina ja lahjakoodin tunnistus on fiksu. Klikkausmäärä on verrokkien tasoa: yleinen vuoro kahdelle 7 klikkausta ja 3 tekstikenttää maksuun asti, yksityisvuoro yritykselle verkkolaskulla 6 klikkausta ja 10 kenttää. Ero ammattimaisiin palveluihin syntyy kassan rakenteesta mobiilissa, lomakevirheistä ja vahvistuksen jälkeisestä kokemuksesta.

Mittaukset (VARMA, kokeilutila 390 × 844): tuotesivun kalenteri alkaa noin 760 px:n kohdalta, kassan nimikenttä noin 930 px:n, lähetysnappi noin 2 370 px:n ja kokonaishinta noin 2 700 px:n kohdalta eli napin alapuolella.

#### KAUPPA-ETUSIVU ja selaus (`/varaa/`, päivänäkymä `#/paiva/<pvm>`)

Nykytila: hero, valinta "Selaa kategorioittain / Selaa päivän mukaan", kategoriasirut ja tuotekortit (kuva, lyhyt kuvaus, kesto, hinta, Valitse). Päivänäkymässä viikkoliuska vapaa/täynnä-pisteineen, Tänään-painike, päivävalitsin ja tuotekortit haitarina; tyhjälle päivälle ehdotetaan seuraavaa vapaata päivää.

1. **KAUPPA-SELAUS-01 · PIENI · Päivänäkymän korteissa tuotteen nimi toistuu kuvauksessa**
   - Ongelma (VARMA): kortit näyttävät "Saunahoito Saunahoito on lempeä…", "Saunotus Saunotus on…": `prodCard` ottaa otteen pitkästä kuvauksesta, joka alkaa `<h2>`-otsikolla, eikä käytä lyhyttä kuvausta (`booking/shop/src/shop.js:477`, `short-desc.js` `derivedExcerpt`). Hinta on listakortissa "99 € (sis. 1 hlö, lisähenkilö +35 €)" mutta päiväkortissa pelkkä "99 €". Selitteessä "vapaana" pienellä, "Täynnä" isolla.
   - Ratkaisu: päiväkortti käyttää lyhyttä kuvausta (`short_description`), varalla ote ilman alun otsikkoa; sama hintamerkintä kuin listakortissa; selitteet samaan kirjainkokoon.
   - Hyväksymiskriteerit: yksikään ote ei ala tuotteen nimellä; hinta on samassa muodossa kaikissa korteissa.
   - Tiedostot: `booking/shop/src/shop.js`, `booking/shop/src/short-desc.js`.
   - Tietokanta: ei.
   - Riippuvuudet: –

2. **KAUPPA-SELAUS-02 · KESKI · Listakorteista puuttuu "seuraava vapaa aika"**
   - **Tila 13.11.2026:** Huomioitava PR #346 (booking_289): saatavuushaut on yhdistetty tiedostoon `booking/shop/src/product-months.js`, joten seuraava vapaa aika rakennetaan sen päälle eikä uusilla kutsuilla.
   - Ongelma (VARMA): kategorianäkymän kortit eivät kerro, milloin tuotteelle on seuraavaksi tilaa; asiakas avaa tuotteen ja selaa kalenteria. Fresha ja Timma näyttävät seuraavan vapaan ajan listassa (OLETUS, yleistieto).
   - Ratkaisu: korttiin "Seuraava vapaa: la 14.11. klo 14.00" olemassa olevalla `public_availability_all`-kutsulla (`availability-months.js`), haettuna listan piirron jälkeen.
   - Hyväksymiskriteerit: tieto ei viivästytä listan ensipiirtoa; virhetilanteessa kortti näkyy kuten nyt.
   - Tiedostot: `booking/shop/src/shop.js`, `booking/shop/src/availability-months.js`, `booking/shop/src/shop.css`.
   - Tietokanta: ei.
   - Riippuvuudet: –

#### KAUPPA-TUOTE: tuotesivu ja vuorovalinta (`#/tuote/<slug>`)

1. **KAUPPA-TUOTE-01 · PIENI · Työpöydällä vuorolista jää kapeaan sarakkeeseen, mobiilissa hero vie ensimmäisen näytön**
   - Ongelma (VARMA): päivän valinnan jälkeen vuorot avautuvat kalenterin alle vasempaan sarakkeeseen ja oikea puoli jää tyhjäksi (`shop.css:659–692`, `shop.js:695–745`). Tuotekuva-hero on vähintään 300 px myös kassalla, vahvistuksessa ja tilaussivulla (`shop.css:226`), joten mobiilissa ensimmäinen näkymä on lähes pelkkää kuvaa.
   - Ratkaisu: vuorot oikeaan sarakkeeseen tai täysleveänä kalenterin alle; kassalle, vahvistukseen, tilaukseen ja maksulinkkisivulle tiivis hero (`hero-compact`, noin 120 px, mobiilissa ilman kuvaa).
   - Hyväksymiskriteerit: 1280 px:llä vuorot näkyvät ilman vieritystä kalenterin vieressä; 390 × 844:llä vahvistussivun laskuri ja kassan valittu vuoro näkyvät ensimmäisessä näkymässä.
   - Tiedostot: `booking/shop/src/shop.css`, `booking/shop/src/shop.js` (`setHero`), `booking/shop/src/order.js`.
   - Tietokanta: ei.
   - Riippuvuudet: –

#### KAUPPA-KASSA: varauslomake (`#/varaa/<sääntö>/<pvm>/<tuote>`)

Nykytila: yhteenvetopalkki ja "Vaihda päivää tai aikaa", henkilömäärä, yksityinen/yritys, yhteystiedot, lisäpalvelut, suljettu koodikenttä, terveiset, peruutusehto, ehtoruutu ja markkinointilupa. Työpöydällä yhteenveto on kiinteänä sivupalkkina, mobiilissa lomakkeen jälkeen.

1. **KAUPPA-KASSA-01 · PIENI · Mobiilissa kokonaishinta ja 15 minuutin ehto ovat lähetysnapin alapuolella**
   - Ongelma (VARMA): alle 900 px:n leveydellä yhteenveto, summa, maksuohje ("Paikka varataan 15 minuutiksi, kun jatkat maksamaan") ja maksutavat tulevat "Jatka maksamaan" -napin jälkeen (`shop.js:1159, 1171–1175`; kahden sarakkeen asettelu vasta ≥ 900 px, `shop.css:90`). Asiakas sitoutuu näkemättä summaa. Tämä on kaupan suurin yksittäinen konversio- ja luottamusriski. Booking-tyyppiset palvelut ja Fresha näyttävät summan kiinteänä palkkina.
   - Ratkaisu: alle 900 px kiinteä alapalkki "Yhteensä 58,00 € · Jatka maksamaan" ja maksuohje palkin yläpuolella; työpöydän sivupalkki säilyy. Sama hoitokulun tiedot-vaiheeseen.
   - Hyväksymiskriteerit: 390 × 844:llä summa ja pidon ehto näkyvät samassa näkymässä kuin lähetysnappi; summa päivittyy henkilömäärän, lisäpalvelujen ja koodin mukaan; palkki ei peitä fokusoitua kenttää.
   - Tiedostot: `booking/shop/src/shop.js` (`viewCheckout`), `booking/shop/src/treatment-ui.js`, `booking/shop/src/shop.css`.
   - Tietokanta: ei.
   - Riippuvuudet: –

2. **KAUPPA-KASSA-02 · KESKI · Lomakevirheet ovat geneerisiä eivätkä näy mobiilissa**
   - Ongelma (VARMA): tyhjä tai virheellinen lähetys näyttää yhden viestin "Täytä kaikki pakolliset kentät." myös silloin, kun sähköposti on täytetty väärin (`shop.js:832`); kenttiin ei aseteta `aria-invalid`-määritettä eikä kenttäkohtaista tekstiä. Mobiilissa fokus siirtyy nimikenttään (y ≈ 400), mutta virhe on napin vieressä (y ≈ 1 835) eli ruudun ulkopuolella (`shop.js:1133`). Pakollisia kenttiä ei ole merkitty (`shop.js:790`), vuosikorttilomakkeessa on (`shop.js:361`). Y-tunnuskentässä `inputmode=numeric`, vaikka vihje pyytää muotoa 1234567-8 (iOS:n numeronäppäimistössä ei ole viivaa) (`shop.js:805`).
   - Ratkaisu: virhe kentän alle (`aria-describedby`, `aria-invalid`); virhekoonti lomakkeen alkuun linkkeineen; omat viestit sähköpostille, puhelimelle, Y-tunnukselle ja OVT:lle; pakolliset kentät merkitty; Y-tunnukselle `inputmode=text` tai viiva automaattisesti. Yksi apuri kaikille kaupan lomakkeille (vuoro, hoito, jono, kurssi, vuosikortti, lahjakortti).
   - Hyväksymiskriteerit: tyhjä lähetys näyttää virheen fokusoidun kentän vieressä ja koonnin ruudulla; ruudunlukija lukee kentän virheen; sama toteutus kaikissa kaupan lomakkeissa.
   - Tiedostot: `booking/shop/src/shop.js` (`field`, `customerFields`, `legalFields`), `treatment-ui.js`, `waitlist-ui.js`, `training-signup.js`, `i18n.js`, `shop.css`.
   - Tietokanta: ei (uudet tekstiavaimet tuontitiedostona).
   - Riippuvuudet: YHT-07.

3. **KAUPPA-KASSA-03 · PIENI · Luottamuselementit ja lahjakorttiohje näkyviin kassalle**
   - Ongelma (VARMA): kassalla maksutavat ovat pelkkää tekstiä ("Maksutavat: Maksa verkossa ja lahjakortti."), logot vain alatunnisteessa pieninä; turvallisesta maksusta (Montonio) ei kerrota. Lahjakortin haltija ei tiedä, mihin koodi syötetään: ohje "Lahjakortin koodia ei syötetä tähän…" näkyy vasta, kun suljettu alennuskoodiosio avataan (`shop.js:1054`, `discount-texts.js:10`).
   - Ratkaisu: kassan yhteenvetoon maksutapalogot (`online-pay-ui.js` `payMark`), rivi "Turvallinen maksu Montonion kautta" ja näkyvä "Lahjakortti? Syötät koodin maksuvaiheessa."
   - Hyväksymiskriteerit: logot ja lahjakorttiohje näkyvät FI/EN ilman lisäklikkausta.
   - Tiedostot: `booking/shop/src/shop.js`, `booking/shop/src/pay-choices-texts.js`, `booking/shop/src/shop.css`.
   - Tietokanta: ei.
   - Riippuvuudet: KAUPPA-KASSA-01.

#### KAUPPA-MAKSU ja KAUPPA-VAHVISTUS (`/varaa/vahvistus/`)

Nykytila: vahvistussivulla tilausnumero, palvelu, aika, henkilöt, summa, maksun tila, pitolaskuri, maksutavat (verkkopankki, kortti, Apple Pay, Google Pay, MobilePay, lahjakortti), uima-asuohje, "Lisää kalenteriin", muutos- ja reittiohje.

1. **KAUPPA-MAKSU-01 · PIENI · Vanhentuneet ja ristiriitaiset maksutekstit**
   - **Tila 13.11.2026:** Osittain, PR #350. Visma Pay -lause on poistettu (FI ja EN, tuonti 145). Jäljellä: maksun tila laskulla ja vanhentuneella varauksella sekä tilaussivun "Verkkomaksu ei ole vielä käytössä" ja himmennetty maksunappi.
   - Ongelma (VARMA): asiakkaalle näkyy "Maksu paikan päällä. Verkkomaksu (Visma Pay) otetaan käyttöön myöhemmin." (`booking/shop/src/i18n.js:47, 126`; tietokannan varateksti `content/site-texts.fallback.json:20641`, EN `:20634`) aina, kun pitotila tai verkkomaksu ei ole päällä tai maksutapojen haku epäonnistuu (`shop.js:1165, 1278`). Montonio on nykyinen maksunvälittäjä. Maksun tila "Maksamatta (maksu paikan päällä)" näkyy myös yrityslaskulla ja vanhentuneella verkkomaksuvarauksella (`shop.js:1221, 1257`). Tilaussivulla "Verkkomaksu ei ole vielä käytössä" ja himmennetty "Maksa maksamaton osa" (`order.js:286–288`, `order-texts.js:15`).
   - Ratkaisu: `payLater` → "Maksu paikan päällä."; "ei vielä käytössä" -tekstit pois; maksun tila valitaan tilan mukaan (lasku → "Laskutetaan", vanhentunut → "Ei veloitettu").
   - Hyväksymiskriteerit: sanoja "Visma Pay" tai "ei vielä käytössä" ei näy missään asiakasnäkymässä FI/EN; yksikkötestit tiloille.
   - Tiedostot: `booking/shop/src/i18n.js`, `booking/shop/src/order-texts.js`, `booking/shop/src/shop.js`, `booking/shop/src/order.js`.
   - Tietokanta: ei skeemamuutosta; tietokannan tekstit `ui.shop.pay_later` ja `ui.order.pay_rest_soon` päivitetään tuontitiedostolla (Koodari).
   - Riippuvuudet: – (kiireellinen).

2. **KAUPPA-VAHVISTUS-01 · KESKI · Vahvistussivu toistaa itseään eikä johda tilaussivulle**
   - **Tila 13.11.2026:** Huomioitava PR #347 (booking_284): asiakas voi pienentää henkilömäärää itse tilaussivulla ja saada automaattisen osahyvityksen (lippu `customer_auto_partial_refund_enabled`). "Hallitse varausta" -tekstin pitää mainita tämä, kun lippu on päällä.
   - Ongelma (VARMA): pitotilassa H1 "Viimeistele varaus", H2 "Varauksesi odottaa maksua" ja merkki "Varaus odottaa maksua"; vanhentuneessa tilassa H1 ja H2 "Varaus on vanhentunut", merkki, H3 "Paikkavaraus vanheni", sama lause tekstinä ja kaksi kilpailevaa toimintoa "Tee uusi varaus" (kulta) ja "Yritä uudelleen" (vihreä) (`shop.js:1275, 1281–1282`, `hold-ui.js:36`). Sivulta ei ole linkkiä tilaussivulle (`/tilaus/?t=`), jossa ovat kuitit, lisäykset ja peruutuspyyntö (`shop.js:1200–1331`), eikä siinä kerrota, että vahvistus on lähetetty sähköpostiin. Vahvistussivu ohjaa peruuttamaan sähköpostilla (`i18n.js` `changeInfo`/`changeLocked`), vaikka tilaussivulla on peruutuspyyntölomake (`order.js:386–420`).
   - Ratkaisu: jokaisessa tilassa (odottaa maksua, vanhentunut, vahvistettu, peruttu) yksi otsikko, yksi tilamerkki ja yksi päätoiminto; vahvistetussa "Vahvistus on lähetetty osoitteeseen …" ja painike "Hallitse varausta"; peruutusohje sama kuin tilaussivulla; vahvistussivun peruutus omaan vahvistusdialogiin `confirm()`-ikkunan sijaan, virheenkäsittelyineen (`shop.js:1268–1273`, `order.js:412`).
   - Hyväksymiskriteerit: jokaisessa tilassa yksi H1 ja yksi ensisijainen painike; vahvistetusta tilasta yksi klikkaus tilaussivulle.
   - Tiedostot: `booking/shop/src/shop.js` (`viewConfirmation`), `confirm-heading.js`, `hold-ui.js`, `i18n.js`, `order.js`.
   - Tietokanta: ei (OLETUS: tilaussivun token saadaan vahvistuksen datasta; jos ei, `public_get_booking` palauttaa myös `order_token`-kentän, luonnos Bottiavustukselle).
   - Riippuvuudet: KAUPPA-MAKSU-01.

#### KAUPPA-TILAUS: asiakkaan tilaussivu (`/tilaus/`)

Nykytila: erittäin kattava (varaukset, rivit, maksutila, maksu, lahjakortti, kuitit, ohjeet, lisäykset, peruutuspyyntö), noin 3 500 px pitkä.

1. **KAUPPA-TILAUS-01 · PIENI · Laskutetulla yritystilauksella näkyvät maksutoiminnot**
   - Ongelma (VARMA): merkin "Laskutettu" vieressä näkyvät himmennetty "Maksa maksamaton osa (131 €)", teksti "maksu paikan päällä" ja lahjakortin lunastus (`order.js:276–290`): ne tarkistavat vain `invoice_locked`-tiedon, eivät `paysByInvoice`-tietoa kuten `pay-choices.js`.
   - Ratkaisu: laskulla maksavalle piilotetaan maksunappi ja lahjakortin lunastus; tilalle "Lasku lähetetään osoitteeseen …".
   - Hyväksymiskriteerit: laskutetulla tilauksella ei näy yhtään maksutoimintoa.
   - Tiedostot: `booking/shop/src/order.js`.
   - Tietokanta: ei.
   - Riippuvuudet: KAUPPA-MAKSU-01.

2. **KAUPPA-TILAUS-02 · PIENI · Englanninkielisellä tilaussivulla tuotenimet suomeksi**
   - Ongelma (VARMA): varausten nimet ja lisäysvalikko näkyvät suomeksi ("Yleinen saunavuoro", "Pyyhe × 2"), koska käytetään `r.product_name`-kenttää (`order.js:231, 338, 366`; muutosnäkymä `shop.js:1427`); muutosnäkymä tulostaa "1 guests" (`i18n.js:101`, `shop.js:1376`).
   - Ratkaisu: nimi `product_id`:n perusteella `static-products.json`:sta kuten vahvistussivulla (`shop.js:1210`); monikkoapuri (`plural.js`).
   - Hyväksymiskriteerit: `/en/order/` ei näytä suomenkielisiä tuotenimiä; "1 guest" / "2 guests".
   - Tiedostot: `booking/shop/src/order.js`, `booking/shop/src/shop.js`, `booking/shop/src/i18n.js`.
   - Tietokanta: ei pakollinen (valinnainen: `public_get_order` palauttaa myös `product_name_en`).
   - Riippuvuudet: YHT-04.

#### KAUPPA-JONO, KAUPPA-LAHJAKORTTI ja muut kulut

1. **KAUPPA-JONO-01 · PIENI · Täyden tapahtuman jonotuslinkki rikkoutuu sivun päivityksessä**
   - **Tila 13.11.2026:** Valmis, PR #350.
   - Ongelma (VARMA): jonotussivu toimii listalta tultaessa, mutta päivitys tai suora linkki (esim. sähköpostista) antaa "Vuoroa ei löytynyt" (`waitlist-ui.js:11–17`), koska tapahtumatuote lisätään `state.catalog`iin vain listanäkymässä (`shop.js:313`).
   - Ratkaisu: reitti `jono` hakee tapahtumat ja puuttuvat tapahtumatuotteet ennen `viewWaitlist`-kutsua.
   - Hyväksymiskriteerit: `#/jono/<sääntö>/<pvm>/<tuote>` toimii sivun päivityksen jälkeen; e2e-testi.
   - Tiedostot: `booking/shop/src/shop.js` (`route`), `booking/shop/src/waitlist-ui.js`.
   - Tietokanta: ei.
   - Riippuvuudet: –

2. **KAUPPA-LAHJAKORTTI-01 · PIENI · Lahjakorttisivun kori on sivun lopussa**
   - Ongelma (VARMA): lahjakorttisivu on muuten ammattimainen (avoin kortti ja paketit), mutta "Tilauksesi" on sivun lopussa ilman kiinteää ilmaisinta; mobiilissa (noin 7 200 px) asiakas ei näe, että valinta meni koriin.
   - Ratkaisu: kiinteä "Tilauksesi: 2 korttia · 116 € · Jatka" -palkki, kun korissa on jotain.
   - Hyväksymiskriteerit: korin sisältö ja summa näkyvät koko ajan, kun kori ei ole tyhjä.
   - Tiedostot: `booking/shop/src/gift.js`, `booking/shop/src/gift-ui.js`, `booking/shop/src/shop.css`.
   - Tietokanta: ei.
   - Riippuvuudet: KAUPPA-KASSA-01 (sama palkkikomponentti).

#### KAUPPA-YHT: kaikkia kulkuja koskevat

1. **KAUPPA-YHT-01 · KESKI · Vuoro- ja hoitokulku tuntuvat eri tuotteilta**
   - Ongelma (VARMA): hoitokulussa numeroidut vaiheet ja oma tarkistusvaihe (9 klikkausta, 5 näkymää), vuorokulussa ei vaiheistusta; pääpainike on vuorokassassa kultainen (`shop.js:1040`), hoitokulussa vihreä (`treatment-ui.js:188, 257`), vanhentuneessa näkymässä molemmat rinnakkain; latausnäkymä on pelkkä "Ladataan…" 60 px:n täytteellä (`shop.css:7`, `shop.js:174`), joten asettelu hyppää.
   - Ratkaisu: kevyt vaihepalkki kaikkiin kulkuihin (1 Valinta → 2 Tiedot → 3 Maksu → 4 Vahvistus); yksi pääpainikkeen tyyli; runkonäkymät "Ladataan…"-tekstin tilalle.
   - Hyväksymiskriteerit: kaikissa kulun näkymissä sama vaihepalkki ja painiketyyli; ei asettelun hyppyä siirtymissä.
   - Tiedostot: `booking/shop/src/shop.js`, `treatment-ui.js`, `training-signup.js`, `hold-ui.js`, `shop.css`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-02.

2. **KAUPPA-YHT-02 · PIENI · Saavutettavuuden pikakorjaukset**
   - Ongelma (VARMA): henkilömäärän −/+ -painikkeiden nimi on pelkkä "−"/"+" (`shop.js:1012–1013`; hoitokulussa oikein "Vähemmän henkilöitä"); kalenteripäivän nimi "lauantai 14. marraskuuta, 6" ilman yksikköä (`shop.js:729`); otsikkotasot hyppäävät h1 → h3 (`shop.js:330, 709`); fokusreunus on kolmea väriä (sivusto sininen #1d6fd8 `src/styles.css:15`, kauppa `--ink`, lahjakortti kulta `shop.css:403`); OLETUS: päivänäkymän koko tuloslista `aria-live`-alueena (`shop.js:558`) on ruudunlukijalla meluisa.
   - Ratkaisu: nimet "Vähemmän henkilöitä" / "Enemmän henkilöitä"; "6 vapaata vuoroa"; otsikot h2; yksi fokusväri sivustolle ja kaupalle; `aria-live` vain tulosmäärään.
   - Hyväksymiskriteerit: axe-ajossa ei otsikkotason hyppyjä eikä nimettömiä painikkeita.
   - Tiedostot: `booking/shop/src/shop.js`, `booking/shop/src/shop.css`, `src/styles.css`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-07.

### 3.3 Hallinta (booking/admin/)

Yleisarvio: toiminnoiltaan laaja ja paikoin erinomainen (tilausnäkymä v3, lahjakorttien pikajatko, hiljaiset ajat, raportit), mutta näkymät on rakennettu yksi kerrallaan omilla ratkaisuillaan, ja osa toiminnoista on yhä kehittäjän varassa. Joonas käyttää hallintaa enimmäkseen puhelimella (`docs/asetukset-uudistus.md`) ja vastaanotto tabletilla, joten mobiili ja tabletti ovat hallinnassa ensisijaisia.

Näkymätiedostojen kattavuus: kaikki `booking/admin/views/`-hakemiston 63 tiedostoa on käyty läpi, ja ne on jaettu osioihin näin:

| Osio | Tiedostot `booking/admin/views/` |
|---|---|
| HALL-KUORI | `nav-group.js` (+ `admin.js`, `admin-navigation.js`, `index.html`, `quick-search.js`) |
| HALL-PAIVA | `day.js`, `dayparts.js`, `day-memos.js` |
| HALL-KALENTERI | `calendar.js` |
| HALL-UUSI | `newbooking.js`, `resbooking.js`, `availability.js`, `legs.js` |
| HALL-TARKISTA | `review.js`, `therapist.js` |
| HALL-TILAUKSET | `orders.js`, `talous-orders.js`, `reservations.js` |
| HALL-TILAUS | `order-view.js`, `order-summary.js`, `order-contents.js`, `order-card.js`, `order-card-delete.js`, `order-add.js`, `order-cancel-flow.js`, `order-reservation-bridge.js`, `refund-cancel.js`, `link-deadline.js`, `shared.js` |
| HALL-ASIAKKAAT | `customers.js`, `customer-view.js`, `customerform.js`, `annual-card-panel.js` |
| HALL-KASSA | `pos.js` (+ `pos-screen.js`, `pos-logic.js`, `checkoutx-pos.js`) |
| HALL-TALOUS | `talous.js`, `talous-payments.js`, `talous-receipts.js`, `talous-reports.js`, `talous-sales-chart.js`, `talous-analytics.js`, `talous-ui.js` |
| HALL-AVOIMET | `paylink-watch.js`, `refund-watch.js` |
| HALL-LASKUT | `invoices.js` |
| HALL-LAHJAKORTIT | `lahjakortit.js`, `talous-giftcards.js`, `talous-vouchers.js`, `voucher-redeem.js` |
| HALL-ALENNUS | `discounts.js` |
| HALL-TUOTTEET | `products.js`, `productimage.js`, `productoptions.js`, `product-suggestions.js`, `addons.js` |
| HALL-TAPAHTUMAT | `events.js` |
| HALL-HILJAISET | `quiet.js` |
| HALL-KOULUTUKSET | `koulutukset.js` |
| HALL-VIESTIT | `messages.js`, `customer-message-panel.js` |
| HALL-TILAT | `resources.js` |
| HALL-SULUT | `blocks.js`, `closures.js` |
| HALL-ASETUKSET | `settings.js`, `calendar-export.js`, `fee-rules-panel.js` |
| HALL-KAYTTAJAT | `users.js`, `shift-staff-panel.js` |

#### HALL-KUORI: kirjautuminen, yläpalkki, päävalikko, pikahaku

Nykytila: kirjautumiskortti (sähköposti + salasana). Kirjautuneena tummanvihreä yläpalkki: logo, pikahaku, "+ Uusi varaus", "✓ Tarkista (n)" ja käyttäjävalikko. Vasemmalla 11 kohdan päävalikko (Päivä, Kalenteri, Tilaukset, Asiakkaat, Lahjakortit, Kassa ja talous, Tuotteet, Koulutukset, Viestit, Tilat ja sulut, Asetukset), joista neljä on välilehtiryhmiä (`booking/admin/admin-navigation.js:6–31`). Alle 900 px valikko on 48 px:n ikonipalkki, jonka saa auki nuolesta. PWA ja versionvalvonta ovat valmiina.

1. **HALL-KUORI-01 · KESKI · Päävalikko on ryhmitelty teknisesti, ei työn mukaan**
   - Ongelma (VARMA): 11 pääkohtaa + 4 ryhmää, joissa yhteensä 15 välilehteä; "Kassa ja talous" sisältää vielä Talous-välilehden neljä alavälilehteä (kolme tasoa). Samat asiat löytyvät kahdesta paikasta: tilauslista (Tilaukset ja Talous › Tilaukset), hyvitysten seuranta (oma välilehti ja raporttivalinta), koulutukset (päävalikko ja Tuotteet › Tapahtumat, jonka otsikko on "Tapahtumat ja koulutukset"), vuosikortit (Tuotteet › Alennuskoodit). Verrokeissa (Fresha, Timma) päävalikossa on 6–8 kohtaa: Kalenteri, Myynti, Asiakkaat, Palvelut, Raportit, Markkinointi, Asetukset.
   - Ratkaisu, ehdotettu rakenne (10 pääkohtaa, enintään kaksi tasoa; Koulutukset omana kohtanaan Joonaksen palautteen 13.11. mukaan, koska sinne tulee jatkossa paljon lisää):
     1. **Päivä**
     2. **Kalenteri** (myös tapahtumien ja koulutusten kerrat)
     3. **Tilaukset** · välilehdet Tilaukset, Varaukset, Avoimet maksut (nykyiset Seurattavat maksut ja Hyvitysten seuranta yhtenä jonona)
     4. **Asiakkaat**
     5. **Lahjakortit ja koodit** · Lahjakortit, Kumppanikoodit, Alennuskoodit, Vuosikortit
     6. **Tarjonta** · Tuotteet, Tapahtumat, Hiljaiset ajat, Aukiolot (uusi, HALL-TILAT-01), Tilat ja sulut
     7. **Koulutukset** · oma päävalikon kohta ja oma työtila (Koulutukset, Matkat ja tulevat koulutustoiminnot); koulutukset poistetaan Tapahtumat-välilehdeltä
     8. **Talous** · Raportit (ensimmäisenä Päivän tilitys), Maksut, Laskut, Kävijät
     9. **Sisältö** · Viestipohjat, Viesti asiakkaille, Tekstit (uusi, SIVU-YHT-03), Saunatietoa (uusi)
     10. **Asetukset** · Yleiset, Varaukset, Maksut ja laskutus, Järjestelmä (vain admin), Käyttäjät
     Yläpalkkiin pikatoiminnoiksi: Haku · Uusi varaus · **Kassa** (Pikakassa) · Tarkista. Pikakassa on tiskityökalu, ei hallinnan osio, joten sen kuuluu olla yhden napautuksen päässä joka näkymästä.
   - Hyväksymiskriteerit: jokainen toiminto löytyy yhdestä paikasta; enintään kaksi navigointitasoa; ryhmä aukeaa sen tärkeimpään välilehteen (nyt Kassa ja talous aukeaa Pikakassaan, `admin-navigation.js:52–55`); vanhat osoitteet (`#/talous`, `#/pikakassa`, `#/alennuskoodit` jne.) ohjautuvat uusiin (`resolveAdminPath` tukee jo tätä); jokaisella sivulla yksi H1; henkilökunnan testitehtävät ("myy juoma", "etsi tilaus 15123", "lisää sulku", "jatka lahjakorttia", "tee eilisen raportti") onnistuvat ilman harhailua.
   - Tiedostot: `booking/admin/admin-navigation.js`, `booking/admin/admin.js` (`ROUTES`), `booking/admin/nav-texts.js`, `booking/admin/views/nav-group.js`, uudet tekstiavaimet tuontitiedostoon.
   - Tietokanta: ei (navigaatiotekstit tuontitiedostona).
   - Riippuvuudet: YHT-03 (yhteiset välilehdet), tilaus- ja talousosion kohdat.

2. **HALL-KUORI-02 · PIENI · Tabletilla ja puhelimella valikossa vain ikonit, yläpalkin painikkeet alle 44 px**
   - Ongelma (VARMA): alle 900 px leveydellä valikon nimet piilotetaan (`admin.css`, `#shell .nav .lbl{display:none}`), ja jäljelle jää 11 ikonia, joista osa on monitulkintaisia (€, hintalappu, mökki, liukusäätimet, hattu). Vastaanoton tabletti (820 px) näyttää siis pelkät ikonit. Yläpalkin pikatoiminnot ovat 38 × 38 px (`.top .quick-action{width:38px}`, `.quick-search-toggle{min-height:38px}`), muualla hallinnassa kosketuskohde on 44 px.
   - Ratkaisu: 600–899 px leveydellä valikko auki nimineen (196 px mahtuu tablettiin), alle 600 px alapalkki 5 tärkeimmällä kohdalla (Päivä, Kalenteri, Tilaukset, Asiakkaat, Lisää…) ja nimet ikonien alla; yläpalkin painikkeet 44 px.
   - Hyväksymiskriteerit: 820 px:llä kaikki valikon nimet näkyvät; 390 px:llä tärkeimmät viisi kohtaa ovat peukalon ulottuvilla alareunassa; kaikki yläpalkin kosketuskohteet ≥ 44 × 44 px.
   - Tiedostot: `booking/admin/admin.css` (rivit ~878–905), `booking/admin/index.html`, `booking/admin/admin-navigation.js`.
   - Tietokanta: ei.
   - Riippuvuudet: HALL-KUORI-01.

3. **HALL-KUORI-03 · PIENI · Kirjautumisesta puuttuu "Unohtuiko salasana?"**
   - Ongelma (VARMA): kirjautumislomakkeessa on vain sähköposti ja salasana (`booking/admin/index.html:22–29`). Palautuslinkin vastaanotto on jo tuettu (`booking/shared/sb.js:43–47`, tyyppi `recovery`), mutta linkkiä ei voi pyytää itse. Sama "Aseta salasana" -näkymä tervehtii palauttajaa sanoin "Tervetuloa!". Kirjautumisessa ei ole logoa, vaikka se on yläpalkissa.
   - Ratkaisu: linkki "Unohtuiko salasana?" → sähköpostikenttä → Supabase Authin palautusviesti (`/auth/v1/recover`); palautusnäkymälle oma otsikko "Vaihda salasana"; logo kortin yläosaan.
   - Hyväksymiskriteerit: työntekijä saa uuden salasanan ilman pääkäyttäjää; viesti ei paljasta, onko osoite olemassa.
   - Tiedostot: `booking/admin/index.html`, `booking/admin/admin.js`, `booking/shared/sb.js`.
   - Tietokanta: ei (Supabase Auth; uudelleenohjausosoite on jo hallinnan osoite).
   - Riippuvuudet: –

4. **HALL-KUORI-04 · PIENI · Kielivalinta (FI/EN) näkyy vain osassa näkymiä**
   - Ongelma (VARMA): FI/EN-kytkin on näkymän oikeassa yläkulmassa Talous-, Lahjakortit-, Seurattavat maksut- ja Uusi varaus -näkymissä, mutta ei muualla. Se vaihtaa vain niiden näkymien tekstit (`booking/admin/talous-i18n.js:16–17`, käytössä 63 tiedostossa), kun taas esimerkiksi tilamerkit ovat kiinteästi suomeksi (`booking/admin/ui.js:35–36`, `STATUS` ja `PAY`). Käyttäjä ei voi tietää, mitä kytkin tekee.
   - Ratkaisu: kielivalinta käyttäjävalikkoon (yksi paikka, tallentuu selaimeen), ja kaikki hallinnan tekstit samasta sanakirjasta. Jos englanninkielistä hallintaa ei tarvita (henkilökunta puhuu suomea), poista kytkin kokonaan ja säilytä EN vain asiakkaalle näkyvissä teksteissä. Päätös Joonakselle.
   - Hyväksymiskriteerit: kytkin on yhdessä paikassa tai ei missään; valittu kieli koskee koko hallintaa.
   - Tiedostot: `booking/admin/talous-i18n.js`, `booking/admin/ui.js`, `booking/admin/index.html`, näkymät, joissa kytkin on.
   - Tietokanta: ei.
   - Riippuvuudet: –

5. **HALL-KUORI-05 · PIENI · Tarkista-määrä ei vastaa Tarkista-sivun sanoja**
   - Ongelma (VARMA, kokeilutila): yläpalkissa "Tarkista 6", sivulla "2 asiaa vaatii huomiota" ja Varaukset-välilehdellä "Tarkista 1". Luku laskee rivejä (`reviewAttentionCount`, `booking/admin/admin.js:211–236`), teksti ryhmiä.
   - Ratkaisu: sama yksikkö kaikkialla ("6 avointa: 5 lunastamatonta lahjakorttia, 1 sulkukonflikti"), ja Varaukset-välilehden oma Tarkista-painike poistetaan (yläpalkissa on jo).
   - Hyväksymiskriteerit: yläpalkin luku = sivun otsikon luku.
   - Tiedostot: `booking/admin/admin.js`, `booking/admin/review-logic.js`, `booking/admin/views/review.js`, `booking/admin/views/reservations.js`.
   - Tietokanta: ei.
   - Riippuvuudet: –

6. **HALL-KUORI-06 · PIENI · Virheet ja puuttuvat oikeudet näkyvät harhaanjohtavasti**
   - Ongelma (VARMA): datan hakuvirhe näytetään samalla tekstillä kuin moduulin latausvirhe ("Näkymän lataus epäonnistui: …"), ja mukana on tekninen syy (kokeilutilassa "toimintoa select:schedule_rules ei ole mockattu"). Resurssit hakee säännöt ja sulut yhdellä `Promise.all`-kutsulla (`booking/admin/views/resources.js:10–13`), joten yksi epäonnistunut haku kaataa koko välilehden, myös kapasiteettien muokkauksen ja sulut. Jos käyttäjällä ei ole oikeutta pyydettyyn välilehteen, `selectGroupTab` vaihtaa hiljaa ensimmäiseen sallittuun (`booking/admin/admin-navigation.js:55–58`), ja jos sallittuja välilehtiä on vain yksi, välilehtipalkki piilotetaan (`booking/admin/views/nav-group.js:13`). Kokeilutilan pääkäyttäjältä puuttuu `blocks.manage` (`booking/admin/options-mock.js:101`), joten savutestit eivät näe Kalenterisulut-välilehteä lainkaan.
   - Ratkaisu: datavirheelle oma teksti ("Tietoja ei saatu ladattua. Yritä uudelleen." + painike, tekninen syy "Näytä lisätiedot" -kohdan takana); osiokohtainen virheenkäsittely (`Promise.allSettled`); kielletty välilehti näyttää "Sinulla ei ole oikeutta tähän näkymään" eikä vaihda hiljaa; kokeilutilan pääkäyttäjälle samat oikeudet kuin tuotannossa.
   - Hyväksymiskriteerit: yhden haun virhe ei piilota muita osioita; käyttäjä näkee, miksi näkymä ei aukea.
   - Tiedostot: `booking/admin/views/nav-group.js`, `booking/admin/admin-navigation.js`, `booking/admin/views/resources.js`, `booking/admin/admin.js` (`route`), `booking/admin/ui.js` (`errMsg`), `booking/admin/options-mock.js`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-03.

#### HALL-PAIVA: päivänäkymä (`#/`)

Nykytila: yhden sarakkeen aikajana: päivän tuotto (vain admin ja manager), työvuorot, hoitovalintamuistutus, päivätyökalut (‹ päivä › · Tänään · Seuraava oma vuoro · + Uusi varaus), Valmistelu-kortti (henkilöt ja lisäpalvelut), vuorokortit varausriveineen, yhteenvetorivi ja Sulut (`booking/admin/views/day.js`, `booking/admin/views/dayparts.js`). Rivin nimi avaa tilausnäkymän. Varausrivin oikeassa reunassa on Saapunut-vaihtopainike.

1. **HALL-PAIVA-01 · PIENI · Järjestys ja leveydet: päivän vaihto on tuoton ja muistutusten alla**
   - Ongelma (VARMA): päivätyökalut ovat tuoton, työvuorojen ja muistutuksen alapuolella (`day.js:203–205`); varaus- ja valmistelukortit ovat 760 px leveitä (`admin.css`: `.dayrev`, `.prepcard`, `.day-notes` `max-width:760px`), mutta muistutus ja Sulut-kortti koko leveydeltä; "3 aktiivista varausta, 6 henkilöä yhteensä" toistaa Valmistelun henkilöluvun (`day.js:209`, `dayparts.js:61`); vuoron tyyppi (yleinen/yksityinen) näkyy vain reunan värinä (`day.js:158`); kapasiteetista näkyy "Vapaana: N", ei "6/10" (`dayparts.js:14`); aika ja henkilömäärä toistuvat kortin otsikossa ja rivillä; "+ Uusi varaus" on sekä yläpalkissa että päivätyökaluissa.
   - Ratkaisu: päivätyökalut heti otsikon alle (tabletilla kiinteänä); niiden alle Valmistelu-kortti, joka näyttää kerralla henkilömäärän ja jokaisen tilatun lisäpalvelun määrän lajeittain (pyyhkeet, saunavihdat, turvenaamiot, jalkakylvyt) ja aloitusajoittaisen erittelyn (Joonaksen palaute 13.11.: tämä on päivänäkymän tärkein tieto; nykyinen `prepCard` tekee tämän jo, se vain siirretään ylös); tuotto samalle riville pienenä lukuna; kaikki kortit samaan leveyteen; yhteenvetorivi pois; vuorokortin otsikkoon tekstimerkki "Yleinen"/"Yksityinen" ja täyttöaste "6/10"; Sulut-osio työkalurivin painikkeeksi; toinen "Uusi varaus" pois.
   - Hyväksymiskriteerit: päivän vaihto ja Valmistelu (henkilöt ja jokainen lisäpalvelu määrineen) näkyvät ilman vieritystä 390, 820 ja 1280 px:llä; vuoron tyyppi luettavissa tekstinä; kaikki päivänäkymän kortit samalla leveydellä.
   - Tiedostot: `booking/admin/views/day.js`, `booking/admin/views/dayparts.js`, `booking/admin/admin.css`.
   - Tietokanta: ei (OLETUS: `admin_day_view` palauttaa jo vuoron kapasiteetin; tarkista).
   - Riippuvuudet: YHT-03.

2. **HALL-PAIVA-02 · PIENI · Sisäänkirjausympyrä säilyy; tilan nimi ja "Ei saapunut" kuntoon**
   - Ongelma (VARMA): vihreäreunainen ympyrä, joka täyttyy vihreäksi sisäänkirjauksessa, on hyvä ja tilaa säästävä ratkaisu (Joonaksen palaute 13.11.: erillinen Saapui-painike olisi turha), mutta painettuna tilamerkiksi tulee "Toteutunut" (`ui.js:35`), vaikka toiminto tarkoittaa "Saapunut"; selitys on vain `title`-vihjeenä, joka ei näy kosketusnäytöllä (`dayparts.js:25–41`); "Ei saapunut" puuttuu päivänäkymästä ja uudesta tilausnäkymästä (HALL-TILAUS-01).
   - Ratkaisu: ympyrä säilyy ennallaan; tilamerkiksi "Saapunut"; ruudunlukijalle kiinteä nimi ("Saapunut: <nimi>") ja `aria-pressed`; "Ei saapunut" rivin ⋯-valikkoon (`admin_set_reservation_status`, tila `no_show`, HALL-PAIVA-03).
   - Hyväksymiskriteerit: ympyrän ulkoasu ja koko eivät muutu; tilamerkki on "Saapunut" kaikissa näkymissä; ruudunlukija lukee nimen ja tilan.
   - Tiedostot: `booking/admin/views/dayparts.js`, `booking/admin/ui.js`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-04.

3. **HALL-PAIVA-03 · KESKI · Rivin pikatoiminnot: siirto, soitto ja peruutus poistumatta päivästä**
   - Ongelma (VARMA): asiakkaan siirto toiseen vuoroon vaatii 5–6 askelta ja kaksi näkymänvaihtoa (Päivä → nimi → tilausnäkymä → Muuta/siirrä → päivä → vuoro → tallenna). Puhelinnumero ei näy rivillä (`day.js:148–152`), joten soittaminen vaatii tilauksen avaamisen. Siirto rajoittuu saman tuotteen vuoroihin (`order-card.js:672`).
   - Ratkaisu: rivin ⋯-valikko: Siirrä (avaa nykyisen siirtodialogin päivänäkymän päälle; siirto sekä toiseen vuoroon että vapaasti valittavaan ajankohtaan, kuten nykyisessä dialogissa `order-card.js` kellonaikakentällä ja `p_start`/`p_end`), Soita (`tel:`), Peru, Ei saapunut; puhelinnumero riville.
   - Hyväksymiskriteerit: siirto enintään 4 klikkausta poistumatta päivänäkymästä; näkymä päivittyy heti.
   - Tiedostot: `booking/admin/views/day.js`, `booking/admin/views/dayparts.js`, `booking/admin/views/order-card.js` (siirtodialogi omaksi moduuliksi).
   - Tietokanta: ei saman tuotteen siirrolle. Tuotteen vaihto (yleinen → yksityinen) vaatii `admin_change_booking`-laajennuksen (`p_product_id`), joka luonnostellaan erikseen.
   - Riippuvuudet: HALL-TILAUS-05.

4. **HALL-PAIVA-04 · KESKI · Vastaanoton tablettitila: automaattinen päivitys ja tulostettava päivälista**
   - Ongelma (VARMA): päivänäkymä ei päivity itsestään: `day.js` ja `admin.js` eivät sisällä ajastinta eikä `visibilitychange`-kuuntelijaa, joten vastaanoton tabletti ei näe uusia verkkovarauksia. Päivänäkymällä ei ole tulostustyyliä (`@media print` koskee vain Taloutta, `admin.css:633`). Verrokeissa (Bókun, FareHarbor) päivän manifesti on perustoiminto.
   - Ratkaisu: hiljainen päivitys 60 s välein, kun välilehti on näkyvissä, ja merkintä "Päivitetty klo 14.05"; "Tulosta päivälista" (nimi, puhelin, henkilöt, lisäpalvelut, maksutila, saapunut-ruutu).
   - Hyväksymiskriteerit: verkkokaupassa tehty varaus näkyy tabletin päivänäkymässä minuutin kuluessa ilman kosketusta; tuloste mahtuu A4:lle.
   - Tiedostot: `booking/admin/views/day.js`, `booking/admin/admin.js`, `booking/admin/admin.css`.
   - Tietokanta: ei.
   - Riippuvuudet: HALL-KUORI-02.

5. **HALL-PAIVA-05 · PIENI · Valmis päivän muistiinpano -toiminto on piilotettu**
   - Ongelma (VARMA): `views/day-memos.js` ja RPC:t (booking_140) ovat valmiina, mutta näkymä on liputettu pois (`day.js:21–22`, `DAY_VIEW_SHOW_DAY_NOTES`). Vuoronvaihdon muistiinpano ("puut haettava", "Rauni lämpiää myöhään") on vastaanoton perustarve.
   - Ratkaisu: kytke päälle, jos piilotukselle ei ole perustetta (Joonaksen päätös).
   - Hyväksymiskriteerit: muistiinpano näkyy päivänäkymässä kaikille henkilökunnan rooleille.
   - Tiedostot: `booking/admin/views/day.js`.
   - Tietokanta: ei (OLETUS: booking_140 on ajettu tuotantoon; tarkista).
   - Riippuvuudet: –

6. **HALL-PAIVA-06 · PIENI · Saavutettavuus päivänäkymässä**
   - Ongelma (VARMA): vuorokorttien otsikot eivät ole otsikkoelementtejä (`day.js:159`, `<header><strong>`); jokaisessa Täynnä-merkissä on `role="status"` (`dayparts.js:17`); lisäpalveluikonien selitys vain `title`-vihjeessä (`dayparts.js:55`); saavutettava nimi sanoo "klo 15.00", näkyvä aika "15:00" (`dayparts.js:15`).
   - Ratkaisu: vuoron otsikko `<h3>`; `role=status` pois staattisista merkeistä; ikonien selitys näkyväksi tekstiksi tai `aria-label`; sama aikamuoto kaikkialla (luku 2).
   - Hyväksymiskriteerit: otsikoilla navigointi toimii; axe ei raportoi vakavia virheitä.
   - Tiedostot: `booking/admin/views/day.js`, `booking/admin/views/dayparts.js`.
   - Tietokanta: ei.
   - Riippuvuudet: –

#### HALL-KALENTERI: kalenteri (`#/kalenteri`)

Nykytila: kuukausi- ja viikkonäkymä; suodatinsirut Työvuorot, Varaukset, Koulutukset; päivän ruudussa "3 var. · 6 hlö"; valitun päivän erittely alla (`booking/admin/views/calendar.js`). Vapaata kapasiteettia ei haeta (`load()`, rivit 50–67). Viikkonäkymä on päiväkohtainen lista, ei aikaruudukko.

1. **HALL-KALENTERI-01 · KESKI · Kalenterista ei näe käyttöastetta eikä pääse päivään**
   - Ongelma (VARMA): kuukausinäkymästä ei näe, mitkä päivät ovat täynnä tai tyhjiä, eikä sieltä pääse yhdellä klikkauksella päivänäkymään (`calendar.js` ei sisällä yhtään `#/?d=`-linkkiä). Viikkonäkymä listaa valitun päivän varaukset kahdesti (ruudukossa ja erittelyssä). Mobiilissa siru "Tilat:" katkeaa ilman lukua. Verrokeissa (Bókun, FareHarbor) saatavuuskalenterin väri kertoo täyttöasteen.
   - Ratkaisu: päivän ruutuun täyttöastepalkki (väri ja teksti "18/40"); erittelyyn "Avaa päivä" ja "Uusi varaus tälle päivälle"; viikkonäkymän tuplalista pois.
   - Hyväksymiskriteerit: kuukausinäkymästä näkee täydet ja vapaat päivät; yksi klikkaus vie päivänäkymään.
   - Tiedostot: `booking/admin/views/calendar.js`, `booking/admin/calendar.css`.
   - Tietokanta: kyllä, uusi lukufunktio (luonnos):
     ```sql
     -- LUONNOS (ei ajettu): päiväkohtainen täyttöaste kalenterille, sama logiikka kuin admin_day_view
     create or replace function booking.admin_capacity_range(p_from date, p_to date)
     returns table(day date, capacity int, booked int, sessions int, closed_sessions int)
     language sql stable security definer set search_path = '' as $$
       -- booking._sessions(p_from, p_to) + aktiiviset varaukset, ryhmittely Helsingin päivän mukaan
       select ...
     $$;
     revoke all on function booking.admin_capacity_range(date, date) from public, anon;
     grant execute on function booking.admin_capacity_range(date, date) to authenticated;   -- + _require_staff() funktion sisällä
     ```
     Ilman funktiota kuukausi vaatisi noin 42 `admin_day_view`-kutsua.
   - Riippuvuudet: –

2. **HALL-KALENTERI-02 · SUURI · Resurssiaikajana ja siirto vetämällä (myöhempi vaihe)**
   - Ongelma (VARMA/OLETUS): päivän varaukset näkyvät listana, joten tilojen (Savusauna, Rauni, Lovi) ja saunottajien päällekkäisyydet hahmottuvat vain lukemalla. Timmassa ja Freshassa päiväkalenteri on resurssisarakkeinen, ja varauksen voi siirtää vetämällä (OLETUS, yleistieto).
   - Ratkaisu: tabletille ja työpöydälle sarakenäkymä (tilat ja saunottajat sarakkeina, aika riveinä); siirto vetämällä esikatselun (`admin_preview_booking_limits`) ja vahvistuksen kautta; tilan vaihto olemassa olevalla `admin_move_reservation_space`-funktiolla. Puhelimessa nykyinen lista säilyy.
   - Hyväksymiskriteerit: päivän tilankäyttö näkyy yhdellä silmäyksellä; siirto vetämällä kysyy vahvistuksen ja estää ristiriidat.
   - Tiedostot: uusi `booking/admin/views/day-timeline.js`, `booking/admin/views/day.js`, `booking/admin/calendar.css`.
   - Tietokanta: ei välttämättä (olemassa olevat RPC:t); tuotteen vaihto vaatii HALL-PAIVA-03:n laajennuksen.
   - Riippuvuudet: HALL-PAIVA-03, HALL-TILAT-01.

#### HALL-UUSI: uusi varaus (`#/uusi`)

Nykytila: kolme tyyppiä: Saunavuoro (`views/newbooking.js`: numeroidut vaiheet, kiinteä alapalkki summineen, aikataulun ulkopuolinen varaus), Hoito tai tila ja Jälkikirjaus (`views/resbooking.js`: yksi kortti ilman numerointia, summaa ja kiinteää palkkia, vain suomeksi; Vapaat ajat -paneeli `views/availability.js`).

1. **HALL-UUSI-01 · KESKI · Kolme varaustyyppiä, kaksi eri lomaketta**
   - Ongelma (VARMA): Hoito tai tila -lomake näyttää eri sovellukselta kuin Saunavuoro (`resbooking.js:143–155`); otsikko "Hoito tai tila" toistuu kolmesti; painike "Luo resurssivaraus" on teknistä kieltä; taito näkyy raakana ("taito: treatment", `resbooking.js:128`); oletusaika 15:00, vaikka vihje kertoo ikkunan alkavan 16:00 (`resbooking.js:51`); tyypin vaihto Saunavuorosta Hoitoon kadottaa valitun päivän (`resbooking.js:27`); valmisruudun linkit vievät eri paikkoihin (`newbooking.js:378` → `#/talous?tab=orders&order=`, `resbooking.js:195` → päivänäkymä ja `#/varaukset`), vaikka muualla käytetään `#/tilaukset/<nro>`.
   - Ratkaisu: yksi lomakerunko kolmelle tyypille (numeroidut vaiheet, kiinteä summa-alapalkki, sama tekstimoduuli FI/EN); päivä säilyy tyypin vaihdossa; oletusaika ensimmäisestä vapaasta ajasta; taidot suomeksi; painike "Tallenna varaus"; valmisruutu avaa aina tilausnäkymän (`openOrderView`).
   - Hyväksymiskriteerit: kolme tyyppiä näyttävät ja toimivat samalla tavalla; valmisruudusta yksi klikkaus tilaukseen.
   - Tiedostot: `booking/admin/views/resbooking.js`, `booking/admin/views/newbooking.js`, `booking/admin/booking-texts.js`, `booking/admin/admin.css`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-03.

2. **HALL-UUSI-02 · PIENI · Natiivit päivä- ja aikakentät näyttävät laitteen kielen mukaan**
   - Ongelma (VARMA/OLETUS): `input type=date/time/datetime-local` noudattaa käyttöjärjestelmän kieltä, ei sivun `lang="fi"`-merkintää (`index.html:2`). Englanninkielisellä laitteella näkyy 11/12/2026 ja AM/PM-aika (kuvat kokeilutilasta). OLETUS: henkilökunnan laitteet ovat suomenkielisiä, jolloin ongelma on pieni.
   - Ratkaisu: päivämäärä myös tekstinä kentän vieressä ("to 12.11.2026"); kellonajoille oma 24 h -valitsin (vuorojen alkuajat ovat rajattu joukko, joten pudotusvalikko riittää).
   - Hyväksymiskriteerit: kaikilla laitteilla päivä ja aika luettavissa suomalaisessa muodossa.
   - Tiedostot: `booking/admin/views/newbooking.js`, `booking/admin/views/resbooking.js`, `booking/admin/views/blocks.js`, `booking/admin/views/day.js`.
   - Tietokanta: ei.
   - Riippuvuudet: –

#### HALL-TARKISTA: tarkistettavat (`#/tarkista`)

Nykytila: vain huomiota vaativat osiot (lunastamattomat kumppanilahjakortit, sulkukonfliktit, saunottaja puuttuu jne.) ja Kunnossa-rivi; kaksivaiheiset kuittaukset (`booking/admin/views/review.js`).

1. **HALL-TARKISTA-01 · PIENI · Luvut, tunnukset ja linkit eivät täsmää**
   - Ongelma (VARMA): yläpalkin merkki laskee rivejä (6), sivun teksti osioita ("2 asiaa", `review.js:143–145`); rivillä näkyy varauksen sisäinen tunnus "varaus #8801" (`review.js:25`), muualla tilausnumero; kehotus "Siirrä tai peru" mutta linkki vie vain päivänäkymään; osio-ohjeet kovakoodattua suomea (`review.js:121–131`).
   - Ratkaisu: sama luku merkissä ja otsikossa; tilausnumero ja linkki tilausnäkymään; Siirrä- ja Peru-painikkeet riville; tekstit tekstimoduuliin.
   - Hyväksymiskriteerit: jokaisesta rivistä yksi klikkaus tilaukseen; luku sama kaikkialla.
   - Tiedostot: `booking/admin/views/review.js`, `booking/admin/review-logic.js`, `booking/admin/admin.js`.
   - Tietokanta: mahdollisesti `admin_review_list` palauttaa `order_no`-kentän sulkukonflikteille (OLETUS: puuttuu nyt; tarkista).
   - Riippuvuudet: HALL-KUORI-05.

#### HALL-TILAT: resurssit, vuorosäännöt ja aukiolot (`#/resurssit`)

Nykytila: resurssikortit (tilat ja kapasiteettipoolit, kapasiteetin muokkaus), vuorosääntötaulukko (vain kevyt muokkaus) ja tulevat sulut (`booking/admin/views/resources.js`). Sivulla lukee "Säännöt ovat dataa (booking.schedule_rules)… SQL-migraatiolla – ks. README" (`resources.js:28`).

1. **HALL-TILAT-01 · SUURI · Aukioloja, vuoroja ja poikkeuspäiviä ei voi hallita ilman kehittäjää**
   - Ongelma (VARMA): `admin_update_schedule_rule` sallii vain kentät nimi, päällä/pois, min/max henkilöt, myynnin takaraja, voimassaolo, muistiinpano ja järjestys (`booking/supabase/migrations/20261016150006_booking_06_admin_api.sql:384–386`); yksikään myöhempi migraatio ei laajenna tätä. Uusi vuoro, alkuajan, viikonpäivien tai keston muutos tehdään SQL-migraatiolla, jonka Bottiavustus ajaa (`booking/README.md`, "Sääntöjen muuttaminen"). Kapasiteetin muutos koskee aina kaikkia päiviä (`admin_update_resource`, `resources.js:18`). Ylimääräistä kertavuoroa ("jouluaaton ilta") tai yhden päivän kapasiteetin muutosta ei voi tehdä. Hoitojen aikaikkunat ovat kovakoodattua tekstiä (`resbooking.js:131`). Tämä on suurin ero verrokkeihin: Bókunissa ja FareHarborissa saatavuus (aukiolot, kertalähdöt, päiväkohtainen kapasiteetti) on henkilökunnan perustyökalu.
   - Miksi tärkeää: kausimuutokset, lomat, juhlapyhät ja sesongin lisävuorot ovat toistuvia; jokainen vaatii nyt kehittäjän ja tietokantamigraation.
   - Ratkaisu: Tilat ja sulut → uusi välilehti **Aukiolot** (manager ja admin):
     - viikkopohja: vuorot viikonpäivittäin; muokattavissa alkuaika, kesto, kapasiteetti ja "voimassa alkaen". Muutos päättää vanhan säännön ja luo uuden, joten olemassa olevat varaukset säilyvät;
     - poikkeuspäivä: sulje päivä (nykyinen sulku), lisää kertavuoro tai muuta päivän kapasiteettia;
     - esikatselu: "Tämä muutos koskee 14 tulevaa päivää, 3 varausta osuu muutettuun aikaan" ennen tallennusta.
     Pohjaksi tapahtumien kertasääntömalli: `schedule_rules.kind='event'` (booking_158) ja `admin_event_rule_upsert` (booking_202).
   - Hyväksymiskriteerit: manager lisää jouluaatolle kertavuoron ja muuttaa yhden lauantain kapasiteetin ilman kehittäjää; kauppa näyttää muutokset heti; olemassa olevat varaukset säilyvät ja ristiriidat listataan ennen tallennusta.
   - Tiedostot: uusi `booking/admin/views/openings.js`, `booking/admin/admin-navigation.js`, `booking/admin/views/resources.js`, tekstit.
   - Tietokanta: kyllä, luonnos:
     ```sql
     -- LUONNOS booking_xxx_openings (ei ajettu; Bottiavustus: ensin DEV, sitten PROD; rollback + SQL-testit)
     -- 1) kertavuoro tavalliselle tuotteelle samalla mallilla kuin tapahtumat
     alter table booking.schedule_rules drop constraint if exists schedule_rules_kind_check;
     alter table booking.schedule_rules add constraint schedule_rules_kind_check check (kind in ('regular','event','extra'));
     -- 2) päiväkohtaiset poikkeukset
     create table booking.session_overrides (
       id bigint generated always as identity primary key,
       rule_id bigint not null references booking.schedule_rules(id),
       day date not null,
       capacity int check (capacity is null or capacity >= 0),
       closed boolean not null default false,
       note text,
       created_by uuid default auth.uid(), created_at timestamptz default now(),
       unique (rule_id, day));
     alter table booking.session_overrides enable row level security;
     -- 3) säännön ajoitusmuutos: päättää vanhan (valid_to = p_from - 1) ja luo uuden (valid_from = p_from), poolit kopioidaan
     create or replace function booking.admin_schedule_rule_split(p_id bigint, p_from date, p_patch jsonb) returns jsonb ...
       -- oikeus rules.edit; sallitut: start_time, duration_minutes, weekdays, max_persons; tarkistaa ettei p_from:n jälkeisiä varauksia jää ilman sääntöä
     create or replace function booking.admin_session_override_set(p_rule_id bigint, p_day date, p_capacity int, p_closed boolean, p_note text) returns jsonb ...
     -- 4) booking._sessions, admin_day_view, public_availability* ja kapasiteettitarkistus (reservations_validate) huomioivat session_overrides-rivit
     ```
     Tarkista ennen toteutusta tuotannon `schedule_rules.kind`-rajoite ja `_sessions`-funktion nykyinen muoto (tuotanto voi olla repoa edellä).
   - Riippuvuudet: HALL-TILAT-02.

2. **HALL-TILAT-02 · PIENI · Resurssit-sivu on kirjoitettu kehittäjälle**
   - Ongelma (VARMA): kaksi H1-otsikkoa (ryhmä ja `resources.js:27`); kehittäjäteksti "Säännöt ovat dataa (booking.schedule_rules)…" (`:28`); henkilöresurssit näkyvät "kapasiteettipooleina" ja sisäiset koodit näkyvät (`:16`); poolit ja säännöt eri listoissa, eikä näy mikä pooli kuuluu millekin vuorolle; sääntötaulukko ei suodata tapahtumasääntöjä pois (`:11`); "Muokkaa" jää 1280 px:llä vaakavierityksen taakse.
   - Ratkaisu: yksi H1; tyyppinimet suomeksi (Tila, Saunottaja, Paikkamäärä); koodit piiloon; kapasiteetti suoraan vuoron rivillä; tapahtumasäännöt pois (`kind='regular'`); tabletilla rivit korteiksi.
   - Hyväksymiskriteerit: sivulla ei ole taulujen tai sarakkeiden nimiä; "Muokkaa" näkyy ilman vaakavieritystä 820 px:llä.
   - Tiedostot: `booking/admin/views/resources.js`, `booking/admin/admin.css`.
   - Tietokanta: ehkä lukuoikeus `schedule_rule_pools`-tauluun henkilökunnalle (OLETUS; tarkista RLS).
   - Riippuvuudet: HALL-KUORI-06.

#### HALL-SULUT: sulut ja kalenterisulut (`#/resurssit` Sulut, `#/sulkukalenterit`)

Nykytila: sulku lisätään päivänäkymän alalaidasta tai Resurssit-sivulta (`booking/admin/views/blocks.js`); Kalenterisulut näyttää Google-sulkukalenterien synkronoinnin, konfliktit ja ohitukset (`booking/admin/views/closures.js`).

1. **HALL-SULUT-01 · KESKI · Sulkua ei voi muokata, ja konfliktissa ei näe mitkä varaukset estävät**
   - Ongelma (VARMA): sulun voi vain poistaa, ei muokata (`blocks.js:162`); oletus on savusauna 08–22 (`blocks.js:169, 173–174`); jos aikaan osuu varauksia, virhe kehottaa "peru ne ensin" näyttämättä niitä (`20261016213924_booking_17b_validators.sql:288`); koko päivän tai usean päivän sulku (loma) pitää tehdä päivä kerrallaan.
   - Ratkaisu: muokkaus; pikavalinnat "Koko päivä", "Huolto", "Loma (useampi päivä)"; sulku myös kalenterin päivästä; konfliktissa lista varauksista (nimi, aika, henkilöt) ja Siirrä/Peru-painikkeet tai Ylitys-oikeudella sulku silti.
   - Hyväksymiskriteerit: huoltosulku tyhjälle päivälle kolmella klikkauksella; konfliktissa käyttäjä näkee estävät varaukset.
   - Tiedostot: `booking/admin/views/blocks.js`, `booking/admin/views/day.js`, `booking/admin/views/calendar.js`.
   - Tietokanta: kyllä, luonnos: `booking.admin_update_block(p_id bigint, p_starts_at timestamptz, p_ends_at timestamptz, p_reason text)` (oikeus `blocks.manage`, kalenterisulut estetty kuten nyt) ja `booking.admin_preview_block(p_space_id bigint, p_starts_at timestamptz, p_ends_at timestamptz)`, joka palauttaa päällekkäiset varaukset.
   - Riippuvuudet: HALL-TILAT-01 (poikkeuspäivät voivat korvata osan).

2. **HALL-SULUT-02 · PIENI · Kalenterisulut-näkymä on tekninen**
   - Ongelma (VARMA): näkymä on rakenteeltaan selkeä, mutta puhuu synkronoinneista, ohituksista ja tapahtumatunnuksista; henkilökunnan kysymys on "onko sauna auki" ja "mikä sulku estää varauksen".
   - Ratkaisu: oletusnäkymä "Tulevat sulut" (päivä, tila, syy, lähde: Google tai hallinta); synkronoinnin tila ja ohitukset "Lisätiedot"-osioon vain adminille.
   - Hyväksymiskriteerit: staff-rooli näkee tulevat sulut ilman teknisiä termejä.
   - Tiedostot: `booking/admin/views/closures.js`.
   - Tietokanta: ei.
   - Riippuvuudet: –

#### HALL-TILAUKSET: tilauslista (`#/tilaukset`)

Nykytila: palvelinpuolen sivutus (25 / sivu), haku, maksutilasirut ja "Näytä suodattimet" -laatikko (`booking/admin/views/talous-orders.js`, `booking/admin/orders-filter.js`). Rivi avaa ≥ 1200 px näytöllä yhteenvetopaneelin, kapeammalla koko tilauksen. Sama lista on myös Kassa ja talous › Talous › Tilaukset (`booking/admin/views/talous.js:58`).

1. **HALL-TILAUKSET-01 · PIENI · Suodatinsirut sekoittavat kolme eri asiaa**
   - Ongelma (VARMA): sirut ovat monivalinta (TAI), mutta "Kaikki" on keskellä ja valitsee vain itsensä; oletuksena kaksi sirua on valittuna, mikä näyttää virheeltä (`orders-filter.js:115, 182–209`). Ryhmässä on maksutila (Maksetut, Maksamattomat, Laskutetut, Hyvitetyt), tilauksen tila (Peruttu, yksikössä: `orders-texts.js:43`) ja arkistointi (Poistetut). Osittain hyvitetty tilaus osuu sekä Maksetut- että Hyvitetyt-siruun (`orders-filter.js:167, 170`).
   - Ratkaisu: järjestys Kaikki · Maksetut · Maksamattomat · Laskutetut · Hyvitetyt; "Perutut" ja "Poistetut" erilliseksi "Näytä myös" -valinnaksi suodatinlaatikkoon; monivalinnan merkiksi valintamerkki sirussa; Hyvitetyt = vain kokonaan hyvitetyt tai selite päällekkäisyydestä.
   - Hyväksymiskriteerit: oletusnäkymässä on yksi selvä valinta; mikään tilaus ei näy kahden sirun alla odottamatta; kaikki sirut monikossa.
   - Tiedostot: `booking/admin/orders-filter.js`, `booking/admin/views/talous-orders.js`, `booking/admin/orders-texts.js`, `booking/admin/admin.css`.
   - Tietokanta: ei, ellei Hyvitetyt-sääntöä muuteta (`admin_list_orders`, booking_277).
   - Riippuvuudet: –

2. **HALL-TILAUKSET-02 · PIENI · Sama lista kahdessa paikassa ja kaksi H1-otsikkoa**
   - Ongelma (VARMA): Talous › Tilaukset on sama lista samalla tehtaalla. Tilaukset › Varaukset -välilehdellä on toinen H1 ("Tilaukset" `views/orders.js:34` ja "Varaukset" `views/reservations.js:142`) sekä omat "Jälkikirjaus"- ja "Tarkista"-painikkeet, joiden luku (1) poikkeaa yläpalkin luvusta (6) (`reservations.js:138–141`, `admin.js:203–214`).
   - Ratkaisu: Talous › Tilaukset poistetaan (vanha osoite `#/talous?tab=orders&order=` ohjataan `#/tilaukset/<nro>`); Varaukset-välilehdeltä pois Tarkista ja Jälkikirjaus (Jälkikirjaus on jo Uusi varaus -sivun kolmas tyyppi); yksi H1 sivulla.
   - Hyväksymiskriteerit: tilauslista on yhdessä paikassa; vanhat syvälinkit toimivat.
   - Tiedostot: `booking/admin/views/talous.js`, `booking/admin/admin-navigation.js`, `booking/admin/views/reservations.js`, `booking/admin/views/orders.js`.
   - Tietokanta: ei.
   - Riippuvuudet: HALL-KUORI-01.

3. **HALL-TILAUKSET-03 · PIENI · Listarivi on epäselvä ja mobiilissa ensimmäinen tilaus alkaa vasta 660 px:n kohdalla**
   - Ongelma (VARMA): rivin oikeassa reunassa on alas osoittava nuoli, joka viittaa haitariin, mutta rivi avaa paneelin tai sivun; maksamaton rivi on punertava mutta "Maksamatta"-merkki harmaa (`admin.css:71`), tilausnäkymässä sama merkki on punainen; nimen alla "L000010 / Maksettu" toistaa maksutilan (`talous-orders.js:138`); tila- ja kanavamerkki (Maksettu, Verkkokauppa) ovat samannäköisiä. 390 px:llä sirut kolmella rivillä ja sivutus ylhäällä.
   - Ratkaisu: nuoli › tai pois; kanava pelkkänä harmaana tekstinä, ei merkkinä; Maksamatta-merkki samanvärinen kaikkialla (`--c-warn`); mobiilissa sirut yhdellä vaakavieritettävällä rivillä ja ylempi sivutus piiloon.
   - Hyväksymiskriteerit: 390 × 844 näytöllä ensimmäinen tilaus näkyy ilman vieritystä; sama tila näyttää samalta listalla, paneelissa ja tilausnäkymässä.
   - Tiedostot: `booking/admin/views/talous-orders.js`, `booking/admin/admin.css`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-04 (tilamerkkien sanasto).

#### HALL-TILAUS: tilausnäkymä v3 (`#/tilaukset/<nro>`)

Nykytila: kaksi saraketta: "Seuraava askel" -palkki, varausrivit toimintoineen, erittely, aikajana, maksukortti, asiakas, muistiinpanot sekä "Peruutus ja poisto" (`booking/admin/views/order-view.js`). Hallinnan selkein ja ammattimaisin näkymä. Kaikki sisäänkäynnit (päivä, kalenteri, varauslista, asiakas, uusi varaus) avaavat tämän (`booking/admin/order-open.js:1–3`); vanha tilauskorttimodaali (`views/order-card.js`, 731 riviä) jää vain varapoluksi.

1. **HALL-TILAUS-01 · KESKI · Uusi tilausnäkymä vei henkilökunnalta toimintoja**
   - **Tila 13.11.2026:** Osittain, PR #347 (booking_282–284, lippu `partial_refunds_enabled`): atominen koko tilauksen peruutus (`admin_cancel_order`), osahyvitys ja ylisuorituksen hyvitys ovat nyt tilausnäkymässä. Jäljellä: Ei saapunut, maksamattoman tilauksen poisto, peruutuspyynnön näkyminen, yrityksen laskutustiedot, vuosikorttikoodi, kumppanikoodi, hyvityksen uudelleenyritys ja saunottajapoikkeus.
   - Ongelma (VARMA): seuraavat ovat vain vanhassa kortissa, johon ei käytännössä enää pääse:
     - "Ei saapunut" -merkintä (`order-card.js:499`; v3:n rivitoiminnot `order-view-logic.js:141–157` eivät sisällä sitä, vaikka asiakasnäkymä laskee no-show-tilastoa `customer-view.js:160`);
     - maksamattoman tilauksen poisto (booking_279): v3:n "Peruutus ja poisto" -kortissa on tyhjä paikka `[data-slot=order-delete]` (`order-view.js:372`), jota mikään koodi ei täytä;
     - asiakkaan peruutuspyyntö: malli lukee `requests`-kentän (`order-view-logic.js:78`), mutta näkymä ei näytä sitä;
     - yritystilauksen laskutustiedot (verkkolaskuosoite, välittäjä, viite) (`order-card.js:397–408`), vuosikorttikoodi (`:620–630`), kumppanilahjakortti (`:411`), keskeneräisen verkkohyvityksen "Yritä uudelleen" (`:303–317`) ja saunottajapoikkeus (`:222–224`).
   - Miksi tärkeää: asiakkaan peruutuspyyntö voi jäädä huomaamatta, no-show-tilasto ei enää kerry, ja virheellisen maksamattoman tilauksen siivous vaatii kehittäjän.
   - Ratkaisu: "Ei saapunut…" ⋯-valikkoon (varauspäivästä alkaen, vahvistusdialogi); `orderDeleteBlock` paikkaan `data-slot=order-delete`; peruutuspyynnöstä huomiopalkki ja oma tila "Seuraava askel" -palkkiin; yritys-, vuosikortti- ja kumppanikortit sivupalkkiin; "Yritä uudelleen" maksukorttiin.
   - Hyväksymiskriteerit: jokainen vanhan kortin toiminto on v3:ssa samoilla oikeuksilla; yksikkötestit (`booking/tests/`) kattavat uudet toiminnot.
   - Tiedostot: `booking/admin/views/order-view.js`, `booking/admin/order-view-logic.js`, `booking/admin/order-view-texts.js`, `booking/admin/views/order-card-delete.js`, `booking/admin/admin.css`.
   - Tietokanta: ei (RPC:t `admin_set_reservation_status` no_show, `admin_order_delete_check`, `admin_delete_unpaid_order` ovat olemassa).
   - Riippuvuudet: YHT-08 (kokeilutila testejä varten).

2. **HALL-TILAUS-02 · PIENI · Julkaisu jättää dynaamiset importit versioimatta: "← Takaisin" ei palaa lähtönäkymään**
   - **Tila 13.11.2026:** Valmis, PR #350.
   - Ongelma (VARMA, paikallinen koonti): `scripts/build-pages.mjs:72` lisää versiotunnuksen vain muotoihin `import '…'` ja `from '…'`. Muodot `import('./order-view.js')` jäävät ilman sitä (tarkistettu `dist/hallinta/views/orders.js`). Selain lataa saman moduulin kahdesti (versioituna ja ilman), jolloin `order-open.js`:n paluutila katoaa: päivänäkymästä, kalenterista tai varauslistasta avatun tilauksen paluulinkki on aina "← Tilaukset". Lisäksi dynaamisesti ladatut näkymät voivat jäädä selaimen välimuistiin vanhoina uuden julkaisun jälkeen.
   - Ratkaisu: sama korvaus myös muodolle `import('…')`; build epäonnistuu, jos distiin jää versioimaton suhteellinen `.js`-import.
   - Hyväksymiskriteerit: jokainen moduuli latautuu distissä kerran (Playwrightin verkkoloki); "← Takaisin" palaa päivänäkymään, kalenteriin ja varauslistaan.
   - Tiedostot: `scripts/build-pages.mjs`.
   - Tietokanta: ei.
   - Riippuvuudet: – (kiireellinen ja pieni).

3. **HALL-TILAUS-03 · PIENI · "Lähetä maksulinkki" ei oletuksena lähetä mitään**
   - Ongelma (VARMA): maksulinkkidialogin sähköpostivalinta on oletuksena pois (`talous-orders.js:279`), ja varapolku lähettää aina `sendEmail: false` (`order-add.js:48`). Painikkeen nimi lupaa lähettämisen.
   - Ratkaisu: valinta oletuksena päällä, kun asiakkaalla on sähköposti; dialogi näyttää vastaanottajan ("Lähetetään osoitteeseen …"); ilman sähköpostia painike on "Luo linkki"; toast kertoo, lähtikö viesti.
   - Hyväksymiskriteerit: painikkeen teksti vastaa tekoa.
   - Tiedostot: `booking/admin/views/talous-orders.js`, `booking/admin/views/order-add.js`, `booking/admin/talous-texts.js`, `booking/admin/orders-texts.js`.
   - Tietokanta: ei.
   - Riippuvuudet: –

4. **HALL-TILAUS-04 · PIENI · Kaksi lisäostodialogia, v3 käyttää suppeampaa**
   - Ongelma (VARMA): v3:n "+ Lisäosto" avaa Talouden dialogin (vain lisäpalvelu tai mukautettu rivi, joka vaatii override-oikeuden: `talous-orders.js:244–250`). Laajempi dialogi, jolla voi lisätä tilaukseen myös uuden varauksen tai vuokratuotteen (`order-add.js:88–103`), on vain vanhoilla poluilla. Samoin maksulinkki, maksun kirjaus ja peruutus on toteutettu kahteen kertaan.
   - Ratkaisu: v3 käyttää `order-add.js`:n dialogia, Talouden suppea poistetaan; kaikista dialogeista pois teksti "Toiminto tallentuu palvelimelle".
   - Hyväksymiskriteerit: tilausnäkymästä voi lisätä samaan tilaukseen uuden varauksen.
   - Tiedostot: `booking/admin/views/orders.js`, `booking/admin/views/talous-orders.js`, `booking/admin/views/order-view.js`.
   - Tietokanta: ei.
   - Riippuvuudet: HALL-TILAUS-01.

5. **HALL-TILAUS-05 · PIENI · Siirto ja henkilömäärän muutos eivät kerro uutta hintaa eivätkä ilmoita asiakkaalle**
   - **Tila 13.11.2026:** Pääosin valmis, PR #347 (booking_282): `admin_change_booking_preview` näyttää uuden hinnan ennen tallennusta, ja `admin_change_booking` sai parametrit `p_refund_amount`, `p_refund_reason` ja `p_notify` (lippu `partial_refunds_enabled`). Vapaa ajankohta oli jo dialogissa (`p_start`, `p_end`). Jäljellä: testaus DEVissä, lipun kytkentä ja paneelin tuonti tilausnäkymän sisään (luonnos 02).
   - Ongelma (VARMA): "Muuta / siirrä" -dialogi (`order-card.js:638–731`) ei näytä uutta hintaa, vaikka palvelin laskee sen uudelleen (`_change_booking_core`, booking_192); hinnan ero selviää vasta tallennuksen jälkeen. Asiakkaalle ei voi lähettää muutosvahvistusta (`admin_change_booking` ilman `p_notify`, booking_192:847–857). Päivä ilman vuoroja näyttää saman tekstin kahdesti (`order-card.js:651–658, 682`).
   - Ratkaisu: ensin pelkkä käyttöliittymä (alle tunnin työ): "Uusi hinta 98,00 € (ero +13,00 €)" ennen tallennusta ja maksulinkkiehdotus, jos syntyy maksettavaa; tuplateksti pois. Sitten tietokantamuutoksen vaativa valinta "Lähetä asiakkaalle muutosvahvistus".
   - Hyväksymiskriteerit: henkilökunta näkee hinnan muutoksen ennen tallennusta; asiakas saa halutessa vahvistuksen uudesta ajasta.
   - Tiedostot: `booking/admin/views/order-card.js` (siirto omaksi `order-change.js`-moduuliksi), `booking/admin/nb-logic.js`, tekstit.
   - Tietokanta: ei enää tarvita: booking_282 (PR #347) toi `admin_change_booking_preview`-funktion ja `admin_change_booking`-funktion parametrit `p_notify`, `p_refund_amount` ja `p_refund_reason`. Viestipohja `email.order_change.*` on olemassa.
   - Riippuvuudet: –

6. **HALL-TILAUS-06 · KESKI · Vahvistusta ei voi lähettää uudelleen eikä yksittäiselle asiakkaalle voi kirjoittaa**
   - Ongelma (VARMA): uudelleenlähetys on vain kuitille (`order-view.js:93–96`). Viestit-sivun asiakasviesti on joukkolähetys päivän ja tuotteen mukaan (`customer-message-panel.js:49`). Käytännössä henkilökunta kirjoittaa omasta sähköpostistaan, eikä viesti näy tilauksen historiassa. Verrokeissa (Bókun, FareHarbor, Fresha) "Resend confirmation" ja "Message customer" ovat tilauksen perustoimintoja.
   - Ratkaisu: ⋯-valikkoon "Lähetä vahvistus uudelleen" ja "Lähetä viesti asiakkaalle" (pohja tai vapaa teksti, esikatselu); molemmat näkyvät aikajanalla.
   - Hyväksymiskriteerit: kaksi klikkausta vahvistuksen uudelleenlähetykseen; lähetetty viesti näkyy aikajanalla.
   - Tiedostot: `booking/admin/views/order-view.js`, `booking/admin/order-view-texts.js`.
   - Tietokanta: kyllä, luonnos:
     ```sql
     -- LUONNOS (ei ajettu)
     create or replace function booking.admin_resend_confirmation(p_order_id bigint) returns jsonb ...
       -- oikeus bookings.manage; lisää email_outbox-riviin kind='order_confirmation'; audit_log
     create or replace function booking.admin_send_customer_message(p_order_id bigint, p_subject text, p_body text) returns jsonb ...
       -- oikeus bookings.manage; pituusrajat; vain pelkkä teksti; email_outbox kind='customer_message'; audit_log
     ```
   - Riippuvuudet: HALL-TILAUS-07 (aikajanan selkokieli).

7. **HALL-TILAUS-07 · PIENI · Aikajanassa ja dialogeissa näkyy teknisiä koodeja**
   - Ongelma (VARMA): muutoshistoria näyttää esimerkiksi "Tila confirmed → cancelled (reservations)" (`order-view-texts.js:173–175`); yleinen not_found-teksti "Tapahtumaa ei löydy (se on voinut poistua kalenterista)" näkyy myös tilaukselle (`ui.js:99`); painike "Saapunut" on tilan nimi eikä toiminto (`order-view-texts.js:66`); monikot puuttuvat ("1 varausta", EN "1 bookings": `order-view-texts.js:21, 257, 272, 309`).
   - Ratkaisu: kentät ja tilat selkokielelle, taulun nimi pois ("Varaus peruttu · tekijän nimi · 12.11. klo 14.05"); kontekstikohtainen not_found; "Merkitse saapuneeksi"; monikkoapuri yhteiseen moduuliin (`booking/shop/src/plural.js` on jo olemassa kaupassa).
   - Hyväksymiskriteerit: aikajanalla ei näy englanninkielisiä koodeja eikä taulujen nimiä.
   - Tiedostot: `booking/admin/order-view-texts.js`, `booking/admin/ui.js`.
   - Tietokanta: ei (tekstit tuontitiedostona).
   - Riippuvuudet: YHT-04.

8. **HALL-TILAUS-08 · PIENI · Kosketuskohteet ja saavutettavuus tilausnäkymässä**
   - Ongelma (VARMA): 390 px:llä "← Tilaukset" on 16 px korkea, "ALV-erittely" 20 px, "Asiakasnäkymä →" 21 px (alle WCAG 2.5.8:n 24 px), "+ Lisäosto" 28 px (`admin.css:1403`). Kaikki dialogit käyttävät samaa `id="dlg-title"` (`ui.js:133–134`). ⋯-valikossa `role=menu` ilman nuolinäppäintukea (`order-view.js:163–193`). Asiakkaaseen johtaa kolme linkkiä samassa näkymässä (`order-view.js:320, 424, 487`). Maksukortti on mobiilissa vasta erittelyn ja aikajanan jälkeen.
   - Ratkaisu: linkkipainikkeet ≥ 44 px; yksilölliset dialogi-id:t; ⋯-valikko tavallisiksi painikkeiksi ilman `role=menu`; yksi asiakaslinkki; mobiilissa maksukortti heti varauskortin jälkeen; kaksi saraketta jo 768 px:stä.
   - Hyväksymiskriteerit: ei alle 44 px:n kosketuskohteita 390 px:llä; axe-tarkistus ilman vakavia virheitä.
   - Tiedostot: `booking/admin/admin.css`, `booking/admin/ui.js`, `booking/admin/views/order-view.js`.
   - Tietokanta: ei.
   - Riippuvuudet: –

9. **HALL-TILAUS-09 · KESKI · Vanhan koodin siivous**
   - Ongelma (VARMA): kuollutta tai rinnakkaista koodia: `orderDetail` (`talous-orders.js:195–238`) ei ole kutsuttu mistään; booking_182-silta etsii elementtejä, joita syntyy vain siitä (`order-contents.js:220`, `order-reservation-bridge.js:125`), mutta ladataan joka kerta (`orders.js:80–83`); kaksi peruutusdialogia (`refund-cancel.js:64`, `order-cancel-flow.js`); kopioitu verkkohyvitysten käsittely (`talous-orders.js:377–402`, `order-card.js:280–302`).
   - Ratkaisu: poista HALL-TILAUS-01:n ja -04:n jälkeen `order-card.js`, `orderDetail`, silta ja vanha peruutusdialogi; hyvityskäsittely yhteen moduuliin.
   - Hyväksymiskriteerit: noin 1 000 riviä vähemmän, testit vihreinä, yksi toteutus kullekin dialogille.
   - Tiedostot: yllä luetellut.
   - Tietokanta: ei.
   - Riippuvuudet: HALL-TILAUS-01, HALL-TILAUS-04.

#### HALL-ASIAKKAAT: asiakaslista ja asiakasnäkymä (`#/asiakkaat`, `#/asiakkaat/<id>`)

Nykytila: lista hakukentällä ja "Näytä lisää" -painikkeella, rivillä merkit Yksityinen/Yritys ja markkinointilupa (`views/customers.js`). Asiakasnäkymä (`views/customer-view.js`) näyttää tunnusluvut (avoin saldo, käynnit, tulevat, ei saapunut), tilaukset, yhteystiedot, lahjakortit, vuosikortin ja muistiinpanon, mutta kaikki on vain luettavaa; "Muokkaa" avaa vanhan modaalin.

1. **HALL-ASIAKKAAT-01 · KESKI · Asiakasnäkymä muokattavaksi ilman vanhaa modaalia**
   - Ongelma (VARMA): muistiinpanon lisääminen vie viisi vaihetta (asiakasnäkymä → Muokkaa → koko lomakemodaali → vieritys → Tallenna); muistiinpanokortissa ei ole omaa muokkausta (`customer-view.js:182`). Kieltä, asiakastyyppiä ja yksityisasiakkaan osoitetta ei voi muuttaa (`customers.js:27–40`), vaikka `admin_update_customer` sallii ne (booking_11:593–594); asiakasnäkymä näyttää "Kieli –". Vuosikortin peruutus kysyy kaksi selaimen `confirm()`-ikkunaa ohjeella "OK = peru, Peruuta = säilytä" (`customers.js:88–89`). Pikahaku avaa asiakkaan vanhana modaalina (`quick-search.js:13`).
   - Ratkaisu: kortit muokattaviksi paikallaan (yhteystiedot, kieli, tyyppi, osoite, markkinointilupa kytkimenä, muistiinpano omalla Muokkaa-painikkeella); vuosikortti omaan korttiin ja `confirmDialog`; "Uusi varaus tälle asiakkaalle" (avaa `#/uusi` esitäytettynä); pikahaku vie `#/asiakkaat/<id>`.
   - Hyväksymiskriteerit: muistiinpanon lisäys enintään kaksi klikkausta; vanhaa asiakasmodaalia ei käytetä.
   - Tiedostot: `booking/admin/views/customer-view.js`, `booking/admin/views/customers.js`, `booking/admin/views/customerform.js`, `booking/admin/quick-search.js`.
   - Tietokanta: ei.
   - Riippuvuudet: –

2. **HALL-ASIAKKAAT-02 · PIENI · Kaksoiskappaleiden yhdistäminen ja asiakkaan anonymisointi**
   - **Tila 13.11.2026:** Valmis kytkimien takana, PR #349 (booking_285, oikeus `customers.admin`). Jäljellä: testaus DEVissä ja kytkimien päälle laitto. Aiempi migraatioluonnos on poistettu tarpeettomana.
   - Ongelma (VARMA): kumpaakaan ei ole; koodissa kommentti "EI Yhdistä/poista-osiota (myöhempi PR)" (`customer-view.js:109`). Johku-tuonti ja verkkovaraukset tuottavat väistämättä kaksoiskappaleita (sama henkilö eri sähköpostilla tai puhelinnumerolla), ja GDPR-poistopyyntö vaatii nyt kehittäjän.
   - Ratkaisu: asiakasnäkymään "Yhdistä…" (haku ehdokkaille samalla nimellä, sähköpostilla tai puhelimella; esikatselu siitä, mitä siirtyy; vahvistus) ja vain adminille "Poista asiakas (anonymisoi)", estettynä jos avoimia tilauksia tai saldoa.
   - Hyväksymiskriteerit: yhdistämisen jälkeen kaikki tilaukset, vuosikortit ja lahjakortit näkyvät yhdellä asiakkaalla, ja audit-rivi syntyy; anonymisoitu asiakas ei näy haussa.
   - Tiedostot: `booking/admin/views/customer-view.js`, uusi `booking/admin/views/customer-merge.js`, tekstit.
   - Tietokanta: toteutettu, booking_285 (PR #349): yhdistäminen ja anonymisointi esikatseluineen, rollback ja SQL-testit (`booking/supabase/tests/t285_customer_merge_anonymize.sql`).
   - Riippuvuudet: HALL-ASIAKKAAT-01.

3. **HALL-ASIAKKAAT-03 · KESKI · Asiakaskortista puuttuvat tagit, no-show-varoitus ja viestihistoria**
   - Ongelma (VARMA/OLETUS): muistiinpano on yksi vapaa tekstikenttä ilman aikaa ja kirjoittajaa; tageja (VIP, allergia, maksaa paikan päällä) ei ole; asiakkaalle lähetettyjä viestejä ei näe. Verrokeissa (Fresha, Timma) nämä ovat asiakaskortin perusta (OLETUS, yleistieto).
   - Ratkaisu: tagit (rajattu lista, ei vapaata tekstiä), jotka näkyvät myös tilausnäkymässä ja päivänäkymässä; no-show-määrä varoituksena uutta varausta tehtäessä; lista lähetetyistä viesteistä (otsikko, tyyppi, aika, tila).
   - Hyväksymiskriteerit: allergiatagi näkyy päivänäkymän varausrivillä.
   - Tiedostot: `booking/admin/views/customer-view.js`, `booking/admin/views/order-view.js`, `booking/admin/views/day.js`.
   - Tietokanta: kyllä, luonnos: `alter table booking.customers add column tags text[] not null default '{}'` + tarkistus sallituista arvoista; `admin_update_customer` sallii `tags`; `admin_customer_emails(p_customer_id)` lukee `email_outbox`-taulusta vain otsikon, tyypin, ajan ja tilan.
   - Riippuvuudet: HALL-TILAUS-01 (no-show-merkintä).

4. **HALL-ASIAKKAAT-04 · PIENI · Asiakaslista: kohinaa ja puuttuvat monikot**
   - Ongelma (VARMA): jokaisella rivillä "Yksityinen" ja "Ei markkinointia" -merkit, vaikka ne ovat yleisin tila; tilausmäärä ilman monikkoa ("1 tilausta", `customers.js:17, 21–22`); haulla ei näkyvää otsikkoa, paikkamerkki katkeaa mobiilissa (`customers.js:99`); ei lajittelua (viimeisin käynti, nimi).
   - Ratkaisu: merkit vain poikkeuksille (Yritys, Vuosikortti, Markkinointilupa); monikko; lajittelu "Viimeisin käynti / Nimi"; rivillä viimeisin käyntipäivä.
   - Hyväksymiskriteerit: rivillä on enintään kaksi merkkiä; monikot oikein FI ja EN.
   - Tiedostot: `booking/admin/views/customers.js`.
   - Tietokanta: ei (viimeisin käynti voi vaatia kentän `admin_list_customers`-vastaukseen: tarkista).
   - Riippuvuudet: –

#### HALL-KASSA: pikakassa (`#/pikakassa`)

Nykytila: tuotepainikkeet (2 saraketta mobiilissa, 3 ≥ 700 px), Yhteensä ja Maksa, kokoon taitettu "Maksurivit (n)". Maksutavat: maksulinkki (pakollinen sähköposti), "Kortti puhelimella (CheckoutX)" (testitila) ja himmennetty "Korttipääte – Tulossa" (`booking/admin/pos-screen.js`, `pos-logic.js`). Käteistä ei oteta vastaan liiketoimintapäätöksellä (`settings-texts.js:108`, booking_119).

1. **HALL-KASSA-01 · PIENI · Kassanäkymä tabletille: kori näkyviin ja otsikot pois tieltä**
   - Ongelma (VARMA): kori on oletuksena kiinni (`pos-screen.js:25`, `showLines = false`), joten kassalla ei näe, mitä korissa on; korin nimi on "Maksurivit" (`pos-texts.js:15`); ryhmän H1 "Kassa ja talous", välilehdet ja H2 "Pikakassa" vievät mobiilissa noin 300 px ennen ensimmäistä tuotetta; −/+ -painikkeilla on sama nimi "Määrä" (`pos-screen.js:723, 725`); summan muutos ei ilmoitu ruudunlukijalle (`pos-screen.js:808–810`); pikakassa on aina suomeksi (`pos-screen.js:15`).
   - Ratkaisu: kori aina näkyvissä ≥ 800 px (sivupaneeli), nimi "Ostoskori"; 4 tuotesaraketta ≥ 1 000 px; pikakassa omaksi näkymäkseen yläpalkin "Kassa"-painikkeesta ilman ryhmäotsikoita (HALL-KUORI-01); nimet "Vähennä"/"Lisää"; `aria-live` summaan; kieli yhteisestä valinnasta.
   - Hyväksymiskriteerit: tabletilla (820 px) korin rivit ja summa näkyvät koko ajan; ensimmäinen tuotepainike näkyy ilman vieritystä 390 px:llä.
   - Tiedostot: `booking/admin/pos-screen.js`, `booking/admin/pos-texts.js`, `booking/admin/admin.css` (rivit ~697–815).
   - Tietokanta: ei.
   - Riippuvuudet: HALL-KUORI-01.

2. **HALL-KASSA-02 · KESKI · Pikakassalla ei voi myydä tiskillä tavallisella korttipäätteellä**
   - Ongelma (VARMA): juoman myynti vaatii asiakkaan sähköpostin ja maksulinkin (`pos-screen.js:315`) tai CheckoutX-testitilan; korttipääte on "Tulossa" (`pos-logic.js:151`). Myynti vie 6–7 vaihetta ja asiakkaan puhelimen. Fresha ja Timma: tuote → Maksa → Kortti → valmis (OLETUS, yleistieto).
   - Ratkaisu: maksutapa "Korttipääte (erillinen)": tilaus luodaan, henkilökunta kuittaa "Maksu hyväksytty päätteellä", kuitti syntyy; maksulinkki myös pelkkänä QR-koodina ilman sähköpostia.
   - Hyväksymiskriteerit: juoma myydään korttipäätteellä enintään 4 napautuksella ja kuitti syntyy.
   - Tiedostot: `booking/admin/pos-screen.js`, `booking/admin/pos-logic.js` (`tenderAvailable`, `TENDER_HANDLERS.terminal`), `booking/admin/pos-texts.js`.
   - Tietokanta: kyllä, luonnos: `admin_pos_checkout` (tai uusi `admin_pos_confirm_terminal(p_order_id bigint)`) hyväksyy maksutavan `card_terminal` ja kirjaa maksun + kuitin; tarkista, salliiko `admin_pos_send_link` `p_email = null`. Tuotanto voi olla repoa edellä.
   - Riippuvuudet: liiketoimintapäätös (CheckoutX vai erillinen pääte); HALL-KASSA-01.

#### HALL-TALOUS: myynti ja ALV, maksut, raportit, kävijät (`#/talous`)

Nykytila: sivun yläosassa ALV-huomautus ja "Myynti ja ALV" -kaavio, jonka alla neljä alavälilehteä: Tilaukset (sama lista kuin päävalikon Tilaukset), Maksut (kuitit ja PDF:t), Raportit (9 raporttia täysleveinä pystynappeina, jakso, PDF, CSV, tulostus) ja Kävijät (verkkokaupan analytiikka). Raporttiin pääsee neljän tason kautta: sivupalkki › Kassa ja talous › Talous › Raportit › raportti (`admin-navigation.js:7–13`, `views/talous.js:19`, `views/talous-reports.js:312`). Ensimmäinen tilausrivi alkaa 1280 px:n näytöllä noin 1 250 px:n kohdalta.

1. **HALL-TALOUS-01 · PIENI · Raporttien virheet ja käytettävyys**
   - **Tila 13.11.2026:** Osittain, PR #350. "Veroton"-sarake on korjattu aidosti verottomaksi (`booking/admin/report-method-net.js`). Jäljellä: Avoimet maksut -taulukon rajaus, raporttivalitsin näppäimistölle, vuosivalitsimen leveys ja Hyvitysten seuranta pois raporttilistasta.
   - Ongelma (VARMA): maksutaparaportin "Maksutavoittain"-taulukon sarake "Veroton" näyttää bruttosumman hyvitysten jälkeen (`views/talous-reports.js:113`: `gross + refunds`; otsikko `ui.admin.reports.col_net` = "Veroton", `reports-texts.js:29`). Kirjanpitäjä voi lukea luvun väärin. "Avoimet maksut" -taulukko piirtää kaikki rivit ilman rajaa (`talous-reports.js:131–132`; kokeilutilassa 1 466 riviä yhdelle päivälle; tuotannon määrä OLETUS). Raporttivalitsimen `role=radio`-napit eivät tue nuolinäppäimiä (`talous-reports.js:319`). Kaavion vuosivalitsin on täysleveä, koska `select{width:100%}` (`admin.css:44`) ohittaa `.tl-sales-year`-säännön (`admin.css:554`), joten ‹ ja › ovat eri riveillä. "Hyvitysten seuranta" on sekä raporttivalinta että oma välilehti.
   - Ratkaisu: sarakkeen nimeksi "Yhteensä hyvitysten jälkeen (sis. ALV)"; "Avoimet maksut" 20 riviä + "Näytä kaikki"; raporttivalinta pudotusvalikoksi tai segmentiksi, joka toimii näppäimistöllä; `.tl-sales-year{width:auto}`; Hyvitysten seuranta pois raporttilistasta.
   - Hyväksymiskriteerit: sarakeotsikot vastaavat laskukaavaa; päiväraportti mahtuu alle kolmen näytön korkeuden; nuolinäppäintesti.
   - Tiedostot: `booking/admin/views/talous-reports.js`, `booking/admin/reports-texts.js`, `booking/admin/admin.css`.
   - Tietokanta: ei.
   - Riippuvuudet: – (sarakeotsikko kiireellinen).

2. **HALL-TALOUS-02 · SUURI · Päivän tilitys (kassan sulkeminen) puuttuu**
   - Ongelma (VARMA): päivän kassaraportti vaatii 5 vaihetta ja kaavion ohi vierityksen; "päivän tilitystä" (myynti maksutavoittain, korttipäätteen erän vertailu, erotus, kuittaus, lukitus) ei ole. Kassa- ja salonkiohjelmistoissa (Fresha, Timma) päivän sulkeminen on perustoiminto (OLETUS, yleistieto).
   - Ratkaisu: Talous › Raportit › ensimmäisenä "Päivän tilitys": myynti maksutavoittain, pikakassan myynti, avoimet linkit ja keskeneräiset hyvitykset; kenttä "korttipäätteen erän summa", erotus ja selitys; "Sulje päivä"; PDF.
   - Hyväksymiskriteerit: yksi näkymä ja tuloste päivää kohden; suljettu päivä näkyy lukittuna ja erotus kirjattuna.
   - Tiedostot: uusi `booking/admin/views/talous-closing.js`, `booking/admin/reports-texts.js`, `booking/admin/admin-navigation.js`.
   - Tietokanta: kyllä, luonnos:
     ```sql
     -- LUONNOS booking_xxx_day_closing (ei ajettu; Bottiavustus: ensin DEV, sitten PROD)
     create table booking.day_closings (
       day date primary key,
       expected numeric(12,2) not null,
       terminal_total numeric(12,2),
       difference numeric(12,2) generated always as (coalesce(terminal_total,0) - expected) stored,
       note text,
       closed_by uuid not null default auth.uid(),
       closed_at timestamptz not null default now());
     alter table booking.day_closings enable row level security;
     create or replace function booking.admin_close_day(p_day date, p_terminal_total numeric, p_note text) returns jsonb ...
       -- oikeus reports.daily; laskee expected maksuriveistä samalla logiikalla kuin maksutaparaportti; audit_log
     create or replace function booking.admin_get_day_closing(p_day date) returns jsonb ...
     ```
   - Riippuvuudet: HALL-KUORI-01, HALL-TALOUS-01.

3. **HALL-TALOUS-03 · PIENI · Teknisiä koodeja ilmoituksissa ja listoissa**
   - Ongelma (VARMA): onnistumisilmoitus näyttää RPC-nimen, esim. "Tehty (admin_set_gift_card_expiry)." (`talous-texts.js:96`, `talous-ui.js:185`); "Ominaisuus ei vielä käytössä (rpc)" (`talous-texts.js:55`); välittäjä "montonio"/"manual" (`views/refund-watch.js:54`); laskun lähetystila "none"/"dry_run" ja ALV "25.5" (`views/invoices.js:81, 84`); ISO-muotoinen eräpäivä (`invoices.js:55, 80`); lahjakortin voimassaolo "12.11.2026 – –" ilman päättymispäivää (`talous-giftcards.js:151`); yleinen `not_found` "Tapahtumaa ei löydy (se on voinut poistua kalenterista)" näkyy myös tilaukselle (`ui.js:99`).
   - Ratkaisu: ilmoituksiin vain selkokieli ("Voimassaolo jatkettu 31.3.2027 asti"); välittäjä- ja maksutapanimet yhdestä sanakirjasta; päivämäärät ja ALV yhteisellä muotoilulla; "Voimassa toistaiseksi"; kontekstikohtainen not_found.
   - Hyväksymiskriteerit: Talous-, Laskut-, Lahjakortit- ja Hyvitysten seuranta -näkymissä ei näy englanninkielisiä koodeja, RPC-nimiä eikä ISO-päivämääriä.
   - Tiedostot: `booking/admin/talous-texts.js`, `booking/admin/views/talous-ui.js`, `booking/admin/views/refund-watch.js`, `booking/admin/views/invoices.js`, `booking/admin/views/talous-giftcards.js`, `booking/admin/ui.js`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-04, YHT-05.

#### HALL-AVOIMET: seurattavat maksut ja hyvitysten seuranta (`#/seurattavat-maksut`, `#/hyvitysten-seuranta`)

Nykytila: Seurattavat maksut näyttää avoimet maksulinkit kortteina (summa, päätoiminto, ⋯-valikko, suodatinsirut määrineen); Hyvitysten seuranta näyttää välittäjän vahvistamatta olevat hyvitykset taulukkona (uudelleenyritys, käsin kirjaus). Molemmat ovat hyviä työjonoja, mutta ne ovat Kassa ja talous -ryhmän välilehtiä eivätkä näy Tarkista-merkissä.

1. **HALL-AVOIMET-01 · KESKI · Kaksi työjonoa yhdeksi "Avoimet maksut" -näkymäksi ja Tarkista-merkkiin**
   - Ongelma (VARMA): toimenpiteitä vaativat maksulinkit ja yli vuorokauden odottaneet hyvitykset eivät näy yläpalkin Tarkista-määrässä (`admin.js:198–227`), joten ne löytyvät vain, jos joku muistaa avata välilehden. Seurattavat maksut hakee vain 50 riviä, ja sirujen määrät lasketaan näistä (`paylink-watch.js:144–148`). Hyvitystaulukko muuttuu mobiilissa korteiksi ilman kenttäotsikoita (`refund-watch.js:49–55`, puuttuva `data-label`). Hakukentällä on vain placeholder (`paylink-watch.js:157`), ⋯-valikon nimi on kovakoodattu suomeksi (`:76`).
   - Ratkaisu: Tilaukset › "Avoimet maksut" -välilehti kahdella osiolla (Maksulinkit, Hyvitykset), välilehdellä määrämerkki; `needs_action`-linkit ja yli 24 h odottaneet hyvitykset Tarkista-määrään; määrät palvelimelta; mobiilikorteille kenttäotsikot.
   - Hyväksymiskriteerit: jokainen toimenpidettä vaativa maksu tai hyvitys näkyy Tarkista-merkissä; määrät ovat oikein yli 50 rivillä.
   - Tiedostot: `booking/admin/views/paylink-watch.js`, `booking/admin/views/refund-watch.js`, `booking/admin/admin.js`, `booking/admin/views/review.js`, `booking/admin/review-logic.js`, `booking/admin/admin-navigation.js`.
   - Tietokanta: suositus: `admin_review_list` palauttaa myös näiden määrät (yksi kutsu); muuten kaksi lisäkutsua selaimesta.
   - Riippuvuudet: HALL-KUORI-01, HALL-KUORI-05.

#### HALL-LASKUT: laskut (`#/laskut`)

Nykytila: "Uusi lasku" (pitkä dialogi YTJ-haulla) ja "Tilauksesta", haku ja suodattimet; esikatselu aukeaa listan alle.

1. **HALL-LASKUT-01 · PIENI · "Lasku tilauksesta" kysyy tilausnumeroa mutta hakee sisäisellä tunnisteella**
   - **Tila 13.11.2026:** Valmis, PR #350 (`booking/admin/invoice-from-order.js`).
   - Ongelma (VARMA): dialogin kenttä on "Tilausnumero" (`booking/admin/invoices-texts.js:62`), ja arvo lähetetään parametrina `p_order_id` (`views/invoices.js:123`), jota funktio vertaa sisäiseen tunnisteeseen `o.id = p_order_id` (`booking/supabase/migrations/20261019011600_booking_92_invoice_checkout.sql:167`; funktio on md5-vartioitu myöhemmissä migraatioissa 175 ja 187, joten se ei ole muuttunut). Henkilökunnan syöttämä tilausnumero (esim. 15123) ei löydä tilausta tai, pahimmillaan, löytää väärän.
   - Ratkaisu: dialogi hakee tilauksen tilausnumerolla (`admin_order_lookup` tai `admin_list_orders`) ja näyttää asiakkaan ja summan ennen luontia ("Luo lasku tilauksesta 15123 · Yritys Oy · 256,00 €"); parempi vielä: "Luo lasku" -toiminto tilausnäkymään.
   - Hyväksymiskriteerit: tilausnumero 15123 luo laskun oikealle tilaukselle; väärä numero antaa selvän virheen.
   - Tiedostot: `booking/admin/views/invoices.js`, `booking/admin/invoices-texts.js`, `booking/admin/views/order-view.js`.
   - Tietokanta: ei (tilausnumero muunnetaan tunnisteeksi selaimessa).
   - Riippuvuudet: – (kiireellinen).

2. **HALL-LASKUT-02 · KESKI · Laskuluonnosta ei voi muokata, vaaralliset toiminnot ilman vahvistusta**
   - Ongelma (VARMA): `editor(existing)` on olemassa, mutta mikään painike ei kutsu sitä (`invoices.js:62–75, 158`), joten virheellinen luonnos pitää mitätöidä ja tehdä uudelleen; "Hyvityslasku", "Mitätöi luonnos" ja "Merkitse maksetuksi" toimivat ilman vahvistusta (`invoices.js:71–73`); lista hakee 100 riviä ilman sivutusta (`invoices.js:47`); näkymällä on oma sisennys ja painikkeet kiinni Haku-otsikossa.
   - Ratkaisu: "Muokkaa luonnosta"; vahvistusdialogit; laskun tiedot sivupaneeliin kuten tilauksissa; sivutus; ulkoasu yhteisillä komponenteilla.
   - Hyväksymiskriteerit: luonnoksen voi korjata; jokainen peruuttamaton toiminto kysyy vahvistuksen.
   - Tiedostot: `booking/admin/views/invoices.js`, `booking/admin/invoices-texts.js`.
   - Tietokanta: ei (valinnainen: `admin_mark_invoice_paid` saa maksupäivän).
   - Riippuvuudet: YHT-02, YHT-06.

#### HALL-LAHJAKORTIT: omat lahjakortit ja lunastuspyynnöt (`#/lahjakortit`)

Nykytila: haku ensin (lista ei avaudu ennen hakua tai "Selaa kaikkia"), myyntitilan merkit, "Uusi lahjakortti"; avattu rivi näyttää tiedot, pikajatkot +1/+3/+6 kk, voimassaolon muutoksen, saldon korjauksen, mitätöinnin ja historian. Lunastuspyynnöt-välilehti listaa asiakkaiden syöttämät kumppanikoodit. Voimassaolon jatko (4 vaihetta) on koko talousosion paras työnkulku.

1. **HALL-LAHJAKORTIT-01 · KESKI · Lahjakortin puhelinmyynti vie 12+ vaihetta kahdessa näkymässä, eikä englanniksi voi myydä**
   - Ongelma (VARMA): maksutapana ei ole maksulinkkiä (`giftcards-api.js:15`): Uusi lahjakortti → Maksa myöhemmin → 15 kenttää yhdessä dialogissa → Luo → tulosdialogissa tilausnumero tekstinä → Tilaukset → haku → avaa → Luo maksulinkki → Lähetä. Kieli on kovakoodattu (`locale: 'fi'`, `talous-giftcards.js:296`).
   - Ratkaisu: maksutapa "Maksulinkki sähköpostiin" (`admin_create_gift_card(p_payment_method='pay_later')` + heti `createPaymentLink({ sendEmail: true })`); kielivalinta (`p_locale` on jo olemassa); dialogi kahteen vaiheeseen (kortti ja maksu → toimitus ja tervehdys); tulosdialogissa linkki tilaukseen.
   - Hyväksymiskriteerit: puhelinmyynti enintään 6 vaiheessa yhdessä näkymässä; englanninkielinen kortti mahdollinen.
   - Tiedostot: `booking/admin/views/talous-giftcards.js`, `booking/admin/giftcards-api.js`, `booking/admin/giftcards-texts.js`.
   - Tietokanta: ei, jos kahden kutsun ketju riittää; atominen vaihtoehto `admin_create_gift_card(…, p_send_payment_link boolean default false)`.
   - Riippuvuudet: –

2. **HALL-LAHJAKORTIT-02 · PIENI · Myyntikytkimet ja haku**
   - Ongelma (VARMA): merkit "Verkkomyynti: pois", "Lunastus: päällä", "Johku-korttien lunastus: pois" ovat vain luku -tietoa (`talous-giftcards.js:87–88`), vaikka ohje sanoo "Muutos tallentuu heti" (`giftcards-texts.js:21`); muokkaus on Asetuksissa (`views/settings.js:325`) ilman linkkiä. Hakukenttä on 420 px leveä (`admin.css` `.fld{max-width:420px}`), ja paikkamerkki katkeaa; lista ei näytä mitään ennen hakua.
   - Ratkaisu: `settings.edit`-oikeudella oikeat kytkimet tässä näkymässä (ja Asetuksista pois, HALL-ASETUKSET-01), muuten linkki; ohjeteksti oikeaksi; täysleveä haku; oletuksena 20 viimeisintä korttia.
   - Hyväksymiskriteerit: kytkimen tila ja muokkaus samassa paikassa; näkymä ei ole tyhjä avattaessa.
   - Tiedostot: `booking/admin/views/talous-giftcards.js`, `booking/admin/giftcards-texts.js`, `booking/admin/views/settings.js`.
   - Tietokanta: ei.
   - Riippuvuudet: HALL-ASETUKSET-01.

3. **HALL-LAHJAKORTIT-03 · KESKI · Kumppanikoodeilla kolme eri käyttöliittymää**
   - Ongelma (VARMA): Lunastuspyynnöt (`views/talous-vouchers.js:103–107`) ei linkitä kumppanin lunastussivulle; tilauksen laatikossa ja Tarkista-sivulla (`views/voucher-redeem.js:79–85`) linkki ja myyjän vaihto ovat; kolmas reitti on Kirjaa maksu › Lahjakortti › tuntematon koodi (`talous-giftcards.js:44–50`). Sama asia on nimeltään "Lunastuspyyntö", "Kumppanin lahjakortti" ja "Kumppanilahjakortit lunastamatta"; sarakeotsikot eivät osu riveille (`talous-vouchers.js:168`); tila on sekä siruissa että suodatinvalikossa (`:143, 157`).
   - Ratkaisu: yksi rivikomponentti (`voucher-redeem.js` `claimRow`) kaikkiin kolmeen paikkaan; nimi kaikkialla "Kumppanikoodit"; sarakkeet korjataan; yksi tilasuodatin.
   - Hyväksymiskriteerit: sama rivi ja samat toiminnot (myös lunastuslinkki) joka paikassa.
   - Tiedostot: `booking/admin/views/talous-vouchers.js`, `booking/admin/views/voucher-redeem.js`, `booking/admin/vouchers-texts.js`, `booking/admin/voucher-redeem-texts.js`.
   - Tietokanta: tarkista, palauttaako `admin_get_voucher_claim` lunastus-URL:n (OLETUS: ei); tarvittaessa kenttä lisätään.
   - Riippuvuudet: HALL-KUORI-01.

#### HALL-ALENNUS: alennuskoodit ja vuosikortit (`#/alennuskoodit`)

Nykytila: alennuskoodit kortteina (Muokkaa, Poista), samalla sivulla vuosikortit (Peru, Poista, Myönnä vuosikortti); tekstit kovakoodattua suomea.

1. **HALL-ALENNUS-01 · PIENI · Koodin tuote näkyy numerona, vahvistukset selaimen ikkunoilla**
   - Ongelma (VARMA): koodi, joka koskee pois käytöstä olevaa tuotetta, näyttää "Tuotteet: #1", koska epäaktiiviset tuotteet suodatetaan nimihausta pois (`views/discounts.js:21–22`); poistot ja vuosikortin peruutus käyttävät `confirm()`-ikkunoita, peruutuksessa kaksi peräkkäin ohjeella "OK = peru, Peruuta = säilytä" (`discounts.js:36, 59–60`); "Poista"-painikkeet ovat kahta eri tyyliä samalla sivulla.
   - Ratkaisu: nimi myös epäaktiiviselle tuotteelle ("Yleinen vuoro (ei käytössä)") ja varoitus, jos koodin kaikki tuotteet ovat pois käytöstä; yksi vahvistusdialogi, jossa vaihtoehdot nimetty ("Peru kortti ja tulevat varaukset" / "Peru vain kortti"); tekstit sanakirjaan.
   - Hyväksymiskriteerit: yhtään tuotetunnusta ei näy; ei `confirm()`-ikkunoita.
   - Tiedostot: `booking/admin/views/discounts.js`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-06.

2. **HALL-ALENNUS-02 · KESKI · Koodin käyttöä ei voi seurata**
   - Ongelma (VARMA): kortti näyttää vain käyttökertojen määrän (`used_count`, `discounts.js:14`); ei näe, mihin tilauksiin koodia on käytetty eikä paljonko myyntiä se toi. Kampanjan onnistumista ei voi arvioida.
   - Ratkaisu: koodin "Käyttö"-paneeli: tilaukset, myynti ja annettu alennus yhteensä, linkit tilauksiin.
   - Hyväksymiskriteerit: kampanjakoodin tulos näkyy yhdellä klikkauksella.
   - Tiedostot: `booking/admin/views/discounts.js`.
   - Tietokanta: kyllä, luonnos: `booking.admin_discount_code_usage(p_id bigint) returns table(order_no bigint, created_at timestamptz, customer_name text, total_gross numeric, discount numeric)`, oikeus `catalog.edit`.
   - Riippuvuudet: –

#### HALL-TUOTTEET: tuotteet, tuotekuva, tuotevalinnat ja lisäpalvelut (`#/tuotteet`)

Nykytila: lista (13 tuotetta: nimi, kategoria, merkit Verkossa/Pikakassa/QR, hinta, ALV), haku ja suodatinlaatikko (näkyvyys, kategoria; tila URL:ssa). Saman sivun alaosassa "Tuotevalinnat (hoidot)" ja "Lisäpalvelut". Tuote avautuu leveään dialogiin: nimet, neljä rikastekstieditoria, hinta ja ALV, hintateksti, Aktiivinen, tuotekuva, verkkokaupan asetukset ja pikakassa, lisämyynti (vain admin) ja hintavariantit (`booking/admin/views/products.js`).

Työnkulut nyt (VARMA): hinnan muutos 5–6 vaihetta (ja muista päivittää hintateksti käsin); uusi tuote kuvineen noin 11 vaihetta, 3 tallennusta ja 2 avauskertaa; tuotteen piilotus kaupasta 4 vaihetta ja noin 1 500 px vieritystä.

1. **HALL-TUOTTEET-01 · KESKI · Tuote-editori on 3 200 px:n dialogi, jossa 4–5 tallennusta ja muutokset katoavat**
   - Ongelma (VARMA): dialogin sisältö on 1280 × 800 -näytöllä 3 236 px korkea (mitattu). Tallennuspainikkeet: Tallenna tuote, Tallenna kuva, Tallenna asetukset, lisämyynnin tallennus ja jokaisen hintavariantin Tallenna (`products.js:114–185`). Tuotteen, asetusten ja kuvan tallennus sulkee dialogin ja lataa näkymän uudelleen (`products.js:142, 166, 168, 274`), jolloin muiden osioiden tallentamattomat muutokset katoavat ilman varoitusta; dialogi ei estä sulkemista (Esc) muutosten ollessa kesken (`ui.js:132–139`). Hintateksti on ylläpidettävä käsin ("Päivitä teksti kun muutat hintaa", `products.js:126`), mutta luonnissa "Tyhjä kenttä täytetään hinnasta" (`product-texts.js:21`). Sama kenttä on luonnissa ja muokkauksessa eri nimellä ("Nimi (FI)" / "Nimi (suomi)", "ALV" / "Alv-prosentti") (`products.js:115–119` vs. `product-texts.js:16–22`).
   - Miksi tärkeää: tuotteiden ylläpito on yleisin hallintatehtävä hallinnan omistajalle, ja nykyinen editori hävittää työtä.
   - Ratkaisu: oma näkymä `#/tuotteet/<id>` (työpöydällä sivupaneeli) välilehdillä Perustiedot · Hinnat · Myynti ja näkyvyys · Kuva · Valinnat ja lisäpalvelut · Lisämyynti; yksi kiinnitetty "Tallenna muutokset" -palkki, joka ajaa tarvittavat RPC:t peräkkäin ja kertoo, mikä osa epäonnistui; varoitus tallentamattomista muutoksista; hintateksti päivittyy automaattisesti, ellei sitä ole muokattu käsin; samat kenttänimet luonnissa ja muokkauksessa.
   - Hyväksymiskriteerit: hinnan ja näkyvyyden muutos yhdellä tallennuksella; näkymä ei sulkeudu tallennuksessa; Esc ja navigointi kysyvät, jos muutoksia on tallentamatta.
   - Tiedostot: `booking/admin/views/products.js`, `booking/admin/views/productimage.js`, `booking/admin/product-texts.js`, `booking/admin/ui.js`, `booking/admin/admin.css`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-02, YHT-06.

2. **HALL-TUOTTEET-02 · KESKI · Neljä päällekkäistä näkyvyysasetusta: henkilökunta ei voi ennustaa, näkyykö tuote kaupassa**
   - Ongelma (VARMA): näkyvyyteen vaikuttavat "Aktiivinen (näkyy kb:ssä)" (`products.js:127`), "Varattavissa verkossa" ja "Näkyy kaupan listassa" (`:148–149`), myyntikanavat Tapahtumat › Asetukset -välilehdellä (`views/events.js:254–266`) ja käyttöliittymässä näkymätön `lifecycle`. "Verkossa"-merkki lasketaan näiden yhdistelmästä (`products.js:36–41`).
   - Ratkaisu: yksi valinta kolmella vaihtoehdolla: "Myynnissä verkossa" · "Vain kassalla ja hallinnassa" · "Piilotettu"; lisäksi selitys, jos tuote ei voi näkyä verkossa ("kesto puuttuu", "ei vuoroja", "ei kuvaa").
   - Hyväksymiskriteerit: tuotteen saa piiloon kaupasta yhdellä valinnalla ja tallennuksella; selitys näkyy aina, kun valittu tila ei toteudu.
   - Tiedostot: `booking/admin/views/products.js`, `booking/admin/views/events.js`, tekstit.
   - Tietokanta: suositus atominen `booking.admin_set_product_visibility(p_product_id bigint, p_mode text)` (`online`/`internal`/`hidden`), joka asettaa `active`, `bookable`, `shop_visible` ja kanavat johdonmukaisesti; väliaikaisesti toimii olemassa olevilla RPC:illä.
   - Riippuvuudet: HALL-TUOTTEET-01.

3. **HALL-TUOTTEET-03 · KESKI · Uuden tuotteen luonti lupaa liikoja, eikä tapahtumaa tai koulutusta voi luoda tyhjästä**
   - Ongelma (VARMA repossa; tuotannon tila OLETUS): kategoriavalikossa on 13 kategoriaa, myös hoidot, vuorot, tapahtumat ja koulutukset (`products.js:20, 203`), mutta palvelin luo varauskonfiguraation tilassa `bookable=false`, `public_slots=false`, resurssiluokka `none`, kesto `null` (`booking/supabase/migrations/20261021171915_booking_122_rich_text.sql:276–279`). Hoito- tai vuorotuote ei siis tule myyntiin ilman kehittäjää. Tapahtumat-näkymässä ei ole "Uusi tapahtuma" -painiketta (`events.js:146–152`), vain "Kopioi tapahtuma" (`:420–432`); koulutuksilla vain "Kopioi seuraavaksi jaksoksi" piilotetussa laatikossa (`koulutukset.js:83–88`).
   - Ratkaisu: luonnin alussa tyyppi: Kassatuote · Lisäpalvelu · Tapahtuma · Koulutus · Hoito tai vuoro. Tapahtuma, koulutus ja hoito/vuoro luodaan mallituotteen kopiona (`admin_product_copy` on olemassa); "Uusi tapahtuma" Tapahtumat-näkymään ja "Uusi koulutus" Koulutuksiin.
   - Hyväksymiskriteerit: jokainen valittavissa oleva tyyppi on luonnin jälkeen myytävissä ilman kehittäjää (hoito/vuoro vaatii lisäksi HALL-TILAT-01:n vuorot).
   - Tiedostot: `booking/admin/views/products.js`, `booking/admin/views/events.js`, `booking/admin/views/koulutukset.js`, tekstit.
   - Tietokanta: ei kevyessä versiossa; jos mallit halutaan dataksi, taulu `booking.product_templates` (luonnos erikseen).
   - Riippuvuudet: HALL-TUOTTEET-01, HALL-TILAT-01.

4. **HALL-TUOTTEET-04 · KESKI · Hintavariantit ja kesto eivät ole henkilökunnan muokattavissa**
   - Ongelma (VARMA): `admin_update_price_variant` sallii nimen, sisältyvät henkilöt, lisähenkilön hinnan ja aktiivisuuden, mutta käyttöliittymä näyttää vain hinnan (`products.js:170–174`); uuden variantin luontiin ei ole RPC:tä, joten kausihinnat vaativat kehittäjän. `admin_update_product_config` sallii keston (`duration_minutes`, booking_81), mutta lomake ei lähetä sitä (`products.js:163`). Tuotteen aikajanalle (`admin_set_product_timeline`, booking_64) ei ole käyttöliittymää.
   - Ratkaisu: varianttirivillä kaikki sallitut kentät; "Lisää hintavariantti" (nimi, hinta, sisältyvät henkilöt, lisähenkilön hinta, voimassaolo); kesto tunteina ja minuutteina.
   - Hyväksymiskriteerit: manager lisää kausihinnan ja muuttaa tuotteen keston ilman kehittäjää.
   - Tiedostot: `booking/admin/views/products.js`, `booking/admin/product-texts.js`.
   - Tietokanta: kyllä, vain variantin luonti: `booking.admin_create_price_variant(p_product_id bigint, p_label text, p_price numeric, p_included_persons int, p_extra_person_price numeric, p_valid_from date, p_valid_to date)`, oikeus `catalog.edit`, kirjaus `kb.change_log`iin kuten muissa kb-muutoksissa. Tarkista `kb.product_price_variants`-taulun voimassaolosarakkeet tuotannosta.
   - Riippuvuudet: HALL-TUOTTEET-01.

5. **HALL-TUOTTEET-05 · PIENI · Lista sarakkeiksi ja valinnat sekä lisäpalvelut omille välilehdilleen**
   - Ongelma (VARMA, kuva): listan merkit ja hinnat eivät asetu linjaan, koska nimi ja kategoria rivittyvät eri pituisiksi; ei lajittelua. Tuotevalinnat ja Lisäpalvelut on liitetty saman sivun alaosaan, ja sivulla on otsikko "Tuotteet" kolmesti (H1, välilehti, H2). Lisäpalvelu kohdistuu vuorotyyppiin eikä tuotteeseen, mikä ei selviä sivulta.
   - Ratkaisu: taulukkomainen lista (Nimi · Kategoria · Myynti · Hinta · ALV), lajittelu nimen ja kategorian mukaan; Tuotevalinnat ja Lisäpalvelut Tarjonta-ryhmän omiksi välilehdiksi tai tuote-editorin välilehdeksi; yksi otsikko.
   - Hyväksymiskriteerit: hinnat samassa sarakkeessa; sivulla yksi H1.
   - Tiedostot: `booking/admin/views/products.js`, `booking/admin/views/productoptions.js`, `booking/admin/views/addons.js`, `booking/admin/admin.css`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-03, HALL-KUORI-01.

6. **HALL-TUOTTEET-06 · PIENI · Pikakorjaukset: ALV-muoto, kehittäjäkieli, koodit ja käännösten puutteet**
   - Ongelma (VARMA): listoissa "ALV 25.5 %" pisteellä (`products.js:57`, `addons.js:66`), valikoissa pilkulla; lisäpalveluiden ALV-listassa vanhentuneet kannat 24, 14 ja 10 % (`addons.js:13`), tuotteilla 25,5 / 13,5 / 0 % (`products.js:19`); kehittäjäkieli "kb:ssä" (`products.js:126–127`), "product_config puuttuu" (`:159`), "oikeuden catalog.edit" (`addons.js:83`, `options-logic.js:12`), "sivusto ja botti käyttävät samaa totuutta" (`products.js:242`); uudelle vaihtoehdolle ja lisäpalvelulle pitää kirjoittaa tekninen koodi a–z/0–9/_ (`productoptions.js:165, 180`, `addons.js:76`); lisämyynti vain adminille, muualla `catalog.edit` riittää (`products.js:184`), ja osio katoaa hiljaa, jos tekstit puuttuvat (`product-suggestions.js:114`); tyhjä EN-nimi tallentaa FI-nimen (`product-texts.js:18`), eikä listassa ole "EN puuttuu" -merkkiä.
   - Ratkaisu: ALV aina pilkulla ja voimassa olevat kannat yhdestä lähteestä (`vat_rates`); kehittäjätermit pois; koodi generoidaan nimestä; lisämyyntiin `catalog.edit`; "EN puuttuu" -merkki ja suodatin "Käännös puuttuu".
   - Hyväksymiskriteerit: Tuotteet-näkymässä ei näy tauluja, oikeuskoodeja eikä pisteellistä ALV:tä; käännöksen puute näkyy listassa.
   - Tiedostot: `booking/admin/views/products.js`, `booking/admin/views/addons.js`, `booking/admin/views/productoptions.js`, `booking/admin/options-logic.js`, `booking/admin/views/product-suggestions.js`, `booking/admin/product-texts.js`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-05.

#### HALL-TAPAHTUMAT: tapahtumat (`#/tapahtumat`)

Nykytila: tunnusluvut, lista tai kalenteri, suodattimet; tapahtuman sisällä välilehdet Yleiskatsaus, Kerrat, Osallistujat, Viestit, Asetukset. Kertojen lisäys kalenterista ja viikkotoistolla, osallistujalista (CSV, tulostus, muistiinpano) ja viesti osallistujille toimivat hyvin (Bókunin tasoa: kerran lisäys 8 vaihetta).

1. **HALL-TAPAHTUMAT-01 · KESKI · Tapahtumien myyntiä ei voi avata hallinnasta**
   - Ongelma (VARMA repossa; tuotannon tila OLETUS): näkymä kertoo "Tapahtumien myynti on vielä suljettu" (`events.js:147, 235`), mutta asetukselle `events.sale_enabled` (booking_158) ei ole kytkintä missään eikä se kuulu `admin_save_settings`-funktion sallittuihin osioihin.
   - Ratkaisu: kytkin vahvistuksella Tapahtumat-näkymään (ja Asetukset › Yleiset).
   - Hyväksymiskriteerit: manager avaa tapahtumien myynnin ilman kehittäjää; tila näkyy samassa paikassa.
   - Tiedostot: `booking/admin/views/events.js`, `booking/admin/views/settings.js`, tekstit.
   - Tietokanta: kyllä, pieni: `admin_save_settings` saa sallitun osion `events_sale` (avain `events.sale_enabled`), oikeus `settings.edit`.
   - Riippuvuudet: HALL-ASETUKSET-01.

2. **HALL-TAPAHTUMAT-02 · PIENI · Pikakorjaukset Tapahtumat-näkymään**
   - Ongelma (VARMA): kerran muokkauslomakkeen peruutuspainikkeessa lukee "Ei viestiä" (`events.js:352` käyttää avainta `time_changed_skip`, `events-texts.js:226`); menneillä kerroilla näkyvät Muokkaa, Peruuta ja Poista (`events.js:327–330`); "Lisää kertoja" -lomake on aina auki listan yläpuolella, joten olemassa olevat kerrat alkavat noin 1 000 px alempana (`events.js:238, 487–496`); kesto minuutteina (koulutuksella enintään 43 200); jokaisella kerralla 7 painiketta ja listarivillä 4; listan ajankohta kahdesti eri muodoissa ("15.11.2026 klo 17.00" ja "su 15.11.2026 17:00–19:30"); otsikko "Tapahtumat ja koulutukset", vaikka Koulutukset on oma päävalikon kohta; välilehdissä `role=tab` ilman nuolinäppäimiä ja `aria-controls`-määritettä (`events.js:231–232`).
   - Ratkaisu: "Peruuta"; menneiltä kerroilta muokkaus pois; "Lisää kertoja" painikkeen taakse; kesto tunteina ja minuutteina; rivillä yksi ensisijainen toiminto ja loput ⋯-valikossa; ajankohta kerran; otsikko "Tapahtumat"; yhteinen välilehtikomponentti.
   - Hyväksymiskriteerit: olemassa olevat kerrat näkyvät ilman vieritystä; ei toimintoja menneillä kerroilla.
   - Tiedostot: `booking/admin/views/events.js`, `booking/admin/events-texts.js`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-03.

#### HALL-HILJAISET: hiljaiset ajat (`#/hiljaiset-ajat`)

Nykytila: selkeä ja hyvin rajattu: päälle/pois, portaat (esim. −20 % 72 h ennen) ja esikatselu vuoroista, jotka saisivat alen. Verrokeissa vastaava (dynaaminen hinnoittelu) on harvinaisempi; tämä on Saunotuksen vahvuus.

1. **HALL-HILJAISET-01 · PIENI · Päälle/pois-ohjain ja vahvistukset muiden kaltaisiksi**
   - Ongelma (VARMA): päälle kytketään painikkeella "Ota käyttöön" ja selaimen `confirm()`-ikkunalla (`views/quiet.js:31–34, 49`), kun Asetuksissa on kytkin + Tallenna ja Viesteissä heti tallentuva valintaruutu.
   - Ratkaisu: yhteinen kytkin (YHT-02) ja vahvistusdialogi (YHT-06).
   - Hyväksymiskriteerit: sama ohjain ja vahvistus kuin muualla.
   - Tiedostot: `booking/admin/views/quiet.js`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-02, YHT-06.

#### HALL-KOULUTUKSET: koulutukset ja matkat (`#/koulutukset`)

Nykytila: uusi työtila: korttilista, jakson yhteenveto, "Onko valmis?" -tarkistuslista, välilehdet Osallistujat, Viestit, Maksut, Tilat ja jonolista. Vanha tapahtumaeditori (Tekstit, Kerrat, Asetukset) on piilossa "Muut tiedot" -laatikossa.

1. **HALL-KOULUTUKSET-01 · PIENI · Ulkoasu poikkeaa muista ja pieniä tekstivirheitä**
   - Ongelma (VARMA): H1 on selvästi muita suurempi ja välilehdet ovat täytettyjä tummia laattoja (`.training-tabs`), kun muualla on alleviivatut välilehdet; välilehdissä pelkkä `active`-luokka ilman `aria-current`/`aria-selected` (`koulutukset.js:41–42, 71`); yhteenvedossa "Tilat Tilat varattu" (`koulutukset.js:69`); "Muut tiedot" -laatikossa linkki, jonka nimi on myös "Muut tiedot" ja joka vie vanhaan Kerrat-editoriin (`:84–86`); kortissa "Paikat 2 / 8" mutta "Vapaita paikkoja –".
   - Ratkaisu: Koulutukset pysyy omana päävalikon kohtanaan ja omana työtilanaan, koska sinne tulee jatkossa paljon lisää (Joonaksen päätös 13.11.); siksi sen pohjaksi yhteiset komponentit nyt, ennen kuin osio kasvaa: yhteinen otsikko- ja välilehtikomponentti; tekstikorjaukset; linkin nimeksi "Muokkaa kertoja ja tekstejä"; vapaat paikat lasketaan.
   - Hyväksymiskriteerit: Koulutukset näyttää samalta kuin muut näkymät; ei toistuvia sanoja.
   - Tiedostot: `booking/admin/views/koulutukset.js`, `booking/admin/training-texts.js`, `booking/admin/admin.css`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-03.

#### HALL-VIESTIT: viestipohjat ja viesti asiakkaille (`#/viestit`)

Nykytila: Pohjat (lista ja dialogi: luokka, toimitustapa, aihe ja teksti FI/EN, ajastus, tuotteet, paikkamerkit; ajastuskytkin tallentuu heti) ja Viesti asiakkaalle (päiväväli, varatut tuotteet, aihe ja teksti FI/EN, esikatselu, vahvistus, loki: hyvä toteutus).

1. **HALL-VIESTIT-01 · KESKI · Kolme erilaista viestityökalua ja puuttuvat perustoiminnot**
   - Ongelma (VARMA): tapahtumien viesti on yksikielinen (`events.js:628–667`), koulutusten ja "Viesti asiakkaalle" kaksikielisiä (`koulutukset.js:154–157`, `customer-message-panel.js:137–145`); paikkamerkit ovat eri muodoissa (`{asiakas_nimi}`, `{tilaus_linkki}` `messages-logic.js:24–30` vs. `{asiakkaan nimi}`, `{tilauslinkki}` `customer-message-logic.js:5–12`), tapahtumaviestissä ei paikkamerkkejä lainkaan. Pohjia ei voi poistaa tai arkistoida, esikatsella eikä lähettää testinä itselle (`messages.js:58–139`; tietokannassa vain `admin_save_message`). Vahvistusviestin tekstiä ei voi muokata (vain Ohje-pohjan lyhyt teksti liitetään vahvistukseen).
   - Ratkaisu: yksi viestikomponentti tapahtumille, koulutuksille ja asiakasviestille (FI/EN, samat paikkamerkit, esikatselu, testilähetys omaan osoitteeseen); pohjiin Arkistoi ja Esikatsele; vahvistusviestin tekstit SIVU-YHT-03:n Tekstit-näkymästä.
   - Hyväksymiskriteerit: kaikissa kolmessa paikassa samat kentät ja paikkamerkit; testilähetys menee vain henkilökunnan omaan osoitteeseen.
   - Tiedostot: `booking/admin/views/messages.js`, `booking/admin/messages-logic.js`, `booking/admin/views/customer-message-panel.js`, `booking/admin/customer-message-logic.js`, `booking/admin/views/events.js`, `booking/admin/views/koulutukset.js`.
   - Tietokanta: kyllä, luonnos: `admin_event_message_send` saa parametrit `p_subject_en` ja `p_body_en`; paikkamerkkien täyttö tukee yhtä muotoa (vanha muoto ohjataan uuteen); uudet `admin_message_test_send(p_message_id bigint)` (vastaanottaja aina kutsujan oma osoite) ja `admin_archive_message(p_message_id bigint)`.
   - Riippuvuudet: SIVU-YHT-03.

2. **HALL-VIESTIT-02 · PIENI · Viestit-sivun ulkoasu ja kehittäjäkieli**
   - Ongelma (VARMA, kuva): välilehdet ovat alleviivattuja linkkejä otsikon yläpuolella ja ikoni otsikon päällä (ainoa näin tehty näkymä); listarivillä nimisarake on liian kapea, ja teksti rivittyy "[…] Ohje2 päivää ennen saapumista" (nimi ja ajoitus liimautuvat yhteen); oikeuskoodi "messages.edit" näkyy tekstissä (`messages.js:30`); ajastuskytkin tallentuu heti, kun muut kytkimet vaativat Tallenna-painikkeen (`messages.js:42–46`).
   - Ratkaisu: yhteinen sivun otsikko ja välilehdet; rivillä nimi, ajoitus ja tila omissa sarakkeissaan; kehittäjäkieli pois; kytkin YHT-02:n mukaan.
   - Hyväksymiskriteerit: Viestit näyttää samalta kuin muut näkymät; rivit luettavia 1280 ja 390 px:llä.
   - Tiedostot: `booking/admin/views/messages.js`, `booking/admin/admin.css`.
   - Tietokanta: ei.
   - Riippuvuudet: YHT-02, YHT-03.

#### HALL-ASETUKSET: asetukset (`#/asetukset/<välilehti>`)

Nykytila: 10 pillerivälilehteä (Etusivu, Yritys, Varaukset, Maksut, Sähköposti, Lahjakortit, Laskut ja kuitit, Yhteydet, Tekninen, QR), jotka vuotavat yli 1280 px:n leveydellä; jokaisella kortilla oma Tallenna. Sivu uudistettiin lokakuussa (`docs/asetukset-uudistus.md`), ja integraatioiden live-tilat on jo poistettu kytkimistä, mikä on hyvä.

1. **HALL-ASETUKSET-01 · KESKI · 10 välilehteä → 5, yksi tallennuspalkki**
   - Ongelma (VARMA): noin 13 korttia 27:stä on pelkkää tilatietoa (esim. "Maksut ja yhteydet" Etusivulla ja uudelleen Yhteyksissä, "Allekirjoitus: Tapio" ilman toimintoa, Saunabotin tila kovakoodattu "Pois" `settings.js:194`); Varaukset-välilehdellä Google-kalenterivientin teknisiä kenttiä (kalenteritunnukset, aikavyöhyke, päiviä taakse/eteen); Yhteyksissä noin 25 Procountor-tilikenttää; Tekninen-välilehdellä 17 rajaa ja polkuja, ja 390 px:llä sivu levenee 518 px:iin; QR-tulostus on Asetuksissa, vaikka oma ohje sanoo "Ei ole asetus"; lahjakorttien kytkimet sekä täällä että Lahjakortit-näkymässä; pitoajat näkyvät, vaikka ne vaikuttavat vain tilassa "pidä kunnes maksettu" (`settings.js:284–288`); kytkimet tallentuvat eri tavoin eri näkymissä (`settings.js:60–69` vs. `messages.js:42–46` vs. `quiet.js:31–34`); otsikko "Asetukset" kolmesti.
   - Ratkaisu, rakenne:
     1. **Yleiset**: verkkovaraus päälle/pois, tapahtumien myynti päälle/pois (HALL-TAPAHTUMAT-01), yritystiedot ryhmiteltynä "Näkyy asiakkaalle / Viralliset tiedot".
     2. **Varaukset**: varausikkunat, takarajat, ryhmä, vuosikortti.
     3. **Maksut ja laskutus**: maksutavat, yrityslasku, eräpäivä ja tili, provisiosäännöt; pitoajat vain kun maksutila sitä vaatii.
     4. **Järjestelmä** (vain admin, osiot oletuksena kiinni): yhteyksien tilat yhdessä paikassa, Procountor-tilit, Google-kalenterivienti, tekniset rajat, polut, kuittisarjat.
     5. **Käyttäjät** (HALL-KAYTTAJAT-01).
     Siirrot: sähköpostin lähettäjä ja ajastuskytkin Sisältö › Viestit -ryhmään; lahjakorttiasetukset Lahjakortit-näkymään; QR-tulostus Tuotteisiin (QR-linkki on tuotteen ominaisuus).
     Jokaisella välilehdellä yksi kiinnitetty tallennuspalkki ("2 muutosta · Tallenna · Hylkää").
   - Hyväksymiskriteerit: managerin näkymässä enintään 4 välilehteä ja vain muokattavia kenttiä; mikään asetus ei ole kahdessa paikassa; ei vaakavieritystä 390 px:llä.
   - Tiedostot: `booking/admin/views/settings.js`, `booking/admin/settings-tabs.js`, `booking/admin/settings-texts.js`, `booking/admin/settings-logic.js`, `booking/admin/admin-navigation.js`, `booking/admin/qr-panel.js`.
   - Tietokanta: ei (tapahtumien myyntikytkin HALL-TAPAHTUMAT-01:ssä).
   - Riippuvuudet: YHT-02, HALL-KUORI-01.

2. **HALL-ASETUKSET-02 · KESKI · Kuittilogoa ei voi vaihtaa eikä provisiosääntöä muokata**
   - Ongelma (VARMA): yritystiedoissa on neljä nimikenttää (Nimi kaupassa, Nimi kuitissa, Virallinen nimi, Toiminimi) mutta logosta vain teksti "Kuittilogo on asetettu" ilman latausta (`settings.js:206–224`); provisiosäännön voi vain lisätä tai poistaa (`views/fee-rules-panel.js:53, 64`), ja maksutapanimet ovat kovakoodattuja (`:9–20`).
   - Ratkaisu: logon lataus samalla mallilla kuin tuotekuva (esikatselu, koko- ja tyyppiraja); provisiosäännön muokkaus paikallaan; maksutapanimet yhteisestä sanakirjasta.
   - Hyväksymiskriteerit: admin vaihtaa kuittilogon ja korjaa provisioprosentin ilman kehittäjää.
   - Tiedostot: `booking/admin/views/settings.js`, `booking/admin/views/fee-rules-panel.js`.
   - Tietokanta: todennäköisesti kyllä: tallennuspaikka logolle (Storage-bucket tai olemassa olevan `product-images`-bucketin polku + asetusavain) ja `admin_update_fee_rule`, jos sellaista ei ole (tarkista tuotannosta).
   - Riippuvuudet: HALL-ASETUKSET-01.

#### HALL-KAYTTAJAT: käyttäjät (`#/kayttajat`)

Nykytila (arvioitu koodista; kokeilutila ei avaa näkymää, koska `admin_list_staff` puuttuu mockista): korttilista, roolin pudotusvalikko, työntekijälinkitys, Poista käytöstä / Aktivoi, Kutsu-dialogi ja samalla sivulla vuorotarjousten omat sivut.

1. **HALL-KAYTTAJAT-01 · KESKI · Roolit, kutsut ja nimet hallittaviksi selkokielellä**
   - Ongelma (VARMA, koodista): roolien ohjeessa koodinimiä ("admin = …; manager (ylläpitäjä) = …", `views/users.js:7`); rooli vaihtuu heti valikon muutoksesta ilman vahvistusta (`users.js:19–21`); kutsua ei voi lähettää uudelleen eikä kutsun tilaa näe; nimeä tai sähköpostia ei voi muokata; oikeuksia ei näytetä; vuorotarjouslinkit ovat samalla sivulla (`users.js:39`); käytöstä poisto `confirm()`-ikkunalla (`users.js:30`).
   - Ratkaisu: roolikuvaukset suomeksi ja avattava "Mitä rooli saa tehdä" -taulukko (`role_permissions`); roolinvaihto vahvistuksella; kutsun tila (odottaa / hyväksytty) ja "Lähetä kutsu uudelleen"; nimen muokkaus; vuorotarjouslinkit omaksi alavälilehdekseen.
   - Hyväksymiskriteerit: admin näkee, kuka ei ole vielä hyväksynyt kutsua, ja lähettää sen uudelleen kahdella klikkauksella.
   - Tiedostot: `booking/admin/views/users.js`, `booking/admin/views/shift-staff-panel.js`, tekstit, `booking/admin/options-mock.js` (mock).
   - Tietokanta: kyllä, pieni: `admin_update_staff(p_user_id uuid, p_name text)`; kutsun uudelleenlähetys Edge Functionin `admin-users` invite-toiminnolla (OLETUS: toimii uudelleenkutsulle; tarkista).
   - Riippuvuudet: HALL-KUORI-03 (salasanan palautus vähentää uudelleenkutsujen tarvetta).

## 4. Koontitaulukko

Kaikki parannusehdotukset koon mukaan ryhmiteltynä, luvun 2 ja 3 esiintymisjärjestyksessä.

### PIENI (61 kohtaa)

| Tunniste | Otsikko | Osio | Tila 13.11. |
|---|---|---|---|
| YHT-04 | Yksi tilasanasto ja monikot | Yhteinen ulkoasu (luku 2.5) | avoin |
| YHT-05 | Kellonajat, päivämäärät, rahat ja ALV yhdellä tavalla | Yhteinen ulkoasu (luku 2.5) | avoin |
| YHT-06 | Selaimen `confirm()` pois, dialogit kuntoon | Yhteinen ulkoasu (luku 2.5) | avoin |
| YHT-07 | Lomakekentät, virheet ja fokus yhdenmukaisiksi | Yhteinen ulkoasu (luku 2.5) | avoin |
| YHT-08 | Kokeilutila kattamaan kaikki näkymät | Yhteinen ulkoasu (luku 2.5) | avoin |
| SIVU-YHT-04 | "Koulutukset" päävalikossa avautuu ulkoiselle sivustolle uuteen välilehteen | Sivusto · yhteiset osat | avoin |
| SIVU-YHT-05 | Pikkuvirheet teksteissä ja muodoissa | Sivusto · yhteiset osat | avoin |
| SIVU-ETUSIVU-01 | "Valitse elämys" -kortit ovat epätasaisia | Sivusto · etusivu | avoin |
| SIVU-ETUSIVU-02 | Hero ja ensimmäinen näkymä mobiilissa | Sivusto · etusivu | avoin |
| SIVU-SAUNAVUOROT-01 | Viikko-ohjelman painikkeet ja vapaat paikat | Sivusto · saunavuorot | avoin |
| SIVU-YRITYKSET-01 | Sama valinta kolmeen kertaan | Sivusto · yrityksille | avoin |
| SIVU-INFO-01 | Peruutusohje ei kerro, miten peruutetaan | Sivusto · käytännön info | avoin |
| SIVU-SAUNATIETOA-01 | Tagisivuja on enemmän kuin sisältöä | Sivusto · saunatietoa | avoin |
| SIVU-JUOMAT-01 | Sivu jää tyhjäksi: koonnista puuttuu kaksi moduulia | Sivusto · juomasivu | Valmis, PR #350 |
| SIVU-404-01 | 404-sivu kahdella kielellä päällekkäin | Sivusto · 404-sivu | avoin |
| KAUPPA-SELAUS-01 | Päivänäkymän korteissa tuotteen nimi toistuu kuvauksessa | Kauppa · etusivu ja selaus | avoin |
| KAUPPA-TUOTE-01 | Työpöydällä vuorolista jää kapeaan sarakkeeseen, mobiilissa hero vie ensimmäisen näytön | Kauppa · tuotesivu | avoin |
| KAUPPA-KASSA-01 | Mobiilissa kokonaishinta ja 15 minuutin ehto ovat lähetysnapin alapuolella | Kauppa · varauslomake | avoin |
| KAUPPA-KASSA-03 | Luottamuselementit ja lahjakorttiohje näkyviin kassalle | Kauppa · varauslomake | avoin |
| KAUPPA-MAKSU-01 | Vanhentuneet ja ristiriitaiset maksutekstit | Kauppa · maksu ja vahvistus | Osittain, PR #350 |
| KAUPPA-TILAUS-01 | Laskutetulla yritystilauksella näkyvät maksutoiminnot | Kauppa · asiakkaan tilaussivu | avoin |
| KAUPPA-TILAUS-02 | Englanninkielisellä tilaussivulla tuotenimet suomeksi | Kauppa · asiakkaan tilaussivu | avoin |
| KAUPPA-JONO-01 | Täyden tapahtuman jonotuslinkki rikkoutuu sivun päivityksessä | Kauppa · jonotus | Valmis, PR #350 |
| KAUPPA-LAHJAKORTTI-01 | Lahjakorttisivun kori on sivun lopussa | Kauppa · lahjakorttisivu | avoin |
| KAUPPA-YHT-02 | Saavutettavuuden pikakorjaukset | Kauppa · kaikki kulut | avoin |
| HALL-KUORI-02 | Tabletilla ja puhelimella valikossa vain ikonit, yläpalkin painikkeet alle 44 px | Hallinta · kuori ja navigaatio | avoin |
| HALL-KUORI-03 | Kirjautumisesta puuttuu "Unohtuiko salasana?" | Hallinta · kuori ja navigaatio | avoin |
| HALL-KUORI-04 | Kielivalinta (FI/EN) näkyy vain osassa näkymiä | Hallinta · kuori ja navigaatio | avoin |
| HALL-KUORI-05 | Tarkista-määrä ei vastaa Tarkista-sivun sanoja | Hallinta · kuori ja navigaatio | avoin |
| HALL-KUORI-06 | Virheet ja puuttuvat oikeudet näkyvät harhaanjohtavasti | Hallinta · kuori ja navigaatio | avoin |
| HALL-PAIVA-01 | Järjestys ja leveydet: päivän vaihto on tuoton ja muistutusten alla | Hallinta · päivänäkymä | avoin |
| HALL-PAIVA-02 | Sisäänkirjausympyrä säilyy; tilan nimi ja "Ei saapunut" kuntoon | Hallinta · päivänäkymä | avoin |
| HALL-PAIVA-05 | Valmis päivän muistiinpano -toiminto on piilotettu | Hallinta · päivänäkymä | avoin |
| HALL-PAIVA-06 | Saavutettavuus päivänäkymässä | Hallinta · päivänäkymä | avoin |
| HALL-UUSI-02 | Natiivit päivä- ja aikakentät näyttävät laitteen kielen mukaan | Hallinta · uusi varaus | avoin |
| HALL-TARKISTA-01 | Luvut, tunnukset ja linkit eivät täsmää | Hallinta · tarkista | avoin |
| HALL-TILAT-02 | Resurssit-sivu on kirjoitettu kehittäjälle | Hallinta · resurssit ja aukiolot | avoin |
| HALL-SULUT-02 | Kalenterisulut-näkymä on tekninen | Hallinta · sulut | avoin |
| HALL-TILAUKSET-01 | Suodatinsirut sekoittavat kolme eri asiaa | Hallinta · tilauslista | avoin |
| HALL-TILAUKSET-02 | Sama lista kahdessa paikassa ja kaksi H1-otsikkoa | Hallinta · tilauslista | avoin |
| HALL-TILAUKSET-03 | Listarivi on epäselvä ja mobiilissa ensimmäinen tilaus alkaa vasta 660 px:n kohdalla | Hallinta · tilauslista | avoin |
| HALL-TILAUS-02 | Julkaisu jättää dynaamiset importit versioimatta: "← Takaisin" ei palaa lähtönäkymään | Hallinta · tilausnäkymä | Valmis, PR #350 |
| HALL-TILAUS-03 | "Lähetä maksulinkki" ei oletuksena lähetä mitään | Hallinta · tilausnäkymä | avoin |
| HALL-TILAUS-04 | Kaksi lisäostodialogia, v3 käyttää suppeampaa | Hallinta · tilausnäkymä | avoin |
| HALL-TILAUS-05 | Siirto ja henkilömäärän muutos eivät kerro uutta hintaa eivätkä ilmoita asiakkaalle | Hallinta · tilausnäkymä | Pääosin valmis, PR #347 (booking_282) |
| HALL-TILAUS-07 | Aikajanassa ja dialogeissa näkyy teknisiä koodeja | Hallinta · tilausnäkymä | avoin |
| HALL-TILAUS-08 | Kosketuskohteet ja saavutettavuus tilausnäkymässä | Hallinta · tilausnäkymä | avoin |
| HALL-ASIAKKAAT-02 | Kaksoiskappaleiden yhdistäminen ja asiakkaan anonymisointi | Hallinta · asiakkaat | Valmis kytkimien takana, PR #349 (booking_285, oikeus `customers.admin`) |
| HALL-ASIAKKAAT-04 | Asiakaslista: kohinaa ja puuttuvat monikot | Hallinta · asiakkaat | avoin |
| HALL-KASSA-01 | Kassanäkymä tabletille: kori näkyviin ja otsikot pois tieltä | Hallinta · pikakassa | avoin |
| HALL-TALOUS-01 | Raporttien virheet ja käytettävyys | Hallinta · talous ja raportit | Osittain, PR #350 |
| HALL-TALOUS-03 | Teknisiä koodeja ilmoituksissa ja listoissa | Hallinta · talous ja raportit | avoin |
| HALL-LASKUT-01 | "Lasku tilauksesta" kysyy tilausnumeroa mutta hakee sisäisellä tunnisteella | Hallinta · laskut | Valmis, PR #350 (`booking/admin/invoice-from-order.js`) |
| HALL-LAHJAKORTIT-02 | Myyntikytkimet ja haku | Hallinta · lahjakortit | avoin |
| HALL-ALENNUS-01 | Koodin tuote näkyy numerona, vahvistukset selaimen ikkunoilla | Hallinta · alennuskoodit ja vuosikortit | avoin |
| HALL-TUOTTEET-05 | Lista sarakkeiksi ja valinnat sekä lisäpalvelut omille välilehdilleen | Hallinta · tuotteet | avoin |
| HALL-TUOTTEET-06 | Pikakorjaukset: ALV-muoto, kehittäjäkieli, koodit ja käännösten puutteet | Hallinta · tuotteet | avoin |
| HALL-TAPAHTUMAT-02 | Pikakorjaukset Tapahtumat-näkymään | Hallinta · tapahtumat | avoin |
| HALL-HILJAISET-01 | Päälle/pois-ohjain ja vahvistukset muiden kaltaisiksi | Hallinta · hiljaiset ajat | avoin |
| HALL-KOULUTUKSET-01 | Ulkoasu poikkeaa muista ja pieniä tekstivirheitä | Hallinta · koulutukset | avoin |
| HALL-VIESTIT-02 | Viestit-sivun ulkoasu ja kehittäjäkieli | Hallinta · viestit | avoin |

### KESKI (37 kohtaa)

| Tunniste | Otsikko | Osio | Tila 13.11. |
|---|---|---|---|
| YHT-01 | Yhteinen tokenitiedosto | Yhteinen ulkoasu (luku 2.5) | avoin |
| YHT-02 | Hallinnan komponenttikirjasto | Yhteinen ulkoasu (luku 2.5) | avoin |
| YHT-03 | Yksi välilehtikomponentti ja yksi H1 sivulla | Yhteinen ulkoasu (luku 2.5) | avoin |
| SIVU-YHT-01 | Varaa-painike puuttuu mobiilin ylätunnisteesta | Sivusto · yhteiset osat | avoin |
| SIVU-YHT-02 | Kaksi serif-otsikkokirjasinta ja kolme painiketyyliä | Sivusto · yhteiset osat | avoin |
| SIVU-HOIDOT-01 | Sivu on liian pitkä ilman sisäistä navigaatiota | Sivusto · hoidot ja rituaalit | avoin |
| SIVU-EN-01 | Englanninkielinen sisältö on koneellisesti käännetty ja osin eri kuin suomeksi | Sivusto · englanninkieliset sivut | avoin |
| KAUPPA-SELAUS-02 | Listakorteista puuttuu "seuraava vapaa aika" | Kauppa · etusivu ja selaus | Huomioitava PR #346 (booking_289) |
| KAUPPA-KASSA-02 | Lomakevirheet ovat geneerisiä eivätkä näy mobiilissa | Kauppa · varauslomake | avoin |
| KAUPPA-VAHVISTUS-01 | Vahvistussivu toistaa itseään eikä johda tilaussivulle | Kauppa · maksu ja vahvistus | Huomioitava PR #347 (booking_284) |
| KAUPPA-YHT-01 | Vuoro- ja hoitokulku tuntuvat eri tuotteilta | Kauppa · kaikki kulut | avoin |
| HALL-KUORI-01 | Päävalikko on ryhmitelty teknisesti, ei työn mukaan | Hallinta · kuori ja navigaatio | avoin |
| HALL-PAIVA-03 | Rivin pikatoiminnot: siirto, soitto ja peruutus poistumatta päivästä | Hallinta · päivänäkymä | avoin |
| HALL-PAIVA-04 | Vastaanoton tablettitila: automaattinen päivitys ja tulostettava päivälista | Hallinta · päivänäkymä | avoin |
| HALL-KALENTERI-01 | Kalenterista ei näe käyttöastetta eikä pääse päivään | Hallinta · kalenteri | avoin |
| HALL-UUSI-01 | Kolme varaustyyppiä, kaksi eri lomaketta | Hallinta · uusi varaus | avoin |
| HALL-SULUT-01 | Sulkua ei voi muokata, ja konfliktissa ei näe mitkä varaukset estävät | Hallinta · sulut | avoin |
| HALL-TILAUS-01 | Uusi tilausnäkymä vei henkilökunnalta toimintoja | Hallinta · tilausnäkymä | Osittain, PR #347 (booking_282–284, lippu `partial_refunds_enabled`) |
| HALL-TILAUS-06 | Vahvistusta ei voi lähettää uudelleen eikä yksittäiselle asiakkaalle voi kirjoittaa | Hallinta · tilausnäkymä | avoin |
| HALL-TILAUS-09 | Vanhan koodin siivous | Hallinta · tilausnäkymä | avoin |
| HALL-ASIAKKAAT-01 | Asiakasnäkymä muokattavaksi ilman vanhaa modaalia | Hallinta · asiakkaat | avoin |
| HALL-ASIAKKAAT-03 | Asiakaskortista puuttuvat tagit, no-show-varoitus ja viestihistoria | Hallinta · asiakkaat | avoin |
| HALL-KASSA-02 | Pikakassalla ei voi myydä tiskillä tavallisella korttipäätteellä | Hallinta · pikakassa | avoin |
| HALL-AVOIMET-01 | Kaksi työjonoa yhdeksi "Avoimet maksut" -näkymäksi ja Tarkista-merkkiin | Hallinta · seurattavat maksut ja hyvitykset | avoin |
| HALL-LASKUT-02 | Laskuluonnosta ei voi muokata, vaaralliset toiminnot ilman vahvistusta | Hallinta · laskut | avoin |
| HALL-LAHJAKORTIT-01 | Lahjakortin puhelinmyynti vie 12+ vaihetta kahdessa näkymässä, eikä englanniksi voi myydä | Hallinta · lahjakortit | avoin |
| HALL-LAHJAKORTIT-03 | Kumppanikoodeilla kolme eri käyttöliittymää | Hallinta · lahjakortit | avoin |
| HALL-ALENNUS-02 | Koodin käyttöä ei voi seurata | Hallinta · alennuskoodit ja vuosikortit | avoin |
| HALL-TUOTTEET-01 | Tuote-editori on 3 200 px:n dialogi, jossa 4–5 tallennusta ja muutokset katoavat | Hallinta · tuotteet | avoin |
| HALL-TUOTTEET-02 | Neljä päällekkäistä näkyvyysasetusta: henkilökunta ei voi ennustaa, näkyykö tuote kaupassa | Hallinta · tuotteet | avoin |
| HALL-TUOTTEET-03 | Uuden tuotteen luonti lupaa liikoja, eikä tapahtumaa tai koulutusta voi luoda tyhjästä | Hallinta · tuotteet | avoin |
| HALL-TUOTTEET-04 | Hintavariantit ja kesto eivät ole henkilökunnan muokattavissa | Hallinta · tuotteet | avoin |
| HALL-TAPAHTUMAT-01 | Tapahtumien myyntiä ei voi avata hallinnasta | Hallinta · tapahtumat | avoin |
| HALL-VIESTIT-01 | Kolme erilaista viestityökalua ja puuttuvat perustoiminnot | Hallinta · viestit | avoin |
| HALL-ASETUKSET-01 | 10 välilehteä → 5, yksi tallennuspalkki | Hallinta · asetukset | avoin |
| HALL-ASETUKSET-02 | Kuittilogoa ei voi vaihtaa eikä provisiosääntöä muokata | Hallinta · asetukset | avoin |
| HALL-KAYTTAJAT-01 | Roolit, kutsut ja nimet hallittaviksi selkokielellä | Hallinta · käyttäjät | avoin |

### SUURI (4 kohtaa)

| Tunniste | Otsikko | Osio | Tila 13.11. |
|---|---|---|---|
| SIVU-YHT-03 | Henkilökunta ei voi muuttaa sivuston tekstejä eikä julkaista muutosta itse | Sivusto · yhteiset osat | avoin |
| HALL-KALENTERI-02 | Resurssiaikajana ja siirto vetämällä (myöhempi vaihe) | Hallinta · kalenteri | avoin |
| HALL-TILAT-01 | Aukioloja, vuoroja ja poikkeuspäiviä ei voi hallita ilman kehittäjää | Hallinta · resurssit ja aukiolot | avoin |
| HALL-TALOUS-02 | Päivän tilitys (kassan sulkeminen) puuttuu | Hallinta · talous ja raportit | avoin |

Yhteensä 102 kohtaa: PIENI 61, KESKI 37, SUURI 4. Valmiita 13.11.2026: 5 (SIVU-JUOMAT-01, KAUPPA-JONO-01, HALL-TILAUS-02, HALL-ASIAKKAAT-02, HALL-LASKUT-01). Avoimia 97: PIENI 56, KESKI 37, SUURI 4.
