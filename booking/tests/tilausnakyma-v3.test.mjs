// Tilausnäkymä v3 (PR 1, booking_278): yhteenvedon / koko tilauksen / mobiilipalkin / asiakasnäkymän puhdas logiikka,
// tekstit (pending-import-137) ja migraation rakenne. Ajo: node --test booking/tests/tilausnakyma-v3.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as L from '../admin/order-view-logic.js';
import { ORDER_VIEW_TEXTS, PREFIXES, ov, primeOvTexts, clearOvTextCache } from '../admin/order-view-texts.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const NOW = new Date('2026-11-11T14:55:00Z');   // ke 11.11.2026 klo 16.55 Helsinki
const TODAY = '2026-11-11T14:30:00Z', FUTURE = '2026-11-19T14:00:00Z', PAST = '2026-11-02T14:00:00Z';
const all = (...p) => (perm) => p.includes(perm);
const MANAGER = all('bookings.manage', 'payments.manage', 'payments.refund');

const res = (o = {}) => ({ id: 1, status: 'confirmed', product_name: 'Saunahoito', starts_at: FUTURE, ends_at: '2026-11-19T15:30:00Z', persons: 2, notes: null, item_total: 85, item_id: 10, product_id: 3, addons: [], option_choices: [], ...o });
const raw = (o = {}) => ({
  order_id: 7001, order_no: 7001, status: 'confirmed', payment_status: 'unpaid', created_at: '2026-11-09T10:50:00Z', source_channel: 'web', is_native: true,
  customer: { id: 5, name: 'Maija Esimerkki', email: 'maija@example.com', phone: '+358400000000' }, staff_can_add: true, invoice_locked: false,
  balance: { total: 98, paid: 0, refunded: 0, pending_link: 0, unpaid: 98, net_paid: 0 },
  reservations: [res()], items: [], payments: [], receipts: [], refunds: [], emails: [], requests: [], ...o,
});
const model = (o) => L.orderModel(raw(o));

test('helDay ja reservationWhen: Helsingin kalenteripäivä', () => {
  assert.equal(L.helDay('2026-11-10T22:30:00Z'), '2026-11-11', 'UTC-ilta on Helsingissä jo seuraava päivä');
  assert.equal(L.reservationWhen({ starts_at: TODAY }, NOW), 'today');
  assert.equal(L.reservationWhen({ starts_at: FUTURE }, NOW), 'future');
  assert.equal(L.reservationWhen({ starts_at: PAST }, NOW), 'past');
  assert.equal(L.helDay(null), null);
});

test('Saapunut näkyy VAIN varauspäivänä ja vain vahvistetulle (t40u)', () => {
  assert.equal(L.canMarkArrived(res({ starts_at: TODAY }), NOW), true);
  assert.equal(L.canMarkArrived(res({ starts_at: FUTURE }), NOW), false, 'tuleville ei mitään saapumiseen liittyvää');
  assert.equal(L.canMarkArrived(res({ starts_at: PAST }), NOW), false, 'mennyt päivä: ei enää Saapunut-nappia');
  assert.equal(L.canMarkArrived(res({ starts_at: TODAY, status: 'pending' }), NOW), false);
  assert.equal(L.canMarkArrived(res({ starts_at: TODAY, status: 'no_show' }), NOW), false);
});

test('varausrivin toiminnot tilan, päivän ja oikeuden mukaan; Ei saapunut ei ole koskaan toiminto', () => {
  const m = model({ reservations: [res({ starts_at: TODAY, persons: 1, space_code: 'rauni', option_choices: [{ code: 'a' }] })], reservation_meta: [{ id: 1, space_code: 'rauni', rule_id: 9 }] });
  const r = m.reservations[0];
  const acts = L.reservationRowActions(r, m, { can: MANAGER, now: NOW });
  assert.deepEqual(acts, ['arrive', 'change', 'option', 'addons', 'move', 'cancel']);
  assert.ok(!acts.includes('noShow'));
  const fut = model();
  assert.deepEqual(L.reservationRowActions(fut.reservations[0], fut, { can: MANAGER, now: NOW }), ['change', 'addons', 'cancel'], 'tulevalle ei saapumista');
  assert.deepEqual(L.reservationRowActions(fut.reservations[0], fut, { can: () => false, now: NOW }), [], 'ilman bookings.manage ei mitään');
  const pend = model({ reservations: [res({ status: 'pending' })] });
  assert.equal(L.reservationRowActions(pend.reservations[0], pend, { can: MANAGER, now: NOW })[0], 'confirm');
  const locked = model({ invoice_locked: true, invoice_no: 'L-1' });
  assert.ok(!L.reservationRowActions(locked.reservations[0], locked, { can: MANAGER, now: NOW }).includes('addons'), 'laskulukko: lisäostot lukossa');
  assert.ok(L.reservationRowActions(locked.reservations[0], locked, { can: MANAGER, now: NOW }).includes('change'), 'laskulukko: aikaa voi siirtää');
  const cancelled = model({ reservations: [res({ status: 'cancelled' })] });
  assert.deepEqual(L.reservationRowActions(cancelled.reservations[0], cancelled, { can: MANAGER, now: NOW }), []);
  assert.deepEqual(L.reservationBadge(res({ status: 'no_show' })), { kind: 'st-no_show', key: 'status.no_show' }, 'Ei saapunut = vain tilamerkki');
  assert.equal(L.reservationBadge(res({ status: 'completed' })).key, 'res.arrived');
});

test('päätoiminnot: tänään Saapunut + Ota maksu, tulevalle Lähetä maksulinkki + Ota maksu, laskulukossa Avaa Laskutuksessa', () => {
  const today = model({ reservations: [res({ starts_at: TODAY })] });
  assert.deepEqual(L.primaryActions(today, { can: MANAGER, now: NOW }).map((a) => a.key), ['arrive', 'takePayment']);
  const fut = model();
  assert.deepEqual(L.primaryActions(fut, { can: MANAGER, now: NOW }).map((a) => a.key), ['sendLink', 'takePayment']);
  const sent = model({ emails: [{ kind: 'payment_link', status: 'sent', sent_at: '2026-11-10T07:02:00Z' }] });
  assert.equal(L.primaryActions(sent, { can: MANAGER, now: NOW })[0].key, 'resendLink');
  const locked = model({ invoice_locked: true, invoice_no: 'L-2026-0142', invoice: { id: 42, invoice_no: 'L-2026-0142', status: 'sent' }, reservations: [res({ starts_at: TODAY })] });
  assert.deepEqual(L.primaryActions(locked, { can: MANAGER, now: NOW }).map((a) => a.key), ['arrive', 'openBilling']);
  const paid = model({ balance: { total: 98, paid: 98, refunded: 0, unpaid: 0, net_paid: 98 }, payment_status: 'paid' });
  assert.deepEqual(L.primaryActions(paid, { can: MANAGER, now: NOW }), []);
  assert.deepEqual(L.primaryActions(today, { can: all('bookings.manage'), now: NOW }).map((a) => a.key), ['arrive'], 'ilman payments.manage ei maksutoimintoja');
  assert.equal(L.primaryActions(today, { can: MANAGER, now: NOW, limit: 1 }).length, 1, 'mobiilipalkki 1–2');
});

test('laskulukko piilottaa Ota maksu, maksulinkin, Kopioi linkki ja hyvityksen; näyttää Laskutus-linkin', () => {
  const pay = [{ id: 1, method: 'montonio', provider: 'montonio', status: 'paid', amount: 50, refunded_amount: 0 }, { id: 2, method: 'montonio', provider: 'montonio', status: 'pending', amount: 48, link_path: '/maksa/?p=x' }];
  const open = model({ payments: pay, balance: { total: 98, paid: 50, refunded: 0, unpaid: 48, net_paid: 50 } });
  const a = L.paymentBox(open, { can: MANAGER }).actions;
  assert.deepEqual(a, { sendLink: true, takePayment: true, copyLink: true, refund: true, openBilling: false });
  const locked = model({ payments: pay, balance: { total: 98, paid: 50, refunded: 0, unpaid: 48, net_paid: 50 }, invoice_locked: true, invoice_no: 'L-1' });
  assert.deepEqual(L.paymentBox(locked, { can: MANAGER }).actions, { sendLink: false, takePayment: false, copyLink: false, refund: false, openBilling: true });
  assert.equal(L.paymentBox(locked, { can: MANAGER }).headline, 'invoice_open');
  const menu = L.moreMenu(locked, { can: MANAGER }).map((x) => x.key);
  assert.ok(!menu.includes('copyLink') && !menu.includes('refund') && !menu.includes('addPurchase'));
  assert.deepEqual(L.moreMenu(open, { can: MANAGER }).map((x) => x.key), ['copyLink', 'refund', 'addPurchase', 'openCustomer']);
  assert.equal(L.moreMenu(open, { can: MANAGER }).find((x) => x.key === 'copyLink').link_path, '/maksa/?p=x', 'payments[].link_path');
  assert.equal(L.moreMenu(model({ receipts: [{ id: 3, receipt_no: 'K-1', kind: 'receipt' }] }), { can: MANAGER })[0].key, 'receipt');
  assert.equal(L.nextStep(locked, { now: NOW }).kind, 'invoice_locked');
});

test('palvelimen refundable_by_payment ratkaisee hyvityksen (lahjakortti/kumppanikoodi eivät ole rahaa)', () => {
  const m = model({ payments: [{ id: 1, method: 'gift_card', gift_card_id: 4, status: 'paid', amount: 98, refunded_amount: 0 }], balance: { total: 98, paid: 98, refunded: 0, unpaid: 0, net_paid: 98 }, refundable_by_payment: [] });
  assert.equal(L.paymentBox(m, { can: MANAGER }).actions.refund, false);
  assert.equal(L.paymentBox(m, { can: MANAGER }).giftCard, 98);
  const fallback = model({ payments: [{ id: 1, method: 'partner_voucher_offerilla', status: 'paid', amount: 60, refunded_amount: 0 }] });
  assert.equal(L.paymentBox(fallback, { can: MANAGER }).refundable.length, 0, 'vanha palvelin: kumppanikoodi ei hyvitettävä');
});

test('avoin, ylisuoritus ja maksun tila', () => {
  const over = model({ balance: { total: 60, paid: 80, refunded: 0, unpaid: 0, net_paid: 80 }, overpaid: 20 });
  assert.equal(L.paymentState(over), 'overpaid');
  assert.equal(L.paymentBox(over, { can: MANAGER }).headline, 'overpaid');
  assert.equal(L.paymentBox(over, { can: MANAGER }).amount, 20);
  assert.equal(L.nextStep(over, { now: NOW }).kind, 'overpaid');
  const local = model({ balance: { total: 60, paid: 80, refunded: 0, unpaid: 0 } });
  assert.equal(local.overpaid, 20, 'ilman booking_278:aa lasketaan saldosta');
  assert.equal(L.paymentState(model({ balance: { total: 98, paid: 40, unpaid: 58, net_paid: 40 } })), 'partial');
  assert.equal(L.paymentState(model()), 'unpaid');
});

test('merkit: varaus, maksu ja Ongelma · Koodi jo käytetty', () => {
  const m = model({ voucher_claims: [{ id: 9, status: 'problem', problem_code: 'already_used', code_masked: '…36G5', reservation_id: 1 }] });
  const b = L.orderBadges(m);
  assert.deepEqual(b.map((x) => x.key), ['status.confirmed', 'pay.unpaid', 'problem.already_used']);
  assert.equal(b[2].problem, true);
  assert.equal(L.nextStep(m, { now: NOW }).kind, 'problem');
  assert.equal(ov('order_view.problem.already_used', null, 'fi'), 'Ongelma · Koodi jo käytetty');
  assert.equal(L.orderProblems(model({ voucher_claims: [{ id: 1, status: 'redeemed' }] })).length, 0);
  assert.ok(L.orderBadges(model({ reservations: [res({ status: 'no_show' })] })).some((x) => x.key === 'status.no_show'));
});

test('muistiinpanot: varauskohtaiset (i/N), aina näkyvissä; internal_note vain luku; ensimmäinen yhteenvetoon', () => {
  const m = model({ reservations: [res({ id: 2, starts_at: '2026-12-20T14:00:00Z', notes: 'Toinen' }), res({ id: 1, starts_at: TODAY, notes: '  Toivoi pyyhkeet  ' })],
    internal_note: '2026-11-09 12:50 verkkokauppa: tilaus luotu', customer_note: 'Ensimmäinen kerta' });
  const n = L.collectNotes(m, { can: MANAGER });
  assert.deepEqual(n.reservations.map((x) => [x.reservation_id, x.index, x.count, x.notes]), [[1, 1, 2, 'Toivoi pyyhkeet'], [2, 2, 2, 'Toinen']], 'aikajärjestys');
  assert.equal(n.first.reservation_id, 1);
  assert.equal(n.system_note, '2026-11-09 12:50 verkkokauppa: tilaus luotu');
  assert.equal(n.customer_note, 'Ensimmäinen kerta');
  assert.equal(L.collectNotes(m, { can: () => false }).reservations[0].editable, false);
  assert.equal(L.shorten('a'.repeat(200), 20).length, 20);
  const s = L.summaryModel(m, { can: MANAGER, now: NOW });
  assert.equal(s.note.reservation_id, 1);
  assert.equal(s.more, 1, '+1 varausta');
});

test('orderModel yhdistää reservation_meta-kentät (tila, sääntö, saapuminen)', () => {
  const m = model({ reservation_meta: [{ id: 1, space_code: 'lovi', rule_id: 12, checkin_at: '2026-11-11T14:40:00Z' }] });
  assert.equal(m.reservations[0].space_code, 'lovi');
  assert.equal(m.reservations[0].rule_id, 12);
  assert.equal(L.reservationBadge(m.reservations[0]).key, 'res.arrived');
  assert.equal(L.orderModel(null), null);
});

test('aikajana nykydatasta: luonti, viestit, maksut, hyvitykset, kuitit, muutoshistoria (vanhin ensin)', () => {
  const m = model({
    emails: [{ kind: 'order_confirmation', status: 'sent', sent_at: '2026-11-09T10:51:00Z' }, { kind: 'payment_link', status: 'failed', created_at: '2026-11-10T07:00:00Z' }],
    payments: [{ id: 1, method: 'cash', provider: 'manual', status: 'paid', amount: 20, paid_at: '2026-11-10T08:00:00Z', refunds: [{ id: 5, amount: 5, status: 'done', done_at: '2026-11-10T09:00:00Z' }] }],
    receipts: [{ id: 1, receipt_no: 'K-9', kind: 'receipt', issued_at: '2026-11-10T08:00:01Z' }],
  });
  const tl = L.buildTimeline(m, { events: [{ at: '2026-11-10T08:30:00Z', action: 'UPDATE', table: 'reservations', changes: [{ field: 'status', from: 'pending', to: 'confirmed' }], actor_name: 'Joonas' }, { at: '2026-11-09T10:50:00Z', action: 'INSERT', table: 'orders', changes: [] }] });
  assert.deepEqual(tl.map((x) => x.key), ['created_web', 'email.order_confirmation', 'email_failed', 'paid.manual', 'receipt', 'h_status', 'refund_done']);
  assert.ok(tl.every((x, i) => i === 0 || x.at >= tl[i - 1].at));
  for (const e of tl) assert.notEqual(ov(`order_view.tl.${e.key}`, e.vars, 'fi'), `ui.admin.order_view.tl.${e.key}`, e.key);
});

test('peruutussuunnitelma: yksi / koko tilaus, hyvitys vain turvallisella polulla, osasumma piilossa, viestivaihe piilossa', () => {
  const two = model({ reservations: [res({ id: 1, starts_at: TODAY, item_total: 174 }), res({ id: 2, item_total: 60 })], balance: { total: 234, paid: 234, refunded: 0, unpaid: 0, net_paid: 234 },
    refundable_by_payment: [{ payment_id: 8, method: 'montonio', provider: 'montonio', refundable: 234 }] });
  const one = L.cancelPlan(two, { reservationId: 2, can: MANAGER, preview: { total: 60, unallocated: 0 } });
  assert.equal(one.multi, true); assert.equal(one.scope, 'one');
  assert.deepEqual(one.refund.options, ['full', 'none'], 'ei osasummaa (PR 3)');
  assert.equal(one.refund.amount, 60);
  assert.equal(one.totalAfter, 174);
  assert.deepEqual(one.steps.map((s) => [s.key, s.shown]), [['what', true], ['refund', true], ['message', false], ['confirm', true]]);
  assert.equal(L.cancelConfirmKey(one, 'full'), 'confirm.cancel_refund');
  assert.equal(L.cancelConfirmKey(one, 'none'), 'confirm.cancel_only');
  const whole = L.cancelPlan(two, { scope: 'all', can: MANAGER });
  assert.equal(whole.refund.show, true); assert.equal(whole.refund.payment_id, 8); assert.equal(whole.totalAfter, 0);
  assert.equal(L.cancelConfirmKey(whole, 'full'), 'confirm.cancel_all_refund');
  const multiPay = L.cancelPlan({ ...two, refundable_by_payment: [{ payment_id: 1, refundable: 100 }, { payment_id: 2, refundable: 134 }] }, { scope: 'all', can: MANAGER });
  assert.equal(multiPay.refund.show, false); assert.equal(multiPay.refund.reason, 'multi_payment');
  // Koko tilauksen hyvitys = maksun koko jäljellä oleva summa → ei tarjota, jos osa tilauksesta on jo käytetty
  const used = model({ reservations: [res({ id: 1, status: 'completed', item_total: 174 }), res({ id: 2, item_total: 60 })], balance: { total: 234, paid: 234, refunded: 0, unpaid: 0, net_paid: 234 },
    refundable_by_payment: [{ payment_id: 8, method: 'montonio', provider: 'montonio', refundable: 234 }] });
  const usedAll = L.cancelPlan(used, { scope: 'all', can: MANAGER });
  assert.equal(usedAll.refund.show, false); assert.equal(usedAll.refund.reason, 'partly_used');
  assert.equal(L.cancelPlan(used, { reservationId: 2, can: MANAGER, preview: { total: 60 } }).refund.show, true, 'yksittäisen varauksen osuus edelleen hyvitettävissä');
  assert.equal(L.cancelPlan(two, { scope: 'all', can: all('bookings.manage') }).refund.reason, 'no_permission');
  const locked = L.cancelPlan({ ...two, locked: true }, { reservationId: 2, can: MANAGER, preview: { total: 60 } });
  assert.equal(locked.refund.reason, 'invoice_locked');
  assert.equal(L.cancelPlan(two, { can: MANAGER }).ready, false, 'monivaraus: valitse ensin');
  const single = model();
  assert.equal(L.cancelPlan(single, { can: MANAGER, preview: { total: 0 } }).refund.reason, 'nothing');
  assert.equal(L.cancelPlan(single, { can: MANAGER }).scope, 'one');
});

test('näppäimistö ja leveys', () => {
  assert.equal(L.stepIndex(-1, 1, 3), 0); assert.equal(L.stepIndex(2, 1, 3), 2); assert.equal(L.stepIndex(1, -1, 3), 0); assert.equal(L.stepIndex(0, 1, 0), -1);
  assert.equal(L.isWide(1440), true); assert.equal(L.isWide(390), false); assert.equal(L.isWide(1199), false);
});

test('asiakasnäkymä: tulevat / menneet, tunnusluvut palvelimelta, ei yhdistä/poista-osiota', () => {
  const c = {
    id: 5, name: 'Maija Esimerkki', customer_kind: 'private', email: 'm@example.com', marketing_consent: true, marketing_consent_at: '2026-04-03T10:00:00Z', marketing_consent_source: 'verkkovaraus',
    orders: [
      { order_id: 1, order_no: 7001, status: 'confirmed', payment_status: 'unpaid', total: 98, created_at: '2026-11-09T10:00:00Z', reservations: [{ id: 1, starts_at: FUTURE, status: 'confirmed', persons: 2, product_name: 'Saunahoito' }] },
      { order_id: 2, order_no: 5102, status: 'completed', payment_status: 'paid', total: 30, created_at: '2026-03-01T10:00:00Z', reservations: [{ id: 2, starts_at: '2026-03-12T14:00:00Z', status: 'no_show', persons: 1, product_name: 'Yleinen vuoro' }] },
      { order_id: 3, order_no: 6620, status: 'completed', payment_status: 'paid', total: 116, created_at: '2026-09-01T10:00:00Z', reservations: [{ id: 3, starts_at: '2026-09-12T13:30:00Z', status: 'completed', persons: 2, product_name: 'Rituaali' }] },
    ],
    stats: { visits: 4, last_visit: '2026-09-12T13:30:00Z' }, open_balance: 98, open_orders: 1,
  };
  const m = L.customerModel(c, { now: NOW });
  assert.deepEqual(m.upcoming.map((o) => o.order_no), [7001]);
  assert.deepEqual(m.past.map((o) => o.order_no), [6620, 5102], 'uusin ensin');
  assert.equal(m.stats.visits, 4, 'palvelimen luku voittaa');
  assert.equal(m.stats.no_show, 1, 'paikallinen varalla');
  assert.equal(m.open_balance, 98);
  assert.deepEqual(L.customerOrderBadges(m.past[1]).map((b) => b.key), ['status.no_show', 'pay.paid']);
  assert.deepEqual(L.customerOrderBadges(m.upcoming[0]).map((b) => b.key), ['status.confirmed', 'pay.unpaid_short']);
  const src = read('booking/admin/views/customer-view.js');
  assert.doesNotMatch(src, /admin_merge|anonymi[sz]e_customer|admin_delete_customer/, 'ei yhdistä/poista-osiota PR 1:ssä');
  const card = read('booking/admin/views/order-view.js');
  assert.doesNotMatch(card, /admin_get_customer/, 'asiakashistoria vain asiakasnäkymässä');
});

test('tekstit: FI = EN, pending-import-137 täsmää, paikkamerkit, ei HTML:ää, ei päällekkäisyyttä muiden tuontien kanssa', () => {
  assert.deepEqual(Object.keys(ORDER_VIEW_TEXTS.fi).sort(), Object.keys(ORDER_VIEW_TEXTS.en).sort());
  const rows = JSON.parse(read('content/site-texts.pending-import-137.json'));
  assert.equal(rows.length, Object.keys(ORDER_VIEW_TEXTS.fi).length * 2);
  const seen = new Set();
  for (const r of rows) {
    assert.ok(PREFIXES.some((p) => r.key.startsWith(p)), r.key);
    assert.equal(r.text, ORDER_VIEW_TEXTS[r.lang][r.key], r.key);
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain');
    assert.ok(r.text.length <= r.max_len, r.key);
    assert.deepEqual(r.placeholders, [...r.text.matchAll(/\{\{var:[a-z0-9_]+\}\}/g)].map((x) => x[0]), r.key);
    assert.doesNotMatch(r.text, /<|>|https?:/, r.key);
    assert.equal(seen.has(`${r.key}|${r.lang}`), false); seen.add(`${r.key}|${r.lang}`);
  }
  for (const f of readdirSync(join(root, 'content')).filter((n) => /^site-texts\.(pending-import|imported|fallback).*\.json$/.test(n) && n !== 'site-texts.pending-import-137.json')) {
    const j = JSON.parse(read(`content/${f}`)); const other = Array.isArray(j) ? j : j.texts || [];
    for (const r of other) assert.ok(!PREFIXES.some((p) => String(r.key).startsWith(p)), `${r.key} myös ${f}`);
  }
  primeOvTexts([{ key: 'ui.admin.order_view.receipt', lang: 'fi', text: 'Kuitti (kanta)' }, { key: 'ui.admin.order_view.pay.unpaid', lang: 'fi', text: 'X {{var:nope}}' }]);
  assert.equal(ov('order_view.receipt', null, 'fi'), 'Kuitti (kanta)');
  assert.equal(ov('order_view.pay.unpaid', { amount: '9,00 €' }, 'fi'), 'Maksamatta 9,00 €', 'täyttymätön paikkamerkki → oletus');
  clearOvTextCache();
  assert.equal(ov('order_view.receipt', null, 'en'), 'Receipt');
});

test('näkymät: ei kovakoodattuja värejä, ei emojeja; poistolle paikka; logiikka palvelimella (ei suoria taulukirjoituksia)', () => {
  const files = ['views/order-view.js', 'views/order-summary.js', 'views/order-cancel-flow.js', 'views/customer-view.js', 'order-view-logic.js', 'order-view-texts.js'];
  for (const f of files) {
    const s = read(`booking/admin/${f}`);
    assert.doesNotMatch(s, /#[0-9a-f]{6}\b|style:/i, f);
    assert.doesNotMatch(s, /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u, f);
    assert.doesNotMatch(s, /dbSelect\('(orders|reservations|payments)'|\.from\(|insert\(|upsert\(/, f);
  }
  const view = read('booking/admin/views/order-view.js');
  assert.match(view, /'data-slot': 'order-delete'/, 'PR #334:n poistolle jätetty paikka');
  assert.doesNotMatch(view, /from '\.\/order-card-delete/, 'poisto ei kuulu PR 1:een');
  for (const rpcName of ['admin_set_reservation_status', 'admin_set_reservation_option', 'admin_set_reservation_addons', 'admin_move_reservation_space', 'admin_set_reservation_note', 'admin_order_history', 'admin_order_lookup']) assert.match(view, new RegExp(`'${rpcName}'`), rpcName);
  assert.match(read('booking/admin/views/order-card.js'), /export function changeDialog/);
  const flow = read('booking/admin/views/order-cancel-flow.js');
  assert.match(flow, /admin_reservation_refund_preview/); assert.match(flow, /admin_cancel_reservation/); assert.match(flow, /refundOrder\(/);
  assert.doesNotMatch(flow, /type: 'number'/, 'osasumman kenttä piilossa PR 1:ssä');
  const css = read('booking/admin/admin.css'); const v3 = css.slice(css.indexOf('/* ---- Tilausnäkymä v3 (PR 1)'));
  assert.ok(v3.length > 100);
  assert.doesNotMatch(v3, /#[0-9a-f]{3,8}\b|rgba?\(|hsl\(|blue|width:\s*\d{3,}px|white-space:\s*nowrap/i);
  assert.match(read('booking/admin/views/orders.js'), /renderOrderView/);
  assert.match(read('booking/admin/views/customers.js'), /renderCustomerView/);
});

test('migraatio booking_278: vain lukufunktiot, SECURITY DEFINER, search_path, oikeudet; rollback palauttaa', () => {
  const dir = 'booking/supabase/migrations';
  const names = readdirSync(join(root, dir)).filter((n) => /booking_278_/.test(n));
  assert.deepEqual(names, ['20261111162544_booking_278_admin_order_customer_read.sql']);
  const sql = read(`${dir}/${names[0]}`);
  for (const f of ['admin_get_order', 'admin_get_customer', 'admin_order_history', 'admin_order_lookup']) {
    assert.match(sql, new RegExp(`create or replace function booking\\.${f}\\(`, 'i'), f);
    assert.match(sql, new RegExp(`grant execute on function booking\\.${f}\\([^)]*\\) to authenticated, service_role`, 'i'), f);
  }
  assert.equal((sql.match(/^\s*STABLE SECURITY DEFINER$/gm) || []).length, 4);
  assert.equal((sql.match(/set search_path to ''|set search_path = ''/gi) || []).length, 4);
  assert.doesNotMatch(sql.replace(/--.*$/gm, ''), /\b(insert\s+into|update\s+booking\.\w+\s+set|delete\s+from|truncate|alter\s+table|drop\s+table)\b/i, 'ei datamuutoksia');
  assert.doesNotMatch(sql, /\bpublic\./);
  assert.ok(existsSync(join(root, 'booking/supabase/rollbacks/20261111162544_booking_278_ROLLBACK.sql')));
  const rb = read('booking/supabase/rollbacks/20261111162544_booking_278_ROLLBACK.sql');
  assert.match(rb, /drop function if exists booking\.admin_order_history\(bigint, integer\)/i);
  assert.match(rb, /drop function if exists booking\.admin_order_lookup\(bigint\)/i);
  assert.ok(existsSync(join(root, 'booking/supabase/tests/t278_admin_order_customer_read.sql')));
});

test('peruutus: koko tilauksen ei-atominen keskeytys jää näkyviin dialogiin; hyvitysvalinta vain hyvitettävistä maksuista; poistopaikka ilman poistomoduulia', () => {
  const flow = read('booking/admin/views/order-cancel-flow.js');
  assert.match(flow, /order_cancel\.partial_fail[\s\S]{0,200}err\.hidden = false[\s\S]{0,120}submit\.hidden = true/, 'keskeytys näkyy dialogissa ja uusi yritys estetään');
  const view = read('booking/admin/views/order-view.js');
  assert.match(view, /paymentBox\(m, \{ can: ctx\.can \}\)\.refundable/, 'Hyvitä maksu -dialogi saa vain refundable_by_payment-maksut');
  assert.match(view, /'data-slot': 'order-delete'/);
  assert.doesNotMatch(view, /import[^;]*order-card-delete|['"]admin_order_delete/, 'PR 1 ei riipu poistomoduulista eikä poisto-RPC:stä');
  assert.doesNotMatch(view, /Verkkokauppa|Paikan päällä/, 'kanavan nimet talous-texts.js:stä');
});

test('placeOverflowMenu: otsikon valikko pysyy ruudulla mobiilissa, työpöydän oikeasuuntaus ennallaan', () => {
  const menu = { width: 220, height: 220 };
  const desk = L.placeOverflowMenu({ left: 1212, right: 1252, top: 116, bottom: 154 }, menu, { width: 1280, height: 900 }, { prefer: 'end' });
  assert.equal(desk.left, 1032, 'työpöytä: oikeareuna nappiin (1252-220)');
  assert.equal(desk.top, 158);
  assert.equal(desk.maxWidth, 1264);

  const phone = L.placeOverflowMenu({ left: 58, right: 98, top: 183.5, bottom: 221 }, menu, { width: 465, height: 1000 }, { prefer: 'end' });
  assert.equal(phone.left, 58, 'mobiili: ei tilaa vasemmalla → vasen reuna nappiin');
  assert.equal(phone.top, 225);
  assert.ok(phone.left + phone.width <= 465 - 8, 'oikea reuna ruudun sisällä');
  assert.ok(phone.left >= 8, 'vasen reuna ruudun sisällä');
  assert.equal(phone.maxWidth, 449);

  const tight = L.placeOverflowMenu({ left: 10, right: 50, top: 80, bottom: 120 }, { width: 400, height: 200 }, { width: 360, height: 640 }, { prefer: 'end' });
  assert.equal(tight.width, 344, 'max-width = 100vw - 16');
  assert.equal(tight.left, 8, 'rajataan 8 px marginaaliin');
  assert.equal(tight.left + tight.width, 352);

  const up = L.placeOverflowMenu({ left: 58, right: 98, top: 700, bottom: 740 }, menu, { width: 390, height: 844 }, { prefer: 'end' });
  assert.equal(up.top, 700 - 4 - 220, 'ei tilaa alhaalla → avautuu ylöspäin');

  const row = L.placeOverflowMenu({ left: 70, right: 110, top: 400, bottom: 438 }, menu, { width: 465, height: 1000 }, { prefer: 'start' });
  assert.equal(row.left, 70, 'rivivalikko: vasen reuna nappiin kun mahtuu oikealle');
});

test('overflowMenu kiinnittää listan ruutuun ja css rajaa leveyden sekä pinon sivupalkin yläpuolelle', () => {
  const view = read('booking/admin/views/order-view.js');
  assert.match(view, /placeOverflowMenu\(/);
  assert.match(view, /list\.style\.position = 'fixed'/);
  assert.match(view, /prefer: 'start'/);
  const css = read('booking/admin/admin.css');
  const v3 = css.slice(css.indexOf('/* ---- Tilausnäkymä v3 (PR 1)'));
  assert.match(v3, /max-width:\s*calc\(100vw - 16px\)/);
  assert.match(v3, /\.ov-menu-list\{[^}]*z-index:60/);
});
