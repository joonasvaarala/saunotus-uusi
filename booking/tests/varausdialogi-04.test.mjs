import assert from 'node:assert/strict';
import test from 'node:test';
import { reservationActions, arrivalActionsAllowed, moveTarget, addonsEditable, telHref, mailHref, createLatestGate } from '../admin/reservation-dialog-logic.js';
import { LINK_DEADLINE, linkExpiresDays, linkValidityText, linkSubmitOnce } from '../admin/payment-link-logic.js';

const r = (status = 'confirmed', extra = {}) => ({ reservation_id: 11, status, space_code: 'rauni', persons: 1,
  starts_at: '2026-11-28T22:30:00Z', notes: '', ...extra });
const permitted = () => true;
const order = (unpaid = 20, extra = {}) => ({ order_id: 7, is_native: true, staff_can_add: true,
  balance: { total: 50, paid: 30, unpaid }, ...extra });
const rawOrder = (addons = []) => ({ reservations: [{ id: 11, item_id: 30, addons }],
  items: addons.map((a, i) => ({ id: i + 50, kind: 'addon', parent_item_id: 30, quantity: a.quantity })), payments: [] });
const date = '2026-11-29T11:00:00Z';
const actions = (status = 'confirmed', options = {}) => reservationActions(r(status), {
  can: permitted, order: order(), rawOrder: rawOrder(), flowEnabled: true, now: date, ...options,
});

test('D1 ja D4: näkyvyys ja napin järjestys', () => {
  assert.deepEqual(actions('pending').primary, ['confirm', 'addPurchase', 'createLink', 'change']);
  assert.deepEqual(actions('confirmed').primary, ['addPurchase', 'createLink', 'arrive', 'change']);
  assert.deepEqual(actions('confirmed').secondary, ['noShow', 'cancel']);
  assert.deepEqual(actions('cancelled').secondary, ['confirm']);
  assert.deepEqual(actions('expired').secondary, ['confirm']);
  assert.deepEqual(actions('no_show').secondary, []);
  assert.deepEqual(actions('completed').primary, ['addPurchase', 'createLink']);
});

test('D2: saapuminen vasta Helsingin varauspäivästä alkaen', () => {
  for (const [now, wanted] of [
    ['2026-11-28T21:59:00Z', false],
    ['2026-11-28T22:00:00Z', true],
    ['2026-11-28T22:29:00Z', true],
    ['2026-11-28T22:31:00Z', true],
    ['2026-11-30T08:00:00Z', true],
  ]) assert.equal(arrivalActionsAllowed(r(), now), wanted, now);
  assert.equal(arrivalActionsAllowed(r('pending'), date), false);
  const before = actions('confirmed', { now: '2026-11-28T21:59:00Z' });
  assert.equal(before.primary.includes('arrive'), false);
  assert.equal(before.secondary.includes('noShow'), false);
});

test('D3: flow pois, maksulinkki silti näkyvissä', () => {
  const a = actions('confirmed', { flowEnabled: false });
  assert.equal(a.primary.includes('addPurchase'), false);
  assert.equal(a.primary.includes('createLink'), true);
  assert.equal(a.editAddons, true);
  assert.equal(actions('confirmed', { order: order(0) }).primary.includes('createLink'), false);
  assert.equal(actions('confirmed', { order: order(0) }).payment.recordPayment, false);
  assert.equal(actions('confirmed', { order: order(10) }).payment.recordPayment, true);
  assert.equal(actions('confirmed', { order: null }).primary.includes('addPurchase'), false);
  assert.equal(actions('confirmed', { order: order(20, { staff_can_add: false }) }).primary.includes('addPurchase'), false);
});

test('Käyttöoikeudet ja Johku estävät niihin liittyvät napit', () => {
  const noBookings = actions('confirmed', { can: (perm) => perm !== 'bookings.manage' });
  assert.equal(noBookings.primary.includes('change'), false);
  assert.equal(noBookings.primary.includes('addPurchase'), false);
  assert.equal(noBookings.secondary.length, 0);
  assert.equal(noBookings.note, null);
  const noPayments = actions('confirmed', { can: (perm) => perm !== 'payments.manage' });
  assert.equal(noPayments.primary.includes('createLink'), false);
  assert.equal(noPayments.payment.openOrder, false);
  assert.equal(noPayments.payment.recordPayment, false);
  const johku = actions('confirmed', { order: order(50, { is_native: false, external_source: 'johku' }) });
  assert.equal(johku.primary.includes('addPurchase'), false);
  assert.equal(johku.primary.includes('createLink'), false);
  assert.equal(johku.payment.recordPayment, false);
  assert.equal(johku.editAddons, true);
});

test('D5: lisäpalveluiden muokkaus vain korjauksiin, kun lisäosto toimii', () => {
  const noAddon = actions('confirmed');
  assert.equal(noAddon.editAddons, false);
  const addOn = [{ addon_id: 10, quantity: 2 }];
  const orderWithAddons = rawOrder(addOn);
  assert.equal(addonsEditable(orderWithAddons, 11), true);
  assert.equal(actions('confirmed', { rawOrder: orderWithAddons }).editAddons, true);
  assert.equal(actions('confirmed', { rawOrder: orderWithAddons, flowEnabled: false }).editAddons, true);
  assert.equal(actions('pending', { rawOrder: rawOrder(), order: order(20, { staff_can_add: false }) }).editAddons, true);
});

test('Tilasiirron rajoitukset', () => {
  assert.equal(moveTarget(r(), permitted), 'lovi');
  assert.equal(moveTarget(r('confirmed', { persons: 2 }), permitted), null);
  assert.equal(moveTarget(r('confirmed', { space_code: 'lovi' }), permitted), 'rauni');
  assert.equal(moveTarget(r('confirmed', { space_code: null }), permitted), null);
  assert.equal(moveTarget(r('cancelled'), permitted), null);
  assert.equal(moveTarget(r(), () => false), null);
});

test('Asiakkaan turvalliset yhteystietolinkit', () => {
  assert.equal(telHref('+358 40 123 45 67'), 'tel:+358401234567');
  assert.equal(telHref(''), null);
  assert.equal(telHref('abc'), null);
  assert.equal(mailHref('  asiakas@example.test  '), 'mailto:asiakas@example.test');
  assert.equal(mailHref('<img onerror=alert(1)>'), null);
});

test('D6: ei takarajaa oletuksena, valinnainen 1–60 päivän takaraja', () => {
  assert.equal(LINK_DEADLINE.max, 60);
  assert.deepEqual(linkExpiresDays({ enabled: false, days: 14 }), { ok: true, expiresDays: undefined });
  for (const days of [1, 14, 60, '7']) assert.deepEqual(linkExpiresDays({ enabled: true, days }), { ok: true, expiresDays: Number(days) });
  for (const days of [0, 61, 1.5, '', 'abc', null, '1e1', '7.0', '7.5']) assert.deepEqual(linkExpiresDays({ enabled: true, days }), { ok: false, error: 'link_deadline_bad' });
  const tx = (key, vars) => `${key}${vars?.date || ''}`;
  assert.equal(linkValidityText({ expires_at: null }, tx, String), 'ui.admin.orders.link_no_deadline');
  assert.equal(linkValidityText({ expires_at: 'null' }, tx, String), 'ui.admin.orders.link_no_deadline');
  assert.equal(linkValidityText({ link_expires_at: null, expires_date: null }, tx, () => 'Invalid Date'), 'ui.admin.orders.link_no_deadline');
  assert.equal(linkValidityText({ expires_at: '2026-12-01' }, tx, String), 'ui.admin.orders.link_valid_until2026-12-01');
});

test('maksulinkki: kaksoislähetys estetään ja virhe vapauttaa lukon', async () => {
  let calls = 0;
  const once = linkSubmitOnce(() => undefined, async (days) => { calls += 1; return days; });
  const first = once({});
  const second = once({});
  assert.equal(await first, undefined);
  assert.equal(await second, undefined);
  assert.equal(calls, 1);
  let reads = 0;
  const bad = linkSubmitOnce(() => { reads += 1; throw new Error('bad'); }, async () => { calls += 1; });
  await assert.rejects(() => bad({}), /bad/);
  await assert.rejects(() => bad({}), /bad/);
  assert.equal(reads, 2);
  assert.equal(calls, 1);
  let sent = 0;
  const retry = linkSubmitOnce(() => 14, async () => { sent += 1; if (sent === 1) throw new Error('net'); return 14; });
  await assert.rejects(() => retry({}), /net/);
  assert.equal(await retry({}), 14);
  assert.equal(sent, 2);
});

test('vanha vastaus ei ole enää voimassa', () => {
  const gate = createLatestGate();
  const older = gate.next();
  const newer = gate.next();
  assert.equal(gate.isCurrent(older), false);
  assert.equal(gate.isCurrent(newer), true);
});

// Lähdekoodin rakennetarkistukset eivät korvaa selaimessa tehtäviä e2e-testejä.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
const admin = join(dirname(fileURLToPath(import.meta.url)), '..', 'admin');
const root = join(admin, '..', '..');
const readAdmin = (rel) => readFileSync(join(admin, rel), 'utf8');

test('UI04: järjestys, testidit, suljetut harvinaiset osiot ja null-turvallisuus', () => {
  const src = readAdmin('views/shared.js');
  const anchors = ['res-summary', 'res-customer', 'res-primary-actions', 'res-payment', 'res-contents',
    'res-note-editor', 'res-secondary-actions', 'res-more', 'res-move'];
  const positions = anchors.map((value) => src.indexOf(`'data-testid': '${value}'`));
  assert.ok(positions.every((n) => n >= 0), JSON.stringify(anchors.map((value, i) => [value, positions[i]])));
  assert.ok(positions.every((n, i) => i === 0 || n > positions[i - 1]));
  assert.match(src, /body\.append\(\.\.\.list\(/);
  assert.doesNotMatch(src, /Verkkomaksulinkki \(Visma Pay\)|admin_create_payment_link|innerHTML/);
  assert.match(src, /h\('details', \{ class: 'rd-more'/);
  assert.match(src, /h\('details', \{ class: 'rd-more rd-move'/);
  assert.match(src, /data-testid': 'res-no-show'/);
  assert.match(src, /formDialog\(tx\('ui\.admin\.res\.no_show_title'/);
});

test('UI04: silta ei tee DOM-jälkikäsittelyä, vaan antaa flow-parametrin', () => {
  const src = readAdmin('views/order-reservation-bridge.js');
  assert.match(src, /flow:\s*\{/);
  assert.match(src, /order-open-reservation/);
  assert.match(src, /data-action=/);
  assert.match(src, /MutationObserver/);
  assert.doesNotMatch(src, /Verkkomaksulinkki|body\.append\(extra\)|innerHTML/);
});

test('UI04: takarajaohjaimen alkuvalinta on pois ja kentän päiväraja 60', () => {
  const orderAdd = readAdmin('views/order-add.js');
  const orders = readAdmin('views/talous-orders.js');
  const control = readAdmin('views/link-deadline.js');
  const src = `${orderAdd}\n${orders}\n${control}`;
  assert.match(control, /type: 'checkbox', name: 'deadline'/);
  assert.match(control, /disabled: true/);
  assert.match(control, /linkDeadlineControl/);
  assert.match(orderAdd, /deadline\.read\(fd\)/);
  assert.match(orderAdd, /createPaymentLink\(\{[^}]*sendEmail: false/s);
  assert.match(orders, /deadline\.read\(fd\)/);
  assert.match(orders, /linkSubmitOnce/);
  assert.doesNotMatch(src, /max:\s*90|value:\s*14,\s*required:\s*true|\|\| 14\)/);
  assert.doesNotMatch(readAdmin('views/shared.js'), /payment-link-04|reservation-texts-04/);
  assert.doesNotMatch(src, /p_expires_days:\s*null|expiresDays:\s*null/);
});

test('UI04: FI/EN-avainluettelo vastaa pending-import-78-tiedostoa', async () => {
  const { ORDER_TEXTS } = await import('../admin/orders-texts.js');
  const lines = JSON.parse(readFileSync(join(root, 'content/site-texts.pending-import-78.json'), 'utf8'));
  const keys = [...new Set(lines.map((x) => x.key))];
  assert.equal(lines.length, keys.length * 2);
  for (const item of lines) {
    assert.equal(ORDER_TEXTS[item.lang][item.key], item.text, `${item.key} ${item.lang}`);
    assert.equal(item.text.includes('<'), false, item.key);
    assert.deepEqual(item.placeholders, [...item.text.matchAll(/\{\{var:[^}]+\}\}/g)].map((m) => m[0]));
  }
});

test('asiakkaan maksusivu: tyhjä voimassaolo ei ole Invalid Date', async () => {
  const { normLinkInfo, linkInfoView, fmtDate } = await import('../shop/src/pay-link-logic.js');
  const info = normLinkInfo({ ok: true, status: 'open', reason: 'open', can_pay: true, amount: 10, currency: 'EUR', expires_date: null, expires_time: null, items: [] });
  assert.equal(info.expires_date, null);
  assert.equal(linkInfoView(info).validKey, null);
  assert.equal(fmtDate('fi', null), '');
  assert.equal(fmtDate('en', 'null'), '');
  assert.equal(linkInfoView(normLinkInfo({ ok: true, status: 'open', reason: 'open', can_pay: true, amount: 10, expires_date: 'null', items: [] })).validKey, null);
});
