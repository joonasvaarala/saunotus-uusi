import { test } from 'node:test';
import assert from 'node:assert/strict';
import { reservationAddonLocks, addonMinimum, addonReductionError } from '../admin/addon-lock-logic.js';
const item = (id, quantity, parent_item_id = 101) => ({ id, kind: 'addon', parent_item_id, quantity });
const a = (addon_id, quantity) => ({ addon_id, quantity });
const p = (status, provider, ids = [], refunded = 0) => ({ status, provider, lines: ids.map(order_item_id => ({ order_item_id, amount_gross: 10, refunded_gross: refunded })) });
const o = (items, addons, payments) => ({ items, reservations: [{ id: 1, item_id: 101, addons }], payments });

test('maksettu rivi, jolla on nettokatetta, pysyy lukittuna (myös osittain hyvitetty)', () => {
  for (const [status, refunded] of [['paid', 0], ['partially_refunded', 0], ['partially_refunded', 4], ['refunded', 9.99]]) {
    const state = reservationAddonLocks(o([item(8, 2)], [a(44, 2)], [p(status, 'manual', [8], refunded)]), 1);
    assert.equal(state.complete, true);
    assert.equal(addonMinimum(state, 44), 2);
    assert.equal(addonReductionError(state, []), 'addon_paid');
    assert.equal(addonReductionError(state, [{ id: 44, quantity: 2 }]), null);
    assert.equal(addonReductionError(state, [{ id: 44, quantity: 3 }]), null);
  }
});
test('avoin verkkomaksulinkki lukitsee, pending manual ei', () => {
  for (const provider of ['visma_pay', 'mobilepay']) {
    const s = reservationAddonLocks(o([item(2, 1)], [a(55, 1)], [p('pending', provider, [2])]), 1);
    assert.equal(addonReductionError(s, []), 'addon_link_open');
  }
  assert.equal(addonMinimum(reservationAddonLocks(o([item(2, 1)], [a(55, 1)], [p('pending', 'manual', [2])]), 1), 55), 0);
});
test('peruttu tai epäonnistunut maksu ei lukitse', () => {
  for (const status of ['cancelled', 'failed', 'expired']) {
    assert.equal(addonMinimum(reservationAddonLocks(o([item(2, 1)], [a(55, 1)], [p(status, 'visma_pay', [2])]), 1), 55), 0);
  }
});
test('rivit kohdistuvat addon_id:hen id-järjestyksessä, myös samannimiset ja hinnaltaan samat', () => {
  const s = reservationAddonLocks(o([item(7, 1), item(8, 2), item(9, 1)], [a(70, 1), a(71, 2), a(70, 1)], [p('paid', 'manual', [7, 9]), p('pending', 'visma_pay', [8])]), 1);
  assert.equal(addonMinimum(s, 70), 2);
  assert.equal(addonMinimum(s, 71), 2);
  assert.equal(addonReductionError(s, [{ id: 70, quantity: 2 }]), 'addon_link_open');
});
test('puuttuvat/rikkinäiset kohdistustiedot eivät koskaan avaa vähennystä', () => {
  for (const obj of [o([item(7, 1)], [], []), o([item(7, 1)], [a(80, 2)], []), { items: [], reservations: [] }]) {
    const s = reservationAddonLocks(obj, 1);
    assert.equal(s.complete, false);
    assert.equal(addonReductionError(s, []), 'addon_lock_unknown');
  }
});
test('XSS-tekstiä ei lueta tai palauteta HTML:nä', () => {
  const payload = '<img src=x onerror=alert(1)>';
  const s = reservationAddonLocks({ ...o([item(7, 1)], [a(80, 1)], [p('paid', 'manual', [7])]), customer_name: payload }, 1);
  assert.equal(JSON.stringify([...s.locks]).includes(payload), false);
});
test('kokonaan hyvitetty rivi ei lukitse (sama sääntö kuin palvelimella)', () => {
  for (const status of ['paid', 'partially_refunded', 'refunded']) {
    const s = reservationAddonLocks(o([item(8, 2)], [a(44, 2)], [p(status, 'manual', [8], 10)]), 1);
    assert.equal(s.complete, true);
    assert.equal(addonMinimum(s, 44), 0);
    assert.equal(addonReductionError(s, []), null);
  }
  // hyvitetty maksu + uusi maksu samalle riville -> lukittu
  const s2 = reservationAddonLocks(o([item(8, 2)], [a(44, 2)], [p('refunded', 'manual', [8], 10), p('paid', 'visma_pay', [8])]), 1);
  assert.equal(addonReductionError(s2, []), 'addon_paid');
});
test('puuttuva tai virheellinen maksurivin summa lukitsee varmuuden vuoksi', () => {
  const bad = { status: 'paid', provider: 'manual', lines: [{ order_item_id: 8, amount_gross: 'x', refunded_gross: 0 }] };
  assert.equal(addonReductionError(reservationAddonLocks(o([item(8, 1)], [a(44, 1)], [bad]), 1), []), 'addon_paid');
  const noRef = { status: 'paid', provider: 'manual', lines: [{ order_item_id: 8, amount_gross: 10 }] };
  assert.equal(addonMinimum(reservationAddonLocks(o([item(8, 1)], [a(44, 1)], [noRef]), 1), 44), 1);
});
