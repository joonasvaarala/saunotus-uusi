# Tilausnäkymä v3 – PR 1 (yhteenveto, koko tilaus, asiakasnäkymä)

Määrittely: `tilausnakyma-luonnos/v3/toteutusmaarittely.md` §8 kohta 1 (lukufunktiot A, H, J).

## Reitit
- `#/tilaukset/<nro>` → `views/orders.js` `render(rest)` → `renderOrderRoute` → `views/order-view.js` `renderOrderView`.
  Numerinen `rest` (ei `varaukset`) avaa koko tilauksen. Tilausnumero → id: `admin_order_lookup(p_order_no)`, varalla `listOrders`-haku.
- `#/asiakkaat/<id>` → `views/customers.js` `render(rest)` → `views/customer-view.js` `renderCustomerView`.
  Asiakaslistan rivi (`data-testid=customer-row`) navigoi tähän; muokkaus avaa vanhan asiakaskortin (`card(id, after)`).
- `admin.js`, navi, runko ja päivänäkymä ennallaan (parseAdminHash antaa jo `rest`:n).

## Tilauslista (`views/talous-orders.js`)
- `createOrdersTab({ api, ctx, gift = null, rpc = null, onAfterChange = null, orderView = true })`
  - `orderView:false` → vanha käytös (rivi avaa `openOrderCard`-dialogin). Fake-DOM-testit (ei `matchMedia`) käyttävät vanhaa polkua automaattisesti.
  - Leveä näyttö (≥ 1200 px, `isWide`, CSS 75em): rivi avaa yhteenvetopaneelin (`views/order-summary.js`), ↑/↓ vaihtaa, Esc sulkee, suodattimen/sivun vaihto sulkee.
  - Kapea: rivi tallentaa listan tilan (`takeOrdersResume`/`hasOrdersResume`) ja asettaa hashin `#/tilaukset/<nro>`; takaisin palatessa tila palautuu.
  - Palauttaa `dialogs {add, link, record, refund}` – koko tilausnäkymä käyttää samoja dialogeja (headless-tab `renderOrderRoute`:ssa).
- `views/order-card.js`: vain `changeDialog` exportattu. Vanha kortti jää päivänäkymän ja fallbackin käyttöön.

## Poisto-paikka (PR #334)
`order-view.js` vaarakortissa on `h('div', { 'data-slot': 'order-delete' })` – PR #334 liittää poistonapin tähän (admin+manager, menneet maksamattomat).

## Migraatio booking_278
- `booking/supabase/migrations/20261111162544_booking_278_admin_order_customer_read.sql` – vain lukufunktiot:
  A `admin_get_order` (+ locale, invoice, overpaid, refundable_by_payment, voucher_claims, reservation_meta),
  H `admin_get_customer` (+ open_balance, open_orders, stats, gift_cards),
  J `admin_order_history(bigint, int default 200)` (uusi), `admin_order_lookup(bigint)` (uusi).
- Rollback: `booking/supabase/rollbacks/20261111162544_booking_278_ROLLBACK.sql` (palauttaa PROD-versiot, pudottaa uudet funktiot).
- Testi: `booking/supabase/tests/t278_admin_order_customer_read.sql` (aja migraation jälkeen DEV:ssä, kaikki rivit PASS).
- Käyttöliittymä toimii myös ilman migraatiota (puuttuvat kentät → fallbackit; historia ja lookup → virhe/fallback).

## Tekstit
`ui.admin.order_view.*`, `ui.admin.order_cancel.*`, `ui.admin.customer_view.*` (FI+EN) → `content/site-texts.pending-import-137.json`; oletukset `booking/admin/order-view-texts.js`.

## Testit
- `node --test booking/tests/tilausnakyma-v3.test.mjs` (logiikka, tekstit, lähde- ja CSS-tarkistukset, migraation rakenne). Ei vielä lisätty `.github/workflows/pages.yml`:iin – Koodarin päätös.
- Kuvat: `PW_DIR=<playwright-core-hakemisto> SHOT_DIR=<kansio> node booking/scripts/e2e-tilausnakyma-v3.mjs` (mock-data, 1440 + 390).
- Ulkoiset E2E-skriptit, jotka klikkaavat `order-head` ja odottavat dialogia, saavat nyt yhteenvedon (leveä) tai navigoinnin (kapea).
  Käytä `createOrdersTab({ …, orderView:false })` tai päivitä skripti.
