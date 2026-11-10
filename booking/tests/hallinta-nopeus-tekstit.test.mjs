// Hallinnan nopeus (t427u, PR A): sivustotekstit haetaan kerran istunnossa jaetun välimuistin kautta,
// viereisten päivien nippua ei esihaeta avauksessa ja mock-data ladataan vain kokeilutilassa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { getSiteTexts, primeSiteTexts, clearSiteTextsCache } from '../admin/site-texts-cache.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = (p) => readFileSync(join(root, p), 'utf8');
const TEXTS = { ok: true, texts: [
  { key: 'ui.admin.orders.title', lang: 'fi', text: 'Tilaukset X' },
  { key: 'ui.admin.booking.title', lang: 'fi', text: 'Varaus X' },
  { key: 'ui.pos.title', lang: 'fi', text: 'Kassa X' },
] };
const counter = (reply = () => TEXTS) => { const calls = []; const fn = async (name, args) => { calls.push([name, args]); return reply(calls.length); }; fn.calls = calls; return fn; };

test('välimuisti: rinnakkaiset ja peräkkäiset haut → yksi public_get_site_texts', async () => {
  clearSiteTextsCache();
  const rpc = counter();
  const [a, b] = await Promise.all([getSiteTexts(rpc), getSiteTexts(rpc)]);
  const c = await getSiteTexts(rpc);
  assert.equal(rpc.calls.length, 1);
  assert.deepEqual(rpc.calls[0], ['public_get_site_texts', { p_lang: null }]);
  assert.equal(a, b); assert.equal(b, c);
});

test('välimuisti: virhe tai kelvoton vastaus ei jää muistiin (seuraava yrittää uudelleen)', async () => {
  clearSiteTextsCache();
  const bad = counter((n) => (n === 1 ? { ok: false } : TEXTS));
  assert.deepEqual(await getSiteTexts(bad), { ok: false });
  assert.equal(await getSiteTexts(bad), TEXTS);
  assert.equal(bad.calls.length, 2);
  clearSiteTextsCache();
  let n = 0;
  const failing = async () => { n += 1; if (n === 1) throw new Error('verkko'); return TEXTS; };
  await assert.rejects(getSiteTexts(failing));
  assert.equal(await getSiteTexts(failing), TEXTS);
  assert.equal(n, 2);
});

test('välimuisti: primeSiteTexts (päivänippu) → ei verkkokutsua; kelvoton prime ohitetaan', async () => {
  clearSiteTextsCache();
  primeSiteTexts({ ok: false });
  const rpc = counter();
  primeSiteTexts(TEXTS);
  assert.equal(await getSiteTexts(rpc), TEXTS);
  assert.equal(rpc.calls.length, 0);
});

test('tekstimoduulit: kaikki lataukset yhteisen välimuistin kautta → yksi haku istunnossa', async () => {
  clearSiteTextsCache();
  const rpc = counter();
  const mods = [
    ['booking-texts.js', 'loadBookingTexts'], ['calendar-export-texts.js', 'loadCalendarExportTexts'],
    ['customer-message-texts.js', 'loadCustomerMessageTexts'], ['events-texts.js', 'loadEventsTexts'],
    ['invoices-texts.js', 'loadInvoiceTexts'], ['orders-texts.js', 'loadOrderTexts'], ['pos-texts.js', 'loadPosTexts'],
    ['product-texts.js', 'loadProductTexts'], ['reports-texts.js', 'loadReportTexts'], ['review-texts.js', 'loadReviewTexts'],
    ['rich-texts.js', 'loadRichTexts'], ['settings-texts.js', 'loadSettingsTexts'], ['training-texts.js', 'loadTrainingTexts'],
  ];
  const loaders = [];
  for (const [file, name] of mods) {
    const m = await import(`../admin/${file}`);
    assert.equal(typeof m[name], 'function', `${file}: ${name}`);
    loaders.push(m[name]);
  }
  await Promise.all(loaders.map((f) => f(rpc)));
  assert.equal(rpc.calls.length, 1);
  const { orderText } = await import('../admin/orders-texts.js');
  assert.equal(orderText('ui.admin.orders.title', null, 'fi'), 'Tilaukset X');
});

test('lähde: yksikään hallinnan moduuli ei kutsu public_get_site_texts-funktiota ohi välimuistin', () => {
  const dir = join(root, 'admin');
  const files = readdirSync(dir).filter((f) => f.endsWith('.js') && !f.endsWith('-mock.js') && f !== 'site-texts-cache.js')
    .concat(readdirSync(join(dir, 'views')).filter((f) => f.endsWith('.js')).map((f) => `views/${f}`));
  const offenders = files.filter((f) => /\(\s*['"]public_get_site_texts['"]/.test(src(`admin/${f}`)));
  assert.deepEqual(offenders, []);
});

test('lähde: Talous, Tuotteet ja Viestit lataavat tekstit rinnakkain', () => {
  assert.match(src('admin/views/talous.js'), /await Promise\.all\(\[loadOrderTexts\(rpc\), loadReportTexts\(rpc\), loadRcTexts\(rpc\), loadAcTexts\(rpc\)\]\)/);
  assert.match(src('admin/views/products.js'), /await Promise\.all\(\[loadPosTexts\(rpc\), loadProductTexts\(rpc\), loadRichTexts\(rpc\), loadEventsTexts\(rpc\)\]\)/);
  assert.match(src('admin/views/messages.js'), /await Promise\.all\(\[loadRichTexts\(rpc\), loadCustomerMessageTexts\(rpc\)\]\)/);
});

test('lähde: avaus ei esihae viereisiä päiviä; esihaku vain ‹/›-aikeesta', () => {
  const admin = src('admin/admin.js');
  assert.equal(/prefetchAdjacentDay\s*\?\.\s*\(/.test(admin), false);
  const day = src('admin/views/day.js');
  assert.match(day, /export const prefetchDay = /);
  assert.match(day, /onpointerenter: f, onfocus: f, ontouchstart: f/);
  assert.match(day, /\.\.\.intent\(addDays\(date, -1\)\)/);
  assert.match(day, /\.\.\.intent\(addDays\(date, 1\)\)/);
});

test('lähde: mock-moduulit eivät ole staattisia importteja tuotantopolulla', () => {
  for (const f of ['admin.js', 'talous-api.js', 'giftcards-api.js', 'vouchers-api.js']) {
    const s = src(`admin/${f}`);
    assert.equal(/^import [^;]*from '\.\/[a-z-]*-mock\.js'/m.test(s), false, f);
  }
  assert.match(src('admin/admin.js'), /if \(MOCK\) \{[\s\S]*await import\(new URL\('\.\/options-mock\.js'/);
});

test('mock-varapolku: createTalousApi/createGiftApi/createVoucherApi toimivat kokeilutilassa laiskalla mockilla', async () => {
  const { createTalousApi } = await import('../admin/talous-api.js');
  const { createGiftApi } = await import('../admin/giftcards-api.js');
  const { createVoucherApi } = await import('../admin/vouchers-api.js');
  const t = createTalousApi({ rpc: null, mock: true });
  assert.equal(t.mode, 'mock');
  const g = createGiftApi({ rpc: null, mock: true });
  assert.equal(g.mode, 'mock');
  const pk = await g.packages();   // mock ladataan vasta tässä (dynaaminen import)
  assert.ok(pk != null);
  const v = createVoucherApi({ rpc: null, mock: true });
  assert.equal(v.mode, 'mock');
});
