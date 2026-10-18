// Testivaihtoehto "maksu paikan päällä" (booking_57, public_confirm_pay_later): palvelimen methods-lista päättää näkyvyydestä (ei env.testUi-ehtoa), nappi kutsuu confirm_rpc:tä order_token:illa,
// onnistuminen = confirmed_unpaid, virheet FI+EN, mock (hold + testui=0 piilottaa), migraatio/rollback/testi repossa tuotannon versionumerolla, Joonaksen poistama lause ei enää missään shopin tekstissä.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, cpSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { HT, ht, payLaterError, PAY_LATER_ERRORS } from '../shop/src/hold-texts.js';
import { normOptions, payLaterMethod, PAY_LATER_RPC } from '../shop/src/mobilepay-logic.js';
import { createOrderMock } from '../shop/src/order-mock.js';
import { holdMockParams, PAY_LATER_METHOD } from '../shop/src/hold-mock.js';
import { normCheckout } from '../shop/src/hold-logic.js';

const tmp = mkdtempSync(join(tmpdir(), 'pay-later-'));
cpSync(new URL('../shop/src/', import.meta.url), tmp, { recursive: true });
cpSync(new URL('../shared/sb.js', import.meta.url), join(tmp, 'sb.js'));
writeFileSync(join(tmp, 'package.json'), '{"type":"module"}');
const { offers, loadPayChoices } = await import(pathToFileURL(join(tmp, 'pay-choices.js')).href);
const { createMobilepayApi } = await import(pathToFileURL(join(tmp, 'mobilepay-api.js')).href);
const { createShopMock } = await import(pathToFileURL(join(tmp, 'shop-mock.js')).href);
const src = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const TOKEN = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';
const memStore = () => { const m = new Map(); return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)) }; };
const om = (scenario, extra = {}) => createOrderMock({ scenario, storage: memStore(), payLaterTest: true, ...extra });
const PL = { code: 'pay_later', kind: 'later', provider: 'manual', label: 'Maksa myöhemmin (testi)', label_en: 'Pay later (test)', test: true, enabled: true, confirm_rpc: 'public_confirm_pay_later' };

// ---------- tekstit ----------
test('tekstit: nappi "Testivaihtoehto: maksu paikan päällä" / "Test option: pay on site"; virheviestit FI+EN kaikille koodeille; yleisviesti tuntemattomalle', () => {
  assert.equal(ht('fi', 'payLater.btn'), 'Testivaihtoehto: maksu paikan päällä');
  assert.equal(ht('en', 'payLater.btn'), 'Test option: pay on site');
  assert.deepEqual(PAY_LATER_ERRORS, ['pay_later_unavailable', 'payment_in_progress', 'order_expired', 'order_cancelled', 'not_found', 'rate_limited']);
  for (const l of ['fi', 'en']) {
    const seen = new Set();
    for (const c of PAY_LATER_ERRORS) { const m = payLaterError(l, c); assert.ok(m.length > 20 && !m.startsWith('payLater.'), `${l} ${c}`); seen.add(m); }
    assert.equal(seen.size, PAY_LATER_ERRORS.length, `${l}: jokaisella koodilla oma viesti`);
    for (const c of ['network', 'timeout', 'bad_response', undefined, 'jokin_outo']) assert.equal(payLaterError(l, c), ht(l, 'payLater.err.generic'), `${l} ${c}`);
  }
  assert.ok(Object.keys(HT.fi).filter((k) => k.startsWith('payLater.')).length >= 10);
  assert.ok(!Object.keys(HT.fi).some((k) => k.startsWith('testOnSite')), 'vanha tietolaatikko poistettu');
});
test('tekstit: lause "Varaus vahvistuu, kun koko summa on maksettu." (ja EN-vastine) poistettu shopista, README:stä ja dokumentista; jäljellä 15 min -ohje', () => {
  const FI = /Varaus vahvistuu, kun koko summa on maksettu/i, EN = /booking is confirmed once the full amount/i;
  for (const f of readdirSync(new URL('../shop/src/', import.meta.url))) { const s = src(`../shop/src/${f}`); assert.ok(!FI.test(s) && !EN.test(s), f); }
  for (const f of ['../README.md', '../docs/KASSA_pito_asiakasteksti_fi.md', '../scripts/e2e-kassa-pito.mjs']) { const s = src(f); assert.ok(!FI.test(s) && !EN.test(s), f); }
  assert.ok(!('confirmRule' in HT.fi) && !('confirmRule' in HT.en));
  assert.equal(ht('fi', 'mustPay', { minutes: 15 }), 'Varaus täytyy maksaa 15 minuutin sisään, muuten se peruuntuu ja paikka vapautuu.');
  assert.equal(ht('en', 'mustPay', { minutes: 15 }), 'The booking must be paid within 15 minutes, otherwise it is cancelled and your spot is released.');
});

// ---------- palvelimen methods-lista ----------
test('payLaterMethod: vain code pay_later + enabled:true; confirm_rpc vain public_*-nimi; puuttuva → oletus', () => {
  assert.deepEqual(payLaterMethod([PL]), { code: 'pay_later', label: 'Maksa myöhemmin (testi)', label_en: 'Pay later (test)', confirmRpc: 'public_confirm_pay_later', test: true });
  assert.equal(payLaterMethod([]), null); assert.equal(payLaterMethod(null), null); assert.equal(payLaterMethod([{ code: 'mobilepay' }]), null);
  assert.equal(payLaterMethod([{ ...PL, enabled: false }]), null); assert.equal(payLaterMethod([{ ...PL, enabled: undefined }]), null);
  assert.equal(payLaterMethod([{ ...PL, confirm_rpc: undefined }]).confirmRpc, PAY_LATER_RPC);
  assert.equal(payLaterMethod([{ ...PL, confirm_rpc: 'admin_drop_everything' }]).confirmRpc, PAY_LATER_RPC, 'ei mielivaltaista RPC-nimeä');
  assert.equal(payLaterMethod([{ ...PL, confirm_rpc: 'public_x; drop' }]).confirmRpc, PAY_LATER_RPC);
});
test('normOptions: payLater mukana vaikka MobilePay puuttuu; ei ilman pay_later-tapaa (flag false → ei tapaa)', () => {
  const mp = { code: 'mobilepay', label: 'MobilePay', test: false };
  assert.equal(normOptions({ ok: true, methods: [mp], order: { can_pay_online: true } }).payLater, null);
  const a = normOptions({ ok: true, methods: [mp, PL], order: { can_pay_online: true } }); assert.equal(a.payLater.confirmRpc, 'public_confirm_pay_later'); assert.equal(a.method.code, 'mobilepay');
  const b = normOptions({ ok: true, methods: [PL], order: { can_pay_online: false } }); assert.equal(b.method, null); assert.ok(b.payLater);
  assert.equal(normOptions(null).payLater, undefined);
});
test('offers: payLater vain kun palvelin listasi tavan – EI riipu env.testUi:sta; ei alustavalle/vanhentuneelle/maksetulle', () => {
  const bk = (s, over = {}) => ({ status: s === 'expired' ? 'expired' : s === 'confirmed_unpaid' ? 'confirmed' : 'pending', payment_status: 'unpaid', checkout_state: s, ...over });
  const withPl = { mpShow: false, redeem: false, claims: [], payLater: payLaterMethod([PL]), env: { testUi: false } };
  assert.equal(offers(withPl, bk('awaiting_payment')).payLater, true, 'näkyy vaikka testUi=false (palvelin päättää)');
  assert.equal(offers({ ...withPl, env: { testUi: true }, payLater: null }, bk('awaiting_payment')).payLater, false, 'testUi=true ei riitä ilman palvelimen tapaa');
  assert.equal(offers(withPl, bk('expired')).payLater, false); assert.equal(offers(withPl, bk('preliminary')).payLater, false);
  assert.equal(offers(withPl, bk('awaiting_payment', { payment_status: 'paid' })).payLater, false);
  assert.equal(offers(withPl, null).payLater, false);
  assert.equal(offers(withPl, bk('awaiting_payment')).mobilepay, false);
});
test('lähdekoodi: nappi on <button> data-testid pc-paylater-btn; vanha pc-onsite-test / testUi-ehto poissa; kutsu order_token:illa', () => {
  const pc = src('../shop/src/pay-choices.js'), api = src('../shop/src/mobilepay-api.js');
  assert.ok(pc.includes("'data-testid': 'pc-paylater-btn'") && pc.includes("h('button'") && !pc.includes('pc-onsite-test') && !/testOnSite/.test(pc));
  const code = pc.split('\n').map((l) => l.replace(/(^|\s)\/\/.*$/, '')).join('\n');
  assert.ok(!/payLater[^\n]*testUi|testUi[^\n]*payLater/.test(code), 'ei env.testUi-ehtoa');
  assert.ok(api.includes('p_order_token: token'));
});

// ---------- datakerros ----------
test('confirmPayLater: kutsuu confirm_rpc:tä { p_order_token }; verkkovirhe → {ok:false, code:network}; puuttuva RPC → pay_later_unavailable; ei heitä', async () => {
  const calls = [];
  const ok = createMobilepayApi({ rpc: async (n, a) => { calls.push([n, a]); return { ok: true, checkout_state: 'confirmed_unpaid', remaining_amount: 40, order_id: 1 }; }, token: TOKEN, functionUrl: (n) => n });
  const r = await ok.confirmPayLater('public_confirm_pay_later');
  assert.deepEqual(calls, [['public_confirm_pay_later', { p_order_token: TOKEN }]]); assert.equal(r.checkout_state, 'confirmed_unpaid');
  const net = createMobilepayApi({ rpc: async () => { throw new TypeError('Failed to fetch'); }, token: TOKEN, functionUrl: (n) => n });
  assert.deepEqual(await net.confirmPayLater(), { ok: false, code: 'network' });
  const miss = createMobilepayApi({ rpc: async () => { throw Object.assign(new Error('Could not find the function'), { status: 404, code: 'PGRST202' }); }, token: TOKEN, functionUrl: (n) => n });
  assert.equal((await miss.confirmPayLater()).code, 'pay_later_unavailable');
  const nul = createMobilepayApi({ rpc: async () => null, token: TOKEN, functionUrl: (n) => n });
  assert.equal((await nul.confirmPayLater()).ok, false);
  const bad = createMobilepayApi({ rpc: async () => ({ ok: false, code: 'order_expired', message: 'x' }), token: TOKEN, functionUrl: (n) => n });
  assert.equal((await bad.confirmPayLater()).code, 'order_expired');
});

// ---------- mock ----------
test('mock: hold + testui → methods sisältää pay_later (palvelimen muoto); testui=0 → ei; vain awaiting_payment', async () => {
  const m = om('hold'), o = await m.rpc('public_payment_options', { p_token: TOKEN });
  const pl = o.methods.find((x) => x.code === 'pay_later'); assert.deepEqual(pl, PAY_LATER_METHOD); assert.equal(pl.enabled, true); assert.equal(pl.test, true); assert.equal(pl.confirm_rpc, 'public_confirm_pay_later');
  assert.ok(o.methods.find((x) => x.code === 'mobilepay'));
  assert.equal((await om('hold', { payLaterTest: false }).rpc('public_payment_options', { p_token: TOKEN })).methods.some((x) => x.code === 'pay_later'), false, 'testui=0');
  for (const sc of ['hold-unpaid', 'hold-confirmed', 'hold-expired', 'hold-cancelled', 'hold-preliminary']) assert.equal((await om(sc).rpc('public_payment_options', { p_token: TOKEN })).methods.some((x) => x.code === 'pay_later'), false, sc);
  for (const sc of ['pay', 'mp', 'gift']) assert.equal((await om(sc).rpc('public_payment_options', { p_token: TOKEN })).methods.some((x) => x.code === 'pay_later'), false, `${sc}: vanhat skenaariot ennallaan`);
  assert.equal((await om('hold-unavailable').rpc('public_payment_options', { p_token: TOKEN })).methods.some((x) => x.code === 'pay_later'), true, 'pay_later ei riipu MobilePaysta');
  assert.equal((await om('hold').rpc('public_checkout_payment_options')).methods.some((x) => x.code === 'pay_later'), false, 'kassan (ei-token) lista ennallaan');
});
test('mock: public_confirm_pay_later → confirmed_unpaid, remaining_amount, order_id; pito poistuu; idempotentti', async () => {
  const m = om('hold');
  const r = await m.rpc('public_confirm_pay_later', { p_order_token: TOKEN });
  assert.equal(r.ok, true); assert.equal(r.checkout_state, 'confirmed_unpaid'); assert.equal(r.remaining_amount, 40); assert.ok(r.order_id); assert.equal(r.idempotent, false); assert.equal(r.pay_later, true);
  const co = normCheckout(r); assert.equal(co.state, 'confirmed_unpaid'); assert.equal(co.awaiting, false);
  const g = await m.rpc('public_get_order', { p_token: TOKEN }); assert.equal(g.status, 'confirmed'); assert.equal(g.checkout_state, 'confirmed_unpaid'); assert.equal(g.hold_expires_at, null); assert.equal(g.payment_status, 'unpaid');
  const again = await m.rpc('public_confirm_pay_later', { p_order_token: TOKEN }); assert.equal(again.ok, true); assert.equal(again.idempotent, true);
  assert.equal((await m.rpc('public_payment_options', { p_token: TOKEN })).methods.some((x) => x.code === 'pay_later'), false, 'vahvistuksen jälkeen ei enää tarjolla');
});
test('mock: virhekoodit (pay_later_unavailable, payment_in_progress, order_expired, order_cancelled, not_found) kuten palvelimella; plfail pakottaa virheen kerran', async () => {
  const code = async (sc, extra, tok = TOKEN) => (await om(sc, extra).rpc('public_confirm_pay_later', { p_order_token: tok })).code;
  assert.equal(await code('hold', { payLaterTest: false }), 'pay_later_unavailable');
  assert.equal(await code('pay'), 'pay_later_unavailable');
  assert.equal(await code('hold', {}, null), 'not_found');
  assert.equal(await code('hold-expired'), 'order_expired'); assert.equal(await code('hold-cancelled'), 'order_cancelled');
  assert.equal(await code('hold-preliminary'), 'payment_in_progress'); assert.equal(await code('hold-processing', { procSeconds: 600 }), 'payment_in_progress');
  const m = om('hold', { payLaterFail: 'order_expired' });
  assert.equal((await m.rpc('public_confirm_pay_later', { p_order_token: TOKEN })).code, 'order_expired');
  assert.equal((await m.rpc('public_confirm_pay_later', { p_order_token: TOKEN })).ok, true, 'plfail vain kerran');
  const e = om('hold', { holdSeconds: 1 }); await new Promise((r) => setTimeout(r, 1200));
  assert.equal((await e.rpc('public_confirm_pay_later', { p_order_token: TOKEN })).code, 'order_expired', 'vanhentunut pito');
});
test('holdMockParams: testui=0 ja plfail', () => {
  assert.equal(holdMockParams('?mock=1').payLaterTest, true); assert.equal(holdMockParams('?mock=1&testui=0').payLaterTest, false);
  assert.equal(holdMockParams('?mock=1&plfail=order_expired').payLaterFail, 'order_expired'); assert.equal(holdMockParams('?mock=1&plfail=<script>').payLaterFail, '');
});
test('shop-mock (vahvistussivu): public_confirm_pay_later toimii ja public_get_booking näyttää confirmed_unpaid; loadPayChoices → model.payLater vain palvelimen tavasta', async () => {
  const sm = createShopMock({ storage: memStore(), scenario: 'hold' }); sm.rpc.length; // eslint-disable-line no-unused-expressions
  // createShopMock ei lue testui-parametria itse: holdMockParams() lukee location.search → oletus (testui päällä)
  const model = await loadPayChoices({ rpc: sm.rpc, token: TOKEN, fetchImpl: sm.mpFetch, cfg: {}, search: '?mock=1&scenario=hold' });
  assert.ok(model.payLater && model.payLater.confirmRpc === 'public_confirm_pay_later', 'tapa tulee palvelimelta');
  assert.equal(model.env.testUi, true);
  const b0 = await sm.rpc('public_get_booking', { p_token: TOKEN }); assert.equal(b0.checkout_state, 'awaiting_payment');
  assert.equal(offers(model, b0).payLater, true);
  const r = await model.mp.confirmPayLater(model.payLater.confirmRpc); assert.equal(r.ok, true); assert.equal(r.checkout_state, 'confirmed_unpaid');
  const b1 = await sm.rpc('public_get_booking', { p_token: TOKEN }); assert.equal(b1.checkout_state, 'confirmed_unpaid'); assert.equal(b1.status, 'confirmed');
  const prod = await loadPayChoices({ rpc: createShopMock({ storage: memStore(), scenario: 'pay' }).rpc, token: TOKEN, cfg: {}, search: '' });
  assert.equal(prod.payLater, null, 'ei tapaa → ei nappia');
});

// ---------- repo vastaa tuotantoa ----------
test('migraatio booking_57 + rollback + SQL-testi repossa (tuotannon versio 20261018081039), lippu ei mene päälle migraatiossa', () => {
  const mig = '../supabase/migrations/20261018081039_booking_57_pay_later_test.sql';
  assert.ok(existsSync(new URL(mig, import.meta.url)) && existsSync(new URL('../supabase/rollbacks/20261018081039_booking_57_ROLLBACK.sql', import.meta.url)) && existsSync(new URL('../supabase/tests/checkout/t57_pay_later_test.sql', import.meta.url)));
  const s = src(mig);
  assert.ok(s.includes("'pay_later_test_enabled', 'false'::jsonb") && s.includes('public_confirm_pay_later(p_order_token uuid)'));
  assert.ok(!/update\s+booking\.settings|pay_later_test_enabled'\s*,\s*'true'/i.test(s), 'migraatio ei laita lippua päälle');
});
