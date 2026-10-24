# Asetukset-sivun uudistus

Tila: **toteutettu** hallinnan kokeilunäkymässä ja tietokantakutsuna. Tuotantoa ei ole muutettu eikä tätä ole yhdistetty. Luonnos, josta ulkoasu lähti, on [`docs/mockups/asetukset.html`](mockups/asetukset.html). Toteutettu sivu on `booking/admin/views/settings.js`. Kuvat puhelimen leveydeltä: [etusivu](mockups/asetukset-toteutus-etusivu.png), [varaukset](mockups/asetukset-toteutus-varaukset.png), [maksut](mockups/asetukset-toteutus-maksut.png).

Migraatio on `booking_123` (`20261021160000`), ei `booking_122`. Tekstit ovat `content/site-texts.pending-import-31.json`, ei `pending-import-30`. Rich-tekstin työ ehti käyttää `booking_122` ja `pending-import-30` aikaleimalla `20261021150000`, joten tämä tulee sen jälkeen.

Sivu on Joonakselle, joka käyttää hallintaa enimmäkseen puhelimella. Tavoite on se, että asetuksista näkee yrityksen, varaussäännöt ja sen, onko maksu tai integraatio testissä, pois päältä vai oikeasti käytössä. Ulkoasua, värejä ja sivuston teemaa ei säädetä täällä.

## Miten sivu toimi ennen

Hallinnan Asetukset (`booking/admin/views/settings.js`, välilehdet `booking/admin/settings-tabs.js`) listaa taulun `booking.settings` rivit. Oikeus on `settings.edit` (pääkäyttäjä ja ylläpitäjä). Peruskäyttäjä ei näe asetuksia. Jos käyttäjällä on vain `pos.use`, hän näkee välilehden QR-koodin tulostus.

Jokainen rivi on avain, kenttä ja oma Tallenna-nappi. Vain muutamalla avaimella on suomenkielinen nimi (`META` tiedostossa `settings.js`). Muut näkyvät sellaisenaan, esimerkiksi `articles_label_en` tai koko `seller`-objekti yhtenä tekstinä. Tuntematon avain putoaa välilehteen Yleiset, jotta rivi ei katoa.

Välilehdet nyt: Yleiset, Varaukset, Maksut, Sähköposti, Laskutus, Kirjanpito ja Procountor, Lahjakortit, Rajoitukset, QR-koodin tulostus.

Samalla sivulla on lomakkeita, jotka eivät lue `booking.settings`-taulua vaan `booking.integration_config`-rivejä: Visma Payn tila, Procountorin tilikartta ja tila (myös **live**), sekä Google-kalenterin vienti (myös **live**). Ne ovat pudotusvalikoita. Puhelimella niistä voi vaihtaa tuotantotilan vahingossa. Uudessa näkymässä niitä ei ole kytkiminä.

`messages.timed_enabled` on tietokannassa, mutta asetussivu suodattaa `messages.`-avaimet pois. Kytkin on jo Viestit-sivulla. Se pysyy siellä.

Tallennus kulkee funktiolla `admin_set_setting`. Se vaatii vain, että avain on olemassa. Tarkistus on vain neljälle avaimelle (`hold_minutes`, `public_payment_mode`, `customer_change_hours_before`, `annual_card_max_persons`). Muut arvot, myös polut ja rate limit -luvut, voi kirjoittaa sellaisenaan.

## Sanasto päätöksille

| Päätös | Mitä tehdään |
|---|---|
| **pidä** | Jää lomakkeelle suomenkielisenä kenttänä. Avain säilyy. |
| **jaa kenttiin** | Sama avain, mutta yksi JSON-möhkäle näytetään erillisinä kenttinä. |
| **siirrä** | Ei tähän lomakkeeseen. Oikea paikka on toinen sivu, koodi tai sivuston build. Avainta ei poisteta kannasta tässä vaiheessa. |
| **vain tila** | Näytetään lukuna tai merkkinä. Ei kytkintä eikä valintaa, jolla tila vaihtuisi liveksi tai testiksi. |
| **piilota teknisenä** | Jää kantaan ja koodiin. Ei näy Joonakselle. |

Avaimia ei poisteta tietokannasta tässä suunnitelmassa. Poisto käyttöliittymästä on eri asia kuin `DELETE`. Vanha moottori lukee yhä osaa piilotetuista avaimista.

## Kaikki nykyiset `booking.settings`-avaimet

Oletus on se arvo, jolla migraatio loi rivin. Tuotannossa arvo voi olla jo toinen. Uusi sivu lukee kannan, ei näitä oletuksia.

### Yritys, kauppa ja kuitin myyjä

| Avain | Oletus | Missä koodi käyttää | Päätös | Perustelu |
|---|---|---|---|---|
| `business_name` | Sipoonjoen Perinnesauna | Julkinen `public_settings()`. Kaupan nimi. | pidä | Nimi, jonka asiakas näkee. Eri kenttä kuin kuitin virallinen nimi. |
| `seller` | JSON: nimi, virallinen nimi, toiminimi, y-tunnus, ALV-tunnus, osoite, puhelin, sähköposti, verkko, `logo_url`, alatunniste. Kopioitu `kb.businesses` id 1 (Havuhattu Oy, 3018112-1, Hindsbyntie 124, 04130 Sipoo, 010 299 2866, savusauna@saunotus.fi). | `booking._seller()` ja kuitin teksti (`booking_31`, täydennys `booking_119`). Uusi kuitti kopioi sen hetkisen arvon. Vanha kuitti ei muutu. | jaa kenttiin | Nyt koko JSON on yksi tekstikenttä avaimella `seller`. |
| `timezone` | Europe/Helsinki | Avain on julkinen. Vuorojen kello tulee funktiosta `booking._tz()`, joka on kovakoodattu `Europe/Helsinki` eikä lue tätä avainta. Kalenteriviennin aikavyöhyke on eri paikassa (`integration_config.booking_calendar`). | piilota teknisenä | Kentän muuttaminen ei siirrä vuoroja. Etusivulla lukee vain "kellonaika Europe/Helsinki". |

`seller`-objektin kentät lomakkeella: kaupan nimi kuitissa (`name`), virallinen nimi (`legal_name`), toiminimi (`trade_name`), y-tunnus (`business_id`), ALV-tunnus (`vat_id`), katu, postinumero, kaupunki, maa, puhelin, sähköposti, verkkosivu, kuitin alatunniste (`footer`). `logo_url` jää tekniseksi: näytetään vain "kuittilogo käytössä" tai "ei logoa".

ALV-tunnus on johdettu y-tunnuksesta (`FI` + numerot). Nykyinen arvo on FI30181121. Lomake näyttää sen ja tarkistaa muodon. Automaattista ylikirjoitusta ei tehdä, jos Joonas on korjannut tunnuksen.

### Varaukset

| Avain | Oletus | Missä koodi käyttää | Päätös | Perustelu |
|---|---|---|---|---|
| `public_booking_enabled` | true | Julkinen varaus (`public_create_booking` ja myöhemmät versiot, viimeisin polku `booking_61` / `booking_64` sekä kassa `booking_53`). Kun false, kauppa näyttää "Verkkovaraus ei ole tällä hetkellä käytössä" ja puhelinnumeron (`booking/shop/src/i18n.js`). Olemassa olevia varauksia ei peruta. | pidä | Etusivun taukokytkin. Pois päältä vaatii vahvistuksen. |
| `booking_horizon_days` | 120 | Kuinka monta päivää eteenpäin yleisen vuoron voi varata. Julkinen asetus. | pidä | |
| `public_treatment_horizon_days` | 14 | Hoitojen ostoikkuna. Julkinen `booking_61` jälkeen, kauppa lukee sen. | pidä | Hoidot ja savusauna eivät jaa samaa ikkunaa. |
| `public_treatment_min_lead_minutes` | 120 | Hoitoa ei tarjota, jos alkuun on tätä vähemmän. Ei julkinen. | pidä | Vain hoidot. |
| `customer_change_hours_before` | 48 | Asiakkaan siirto ja henkilömäärän muutos. Julkinen. Sivutekstit käyttävät merkintää `{{setting:customer_change_hours_before}}`. Rajat 0–720 h, kokonaisluku (`admin_set_setting`). | pidä | Ei ole peruutusaika. Vahvistettua varausta asiakas ei peru itse (`public_cancel_booking` peruu vain vielä vahvistamattoman). |
| `annual_card_max_persons` | 1 | Vuosikorttivarauksen henkilömäärä. Rajat 1–20. Yksi tuleva varaus kerrallaan on moottorin sääntö, ei tämä luku. | pidä | |
| `checkout_group_threshold_persons` | 0 | Kassa: tästä henkilömäärästä varaus jää alustavaksi. 0 = pois. Raja 0–1000 (`_checkout_cfg_int`). | pidä | Nyt pois käytöstä. |
| `checkout_group_hold_days` | 7 | Alustava varaus vapautuu näin monen päivän kuluttua. Raja 1–60. | pidä | Näytetään, kun kynnys on yli 0. |
| `public_treatment_global_per_hour` | 30 | Uusia julkisia hoitovarauksia tunnissa enintään. | piilota teknisenä | Suojakatto, ei aukiolo. |
| `public_treatment_max_open_per_email` | 5 | Maksamattomia hoitovarauksia samalla sähköpostilla. | piilota teknisenä | Suojakatto. |

Savusaunavuoron oma myynnin takaraja on rivillä `schedule_rules.deadline_minutes` (esimerkiksi 15 min, 2 h tai 12 h ennen alkua). Sitä muokataan vuorosäännöissä, ei asetuksissa. Asetussivu kertoo tämän lyhyesti, eikä kopioi sitä toiseksi kentäksi.

Vuorojen välistä puskuria ei ole. Vuorot ovat valmiita aikoja ja kapasiteettipoolit, eivät vapaata kalenteria, johon lisätään tyhjä väli. Puskurikenttää ei lisätä. Jos tyhjä väli tarvitaan, se on vuorosäännön muutos.

### Maksut

| Avain | Oletus | Missä koodi käyttää | Päätös | Perustelu |
|---|---|---|---|---|
| `public_payment_mode` | `pay_later` | `pay_later` = varaus vahvistuu heti, maksu paikan päällä. `hold_until_paid` = paikka pidetään, kunnes summa on maksettu. Julkinen. Sallitut arvot vain nämä kaksi. | vain tila | Vaihto muuttaa koko kassan. Ei pudotusvalikkoa. |
| `hold_minutes` | 15 | Vanha moottori (`booking_05`, `booking_11`). Uusi kassa lukee `checkout_hold_minutes`. Avain on yhä julkinen. `admin_set_setting` sallii 1–240. | piilota teknisenä | Kaksi pitoaikaa. Näkyvä kenttä on `checkout_hold_minutes`. Toteutuksessa arvot pidetään samoina, kunnes vanha lukija on poistettu. Avainta ei näytetä. |
| `checkout_hold_minutes` | 15 | `_checkout_hold_minutes()`, raja 5–60. Kassa palauttaa tämän `hold_minutes`-nimisenä. | pidä | Vaikuttaa vasta, kun maksutila on "pidä kunnes maksettu". Nyt se ei ole. Lomake sanoo sen. |
| `checkout_mobilepay_grace_minutes` | 15 | Kesken jäänyttä MobilePayta odotetaan. Raja 0–60. | pidä | Selkokieli: kuinka kauan paikka pysyy, jos maksu on kesken. |
| `checkout_mobilepay_max_wait_minutes` | 30 | Odotuksen katto tilauksen luonnista. Raja 0–120. | pidä | Sama kortti kuin yllä. |
| `pay_later_test_enabled` | false | `public_confirm_pay_later`: odottava varaus vahvistetaan maksamattomana. Oletus pois, migraatio ei laita päälle. | vain tila | Kytkin vahvistaisi maksamattomia varauksia. |
| `checkout_company_invoice_enabled` | true | Yritysasiakas voi kassalla mennä laskulle, myös pitotilassa. | pidä | Tämä on yrityskaupan sääntö, ei Procountorin live-tila. |

Asiakkaan verkkomaksu (Visma Pay, MobilePay) ei ole näitä avaimia. Tila on `integration_config`. Katso seuraava luku. Niitä ei tehdä kytkimiksi.

Käsin kirjattavat maksutavat ovat taulussa `booking.payment_methods` (`active`), eivät `settings`. Käteinen on merkitty pois (`booking_119`: `cash` ei kelpaa, `admin_record_payment` hylkää sen). Uusi Maksut-osio voi näyttää, mitkä tavat henkilökunta näkee kirjatessaan maksua. Se vaatii uuden rajapinnan. Käteiselle ei tule kytkintä. Verkkomaksun tapaa ei kytketä tästä listasta.

### Sähköposti ja tarjouspyynnöt

| Avain | Oletus | Missä koodi käyttää | Päätös | Perustelu |
|---|---|---|---|---|
| `business_quote_notify_email` | savusauna@saunotus.fi | Sisäinen viesti uudesta tarjouspyynnöstä. Tyhjä = ei viestiä. | pidä | Henkilökunnan vastaanottaja. Vain tämä tapahtuma. Uudesta verkkovarauksesta ei lähde erillistä henkilökuntaviestiä. |
| `business_quote_notify_name` | Joonas | Tervehdys siinä viestissä. | pidä | |
| `business_quote_rl_ip_per_10min` | 5 | Tarjouslomakkeen rajoitus. | piilota teknisenä | |
| `business_quote_rl_email_per_hour` | 3 | Sama. | piilota teknisenä | |
| `messages.timed_enabled` | false | Ajastetut tuoteviestit (`booking_121`). Lyhyt ohje tilausvahvistuksessa ei riipu tästä. | siirrä | Kytkin on Viestit-sivulla. Asetuksissa lukee tila ja linkki Viesteihin. Toista kytkintä ei tehdä. |

Lähettäjän nimi, vastausosoite, lähetystila (pois / harjoitusajo / live) ja vastaanottajarajaus (`test_recipients`) ovat rivillä `integration_config.resend`, eivät tässä taulussa. Allekirjoitus "Tapio" on sähköpostipohjien teksteissä (`email.*.sign_name`), ei asetuksessa.

### Laskut ja kuitit

| Avain | Oletus | Missä koodi käyttää | Päätös | Perustelu |
|---|---|---|---|---|
| `invoice_due_days` | 14 | Laskun eräpäivä. | pidä | |
| `invoice_bank` | `iban`, `bic` ja `name` tyhjinä | Laskun pankkiyhteys. Julkinen laskulla. Ei salasana. | jaa kenttiin | Kolme kenttää. Tyhjä, kunnes täytetty. Ei ole live-kytkin. |
| `invoice_dispatch_mode` | `dry_run` | `dry_run` ei kutsu Procountoria. `live` on jätetty erilliseen käyttöönottoon. | vain tila | |
| `receipt_series` | `receipt` = K, `refund_receipt` = H. `booking_119` lisää `giftcard_info` = L, jos puuttuu. | Aukoton numerosarja vuodelle. | vain tila | Sarjan kirjainta ei vaihdeta lomakkeella. Vaihto kesken vuoden rikkoo juoksevan numeron. |

Kuitin y-tunnus, ALV ja osoite tulevat `seller`-objektista. ALV-kannat ovat taulussa `booking.vat_rates` ja tuotteilla, ei asetuksissa.

### Lahjakortit ja kumppanikoodit

| Avain | Oletus | Missä koodi käyttää | Päätös | Perustelu |
|---|---|---|---|---|
| `gift_cards.sale_enabled` | false | `public_buy_gift_card`. | pidä | Oma verkkomyynti. Päälle vain vahvistuksella. Oletus pois. |
| `gift_cards.redeem_enabled` | false | Lunastus kassalla ja verkossa. | pidä | Sama. Oletus pois. |
| `gift_cards.johku_cards_redeemable` | false | Johku-kortin lunastus. Kommentti: pidä false, kunnes Johkun kortit on suljettu, ettei samaa korttia lunasteta kahdesti. | vain tila | Ei kytkintä. |
| `gift_cards.max_cards_per_order` | 10 | Kortteja yhdessä ostossa. | pidä | |
| `gift_cards.rl_check_fail_per_10min` | 10 | Arvausten raja. | piilota teknisenä | |
| `gift_cards.rl_global_fail_per_10min` | 200 | Sama, yhteensä. | piilota teknisenä | |
| `gift_cards.rl_buy_per_10min` | 6 | Ostoja / IP. | piilota teknisenä | |
| `voucher_claims.enabled` | false | Kumppanikoodin jättö verkossa (Elämyslahjat, Kokemuskauppa, Kiitoskauppa, Offerilla). | vain tila | Oletus pois, kunnes käyttöönotto. Ei kytkintä puhelimessa. |
| `voucher_claims.problem_emails_enabled` | false | Ongelmaviesti asiakkaalle vasta, kun true ja pohja on hyväksytty. | vain tila | Vois lähetä asiakaspostia, kun sähköposti on joskus livessä. |
| `voucher_claims.partner_voucher_accounted` | false | false = kumppanikoodi ei tee kuittia eikä kassaraporttia. true = kuten muu käsin kirjattu maksu. | vain tila | Kirjanpitosääntö, ei arkinen kytkin. |
| `voucher_claims.max_per_order` | 10 | Avoimia pyyntöjä / tilaus. | pidä | |
| `voucher_claims.remind_after_hours` | 24 | Pyyntö nousee vanhojen listalle. Raja koodissa 1–720. Mikään ei vanhene automaattisesti. | pidä | |
| `voucher_claims.max_attempts` | 6 | Botin yritykset, sen jälkeen tapaus henkilökunnalle. | piilota teknisenä | |

Voimassaolo ei ole `settings`-avain. Se on paketilla `gift_card_packages.valid_months` (kaikilla siemenpaketeilla 6, sallittu 1–36). Hallinnan myynnissä yhdelle kortille voi antaa 1–12 kk. Asetuksissa näytetään yhteenveto ("paketeilla 6 kk") ja ohjataan lahjakorttien myyntiin, jos yksittäinen kortti tarvitsee toisen ajan. Yhteistä uutta avainta ei lisätä, ellei avoin kysymys päätä toisin.

Maksuton hallintokortti on sarake `gift_cards.complimentary` (`booking_117`), ei asetus.

### Osoitteet, polut ja sivuston rakenne

| Avain | Oletus | Missä koodi käyttää | Päätös | Perustelu |
|---|---|---|---|---|
| `site_base_url` | https://saunotus.fi | Sähköpostien, tilaussivun, QR-koodin ja kalenterin linkit. | vain tila | Väärä osoite rikkoo viestit. Ei tekstikenttää. |
| `order_page_path` | /tilaus/ | Tilaussivun polku. Päätetty 17.10.2026. | siirrä | Polku on sivuston reitti, ei liiketoiminta-asetus. |
| `payment_link_path` | /maksa/ | Maksulinkki. Visma-ohje: älä vaihda oletuspolkua migraatiolla. | siirrä | Sama. |
| `functions_base_url` | Edge-funktioiden osoite | Kuitti-PDF ja ajastetut kutsut. | piilota teknisenä | |
| `articles_path_fi` | /saunatietoa/ | Artikkelin osoite. Julkinen. Vaihto vaatii sivuston uudelleenbuildin. | siirrä | Kuuluu koodiin tai sivuston buildiin, ei tähän lomakkeeseen. |
| `articles_path_en` | /en/sauna-knowledge/ | Sama englanniksi. | siirrä | |
| `articles_label_fi` | Saunatietoa | Osion nimi. | siirrä | Sivuteksti, ei hallinnan asetus. |
| `articles_label_en` | Sauna knowledge | Sama. | siirrä | Juuri tällainen avain tekee nykyisestä sivusta sekavan. |

### Rajoitukset ja bottien kiintiöt

| Avain | Oletus | Missä koodi käyttää | Päätös | Perustelu |
|---|---|---|---|---|
| `rl_ip_per_10min` | 12 | Julkiset varausyritykset / IP. Ei julkinen. | piilota teknisenä | Nykyinen välilehti Rajoitukset poistuu. |
| `rl_email_per_10min` | 5 | Sama sähköpostilla. | piilota teknisenä | |
| `rl_change_per_10min` | 10 | Muutosyritykset / varaustunnus. | piilota teknisenä | |
| `rl_avail_per_10min` | 60 | Hoitoaikojen kyselyt / IP. | piilota teknisenä | |
| `rl_order_get_per_10min` | 60 | Tilaussivun avaukset. | piilota teknisenä | |
| `rl_order_add_per_10min` | 20 | Lisäykset tilaukseen. | piilota teknisenä | |
| `rl_order_req_per_10min` | 6 | Pyynnöt tilaukselta. | piilota teknisenä | |
| `marketing_consent_text_version` | v1 | Tallennetaan asiakkaalle suostumuksen yhteydessä. | piilota teknisenä | Versioleima. Itse teksti on sivuteksti. |
| `texts_max_proposals_per_day` | 200 | Tekstibotin ehdotuskiintiö / 24 h. | piilota teknisenä | |
| `texts_bot_max_approvals_per_day` | 100 | Botin hyväksyntäkiintiö / 24 h. | piilota teknisenä | |
| `closure_sync` | JSON: `max_timed_hours` 36, `guard_min_deletes` 5, `guard_ratio` 0.5, ikkunat, `tombstone_days` 90 | Sulkukalenterin synkka (`booking_18`). | piilota teknisenä | Suoja massapoistoa vastaan. Ei liiketoimintakytkin. |

### Kannasta jo poistetut avaimet

Näitä ei palauteta lomakkeelle.

| Avain | Mitä tapahtui |
|---|---|
| `voucher_claims.hold_hours` | Luotiin (48 h) ja poistettiin `booking_48`. Lunastuspyyntö ei vanhenna varausta. |
| `gift_cards.complimentary_vat_treatment` | Poistettu `booking_117`. Maksuton kortti on sarake `complimentary`. |

Koodi lukee myös nimeä `procountor_env` varalla (`_setting`, oletus `pts`), mutta sellaista avainta ei ole luotu. Procountorin ympäristö on `integration_config`. Uutta avainta ei tehdä.

## Yhteydet, jotka eivät ole settings-avaimia

Nämä näkyvät nykyisellä asetussivulla tai kuvaavat samaa asiaa. Uudessa näkymässä ne ovat **tilakortteja**. Live-, testi- ja harjoitusvalintoja ei ole.

| Yhteys | Missä tila on | Mitä koodi tekee nyt | Uudessa näkymässä |
|---|---|---|---|
| Visma Pay | `integration_config.vismapay`. Tila `off`, `dry_run`, `test` tai `live`. Testi ja live vaativat `approved_by`. Oletus migraatiossa `off`. | `admin_set_vismapay_mode` antaa ylläpitäjän vaihtaa tilan, myös liveen. | Vain tila. Testi näyttää varoituksen: asiakkaalta ei veloiteta oikeaa rahaa. Live näyttäisi toisen varoituksen. Ei valintaa. |
| MobilePay | `integration_config.mobilepay`. Tila `off`, `test` tai `live` (ei harjoitusajoa). Testi ja live vaativat `approved_by`. Oletus `off`. | Tila ei ole nykyisessä asetusten pudotusvalikossa, mutta se on sama taulu. | Vain tila. |
| Sähköposti (Resend) | `integration_config.resend`. Oletus `dry_run`. `from` ja `reply_to`. `test_recipients`: kun lista ei ole tyhjä ja tila on live, muu vastaanottaja ohitetaan ("ei allowlistissa"). Tyhjä lista ei rajaa ketään. | Tila ja lista eivät ole lomakkeella. Ne vaihdetaan tietokannassa. | Tila ja "rajaus päällä / ei rajausta" vain lukuina. Listaa ei tyhjennetä eikä tilaa vaihdeta tästä. Lähettäjän **näkyvä nimi** ja **vastausosoite** ovat muokattavia. Osoite `savusauna@saunotus.fi` pysyy lukittuna, koska väärä osoite rikkoo lähtevän postin. |
| Procountor | `integration_config.procountor`. Oletus `off`, ympäristö `pts`. Tilit, ALV-tila, päiväkirjaus, pankkitili, `api_prefix`. | Tila, ympäristö ja päiväkirjaus ovat vain luku. Pääkäyttäjä muokkaa tilikarttaa, ALV-tilaa, pyöristystiliä, pankkitiliä ja `api_prefix`-etuliitettä Yhteydet-välilehdellä. Tallennus lähettää tilan, ympäristön ja päiväkirjauksen nykyisinä arvoina, jotta ne eivät nollaudu. | Tila: pois / harjoitusajo / yhdistetty. Tilikartta on muokattava vain roolille admin. |
| Google-varauskalenteri | `integration_config.booking_calendar`. Oletus `off`. | Lomake Varaukset-välilehdellä, vain pääkäyttäjälle: tila `off` / `dry_run` / `live`, kalenteritunnus, esikatselu. Käyttöönotto 26.10. | Yhteydet-välilehdellä tila on vain luku. Käyttöönotto on Varaukset-kortissa. Sulkukalenterit ovat eri synkka. |
| Laskun lähetys Procountoriin | `invoice_dispatch_mode` | Katso yllä. | Vain tila. |

Salaisuuksia (API-avaimet, SMTP, Google-palvelutili) ei näytetä eikä kysytä. Ne ovat Edge-salaisuuksia.

## Mitä järjestelmässä on, mutta ei tälle lomakkeelle

| Asia | Missä se on | Miksi ei asetuksiin |
|---|---|---|
| Viestipohjat, ajastus, palautepyynnön linkki | Viestit-sivu, taulu `booking.messages` | Sisältö, ei yleinen asetus. Ajastuskytkin pysyy siellä. |
| Muotoiltu teksti | `booking.site_texts`, laji `plain` tai `lite` | Sivutekstit ja bottien työnkulku. Ei teema eikä tämä sivu. |
| Roolit ja oikeudet | Käyttäjät-sivu, `booking.roles` ja `role_permissions` | Vain pääkäyttäjä (`staff.manage`). Asetuksissa lukee vain "sinun roolisi". |
| Saunabot | `content/site.json` → `chatbot.enabled` on false. Sivu ei lataa bottia. Testissä `SAUNABOT=on`. | Ei tuotantoon ennen erillistä päätöstä ja avainta. Ei kytkintä. Yhteydet-kortti: pois. |
| Google-arvostelut sivustolla | `content/reviews.json` (käsin poimittu). Tekstit `ui.reviews.*`. | Ei hallinnan asetus. Palautepyyntö on Viestit-osiossa. |
| Tuotteet, hinnat, ALV, resurssit, vuorosäännöt, sulut | Omat sivut | Jo olemassa. Asetukset eivät kopioi niitä. |
| QR-tarrat | Asetusten välilehti, oikeus `pos.use` tai `settings.edit` | Työkalu, ei asetus. Etusivulla linkki. Peruskäyttäjä, jolla on vain `pos.use`, pääsee yhä suoraan tarroihin eikä näe muuta. |
| Ulkoasu | Sivuston build | Rajattu pois. |

## Uusi rakenne

Etusivu on yhteenveto. Välilehti ei ala tyhjällä avainlistalla. Puhelimella välilehdet ovat vaakaan vieritettäviä nappeja, kuten nyt, mutta nimiä on vähemmän: **Etusivu, Yritys, Varaukset, Maksut, Sähköposti, Lahjakortit, Laskut ja kuitit, Yhteydet**.

Rajoitukset-välilehti poistuu. Kirjanpito ja Procountor eivät ole omaa lomaketta. Procountor on Yhteydet-välilehden tilakortti. Yrityksen ja kuitin tiedot ovat Yritys-välilehdellä.

### Etusivu

1. **Varoitus**, jos jokin on testissä tai harjoitusajossa, tai jos vastaanottajarajaus puuttuu silloin kun sähköposti on live. Esimerkki: "Verkkomaksu on testitilassa. Asiakkaalta ei veloiteta oikeaa rahaa."
2. **Verkkovaraus** -kytkin (`public_booking_enabled`). Päällä: asiakas voi varata. Pois: kauppa näyttää nykyisen tekstin ja puhelinnumeron. Olemassa olevat varaukset säilyvät. Pois kytkeminen kysyy vahvistuksen. Tallennus on tämän kortin nappi, ei jokaisen rivin nappi.
3. **Yritys** -tiivistelmä: virallinen nimi, y-tunnus, osoite, puhelin, sähköposti. Linkki muokkaukseen.
4. **Maksut ja yhteydet** -tilat: Visma Pay, MobilePay, sähköposti, Procountor, Google-kalenteri, Saunabot. Ei kytkimiä.
5. **Omat oikeudet**: roolin nimi. Linkki Käyttäjiin vain, jos oikeus `staff.manage`.
6. **QR-tarrat**: linkki tulostukseen. Ei sekoitu asetusriveihin.

### Yritys

Yksi kortti, yksi Tallenna. Kentät `business_name` ja `seller` (jaettuna). Katso validointi alla. Kellonaikaa ei voi vaihtaa.

### Varaukset

Kolme korttia, kullakin oma Tallenna:

- Kuinka pitkälle voi varata (savusauna ja hoidot erikseen).
- Milloin viimeistään (hoidon varoaika, asiakkaan muutosaika). Teksti kertoo, ettei vahvistettua varausta peruta itse, ja että vuorokohtainen takaraja on vuorosäännöissä.
- Iso ryhmä ja vuosikortti.

### Maksut

- Tilakortit: maksutila, Visma Pay, MobilePay, "maksa myöhemmin" -testi. Vain luku.
- Kortti "Kun paikka odottaa maksua": pito, MobilePayn lisäaika ja katto. Selite, että ne vaikuttavat vasta pitotilassa.
- Kortti "Yrityslasku kassalla": `checkout_company_invoice_enabled`.
- Kortti "Maksutavat, kun kirjaat maksun hallinnassa": taulun `payment_methods` aktiivisuus. Käteinen lukittu pois. Visma Pay ja MobilePay eivät ole tässä listassa.

### Sähköposti

- Tila ja vastaanottajarajaus, vain luku.
- Lähettäjän näkyvä nimi ja vastausosoite. Lähettävä osoite lukittu.
- Allekirjoitus Tapio, vain luku, kunnes avoin kysymys päätetään.
- Tarjouspyynnön vastaanottaja ja nimi.
- Rivi "Ajastetut viestit: pois" ja linkki Viestit-sivulle.

### Lahjakortit

- Oman kortin myynti ja lunastus, kytkimet vahvistuksella, oletus pois.
- Kortteja yhdessä ostossa.
- Voimassaolo yhteenvetona (pakettien 6 kk), ei uutta avainta.
- Johku-kortit, kumppanikoodit, ongelmaviestit ja kirjanpitokäsittely vain tiloina.
- Kumppanipyyntöjen enimmäismäärä ja muistutuksen tunnit.

### Laskut ja kuitit

- Eräpäivä ja pankki (IBAN, BIC, pankin nimi).
- Lähetystila Procountoriin vain luku.
- Kuittisarjat K, H ja L vain luku.
- Muistutus, että kuitin nimi ja ALV tulevat Yritys-välilehdeltä.

### Yhteydet

Vain tilakortit: Visma Pay, MobilePay, sähköposti, Procountor (myös viimeisin ajo ja virheet, kuten nykyinen yhteenveto), Google-varauskalenteri, sulkukalenterin synkka yhtenä lauseena ("käytössä erikseen, ei säädetä tästä"), Saunabot pois, sivuston osoite vain luku. Arvostelut: yksi lause, että ne tulevat tiedostosta ja palautepyyntö on Viesteissä.

## Kentät, jotka lomake näyttää

Oikeus muokata on `settings.edit` (pääkäyttäjä ja ylläpitäjä), ellei rivillä lue muuta. Peruskäyttäjä ei näe lomaketta. Vain tila -rivit eivät ole kenelläkään muokattavia, ei myöskään pääkäyttäjällä. Live-tilaan ei pääse hallinnasta.

Tallennus on korttikohtainen. Yksi nappi kirjoittaa kortin kentät. Automaattitallennusta ei käytetä: puhelimella kytkin ehtii lähteä vahingossa. Kytkin, joka sulkee verkkovarauksen tai avaa lahjakortin myynnin tai lunastuksen, kysyy vielä erillisen vahvistuksen.

Toteutus ei saa jättää vanhaa `admin_set_setting(avain, arvo)` -polkua selaimen lomakkeelle. Uusi kutsu ottaa vastaan nimetyt kortit ja hylkää polut, rate limit -luvut ja live-tilat. Vanha funktio voi jäädä palvelimelle, mutta uusi sivu ei kutsu sillä piilotettuja avaimia.

### Etusivu ja yritys

| Kenttä | Avain | Tyyppi | Oletus | Validointi | Uutta koodia |
|---|---|---|---|---|---|
| Verkkovaraus käytössä | `public_booking_enabled` | kytkin | päällä | boolean. Pois päältä: vahvistus. | Ei uutta avainta. Uusi korttitallennus. |
| Nimi kaupassa | `business_name` | teksti | Sipoonjoen Perinnesauna | 2–80 merkkiä. | Ei. |
| Nimi kuitissa | `seller.name` | teksti | Havuhattu Oy / Sipoonjoen Perinnesauna | 2–120 merkkiä. | Ei uutta avainta. Tallennus kirjoittaa JSON-kentän. |
| Virallinen nimi | `seller.legal_name` | teksti | Havuhattu Oy | 2–120. | Ei. |
| Toiminimi | `seller.trade_name` | teksti | Sipoonjoen Perinnesauna | 2–120. | Ei. |
| Y-tunnus | `seller.business_id` | teksti | 3018112-1 | Muoto `1234567-8`. | Ei. |
| ALV-tunnus | `seller.vat_id` | teksti | FI30181121 | Muoto `FI` ja 8 numeroa. Ei ylikirjoiteta y-tunnuksesta hiljaa. | Ei. |
| Katuosoite | `seller.street` | teksti | Hindsbyntie 124 | 1–120. | Ei. |
| Postinumero | `seller.postal_code` | teksti | 04130 | 5 numeroa. | Ei. |
| Postitoimipaikka | `seller.city` | teksti | Sipoo | 1–80. | Ei. |
| Maa | `seller.country` | teksti, lukittu ehdotuksessa | FI | Kahden kirjaimen maakoodi. | Ei. |
| Puhelin | `seller.phone` | puhelin | 010 299 2866 | 5–30 merkkiä, numerot ja väli. | Ei. |
| Sähköposti | `seller.email` | sähköposti | savusauna@saunotus.fi | Kelvollinen osoite. | Ei. |
| Verkkosivu | `seller.website` | teksti | https://saunotus.fi | https-osoite. | Ei. |
| Kuitin alatunniste | `seller.footer` | teksti | Kiitos käynnistä! | 0–160 merkkiä. | Ei. |
| Kuittilogo | `seller.logo_url` | vain tila | asetettu osoite tai tyhjä | Ei muokata. | Ei. |

Avoin kysymys: saako ylläpitäjä muokata y-tunnusta, ALV-tunnusta ja laskun tiliä, vai vain pääkäyttäjä. Luonnos näyttää ne muokattavina nykyisellä oikeudella `settings.edit`.

### Varaukset

| Kenttä | Avain | Tyyppi | Oletus | Validointi | Uutta koodia |
|---|---|---|---|---|---|
| Savusauna ja yleiset vuorot, varausikkuna | `booking_horizon_days` | luku + päivää | 120 | kokonaisluku 1–730 | Ei. |
| Hoidot, varausikkuna | `public_treatment_horizon_days` | luku + päivää | 14 | kokonaisluku 1–180 | Ei. |
| Hoito varattava viimeistään | `public_treatment_min_lead_minutes` | luku + minuuttia | 120 | kokonaisluku 0–1440 | Ei. |
| Asiakas voi muuttaa viimeistään | `customer_change_hours_before` | luku + tuntia | 48 | kokonaisluku 0–720, jo nyt | Ei. |
| Iso ryhmä, kun henkilöitä vähintään | `checkout_group_threshold_persons` | luku + henkilöä | 0 | kokonaisluku 0–100. 0 = pois. | Ei. |
| Alustava varaus vapautuu | `checkout_group_hold_days` | luku + päivää | 7 | kokonaisluku 1–60. Piilossa, kun kynnys on 0. | Ei. |
| Vuosikortilla henkilöitä | `annual_card_max_persons` | luku | 1 | kokonaisluku 1–20, jo nyt | Ei. |

### Maksut

| Kenttä | Avain tai taulu | Tyyppi | Oletus | Validointi | Uutta koodia |
|---|---|---|---|---|---|
| Maksutila | `public_payment_mode` | vain tila | maksetaan paikan päällä | Ei muokata. | Ei. |
| Visma Pay | `integration_config.vismapay.mode` | vain tila | kannan tila | Ei muokata. | Nykyinen `admin_set_vismapay_mode` jää palvelimelle, mutta uusi sivu ei kutsu sitä. |
| MobilePay | `integration_config.mobilepay.mode` | vain tila | kannan tila | Ei muokata. | Ei uutta kirjoitusta. |
| Maksa myöhemmin -testi | `pay_later_test_enabled` | vain tila | pois | Ei muokata. | Ei. |
| Paikan pito | `checkout_hold_minutes` | luku + minuuttia | 15 | 5–60, jo koodissa | Ei. Selite: ei vaikuta, kun tila on maksa paikan päällä. |
| MobilePayn lisäaika | `checkout_mobilepay_grace_minutes` | luku + minuuttia | 15 | 0–60 | Ei. |
| MobilePayn odotuksen katto | `checkout_mobilepay_max_wait_minutes` | luku + minuuttia | 30 | 0–120 | Ei. |
| Yritys voi valita laskun | `checkout_company_invoice_enabled` | kytkin | päällä | boolean | Ei. |
| Hallinnan maksutavat | `payment_methods.active` | kytkin per tapa, paitsi käteinen | nykyinen taulu. Käteinen pois. | Vain tunnetut koodit. `cash` hylätään. `visma_pay` ja `mobilepay` eivät ole tässä. | **Kyllä.** Uusi kutsu, joka päivittää `active`. Ei uutta settings-avainta. |

### Sähköposti

| Kenttä | Avain | Tyyppi | Oletus | Validointi | Uutta koodia |
|---|---|---|---|---|---|
| Lähetystila | `integration_config.resend.mode` | vain tila | harjoitusajo | Ei muokata. | Ei kirjoitusta. |
| Vastaanottajarajaus | `resend.settings.test_recipients` | vain tila | kannan lista | Ei muokata eikä tyhjennetä. Jos tila on live ja lista on tyhjä, etusivu varoittaa. | Ei. |
| Lähettäjän nimi | `resend.settings.from` nimen osa | teksti | Sipoonjoen Perinnesauna | 2–80. Osoiteosoite säilyy. | **Kyllä.** Uusi kutsu, joka vaihtaa vain nimen. Ei uutta settings-avainta. |
| Vastausosoite | `resend.settings.reply_to` | sähköposti | savusauna@saunotus.fi | Kelvollinen osoite. | **Kyllä**, sama kutsu. |
| Lähettävä osoite | `from`-osoite | vain tila | savusauna@saunotus.fi | Ei muokata. | Ei. |
| Allekirjoitus | sivuteksti `email.*.sign_name` | vain tila, kunnes päätös | Tapio | Katso avoimet kysymykset. | Ei vielä. |
| Tarjouspyynnöt osoitteeseen | `business_quote_notify_email` | sähköposti, saa olla tyhjä | savusauna@saunotus.fi | Tyhjä tai kelvollinen osoite. Tyhjä = ei viestiä. | Ei. |
| Tervehdysnimi | `business_quote_notify_name` | teksti | Joonas | 1–80. | Ei. |
| Ajastetut viestit | `messages.timed_enabled` | vain tila + linkki | pois | Ei toista kytkintä. | Ei. |

### Lahjakortit

| Kenttä | Avain | Tyyppi | Oletus | Validointi | Uutta koodia |
|---|---|---|---|---|---|
| Myynti verkossa | `gift_cards.sale_enabled` | kytkin | pois | Päälle vain vahvistuksella. | Ei. |
| Lunastus | `gift_cards.redeem_enabled` | kytkin | pois | Päälle vain vahvistuksella. | Ei. |
| Kortteja yhdessä ostossa | `gift_cards.max_cards_per_order` | luku | 10 | kokonaisluku 1–30 | Ei. |
| Voimassaolo | `gift_card_packages.valid_months` | vain yhteenveto | 6 kk | Ei uutta yhteistä avainta. | Ei, ellei avoin kysymys muuta. |
| Johku-kortit | `gift_cards.johku_cards_redeemable` | vain tila | pois | Ei muokata. | Ei. |
| Kumppanikoodit verkossa | `voucher_claims.enabled` | vain tila | pois | Ei muokata. | Ei. |
| Ongelmaviestit | `voucher_claims.problem_emails_enabled` | vain tila | pois | Ei muokata. | Ei. |
| Kumppanikoodi kuitille | `voucher_claims.partner_voucher_accounted` | vain tila | pois (ei kuittia) | Ei muokata. | Ei. |
| Pyyntöjä yhdessä tilauksessa | `voucher_claims.max_per_order` | luku | 10 | kokonaisluku 1–30 | Ei. |
| Muistutus, kun pyyntö on vanha | `voucher_claims.remind_after_hours` | luku + tuntia | 24 | kokonaisluku 1–720 | Ei. |

### Laskut

| Kenttä | Avain | Tyyppi | Oletus | Validointi | Uutta koodia |
|---|---|---|---|---|---|
| Eräpäivä | `invoice_due_days` | luku + päivää | 14 | kokonaisluku 1–90 | Ei. |
| IBAN | `invoice_bank.iban` | teksti | tyhjä | Suomalainen IBAN, välit sallitaan. Tyhjä sallitaan, kunnes tili on tiedossa. | Ei uutta avainta. |
| BIC | `invoice_bank.bic` | teksti | tyhjä | 8 tai 11 merkkiä, tai tyhjä. | Ei. |
| Pankin nimi | `invoice_bank.name` | teksti | tyhjä | 0–80. | Ei. |
| Lähetys Procountoriin | `invoice_dispatch_mode` | vain tila | harjoitusajo | Ei muokata. | Ei. |
| Kuittisarjat | `receipt_series` | vain tila | K, H, L | Ei muokata. | Ei. |

## Uudet asiat ja mitä ne vaativat

Ei uusia `booking.settings`-avaimia, ellei allekirjoituksesta päätetä toisin.

| Ehdotus | Tarvitaanko tietokantamuutos | Tarvitaanko koodia |
|---|---|---|
| Korttikohtainen tallennus ja suomenkieliset kentät | Ei uusia avaimia. `seller` ja `invoice_bank` pysyvät JSON-objekteina. | Kyllä. Uusi hallintakutsu ja uusi `settings.js`. Vanha avainlista poistuu näkymästä. |
| Live-, testi- ja allowlist-tilat vain lukuina | Ei. | Visma Payn tilaa ei vaihdeta (`admin_set_vismapay_mode` ei ole sivulla). Procountorin tila, ympäristö ja päiväkirjaus lähtevät tallennuksessa nykyisinä arvoina. Varauskalenterin tilan pääkäyttäjä valitsee Varaukset-kortissa. |
| Lähettäjän nimi ja vastausosoite | Ei uutta avainta. Kirjoitus `integration_config.resend.settings`. | Kyllä. Uusi kutsu, joka ei koske tilaan eikä `test_recipients`-listaan. |
| Hallinnan maksutapojen kytkimet | Ei. Sarake `payment_methods.active` on olemassa. | Kyllä. Uusi kutsu. Käteinen pysyy hylättynä. |
| Allekirjoitus Tapio muokattavaksi | Vain jos niin päätetään: uusi avain `email_sign_name` tai nykyisten sivutekstien muokkaus. | Kyllä, pohjat lukevat nyt kiinteää tekstiä. Ei toteuteta ennen päätöstä. |
| Oma taukoviesti | Ei nykyisellään. Kaupassa on jo valmis lause ja puhelinnumero. | Vain jos halutaan eri teksti. Silloin sivuteksti tai uusi avain, ja kaupan muutos. |
| Henkilökuntaviesti uudesta varauksesta | Ei ole. | Iso uusi polku. Ei tähän uudistukseen. |
| Yksi voimassaolo kaikille lahjakorteille | Ei, jos yhteenveto riittää. | Vain jos paketikohtainen 6 kk hylätään. |
| Asiakkaan oma peruutusaika | Ei avainta. Vahvistettua ei peruta itse. | Iso muutos varausmoottoriin. Ei tähän, ellei päätetä toisin. |
| Puskuri vuorojen väliin | Ei sovi nykyiseen vuoromalliin. | Vuorosäännöt, ei asetuskytkin. |

## Vain luku, myös pääkäyttäjältä

Näitä ei saa tehdä kytkimiksi eikä pudotusvalikoiksi hallinnassa:

- Visma Payn tila (`off` / `dry_run` / `test` / `live`)
- MobilePayn tila (`off` / `test` / `live`)
- Procountorin tila, ympäristö (`pts` / `prod`) ja päiväkirjaus. Tilikartta, ALV-tila, pyöristys, pankkitili ja `api_prefix` ovat pääkäyttäjän lomakkeella.
- Sähköpostin lähetystila ja vastaanottajarajaus (`test_recipients`)
- Laskun lähetystila Procountoriin (`invoice_dispatch_mode`)
- Maksutila `public_payment_mode`
- `pay_later_test_enabled`
- Johku-lahjakorttien lunastus
- Kumppanikoodien verkkolunastus, ongelmaviestit ja se, tuleeko niistä kuitti
- Google-kalenterin tila Yhteydet-välilehden yhteenvedossa. Tunnus ja tila (`off` / `dry_run` / `live`) ovat Varaukset-välilehden kortissa, vain pääkäyttäjälle. Käyttöönotto 26.10.
- Saunabot
- Kuittisarjojen kirjaimet
- Sivuston osoite ja polut
- Aikavyöhyke

Vanhat kutsut `admin_set_vismapay_mode`, `admin_set_procountor_settings` ja `admin_set_booking_calendar` jäävät tietokantaan, koska aiemmat testit ja mahdollinen vanha selainistunto tuntevat ne. Uusi sivu ei kutsu niitä. Live-tilaa ei vaihdeta tästä näkymästä.

QR-tarrat pysyvät kenellä on `pos.use`. Muu sivu vaatii `settings.edit`.

## Miltä sivu tuntuu

- Kortteja, joilla on otsikko ja lyhyt ohje. Ei avaimia.
- Yksi Tallenna kortin lopussa. Nappi on koko rivin levyinen puhelimella.
- Kytkin on rivin oikeassa reunassa, kosketuskoko vähintään 44 pikseliä. Vieressä lukee, mitä päällä ja pois tarkoittavat.
- Luvun perässä on yksikkö (päivää, tuntia, minuuttia), ei erillistä ihmettelyä.
- Testi, harjoitusajo ja puuttuva tieto käyttävät hallinnan nykyisiä varoitus- ja ok-värejä (`admin.css`).
- Virhe tulee kentän alle suomeksi, ei tietokannan avaimena.
- Luonnos käyttää samaa hallinnan CSS:ää (`booking/admin/admin.css`): hiekka tausta, tumma vihreä palkki, kortit, pill-välilehdet, alapalkki alle 900 px.

Luonnos: [`docs/mockups/asetukset.html`](mockups/asetukset.html). Avaa se selaimessa. Välilehdet vaihtuvat. Tallenna ei kirjoita mihinkään. Kuvat puhelimen leveydellä: [etusivu](mockups/asetukset-etusivu.png), [varaukset](mockups/asetukset-varaukset.png), [maksut](mockups/asetukset-maksut.png).

Esimerkkitilat luonnoksessa (Visma Pay ja MobilePay testissä, Procountor pois, sähköposti harjoitusajossa) on valittu siksi, että varoitus näkyy. Oikea sivu lukee kannan tilan. Jos tuotannossa yhteys on pois, kortissa lukee pois.

## Avoimet kysymykset

Vain päätökset, jotka muuttavat lomaketta tai sitä, mitä asiakas kokee. Tekniikkaa ei kysytä.

1. **Tauko.** Kun verkkovaraus laitetaan pois, asiakas näkee jo lauseen "Verkkovaraus ei ole tällä hetkellä käytössä" ja puhelinnumeron. Riittääkö se, vai tarvitaanko oma viesti (esimerkiksi huolto)?
2. **Peruutus.** Asiakas voi muuttaa vahvistettua varausta 48 tuntia ennen alkua, mutta ei perua sitä itse. Peruutus tulee sähköpostilla. Säilytetäänkö tämä?
3. **Ajat.** Ovatko nämä oikein: savusauna 120 päivää eteenpäin, hoidot 14 päivää, hoito viimeistään 2 tuntia ennen alkua, muutos viimeistään 48 tuntia ennen?
4. **Iso ryhmä.** Alustava varaus ilman heti maksua on nyt pois (kynnys 0). Otetaanko se käyttöön, ja millä henkilömäärällä?
5. **Lahjakortin voimassaolo.** Kaikilla paketeilla on 6 kuukautta. Yksittäiselle kortille voi hallinnan myynnissä antaa 1–12 kuukautta. Halutaanko yksi yhteinen aika vai paketikohtainen?
6. **Henkilökunnan posti.** Tarjouspyyntö lähtee osoitteeseen savusauna@saunotus.fi, tervehdys Joonas. Uudesta verkkovarauksesta ei lähde erillistä viestiä henkilökunnalle. Riittääkö tarjouspyyntö?
7. **Allekirjoitus.** Lähtevissä viesteissä lukee Tapio. Vaihdetaanko nimi asetuksesta, vai jääkö Tapio?
8. **Kuka saa muokata y-tunnusta, ALV-tunnusta ja laskun IBAN-tiliä?** Nyt sekä pääkäyttäjä että ylläpitäjä (Otto, Laura). Rajataanko pankki ja y-tunnus vain pääkäyttäjälle?

## Päätökset

Nämä on lukittu toteutukseen. Peruste on se, ettei sivulle tule kytkintä, jota koodi ei lue, ja ettei vaarallista tilaa voi vaihtaa puhelimella.

1. **Tauko.** Oma viestiä ei lisätä. Kaupassa on jo lause "Verkkovaraus ei ole tällä hetkellä käytössä" ja puhelinnumero. Pois kytkeminen kysyy vahvistuksen.
2. **Peruutus.** Nykyinen käytös säilyy. `customer_change_hours_before` on vain muutosaika. Vahvistettua varausta asiakas ei peru itse. Uutta peruutusaikaa ei lisätä, koska se vaatisi varausmoottorin muutoksen.
3. **Ajat.** Oletukset säilyvät ja kentät jäävät muokattaviksi: savusauna 120 päivää, hoidot 14 päivää, hoidon varoaika 120 minuuttia, muutos 48 tuntia. Puskuria vuorojen väliin ei lisätä. Vuoron oma takaraja jää vuorosääntöön.
4. **Iso ryhmä.** Kynnys jää oletuksena nollaan (pois). Kentät ovat yhä muokattavissa. Kynnys on lomakkeella 0–100.
5. **Lahjakortin voimassaolo.** Aika pysyy paketilla (`gift_card_packages.valid_months`). Sivulla on vain yhteenveto. Uutta yhteistä avainta ei ole.
6. **Henkilökunnan posti.** Vain nykyinen tarjouspyynnön osoite ja tervehdysnimi. Uudesta varauksesta ei lähde erillistä viestiä, eikä sellaista kytkintä lisätä.
7. **Allekirjoitus.** Jää Tapio, sivuteksteihin `email.*.sign_name`. Asetusta `email_sign_name` ei lisätä, koska lähetys ei lukisi sitä.
8. **Oikeudet.** Y-tunnus, ALV-tunnus ja laskun tili pysyvät oikeudella `settings.edit` (pääkäyttäjä ja ylläpitäjä). Tekninen välilehti on vain roolille admin. Maksun live-tila, Procountorin tila, ympäristö ja päiväkirjaus sekä sähköpostin vastaanottajarajaus ovat vain luku kaikille, myös pääkäyttäjälle. Procountorin tilikartan ja varauskalenterin käyttöönoton (`off` / `dry_run` / `live`, tunnus, esikatselu) tallentaa vain pääkäyttäjä. Kalenteri otetaan käyttöön 26.10.

Uusia `booking.settings`-avaimia ei ole. `seller` ja `invoice_bank` pysyvät JSON-objekteina ja lomake jakaa ne kenttiin. Kuittilogo ja tuntemattomat kentät säilyvät tallennuksessa. Paikan pito kirjoittaa saman luvun myös vanhaan `hold_minutes`-avaimeen, jotta kaksi pitoaikaa ei erkane. Käteistä ei voi laittaa päälle.
