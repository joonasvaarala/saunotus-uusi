// Visma Pay: kauppanappi testitilassa, ohjaus vain Vismaan, hallinnan hyvityskutsu, tuontitekstit.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { normVisma, shouldShowVisma, safeVismaRedirect, classifyVisma } from '../shop/src/vismapay-logic.js';
import { VT } from '../shop/src/vismapay-texts.js';
import { createTalousApi } from '../admin/talous-api.js';
import { TEXTS } from '../admin/talous-texts.js';
import { VISMAPAY_TEXTS } from '../admin/vismapay-texts.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const pending = JSON.parse(readFileSync(join(root, 'content/site-texts.pending-import-28.json'), 'utf8'));
const { collectDefaults, classFor } = await import(pathToFileURL(join(root, 'booking/shop/src/text-registry.js')).href);
const { tokensOf, KEY_RE, TOKEN_RE, KINDS } = await import(pathToFileURL(join(root, 'booking/shop/src/site-texts-logic.js')).href);
const doc = readFileSync(join(root, 'docs/vismapay-integraatio.md'), 'utf8');

const method = (testFlag) => ({ code: 'visma_pay', test: testFlag });
const opts = (testFlag) => ({ ok: true, methods: [method(testFlag)], order: { can_pay_online: true, unpaid: 40 } });

test('testitilan painike näkyy ilman MobilePayn testikäyttöliittymää', () => {
  assert.equal(shouldShowVisma(normVisma(opts(true))), true);
  assert.equal(shouldShowVisma(normVisma(opts(false))), true);
  assert.equal(shouldShowVisma(normVisma({ ok: true, methods: [], order: { can_pay_online: true } })), false);
  assert.equal(shouldShowVisma(normVisma({ ok: false })), false);
});

test('ohjaus hyväksyy vain Visma Payn token-sivun', () => {
  assert.equal(safeVismaRedirect('https://www.vismapay.com/pbwapi/token/tokentokentoken'), 'https://www.vismapay.com/pbwapi/token/tokentokentoken');
  assert.equal(safeVismaRedirect('https://evil.example/pbwapi/token/tokentokentoken'), null);
  assert.equal(safeVismaRedirect('http://www.vismapay.com/pbwapi/token/tokentokentoken'), null);
});

test('kaupan tekstit: FI ja EN samat avaimet', () => {
  assert.deepEqual(Object.keys(VT.fi).sort(), Object.keys(VT.en).sort());
  for (const k of Object.keys(VT.fi)) assert.ok(VT.fi[k] && VT.en[k], k);
  assert.equal(classifyVisma({ ok: true, payment_status: 'paid', results: [{ outcome: 'paid' }] }), 'paid');
  assert.equal(classifyVisma({ ok: true, results: [{ outcome: 'needs_review' }] }), 'review');
  assert.equal(classifyVisma({ ok: false, code: 'network' }), 'net');
});

test('admin: vismapayRefund kutsuu vismapay-refund ja tulkitsee tuloksen', async () => {
  const calls = [];
  const api = createTalousApi({ rpc: async () => ({ ok: true }), mock: false, io: { fn: async (name, body) => { calls.push([name, body]); return { ok: true, mode: 'test', processed: [{ refund_id: 9, result: 'done' }] }; } } });
  assert.deepEqual(await api.vismapayRefund(9), { result: 'done', detail: null });
  assert.deepEqual(calls[0], ['vismapay-refund', { refund_id: 9 }]);
  const off = createTalousApi({ rpc: async () => ({}), mock: false, io: { fn: async () => ({ ok: true, mode: 'off', processed: [] }) } });
  assert.equal((await off.vismapayRefund(9)).result, 'off');
  const dry = createTalousApi({ rpc: async () => ({}), mock: false, io: { fn: async () => ({ ok: true, mode: 'dry_run', processed: [] }) } });
  assert.equal((await dry.vismapayRefund(9)).result, 'off');
  const src = readFileSync(new URL('../admin/views/talous-orders.js', import.meta.url), 'utf8');
  assert.match(src, /provider === 'visma_pay'\) await processVismaRefund/);
});

test('hyvitystekstit kattavat Visma Payn tulokset', () => {
  for (const k of ['done', 'failed', 'retry_later', 'awaiting_customer', 'unverified', 'db_error', 'none', 'off', 'forbidden', 'error', 'not_settled', 'not_configured']) {
    for (const l of ['fi', 'en']) assert.ok(TEXTS[l][`refund.vp.${k}`], `${l} ${k}`);
  }
  assert.equal(Object.keys(VISMAPAY_TEXTS.fi).sort().join(), Object.keys(VISMAPAY_TEXTS.en).sort().join());
});

test('pending-import-28: kauppa, hallinnan tila ja hyvitystekstit', () => {
  const seen = new Set();
  for (const r of pending) {
    const w = `${r.key} [${r.lang}]`;
    assert.match(r.key, KEY_RE, w);
    assert.ok(['fi', 'en'].includes(r.lang), w);
    assert.ok(['normal', 'protected'].includes(r.class), w);
    assert.equal(r.kind, 'plain', w);
    assert.ok(r.max_len >= r.text.length && r.max_len <= 100000, w);
    assert.equal(r.text.trim(), r.text, w);
    assert.doesNotMatch(r.text, /[<>]|https?:\/\/|www\./, w);
    assert.deepEqual([...r.placeholders].sort(), [...tokensOf(r.text)].sort(), w);
    for (const tok of tokensOf(r.text)) assert.ok(TOKEN_RE.test(tok) && KINDS.includes(tok.slice(2, -2).split(':')[0]), tok);
    assert.ok(r.reason && r.reason.length <= 300, w);
    assert.ok(!seen.has(`${r.key}|${r.lang}`), w);
    seen.add(`${r.key}|${r.lang}`);
  }
  for (const row of collectDefaults().filter((r) => r.id === 'VT')) {
    const got = pending.find((r) => r.key === row.key && r.lang === row.lang);
    assert.ok(got, row.key);
    assert.equal(got.text, row.text);
    const fi = collectDefaults().find((r) => r.id === 'VT' && r.key === row.key && r.lang === 'fi').text;
    assert.equal(got.class, classFor(row.key, fi));
  }
  for (const lang of ['fi', 'en']) for (const [key, text] of Object.entries(VISMAPAY_TEXTS[lang])) {
    const got = pending.find((r) => r.key === key && r.lang === lang);
    assert.equal(got?.text, text, key);
  }
  const refundKeys = ['refund.visma', ...Object.keys(TEXTS.fi).filter((k) => k.startsWith('refund.vp.'))];
  for (const short of refundKeys) {
    const key = short === 'refund.visma' ? 'ui.admin.talous.refund_visma' : `ui.admin.talous.${short.replace(/\./g, '_')}`;
    for (const lang of ['fi', 'en']) assert.equal(pending.find((r) => r.key === key && r.lang === lang)?.text, TEXTS[lang][short], key);
  }
  for (const pan of ['4012888888881881', '4917300800000000']) assert.equal(doc.includes(pan), true);
});
