# Viestit (booking_121)

Tuotekohtaiset asiakasviestit hallinnan osiossa **Viestit**. Oikeus on `messages.edit` (admin ja manager). Henkilökunta (`staff`) ei näe osiota eikä voi tallentaa.

Viestipohja ei ole sivuteksti. Asiakkaalle näkyvä sisältö on taulussa `booking.messages`. Sivutekstit (`content/site-texts.pending-import-29.json`) ovat vain tilaussivun ja sähköpostin kiinteitä otsikoita.

## Tietomalli

`booking.messages`

| Kenttä | Merkitys |
|---|---|
| `name` | Nimi hallinnassa (1–120 merkkiä). Ei lähde asiakkaalle. |
| `category` | `instruction` (Ohje), `after_marketing` (Jälkimarkkinointi) tai `feedback` (Palautepyyntö). |
| `subject_fi` / `subject_en` | Aihe. Englanti puuttuu → käytetään suomea. |
| `short_fi` / `short_en` | Vain ohjeella. Lyhyt teksti tilausvahvistuksessa. |
| `body_fi` / `body_en` | Ohjeen täysi teksti tilaussivulla. Muissa luokissa sähköpostin teksti. |
| `link_url` | Vapaaehtoinen `https`-osoite, enintään 500 merkkiä. Paikkamerkki `{linkki}`. |
| `active` | Käytössä. Oletus pois. Passiivinen ei näy tilaussivulla eikä lähde. |
| `send_amount`, `send_unit`, `send_direction`, `send_anchor` | Ajastus. Kaikki neljä tai ei yhtään. |

`booking.message_products` on monesta moneen (`message_id`, `product_id`). Yksi viesti voi koskea monta tuotetta, ja yhdellä tuotteella voi olla monta viestiä. Tilauksesta lähtee **yksi sähköposti viestiä kohti**, ei yhtä tuotetta kohti.

Tuotteet osuvat tilaukseen, kun tuotteen tunniste on vahvistamattomassa piilotetussa varauksessa (`reservations.product_id`, `hidden_at` on tyhjä) tai tilausrivillä (`order_items.product_id`, `kind` on `reservation` tai `product`).

Asetus `booking.settings.messages.timed_enabled` on jsonb-boolean. Oletus `false`. Se ei näy yleisessä Asetukset-listassa. Kytkin on Viestit-sivulla.

Migraatio lisää kolme **pois päältä** olevaa esimerkkipohjaa nimellä `[ESIMERKKI EI KÄYTÖSSÄ] …`. Niillä ei ole tuotteita. Ajastus ei käsittele niitä.

Viestiä ei poisteta. Se otetaan pois käytöstä.

## Mitä asiakas näkee

- **Ohjeen lyhyt teksti** lisätään tilausvahvistukseen (`order_confirmation`), kun viesti on käytössä, se on kytketty tilauksen tuotteeseen ja lyhyt teksti ei ole tyhjä. Tämä ei riipu ajastuskytkimestä. Usea ohje = usea lohko samassa viestissä, kukin kerran. Otsikko on sivuteksti `email.order_confirmation.instructions_title` (Ohje / Instructions).
- **Ohjeen täysi teksti** tulee tilaussivulle (`/tilaus/`) osioon Ohjeet. Tekstit ovat kiinni, kunnes asiakas painaa **Näytä ohjeet**.
- Lyhyt ohje, täysi ohje ja sähköpostin teksti voivat olla pelkkää tekstiä tai kapeaa rich-tekstiä (lihavointi, kursivointi, otsikko, luettelo, linkki). Vanha pelkkä teksti näytetään ennallaan. Puhdistus ja sähköposti: [rich-text.md](rich-text.md).
- **Jälkimarkkinointi ja palautepyyntö** lähtevät vain ajastettuna lajina `product_message`. Ohjeelle voi lisäksi asettaa ajastuksen (esimerkiksi muistutus 2 päivää ennen saapumista). Ajastettu ohje käyttää täyttä tekstiä ja tilauslinkkiä.
- Jos viestillä on https-linkki, sähköpostiin tulee painike. Tilaussivun ohjeessa linkki on tekstin alla.

## Markkinointilupa ja peruutus

Kenttä on jo olemassa: `customers.marketing_consent` (oletus `false`), plus `marketing_unsubscribed_at` ja `unsubscribe_token` (booking_02). Uutta suostumuskenttää ei lisätä.

- **Jälkimarkkinointi** lähtee vain, kun tilauksella on asiakas ja `marketing_consent` on tosi. Muuten jonoon kirjoitetaan `skipped` ja syy `no_consent`. Päätös on pysyvä tälle tilaus–viesti-parille: myöhempi luvan antaminen ei lähetä samaa viestiä uudestaan.
- Tilaus ilman asiakasta ei ole suostumustapaus. Sille pätee yhä syy `no_email`.
- **Ohje ja palautepyyntö ovat palveluviestejä.** Ne eivät katso lupaa eikä niissä ole peruutuslinkkiä. Lyhyt ohje vahvistuksessa ei myöskään katso lupaa.
- Jälkimarkkinoinnin loppuun lisätään automaattisesti linkki `site_base_url` + tilaussivun polku + `?u=` + `unsubscribe_token` (englanniksi `/en/order/`). Se ei ole paikkamerkki, joten pohjan kirjoittajan ei tarvitse muistaa sitä. Linkki vaatii `site_base_url`-asetuksen https-osoitteeksi, samaan tapaan kuin tilauslinkki.
- Linkki avaa tilaussivun, joka kutsuu `booking.public_marketing_unsubscribe`. Funktio asettaa `marketing_consent = false`, täyttää `marketing_unsubscribed_at` ja merkitsee saman asiakkaan jonossa olevat jälkimarkkinointirivit (`pending` / `failed`) tilaan `skipped`, syy `unsubscribed`. Toinen avaus onnistuu eikä muuta jo peruttua lupaa. Ohje ja palautepyyntö jäävät jonoon.
- Lähetyshetkellä `send-emails` tarkistaa luvan vielä uudestaan. Jos asiakas peruutti sen jälkeen, kun rivi ehdittiin jonottaa, viestiä ei lähetetä (`ei markkinointilupaa`). Allowlist tarkistetaan yhä ensin.

## Paikkamerkit

Samat nimet suomeksi ja englanniksi. Hallinta listaa ne lomakkeessa.

| Merkki | Arvo |
|---|---|
| `{asiakas_nimi}` | Asiakkaan koko nimi. |
| `{tilaus_linkki}` | Sama tilaussivun osoite kuin vahvistuksessa: `site_base_url` + `order_page_path` + `?t=` + tilauksen tunniste. Uutta osoitetta ei keksitä. |
| `{tuote}` | Niiden osumien nimet, joihin tämä viesti on kytketty. Englanninkielisessä viestissä `name_en`, jos se on annettu. |
| `{saapumisaika}` | Näiden varausten alkuajat, Europe/Helsinki, `pp.kk.vvvv tt:mm`, pilkulla erotettuna. |
| `{linkki}` | Viestin https-linkki. Tyhjä, jos kenttä on tyhjä tai osoite ei ole https. |

Tuntematon aaltosulku jää tekstiin. Tunnettu merkki, jolle ei ole arvoa, vaihtuu tyhjään.

Teksti täytetään **lähetyshetkellä** elävästä pohjasta. Muokkaus ennen lähetystä näkyy viestissä. Jos pohja on lähetyshetkellä pois käytöstä, `send-emails` ohittaa rivin.

## Ajastus

Muoto: määrä (1–3650) + yksikkö (`minutes` / `hours` / `days`) + suunta (`before` / `after`) + vertailukohta.

- `booking` = `orders.created_at` (tilaus luotu).
- `arrival` = varauksen `starts_at`. Ennen = aikaisin osuva vahvistettu tai toteutunut varaus. Jälkeen = myöhäisin. Vain viestiin kytketyt tuotteet, ei piilotettuja.

**Päivä on 24 tuntia**, ei kalenteripäivä (`make_interval(hours => määrä * 24)`). Kesä- ja talviajan vaihto ei siirrä kellonaikaa eri tavalla kuin 24 tunnin jakso.

Päätös (`booking._message_decision`):

| Syy | Mitä tapahtuu |
|---|---|
| `external_import` | Johku- tai muu tuontitilaus (`external_source` ei ole tyhjä). Ei lähetetä. |
| `order_status` | Tila ei ole `confirmed` tai `completed`. Peruttu, vanhentunut, luonnos ja odottava eivät lähde. Odotus ei saa ohitusriviä, jotta vahvistus voi vielä laukaista ajastuksen. |
| `refunded` | `payment_status = refunded`. Ei lähetetä. `partially_refunded` lähtee yhä. |
| `no_consent` | Vain jälkimarkkinointi, kun asiakas on olemassa ja `marketing_consent` ei ole tosi. Ohitus kirjoitetaan heti. |
| `no_timing` / `invalid_timing` | Ajastus puuttuu tai ei kelpaa. |
| `no_arrival` | Vertailukohta on saapuminen, mutta osuvaa varausta ei ole. |
| `missed_at_booking` | Lähetyshetki on jo mennyt tai sama kuin tilauksen luonti. **Ei lähetetä heti.** Ohjeen lyhyt teksti on jo vahvistuksessa. Esimerkki: varaus tehdään huomenna, mutta muistutus on asetettu kahdeksi päiväksi ennen saapumista. |
| `not_due` | Hetki on tulevaisuudessa. Riviä ei kirjoiteta. Seuraava minuutti katsoo uudestaan. |
| `too_late` | Hetki on yli 36 tuntia myöhässä. Ohitetaan, jotta kytkimen avaaminen ei lähetä vanhoja viestejä. |
| `due` | Hetki on nyt tai enintään 36 tuntia myöhässä, ja se on tilauksen luonnin jälkeen. Lähtee heti. |

Yksi päätös tilausta ja viestiä kohti. Kun rivi on jonossa, ajastuksen muuttaminen ei lähetä samaa viestiä uudestaan. Avain on `product_message:<viesti>:<tilaus>`.

## Lähetys ja kytkin

`booking.messages_dispatch()` ajetaan pg_cron-työllä `booking_messages_dispatch` kerran minuutissa (`* * * * *`), jos `pg_cron` on asennettu. Funktio vain jonottaa. Uutta edge-funktiota ei ole.

Kytkin pois: funktio palauttaa 0 eikä kirjoita jonoon.

Kytkin päällä:

- Lähetys kulkee `booking._enqueue_email`-funktion kautta lajina `product_message`. Resendin tila (`off` / `dry_run` / `live`) ja allowlist **eivät muutu**. `off` merkitsee rivin `skipped` kuten muutkin viestit. `dry_run` renderöi eikä lähetä. `live` lähettää, ja epätyhjä testivastaanottajalista ohittaa listan ulkopuoliset ennen renderöintiä.
- Pysyvä ohitus kirjoitetaan heti tilaan `skipped` ja `last_error`-kenttään syy, jotta sitä ei yritetä uudestaan.
- Jos osoite puuttuu, rivi on `skipped` ja syy `no_email`.
- Kerralla enintään 50 riviä (katto 200). Lähetykset käsitellään ennen ohituksia, jotta vanha ohitusjono ei pidättele ajallaan olevaa viestiä.
- Tilaus saa olla enintään 18 kuukautta vanha.
- `send-emails` tarkistaa vielä lähetyshetkellä, että pohja on käytössä, tila on lähetettävissä, maksu ei ole kokonaan hyvitetty ja teksti ei ole tyhjä. Tämä tarkistus on allowlistin jälkeen.

## Tilaussivun lisämyynti

Lisäpalvelu (`upsell.addons`), jonka voi lisätä tähän tilaukseen, käyttää entistä lomaketta (`public_add_to_order`, tyyppi addon). Ohjeet ja lisäyslomake ovat vierekkäin leveällä näytöllä ja päällekkäin kapealla.

Hoito- tai muu `public_slots`-tuote (`upsell.treatments`) näytetään nimellä. Ajan valinta tapahtuu yhä varauskalenterin linkistä. **Ajan valinta olemassa olevalle tilaukselle ei ole rakennettu.** Palvelin osaa lisätä varausrivin, mutta tilaussivulla ei ole vuorovalitsinta.

## Käyttöönotto

1. Aja migraatio `booking/supabase/migrations/20261021140000_booking_121_messages.sql` (versio booking_121). Älä aja tätä tuotantoon tästä reposita ilman tavallista julkaisua.
2. Julkaise edge-funktio `send-emails` uudelleen (malli ja ohitus). Cron-työ syntyy migraatiossa, jos `pg_cron` on käytössä. Nimi: `booking_messages_dispatch`.
3. Tuo sivutekstit tiedostosta `content/site-texts.pending-import-29.json` (28 riviä, 14 avainta × fi/en).
4. Kirjoita pohjat hallinnassa, kytke tuotteet ja ota pohja käyttöön. Esimerkkipohjat eivät kelpaa asiakkaille.
5. Kytke **Ajastetut viestit päällä** vasta, kun pohjat on tarkistettu. Ennen sitä ajastus ei jonota mitään. Lyhyt ohje vahvistuksessa toimii jo, kun pohja on käytössä.

Peruutusskripti: `booking/supabase/rollbacks/20261021140000_booking_121_ROLLBACK.sql`. Se poistaa `product_message`-jonorivit, palauttaa `public_get_order`- ja `email_outbox_claim`-funktiot ja poistaa taulut.
