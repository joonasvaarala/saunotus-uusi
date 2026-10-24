// Koodi- ja SQL-sopimustestit. Varsinainen tietokantaintegraatio vaatii Supabasen.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { normCheckout, isHoldView, nextPollIn } from '../shop/src/hold-logic.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const file = (path) => readFileSync(resolve(root, path), 'utf8');
const mig = file('booking/supabase/migrations/20261024054738_booking_131_giftcard_checkout_fix.sql');
const rollback = file('booking/supabase/rollbacks/20261024054738_booking_131_ROLLBACK.sql');
// Paketti sisältää git apply -korjaukset; asennuksen jälkeen testeissä luetaan varsinaiset .js-tiedostot.
const giftSrc = existsSync(resolve(root, 'booking/shop/src/gift.js'))
  ? file('booking/shop/src/gift.js') : null;
const gift = giftSrc ?? file('patches/gift.js.patch').split('\n')
  .filter((line) => line.startsWith('+') || line.startsWith(' '))
  .map((line) => line.slice(1)).join('\n');
const order = existsSync(resolve(root, 'booking/shop/src/order.js'))
  ? file('booking/shop/src/order.js') : file('patches/order.js.patch');

test('onnistunut lahjakorttiosto ohjautuu suoraan maksu- tai tilaussivulle', () => {
  assert.match(gift, /if \(r\.payment_url\)\s*\{\s*location\.assign\(r\.payment_url\);\s*return;/);
  assert.match(gift, /if \(r\.token\)\s*\{\s*location\.assign\(orderHref\(r\.token\)\);\s*return;/);
  const pattern = /if \(r\?\.ok\) \{[\s\S]*?return done\(r\);[^\n]*\n\s*\}/;
  const match = gift.match(pattern);
  assert.ok(match, 'onnistumishaaran pitää olla olemassa');
  let redirected = [], confirmed = 0;
  const act = new Function('r', 'location', 'orderHref', 'done', `${match[0]}`);
  act({ ok: true, token: 'abc-123' }, { assign: (x) => redirected.push(x) },
    (token) => `/tilaus/?t=${encodeURIComponent(token)}`, () => confirmed++);
  assert.deepEqual(redirected, ['/tilaus/?t=abc-123']);
  assert.equal(confirmed, 0);
  redirected = [];
  act({ ok: true, token: 'abc', payment_url: 'https://maksu.example/checkout' },
    { assign: (x) => redirected.push(x) }, (token) => `/en/order/?t=${token}`, () => confirmed++);
  assert.deepEqual(redirected, ['https://maksu.example/checkout']);
  redirected = [];
  act({ ok: true, token: 'abc' }, { assign: (x) => redirected.push(x) },
    (token) => `/en/order/?t=${token}`, () => confirmed++);
  assert.deepEqual(redirected, ['/en/order/?t=abc']);
});

test('pending ilman booking.reservations-rivejä ei vanhene SQL:ssa', () => {
  assert.match(mig, /v_has_res\s*:=\s*exists\s*\(select 1 from booking\.reservations r where r\.order_id = o\.id\)/);
  assert.match(mig, /when o\.status = 'pending' and not v_has_res then\s*case when v_inflight then 'processing_payment' else 'awaiting_payment' end/);
  assert.match(mig, /v_open\s*:=\s*o\.status = 'pending' and \(not v_has_res or/);
  assert.match(mig, /'hold_expires_at', case when v_has_res and o\.status = 'pending' then v_hold end/);
  assert.match(mig, /'seconds_left', case when v_has_res and o\.status = 'pending' and v_open then/);
  assert.match(mig, /v_status := case when o\.status = 'pending' and exists \(select 1 from booking\.reservations r where r\.order_id = o\.id\)/);
  // Ajastettu lahjakorttitoimitus ei saa vaikuttaa maksamisen määräaikaan.
  assert.doesNotMatch(mig, /deliver_on\s*[<>]=?\s*now\(\)/);
  const checkout = normCheckout({ checkout_state: 'awaiting_payment', hold_expires_at: null, seconds_left: null });
  assert.equal(isHoldView(checkout), false);
  assert.equal(nextPollIn(checkout), null);
  assert.match(rollback, /v_open := o\.status = 'pending' and \(v_hold is not null or v_inflight\)/);
});

test('preliminary-varaus säilyttää 15 minuutin nykylogiikkansa', () => {
  assert.match(mig, /when o\.status = 'pending' and o\.hold_kind = 'preliminary' then 'preliminary'/);
  assert.match(mig, /when o\.status = 'pending' and not v_open then 'expired'/);
  assert.match(mig, /v_hold is not null or v_inflight/);
  assert.equal(isHoldView(normCheckout({ checkout_state: 'preliminary', hold_kind: 'preliminary' })), true);
});

test('tilaussivulla maksuosio ennen lahjakortteja, ei lisä-/peruutuskortteja ilman varausta', () => {
  assert.match(order, /lines, pay, giftCards, claimBox/);
  assert.match(order, /const add = closedHold \|\| o\.reservations\.length === 0 \? null/);
  assert.match(order, /const cancel = closedHold \|\| o\.reservations\.length === 0 \? null/);
});
