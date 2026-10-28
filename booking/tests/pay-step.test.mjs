import test from 'node:test';
import assert from 'node:assert/strict';
import { payStepKind, giftPayOffered, customerBadges, duePresentation, freshPayKey, markFreshPay, takeFreshPay } from '../shop/src/pay-step.js';

const texts = {
  cancel: 'Peruutus', cancelled: 'Peruttu', expired: 'Vanhentunut', invoiced: 'Laskutettu',
  refunded: 'Hyvitetty', partialRefund: 'Osittain hyvitetty', paid: 'Maksettu', failed: 'Maksu ei onnistunut',
  partial: 'Osittain maksettu', open: 'Maksu on vielä kesken', confirmed: 'Vahvistettu',
  processing: 'Maksua käsitellään', preliminary: 'Alustava varaus',
};

test('osto ohjaa maksuun, myöhempi käynti tilaussivulle', () => {
  assert.equal(payStepKind({ fresh: true, payable: true, onlineCount: 1 }), 'redirect');
  assert.equal(payStepKind({ fresh: true, payable: true, onlineCount: 5 }), 'finish');
  assert.equal(payStepKind({ fresh: true, payable: true, onlineCount: 5, gift: true }), 'finish');
  assert.equal(payStepKind({ fresh: true, payable: true, onlineCount: 1, gift: true }), 'finish');
  assert.equal(payStepKind({ fresh: true, payable: true, link: true }), 'redirect-link');
  assert.equal(payStepKind({ fresh: true, payable: true, onlineCount: 0, gift: true, link: true }), 'finish');
  assert.equal(payStepKind({ fresh: false, payable: true, onlineCount: 5 }), 'status');
  assert.equal(payStepKind({ fresh: true, returning: true, payable: true, onlineCount: 1 }), 'status');
  assert.equal(payStepKind({ fresh: true, payable: false, onlineCount: 1 }), 'status');
});

test('lahjakortilla ei makseta lahjakorttitilausta', () => {
  assert.equal(giftPayOffered({ redeem: true, unpaid: 10, hasCards: true, status: 'pending' }), false);
  assert.equal(giftPayOffered({ redeem: true, unpaid: 10, status: 'pending' }), true);
  assert.equal(giftPayOffered({ redeem: true, unpaid: 10, status: 'pending', locked: true }), false);
  assert.equal(giftPayOffered({ redeem: false, unpaid: 10, status: 'confirmed' }), false);
});

test('avoin maksu on yksi merkki, osasuoritus pitää maksamaton-sanan', () => {
  assert.deepEqual(customerBadges({ status: 'pending', paymentStatus: 'pending', unpaid: 328, online: true, texts }), [{ kind: 'pay-pending', text: texts.open }]);
  assert.deepEqual(customerBadges({ status: 'pending', paymentStatus: 'unpaid', unpaid: 40, online: true, texts }).map((b) => b.text), [texts.open]);
  assert.deepEqual(customerBadges({ status: 'confirmed', paymentStatus: 'partially_paid', paid: 20, unpaid: 8, online: true, texts }).map((b) => b.text), [texts.partial]);
  assert.deepEqual(customerBadges({ status: 'confirmed', paymentStatus: 'paid', paid: 40, texts }).map((b) => b.text), [texts.paid]);
  assert.deepEqual(customerBadges({ status: 'confirmed', paymentStatus: 'unpaid', unpaid: 40, online: false, texts }).map((b) => b.text), [texts.confirmed]);
  assert.equal(customerBadges({ status: 'pending', paymentStatus: 'pending', unpaid: 10, hold: 'processing', texts })[0].text, texts.processing);
  const full = duePresentation({ paid: 0, unpaid: 328 });
  assert.equal(full.partial, false);
  assert.equal(full.cta, 'continue');
  assert.equal(full.alarm, false);
  const part = duePresentation({ paid: 50, unpaid: 10 });
  assert.equal(part.partial, true);
  assert.equal(part.cta, 'rest');
  assert.equal(part.alarm, true);
});

test('oston merkki luetaan kerran', () => {
  const bag = new Map();
  const storage = { getItem: (k) => bag.get(k) ?? null, setItem: (k, v) => bag.set(k, v), removeItem: (k) => bag.delete(k) };
  const token = 'AbC';
  markFreshPay(token, storage);
  assert.equal(bag.get(freshPayKey(token)), '1');
  assert.equal(takeFreshPay(token, storage), true);
  assert.equal(takeFreshPay(token, storage), false);
});
