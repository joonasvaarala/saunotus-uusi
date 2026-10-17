# Koodarille: taloushallinto vaiheet A–D – rajapintasopimus (v1, 17.10.2026)

Supabase `sxbofnuisemspgquoxyv`, skeema `booking`. Pohja: `TALOUSHALLINTO_SUUNNITELMA_fi.md`; kuittisäännöt `KUITTI_VAATIMUKSET_fi.md`. **Tämä on sopimus: nimet, parametrit ja palautusrakenteet eivät muutu ilman ilmoitusta.** Bottiavustus toteuttaa tietokannan ja edge-funktiot ja ilmoittaa kun vaihe on tuotannossa (milestone A, B, C, D). Visma Pay ja Procountor eivät ole käytössä: rakenteet ovat valmiina, mutta `integration_config`-tilassa `off`/`dry_run`.

## 0. Yleiset säännöt
- **Kutsu:** `supabase.schema('booking').rpc(nimi, {p_param: …})`; JSON-vastaus. `admin_*` vaativat kirjautumisen (authenticated + `booking.staff`), `public_*` toimivat anon-avaimella tokenilla, `svc_*`/`_*` vain service_role.
- **Virheet:** `admin_*` nostavat SQLSTATE `BK001`, `message` = suomenkielinen teksti, `details`/`detail` = konekoodi (kuten nykyiset). `public_*` palauttaa `{ok:false, code, message}` (HTTP 200), kuten nykyiset. Uudet koodit: `forbidden`, `not_found`, `invalid_sort`, `invalid_param`, `order_not_editable`, `order_closed` (lisäysaika päättynyt), `nothing_to_pay`, `amount_exceeds_unpaid`, `amount_exceeds_refundable`, `invalid_payment_method`, `invalid_items`, `item_not_found`, `invalid_vat`, `vat_missing`, `below_paid` (hinta ei voi laskea alle maksetun), `refund_not_allowed`, `already_refunded`, `receipt_not_found`, `rate_limited`, `request_exists`; lisäksi kaikki moottorin koodit (`slot_taken`, `no_therapist`, `addon_quantity`, `addon_not_allowed`, …) välittyvät ennallaan.
- **Rahat:** `numeric` (EUR, 2 desimaalia) JSON-lukuna. Ajat ISO 8601 (UTC-offset), päivämäärärajat Europe/Helsinki.
- **Oikeudet** (`role_permissions`): olemassa `bookings.manage`, `bookings.override`, `payments.manage`, `catalog.edit`, `settings.edit`; **uudet** `payments.refund` (manager, admin), `reports.view` (manager, admin: päivä+kuukausi+CSV/PDF), `reports.daily` (staff, manager, admin: vain päivä). Luku (`admin_list_*`, `admin_get_order`, `admin_get_receipt`) = mikä tahansa henkilökunta.
- **Tilausnumerot:** natiivit 15000→ (`orders.order_no`, sekvenssi jo tuotannossa). Johku-tilaukset (`external_source='johku'`) ovat vain luettavia: lisäys/maksu/hyvitys → `order_not_editable`.
- **Saldo** (`balance`, kaikissa tilausvastauksissa): `{total, paid, refunded, pending_link, unpaid, unpaid_unlinked}`; `paid` = maksetut summat, `refunded` = tehdyt hyvitykset, `pending_link` = avoimet maksulinkit, `unpaid = total − (paid − refunded)` (≥0), `unpaid_unlinked = unpaid − pending_link`.
- **ALV kuiteilla:** summataan laskun loppusummasta verokannoittain (pyöristys 2 desimaaliin ryhmätasolla, ei riveittäin; KUITTI_VAATIMUKSET). Käteinen pyöristetään 0,05 €:n tarkkuuteen (`rounding`).

## 1. Taulut (lyhyesti; kaikki `booking`, RLS päällä, luku vain staff, kirjoitus vain funktioilla, audit päällä)
| Taulu | Sisältö |
|---|---|
| `vat_rates` | `rate` (pk), `label`, `active` (sallittu uusille riveille), `sort_order`. Siemen: 0, 13,5, 25,5 aktiiviset; 10, 14, 24 vanhoja (inactive). Trigger estää natiivin `order_items`/`addons`-rivin kannan jota ei ole aktiivisena |
| `payment_lines` | maksun laskurivit: `payment_id`, `order_item_id`, `description`, `quantity`, `amount_gross`, `vat_rate`, `line_vat`, `line_net` (generoidut), `kind`. Yksi maksu → monta riviä; tilaus → monta maksua |
| `payments` (+sarakkeet) | `rounding` (käteispyöristys), `link_sent_at`; entiset: method, provider, provider_ref, status, amount, refunded_amount, paid_at, link_token, link_url, link_expires_at, raw |
| `refunds` | `payment_id`, `order_id`, `amount`, `reason`, `status` (requested/processing/done/failed/cancelled), `provider`, `provider_refund_id`, `lines jsonb`, `created_by`, `done_at` |
| `receipts` | `receipt_no` (K-2026-000001 / hyvityskuitti H-2026-000001, aukoton sarja/vuosi), `kind` (receipt/refund_receipt), `order_id`, `payment_id`, `refund_id`, `original_receipt_id`, `issued_at`, `total_gross`, **muuttumaton `snapshot jsonb`**, `text_body`, `public_token` (uuid), `pdf_path`, `sent_at`. Ei poistettavissa, snapshot ei muutettavissa (6 v säilytys) |
| `email_outbox` | `kind` (order_confirmation, payment_link, receipt, refund_receipt, cancel_request_ack, order_change), `order_id`, `receipt_id`, `payment_id`, `locale`, `dedupe_key` (uniikki), `status` (pending/sending/sent/failed/dead/skipped/dry_run), `attempts`, `next_attempt_at`, `provider_id`, `last_error`, `payload jsonb` (ei henkilötietoja; vastaanotin luetaan lähetyshetkellä) |
| `order_requests` | asiakkaan pyynnöt: `order_id`, `kind` (cancel/change/refund_due), `status` (open/handled/rejected), `reason`, `payload`, `handled_by/at`, `note` |
| `accounting_outbox` | Procountor-valmius (ei käytössä): `kind`, `dedupe_key`, `payload`, `status`, `attempts`, `environment`; täyttyy vasta kun `integration_config.procountor.mode<>'off'` |
| `integration_config` | `key` (resend/vismapay/procountor), `mode` (off/dry_run/live), `settings jsonb` (ei salaisuuksia), `notes`. Salaisuudet vain Edge-salaisuuksina (ks. `docs/talous-integraatiot.md`) |
| `settings` (avaimet) | `seller` (jsonb: nimi, virallinen nimi, y-tunnus, alv_tunnus, osoite, postinumero, kaupunki, sähköposti, puhelin, www, logo_url, kuitin alateksti), `site_base_url`, `payment_link_path` (`/maksa/`), `order_page_path` (`/tilaus/`) |

## 2. Vaihe A – tilaukset, maksut, ALV (hallinta: Tilaukset ja Maksut)

### 2.1 `admin_list_orders`
Params (kaikki valinnaisia): `p_search text` (tilausnumero tai Johku-numero tarkka; muuten nimi/sähköposti/puhelin/yritys, osittainen), `p_status text` (pending/confirmed/cancelled/expired/completed), `p_payment_status text` (unpaid/pending/paid/partially_paid/refunded/partially_refunded/failed), `p_source text` (web/admin/phone/email/walk_in/johku_import/other), `p_native boolean` (true = vain natiivit 15000→), `p_date_field text` (`created`|`start`, oletus created), `p_from date`, `p_to date`, `p_sort text` (`created_desc` oletus, `created_asc`, `order_no_desc|asc`, `total_desc|asc`, `start_desc|asc`, `paid_desc|asc`, `unpaid_desc`), `p_limit int` (1–200, oletus 50), `p_offset int`.
Palauttaa `{total:int, rows:[{order_id, order_no, johku_order_no, created_at, status, payment_status, source_channel, is_native, total, paid, refunded, unpaid, customer_id, customer_name, customer_company, customer_kind, first_start, last_end, reservation_count, payment_count, last_paid_at, receipt_count}]}`. Tuntematon lajittelu → `invalid_sort`.

### 2.2 `admin_get_order(p_order_id bigint)` (laajennettu; vanhat avaimet säilyvät)
Vanhat: `order_id, order_no, status, payment_status, total, source_channel, created_at, customer_note, internal_note, customer_kind, billing, invoice_reference, customer{…}, reservations[{id,status,product_name,mode,starts_at,ends_at,persons,notes,item_total,addons[…]}], payments[{id,method,status,amount,paid_at}]`.
Uudet: `public_token, order_page_path` (kokoa `site_base_url + order_page_path + '?t=' + public_token`), `is_native`, `balance{…}`, `can_add` + `add_until` (= viimeisen aktiivisen varauksen päättymisaika; staff voi lisätä myös sen jälkeen jos tila confirmed/completed → `can_add` kertoo asiakassivun säännön, `staff_can_add` hallinnan), `items[{id, parent_item_id, kind, product_id, name, quantity, unit_price, line_total, vat_rate, line_vat, line_net, covered, remaining}]`, `payments[]` laajennettuna: `{…, provider, provider_status, refunded_amount, rounding, link_token, link_path, link_expires_at, note, created_at, lines[{id, order_item_id, description, quantity, amount_gross, vat_rate}], receipts[{id, receipt_no, kind, issued_at, public_token, sent_at}], refunds[{id, amount, status, reason, created_at, done_at}]}`, `receipts[]` (kaikki tilauksen kuitit), `refunds[]`, `emails[{kind,status,sent_at}]`, `requests[]` (order_requests, vaihe C).

### 2.3 `admin_list_payments`
Params: `p_search` (tilausnro, kuittinro, asiakas, maksun id), `p_method`, `p_status`, `p_from date`, `p_to date` (rajaus `coalesce(paid_at, created_at)` Helsingin päivinä), `p_sort` (`paid_desc` oletus, `paid_asc`, `amount_desc|asc`, `order_no_desc|asc`), `p_include_placeholders boolean` (oletus false: piilottaa rivittömät "odotettu maksu" -rivit), `p_limit`, `p_offset`.
Palauttaa `{total, sum_paid, sum_refunded, rows:[{payment_id, order_id, order_no, method, method_label, provider, status, amount, refunded_amount, rounding, paid_at, created_at, customer_name, line_count, receipt_no, receipt_token}]}`.

### 2.4 `admin_add_to_order(p_order_id bigint, p_items jsonb, p_create_link boolean default false, p_send_email boolean default false, p_note text default null)`
Oikeus `bookings.manage` (`custom`-rivi: `bookings.override`). Tilan oltava `confirmed|completed` ja natiivi. Tilauksen summa kasvaa; vaikutus maksutilaan: paid → `partially_paid`. `p_items` (1–20 alkiota), tyypit:
- `{"type":"addon","reservation_id":N,"addon_id":N | "code":"saunavihta","quantity":n}` (rajat kuten nyt; olemassa oleva + uusi määrä ≤ raja)
- `{"type":"reservation","product_id":N,"start":"ts","end":"ts?","persons":n,"space_id":N?,"price":x?,"parent_reservation_id":N?,"override":bool?,"override_reason":"?","addons":[{code,quantity}]?}` (resurssivaraus/hoito/saunotus, moottori kuten `admin_create_resource_booking`)
- `{"type":"reservation","rule_id":N,"date":"YYYY-MM-DD","persons":n,"addons":[…]?}` (sääntövuoro)
- `{"type":"product","product_id":N,"quantity":n}` (vain `product_rental`-ryhmä: vihta, pyyhe …; hinta+ALV kb:stä)
- `{"type":"custom","description":"…","amount":12.5,"vat_rate":25.5,"quantity":1}` (poikkeus; negatiivinen = alennus)
Palauttaa `{ok:true, order_id, added:[{item_id, name, line_total, reservation_id?}], added_total, balance, payment: null | {payment_id, link_token, link_path, amount, expires_at}, email_queued}`. `p_create_link` luo/päivittää maksulinkin maksamattomalle osalle (ks. 2.5); `p_send_email` jonottaa `payment_link`-viestin.

### 2.5 `admin_create_payment_link(p_order_id bigint, p_send_email boolean default false, p_expires_days int default 14, p_note text default null)`
Oikeus `payments.manage`. Luo `payments`-rivin (`status pending`, `provider visma_pay`, `method visma_pay`) **maksamattomalle osalle** + `payment_lines` kattamattomista riveistä. Jos avoin linkki jo kattaa saman summan → palautetaan sama (idempotentti); muuten vanhat avoimet linkit peruutetaan ja luodaan yksi uusi koko jäännökselle. **Pysyvä `link_token` (uuid)**; asiakkaalle lähtevä osoite on `site_base_url + payment_link_path + '?p=' + link_token`. Tuore Visma-token luodaan vasta kun asiakas avaa linkin (edge `vismapay-start`, vaihe E; nyt `integration_config.vismapay.mode='off'` → `online_payment_enabled:false`, sivu näyttää "maksu paikan päällä").
Palauttaa `{ok, payment_id, link_token, link_path, amount, expires_at, lines[], online_payment_enabled, email_queued}`. Virheet: `nothing_to_pay`, `order_not_editable`.

### 2.6 `admin_record_payment(p_order_id bigint, p_method text, p_amount numeric, p_note text default null, p_lines jsonb default null)`
Korvaa nykyisen (sama nimi, lisäparametri). Oikeus `payments.manage`. `p_method` aktiivinen käsin kirjattava (`is_manual`). **Summatarkistus:** `0 < p_amount ≤ unpaid` muuten `amount_exceeds_unpaid`. Rivit: oletuksena kohdistetaan kattamattomille riveille järjestyksessä; `p_lines=[{item_id, amount}]` kohdistaa käsin (summan pitää = `p_amount`). Käteinen: `rounding` lasketaan (0,05 €). Kirjaus on heti `paid`, luo kuitin (vaihe B) ja vahvistaa pitovaraukset kuten ennen. Rivittömät "odotettu maksu" -paikkaajat peruuntuvat.
Palauttaa `{ok:true, payment_id, balance, receipt_id|null, receipt_no|null, rounding}`.

### 2.7 `admin_refund(p_payment_id bigint, p_amount numeric, p_reason text, p_lines jsonb default null)`
Oikeus `payments.refund` (manager, admin). `0 < p_amount ≤ amount − refunded_amount` (`amount_exceeds_refundable`); maksun tila paid/partially_refunded. Rivijako `p_lines=[{payment_line_id, amount}]` (oletus suhteessa riveihin).
- **Käsin kirjatut maksutavat** (käteinen, kortti, MobilePay, tilisiirto…): hyvitys kirjautuu heti `done`, `refunded_amount` kasvaa, **hyvityskuitti** (oma numero, viite alkuperäiseen kuittiin, negatiiviset summat/ALV) luodaan ja jonotetaan asiakkaalle.
- **Visma Pay -maksu:** rivi `status='requested'`, `provider='visma_pay'`; edge `vismapay-refund` (vaihe E, nyt `off`) lähettää `create_refund` ja asettaa `done` + hyvityskuitin kun notify tulee. `integration_config.vismapay.mode='off'` → `refund_not_allowed` ("Verkkomaksun hyvitys ei ole vielä käytössä – hyvitä Visman portaalissa ja kirjaa käsin"), käsinkirjaus mahdollinen `p_manual_done:=true` (vain admin).
Palauttaa `{ok, refund_id, status, balance, receipt_id|null, receipt_no|null}`.

### 2.8 ALV
- `admin_list_vat_rates()` → `{rates:[{rate,label,active,products,addons}], missing:[{kind:'product'|'addon', id, name}]}` (tuotteet joilla ALV tyhjä).
- `admin_set_product_vat(p_product_id bigint, p_vat_rate numeric, p_note text default null)` (`catalog.edit`; kanta oltava aktiivisena `vat_rates`issa, muuten `invalid_vat`) → `{ok, product_id, old, new, applies:'new_rows_only'}`. Vain uudet tilausrivit; vanhat rivit säilyvät (tilausrivi tallentaa kannan). Kirjautuu `audit_log` (`ADMIN_SET_VAT`) ja `kb.change_log`.
- `admin_set_addon_vat(p_addon_id bigint, p_vat_rate numeric)` samoin. `admin_upsert_vat_rate(p_rate numeric, p_label text, p_active boolean)` (`settings.edit`).
- `admin_update_product`/`admin_update_addon` hylkäävät `vat_rate`-arvon joka ei ole aktiivinen (`invalid_vat`).

### 2.9 Muuttuneet olemassa olevat
`admin_set_reservation_addons` ei salli tilauksen summan laskua alle maksetun (`below_paid`). Maksun merkitseminen maksetuksi (mikä tahansa reitti: hallinta, Visma-adapteri) kohdistaa rivit ja luo kuitin automaattisesti.

## 3. Vaihe B – kuitit ja sähköposti
- **Kuitti syntyy automaattisesti** kun maksu muuttuu `paid`-tilaan (ja hyvityskuitti kun hyvitys `done`). Sarjat: `K-YYYY-NNNNNN`, `H-YYYY-NNNNNN` (aukoton, vuosittain nollautuva).
- **Snapshot (v1)** (muuttumaton; sama data tekstille ja PDF:lle):
```
{ "v":1, "document":"receipt|refund_receipt", "receipt_no", "issued_at", "issued_local":"17.10.2026 11:22",
  "seller":{"name","legal_name","business_id","vat_id":"FI…","address","zip","city","email","phone","web","logo_url","footer"},
  "order_no", "payment":{"id","method","method_label","paid_at"},
  "buyer": null | {"name","company","business_id","address","zip","city","reference"},   // vain yritysasiakas
  "invoice_required": bool,                       // yritys && summa > 400 € → "lasku/kuitti", ostajan tiedot pakolliset
  "lines":[{"description","quantity","unit_gross","unit_net","line_gross","line_net","vat_rate","kind","starts_at","ends_at"}],
  "vat":[{"rate","net","vat","gross"}], "total_gross","total_net","total_vat","rounding","total_paid","currency":"EUR",
  "original":{"receipt_no","issued_at"} | null,   // hyvityskuitti
  "reason": null|"…", "locale":"fi" }
```
- RPC: `admin_get_receipt(p_receipt_id bigint)` → `{id, receipt_no, kind, issued_at, total_gross, snapshot, text_body, public_token, pdf_url, sent_at}`; `admin_resend_receipt(p_receipt_id bigint)` → `{ok, email_queued}`; `public_get_receipt(p_order_token uuid, p_receipt_no text)` (asiakas) → sama sisältö ilman henkilötietoja muista tilauksista.
- **PDF:** edge-funktio `receipt-pdf` (pdf-lib, `verify_jwt=false`): `GET /functions/v1/receipt-pdf?t=<receipt.public_token>` → `application/pdf` (tallennetaan yksityiseen Storageen `receipts/`). **Teksti:** `text_body` (`admin_get_receipt`/`public_get_receipt`); sama teksti menee viestin plain-text-osaan.
- **Sähköposti:** `send-emails` (edge, Resend; ajastus pg_cron 1 min). Riippumaton: lukee salaisuuden `RESEND_API_KEY`; `integration_config.resend.mode='dry_run'` (oletus) → viestit renderöidään ja merkitään `dry_run`, **mitään ei lähde**. Live vain kun avain on asetettu ja mode=`live`. **Tilausvahvistus + linkki lähtee aina kun natiivi tilaus vahvistuu** (trigger `orders` → `email_outbox`, dedupe `order_confirmation:<order_id>`, viive 45 s); kuitti-/hyvityskuittiviesti (PDF liitteenä + tekstikuitti rungossa) kun kuitti syntyy; maksulinkki kun `p_send_email`.
- **Koodarin vastuu (mallit):** `booking/supabase/functions/send-emails/templates.ts`: funktio `render(kind, data, locale) → {subject, text, html}`; `data` = `email_outbox_claim`-rivi: `{id, kind, locale, attempts, max_attempts, to, to_name, order:{order_no, order_url, total, status, items[{name,quantity,line_total,vat_rate,kind}], reservations[{product_name,starts_at,ends_at,persons,status}]}, receipt:{id, receipt_no, kind, text_body, public_token, total, issued_at}|null, payment:{id, amount, link_url, link_expires_at}|null}`; PDF-liite haetaan `receipt-pdf?t=<receipt.public_token>`. Bottiavustus toimittaa alkuversion (fi/en), Koodari viimeistelee sanamuodon ja HTML:n.

## 4. Vaihe C – asiakkaan tilaussivu (anon; token = `orders.public_token`)
Sivu esim. `/tilaus/?t=<token>` (+ `/en/order/`). Kaikki vastaukset `{ok:true,…}` tai `{ok:false, code, message}`; rate limit.
- `public_get_order(p_token uuid)` → `{ok, order_no, status, payment_status, currency, locale, first_name, customer_kind, total, paid, unpaid, items[{name, quantity, line_total, vat_rate}], reservations[{reservation_id, product_id, product_name, starts_at, ends_at, persons, status, addons[]}], payments[{status, amount, paid_at, method_label, link_token|null, link_path|null}], receipts[{receipt_no, kind, issued_at, token, total}], can_add, add_until, can_change, change_deadline, change_hours_before, cancel_request:{status,created_at}|null, online_payment_enabled, upsell:{addons[{id,code,name,name_en,price,max}], treatments[{product_id,name,name_en,price,duration_minutes,description}]}}`. `can_add` = tila confirmed ∧ nyt < viimeisen aktiivisen varauksen päättyminen. Sen jälkeen vain luku (uudelle käynnille uusi tilaus).
- `public_add_to_order(p_token uuid, p_items jsonb)` – tyypit `addon` (`reservation_id` valinn., `addon_id|code`, `quantity`) ja `reservation` (`product_id`, `start`, `persons`; vain `public_slots`-hoidot) kuten 2.4; ei `product`/`custom`. → `{ok, added_total, balance, payment:{link_token, link_path, amount}|null, online_payment_enabled}`. Maksamaton lisäys: linkki luodaan vain jos verkkomaksu on käytössä, muuten maksu paikan päällä.
- `public_request_cancel(p_token uuid, p_reason text default null)` → luo `order_requests(kind='cancel', open)` + ilmoitus henkilökunnalle (`notifications_outbox`, topic `cancel_request`) + vahvistusviesti asiakkaalle; `request_exists` jos avoin on. **Henkilökunta käsittelee aina**: `admin_list_order_requests(p_status text default 'open')`, `admin_resolve_order_request(p_request_id bigint, p_action text 'approve'|'reject', p_note text)` (approve peruu varaukset `admin_set_reservation_status`-logiikalla; hyvitys erikseen `admin_refund`).
- `public_change_order_time(p_token uuid, p_reservation_id bigint, p_start timestamptz default null, p_rule_id bigint default null, p_date date default null, p_persons int default null)` → ympäröi nykyiset `public_change_*`; palauttaa lisäksi `{price_diff, payment:{link…}|null}`; kalliimpi → maksulinkki erotukselle; halvempi → `order_requests(kind='refund_due')` henkilökunnalle.
- Olemassa olevat `public_get_booking`, `public_change_booking`, `public_change_treatment_booking`, `public_cancel_booking`, `public_addons`, `public_catalog`, `public_treatment_availability` säilyvät ennallaan.

## 5. Vaihe D – raportit (kassaperuste: kuitin antamispäivä Helsingin ajassa)
- `admin_report_daily(p_date date)` (`reports.daily|reports.view`) ja `admin_report_month(p_ym text 'YYYY-MM')` (`reports.view`) → 
```
{ "period":{"from","to","tz":"Europe/Helsinki"}, "generated_at",
  "totals":{"receipts","refund_receipts","gross","net","vat","refunds_gross","net_after_refunds","vat_after_refunds","net_ex_vat_after_refunds","rounding"},   // gross/net/vat = vain kuitit (ennen hyvityksiä); refunds_gross NEGATIIVINEN; net_after_refunds = gross + refunds_gross; *_after_refunds = kuitit + hyvityskuitit
  "by_method":[{"method","label","payments","gross","refunds","rounding"}],
  "by_vat":[{"rate","net","vat","gross"}],                  // hyvitykset negatiivisina, ryhmätason pyöristys
  "by_method_vat":[{"method","rate","net","vat","gross"}],
  "by_category":[{"category","label","rate","quantity","gross","net","vat"}],
  "receipts":[{"receipt_no","kind","issued_at","order_no","method","gross","net","vat"}],   // vain päivä
  "by_day":[{"date","receipts","gross","vat","refunds"}],                                 // vain kuukausi
  "open":{"orders":n,"unpaid":x},
  "unreceipted":{"payments":n,"amount":x} }   // jaksolla maksetut natiivimaksut, joille ei ole kuittia (ennen vaihetta B tehdyt) – täsmäytys                           // vahvistetut tilaukset joiden käynti jakson sisällä ja maksamatta
```
- **CSV:** `admin_report_csv(p_from date, p_to date, p_kind text default 'lines')` → `{filename, mime:'text/csv;charset=utf-8', content}`; `content` alkaa BOM:lla (U+FEFF), erotin `;`, desimaalipilkku, rivinvaihto CRLF, kentät lainattu tarvittaessa. `lines`-sarakkeet (päivitetty 17.10.): `pvm;kuitti_no;tilaus_no;maksutapa;tuoteryhmä;tuote;määrä;brutto;alv_%;alv_€;netto;hyvitys` (hyvitys = `kyllä`/`ei`); `vat`-sarakkeet (virallinen ALV, ryhmätason pyöristys): `pvm;kuitti;tilaus;tyyppi;maksutapa;alv_prosentti;netto;alv_eur;brutto`. Hyvityskuitit negatiivisina.
- **PDF:** edge `report-pdf` (pdf-lib, `verify_jwt=true`): `GET /functions/v1/report-pdf?kind=daily&date=YYYY-MM-DD` tai `?kind=month&ym=YYYY-MM` → `application/pdf`; kutsuu RPC:tä kutsujan JWT:llä.

## 6. Integraatiovalmius (ei käytössä nyt)
- `integration_config`: `resend` (dry_run), `vismapay` (off), `procountor` (off). Dokumentaatio: `docs/talous-integraatiot.md` (tarvittavat tunnukset/salaisuudet: `RESEND_API_KEY`; `VISMAPAY_API_KEY`, `VISMAPAY_PRIVATE_KEY`; `PROCOUNTOR_CLIENT_ID/SECRET/API_KEY`; `site_base_url`).
- Tyhjät edge-rungot dry_run: `vismapay-start`, `vismapay-notify`, `vismapay-refund`, `procountor-sync`.
- `accounting_outbox` täyttyy vain kun procountor-mode ≠ off; sisältö = kuitin snapshot.

## 7. Vaiheistus ja työnjako
| Vaihe | Bottiavustus | Koodari | Valmis kun |
|---|---|---|---|
| A | migraatiot 29–30, RPC:t 2.1–2.9, testit | Hallinta → Talous: **Tilaukset** (lista, haku, lajittelu, sivutus), tilaus (varaukset, maksut, rivit, kuitit), **Maksut**, Lisää tilaukseen, Kirjaa maksu, Maksulinkki, Hyvitä (manager/admin), ALV-näkymä (Tuotteet) | milestone A (Botti ilmoittaa) |
| B | kuittitaulut+numerointi, `email_outbox`, `send-emails`, `receipt-pdf`, mallien alkuversio | Mallien viimeistely, kuittinäkymä/lataus/uudelleenlähetys hallinnassa | milestone B |
| C | `public_*`-RPC:t, `order_requests` | Asiakkaan tilaussivu, upsell-osio, peruutus-/aikamuutoslomake, hallinnan pyyntölista | milestone C |
| D | `admin_report_*`, CSV, `report-pdf` | Raportit-näkymä (päivä/kuukausi, CSV- ja PDF-napit) | milestone D |
Riippuvuudet: B←A, C←A+B, D←B. Koodari voi aloittaa A-UI:n heti tästä sopimuksesta (RPC:t ovat tuotannossa milestone A:n jälkeen; testaus ennen sitä paikallisella mockilla).

## 8. Vaihe A TUOTANNOSSA (17.10.2026, migraatiot booking_29 + booking_30) – tarkennukset sopimukseen
- Kaikki §2:n RPC:t ovat käytössä: `admin_list_orders`, `admin_get_order` (laajennettu), `admin_list_payments`, `admin_add_to_order`, `admin_create_payment_link`, `admin_record_payment`, `admin_refund`, `admin_list_vat_rates`, `admin_set_product_vat`, `admin_set_addon_vat`, `admin_upsert_vat_rate`. Vanhat kutsut `admin_record_payment(p_order_id,p_method,p_amount,p_note)` ja `admin_create_payment_link(p_order_id)` toimivat ennallaan (uudet parametrit ovat valinnaisia).
- `admin_refund` saa lisäparametrin `p_manual_done boolean default false` (vain admin; verkkomaksun hyvitys käsin kun Visma `off`). Hyvitys joka odottaa Vismaa: `status:'requested'`, maksu ei muutu.
- `balance` sisältää lisäksi `net_paid` (= maksettu − hyvitetty). Peruttu/vanhentunut tilaus: `unpaid = 0`.
- `admin_get_order.reservations[]` sisältää myös `item_id` (varauksen tilausrivi); `items[].covered/remaining` = maksuriveillä katettu/kattamaton osa.
- **Käteispyöristys:** `payments.amount` = tilaukselle hyvitetty täsmällinen summa, `rounding` = (0,05 €:iin pyöristetty kerätty summa − amount), esim. 100,03 → kerätään 100,05, `rounding = +0,02`. Asetetaan automaattisesti kaikille `cash`-maksuille (myös luonnissa `p_paid=true`).
- `payment_lines.refunded_gross` = rivin hyvitetty osuus; kattamaton osa = `amount_gross − refunded_gross`.
- Maksulinkki: `link_path` = `settings.payment_link_path` + `?p=` + `link_token`; vanhentuneet linkit peruuntuvat cronilla (15 min). Tilaussivun polku `settings.order_page_path` + `?t=` + `public_token`; `settings.site_base_url` on nyt `https://uusi.saunotus.com` (vahvistettava).
- `settings.seller` on täytetty `kb.businesses`-taulusta: Havuhattu Oy / Sipoonjoen perinnesauna, y-tunnus 3018112-1, ALV-tunnus FI30181121 (johdettu y-tunnuksesta, VAHVISTETTAVA), Hindsbyntie 124, 04130 Sipoo, savusauna@saunotus.fi, 010 299 2866, https://saunotus.fi. `logo_url` on tyhjä (tarvitaan logon osoite).
- Löydös: 2 aktiivista tuotetta ilman ALV-kantaa (mm. kb 47 "Tossujen tai saunatakin vuokra"); näkyvät `admin_list_vat_rates().missing`. Lisäys tilaukseen estää ne (`vat_missing`) kunnes kanta on asetettu (`admin_set_product_vat`).
- Sähköpostijono: `email_outbox`-rivi syntyy nyt `payment_link`-viestille (`p_send_email`); `integration_config.resend.mode='off'` → `skipped`, muuten `pending` (send-emails vaihe B). Kuitit ja hyvityskuitit: vaihe B (kuitti syntyy silloin automaattisesti myös jo tehdyille maksuille vain uusista maksuista eteenpäin).


## 9. Vaiheet B, C (db) ja D TUOTANNOSSA (17.10.2026; migraatiot booking_31, booking_32, booking_33) – lopullinen rajapinta
Kaikki alla on tuotannossa ja testattu (rollback-testit + E2E tuotannossa). Funktioiden virheet: `admin_*`/sisäiset nostavat `BK001` + `DETAIL=<code>`; `public_*` palauttavat `{ok:false, code, message}`.

### 9.1 B – kuitit
- `admin_get_receipt(p_receipt_id)`, `admin_resend_receipt(p_receipt_id)`, `public_get_receipt(p_order_token uuid, p_receipt_no text)` kuten §3. `receipt_by_token(p_token uuid)` ja `receipt_set_pdf(id, path)` ovat vain service_role (edge-funktiot).
- `admin_record_payment` ja `admin_refund` palauttavat nyt myös `receipt_id`, `receipt_no` kun kuitti syntyi.
- Kuitin PDF: `GET {SUPABASE_URL}/functions/v1/receipt-pdf?t=<public_token>` (ei JWT). Adminissa: `admin_get_receipt().pdf_url`. Teksti: `text_body`.
- `admin_list_vat_rates()` palauttaa nyt `{rates, missing, quote_only}`: `missing` = hinnalliset tuotteet ilman ALV:ia; `quote_only` = hinnattomat (tarjouspyyntö) tuotteet ilman ALV:ia (kb 50; ei tilattavissa, `item_not_found`).
- Asetukset (`settings`): `functions_base_url`, `receipt_series` `{"receipt":"K","refund_receipt":"H"}`, `site_base_url` (nyt `https://uusi.saunotus.com`, vahvistettava), `order_page_path` `/tilaus/` (linkki `…/tilaus/?t=<orders.public_token>`), `payment_link_path` `/maksa/` (linkki `…/maksa/?p=<link_token>`).
- **Logo:** Koodari julkaisee `https://joonasvaarala.github.io/saunotus-uusi/img/logo-kuitti.png` (PNG) ja ilmoittaa; botti asettaa `settings.seller.logo_url` vasta kun URL palauttaa 200. Ilman logoa PDF tehdään normaalisti.
- Sähköpostit: `send-emails` ajetaan minuutin välein (pg_cron, tunnistus tietokannassa), tila `dry_run` – mitään ei lähde. Mallit: `booking/supabase/functions/send-emails/templates.ts` (alkuversio, fi/en, text+html; viimeistele HTML ja sanamuoto). Viestilajit: `order_confirmation`, `payment_link`, `receipt`, `refund_receipt`, `cancel_request_ack`, `order_change`.

### 9.2 D – raportit
- `admin_report_daily`, `admin_report_month`, `admin_report_csv` täsmälleen §5 (+ avaimet `vat_after_refunds`, `net_ex_vat_after_refunds`, `unreceipted`). Päivämäärä = kuitin antopäivä Helsingin ajassa.
- `report-pdf` (verify_jwt=true): `GET /functions/v1/report-pdf?kind=daily&date=YYYY-MM-DD` tai `?kind=month&ym=YYYY-MM`, header `Authorization: Bearer <käyttäjän JWT>` (+ `apikey`). Virheet JSON: `{ok:false, code, message}` (403 `forbidden`/`not_authenticated`, 400 muut). PDF avataan esim. `fetch` → `blob` → `URL.createObjectURL` (JWT-header, joten ei suora `<a href>`).
- CSV: `admin_report_csv(...).content` → `new Blob([content], {type:'text/csv;charset=utf-8'})` (BOM jo sisällössä).

### 9.3 C – asiakkaan tilaussivu (anon; token = `orders.public_token`)
- `public_get_order(p_token uuid)` palauttaa avaimet: `ok, order_no, status, payment_status, currency, locale, created_at, first_name, customer_kind, total, paid (= maksettu − hyvitetty), refunded, unpaid, items[{name,quantity,line_total,vat_rate,kind}], reservations[{reservation_id,product_id,product_name,starts_at,ends_at,persons,status,addons[{addon_id,name,quantity,line_total}]}], payments[{status,amount,paid_at,method_label,link_token|null,link_path|null,refunded}], receipts[{receipt_no,kind,issued_at,token,total}], can_add, add_until, can_change, change_deadline, change_hours_before, change_via ('public_change_order_time'), booking_kind ('slots'|'rules'|'other'), can_request_cancel, cancel_request:{status,created_at}|null, online_payment_enabled, upsell:{addons[{id,code,name,name_en,description,description_en,price,vat_rate,max,reservation_ids[]}], treatments[{product_id,name,name_en,price,duration_minutes,description,description_en,category}]}` (upsell tyhjä kun `can_add=false`). Ei sähköpostia/puhelinta/osoitetta; vain etunimi. Kuitin PDF: `{functions_base_url}/receipt-pdf?t=<receipts[].token>`.
- `public_add_to_order(p_token, p_items)`: `addon` (`code` tai `addon_id`, `quantity`, valinn. `reservation_id` – pakollinen jos tilauksella useita varauksia) ja `reservation` (`product_id`, `start`, `persons`; `public_slots`-hoito; tuotteen voi lisätä vain saatavuuslistan ajoille). Max 10 riviä. Palauttaa `{ok, added_total, added[{name,line_total}], balance:{total,paid,unpaid}, payment:{link_token,link_path,amount,expires_at,reused}|null, online_payment_enabled}`. `payment` ≠ null vain kun verkkomaksu on `live` (linkki koko maksamattomalle määrälle); muuten maksu paikan päällä. Virhekoodit: `invalid_items, addon_quantity, addon_not_found, addon_not_allowed, item_not_found, order_not_editable, order_closed, space_busy, slot_unavailable, bad_time, not_bookable, rate_limited, busy` ym. (`message` suomeksi).
- `public_request_cancel(p_token, p_reason default null)` → `{ok, request:{id,status:'open',created_at}}`; virheet `request_exists`, `order_closed`, `invalid_reason`, `rate_limited`. Luo `order_requests(kind='cancel')`, `notifications_outbox(topic 'cancel_request', ei henkilötietoja)` ja `cancel_request_ack`-viestin. **Varaus ei peruunnu** ennen kuin henkilökunta hyväksyy.
- `public_change_order_time(p_token, p_reservation_id, p_start, p_rule_id, p_date, p_persons)` – sama `reservation_id` kuin `public_get_order.reservations[]`; vain jos `can_change` (yksi vahvistettu varaus, ≥ 48 h ennen). Onnistuessa `{ok, order_no, starts_at, ends_at, persons, total, price_diff, payment|null, balance, online_payment_enabled}`. **Maksettu varaus, jonka hinta muuttuisi** → `{ok:false, code:'price_change_requires_staff', request_created:true}` ja henkilökunnalle `order_requests(kind='change', payload)` (+ notifikaatio `order_change_request`); `refund_due`-pyyntö syntyy jos maksettu summa ylittäisi uuden hinnan. Maksamattomassa kalliimmassa muutoksessa `payment` = linkki vain jos verkkomaksu `live`.
- Henkilökunta: `admin_list_order_requests(p_status 'open'|'handled'|'rejected'|'all' default 'open')` → `{ok, count, requests[{id,order_id,order_no,order_status,customer_name,kind,status,reason,payload,created_at,handled_at,note,total,paid,first_start}]}`; `admin_resolve_order_request(p_request_id, p_action 'approve'|'reject', p_note)` (`bookings.manage`) → `{ok, status, cancelled_reservations, order_status, balance, refund_needed}`. `approve` + `cancel` peruu kaikki aktiiviset varaukset ja avoimet maksulinkit; **hyvitys tehdään erikseen `admin_refund`illa (manager/admin)** – `refund_needed=true` kertoo kun maksettua on jäljellä. Virhe `request_closed` jos jo käsitelty. Pyynnöt kannattaa näyttää Tilaukset-näkymässä merkkinä ja erillisenä listana.
- Rajoitukset: `rl_order_get_per_10min` (60), `rl_order_add_per_10min` (20/IP, 10/token), `rl_order_req_per_10min` (12/IP, 6/token); `rate_limited` palautetaan `ok:false`.


## 10. Päivitykset 17.10.2026 (migraatio booking_34) – korvaa ristiriitaisen §5/§9-tekstin
- **CSV `lines` (admin_report_csv p_kind='lines'):** otsikko `pvm;kuitti_no;tilaus_no;maksutapa;tuoteryhmä;tuote;määrä;brutto;alv_%;alv_€;netto;hyvitys`; `;`-erotin, desimaalipilkku (`25,5`, `99,00`), UTF-8 BOM alussa, CRLF joka rivin lopussa (myös viimeisen), kentät lainataan tarvittaessa. `pvm` = `DD.MM.YYYY` (kuitin antopäivä, Helsinki). Hyvityskuittirivit: `määrä`, `brutto`, `alv_€`, `netto` negatiivisina ja `hyvitys=kyllä`; muuten `ei`. Kellonaika ja `tyyppi`-sarake on poistettu. **`vat`-yhteenveto ennallaan:** `pvm;kuitti;tilaus;tyyppi;maksutapa;alv_prosentti;netto;alv_eur;brutto`.
- **Raportin `totals`:** `gross`, `net`, `vat` = vain kuitit, ennen hyvityksiä (gross = sis. ALV, net = veroton). `refunds_gross` on **negatiivinen** (esim. -30.00). `net_after_refunds = gross + refunds_gross`; `vat_after_refunds` ja `net_ex_vat_after_refunds` = ALV ja veroton hyvitysten jälkeen. Samoin **`by_method[].refunds` ja `by_day[].refunds` ovat nyt negatiivisia** (aiemmin positiivisia). `by_vat`/`by_method_vat`/`by_category` sisältävät hyvitykset suoraan negatiivisina rivisummina kuten ennenkin. `report-pdf` näyttää merkit samoin.
- **Maksurivit:** `payment_lines`-rivit (`admin_get_order().payments[].lines[]` ja maksulinkin `lines[]` esim. `admin_create_payment_link`/`_link_json`) sisältävät nyt myös `net` (veroton, €) ja `vat_eur` (ALV €); `net + vat_eur = amount_gross`. Muut avaimet ennallaan (`id, order_item_id, description, quantity, amount_gross, vat_rate, refunded_gross`).
- **`order_page_path` = `/tilaus/`** (päätös): lyhyt, kielineutraali ja pysyvä URL, jota ei tarvitse muuttaa kun varaussivun rakenne muuttuu; sähköpostien linkit ovat muotoa `{site_base_url}/tilaus/?t=<token>`. Suositus: pidä `/varaa/tilaus/` ohjauksena (redirect/saman sivun alias) `/tilaus/`-sivulle, jotta jo lähetetyt tai vaihtoehtoiset linkit toimivat. Jos haluatte toisen polun, vaihto on yksi rivi (`settings.order_page_path`) – kertokaa.


## 11. Päivitykset 17.10.2026 iltapäivä (migraatiot booking_35, booking_36)
- **Logo:** `settings.seller.logo_url` = `https://joonasvaarala.github.io/saunotus-uusi/img/logo-kuitti.png` (varmistettu 200 image/png, 600×829). Uusien kuittien snapshot kopioi osoitteen; PDF-testi tuotantoprojektissa näytti logon kuvana oikeassa yläkulmassa. **Älä siirrä/poista tiedostoa** – jo annettujen kuittien PDF:t haetaan uudelleen snapshotin osoitteesta (valmis PDF on välimuistissa Storagessa, mutta se voidaan joutua generoimaan uudelleen). Jos osoite joskus muuttuu, uudet kuitit käyttävät uutta `settings.seller.logo_url`-arvoa, vanhat vanhaa.
- **Raportin `totals`:** uusi `gross_after_refunds` (brutto hyvitysten jälkeen = `gross + refunds_gross`). **`net_after_refunds` on DEPRECATED** (harhaanjohtava nimi; sama arvo kuin `gross_after_refunds`, jätetty vain yhteensopivuuden vuoksi – älä käytä uudessa koodissa). Veroton hyvitysten jälkeen = `net_ex_vat_after_refunds`, ALV hyvitysten jälkeen = `vat_after_refunds`; `gross_after_refunds = vat_after_refunds + net_ex_vat_after_refunds` (testattu).
- **`period.kind`:** `'day'` (admin_report_daily) tai `'month'` (admin_report_month); `period` = `{from, to, tz, kind}`.
- **Roolit (tarkoituksellinen, ei muutu):** `admin_report_daily` = `reports.daily` TAI `reports.view` → päiväraportin saa myös kassavuorossa oleva henkilökunta (rooli `staff`). `admin_report_month`, `admin_report_csv` ja `report-pdf?kind=month` = vain `reports.view` (manager/admin). `report-pdf?kind=daily` seuraa päiväraportin oikeutta. Virhe ilman oikeutta: `forbidden` (HTTP 403 report-pdf:ssä). Testattu rollbackissa oikealla `staff`-käyttäjällä.
- **`admin_list_payments`** palauttaa kevyen listan **ilman laskurivejä** (tarkoituksellinen). Rivit haetaan tarvittaessa `admin_get_order(order_id).payments[].lines[]` (sisältää `net`, `vat_eur`).
- **Tietoturva (booking_36):** sisäinen `_vat_active` ei ole enää kutsuttavissa REST-rajapinnasta (vain service_role).
