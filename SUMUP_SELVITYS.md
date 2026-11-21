# SumUp-selvitys: Pikakassan korttipääte (13.11.2026)

**Valinta (päätetty, ei avata uudelleen tässä työssä): SumUp Solo -lukija + Cloud API.** Payment Switch / Tap to Pay jätetään myöhemmäksi kanavaksi (messut ym.); sitä ei toteuteta nyt.

> **Päivitys 13.11.2026:** endpointit on tarkistettu virallista Cloud API -sivua (`docs/SUMUP_API_LAHDE.txt`) ja API-referenssiä (developer.sumup.com/api) vastaan. Korjaukset ja jäljelle jääneet ⚠-kohdat on kirjattu `SUMUP_TILA.md`:n kohtaan "API-tarkistus". Alla olevassa taulukossa on korjatut arvot. Kaikki SumUp-kutsut ovat yhdessä paikassa (`_shared/sumup.ts`, `SumupApi`).

## 1. Vaihtoehtojen vertailu

| Vaihtoehto | Toimiiko meillä | Päätös |
|---|---|---|
| **Cloud API + Solo** | Palvelin ohjaa lukijaa HTTP-kutsuilla; ei natiivisovellusta, ei selaimen avaimia. Sopii Edge-funktioihin. | **Valittu** |
| Payment Switch | URL-skeema / sovelluksen avaus affiliate keyllä. Vaatii SumUp-sovelluksen puhelimessa ja paluulinkin. Sopii myöhemmin puhelimen Tap to Payhin (esim. messut). | Ei nyt; myöhempi kanava `tap_to_pay` |
| Tap to Pay SDK / selainpolku | Natiivit SDK:t (iOS/Android); meillä ei natiivisovellusta. | Ei sovi |
| Checkouts / Transactions / Refunds API | Verkkokaupan korttimaksu ja raportointi. **Käytetään sivutuotteena**: Transactions API vahvistaa maksun tilan, Refunds API hyvittää. Checkouts API ei käynnistä lukijaa. | Osittain (tilan haku, hyvitys) |
| Virtual Solo | SumUpin ohjelmallinen lukijasimulaattori (parituskoodi kuten oikealla lukijalla) kehitystä varten. ⚠ varmista saatavuus ja käyttö sandbox-tilillä. | Käytetään testissä, jos tili sen sallii |

## 2. Todennus: API-avain vs OAuth, affiliate key

- **API-avain (Bearer)**: yksinkertainen palvelimelta palvelimelle -kutsuihin, kauppiaan oma tili. Sopii meille, koska yksi kauppias (Havuhattu Oy), ei kolmansien osapuolten tilejä. Tallennetaan Edge-salaisuuteen `SUMUP_API_KEY`.
- **OAuth**: tarvitaan vasta, jos useita kauppiaita antaisi valtuutuksen sovellukselle. Ei tarvita tässä.
- **Affiliate key** (+ app id): luodaan SumUp-kehittäjäportaalissa; **Cloud API:n checkout-pyyntö vaatii `affiliate`-objektin** (`app_id`, `key`, `foreign_transaction_id`). Key on sidottu sovelluksen tunnisteeseen. Vain palvelimella (`SUMUP_AFFILIATE_KEY`, `SUMUP_AFFILIATE_APP_ID`). ⚠
- **Merchant code** (`SUMUP_MERCHANT_CODE`): kaikissa Cloud API -poluissa `/v0.1/merchants/{merchant_code}/…`.

## 3. Endpointit, jotka toteutus käyttää (⚠ varmistettava)

Base: `https://api.sumup.com` (ylikirjoitettavissa `SUMUP_API_URL`:lla testimockia varten). Otsake: `Authorization: Bearer <SUMUP_API_KEY>`.

| Toiminto | Kutsu | Huomiot |
|---|---|---|
| Parita lukija | `POST /v0.1/merchants/{merchant_code}/readers` `{ "pairing_code": "ABCD1234", "name": "Kassa" }` | Parituskoodi 8–9 merkkiä, voimassa 5 min; näkyy uloskirjautuneen lukijan näytöllä (Connections → API → Connect). `name` pakollinen (max 500). Vastaus **201**: lukija `{ id ("rdr_…", 30 merkkiä), name, status: unknown\|processing\|paired\|expired, device: { identifier, model: solo\|virtual-solo } }`. Tallennamme vain `id` ja `name`. |
| Listaa lukijat | `GET /v0.1/merchants/{merchant_code}/readers` | `{ items: [...] }` |
| Aloita maksu | `POST /v0.1/merchants/{merchant_code}/readers/{reader_id}/checkout` | Body: `total_amount: { value: 700, currency: "EUR", minor_unit: 2 }` (summa **pienimmässä yksikössä**, ei desimaaleja), `description`, `affiliate: { app_id, key, foreign_transaction_id }`, valinnaisesti `return_url` (webhook). `affiliate` = `{ app_id, key, foreign_transaction_id? }` (app_id ja key molemmat pakollisia). Vastaus 201: `{ data: { client_transaction_id, checkout_id? } }`. Lukijan on oltava online; 60 s kuluessa muut checkoutit samalle lukijalle hylätään. Virheet: 404 lukijaa ei löydy; 422 `errors.type = READER_OFFLINE` lukija offline. |
| Keskeytä (terminate) | `POST /v0.1/merchants/{merchant_code}/readers/{reader_id}/terminate` | 202. Asynkroninen, ei vahvistusta; toimii vain kun lukija odottaa korttia/PINiä. Onnistunut keskeytys + `return_url` → webhook `status=failed`. Offline: 422 READER_OFFLINE. |
| Maksun tila | `GET /v2.1/merchants/{merchant_code}/transactions?client_transaction_id=…` | Vastaus on yksittäinen transaktio-objekti (ei `items`-listaa): `status` `SUCCESSFUL`/`FAILED`/`CANCELLED`/`PENDING`/`REFUNDED`, `id` (UUID), `transaction_code`, `amount` (pääyksikkö, EUR), `currency`, `client_transaction_id`, `foreign_transaction_id`. Haku vaatii yhden parametreista id/transaction_code/foreign_transaction_id/client_transaction_id. 404 = ei vielä transaktiota (⚠ ei dokumentoitu erikseen). REFUNDED = onnistunut maksu, josta hyvitetty. |
| Hyvitys | `POST /v1.0/merchants/{merchant_code}/payments/{transaction_id}/refunds` (tyhjä body = koko summa, `{ "amount": 3.00 }` = osittainen, pääyksikkö) | **201**. `transaction_id` = Transactions API:n `id` (UUID). Dokumentaatio tukee osittaista hyvitystä (amount > 0, enintään hyvitettävä); koodi estää sen silti oletuksena (`settings.partial_refund = false`) – päätös omistajalle. Virheet: 400, 403, 404, 409 (ei hyvitettävissä), 422. |

### Webhook
- Cloud API lähettää POST-kutsun checkoutin `return_url`-osoitteeseen (oltava https ja julkinen). Dokumentoitu runko: `{ id, event_type: "solo.transaction.updated", payload: { client_transaction_id, merchant_code, status: "successful"|"failed", failure_reason? }, timestamp }`. `transaction_id` on vanhentunut, ei käytetä. `failure_reason` on vapaatekstiä, ei näytetä asiakkaalle eikä sen arvoihin sidota.
- **Allekirjoitusta ei ole dokumentoitu** (Cloud API -sivulla ei mainita allekirjoitusotsaketta; ⚠ tarkista uudelleen ennen tuotantoa). Siksi suunnittelu on kaksivaiheinen:
  1. `return_url`:iin liitetään oma salaisuus `?s=<SUMUP_WEBHOOK_SECRET>`; `sumup-notify` vertaa sitä vakioaikaisesti. (Jos SumUp tukee allekirjoitusotsaketta, lisätään tarkistus tähän.)
  2. **Webhookin sisältöön ei luoteta.** Funktio hakee tilan itse (`GET transactions`) ja vasta SUCCESSFUL + täsmäävä summa + valuutta johtaa `payment_mark_paid`-polkuun. Webhookin `status` on vain vihje (poikkeus: `failed` ilman transaktiota → failed, koska rahaa ei ole liikkunut).
- Webhook-osoite: `https://<projekti>.supabase.co/functions/v1/sumup-notify` (`SUMUP_NOTIFY_URL`). Funktio ei vaadi JWT:tä (`verify_jwt = false`).
- Jos webhook ei tule perille (tai `SUMUP_NOTIFY_URL` puuttuu), kassa kysyy tilaa 2,5 s välein `sumup-pos` `status`-toiminnolla. Webhook on siis nopeutus, ei välttämätön.

## 4. Sandbox ja Virtual Solo

- SumUpilla ei ole erillistä sandbox-hostia: **sandbox on erillinen kauppiastili** (⚠ luodaan kehittäjäportaalin kautta; sandbox-API-avaimet), kutsut menevät samaan `api.sumup.com`-osoitteeseen. Siksi koodissa `SUMUP_ENV = sandbox|live` on pakollinen ja sen on vastattava `integration_config.sumup.mode`-tilaa (`test` ↔ `sandbox`, `live` ↔ `live`). Sandbox-avaimia ei voi vahingossa käyttää liveen eikä päinvastoin.
- **Virtual Solo**: ohjelmallinen lukija, jonka voi parittaa Cloud API:lla sandbox-tilillä ilman fyysistä laitetta. Soveltuu koko ketjun (paritus → checkout → webhook → tila) testaamiseen. ⚠ Saatavuus ja käyttö tarkistettava SumUpilta (Joonaksen tai tuen kautta).

## 5. Toimivuus Suomessa

- SumUp toimii Suomessa (SumUp-tili Suomessa, EUR, suomalaiset kortit ja Apple/Google Pay). ⚠ Tarkista: onko **Solo ja Cloud API** käytettävissä juuri suomalaiselle kauppiastilille ja onko tilin KYC (Havuhattu Oy, Y-tunnus) valmis. Tämä on liiketoiminnallinen kysymys, ei koodikysymys.
- Alkoholia ei myydä Pikakassassa QR-linkillä; kortilla kassalla myynti noudattaa olemassa olevaa ikärajakäytäntöä (ei muutosta tässä).

## 6. Rakenne ja perustelut

- **Yksi kanava kerrallaan, laajennettava**: Nyt vain Solo (`pos_tenders.handler = 'sumup'`). Myöhempi kanava (Tap to Pay / Payment Switch, `tap_to_pay`) = uusi handler + oma Pikakassan polku + oma Edge-funktio; Cloud API -polku (`sumup-pos`, `sumup-notify`, `booking.sumup_*`) ei muutu. Yhteiset osat (`payment_mark_paid('sumup')`, Transactions/Refunds, tilakone) voidaan käyttää uudelleen.
- **Tilakone**: `payments.status`: `pending` → `paid` (vain `sumup_pos_apply(…, p_confirmed_by='api', p_amount)`) / `failed` / `cancelled`. Tietokantafunktio kieltäytyy `paid`-merkinnästä ilman `api`-vahvistusta, joten virheellinen Edge-koodikaan ei voi merkitä maksua maksetuksi pelkän webhookin perusteella.
- **provider_ref = `client_transaction_id`** (checkoutin tunniste, tiedossa heti checkoutin jälkeen ja webhookin avain). SumUpin transaktio-id tallennetaan `raw.transaction_id`:hen maksun vahvistuessa ja sitä käytetään hyvityksessä.
- **Ristiriitatilanne**: jos asiakas ehtii maksaa lukijalla samalla hetkellä kun kassa perutaan, `cancel` tarkistaa ensin rajapinnasta; maksettu voittaa (kassatilausta ei peruta). Jos maksu vahvistuu vasta perutun rivin jälkeen (webhook), `apply paid` sallitaan myös `cancelled`/`failed`-riville, jotta maksettu raha ei jää kirjaamatta.
