// Saunarituaali yleisen vuoron lisäpalveluna (booking_166): kaupan logiikka (aikasääntö, normalisointi, sovitus, p_addons-alkio), mock-kulku
// (?mock=1&ritual=1), tekstit FI/EN (= content/site-texts.pending-import-62.json), migraation/rollbackin/SQL-testin rakenne (tuotannon md5:t),
// ei innerHTML:ää, värit ja kontrasti. Tietokantakäytös: booking/supabase/tests/t166_ritual_addon.sql (paikallinen PG + migraatioketju).
import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';
import * as L from '../shop/src/ritual-addon-logic.js';
import { RITUAL_TEXTS, RITUAL_ERRORS } from '../shop/src/ritual-addon-texts.js';
import { T } from '../shop/src/i18n.js';
import { collectDefaults } from '../shop/src/text-registry.js';

const tmp = mkdtempSync(join(tmpdir(), 'rituaali-'));
cpSync(new URL('../shop/src/', import.meta.url), tmp, { recursive: true });
cpSync(new URL('../shared/sb.js', import.meta.url), join(tmp, 'sb.js'));
writeFileSync(join(tmp, 'package.json'), '{"type":"module"}');
const { createRitualMock } = await import(pathToFileURL(join(tmp, 'ritual-addon-mock.js')).href);
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const rd = (p) => readFileSync(join(root, '..', p), 'utf8');
const MIG = rd('booking/supabase/migrations/20261024202015_booking_166_ritual_addon.sql');
const RB = rd('booking/supabase/rollbacks/20261024202015_booking_166_ROLLBACK.sql');
const SQLT = rd('booking/supabase/tests/t166_ritual_addon.sql');
const PENDING = JSON.parse(rd('content/site-texts.pending-import-62.json'));
const PENDING63 = JSON.parse(rd('content/site-texts.pending-import-63.json'));   // kassakortin korjaus: 3 uutta avainta (ei SQL:ää)
const MD5 = { _attach_addons: '6a780e8e00229ff273a321591f197541', _reservation_refund_plan: 'cb44c682ac0095617fe20b297b0cdac3', public_get_booking: 'a155cd472c356c09e595cbda46b4dada',
  public_preview_code: 'fec859d04960f42d79412bbdf7dc6561', reservations_time_window: '023b689b0366602ab32738b7821dcc16' };
const hel = (ms) => new Intl.DateTimeFormat('fi-FI', { timeZone: 'Europe/Helsinki', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(ms)).replace('.', ':');

// ---------------------------------------------------------------- aikasääntö
test('aikasääntö: vuoro 16.00–18.00 → 15.30, 16.00, 16.30, 17.30, 18.00 (Helsinki, kesä- ja talviaika)', () => {
  for (const [s, e] of [['2027-06-05T16:00:00+03:00', '2027-06-05T18:00:00+03:00'], ['2027-01-09T16:00:00+02:00', '2027-01-09T18:00:00+02:00'], ['2027-01-09T14:00:00Z', '2027-01-09T16:00:00Z']])
    assert.deepEqual(L.ritualStarts(s, e).map(hel), ['15:30', '16:00', '16:30', '17:30', '18:00'], s);
  assert.deepEqual(L.ritualStarts('2027-06-05T14:00:00+03:00', '2027-06-05T17:00:00+03:00').map(hel), ['13:30', '14:00', '14:30', '15:30', '16:30', '17:00']);
  assert.deepEqual(L.ritualStarts('2027-06-05T16:00:00+03:00', '2027-06-05T18:00:00+03:00', { at_start: false }).map(hel), ['15:30', '16:30', '17:30', '18:00']);
  assert.deepEqual(L.ritualStarts('2027-06-05T16:00:00+03:00', '2027-06-05T18:00:00+03:00', { before_min: 0, at_end: false }).map(hel), ['16:00', '16:30', '17:30']);
  assert.deepEqual(L.ritualStarts('x', 'y'), []);
  assert.deepEqual(L.ritualStarts('2027-06-05T18:00:00+03:00', '2027-06-05T16:00:00+03:00'), []);
  const s = Date.parse('2027-06-05T16:00:00+03:00'), e = s + 2 * 36e5;
  assert.deepEqual(L.ritualStarts(s, e).map((t) => L.positionOf(t, s, e)), ['before', 'start', 'during', 'during', 'end']);
});
test('aikasääntö yhdessä paikassa: JS-peilin oletus = migraation asetus ritual_addon; SQL-funktio _ritual_addon_starts lukee asetusta', () => {
  const m = MIG.match(/'(\{"enabled": true, "product_id": 8[^']*\})'::jsonb/);
  assert.ok(m, 'asetuksen oletus migraatiossa');
  const cfg = JSON.parse(m[1]);
  for (const [k, v] of Object.entries(L.RITUAL_RULE_DEFAULTS)) assert.equal(cfg[k], v, k);
  assert.equal(cfg.enabled, true, 'kytkin oletuksena päällä');
  assert.match(MIG, /create or replace function booking\._ritual_addon_starts\(/);
  assert.match(MIG, /create or replace function booking\._ritual_addon_cfg\(/);
});

// ---------------------------------------------------------------- normalisointi ja valinta
const raw = (o = {}) => ({ ok: true, available: true, product_id: 8, name: 'Saunotusrituaali', name_en: 'Sauna ritual', unit_price: 20, prices: { 1: 20, 2: 40, 3: 60 }, vat_rate: 25.5, duration_minutes: 20, min_persons: 1, max_persons: 3,
  times: [{ starts_at: '2027-06-05T16:30:00+03:00', max_persons: 2, position: 'during' }, { starts_at: '2027-06-05T15:30:00+03:00', max_persons: 3, position: 'before' }, { starts_at: '2027-06-05T18:00:00+03:00', max_persons: 0 }, { starts_at: 'x', max_persons: 3 }], ...o });
test('normalizeOffer: piilotus kun ei ok/available/aikoja; täydet ajat pois; järjestys; avain UTC-ISO', () => {
  for (const r of [null, {}, { ok: false }, raw({ available: false }), raw({ times: [] }), raw({ times: [{ starts_at: '2027-06-05T16:30:00+03:00', max_persons: 0 }] })]) assert.equal(L.normalizeOffer(r), null);
  const o = L.normalizeOffer(raw());
  assert.deepEqual(o.times.map((x) => x.key), ['2027-06-05T12:30:00.000Z', '2027-06-05T13:30:00.000Z']);
  assert.equal(L.ritualPrice(o, 2), 40);
  assert.equal(L.ritualPrice({ ...o, prices: {} }, 3), 60);
  assert.equal(L.ritualPrice(o, 0), 0);
});
test('clampQty / reconcile / ritualAddonArg / ritualSig / splitItems / isRitualError', () => {
  const o = L.normalizeOffer(raw()), k1 = '2027-06-05T13:30:00.000Z', k0 = '2027-06-05T12:30:00.000Z';
  assert.equal(L.clampQty(null, o, k1, 4), 2);
  assert.equal(L.clampQty(1, o, k1, 4), 1);
  assert.equal(L.clampQty(5, o, k0, 2), 2);
  assert.equal(L.clampQty(1, o, 'nope', 2), 0);
  assert.deepEqual(L.reconcile({ key: k1, qty: 2 }, o, 1), { key: k1, qty: 1, lost: false });
  assert.deepEqual(L.reconcile({ key: '2027-06-05T15:00:00.000Z', qty: 2 }, o, 2), { key: null, qty: 0, lost: true });
  assert.deepEqual(L.reconcile({ key: k1, qty: 1 }, null, 2), { key: null, qty: 0, lost: true });
  assert.deepEqual(L.reconcile(null, o, 2), { key: null, qty: 0, lost: false });
  assert.deepEqual(L.ritualAddonArg({ key: k1, qty: 2 }), { ritual_start: k1, quantity: 2 });
  assert.equal(L.ritualAddonArg({ key: null, qty: 0 }), null);
  assert.ok(!('price' in L.ritualAddonArg({ key: k1, qty: 2 })), 'hinta ei kulje asiakkaalta');
  assert.equal(L.ritualSig({ key: k1, qty: 2 }), `${k1}x2`);
  assert.equal(L.ritualSig(null), '-');
  const { main, ritual } = L.splitItems([{ product_id: 8, ritual_addon: true }, { product_id: 1, ritual_addon: false }]);
  assert.equal(main.product_id, 1); assert.equal(ritual.length, 1);
  assert.equal(L.splitItems([{ product_id: 1 }]).ritual.length, 0);
  assert.ok(L.isRitualError('ritual_addon_full')); assert.ok(!L.isRitualError('capacity_exceeded'));
});

// ---------------------------------------------------------------- mock-kulku
const NOW = Date.parse('2027-06-01T09:00:00Z');
const mem = () => { const m = new Map(); return { getItem: (k) => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) }; };
test('mock: saatavuus → tarjous (täysi aika piilossa, vajaa rajattu) → varaus lukitsee hinnan → vahvistus (rituaalirivi, ei verkkomuutosta)', () => {
  const rpc = createRitualMock({ storage: mem(), now: () => NOW });
  const rows = rpc('public_availability', { p_product_id: 1, p_from: '2027-06-05', p_to: '2027-06-06' });
  const r = rows.find((x) => x.rule_id === 9 && x.session_date === '2027-06-05');
  assert.equal(hel(Date.parse(r.starts_at)), '16:00'); assert.equal(r.mode, 'shared'); assert.equal(r.unit_price, 29);
  const o = L.normalizeOffer(rpc('public_ritual_addon', { p_rule_id: 9, p_date: '2027-06-05', p_persons: 3 }));
  assert.deepEqual(o.times.map((x) => hel(Date.parse(x.starts_at))), ['15:30', '16:00', '16:30', '18:00'], '17.30 täynnä → ei näy');
  assert.equal(o.times.find((x) => hel(Date.parse(x.starts_at)) === '16:30').max, 2);
  assert.equal(o.unit_price, 20);
  const t = o.times[1].key;
  assert.equal(rpc('public_create_booking', { p_rule_id: 9, p_date: '2027-06-05', p_persons: 3, p_name: 'Testi', p_addons: [{ ritual_start: o.times[2].key, quantity: 3 }] }).code, 'ritual_addon_full');
  assert.equal(rpc('public_create_booking', { p_rule_id: 9, p_date: '2027-06-05', p_persons: 3, p_name: 'Testi', p_addons: [{ ritual_start: '2027-06-05T13:15:00Z', quantity: 1 }] }).code, 'ritual_addon_time', '16.15 ei ole säännön aika');
  assert.equal(rpc('public_create_booking', { p_rule_id: 9, p_date: '2027-06-05', p_persons: 3, p_name: 'Testi', p_addons: [{ ritual_start: t, quantity: 4 }] }).code, 'ritual_addon_persons');
  const ok = rpc('public_create_booking', { p_rule_id: 9, p_date: '2027-06-05', p_persons: 3, p_name: 'Testi', p_addons: [{ ritual_start: t, quantity: 2, price: 0 }] });
  assert.equal(ok.ok, true); assert.equal(ok.total, 3 * 29 + 40, 'asiakkaan price ohitetaan');
  const b = rpc('public_get_booking', { p_token: ok.token });
  assert.equal(b.has_ritual_addon, true); assert.equal(b.can_change, false);
  const { main, ritual } = L.splitItems(b.items);
  assert.equal(main.product_id, 1); assert.equal(ritual[0].product_id, 8); assert.equal(ritual[0].persons, 2); assert.equal(hel(Date.parse(ritual[0].starts_at)), '16:00');
  const after = L.normalizeOffer(rpc('public_ritual_addon', { p_rule_id: 9, p_date: '2027-06-05', p_persons: 6 }));
  assert.equal(after.times.find((x) => x.key === t).max, 4, 'oma varaus vie rituaalipaikat');
  assert.equal(rpc('public_get_booking', { p_token: 'x' }), undefined);
});
test('mock: ?fail=noritual → ei aikoja (osio piilossa); arkipäivä → ei vuoroa', () => {
  const rpc = createRitualMock({ storage: mem(), now: () => NOW, fail: 'noritual' });
  assert.equal(L.normalizeOffer(rpc('public_ritual_addon', { p_rule_id: 9, p_date: '2027-06-05', p_persons: 2 })), null);
  const rpc2 = createRitualMock({ storage: mem(), now: () => NOW });
  assert.equal(L.normalizeOffer(rpc2('public_ritual_addon', { p_rule_id: 9, p_date: '2027-06-02', p_persons: 2 })), null);
});

// ---------------------------------------------------------------- tekstit
test('tekstit FI/EN: kaikki avaimet molemmilla kielillä, ei "<", yhdistetty i18n:ään; virhekoodit katettu', () => {
  for (const k of Object.keys(RITUAL_TEXTS.fi)) { assert.ok(RITUAL_TEXTS.en[k], k); assert.equal(T.fi[k], RITUAL_TEXTS.fi[k]); assert.equal(T.en[k], RITUAL_TEXTS.en[k]); }
  assert.deepEqual(Object.keys(RITUAL_TEXTS.en).sort(), Object.keys(RITUAL_TEXTS.fi).sort());
  for (const k of Object.keys(RITUAL_ERRORS.fi)) { assert.ok(RITUAL_ERRORS.en[k], k); assert.equal(T.fi.errors[k], RITUAL_ERRORS.fi[k]); assert.equal(T.en.errors[k], RITUAL_ERRORS.en[k]); }
  for (const c of L.RITUAL_ERROR_CODES.filter((c) => c !== 'ritual_addon_move')) assert.ok(RITUAL_ERRORS.fi[c], c);
  for (const s of [...Object.values(RITUAL_TEXTS.fi), ...Object.values(RITUAL_TEXTS.en), ...Object.values(RITUAL_ERRORS.fi), ...Object.values(RITUAL_ERRORS.en)]) assert.ok(!s.includes('<'), s);
});
test('content/site-texts.pending-import-62.json = koodin oletukset (22 avainta, 44 riviä, FI+EN), ei "<", ei kaksoisrivejä', () => {
  const keys62 = new Set(PENDING.map((r) => r.key));
  const want = collectDefaults().filter((r) => /^ui\.shop\.(ritual_|error_ritual_addon_)/.test(r.key) && keys62.has(r.key));
  assert.equal(PENDING.length, 44); assert.equal(new Set(PENDING.map((r) => r.key)).size, 22);
  assert.equal(new Set(PENDING.map((r) => `${r.key}|${r.lang}`)).size, PENDING.length);
  for (const w of want) {
    const p = PENDING.find((r) => r.key === w.key && r.lang === w.lang);
    assert.ok(p, `${w.key}|${w.lang}`); assert.equal(p.text, w.text); assert.equal(p.kind, 'plain'); assert.ok(p.max_len >= Math.max(200, p.text.length));
    assert.ok(!p.text.includes('<')); assert.match(p.reason, /booking_166/);
    assert.deepEqual(p.placeholders, [...new Set(p.text.match(/\{\{var:[a-z_]+\}\}/g) || [])]);
  }
  assert.equal(want.length, PENDING.length);
});

test('content/site-texts.pending-import-63.json = kassakortin uudet avaimet (3 avainta, 6 riviä, FI+EN); 62 + 63 kattavat kaikki rituaaliavaimet', () => {
  const all = collectDefaults().filter((r) => /^ui\.shop\.(ritual_|error_ritual_addon_)/.test(r.key));
  assert.deepEqual([...new Set(PENDING63.map((r) => r.key))].sort(), ['ui.shop.ritual_choose', 'ui.shop.ritual_time_label', 'ui.shop.ritual_time_required']);
  assert.equal(PENDING63.length, 6);
  for (const p of PENDING63) {
    const w = all.find((r) => r.key === p.key && r.lang === p.lang);
    assert.ok(w, `${p.key}|${p.lang}`); assert.equal(p.text, w.text); assert.equal(p.kind, 'plain'); assert.ok(!p.text.includes('<')); assert.match(p.reason, /booking_166/);
    assert.ok(!PENDING.some((r) => r.key === p.key), 'ei päällekkäin 62:n kanssa');
  }
  assert.equal(all.length, PENDING.length + PENDING63.length);
  assert.equal(RITUAL_TEXTS.fi.ritualChoose, 'Valitse kellonaika'); assert.equal(RITUAL_TEXTS.en.ritualChoose, 'Choose a time');
});

// ---------------------------------------------------------------- migraatio, rollback, SQL-testi
test('migraatio: md5-vartija tuotannon funktioille, kytkin, palvelimen hinta; rollback palauttaa tuotannon funktiot; SQL-testi kattaa vaaditut kohdat', () => {
  for (const [f, h] of Object.entries(MD5)) { assert.ok(MIG.includes(h), `migraatio: ${f}`); assert.ok(RB.includes(h), `rollback: ${f}`); }
  assert.match(MIG, /raise exception 'booking_166: korvattavien funktioiden md5/);
  assert.match(RB, /drop function if exists booking\.public_ritual_addon\(bigint, date, integer\)/);
  assert.ok(!/schema public|public\./i.test(MIG.replace(/booking\.public_\w+/g, '').replace(/--.*$/gm, '')), 'ei public-skeemaa');
  assert.match(MIG, /grant execute on function booking\.public_ritual_addon\(bigint, date, integer\) to anon/);
  for (const k of ['16:00', '15:30', 'Europe/Helsinki', 'UTC', 'cancel', 'move', 'enabled', '2027-']) assert.ok(SQLT.includes(k), `t166: ${k}`);
  assert.match(SQLT, /TESTRESULT/);
  assert.ok(!/20(2[0-6])-\d\d-\d\d/.test(SQLT.replace(/--.*$/gm, '')), 't166 käyttää vain 2027-päiviä');
});

// ---------------------------------------------------------------- käyttöliittymä
test('ei innerHTML:ää uusissa/muutetuissa tiedostoissa; ei sinistä eikä emojeita booking_166-tyyleissä', () => {
  for (const f of ['booking/shop/src/ritual-addon-logic.js', 'booking/shop/src/ritual-addon-texts.js', 'booking/shop/src/ritual-addon-mock.js', 'booking/shop/src/shop.js'])
    assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML/.test(rd(f).replace(/^\s*\/\/.*$/gm, '')), f);
  const css = rd('booking/shop/src/shop.css'), part = css.slice(css.indexOf('/* booking_166'));
  assert.ok(part.length > 100 && part.includes('.bk-addon-ritual .bk-rit-select'));
  for (const sel of part.match(/^[^{}\n/][^{]*(?=\{)/gm)) for (const one of sel.split(',')) assert.match(one.trim(), /^\.bk-(addon-ritual|addons|ritual-msg)\b/, `vain kortin tyylit: ${one}`);
  assert.ok(!/blue|#00f|#0000ff|#1e90ff|#2563eb|#3b82f6/i.test(part));
  assert.ok(!/\p{Extended_Pictographic}/u.test(part + JSON.stringify(RITUAL_TEXTS) + JSON.stringify(RITUAL_ERRORS)));
  for (const c of part.match(/#[0-9a-f]{6}\b/gi)) assert.ok(['#2B3A30', '#F4EFE7', '#7A5530', '#6B5E52'].includes(c.toUpperCase()), c);
});
test('kontrasti ≥ 4,5:1 (#2B3A30 / #F4EFE7 / #7A5530 ja --muted valkoisella ja valitun rivin taustalla)', () => {
  const lum = (hex) => { const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
  const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
  for (const [fg, bg] of [['#2B3A30', '#ffffff'], ['#2B3A30', '#F4EFE7'], ['#7A5530', '#ffffff'], ['#7A5530', '#F4EFE7'], ['#6B5E52', '#ffffff'], ['#6B5E52', '#F4EFE7']])
    assert.ok(ratio(fg, bg) >= 4.5, `${fg} / ${bg}: ${ratio(fg, bg).toFixed(2)}`);
});
test('kassa: lisäpalvelu piilossa ilman tarjousta, kutsuu public_ritual_addon; valinta p_addons-listaan (koodin tarkistus + varaus)', () => {
  const s = rd('booking/shop/src/shop.js');
  assert.match(s, /'public_ritual_addon'/);
  assert.match(s, /data-testid': 'checkout-ritual'/);
  assert.match(s, /ritualAddonArg\(/);
  assert.match(s, /'fail', 'ritual'\]/);
});

// ---------------------------------------------------------------- kassakortti (Joonas 24.10.2026)
test('kortti: ritualMax / cardQty / reconcileCard (määrä 0 = ei rituaalia, yläraja min(henkilöt, max 6, ajan vapaat))', () => {
  const o = L.normalizeOffer({ ok: true, available: true, min_persons: 1, max_persons: 6, unit_price: 20, prices: { 1: 20, 2: 40, 3: 60 }, times: [
    { starts_at: '2026-10-31T13:30:00Z', max_persons: 3, position: 'before' }, { starts_at: '2026-10-31T14:30:00Z', max_persons: 2, position: 'during' }] });
  const [a, b] = o.times.map((x) => x.key);
  assert.equal(L.ritualMax(o, null, 3), 3); assert.equal(L.ritualMax(o, b, 3), 2); assert.equal(L.ritualMax(o, a, 1), 1); assert.equal(L.ritualMax(o, 'x', 3), 0); assert.equal(L.ritualMax(null, null, 3), 0);
  assert.equal(L.cardQty(0, o, null, 3), 0); assert.equal(L.cardQty(5, o, null, 3), 3); assert.equal(L.cardQty(3, o, b, 3), 2); assert.equal(L.cardQty(-1, o, a, 3), 0);
  assert.deepEqual(L.reconcileCard({ key: null, qty: 2 }, o, 3), { key: null, qty: 2, lost: false });
  assert.deepEqual(L.reconcileCard({ key: b, qty: 3 }, o, 3), { key: b, qty: 2, lost: false });
  assert.deepEqual(L.reconcileCard({ key: 'gone', qty: 2 }, o, 3), { key: null, qty: 2, lost: true });
  assert.deepEqual(L.reconcileCard({ key: a, qty: 2 }, null, 3), { key: null, qty: 0, lost: true });
  assert.deepEqual(L.reconcileCard({ key: null, qty: 0 }, o, 3), { key: null, qty: 0, lost: false });
});
test('kassa: rituaali on kortti LISÄPALVELUT-listassa (.bk-addon), aika alasvetovalikosta vasta määrällä ≥ 1, pakollinen; tekstien varaoletukset', () => {
  const js = rd('booking/shop/src/shop.js');
  assert.match(js, /h\('li', \{ class: 'bk-addon bk-addon-ritual', 'data-testid': 'checkout-ritual'/);
  assert.match(js, /h\('ul', \{ class: 'bk-addonlist' \}, ritCard, addonRows\.map/);
  assert.ok(!/type: 'radio', name: 'bk-ritual'/.test(js), 'ei radiolistaa');
  assert.match(js, /h\('select', \{ id: 'bk-rit-time'/); assert.match(js, /h\('option', \{ value: '', text: rtx\('ritualChoose'\) \}\)/);
  assert.match(js, /timeBox\.hidden = !\(rit\.sel\.qty > 0\)/);
  assert.match(js, /ritErr\(rtx\('ritualTimeRequired'\)\); rit\.ui\.card\.scrollIntoView/);
  assert.match(js, /const rtx = \(k, v\) => fillText\(t\[k\] \|\| RITUAL_TEXTS\[S\.lang\]\?\.\[k\] \|\| RITUAL_TEXTS\.fi\[k\] \|\| ''/);
  assert.ok(!/\bt\.ritual[A-Z]/.test(js), 'rituaalitekstit vain rtx():n kautta');
});
test('kaupan build: versiotunnus ?v= kaikkiin kaupan moduuleihin ja sivujen /booking/-viittauksiin (ei vanhan välimuistin sekoitusta)', () => {
  const b = rd('booking/shop/build.mjs');
  assert.match(b, /const SHOP_VER = '\?v=' \+/);
  assert.match(b, /versioimaton relatiivinen import/);
  assert.match(b, /\/booking\/\[\\\\w\.-\]\+\\\\\.\(\?:js\|css\|json\)/);
});
