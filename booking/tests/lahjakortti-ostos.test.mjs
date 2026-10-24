// Lahjakortin ostoketju: tilaussivu näyttää yhden yhteenvedon ja yhden tilan.
// Varaus + lahjakortti ja osittainen maksu säilyttävät rivit ja maksetun summan. Ei DOMia, ei maksulogikkaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { orderChrome } from '../shop/src/order-view.js';

const src = (name) => readFileSync(new URL(`../shop/src/${name}`, import.meta.url), 'utf8');

test('pelkkä lahjakortti, maksamatta: ei tuplarivejä, ei kuitteja, yksi summa, yksi tila', () => {
  const v = orderChrome({ giftCards: [{}, {}], reservations: [], paid: 0, unpaid: 267, paymentStatus: 'unpaid', status: 'pending', receipts: [] });
  assert.equal(v.giftOnly, true);
  assert.equal(v.showLines, false);
  assert.equal(v.showReceipts, false);
  assert.equal(v.sums, 'total');
  assert.equal(v.showAdd, false);
  assert.equal(v.showCancel, false);
  assert.equal(v.explainGiftPay, false);
  assert.equal(v.heading, 'pay');
  assert.deepEqual(v.badge, { kind: 'st-pending', key: 'st.pending' });
});

test('pelkkä lahjakortti, maksettu: kiitos, kuitit vain jos niitä on', () => {
  const paid = orderChrome({ giftCards: [{}], reservations: [], paid: 75, unpaid: 0, paymentStatus: 'paid', status: 'confirmed', receipts: [{ receipt_no: 'K-1' }] });
  assert.equal(paid.heading, 'thanks');
  assert.equal(paid.sums, 'total');
  assert.equal(paid.showLines, false);
  assert.equal(paid.showReceipts, true);
  assert.deepEqual(paid.badge, { kind: 'pay-paid', key: 'pay.paid' });
  const none = orderChrome({ giftCards: [{}], reservations: [], paid: 75, unpaid: 0, paymentStatus: 'paid', status: 'confirmed', receipts: [] });
  assert.equal(none.showReceipts, false);
});

test('varaus osittain lahjakortilla: rivit, kolme summaa, lahjakortilla maksamisen ohje', () => {
  const v = orderChrome({ giftCards: [], reservations: [{}], paid: 20, unpaid: 62, paymentStatus: 'partially_paid', status: 'confirmed', receipts: [] });
  assert.equal(v.giftOnly, false);
  assert.equal(v.showLines, true);
  assert.equal(v.sums, 'partial');
  assert.equal(v.explainGiftPay, true);
  assert.equal(v.showAdd, true);
  assert.equal(v.showReceipts, false);
  assert.equal(v.heading, 'order');
  assert.deepEqual(v.badge, { kind: 'pay-partially_paid', key: 'pay.partially_paid' });
});

test('varaus ja ostettu lahjakortti samassa tilauksessa: rivit jäävät, lahjakorttimaksun ohje ei', () => {
  const v = orderChrome({ giftCards: [{}], reservations: [{}], paid: 50, unpaid: 100, paymentStatus: 'partially_paid', status: 'confirmed', receipts: [] });
  assert.equal(v.giftOnly, false);
  assert.equal(v.showLines, true);
  assert.equal(v.explainGiftPay, false);
  assert.equal(v.sums, 'partial');
  assert.equal(v.heading, 'order');
});

test('maksettu varaus ja avoin peruutuspyyntö: tila on peruutuspyyntö, lahjakorttitilaus näyttää pyynnön', () => {
  const booking = orderChrome({ reservations: [{}], paid: 40, unpaid: 0, paymentStatus: 'paid', status: 'confirmed' });
  assert.deepEqual(booking.badge, { kind: 'pay-paid', key: 'pay.paid' });
  const asked = orderChrome({ giftCards: [{}], reservations: [], paid: 0, unpaid: 75, status: 'pending', cancelRequest: { status: 'open' } });
  assert.equal(asked.showCancel, true);
  assert.deepEqual(asked.badge, { kind: 'st-cancel_requested', key: 'st.cancel_requested' });
});

test('paikanpidon näkymä ei lisää toista tilamerkkiä', () => {
  const v = orderChrome({ giftCards: [{}], reservations: [], paid: 0, unpaid: 75, status: 'pending', holdView: true });
  assert.equal(v.badge, null);
  assert.equal(v.heading, 'pay');
  assert.equal(v.explainGiftPay, false);
});

test('lahjakorttitilaus käyttää yhteenvetoa, yhtä maksupainiketta ja ehjää korttiriviä', () => {
  const order = src('order.js');
  const gift = src('order-gift.js');
  const css = src('shop.css');
  assert.match(order, /orderChrome\(/);
  assert.match(order, /t\.giftPayBtn\.replace\('\{amount\}', due\)/);
  assert.match(order, /mustText: view\.giftOnly \? t\.giftHoldMust/);
  assert.match(order, /mount\(api\.mock \? h\('p', \{ class: 'ord-mock'/);
  assert.match(order, /mpHost, head, holdEl, closedEl, resv, optSec, lines, giftCards, claimBox, pay, giftUse, receipts, extra, cancel, msg, phoneBox\(\)/);
  assert.match(gift, /class: 'gc-top'/);
  assert.match(gift, /if \(c\.ready && !rec\) reveal\(true\)/);
  assert.doesNotMatch(gift, /data-testid': 'gc-show'/);
  assert.match(css, /\.ord-lines li\.gc-ocard\{display:flex/);
  assert.doesNotMatch(css, /grid-template-areas:"m s" "t s" "a a"/);
});
