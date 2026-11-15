// PR #386: hoitojen saatavuushaut ajetaan yksi kerrallaan (palvelin sallii vain yhden raskaan haun; toinen saa HTTP 400 busy). Busy-uudelleenyritys säilyy.
import test from 'node:test';
import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = resolve(new URL('..', import.meta.url).pathname);
// treatments.js tuo ./sb.js:n → väliaikainen kopio, jossa sb.js on mock (ei verkkoa).
const tmp = join(mkdtempSync(join(process.env.TMPDIR || tmpdir(), 'hoitohaku-')), 'shop');
cpSync(join(root, 'shop/src'), tmp, { recursive: true });
writeFileSync(join(tmp, 'sb.js'), `export class ApiError extends Error {}
export async function rpc(name, a) { return globalThis.__RPC(name, a); }
`);
const T = await import(pathToFileURL(join(tmp, 'treatments.js')));

const p = (id) => ({ id, duration_minutes: 60 });
const row = (id, day) => ({ product_id: id, session_date: day, starts_at: `${day}T14:00:00Z`, ends_at: `${day}T15:00:00Z`, status: 'available', total: 50 });

test('hoitohaut: enintään yksi raskas haku kerrallaan, vaikka haetaan usea tuote yhtä aikaa', async () => {
  let active = 0, max = 0, calls = 0;
  globalThis.__RPC = async (name, a) => {
    calls++; active++; max = Math.max(max, active);
    await new Promise((r) => setTimeout(r, 15));
    active--;
    return [row(a.p_product_id, a.p_from)];
  };
  T.clearCache();
  const res = await Promise.all([1, 2, 3, 4].map((id) => T.loadAvailability(p(id), 1, '2026-12-01', '2026-12-01')));
  assert.equal(calls, 4);
  assert.equal(max, 1, 'rinnakkaisia hakuja enintään 1');
  assert.deepEqual(res.map((m) => [...m.keys()]), [['2026-12-01'], ['2026-12-01'], ['2026-12-01'], ['2026-12-01']]);
});

test('hoitohaut: busy-vastaus yritetään uudelleen ja onnistuu', async () => {
  let n = 0;
  globalThis.__RPC = async (name, a) => {
    if (++n === 1) { const e = new Error('busy'); e.code = 'busy'; throw e; }
    return [row(a.p_product_id, a.p_from)];
  };
  T.clearCache();
  const m = await T.loadAvailability(p(9), 1, '2026-12-02', '2026-12-02');
  assert.equal(n, 2, 'toinen yritys busyn jälkeen');
  assert.deepEqual([...m.keys()], ['2026-12-02']);
});

test('hoitohaut: virhe ei jätä jonoa jumiin', async () => {
  globalThis.__RPC = async () => { const e = new Error('rikki'); e.code = 'bad_range'; throw e; };
  T.clearCache();
  await assert.rejects(T.loadAvailability(p(5), 1, '2026-12-03', '2026-12-03'));
  globalThis.__RPC = async (name, a) => [row(a.p_product_id, a.p_from)];
  T.clearCache();
  const m = await T.loadAvailability(p(6), 1, '2026-12-03', '2026-12-03');
  assert.deepEqual([...m.keys()], ['2026-12-03']);
});

test('horizonDays: public_settings-arvo, varalla POLICY', () => {
  assert.equal(T.horizonDays({ public_treatment_horizon_days: 90 }), 90);
  assert.equal(T.horizonDays(null), T.POLICY.horizonDays);
  assert.equal(T.horizonDays({}), 14);
});
