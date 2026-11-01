// Yritysten vuorokalenteri (audience business) näyttää vain yritysten savusaunavuoron ja jälkilöylyt.
// public_events (Kekri, joulusaunat, perinnesaunotusilta) ei tule listalle, Tapahtumat-chippiin eikä päivänäkymään.
// Kuluttajan kauppa yhdistää tapahtumat kuten ennen. Ei verkkoa eikä tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { productsForAudience, chipsFor, kindOf, DAY_KIND_ORDER } from '../shop/src/catalog-kind.js';
import { missingEventProducts } from '../shop/src/event-full.js';
import { hasWaitlistSlots } from '../shop/src/waitlist-logic.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (rel) => readFileSync(join(root, rel), 'utf8');
const NOW = Date.parse('2026-10-30T12:00:00Z');
const tmp = mkdtempSync(join(tmpdir(), 'yritys-kalenteri-'));
cpSync(new URL('../shop/src/', import.meta.url), tmp, { recursive: true });
cpSync(new URL('../shared/sb.js', import.meta.url), join(tmp, 'sb.js'));
const { createShopMock } = await import(pathToFileURL(join(tmp, 'shop-mock.js')).href);

const shift = (id, slug, name) => ({ id, slug, name, category: 'corporate', audience: 'business', sale_kind: 'private_shift', booking_kind: 'rules' });
const BUSINESS = [
  shift(48, 'saunavuoro-yrityksille', 'Savusaunavuoro yrityksille'),
  shift(49, 'jalkiloylyt-yrityksille', 'Savusaunan jälkilöylyt yrityksille'),
];
const pub = { id: 1, slug: 'yleinen', name: 'Yleinen saunavuoro', category: 'public_sauna', sale_kind: 'public_shift', booking_kind: 'rules' };
const occ = (start, status) => ({ status, starts_at: start, ends_at: start.replace('T14', 'T17'), rule_id: 1 });
const ev = (id, slug, name, start, status = 'available') => ({
  product_id: id, slug, name, category: 'event',
  occurrences: [occ(start, status)],
});
const PUBLIC_EVENTS = [
  ev(9101, 'kekri', 'Sipoonjoen Kekri', '2026-11-14T14:00:00Z', 'full'),
  ev(32, 'joulusaunat', 'Joulusaunat', '2026-12-13T14:00:00Z'),
  ev(31, 'perinnesaunotusilta', 'Perinnesaunotusilta', '2026-11-20T14:00:00Z'),
];

const slot = (status = 'available') => ({ status, starts_at: '2026-11-02T12:00:00Z' });

/** Sama päätös kuin shop.js viewList: yrityksille tyhjä public_events, sitten suodatus. */
function listFor(audience, catalog, events, ask = null) {
  const fetched = audience === 'business' ? [] : events;
  const next = catalog.slice();
  for (const p of missingEventProducts(next, fetched, NOW)) next.push(p);
  const stored = audience === 'business' ? productsForAudience(next, 'business') : next;
  const cat = productsForAudience([...stored], audience);
  const kinds = chipsFor(cat).filter((x) => audience !== 'business' || x !== 'tapahtuma');
  const k = ask && kinds.includes(ask) ? ask : 'all';
  const list = cat.filter((p) => k === 'all' || kindOf(p) === k);
  return { slugs: list.map((p) => p.slug), kinds, k };
}

function dayFor(audience, catalog, slotsById) {
  const products = productsForAudience(catalog, audience);
  const prods = products.map((p) => [p, (slotsById[p.id] || []).map((r) => ({ r }))]).filter(([, rs]) => hasWaitlistSlots(rs));
  const groups = DAY_KIND_ORDER.map((k) => [k, prods.filter(([p]) => kindOf(p) === k)]).filter(([, g]) => g.length);
  const weekFree = products.flatMap((p) => (slotsById[p.id] || []).filter((r) => r.status === 'available'));
  return { ids: prods.map(([p]) => p.id), groups: groups.map(([k]) => k), free: weekFree.length };
}

test('yrityskalenteri ei yhdistä Kekriä, joulusaunoja eikä perinnesaunotusiltaa, eikä näytä Tapahtumat-chippiä', () => {
  const leaked = missingEventProducts(BUSINESS, PUBLIC_EVENTS, NOW).map((p) => p.slug).sort();
  assert.deepEqual(leaked, ['joulusaunat', 'kekri', 'perinnesaunotusilta'], 'ilman suojaa public_events täyttäisi kalenterin');
  const shown = listFor('business', BUSINESS, PUBLIC_EVENTS, 'tapahtuma');
  assert.deepEqual(shown.slugs, ['saunavuoro-yrityksille', 'jalkiloylyt-yrityksille']);
  assert.deepEqual(shown.kinds, ['all', 'yksityinen']);
  assert.equal(shown.kinds.includes('tapahtuma'), false);
  assert.equal(shown.k, 'all', 'osoite ?k=tapahtuma ei avaa tapahtumalistaa');
  const rows = [...BUSINESS, ...missingEventProducts(BUSINESS, PUBLIC_EVENTS, NOW)];
  assert.equal(productsForAudience(rows, 'business').some((p) => p.category === 'event'), false);
  assert.equal(rows.length, 5, 'suodatus ei muuta alkuperäistä taulukkoa');
});

test('kuluttajan kauppa yhdistää tapahtumat ja pitää Tapahtumat-chipin', () => {
  const catalog = [pub];
  assert.equal(productsForAudience(catalog, 'consumer'), catalog);
  assert.equal(productsForAudience(catalog, undefined), catalog);
  const shown = listFor('consumer', catalog, PUBLIC_EVENTS);
  assert.deepEqual(shown.slugs, ['yleinen', 'kekri', 'perinnesaunotusilta', 'joulusaunat']);
  assert.ok(shown.kinds.includes('tapahtuma'));
  const only = listFor('consumer', catalog, PUBLIC_EVENTS, 'tapahtuma');
  assert.equal(only.k, 'tapahtuma');
  assert.deepEqual(only.slugs, ['kekri', 'perinnesaunotusilta', 'joulusaunat']);
});

test('päivänäkymä ja viikkoliuska: yrityksille vain omat vuorot, kuluttajalle myös tapahtumat', () => {
  const catalog = [...BUSINESS, ...missingEventProducts([], PUBLIC_EVENTS, NOW)];
  const slots = { 48: [slot()], 49: [slot('full')], 9101: [slot('full')], 32: [slot()], 31: [slot()] };
  const biz = dayFor('business', catalog, slots);
  assert.deepEqual(biz.ids, [48, 49]);
  assert.deepEqual(biz.groups, ['yksityinen']);
  assert.equal(biz.free, 1, 'viikkoliuska ei laske tapahtuman vapaita paikkoja');
  const shop = dayFor('consumer', [pub, ...catalog.filter((p) => p.category === 'event')], { 1: [slot()], ...slots });
  assert.deepEqual(shop.ids, [1, 9101, 31, 32]);
  assert.deepEqual(shop.groups, ['yleinen', 'tapahtuma']);
});

test('mock: public_catalog_for(business) on täsmälleen kaksi yritysvuoroa, myös events=1', async () => {
  const plain = createShopMock({ storage: null, now: () => NOW });
  assert.deepEqual((await plain.rpc('public_catalog_for', { p_audience: 'business' })).map((p) => p.slug), ['saunavuoro-yrityksille', 'jalkiloylyt-yrityksille']);
  const consumer = await plain.rpc('public_catalog_for', { p_audience: 'consumer' });
  assert.equal(consumer.some((p) => p.audience === 'business' || p.category === 'event'), false);
  const events = await plain.rpc('public_events', { p_from: '2026-10-30', p_channel: 'shop' });
  const biz = await plain.rpc('public_catalog_for', { p_audience: 'business' });
  assert.equal(missingEventProducts(biz, [], NOW).length, 0);
  assert.ok(missingEventProducts(biz, events, NOW).some((p) => p.slug === 'kekri-taynna'), 'mockin public_events vuotaisi Kekrin, jos se yhdistettäisiin');
  const from = '2026-10-01', to = '2026-12-31';
  const slots = await plain.rpc('public_availability_all', { p_from: from, p_to: to, p_audience: 'business' });
  assert.ok(slots.length >= 2);
  assert.deepEqual([...new Set(slots.map((r) => r.product_id))].sort(), [48, 49]);
  const consumerSlots = await plain.rpc('public_availability_all', { p_from: from, p_to: to, p_audience: 'consumer' });
  assert.equal(consumerSlots.some((r) => r.product_id === 48 || r.product_id === 49), false);
  const had = Object.getOwnPropertyDescriptor(globalThis, 'location');
  Object.defineProperty(globalThis, 'location', { value: { search: '?mock=1&events=1&priv=1' }, configurable: true, writable: true });
  try {
    const flagged = createShopMock({ storage: null, now: () => NOW });
    assert.deepEqual((await flagged.rpc('public_catalog_for', { p_audience: 'business' })).map((p) => p.slug), ['saunavuoro-yrityksille', 'jalkiloylyt-yrityksille']);
    const open = await flagged.rpc('public_catalog_for', { p_audience: 'consumer' });
    assert.ok(open.some((p) => p.slug === 'perinnesaunotusilta'), 'kuluttajan events=1 ennallaan');
    assert.ok(open.some((p) => p.slug === 'oma-saunavuoro'));
    assert.equal(open.some((p) => p.slug === 'saunavuoro-yrityksille'), false);
  } finally {
    if (had) Object.defineProperty(globalThis, 'location', had);
    else delete globalThis.location;
  }
});

test('shop.js: yritysyleisö ei hae public_events, piilottaa chipin ja suodattaa päivänäkymän', () => {
  const shop = read('booking/shop/src/shop.js');
  const list = shop.slice(shop.indexOf('async function viewList'), shop.indexOf('const annualOffer'));
  assert.match(list, /const events = S\.audience === 'business' \? \[\] : await publicEvents\(\)/);
  assert.match(list, /missingEventProducts\(state\.catalog, events\)/);
  assert.match(list, /productsForAudience\(/);
  assert.match(list, /chipsFor\(cat\)\.filter\(\(x\) => S\.audience !== 'business' \|\| x !== 'tapahtuma'\)/);
  const day = shop.slice(shop.indexOf('async function viewDay'), shop.indexOf('async function viewProduct'));
  assert.match(day, /productsForAudience\(state\.catalog, 'business'\)/);
  assert.match(day, /listedProducts\(productsForAudience\(state\.catalog, S\.audience\)\)\.map/);
  assert.match(shop, /const products = listedProducts\(productsForAudience\(state\.catalog, S\.audience\)\)/);
  assert.match(shop, /catalog: listedProducts\(productsForAudience\(state\.catalog, S\.audience\)\)/);
  const product = shop.slice(shop.indexOf('async function viewProduct'), shop.indexOf('function spotBadge'));
  assert.match(product, /productsForAudience\(state\.catalog, S\.audience\)\.find/);
  assert.match(product, /S\.audience === 'business' \? null : findEvent\(await publicEvents\(\), slug\)/);
  assert.match(shop, /findEvent\(await publicEvents\(\), slug\)/);
  assert.match(shop, /audience === 'business' \? \[\] : split\.treatments/);
  assert.match(read('.github/workflows/pages.yml'), /node --test booking\/tests\/yritys-kalenteri-tapahtumat\.test\.mjs/);
  assert.equal(read('booking/shop/src/catalog-kind.js').includes('export function productsForAudience'), true);
});
