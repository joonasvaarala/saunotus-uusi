import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { cachedDayBundle, seedDayBundle, clearDayBundles } from '../admin/day-bundle-cache.js';
import { getSiteTexts, primeSiteTexts, clearSiteTextsCache } from '../admin/site-texts-cache.js';
import { ensureAllMonths, resetMonthAvailabilityLoader } from '../shop/src/availability-months.js';

const migration = new URL('../supabase/migrations/20261024070000_booking_133_day_and_availability_speedup.sql', import.meta.url);
const read = (url) => readFile(url, 'utf8');

test('admin_day_bundle käyttää 9 argumenttia ja sisältää alkulatauksen', async () => {
  const sql = await read(migration);
  const block = sql.split('create or replace function booking.admin_day_bundle(')[1];
  const params = block.match(/admin_list_reservations\(([^)]*)\)/)?.[1]?.split(/\s*,\s*/);
  assert.equal(params?.length, 9); // booking_132: admin_list_reservations(…, p_option_missing) – kaikki 9 argumenttia eksplisiittisesti
  assert.deepEqual(params, ['v_from', 'v_to', 'null', 'null', 'null', '200', '0', 'null', 'null']);
  for (const field of ['role', 'permissions', 'products', 'payment_methods', 'resources', 'site_texts']) {
    assert.match(block, new RegExp(`'${field}'`));
  }
});

test('päivänippu: vain yksi RPC per päivä; rinnakkaiset kutsut jakavat saman lupauksen', async () => {
  clearDayBundles();
  let calls = 0;
  const loader = async (d) => { calls++; await Promise.resolve(); return { date: d, view: { sessions: [] } }; };
  const [a, b] = await Promise.all([
    cachedDayBundle('2026-10-24', loader), cachedDayBundle('2026-10-24', loader),
  ]);
  assert.deepEqual(a, b);
  assert.equal(calls, 1);
  await cachedDayBundle('2026-10-24', loader);
  assert.equal(calls, 1);
  clearDayBundles();
  await cachedDayBundle('2026-10-24', loader);
  assert.equal(calls, 2);
  seedDayBundle('2026-10-25', { date: '2026-10-25', view: {} });
  await cachedDayBundle('2026-10-25', loader);
  assert.equal(calls, 2);
});

test('site_texts: yhdellä lupauksella kaikille moduuleille, myös bundlesta', async () => {
  clearSiteTextsCache();
  let calls = 0;
  const rpc = async (name) => { assert.equal(name, 'public_get_site_texts'); calls++; return { ok: true, texts: [] }; };
  await Promise.all([getSiteTexts(rpc), getSiteTexts(rpc), getSiteTexts(rpc)]);
  assert.equal(calls, 1);
  clearSiteTextsCache();
  primeSiteTexts({ ok: true, texts: [{ key: 'ui.test', text: 'test' }] });
  assert.equal((await getSiteTexts(rpc)).texts[0].key, 'ui.test');
  assert.equal(calls, 1);
});

test('kauppa: koko lokakuu kaikille tuotteille yhdellä kutsulla', async () => {
  resetMonthAvailabilityLoader();
  const months = new Map(), seen = [];
  const catalog = [{ id: 1 }, { id: 7 }, { id: 48 }];
  const rpc = async (name, args) => {
    seen.push([name, args]);
    return [
      { product_id: 7, session_date: '2026-10-25', starts_at: '2026-10-25T16:00:00Z', status: 'full' },
      { product_id: 1, session_date: '2026-10-25', starts_at: '2026-10-25T15:00:00Z', status: 'available' },
    ];
  };
  let legacy = 0;
  const options = { pairs: [[2026, 9]], catalog, months, rpc, fallback: async () => { legacy++; }, audience: 'consumer' };
  await Promise.all([ensureAllMonths(options), ensureAllMonths(options)]);
  assert.equal(seen.length, 1);
  assert.equal(seen[0][0], 'public_availability_all');
  assert.deepEqual(seen[0][1], { p_from: '2026-10-01', p_to: '2026-10-31', p_audience: 'consumer' });
  assert.equal(legacy, 0);
  assert.equal(months.size, 3);
  assert.deepEqual(months.get('48:2026-9'), {});
  assert.equal(months.get('7:2026-9')['2026-10-25'][0].status, 'full');
});

test('kauppa: PGRST202/42883 -> automaattinen tuotekohtainen varapolku', async () => {
  resetMonthAvailabilityLoader();
  const months = new Map();
  let calls = 0, old = 0;
  const opts = { pairs: [[2026, 9]], catalog: [{ id: 1 }, { id: 7 }], months,
    rpc: async () => { calls++; throw Object.assign(new Error('function does not exist'), { code: '42883' }); },
    fallback: async (id, y, m) => { old++; months.set(`${id}:${y}-${m}`, {}); },
  };
  await ensureAllMonths(opts);
  assert.equal(calls, 1);
  assert.equal(old, 2);
  months.clear();
  await ensureAllMonths(opts);
  assert.equal(calls, 1); // Puuttuvaa RPC:tä ei kysellä jatkuvasti
  assert.equal(old, 4);
});

// booking_125:n kuormitusmalli: maksimikuorma jokaisessa claim-alkuhetkessä.
const peakOld = (claims, start, end) => {
  const rs = claims.filter((r) => r.start < end && r.end > start);
  const times = [start, ...rs.map((r) => r.start).filter((t) => t > start && t < end)];
  return Math.max(0, ...times.map((t) => rs.reduce((n, r) => n + (r.start <= t && r.end > t ? r.n : 0), 0)));
};
// booking_133 / _pool_peak: päättyvä claim vähennetään samassa hetkessä ennen alun lisäämistä.
const peakNew = (claims, start, end) => {
  const rs = claims.filter((r) => r.start < end && r.end > start);
  let load = rs.filter((r) => r.start <= start).reduce((n, r) => n + r.n, 0);
  let max = load;
  const events = new Map();
  for (const r of rs) {
    if (r.start > start && r.start < end) events.set(r.start, (events.get(r.start) || 0) + r.n);
    if (r.end > start && r.end < end) events.set(r.end, (events.get(r.end) || 0) - r.n);
  }
  for (const t of [...events.keys()].sort((a, b) => a - b)) { load += events.get(t); max = Math.max(load, max); }
  return Math.max(max, 0);
};

test('pool_peak: 500 arvottua claim-ikkunaa, offsetit ja peräkkäiset varaukset täsmäävät', () => {
  let seed = 0x12345678;
  const rand = () => ((seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0) / 2 ** 32);
  for (let i = 0; i < 500; i++) {
    const claims = Array.from({ length: 50 }, () => {
      const start = Math.floor(rand() * 200) - 50; // myös ennen ikkunaa alkaneet claimit
      return { start, end: start + 1 + Math.floor(rand() * 65), n: 1 + Math.floor(rand() * 7) };
    });
    assert.equal(peakNew(claims, 0, 150), peakOld(claims, 0, 150));
  }
  assert.equal(peakNew([{ start: 0, end: 10, n: 6 }, { start: 10, end: 20, n: 4 }], 0, 20), 6);
});

test('SQL: sessions käyttää esisuodatettua tilakuormaa, ja yksittäistä materialisoitua poolitulosta', async () => {
  const sql = await read(migration);
  const sessions = sql.split('create or replace function booking._sessions(')[1].split('create or replace function booking.public_availability_all(')[0];
  assert.match(sessions, /active_space as materialized/);
  assert.match(sessions, /active_blocks as materialized/);
  assert.match(sessions, /calc as materialized/);
  assert.equal((sessions.match(/booking\._pools_remaining\(/g) || []).length, 1);
  assert.match(sql, /reservation_legs l\s+join booking\.reservations r/);
  // claim-lausekeindeksi ei ole mahdollinen (timestamptz + interval ei ole IMMUTABLE); olemassa olevat indeksit kattavat varaukset, uusi osittainen gist kattaa jaetut legit
  assert.match(sql, /create index if not exists reservation_legs_shared_during_133_idx\s+on booking\.reservation_legs using gist \(during\) where mode = 'shared'/);
  assert.doesNotMatch(sql, /create index[^;]*claim_offset_min/i);
});
