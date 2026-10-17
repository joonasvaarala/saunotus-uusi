# Talous-kehys (vaihe A:n UI) – datakerros ja sopimus

Tila: 17.10.2026. UI hallintaan (**Talous**: Tilaukset, Maksut, Raportit) ja asiakkaan tilaussivu. Sopimus: `/workspace/procountor/KOODARI_talous_A_D_fi.md` (v1) + migraatiot booking_29–34. Kehitetty mockilla ja **ajettu oikeaa testiprojektia vasten** (Tapio-havuhattu-test; ei tuotantokantaa, ei oikeita viestejä) – ks. kohta *Live-testi*.

## Rakenne

| Tiedosto | Tehtävä |
|---|---|
| `admin/talous-api.js` | **Ainoa** paikka, joka tuntee RPC-nimet, `p_`-parametrit ja vastausmuodot (`RPC`, `rpcBackend`, normalisoijat, `LIVE_ACTIONS`) |
| `admin/talous-mock.js` | Mock-PALVELIN: `createMock().rpc(nimi, parametrit)` vastaa sopimuksen RPC:itä (12 000 tilausta, ~8 700 maksua, deterministinen, keksittyä dataa) |
| `admin/views/talous*.js` | Näkymät (ei RPC-tietoa): `talous.js` (sivu, välilehdet, kielivalinta, banneri), `-orders`, `-payments`, `-reports`, `-ui` |
| `admin/csv.js` | Oma RFC 4180 -CSV: UTF-8 BOM, `;`, CRLF, desimaalipilkku, kaavainjektion esto |
| `admin/talous-i18n.js`, `talous-texts.js` | FI/EN (`?lang=en` tai kielipainike; avaimet samat, node-testi tarkistaa) |
| `shop/src/order*.js` | Asiakkaan tilaussivu: **`/tilaus/?t=<token>`** (= `settings.order_page_path`, sopimus/booking_29/34), EN-sivu `/en/order/?t=<token>`; tilauksen `locale` ohjaa oikean kielen sivulle |
| `scripts/e2e-talous.mjs`, `scripts/e2e-talous-live.mjs` | Mock-e2e (Playwright) ja live-e2e testiprojektia vasten |

## Mock ↔ oikea = yksi `rpc`-funktio

`createTalousApi({ rpc })` rakentaa `rpcBackend(rpc)`:n; mock käyttää samaa koodia `createMock().rpc`-funktiolla. Tilat:

* `?mock=1` (kyselyosassa tai `#/talous?mock=1`) → kaikki data mockista, banneri "Esimerkkidata", kirjoittavat napit toimivat mockina (ei tallenna).
* Muuten **oikea tila**. Jos jokin RPC puuttuu palvelimelta (404 / `PGRST202` / `42883`), **vain se toiminto** siirtyy mockiin ja sivu näyttää bannerin "Ominaisuus ei vielä käytössä – palvelimelta puuttuu: <rpc>". Muut toiminnot pysyvät oikeina (esim. tilaukset oikeita, raportit mockia kunnes vaihe D on tuotannossa).
* Kirjoittavat toiminnot (`LIVE_ACTIONS` talous-api.js:ssä: `addToOrder`, `createPaymentLink`, `refund`, `recordPayment`) ovat **päällä (true)**: ne kokeiltiin ensin testiprojektissa (live-e2e), ja ne ovat vain hallinnassa oikeuksien takana (`payments.manage`, hyvitys `payments.refund`, käsinkirjaus verkkomaksulle vain admin). Oikeassa tilassa kirjoitus **ei koskaan putoa mockiin** (404/virhe näytetään käyttäjälle). Lipun voi sulkea yhdellä rivillä/toiminto.
* Asiakkaan sivu: **ei automaattista mockia**. Puuttuva `public_*`-RPC (vaihe C) → "Tilaussivu ei ole vielä käytössä" + yhteystiedot. Mock vain `?mock=1`.

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
| Raportit (vaihe D) | `admin_report_daily(p_date)`, `admin_report_month(p_ym)`; CSV: `admin_report_csv(p_from, p_to, p_kind='lines'|'vat')` |
| Asiakas (vaihe C) | `public_get_order(p_token)`, `public_add_to_order(p_token, p_items)`, `public_request_cancel(p_token, p_reason)`, `public_get_receipt(p_order_token, p_receipt_no)` ← huom. kuitissa parametri `p_order_token` |

Virheet: `admin_*` nostaa SQLSTATE BK001 (koodi `details`-kentässä → `ApiError.code`); `public_*` palauttaa `{ok:false, code, message}` HTTP 200. UI kääntää tunnetut koodit (`nothing_to_pay`, `order_not_editable`, `amount_exceeds_refundable`, `refund_not_allowed`, `order_closed`, `request_exists`, `rate_limited` …) ja näyttää muuten palvelimen viestin.

## Päätökset (17.10.2026)

1. **CSV**: palvelimen `admin_report_csv(p_kind='lines')` (booking_34) tuottaa pyydetyt 12 saraketta (`pvm;kuitti_no;tilaus_no;maksutapa;tuoteryhmä;tuote;määrä;brutto;alv_%;alv_€;netto;hyvitys`; pvm PP.KK.VVVV, `hyvitys` = kyllä/ei, hyvitysrivin määrä negatiivinen). UI lataa palvelimen CSV:n sellaisenaan (BOM, `;`, CRLF). `csv.js` jää samoille sarakkeille varakirjoittajaksi/testattavaksi.
2. **Maksutila-lajittelu**: pysyy `unpaid_desc` (maksamattomat ensin); "Ensimmäinen varauspäivä" = `start_*`.
3. **Raportin `totals`** (palvelin, booking_34): `gross`/`net`/`vat` = myynti (kuitit) ennen hyvityksiä; `refunds_gross` **negatiivinen**; `net_after_refunds` = **brutto** hyvitysten jälkeen (gross + refunds_gross; nimi harhaanjohtava); `vat_after_refunds` ja `net_ex_vat_after_refunds` = ALV ja ALV-ton netto hyvitysten jälkeen. `by_vat`/`by_method_vat`/`by_category` sisältävät hyvitykset negatiivisina. UI-kortit: Myynti, Hyvitykset, Yhteensä hyvitysten jälkeen, ALV, Netto (ALV 0 %). Käyttäjä varmistaa vielä Bottiavustukselta.
4. **LIVE_ACTIONS** päällä, ks. yllä.
5. **Raporttien oikeus**: sivu/välilehti `payments.manage`. Huom. palvelin: `admin_report_daily` sallii `reports.daily` tai `reports.view`, `admin_report_month` ja CSV vaativat `reports.view` (staffilla vain `reports.daily`) → staff näkee päivän mutta kuukausi antaa `forbidden` (UI näyttää käännetyn virheen).
6. **Tilaussivun polku**: `/tilaus/` (+ `/en/order/`), ei aliaksia `/varaa/tilaus/`. Maksulinkin osoite = asiakassivuston origin + `order_page_path` + `?t=<public_token>` (linkin isäntä ei ole hallinnan osoite).
7. **Kuittilogo**: `public/img/logo-kuitti.png` (läpinäkyvä, 600 px, Havuhattu-merkki, tumma vihreä) → `seller.logo_url` = `<sivusto>/img/logo-kuitti.png`.

## Live-testi (testiprojekti)

`node booking/scripts/e2e-talous-live.mjs` ajaa **oikeaa Supabase-testiprojektia** vasten (ei mockia, ei `page.route`-vastauksia): lista/haku/suodattimet/lajittelu/laajennus, Maksut, Raportit (+ CSV), ALV-huomautus, maksun kirjaus, maksulinkki, tilaukseen lisäys, hyvitys, BK001-virhekoodit (UI + suora RPC) sekä staffin oikeudet. Osoite ja avaimet luetaan tiedostosta `LIVE_ENV` (oletus `/workspace/.live/env`; rivit `LIVE_URL`, `LIVE_ANON`, `LIVE_EMAIL`, `LIVE_PASSWORD`, `STAFF_EMAIL`, `STAFF_PASSWORD`; tiedostoa ei commitoida, avaimia ei tulosteta). Skripti kieltäytyy ajamasta tuotannon ref-tunnusta vasten. Testi kirjoittaa testiprojektiin (uudet tilaukset/maksut/hyvitykset, keksittyä dataa). Kuvat: `SHOT_DIR` (oletus `/workspace/screenshots-talous-live`).

Testiprojektin ketju: booking-migraatiot 01–23 repon järjestyksessä + 24–34 (`/workspace/johku/import/migrations/`; 31:n cron-osa jätetty pois, koska se kutsuu tuotannon osoitetta) + minimifikstuurit (`kb`/`public` mock-skeemat, `kb.businesses`, pg_cron) ja pieni keksitty seed.

## Havainnot RPC:istä (Bottiavustukselle)

* `admin_report_*`: `net_after_refunds` on brutto hyvitysten jälkeen (ei netto) – nimi harhaanjohtava; `refunds_gross` negatiivinen (booking_34; aiemmin 32 antoi positiivisen). Jakso-objektissa (`period`) ei ole `kind`-kenttää → UI päättelee päivä/kuukausi itse.
* `admin_report_month`/`admin_report_csv` vaativat `reports.view`, `admin_report_daily` hyväksyy myös `reports.daily` → staff (payments.manage + reports.daily) näkee Raportit-välilehden mutta kuukausi/CSV palauttaa `forbidden`.
* BK001-virheiden HTTP-status vaihtelee (esim. `forbidden` 400, `not_found` 404) → UI käyttää `details`-kentän konekoodia, ei statusta; puuttuva funktio/väärät parametrit = 404 + `PGRST202`. `public_*` palauttaa `{ok:false, code}` HTTP 200.
* `admin_refund`: syy vähintään 3 merkkiä; täyshyvitetylle maksulle `already_refunded` (ei `amount_exceeds_refundable`).
* Maksun `link_path` on suhteellinen (`/maksa/?p=<token>`, asetus `payment_link_path`); UI kokoaa täyden osoitteen asiakassivuston originilla (ei hallinnan osoitteella). Vanhat hallintanäkymät näyttivät vain `link_url`:n – korjattu.
* Maksulistalla `admin_list_payments` ei ole laskurivejä → laajennus hakee `admin_get_order`:n.

## Tulkinnat ja avoimet kohdat

1. **`p_manual_done`** (käsinkirjaus verkkomaksulle, vain admin): UI tarjoaa sen vain admin-roolille – varmista tarvittaessa tuotantotekstit.
2. **Laskurivin ALV/netto**: `payments[].lines[]` sisältää nyt netto/vat_eur (booking_34); vanhoissa vastauksissa ne lasketaan selaimessa (arvio).
3. **PDF**: nappi käyttää selaimen tulostusta (`@media print`). Palvelimen `report-pdf` (`verify_jwt=true`) kytketään myöhemmin.
4. **Maksulinkki asiakkaan sivulla**: näytetään vain jos `online_payment_enabled` ja avoin maksu (`link_path`); muuten "maksu paikan päällä".
