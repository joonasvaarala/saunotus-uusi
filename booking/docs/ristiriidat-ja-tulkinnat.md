# kb ↔ Johku -ristiriidat, vuorosääntöjen tulkinnat ja avoimet kysymykset

Periaate: **kb on totuus**. Kun Johku ja kb eroavat, järjestelmä noudattaa kb:ta (hinnat luetaan suoraan kb:stä); alla ristiriidat, jotka Joonaksen pitää vahvistaa. Sääntödata on `supabase/migrations/…_08_seed_rules.sql`.

## A. Ristiriidat kb ↔ Johku (havaittu)

| # | Asia | kb | Johku | Mitä tein |
|---|---|---|---|---|
| 1 | Tunnin vuoro (la–su 14 ja 18) paikat | omistajan ohje: 6 hlöä sisällä | resurssi "Tunnin vuoro 1800": 10 paikkaa | ✅ **RATKAISTU (omistaja 16.10.2026):** 10 hlöä / vuoro, oma kapasiteetti (pooli `tunti_vkp_1400` ja `tunti_vkp_1800`), ei jaa paikkoja 2 h vuorojen kanssa |
| 2 | Viikonlopun yleisten vuorojen tarkat alkuajat | vain "klo 14–19, saunomisaika 2 h" | 14:00, 14:30, 15:00, 16:00, 16:30, 17:00 (+ 15:30 vain kesä 2026) | ✅ **RATKAISTU (omistaja 16.10.2026):** alkuajat 14:00, 14:30, 15:00, 16:00, 16:30, 17:00 (viimeinen päättyy 19:00). **15:30 ei ole alkuaika** – kesäkauden 15:30-sääntö ja sen `valid_from/to` poistettu |
| 3 | Hintarivien "sisältää N hlöä" (yksityisvuoro, jälkilöylyt) | arvo tyhjä (`included_persons` NULL) | 8 tai 11 (rivistä riippuen) | oletus 8 yksityisvuorolle (kb 25) ja 6 jälkilöylyille (kb 26, 49) – **vahvista** |
| 4 | Perjantain Jälkilöylyt | kb:ssä pe-variantti (19–22) | aloitusaika vain yksittäiselle päivälle 16.1.2026 | sääntö pe 19–22 luotu kb:n mukaan |
| 5 | Uudenvuodenaatto 31.12.2026 -variantti | variantti olemassa | ei aloitusaikaa | sääntö luotu mutta **ei käytössä** (`active=false`) |
| 6 | Myynnin sulkeutumisajat (`deadline_minutes`) | – | Johku: tuote 132 → 15 min, 152 → 30 min, 16 → 12 h, 17 → 24 h; muille ei tietoa | nuo käytössä; ma–ke-vuorot 0 min, jälkilöylyt 2 h ovat **oletuksia** |
| 7 | Morsiussauna | alkaen 390 € | 549 € | ei ole kaupan tuotekonfiguraatiossa (ei varattavissa verkossa); kb on totuus, hinta tarkistettava |
| 8 | Johkun "ma–to 3 h" -hintarivi sisältää myös perjantain | – | kyllä | sääntö ma–pe 16–19 yksityisvuorolle (vastaa Johkua) |
| 9 | Yksityisvuoron enimmäishenkilömäärä | ei määritelty | – | oletus 16 (sama kuin yleinen) |

## B. Vuorosääntöjen tulkinnat

1. **Yksityisvuoro vs. yleinen vuoro** – eivät voi olla yhtä aikaa (vaatimus B). Toteutettu DB-tasolla (ks. README). Yksityinen varaus poistaa päällekkäiset yleiset vuorot myynnistä; yksikin yleisen vuoron varaus estää päällekkäisen yksityisvuoron. Myös odottava (maksamaton, pito voimassa) varaus estää, vanhentunut ei.
2. **Viikonloppu (la–su): kapasiteetti 6 hlöä PER ALKAMISAIKA** (✅ ratkaistu, ks. D) – 2 h vuoroilla 14:00, 14:30, 15:00, 16:00, 16:30 ja 17:00 on jokaisella oma 6 hengen kiintiö (oma kapasiteettipooli `yleinen_vkp_1400` … `yleinen_vkp_1700`). Eri alkamisajat eivät siis jaa paikkoja, vaikka vuorot menevät ajallisesti päällekkäin (14:00–16:00 ja 14:30–16:30). Tunnin vuorot (14:00, 18:00; Johku 152) ovat oma kokonaisuutensa: 10 hlöä / vuoro. Kapasiteetit ovat dataa (`booking.resources`), muokattavissa hallinnan Resurssit-näkymästä. **Huomio:** koska kiintiöt ovat erilliset, saunassa voi olla yhtä aikaa yli 6 henkilöä (esim. 14:00-vuoro 6 + 14:30-vuoro 6 klo 14:30–16:00 = 12; lisäksi tunnin vuoro enintään 10) – tämä on omistajan päätös.
3. **Torstai** – turvesauna 16–17 (max 8) ja yleinen vuoro 17–19; **yhteensä max 16** turvesaunalaiset mukaan lukien. Toteutus: turvetorstain tuote kuluttaa kaksi poolia (`yleinen_arki` 16 + `turve` 8) ajalle 16–19; torstain yleinen vuoro 17–19 käyttää `yleinen_arki`-poolia → turvesaunalaiset vähentävät yleisen vuoron paikkoja.
4. **ma–ke** 16 hlöä / vuoro (ma miehet, ti naiset, ke hiljainen).
5. **Maksamattomat pidot**: 15 min (asetus). `pay_later`-tilassa pitoa ei tarvita (vahvistuu heti).
6. **Hinnoittelutavat**: `per_person` (kb-hinta × hlömäärä), `fixed` (kiinteä), `fixed_plus_extra` (perushinta sisältää N hlöä + lisähenkilömaksu). Hinnat luetaan live kb:stä; hinnanmuutos ei muuta vanhoja tilauksia (rivihinta tallennetaan).

## C. Avoimet kysymykset Joonakselle

1. ~~**Viikonlopun kapasiteetti**~~ ✅ **RATKAISTU:** 6 hlöä / alkamisaika (2 h vuorot), 1 h vuorot (14 ja 18) 10 hlöä / vuoro omana kapasiteettinaan. Ks. D.
2. **Yksityisvuoron enimmäishenkilömäärä** ja hinnan "sisältää" -rajat (8? 6?) sekä lisähenkilön hinta kaikille variantteille.
3. **Myynnin sulkeutumisajat** (deadline) jokaiselle tuotteelle: kuinka pitkään ennen vuoroa verkosta saa varata (nyt yleiset 15–30 min; yksityisvuorot 12 h; jälkilöylyt 2 h; yritys 24 h)?
4. ~~**Peruutusehdot verkossa**~~ ✅ **RATKAISTU:** asiakas ei peruuta vahvistettua varausta itse. Peruutukset sähköpostilla henkilökunnalle, joka peruu hallinnasta. Asiakas voi sen sijaan MUUTTAA varausta (toinen vapaa vuoro samalle tuotteelle tai henkilömäärä) viimeistään 48 h ennen vuoron alkua (asetus `customer_change_hours_before`). Ks. D.
5. **Maksutapa alkuvaiheessa**: jatketaanko `pay_later` (maksu paikan päällä) kunnes Visma Pay on valmis? Vai otetaanko käyttöön vasta kun verkkomaksu toimii?
6. ~~**Henkilökunnan oikeudet**~~ ✅ **RATKAISTU:** kolme henkilöstöroolia: `admin` (Joonas, Koodari: kaikki), `manager` = ylläpitäjä (Otto, Laura: hinnat, kuvaukset, tuoteasetukset, asetukset, resurssit, vuorosäännöt, vuosikortit) ja `staff` = peruskäyttäjä (varaukset, asiakkaat, maksujen kirjaus, sulut; ei hinta-/tuote-/asetusmuokkausta). Ks. D ja roolit-ja-kb.md.
7. **Sähköpostivahvistukset – AVOIN.** Palvelua ei ole valittu eikä sitä toteuteta nyt; nyt vahvistus näkyy vain sivulla. **Suunnitelma (tehdään myöhemmin, EI toteutettu):** vahvistukset lähetetään osoitteesta savusauna@saunotus.fi Supabase Edge Functionilla, joka käyttää transaktiosähköpostipalvelua (esim. Resend, Postmark tai Amazon SES; valinta ja domainin SPF/DKIM/DMARC-todennus tehdään silloin). Edge Function kutsutaan palvelurooliavaimella (`service_role`) varauksen vahvistuksen jälkeen (tietokannan webhook/`pg_net` tai kauppa kutsuu), ja se lähettää vahvistuksen sekä muutos- ja peruutusviestit. Siihen asti peruutus- ja muutospyynnöt tulevat asiakkaalta osoitteeseen savusauna@saunotus.fi.
8. **Yritysvuorot ja jälkilöylyt** verkkoon heti vai vain tarjouspyyntönä (nyt mukana kaikki 10 savusaunatuotetta; `bookable`-lippu hallinnasta).
9. **Englanti**: tuotteiden `name_en/description_en` puuttuvat osin kb:stä – täydennetäänkö ennen julkaisua?
10. **Hoidot / tapahtumat / lahjakortit**: aikataulu seuraaville vaiheille ja se, linkittyvätkö ne tilapäisesti vielä Johkuun (nyt hoito- ja tapahtumatuotteet näyttävät "ota yhteyttä", lahjakortit/yritykset-linkit jäävät Johkuun).
11. **Markkinointilupateksti**: lopullinen teksti (nyt versio `v1`: "Haluan vastaanottaa … uutiskirjeitä ja tarjouksia") ja milloin tuodaan Johku-luvat (`allowmarketing=1`).
12. **Tuotantojulkaisun portti**: käytetäänkö hallinnalle erillistä osoitetta (ehdotus `/hallinta/`, noindex) ja otetaanko 2FA Supabase Authissa käyttöön admin-tileille?

## D. Ratkaistut päätökset (omistaja, 16.10.2026) ja niiden toteutus

| Päätös | Toteutus |
|---|---|
| **Viikonloppu: 6 hlöä per alkamisaika** (2 h vuorot 14:00, 14:30, 15:00, 16:00, 16:30, 17:00) | Jokaisella viikonlopun yleisellä säännöllä oma kapasiteettipooli (`yleinen_vkp_HHMM`, 6 hlöä); pooli kopioituu varaukseen (`reservations.pool_ids`). Vanha jaettu pooli `yleinen_vkp` poistettu. Kapasiteetti muokattavissa hallinnasta. |
| **15:30 ei ole alkuaika** | Kesäkauden 15:30-sääntö ja `valid_from/valid_to`-perustelut poistettu (08_seed_rules). |
| **1 h vuoro (Johku 152) la–su 14:00 ja 18:00: 10 hlöä / vuoro, oma kapasiteetti** | Pooli `tunti_vkp_1400` ja `tunti_vkp_1800` (10), `product_config.max_persons` = 10. Ei jaa paikkoja 2 h vuorojen kanssa. |
| **Päällekkäisyyssääntö säilyy** | Yksityinen ja yleinen vuoro eivät saa olla päällekkäin kumpaankaan suuntaan (1 h vuorot mukaan lukien, esim. yksityinen 13–15 vs 1 h 14:00). |
| **Asiakas ei peruuta vahvistettua varausta** | `public_cancel_booking` vapauttaa vain maksamattoman `pending`-pidon. Kaupan vahvistussivulla ei ole peruutuspainiketta vahvistetulle varaukselle; peruutus sähköpostilla → henkilökunta peruu hallinnasta. |
| **Asiakas voi muuttaa varausta ≥ 48 h ennen alkua** (toinen vapaa vuoro samalle tuotteelle tai henkilömäärä) | `public_change_booking(token, rule_id, date, persons)`; atomistinen (sama rivilukitus, tilan lukko ja säännöt kuin uudessa varauksessa; kapasiteetti ja päällekkäisyys tarkistetaan trigger-tasolla). Raja asetuksessa `customer_change_hours_before` = 48. |
| **Roolit admin / manager / staff** (+ ei-henkilöstö: customer, annual_card) | Taulut `booking.roles` ja `booking.role_permissions`; oikeudet pakotetaan `admin_*`-funktioissa ja RLS:ssä; hallinnan UI piilottaa/lukitsee kentät oikeuksien mukaan. Uusi rooli = INSERT, ei koodimuutosta (ks. roolit-ja-kb.md). |
| **Vuosikorttiasiakas** | `booking.annual_cards`; ilmaiset (0 €) varaukset vain yleisiin vuoroihin, vain yksi tuleva vahvistettu varaus kerrallaan, ei yksityisvuoroja – pakotus varausmoottorin triggerissä. Itsepalvelua ei vielä toteuteta, mutta `customers.auth_user_id` on valmiina. |

### Tulkinnat ja huomiot päätöksistä (tarkista)

* **Vuosikortin henkilömäärä:** korttivaraus on 1 hlö (asetus `annual_card_max_persons`, oletus 1). Muuta asetusta jos kortilla saa tuoda seuraa.
* **"Yksi tuleva varaus":** lasketaan varaukset, joiden alku on tulevaisuudessa (`starts_at > now()`) ja tila `pending`/`confirmed`. Mennyt tai peruttu varaus vapauttaa kortin.
* **Muutos 48 h:** raja koskee sekä vanhaa että uutta vuoroa (uusi vuoro ei saa alkaa alle 48 h päästä) ja uusi vuoro noudattaa myös säännön myynnin sulkeutumisaikaa. Henkilömäärän muutoksessa vuoro pysyy samana.
* **Hinnanmuutos:** asiakas ei voi tehdä muutosta, joka muuttaisi jo maksetun tilauksen hintaa (esim. henkilömäärän nosto maksetulla `per_person`-vuorolla) → sähköpostilla henkilökunnalle. Maksamattoman tilauksen hinta päivittyy muutoksessa.
* **Henkilöstöhallinta ja audit-loki** ovat vain `admin`-roolille. Manager voi muokata hintoja ym. mutta ei henkilöstöä eikä antaa admin-oikeuksia. Viimeistä adminia ei voi alentaa tai poistaa käytöstä.
* **Vuosikortin peruutus** ei peru tulevia varauksia ellei hallinnassa valita sitä erikseen; voimassaolon lyhentäminen ei tarkista olemassa olevia varauksia.
* **Seuraus viikonlopun mallista:** yhtäaikaisia henkilöitä voi olla enemmän kuin 6 (limittäiset alkamisajat + 1 h vuorot), kapasiteetit ovat erilliset – tämä on omistajan päätös ja kapasiteetteja voi säätää Resurssit-näkymästä.

## F. Käyttäjähallinta ja työvuorot (testiversio 16.10.2026)

* **F1 (tulkinta):** `staff.manage` (käyttäjien kutsu, roolit, käytöstä poisto, linkitys) on vain adminilla; manager ei saa sitä. Uudet oikeudet `shifts.view` (staff: omat) ja `shifts.view_all` (manager, admin).
* **F2 (tulkinta):** työvuorojen totuus on Google Calendar → Työvuoro-Tapio → `public.work_shifts`. Varausjärjestelmä vain **lukee**; vuorojen muokkausta ei toteuteta. Staff näkee vain omat vuoronsa linkin `booking.staff.public_staff_id` → `public.staff.id` kautta (löyhä viittaus, ei viiteavainta). Ilman linkkiä lista on tyhjä.
* **F3 (AVOIN, varmistettava):** `public`-skeeman sarakenimet ovat oletuksia (ei yhteyttä oikeaan kantaan koodatessa). Bottiavustus tarkistaa ne ennen migraatioiden ajoa: ks. [roolit-ja-kb.md](roolit-ja-kb.md#oletetut-public-sarakkeet-varmistettava-ennen-migraatioiden-ajoa).
* **F4 (tulkinta):** kutsu tehdään Edge Functionilla (service role palvelimella), ei selaimesta. Jos kutsutulla sähköpostilla on jo Auth-tunnus, uutta kutsua ei lähetetä vaan tunnukselle annetaan rooli. Käytöstä poisto = `booking.staff.active = false` + Auth-esto. Kutsusähköposti lähtee Supabasen oletuslähettäjältä, kunnes oma SMTP (savusauna@saunotus.fi) on otettu käyttöön – **avoin**.
* **F5 (tulkinta):** `admin_upsert_staff`:n uusi parametri `p_public_staff_id` = null jättää linkin ennalleen; linkin poisto tehdään `admin_link_public_staff(user, null)`.

## G. Asiakastyypit ja lisäpalvelut (migraatio 11, v8)

Tulkinnat (tarkista) ja avoimet kysymykset Joonakselle. **T** = tulkinta tehty, **A** = avoin.

* **G1 (T) ALV:** lisäpalvelujen hinnat ovat **bruttohintoja (sis. ALV)** kuten kaikki muu hinnoittelu (`kb.products.price`, `order_items.unit_price_gross`); ALV-kanta on rivillä (`vat_rate`) ja `line_vat`/`line_net` lasketaan siitä. Molemmille alkulisäpalveluille **25,5 %**. **A:** vahvista, että turvenaamio + jalkakylpy ja saunavihta ovat 25,5 % (ei esim. 14 %); kanta vaihdetaan Tuotteet → Lisäpalvelut (sallitut 0, 10, 13,5, 14, 24, 25,5). Hinnan/ALV:n muutos koskee vain uusia tilauksia (rivi kopioi hinnan tilaushetkellä).
* **G2 (T) Määrärajat:** lisäpalvelun enimmäismäärä varauksessa = **henkilömäärä × `max_per_person`** (oletus 1 / henkilö), kattona 99 kpl. Määrä on kokonaisluku ≥ 0, ja se rajataan automaattisesti, jos henkilömäärä pienenee varauksen muutoksessa. `max_per_person` (1–20) on muokattavissa lisäpalvelukohtaisesti hallinnassa. **A:** riittääkö "enintään yksi per henkilö" (esim. voiko ostaa 2 vihtaa / hlö → nosta `max_per_person`)?
* **G3 (T) Mille varauksille:** lisäpalvelut koskevat sekä yleisiä että yksityisvuoroja (`applies_modes`, muokattavissa). **Vuosikorttivaraus (0 €, 1 hlö) ei sisällä lisäpalveluita**; hallinnan lomakkeessa valitsin piiloutuu kun "Vuosikorttivaraus" on valittu. **A:** saako vuosikortilla ostaa lisäpalveluita?
* **G4 (T) Muokkaus jälkikäteen:** asiakas valitsee lisäpalvelut varatessaan; verkossa niitä ei voi lisätä/poistaa jälkikäteen (vain määrä rajautuu henkilömäärän muutoksessa; maksetun tilauksen hinnanmuutos → henkilökunnalle). Henkilökunta muokkaa lisäpalveluita varauksen tiedoista (`admin_set_reservation_addons`, oikeus `bookings.manage`; tilauksen summa ja odottava maksu päivittyvät). Maksetun tilauksen lisäpalveluiden muutoksessa maksutila lasketaan uudelleen (esim. maksettu → osittain maksettu, jos summa kasvaa), mutta palautusta tai lisämaksua ei luoda automaattisesti: erotus kirjataan käsin. Vuosikorttivaraukselle henkilökunta voi lisätä lisäpalveluita käsin (silloin tilauksen summa on pelkkä lisäpalveluiden summa).
* **G5 (T) Yritysasiakkaan maksu:** `pay_later`-tilassa yritysasiakkaan verkkovaraus vahvistuu heti ja maksutavaksi merkitään `invoice` (lasku); laskun lähetys tehdään käsin / tulevalla laskutusintegraatiolla, tässä vaiheessa **laskua ei lähetetä automaattisesti**. `hold_until_paid`-tilassa (Visma Pay, myöhemmin) yritys kulkee samaa verkkomaksupolkua kuin yksityinen. **A:** halutaanko yritykselle verkkomaksun sijaan aina lasku?
* **G6 (T) Y-tunnus:** muoto `1234567-8`, tarkistenumero painoilla 7,9,10,5,8,4,2 mod 11 (jäännös 0 → tarkiste 0, jäännös 1 → virheellinen, muuten 11 − jäännös). Syötteenä hyväksytään myös 8 numeroa ilman viivaa, vanha 6+1-muoto (etunolla täydennetään) ja `FI`+8 numeroa (ALV-tunnus muunnetaan y-tunnukseksi); tallennus aina muodossa `1234567-8`. Tarkistus on sekä selaimessa (nopea palaute) että tietokannassa (`_business_id_ok` + check-rajoite). **A:** ulkomaiset yritykset (ei suomalaista y-tunnusta) eivät ole tuettuja.
* **G7 (T) Verkkolaskutiedot:** *verkkolaskuosoite (OVT-tunnus)* ja *operaattori (välittäjätunnus)* ovat valinnaisia, mutta vain **yhdessä** (molemmat tai kumpikaan; virhe `einvoice_incomplete`). Muoto: isot kirjaimet/numerot, osoite 6–35 ja välittäjä 3–35 merkkiä (esim. `003723327487` tai `BAWCFI22`); välilyönnit poistetaan. **Viite / tilausnumero** on valinnainen (≤ 100 merkkiä) ja tilauskohtainen: tilauksen viite ohittaa asiakkaan oletusviitteen. Laskutusosoite (katu, 5-numeroinen postinumero, postitoimipaikka) on pakollinen. **A:** tarvitaanko myös erillinen laskutussähköposti (nyt käytetään yhteyshenkilön sähköpostia) tai ALV-tunnus erikseen?
* **G8 (T) Asiakasrekisteri:** yritysasiakas on rivi, jossa yritys + yhteyshenkilö (`name` = yhteyshenkilö). Haku/yhdistäminen: yksityinen asiakas yhdistetään sähköpostilla, yritysasiakas **y-tunnus + yhteyshenkilön sähköposti**; **yksityinen ja yritys samalla sähköpostilla ovat eri asiakkaita** (ei yhdistetä automaattisesti). Tilaukselle tallennetaan laskutustietojen kuva (`orders.billing`), joten vanhan tilauksen laskutustiedot eivät muutu, vaikka asiakasrekisteriä muokataan. `customer_type` (customer/annual_card) ja `customer_kind` (private/company) ovat eri asioita; vuosikortti voi periaatteessa olla vain yksityisasiakkaalle (kortin myöntö ei tarkista tyyppiä – **A**).
* **G9 (T) Oikeudet:** ei uusia oikeuksia. *Lisää asiakas* ja asiakkaan muokkaus = `customers.manage` (staff, manager, admin); lisäpalvelujen nimet/kuvaukset/hinnat/ALV/aktiivisuus = `catalog.edit` (manager, admin; staff näkee mutta ei muokkaa, kuten tuotetiedot); lisäpalvelun lisäys/muutos varaukseen = `bookings.manage`; lisäpalvelujen lukeminen = kaikki henkilökunta; kauppa lukee vain aktiiviset `public_addons()`-funktiolla (anon ei lue taulua).
* **G10 (T) Kielet:** lisäpalvelulla on FI- ja EN-nimi/kuvaus (`name_en`, `description_en`); EN-kauppa käyttää englantia, jos käännös on annettu. Yrityslomakkeen FI/EN-tekstit ovat `shop/src/i18n.js`:ssä.
* **G11 (T) Markkinointilupa:** annetaan yhteyshenkilölle (henkilökohtainen suostumus, kuten yksityisellä); yritys ei anna lupaa erikseen.
* **G12 (T) Päivänäkymän "Valmistele":** vuorokohtainen yhteenveto laskee lisäpalvelut vain aktiivisista varauksista (vahvistettu tai voimassa oleva pito); peruttu/vanhentunut ei näy. Vuoro tunnistetaan säännön (`rule_id`) ja alkamisajan mukaan, joten sama vuoro yhdistyy riippumatta siitä, onko varaus tehty verkossa vai hallinnasta.

