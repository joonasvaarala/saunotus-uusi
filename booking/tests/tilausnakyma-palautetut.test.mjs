// HALL-TILAUS-01: vanhan kortin toiminnot uudessa tilausnäkymässä (Ei saapunut, poisto, peruutuspyyntö, yrityksen laskutustiedot,
// vuosikortti, keskeneräisen hyvityksen uudelleenyritys). Samat RPC:t ja oikeudet kuin vanhassa kortissa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as L from '../admin/order-view-logic.js';
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const can = (...p) => (x) => p.includes(x);
const NOW = new Date('2026-11-11T14:55:00Z');
const res = (o = {}) => ({ id: 1, status: 'confirmed', starts_at: '2026-11-11T14:30:00Z', ends_at: '2026-11-11T16:00:00Z', addons: [], option_choices: [], ...o });

test('Ei saapunut: vahvistettu varaus varauspäivästä alkaen, vain bookings.manage; ei tulevalle eikä perutulle', () => {
  const m = { is_native: true, raw: {}, reservations: [] };
  assert.ok(L.reservationRowActions(res(), m, { can: can('bookings.manage'), now: NOW }).includes('noShow'));
  assert.ok(L.reservationRowActions(res({ starts_at: '2026-11-09T14:00:00Z' }), m, { can: can('bookings.manage'), now: NOW }).includes('noShow'), 'mennyt päivä');
  assert.ok(!L.reservationRowActions(res({ starts_at: '2026-11-19T14:00:00Z' }), m, { can: can('bookings.manage'), now: NOW }).includes('noShow'), 'tuleva');
  assert.ok(!L.reservationRowActions(res({ status: 'cancelled' }), m, { can: can('bookings.manage'), now: NOW }).includes('noShow'));
  assert.ok(!L.reservationRowActions(res({ status: 'pending' }), m, { can: can('bookings.manage'), now: NOW }).includes('noShow'));
  assert.ok(!L.reservationRowActions(res(), m, { can: can(), now: NOW }).includes('noShow'), 'ilman oikeutta');
});

test('peruutuspyyntö: vain avoin cancel-pyyntö', () => {
  assert.equal(L.openCancelRequest({ requests: [] }), null);
  assert.equal(L.openCancelRequest({ requests: [{ kind: 'cancel', status: 'handled' }] }), null);
  assert.deepEqual(L.openCancelRequest({ requests: [{ kind: 'cancel', status: 'open', reason: 'sairas' }] }), { kind: 'cancel', status: 'open', reason: 'sairas' });
  assert.equal(L.openCancelRequest({ requests: [{ kind: 'change', status: 'open' }] }), null);
});

test('hyvityksen uudelleenyritys: requested/processing verkkomaksulle payments.refund-oikeudella; failed näytetään ilman nappia', () => {
  const pays = [
    { provider: 'mobilepay', refunds: [{ id: 1, status: 'requested', amount: 10 }, { id: 2, status: 'failed', amount: 5 }, { id: 3, status: 'done', amount: 1 }] },
    { provider: 'cash', refunds: [{ id: 4, status: 'processing', amount: 3 }] },
  ];
  const rows = L.openRefundRows(pays, { can: can('payments.refund') });
  assert.deepEqual(rows.map((r) => [r.refund.id, r.canRetry]), [[1, true], [2, false], [4, false]]);
  assert.deepEqual(L.openRefundRows(pays, { can: can() }).map((r) => r.canRetry), [false, false, false]);
  assert.deepEqual(L.openRefundRows(pays, { can: can('payments.refund'), mock: true }).map((r) => r.canRetry), [false, false, false]);
});

test('näkymä: poisto, vuosikortti, laskutustiedot, peruutuspyyntö ja uudelleenyritys kytketty; vain olemassa olevat RPC:t', () => {
  const v = read('booking/admin/views/order-view.js');
  assert.match(v, /orderDeleteBlock\(\{ api: talousApi, order: normOrder\(m\.raw\), check,/);
  assert.match(v, /talousApi\.orderDeleteCheck\(m\.order_id\)/);
  assert.match(v, /talousApi\.annualCardForOrder\(m\.order_id\)/);
  assert.match(v, /'data-testid': 'ov-cancel-request'/);
  assert.match(v, /'Yritysasiakas – laskutustiedot'/);
  assert.match(v, /x\.einvoice_address && \[x\.einvoice_address, x\.einvoice_operator\]/);
  assert.match(v, /processOnlineRefunds\(env\.api, \[\{ status: 'requested', provider: row\.payment\.provider, refund_id: row\.refund\.id \}\]\)/);
  assert.match(v, /status\(a\.reservation_id, 'no_show'\)/);
  assert.match(v, /await confirmAsk\(orderText\('ui\.admin\.res\.no_show_text'\)/);
  assert.match(v, /side = h\('aside', \{ class: 'ov-side' \}, paymentCard\(m, env, runner\), customerCard\(m, env\), billingCard\(m\), annualCard\(m, env\), notesCard/);
});
