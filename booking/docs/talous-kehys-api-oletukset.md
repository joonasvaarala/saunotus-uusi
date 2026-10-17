# Talous-kehys (vaihe A:n UI) – datakerros ja sopimus

Tila: 17.10.2026. UI hallintaan (**Talous**: Tilaukset, Maksut, Raportit) ja asiakkaan tilaussivu. Sopimus: `/workspace/procountor/KOODARI_talous_A_D_fi.md` (v1) + migraatiot booking_29–34. Kehitetty mockilla ja **ajettu oikeaa testiprojektia vasten** (Tapio-havuhattu-test; ei tuotantokantaa, ei oikeita viestejä) – ks. kohta *Live-testi*.

## Rakenne

| Tiedosto | Tehtävä |
|---|---|
| `admin/talous-api.js` | **Ainoa** paikka, joka tuntee RPC-nimet, `p_`-parametrit ja vastausmuodot (`RPC`, `rpcBackend`, normalisoijat) |
| `admin/talous-mock.js` | Mock-PALVELIN: `createMock().rpc(nimi, parametrit)` vastaa sopimuksen RPC:itä (12 000 tilausta, ~8 700 maksua, deterministinen, keksittyä dataa) |
| `admin/views/talous*.js` | Näkymät (ei RPC-tietoa): `talous.js` (sivu, välilehdet, kielivalinta, banneri), `-orders`, `-payments`, `-reports`, `-receipts` (kuitit: PDF-linkki, teksti, uudelleenlähetys), `-ui` |
| `admin/csv.js` | Oma RFC 4180 -CSV: UTF-8 BOM, `;`, CRLF, desimaalipilkku, kaavainjektion esto |
| `admin/talous-i18n.js`, `talous-texts.js` | FI/EN (`?lang=en` tai kielipainike; avaimet samat, node-testi tarkistaa) |
| `shop/src/order*.js` | Asiakkaan tilaussivu: **`/tilaus/?t=<token>`** (= `settings.order_page_path`, sopimus/booking_29/34), EN-sivu `/en/order/?t=<token>`; tilauksen `locale` ohjaa oikean kielen sivulle |
| `scripts/e2e-talous.mjs`, `scripts/e2e-talous-live.mjs` | Mock-e2e (Playwright) ja live-e2e testiprojektia vasten |

## Mock ↔ oikea = yksi `rpc`-funktio

`createTalousApi({ rpc })` rakentaa `rpcBackend(rpc)`:n; mock käyttää samaa koodia `createMock().rpc`-funktiolla. Tilat:

* `?mock=1` (kyselyosassa tai `#/talous?mock=1`) → kaikki data mockista, banneri "Esimerkkidata", kirjoittavat napit toimivat mockina (ei tallenna).
* Muuten **oikea tila**. Jos jokin RPC puuttuu palvelimelta (404 / `PGRST202` / `42883`), **vain se toiminto** siirtyy mockiin ja sivu näyttää bannerin "Ominaisuus ei vielä käytössä – palvelimelta puuttuu: <rpc>". Muut toiminnot pysyvät oikeina (esim. tilaukset oikeita, raportit mockia jos raportti-RPC:t puuttuvat vanhasta kannasta).
* Kirjoittavat toiminnot (`addToOrder`, `createPaymentLink`, `refund`, `recordPayment`, `resendReceipt`) ovat **aina päällä** (ei käyttöönottolippuja): ne kokeiltiin testiprojektissa (live-e2e) ja ovat vain hallinnassa oikeuksien takana (`payments.manage`, hyvitys `payments.refund`, käsinkirjaus verkkomaksulle vain admin). Nappi on pois käytöstä vain kun toiminto ei sovellu tilaukselle (selite näkyy napin title-tekstinä). Oikeassa tilassa kirjoitus **ei koskaan putoa mockiin** (404/virhe näytetään käyttäjälle).
* **Kuitit (§3, §9.1):** `admin_get_order.receipts[]` (`id, receipt_no, kind, issued_at, total, payment_id, refund_id, public_token, sent_at`) listataan maksujen alla. **PDF** = tavallinen linkki `<SUPABASE_URL>/functions/v1/receipt-pdf?t=<public_token>` (`sb.js` `functionUrl`, uusi välilehti; `verify_jwt=false`). Osoite muodostetaan hallinnan omasta konfiguraatiosta, **ei** `admin_get_receipt().pdf_url`-kentästä: sen isäntä on `settings.functions_base_url`, joka testiprojektissa osoittaa tuotantoon. **Teksti** = `admin_get_receipt(p_receipt_id).text_body` (dialogi, Kopioi teksti). **Uudelleenlähetys** = `admin_resend_receipt(p_receipt_id)` → `{ok, email_queued}` (oikeus `payments.manage`; `email_queued=false` = asiakkaalla ei kelvollista sähköpostia). Vastaus ei kerro sähköpostin tilaa, joten UI lukee `integration_config.resend.mode` (henkilökunnan SELECT, RLS): `dry_run`/`off` → selvä varoitus ettei viesti lähde oikeasti; `live` → lähtee minuutin sisällä.
* **Raportin PDF:** `report-pdf` (`verify_jwt=true`) haetaan `fetch` + JWT → Blob → lataus (`sb.js` `fnBlob`); mockissa selaimen tulostus.
* Asiakkaan sivu: **ei automaattista mockia**. Puuttuva `public_*`-RPC → "Tilaussivu ei ole vielä käytössä" + yhteystiedot. Mock vain `?mock=1`.

## Käytetyt RPC:t (sopimuksen mukaan)

| Käyttö | RPC ja parametrit |
|---|---|
| Tilauslista | `admin_list_orders(p_search, p_status, p_payment_status, p_source, p_native, p_date_field, p_from, p_to, p_sort, p_limit, p_offset)` → `{total, rows[]}`. Lähetetään vain asetetut parametrit. `p_limit` max 200 (UI: 25/50/100). |
| Tilaus | `admin_get_order(p_order_id)` → `balance`, `items`, `payments[].lines/receipts/refunds`, `receipts`, `reservations`, `can_add`/`staff_can_add`, `public_token`, `order_page_path` |
| Maksulista | `admin_list_payments(p_search, p_method, p_status, p_from, p_to, p_sort, p_limit, p_offset)` → `{total, sum_paid, sum_refunded, rows[]}` – **ei laskurivejä**: Maksut-välilehden rivin laajennus hakee rivit `admin_get_order`:sta |
| Lisäpalveluluettelo (lisää tilaukseen -dialogi) | `admin_list_addons()` (olemassa oleva) |
| Lisää tilaukseen | `admin_add_to_order(p_order_id, p_items, p_create_link, p_send_email, p_note)`; UI tukee tyyppejä `addon` (reservation_id + code + quantity) ja `custom` (vaatii `bookings.override`) |
| Maksulinkki | `admin_create_payment_link(p_order_id, p_send_email, p_expires_days)` – maksamattomalle osalle (`balance.unpaid`) |
| Hyvitys | `admin_refund(p_payment_id, p_amount, p_reason)` – vaatii `payments.refund` (nappi disabloitu ilman oikeutta); syy vähintään 3 merkkiä (UI tarkistaa) |
| Maksun kirjaus | `admin_record_payment` (Kirjaa maksu -ikkuna; käsinkirjaus verkkomaksulle `p_manual_done` vain admin) |
| ALV-huomautus | `admin_list_vat_rates()` – puuttuvat ALV-kannat (`missing`) näytetään tiedotteena; virhe/puuttuva RPC → ei huomautusta |
| Kuitit | `admin_get_receipt(p_receipt_id)` → `{id, receipt_no, kind, issued_at, total_gross, snapshot, text_body, public_token, pdf_url, sent_at, …}`; `admin_resend_receipt(p_receipt_id)` → `{ok, email_queued}`; PDF: `GET <SUPABASE_URL>/functions/v1/receipt-pdf?t=<public_token>` |
| Raportit (vaihe D) | `admin_report_daily(p_date)`, `admin_report_month(p_ym)`; CSV: `admin_report_csv(p_from, p_to, p_kind='lines'|'vat')` |
| Asiakas (vaihe C) | `public_get_order(p_token)`, `public_add_to_order(p_token, p_items)`, `public_request_cancel(p_token, p_reason)`, `public_get_receipt(p_order_token, p_receipt_no)` ← huom. kuitissa parametri `p_order_token` |

Virheet: `admin_*` nostaa SQLSTATE BK001 (koodi `details`-kentässä → `ApiError.code`); `public_*` palauttaa `{ok:false, code, message}` HTTP 200. UI kääntää tunnetut koodit (`nothing_to_pay`, `order_not_editable`, `amount_exceeds_refundable`, `refund_not_allowed`, `order_closed`, `request_exists`, `rate_limited` …) ja näyttää muuten palvelimen viestin.

## Päätökset (17.10.2026)

1. **CSV**: palvelimen `admin_report_csv(p_kind='lines')` (booking_34) tuottaa pyydetyt 12 saraketta (`pvm;kuitti_no;tilaus_no;maksutapa;tuoteryhmä;tuote;määrä;brutto;alv_%;alv_€;netto;hyvitys`; pvm PP.KK.VVVV, `hyvitys` = kyllä/ei, hyvitysrivin määrä negatiivinen). UI lataa palvelimen CSV:n sellaisenaan (BOM, `;`, CRLF). `csv.js` jää samoille sarakkeille varakirjoittajaksi/testattavaksi.
2. **Maksutila-lajittelu**: pysyy `unpaid_desc` (maksamattomat ensin); "Ensimmäinen varauspäivä" = `start_*`.
3. **Raportin `totals`** (sopimus §11, booking_35): `gross`/`net`/`vat` = myynti (kuitit) ennen hyvityksiä; `refunds_gross` **negatiivinen**; **`gross_after_refunds`** = brutto hyvitysten jälkeen (UI:n kortti "Myynti hyvitysten jälkeen (brutto)"); `net_after_refunds` on **DEPRECATED** (sama arvo, UI ei käytä sitä); `vat_after_refunds` = ALV ja `net_ex_vat_after_refunds` = veroton summa hyvitysten jälkeen (`gross_after_refunds = vat_after_refunds + net_ex_vat_after_refunds`). `period.kind` = `'day'|'month'` luetaan palvelimelta; varapäättely (sama päivä = päivä) vain jos kenttä puuttuu. `by_vat`/`by_method_vat`/`by_category` sisältävät hyvitykset negatiivisina.
4. Kirjoittavat toiminnot päällä ilman lippuja, ks. yllä.
5. **Raporttien oikeudet** (sopimus §11, tarkoituksellinen): `admin_report_daily` = `reports.daily` TAI `reports.view`; `admin_report_month`, `admin_report_csv` ja `report-pdf?kind=month` = vain `reports.view`. UI: sivu vaatii `payments.manage`; **Raportit-välilehti ja päiväraportti näkyvät** kun käyttäjällä on `reports.daily` tai `reports.view` (muuten välilehti piilotetaan); **kuukausivalinta ja CSV ovat pois käytöstä** ilman `reports.view`:tä ja näytetään selkeä ilmoitus (`r-limited`). Oikeudet luetaan aina oikealta käyttäjältä (myös `?mock=1`).
6. **Tilaussivun polku**: `/tilaus/` (+ `/en/order/`), ei aliaksia `/varaa/tilaus/`. Maksulinkin osoite = asiakassivuston origin + `order_page_path` + `?t=<public_token>` (linkin isäntä ei ole hallinnan osoite).
7. **Kuittilogo**: `public/img/logo-kuitti.png` (läpinäkyvä, 600 px, Havuhattu-merkki, tumma vihreä) → `seller.logo_url` = `<sivusto>/img/logo-kuitti.png`.
8. **Johku ei kirjanpitoon** (sopimus §12, migraatio booking_41): `admin_report_daily`/`admin_report_month` palauttavat ylätason `statistics.johku` (`label`, `accounting:false`, `basis`, `orders`, `gross`, `refunded_orders`, `refunded_gross`, `by_method[]`). Raportit-välilehti näyttää sen **erillisenä lohkona** "Johku (ei kirjanpitoon)" (katkoviivareunus, hiekka-tausta, oma selite); lukuja **ei lasketa `totals`-kortteihin**, lohko ei ole mukana PDF-/CSV-raportissa (palvelin ei sisällytä) eikä tulostusnäkymässä (`tl-noprint`). Avain puuttuessa (vanha palvelin) lohkoa ei näytetä. `admin_list_payments`: rivillä `source`/`is_johku` (Johku-merkki, ei kuittia), ylätasolla `sum_paid_ex_johku`, `sum_refunded_ex_johku`, `johku_rows`; Maksut-listan summarivi käyttää `*_ex_johku`-summia ja näyttää Johku-rivien määrän, kun niitä on (`johku_rows` > 0; tuotannossa nyt 0). Vanha palvelin ilman kenttiä → summat = `sum_paid`/`sum_refunded`, `johku_rows` = 0. Tilaukset: Johku-tilauksella ei ole maksurivejä (maksutieto vain tilauksella) → maksuosio kertoo "Johku-tilaus: maksu on kirjattu Johkuun (ei kirjanpitoon, ei kuittia)"; mahdolliset maksurivit saavat Johku-merkin.

## Live-testi (testiprojekti)

`node booking/scripts/e2e-talous-live.mjs` ajaa **oikeaa Supabase-testiprojektia** vasten (ei mockia, ei `page.route`-vastauksia): lista/haku/suodattimet/lajittelu/laajennus, Maksut, Raportit (+ CSV), ALV-huomautus, maksun kirjaus, maksulinkki, tilaukseen lisäys, hyvitys, BK001-virhekoodit (UI + suora RPC) sekä staffin oikeudet. Osoite ja avaimet luetaan tiedostosta `LIVE_ENV` (oletus `/workspace/.live/env`; rivit `LIVE_URL`, `LIVE_ANON`, `LIVE_EMAIL`, `LIVE_PASSWORD`, `STAFF_EMAIL`, `STAFF_PASSWORD`; tiedostoa ei commitoida, avaimia ei tulosteta). Skripti kieltäytyy ajamasta tuotannon ref-tunnusta vasten. Testi kirjoittaa testiprojektiin (uudet tilaukset/maksut/hyvitykset, keksittyä dataa). Kuvat: `SHOT_DIR` (oletus `/workspace/screenshots-talous-live`).

Testiprojektin ketju: booking-migraatiot 01–23 repon järjestyksessä + 24–34 (`/workspace/johku/import/migrations/`; 31:n cron-osa jätetty pois, koska se kutsuu tuotannon osoitetta) + minimifikstuurit (`kb`/`public` mock-skeemat, `kb.businesses`, pg_cron) ja pieni keksitty seed.

## Havainnot RPC:istä (Bottiavustukselle)

* `admin_report_*` (booking_35): `net_after_refunds` on nyt DEPRECATED ja `gross_after_refunds` korvaa sen; `period.kind` palvelimelta – UI on päivitetty käyttämään niitä. `refunds_gross` negatiivinen (booking_34).
* Roolit (§11, tarkoituksellinen): `admin_report_daily` = `reports.daily`/`reports.view`; kuukausi, CSV ja report-pdf month = vain `reports.view`. Staff näkee päivän, kuukausi palauttaa `forbidden` (UI estää valinnan etukäteen). Live-testattu oikealla staff-käyttäjällä.
* BK001-virheiden HTTP-status vaihtelee (esim. `forbidden` 400, `not_found` 404) → UI käyttää `details`-kentän konekoodia, ei statusta; puuttuva funktio/väärät parametrit = 404 + `PGRST202`. `public_*` palauttaa `{ok:false, code}` HTTP 200.
* `admin_refund`: syy vähintään 3 merkkiä; täyshyvitetylle maksulle `already_refunded` (ei `amount_exceeds_refundable`).
* Maksun `link_path` on suhteellinen (`/maksa/?p=<token>`, asetus `payment_link_path`); UI kokoaa täyden osoitteen asiakassivuston originilla (ei hallinnan osoitteella). Vanhat hallintanäkymät näyttivät vain `link_url`:n – korjattu.
* Maksulistalla `admin_list_payments` ei ole laskurivejä → laajennus hakee `admin_get_order`:n.

## Tulkinnat ja avoimet kohdat

1. **`p_manual_done`** (käsinkirjaus verkkomaksulle, vain admin): UI tarjoaa sen vain admin-roolille – varmista tarvittaessa tuotantotekstit.
2. **Laskurivin ALV/netto**: `payments[].lines[]` sisältää nyt netto/vat_eur (booking_34); vanhoissa vastauksissa ne lasketaan selaimessa (arvio).
3. **PDF**: nappi käyttää selaimen tulostusta (`@media print`). Palvelimen `report-pdf` (`verify_jwt=true`) kytketään myöhemmin.
4. **Maksulinkki asiakkaan sivulla**: näytetään vain jos `online_payment_enabled` ja avoin maksu (`link_path`); muuten "maksu paikan päällä".
