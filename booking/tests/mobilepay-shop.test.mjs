// MobilePay-maksun kauppalogiikka (sopimus KOODARI_talous_A_D_fi.md §14): painikkeen näyttöpäätös, testitilan piilotus, paluutilan luokittelu ja polling (väärennetty kello),
// edge-funktiokutsujen muodot (virheet eivät heitä), FI/EN-tekstipariteetti, mock vs. sopimus ja admin-hyvityksen jatkokutsu.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { normOptions, shouldShowButton, testUiEnabled, safeRedirect, classifyResults, pollPayment, POLL_INTERVAL_MS, POLL_MAX_MS } from '../shop/src/mobilepay-logic.js';
import { createMobilepayApi } from '../shop/src/mobilepay-api.js';
import { MT, mt } from '../shop/src/mobilepay-texts.js';
import { createOrderMock } from '../shop/src/order-mock.js';
import { createTalousApi } from '../admin/talous-api.js';
import { TEXTS } from '../admin/talous-texts.js';

const TOKEN = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';
const method = (over = {}) => ({ code: 'mobilepay', provider: 'vipps_mobilepay', label: 'MobilePay', label_en: 'MobilePay', test: false, start: { function: 'mobilepay-start', method: 'POST', body: { order_token: TOKEN } }, ...over });
const opts = ({ methods = [method()], order = { can_pay_online: true, unpaid: 40, mobilepay_pending: false } } = {}) => ({ ok: true, online_enabled: true, methods, order });

test('tekstit: avaimet samat FI/EN, ei tyhjiä, ei emojeita, muuttujat täsmäävät', () => {
  assert.deepEqual(Object.keys(MT.fi).sort(), Object.keys(MT.en).sort());
  for (const l of ['fi', 'en']) for (const [k, v] of Object.entries(MT[l])) {
    assert.ok(typeof v === 'string' && v.trim(), `${l}.${k}`);
    assert.ok(!/\p{Extended_Pictographic}/u.test(v), `${l}.${k}: emoji`);
  }
  for (const k of Object.keys(MT.fi)) assert.deepEqual((MT.fi[k].match(/\{\w+\}/g) || []).sort(), (MT.en[k].match(/\{\w+\}/g) || []).sort(), `muuttujat ${k}`);
  assert.equal(mt('fi', 'payBtn'), 'Maksa MobilePaylla'); assert.equal(mt('en', 'payBtn'), 'Pay with MobilePay');
  assert.equal(mt('fi', 'methodTitle'), 'Maksa MobilePaylla'); assert.equal(mt('en', 'methodTitle'), 'Pay with MobilePay');
  assert.equal(mt('fi', 'payAmount', { amount: '40,00 €' }), 'Maksettava: 40,00 €');
  for (const code of ['mobilepay_off', 'not_configured', 'invalid_param', 'not_found', 'rate_limited', 'already_paid', 'nothing_to_pay', 'order_not_payable', 'payment_not_pending', 'other_provider_started', 'link_expired', 'link_stale', 'unsupported_currency', 'provider_error'])
    for (const l of ['fi', 'en']) assert.ok(MT[l][`err.${code}`], `virhekoodi ${code} (${l}) puuttuu`);   // §14.2:n kaikki koodit katettu
});

test('painikkeen näyttö: methods sisältää mobilepayn JA can_pay_online', () => {
  const env = { testUi: true };
  assert.equal(shouldShowButton(opts(), env), true);
  assert.equal(shouldShowButton(opts({ methods: [] }), env), false, 'off: methods=[]');
  assert.equal(shouldShowButton(opts({ methods: [{ code: 'visma_pay' }] }), env), false, 'muu tapa');
  assert.equal(shouldShowButton(opts({ order: { can_pay_online: false } }), env), false);
  assert.equal(shouldShowButton({ ok: true, methods: [method()] }, env), false, 'ilman tilausta ei painiketta (token vaaditaan)');
  assert.equal(shouldShowButton({ ok: false, code: 'not_found' }, env), false);
  assert.equal(shouldShowButton({ ok: false, code: 'rate_limited' }, env), false);
  assert.equal(shouldShowButton(null, env), false); assert.equal(shouldShowButton(undefined, env), false); assert.equal(shouldShowButton('x', env), false);
});
test('testitila: methods[].test=true näytetään vain testiympäristössä (tuotannossa piiloon)', () => {
  const t = opts({ methods: [method({ test: true })] });
  assert.equal(shouldShowButton(t, { testUi: false }), false, 'tuotanto + test=true → piilossa');
  assert.equal(shouldShowButton(t, {}), false, 'oletus (ei asetusta) → piilossa');
  assert.equal(shouldShowButton(t, { testUi: true }), true, 'testisivusto + test=true → näkyy');
  assert.equal(shouldShowButton(opts({ methods: [method({ test: false })] }), { testUi: false }), true, 'live (test=false) näkyy tuotannossa');
  assert.equal(normOptions(t).method.test, true); assert.equal(normOptions(opts({ order: { can_pay_online: true, mobilepay_pending: true } })).pending, true);
  assert.equal(testUiEnabled({ mobilepayTestUi: true }, ''), true); assert.equal(testUiEnabled({ mobilepayTestUi: false }, ''), false); assert.equal(testUiEnabled({}, ''), false);
  assert.equal(testUiEnabled({ mobilepayTestUi: false }, '?t=x&mock=1'), true, 'mock-sivu on aina testiympäristö'); assert.equal(testUiEnabled({}, '?mock=0'), false);
});
test('ohjausosoite: vain https (http vain localhost kun sallittu)', () => {
  assert.equal(safeRedirect('https://pay.vipps.example/x?a=1'), 'https://pay.vipps.example/x?a=1');
  for (const bad of ['http://evil.example/x', 'javascript:alert(1)', '//evil.example', 'data:text/html,x', '', null, undefined, 'ftp://x']) assert.equal(safeRedirect(bad), null, String(bad));
  assert.equal(safeRedirect('http://127.0.0.1:4000/x'), null); assert.equal(safeRedirect('http://127.0.0.1:4000/x', { allowHttpLocal: true }), 'http://127.0.0.1:4000/x'); assert.equal(safeRedirect('http://evil.example/x', { allowHttpLocal: true }), null);
});
test('reconcile-tulosten luokittelu (§14.3)', () => {
  const r = (...o) => o.map((outcome) => ({ outcome, state: 'X' }));
  assert.equal(classifyResults(r('paid')), 'paid'); assert.equal(classifyResults(r('paid_needs_review')), 'review');
  assert.equal(classifyResults(r('not_authorized')), 'failed'); assert.equal(classifyResults(r('cancelled_slot_lost')), 'slot_lost');
  assert.equal(classifyResults(r('capture_failed')), 'contact'); assert.equal(classifyResults(r('amount_mismatch')), 'contact');
  assert.equal(classifyResults(r('pending')), 'pending'); assert.equal(classifyResults(r('error')), 'pending');
  assert.equal(classifyResults(r('not_authorized', 'pending')), 'pending', 'uusi yritys kesken → ei vielä epäonnistunut');
  assert.equal(classifyResults(r('not_authorized', 'paid')), 'paid'); assert.equal(classifyResults(r('not_authorized', 'not_authorized')), 'failed');
  assert.equal(classifyResults([]), 'none'); assert.equal(classifyResults(undefined), 'none'); assert.equal(classifyResults([{}]), 'none');
});

// ---- polling väärennetyllä kellolla ----
function clock() { let t = 0; return { now: () => t, sleep: async (ms) => { t += ms; }, get t() { return t; } }; }
const poll = (deps, o) => { const c = clock(); return pollPayment({ sleep: c.sleep, now: c.now, ...deps }, o).then((r) => ({ ...r, elapsed: c.t })); };
test('polling: vakioajat 2-3 s ja ~60 s', () => { assert.ok(POLL_INTERVAL_MS >= 2000 && POLL_INTERVAL_MS <= 3000); assert.ok(POLL_MAX_MS >= 55000 && POLL_MAX_MS <= 65000); });
test('polling: reconcile ensin, sitten public_get_order; maksettu heti → paid', async () => {
  const order = []; let recs = 0;
  const r = await poll({ reconcile: async () => { order.push('rec'); recs++; return { ok: true, payment_status: 'paid', results: [{ outcome: 'paid' }] }; }, getOrder: async () => { order.push('get'); return { ok: true, payment_status: 'paid' }; } });
  assert.equal(r.state, 'paid'); assert.equal(order[0], 'rec'); assert.equal(recs, 1); assert.equal(r.elapsed, 0);
});
test('polling: webhook ehtii ensin (reconcile pending, get_order paid kolmannella kierroksella)', async () => {
  let gets = 0;
  const r = await poll({ reconcile: async () => ({ ok: true, payment_status: 'unpaid', results: [{ outcome: 'pending' }] }), getOrder: async () => ({ ok: true, payment_status: ++gets >= 3 ? 'paid' : 'unpaid' }) });
  assert.equal(r.state, 'paid'); assert.equal(gets, 3); assert.equal(r.elapsed, 2 * POLL_INTERVAL_MS);
});
test('polling: ei maksua → aikakatkaisu ~60 s (wait); reconcile harvemmin kuin get_order', async () => {
  let recs = 0, gets = 0;
  const r = await poll({ reconcile: async () => { recs++; return { ok: true, payment_status: 'unpaid', results: [{ outcome: 'pending' }] }; }, getOrder: async () => { gets++; return { ok: true, payment_status: 'unpaid' }; } });
  assert.equal(r.state, 'wait'); assert.ok(r.elapsed <= POLL_MAX_MS && r.elapsed >= POLL_MAX_MS - POLL_INTERVAL_MS, `kesto ${r.elapsed}`);
  assert.ok(gets >= 20 && gets <= 26, `get_order-kutsut ${gets}`); assert.ok(recs >= 5 && recs <= 7 && recs < gets, `reconcile-kutsut ${recs}`);
});
test('polling: epäonnistunut / aika meni / ota yhteyttä päättyvät heti', async () => {
  for (const [outcome, state] of [['not_authorized', 'failed'], ['cancelled_slot_lost', 'slot_lost'], ['capture_failed', 'contact'], ['paid_needs_review', 'review']]) {
    const r = await poll({ reconcile: async () => ({ ok: true, payment_status: 'unpaid', results: [{ outcome }] }), getOrder: async () => ({ ok: true, payment_status: outcome === 'paid_needs_review' ? 'paid' : 'unpaid' }) });
    assert.equal(r.state, state, outcome); assert.equal(r.elapsed, 0);
  }
});
test('polling: epäonnistunut mutta tilaus ehti jo maksetuksi (webhook) → paid', async () => {
  const r = await poll({ reconcile: async () => ({ ok: true, payment_status: 'unpaid', results: [{ outcome: 'not_authorized' }] }), getOrder: async () => ({ ok: true, payment_status: 'paid' }) });
  assert.equal(r.state, 'paid');
});
test('polling: verkkovirheet (reconcile heittää / ei vastausta) → jatkaa get_orderilla; pelkkä verkkovirhe 60 s → net', async () => {
  let n = 0;
  let r = await poll({ reconcile: async () => { throw new TypeError('fetch'); }, getOrder: async () => { if (++n < 3) throw new TypeError('fetch'); return { ok: true, payment_status: 'paid' }; } });
  assert.equal(r.state, 'paid');
  r = await poll({ reconcile: async () => ({ ok: false, code: 'network' }), getOrder: async () => { throw new TypeError('fetch'); } });
  assert.equal(r.state, 'net'); assert.ok(r.elapsed >= POLL_MAX_MS - POLL_INTERVAL_MS);
  r = await poll({ reconcile: async () => ({ ok: false, code: 'timeout' }), getOrder: async () => ({ ok: false }) });
  assert.equal(r.state, 'net', 'get_order ok:false ei ole vastaus; timeout ei ole vastaus');
  r = await poll({ reconcile: async () => ({ ok: false, code: 'rate_limited' }), getOrder: async () => { throw new TypeError('x'); } });
  assert.equal(r.state, 'wait', 'palvelin vastasi (rate_limited) → ei verkkovirhe, vaan odottava tila');
});
test('polling: mukautetut ajat (mock/esittely)', async () => {
  const r = await poll({ reconcile: async () => ({ ok: true, results: [{ outcome: 'pending' }] }), getOrder: async () => ({ ok: true, payment_status: 'unpaid' }) }, { intervalMs: 100, maxMs: 1000 });
  assert.equal(r.state, 'wait'); assert.ok(r.elapsed <= 1000);
});

// ---- edge-funktiokutsut ----
const resp = (status, body, raw) => ({ ok: status >= 200 && status < 300, status, text: async () => (raw ?? JSON.stringify(body)) });
const mk = (fetchImpl, over = {}) => createMobilepayApi({ rpc: async () => ({}), token: TOKEN, functionUrl: (n) => `https://x.supabase.co/functions/v1/${n}`, anonKey: 'pk', fetchImpl, ...over });
test('start: POST {order_token} JSON + apikey; palauttaa redirect_url', async () => {
  const seen = []; const api = mk(async (url, init) => { seen.push({ url, init }); return resp(200, { ok: true, reuse: false, redirect_url: 'https://pay.example/x', reference: 'r' }); });
  const r = await api.start();
  assert.deepEqual(r, { ok: true, reuse: false, redirect_url: 'https://pay.example/x', reference: 'r' });
  assert.equal(seen[0].url, 'https://x.supabase.co/functions/v1/mobilepay-start'); assert.equal(seen[0].init.method, 'POST');
  assert.deepEqual(JSON.parse(seen[0].init.body), { order_token: TOKEN }); assert.equal(seen[0].init.headers['Content-Type'], 'application/json'); assert.equal(seen[0].init.headers.apikey, 'pk');
  assert.equal(seen[0].init.credentials, 'omit');
});
test('reconcile: POST {action:"reconcile", order_token} osoitteeseen mobilepay-notify', async () => {
  const seen = []; const api = mk(async (url, init) => { seen.push({ url, init }); return resp(200, { ok: true, payment_status: 'unpaid', results: [{ outcome: 'pending', state: 'CREATED' }] }); });
  const r = await api.reconcile(); assert.equal(r.results[0].outcome, 'pending');
  assert.equal(seen[0].url, 'https://x.supabase.co/functions/v1/mobilepay-notify'); assert.deepEqual(JSON.parse(seen[0].init.body), { action: 'reconcile', order_token: TOKEN });
});
test('virheet: palvelimen {ok:false,code,message} sellaisenaan; verkko/aikakatkaisu/ei-JSON ei heitä', async () => {
  assert.deepEqual(await mk(async () => resp(503, { ok: false, code: 'provider_error', message: 'm' })).start(), { ok: false, code: 'provider_error', message: 'm' });
  assert.deepEqual(await mk(async () => resp(429, { ok: false, code: 'rate_limited' })).reconcile(), { ok: false, code: 'rate_limited' });
  assert.equal((await mk(async () => { throw new TypeError('Failed to fetch'); }).start()).code, 'network');
  assert.equal((await mk(async () => { throw Object.assign(new Error('x'), { name: 'AbortError' }); }).start()).code, 'timeout');
  assert.equal((await mk(async () => resp(502, null, '<h1>Bad gateway</h1>')).start()).code, 'http_502');
  assert.equal((await mk(async () => resp(200, null, '')).start()).code, 'bad_response');
  assert.equal((await mk(async () => resp(500, { foo: 1 })).start()).code, 'http_500');
  assert.equal((await mk(null).start()).code, 'network');
});
test('aikakatkaisu: pyyntö katkaistaan AbortSignalilla', async () => {
  const api = mk((url, init) => new Promise((_, rej) => init.signal.addEventListener('abort', () => rej(Object.assign(new Error('aborted'), { name: 'AbortError' })))), { timeoutMs: 30 });
  assert.equal((await api.start()).code, 'timeout');
});
test('options: public_payment_options(p_token); puuttuva RPC ja virhe → null (ei painiketta, ei virhettä)', async () => {
  const calls = []; const ok = createMobilepayApi({ rpc: async (n, a) => { calls.push([n, a]); return opts(); }, token: TOKEN, functionUrl: () => '' });
  assert.equal((await ok.options()).ok, true); assert.deepEqual(calls[0], ['public_payment_options', { p_token: TOKEN }]);
  for (const err of [{ status: 404, code: 'PGRST202', message: 'Could not find the function' }, { status: 500, message: 'boom' }, new TypeError('fetch')])
    assert.equal(await createMobilepayApi({ rpc: async () => { throw err; }, token: TOKEN, functionUrl: () => '' }).options(), null);
});

// ---- mock vs. sopimus ----
test('mock: public_payment_options noudattaa §14.1-muotoa; mpFetch vastaa start/reconcile-muodoilla', async () => {
  const m = createOrderMock({ scenario: 'mp' });
  const o = await m.rpc('public_payment_options', { p_token: TOKEN });
  assert.equal(o.ok, true); assert.equal(o.online_enabled, true); assert.equal(o.methods[0].code, 'online'); assert.equal(o.methods[0].test, true);
  assert.deepEqual(o.methods[0].start, { function: 'montonio-start', method: 'POST', body: { order_token: TOKEN } });
  for (const k of ['order_no', 'status', 'payment_status', 'unpaid', 'can_pay_online', 'mobilepay_pending']) assert.ok(k in o.order, k);
  assert.equal(o.order.can_pay_online, true); assert.equal(o.order.unpaid, 40);
  assert.equal((await createOrderMock({ scenario: 'mp-prod' }).rpc('public_payment_options', { p_token: TOKEN })).methods[0].test, false);
  for (const sc of ['', 'mp-off', 'gift', 'cards']) {
    const methods = (await createOrderMock({ scenario: sc }).rpc('public_payment_options', { p_token: TOKEN })).methods;
    assert.equal(methods.some((m) => m.code === 'mobilepay'), false, `${sc || '(oletus)'}: ei MobilePayta`);
    if (sc === 'cards') assert.equal(methods[0]?.code, 'online', 'lahjakorttitilaus maksetaan verkossa');
    else assert.deepEqual(methods, [], `skenaario ${sc || '(oletus)'}: ei verkkomaksua`);
  }
  const start = JSON.parse(await (await m.mpFetch('https://x/functions/v1/mobilepay-start', { method: 'POST', body: JSON.stringify({ order_token: TOKEN }) })).text());
  assert.equal(start.ok, true); assert.ok(/pay=mobilepay/.test(start.redirect_url)); assert.ok(start.reference);
  const rec = JSON.parse(await (await m.mpFetch('https://x/functions/v1/mobilepay-notify', { method: 'POST', body: JSON.stringify({ action: 'reconcile', order_token: TOKEN }) })).text());
  assert.deepEqual(Object.keys(rec).sort(), ['ok', 'payment_status', 'results']); assert.deepEqual(Object.keys(rec.results[0]).sort(), ['outcome', 'state']);
  // paluu: maksu kirjautuu 3. public_get_order-kyselyllä reconcilen jälkeen
  let g; for (let i = 0; i < 3; i++) g = await m.rpc('public_get_order', { p_token: TOKEN });
  assert.equal(g.payment_status, 'paid'); assert.equal(g.unpaid, 0); assert.equal(g.receipts.length, 1);
  assert.equal(JSON.parse(await (await m.mpFetch('https://x/functions/v1/mobilepay-start', { method: 'POST', body: '{}' })).text()).code, 'already_paid');
  // epäonnistuneet tulokset
  for (const [res, outcome] of [['failed', 'not_authorized'], ['slotlost', 'cancelled_slot_lost'], ['contact', 'capture_failed']]) {
    const mm = createOrderMock({ scenario: 'mp', mpResult: res });
    const r = JSON.parse(await (await mm.mpFetch('https://x/functions/v1/mobilepay-notify', { method: 'POST', body: JSON.stringify({ action: 'reconcile', order_token: TOKEN }) })).text());
    assert.equal(r.results[0].outcome, outcome);
  }
});

// ---- tuotannon backend ↔ UI: sopimuksen §14.1 esimerkki ----
test('sopimuksen §14.1 -esimerkkivastaus: painike näkyy testiympäristössä, ei tuotannossa', () => {
  const sample = { ok: true, online_enabled: true, methods: [{ code: 'mobilepay', provider: 'vipps_mobilepay', label: 'MobilePay', label_en: 'MobilePay', test: true, start: { function: 'mobilepay-start', method: 'POST', body: { order_token: '<token>' } } }],
    order: { order_no: 123, status: 'pending', payment_status: 'unpaid', unpaid: 40.0, can_pay_online: true, mobilepay_pending: false } };
  assert.equal(shouldShowButton(sample, { testUi: true }), true); assert.equal(shouldShowButton(sample, { testUi: false }), false);
});

// ---- admin: hyvitys → mobilepay-refund ----
test('admin: mobilepayRefund kutsuu mobilepay-refund {refund_id} ja tulkitsee processed[]', async () => {
  const calls = [];
  const mkApi = (fn) => createTalousApi({ rpc: async () => ({ ok: true }), io: { fn }, mock: false });
  const api = mkApi(async (name, body) => { calls.push([name, body]); return { ok: true, mode: 'test', processed: [{ refund_id: 9, result: 'done' }] }; });
  assert.deepEqual(await api.mobilepayRefund(9), { result: 'done', detail: null }); assert.deepEqual(calls[0], ['mobilepay-refund', { refund_id: 9 }]);
  for (const result of ['failed', 'retry_later', 'unverified', 'db_error']) assert.equal((await mkApi(async () => ({ ok: true, processed: [{ refund_id: 9, result, detail: { x: 1 } }] })).mobilepayRefund(9)).result, result);
  assert.equal((await mkApi(async () => ({ ok: true, mode: 'off', processed: [] })).mobilepayRefund(9)).result, 'off');
  assert.equal((await mkApi(async () => ({ ok: true, mode: 'test', processed: [] })).mobilepayRefund(9)).result, 'none');
  assert.equal((await mkApi(async () => ({ ok: true, processed: [{ refund_id: 8, result: 'done' }] })).mobilepayRefund(9)).result, 'none', 'vain oma refund_id');
  assert.equal((await mkApi(async () => { throw Object.assign(new Error('x'), { code: 'forbidden', status: 403 }); }).mobilepayRefund(9)).result, 'forbidden');
  assert.equal((await mkApi(async () => { throw new TypeError('Failed to fetch'); }).mobilepayRefund(9)).result, 'error', 'verkkovirhe ei heitä');
  assert.equal((await createTalousApi({ rpc: async () => ({}), mock: true }).mobilepayRefund(9)).mock, true, 'mock-tila ei kutsu palvelinta');
});
test('admin: hyvitystekstit FI/EN-pariteetti ja kaikki tulokset katettu', () => {
  assert.deepEqual(Object.keys(TEXTS.fi).sort(), Object.keys(TEXTS.en).sort());
  for (const k of ['done', 'failed', 'retry_later', 'unverified', 'db_error', 'none', 'off', 'forbidden', 'error']) for (const l of ['fi', 'en']) assert.ok(TEXTS[l][`refund.mp.${k}`], `${l} refund.mp.${k}`);
});
test('admin: hyvitysvirta on kytketty (talous-orders.js kutsuu mobilepayRefund kun status=requested ja provider=mobilepay)', () => {
  const src = readFileSync(new URL('../admin/views/talous-orders.js', import.meta.url), 'utf8');
  assert.ok(/res\?\.status === 'requested'[^\n]*provider === 'mobilepay'[^\n]*processMobilepayRefund/.test(src));
  const tl = readFileSync(new URL('../admin/views/talous.js', import.meta.url), 'utf8');
  assert.ok(/import \{[^}]*\bfn\b[^}]*\} from '\.\.\/sb\.js'/.test(tl) && /io: \{[^}]*\bfn\b/.test(tl), 'sb.js:n fn annettu talous-api:lle');
});
