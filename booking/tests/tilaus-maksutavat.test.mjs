// Tilausnäkymän maksukortti: maksutavat omilla summillaan (Joonas 14.11.2026). Summa = palvelimen _order_balance.paid
// (paid, partially_refunded, refunded bruttona); peruttu/kesken ei kuulu erittelyyn. Tekstit tuonnissa 170.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { paymentMethodSplit, paymentCode } from '../admin/order-view-logic.js';
import { ORDER_VIEW_TEXTS } from '../admin/order-view-texts.js';
const read = (p) => readFileSync(new URL(`../../${p}`, import.meta.url), 'utf8');

const P = (id, method, status, amount, extra = {}) => ({ id, method, provider: ['montonio', 'visma_pay'].includes(method) ? method : 'manual', status, amount, refunded_amount: 0, note: null, ...extra });

test('sekamaksu: lahjakortti koodeineen + verkkomaksu omilla summillaan, peruttu ja kesken pois', () => {
  const pays = [
    P(1, 'gift_card', 'paid', 20, { note: 'Lahjakortti …K7Q2 | Verkkokauppa' }),
    P(2, 'montonio', 'cancelled', 49),
    P(3, 'montonio', 'paid', 49),
    P(4, 'montonio', 'pending', 10),
    P(5, 'pay_later', 'pending', 5),
    P(6, 'invoice', 'pending', 5),
  ];
  const s = paymentMethodSplit(pays);
  assert.deepEqual(s.map((x) => [x.method, x.code, x.amount, x.refunded]), [['gift_card', '…K7Q2', 20, 0], ['montonio', null, 49, 0]]);
  // sama rajaus kuin _order_balance.paid
  const serverPaid = pays.filter((p) => ['paid', 'partially_refunded', 'refunded'].includes(p.status)).reduce((a, p) => a + p.amount, 0);
  assert.equal(s.reduce((a, x) => a + x.amount, 0), serverPaid);
});

test('kumppanikoodi, käteinen, korttipääte ja hyvitetty osuus', () => {
  const s = paymentMethodSplit([
    P(1, 'partner_voucher_elamyslahjat', 'paid', 60, { note: 'Lahjakortti – Elämyslahjat …9F3K | pyyntö #188' }),
    P(2, 'cash', 'paid', 5),
    P(3, 'card_terminal', 'partially_refunded', 30, { refunded_amount: 10 }),
    P(4, 'montonio', 'refunded', 15, { refunded_amount: 15 }),
    P(5, 'cash', 'paid', 2.5),
  ]);
  assert.deepEqual(s.map((x) => [x.method, x.code, x.amount, x.refunded]),
    [['partner_voucher_elamyslahjat', '…9F3K', 60, 0], ['cash', null, 7.5, 0], ['card_terminal', null, 30, 10], ['montonio', null, 15, 15]]);
});

test('paymentCode: vain lahjakortille ja kumppanille; puuttuva koodi → null', () => {
  assert.equal(paymentCode(P(1, 'gift_card', 'paid', 1, { note: 'Lahjakortti …AB12' })), '…AB12');
  assert.equal(paymentCode(P(1, 'gift_card', 'paid', 1, { note: null })), null);
  assert.equal(paymentCode(P(1, 'montonio', 'paid', 1, { note: 'x …AB12' })), null);
  assert.deepEqual(paymentMethodSplit([]), []);
  assert.deepEqual(paymentMethodSplit(null), []);
});

test('näkymä: rivi Maksettu-rivin jälkeen, vanhat rivit säilyvät, tekstit FI+EN tuonnissa 170', () => {
  const v = read('booking/admin/views/order-view.js');
  assert.match(v, /'order_view\.pay_paid'[^\n]*\n\s*box\.methods\.length \? \[box\.methods\.length > 1 \? 'order_view\.pay_methods' : 'order_view\.pay_method'/);
  for (const k of ['pay_total', 'pay_paid', 'pay_refunded', 'pay_gift', 'pay_partner', 'pay_link', 'pay_invoice', 'pay_due']) assert.match(v, new RegExp(`'order_view\\.${k}'`));
  assert.match(v, /methodLabel\(x\.method\)/);
  const rows = JSON.parse(read('content/site-texts.pending-import-170.json'));
  assert.equal(rows.length, 6);
  for (const r of rows) assert.equal(ORDER_VIEW_TEXTS[r.lang][r.key], r.text);
  assert.match(read('booking/admin/options-mock.js'), /MOCK_MIXED_PAY_ORDER_NO = 7001/);
});
