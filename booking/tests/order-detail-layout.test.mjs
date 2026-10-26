// Tehtävä 03: hallinnan avattavan tilauksen rakenne ja toimintonappien näkyvyyssäännöt.
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { visibleOrderActions } from '../admin/order-actions-logic.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const hasFullRepo = existsSync(join(root, 'booking/admin/views/talous-orders.js'));
const read = (path) => readFileSync(join(root, path), 'utf8');
const source = hasFullRepo ? read('booking/admin/views/talous-orders.js') : '';
const BASE = {
  is_native: true, staff_can_add: true, balance: { unpaid: 29 },
  payments: [{ status: 'paid', amount: 40, refunded_amount: 0 }],
};
const enabled = { canAdd: true, canRefund: true };
const all = ['addToOrder', 'createPaymentLink', 'recordPayment', 'refund'];

test('kaikki neljä käytettävissä olevaa nappia oikeassa järjestyksessä', () => {
  assert.deepEqual(visibleOrderActions(BASE, enabled), all);
  assert.deepEqual(visibleOrderActions(BASE, { ...enabled }), all);
});

test('Johku ja suljettu tilaus: lisäys/linkki/kirjaus eivät näy', () => {
  assert.deepEqual(visibleOrderActions({ ...BASE, is_native: false }, enabled), ['refund'], 'hyvityksen erilliset ehdot pysyvät ennallaan');
  assert.deepEqual(visibleOrderActions({ ...BASE, staff_can_add: false }, enabled), all.slice(1), 'palvelimen staff_can_add');
  assert.deepEqual(visibleOrderActions(BASE, { canAdd: false, canRefund: true }), all.slice(1), 'bookings.manage puuttuu');
});

test('maksettavaa ei ole: maksulinkki ja maksun kirjaus katoavat', () => {
  assert.deepEqual(visibleOrderActions({ ...BASE, balance: { unpaid: 0 } }, enabled), ['addToOrder', 'refund']);
  assert.deepEqual(visibleOrderActions({ ...BASE, balance: { unpaid: -1 } }, enabled), ['addToOrder', 'refund']);
});

test('hyvitysoikeus, maksun tila ja jäljellä oleva osuus ratkaisevat hyvitysnappia', () => {
  assert.deepEqual(visibleOrderActions(BASE, { canAdd: true, canRefund: false }), all.slice(0, 3), 'payments.refund puuttuu');
  assert.deepEqual(visibleOrderActions({ ...BASE, payments: [] }, enabled), all.slice(0, 3), 'ei hyvitettävää maksua');
  assert.deepEqual(visibleOrderActions({ ...BASE, payments: [{ status: 'pending', amount: 40, refunded_amount: 0 }] }, enabled), all.slice(0, 3), 'avoin maksu');
  assert.deepEqual(visibleOrderActions({ ...BASE, payments: [{ status: 'paid', amount: 40, refunded_amount: 40 }] }, enabled), all.slice(0, 3), 'kokonaan hyvitetty');
  assert.deepEqual(visibleOrderActions({ ...BASE, payments: [{ status: 'partially_refunded', amount: 40, refunded_amount: 20 }] }, enabled), all, 'osittain hyvitetty');
  assert.deepEqual(visibleOrderActions({ ...BASE, payments: [{ status: 'refunded', amount: 40, refunded_amount: 0 }] }, enabled), all.slice(0, 3), 'status refunded');
});

test('yhtään sallittua toimintoa ei ole: tyhjä lista ja ei tyhjää nappiriviä', () => {
  assert.deepEqual(visibleOrderActions({ is_native: false, staff_can_add: false, balance: { unpaid: 0 }, payments: [] }, { canAdd: false, canRefund: false }), []);
});

test('palautusrakenteen järjestys ja kuittitekstin poisto', { skip: !hasFullRepo && 'Täysi GitHub-repo ei ole saatavilla paikallisesti' }, () => {
  assert.match(source, /const actions = visible\.length\s*\? h\('div', \{ class: 'tl-actions', 'data-testid': 'order-actions' \}/);
  assert.match(source, /: null;\s*const receipts = sec/);
  const at = source.indexOf("return h('div', { class: 'tl-detail' }");
  assert.ok(at >= 0, 'orderDetail-paluu löytyy');
  const tail = source.slice(at, source.indexOf('  // ---- dialogit ----', at));
  const order = [
    'meta, ...notes', 'sums', 'annualSec(annual, sec)',
    "sec(t('order.reservations'), reservations)", 'actions',
    "sec(t('order.payments'), payments)", 'vbox', "!o.is_native && !o.receipts.length ? null : receipts",
  ];
  let prev = -1;
  for (const token of order) {
    const pos = tail.indexOf(token);
    assert.ok(pos > prev, `järjestys rikkoutui kohdassa ${token}: ${tail}`);
    prev = pos;
  }
  assert.match(source, /receiptsList\(\{ api, ctx, receipts: o\.receipts \}\)/, 'kuitin lista säilyy');
  assert.doesNotMatch(source, /receipts\.emailNote/, 'kuittihuomautusta ei enää rakenneta näkymään');
});

test('tilaus-varaus-silta: id:t ja muuttumattomat tiedostot', { skip: !hasFullRepo && 'Täysi GitHub-repo ei ole saatavilla paikallisesti' }, () => {
  assert.match(source, /'data-testid': 'order-reservations'/);
  assert.match(source, /o\.reservations\.map\(\(r\) => h\('li'/, 'yksi li jokaista varausta kohden');
  assert.match(source, /row\.dataset\.orderId = o\.order_id/, 'tilausrivin data-order-id');
  for (const action of ['addToOrder', 'createPaymentLink'])
    assert.match(source, new RegExp("key: '" + action + "'"), `bridge-painike ${action}`);
  assert.match(read('booking/admin/views/talous-ui.js'), /'data-action': key/, 'actionBtn välittää data-actionin');
  const bridge = read('booking/admin/views/order-reservation-bridge.js');
  const shared = read('booking/admin/views/shared.js');
  assert.match(bridge, /flow:\s*\{/);
  assert.match(bridge, /order-open-reservation/);
  assert.match(bridge, /data-action=/);
  assert.doesNotMatch(bridge, /body\.append\(extra\)|Verkkomaksulinkki/);
  assert.match(shared, /res-summary/);
  assert.match(shared, /res-secondary-actions/);
  assert.doesNotMatch(shared, /Verkkomaksulinkki \(Visma Pay\)/);
});
