// HALL-TUOTTEET-02: tuotteen näkyvyys yhtenä valintana (online / internal / hidden). Ei verkkoa eikä tietokantaa.
// Joonas 15.11.2026: "Vain kassalla ja hallinnassa" poistaa tuotteen KAIKISTA myyntikanavista (verkkokauppa, upotus, suora linkki,
// lisämyynti, QR-myynti, lahjakorttikauppa) ja näkyy vain kassalla ja hallinnassa.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { factsFromProduct, factsFromEvent, modeOf, explain, visibilityPlan, applyPlan, planIsEmpty, saveVisibility, openChannels, packagesFor } from '../admin/product-visibility.js';
import * as L from '../admin/product-editor-logic.js';
import { isOnline } from '../admin/product-visibility.js';
import { VISIBILITY_TEXTS } from '../admin/product-visibility-texts.js';
import { createAdminMock } from '../admin/options-mock.js';

const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), 'utf8');
const prod = (over = {}, cfg = {}) => ({ id: 1, name: 'Testi', category: 'ritual', active: true,
  config: { bookable: true, shop_visible: true, lifecycle: 'current', resource_class: 'resourced', sale_kind: 'other', duration_minutes: 90, image_path: 'a.jpg', ...cfg }, ...over });
const codes = (items) => items.map((x) => x.code);

test('tila johdetaan tallennetuista arvoista', () => {
  assert.equal(modeOf(factsFromProduct(prod())), 'online');
  assert.equal(modeOf(factsFromProduct(prod({ active: false }))), 'hidden');
  assert.equal(modeOf(factsFromProduct(prod({}, { shop_visible: false }))), 'internal');
  assert.equal(modeOf(factsFromProduct(prod({}, { bookable: false }))), 'internal');
  assert.equal(modeOf(factsFromProduct(prod({ config: null }))), 'internal');
  // koulutus: suora linkki riittää, shop_visible = false on normaali
  assert.equal(modeOf(factsFromProduct(prod({ category: 'training' }, { shop_visible: false, channels: ['widget', 'link'] }))), 'online');
  assert.equal(modeOf(factsFromProduct(prod({ category: 'training' }, { shop_visible: false }))), 'internal');
});

test('online-tila vastaa vanhaa Verkossa-merkkiä (isOnline), kun mikään ei estä', () => {
  for (const p of [prod(), prod({ active: false }), prod({}, { shop_visible: false }), prod({}, { channels: ['shop'] }), prod({}, { lifecycle: 'old' }),
    prod({ category: 'training' }, { shop_visible: false, channels: ['link'] }), prod({ category: 'training' }, { shop_visible: false })]) {
    const f = factsFromProduct(p);
    const blocked = explain(f, modeOf(f), { saved: true }).some((x) => x.level === 'block');
    assert.equal(modeOf(f) === 'online' && !blocked, isOnline(p), JSON.stringify(p));
  }
});

test('piilotus yhdellä valinnalla: active = false ja kaikki myyntikanavat pois', () => {
  const pl = visibilityPlan(factsFromProduct(prod()), 'hidden');
  assert.deepEqual(pl, { product: { active: false }, config: { shop_visible: false }, channels: [], packages: null });
  assert.equal(isOnline(applyToProduct(prod(), pl)), false);
});
function applyToProduct(p, pl) {
  return { ...p, active: pl.product ? pl.product.active : p.active, config: { ...p.config, ...(pl.config || {}), ...(pl.channels ? { channels: pl.channels } : {}) } };
}

test('internal poistaa kaupan listan ja myyntikanavat, mutta jättää varattavuuden (hallinnan varaukset)', () => {
  const pl = visibilityPlan(factsFromProduct(prod({}, { channels: ['shop', 'widget'] })), 'internal');
  assert.deepEqual(pl, { product: null, config: { shop_visible: false }, channels: [], packages: null });
  const after = applyToProduct(prod({}, { channels: ['shop', 'widget'] }), pl);
  assert.equal(isOnline(after), false);
  assert.equal(after.config.bookable, true);
  assert.equal(modeOf(factsFromProduct(after)), 'internal');
});

test('online asettaa kaiken johdonmukaisesti, myös piilotetusta tuotteesta', () => {
  const p = prod({ active: false }, { bookable: false, shop_visible: false, channels: [] });
  const pl = visibilityPlan(factsFromProduct(p), 'online');
  assert.deepEqual(pl, { product: { active: true }, config: { bookable: true, shop_visible: true }, channels: ['shop'], packages: null });
  assert.equal(isOnline(applyToProduct(p, pl)), true);
  // koulutus: lisätään suora linkki, shop_visible ennallaan, widget säilyy
  const t = prod({ category: 'training' }, { shop_visible: false, channels: ['widget'] });
  const tp = visibilityPlan(factsFromProduct(t), 'online');
  assert.deepEqual(tp, { product: null, config: null, channels: ['widget', 'link'], packages: null });
  assert.equal(isOnline(applyToProduct(t, tp)), true);
});

test('suunnitelma on tyhjä, kun tila on jo valittu', () => {
  for (const m of ['online', 'internal', 'hidden']) {
    const f = applyPlan(factsFromProduct(prod()), visibilityPlan(factsFromProduct(prod()), m));
    assert.ok(planIsEmpty(visibilityPlan(f, m)), m);
  }
});

test('selitys näkyy, kun valittu tila ei toteudu', () => {
  assert.deepEqual(explain(factsFromProduct(prod()), 'online'), []);
  assert.deepEqual(codes(explain(factsFromProduct(prod({}, { duration_minutes: null })), 'online')), ['duration']);
  assert.deepEqual(codes(explain(factsFromProduct(prod({}, { lifecycle: 'old' })), 'online')), ['lifecycle_old']);
  assert.deepEqual(codes(explain(factsFromProduct(prod({}, { image_path: null })), 'online')), ['no_image']);
  assert.equal(explain(factsFromProduct(prod({}, { image_path: null })), 'online')[0].level, 'warn');
  assert.deepEqual(codes(explain(factsFromProduct(prod({ config: null })), 'online')), ['no_config', 'no_image']);
  // slots-tuotteella (yleinen vuoro) kesto ei ole pakollinen
  assert.deepEqual(explain(factsFromProduct(prod({}, { resource_class: 'shift', sale_kind: 'slots', duration_minutes: null })), 'online'), []);
  // tallennettu tila: kauppakanava puuttuu vaikka asetukset ovat päällä
  assert.deepEqual(codes(explain(factsFromProduct(prod({}, { channels: ['widget'] })), 'online', { saved: true })), ['channel_missing']);
  assert.deepEqual(explain(factsFromProduct(prod({}, { channels: ['widget'] })), 'online'), []);   // tallennus lisää kanavan
  // tallennettu "vain kassalla", mutta upotus on vielä päällä → ei toteudu
  const left = explain(factsFromProduct(prod({}, { shop_visible: false, channels: ['shop', 'widget'], pos_enabled: true })), 'internal', { saved: true });
  assert.deepEqual(left.map((x) => [x.code, x.level, x.channels]), [['still_on_sale', 'block', ['widget']]]);
  assert.deepEqual(explain(factsFromProduct(prod({}, { shop_visible: false, channels: [], pos_enabled: true })), 'internal', { saved: true }), []);
  assert.deepEqual(explain(factsFromProduct(prod({ active: false })), 'hidden', { saved: true }), []);
});

test('tapahtuma: myynti suljettu ja ei tulevia kertoja selitetään', () => {
  const ev = { product_id: 31, category: 'event', active: true, bookable: true, shop_visible: true, lifecycle: 'current', channels: ['shop'], duration_minutes: 180, image_path: 'k.jpg', sale_enabled: false, upcoming: 0 };
  const f = factsFromEvent(ev);
  assert.equal(modeOf(f), 'online');
  assert.deepEqual(codes(explain(f, 'online', { saved: true })), ['sale_closed', 'no_occurrences']);
  assert.deepEqual(explain(factsFromEvent({ ...ev, sale_enabled: true, upcoming: 2 }), 'online', { saved: true }), []);
});

test('saveVisibility: piilotus ensin, näkyväksi tekeminen viimeisenä; virhe kertoo vaiheen', async () => {
  const calls = [];
  const rpc = async (name) => { calls.push(name); };
  await saveVisibility(rpc, 1, factsFromProduct(prod({ active: false }, { bookable: false, shop_visible: false, channels: [] })), 'online');
  assert.deepEqual(calls, ['admin_update_product_config', 'admin_event_set_channels', 'admin_update_product']);
  calls.length = 0;
  await saveVisibility(rpc, 1, factsFromProduct(prod()), 'hidden');
  assert.deepEqual(calls, ['admin_update_product', 'admin_update_product_config', 'admin_event_set_channels']);
  await assert.rejects(saveVisibility(async (n) => { if (n === 'admin_event_set_channels') throw new Error('x'); }, 1, factsFromProduct(prod({ active: false }, { bookable: false, channels: [] })), 'online'), (e) => e.step === 'channels' && e.done.includes('config'));
});

test('kokeilutila: tallennus muuttaa tuotelistan Verkossa-tilaa ja tapahtumien tilaa', async () => {
  const m = createAdminMock({ role: 'admin' });
  const get = async (id) => (await m.rpc('admin_list_products')).find((p) => p.id === id);
  let p = await get(7);
  assert.equal(modeOf(factsFromProduct(p)), 'online');
  await saveVisibility(m.rpc, 7, factsFromProduct(p), 'internal');
  p = await get(7);
  assert.equal(modeOf(factsFromProduct(p)), 'internal'); assert.equal(isOnline(p), false);
  await saveVisibility(m.rpc, 7, factsFromProduct(p), 'hidden');
  assert.equal((await get(7)).active, false);
  await saveVisibility(m.rpc, 7, factsFromProduct(await get(7)), 'online');
  assert.equal(isOnline(await get(7)), true);
  // tapahtumatuote: Tapahtumat-näkymän rivi seuraa
  await saveVisibility(m.rpc, 32, factsFromProduct(await get(32)), 'hidden');
  assert.equal((await m.rpc('admin_event_list', {})).find((e) => e.product_id === 32)?.active ?? false, false);
});

test('peruskäyttäjä ei voi tallentaa (catalog.edit)', async () => {
  const m = createAdminMock({ role: 'staff', perms: ['shifts.view_all'] });
  const p = (await m.rpc('admin_list_products')).find((x) => x.id === 7);
  await assert.rejects(saveVisibility(m.rpc, 7, factsFromProduct(p), 'hidden'));
});

test('Vain kassalla (Joonas 15.11.2026): kaikki myyntikanavat pois – kauppa, upotus, suora linkki, lisämyynti, QR-myynti, lahjakorttikauppa', () => {
  const pk = [
    { code: 'open', name: 'Avoin', active: true, kb_product_id: 38, items: [] },
    { code: 'a', name: 'Paketti A', active: true, kb_product_id: null, items: [{ kb_product_id: 1 }] },
    { code: 'b', name: 'Paketti B', active: true, kb_product_id: null, items: [{ kb_product_id: 9 }, { kb_product_id: 1 }] },
    { code: 'c', name: 'Paketti C', active: false, kb_product_id: null, items: [{ kb_product_id: 1 }] },
    { code: 'd', name: 'Lahjakorttituote', active: true, kb_product_id: 1, items: null },
  ];
  assert.deepEqual(packagesFor(1, pk).map((x) => x.code), ['a', 'b', 'c', 'd']);
  assert.equal(packagesFor(1, null), null);
  const p = prod({}, { channels: ['shop', 'widget', 'link'], fridge_sale: true, pos_enabled: true });
  const f = factsFromProduct(p, { packages: pk });
  assert.deepEqual(openChannels(f), ['shop', 'widget', 'link', 'fridge', 'gift_shop']);
  const pl = visibilityPlan(f, 'internal');
  assert.deepEqual(pl, { product: null, config: { shop_visible: false, fridge_sale: false }, channels: [], packages: ['a', 'b', 'd'] });
  const g = applyPlan(f, pl);
  assert.deepEqual(openChannels(g), []);
  assert.equal(g.bookable, true, 'varattavuus jää hallinnan ja kassan varauksia varten');
  assert.equal(modeOf(g), 'internal');
  assert.deepEqual(explain(g, 'internal', { saved: true }), []);
  // ennen tallennusta kerrotaan, mitkä paketit poistuvat lahjakorttikaupasta ja että QR-myynti suljetaan
  assert.deepEqual(explain(f, 'internal').map((x) => [x.code, x.vars?.names]), [['packages_off', 'Paketti A, Paketti B, Lahjakorttituote'], ['fridge_off', undefined]]);
  // piilotus sulkee samat kanavat
  assert.deepEqual(visibilityPlan(f, 'hidden'), { product: { active: false }, config: { shop_visible: false, fridge_sale: false }, channels: [], packages: ['a', 'b', 'd'] });
  // piilotettu tuote: vain lahjakorttipaketti jää myyntiin, koska paketit eivät katso tuotteen tilaa
  const hiddenLeft = explain(factsFromProduct(prod({ active: false }, { channels: ['shop'] }), { packages: pk }), 'hidden', { saved: true });
  assert.deepEqual(hiddenLeft.map((x) => [x.code, x.channels]), [['still_on_sale', ['gift_shop']]]);
  // verkkoon palautus ei avaa paketteja eikä QR-myyntiä itsestään: pois myynnistä olevat paketit kerrotaan
  const back = explain(g, 'online');
  assert.deepEqual(back.map((x) => x.code), ['packages_inactive']);
  assert.match(back[0].vars.names, /Paketti A/);
  assert.equal(visibilityPlan(g, 'online').packages, null);
});

test('Vain kassalla: koulutuksen kaupan lista ja kanavat pois, kassavalinta pois → huomautus', () => {
  const t = prod({ category: 'training' }, { shop_visible: true, channels: ['widget', 'link'], pos_enabled: false });
  const pl = visibilityPlan(factsFromProduct(t), 'internal');
  assert.deepEqual(pl.config, { shop_visible: false });   // lisämyynti (_upsell_options) katsoo vain kaupan listaa
  assert.deepEqual(pl.channels, []);
  assert.deepEqual(explain(factsFromProduct(t), 'internal').map((x) => x.code), ['pos_off']);
  // tapahtuma kauppakanavalla näkyy tapahtumalistassa (public_events) ilman kaupan listaakin
  assert.deepEqual(openChannels(factsFromEvent({ category: 'event', active: true, bookable: true, shop_visible: false, channels: ['shop'] })), ['shop']);
});

test('tuote-editori: näkyvyys on oma osansa tallennuspalkissa (piilotus ensin, verkkoon viimeisenä)', () => {
  const p = prod({ price: 5, vat_rate: 25.5, price_text: '5,00 €' }, { pos_enabled: true, pos_sort: 100, sort_order: 1, min_persons: 1, max_persons: null, fridge_sale: false, age_restricted: false });
  const base = L.baselineFromProduct(p);
  assert.equal(base.visibility, 'online');
  const labels = { product: 'P', training: 'T', config: 'C', image: 'I', suggestions: 'S', visibility: 'V', variant: () => 'X' };
  const cur = JSON.parse(JSON.stringify(base));
  cur.visibility = 'internal'; cur.product.name = 'Uusi';
  const d = L.diffSnapshots(base, cur);
  assert.equal(d.visibility, true); assert.ok(L.isDirty(d)); assert.deepEqual(L.dirtyTabs(d), ['perustiedot', 'myynti']);
  const steps = L.buildSavePlan({ productId: 1, base, cur, labels });
  assert.deepEqual(steps.map((x) => x.key), ['visibility', 'product']);
  assert.equal(steps[0].mode, 'internal'); assert.equal(steps[0].custom, true);
  const back = { ...JSON.parse(JSON.stringify(base)), visibility: 'internal' };
  const cur2 = { ...JSON.parse(JSON.stringify(back)), visibility: 'online' };
  cur2.config.pos_sort = 5;
  assert.deepEqual(L.buildSavePlan({ productId: 1, base: back, cur: cur2, labels }).map((x) => x.key), ['config', 'visibility']);
  assert.equal(L.rebase(base, cur, ['visibility']).visibility, 'internal');
  assert.equal(L.rebase(base, cur, ['product']).visibility, 'online', 'epäonnistunut näkyvyys jää muutokseksi');
});

test('kokeilutila: Vain kassalla ottaa tuotteen lahjakorttipaketit pois myynnistä', async () => {
  const m = createAdminMock({ role: 'admin' });
  const pk = async () => (await m.rpc('admin_list_gift_card_packages')).packages;
  const p = (await m.rpc('admin_list_products')).find((x) => x.id === 7);
  await saveVisibility(m.rpc, 7, factsFromProduct(p, { packages: await pk() }), 'internal');
  assert.equal((await pk()).find((x) => x.code === 'saunarituaali_2').active, false);
  assert.equal((await pk()).find((x) => x.code === 'entry_2').active, true, 'muiden tuotteiden paketit ennallaan');
  const after = (await m.rpc('admin_list_products')).find((x) => x.id === 7);
  assert.deepEqual(openChannels(factsFromProduct(after, { packages: await pk() })), []);
});

test('lähde: tuote-editorissa yksi Näkyvyys-valinta, ei vanhoja päällekkäisiä valintoja; tapahtumayhteenveto paikallaan', () => {
  const src = read('admin/views/product-editor.js');
  assert.doesNotMatch(src, /Aktiivinen \(näkyy kb:ssä\)/);
  assert.doesNotMatch(src, /Varattavissa verkossa/);
  assert.doesNotMatch(src, /Näkyy kaupan listassa/);
  assert.doesNotMatch(src, /chk\('(active|bookable|shop_visible)'/);
  assert.match(src, /data-testid': 'product-visibility'/);
  assert.match(src, /saveVisibility\(rpc, p\.id, facts\(\), s\.mode\)/);
  assert.match(src, /admin_list_gift_card_packages/);
  assert.match(read('admin/views/events.js'), /event-visibility/);
  // YHT-07: ei kovakoodattuja värejä näkyvyyden tyyleissä
  const css = read('admin/admin.css').split('\n').filter((l) => /\.vis-(opt|why)/.test(l)).join('\n');
  assert.doesNotMatch(css, /#[0-9a-fA-F]{3,6}\b|rgb\(/);
});

test('pending-import-166 vastaa sanakirjaa, FI+EN, normal, paikkamerkit ilmoitettu, ei hintoja', () => {
  const rows = JSON.parse(read('../content/site-texts.pending-import-166.json'));
  const keys = new Set();
  for (const r of rows) {
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain');
    assert.deepEqual(r.placeholders, [...new Set(r.text.match(/\{\{var:\w+\}\}/g) || [])], r.key);
    assert.match(r.key, /^ui\.admin\.product\.vis_/);
    assert.equal(r.text, VISIBILITY_TEXTS[r.lang][r.key], r.key);
    assert.ok(r.text.length <= r.max_len);
    assert.doesNotMatch(r.text, /\d|€|@|https?:/);
    keys.add(`${r.key}|${r.lang}`);
  }
  for (const lang of ['fi', 'en']) for (const k of Object.keys(VISIBILITY_TEXTS[lang])) assert.ok(keys.has(`${k}|${lang}`), k);
  assert.equal(keys.size, Object.keys(VISIBILITY_TEXTS.fi).length * 2);
  assert.deepEqual(Object.keys(VISIBILITY_TEXTS.fi), Object.keys(VISIBILITY_TEXTS.en));
  // päätöksen sanamuoto
  assert.match(VISIBILITY_TEXTS.fi['ui.admin.product.vis_internal_hint'], /kaikista myyntikanavista/);
  assert.match(VISIBILITY_TEXTS.fi['ui.admin.product.vis_internal_hint'], /lahjakorttikauppa/);
  assert.match(VISIBILITY_TEXTS.en['ui.admin.product.vis_internal_hint'], /all sales channels/);
});

test('qr_hint (v3): viittaa Tuotteet-sivuun', async () => {
  const { PRODUCT_TEXTS } = await import('../admin/product-texts.js');
  assert.equal(PRODUCT_TEXTS.fi['ui.admin.product.qr_hint'], 'QR-koodi tehdään Tuotteet-sivun osiossa QR-koodin tulostus.');
  assert.equal(PRODUCT_TEXTS.en['ui.admin.product.qr_hint'], 'The QR code is created in the QR code printing section of the Products page.');
});
