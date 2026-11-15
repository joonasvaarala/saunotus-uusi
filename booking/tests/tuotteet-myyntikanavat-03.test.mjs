// booking_316 / HALL-TUOTTEET-03: tuotteen myyntikanavat monivalintana tuote-editorissa (Joonas t1780u 15.11.2026 klo 9.04).
// Kanavat ladataan datasta (admin_list_sales_channels), tallennus admin_set_product_sales_channels. Ei verkkoa eikä tietokantaa.
// SQL-puoli: booking/supabase/tests/t316_sales_channels.sql (paikallinen PG) ja booking/tests/myyntikanavat-316.test.mjs.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const href = (rel) => new URL(rel, import.meta.url);
const read = (rel) => readFileSync(href(rel), 'utf8');
const S = await import(href('../admin/sales-channels.js'));
const L = await import(href('../admin/product-editor-logic.js'));
const { createAdminMock, MOCK_SALES_CHANNELS } = await import(href('../admin/options-mock.js'));
const clone = (o) => JSON.parse(JSON.stringify(o));
const labels = { product: 'Perustiedot ja hinta', training: 'Koulutus', config: 'Myynti ja näkyvyys', channels: 'Myyntikanavat', image: 'Kuva', suggestions: 'Lisämyynti', variant: (id) => `Variantti ${id}` };
const product = (over = {}) => ({
  id: 7, name: 'Pyyhevuokra', price: 5, price_text: '5,00 €', vat_rate: 25.5, active: true, category: 'product_rental',
  config: { bookable: true, shop_visible: true, audience: 'consumer', sort_order: 10, min_persons: 1, max_persons: null, pos_enabled: false, pos_sort: 100, fridge_sale: false, age_restricted: false },
  variants: [], ...over,
});
const plan = (base, cur) => L.buildSavePlan({ productId: 7, base, cur, labels });

test('kanavasääntö = booking_316:n backfill ja synkka (vanhat kentät ↔ kanavat)', () => {
  const cfg = (o) => ({ bookable: true, shop_visible: false, channels: null, fridge_sale: false, pos_enabled: false, ...o });
  assert.deepEqual(S.channelsFromConfig('public_sauna', cfg({ shop_visible: true })), ['shop']);
  assert.deepEqual(S.channelsFromConfig('treatment', cfg({ shop_visible: false })), [], 'shop vaatii shop_visible');
  assert.deepEqual(S.channelsFromConfig('training', cfg({})), ['widget'], 'koulutuksen oletus');
  assert.deepEqual(S.channelsFromConfig('training', cfg({ channels: ['link'] })), ['link']);
  assert.deepEqual(S.channelsFromConfig('training', cfg({ shop_visible: true, channels: ['link'], fridge_sale: true })), ['link', 'qr'], 'PRODin tuote 121');
  assert.deepEqual(S.channelsFromConfig('product_rental', cfg({ fridge_sale: true, pos_enabled: true })), ['qr', 'pos']);
  assert.deepEqual(S.channelsFromConfig('x', null), []);
  // julkinen kanava vain bookable-tuotteelle (PRODin koulutukset 35–37: bookable false → ei Upotusta)
  assert.deepEqual(S.channelsFromConfig('training', cfg({ bookable: false })), []);
  assert.deepEqual(S.channelsFromConfig('public_sauna', cfg({ bookable: false, shop_visible: true, pos_enabled: true })), ['pos']);
  // julkisen kanavan lisäys asettaa bookable = true; poisto ei muuta sitä; ei-julkinen kanava ei koske siihen
  assert.deepEqual(S.applyChannelsToConfig('training', cfg({ bookable: false }), ['widget']), cfg({ bookable: true }));
  assert.deepEqual(S.applyChannelsToConfig('ceremony', cfg({ bookable: false, shop_visible: true }), ['link']), cfg({ bookable: true, shop_visible: false, channels: ['link'] }),
    'vanhat kentät liitostaulun mukaisiksi (shop ei avaudu vahingossa)');
  assert.deepEqual(S.applyChannelsToConfig('public_sauna', cfg({ shop_visible: true }), []), cfg({ shop_visible: false, channels: [] }), 'poisto: bookable säilyy');
  assert.deepEqual(S.applyChannelsToConfig('product_rental', cfg({ bookable: false }), ['pos']), cfg({ bookable: false, pos_enabled: true }));
  // kanavat → kentät
  assert.deepEqual(S.applyChannelsToConfig('public_sauna', cfg({ shop_visible: true }), ['widget', 'pos']), cfg({ shop_visible: false, channels: ['widget'], pos_enabled: true }));
  assert.deepEqual(S.applyChannelsToConfig('public_sauna', cfg({ shop_visible: true }), ['shop']), cfg({ shop_visible: true }), 'muuttamaton oletus pysyy null-arvona');
  assert.deepEqual(S.applyChannelsToConfig('public_sauna', cfg({ shop_visible: false }), ['shop', 'link']), cfg({ shop_visible: true, channels: ['shop', 'link'] }));
  assert.deepEqual(S.applyChannelsToConfig('training', cfg({ shop_visible: true, channels: ['link'], fridge_sale: true }), ['link', 'qr']),
    cfg({ shop_visible: true, channels: ['link'], fridge_sale: true }), '121: tallennus samoilla kanavilla ei muuta shop_visibleä');
  assert.deepEqual(S.applyChannelsToConfig('training', cfg({}), []), cfg({ channels: [] }));
  // kierros: kanavat → kentät → kanavat
  for (const codes of [[], ['shop'], ['widget', 'link'], ['shop', 'widget', 'link', 'qr', 'pos'], ['link', 'pos']]) {
    for (const cat of ['public_sauna', 'training']) {
      assert.deepEqual(S.channelsFromConfig(cat, S.applyChannelsToConfig(cat, cfg({ shop_visible: true }), codes)), codes.filter((c) => S.MAPPED.includes(c)), `${cat} ${codes}`);
    }
  }
});

test('estot: passiivinen kanava, QR ikärajalle/alkoholille, pikakassa lahjakortille, konfiguraatio puuttuu', () => {
  const ch = (code, active = true) => ({ code, name: code, name_en: code, active });
  assert.equal(S.channelBlock(ch('shop'), { category: 'public_sauna' }), null);
  assert.equal(S.channelBlock(ch('widget', false), {}), 'channels_inactive');
  assert.equal(S.channelBlock(ch('widget', false), { selected: true }), null, 'valitun voi poistaa');
  assert.equal(S.channelBlock(ch('qr'), { ageRestricted: true }), 'channels_qr_blocked');
  assert.equal(S.channelBlock(ch('qr'), { alcohol: true, selected: true }), 'channels_qr_blocked');
  assert.equal(S.channelBlock(ch('pos'), { category: 'gift_card' }), 'channels_pos_blocked');
  assert.equal(S.channelBlock(ch('pos'), { category: 'gift_card', selected: true }), null);
  assert.equal(S.channelBlock(ch('shop'), { hasConfig: false }), 'vis_why_no_config');
  assert.equal(S.channelBlock(ch('gift_shop'), { hasConfig: false }), null);
  assert.equal(S.channelName({ code: 'shop', name: 'Verkkokauppa', name_en: 'Online shop' }, 'en'), 'Online shop');
  assert.deepEqual(S.sortCodes(['pos', 'shop', 'x'], MOCK_SALES_CHANNELS), ['shop', 'pos', 'x']);
});

test('editori: kanavat ovat oma askel; vanhat kentät eivät ole enää config-kenttiä', () => {
  assert.ok(!L.CONFIG_FIELDS.includes('shop_visible') && !L.CONFIG_FIELDS.includes('pos_enabled') && !L.CONFIG_FIELDS.includes('fridge_sale'));
  assert.ok(!L.CONFIG_FIELDS.includes('bookable'), 'Varattavissa verkossa -valinta poistui (Joonas 15.11. klo 10.38)');
  const base = L.baselineFromProduct(product(), { channels: ['shop', 'gift_shop'] });
  assert.deepEqual(base.channels, ['gift_shop', 'shop']);
  assert.equal('shop_visible' in base.config, false);
  assert.equal('bookable' in base.config, false);
  const cur = clone(base); cur.channels = ['pos', 'shop'];
  const d = L.diffSnapshots(base, cur);
  assert.equal(d.channels, true);
  assert.deepEqual(L.dirtyTabs(d), ['myynti']);
  const steps = plan(base, cur);
  assert.deepEqual(steps, [{ key: 'channels', label: 'Myyntikanavat', calls: [{ fn: 'admin_set_product_sales_channels', args: { p_product_id: 7, p_codes: ['pos', 'shop'] } }] }]);
  // järjestys ei ole muutos
  const same = clone(base); same.channels = ['shop', 'gift_shop'];
  assert.equal(L.isDirty(L.diffSnapshots(base, same)), false);
  // asetukset + kanavat: asetukset ensin (esim. ikärajan poisto ennen QR-myynnin lisäystä)
  const p2 = product({ config: { ...product().config, age_restricted: true } });
  const b2 = L.baselineFromProduct(p2, { channels: ['pos'] });
  const c2 = clone(b2); c2.config.age_restricted = false; c2.channels = ['pos', 'qr'];
  assert.deepEqual(plan(b2, c2).map((s) => s.key), ['config', 'channels']);
  // ikärajan lisäys + QR pois: kanavat ensin
  const b3 = L.baselineFromProduct(product(), { channels: ['qr'] });
  const c3 = clone(b3); c3.config.age_restricted = true; c3.channels = [];
  assert.deepEqual(plan(b3, c3).map((s) => s.key), ['channels', 'config']);
  // onnistunut askel kuitataan
  const next = L.rebase(b3, c3, ['channels']);
  assert.deepEqual(next.channels, []); assert.equal(next.qrStored, false);
  assert.deepEqual(L.diffSnapshots(next, c3).config, ['age_restricted']);
});

test('editori: kanavien latausvirhe → kanavia ei tallenneta (ei tyhjennetä vahingossa)', () => {
  const base = L.baselineFromProduct(product(), { channels: null });
  assert.equal(base.channels, null);
  const cur = clone(base); cur.channels = null; cur.config.sort_order = 11;
  assert.deepEqual(plan(base, cur).map((s) => s.key), ['config']);
});

test('mock: kanavat datasta, tallennus synkkaa vanhat kentät ja tarkistaa kuten palvelin', async () => {
  const mock = createAdminMock({ role: 'manager', delay: 0 });
  const r = await mock.rpc('admin_list_sales_channels');
  assert.deepEqual(r.channels.map((c) => c.code), ['shop', 'widget', 'link', 'pos', 'qr', 'gift_shop']);
  const all = await mock.rpc('admin_list_products');
  const towel = all.find((p) => p.category === 'product_rental' && p.config);
  const save = await mock.rpc('admin_set_product_sales_channels', { p_product_id: towel.id, p_codes: ['pos', 'shop'] });
  assert.deepEqual(save.channels, ['shop', 'pos']);
  const after = (await mock.rpc('admin_list_products')).find((p) => p.id === towel.id);
  assert.equal(after.config.shop_visible, true); assert.equal(after.config.pos_enabled, true); assert.equal(after.config.fridge_sale, false);
  assert.equal(after.config.bookable, true, 'julkinen kanava asettaa bookable = true kuten palvelin');
  assert.deepEqual((await mock.rpc('admin_list_sales_channels')).products[String(towel.id)], ['shop', 'pos']);
  await assert.rejects(() => mock.rpc('admin_set_product_sales_channels', { p_product_id: towel.id, p_codes: ['partner_x'] }), (e) => e.code === 'unknown_channel');
  const gift = all.find((p) => p.category === 'gift_card');
  await assert.rejects(() => mock.rpc('admin_set_product_sales_channels', { p_product_id: gift.id, p_codes: ['pos'] }), (e) => e.code === 'not_counter_product');
  const staff = createAdminMock({ role: 'staff', perms: ['bookings.manage'] });
  await assert.rejects(() => staff.rpc('admin_set_product_sales_channels', { p_product_id: towel.id, p_codes: [] }), (e) => e.code === 'forbidden');
  assert.ok((await staff.rpc('admin_list_sales_channels')).channels.length === 6, 'henkilökunta näkee kanavat');
});

test('näkymä: monivalinta Myynti ja näkyvyys -välilehdellä, kanavat datasta, Piilotettu erillinen; vanha kolmen valinnan malli ei palaa', () => {
  const ed = read('../admin/views/product-editor.js');
  assert.match(ed, /rpc\('admin_list_sales_channels'\)/);
  assert.match(ed, /'data-testid': 'product-channels'/);
  assert.match(ed, /`product-channel-\$\{code\}`/);
  assert.match(ed, /channelName\(ch, lang\)/, 'nimi tulee datasta');
  assert.match(ed, /chk\('hidden', T\('vis_hidden'\), !base\.product\.active\)/);
  assert.match(ed, /active: !ctl\.hidden\.checked/);
  assert.match(ed, /channels: T\('channels_title'\)/);
  assert.doesNotMatch(ed, /chk\('(shop_visible|pos_enabled|fridge_sale|bookable)'/, 'vanhat valintaruudut korvattu kanavilla');
  assert.doesNotMatch(ed, /Varattavissa verkossa|ctl\.bookable/, 'Varattavissa verkossa -valinta poistui; julkiset kanavat korvaavat sen');
  assert.match(ed, /T\('channels_public_hint'\)/);
  assert.doesNotMatch(ed, /vis_online|vis_internal|visibilityPlan|product-visibility/, '#388:n kolmen vaihtoehdon malli ei palaa');
  assert.doesNotMatch(ed, /['"](shop|widget|link|pos|qr|gift_shop)['"]\s*:\s*['"][A-ZÄÖ]/, 'kanavien nimiä ei ole kovakoodattu');
  const logic = read('../admin/product-editor-logic.js');
  assert.match(logic, /fn: 'admin_set_product_sales_channels'/);
});

test('tekstit: pending-import-174 = sanakirja, FI+EN, ei hintoja; käyttämättömät 166-avaimet eivät ole sanakirjassa', async () => {
  const { PRODUCT_TEXTS } = await import(href('../admin/product-texts.js'));
  const rows = JSON.parse(read('../../content/site-texts.pending-import-174.json'));
  assert.equal(rows.length, 30);
  for (const r of rows) {
    assert.equal(PRODUCT_TEXTS[r.lang][r.key], r.text, r.key);
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain'); assert.ok(r.text.length <= r.max_len);
    assert.doesNotMatch(r.text, /\d+[,.]?\d*\s*€|alv\s*\d/i, 'ei hintoja tai ALV-kantoja');
  }
  for (const k of ['channels_title', 'channels_lead', 'channels_none', 'channels_inactive', 'channels_load_error', 'channels_qr_blocked', 'channels_pos_blocked', 'channels_gift_hint', 'channels_public_hint']) {
    for (const lang of ['fi', 'en']) assert.ok(rows.some((r) => r.key === `ui.admin.product.${k}` && r.lang === lang), `${k} ${lang}`);
  }
  const reused = ['vis_hidden', 'vis_hidden_hint', 'vis_note', 'vis_why_no_config', 'vis_why_lifecycle_old', 'vis_why_no_image'];
  for (const k of reused) assert.ok(rows.some((r) => r.key === `ui.admin.product.${k}` && /tuonnissa 166/.test(r.reason)), k);
  for (const k of ['vis_online', 'vis_internal', 'vis_fix', 'vis_ch_shop', 'vis_step_channels']) assert.equal(PRODUCT_TEXTS.fi[`ui.admin.product.${k}`], undefined, k);
});
