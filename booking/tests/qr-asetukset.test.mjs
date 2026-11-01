// QR-tulostus, pikakassan tuotevalinta ja asetusten välilehdet. Ei verkkoa eikä tietokantaa.
// SQL: booking/supabase/tests/pos/t104_product_qr.sql (Bottiavustus ajaa).
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { createAdminMock } from '../admin/options-mock.js';
import { moveSort, posCandidates, qrEligible, tillEditorOpen } from '../admin/pos-logic.js';
import { POS_EDIT_TEXTS, POS_TEXTS } from '../admin/pos-texts.js';
import { drinksQrUrl, printSheetHtml, printSheetSvg, sheetHasQr, stickerPlace } from '../admin/qr-print.js';
import { h } from '../admin/ui.js';
import { placeLabel } from '../drinks/drinks-logic.js';
import { parseAdminHash } from '../admin/reservation-query.js';
import { tabFromHash, visibleSettingTabs } from '../admin/settings-tabs.js';
import { SETTINGS_TEXTS } from '../admin/settings-texts.js';
import { createDrinksMock, DRINKS_QR } from '../drinks/drinks-mock.js';
import { DRINKS_EXTRA, DRINKS_TEXTS } from '../drinks/drinks-texts.js';

const read = (rel) => readFileSync(new URL(rel, import.meta.url), 'utf8');
const pending16 = JSON.parse(read('../../content/site-texts.pending-import-16.json'));
const pending12 = JSON.parse(read('../../content/site-texts.pending-import-12.json'));
const pending24 = JSON.parse(read('../../content/site-texts.pending-import-24.json'));
const pending31 = JSON.parse(read('../../content/site-texts.pending-import-31.json'));
const pending109 = JSON.parse(read('../../content/site-texts.pending-import-109.json'));
const URL_QR = 'https://saunotus.fi/juomat/?laite=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

test('QR-osoite on lukittu polku ja tuloste ei ole tyhjä', () => {
  assert.equal(drinksQrUrl('https://saunotus.fi', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), URL_QR);
  assert.equal(drinksQrUrl('https://saunotus.fi/', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), URL_QR);
  const html = printSheetHtml([
    { name: 'Vichy', priceText: '3,00 €', url: URL_QR, label: 'Pukuhuone' },
    { name: 'Käsipyyhe', priceText: '4,00 €', url: 'https://saunotus.fi/juomat/?laite=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', label: '' },
  ], { scan: 'Skannaa ja osta' });
  assert.ok(html.length > 200);
  assert.match(html, /<svg/);
  assert.match(html, /<rect /);
  assert.ok(html.includes('Vichy'));
  assert.ok(html.includes('Käsipyyhe'));
  assert.ok(html.includes('Skannaa ja osta'));
  assert.ok(html.includes(URL_QR));
  assert.equal(sheetHasQr(html, URL_QR), true);
  assert.equal(sheetHasQr('<section></section>', URL_QR), false);
  const svg = printSheetSvg([{ name: 'Vichy', priceText: '3,00 €', url: URL_QR, label: 'Pukuhuone' }], { scan: 'Skannaa ja osta' });
  assert.ok(svg.startsWith('<svg'));
  assert.ok(svg.includes('</svg>'));
  assert.ok(svg.includes('Vichy'));
  assert.ok(svg.includes('Skannaa ja osta'));
  assert.ok(svg.includes('<rect '));
  assert.ok(svg.includes('Pukuhuone'));
});

test('tyhjä sijainti ei näy tarrassa, HTML:ssä eikä SVG:ssä', () => {
  assert.equal(stickerPlace(null), '');
  assert.equal(stickerPlace(undefined), '');
  assert.equal(stickerPlace(false), '');
  assert.equal(stickerPlace(''), '');
  assert.equal(stickerPlace('   '), '');
  assert.equal(stickerPlace('Pukuhuone'), 'Pukuhuone');
  assert.equal(placeLabel(null), '');
  assert.equal(placeLabel(undefined), '');
  assert.equal(placeLabel(''), '');
  assert.equal(placeLabel('  jääkaappi  '), 'jääkaappi');
  for (const label of [null, undefined, false, '', '   ']) {
    const html = printSheetHtml([{ name: 'Vichy', priceText: '3,00 €', url: URL_QR, label }], { scan: 'Skannaa ja osta' });
    const svg = printSheetSvg([{ name: 'Vichy', priceText: '3,00 €', url: URL_QR, label }], { scan: 'Skannaa ja osta' });
    assert.equal(html.includes('qr-where'), false, String(label));
    assert.equal(html.includes('>null<'), false, String(label));
    assert.equal(html.includes('undefined'), false, String(label));
    assert.equal(svg.includes('>null<'), false, String(label));
    assert.equal(svg.includes('undefined'), false, String(label));
    assert.equal((svg.match(/<text /g) || []).length, 3, String(label));
  }
  const shown = printSheetSvg([{ name: 'Vichy', priceText: '3,00 €', url: URL_QR, label: 'Pukuhuone' }]);
  assert.equal((shown.match(/<text /g) || []).length, 4);
});

test('pikakassaan voi valita myös verkkokaupan ulkopuolisen tuotteen', () => {
  const products = [
    { id: 105, name: 'Käsipyyhe', active: true, price: 4, category: 'other', config: { shop_visible: false, age_restricted: false } },
    { id: 104, name: 'Lahjakortti', active: true, price: 58, category: 'gift_card', config: { age_restricted: false } },
    { id: 106, name: 'Olut', name_en: 'Beer', active: true, price: 6, category: 'other', config: { age_restricted: true } },
  ];
  assert.deepEqual(posCandidates(products).map((p) => p.id), [105, 106]);
  assert.equal(qrEligible(products[0]), true);
  assert.equal(qrEligible(products[1]), false);
  assert.equal(qrEligible(products[2]), false);
  assert.equal(tillEditorOpen(0, false), false);
  assert.equal(tillEditorOpen(2, false), false);
  assert.equal(tillEditorOpen(0, true), true);
  assert.equal(tillEditorOpen(2, true), true);
  const sorted = moveSort([{ product_id: 1, name: 'A', pos_sort: 10 }, { product_id: 2, name: 'B', pos_sort: 20 }], 2, -1);
  assert.deepEqual(sorted.map((r) => r.product_id), [2, 1]);
  assert.deepEqual(sorted.map((r) => r.pos_sort), [10, 20]);
});

test('asetusten välilehti tulee osoitteesta ja staff näkee vain QR:n', () => {
  const staff = visibleSettingTabs({ can: (p) => p === 'pos.use', role: 'staff' });
  assert.deepEqual(staff, ['qr']);
  const manager = visibleSettingTabs({ can: (p) => p === 'settings.edit' || p === 'pos.use', role: 'manager' });
  assert.ok(manager.includes('etusivu'));
  assert.ok(manager.includes('varaukset'));
  assert.ok(manager.includes('maksut'));
  assert.ok(manager.includes('laskut'));
  assert.ok(manager.includes('yhteydet'));
  assert.ok(manager.includes('qr'));
  assert.equal(manager.includes('tekninen'), false);
  const admin = visibleSettingTabs({ can: (p) => p === 'settings.edit' || p === 'pos.use', role: 'admin' });
  assert.ok(admin.includes('tekninen'));
  assert.equal(parseAdminHash('#/asetukset/maksut').path, 'asetukset');
  assert.equal(parseAdminHash('#/asetukset/maksut').rest, 'maksut');
  assert.equal(tabFromHash('#/asetukset/maksut', admin), 'maksut');
  assert.equal(tabFromHash('#/asetukset/maksut', staff), 'qr');
  assert.equal(tabFromHash('#/asetukset/tekninen', manager), manager[0]);
  assert.equal(tabFromHash('#/varaukset?filter=treatment_unassigned', admin), admin[0]);
});

test('mock: tuote kassaan, ikäraja ei saa QR-koodia, juomasivu näyttää vain yhden tuotteen', async () => {
  const admin = createAdminMock({ role: 'staff', perms: ['pos.use'] });
  const added = await admin.rpc('admin_set_pos_product', { p_product_id: 105, p_enabled: true, p_sort: 50 });
  assert.equal(added.pos_enabled, true);
  await assert.rejects(() => admin.rpc('admin_set_pos_product', { p_product_id: 104, p_enabled: true, p_sort: 60 }), (e) => e.code === 'not_counter_product');
  await assert.rejects(() => admin.rpc('admin_create_product_qr', { p_product_id: 106, p_label: 'baari' }), (e) => e.code === 'age_restricted');
  const qr = await admin.rpc('admin_create_product_qr', { p_product_id: 105, p_label: 'Pukuhuone' });
  assert.match(qr.code, /^[a-f0-9]{32}$/);
  const blank = await admin.rpc('admin_create_product_qr', { p_product_id: 105, p_label: '' });
  assert.equal(blank.label, null);
  const missing = await admin.rpc('admin_create_product_qr', { p_product_id: 105, p_label: null });
  assert.equal(missing.label, null);
  assert.equal(printSheetHtml([{ name: blank.name, priceText: '4,00 €', url: blank.print_url, label: blank.label }]).includes('qr-where'), false);
  assert.equal(qr.print_url, `https://saunotus.fi/juomat/?laite=${qr.code}`);
  assert.equal(qr.name, 'Käsipyyhe');
  assert.equal(qr.price, 4);
  const staffBlocked = createAdminMock({ role: 'staff', perms: ['bookings.manage'] });
  await assert.rejects(() => staffBlocked.rpc('admin_list_product_qr'), (e) => e.code === 'forbidden');
  const drinks = createDrinksMock();
  const empty = await drinks.rpc('public_drinks_catalog', { p_device: null });
  assert.deepEqual(empty.products, []);
  assert.equal(empty.device.unknown, true);
  const one = await drinks.rpc('public_drinks_catalog', { p_device: DRINKS_QR });
  assert.equal(one.products.length, 1);
  assert.equal(one.products[0].name, 'Vichy');
  assert.equal(one.products[0].price, 3);
  assert.equal('vat_rate' in one.products[0], false);
  const wrong = await drinks.rpc('public_drinks_checkout', { p_device: DRINKS_QR, p_items: [{ product_id: 999, quantity: 1 }] });
  assert.equal(wrong.code, 'not_counter_product');
  const pay = await drinks.rpc('public_drinks_checkout', { p_device: DRINKS_QR, p_items: [{ product_id: 201, quantity: 2 }] });
  assert.equal(pay.ok, true);
  assert.equal(pay.total, 6);
  assert.equal(pay.source_channel, 'kylmalaite');
});

test('näkymät eivät avaa tyhjää ikkunaa ja Procountor-kortti säilyy', () => {
  const pos = read('../admin/pos-screen.js');
  const posEntry = read('../admin/views/pos.js');
  const settings = read('../admin/views/settings.js');
  const panel = read('../admin/qr-panel.js');
  const print = read('../admin/qr-print.js');
  for (const src of [pos, posEntry, settings, panel, print]) assert.equal(src.includes('window.open'), false);
  for (const rel of ['../admin/pos-screen.js', '../admin/views/pos.js', '../admin/views/settings.js', '../admin/qr-panel.js', '../admin/qr-print.js', '../drinks/drinks.js']) {
    const file = fileURLToPath(new URL(rel, import.meta.url));
    const checked = spawnSync(process.execPath, ['--check', file], { encoding: 'utf8' });
    assert.equal(checked.status, 0, checked.stderr);
  }
  assert.match(pos, /admin_set_pos_product/);
  assert.match(pos, /data-testid': 'pos-add'|data-testid": "pos-add"/);
  assert.match(settings, /data-testid': 'procountor-status'/);
  assert.match(settings, /panel-yhteydet/);
  assert.equal(settings.includes('admin_set_vismapay_mode'), false);
  assert.match(settings, /admin_set_procountor_settings/);
  assert.match(settings, /renderCalendarExport/);
  assert.equal(settings.includes('admin_set_booking_calendar'), false);
  assert.equal(settings.includes('admin_set_setting'), false);
  assert.equal(settings.includes('Harjoitusajo'), false);
  assert.equal(settings.includes('Tilit puuttuvat'), false);
  assert.match(panel, /qr-preview/);
  assert.match(panel, /window\.print/);
  assert.match(panel, /stickerPlace/);
  assert.match(panel, /t\('location'\)/);
  assert.equal(panel.includes('card.append'), false);
  assert.match(read('../drinks/drinks.js'), /placeLabel\(device\?\.label\)/);
  const html = read('../drinks/index.html');
  const en = read('../drinks/index.en.html');
  assert.match(html, /noindex, nofollow/);
  assert.match(en, /noindex, nofollow/);
});

test('pending-import-16: vain uudet avaimet, FI+EN, ei numeroita', () => {
  const old = new Set(pending12.map((r) => `${r.key}|${r.lang}`));
  const seen = new Set();
  for (const row of pending16) {
    assert.match(row.key, /^[a-z0-9_]+(\.[a-z0-9_-]+)+$/);
    assert.ok(['fi', 'en'].includes(row.lang));
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.ok(row.max_len >= row.text.length);
    assert.deepEqual(row.placeholders, []);
    assert.equal(/\d|€|@|https?:|www\./i.test(row.text), false);
    assert.equal(old.has(`${row.key}|${row.lang}`), false);
    assert.equal(seen.has(`${row.key}|${row.lang}`), false);
    seen.add(`${row.key}|${row.lang}`);
  }
  for (const [key, text] of Object.entries(POS_EDIT_TEXTS.fi)) {
    assert.equal(POS_TEXTS.fi[key], undefined);
    for (const lang of ['fi', 'en']) {
      const row = pending16.find((r) => r.key === `ui.pos.${key}` && r.lang === lang);
      assert.ok(row, key + ' ' + lang);
      assert.equal(row.text, POS_EDIT_TEXTS[lang][key]);
    }
  }
  for (const lang of ['fi', 'en']) {
    for (const [key, text] of Object.entries(SETTINGS_TEXTS[lang])) {
      const row16 = pending16.find((r) => r.key === key && r.lang === lang);
      const row = pending109.find((r) => r.key === key && r.lang === lang) || row16 || pending24.find((r) => r.key === key && r.lang === lang) || pending31.find((r) => r.key === key && r.lang === lang);
      assert.ok(row, key);
      assert.equal(row.text, text);
      if (!row16) assert.equal(pending109.some((r) => r.key === key && r.lang === lang) || pending24.some((r) => r.key === key && r.lang === lang) || pending31.some((r) => r.key === key && r.lang === lang), true, key);
    }
    for (const [key, text] of Object.entries(DRINKS_EXTRA[lang])) {
      assert.equal(DRINKS_TEXTS[lang][key], undefined);
      const row = pending16.find((r) => r.key === `ui.drinks.${key}` && r.lang === lang);
      assert.equal(row.text, text);
    }
  }
});

function installDom() {
  function Node(type) { this.nodeType = type; this.childNodes = []; this.parent = null; }
  function Text(data) { Node.call(this, 3); this.data = String(data); }
  function El(tag) {
    Node.call(this, 1);
    this.tagName = String(tag).toUpperCase();
    this.attrs = {};
    this.className = '';
  }
  El.prototype.append = function (...nodes) {
    for (const n of nodes) {
      // Selain: ParentNode.append muuttaa null/undefined/false merkkijonoksi.
      const child = n != null && n !== false && n.nodeType ? n : new Text(n);
      child.parent = this;
      this.childNodes.push(child);
    }
  };
  El.prototype.setAttribute = function (k, v) { this.attrs[k] = String(v); };
  El.prototype.addEventListener = function () {};
  Object.defineProperty(El.prototype, 'textContent', {
    set(v) { this.childNodes = [new Text(v)]; },
    get() { return this.childNodes.map((n) => (n.nodeType === 3 ? n.data : n.textContent)).join(''); },
  });
  globalThis.document = {
    createElement: (tag) => new El(tag),
    createElementNS: (_ns, tag) => new El(tag),
    createTextNode: (t) => new Text(t),
  };
}

test('h() ohittaa null-, undefined- ja false-lapset', () => {
  const prev = globalThis.document;
  installDom();
  try {
    const el = h('div', {}, 'a', null, undefined, false, ['b', null], h('span', { text: 'c' }), 0, '');
    assert.equal(el.textContent, 'abc0');
    assert.equal(el.childNodes.some((n) => n.data === 'null' || n.data === 'undefined' || n.data === 'false'), false);
    const card = h('article', { class: 'qr-card' },
      h('h2', { text: 'Vichy' }),
      h('p', { class: 'qr-price', text: '3,00 €' }),
      null,
      h('p', { class: 'qr-scan', text: 'Skannaa ja osta' }));
    assert.equal(card.textContent.includes('null'), false);
    assert.equal(card.childNodes.length, 3);
    assert.equal(card.childNodes.some((n) => n.nodeType === 3), false);
  } finally {
    if (prev === undefined) delete globalThis.document;
    else globalThis.document = prev;
  }
});

test('pending-import-24: sijaintikentän nimi, FI+EN, ei päällekkäin', () => {
  assert.equal(pending24.length, 2);
  const seen = new Set();
  for (const row of pending24) {
    assert.equal(row.key, 'ui.admin.qr.location');
    assert.ok(row.lang === 'fi' || row.lang === 'en');
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.deepEqual(row.placeholders, []);
    assert.ok(row.max_len >= row.text.length);
    assert.equal(row.text.includes('{{'), false);
    assert.equal(seen.has(row.lang), false);
    seen.add(row.lang);
    assert.equal(SETTINGS_TEXTS[row.lang][row.key], row.text);
  }
  assert.equal(SETTINGS_TEXTS.fi['ui.admin.qr.location'], 'Sijainti (näkyy tarrassa, valinnainen)');
  assert.equal(SETTINGS_TEXTS.en['ui.admin.qr.location'], 'Location (shown on the sticker, optional)');
  assert.equal(SETTINGS_TEXTS.fi['ui.admin.qr.label'], 'Tarra');
  const taken = new Set();
  for (const row of [...pending12, ...pending16]) taken.add(`${row.key}|${row.lang}`);
  for (const row of pending24) assert.equal(taken.has(`${row.key}|${row.lang}`), false);
  const fb = JSON.parse(read('../../content/site-texts.fallback.json'));
  const fbRows = Array.isArray(fb) ? fb : fb.texts;
  for (const row of pending24) assert.equal(fbRows.find((r) => r.key === row.key && r.lang === row.lang)?.text, row.text);
});

test('SQL ja build-lista: t104, ei mobilepay-uudelleenkirjoitusta, uudet moduulit', () => {
  const rpc = read('../supabase/migrations/20261019020100_booking_105_product_qr_rpc.sql');
  const t80 = read('../supabase/tests/pos/t80_pos_fridge.sql');
  const t104 = read('../supabase/tests/pos/t104_product_qr.sql');
  const pages = read('../../.github/workflows/pages.yml');
  const build = read('../../scripts/build-pages.mjs');
  assert.equal(/function booking\.mobilepay_payment_prepare/.test(rpc), false);
  assert.equal(/function booking\.admin_update_product_config/.test(rpc), false);
  assert.equal(/function booking\.expire_counter_orders/.test(rpc), false);
  assert.equal(/function booking\.email_outbox_claim/.test(rpc), false);
  assert.match(rpc, /security definer set search_path = ''/i);
  assert.match(rpc, /public_drinks_catalog/);
  assert.equal(t80.includes('cold_units'), false);
  assert.match(t80, /product_qr/);
  assert.match(t104, /age_restricted/);
  assert.match(t104, /push_not_allowed/);
  assert.match(t104, /expire_counter_orders/);
  assert.match(t104, /business_id/);
  assert.match(t104, /site_base_url/);
  assert.match(t104, /cold_units_archive/);
  assert.equal(rpc.includes('ei ole tyhjä'), false);
  assert.match(rpc, /insert into booking\.cold_units_archive/);
  assert.match(rpc, /drop table booking\.cold_units/);
  const schema = read('../supabase/migrations/20261019020000_booking_104_product_qr_schema.sql');
  const rb104 = read('../supabase/rollbacks/20261019020000_booking_104_ROLLBACK.sql');
  const rb105 = read('../supabase/rollbacks/20261019020100_booking_105_ROLLBACK.sql');
  assert.match(schema, /create table booking\.cold_units_archive/);
  assert.match(schema, /revoke all on booking\.cold_units_archive from public, anon, authenticated/);
  assert.match(rb105, /from booking\.cold_units_archive/);
  assert.equal(/drop table[^;]*cold_units_archive/i.test(rb105), false);
  assert.match(rb104, /drop table if exists booking\.cold_units_archive/);
  assert.match(pages, /t104 \(booking\/supabase\/tests\/pos\/t104_product_qr\.sql\) ei ole tässä ajossa/);
  assert.match(pages, /node --test booking\/tests\/procountor-admin\.test\.mjs booking\/tests\/pikakassa\.test\.mjs/);
  assert.match(pages, /node --test booking\/tests\/qr-asetukset\.test\.mjs/);
  for (const f of ['settings-tabs.js', 'settings-texts.js', 'qr-print.js', 'qr-panel.js', 'pos-screen.js']) assert.ok(build.includes(f), f);
});
