// Hallinnan tilauksen summalaatikko (Joonas t462u): amountSummary-tilat, tekstit (pending-import-140) ja näkymien kytkentä.
// Ajo: node --test booking/tests/summalaatikko.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as L from '../admin/order-view-logic.js';
import { ORDER_VIEW_TEXTS } from '../admin/order-view-texts.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const res = (o = {}) => ({ id: 1, status: 'confirmed', product_name: 'Saunotus', starts_at: '2026-11-21T15:00:00Z', persons: 2, addons: [], option_choices: [], ...o });
const pay = (o = {}) => ({ id: 1, method: 'montonio', provider: 'montonio', status: 'paid', amount: 270, refunded_amount: 0, ...o });
const bal = (total, paid, refunded = 0, cancelled = false) => ({ total, paid, refunded, pending_link: 0, unpaid: cancelled ? 0 : Math.max(0, total - (paid - refunded)), net_paid: paid - refunded });
const model = (o = {}) => L.orderModel({ order_id: 1, order_no: 15189, status: 'confirmed', is_native: true, reservations: [res()], payments: [], ...o });
const S = (o) => L.amountSummary(model(o));
const keys = (d) => d.lines.map((x) => `${x.key}:${x.amount}`);

test('maksettu kokonaan: iso luku = maksettu summa, ei 0 € (Joonaksen kuva #15189)', () => {
  const d = S({ balance: bal(270, 270), payments: [pay()] });
  assert.equal(d.state, 'paid'); assert.equal(d.tone, 'ok'); assert.equal(d.label, 'amt.paid');
  assert.equal(d.amount, 270, 'iso luku on maksettu summa');
  assert.deepEqual(keys(d), ['total:270', 'unpaid_line:0'], 'pienellä: Yhteensä · Maksamatta 0,00 €');
});

test('maksamatta ja osittain maksettu: iso luku = maksamatta oleva osa', () => {
  const u = S({ balance: bal(98, 0) });
  assert.equal(u.state, 'due'); assert.equal(u.tone, 'due'); assert.equal(u.amount, 98); assert.deepEqual(keys(u), ['total:98', 'paid_line:0']);
  const p = S({ balance: bal(270, 100), payments: [pay({ amount: 100, method: 'card_terminal', provider: 'manual' })] });
  assert.equal(p.state, 'due'); assert.equal(p.amount, 170); assert.deepEqual(keys(p), ['total:270', 'paid_line:100']);
  const link = S({ balance: { ...bal(98, 0), pending_link: 98 } });
  assert.deepEqual(keys(link), ['total:98', 'paid_line:0', 'link_line:98'], 'avoin maksulinkki näkyy pienellä');
});

test('laskulla avoinna (laskulukko): oma otsikko, ei maksulinkkiriviä', () => {
  const d = S({ balance: { ...bal(246, 0), pending_link: 10 }, invoice_locked: true, invoice_no: 'L-1' });
  assert.equal(d.state, 'invoice'); assert.equal(d.tone, 'info'); assert.equal(d.amount, 246);
  assert.ok(!keys(d).some((k) => k.startsWith('link_line')));
});

test('peruttu ja hyvitetty kokonaan: iso luku = hyvitys, rivillä peruttu', () => {
  const d = S({ status: 'cancelled', balance: bal(270, 270, 270, true), overpaid: 0, payments: [pay({ status: 'refunded', refunded_amount: 270 })], reservations: [res({ status: 'cancelled' })] });
  assert.equal(d.state, 'refunded'); assert.equal(d.amount, 270); assert.equal(d.cancelled, true);
  assert.deepEqual(keys(d), ['cancelled_total:270', 'paid_line:270']);
});

test('peruttu mutta hyvittämättä / ylisuoritus: iso "Hyvitettävää"', () => {
  const c = S({ status: 'cancelled', balance: bal(120, 120, 0, true), overpaid: 120, payments: [pay({ amount: 120 })] });
  assert.equal(c.state, 'to_refund'); assert.equal(c.tone, 'warn'); assert.equal(c.amount, 120);
  assert.deepEqual(keys(c), ['cancelled_total:120', 'paid_line:120']);
  const o = S({ balance: bal(60, 80), overpaid: 20 });
  assert.equal(o.state, 'to_refund'); assert.equal(o.amount, 20); assert.deepEqual(keys(o), ['total:60', 'paid_line:80']);
  const fallback = S({ balance: { total: 60, paid: 80, refunded: 0, unpaid: 0 } });
  assert.equal(fallback.state, 'to_refund', 'vanha palvelin: ylisuoritus lasketaan saldosta'); assert.equal(fallback.amount, 20);
});

test('osittain hyvitetty mutta muuten maksettu: iso luku = nettomaksu, hyvitys pienellä', () => {
  const d = S({ balance: { total: 80, paid: 100, refunded: 20, unpaid: 0, net_paid: 80 }, payments: [pay({ amount: 100, refunded_amount: 20, status: 'partially_refunded' })] });
  assert.equal(d.state, 'paid'); assert.equal(d.amount, 80); assert.deepEqual(keys(d), ['total:80', 'unpaid_line:0', 'refunded_line:20']);
});

test('lahjakortilla / kumppanikoodilla maksettu: maksettu + lähde pienellä', () => {
  const g = S({ balance: bal(60, 60), payments: [pay({ amount: 60, method: 'gift_card', provider: 'manual', gift_card_id: 7 })] });
  assert.equal(g.state, 'paid'); assert.deepEqual(keys(g), ['total:60', 'unpaid_line:0', 'gift_line:60']);
  const v = S({ balance: bal(116, 116), payments: [pay({ amount: 116, method: 'partner_voucher_offerilla', provider: 'manual' })] });
  assert.deepEqual(keys(v), ['total:116', 'unpaid_line:0', 'partner_line:116']);
});

test('0 €:n tilaus ja peruttu maksamaton: "Ei maksettavaa" ilman isoa nollaa', () => {
  const z = S({ balance: bal(0, 0) });
  assert.equal(z.state, 'none'); assert.equal(z.amount, null); assert.deepEqual(z.lines, []);
  const c = S({ status: 'cancelled', balance: bal(98, 0, 0, true) });
  assert.equal(c.state, 'none'); assert.equal(c.amount, null); assert.deepEqual(keys(c), ['cancelled_total:98']);
  assert.equal(L.amountSummary(null), null);
});

test('paymentBox.display = amountSummary; saldo- ja toimintologiikka ennallaan', () => {
  const m = model({ balance: bal(270, 270), payments: [pay()] });
  const box = L.paymentBox(m, { can: () => true });
  assert.deepEqual(box.display, L.amountSummary(m));
  assert.equal(box.headline, 'settled'); assert.equal(box.amount, 0, 'vanhat kentät ennallaan (vain näyttö muuttui)');
});

test('tekstit: jokaiselle tilalle ja riville FI+EN, import 140 = sanakirja', () => {
  const states = ['paid', 'due', 'invoice', 'to_refund', 'refunded', 'none'];
  const lines = ['total', 'cancelled_total', 'paid_line', 'unpaid_line', 'refunded_line', 'gift_line', 'partner_line', 'link_line'];
  const rows = JSON.parse(read('content/site-texts.pending-import-140.json'));
  assert.equal(rows.length, (states.length + lines.length) * 2);
  for (const lang of ['fi', 'en']) {
    for (const k of [...states, ...lines]) {
      const key = `ui.admin.order_view.amt.${k}`; const text = ORDER_VIEW_TEXTS[lang][key];
      assert.ok(text, `${key} ${lang}`);
      assert.equal(rows.find((r) => r.key === key && r.lang === lang)?.text, text, `${key} ${lang}`);
      if (lines.includes(k)) assert.match(text, /\{\{var:amount\}\}/, key);
    }
  }
  assert.equal(ORDER_VIEW_TEXTS.fi['ui.admin.order_view.amt.paid'], 'Maksettu');
  assert.equal(ORDER_VIEW_TEXTS.fi['ui.admin.order_view.amt.due'], 'Maksamatta');
});

test('näkymät käyttävät samaa amountBoxia (yhteenveto + koko tilaus), vanha "Maksettu kokonaan" -otsikko pois käytöstä', () => {
  const view = read('booking/admin/views/order-view.js'), sum = read('booking/admin/views/order-summary.js');
  assert.match(view, /export function amountBox\(/);
  assert.match(view, /amountBox\(box\.display, \{ meta: false/);
  assert.match(sum, /amountBox\(box\.display, \{ testid: 'ov-sum-pay', amountTestid: 'ov-sum-open' \}\)/);
  for (const s of [view, sum]) assert.doesNotMatch(s, /order_view\.pay_settled|box\.headline/);
  const css = read('booking/admin/admin.css');
  for (const t of ['ok', 'due', 'warn', 'info', 'muted']) assert.match(css, new RegExp(`\\.ov-paybox\\.tone-${t}\\{`), t);
  assert.doesNotMatch(css, /\.ov-big|\.ov-sum-pay/);
});
