// Regressio 12.11.2026 (Joonas, #15149): ylisuoritus 58 € ("Asiakas on maksanut 58,00 € liikaa"), mutta "Hyvitä maksu…" ei tehnyt mitään.
// Syy: tilausnäkymän runner vertasi normOrder()-maksun p.id:tä (ei ole olemassa; normalisoitu tunniste on payment_id) → dialogi ei auennut.
// Ajo: node --test booking/tests/tilausnakyma-hyvitys-15149.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as L from '../admin/order-view-logic.js';
import { normOrder } from '../admin/talous-api.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const MANAGER = (perm) => ['bookings.manage', 'payments.manage', 'payments.refund'].includes(perm);

// #15149 -muotoinen tilaus: vahvistettu, 29,00 €, Montonio-maksu 87,00 € maksettu, ei hyvityksiä → ylisuoritus 58,00 €.
const raw = {
  order_id: 14095, order_no: 15149, status: 'confirmed', payment_status: 'paid', created_at: '2026-11-10T10:00:00Z', source_channel: 'web', is_native: true,
  customer: { id: 1, name: 'Testi Asiakas' }, staff_can_add: true, invoice_locked: false, overpaid: 58,
  balance: { total: 29, paid: 87, refunded: 0, pending_link: 0, unpaid: 0, net_paid: 87 },
  reservations: [{ id: 1, status: 'confirmed', product_name: 'Sauna', starts_at: '2026-11-20T14:00:00Z', ends_at: '2026-11-20T16:00:00Z', persons: 1, item_total: 29, addons: [], option_choices: [] }],
  items: [], receipts: [], refunds: [], emails: [], requests: [],
  payments: [{ id: 1086, method: 'montonio', provider: 'montonio', status: 'paid', amount: 87, refunded_amount: 0, paid_at: '2026-11-10T10:05:00Z' }],
  refundable_by_payment: [{ payment_id: 1086, method: 'montonio', provider: 'montonio', refundable: 87 }],
};

test('#15149: ylisuoritus näyttää Hyvitettävää 58 € ja hyvitysnapin', () => {
  const m = L.orderModel(raw);
  const box = L.paymentBox(m, { can: MANAGER });
  assert.equal(box.display.state, 'to_refund');
  assert.equal(box.display.amount, 58);
  assert.equal(box.actions.refund, true);
});

test('#15149: Hyvitä maksu… löytää normalisoidun Montonio-maksun (payment_id) ja esitäyttää 58 €', () => {
  const m = L.orderModel(raw);
  const o = normOrder(m.raw);
  assert.equal(o.payments[0].id, undefined, 'normOrder ei tuo id-kenttää – vertailu payment_id:llä');
  const targets = L.refundTargets(m, o.payments, { can: MANAGER });
  assert.deepEqual(targets.map((p) => p.payment_id), [1086]);
  assert.equal(L.refundSuggestion(m, targets[0]), 58, 'ylisuoritus: vain liikaa maksettu osuus');
  assert.equal(L.refundSuggestion({ ...m, overpaid: 0 }, targets[0]), 87, 'ilman ylisuoritusta koko jäljellä oleva');
  assert.equal(L.refundSuggestion({ ...m, overpaid: 200 }, targets[0]), 87, 'ei koskaan yli maksun jäljellä olevan');
});

test('refundTargets: ei oikeutta / laskulukko / lahjakortti → tyhjä', () => {
  const m = L.orderModel(raw), o = normOrder(m.raw);
  assert.deepEqual(L.refundTargets(m, o.payments, { can: () => false }), []);
  assert.deepEqual(L.refundTargets(L.orderModel({ ...raw, refundable_by_payment: [] }), o.payments, { can: MANAGER }), []);
});

test('tilausnäkymän runner käyttää refundTargetsia, välittää esitäytön eikä epäonnistu hiljaa', () => {
  const src = read('booking/admin/views/order-view.js');
  const body = src.slice(src.indexOf('    refund(m) {'), src.indexOf('    addPurchase(m'));
  assert.match(body, /refundTargets\(m, o\.payments/);
  assert.doesNotMatch(body, /String\(p\.id\)/);
  assert.match(body, /suggest:/);
  assert.match(body, /toast\(/);
  const tal = read('booking/admin/views/talous-orders.js');
  assert.match(tal, /function refundDialog\(o, refundable, \{ suggest = null \} = \{\}\)/);
  assert.match(tal, /refund: \(o, refundable, opts\) =>/);
});
