// Hiljaisten aikojen ale (booking_162): kaupan ja viikko-ohjelman logiikka, mockit, hallinnan validointi ja mock-RPC:t, tekstit FI/EN
// (= content/site-texts.pending-import-59.json), migraation/rollbackin/SQL-testin rakenne (tuotannon md5:t), ei innerHTML:ää, värit ja kontrasti.
// Tietokantakäytös testataan pgTAP-tyylisellä SQL-testillä booking/supabase/tests/discounts/t162_quiet_discounts.sql (paikallinen PG + migraatioketju).
import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';
import * as L from '../shop/src/quiet-offers-logic.js';
import { mockQuietOffers } from '../shop/src/quiet-offers-mock.js';
import { QUIET_TEXTS } from '../shop/src/quiet-texts.js';
import { T } from '../shop/src/i18n.js';
import { collectDefaults } from '../shop/src/text-registry.js';
import { validateQuietRule } from '../admin/quiet-logic.js';
import { QUIET_ADMIN_TEXTS, quietText } from '../admin/quiet-texts.js';
import { createAdminMock } from '../admin/options-mock.js';
import { QUIET_SITE_TEXTS } from '../../src/quiet-week.mjs';

// shop-mock.js tuo './sb.js':n (rakennuksessa kopio booking/shared/sb.js:stä) → sama asettelu väliaikaiskansioon (kuten kassa-maksu.test.mjs).
const tmp = mkdtempSync(join(tmpdir(), 'hiljaiset-'));
cpSync(new URL('../shop/src/', import.meta.url), tmp, { recursive: true });
cpSync(new URL('../shared/sb.js', import.meta.url), join(tmp, 'sb.js'));
writeFileSync(join(tmp, 'package.json'), '{"type":"module"}');
const { createShopMock } = await import(pathToFileURL(join(tmp, 'shop-mock.js')).href);
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const rd = (p) => readFileSync(join(root, '..', p), 'utf8');
const MIG = rd('booking/supabase/migrations/20261024213000_booking_162_quiet_discounts.sql');
const RB = rd('booking/supabase/rollbacks/20261024213000_booking_162_ROLLBACK.sql');
const SQLT = rd('booking/supabase/tests/discounts/t162_quiet_discounts.sql');
const PENDING = JSON.parse(rd('content/site-texts.pending-import-59.json'));
const MD5 = { public_create_booking: 'f7b15dca769f5fb4abfd9f81090718ac', public_create_booking_code: '31a03d52526c7b22d2643be477589b7f', public_preview_code: 'aaac81dc8ae5704a67b56184e5cd4cd7' };
const offer = (o = {}) => ({ product_id: 26, rule_id: 7, session_date: '2026-10-25', starts_at: '2026-10-25T17:00:00+03:00', ends_at: '2026-10-25T19:00:00+03:00', percent: 30, base_price: 200, discounted_price: 140, extra_person_price: 25, ...o });

// ---------------------------------------------------------------- logiikka
test('offerKey: sama vuoro eri aikaleimamuodoissa (PostgREST / jsonb / UTC) → sama avain', () => {
  assert.equal(L.offerKey(26, 7, '2026-10-25T17:00:00+03:00'), L.offerKey('26', '7', '2026-10-25T14:00:00Z'));
  assert.equal(L.offerKey(26, 7, '2026-10-25 17:00:00+03'), L.offerKey(26, 7, '2026-10-25T14:00:00.000Z'));
  assert.notEqual(L.offerKey(26, 7, '2026-10-25T17:00:00+03:00'), L.offerKey(26, 8, '2026-10-25T17:00:00+03:00'));
});
test('hinnat ja pyöristys kuten palvelimella (round(x * pct / 100, 2)); prosenttiteksti FI pilkulla', () => {
  assert.equal(L.discountPrice(200, 30), 140);
  assert.equal(L.discountPrice(189, 20), 151.2);
  assert.equal(L.quietAmount(245, 30), 73.5);
  assert.equal(L.quietAmount(99.99, 20), 20);
  assert.equal(L.quietAmount(100, 0), 0);
  assert.equal(L.pctText(20, 'fi'), '20');
  assert.equal(L.pctText(12.5, 'fi'), '12,5');
  assert.equal(L.pctText(12.5, 'en'), '12.5');
  assert.equal(L.fillText('−{pct} % {x}', { pct: '30' }), '−30 % {x}');
});
test('indexOffers / findOffer / dayMaxPercent / productMaxPercent; virheelliset rivit ohitetaan', () => {
  const idx = L.indexOffers([offer(), offer({ rule_id: 8, starts_at: '2026-10-25T20:00:00+03:00', percent: 20, discounted_price: 160 }),
    offer({ product_id: 25, session_date: '2026-10-26', starts_at: '2026-10-26T12:00:00+03:00', percent: 20 }), { percent: 0 }, null, offer({ base_price: 'x' })]);
  assert.equal(idx.byKey.size, 3);
  assert.equal(L.findOffer(idx, 26, 7, '2026-10-25T14:00:00Z').percent, 30);
  assert.equal(L.findOffer(idx, 26, 9, '2026-10-25T14:00:00Z'), null);
  assert.equal(L.findOffer(null, 26, 7, '2026-10-25T14:00:00Z'), null);
  assert.equal(L.dayMaxPercent(idx, '2026-10-25'), 30);
  assert.equal(L.dayMaxPercent(idx, '2026-10-26', 26), 0);
  assert.equal(L.dayMaxPercent(idx, '2026-10-26', 25), 20);
  assert.equal(L.productMaxPercent(idx, 26), 30);
  assert.deepEqual(L.quietPrices(offer()), { pct: 30, was: 200, now: 140, extraNow: 17.5 });
});
test('quietCheckout: palvelimen vastaus voittaa; ei pinoamista; ilman koodia alennus vuoron hinnasta', () => {
  assert.deepEqual(L.quietCheckout({ offer: offer(), sessionTotal: 250 }), { source: 'quiet', percent: 30, amount: 75, codeNotUsed: false });
  assert.deepEqual(L.quietCheckout({ quote: { discount_source: 'quiet', discount: 75, quiet: { percent: 30, amount: 75 } }, offer: offer() }),
    { source: 'quiet', percent: 30, amount: 75, codeNotUsed: true });
  assert.deepEqual(L.quietCheckout({ quote: { discount_source: 'code', discount: 100, quiet: { percent: 30, amount: 75 } }, offer: offer() }), { source: 'code' });
  assert.deepEqual(L.quietCheckout({ quote: { ok: true, discount: 10 }, offer: offer() }), { source: 'code' });   // vanha backend: koodi
  assert.deepEqual(L.quietCheckout({ offer: null, sessionTotal: 250 }), { source: 'none' });
  assert.deepEqual(L.quietCheckout({ offer: offer(), sessionTotal: 0 }), { source: 'none' });
});
test('createQuietOfferCache: yksi kutsu / ikkuna, 60 s tai next_change_at, virhe → [] 10 s, ikkuna ≤ 14 pv', async () => {
  let t = Date.parse('2026-10-24T12:00:00Z'), calls = 0, fail = false;
  const rpc = async (name, a) => { calls++; assert.equal(name, 'public_quiet_offers'); assert.equal(a.p_audience, 'consumer'); if (fail) throw new Error('PGRST202');
    return [offer({ next_change_at: new Date(t + 30000).toISOString() }), { bad: true }]; };
  const c = L.createQuietOfferCache({ rpc, now: () => t });
  const [a, b] = await Promise.all([c.load('2026-10-24', '2026-10-30'), c.load('2026-10-24', '2026-10-30')]);
  assert.equal(calls, 1); assert.equal(a.length, 1); assert.equal(a, b);
  t += 20000; await c.load('2026-10-24', '2026-10-30'); assert.equal(calls, 1);
  t += 15000; await c.load('2026-10-24', '2026-10-30'); assert.equal(calls, 2);   // next_change_at ohitettu → uusi haku
  assert.deepEqual(await c.load('2026-10-24', '2026-11-08'), []);                // > 14 pv: ei kutsua
  assert.deepEqual(await c.load('x', '2026-10-30'), []);
  assert.equal(calls, 2);
  c.clear(); fail = true;
  assert.deepEqual(await c.load('2026-10-24', '2026-10-30'), []); assert.equal(calls, 3);
  t += 5000; await c.load('2026-10-24', '2026-10-30'); assert.equal(calls, 3);
  t += 6000; await c.load('2026-10-24', '2026-10-30'); assert.equal(calls, 4);
});
test('quietByWeekday: tänään + 6 päivää viikonpäivittäin aikajärjestyksessä', () => {
  const m = L.quietByWeekday([offer({ session_date: '2026-10-26', starts_at: '2026-10-26T20:00:00+02:00' }), offer({ session_date: '2026-10-26', starts_at: '2026-10-26T12:00:00+02:00' }),
    offer({ session_date: '2026-10-31', starts_at: '2026-10-31T12:00:00+02:00' }), offer({ session_date: '2026-10-23' })], '2026-10-24');
  assert.deepEqual([...m.keys()], [1]);
  assert.deepEqual(m.get(1).map((o) => o.starts_at), ['2026-10-26T12:00:00+02:00', '2026-10-26T20:00:00+02:00']);
  assert.equal(L.weekdayIso('2026-10-25'), 7);
  assert.equal(L.weekdayIso('bad'), null);
});

// ---------------------------------------------------------------- mockit
test('mockQuietOffers: vain vapaa yksityisvuoro (exclusive, ei per_person); ≤ 36 h 30 %, ≤ 72 h 20 %', () => {
  const now = Date.parse('2026-10-24T09:00:00Z');
  const row = (h, o = {}) => ({ status: 'available', mode: 'exclusive', price_mode: 'fixed', product_id: 26, rule_id: h, base_price: 200, starts_at: new Date(now + h * 3600000).toISOString(), ends_at: new Date(now + (h + 2) * 3600000).toISOString(), ...o });
  const out = mockQuietOffers([row(10), row(36), row(50), row(72), row(73), row(-1), row(20, { status: 'booked' }), row(20, { mode: 'shared' }), row(20, { price_mode: 'per_person' })], now);
  assert.deepEqual(out.map((o) => [o.rule_id, o.percent, o.discounted_price]), [[10, 30, 140], [36, 30, 140], [50, 20, 160], [72, 20, 160]]);
  assert.equal(out[0].next_change_at, null);
  assert.equal(Date.parse(out[2].next_change_at), Date.parse(out[2].starts_at) - 36 * 3600000);
});
test('kaupan mock: public_quiet_offers tyhjä ilman ?quiet=1 (kuten tuotanto pois päältä)', async () => {
  const m = createShopMock({ storage: null });
  assert.deepEqual(await m.rpc('public_quiet_offers', { p_from: '2026-10-24', p_to: '2026-10-30', p_audience: 'consumer' }), []);
  const had = Object.getOwnPropertyDescriptor(globalThis, 'location');
  Object.defineProperty(globalThis, 'location', { value: { search: '?mock=1&quiet=1' }, configurable: true, writable: true });
  try {
    const q = createShopMock({ storage: null });
    const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
    const rows = await q.rpc('public_quiet_offers', { p_from: today, p_to: L.addDaysIso(today, 6), p_audience: 'consumer' });
    assert.ok(Array.isArray(rows));
    for (const o of rows) { assert.ok([20, 30].includes(o.percent)); assert.ok(L.validOffer(o)); assert.ok(Date.parse(o.starts_at) - Date.now() <= 72 * 3600000); }
  } finally { if (had) Object.defineProperty(globalThis, 'location', had); else delete globalThis.location; }
});
test('hallinnan validointi: samat rajat kuin admin_quiet_rule_upsert; päällekkäinen aktiivinen porras → overlap', () => {
  const ok = validateQuietRule({ label: 'Jälkilöyly 24 h', product_ids: [26, '26'], hours_before: '24', percent: '12,5', active: true });
  assert.equal(ok.ok, true);
  assert.deepEqual(ok.patch.product_ids, [26]);
  assert.equal(ok.patch.percent, '12.5');
  const bad = validateQuietRule({ label: '', product_ids: [], hours_before: '1.5', percent: '95', valid_from: '2026-11-02', valid_to: '2026-11-01' });
  assert.deepEqual(bad.errors.sort(), ['dates', 'hours', 'name', 'percent', 'products']);
  assert.ok(validateQuietRule({ label: 'x', product_ids: [1], hours_before: 337, percent: 10 }).errors.includes('hours'));
  assert.ok(validateQuietRule({ label: 'x', product_ids: [1], hours_before: 10, percent: '0' }).errors.includes('percent'));
  assert.ok(validateQuietRule({ label: 'x', product_ids: [1], hours_before: 10, percent: '10.123' }).errors.includes('percent'));
  const others = [{ id: 1, product_ids: [26], hours_before: 72, active: true }, { id: 2, product_ids: [26], hours_before: 36, active: false }];
  assert.deepEqual(validateQuietRule({ label: 'x', product_ids: [26, 49], hours_before: 72, percent: 10 }, others).errors, ['overlap']);
  assert.equal(validateQuietRule({ id: 1, label: 'x', product_ids: [26], hours_before: 72, percent: 10 }, others).ok, true);   // sama sääntö
  assert.equal(validateQuietRule({ label: 'x', product_ids: [26], hours_before: 36, percent: 10 }, others).ok, true);           // toinen ei aktiivinen
  assert.equal(validateQuietRule({ label: 'x', product_ids: [26], hours_before: 72, percent: 10, active: false }, others).ok, true);
});
test('hallinnan mock: oletuksena pois päältä, portaat 72 h 20 % ja 36 h 30 % tuotteelle 26; oikeudet kuten palvelimella', async () => {
  const m = createAdminMock({ now: new Date('2026-10-24T09:00:00Z') });
  const l = await m.rpc('admin_quiet_rules_list');
  assert.equal(l.enabled, false);
  assert.deepEqual(l.rules.map((r) => [r.product_ids, r.hours_before, r.percent]), [[[26], 72, 20], [[26], 36, 30]]);
  await assert.rejects(m.rpc('admin_quiet_rule_upsert', { p_id: null, p_patch: { label: 'x', product_ids: [26], hours_before: 36, percent: 10 } }), (e) => e.code === 'quiet_overlap');
  const r = await m.rpc('admin_quiet_rule_upsert', { p_id: null, p_patch: { label: 'Testi', product_ids: [49], hours_before: 24, percent: 15 } });
  assert.equal(r.rule.percent, 15);
  assert.deepEqual(await m.rpc('admin_quiet_rule_delete', { p_id: r.rule.id }), { ok: true });
  assert.deepEqual(await m.rpc('admin_quiet_set_enabled', { p_enabled: true }), { ok: true, enabled: true });
  assert.equal((await m.rpc('admin_quiet_preview', {})).offers.length, 2);
  const staff = createAdminMock({ role: 'staff', perms: ['bookings.view'] });
  const sl = await staff.rpc('admin_quiet_rules_list');
  assert.equal(sl.can_edit, false); assert.equal(sl.can_toggle, false);
  await assert.rejects(staff.rpc('admin_quiet_set_enabled', { p_enabled: true }), (e) => e.code === 'forbidden');
  await assert.rejects(staff.rpc('admin_quiet_rule_delete', { p_id: 1 }), (e) => e.code === 'forbidden');
});

// ---------------------------------------------------------------- tekstit
const toVar = (s) => String(s).replace(/\{(\w+)\}/g, '{{var:$1}}');
const noEmoji = (s) => !/\p{Extended_Pictographic}/u.test(s);
test('kaupan tekstit: FI/EN samat avaimet, T sisältää ne, ei emojeita; vastaavat pending-import-59:n ui.shop.quiet_*-rivejä', () => {
  assert.deepEqual(Object.keys(QUIET_TEXTS.fi).sort(), Object.keys(QUIET_TEXTS.en).sort());
  for (const lang of ['fi', 'en']) for (const [k, v] of Object.entries(QUIET_TEXTS[lang])) { assert.equal(T[lang][k], v, k); assert.ok(noEmoji(v), k); }
  const reg = collectDefaults().filter((r) => r.key.startsWith('ui.shop.quiet_'));
  assert.equal(reg.length, Object.keys(QUIET_TEXTS.fi).length * 2);
  const pend = new Map(PENDING.filter((r) => r.key.startsWith('ui.shop.')).map((r) => [`${r.key}|${r.lang}`, r]));
  assert.equal(pend.size, reg.length);
  for (const r of reg) assert.equal(pend.get(`${r.key}|${r.lang}`)?.text, toVar(r.text), r.key);
});
test('viikko-ohjelman ja hallinnan tekstit = pending-import-59; tuontirivien muoto; vain käytetyt hallinnan avaimet', () => {
  const want = new Map();
  for (const [k, v] of Object.entries(QUIET_SITE_TEXTS)) for (const lang of ['fi', 'en']) want.set(`${k}|${lang}`, v[lang]);
  assert.deepEqual(Object.keys(QUIET_ADMIN_TEXTS.fi).sort(), Object.keys(QUIET_ADMIN_TEXTS.en).sort());
  for (const lang of ['fi', 'en']) for (const [k, v] of Object.entries(QUIET_ADMIN_TEXTS[lang])) want.set(`${k}|${lang}`, v);
  const got = new Map(PENDING.filter((r) => !r.key.startsWith('ui.shop.')).map((r) => [`${r.key}|${r.lang}`, r.text]));
  assert.deepEqual([...got.keys()].sort(), [...want.keys()].sort());
  for (const [k, v] of want) assert.equal(got.get(k), v, k);
  const seen = new Set();
  for (const r of PENDING) {
    assert.ok(/^ui\.(shop|site|admin\.quiet)\.[a-z0-9_.]+$/.test(r.key), r.key);
    assert.ok(['fi', 'en'].includes(r.lang));
    assert.equal(r.kind, 'plain'); assert.equal(r.class, 'normal');
    assert.ok(r.text.length <= r.max_len, r.key);
    assert.deepEqual(r.placeholders, [...new Set(r.text.match(/\{\{var:\w+\}\}/g) || [])], r.key);
    assert.match(r.reason, /^booking_162/);
    assert.ok(noEmoji(r.text), r.key);
    assert.ok(!seen.has(`${r.key}|${r.lang}`)); seen.add(`${r.key}|${r.lang}`);
  }
  for (const k of new Set(PENDING.map((r) => r.key))) assert.ok(seen.has(`${k}|fi`) && seen.has(`${k}|en`), k);
  const view = rd('booking/admin/views/quiet.js');
  const used = new Set([...view.matchAll(/'(ui\.admin\.quiet\.[a-z_]+)'/g)].map((m) => m[1]));
  for (const k of ['name', 'percent', 'hours', 'products', 'dates', 'overlap']) used.add(`ui.admin.quiet.v_${k}`);   // `ui.admin.quiet.v_${k}`
  assert.deepEqual([...used].sort(), Object.keys(QUIET_ADMIN_TEXTS.fi).sort());
  assert.equal(quietText('ui.admin.quiet.rule_line', { products: 'A', hours: 36, pct: '30' }, 'fi'), 'A · enintään 36 h ennen alkua · −30 %');
});

// ---------------------------------------------------------------- migraatio, rollback, SQL-testi
test('migraatio: tuotannon md5-tarkistus ennen muutoksia, kytkin false, ei public-skeemaa, oikeudet; uudelleenajettava', () => {
  for (const [fn, md5] of Object.entries(MD5)) { assert.ok(MIG.includes(`booking.${fn}(`), fn); assert.ok(MIG.includes(md5), fn); assert.ok(RB.includes(md5), fn); }
  assert.ok(MIG.indexOf('raise exception \'booking_162: % poikkeaa tuotannon versiosta') < MIG.indexOf('create table'));
  assert.match(MIG, /'quiet_discounts\.enabled',\s*'false'::jsonb/);
  assert.ok(!/\bpublic\./i.test(MIG.replace(/booking\.public_\w+/g, '')), 'ei public-skeeman objekteja');
  assert.match(MIG, /grant execute on function booking\.public_quiet_offers\(date, date, text\) to anon/);
  assert.match(MIG, /revoke all on function booking\._quiet_offers\(date, date, bigint, boolean\) from public, anon, authenticated/);
  for (const fn of ['admin_quiet_rules_list', 'admin_quiet_rule_upsert', 'admin_quiet_rule_delete', 'admin_quiet_set_enabled', 'admin_quiet_preview', 'public_quiet_offers'])
    assert.match(MIG, new RegExp(`create or replace function booking\\.${fn}\\(`), fn);
  assert.match(MIG, /create table if not exists booking\.quiet_discount_rules/);
});
test('rollback: palauttaa kolme funktiota ja poistaa uudet objektit; SQL-testi ajaa migraation ja rollbackin (\\ir) ja vertaa md5:t', () => {
  for (const fn of Object.keys(MD5)) assert.match(RB, new RegExp(`CREATE OR REPLACE FUNCTION booking\\.${fn}\\(`), fn);
  for (const fn of ['admin_quiet_rules_list', 'public_quiet_offers', '_quiet_offers']) assert.match(RB, new RegExp(`drop function if exists booking\\.${fn}\\(`), fn);
  assert.match(RB, /drop table if exists booking\.quiet_discount_rules/);
  assert.match(RB, /delete from booking\.settings where key = 'quiet_discounts\.enabled'/);
  assert.match(SQLT, /\\ir \.\.\/\.\.\/migrations\/20261024213000_booking_162_quiet_discounts\.sql/);
  assert.match(SQLT, /\\ir \.\.\/\.\.\/rollbacks\/20261024213000_booking_162_ROLLBACK\.sql/);
  for (const md5 of Object.values(MD5)) assert.ok(SQLT.includes(md5));
  assert.match(SQLT, /TESTRESULT/);
  assert.ok(!/@(?!example\.test)[a-z0-9-]+\.[a-z]/i.test(SQLT.replace(/--.*$/gm, '')), 'vain @example.test-osoitteita');
});

// ---------------------------------------------------------------- käyttöliittymä: turvallisuus, värit, rakentaminen
test('ei innerHTML:ää uusissa/muutetuissa käyttöliittymätiedostoissa; ei sinisiä värejä tai emojeita booking_162-tyyleissä', () => {
  for (const f of ['booking/shop/src/shop.js', 'booking/shop/src/quiet-week.js', 'booking/shop/src/quiet-offers-logic.js', 'booking/admin/views/quiet.js', 'booking/admin/quiet-texts.js'])
    assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML/.test(rd(f).replace(/^\s*\/\/.*$/gm, '')), f);
  const shopCss = rd('booking/shop/src/shop.css'), siteCss = rd('src/styles.css');
  const blocks = [shopCss.slice(shopCss.indexOf('booking_162')), siteCss.slice(siteCss.indexOf('booking_162'))];
  for (const b of blocks) {
    assert.ok(b.length > 100);
    for (const hex of b.match(/#[0-9a-f]{6}\b/gi) || []) {
      const [r, g, bl] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
      assert.ok(!(bl > r + 30 && bl > g + 10), `sininen sävy ${hex}`);
    }
    assert.ok(noEmoji(b));
  }
});
test('kontrasti ≥ 4,5:1 paletin pareille (#2B3A30 / #F4EFE7 / #7A5530 valkoisella ja kortin taustoilla)', () => {
  const lum = (hex) => { const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
  const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
  for (const [fg, bg] of [['#F4EFE7', '#2B3A30'], ['#7A5530', '#ffffff'], ['#7A5530', '#F4EFE7'], ['#7A5530', '#efe6d8'], ['#7A5530', '#e8f3ea'], ['#2B3A30', '#F4EFE7'], ['#2B3A30', '#efe6d8']])
    assert.ok(ratio(fg, bg) >= 4.5, `${fg} / ${bg}: ${ratio(fg, bg).toFixed(2)}`);
});
test('viikko-ohjelma: <ol data-quiet-week> tekstit + yksityisvuorotuotteet (25, 26), päivillä data-wd; kauppa-build lisää quiet-week.js:n', async () => {
  const R = await import('../../src/render.mjs');
  for (const lang of ['fi', 'en']) {
    const html = R.week(lang);
    assert.match(html, /<ol class="week"[^>]* data-quiet-week /);
    for (let d = 1; d <= 7; d++) assert.ok(html.includes(`data-wd="${d}"`), `${lang} ${d}`);
    const prods = JSON.parse(/data-quiet-products="([^"]*)"/.exec(html)[1].replace(/&quot;/g, '"').replace(/&amp;/g, '&'));
    assert.deepEqual(Object.keys(prods).sort(), ['25', '26']);
    assert.equal(prods[26].s, 'jalkiloylyt');
    assert.match(html, lang === 'fi' ? /data-quiet-badge="−\{pct\} %"/ : /data-quiet-badge="−\{pct\}%"/);
  }
  const build = rd('booking/shop/build.mjs');
  assert.match(build, /out\.includes\('data-quiet-week'\) && !out\.includes\('\/booking\/quiet-week\.js'\)/);
  assert.match(build, /window\.BOOKING_QUIET=/);
  assert.match(rd('booking/shop/src/quiet-week.js'), /rpc\('public_quiet_offers', \{ p_from: today, p_to: addDaysIso\(today, 6\), p_audience: 'consumer' \}\)/);
});
test('hallinta: reitti Hiljaiset ajat (catalog.edit / settings.edit) alennuskoodien jälkeen; CI ajaa tämän testin', () => {
  const admin = rd('booking/admin/admin.js');
  assert.match(admin, /path: 'alennuskoodit'[^\n]*\n\s*\{ path: 'hiljaiset-ajat', label: 'Hiljaiset ajat', icon: 'leaf', any: \['catalog\.edit', 'settings\.edit'\], mod: \(\) => loadView\('quiet'\) \}/);
  assert.match(rd('.github/workflows/pages.yml'), /node --test booking\/tests\/hiljaiset-ajat\.test\.mjs/);
});
