// Regressio 12.11.2026 (#15149): 58 €:n hyvitys tehtiin (refunds 64, processing / Montonio PENDING), mutta tilausnäkymä näytti yhä
// "Asiakas on maksanut 58,00 € liikaa" + Hyvitä maksu ja summalaatikko "Hyvitettävää 58,00 €". Keskeneräiset hyvitykset
// (requested/processing) vähennetään nyt ylisuorituksesta ja hyvitettävästä. Ajo: node --test booking/tests/hyvitys-kasittelyssa-15149.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as L from '../admin/order-view-logic.js';
import { normOrder } from '../admin/talous-api.js';
import { visibleOrderActions } from '../admin/order-actions-logic.js';
import { paymentRefundLeft, pendingRefundTotal, PENDING_REFUND_STATUSES } from '../admin/refund-pending.js';
import { ORDER_VIEW_TEXTS } from '../admin/order-view-texts.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const MANAGER = (perm) => ['bookings.manage', 'payments.manage', 'payments.refund'].includes(perm);

// admin_get_order -muoto: palvelimen overpaid laskee vain valmiit hyvitykset (refunded_amount), refundable_by_payment vähentää keskeneräiset.
const raw = (refunds = [], refundable = 87 - refunds.filter((f) => PENDING_REFUND_STATUSES.includes(f.status)).reduce((s, f) => s + f.amount, 0)) => ({
  order_id: 14095, order_no: 15149, status: 'confirmed', payment_status: 'paid', created_at: '2026-11-10T10:00:00Z', source_channel: 'web', is_native: true,
  customer: { id: 1, name: 'Testi Asiakas' }, staff_can_add: true, invoice_locked: false, overpaid: 58,
  balance: { total: 29, paid: 87, refunded: 0, pending_link: 0, unpaid: 0, net_paid: 87 },
  reservations: [{ id: 1, status: 'confirmed', product_name: 'Sauna', starts_at: '2026-11-20T14:00:00Z', ends_at: '2026-11-20T16:00:00Z', persons: 1, item_total: 29, addons: [], option_choices: [] }],
  items: [], receipts: [], emails: [], requests: [],
  refunds: refunds.map((f) => ({ ...f, payment_id: 1086 })),
  payments: [{ id: 1086, method: 'montonio', provider: 'montonio', status: 'paid', amount: 87, refunded_amount: 0, paid_at: '2026-11-10T10:05:00Z', refunds }],
  refundable_by_payment: [{ payment_id: 1086, method: 'montonio', provider: 'montonio', refundable: refundable }],
});
const R64 = { id: 64, amount: 58, status: 'processing', reason: 'Ylisuoritus', created_at: '2026-11-12T19:34:02Z', done_at: null };

test('apu: vain requested/processing ovat keskeneräisiä; hyvitettävä = maksettu − hyvitetty − keskeneräiset', () => {
  assert.equal(pendingRefundTotal([R64, { amount: 5, status: 'requested' }, { amount: 7, status: 'done' }, { amount: 9, status: 'failed' }, { amount: 3, status: 'cancelled' }]), 63);
  assert.equal(paymentRefundLeft({ amount: 87, refunded_amount: 0, refunds: [R64] }), 29);
  assert.equal(paymentRefundLeft({ amount: 87, refunded_amount: 0, refunds: [R64], refundable: 20 }), 20, 'palvelimen raja voittaa');
  assert.equal(paymentRefundLeft({ amount: 10, refunded_amount: 5, refunds: [{ amount: 9, status: 'processing' }] }), 0, 'ei negatiivinen');
});

test('#15149 hyvityksen jälkeen: ei ylisuoritusta, summalaatikko "Hyvitys käsittelyssä 58 €", seuraava askel neutraali', () => {
  const m = L.orderModel(raw([R64]));
  assert.equal(m.overpaid, 0); assert.equal(m.pending_refund, 58); assert.equal(m.refund_covered, 58);
  const box = L.paymentBox(m, { can: MANAGER });
  assert.equal(box.display.state, 'refund_pending');
  assert.equal(box.display.amount, 58);
  assert.equal(box.display.tone, 'info');
  assert.equal(box.headline, 'settled');
  assert.deepEqual(L.nextStep(m, { now: new Date('2026-11-12T20:00:00Z') }), { kind: 'refund_pending', amount: 58 });
  assert.notEqual(L.paymentState(m), 'overpaid');
  // ⋯-valikon yleinen hyvitys jää (29 € myyntiä), mutta ylisuoritusta ei esitäytetä uudelleen
  const t = L.refundTargets(m, normOrder(m.raw).payments, { can: MANAGER });
  assert.deepEqual(t.map((p) => [p.payment_id, p.refundable]), [[1086, 29]]);
  assert.equal(L.refundSuggestion(m, t[0]), null);
});

test('osittain katettu ylisuoritus: tarjotaan vain jäljellä oleva osuus', () => {
  const m = L.orderModel(raw([{ ...R64, amount: 40 }]));
  assert.equal(m.overpaid, 18);
  const box = L.paymentBox(m, { can: MANAGER });
  assert.equal(box.display.state, 'to_refund'); assert.equal(box.display.amount, 18);
  assert.ok(box.display.lines.some((x) => x.key === 'refund_pending_line' && x.amount === 40));
  assert.deepEqual(L.nextStep(m, { now: new Date('2026-11-12T20:00:00Z') }), { kind: 'overpaid', amount: 18 });
  const t = L.refundTargets(m, normOrder(m.raw).payments, { can: MANAGER });
  assert.equal(t[0].refundable, 47);
  assert.equal(L.refundSuggestion(m, t[0]), 18);
});

test('valmis tai epäonnistunut hyvitys ei ole keskeneräinen', () => {
  const failed = L.orderModel(raw([{ ...R64, status: 'failed' }]));
  assert.equal(failed.overpaid, 58); assert.equal(L.paymentBox(failed, { can: MANAGER }).display.state, 'to_refund');
  // valmis: palvelin päivittää refunded_amount / balance → overpaid 0, ei refund_pending-tilaa
  const done = L.orderModel({ ...raw([{ ...R64, status: 'done' }], 29), overpaid: 0, balance: { total: 29, paid: 87, refunded: 58, pending_link: 0, unpaid: 0, net_paid: 29 },
    payments: [{ id: 1086, method: 'montonio', provider: 'montonio', status: 'partially_refunded', amount: 87, refunded_amount: 58, refunds: [{ ...R64, status: 'done' }] }] });
  assert.equal(done.pending_refund, 0); assert.equal(L.paymentBox(done, { can: MANAGER }).display.state, 'paid');
  assert.equal(L.nextStep(done, { now: new Date('2026-11-12T20:00:00Z') }), null);
});

test('Talous-lista: hyvitysnappi ja dialogi vähentävät keskeneräiset hyvitykset', () => {
  const full = normOrder(raw([{ ...R64, amount: 87 }], 0));
  assert.deepEqual(visibleOrderActions(full, { canRefund: true, canAdd: false }).includes('refund'), false, 'kaikki jo hyvityksessä');
  assert.equal(visibleOrderActions(normOrder(raw([R64])), { canRefund: true }).includes('refund'), true);
  const tal = read('booking/admin/views/talous-orders.js');
  assert.match(tal, /const left = \(p\) => paymentRefundLeft\(p\);/);
  assert.doesNotMatch(tal, /p\.amount > \(?p\.refunded_amount/);
});

test('näkymä: neutraali seuraava askel ilman nappia, maksu-kortin rivi ja nappi piiloon kun ylisuoritus katettu; tekstit FI+EN + import 144', () => {
  const v = read('booking/admin/views/order-view.js');
  assert.match(v, /step\.kind === 'refund_pending'\) \{\n\s+title = ov\('order_view\.tl\.refund_pending'/);
  assert.match(v, /const btns = step\.kind === 'refund_pending' \? \[\]/);
  assert.match(v, /box\.pendingRefund > 0\.004 \? \['order_view\.amt\.refund_pending'/);
  assert.match(v, /!\(box\.refundCovered > 0\.004 && m\.overpaid <= 0\.004\)/);
  const rows = JSON.parse(read('content/site-texts.pending-import-144.json'));
  assert.equal(rows.length, 4);
  for (const r of rows) assert.equal(ORDER_VIEW_TEXTS[r.lang][r.key], r.text, r.key);
  assert.equal(ORDER_VIEW_TEXTS.fi['ui.admin.order_view.amt.refund_pending'], 'Hyvitys käsittelyssä');
});

test('css: neutraali "Hyvitys käsittelyssä" -palkki (ei keltaista varoitusta)', () => {
  assert.match(read('booking/admin/admin.css'), /\.ov-next-refund_pending\{background:var\(--card\);border-color:var\(--line\)\}/);
});
