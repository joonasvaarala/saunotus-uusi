// Tapahtumatuotteen varaus: päivänapit ja kellonajat, ei kuukausikalenteria.
// Yleiset vuorot, hoidot ja yksityisvuorot pitävät kuukausikalenterin. Tekstit pending-import-101.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { T } from '../shop/src/i18n.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const read = (rel) => readFileSync(join(repo, rel), 'utf8');
const NOW = Date.parse('2026-10-29T10:00:00Z');
const { groupEventDays, eventDayLabel } = await import(pathToFileURL(join(root, 'shop/src/event-pick.js')).href);

const slot = (date, hh, status, rule, endHour = hh + 2) => ({
  rule_id: rule, status, session_date: date,
  starts_at: `${date}T${String(hh).padStart(2, '0')}:00:00Z`,
  ends_at: `${date}T${String(endHour).padStart(2, '0')}:00:00Z`,
});

test('groupEventDays: aikajärjestys, täysi päivä, yksi kerta säilyy, menneet ja unavailable pois', () => {
  const days = groupEventDays({
    '2026-11-20': [slot('2026-11-20', 16, 'available', 2), slot('2026-11-20', 14, 'full', 3)],
    '2026-11-13': [slot('2026-11-13', 16, 'available', 1)],
    '2026-11-27': [slot('2026-11-27', 16, 'full', 4), slot('2026-11-27', 18, 'unavailable', 5)],
    '2026-10-01': [slot('2026-10-01', 16, 'available', 9)],
    '2026-10-29': [slot('2026-10-29', 8, 'available', 8, 9)],
    'ei-paiva': [slot('2026-11-13', 16, 'available', 7)],
  }, { now: NOW, today: '2026-10-29' });
  assert.deepEqual(days.map((d) => d.date), ['2026-11-13', '2026-11-20', '2026-11-27']);
  assert.equal(days[0].slots.length, 1, 'yksi kellonaika jää yhdeksi napiksi');
  assert.equal(days[0].full, false);
  assert.deepEqual(days[1].slots.map((r) => r.rule_id), [3, 2], 'kerrat alkamisajan mukaan');
  assert.equal(days[1].full, false, 'yksi vapaa kerta pitää päivän varattavana');
  assert.equal(days[2].full, true);
  assert.equal(days[2].slots.length, 1, 'unavailable ei näy');
  assert.deepEqual(groupEventDays(null), []);
});

test('eventDayLabel: pe 13.11. / Fri 13 Nov, muu vuosi vuoden kanssa', () => {
  assert.equal(eventDayLabel('2026-11-13', 'fi', NOW), 'pe 13.11.');
  assert.equal(eventDayLabel('2026-11-13', 'en', NOW), 'Fri 13 Nov');
  assert.equal(eventDayLabel('2027-02-06', 'fi', NOW), 'la 6.2.2027');
  assert.equal(eventDayLabel('2027-02-06', 'en', NOW), 'Sat 6 Feb 2027');
  assert.equal(eventDayLabel('x', 'fi', NOW), '');
});

test('kauppa: tapahtuma käyttää päivänappeja, muu tuote kuukausikalenteria', () => {
  const src = read('booking/shop/src/shop.js');
  const body = src.slice(src.indexOf('async function viewProduct'), src.indexOf('\nfunction slotItem'));
  assert.match(body, /const eventProduct = p\.category === 'event'/);
  assert.match(body, /groupEventDays\(byDay/);
  assert.match(body, /class: 'bk-ev-dates'/);
  assert.match(body, /'aria-pressed': 'false'/);
  assert.match(body, /data-testid': 'event-time'/);
  assert.match(body, /t\.eventPickTime/);
  assert.match(body, /t\.eventNoDates/);
  assert.match(body, /t\.full/);
  assert.match(body, /t\.eventWaitlistCta/);
  assert.match(body, /\/jono\/\$\{r\.rule_id\}/);
  assert.match(body, /\/varaa\/\$\{r\.rule_id\}/);
  assert.match(body, /if \(eventProduct\) \{ await fillEventDates/);
  assert.match(body, /class: 'bk-calnav'/);
  assert.match(body, /class: 'bk-grid'/);
  assert.doesNotMatch(body, /slots\.length === 1[\s\S]{0,120}(?:location|drawSlots)/);
  assert.match(read('booking/shop/src/shop.css'), /\.bk-ev-date\[aria-pressed="true"\]/);
  assert.match(read('booking/shop/src/shop.css'), /\.bk-ev-date:focus-visible,\.bk-ev-time:focus-visible/);
  assert.match(read('booking/shop/src/shop.css'), /\.bk-ev-date\.is-full,\.bk-ev-time\.is-full/);
});

test('pending-import-101: FI+EN, sama kuin koodin oletus, ei vielä varatekstissä, ei päällekkäin', () => {
  const rows = JSON.parse(read('content/site-texts.pending-import-101.json'));
  const fallback = JSON.parse(read('content/site-texts.fallback.json'));
  const have = new Set(fallback.texts.map((r) => `${r.key}|${r.lang}`));
  const want = {
    'ui.shop.event_pick_time': { fi: T.fi.eventPickTime, en: T.en.eventPickTime },
    'ui.shop.event_no_dates': { fi: T.fi.eventNoDates, en: T.en.eventNoDates },
  };
  assert.equal(rows.length, 4);
  const seen = new Set();
  for (const r of rows) {
    assert.equal(r.text, want[r.key][r.lang], `${r.key} ${r.lang}`);
    assert.equal(r.class, 'normal');
    assert.equal(r.kind, 'plain');
    assert.ok(r.max_len >= r.text.length && r.max_len <= 100000);
    assert.deepEqual(r.placeholders, []);
    assert.equal(have.has(`${r.key}|${r.lang}`), false);
    assert.doesNotMatch(r.text, /[<>]|https?:\/\/|www\./);
    assert.ok(!seen.has(`${r.key}|${r.lang}`));
    seen.add(`${r.key}|${r.lang}`);
  }
  for (const k of Object.keys(want)) assert.ok(seen.has(`${k}|fi`) && seen.has(`${k}|en`), k);
  for (const f of readdirSync(join(repo, 'content')).filter((n) => /^site-texts\.(pending-import|imported).*\.json$/.test(n) && n !== 'site-texts.pending-import-101.json')) {
    const other = JSON.parse(readFileSync(join(repo, 'content', f), 'utf8'));
    if (!Array.isArray(other)) continue;
    for (const r of other) assert.equal(Object.hasOwn(want, r.key), false, `${r.key} on jo tiedostossa ${f}`);
  }
  assert.match(read('.github/workflows/pages.yml'), /node --test booking\/tests\/tapahtuma-paivat\.test\.mjs/);
});

test('mock events=1 on erillinen lippu: oletuskatalogi ei saa tapahtumaa', () => {
  const src = read('booking/shop/src/shop-mock.js');
  assert.match(src, /events=1/);
  assert.match(src, /\.\.\.\(eventsOn \? \[EVENT_DEMO\] : \[\]\)/);
  assert.match(src, /public_availability' && eventsOn && \+args\.p_product_id === 31/);
  assert.match(src, /slug: 'perinnesaunotusilta'/);
  assert.match(src, /category: 'event'/);
  assert.match(read('booking/shop/src/shop.js'), /'events'/);
});
