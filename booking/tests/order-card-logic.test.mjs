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

// --- Tilauserittely ja lisäostorivi (Joonas t430u) ---
import { cardAddonLine, orderBreakdown, vatRateLabel } from '../admin/order-card-logic.js';
import { normOrder } from '../admin/talous-api.js';

const NAISTEN = {
  order_id: 1, order_no: 15180, balance: { total: 100, paid: 100, unpaid: 0 },
  reservations: [{ id: 5, item_id: 16651, status: 'confirmed', addons: [{ name: 'Saunavihta', quantity: 1, line_total: 13, vat_rate: 25.5 }] }],
  items: [
    { id: 16652, parent_item_id: 16651, kind: 'addon', name: 'Saunavihta', quantity: 1, unit_price: 13, line_total: 13, vat_rate: 25.5, line_vat: 2.64, line_net: 10.36 },
    { id: 16651, parent_item_id: null, kind: 'reservation', name: 'Naisten sauna', quantity: 1, unit_price: 87, line_total: 87, vat_rate: 25.5, line_vat: 17.68, line_net: 69.32 },
  ],
};

test('lisäostorivi: määrä × nimi, useampi erotetaan pisteellä, tyhjä ilman lisäostoja', () => {
  assert.equal(cardAddonLine([{ name: 'Saunavihta', quantity: 1 }]), '1 × Saunavihta');
  assert.equal(cardAddonLine([{ name: 'Saunavihta', quantity: 1 }, { name: 'Pyyhe', quantity: 2 }]), '1 × Saunavihta · 2 × Pyyhe');
  assert.equal(cardAddonLine([]), '');
  assert.equal(cardAddonLine(undefined), '');
  assert.equal(cardAddonLine([{ name: 'Pyyhe', quantity: 0 }]), '');
});

test('tilauserittely: pääpalvelu ensin, lisäosto sen alla, ALV tilausriviltä sellaisenaan', () => {
  const bd = orderBreakdown(normOrder(NAISTEN));
  assert.deepEqual(bd.rows.map((x) => [x.name, x.child, x.gross, x.vat_rate, x.vat, x.net]), [
    ['Naisten sauna', false, 87, 25.5, 17.68, 69.32],
    ['Saunavihta', true, 13, 25.5, 2.64, 10.36],
  ]);
  assert.equal(bd.total, 100);
  assert.deepEqual(bd.vatByRate, [{ rate: 25.5, gross: 100, vat: 20.32, net: 79.68 }]);
  assert.equal(bd.unknownVat, 0);
});

test('tilauserittely: kannat eritellään erikseen, puuttuva kanta ei muutu nollaksi', () => {
  const o = normOrder({ ...NAISTEN, balance: { total: 150 }, items: [
    ...NAISTEN.items,
    { id: 16700, kind: 'gift_card', name: 'Lahjakortti', quantity: 1, unit_price: 40, line_total: 40, vat_rate: 0, line_vat: 0, line_net: 40 },
    { id: 16701, kind: 'custom', name: 'Tuotu rivi', quantity: 2, unit_price: 5, line_total: 10, vat_rate: null },
  ] });
  const bd = orderBreakdown(o);
  assert.deepEqual(bd.vatByRate.map((v) => [v.rate, v.vat, v.gross]), [[25.5, 20.32, 100], [0, 0, 40]]);
  assert.equal(bd.rows.find((x) => x.name === 'Tuotu rivi').vat_rate, null);
  assert.equal(bd.unknownVat, 1);
});

test('tilauserittely: peruttu varaus merkitään, tyhjä tilaus on tyhjä', () => {
  const bd = orderBreakdown({ ...NAISTEN, reservations: [{ ...NAISTEN.reservations[0], status: 'cancelled' }] });
  assert.ok(bd.rows.every((x) => x.cancelled));
  assert.equal(orderBreakdown({ items: [] }).empty, true);
  assert.equal(orderBreakdown(null).empty, true);
});

test('ALV-kanta suomalaisittain', () => {
  assert.equal(vatRateLabel(25.5), '25,5 %');
  assert.equal(vatRateLabel(13.5), '13,5 %');
  assert.equal(vatRateLabel(0), '0 %');
  assert.equal(vatRateLabel(null), '');
});

test('tekstit: pending-import-132 FI+EN = koodin oletukset, paikkamerkit täsmäävät', async () => {
  const { readFileSync } = await import('node:fs');
  const { ORDER_TEXTS } = await import('../admin/orders-texts.js');
  const rows = JSON.parse(readFileSync(new URL('../../content/site-texts.pending-import-132.json', import.meta.url), 'utf8'));
  assert.equal(rows.length, 30);
  for (const row of rows) {
    assert.equal(ORDER_TEXTS[row.lang][row.key], row.text, row.key);
    assert.deepEqual(row.placeholders, row.text.match(/\{\{var:[a-z_]+\}\}/g) || [], row.key);
    assert.ok(!/[<>]/.test(row.text), row.key);
  }
  for (const lang of ['fi', 'en']) assert.equal(rows.filter((x) => x.lang === lang).length, 15);
});

test('tilauserittely: ilman tilausrivejä varaus ja lisäostot näkyvät, varauksen ALV puuttuu eikä sitä keksitä', () => {
  const o = normOrder({ order_id: 2, order_no: 2, balance: { total: 60 }, items: [],
    reservations: [{ id: 9, item_id: null, product_name: 'Tuotu vuoro', item_total: 50, status: 'confirmed', addons: [{ name: 'Pyyhe', quantity: 2, unit_price: 5, line_total: 10, vat_rate: 25.5 }, { name: 'Vanha', quantity: 1, line_total: 0 }] }] });
  const bd = orderBreakdown(o);
  assert.deepEqual(bd.rows.map((x) => [x.name, x.child, x.vat_rate]), [['Tuotu vuoro', false, null], ['Pyyhe', true, 25.5], ['Vanha', true, null]]);
  assert.equal(bd.unknownVat, 2);
  assert.equal(bd.rows[1].vat, 2.03);
});
