import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { finnishMobileMsisdn } from '../admin/phone-fi.js';
import { cartAdd, cartSetQty, cartTotal, checkoutItems, looksLikeAlcohol, tenderAvailable, tendersFor, validEmail } from '../admin/pos-logic.js';
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
  const rows = qrMatrix('https://saunotus.fi/juomat/?laite=pukuhuone-abcdef1234');
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
  assert.equal(tenderAvailable(list.find((t) => t.code === 'mobilepay'), { mobilepay_mode: 'test' }), false);
  assert.equal(tenderAvailable(list.find((t) => t.code === 'visma_pay'), { vismapay_mode: 'test' }), false);
  const link = list.find((t) => t.code === 'payment_link');
  assert.equal(tenderAvailable(link, { vismapay_mode: 'off' }), false);
  assert.equal(tenderAvailable(link, {}), false);
  assert.equal(tenderAvailable(link, { vismapay_mode: 'dry_run' }), true);
  assert.equal(tenderAvailable(link, { montonio_mode: 'off', vismapay_mode: 'test' }), false);
  assert.equal(tenderAvailable(link, { montonio_mode: 'test', vismapay_mode: 'off' }), true);
});

test('sähköposti: sama sääntö kuin palvelimella', () => {
  assert.equal(validEmail('  Asiakas@Example.Test  '), true);
  assert.equal(validEmail('asiakas@example.test'), true);
  assert.equal(validEmail(''), false);
  assert.equal(validEmail('   '), false);
  assert.equal(validEmail('ei-kelpaa'), false);
  assert.equal(validEmail('a@b.c'), false);
  assert.equal(validEmail(`${'a'.repeat(250)}@x.co`), false);
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

test('mock: pos.use saa lähettää linkin, payments.manage ei ole tarpeen, tuplakutsu on yksi rivi', async () => {
  const mock = createAdminMock({ delay: 0, perms: ['pos.use'] });
  const order = await mock.rpc('admin_pos_checkout', { p_items: [{ product_id: 101, quantity: 1 }], p_email: '  Asiakas@Example.Test  ' });
  assert.equal(order.customer_email, 'asiakas@example.test');
  const link = await mock.rpc('admin_pos_send_link', { p_order_id: order.order_id, p_email: '  Asiakas@Example.Test  ' });
  assert.equal(link.ok, true);
  assert.equal(link.email_queued, true);
  assert.equal(link.masked_to, 'a***@e***.test');
  assert.equal(JSON.stringify(link).includes('asiakas@example.test'), false);
  const again = await mock.rpc('admin_pos_send_link', { p_order_id: order.order_id, p_email: 'asiakas@example.test' });
  assert.equal(again.email_queued, false);
  assert.equal(again.payment_id, link.payment_id);
  assert.equal(mock.state.posMail.length, 1);
  await assert.rejects(() => mock.rpc('admin_pos_send_link', { p_order_id: order.order_id, p_email: 'ei' }), (e) => e.code === 'invalid_email');
  await assert.rejects(() => mock.rpc('admin_pos_send_link', { p_order_id: order.order_id, p_email: 'asiakas@example.test', p_resend: true }), (e) => e.code === 'rate_limited');
  assert.equal(mock.state.posMail.length, 1);
  mock.state.posMail[0].created = Date.now() - 120000;
  const resent = await mock.rpc('admin_pos_send_link', { p_order_id: order.order_id, p_email: 'asiakas@example.test', p_resend: true });
  assert.equal(resent.email_queued, true);
  assert.equal(mock.state.posMail.length, 2);
  mock.state.posMail.forEach((m) => { m.created = Date.now() - 120000; });
  await mock.rpc('admin_pos_send_link', { p_order_id: order.order_id, p_email: 'asiakas@example.test', p_resend: true });
  await assert.rejects(() => mock.rpc('admin_pos_send_link', { p_order_id: order.order_id, p_email: 'asiakas@example.test', p_resend: true }), (e) => e.code === 'rate_limited');
  assert.equal(mock.state.posMail.length, 3);
  await assert.rejects(() => mock.rpc('admin_create_payment_link', { p_order_id: order.order_id }), (e) => e.code === 'forbidden');
  const st = await mock.rpc('admin_pos_email_status', { p_order_id: order.order_id });
  assert.equal(st.masked_to, 'a***@e***.test');
  assert.equal(JSON.stringify(st).includes('asiakas@example.test'), false);
  mock.state.posOrders[0].status = 'cancelled';
  await assert.rejects(() => mock.rpc('admin_pos_send_link', { p_order_id: order.order_id, p_email: 'asiakas@example.test' }), (e) => e.code === 'order_not_editable');
});

test('mock: linkin jälkeen pending-tilainen tilaus lähtee uudelleen, vanhaa asiakasta ei muuteta', async () => {
  const mock = createAdminMock({ delay: 0, perms: ['pos.use'] });
  const order = await mock.rpc('admin_pos_checkout', { p_items: [{ product_id: 101, quantity: 1 }], p_email: 'vanha@example.test' });
  const oldId = mock.state.posOrders[0].customer_id;
  const link = await mock.rpc('admin_pos_send_link', { p_order_id: order.order_id, p_email: 'vanha@example.test' });
  assert.equal(mock.state.posOrders[0].payment_status, 'pending');
  const again = await mock.rpc('admin_pos_send_link', { p_order_id: order.order_id, p_email: 'vanha@example.test' });
  assert.equal(again.ok, true);
  assert.equal(again.email_queued, false);
  assert.equal(again.payment_id, link.payment_id);
  assert.equal(mock.state.posMail.length, 1);
  const moved = await mock.rpc('admin_pos_send_link', { p_order_id: order.order_id, p_email: 'uusi@example.test' });
  assert.equal(moved.ok, true);
  assert.equal(moved.masked_to, 'u***@e***.test');
  assert.notEqual(mock.state.posOrders[0].customer_id, oldId);
  assert.equal(mock.state.posCustomers.find((c) => c.id === oldId).email, 'vanha@example.test');
  assert.equal(mock.state.posOrders[0].customer_email, 'uusi@example.test');
});

test('mock: ilman pos.use tai settings.edit linkkiä ei saa lähettää', async () => {
  const mock = createAdminMock({ delay: 0, perms: [] });
  mock.state.posOrders.push({ order_id: 1, status: 'pending', payment_status: 'unpaid', source_channel: 'pikakassa', total: 3, customer_email: null });
  await assert.rejects(() => mock.rpc('admin_pos_send_link', { p_order_id: 1, p_email: 'asiakas@example.test' }), (e) => e.code === 'forbidden');
  await assert.rejects(() => mock.rpc('admin_pos_email_status', { p_order_id: 1 }), (e) => e.code === 'forbidden');
  const editor = createAdminMock({ delay: 0, perms: ['settings.edit'] });
  editor.state.posOrders.push({ order_id: 1, status: 'pending', payment_status: 'unpaid', source_channel: 'pikakassa', total: 3, customer_email: null });
  const link = await editor.rpc('admin_pos_send_link', { p_order_id: 1, p_email: 'asiakas@example.test' });
  assert.equal(link.ok, true);
  assert.equal(editor.state.resendMode, 'dry_run');
  assert.equal(editor.state.posModes.vismapay_mode, 'dry_run');
});
