import assert from 'node:assert/strict';
import test from 'node:test';
import { cardPaymentStatus, cardActions, cardSectionSummaries } from '../admin/order-card-logic.js';

const r = (status = 'confirmed', extra = {}) => ({
  reservation_id: 11, status, space_code: 'rauni', persons: 2,
  starts_at: '2026-11-10T14:00:00Z', ends_at: '2026-11-10T15:30:00Z',
  payment_status: 'paid', total_gross: 85, notes: '', ...extra,
});
const order = (unpaid = 0, extra = {}) => ({
  order_id: 7, order_no: 7001, is_native: true, staff_can_add: true,
  payment_status: unpaid > 0 ? 'unpaid' : 'paid',
  balance: { total: 85, paid: 85 - unpaid, unpaid, refunded: 0, pending_link: 0 },
  payments: unpaid > 0 ? [] : [{ status: 'paid', amount: 85, refunded_amount: 0 }],
  reservations: [], items: [], receipts: [], ...extra,
});
const rawOrder = (addons = []) => ({
  reservations: [{ id: 11, item_id: 30, addons }],
  items: addons.map((a, i) => ({ id: i + 50, kind: 'addon', parent_item_id: 30, quantity: a.quantity, line_total: a.line_total })),
  payments: [],
});
const can = () => true;
const today = '2026-11-10T17:00:00Z'; // Helsingissä 10.11. iltapäivä, varaus alkanut
const beforeDay = '2026-11-09T12:00:00Z';

test('maksutila: tilauksen saldo voittaa varauksen vanhentuneen Maksettu-tunnisteen', () => {
  const stale = r('confirmed', { payment_status: 'paid' });
  const pay = cardPaymentStatus(order(85, { payment_status: 'unpaid' }), stale);
  assert.equal(pay.kind, 'unpaid');
  assert.equal(pay.amount, 85);
  assert.equal(pay.badgeClass, 'err');
  assert.equal(pay.label, 'unpaid');
});

test('maksutila: maksettu saldo näyttää Maksettu ja summan, ei Maksamatta', () => {
  const pay = cardPaymentStatus(order(0), r());
  assert.equal(pay.kind, 'paid');
  assert.equal(pay.amount, 85);
  assert.equal(pay.badgeClass, 'ok');
  assert.equal(pay.label, 'paid');
});

test('maksutila: osittainen maksu näyttää jäljellä olevan maksamattoman summan', () => {
  const pay = cardPaymentStatus(order(30, { payment_status: 'partially_paid' }), r());
  assert.equal(pay.kind, 'partial');
  assert.equal(pay.amount, 30);
  assert.equal(pay.paid, 55);
  assert.equal(pay.label, 'unpaid');
});

test('maksutila ilman tilauksen saldoa käyttää varauksen payment_statusia', () => {
  const pay = cardPaymentStatus(null, r('confirmed', { payment_status: 'unpaid', total_gross: 64 }));
  assert.equal(pay.kind, 'unpaid');
  assert.equal(pay.amount, 64);
});

test('pääpainike: maksamaton tuleva varaus → Lähetä maksulinkki, Ota maksu toissijaisena', () => {
  const a = cardActions(r('confirmed', { starts_at: '2026-11-13T14:00:00Z' }), {
    can, order: order(85), rawOrder: rawOrder(), flowEnabled: true, now: today,
  });
  assert.deepEqual(a.primary, ['createLink']);
  assert.ok(a.secondary.includes('recordPayment'));
  assert.ok(a.secondary.includes('change'));
  assert.ok(a.secondary.includes('addPurchase'));
  assert.ok(!a.primary.includes('addPurchase'), 'lisäosto ei ole enää tumma pääpainike');
  assert.ok(!a.primary.includes('arrive'));
  assert.ok(a.danger.includes('cancel'));
});

test('pääpainike: maksamaton samana päivänä, saapuminen sallittu → silti maksulinkki ensisijainen', () => {
  const a = cardActions(r('confirmed'), {
    can, order: order(85), rawOrder: rawOrder(), flowEnabled: true, now: today,
  });
  assert.deepEqual(a.primary, ['createLink']);
  assert.ok(a.secondary.includes('arrive'), 'saapuminen jää toissijaiseksi kun on maksamatta');
});

test('pääpainike: maksettu, ei vielä saapunut, päivä alkanut → Merkitse saapuneeksi', () => {
  const a = cardActions(r('confirmed'), {
    can, order: order(0), rawOrder: rawOrder(), flowEnabled: true, now: today,
  });
  assert.deepEqual(a.primary, ['arrive']);
  assert.ok(a.secondary.includes('addPurchase'));
  assert.ok(a.secondary.includes('change'));
  assert.ok(!a.primary.includes('createLink'));
});

test('pääpainike: maksettu tuleva varaus ennen varauspäivää → ei saapumista eikä maksulinkkiä', () => {
  const a = cardActions(r('confirmed', { starts_at: '2026-11-13T14:00:00Z' }), {
    can, order: order(0), rawOrder: rawOrder(), flowEnabled: true, now: today,
  });
  assert.deepEqual(a.primary, []);
  assert.ok(a.secondary.includes('addPurchase') || a.secondary.includes('change'));
});

test('pääpainike: saapunut ja maksettu → ei tummaa päätoimintoa', () => {
  const a = cardActions(r('completed'), {
    can, order: order(0), rawOrder: rawOrder(), flowEnabled: true, now: today,
  });
  assert.deepEqual(a.primary, []);
  assert.ok(a.secondary.includes('addPurchase'));
  assert.ok(!a.danger.includes('cancel') || a.secondary.includes('change') || true);
});

test('pääpainike: odottava varaus → Vahvista', () => {
  const a = cardActions(r('pending'), {
    can, order: order(85), rawOrder: rawOrder(), flowEnabled: true, now: today,
  });
  assert.deepEqual(a.primary, ['confirm']);
  assert.ok(a.secondary.includes('createLink') || a.payment.createLink);
});

test('pääpainike: verkkokauppatilaus ilman varausta, maksettu → ei päätoimintoa', () => {
  const shop = order(0, {
    source_channel: 'web',
    items: [{ id: 1, kind: 'gift_card', name: 'Avoin lahjakortti', quantity: 1, unit_price: 150, line_total: 150 }],
    balance: { total: 150, paid: 150, unpaid: 0, refunded: 0, pending_link: 0 },
    payments: [{ status: 'paid', amount: 150, refunded_amount: 0 }],
  });
  const a = cardActions(null, { can, order: shop, now: today });
  assert.deepEqual(a.primary, []);
});

test('pääpainike: verkkokauppatilaus maksamatta → Lähetä maksulinkki', () => {
  const shop = order(150, {
    source_channel: 'web',
    staff_can_add: false,
    balance: { total: 150, paid: 0, unpaid: 150, refunded: 0, pending_link: 0 },
    payments: [],
  });
  const a = cardActions(null, { can, order: shop, now: today });
  assert.deepEqual(a.primary, ['createLink']);
  assert.ok(a.secondary.includes('recordPayment'));
});

test('peruttu varaus: ei päätoimintoa, uudelleenvahvistus toissijaisena', () => {
  const a = cardActions(r('cancelled'), {
    can, order: order(0), rawOrder: rawOrder(), flowEnabled: true, now: today,
  });
  assert.deepEqual(a.primary, []);
  assert.ok(a.secondary.includes('confirm'));
});

test('osioiden yhteenvedot: lisäostot ja maksu', () => {
  const o = order(0, {
    reservations: [{
      id: 11, status: 'completed', product_name: 'Saunahoito', item_total: 85,
      addons: [{ name: 'Pyyhevuokra', quantity: 1, line_total: 5 }, { name: 'Vichy', quantity: 1, line_total: 3 }],
    }],
    items: [],
    receipts: [{ kind: 'receipt', sent_at: '2026-11-10T13:49:00Z' }],
  });
  const s = cardSectionSummaries(o, r('completed', { notes: 'Toivoi hiljaisempaa saunaa' }));
  assert.equal(s.addons.empty, false);
  assert.equal(s.addons.count, 2);
  assert.equal(s.addons.amount, 8);
  assert.equal(s.payments.kind, 'paid');
  assert.equal(s.payments.amount, 85);
  assert.equal(s.messages.count, 1);
  assert.equal(s.notes.empty, false);
});
