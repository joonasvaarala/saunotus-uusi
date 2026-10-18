# Procountor-liitäntä (Havuhattu Oy / Sipoonjoen Perinnesauna)

Tila 18.10.2026. Tämä tiedosto on selvitys julkisesta Procountor API -dokumentaatiosta ja tämän repon adapterin sopimus. Tuotantotietokantaan, tuotantoon tai oikeisiin tunnuksiin ei ole koskettu. Tunnuksia ei ole repossa.

Merkinnät:

- **Varmistettu** = luettu julkisesta lähteestä. Lähde on linkkinä.
- **Oletus** = tämän repon valinta tai tulkinta, jota dokumentaatio ei vahvista. Ei keksittyjä API-kenttiä: pyynnöissä käytetään vain OpenAPI-skeeman kenttiä.

OpenAPI haettiin 18.10.2026 osoitteesta `https://pts-api.procountor.com/api/openapi.json` (title: Procountor API 26.10).

## 1. Autentikointi

**Varmistettu** ([M2M](https://dev.procountor.com/m2m-authentication/), [API authentication](https://dev.procountor.com/api-authentication/), [yleistietoa](https://dev.procountor.com/general-information/)):

- Koneellinen yhteys on OAuth2 **client credentials**.
- `POST {origin}/api/oauth/token`, runko `application/x-www-form-urlencoded`: `grant_type=client_credentials`, `client_id`, `client_secret`, `redirect_uri`, `api_key`.
- Vastaus: `access_token` ja `expires_in` (esimerkissä 3600 sekuntia). M2M-esimerkissä ei ole `refresh_token`-kenttää. Refresh token kuuluu authorization code -virtaan. Token uusitaan hakemalla uusi client-credentials-token samalla API-avaimella.
- API-avain on sidottu käyttäjään, yritykseen ja clientiin (JWT:n `cid`). Erillistä company id -salaisuutta nykyinen M2M-virta ei pyydä.
- `redirect_uri` on pakollinen myös client-credentials-kutsussa, ja sen pitää täsmätä rekisteröityyn osoitteeseen.
- Client-credentials-tokenilla ei voi kutsua 2FA-päätepisteitä.
- Tuotanto: `https://api.procountor.com`. Julkinen testi (PTS): `https://pts-api.procountor.com` (käyttöliittymä `https://pts-secure.procountor.com/procountor/`). Testi ei lähetä sähköpostia eikä tee pankkiyhteyksiä. Testikäyttö on maksutonta. Testi- ja tuotantoavaimet ovat eri avaimet.

**Oletus:**

- Vanhemmissa esimerkeissä esiintyvä issuer `api-test.procountor.com` ei ole sama asia kuin `pts-api.procountor.com`. Adapteri käyttää vain `pts-api` (kun ympäristö ei ole `prod`) ja `api.procountor.com` (kun `environment=prod`). Muu arvo on PTS, ei tuotanto.
- Asetuksista ei lueta vapaata base URL -osoitetta.
- Tokenia ei tallenneta tietokantaan. Välimuisti on vain funktion muistissa, ja se vanhenee `expires_in` miinus 60 sekuntia.
- Repo ei käytä salaisuutta `PROCOUNTOR_COMPANY_ID`. Vanha maininta company id:stä on vanhentunut tämän M2M-virran osalta.

Edge-salaisuuksien nimet (arvoja ei ole repossa):

- `PROCOUNTOR_CLIENT_ID`
- `PROCOUNTOR_CLIENT_SECRET`
- `PROCOUNTOR_API_KEY`
- `PROCOUNTOR_REDIRECT_URI`

Jos yksikin puuttuu, live-tilakin jää dry_run-tilaan ja `last_error` on `credentials_missing`.

## 2. Rajapinnan versio

**Varmistettu** ([getting started](https://dev.procountor.com/getting-started/), [API requests](https://dev.procountor.com/api-requests/)):

- `/api` ja `/latest/api` = uusin kuukausiversio.
- `/supported/api` = uusin tuettu neljännesvuosiversio.
- `/vYYMM/api` = kiinnitetty versio.

**Oletus:** oletusetuliite on `/supported/api` (`integration_config.settings.api_prefix`). Sallitut arvot ovat vain nuo neljä muotoa. Tuntematon arvo palautuu `/supported/api`-etuliitteeseen.

## 3. Päivittäinen myyntikirjaus

Kassaperusteinen luku on jo repossa: `booking._report_json(p_from, p_to, false, false)` (booking_41). Adapteri ei laske ALV:ia uudelleen. Johku jää raportin ulkopuolelle (`booking._acct_excluded`).

Käytetyt kentät:

- `totals.receipts`, `totals.refund_receipts`, `totals.rounding`
- `unreceipted.payments`
- `by_vat[]`: `rate`, `net`, `vat`, `gross` (hyvityskuitin luvut ovat jo negatiivisia)
- `by_method[]`: `method`, `gross`, `refunds`, `rounding` (maksutavan netto = `gross + refunds`)

Pyöristys ei ole `by_vat`-taulukossa.

**Varmistettu** (OpenAPI `LedgerReceipt`, `Transaction`, `POST /ledgerreceipts`):

- Tosite luodaan `POST /ledgerreceipts`. Kyselyparametri `createReconciliation=true` luo täsmäytysrivin automaattisesti. ALV-rivin `accountingValue` on netto; Procountor laskee veron `vatPercent`-kentästä, joten sentin erotus on mahdollinen.
- Pakolliset kentät: `type`, `name`, `receiptDate`, `transactions`, `vatType` (`PURCHASE`|`SALES`), `vatStatus` (kokonaisluku).
- `type` POST-kutsussa on `JOURNAL`.
- `status` on read-only. Uusi tosite syntyy tilaan `UNFINISHED`. Tilaa ei voi asettaa APIlla. Adapteri tallentaa `status: UNFINISHED` omaan pyyntöön, mutta **ei lähetä** sitä Procountoriin.
- Tapahtuman pakolliset kentät: `transactionType` (`ENTRY`|`REVERSING_ENTRY`|`RECONCILIATION_ENTRY`), `account` (oltava tilikartassa, `GET /coa`), `accountingValue`, `vatPercent`.
- `REVERSING_ENTRY` ja `RECONCILIATION_ENTRY`: `vatPercent` pitää olla 0, ja kumpaakin saa olla enintään yksi. Ilman reversing-riviäkin tosite on sallittu.
- `vatStatus` on Procountorin ALV-oletuskoodin numero-osa (`vat_12` → `12`). Oikea koodi haetaan `GET /vats/default` ja `GET /vats/settings`. Sitä ei kovakoodata.

**Oletus:**

- `vatType` on `SALES`, koska kyse on myynnistä. OpenAPI-esimerkki käyttää myös arvoa `PURCHASE`.
- Tapahtuman `description` on oma teksti (`Maksutapa …`, `Myynti ALV …`, `Käteispyöristys`). Kenttä on skeemassa, teksti ei ole Procountorin vaatimus.
- Selvittely- ja pyöristysrivit ovat ensin. Niistä ensimmäinen on `REVERSING_ENTRY` (`vatPercent` 0). Myyntirivit ovat aina `ENTRY`, `accountingValue` = raportin neton vastaluku, `vatPercent` = raportin kanta.
- Maksutaparivin `accountingValue` = `gross + refunds`, `vatPercent` 0.
- Pyöristysrivi, jos `totals.rounding <> 0`: `accountingValue` = pyöristyksen vastaluku, `vatPercent` 0.
- Tilit tulevat asetuksesta, eivät koodista:
  - `settings.vat_status` (1–4 numeroa)
  - `settings.accounts.sales_by_vat` avaimena kannan teksti (`25.5`, `13.5`, `0`)
  - `settings.accounts.clearing_by_method` avaimena maksutavan koodi (`card_terminal`, `cash`, `mobilepay`, …)
  - `settings.accounts.rounding`
- Jos tili, `vat_status`, täsmäytys (`|sum(by_vat.gross) − sum(method gross+refunds)| > 0,05`) tai kuittiton maksu (`unreceipted.payments > 0`) puuttuu, tila on `needs_review` eikä POST-kutsua tehdä. Puuttuva tili tallentuu pyyntöön arvona `null`, jotta aukko näkyy.
- Tyhjä päivä (ei kuitteja eikä hyvityskuitteja, eikä kuittittomia maksuja) → `skipped`. Rivi jää, jotta samaa päivää ei yritetä uudelleen tyhjänä.
- Kuittiton maksu ilman kuitteja → `needs_review`, syy `unreceipted`.
- Sama päivä ei kirjaudu kahdesti: `dedupe_key = daily:YYYY-MM-DD` ja osittainen uniikki-indeksi `(business_date) where kind = daily_sales`. Tila `sent` palauttaa `already`.
- Päivä pitää olla mennyt Helsingin päivä. Tyhjä parametri ottaa vanhimman epäonnistuneen 14 päivän sisältä (alle 8 yritystä), muuten eilisen.
- `processing`-lukko 15 minuuttia. Neuvontalukko `pg_advisory_xact_lock(77261018, päivä)` (kaksiosainen lukko on int4, int4).
- Kun päivä on `sent`, myöhempi kuitti samalle päivälle ei lähde uudelleen. Se jää ihmisen tarkistettavaksi.

ALV-kannat repossa (booking_29): aktiiviset 0, 13,5 ja 25,5. Historialliset ei-aktiiviset 10, 14 ja 24.

**Varmistettu** Verohallinto, luettu 18.10.2026 ([arvonlisäveroprosentit](https://www.vero.fi/yritykset-ja-yhteisot/verot-ja-maksut/arvonlisaverotus/arvonlisaveroprosentit/), [alennetun kannan muutos](https://www.vero.fi/tietoa-verohallinnosta/uutishuone/verotuksen_muutoksia/alv-kannan-aleneminen/)): yleinen kanta 25,5 %. Alennettu kanta oli 14 % 31.12.2025 asti ja on 13,5 % alkaen 1.1.2026. 10 % jäi sanoma- ja aikakauslehdille; yleisradiotoiminta siirtyi 13,5 %:iin. **Oletus:** saunapalvelu on yleisellä kannalla 25,5 %, ellei kirjanpitäjä toisin määrää. Adapteri ei päätä tuotteen kantaa; se käyttää kuitin raporttia.

Maksutavat, jotka siemen on luonut: `cash`, `card_terminal`, `mobilepay`, `bank_transfer`, `invoice`, `gift_card`, `partner_voucher`, `visma_pay`, `annual_card`, `other`. Selvittelytili pitää olla jokaiselle kannalle, jolla päivänä on nettoa.

## 4. Laskun välityksen sopimus

Toinen agentti rakentaa `booking.invoices`, `booking.invoice_lines`, hallinnan, PDF:n ja sähköpostin. Tämä adapteri ei luo niitä. Se tarjoaa kaksi funktiota:

- `buildProcountorInvoice(invoice, { vatStatus, bankAccount })` → `{ ok, errors, blockers, channel, request }`
- lähetys: `POST procountor-sync` rungolla `{ "action": "send_invoice", "idempotency_key": "...", "invoice": { ... } }`

Edge-funktio tarkistaa otsikon `x-sync-secret` (`booking._cron_secret_ok`). Funktio on vain `service_role`-kutsuttavissa tietokannassa; selaimelle ei ole anon-oikeutta.

### 4.1 Normalisoitu JSON

```json
{
  "customer": {
    "name": "Havuhattu Oy",
    "business_id": "3018112-1",
    "vat_id": "FI30181121",
    "einvoice_address": "003708369224",
    "einvoice_operator": "003723327487",
    "email": "lasku@example.test",
    "address": { "street": "Saunatie 1", "zip": "04130", "city": "Sipoo", "country": "FI" }
  },
  "number": "L-100",
  "date": "2026-10-01",
  "due_date": "2026-10-15",
  "reference": "26013",
  "currency": "EUR",
  "lines": [
    { "description": "Saunavuoro", "quantity": 2, "unit": "kpl", "unit_price_net": 40, "vat_rate": 25.5 }
  ],
  "notes": "Lisätieto"
}
```

`idempotency_key` on rungon vieressä, ei laskuobjektin sisällä. Sallittu muoto: `^[A-Za-z0-9._:-]{1,120}$`. Tietokanta-avain on `invoice:` + avain.

### 4.2 Kenttäkartta Procountoriin

**Varmistettu** OpenAPI-skeemoista `Invoice`, `CounterParty`, `InvoiceCounterpartyAddress`, `InvoiceBillingAddress`, `ExtraInfo`, `PaymentInfo`, `BankAccount`, `EInvoiceAddress`, `InvoiceRow`:

| Meidän kenttä | Procountor | Huomio |
|---|---|---|
| — | `type` | aina `SALES_INVOICE` |
| — | `status` | tallennetaan `UNFINISHED`, ei lähetetä (read-only; uusi lasku on aina UNFINISHED) |
| `date` | `date` | `YYYY-MM-DD` |
| — | `language` | **oletus** `FINNISH` (myyntilaskulla pakollinen; enum DANISH, ENGLISH, ESTONIAN, FINNISH, NORWEGIAN, SWEDISH) |
| — | `discountPercent` | 0 |
| kanava | `invoiceChannel` | `EMAIL` tai `ELECTRONIC_INVOICE`. `EDIFACT` ja `PAPER_INVOICE` eivät ole sallittuja POST/PUT-kutsuissa. |
| `settings.vat_status` | `vatStatus` | ei tule lasku-JSONista. Puuttuva arvo on este (`blockers`), ei arvaus. |
| `customer.name` | `counterParty.counterPartyAddress.name` | pakollinen |
| `customer.business_id` | `counterParty.identifier` | **varmistettu** kuvaus: business ID |
| `customer.vat_id` | `counterParty.taxCode` | **oletus**: skeeman kuvaus on "Tax code of the customer" |
| `customer.email` | `counterParty.email` | pakollinen kun kanava on EMAIL |
| `customer.einvoice_address` + `einvoice_operator` | `counterParty.einvoiceAddress.address` ja `.operator` | molemmat pakollisia Suomen verkkolaskulle. `ediId` ei täytetä. |
| osoite | `counterParty.counterPartyAddress` ja verkkolaskulla myös `billingAddress` | street, zip ja city pakollisia kanavalla ELECTRONIC_INVOICE (skeeman kuvaus) |
| `customer.address.country` | `country` | alias FI/fin/Finland/Suomi → `FINLAND`. Muu iso kirjain- ja alaviivaketju välitetään sellaisenaan. Tuntematon muoto on virhe. Puuttuva maa → **oletus** `FINLAND`. |
| — | `extraInfo.accountingByRow` | **oletus** `false` |
| — | `extraInfo.unitPricesIncludeVat` | **oletus** `false`, koska hinta on `unit_price_net` |
| rivi `description` | `invoiceRows[].product` | vapaa teksti. `productId` ei aseteta, tuoterekisteriä ei luoda. |
| `quantity` | `quantity` | äärellinen luku, ei nolla |
| `unit` | `unit` | kpl/pcs → `PIECE`, tunti/hour → `HOUR`, min → `MINUTE`, henkilö → `PERSON`, päivä → `DAY`. Puuttuva → **oletus** `PIECE`. Tuntematon → virhe `unknown_unit`. |
| `unit_price_net` | `unitPrice` | |
| — | `discountPercent` | 0 |
| `vat_rate` | `vatPercent` | 0–100. Procountor vaatii kannan, joka on yrityksellä käytössä. |
| `number` | `originalInvoiceNumber` | ei koskaan `invoiceNumber` (read-only, Procountor numeroi) |
| `reference` annettu | `paymentInfo.bankReferenceCode` | pitää olla kelvollinen viite, jonka viimeinen merkki on tarkiste. Adapteri ei laske tarkistetta. |
| `reference` puuttuu | `bankReferenceCode: ""` | **varmistettu**: tyhjä merkkijono = Procountor generoi viitteen. Kentän pois jättäminen = ei viitettä. |
| — | `paymentInfo.paymentMethod` | `BANK_TRANSFER` |
| — | `paymentInfo.currency` | vain `EUR` (**oletus**; muu valuutta on virhe) |
| — | `paymentInfo.currencyRate` | 1 |
| `due_date` | `paymentInfo.dueDate` | eräpäivä ennen laskupäivää → virhe `due_before_date` (Procountorin koodi `DUE_DATE_BEFORE_BILL_DATE`) |
| `settings.bank_account` | `paymentInfo.bankAccount.accountNumber` | IBAN ilman välilyöntejä. Pakollinen, koska `BANK_TRANSFER` vaatii olemassa olevan tilin. Puuttuva tili on este. IBANia ei näytetä hallinnassa. |
| `notes` | `additionalInformation` | näkyy laskulla. Skeeman `notes` ei näy laskulla, sitä ei käytetä. |

Kanava:

1. Sekä `einvoice_address` että `einvoice_operator` → `ELECTRONIC_INVOICE`.
2. Vain toinen niistä → virhe `einvoice_incomplete` (ei vaihdeta sähköpostiksi).
3. Muuten kelvollinen `email` → `EMAIL`.
4. Muuten virhe `channel_missing`. Kanavaa `MAIL` ei arvata.

Virheellinen lasku (400) ei luo vientiriviä. Asetuseste (`vat_status`, `bank_account`) luo rivin tilaan `needs_review`.

### 4.3 Lähetysjärjestys

**Varmistettu:**

- Uusi lasku on `UNFINISHED`.
- `PUT /invoices/{invoiceId}/approve` hyväksyy. Myyntilaskun kommentti ohitetaan (OpenAPI). Runko on tyhjä objekti (`CheckingEvent.comment` ei ole pakollinen).
- `PUT /invoices/{invoiceId}/send` lähettää vain tiloissa `NOT_SENT` ja `SENT`.
- `NO_SENDING` hyväksyttynä on `APPROVED` eikä lähde. Tätä kanavaa ei käytetä.

**Oletus:** approve ja send eivät vaadi 2FA:ta. Jos PTS-testi palauttaa 403 2FA-vaatimuksen takia, M2M-token ei voi lähettää. Se on avoin kysymys (kohta 8).

Keskeytys: laskun id ja `step` (`created` | `approved` | `sent`) tallennetaan tilaan `processing` ennen seuraavaa kutsua. Uusi yritys ei tee toista POST-kutsua, jos id on jo tallessa. Verkkovirhe tai 5xx ilman id:tä → `needs_review` (`post_unconfirmed`), ei automaattista uutta POST-kutsua.

Kun rivi on `sent`, sama avain palauttaa `already` eikä pyyntöä korvata.

Maksetuksi merkintää (`PUT /invoices/{id}/paymentevents/markpaid`) tämä rajapinta ei kutsu. Normalisoidussa JSONissa ei ole maksettua-lippua. Laskun tilaa `PAID` ei voi asettaa APIlla; sen tekee tiliote. `MARKED_PAID` ja `PARTLY_PAID` ovat eri tiloja ([statukset](https://help.procountor.fi/en/articles/532423-sales-invoice-statuses-in-the-procountor-api)).

## 5. Verkkolasku ja sähköposti

**Varmistettu:**

- Verkkolasku Suomessa: `counterParty.einvoiceAddress.operator` ja `.address` ([EInvoiceAddress](https://pts-api.procountor.com/api/openapi.json)).
- Katu, postinumero ja kaupunki vaaditaan sekä `billingAddress`- että `counterPartyAddress`-osoitteessa, kun kanava on `ELECTRONIC_INVOICE`.
- Kumppanin laskutustiedoissa on erilliset kentät `invoicingInfo.einvoiceAddress`, `einvoiceOperator`, `ovt`, `identifier`, `identifierType` (merkkijono, ei enumia). Ohje-esimerkissä operaattori `003723327487` ja osoite `003708369224` ([lähetysohje](https://help.procountor.fi/en/articles/531855-sales-invoice-how-to-send-sales-invoices-via-finago-procountor-api)).
- Y-tunnus on asiakkaan tunniste. OVT-tunnus on verkkolaskuosoite (usein `0037` + Y-tunnus ilman väliviivaa). Adapteri ei kopioi verkkolaskuosoitetta kenttiin `ovt` tai `ediId`.
- Sähköpostikanava `EMAIL` vaatii `counterParty.email`. Procountor lähettää laskun. `GET /invoices/{id}/image` palauttaa vain PNG/JPG/JPEG, ei PDF:ää.

**Oletus / ei varmistettu:**

- Dokumentaatio ei sano, että EMAIL-kanavan viestissä on PDF-liite. Adapteri ei lataa omaa PDF:ää Procountoriin eikä väitä liitettä.
- Finvoice-aineiston muodostaa Procountor kanavalla `ELECTRONIC_INVOICE`. Emme rakenna Finvoice-XML:ää itse.
- Ulkomainen verkkolasku (etuliite 9999, tyhjä operaattori, vain tuotanto) ei ole toteutettu.

## 6. Asiakasrekisteri

**Varmistettu** (`GET/POST /businesspartners`, skeemat `BusinessPartner`, `InvoicingInfo`, `BusinessPartnerPaymentInfo`):

- Haku: `name` ja `identifier` ovat HTTP-otsikoita, eivät kyselyparametreja. `type` on kysely (`CUSTOMER`|`SUPPLIER`|`PERSON`). Vastaus `results[].id`.
- Luonti vaatii `name`, `type`, `paymentInfo.paymentMethod`. Osoite on kuvattu asiakkaalle vaadituksi.
- Laskun `partnerId` on valinnainen. Vastapuolen tiedot pitää silti olla laskulla.

**Oletus (toteutus):**

- Haku vain `business_id`-otsikolla `identifier`, `type=CUSTOMER`. Nimeä ei haeta (osuma on alimerkkijono).
- 0 osumaa ja katu+postinumero+kaupunki olemassa → `POST` tyyppi `CUSTOMER`, `paymentInfo.paymentMethod=BANK_TRANSFER`.
- `invoicingInfo.identifierType` = `FI` vain kun tunniste näyttää suomalaiselta Y-tunnukselta `NNNNNNN-N`. OpenAPI ei anna identifierType-enumia. Haku-esimerkin arvo on `FN`; ohjeartikkelin esimerkki on `FI`. Käytämme `FI`:tä vain Y-tunnukselle.
- Useampi osuma → ei linkitystä, varoitus `partner_ambiguous`, lasku jatkuu ilman `partnerId`.
- Luonti tai haku epäonnistuu → varoitus, lasku jatkuu ilman `partnerId`.
- Ilman Y-tunnusta kumppania ei luoda.

## 7. Rajoitukset, virheet, tietoturva

**Varmistettu:**

- Tuotanto: 60 pyyntöä/s / client (ylitys voi sulkea avaimen). Julkinen testi: 90 pyyntöä/min / client ([yleistietoa](https://dev.procountor.com/general-information/)).
- Validointikoodit: [validation error codes](https://dev.procountor.com/api-reference/validation-error-codes/). Virheen muoto `{ "errors": [{ "status", "message" }] }`.
- Idempotency-Key-otsikkoa ei ole dokumentoitu. Idempotenssi on tietokannan uniikki avain.

**Toteutus:**

- POST/PUT uudelleen vain HTTP 429, kerran. 401 tyhjentää tokenin ja yrittää kerran uudelleen. 400 ei uudelleenyritä. 5xx ja verkkokatko eivät luo toista tositetta automaattisesti.
- `booking.accounting_exports`: RLS-luku vain `settings.edit` (admin ja ylläpitäjä/manager). Ei anon- eikä public-oikeutta. Kirjoitus vain service-funktioilla, jotka hylkäävät roolit `anon` ja `authenticated`.
- `admin_procountor_status` vaatii `settings.edit`. Se palauttaa tilan, ympäristön, onko päiväajo päällä, onko tilit ja pankkitili asetettu (boolean), viimeisen ajon ja enintään 8 virhettä. Ei pyyntörunkoa, ei raporttia, ei tilinumeroita, ei IBANia, ei salaisuuksia.
- `procountor_export_mark` hylkää vastauksen, jonka tekstissä on `client_secret`, `api_key` tai `access_token`.
- Ajastus `booking_procountor_daily` klo 04:20 (`20 4 * * *`) kutsuu `booking.procountor_daily_dispatch()`. Funktio palaa heti, jos `mode = off` tai `daily_enabled` ei ole `true`. Kutsu on `net.http_post` osoitteeseen `functions_base_url || '/procountor-sync'`, otsikko `x-sync-secret` = vault-salaisuus `calendar_sync_cron_secret` (sama kuin send-emails).

Taulun tilat: `pending`, `processing`, `dry_run`, `sent`, `failed`, `skipped`, `needs_review`.

## 8. Mitä Joonaksen pitää hankkia

Konkreettinen lista. Arvoja ei kirjoiteta repoon eikä chattiin.

1. Procountor API -käyttöoikeus Havuhattu Oy:n ympäristöön (API-lisäosa; hinnoittelu Procountorin hinnaston mukaan, ei vahvistettu tähän).
2. Kehittäjärekisteröinti ja PTS-testiympäristö: [getting started](https://dev.procountor.com/getting-started/).
3. API-client: `client_id`, `client_secret` ja täsmälleen sama `redirect_uri`.
4. Tekninen API-käyttäjä yrityksessä ja sille API-avain (Basics → New API key). Avain on eri PTS:ssä ja tuotannossa.
5. Tilikartta (`GET /coa`) ja päätös tileistä: myynti kannoittain 25,5 / 13,5 / 0, selvittelytili jokaiselle käytetylle maksutavalle, käteispyöristyksen tili. Numerot asetetaan `integration_config.settings.accounts`-objektiin, ei salaisuudeksi.
6. ALV-tilakoodin numero (`GET /vats/default`) kenttään `settings.vat_status`.
7. Yrityksen pankkitili Procountorissa ja sen IBAN kenttään `settings.bank_account` (vain laskujen välitykseen).
8. Verkkolaskuoperaattorin tunnus ja oma verkkolaskuosoite, kun verkkolaskuja lähetetään.
9. Edge-salaisuudet nimillä kohdassa 1. `daily_enabled` ja `mode=live` vasta PTS-testin jälkeen.
10. Vahvistus, että `functions_base_url` osoittaa funktioihin ja että cron-job `booking_procountor_daily` on olemassa (se ei tee mitään ennen kohtia 5–9).

## 9. Avoimet kysymykset

- Oikea `vat_status`-numero ja tilinumerot. Testikoodi `1` testeissä ei ole Havuhatun tilikartta.
- Vaatiiko `PUT /invoices/{id}/send` tai approve 2FA:n. Jos vaatii, M2M ei voi lähettää.
- Sisältääkö EMAIL-kanava PDF-liitteen. Image-päätepiste ei palauta PDF:ää.
- Onko `api-test.procountor.com` jossain sopimuksessa vielä käytössä. Adapteri ei käytä sitä.
- Päivä, joka on jo `sent`, ei päivity, vaikka samalle päivälle tulisi kuitti jälkikäteen.
- Kuittiton maksettu maksu estää päivän (`needs_review`).
- Asiakaslaskun kirjanpitotilejä ei tässä versiossa päivitetä (`PUT /ledgerreceipts` laskulle). Procountor käyttää omia oletustilejään.
- `identifierType`-arvo `FI` on oletus Y-tunnukselle. OpenAPI ei lukitse enumia.

## 10. Repon tiedostot

- `booking/supabase/migrations/20261018230000_booking_77_procountor_exports.sql` — taulu, RLS, asetuksen `daily_enabled=false` ja `api_prefix`.
- `booking/supabase/migrations/20261018231000_booking_78_procountor_rpc.sql` — koostaminen, varaus, merkintä, hallinnan tila.
- `booking/supabase/migrations/20261018232000_booking_79_procountor_cron.sql` — ajastus, oletuksena tyhjäkäynti.
- Rollback-tiedostot `booking/supabase/rollbacks/2026101823*_booking_7*_ROLLBACK.sql`. Purku järjestyksessä 79, 78, 77.
- `booking/supabase/functions/procountor-sync/` — `client.ts`, `invoice.ts`, `handler.ts`, `index.ts`.
- Hallinta: `booking/admin/views/settings.js` ja `booking/admin/procountor-texts.js`. Tekstit: `content/site-texts.pending-import-11.json`.
- SQL-testi: `booking/supabase/tests/talous/t77_procountor.sql` (ei CI-ajossa; `run.sh` ajaa vain `[0-9]*.test.sql`).
