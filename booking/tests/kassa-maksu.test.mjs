// Maksuvalinta kassalle ja vahvistussivulle: tekstipariteetti, tarjontapäätökset (offers/dueAmount/onlineAtCheckout), latauksen virheensieto,
// mock-skenaario "pay" (sama order-mock/gift-mock kuin tilaussivulla), MobilePay-paluuosoite (hash + polkuetuliite säilyvät), ettei public_payment_mode:a kirjoiteta.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, cpSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { PT, pt } from '../shop/src/pay-choices-texts.js';
import { GT } from '../shop/src/gift-texts.js';
import { createOrderMock } from '../shop/src/order-mock.js';

// pay-choices.js ja shop-mock.js tuovat './sb.js':n, joka on rakennuksessa kopio booking/shared/sb.js:stä (build.mjs) → sama asettelu väliaikaiskansioon.
const tmp = mkdtempSync(join(tmpdir(), 'kassa-maksu-'));
cpSync(new URL('../shop/src/', import.meta.url), tmp, { recursive: true });
cpSync(new URL('../shared/sb.js', import.meta.url), join(tmp, 'sb.js'));
writeFileSync(join(tmp, 'package.json'), '{"type":"module"}');
const { offers, dueAmount, onlineAvailable, onlineAtCheckout, loadPayChoices } = await import(pathToFileURL(join(tmp, 'pay-choices.js')).href);
const { createShopMock } = await import(pathToFileURL(join(tmp, 'shop-mock.js')).href);

const TOKEN = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';
const src = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const method = (over = {}) => ({ code: 'mobilepay', provider: 'vipps_mobilepay', label: 'MobilePay', label_en: 'MobilePay', test: false, start: { function: 'mobilepay-start', method: 'POST', body: { order_token: TOKEN } }, ...over });
const popts = ({ methods = [method()], order = { can_pay_online: true, unpaid: 40, mobilepay_pending: false } } = {}) => ({ ok: true, online_enabled: true, methods, order });
const model = (over = {}) => ({ env: { testUi: false, mock: false, official: true }, opts: null, mpShow: false, redeem: false, claims: [], ...over });
const booking = (over = {}) => ({ status: 'confirmed', payment_status: 'unpaid', total: 40, ...over });

test('tekstit: PT FI/EN avaimet samat, ei tyhjiä, ei emojeita, muuttujat täsmäävät', () => {
  assert.deepEqual(Object.keys(PT.fi).sort(), Object.keys(PT.en).sort());
  for (const l of ['fi', 'en']) for (const [k, v] of Object.entries(PT[l])) {
    assert.ok(typeof v === 'string' && v.trim(), `${l}.${k}`);
    assert.ok(!/\p{Extended_Pictographic}/u.test(v), `${l}.${k}: emoji`);
  }
  for (const k of Object.keys(PT.fi)) assert.deepEqual((PT.fi[k].match(/\{\w+\}/g) || []).sort(), (PT.en[k].match(/\{\w+\}/g) || []).sort(), `muuttujat ${k}`);
  assert.equal(pt('fi', 'giftBtn'), 'Maksa lahjakortilla'); assert.equal(pt('en', 'giftBtn'), 'Pay with a gift card');
  assert.equal(pt('fi', 'amountDue', { amount: '25 €' }), 'Maksettavaa jäljellä: 25 €');
  assert.equal(pt('xx', 'title'), PT.fi.title);
});

test('tekstit: lahjakortin saldotekstit (uudet o.*-avaimet) FI/EN-pariteetti', () => {
  for (const k of ['o.checkBtn', 'o.checking', 'o.balanceIs', 'o.balanceIsFull', 'o.checkUnknown']) {
    assert.ok(GT.fi[k] && GT.en[k], k);
    assert.deepEqual((GT.fi[k].match(/\{\w+\}/g) || []).sort(), (GT.en[k].match(/\{\w+\}/g) || []).sort(), `muuttujat ${k}`);
    assert.ok(!/\p{Extended_Pictographic}/u.test(GT.fi[k] + GT.en[k]), `${k}: emoji`);
  }
});

test('offers: tarjotaan vain maksettavalle varaukselle, päätökset tulevat palvelimelta', () => {
  const m = model({ mpShow: true, redeem: true });
  assert.deepEqual(offers(m, booking()), { mobilepay: true, gift: true, claims: false });
  assert.deepEqual(offers(m, booking({ status: 'pending' })), { mobilepay: true, gift: true, claims: false });
  assert.deepEqual(offers(m, booking({ payment_status: 'paid' })), { mobilepay: false, gift: false, claims: false });
  assert.deepEqual(offers(m, booking({ status: 'cancelled' })), { mobilepay: false, gift: false, claims: false });
  assert.deepEqual(offers(model(), booking()), { mobilepay: false, gift: false, claims: false }, 'ei oletettua maksutapaa');
  assert.deepEqual(offers(model({ claims: [{ id: 1 }] }), booking({ payment_status: 'paid' })).claims, true, 'lunastuspyynnöt näkyvät maksun jälkeenkin');
  assert.deepEqual(offers(m, null), { mobilepay: false, gift: false, claims: false });
});

test('dueAmount: palvelimen unpaid ensin, sitten varauksen kentät, muuten ei summaa', () => {
  assert.equal(dueAmount(model({ opts: { unpaid: 25 } }), booking()), 25);
  assert.equal(dueAmount(model({ opts: { unpaid: 0 } }), booking()), 0);
  assert.equal(dueAmount(model(), booking({ unpaid: 12.5 })), 12.5);
  assert.equal(dueAmount(model(), booking({ total: 40, paid: 15 })), 25);
  assert.equal(dueAmount(model(), booking({ total: 40 })), 40);
  assert.equal(dueAmount(model(), booking({ payment_status: 'partial', total: 40 })), null);
  assert.equal(dueAmount(model(), null), null);
});

test('onlineAvailable / onlineAtCheckout: testimenetelmä vain testiympäristössä, lahjakortti redeem_enabled', () => {
  assert.equal(onlineAvailable(null), false); assert.equal(onlineAtCheckout(null), false);
  assert.equal(onlineAvailable(model({ mpShow: true })), true); assert.equal(onlineAvailable(model({ redeem: true })), true); assert.equal(onlineAvailable(model()), false);
  const live = model({ opts: { method: method() } }), test_ = model({ opts: { method: method({ test: true }) } });
  assert.equal(onlineAtCheckout(live), true);
  assert.equal(onlineAtCheckout(test_), false, 'test=true piilossa tuotannossa');
  assert.equal(onlineAtCheckout({ ...test_, env: { testUi: true } }), true, 'test=true näkyy testisivustolla');
  assert.equal(onlineAtCheckout(model({ redeem: true })), true);
  assert.equal(onlineAtCheckout(model()), false);
});

test('loadPayChoices: puuttuvat RPC:t ja virheet eivät heitä, ei tarjontaa', async () => {
  const rpc = async () => { throw new Error('PGRST202'); };
  const m = await loadPayChoices({ rpc, token: TOKEN, cfg: {}, search: '' });
  assert.equal(m.mpShow, false); assert.equal(m.redeem, false); assert.deepEqual(m.claims, []);
  assert.equal(onlineAvailable(m), false);
});

test('loadPayChoices: MobilePay + lahjakortti palvelimen vastauksista; pyynnöt haetaan vain tokenilla ja kun lunastus on päällä', async () => {
  const calls = [];
  const rpc = async (name, args) => {
    calls.push(name);
    if (name === 'public_payment_options') return popts();
    if (name === 'public_gift_card_packages') return { ok: true, redeem_enabled: true, packages: [] };
    if (name === 'public_get_order_voucher_claims') return { ok: true, claims: [{ id: 7, status: 'received' }] };
    return { ok: false };
  };
  const m = await loadPayChoices({ rpc, token: TOKEN, cfg: {}, search: '' });
  assert.equal(m.mpShow, true); assert.equal(m.redeem, true); assert.equal(m.claims.length, 1);
  assert.ok(calls.includes('public_payment_options') && calls.includes('public_get_order_voucher_claims'));
  calls.length = 0;
  const k = await loadPayChoices({ rpc, token: null, cfg: {}, search: '' });
  assert.ok(!calls.includes('public_get_order_voucher_claims'), 'kassalla ei ole tokenia → ei pyyntöjä');
  assert.equal(k.redeem, true); assert.deepEqual(k.claims, []);
  const off = await loadPayChoices({ rpc: async (n) => (n === 'public_gift_card_packages' ? { ok: true, redeem_enabled: false } : popts({ methods: [] })), token: TOKEN, cfg: {}, search: '' });
  assert.equal(off.mpShow, false); assert.equal(off.redeem, false);
});

test('shop-mock: oletus ei muutu; scenario=pay antaa MobilePayn, lahjakortin ja maksetun tilan public_get_booking-vastaukseen', async () => {
  const plain = createShopMock({ storage: null });
  assert.deepEqual(await plain.rpc('public_payment_options', {}), { ok: true, online_enabled: false, methods: [] });
  assert.equal(plain.mpFetch, undefined);
  const s = createShopMock({ storage: null, scenario: 'pay' });
  const o = await s.rpc('public_payment_options', { p_token: TOKEN });
  assert.equal(o.ok, true); assert.ok(o.methods.some((x) => x.code === 'mobilepay'));
  const b = await s.rpc('public_get_booking', { p_token: TOKEN });
  assert.equal(b.ok, true); assert.equal(b.payment_status, 'unpaid'); assert.equal(b.total, 40);
  const pk = await s.rpc('public_gift_card_packages', {}); assert.equal(pk.redeem_enabled, true);
  const r = await s.rpc('public_apply_gift_card', { p_token: TOKEN, p_code: 'HH3A-7CEF-HJKL', p_amount: null });
  assert.equal(r.ok, true);
  const b2 = await s.rpc('public_get_booking', { p_token: TOKEN });
  assert.equal(b2.payment_status, 'paid', 'lahjakortti kattaa 40 € → varaus maksettu');
  assert.equal(typeof s.mpFetch, 'function');
});

test('shop-mock: scenario=pay-off ei tarjoa MobilePayta', async () => {
  const s = createShopMock({ storage: null, scenario: 'pay-off' });
  const o = await s.rpc('public_payment_options', { p_token: TOKEN });
  assert.ok(!(o.methods || []).some((x) => x.code === 'mobilepay'));
});

test('order-mock: MobilePay-paluuosoite säilyttää polun (polkuetuliite), hashin (vahvistussivun token) ja mock-ajoitukset', async () => {
  const prev = globalThis.location;
  globalThis.location = new URL(`https://joonasvaarala.github.io/saunotus-uusi/varaa/vahvistus/?mock=1&scenario=pay&mpinterval=150&mpmax=3000#${TOKEN}`);
  try {
    const om = createOrderMock({ scenario: 'pay' });
    const res = await om.mpFetch('https://x.test/functions/v1/mobilepay-start', { method: 'POST', body: JSON.stringify({ order_token: TOKEN }) });
    const j = JSON.parse(await res.text()); const u = new URL(j.redirect_url);
    assert.equal(u.pathname, '/saunotus-uusi/varaa/vahvistus/'); assert.equal(u.hash, `#${TOKEN}`);
    assert.equal(u.searchParams.get('pay'), 'mobilepay'); assert.equal(u.searchParams.get('mock'), '1');
    assert.equal(u.searchParams.get('mpinterval'), '150'); assert.equal(u.searchParams.get('mpmax'), '3000');
  } finally { globalThis.location = prev; }
});

test('lähde: public_payment_mode:a ei kirjoiteta, ei kopioitua maksulogiikkaa, rakennus kopioi uudet tiedostot', () => {
  for (const f of ['../shop/src/shop.js', '../shop/src/pay-choices.js', '../shop/src/shop-mock.js']) assert.ok(!/set_setting|update_setting|settings\s*\.\s*upsert|public_payment_mode\s*[:=]\s*['"]/.test(src(f)), `${f}: kirjoittaa asetuksen`);
  const pc = src('../shop/src/pay-choices.js');
  for (const m of ['./mobilepay-api.js', './mobilepay-ui.js', './mobilepay-logic.js', './gift-api.js', './order-gift.js']) assert.ok(pc.includes(m), `pay-choices käyttää ${m}`);
  assert.ok(!/public_apply_gift_card|public_resolve_gift_code|mobilepay-start/.test(pc.replace(/\/\/.*$/gm, '')), 'RPC:t kutsutaan olemassa olevien moduulien kautta');
  const build = src('../shop/build.mjs'); assert.ok(build.includes("'pay-choices.js'") && build.includes("'pay-choices-texts.js'"));
  const shop = src('../shop/src/shop.js'); assert.ok(shop.includes("from './pay-choices.js'") && shop.includes('runReturn'));
});

test('mobilepay-start: palautusosoitteen polkuetuliite säilyy (vastaa tuotannon v4:ää)', () => {
  const t = src('../supabase/functions/_shared/mobilepay.ts');
  const body = t.slice(t.indexOf('export function buildReturnUrl'));
  assert.ok(/pathname/.test(body.slice(0, 900)), 'buildReturnUrl käsittelee site_base_url:n polun');
  assert.ok(src('../supabase/functions/_tests/mobilepay_test.ts').includes('/saunotus-uusi/tilaus/?t='), 'Deno-testi kattaa polkuetuliitteen');
});
