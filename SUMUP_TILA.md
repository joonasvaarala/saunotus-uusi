# SumUp Solo -pikakassa: tila (13.11.2026)

Haara: `claude/sumup-pikakassa` (päällä main fb0e543, commit 98d5b39). Ei pusku, PR:ää eikä mergeä. Ei tuotantoajoja. DEV-kannan ja DEV-funktioiden tila on alla kohdassa "Bottiavustus / DEV".

## Lyhyesti
Pikakassaan on toteutettu maksutapa **Korttipääte (SumUp Solo)** SumUp Cloud API:lla: lukijan paritus, checkout lukijalle, tila webhookilla + rajapintavahvistus, peruutus (terminate), hyvitys. Tila oletuksena `off` (maksutapaa ei näy). CheckoutX on piilotettu Pikakassasta; sen koodi, migraatio, taulut ja data ovat ennallaan.

**Isoin riski:** API-kutsut on tarkistettu virallista dokumentaatiota vastaan (ks. "API-tarkistus" alla), mutta mitään ei ole ajettu sandboxia tai Solo/Virtual Solo -lukijaa vastaan. Ks. "Mitä jäi ajamatta".

## Tiedostot
Migraatio (EI ajettu): 
- `booking/supabase/migrations/20261113190000_booking_295_sumup_pos.sql`
- `booking/supabase/rollbacks/20261113190000_booking_295_ROLLBACK.sql` (pysähtyy, jos sumup-maksuja/-hyvityksiä on; palauttaa `admin_pos_tenders`in booking_286-muotoon, md5 864bc26d…)
- numero 295: repossa ei ole 290–294; testi varmistaa. Migraation guard vaatii `admin_pos_tenders` md5 = 864bc26d1e42f6cb36eaf06da46dd6e6 (booking_286). Avainrajoitteet (`integration_config_key_check`, `…_test_only_online`) päivitetään lukemalla nykyinen määritys ja lisäämällä `sumup`, jotta muiden migraatioiden (uutiskirje ym.) avaimet eivät katoa.

Edge-funktiot (EI deployattu):
- `booking/supabase/functions/_shared/sumup.ts` (asetukset, `SumupApi`, tilamappaus), `_shared/sumup_flow.ts` (täsmäytys: yhteinen status- ja webhook-polulle)
- `booking/supabase/functions/sumup-pos/{handler,index}.ts`: `reader_pair`, `reader_list`, `start`, `status`, `cancel`, `refund`
- `booking/supabase/functions/sumup-notify/{handler,index}.ts`: webhook
- `booking/supabase/config.toml`: `sumup-pos` verify_jwt = true, `sumup-notify` verify_jwt = false

Hallinta:
- `booking/admin/sumup-pos.js` (apurit, lukijan ja kesken olevan maksun muisti), `pos-screen.js` (maksutapa, lukijavalinta, paritus, tilat), `pos-logic.js` (näkyvyys, CheckoutX piiloon), `pos-texts.js` (`POS_SUMUP_TEXTS`), `talous-texts.js` + `talous-api.js` + `views/{order-card,talous-orders,refund-cancel}.js` (hyvitys), `options-mock.js` + `admin.js` (kokeilutila `?mock=1`: simuloitu SumUp, `?su=decline` hylkää ensimmäisen yrityksen)
- Lukijoiden paritus ja lista ovat Pikakassan maksuikkunassa (maksutapa SumUp valittuna), näkyy vain `settings.edit`-oikeudella. Erillistä hallinnan asetussivua ei tehty.

Tekstit: `content/site-texts.pending-import-150.json` (62 riviä, `ui.pos.method_sumup`, `ui.pos.su_*`; numero 150 oli vapaa kaikissa paikallisissa haaroissa, ylin käytetty oli 146). `site-texts.fallback.json`ia ei muutettu (generoidaan PRODista). Koodin sanakirja toimii varana, kunnes Koodari ajaa tuonnin.

Testit:
- `booking/supabase/functions/_tests/sumup_test.ts` (Deno, 20 testiä)
- `booking/tests/sumup-pikakassa.test.mjs` (13 testiä), `booking/tests/checkoutx-pikakassa.test.mjs` päivitetty
- `booking/supabase/tests/pos/t295_sumup_pos.sql` (SQL, ei ajettu)

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

**⚠ Jäi auki (ei varmistettavissa dokumentaatiosta):**
- Transactions-haun vastaus `client_transaction_id`:llä Solo-maksulle: ovatko checkoutin palauttama `client_transaction_id` ja transaktion `client_transaction_id` varmasti sama arvo (dokumentaatio: "use this value to match … transaction records") ja mikä on haun vastaus, kun transaktiota ei vielä ole (oletus 404; koodi hoitaa myös tyhjän). Varmistuu vasta Virtual Solo -testissä. Vaihtoehto: `foreign_transaction_id` (`saunotus-pos-<id>`) on jo lähetetty ja kelpaa hakuparametriksi.
- Refund-virhekoodit 409/422 kirjataan toistaiseksi `provider_error`/failed ilman erittelyä.
- Webhookin allekirjoitus: ei dokumentoitu; tarkista uudelleen ennen tuotantoa.
- Sandbox-tilin ja Virtual Solon toimivuus (koko ketju) ajamatta.

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
| SQL `t295_sumup_pos.sql` | DEV-ajo 1: ei mennyt läpi testin omien oletusten takia. **Korjattu (business_id, `v_order_id`, lukijataulu vain service/omistaja-osiossa); korjattua ei ole ajettu.** Bottiavustus ajaa DEVissä rollback-transaktiossa. |
| Virtual Solo / sandbox | **EI ajettu** (sandbox-tunnuksia ei ole). Oikealla tilillä tehtiin vain lukukyselyt, ei checkout-/paritus-/hyvityskutsuja. |

## Mitä jäi ajamatta
- Migraatio ja SQL-testi t295 (paikallinen Postgres tai DEV; Bottiavustus ajaa DEV:n). md5-arvot uusille funktioille ja uudelle `admin_pos_tenders`ille kirjataan migraation otsikkoon ajon jälkeen.
- Oikea SumUp-kutsu (sandbox + Virtual Solo): paritus, checkout, webhook, hyvitys.
- `deno check` indexeille (`npm:@supabase/supabase-js` ei ratkea ilman verkkoa; sama kuin muillakin funktioilla).
- Selainkokeilu oikealla laitteella.

## Avoimet kysymykset
1. **API:n tarkkuus** (⚠ `SUMUP_SELVITYS.md`): checkout-body, `affiliate`-kentät, `return_url`, transaktiohaun polku/vastausmuoto, webhookin runko ja mahdollinen allekirjoitus, refund-polku. Korjaukset keskitetty `_shared/sumup.ts`:ään ja `mapTransaction`iin.
2. **Osittainen hyvitys**: tukeeko SumUp sitä Solo-maksulle? Oletus: ei sallita (`settings.partial_refund=false`, estetään kuten CheckoutX).
3. **Webhookin todennus**: nyt jaettu salaisuus URL:ssä (`?s=`) + pakollinen rajapintavahvistus. Jos SumUp tarjoaa allekirjoituksen, lisätään.
4. Pikakassan maksurivi vanhenee 15 min; jos asiakas maksaa vanhenemisen jälkeen, status/webhook kirjaa maksun silti (apply sallii `paid` myös `failed`/`cancelled`-riville) → tilaus voi tarvita käsin tarkistusta.
5. Lukijan fyysinen tila (offline) tulkitaan checkoutin 404/422-vastauksesta virheeksi `reader_offline`; tarkista oikea virhekoodi.
6. Lukijalistaus (`reader_list`) on toteutettu Edgessä, mutta UI käyttää kannan listaa (`admin_get_sumup_status`); API-lista on käytettävissä lukijan tilan tarkistukseen myöhemmin.

## Mitä Joonaksen pitää hankkia
- SumUp-tili (Havuhattu Oy, Suomi), KYC valmiina; varmistus että Solo + Cloud API on käytössä tilillä
- **Solo-lukija** (tai Virtual Solo kehitykseen) ja sen parituskoodi
- **Sandbox-kauppiastili** + sandbox-API-avain (testi), myöhemmin live-API-avain
- **API-avain**, **affiliate key** ja **affiliate app id** (`fi.saunotus.kassa`) ovat nyt boxin ympäristössä oikealta tililtä; DEV-maksutesteihin tarvitaan silti **sandbox**-avaimet. Merchant code: `MVVBWM97`
- **Webhook-salaisuus**: keksitään itse (pitkä satunnaismerkkijono), ei SumUpilta
- Callback/webhook-domain: `https://<supabase-projekti>.supabase.co/functions/v1/sumup-notify` (jos SumUp vaatii sallittujen domainien listan, lisätään tämä)

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

**DEV-salaisuudet tarvitaan** `sumup-pos`- ja `sumup-notify`-funktioille (sandbox-arvot, `SUMUP_ENV=sandbox`) ennen DEV-testiä. Ilman niitä funktiot palauttavat `not_configured` ja maksua ei aloiteta.

## Jatkokehitys (ei toteuteta nyt)
Joonas haluaa myöhemmin käyttöön myös **Tap to Pay puhelimella** (esim. messuille), esimerkiksi SumUp-sovelluksen Payment Switchin kautta. **Nyt tehdään vain yksi Solo-lukija** (Cloud API). Payment Switchiä ja puhelimen Tap to Paytä ei toteuteta tässä haarassa.

Rakenne on jätetty niin, että maksutavan eli kanavan (`solo` / `tap_to_pay`) voi lisätä myöhemmin ilman isoja muutoksia:
- Nykyinen Pikakassan tapa on `pos_tenders.handler = 'sumup'` (Solo / Cloud API). Uusi kanava = uusi handler (esim. `sumup_tap_to_pay`) + oma Pikakassan polku + oma Edge-funktio. Nykyisiä Solo-polkuja (`sumup-pos`, `sumup-notify`, `booking.sumup_readers`, `sumup_pos_*`) ei tarvitse rikkoa.
- Yhteiset osat voidaan käyttää uudelleen: `payment_mark_paid('sumup', …)`, `payments.provider = 'sumup'`, hyvitys, `_shared/sumup.ts` (Transactions API, refund), tilakone (maksetuksi vain rajapintavahvistuksella).
- Affiliate key ja app id (`fi.saunotus.kassa`) ovat nyt saatavilla oikealta tililtä; Payment Switchiä ei silti toteuteta nyt. DEV-maksutestit vain sandboxilla tai mockeilla.

## Bottiavustus / DEV (13.11.2026, Europe/Helsinki)
- Migraatio `booking_295_sumup_pos` ajettu **vain DEViin** (projekti aoejjmfzulhkhxbehphs). `integration_config.sumup.mode = off`, lukijoita 0, `approved_by` tyhjä, maksutapa ei näy. Uusi `admin_pos_tenders`-md5: `babb3ce2a62c15356c90143d03c3a589`.
- SQL-testi `t295_sumup_pos.sql` ajettiin DEVissä rollback-transaktiossa. Ei mennyt läpi testin omien oletusten takia (ei migraatiovirhe): `kb.products.business_id` on pakollinen; PL/pgSQL-muuttuja `oid` törmää `pg_constraint.oid`:hen; authenticated-rooli ei saa lukea `booking.sumup_readers`-taulua suoraan. Testidata ei jäänyt DEViin (mode pysyi `off`).
- Oikea SumUp-tili (Havuhattu Oy, merchant_code `MVVBWM97`, FI): vain lukukyselyt. `GET /v0.1/me` → HTTP 200, merchant_code täsmää. `GET /v0.1/merchants/MVVBWM97/readers` → HTTP 200, **0 lukijaa**. Checkoutteja, parituksia tai hyvityksiä ei tehty. Boxin ympäristössä ovat `SUMUP_API_KEY`, `SUMUP_PUBLIC_KEY` ja `SUMUP_AFFILIATE_KEY` (oikea tili); affiliate app id on `fi.saunotus.kassa`. Avaimia ei ole kirjoitettu tiedostoihin eikä repoon, eikä niitä ole laitettu DEV Edge-salaisuuksiksi (maksutestit vain sandboxilla tai mockeilla).
- Edge-funktiot `sumup-pos` (verify_jwt = true, versio 1) ja `sumup-notify` (verify_jwt = false, versio 1) on deployattu **vain DEViin**, tila ACTIVE. DEV Edge-salaisuuksia ei asetettu (ei live-avaimia, ei sandbox-avaimia); funktiot palauttavat `not_configured`, kunnes sandbox-salaisuudet lisätään. Tuotantoon ei ole viety mitään.

## Käyttöönottojärjestys (ehdotus, Koodarille/Bottiavustukselle)
1. Katselmointi (migraatio 295 on jo DEVissä). Korjaa t295-testi (business_id, oid-nimi, lukijakysely RPC:n kautta) ja aja se DEVissä rollback-transaktiossa. Kirjaa md5 otsikkoon.
2. Deploy `sumup-pos`, `sumup-notify` DEViin. DEV-salaisuuksiksi vain **sandbox**-arvot (`SUMUP_ENV=sandbox`). Älä käytä oikean tilin avaimia checkout-testeihin.
3. Tuo `site-texts.pending-import-150.json`.
4. `admin_set_sumup_mode('test', …)` DEVissä (vaatii Joonaksen hyväksynnän kytkentään) → Virtual Solo / sandbox-testi koko ketjulle.
5. PROD vasta kun 1–4 läpi ja Joonas hyväksyy; live vaatii `approved_by` ja `SUMUP_ENV=live`.
6. Tap to Pay / Payment Switch vasta erillisenä myöhempänä työnä (ks. Jatkokehitys).
