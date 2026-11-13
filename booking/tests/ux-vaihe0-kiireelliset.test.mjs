// UX-analyysi #345, vaihe 0 (kiireelliset): HALL-LASKUT-01, HALL-TALOUS-01, KAUPPA-MAKSU-01 (Visma Pay -teksti), KAUPPA-JONO-01.
// SIVU-JUOMAT-01 ja HALL-TILAUS-02: booking/tests/juomat-moduulit.test.mjs.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseOrderNo, resolveOrderForInvoice, orderSummaryLine } from '../admin/invoice-from-order.js';
import { methodNet, methodsNetTotal, methodVat } from '../admin/report-method-net.js';
import { ensureEventProduct } from '../shop/src/event-full.js';
import { INVOICE_TEXTS } from '../admin/invoices-texts.js';
import { T as SHOP_T } from '../shop/src/i18n.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const rd = (p) => readFileSync(join(root, p), 'utf8');
const money = (n) => `${Number(n).toFixed(2).replace('.', ',')} €`;

// PRODin tilanne: id:t 1–14148 ja tilausnumerot 19–15202 menevät päällekkäin. Tilausnumero 15123 ≠ id 15123.
function fakeRpc() {
  const orders = [
    { id: 14001, order_no: 15123, total: 256, customer: { name: 'Matti Meikäläinen', company: 'Yritys Oy' } },
    { id: 15123, order_no: 16000, total: 12, customer: { name: 'Väärä Asiakas' } },
  ];
  const calls = [];
  const rpc = async (fn, a) => {
    calls.push([fn, a]);
    if (fn === 'admin_order_lookup') { const o = orders.find((x) => x.order_no === a.p_order_no); if (!o) { const e = new Error('Tilausta ei löydy'); e.code = 'not_found'; throw e; } return { order_id: o.id, order_no: o.order_no }; }
    if (fn === 'admin_get_order') { const o = orders.find((x) => x.id === a.p_order_id); return { order_id: o.id, order_no: o.order_no, total: o.total, status: 'confirmed', customer: o.customer, invoice: null }; }
    throw new Error(fn);
  };
  return { rpc, calls };
}

test('HALL-LASKUT-01: tilausnumero muunnetaan sisäiseksi id:ksi (ei käytetä numeroa id:nä)', async () => {
  const { rpc, calls } = fakeRpc();
  const o = await resolveOrderForInvoice(rpc, ' 15123 ');
  assert.equal(o.orderId, 14001);
  assert.equal(o.orderNo, 15123);
  assert.equal(o.company, 'Yritys Oy'); assert.equal(o.customer, 'Matti Meikäläinen'); assert.equal(o.total, 256);
  assert.deepEqual(calls, [['admin_order_lookup', { p_order_no: 15123 }], ['admin_get_order', { p_order_id: 14001 }]]);
  assert.equal(orderSummaryLine(o, money), '#15123 · Yritys Oy · Matti Meikäläinen · 256,00 €');
});

test('HALL-LASKUT-01: väärä tai puuttuva numero antaa selvän virheen eikä hae mitään tilausta', async () => {
  const { rpc, calls } = fakeRpc();
  for (const bad of ['', 'abc', '0', '-5', '12.5']) await assert.rejects(resolveOrderForInvoice(rpc, bad), { code: 'invalid_order_no' }, bad);
  assert.equal(calls.length, 0);
  await assert.rejects(resolveOrderForInvoice(rpc, '99999'), { code: 'not_found' });
  assert.equal(parseOrderNo('#15123'), 15123);
});

test('HALL-LASKUT-01: jos haettu tilaus ei ole kirjoitettu numero, luontia ei tarjota', async () => {
  const rpc = async (fn) => (fn === 'admin_order_lookup' ? { order_id: 7, order_no: 15123 } : { order_id: 7, order_no: 999, total: 1, customer: {} });
  await assert.rejects(resolveOrderForInvoice(rpc, '15123'), { code: 'mismatch' });
});

test('HALL-LASKUT-01: Laskut-näkymä hakee ensin, näyttää asiakkaan ja summan ja luo laskun order_id:llä', () => {
  const v = rd('booking/admin/views/invoices.js');
  const fn = v.slice(v.indexOf('async function fromOrder()'), v.indexOf('function customerFromError'));
  assert.match(fn, /resolveOrderForInvoice\(rpc, orderNo\.value\)/);
  assert.match(fn, /orderSummaryLine\(o, money\)/);
  assert.match(fn, /admin_create_invoice_from_order', \{ p_order_id: found\.orderId \}/);
  assert.doesNotMatch(fn, /p_order_id: Number\(/, 'kirjoitettua numeroa ei lähetetä id:nä');
  assert.match(fn, /disabled: true, 'data-testid': 'inv-order-create'/, 'Luo lasku on pois käytöstä ennen hakua');
  assert.match(fn, /addEventListener\('input', reset\)/, 'numeron muutos peruu vahvistuksen');
  // kokeilutila: sama sopimus kuin tuotannossa
  const mock = rd('booking/admin/options-mock.js');
  assert.match(mock, /admin_order_lookup: \(a\) =>/);
  assert.doesNotMatch(mock, /r\.order_no === a\.p_order_id/);
});

test('HALL-LASKUT-01: uudet tekstit FI+EN koodissa ja tuonnissa 145', () => {
  const rows = JSON.parse(rd('content/site-texts.pending-import-145.json'));
  const inv = rows.filter((r) => r.key.startsWith('ui.admin.invoices.'));
  assert.equal(inv.length, 12);
  for (const r of inv) {
    assert.equal(INVOICE_TEXTS[r.lang][r.key], r.text, `${r.key} ${r.lang}`);
    assert.deepEqual(r.placeholders, r.text.match(/\{\{var:[a-z0-9_]+\}\}/g) || []);
    assert.ok(r.text.length <= r.max_len);
  }
});

test('HALL-TALOUS-01: Veroton = brutto hyvitysten jälkeen − maksutavan ALV (ei bruttoa)', () => {
  const vat = [
    { method: 'card', rate: 25.5, net: 79.68, vat: 20.32, gross: 100 },
    { method: 'card', rate: 14, net: 43.86, vat: 6.14, gross: 50 },
    { method: 'card', rate: 25.5, net: -15.94, vat: -4.06, gross: -20 },
    { method: 'mobilepay', rate: 25.5, net: 39.84, vat: 10.16, gross: 50 },
  ];
  const card = { method: 'card', gross: 150, refunds: -20 };
  assert.equal(methodVat(vat, 'card'), 22.4);
  assert.equal(methodNet(card, vat), 107.6);
  assert.notEqual(methodNet(card, vat), card.gross + card.refunds);
  assert.equal(methodNet({ method: 'cash', gross: 10, refunds: 0 }, vat), 10, 'ei ALV-rivejä (esim. lahjakortin myynti) → koko summa veroton');
  assert.equal(methodsNetTotal([card, { method: 'mobilepay', gross: 50, refunds: 0 }], vat), 147.44);
  const view = rd('booking/admin/views/talous-reports.js');
  const by = view.slice(view.indexOf("table('r-by-method'"), view.indexOf("const matrix"));
  assert.match(by, /methodNet\(m, r\.by_method_vat\)/);
  assert.match(by, /methodsNetTotal\(methods, r\.by_method_vat\)/);
  assert.doesNotMatch(by, /M\(\(m\.gross \|\| 0\) \+ \(m\.refunds \|\| 0\)\)/);
});

test('KAUPPA-MAKSU-01: "Visma Pay otetaan käyttöön myöhemmin" pois (maksunvälittäjä Montonio), koodi + varateksti + tuonti 145', () => {
  assert.equal(SHOP_T.fi.payLater, 'Maksu paikan päällä.');
  assert.equal(SHOP_T.en.payLater, 'Payment on site.');
  const fb = JSON.parse(rd('content/site-texts.fallback.json')).texts;
  const rows = JSON.parse(rd('content/site-texts.pending-import-145.json')).filter((r) => r.key === 'ui.shop.pay_later');
  assert.equal(rows.length, 2);
  for (const r of rows) {
    assert.equal(r.text, r.lang === 'fi' ? SHOP_T.fi.payLater : SHOP_T.en.payLater);
    assert.equal(fb.find((x) => x.key === r.key && x.lang === r.lang).text, r.text);
  }
  for (const f of ['booking/shop/src/i18n.js', 'content/site-texts.fallback.json']) assert.doesNotMatch(rd(f), /otetaan käyttöön myöhemmin|will be introduced later/, f);
});

test('tuonti 145: numero vapaa, rivit FI+EN pareittain, ei päällekkäisiä avaimia muissa odottavissa tuonneissa', () => {
  const rows = JSON.parse(rd('content/site-texts.pending-import-145.json'));
  const keys = new Set(rows.map((r) => r.key));
  for (const k of keys) assert.deepEqual(rows.filter((r) => r.key === k).map((r) => r.lang).sort(), ['en', 'fi'], k);
  for (const r of rows) { assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain'); assert.ok(r.reason); }
  for (const f of readdirSync(join(root, 'content'))) {
    if (!/^site-texts\.pending-import-\d+\.json$/.test(f) || f.endsWith('-145.json')) continue;
    for (const r of JSON.parse(rd(`content/${f}`))) if (r.key.startsWith('ui.admin.invoices.order_')) assert.fail(`${f}: ${r.key}`);
  }
});

const ev = (over = {}) => ({ product_id: 77, slug: 'naisten-joulusauna', name: 'Naisten joulusauna', category: 'event', price: 39, occurrences: [{ status: 'full', starts_at: '2026-12-12T15:00:00Z', ends_at: '2026-12-12T18:00:00Z' }], ...over });
const NOW = Date.parse('2026-11-13T08:00:00Z');

test('KAUPPA-JONO-01: suora jonotuslinkki lisää täyden tapahtuman tuotteen katalogiin (kuten listanäkymä)', async () => {
  const catalog = [{ id: 1, slug: 'sauna' }];
  let n = 0;
  const load = async () => { n++; return [ev()]; };
  assert.equal(await ensureEventProduct(catalog, '77', load, { now: NOW }), true);
  assert.equal(catalog.find((p) => p.id === 77).category, 'event');
  assert.equal(await ensureEventProduct(catalog, 77, load, { now: NOW }), true);
  assert.equal(n, 1, 'jo katalogissa → ei uutta hakua');
  assert.equal(catalog.filter((p) => p.id === 77).length, 1);
});

test('KAUPPA-JONO-01: yrityskalenteri ei hae julkisia tapahtumia; haun virhe → false (näkymä näyttää "Vuoroa ei löytynyt")', async () => {
  let called = false;
  assert.equal(await ensureEventProduct([], 77, async () => { called = true; return [ev()]; }, { business: true, now: NOW }), false);
  assert.equal(called, false);
  assert.equal(await ensureEventProduct([], 77, async () => { throw new Error('verkko'); }, { now: NOW }), false);
  assert.equal(await ensureEventProduct([], 78, async () => [ev()], { now: NOW }), false, 'eri tuote');
});

test('KAUPPA-JONO-01: reitti jono kutsuu ensureEventProduct ennen viewWaitlistiä', () => {
  const s = rd('booking/shop/src/shop.js');
  const at = s.indexOf("parts[0] === 'jono'");
  const seg = s.slice(at, s.indexOf('wv.viewWaitlist(', at) + 20);
  assert.match(seg, /await ensureEventProduct\(state\.catalog, parts\[3\], publicEvents, \{ business: S\.audience === 'business' \}\)/);
});
