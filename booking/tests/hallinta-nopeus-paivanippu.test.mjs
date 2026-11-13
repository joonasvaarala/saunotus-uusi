// Hallinnan nopeus (t427u, PR B / booking_276): admin_ui_texts + kevyt admin_day_data, varapolut vanhaan kantaan.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { getSiteTexts, clearSiteTextsCache } from '../admin/site-texts-cache.js';
import { createAdminMock } from '../admin/options-mock.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = (p) => readFileSync(join(root, p), 'utf8');
const T = (k) => ({ ok: true, texts: [{ key: k, lang: 'fi', text: 'x' }] });
const mig = readdirSync(join(root, 'supabase/migrations')).filter((f) => /_booking_276_/.test(f));
const rb = readdirSync(join(root, 'supabase/rollbacks')).filter((f) => /_booking_276_ROLLBACK/.test(f));

test('tekstit: admin_ui_texts ensin, yksi kutsu', async () => {
  clearSiteTextsCache();
  const calls = [];
  const rpc = async (n) => { calls.push(n); return T('ui.admin.a'); };
  await Promise.all([getSiteTexts(rpc), getSiteTexts(rpc)]);
  assert.deepEqual(calls, ['admin_ui_texts']);
});

test('tekstit: puuttuva admin_ui_texts (vanha kanta) → public_get_site_texts, eikä uutta yritystä istunnossa', async () => {
  clearSiteTextsCache();
  const calls = [];
  const rpc = async (n) => { calls.push(n); if (n === 'admin_ui_texts') throw Object.assign(new Error('Could not find the function'), { status: 404, code: 'PGRST202' }); return T('ui.admin.b'); };
  assert.equal((await getSiteTexts(rpc)).texts[0].key, 'ui.admin.b');
  assert.deepEqual(calls, ['admin_ui_texts', 'public_get_site_texts']);
});

test('tekstit: kelvoton admin_ui_texts-vastaus → varapolku', async () => {
  clearSiteTextsCache();
  const calls = [];
  const rpc = async (n) => { calls.push(n); return n === 'admin_ui_texts' ? { ok: false } : T('ui.admin.c'); };
  assert.equal((await getSiteTexts(rpc)).ok, true);
  assert.deepEqual(calls, ['admin_ui_texts', 'public_get_site_texts']);
});

test('päivänäkymä: päivänvaihto admin_day_data, varapolku admin_day_bundle; tekstit välimuistista', () => {
  const day = src('admin/views/day.js');
  assert.match(day, /rpc\('admin_day_data', \{ p_date: d \}\)/);
  assert.match(day, /if \(!rpcMissing\(e\)\) throw e; dataMissing = Date\.now\(\);/);
  assert.match(day, /return rpc\('admin_day_bundle', \{ p_date: d \}\);/);
  assert.match(day, /cachedDayBundle\(date, fetchDay\)/);
  assert.equal(day.includes("bundle.site_texts?.texts || []"), false, 'kevyessä nipussa ei tekstejä: [] ei saa korvata välimuistia');
  assert.match(src('admin/admin.js'), /rpc\('admin_day_bundle', \{ p_date: date \}\)/, 'avaus käyttää edelleen täyttä nippua');
});

test('mock: admin_day_data = nipun osajoukko, admin_ui_texts = tekstit', () => {
  const m = createAdminMock({ role: 'manager' });
  const b = m.handlers ? null : null;  // handlers eivät ole julkisia; käytetään rpc:tä
  return Promise.all([m.rpc('admin_day_bundle', { p_date: '2026-11-10' }), m.rpc('admin_day_data', { p_date: '2026-11-10' }), m.rpc('admin_ui_texts', { p_lang: null })]).then(([full, light, tx]) => {
    assert.deepEqual(Object.keys(light).sort(), ['addons', 'date', 'extras', 'light', 'notes_bundle', 'options', 'reservations', 'shifts', 'view']);
    for (const k of ['view', 'reservations', 'shifts', 'addons', 'options', 'extras', 'notes_bundle']) assert.deepEqual(light[k], full[k], k);
    assert.equal(tx.ok, true);
    void b;
  });
});

test('booking_276: migraatio + rollback + SQL-testi; ei public-skeemaa; rollback palauttaa vanhan site_texts-rivin', () => {
  assert.equal(mig.length, 1); assert.equal(rb.length, 1);
  const m = src(`supabase/migrations/${mig[0]}`), r = src(`supabase/rollbacks/${rb[0]}`);
  assert.match(m, /CREATE OR REPLACE FUNCTION booking\.admin_ui_texts\(p_lang text DEFAULT NULL::text\)/);
  assert.match(m, /CREATE OR REPLACE FUNCTION booking\.admin_day_data\(p_date date\)/);
  assert.match(m, /'site_texts', booking\.admin_ui_texts\(null\)/);
  assert.match(m, /revoke all on function booking\.admin_ui_texts\(text\) from public, anon;/);
  assert.match(m, /revoke all on function booking\.admin_day_data\(date\) from public, anon;/);
  assert.equal(/\bpublic\.[a-z_]+\s*\(/i.test(m.replace(/--.*$/gm, '')), false, 'ei public-skeeman funktioita');
  assert.equal(/^\s*(begin|commit);/im.test(m), false, 'ei begin/commit-kääreitä');
  assert.match(r, /'site_texts', booking\.public_get_site_texts\(null\)/);
  assert.match(r, /drop function if exists booking\.admin_day_data\(date\);/);
  assert.match(r, /drop function if exists booking\.admin_ui_texts\(text\);/);
  assert.ok(r.indexOf('admin_day_bundle') < r.indexOf('drop function if exists booking.admin_ui_texts'), 'nippu palautetaan ennen kuin sen käyttämä funktio poistetaan');
  assert.match(src('supabase/tests/hallinta/t276_day_bundle_light.sql'), /TESTRESULT pass=/);
});
