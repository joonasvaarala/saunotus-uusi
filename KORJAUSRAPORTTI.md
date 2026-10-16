# Korjausraportti

Uuden sivuston (staattinen kopio) suhde korjauslistaan (kb.review_items, 78 riviä). Tila: **korjattu**, **osittain**, **ei korjattu**.

**Yhteenveto:** korjattu 26, osittain 10, ei korjattu 42 (yhteensä 78).

| Kohdetyyppi (fix_target) | rivejä | korjattu / osittain / ei |
|---|---|---|
| new_site | 23 | 22 k / 1 o / 0 e |
| johku | 21 | 1 k / 4 o / 16 e |
| old_site | 8 | 0 k / 0 o / 8 e |
| owner_decision | 12 | 2 k / 2 o / 8 e |
| missing_info | 13 | 0 k / 3 o / 10 e |
| kb | 1 | 1 k / 0 o / 0 e |

Periaatteet: hinnat, ajat ja kuvaukset tulevat Supabasen kb-skeemasta (vain luku, snapshot content/kb/kb.json). Omistajan päätökset 9.–11.10.2026 on huomioitu (la–su 14–19, Johkun hinnat oikein, kaikki hoidot Raunissa, vain kolme hoitoa + päätöksen 73 tuotteet, lahjakortin jatko ilmainen). Sisäisiä policy-rivejä (internal=true) ei käytetä. Puuttuvaa tietoa ei ole keksitty: se on merkitty "ei korjattu".

Johku-, vanhan sivuston ja Groweo-kohdat eivät ole uuden sivuston hallinnassa; niiden korjaus tehdään kyseisissä järjestelmissä.

| id | otsikko | kohde | tila | mitä tehtiin / miksi ei |
|---|---|---|---|---|
| 1 | Viikonlopun yleisen vuoron alkamisaika (14.30 → 14) | johku | korjattu | Viikonlopun yleinen vuoro la–su klo 14–19 kaikkialla (viikko-ohjelma tulee kb.opening_hours-datasta, kortit ja FAQ). |
| 2 | Torstain yleisen vuoron uima-asusääntö | owner_decision | ei korjattu | Omistajan päätös puuttuu. Torstain uima-asusääntöä ei väitetä sivustolla suuntaan eikä toiseen. |
| 3 | Turvetorstain kellonajat ja rakenne | owner_decision | osittain | Päätös puuttuu. Viikko-ohjelma näyttää kb:n mukaan to 16–17 Turvetorstai ja 17–19 yleinen vuoro; turvetorstain kortti ei lupaa seremonian kellonaikaa. |
| 4 | Saunarituaalin (la–su) kesto ja kellonaika | owner_decision | osittain | Päätös puuttuu. Rituaali-iltaa ei kuvata kestolla tai kellonajalla (vain "20 minuuttia" rituaali ja "sisältää savusaunavuoron"); ristiriitaisia kestoja ei esitetä. |
| 5 | Synttärisauna: väärä hinta ja kesto | new_site | korjattu | Synttärisauna: alk. 350 € (Johkun hinta kb:stä); väärää 290 € / 1 h 30 min ei esitetä. |
| 6 | Turvesauna: väärä hinta ja kesto | new_site | korjattu | Turvesauna: alk. 330 € (Johkun hinta kb:stä). |
| 7 | Morsiussauna: ryhmäkoko ja kategorian alkaen-hinta | johku | osittain | Johkun asia, ei uuden sivuston/tämän repon hallinnassa. Uusi sivusto näyttää Johkun mukaisesti "alk. 390 €" ja "enintään 8 hlö" (ei 1–16 hlö / 1–5 h); Johkun korjaus odottaa. |
| 8 | Lovi → Rauni (hoitosauna) Johkun sivuilla | johku | osittain | Uusi sivusto: kaikki hoidot Raunissa, Lovia ei mainita. Johkun asia, ei uuden sivuston/tämän repon hallinnassa. Johkun lahjakorttitekstit "Lovi" korjattava siellä. |
| 9 | Yksityisvuorot-kortin henkilömäärä | new_site | korjattu | Yksityisvuorot: "alk. 180 €" (jälkilöylyt, sis. 6 hlö, lisähenkilö 10 €) ja oma vuoro "alk. 250 €"; henkilömäärää 1–8 ei väitetä. |
| 10 | Lahjakortit: väärä alkaen-hinta | new_site | korjattu | Lahjakortit: avoin kortti alk. 29 €, paketit 42/88/128/192 €, vuosikortti 290 € (Johku). |
| 11 | ALV 13,5 % kahdessa saunottajapalvelussa | owner_decision | ei korjattu | Omistajan päätös (ALV-kanta) puuttuu; sivusto ei esitä ALV-prosentteja. Ehdoissa mainitaan vain että hinnat sisältävät arvonlisäveron. |
| 12 | EN-kauppa: Perinnesaunotusilta €69 ja vanha kekri-tuote | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa. Uusi sivusto: Perinnesaunotusilta 59 € (FI ja EN). |
| 13 | Lahjakortti-sivun paikkatekstit | new_site | korjattu | Ei paikkatekstejä: kaikilla sivuilla (FI ja EN) on oikea sisältö. |
| 14 | EN: "approx." alkaen-hinnoissa | new_site | korjattu | EN-tekstit kirjoitettu uudelleen: "from" (ei "approx."), "Sat, Sun", "no earlier than about 10 minutes", "Peat Thursday". EN-tekstit kannattaa antaa natiivin tarkistettavaksi. |
| 15 | Lisähoidot: tarjotaanko yhä? | owner_decision | korjattu | Vain saunahoito 1 h (99 €), saunotus 2 h (210 €), syväsaunotus 3 h (290 €) sekä päätöksen 73 tuotteet. Lisähoidot poistettu kaikkialta. |
| 16 | Tunnin saunavuoro: onko voimassa? | owner_decision | ei korjattu | Omistajan päätös puuttuu; tunnin saunavuoroa ei esitetä sivustolla. |
| 17 | Syksy 2026 -koulutuksen päivämäärän kirjoitusvirhe | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa.  |
| 18 | Jälkilöylyt: kesä- vs. talvihinnat | owner_decision | ei korjattu | Päätös puuttuu; jälkilöylyissä esitetään vain "alk. 180 €" (ei kausirivejä). |
| 19 | Perinnesaunotus ryhmälle: kopioitu teksti | johku | osittain | Johkun asia, ei uuden sivuston/tämän repon hallinnassa. Uusi sivusto käyttää kb:n kuvausta (3–6 hlö, noin 3 h, 499 €). Koska Johkun EN-sivu palauttaa 404, EN-kortti linkittää hoitolistaukseen. |
| 20 | Saunatakin ja tossujen vuokra | owner_decision | ei korjattu | Päätös puuttuu; vuokrahintaa (saunatakki/tossut) ei esitetä. |
| 21 | Esteettömyystieto puuttuu uudelta sivulta | new_site | korjattu | Info-sivulle lisätty Esteettömyys-osio (portaat, apu etukäteen sähköpostilla, noin 40 m pukuhuoneilta saunalle) ja Mitä mukaan -ohje kb:stä. |
| 22 | Mennyt opiskelijahoitopäivä etusivulla | new_site | korjattu | Menneitä päiviä ei ole; tapahtumat ja päivät tulevat kb.event_dates-datasta ja menneet suodatetaan pois rakennusvaiheessa (päivittäinen ajastettu rakennus). |
| 23 | Vanha hinta vs. uusi: yleinen vuoro & perinnesaunotusilta | kb | korjattu | Yleinen vuoro 29 €, perinnesaunotusilta 59 € (FI ja EN). |
| 24 | Kuluttajariitalautakunnan nimi ehdoissa | owner_decision | ei korjattu | Omistajan päätös puuttuu. Kohta "Kohteen käyttö, vahingot ja valitukset" (kb.policies 4) jätetty pois sivuston ehdoista kunnes sanamuoto on päätetty. |
| 25 | Terveys ja turvallisuus | missing_info | ei korjattu | Tietoa ei ole lähteissä, ei keksitty. Vasta-aiheet/terveysohjeet tulee toimittaa. |
| 26 | Alkoholikäytäntö | missing_info | ei korjattu | Tietoa ei ole lähteissä. Alkoholikäytäntö puuttuu (vain: alkoholittomia virvokkeita on saatavilla). |
| 27 | Lapset ja ikärajat | missing_info | ei korjattu | Tietoa ei ole lähteissä. Ehdoissa vain "myynti täysi-ikäisille". |
| 28 | Lemmikit | missing_info | ei korjattu | Tietoa ei ole lähteissä. |
| 29 | Arvotavarat ja pukutilat | missing_info | osittain | Kb:stä: hirsimökissä suihku, huussi, hoitosaunalla pukukoppi. Lokeroista/arvotavaroista ei tietoa. |
| 30 | Maksutavat | missing_info | ei korjattu | Hyväksyttyjä maksutapoja ei ole lähteissä; ehdot kuvaavat vain yleisesti maksuvälittäjät ja laskutuksen yrityksille. |
| 31 | Hoitojen myöhästymis- ja no-show-käytäntö | missing_info | ei korjattu | Tietoa ei ole lähteissä. |
| 32 | Sää- ja juhlapyhäpoikkeukset | missing_info | ei korjattu | Tietoa ei ole lähteissä (ei sää- tai juhlapyhäpoikkeuksia). |
| 33 | Asiakaspalvelun aukioloajat | missing_info | ei korjattu | Tietoa ei ole lähteissä; sivustolla vain puhelinnumero ja sähköposti. |
| 34 | Yleisen vuoron kapasiteetti ja allaslämpötilat | missing_info | ei korjattu | Kapasiteettia ja lämpötiloja ei ole lähteissä (kb: lämpötilat vaihtelevat sään mukaan). |
| 35 | Englanninkieliset tuotekuvaukset ja tietosuojaseloste | missing_info | osittain | Kaikilla sivustolla esitetyillä tuotteilla on EN-kuvaus (käännetty), EN-tietosuojaselostetta ei ole: EN-sivuilta linkki FI-selosteeseen. |
| 36 | Yritysten hinnoittelu ja tarjouspyyntö | missing_info | osittain | Yrityssivulla Johku-tuotteet (alk. 350 € / alk. 250 €) ja tarjouspyyntö sähköpostilla (mailto). Työhyvinvointipäivien hinnat puuttuvat (tarjouspyynnöstä). |
| 37 | Englanninkielinen saunottajakoulutus | missing_info | ei korjattu | Koulutustiedot eivät kuulu lähteisiin; sivusto linkittää saunakoulutus.fi:hin. |
| 38 | Saunavuorot-sivun paikkatekstit | new_site | korjattu | Ei paikkatekstejä; Saunavuorot-sivu täydellinen (FI ja EN). |
| 39 | Yritykset-sivu keskeneräinen | new_site | korjattu | Yritykset-sivu valmis: tuotteet, työhyvinvointipäivät, tarjouspyyntö. |
| 40 | EN gift card -sivun paikkatekstit | new_site | korjattu | EN Gift cards -sivu valmis. |
| 41 | EN sauna -sivun paikkatekstit | new_site | korjattu | EN Sauna sessions -sivu valmis. |
| 42 | EN: saapumisaika väärin käännetty | new_site | korjattu | EN: "Please arrive no earlier than about 10 minutes before your booking starts." |
| 43 | EN: uima-asuohje väärin käännetty | new_site | korjattu | EN: uima-asuohje korjattu (vuorokohtainen, pakollisuus oikein päin). |
| 44 | EN: "Hand towel" | new_site | korjattu | Käsipyyhettä ei mainita väärin; "a towel". |
| 45 | EN: bussiohje | new_site | korjattu | EN-bussiohje: bus 841 Itäkeskus → Broböle, noin 1 km. |
| 46 | EN: "Peet Thursday" | new_site | korjattu | "Peat Thursday". |
| 47 | EN: "there, her" viikonpäivinä | new_site | korjattu | "Sat, Sun" / "Sat–Sun". |
| 48 | EN: "shift" = vuoro | new_site | korjattu | "session" kaikkialla, ei "shift". |
| 49 | EN: saunan englanninkielinen nimi vaihtelee | new_site | osittain | Yhtenäinen nimi "Sipoonjoen Perinnesauna" kaikkialla; virallinen EN-nimi on päätettävä (#62). |
| 50 | Rauni kuvattu savusaunaksi | new_site | korjattu | Rauni = hoitosauna kaikkialla; savusauna erikseen. |
| 51 | "Viime vuonna" ilman vuosilukua | new_site | korjattu | Tarinaosiossa vuosiluvut (2021, 2022, 2023, 2024, "Sen jälkeen"); "viime vuonna" ei käytetä. |
| 52 | EN-kauppa: €42-lahjakortin kuvaus väärä | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa.  |
| 53 | EN-kauppa: €128-lahjakortin hoidon kesto | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa.  |
| 54 | EN-kauppa: "Public sauna (Sat & Sun)" | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa.  |
| 55 | EN-kauppa: "Seremony" | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa.  |
| 56 | Kevät 2026 -koulutuksen varausmaksutuote yhä listattuna | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa.  |
| 57 | Koulutus kevät & syksy 2027: päivämäärät puuttuvat | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa.  |
| 58 | Opiskelijahoidot: /fi_FI/opiskelijahoidot palauttaa 404 | johku | osittain | Johkun asia, ei uuden sivuston/tämän repon hallinnassa. Uusi sivusto ei linkitä rikkinäiseen osoitteeseen: opiskelijahoito-kortti linkittää Johkun hoitolistaukseen (tuotesivu /hoidot/vihtahoito-opiskelijatyona palauttaa 404 sekä FI että EN). |
| 59 | Vanha sivu: viikonloppuvuoro 14.30 | old_site | ei korjattu | Vanhan sivuston / ulkoisen työkalun asia, ei tämän repon hallinnassa.  |
| 60 | Vanha sivu: Lovi → Rauni | old_site | ei korjattu | Vanhan sivuston / ulkoisen työkalun asia, ei tämän repon hallinnassa.  |
| 61 | Vanhan sivuston uudelleenohjaus | old_site | ei korjattu | Vanhan sivuston / ulkoisen työkalun asia, ei tämän repon hallinnassa. Uudelleenohjaus on päätettävä, kun tuotantodomain ja hosting on valittu. |
| 62 | Saunan virallinen englanninkielinen nimi | owner_decision | ei korjattu | Omistajan päätös puuttuu. |
| 63 | Johku: Yleinen vuoro (to, la–su) – Perinnevihdonta lisäpalveluna | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa.  |
| 64 | Johku: lopetettujen hoitojen omat tuotesivut yhä auki | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa.  |
| 65 | Groweo (saunotus.fi): Löylytesti 4.0 mainostaa turvehoitoja ja perinnevihdontaa | old_site | ei korjattu | Vanhan sivuston / ulkoisen työkalun asia, ei tämän repon hallinnassa.  |
| 66 | Johku: Hiljainen sauna (ke) – lopetetut lisähoidot | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa.  |
| 67 | Johku: Turvetorstai (to) – lopetetut lisähoidot | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa.  |
| 68 | Johku: Miesten sauna (ma) – lopetetut lisähoidot | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa.  |
| 69 | Uusi sivu: etusivun hoitokuvaus listaa vanhat hoidot | new_site | korjattu | Etusivun hoitoteksti viittaa vain nykyisiin hoitoihin. |
| 70 | Johku EN: lahjakortit 42 € ja 128 € lupaavat "30-minute custom sauna treatment" | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa. Uuden sivuston EN-lahjakorttitekstit eivät lupaa 30 min hoitoa. |
| 71 | Groweo (saunotus.fi): tarjouspyyntölomakkeen "Lisäpalvelut" listaa 7 lopetettua hoitoa | old_site | ei korjattu | Vanhan sivuston / ulkoisen työkalun asia, ei tämän repon hallinnassa.  |
| 72 | Vanha sivu: "Saunahoidot ja tapahtumat" listaa lopetetut hoidot | old_site | ei korjattu | Vanhan sivuston / ulkoisen työkalun asia, ei tämän repon hallinnassa.  |
| 73 | Muut hoidon kaltaiset tuotteet: jatkuvatko? | owner_decision | korjattu | Opiskelijahoito 20 € (satunnainen, koulutusten yhteydessä), saunotusrituaali 20 €, perinnesaunotus ryhmälle 499 € mukana. |
| 74 | Johku: Naisten sauna (ti) – lopetetut lisähoidot | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa.  |
| 75 | Vanha sivu: UKK "Mitä palveluita voi yhdistää saunavuoroon?" | old_site | ei korjattu | Vanhan sivuston / ulkoisen työkalun asia, ei tämän repon hallinnassa.  |
| 76 | Vanha sivu: esittelyteksti lupaa vihdontaa, turvehoitoja ja yrttihierontaa kaikilla vuoroilla | old_site | ei korjattu | Vanhan sivuston / ulkoisen työkalun asia, ei tämän repon hallinnassa.  |
| 77 | Johku: Tunnin saunavuoro (la–su) – lopetetut lisähoidot | johku | ei korjattu | Johkun asia, ei uuden sivuston/tämän repon hallinnassa.  |
| 79 | Yksityiskoulutusten (privakoulutusten) hinnat | owner_decision | ei korjattu | Yksityiskoulutusten hintoja ei esitetä; päätös ja vastuuhenkilö puuttuvat. |

Huom. rivi 78 ei ole korjauslistassa (numerointi hyppää 77 → 79).
