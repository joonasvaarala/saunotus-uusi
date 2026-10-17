# Talous-kehys (vaihe A:n UI) – datakerros ja sopimus

Tila: 17.10.2026. UI-kehys hallintaan (**Talous**: Tilaukset, Maksut, Raportit) ja asiakkaan tilaussivu. Sopimus: `/workspace/procountor/KOODARI_talous_A_D_fi.md` (v1). Kehys on kehitetty ja testattu **vain mock-datalla** (ei tuotantokantaa, ei oikeita viestejä).

## Rakenne

| Tiedosto | Tehtävä |
|---|---|
| `admin/talous-api.js` | **Ainoa** paikka, joka tuntee RPC-nimet, `p_`-parametrit ja vastausmuodot (`RPC`, `rpcBackend`, normalisoijat, `LIVE_ACTIONS`) |
| `admin/talous-mock.js` | Mock-PALVELIN: `createMock().rpc(nimi, parametrit)` vastaa sopimuksen RPC:itä (12 000 tilausta, ~8 700 maksua, deterministinen, keksittyä dataa) |
| `admin/views/talous*.js` | Näkymät (ei RPC-tietoa): `talous.js` (sivu, välilehdet, kielivalinta, banneri), `-orders`, `-payments`, `-reports`, `-ui` |
| `admin/csv.js` | Oma RFC 4180 -CSV: UTF-8 BOM, `;`, CRLF, desimaalipilkku, kaavainjektion esto |
| `admin/talous-i18n.js`, `talous-texts.js` | FI/EN (`?lang=en` tai kielipainike; avaimet samat, node-testi tarkistaa) |
| `shop/src/order*.js` | Asiakkaan tilaussivu (`/varaa/tilaus/?t=<token>`, EN `/en/book/order/`, sekä sopimuksen oletuspolut `/tilaus/` ja `/en/order/`) |

## Mock ↔ oikea = yksi `rpc`-funktio

`createTalousApi({ rpc })` rakentaa `rpcBackend(rpc)`:n; mock käyttää samaa koodia `createMock().rpc`-funktiolla. Tilat:

* `?mock=1` (kyselyosassa tai `#/talous?mock=1`) → kaikki data mockista, banneri "Esimerkkidata", kirjoittavat napit toimivat mockina (ei tallenna).
* Muuten **oikea tila**. Jos jokin RPC puuttuu palvelimelta (404 / `PGRST202` / `42883`), **vain se toiminto** siirtyy mockiin ja sivu näyttää bannerin "Ominaisuus ei vielä käytössä – palvelimelta puuttuu: <rpc>". Muut toiminnot pysyvät oikeina (esim. tilaukset oikeita, raportit mockia kunnes vaihe D on tuotannossa).
* Kirjoittavat toiminnot (`LIVE_ACTIONS` talous-api.js:ssä: `addToOrder`, `createPaymentLink`, `refund`) ovat oikeassa tilassa **pois päältä** (`FeatureNotReady`, nappi disabloitu + selite). Sopimuksen mukaan nämä RPC:t ovat vaiheessa A jo tuotannossa, mutta rahaa liikuttavat toiminnot kytketään vasta kun ne on kokeiltu käyttöliittymästä testikannalla. **Kytkentä = `LIVE_ACTIONS.<toiminto> = true`** (yksi rivi/toiminto).
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
| Hyvitys | `admin_refund(p_payment_id, p_amount, p_reason)` – vaatii `payments.refund` (nappi disabloitu ilman oikeutta; mockissa sallittu) |
| Raportit (vaihe D) | `admin_report_daily(p_date)`, `admin_report_month(p_ym)`; CSV: `admin_report_csv(p_from, p_to, p_kind='lines')` |
| Asiakas (vaihe C) | `public_get_order(p_token)`, `public_add_to_order(p_token, p_items)`, `public_request_cancel(p_token, p_reason)`, `public_get_receipt(p_order_token, p_receipt_no)` ← huom. kuitissa parametri `p_order_token` |

Virheet: `admin_*` nostaa SQLSTATE BK001 (koodi `details`-kentässä → `ApiError.code`); `public_*` palauttaa `{ok:false, code, message}` HTTP 200. UI kääntää tunnetut koodit (`nothing_to_pay`, `order_not_editable`, `amount_exceeds_refundable`, `refund_not_allowed`, `order_closed`, `request_exists`, `rate_limited` …) ja näyttää muuten palvelimen viestin.

## Tulkinnat ja avoimet kohdat

1. **Maksutila-lajittelu**: sopimuksessa ei ole `payment_status`-lajittelua, vain `paid_*`/`unpaid_desc`. UI:n "Maksutila" = `unpaid_desc` (maksamattomat ensin, suunta lukittu). "Ensimmäinen varauspäivä" = `start_*`.
2. **Raportin CSV**: pyydetyt sarakkeet (`pvm;kuitti_no;tilaus_no;maksutapa;tuoteryhmä;tuote;määrä;brutto;alv_%;alv_€;netto;hyvitys`) tehdään asiakaspuolella (`csv.js`), kun raportti sisältää rivitason `lines`-kentän (nyt vain mock). Sopimuksen `admin_report_daily/_month` palauttaa vain koosteet (ei tuoterivejä) ja `admin_report_csv` omat sarakkeet (`pvm;klo;kuitti;tilaus;tyyppi;maksutapa;tuoteryhma;tuote;maara;brutto;alv_prosentti;alv_eur;netto`, ei `hyvitys`-saraketta) → oikeassa tilassa CSV-nappi lataa **palvelimen CSV:n sellaisenaan**. Päätettävä: halutaanko palvelimelle pyydetyt sarakkeet (suositus: `admin_report_csv` tuottaa 12 saraketta) vai asiakaspuolen muunnos.
3. **Raportin `totals`**: tulkinta `gross`/`net`/`vat` = myynti (kuitit) ennen hyvityksiä, `refunds_gross` negatiivinen, `net_after_refunds` hyvitysten jälkeen; `by_vat`/`by_method_vat`/`by_category` sisältävät hyvitykset negatiivisina (taulukon yhteensä = brutto + hyvitykset). Vahvistettava palvelimen toteutuksesta.
4. **Laskurivin ALV/netto**: `payments[].lines[]` sisältää vain `amount_gross` + `vat_rate` → ALV ja netto lasketaan selaimessa (arvio; kuitin pyöristys tehdään loppusummasta).
5. **PDF**: nappi käyttää selaimen tulostusta (`@media print`). Palvelimen `report-pdf` (vaihe D, `verify_jwt=true`) kytketään myöhemmin.
6. **Oikeudet**: navigaatio ja sivu `payments.manage`; hyvitys `payments.refund`; mukautettu rivi `bookings.override`. Raporteille ei vielä erillistä oikeutta (staff näkee ne, koska heillä on `payments.manage`) → harkittava `reports.view`.
7. **Tilaussivun polku**: sopimuksen oletus `settings.order_page_path = /tilaus/`; rakennus tuottaa sivun sekä `/tilaus/` että `/varaa/tilaus/` (EN `/en/order/` ja `/en/book/order/`). Yhteinen `<title>` → `check.mjs` varoittaa kaksoistitlestä (noindex-sivut, ei virhe).
8. **Maksulinkki asiakkaan sivulla**: näytetään vain jos `online_payment_enabled` ja avoin maksu (`link_path`); muuten "maksu paikan päällä".
