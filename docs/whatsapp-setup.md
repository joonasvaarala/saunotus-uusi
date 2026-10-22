# WhatsApp-lähettäjä vuorotarjouksille

Tämä ohje on Joonakselle. Tässä haarassa ei deployata edge-funktiota, ei ajeta migraatiota tuotantoon eikä lähetetä yhtään viestiä.

Lähettäjä on Meta WhatsApp Business Cloud API (`POST https://graph.facebook.com/v25.0/{WHATSAPP_PHONE_NUMBER_ID}/messages`). Viestit ovat hyväksyttyjä Utility-mallipohjia suomeksi. Henkilökunta vastaa linkistä, ei WhatsAppin pikavastauksesta. Linkki avaa saman sivun kuin ennen (`shift-offer-engine`): GET näyttää Hyväksy / Kieltäydy / Palaan asiaan -lomakkeen eikä täytä vuoroa.

Mallipohjat ovat tiedostossa [`docs/whatsapp-templates.json`](whatsapp-templates.json). Lähetyskoodi käyttää samoja nimiä ja samaa muuttujajärjestystä.

| Jonon `kind` | Mallipohja | Mitä viestissä on |
| --- | --- | --- |
| `offer`, `reminder` | `vuorotarjous` | rooli, ajankohta, vastausaika, URL-painike |
| `filled` | `vuoro_taytetty` | vuoro on täytetty |
| `cancelled` | `tarjous_peruttu` | hoidot-sulku perui tarjouksen |
| `exhausted_ask`, `alert` | `joonas_tyhja_vuoro` | tyhjä vuoro, ilmoituksen numero tai sana hälytys, URL-painike |

URL-painikkeen kiinteä alku on `https://sxbofnuisemspgquoxyv.supabase.co/functions/v1/shift-offer-engine?token=` ja dynaaminen loppu on allekirjoitettu vastauspoletti (ei koko osoitetta).

## Salaisuuksien nimet

Nämä neljä annetaan Supabasen edge-funktion ympäristöön. Niitä ei kirjoiteta repoon, migraatioon eikä chattiin.

| Nimi | Mistä arvo tulee |
| --- | --- |
| `WHATSAPP_TOKEN` | System userin pysyvä poletti (ei API Setup -sivun noin vuorokauden poletti) |
| `WHATSAPP_PHONE_NUMBER_ID` | WhatsAppin API Setup -sivun Phone number ID, pelkkä numerosarja, ei puhelinnumero |
| `WHATSAPP_APP_SECRET` | Sovelluksen App settings → Basic → App secret. Webhookin `X-Hub-Signature-256` tarkistetaan tällä |
| `WHATSAPP_VERIFY_TOKEN` | Itse keksitty pitkä satunnainen merkkijono. Sama arvo Metan webhook-lomakkeeseen |

Lisäksi vastauslinkki tarvitsee jo aiemmin sovitun holvisalaisuuden `shift_offer_token_secret` (Vault, ei edge-ympäristö). Ilman sitä painikemallit eivät lähde: rivi jää jonoon ja `last_error` on `no_token`.

Paikka Supabasessa: projekti Tapio-havuhattu (`sxbofnuisemspgquoxyv`) → Edge Functions → Secrets. Tai myöhemmin, kun deploy on tarkoitus tehdä: `supabase secrets set --project-ref sxbofnuisemspgquoxyv`. Älä laita arvoja komentorivin historiaan jaettuun lokiin, jos et halua niiden jäävän talteen.

## Mitä Metassa tehdään

Käyttöliittymän nimet liikkuvat. Oliot ovat samat: Business-portfolio, sovellus, WhatsApp-tuote, puhelinnumero, näyttönimi, system user, mallipohja, webhook.

1. **Business-portfolio.** Avaa [business.facebook.com](https://business.facebook.com). Käytä olemassa olevaa portfoliota tai luo uusi yritykselle (esimerkiksi Sipoonjoen Perinnesauna). Settings → Business info: virallinen nimi, osoite ja verkkosivu `https://uusi.saunotus.com` tai se osoite, jonka Meta saa tarkistaa.

2. **Sovellus.** Avaa [developers.facebook.com/apps](https://developers.facebook.com/apps) → Create app. Valitse käyttötapaukseksi WhatsApp, jos se on listalla. Muuten tyyppi Business. Lisää tuotteeksi WhatsApp, jos se ei tullut mukana.

3. **Puhelinnumero, joka ei ole WhatsApp-sovelluksessa.** WhatsApp → API Setup → Add phone number. Numero ei saa olla rekisteröitynä WhatsApp- tai WhatsApp Business -puhelinsovellukseen. Jos on: puhelimessa WhatsApp → Asetukset → Tili → Poista tili, odota, ja rekisteröi numero vasta sitten Cloud APIin. Vahvistuskoodi tulee tekstiviestinä tai puheluna. Kirjaa talteen **Phone number ID** (`WHATSAPP_PHONE_NUMBER_ID`) ja WhatsApp Business Account ID. Älä käytä tältä sivulta Temporary access tokenia.

4. **Näyttönimi.** WhatsApp Manager → puhelinnumero → Profile → Display name. Lähetä nimi, jonka henkilökunta saa nähdä keskustelun ylälaidassa, esimerkiksi Sipoonjoen Perinnesauna. Nimen pitää vastata yritystä. Odota tila Approved. Hylättyä nimeä ei kannata kiertää vaihtamalla kirjainta.

5. **Yrityksen vahvistus.** Business settings → Security Center → Start verification. Meta pyytää yrityksen asiakirjan. Ilman vahvistusta viestejä voi lähettää vain numeroihin, jotka on lisätty sovelluksen testivastaanottajiksi. Henkilökunnan pilotille vahvistus tarvitaan.

6. **System user ja pysyvä poletti.** Business settings → Users → System users → Add. Rooli Admin. Add assets: tämä sovellus ja WhatsApp-tili, täydet oikeudet. Generate token. Valitse poletti, joka ei vanhene. Oikeudet: `whatsapp_business_messaging` ja `whatsapp_business_management`. Kopioi poletti heti talteen. Se on `WHATSAPP_TOKEN`. Sitä ei näytetä uudelleen.

7. **App secret.** App settings → Basic → App secret → Show. Se on `WHATSAPP_APP_SECRET`.

8. **Verify token.** Keksi pitkä satunnainen merkkijono (esimerkiksi `openssl rand -hex 32`). Se on `WHATSAPP_VERIFY_TOKEN`. Sama merkkijono kohtaan 10.

9. **Mallipohjat.** WhatsApp Manager → Account tools → Message templates → Create template. Neljä pohjaa, jokaiselle:
   - Category: **Utility**. Älä anna Metan vaihtaa luokkaa Marketingiksi, jos se kysyy (`allow_category_change` JSON-tiedostossa on false).
   - Language: **Finnish** (`fi`).
   - Name: täsmälleen `vuorotarjous`, `vuoro_taytetty`, `tarjous_peruttu` tai `joonas_tyhja_vuoro`.
   - Body: teksti tiedostosta `docs/whatsapp-templates.json`. Muuttujat ovat `{{1}}`, `{{2}}`, `{{3}}`. Esimerkkiarvot ovat samassa tiedostossa. Älä jätä muuttujaa lauseen alkuun tai loppuun. Teksti on jo kirjoitettu niin.
   - Footer: `Tapio`.
   - Painike vain pohjissa `vuorotarjous` ja `joonas_tyhja_vuoro`: tyyppi Visit website / URL, teksti `Avaa vastaus`, osoite  
     `https://sxbofnuisemspgquoxyv.supabase.co/functions/v1/shift-offer-engine?token={{1}}`  
     Esimerkkiloppu: `esimerkkitoken`. Oikea lähetys laittaa loppuun poletin, jossa on yksi piste (`payload.allekirjoitus`). Esimerkissä pistettä ei ole, jotta Managerin esikatselu pysyy yksinkertaisena.
   - Lähetä kaikki neljä. Odota tila **Approved**. Ennen sitä oikeaa lähetystä ei tehdä. Hylkäys näkyy Managerissa; tekstiä ei muuteta repossa ennen kuin uusi versio on sovittu, koska lähettäjä olettaa tämän muuttujajärjestyksen.

   Saman JSON-rivin voi myös POSTata Graphiin `/{WHATSAPP_BUSINESS_ACCOUNT_ID}/message_templates`, kun poletilla on `whatsapp_business_management`. Manager riittää.

10. **Webhook.** Tämä toimii vasta, kun edge-funktio on deployattu. Callback URL:

    `https://sxbofnuisemspgquoxyv.supabase.co/functions/v1/shift-offer-engine/webhook`

    Verify token: sama kuin `WHATSAPP_VERIFY_TOKEN`. Paina Verify and save. Subscribe-kentäksi **messages** (toimitus-, luettu- ja virhetilat tulevat samassa kentässä). Saapuvia pikavastauksia ei käsitellä. Vastaus tapahtuu linkistä.

11. **Sovellus Live-tilaan**, kun vahvistus ja näyttönimi ovat kunnossa. Development-tilassa Meta välittää viestin vain numeroille, jotka on lisätty API Setup -sivun testivastaanottajiksi. Pilottiin lisättävät henkilöt pitää joko lisätä sinne tai sovelluksen pitää olla Live.

## Tietokanta ja kytkimet

Tuotannossa moottorin migraatio on versio `20261022003917`, WhatsApp-migraatio `20261022013104` ja tarkennus `20261022014510`. Repon tiedostot on nimetty samoiksi, jotta niitä ei ajeta uudelleen. Ajamatta ovat vastaussivu `booking/supabase/migrations/20261022022221_shift_offer_response_page.sql` ja bot-kanava `booking/supabase/migrations/20261022024547_shift_offer_bot_channel.sql`.

Joonas ja Otto eivät saa vuoroviestejä WhatsAppilla. Heidän `public.staff.bot_channel` on true ja `whatsapp_enabled` pysyy false, vaikka sen yrittäisi kytkeä päälle. Uloslähtevä rivi on kanavalla `bot` ja tilassa `bot_channel`. Lähettäjä ei poimi sitä eikä soita Metalle.

Kun se myöhemmin ajetaan, tauluun `public.shift_offer_engine_settings` tulee:

| Sarake | Oletus | Merkitys |
| --- | --- | --- |
| `sender_enabled` | `false` | Yleinen kytkin. Pois: jonoa ei käsitellä. |
| `whatsapp_enabled` | `false` | Kanavakytkin. Pois: Metalle ei soiteta. |
| `whatsapp_dry_run` | `true` | Päällä: lokiin kirjoitetaan tarkka JSON-runko, Metalle ei soiteta. |
| `whatsapp_allow_staff_ids` | tyhjä lista | Vain nämä `public.staff.id`-arvot voivat saada oikean viestin. |

Oikea lähetys vaatii kaikki neljä: `sender_enabled = true`, `whatsapp_enabled = true`, `whatsapp_dry_run = false` ja henkilön id listalla. Lisäksi `public.staff.whatsapp_enabled` pitää olla päällä ja numeron pitää normalisoitua. Tyhjä lista ei lähetä kenellekään, vaikka muut olisivat päällä.

Kuivaharjoitus (kolme ensimmäistä päällä, `whatsapp_dry_run` vielä true) lokittaa peitetyn rungon tapahtumaan `whatsapp_dry_run`. Mallin tekstimuuttujat näkyvät. Puhelinnumero on muodossa `+358*******67` ja URL-painikkeen poletti on `***`. Sama peitetty runko tallennetaan sarakkeeseen `last_payload`. Authorization-otsaketta ei lokiteta. Rivi jää jonoon (`last_error = dry_run`) eikä saa `wamid`-tunnusta. Sarakkeessa `to_address` on edelleen oikea E.164-numero.

Numero luetaan lähetyksessä uudelleen `public.staff.phone_e164`-sarakkeesta. `040 123 4567`, `0401234567`, `358401234567` ja `+358401234567` kelpaavat ja niistä tulee `+358401234567`. Vain suomalainen matkapuhelin (alku 4 tai 50). Lankapuhelin ei kelpaa.

WhatsApp-kanava vaatii sekä kelvollisen numeron että `public.staff.whatsapp_enabled = true`. Allowlist on tämän lisäksi: opt-in ilman listaa ei lähetä, eikä lista ilman opt-inia lähetä.

- Opt-in ja numero → kanava `whatsapp`.
- Numero ilman opt-inia, sähköposti löytyy → kanava `email`.
- Vain sähköposti → kanava `email`. WhatsApp-lähettäjä ei koske näihin riveihin eikä merkitse niitä epäonnistuneiksi. Sähköpostilähetystä ei ole tässä muutoksessa.
- Ei numeroa eikä sähköpostia → tila `failed_no_contact`. Riviä ei poisteta. Mona on nyt tässä ryhmässä: hänellä ei ole puhelinta eikä sähköpostia. Lisää numero sarakkeeseen `phone_e164`, laita `whatsapp_enabled` päälle ja lisää id allowlistalle, niin seuraava uusi viesti voi lähteä. Jo `failed_no_contact`-tilaan merkittyä riviä ei lähetetä uudelleen.

Henkilö, joka ei ole allowlistalla, jää jonoon (`last_error = not_allowlisted`) eikä saa viestiä. Kun id lisätään listaan, rivi yritetään uudelleen noin 15 minuutin kuluessa.

Virhe 5xx tai 429 yritetään uudelleen viiveellä `yritykset²` minuuttia, enintään kahdeksan kertaa, sitten tila `failed`. Muu 4xx ei yritä uudelleen. Kun rivillä on `wamid`, sitä ei lähetetä toista kertaa. Webhook päivittää tilan `delivered` tai `read`. `read` ei peruudu. Jos rivi on `sending` eikä `wamid` ole tallessa 10 minuutin jälkeen, tilaksi tulee `unknown` ja `last_error` on `unknown_delivery`. Riviä ei palauteta jonoon eikä lähetetä uudelleen. Se pitää tarkistaa käsin: katso Metasta, lähtiikö viesti, ja päätä rivi itse. Webhook ei siirrä `unknown`-riviä. Kun `wamid` on kannassa, toista lähetystä ei tehdä.

Roolien `shift_offer_settings.enabled` on eri kytkin. WhatsAppin kytkeminen ei laita tarjouksia liikkeelle, eikä tarjousten laittaminen päälle lähetä WhatsAppia, jos lähettäjä on pois.

## Järjestys, kun tämä halutaan käyttöön

Tätä ei tehdä tässä haarassa.

1. Mergeä tämä PR.
2. Aja vain `20261022022221_shift_offer_response_page.sql` ja `20261022024547_shift_offer_bot_channel.sql`, jos vastaussivu ja bot-kanava halutaan käyttöön. Älä aja uudelleen `20261022003917`, `20261022013104` tai `20261022014510` äläkä sääntösiementä.
3. Laita neljä `WHATSAPP_*`-salaisuutta edge-ympäristöön. Varmista holvin `shift_offer_token_secret`.
4. `supabase functions deploy shift-offer-engine --project-ref sxbofnuisemspgquoxyv`. `verify_jwt` pysyy false: tick tunnistaa `x-sync-secret`, webhook allekirjoituksen, vastauslinkki poletin.
5. Tee Metassa webhookin Verify and save ja tilaa `messages`.
6. Lähetä neljä mallipohjaa ja odota Approved.
7. Täytä `public.staff.phone_e164` ja laita `public.staff.whatsapp_enabled` päälle vain niille, jotka saavat WhatsAppin.
8. Lisää pilottiin otettavien id:t `whatsapp_allow_staff_ids`-listaan.
9. Laita `sender_enabled` ja `whatsapp_enabled` päälle, jätä `whatsapp_dry_run` päälle. Katso funktion lokista `whatsapp_dry_run`-tapahtuma. Siinä on peitetty runko (numero ja poletti eivät näy), eikä Metaa ole kutsuttu.
10. Sammuta `whatsapp_dry_run` vasta, kun yksi oikea lähetys on tarkoitus tehdä. Cron-ehdotus on funktion kommentissa; sitä ei ole luotu.

Jonon tila:

```sql
select id, staff_id, kind, channel, status, last_error, attempts, wamid
  from public.shift_offer_messages
 order by id desc;
```
