import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { visibleOrderActions } from '../admin/order-actions-logic.js';
import {
  orderInvoiceLocked, staffInvoiceChange, staffInvoiceCancel, customerInvoiceLock,
  invoiceLockReason, linkStaleNote, linkStaleKind,
} from '../admin/addon-lock-logic.js';
import { ADDON_LOCK_TEXTS, alt } from '../admin/addon-lock-texts.js';
import { setLang } from '../admin/talous-i18n.js';
import { normOrder, normOrderPayment } from '../admin/talous-api.js';
import { reservationActions } from '../admin/reservation-dialog-logic.js';
import { customerInvoiceLock as shopLock } from '../shop/src/invoice-lock.js';
import { T } from '../shop/src/i18n.js';
import { OT } from '../shop/src/order-texts.js';
import { createOrderMock } from '../shop/src/order-mock.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (path) => readFileSync(join(root, path), 'utf8');
const base = {
  is_native: true, staff_can_add: true, balance: { unpaid: 29 },
  payments: [{ status: 'paid', amount: 40, refunded_amount: 0 }],
};
const enabled = { canAdd: true, canRefund: true };

test('laskutettu tilaus piilottaa lisäyksen, linkin ja kirjauksen, hyvitys jää', () => {
  const locked = { ...base, invoice_locked: true, invoice_no: 'L000185', staff_can_add: true };
  assert.deepEqual(visibleOrderActions(locked, enabled), ['refund']);
  assert.deepEqual(visibleOrderActions(base, enabled), ['addToOrder', 'createPaymentLink', 'recordPayment', 'refund']);
  assert.equal(orderInvoiceLocked(locked), true);
  assert.equal(orderInvoiceLocked(base), false);
});

test('henkilökunta voi siirtää ja muuttaa henkilömäärää, hyvitysvalinta piiloon', () => {
  const order = { order_id: 7, is_native: true, staff_can_add: true, invoice_locked: true, invoice_no: 'L000185', balance: { unpaid: 20 } };
  const change = staffInvoiceChange(order);
  assert.equal(change.personsEnabled, true);
  assert.equal(change.moveEnabled, true);
  assert.equal(change.showNewPrice, false);
  assert.equal(staffInvoiceCancel(order).allowRefundChoice, false);
  assert.equal(staffInvoiceCancel({ invoice_locked: false }).allowRefundChoice, true);
  const actions = reservationActions(
    { reservation_id: 11, status: 'confirmed', space_code: 'rauni', persons: 1, starts_at: '2026-11-28T22:30:00Z' },
    { can: () => true, order, rawOrder: { reservations: [{ id: 11, addons: [] }], items: [], payments: [] }, flowEnabled: true, now: '2026-11-29T11:00:00Z' },
  );
  assert.equal(actions.primary.includes('change'), true);
  assert.equal(actions.primary.includes('addPurchase'), false);
  assert.equal(actions.primary.includes('createLink'), false);
  assert.equal(actions.secondary.includes('cancel'), true);
  assert.equal(actions.payment.recordPayment, false);
  assert.equal(actions.editAddons, false);
  assert.equal(actions.move?.show, true);
});

test('linkki: vanha summa kehottaa uuteen linkkiin, lasku ei', () => {
  const pay = { status: 'pending', provider: 'visma_pay', link_token: 't', link_stale: true, amount: 40 };
  setLang('fi');
  assert.equal(linkStaleKind(pay, {}), 'stale');
  assert.match(linkStaleNote(pay, {}, alt), /luo uusi linkki/);
  assert.match(linkStaleNote(pay, { invoice_locked: true }, alt), /laskutettu/);
  assert.doesNotMatch(linkStaleNote(pay, { invoice_locked: true }, alt), /uusi linkki/i);
  setLang('en');
  assert.match(linkStaleNote(pay, {}, alt), /create a new link/i);
  assert.match(invoiceLockReason({ invoice_locked: true, invoice_no: 'L000185' }, alt), /L000185/);
  assert.equal(linkStaleNote({ status: 'paid', link_stale: false }, {}, alt), '');
  setLang('fi');
});

test('normOrder kopioi lukituksen ja link_stale', () => {
  const o = normOrder({ order_id: 1, order_no: 2, invoice_locked: true, invoice_no: 'L9', balance: { unpaid: 1 }, can_add: true, staff_can_add: true,
    payments: [{ id: 3, status: 'pending', provider: 'mobilepay', link_token: 'x', link_stale: true, amount: 9, lines: [] }] });
  assert.equal(o.invoice_locked, true);
  assert.equal(o.invoice_no, 'L9');
  assert.equal(o.payments[0].link_stale, true);
  assert.equal(normOrderPayment({ id: 1, status: 'paid', amount: 1 }).link_stale, false);
  assert.equal(normOrder({ order_id: 1, balance: {} }).invoice_locked, false);
});

test('asiakkaan lukko: ei peruutusnappia, henkilömäärä kiinni, aika sallittu', () => {
  const open = customerInvoiceLock({ status: 'pending' });
  assert.equal(open.showPendingCancel, true);
  assert.equal(open.personsDisabled, false);
  assert.equal(open.showPriceEstimate, true);
  const locked = shopLock({ invoice_locked: true, status: 'pending' });
  assert.deepEqual(locked, customerInvoiceLock({ invoice_locked: true }));
  assert.equal(locked.showPendingCancel, false);
  assert.equal(locked.personsDisabled, true);
  assert.equal(locked.showPriceEstimate, false);
  const shop = read('shop/src/shop.js');
  assert.match(shop, /invoiced-cancel-note/);
  assert.match(shop, /invoiced-persons-note/);
  assert.match(shop, /showPriceEstimate/);
  assert.match(read('shop/src/treatment-ui.js'), /lockPersons/);
  assert.match(read('shop/src/order.js'), /invoiced-pay-note/);
  assert.match(read('shop/src/shop.js'), /order_invoiced_persons/);
  assert.match(read('shop/src/treatment-ui.js'), /order_invoiced_persons/);
  for (const lang of ['fi', 'en']) {
    assert.ok(T[lang].invoicedCancelNote && T[lang].invoicedPersonsNote && T[lang].invoicedSumNote);
    assert.match(T[lang].errors.order_invoiced, /Peruutus|Cancellation/);
    assert.match(T[lang].errors.order_invoiced_persons, /henkilömäär|number of guests/i);
    assert.notEqual(T[lang].errors.order_invoiced, T[lang].errors.order_invoiced_persons);
    assert.ok(OT[lang]['err.order_invoiced'] && OT[lang].invoicedNote);
    assert.equal(T[lang].invoicedCancelNote.includes('€') || /\d/.test(T[lang].invoicedPersonsNote), false);
  }
});

test('tekstit FI/EN ja mock-skenaariot', async () => {
  assert.deepEqual(Object.keys(ADDON_LOCK_TEXTS.fi).sort(), Object.keys(ADDON_LOCK_TEXTS.en).sort());
  for (const key of ['invoiced', 'error_invoiced', 'invoiced_hint', 'persons_invoiced_hint', 'cancel_invoiced_hint', 'link_stale', 'link_unpayable_invoiced']) {
    assert.ok(ADDON_LOCK_TEXTS.fi[key] && ADDON_LOCK_TEXTS.en[key]);
  }
  const rows = JSON.parse(readFileSync(join(root, '..', 'content/site-texts.pending-import-80.json'), 'utf8'));
  const keys = new Set(rows.map((r) => `${r.lang}:${r.key}`));
  for (const key of ['ui.admin.addon_lock.invoiced', 'ui.shop.error_order_invoiced', 'ui.shop.error_order_invoiced_persons', 'ui.order.err.order_invoiced', 'ui.order.invoiced_note', 'ui.shop.invoiced_persons_note']) {
    assert.equal(keys.has(`fi:${key}`) && keys.has(`en:${key}`), true, key);
  }
  for (const row of rows) assert.equal(/€|\d+[.,]\d+/.test(row.text), false, row.key);
  const order = createOrderMock({ scenario: 'invoice_locked' });
  const got = await order.rpc('public_get_order', { p_token: '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b' });
  assert.equal(got.invoice_locked, true);
  assert.equal(got.payments.some((p) => p.link_stale), true);
  const added = await order.rpc('public_add_to_order', { p_token: 'x', p_items: [{ type: 'addon', code: 'pyyhe', quantity: 1 }] });
  assert.equal(added.code, 'order_invoiced');
  const shop = read('shop/src/shop-mock.js');
  assert.match(shop, /scenario === 'invoice_locked'/);
  assert.match(shop, /code: 'order_invoiced'/);
});
