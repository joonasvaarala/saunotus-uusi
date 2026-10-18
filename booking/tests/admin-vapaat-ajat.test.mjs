// Hallinnan "Vapaat ajat" -paneeli (admin/views/availability.js): tuotteet johdetaan product_config.public_slots-kentästä (ei kovakoodattua id-listaa),
// kb 7 (Saunarituaali ja savusaunavuoro, 120 min) toimii: paneeli, pituus ja pakettiaikajana. DOM-käyttäytyminen: scripts/e2e-admin-vapaat-ajat.mjs.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, mkdtempSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const imp = (p) => import(pathToFileURL(join(root, p)));
const read = (p) => readFileSync(join(root, p), 'utf8');
const PROD61 = JSON.parse(read('tests/fixtures/prod-catalog-61.json'));   // tuotannon public_catalog() booking_61:n jälkeen (vain luku)
const TL = await imp('admin/package-timeline.js');
const { createAdminMock, helIso } = await imp('admin/options-mock.js');
// kaupan treatments.js importoi ./sb.js:n → kopioidaan väliaikaishakemistoon kuten saunarituaali.test.mjs
const tmp = mkdtempSync(join(tmpdir(), 'admin-vapaat-'));
cpSync(join(root, 'shop/src'), tmp, { recursive: true }); cpSync(join(root, 'shared/sb.js'), join(tmp, 'sb.js'));
const shopTl = await import(pathToFileURL(join(tmp, 'treatments.js')));

// Tuotannon admin_list_products-vastauksen config-kentät (SELECT 18.10.2026, kb.products + booking.product_config) – vain tässä testattavat kentät.
const PROD = [
  { id: 7, config: { lifecycle: 'current', public_slots: true, public_weekdays: [6, 7], duration_minutes: 120, max_persons: 6 } },
  { id: 8, config: { lifecycle: 'current', public_slots: true, public_weekdays: [6, 7], duration_minutes: 20, max_persons: 6 } },
  { id: 10, config: { lifecycle: 'current', public_slots: true, public_weekdays: null, duration_minutes: 60, max_persons: 4 } },
  { id: 11, config: { lifecycle: 'current', public_slots: true, public_weekdays: null, duration_minutes: 120, max_persons: 4 } },
  { id: 12, config: { lifecycle: 'current', public_slots: true, public_weekdays: null, duration_minutes: 180, max_persons: 4 } },
  { id: 3, config: { lifecycle: 'current', public_slots: false, sale_kind: 'slots' } },
  { id: 9, config: { lifecycle: 'current', public_slots: false } },
];

// availability.js importoi ../sb.js:n (hallinnassa osoitteesta /admin/sb.js), joten Nodessa moduuli luetaan lähdetekstinä ja isSlotProduct arvioidaan siitä.
const src = read('admin/views/availability.js');
const isSlotProduct = new Function(`${src.match(/export const isSlotProduct = .*;/)[0].replace('export const', 'const')}; return isSlotProduct;`)();

test('isSlotProduct johdetaan config.public_slots-kentästä: kb 7, 8, 10, 11, 12 mukana, muut ei', () => {
  assert.deepEqual(PROD.filter(isSlotProduct).map((p) => p.id), [7, 8, 10, 11, 12]);
  assert.equal(isSlotProduct(PROD[0]), true, 'kb 7 näyttää Vapaat ajat -paneelin');
});
test('isSlotProduct: vanha tuote, puuttuva config/kenttä ja null → ei paneelia', () => {
  assert.equal(isSlotProduct(null), false); assert.equal(isSlotProduct(undefined), false);
  assert.equal(isSlotProduct({ id: 7 }), false, 'ei configia');
  assert.equal(isSlotProduct({ id: 7, config: { lifecycle: 'current' } }), false, 'kenttä puuttuu (vanha kanta) → ei arvata id:stä');
  assert.equal(isSlotProduct({ id: 7, config: { lifecycle: 'old', public_slots: true } }), false);
  assert.equal(isSlotProduct({ id: 99, config: { lifecycle: 'current', public_slots: true } }), true, 'uusi slots-tuote tulee mukaan ilman koodimuutosta');
  assert.equal(isSlotProduct({ id: 8, config: { lifecycle: 'current', public_slots: 'true' } }), false);
});
test('ei kovakoodattua tuote-id-listaa hallinnan koodissa (koko admin-hakemisto)', () => {
  assert.ok(!/SLOT_PRODUCT_IDS/.test(src), 'SLOT_PRODUCT_IDS poistettu');
  const files = []; const walk = (d) => { for (const e of readdirSync(join(root, d), { withFileTypes: true })) e.isDirectory() ? walk(`${d}/${e.name}`) : /\.js$/.test(e.name) && files.push(`${d}/${e.name}`); };
  walk('admin');
  for (const f of files) { const t = read(f); assert.ok(!/SLOT_PRODUCT/.test(t), `${f}: SLOT_PRODUCT`); assert.ok(!/\[\s*8\s*,\s*10\s*,\s*11/.test(t), `${f}: id-lista`); }
  assert.match(src, /p\.config\?\.public_slots === true/);
});
test('resbooking: paneelin näkyvyys ja haku käyttävät isSlotProduct-funktiota; tuotelista ei rajaa id:llä', () => {
  const rb = read('admin/views/resbooking.js');
  assert.equal((rb.match(/isSlotProduct\(st\.product\)/g) || []).length, 2, 'getQuery + loadAvail');
  assert.ok(!/p\.id\s*===?\s*\d|\.includes\(p\.id\)/.test(rb), 'ei id-ehtoja tuotelistassa');
});

// ---- aikajana ----
test('aikajana: sama kuin kaupassa (rituaali 20 · tauko 10 · savusauna 90 = 120 min), vain kb 7', () => {
  // Kauppa lukee aikajanan kannasta (public_catalog().timeline, booking_61); hallinnan sisäinen aikajana saa sisältää tauon, kaupassa taukoa ei näytetä.
  // Vertailu tuotannon katalogiriviin: rituaalin ja savusaunan kesto + alkuhetki sekä kokonaiskesto
  const p7 = shopTl.splitCatalog(PROD61.catalog, new Map()).treatments.find((x) => x.id === 7);
  const admin = (id) => { let at = 0; return Object.fromEntries(TL.timelineOf(id).map((x) => { const r = [x.key, { start: at, min: x.min }]; at += x.min; return r; })); };
  const shop = () => Object.fromEntries(shopTl.timelineOf(p7).map((x) => [x.key === 'smoke_sauna' ? 'smoke' : x.key, { start: x.start, min: x.min }]));
  for (const k of ['ritual', 'smoke']) assert.deepEqual(admin(7)[k], shop()[k], `hallinnan ja kaupan jakso ${k} (alku + kesto) ei saa eriytyä`);
  assert.equal(TL.timelineMinutes(7), shopTl.timelineMinutes(p7), 'kokonaiskesto sama (120 min)');
  assert.ok(!shopTl.timelineOf(p7).some((x) => x.key === 'break'), 'kauppa ei näytä taukoa');
  assert.ok(TL.timelineOf(7).some((x) => x.key === 'break'), 'hallinnan sisäinen aikajana näyttää tauon');
  assert.deepEqual(TL.timelineOf(7).map((x) => [x.key, x.min]), [['ritual', 20], ['break', 10], ['smoke', 90]]);
  assert.equal(TL.timelineMinutes(7), 120);
  for (const id of [8, 10, 11, 12, 99]) { assert.equal(TL.timelineOf(id), null); assert.deepEqual(TL.timelineSlots(id, '2026-10-25T14:00:00Z'), []); assert.equal(TL.timelineMinutes(id), 0); }
  assert.deepEqual(Object.keys(TL.SEGMENT_FI).sort(), ['break', 'ritual', 'smoke']);
});
test('timelineSlots: kellonajat Helsingin ajassa (kesä- ja talviaika)', () => {
  const f = (iso) => TL.timelineSlots(7, iso).map((x) => `${x.key} ${x.from}–${x.to}`);
  assert.deepEqual(f('2026-10-18T13:30:00Z'), ['ritual 16:30–16:50', 'break 16:50–17:00', 'smoke 17:00–18:30'], 'EEST (UTC+3)');
  assert.deepEqual(f('2026-10-25T14:00:00Z'), ['ritual 16:00–16:20', 'break 16:20–16:30', 'smoke 16:30–18:00'], 'EET (UTC+2)');
  assert.deepEqual(TL.timelineSlots(7, null), []);
});
test('fmtDuration', () => {
  assert.equal(TL.fmtDuration(120), '2 h'); assert.equal(TL.fmtDuration(90), '1 h 30 min'); assert.equal(TL.fmtDuration(20), '20 min'); assert.equal(TL.fmtDuration(null), ''); assert.equal(TL.fmtDuration(0), '');
});
test('availability.js: aikajana näytetään vain kun jaksot täsmäävät palvelimen kestoon; teksti hallinnan suomea', () => {
  assert.match(src, /mins === timelineMinutes\(st\.rowsProduct\)/);
  assert.match(src, /timeline = h\('p', \{ class: 'slot-timeline', 'data-testid': 'slot-timeline'/);
  assert.match(src, /'Aikajana: '/);
});

// ---- mock vastaa tuotannon admin_treatment_availability-funktiota ----
const mock = () => createAdminMock({ now: new Date('2026-10-17T10:00:00Z') });
test('mock: admin_list_products sisältää kb 7:n public_slots-asetuksella; kb 3 (vuoro) ei', async () => {
  const rows = await mock().rpc('admin_list_products');
  assert.deepEqual(rows.filter(isSlotProduct).map((p) => p.id).sort((a, b) => a - b), [7, 8, 10]);
  const p7 = rows.find((p) => p.id === 7);
  assert.equal(p7.config.duration_minutes, 120); assert.equal(p7.config.max_persons, 6); assert.equal(p7.config.time_window_class, 'ritual'); assert.deepEqual(p7.config.public_weekdays, [6, 7]);
});
test('mock: kb 7 saatavuus – vain la/su, alkuajat 16:00/16:30/17:00, kesto ja loppuaika 2 h, hinta 49 €/hlö', async () => {
  const rows = await mock().rpc('admin_treatment_availability', { p_product_id: 7, p_from: '2026-10-25', p_to: '2026-11-07', p_persons: 3, p_override: false, p_override_reason: null });
  assert.ok(rows.length > 0);
  const days = [...new Set(rows.map((r) => r.session_date))];
  assert.deepEqual(days, ['2026-10-25', '2026-10-31', '2026-11-01', '2026-11-07'], 'su 25.10., la 31.10., su 1.11., la 7.11.');
  assert.deepEqual(rows.filter((r) => r.session_date === '2026-10-25').map((r) => r.starts_at), [helIso('2026-10-25', '16:00'), helIso('2026-10-25', '16:30'), helIso('2026-10-25', '17:00')]);
  for (const r of rows) { assert.equal(r.duration_minutes, 120); assert.equal(new Date(r.ends_at) - new Date(r.starts_at), 120 * 60e3); assert.equal(r.total, 147); assert.equal(r.persons, 3); assert.equal(r.status, 'available'); }
  assert.deepEqual(TL.timelineSlots(7, rows[0].starts_at).map((x) => `${x.from}–${x.to}`), ['16:00–16:20', '16:20–16:30', '16:30–18:00']);
});
test('mock: muut slots-tuotteet ennallaan (kb 10: 90 min; arkipäivät mukana), tuntematon tuote → tyhjä; vaatii bookings.manage', async () => {
  const m = mock();
  const r10 = await m.rpc('admin_treatment_availability', { p_product_id: 10, p_from: '2026-10-26', p_to: '2026-11-08', p_persons: 1 });
  assert.equal(r10.length, 28); for (const r of r10) assert.equal(new Date(r.ends_at) - new Date(r.starts_at), 90 * 60e3);
  assert.deepEqual(await m.rpc('admin_treatment_availability', { p_product_id: 999, p_from: '2026-10-26', p_to: '2026-11-08', p_persons: 1 }), []);
  await assert.rejects(async () => createAdminMock({ perms: [] }).rpc('admin_treatment_availability', { p_product_id: 7, p_from: '2026-10-26', p_to: '2026-11-08' }), (e) => e.code === 'forbidden');
});
