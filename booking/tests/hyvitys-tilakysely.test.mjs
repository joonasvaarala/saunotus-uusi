// Hallinta › Tilaukset › Avoimet maksut › Hyvitykset: "Tarkista tila Montoniosta". VAIN LUKU: ainoa kutsu on
// montonio-refund {action:'status', refund_id}; ei montonio_refund_claimia, ei hyvitystä, ei RPC-kirjoituksia.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { canCheckStatus, checkRefundStatus, statusCheckView } from '../admin/refund-status-logic.js';
import { createRefundWatchApi } from '../admin/refund-watch-api.js';
import { RS_TEXTS, rs } from '../admin/refund-status-texts.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = (p) => readFileSync(join(root, p), 'utf8');

test('nappi vain Montonio-hyvitykselle, joka on requested tai processing', () => {
  assert.equal(canCheckStatus({ refund_id: 68, provider: 'montonio', status: 'processing' }), true);
  assert.equal(canCheckStatus({ refund_id: 68, provider: 'montonio', status: 'requested' }), true);
  assert.equal(canCheckStatus({ refund_id: 68, provider: 'montonio', status: 'failed' }), false);
  assert.equal(canCheckStatus({ refund_id: 68, provider: 'mobilepay', status: 'processing' }), false);
  assert.equal(canCheckStatus({ refund_id: null, provider: 'montonio', status: 'processing' }), false);
});

test('nappi kutsuu vain montonio-refund {action:"status"}: ei rpc-kutsuja, ei hyvitystä', async () => {
  const fnCalls = [], rpcCalls = [];
  const fn = async (name, body) => { fnCalls.push([name, body]); return { ok: true, mode: 'live', local: { refund_id: 68, status: 'processing', provider_status: 'PENDING', amount: 18 }, montonio: { ok: true, found: true, refund: { status: 'PENDING', amount: 18, createdAt: '2026-11-22T10:00:00Z' }, order: { paymentStatus: 'PAID' } } }; };
  const rpc = async (name, args) => { rpcCalls.push([name, args]); return {}; };
  const api = createRefundWatchApi({ rpc, fn });
  const res = await api.statusCheck(68);
  assert.deepEqual(fnCalls, [['montonio-refund', { action: 'status', refund_id: 68 }]]);
  assert.deepEqual(Object.keys(fnCalls[0][1]).sort(), ['action', 'refund_id']);
  assert.deepEqual(rpcCalls, []);
  const v = statusCheckView(res, { money: (n) => `${n} €`, date: (d) => d });
  assert.deepEqual(v.local.map(([, x]) => x), ['processing', 'PENDING', '18 €']);
  assert.deepEqual(v.montonio.map(([, x]) => x), ['PENDING', '18 €', '2026-11-22T10:00:00Z', 'PAID']);
  assert.deepEqual(v.notes, []);
});

test('näkymä: napin käsittelijä käyttää vain statusCheckiä, ei retryä, manualia, providerRefundia eikä load()-uudelleenlatausta', () => {
  const view = src('admin/views/refund-watch.js');
  const fnBody = view.slice(view.indexOf('async function statusCheck('), view.indexOf('function manual('));
  assert.match(fnBody, /api\.statusCheck\(row\.refund_id\)/);
  assert.doesNotMatch(fnBody, /api\.(retry|manual|providerRefund|list)|rpc\(|fn\(|load\(\)|notifyOpenPaymentsChanged/);
  assert.match(view, /if \(canCheckStatus\(row\)\)/);
  assert.match(view, /'data-testid': 'refund-watch-status'/);
  const logic = src('admin/refund-status-logic.js').replace(/^\s*(\/\/|\/\*\*).*$/gm, '');
  assert.equal((logic.match(/fn\(/g) || []).length, 1);
  assert.match(logic, /fn\('montonio-refund', \{ action: 'status', refund_id: Number\(refundId\) \}\)/);
  assert.doesNotMatch(logic, /claim|rpc|POST/i);
});

test('tilat off / not_configured / not_found / forbidden ja virheet näkyvät selkeänä tekstinä', async () => {
  const P = 'ui.admin.refund_watch.status_check.';
  const local = { refund_id: 68, status: 'processing', provider_status: 'PENDING', amount: 18 };
  assert.deepEqual(statusCheckView({ ok: true, mode: 'off', local, montonio: null, code: 'off' }).notes, [{ key: P + 'off' }]);
  assert.deepEqual(statusCheckView({ ok: true, mode: 'live', local, montonio: null, code: 'not_configured' }).notes, [{ key: P + 'not_configured' }]);
  assert.deepEqual(statusCheckView({ ok: true, mode: 'live', local, montonio: { ok: false, code: 'no_provider_refund_id' } }).notes, [{ key: P + 'no_provider_refund_id' }]);
  assert.deepEqual(statusCheckView({ ok: true, mode: 'live', local, montonio: { ok: true, found: false, refund: null, order: {} } }).notes, [{ key: P + 'montonio_missing' }]);
  const err = (status, code) => async () => { const e = new Error('x'); e.status = status; if (code) e.code = code; throw e; };
  assert.equal((await checkRefundStatus(err(403, 'forbidden'), 68)).code, 'forbidden');
  assert.equal((await checkRefundStatus(err(401), 68)).code, 'forbidden');
  assert.equal((await checkRefundStatus(err(404, 'not_found'), 68)).code, 'not_found');
  assert.deepEqual(statusCheckView({ ok: false, code: 'forbidden' }).notes, [{ key: P + 'forbidden' }]);
  assert.deepEqual(statusCheckView({ ok: false, code: 'not_found' }).notes, [{ key: P + 'not_found' }]);
  assert.deepEqual(statusCheckView({ ok: false, code: 'boom', message: 'Palvelin' }).notes, [{ key: P + 'error', vars: { error: 'Palvelin' } }]);
  assert.equal(rs(P + 'button', {}, 'fi'), 'Tarkista tila Montoniosta');
  assert.equal(rs(P + 'button', {}, 'en'), 'Check status from Montonio');
});

test('tuonti 196: FI+EN, vastaa sanakirjaa, ei päällekkäin muiden tuontien kanssa', () => {
  const rows = JSON.parse(src('../content/site-texts.pending-import-196.json'));
  assert.deepEqual(Object.keys(RS_TEXTS.fi).sort(), Object.keys(RS_TEXTS.en).sort());
  assert.equal(rows.length, Object.keys(RS_TEXTS.fi).length * 2);
  const taken = new Set();
  for (const f of readdirSync(join(root, '../content'))) {
    if (f === 'site-texts.pending-import-196.json' || !/^site-texts\.(pending-import-|imported)/.test(f) || !f.endsWith('.json')) continue;
    const j = JSON.parse(readFileSync(join(root, '../content', f), 'utf8'));
    for (const r of (Array.isArray(j) ? j : j.texts || [])) if (r?.key) taken.add(`${r.key}|${r.lang}`);
  }
  for (const r of rows) {
    assert.equal(RS_TEXTS[r.lang][r.key], r.text, r.key);
    assert.equal(taken.has(`${r.key}|${r.lang}`), false, r.key);
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain');
    assert.ok(r.text.length <= r.max_len);
    assert.deepEqual(r.placeholders, [...r.text.matchAll(/\{\{var:[a-z0-9_]+\}\}/g)].map((m) => m[0]));
  }
  const view = src('admin/views/refund-watch.js') + src('admin/refund-status-logic.js');
  for (const k of new Set(view.match(/status_check\.[a-z_]+/g))) if (!k.endsWith('.')) assert.ok(RS_TEXTS.fi[`ui.admin.refund_watch.${k}`], k);
  assert.match(readFileSync(join(root, '../.github/workflows/pages.yml'), 'utf8'), /hyvitys-tilakysely\.test\.mjs/);
});
