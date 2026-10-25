# Visma Pay -integraatio (Paybyway REST w3.2)

Tila 21.10.2026. Tämä on käyttöönotto-ohje. Tuotantotietokantaan ei ole koskettu, eikä tähän tiedostoon tai repoon ole laitettu avaimia. Rajapinta: [Visma Pay web payments](https://www.vismapay.com/docs/web_payments/). Testikortit: [testing](https://www.vismapay.com/docs/web_payments/?page=testing).

Testi ja tuotanto käyttävät **samaa osoitetta** `https://www.vismapay.com/pbwapi`. Ero on kauppiasavaimissa, ei palvelimen nimessä. Migraatio ei kytke testiä eikä tuotantoa päälle: `integration_config.key = vismapay` jää tilaan `off`.

## Mitä koodi tekee

1. Asiakas painaa tilaussivulla Visma Payta (tai juomakioski valitsee verkkomaksun). Edge `vismapay-start` kutsuu `auth_payment` (summa senteissä, ei tuoterivejä). ALV jää meidän `payment_lines`-riveille ja K-kuitille.
2. Asiakas ohjataan vain osoitteeseen `https://www.vismapay.com/pbwapi/token/{token}`.
3. Paluu tulee edgeen `vismapay-return`, ilmoitus edgeen `vismapay-notify`. Molemmat tarkistavat MAC:n (HMAC-SHA256, yksityinen avain, heksa isoilla kirjaimilla). Selainpaluu ei yksin merkitse tilausta maksetuksi.
4. Vahvistus kysyy `get_payment`. Jos tila on vielä valtuutettu (status 1), kutsutaan `capture` ja haetaan maksu uudelleen. Maksetuksi merkitään vain kun tila on 4, 5 tai 15 ja summa senteissä täsmää. Silloin `payment_mark_paid` tekee K-kuitin kuten muissakin maksuissa. Summan erotus ei merkitse maksetuksi eikä epäonnistuneeksi: tila on `amount_mismatch` ja se vaatii tarkistuksen.
5. Jos ilmoitus jää tulematta, tilaussivu kutsuu `vismapay-notify` toiminnolla `reconcile` (sama `get_payment` / `check_payment_status`).
6. Hallinnan hyvitys (`/hallinta/`, talous → tilaus) luo `admin_refund`-rivin ja edge `vismapay-refund` kutsuu `create_refund`. Kun Visma hyväksyy, syntyy H-kuitti. Lahjakortin oston täysi hyvitys peruu kortit samalla tavalla kuin MobilePayssa.

`dry_run` ei lähetä HTTP-kutsua eikä tee kuittia (kioskin paikallinen testi). `off` ei näytä painiketta.

## Salaisuudet

Aseta vain Supabasen Edge Function -salaisuuksiin (Dashboard → Edge Functions → Secrets). Älä commitoi arvoja.

| Nimi | Milloin |
|---|---|
| `VISMAPAY_TEST_API_KEY` | Testitila. Pakollinen testissä. |
| `VISMAPAY_TEST_PRIVATE_KEY` | Testitila. Pakollinen testissä. |
| `VISMAPAY_LIVE_API_KEY` | Tuotanto. Ensisijainen. |
| `VISMAPAY_LIVE_PRIVATE_KEY` | Tuotanto. Ensisijainen. |
| `VISMAPAY_API_KEY` | Vain tuotannon varanimi, jos `VISMAPAY_LIVE_API_KEY` puuttuu. |
| `VISMAPAY_PRIVATE_KEY` | Vain tuotannon varanimi, jos `VISMAPAY_LIVE_PRIVATE_KEY` puuttuu. |

Testitila **ei** lue tuotannon avaimia. w3.2 ei tarvitse erillistä merchant id -salaisuutta; `api_key` yksilöi kauppiaan. `VISMAPAY_*_MERCHANT_ID` ei ole käytössä.

`SUPABASE_URL` on jo olemassa. Siitä rakennetaan paluu- ja ilmoitusosoitteet (vain https):

- `{SUPABASE_URL}/functions/v1/vismapay-return`
- `{SUPABASE_URL}/functions/v1/vismapay-notify`

Ilmoitusosoite lähtee jokaisessa `auth_payment`- ja `create_refund`-kutsussa. Erillistä portaaliin koodattua notify-osoitetta ei tarvita, kunhan Visma hyväksyy kutsussa annetun https-osoitteen (oletusportti).

## Käyttöönotto (testi)

1. Aja migraatio `booking/supabase/migrations/20261021121725_booking_120_vismapay.sql`. Se ei vaihda tilaa pois `off`-tilasta.
2. Aseta testisalaisuudet.
3. Julkaise edge-funktiot: `vismapay-start`, `vismapay-return`, `vismapay-notify`, `vismapay-refund`.
4. Tuo tekstit tiedostosta `content/site-texts.pending-import-28.json` (FI+EN). Ennen tuontia kauppa ja hallinta käyttävät koodin oletustekstejä.
5. Kytke testitila. Hallinta → Asetukset → Maksut → Visma Pay, tila **Testi**, hyväksyjä esim. `Nimi 2026-10-21`. Tai SQL (ylläpitäjä):

```sql
update booking.integration_config
set mode = 'test',
    settings = settings || jsonb_build_object('approved_by', 'Nimi 2026-10-21')
where key = 'vismapay';
```

Ilman `settings.approved_by` testi ja tuotanto hylätään (BK001, `approval_required`).

6. Pyydä Vismalta `create_refund` käyttöön testikauppiaalle. Ilman sitä hyvitys palauttaa virheen ja rivi jää jonoon, ei H-kuittia.
7. Tee testitilaus ja maksa testikortilla. Kuitti on sarjaa K. Hyvitä hallinnasta koko summa ja toinen tilaus osittain. Hyvityskuitti on sarjaa H.

Maksulinkki sähköpostissa on yhä `settings.payment_link_path` (oletus `/maksa/?p=`). Sitä polkua ei ole tässä repossa. Kun Visma-painike näkyy tilaussivulla, geneeristä linkkiä ei näytetä. Linkin voi osoittaa suoraan edgeen vaihtamalla asetuksen (älä vaihda oletuspolkua migraatiolla):

`{SUPABASE_URL}/functions/v1/vismapay-start?p=<link_token>`

## Testikortit

Mikä tahansa tuleva vanhenemispäivä ja mikä tahansa kolminumeroinen CVV. Lähde: Visma Payn testaussivu.

Onnistuu:

| Kortti | Huomio |
|---|---|
| 4012888888881881 | Visa |
| 5244024870672677 | Mastercard |
| 378748900392307 | American Express |
| 36319163670450 | Diners |

Epäonnistuu (maksua ei merkitä maksetuksi):

| Kortti | Tulos |
|---|---|
| 4400000000000008 | tuntematon |
| 4484070000000000 | koodi 04 |
| 4462030000000000 | koodi 05 |
| 4900000000000003 | koodi 51 |
| 4900000000000011 | koodi 54 |
| 4900000000000086 | koodi 61 |
| 4917610000000000 | koodi 62 |
| 4917300800000000 | koodi 1000, aikakatkaisu |

Pankkipainikkeet testissä: Nordea voi hyväksyä tai perua, Osuuspankki hyväksyy aina.

Testitilassa kauppa näyttää huomion, että kyse on testikortista. Painiketta ei piiloteta.

## Tuotanto: oma kortti ja hyvitys

1. Aseta `VISMAPAY_LIVE_API_KEY` ja `VISMAPAY_LIVE_PRIVATE_KEY` (tai varanimet).
2. Varmista että Visma on sallinut `create_refund` myös tuotantokauppiaalle.
3. Hallinnassa tila **Tuotanto** ja hyväksyjä, tai:

```sql
update booking.integration_config
set mode = 'live',
    settings = settings || jsonb_build_object('approved_by', 'Nimi 2026-10-21')
where key = 'vismapay';
```

4. Tee pieni oikea varaus ja maksa omalla kortilla. Tarkista että tilaus on maksettu ja K-kuitti syntyi.
5. Hallinta → Talous → tilaus → Hyvitä. Syyn pituus 3–500 merkkiä. Oikeus `payments.refund`. Tee ensin täysi hyvitys tälle pienelle maksulle. Toisella pienellä maksulla voit kokeilla osittaista summaa. Tarkista H-kuitti ja että Visma näyttää hyvityksen.
6. Jos et jatka tuotantoa heti, palauta tila `off` samasta näkymästä.

Kesken oleva maksu muistaa luontihetken ympäristön (`raw.env`). Ilmoitus käyttää sen ympäristön avaimia, vaikka tila ehditään vaihtaa. Hyvitysjonoon jäänyt rivi ei lähde Vismaan, kun tila on `off` tai `dry_run`; se lähtee kun tila on taas `test` tai `live`.

## Kirjanpito

Kassaperuste ennallaan. Maksu → K-kuitti (`K-{vuosi}-{juokseva}`). Hyvitys → H-kuitti (`H-{vuosi}-{juokseva}`), rivit hyvityksen `lines`-kentästä. Lahjakortin lunastuskuitti L ei muutu. ALV-kannat eivät muutu. Johku- ja ulkoiset tilaukset eivät lähde Vismaan.

## Edge-funktiot

| Funktio | verify_jwt | Kuka kutsuu |
|---|---|---|
| `vismapay-start` | ei | Kauppa, juomakioski, maksulinkki `?p=` |
| `vismapay-return` | ei | Asiakkaan selain Visma Paysta |
| `vismapay-notify` | ei | Visma (GET) ja tilaussivun tilatarkistus (POST) |
| `vismapay-refund` | kyllä | Hallinta, käyttäjän JWT ja oikeus `payments.refund`, tai service role |

## Peruutus

1. Aseta tila `off` hallinnasta tai SQL:llä. Avoimet hyvitykset jäävät jonoon eivätkä lähde Vismaan.
2. Aja `booking/supabase/rollbacks/20261021121725_booking_120_ROLLBACK.sql`. Se palauttaa tilan `off`, jos se oli `test` tai `live`, ja palauttaa vanhat RPC:t. `dry_run` jätetään `dry_run`-tilaan.
3. Vanhat edge-funktiot voi jättää julkaistuksi: ilman uusia RPC:itä ne eivät merkitse maksua maksetuksi. Halutessa julkaise edellinen versio funktioista `vismapay-start`, `vismapay-notify` ja `vismapay-refund`, ja poista `vismapay-return`.

Rollbackin jälkeen verkkomaksu on taas poissa. Jo syntyneitä K- ja H-kuitteja rollback ei poista.
