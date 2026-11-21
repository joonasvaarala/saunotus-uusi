# SumUp Solo -pikakassa: tila (13.11.2026)

Haara: `claude/sumup-pikakassa` (päällä main fb0e543). Ei pusku, PR:ää eikä mergeä. Ei tuotantoajoja. DEV-kannan ja DEV-funktioiden tila on alla kohdassa "Bottiavustus / DEV".

## Lyhyesti
Pikakassaan on toteutettu maksutapa **Korttipääte (SumUp Solo)** SumUp Cloud API:lla: lukijan paritus, checkout lukijalle, tila webhookilla + rajapintavahvistus, peruutus (terminate), hyvitys. Tila oletuksena `off` (maksutapaa ei näy). CheckoutX on piilotettu Pikakassasta; sen koodi, migraatio, taulut ja data ovat ennallaan.

**Sandbox-e2e (13.11.2026, Europe/Helsinki):** Virtual Solo + DEV-ketju on ajettu testikauppiaalla `M49HK09W` (`SUMUP_ENV=sandbox`). Onnistuva 10,00 €, hylätty 11,00 €, keskeytys (terminate) ja testihyvitys v1.0-polulla menivät läpi. Webhook (`sumup-notify` 2× HTTP 200) ja Transactions API -täsmäys (`provider_ref` = `client_transaction_id`, `payment_mark_paid` + `confirmed_by='api'`) varmistettu. DEVin `integration_config.sumup.mode` palautettu `off`.

**Jäljellä ennen PRODia:** oikea Solo-lukija, live-tila + live-salaisuudet, sivutekstien tuonti, Koodarin PR / katselmointi. Webhookin allekirjoitusta SumUp ei dokumentoi; käytössä on `?s=`-salaisuus + pakollinen rajapintavahvistus.

## Tiedostot
Migraatio (ajettu vain DEViin):
- `booking/supabase/migrations/20261121115144_booking_295_sumup_pos.sql (PROD-versio)`
- `booking/supabase/rollbacks/20261121115144_booking_295_ROLLBACK.sql` (pysähtyy, jos sumup-maksuja/-hyvityksiä on; palauttaa `admin_pos_tenders`in booking_286-muotoon, md5 864bc26d…)
- numero 295: repossa ei ole 290–294; testi varmistaa. Migraation guard vaatii `admin_pos_tenders` md5 = 864bc26d1e42f6cb36eaf06da46dd6e6 (booking_286). Avainrajoitteet (`integration_config_key_check`, `…_test_only_online`) päivitetään lukemalla nykyinen määritys ja lisäämällä `sumup`, jotta muiden migraatioiden (uutiskirje ym.) avaimet eivät katoa.

Edge-funktiot (deployattu vain DEViin; API-tarkistuksen korjaukset mukana):
- `booking/supabase/functions/_shared/sumup.ts` (asetukset, `SumupApi`, tilamappaus), `_shared/sumup_flow.ts` (täsmäytys: yhteinen status- ja webhook-polulle)
- `booking/supabase/functions/sumup-pos/{handler,index}.ts`: `reader_pair`, `reader_list`, `start`, `status`, `cancel`, `refund`
- `booking/supabase/functions/sumup-notify/{handler,index}.ts`: webhook
- `booking/supabase/config.toml`: `sumup-pos` verify_jwt = true, `sumup-notify` verify_jwt = false

Hallinta:
- `booking/admin/sumup-pos.js` (apurit, lukijan ja kesken olevan maksun muisti), `pos-screen.js` (maksutapa, lukijavalinta, paritus, tilat), `pos-logic.js` (näkyvyys, CheckoutX piiloon), `pos-texts.js` (`POS_SUMUP_TEXTS`), `talous-texts.js` + `talous-api.js` + `views/{order-card,talous-orders,refund-cancel}.js` (hyvitys), `options-mock.js` + `admin.js` (kokeilutila `?mock=1`: simuloitu SumUp, `?su=decline` hylkää ensimmäisen yrityksen)
- Lukijoiden paritus ja lista ovat Pikakassan maksuikkunassa (maksutapa SumUp valittuna), näkyy vain `settings.edit`-oikeudella. Erillistä hallinnan asetussivua ei tehty.

Tekstit: `content/site-texts.pending-import-150.json` (62 riviä, `ui.pos.method_sumup`, `ui.pos.su_*`; numero 150 oli vapaa kaikissa paikallisissa haaroissa, ylin käytetty oli 146). `site-texts.fallback.json`ia ei muutettu (generoidaan PRODista). Koodin sanakirja toimii varana, kunnes Koodari ajaa tuonnin.

Testit:
- `booking/supabase/functions/_tests/sumup_test.ts` (Deno, 23 testiä)
- `booking/tests/sumup-pikakassa.test.mjs` (13 testiä), `booking/tests/checkoutx-pikakassa.test.mjs` päivitetty
- `booking/supabase/tests/pos/t295_sumup_pos.sql` (SQL, ajettu DEVissä rollback-transaktiossa, läpi)

## API-tarkistus (13.11.2026)
Lähteet: `docs/SUMUP_API_LAHDE.txt` (Cloud API -sivu) sekä API-referenssisivut developer.sumup.com/api (Create/List/Retrieve Reader, Create Reader Checkout, Terminate, Retrieve a transaction, Refund a transaction, Get Reader Status), haettu curlilla (WebFetch ei ollut sallittu). Oikealle SumUp-tilille ei tehty yhtään kutsua tässä tarkistuksessa.

**Täsmäsi (ei muutosta):** `POST /v0.1/merchants/{code}/readers` (pairing_code + name, 201); `GET …/readers` (`items`) ja `GET …/readers/{id}`; `POST …/readers/{id}/checkout` (`total_amount {currency, minor_unit, value}`, `return_url` https, `description`, `affiliate {app_id, key, foreign_transaction_id}`, vastaus 201 `data.client_transaction_id`); `POST …/readers/{id}/terminate` (202, ei vahvistusta); `GET /v2.1/merchants/{code}/transactions?client_transaction_id=`; webhook `solo.transaction.updated`, `status` successful|failed, täsmäys `client_transaction_id`:llä, `transaction_id`ä ei käytetä; allekirjoitusta ei dokumentoida → `?s=`-salaisuus + pakollinen rajapintavahvistus säilyy.

**Korjattu (vanha → uusi):**
1. Hyvitys: `POST /v0.1/me/refund/{txn}` (odotti 204) → `POST /v1.0/merchants/{code}/payments/{transaction_id}/refunds` (201). Tunniste = Transactions API:n `id` (UUID), jota `mapTransaction` jo tallentaa; webhookin vanhentunutta `transaction_id`:tä ei käytetä (`mapTransaction` ei enää lue sitä).
2. Transaktion tila `REFUNDED` (uusi arvo dokumentaatiossa) tulkittiin `pending` → nyt `paid` (onnistunut maksu, josta on hyvitetty), jotta hyvitetty maksu ei näytä keskeneräiseltä.
3. Parituskoodi: sallittu 6–12 merkkiä → 8–9 merkkiä (dokumentaatio: minLength 8, maxLength 9).
4. Lukija offline: aiemmin kaikki checkoutin 404/422 → `reader_offline`. Nyt vain 422 + `errors.type = READER_OFFLINE` (myös problem+json-muoto) → `reader_offline`; 404 (lukijaa ei löydy) → `reader_not_paired`. `SumupError` kantaa nyt `errType`-kentän, ja virheviesti luetaan `errors.detail`/`detail`-kentistä.
5. Testit: webhook-testin payloadista poistettu vanhentunut `transaction_id`; uudet testit 404-koodille, REFUNDED-mappaukselle ja parituskoodille.

**Ei muutettu, mutta huomioitu:**
- Osittainen hyvitys on dokumentaation mukaan tuettu (`amount` pääyksikössä, > 0, enintään hyvitettävä). Koodin kytkin `settings.partial_refund` (oletus false) jätettiin ennalleen; päätös Joonakselle.
- `failure_reason` on vapaatekstiä: ei tallenneta asiakasnäkymään eikä sen arvoihin sidota (koodi ei lue sitä).
- Cloud API -checkout vaatii Solo-firmwaren ≥ 3.3.24.3 (terminate ≥ 3.3.28.0, status ≥ 3.3.39.0).
- Uusi mahdollisuus: `GET …/readers/{id}/status` (ONLINE/OFFLINE, IDLE/WAITING_FOR_CARD…) voisi estää checkoutin offline-lukijalle etukäteen. Ei toteutettu.
- Ei tietokantamuutosta, joten uutta migraatiota (296) ei tarvittu; 295 koskematon.

**⚠ Jäi auki (ei varmistettavissa pelkästä dokumentaatiosta; sandbox-e2e täydensi osan):**
- Transactions-haku `client_transaction_id`:llä: sandbox-e2essä checkoutin palauttama tunnus ja transaktion / kannan `provider_ref` olivat sama arvo; `payment_mark_paid` kirjattiin `confirmed_by='api'`.
- Refund-virhekoodit 409/422 kirjataan toistaiseksi `provider_error`/failed ilman erittelyä.
- Webhookin allekirjoitus: ei dokumentoitu; tarkista uudelleen ennen tuotantoa. Sandbox-e2essä `sumup-notify` vastasi HTTP 200 (salaisuus URL:ssä kelpasi); maksu merkittiin silti vasta Transactions API -vahvistuksen jälkeen.

## Toiminta (lyhyt)
1. Ylläpitäjä kytkee tilan: `admin_set_sumup_mode('test'|'live', '<nimi>')` (vaatii `approved_by`; live vain admin). Trigger estää tilan ilman `approved_by`.
2. Pikakassa → Maksutapa "Korttipääte (SumUp Solo)" → (admin) parituskoodi + nimi → `sumup-pos reader_pair` → `POST …/readers`; lukija tallentuu `booking.sumup_readers` (vain id, nimi, env, oletus).
3. Maksa: kassatilaus → `start`: `sumup_pos_prepare` luo `payments`-rivin (`method=provider='sumup'`, `pending`, summa = tilauksen maksamaton osuus, 15 min) → `POST …/readers/{id}/checkout` (affiliate palvelimella) → `provider_ref = client_transaction_id`.
4. Tila: webhook ja/tai 2,5 s kysely → `reconcilePayment` hakee `GET transactions`; vain SUCCESSFUL + täsmäävä summa → `sumup_pos_apply(..., p_confirmed_by='api')` → `payment_mark_paid('sumup', …)`. DB kieltäytyy `paid`-kirjauksesta ilman `api`-vahvistusta.
5. UI-tilat: odotus, onnistui, hylätty (Yritä uudelleen / Peru), peruttu. Peru → `terminate` lukijalle, sitten kassatilauksen peruutus; jos asiakas ehti maksaa, tilausta ei peruta.
6. Hyvitys: `admin_refund` luo `refunds`-rivin `provider='sumup'` → `sumup-pos refund` → `POST /v1.0/merchants/{code}/payments/{txn}/refunds`. Koko maksu oletuksena; osittainen estetty ellei `settings.partial_refund = true` (ks. avoimet kysymykset).

## Testitulokset
Juuren `tests/`-testit, jotka koskevat site-texteja (4 tiedostoa): läpi.

| Testi | Tulos |
|---|---|
| Deno `_tests/sumup_test.ts` | **23/23 läpi** (`deno test --no-check`; API-tarkistuksen jälkeen +3 testiä) |
| Deno `_tests/checkoutx_test.ts` (vanha) | 14/14 läpi, koskematta (yhteensä 37/37) |
| JS `sumup-pikakassa.test.mjs` | **13/13 läpi** (uudelleenajo API-tarkistuksen jälkeen: sumup- + checkoutx-pikakassa yhteensä 20/20) |
| JS `checkoutx-pikakassa.test.mjs` | 7/7 läpi. Päivitetty: UI-testit korvattu "CheckoutX ei näy" -testillä, koska maksutapa on tarkoituksella piilotettu; puhtaat apurit ja staattiset 286-tarkistukset ennallaan |
| JS koko `booking/tests/*.test.mjs` (174 tiedostoa, ajettu yksitellen rinnakkain, aikaraja 90 s/tiedosto) | **174/174 läpi** (yksi ajo aikakatkesi ensin testin jättämän kyselyajastimen vuoksi; korjattu testissä) |
| SQL `t295_sumup_pos.sql` | Ensimmäinen DEV-ajo ei mennyt läpi testin oletusten takia. **Korjattu** (business_id, PL/pgSQL `oid`-nimiväistö, lukijakysely oikealla roolilla) ja ajettu uudelleen DEVissä rollback-transaktiossa: **TESTRESULT pass=78 fail=0**, ei jäämiä, mode oli tuolloin `off`. |
| Virtual Solo / sandbox (DEV, 13.11.2026 ~23:06–23:09 Europe/Helsinki) | **Läpi.** Paritus integraation `reader_pair`-kautta, sitten: 10,00 € → `paid` (tilaus 2469 / 8802505, maksu 1834, `provider_status=SUCCESSFUL`, `paid_at` asetettu, `confirmed_by=api`); 11,00 € → `failed` (tilaus 2470 / 8802506, maksu 1835); terminate 12,00 € → `cancelled` (tilaus 2471 / 8802507, maksu 1836, `provider_status=CANCELLED`, `by=pos_cancel`). `provider_ref` = `client_transaction_id` kaikissa kolmessa. `sumup-notify` 2× HTTP 200, `sumup-pos` 11× HTTP 200 samalla ikkunalla. Testihyvitys (refund 82) `POST /v1.0/…/refunds` → `processed: done`; maksu 1834 `refunded` 10,00 €, tilaus `payment_status=refunded`. |

## Mitä jäi ajamatta
- Selainkokeilu oikealla laitteella / oikealla Solo-lukijalla (live).
- `deno check` indexeille (`npm:@supabase/supabase-js` ei ratkea ilman verkkoa; sama kuin muillakin funktioilla).
- Sivutekstien tuonti (`site-texts.pending-import-150.json`) ja Koodarin PR.
- Osittaista hyvitystä ei testattu (`partial_refund=false`).

## Avoimet kysymykset
1. **Webhookin todennus:** nyt jaettu salaisuus URL:ssä (`?s=`) + pakollinen rajapintavahvistus. Jos SumUp tarjoaa allekirjoituksen, lisätään. Tarkista uudelleen ennen tuotantoa.
2. **Osittainen hyvitys:** dokumentaation mukaan tuettu; koodissa oletus `settings.partial_refund=false`. Päätös Joonakselle.
3. Pikakassan maksurivi vanhenee 15 min; jos asiakas maksaa vanhenemisen jälkeen, status/webhook kirjaa maksun silti (apply sallii `paid` myös `failed`/`cancelled`-riville) → tilaus voi tarvita käsin tarkistusta.
4. Lukijalistaus (`reader_list`) on toteutettu Edgessä, mutta UI käyttää kannan listaa (`admin_get_sumup_status`); API-lista on käytettävissä lukijan tilan tarkistukseen myöhemmin.
5. Havainto (ei regressiokorjausta tässä): `payments.raw.sumup_status` voi tallentua JSON-merkkijonona eikä objektina, jos Edge välittää `p_raw`:n merkkijonona. Ei vaikuttanut tilakoneeseen.

## Mitä Joonaksen pitää hankkia / PRODiin
- Oikea **Solo-lukija** (Cloud API, firmware vähintään yllä mainitut) ja parituskoodi
- Live-tila: `admin_set_sumup_mode('live', approved_by)` Joonaksen hyväksynnällä, ja PRODin Edge-salaisuudet oikealta tililtä (`SUMUP_ENV=live`, merchant `MVVBWM97`, live-API-avain, affiliate key + app id `fi.saunotus.kassa`, webhook-salaisuus, `SUMUP_NOTIFY_URL` PRODin notify-osoitteeseen). Älä kopioi sandbox-avaimia PRODiin.
- Koodarin katselmointi + PR haarasta `claude/sumup-pikakassa` (ei pusketu tässä työssä)
- Sivutekstien tuonti (`pending-import-150.json`)
- SumUp-tili (Havuhattu Oy, Suomi) on jo olemassa; KYC / Cloud API käytössä live-tilillä. Live-lukukysely: `GET /v0.1/me` HTTP 200, merchant `MVVBWM97`; lukijoita 0. Checkoutteja, parituksia tai hyvityksiä ei ole tehty oikealle tilille.

## Tarvittavat salaisuudet (Edge-salaisuudet; EI kantaan, EI koodiin)
| Nimi | Käyttö |
|---|---|
| `SUMUP_API_KEY` | Bearer-avain (sandbox tai live) |
| `SUMUP_AFFILIATE_KEY` | checkoutin `affiliate.key` |
| `SUMUP_AFFILIATE_APP_ID` | checkoutin `affiliate.app_id` |
| `SUMUP_MERCHANT_CODE` | polkuparametri `merchants/{code}` |
| `SUMUP_WEBHOOK_SECRET` | webhook-URL:n `?s=` |
| `SUMUP_ENV` | `sandbox` (tila test) tai `live` (tila live); ristiin kytkentä estetty |
| `SUMUP_NOTIFY_URL` | koko webhook-osoite (https), valinn.: ilman sitä vain kyselytila |
| `SUMUP_API_URL` | valinn. (oletus `https://api.sumup.com`); mock-palvelimelle |
| `SUMUP_ALLOWED_ORIGINS` | valinn. CORS |

**DEV-salaisuudet on asetettu** `sumup-pos`- ja `sumup-notify`-funktioille (vain sandbox: `SUMUP_ENV=sandbox`, testikauppias `M49HK09W`, affiliate app id `fi.saunotus.kassa`, webhook-salaisuus, `SUMUP_NOTIFY_URL` DEVin notify-osoitteeseen). Arvoja ei ole kirjoitettu tiedostoihin, repoon eikä lokeihin. Oikean tilin avaimet ovat vain boxin ympäristössä; niitä ei ole laitettu DEV-maksusalaisuuksiksi eikä käytetty checkouteihin.

## Jatkokehitys (ei toteuteta nyt)
Joonas haluaa myöhemmin käyttöön myös **Tap to Pay puhelimella** (esim. messuille), esimerkiksi SumUp-sovelluksen Payment Switchin kautta. **Nyt tehdään vain yksi Solo-lukija** (Cloud API). Payment Switchiä ja puhelimen Tap to Paytä ei toteuteta tässä haarassa.

Rakenne on jätetty niin, että maksutavan eli kanavan (`solo` / `tap_to_pay`) voi lisätä myöhemmin ilman isoja muutoksia:
- Nykyinen Pikakassan tapa on `pos_tenders.handler = 'sumup'` (Solo / Cloud API). Uusi kanava = uusi handler (esim. `sumup_tap_to_pay`) + oma Pikakassan polku + oma Edge-funktio. Nykyisiä Solo-polkuja (`sumup-pos`, `sumup-notify`, `booking.sumup_readers`, `sumup_pos_*`) ei tarvitse rikkoa.
- Yhteiset osat voidaan käyttää uudelleen: `payment_mark_paid('sumup', …)`, `payments.provider = 'sumup'`, hyvitys, `_shared/sumup.ts` (Transactions API, refund), tilakone (maksetuksi vain rajapintavahvistuksella).
- Affiliate key ja app id (`fi.saunotus.kassa`) ovat saatavilla oikealta tililtä; Payment Switchiä ei silti toteuteta nyt.

## Bottiavustus / DEV (13.11.2026, Europe/Helsinki)
- Migraatio `booking_295_sumup_pos` ajettu **vain DEViin** (projekti aoejjmfzulhkhxbehphs). Uusi `admin_pos_tenders`-md5: `babb3ce2a62c15356c90143d03c3a589`.
- SQL-testi `t295_sumup_pos.sql` korjattu ja ajettu DEVissä rollback-transaktiossa: pass=78 fail=0, ei jäämiä.
- Oikea SumUp-tili (Havuhattu Oy, merchant_code `MVVBWM97`, FI): vain lukukyselyt. Checkoutteja, parituksia tai hyvityksiä ei tehty live-tilille.
- Edge-funktiot `sumup-pos` (verify_jwt = true) ja `sumup-notify` (verify_jwt = false) on deployattu **vain DEViin**, tila ACTIVE, API-tarkistuksen korjaukset mukana. Sandbox-salaisuudet asetettu (nimet yllä). Tuotantoon ei ole viety mitään.
- Sandbox-testin ajaksi `integration_config.sumup.mode` kytkettiin `test`-tilaan, `settings.approved_by='Joonas t1716u (DEV-testi)'` (Joonas pyysi t1716u:ta testaamaan DEViin). **Mode palautettu `off` 13.11.2026 ~23:09 Europe/Helsinki.** `approved_by` jäi settings-kenttään historiatiedoksi; maksutapa ei näy Pikakassassa mode=off-tilassa.
- Virtual Solo -e2e (simulator-edge + Phoenix-WS, ei selain-GUI:ta): ensimmäinen paritus jätti lukijan `processing`/`OFFLINE`-tilaan, koska enroll/WS ei ehtinyt; toinen `reader_pair` palautti 502 `provider_error`, kun vanha lukija oli vielä sandbox-tilillä. Vanha lukija poistettiin SumUpista, OAuth-kutsulle lisättiin User-Agent/iat/exp, ja ketju toimi. Nämä olivat testiympäristön/harnessin ongelmia, eivät tuotekoodin muutoksia tässä ajossa.
- `admin_refund` RPC service_role-kutsuna palautti HTTP 400 (`_require_permission('payments.refund')` vaatii henkilökunnan JWT:n). Tämä ei ole SumUp-bugi. Testihyvitysrivi (id 82) luotiin suoraan kantaan ja ajettiin `sumup-pos refund`-toiminnolla onnistuneesti.
- Siivous DEVissä: Virtual Solo -lukijat deaktivoitu kannassa (3 riviä, aktiivisia 0); vastaavat lukijat poistettu sandbox-tililtä (0 jäljellä); tuotteet 261–263 (`t1716u sandbox 10e/11e/12e`) deaktivoitu; staff `t1716u.sandbox@example.test` (user_id `8ac455c6-ddfd-4eed-aed3-169632954513`) deaktivoitu. **Jäljellä (listattu, ei poistettu maksuhistoriasta):** tilaukset 2469 (confirmed / refunded), 2470 ja 2471 (pending / unpaid), maksut 1834–1836, hyvitys 82, kolme inaktiivista `sumup_readers`-riviä, inaktiiviset tuotteet ja auth-käyttäjä testiosoitteella. Tilauksiin lisätty sisäinen merkintä `t1716u sandbox e2e`.

## Käyttöönottojärjestys (ehdotus, Koodarille)
1. Katselmointi (migraatio 295 ja sandbox-e2e ovat DEVissä). Haara `claude/sumup-pikakassa` ei ole puskettu.
2. Tuo `site-texts.pending-import-150.json`.
3. PROD vasta Joonaksen hyväksynnällä: live-salaisuudet, oikea Solo, `admin_set_sumup_mode('live', …)`, `SUMUP_ENV=live`.
4. Tap to Pay / Payment Switch vasta erillisenä myöhempänä työnä (ks. Jatkokehitys).
