import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { finnishMobileMsisdn } from '../admin/phone-fi.js';
import { cartAdd, cartSetQty, cartTotal, checkoutItems, looksLikeAlcohol, tenderAvailable, tendersFor } from '../admin/pos-logic.js';
import { POS_TEXTS } from '../admin/pos-texts.js';
import { qrMatrix } from '../admin/qrsvg.js';
import { deviceFromSearch, drinksCartAdd, looksLikeAlcohol as drinksAlcohol } from '../drinks/drinks-logic.js';
import { DRINKS_TEXTS } from '../drinks/drinks-texts.js';
import { createAdminMock } from '../admin/options-mock.js';

const pending = JSON.parse(readFileSync(new URL('../../content/site-texts.pending-import-12.json', import.meta.url), 'utf8'));

test('suomalainen matkapuhelin: MSISDN ilman plus-merkkiä, kiinteä ei kelpaa', () => {
  assert.equal(finnishMobileMsisdn('040 123 4567'), '358401234567');
  assert.equal(finnishMobileMsisdn('+358501234567'), '358501234567');
  assert.equal(finnishMobileMsisdn('00358-40-1234567'), '358401234567');
  assert.equal(finnishMobileMsisdn('0102992866'), null);
  assert.equal(finnishMobileMsisdn(''), null);
  assert.equal(finnishMobileMsisdn('12345'), null);
});

test('QR-matriisi syntyy paikallisesti ja on neliö', () => {
  const rows = qrMatrix('https://uusi.saunotus.com/juomat/?laite=pukuhuone-abcdef1234');
  assert.ok(rows.length >= 21);
  assert.ok(rows.every((r) => r.length === rows.length));
  assert.ok(rows.some((r) => r.includes('1')));
});

test('ostoskori lisää, vähentää ja laskee katalogin hinnalla', () => {
  const vichy = { product_id: 101, name: 'Vichy', price: 3, vat_rate: 13.5 };
  let cart = cartAdd([], vichy);
  cart = cartAdd(cart, vichy);
  assert.equal(cartTotal(cart), 6);
  assert.deepEqual(checkoutItems(cart), [{ product_id: 101, quantity: 2 }]);
  assert.equal('price' in checkoutItems(cart)[0], false);
  cart = cartSetQty(cart, 101, 1);
  assert.equal(cartTotal(cart), 3);
  cart = cartSetQty(cart, 101, 0);
  assert.equal(cart.length, 0);
});

test('maksutavat: ei käteistä, korttipääte näkyy mutta ei ole valittavissa', () => {
  const list = [
    { code: 'cash', handler: 'cash', channels: ['pos'], active: true, sort_order: 1 },
    { code: 'payment_link', handler: 'payment_link', channels: ['pos'], active: true, sort_order: 10 },
    { code: 'mobilepay', handler: 'mobilepay', channels: ['pos', 'drinks'], active: true, sort_order: 20 },
    { code: 'card_terminal', handler: 'terminal', channels: ['pos'], active: false, sort_order: 40 },
    { code: 'visma_pay', handler: 'visma_pay', channels: ['drinks'], active: true, sort_order: 30 },
  ];
  const pos = tendersFor(list, 'pos').map((t) => t.code);
  assert.deepEqual(pos, ['payment_link', 'mobilepay', 'card_terminal']);
  assert.equal(tenderAvailable(list.find((t) => t.code === 'card_terminal'), { mobilepay_mode: 'test' }), false);
  assert.equal(tenderAvailable(list.find((t) => t.code === 'mobilepay'), { mobilepay_mode: 'off' }), false);
  assert.equal(tenderAvailable(list.find((t) => t.code === 'mobilepay'), { mobilepay_mode: 'test' }), true);
});

test('alkoholi: sanaraja, alkoholiton ja viinirypäle sallitaan', () => {
  assert.equal(looksLikeAlcohol('Olut'), true);
  assert.equal(looksLikeAlcohol('Gin and tonic'), true);
  assert.equal(looksLikeAlcohol('Alkoholiton vichy'), false);
  assert.equal(looksLikeAlcohol('Viinirypälemehu'), false);
  assert.equal(looksLikeAlcohol('Ginger ale'), false);
  assert.equal(drinksAlcohol('olut'), true);
});

test('juomasivu lukee laite-parametrin', () => {
  assert.equal(deviceFromSearch('?laite=pukuhuone-abcdef1234&mock=1'), 'pukuhuone-abcdef1234');
  assert.equal(deviceFromSearch('?device=abc'), 'abc');
  assert.equal(drinksCartAdd([], { product_id: 201, name: 'Vichy', price: 3 }).length, 1);
});

test('pending-import-12: FI+EN, ei numeroita, lakitekstit protected', () => {
  const seen = new Set();
  for (const row of pending) {
    assert.match(row.key, /^[a-z0-9_]+(\.[a-z0-9_-]+)+$/);
    assert.ok(['fi', 'en'].includes(row.lang));
    assert.ok(['normal', 'protected'].includes(row.class));
    assert.equal(row.kind, 'plain');
    assert.ok(row.max_len >= row.text.length);
    assert.deepEqual(row.placeholders, []);
    assert.equal(/\d|€|@|https?:|www\./i.test(row.text), false);
    assert.ok(!seen.has(`${row.key}|${row.lang}`));
    seen.add(`${row.key}|${row.lang}`);
  }
  for (const key of Object.keys(POS_TEXTS.fi)) {
    for (const lang of ['fi', 'en']) {
      const row = pending.find((r) => r.key === `ui.pos.${key}` && r.lang === lang);
      assert.ok(row, `ui.pos.${key} ${lang}`);
      assert.equal(row.text, POS_TEXTS[lang][key]);
      assert.equal(row.class, key === 'pay_legal' ? 'protected' : 'normal');
    }
  }
  for (const key of Object.keys(DRINKS_TEXTS.fi)) {
    for (const lang of ['fi', 'en']) {
      const row = pending.find((r) => r.key === `ui.drinks.${key}` && r.lang === lang);
      assert.ok(row, `ui.drinks.${key} ${lang}`);
      assert.equal(row.text, DRINKS_TEXTS[lang][key]);
      assert.equal(row.class, key === 'pay_legal' ? 'protected' : 'normal');
    }
  }
  for (const key of ['src.pikakassa', 'src.kylmalaite', 'ui.mobilepay.start_error_invalid_phone']) {
    assert.equal(pending.filter((r) => r.key === key).length, 2, key);
  }
});

test('mock-kassa: lahjakortti pois, asiakkaan hinta hylätään, summa katalogista', async () => {
  const mock = createAdminMock({ delay: 0 });
  const cat = await mock.rpc('admin_pos_catalog');
  assert.ok(cat.some((p) => p.product_id === 101));
  assert.equal(cat.some((p) => p.product_id === 104), false);
  await assert.rejects(() => mock.rpc('admin_pos_checkout', { p_items: [{ product_id: 101, quantity: 1, price: 0.01 }] }));
  const order = await mock.rpc('admin_pos_checkout', { p_items: [{ product_id: 101, quantity: 2 }] });
  assert.equal(order.source_channel, 'pikakassa');
  assert.equal(order.total, 6);
  assert.equal(order.lines[0].unit_price, 3);
});
