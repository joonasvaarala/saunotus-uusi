// Maksuvalinta kassalle ja vahvistussivulle: tekstipariteetti, tarjontapäätökset (offers/dueAmount/onlineAtCheckout), latauksen virheensieto,
// mock-skenaario "pay" (sama order-mock/gift-mock kuin tilaussivulla), MobilePay-paluuosoite (hash + polkuetuliite säilyvät), ettei public_payment_mode:a kirjoiteta.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, cpSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { normCheckoutOptions } from '../shop/src/mobilepay-logic.js';
import { createMobilepayApi } from '../shop/src/mobilepay-api.js';
import { normOrder } from '../shop/src/order-api.js';
import { rowLabel } from '../shop/src/options-logic.js';
import { createOptionPicker } from '../shop/src/options-ui.js';
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
const checkoutOpts = ({ mp = true, gc = true, test = false } = {}) => ({ ok: true, mobilepay_enabled: mp, gift_card_redeem_enabled: gc, methods: [
  ...(mp ? [method({ kind: 'online', test })] : []), ...(gc ? [{ code: 'gift_card', kind: 'redeem', provider: 'gift_card', label: 'Lahjakortti', label_en: 'Gift card', test: false, check_rpc: 'public_check_gift_card', apply_rpc: 'public_apply_gift_card' }] : [])] });
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
  assert.deepEqual(offers(m, booking()), { mobilepay: true, vismapay: false, gift: true, claims: false, payLater: false });
  assert.deepEqual(offers(m, booking({ status: 'pending' })), { mobilepay: true, vismapay: false, gift: true, claims: false, payLater: false });
  assert.deepEqual(offers(m, booking({ payment_status: 'paid' })), { mobilepay: false, vismapay: false, gift: false, claims: false, payLater: false });
  assert.deepEqual(offers(m, booking({ status: 'cancelled' })), { mobilepay: false, vismapay: false, gift: false, claims: false, payLater: false });
  assert.deepEqual(offers(model(), booking()), { mobilepay: false, vismapay: false, gift: false, claims: false, payLater: false }, 'ei oletettua maksutapaa');
  assert.deepEqual(offers(model({ claims: [{ id: 1 }] }), booking({ payment_status: 'paid' })).claims, true, 'lunastuspyynnöt näkyvät maksun jälkeenkin');
  assert.deepEqual(offers(m, null), { mobilepay: false, vismapay: false, gift: false, claims: false, payLater: false });
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
    if (name === 'public_checkout_payment_options') return checkoutOpts();
    if (name === 'public_gift_card_packages') return { ok: true, redeem_enabled: true, packages: [] };
    if (name === 'public_get_order_voucher_claims') return { ok: true, claims: [{ id: 7, status: 'received' }] };
    return { ok: false };
  };
  const m = await loadPayChoices({ rpc, token: TOKEN, cfg: {}, search: '' });
  assert.equal(m.mpShow, true); assert.equal(m.redeem, true); assert.equal(m.claims.length, 1);
  assert.ok(calls.includes('public_payment_options') && calls.includes('public_get_order_voucher_claims'));
  calls.length = 0;
  const k = await loadPayChoices({ rpc, token: null, cfg: {}, search: '' });
  assert.deepEqual(calls, ['public_checkout_payment_options'], 'kassa: vain public_checkout_payment_options (ei public_payment_options(null), ei lahjakorttipaketteja)');
  assert.equal(k.redeem, true, 'gift_card methods-listassa → lahjakortti'); assert.deepEqual(k.claims, []);
  assert.equal(k.opts.method.code, 'mobilepay'); assert.equal(onlineAtCheckout(k), true);
  const off = await loadPayChoices({ rpc: async (n) => (n === 'public_gift_card_packages' ? { ok: true, redeem_enabled: false } : popts({ methods: [] })), token: TOKEN, cfg: {}, search: '' });
  assert.equal(off.mpShow, false); assert.equal(off.redeem, false);
});

test('kassa: public_checkout_payment_options → normCheckoutOptions; tapa vain jos methods-listassa, virhe/puuttuva RPC → ei tarjontaa', async () => {
  const both = normCheckoutOptions(checkoutOpts());
  assert.equal(both.ok, true); assert.equal(both.method.code, 'mobilepay'); assert.equal(both.gift, true);
  const gcOnly = normCheckoutOptions(checkoutOpts({ mp: false })); assert.equal(gcOnly.method, null); assert.equal(gcOnly.gift, true);
  const mpOnly = normCheckoutOptions(checkoutOpts({ gc: false })); assert.equal(mpOnly.method.code, 'mobilepay'); assert.equal(mpOnly.gift, false);
  const none = normCheckoutOptions(checkoutOpts({ mp: false, gc: false })); assert.equal(none.method, null); assert.equal(none.gift, false); assert.equal(none.ok, true);
  assert.equal(normCheckoutOptions({ ok: true, mobilepay_enabled: true, gift_card_redeem_enabled: true }).method, null, 'lippu ilman methods-riviä ei riitä: palvelimen methods on totuus');
  for (const bad of [null, undefined, { ok: false }, 'x']) { const n = normCheckoutOptions(bad); assert.equal(n.method, null); assert.equal(n.gift, false); }
  // kutsu: ei argumentteja; puuttuva RPC / virhe → null
  const seen = []; const api = createMobilepayApi({ rpc: async (n, a) => { seen.push([n, a]); return checkoutOpts(); }, token: null, functionUrl: (n) => n });
  assert.equal((await api.checkoutOptions()).ok, true); assert.deepEqual(seen[0], ['public_checkout_payment_options', {}]);
  const missing = createMobilepayApi({ rpc: async () => { throw Object.assign(new Error('x'), { status: 404, code: 'PGRST202' }); }, token: null, functionUrl: (n) => n });
  assert.equal(await missing.checkoutOptions(), null);
  // testimenetelmä kassalla: vain testisivustolla
  const t = await loadPayChoices({ rpc: async () => checkoutOpts({ gc: false, test: true }), token: null, cfg: {}, search: '' });
  assert.equal(onlineAtCheckout(t), false, 'tuotanto: test=true piilossa'); 
  const t2 = await loadPayChoices({ rpc: async () => checkoutOpts({ gc: false, test: true }), token: null, cfg: { mobilepayTestUi: true }, search: '' });
  assert.equal(onlineAtCheckout(t2), true, 'testisivusto: test=true näkyy');
  const e = await loadPayChoices({ rpc: async () => { throw new Error('boom'); }, token: null, cfg: {}, search: '' });
  assert.equal(onlineAtCheckout(e), false);
});

test('option_label (booking_52): rowLabel valitsee sivun kielen mukaan, fallback null', () => {
  const row = { option_label: 'Choose your treatment', option_label_fi: 'Valitse hoito', option_label_en: 'Choose your treatment' };
  assert.equal(rowLabel(row, 'fi'), 'Valitse hoito'); assert.equal(rowLabel(row, 'en'), 'Choose your treatment');
  assert.equal(rowLabel({ option_label: 'Valitse hoito' }, 'en'), 'Valitse hoito', 'vain option_label (tilauksen kieli)');
  assert.equal(rowLabel({ option_label: 'Valitse hoito' }, 'fi'), 'Valitse hoito');
  assert.equal(rowLabel({ option_label: null, option_label_fi: null, option_label_en: null }, 'fi'), null);
  assert.equal(rowLabel({ option_label: '  ' }, 'fi'), null);
  assert.equal(rowLabel({}, 'fi'), null); assert.equal(rowLabel(null, 'en'), null);
});

// minimaalinen DOM-tynkä: otsikko luetaan legendistä
const stubH = (tag, attrs = {}, ...kids) => {
  const el = { tag, attrs: attrs || {}, kids: kids.flat(Infinity).filter((k) => k != null), hidden: false, textContent: '', classList: { toggle() {} }, setAttribute() {}, removeAttribute() {}, addEventListener() {}, focus() {} };
  if (attrs?.text != null) el.kids.push(String(attrs.text));
  return el;
};
const textOf = (n) => (typeof n === 'string' ? n : (n.kids || []).map(textOf).join(''));
const findTag = (n, tag) => (typeof n === 'string' ? null : n.tag === tag ? n : (n.kids || []).map((k) => findTag(k, tag)).find(Boolean) || null);
test('option_label: valitsimen otsikko = rivin otsikko > tuotteen otsikko > oletus', () => {
  const opts = [{ code: 'a', name: 'A', name_en: 'A', description: null, description_en: null }];
  const title = (o) => { const pk = createOptionPicker({ h: stubH, lang: 'fi', options: opts, required: null, ...o }); return textOf(findTag(pk.node || pk.el || pk, 'legend')); };
  assert.match(title({ label: 'Valitse hoito (rivi)' }), /Valitse hoito \(rivi\)/);
  assert.match(title({ product: { option_label: 'Tuotteen otsikko' } }), /Tuotteen otsikko/);
  assert.match(title({ product: { option_label: 'Tuotteen otsikko' }, label: 'Rivin otsikko' }), /Rivin otsikko/);
  assert.match(title({ product: {}, label: null }), /Valitse hoito/);
  assert.match(title({}), /Valitse hoito/);
});

test('booking_52 mockit: public_get_booking items[] ja public_get_order reservations[] sisältävät option_label(_fi/_en); kassan RPC mockissa', async () => {
  const om = createOrderMock({ scenario: 'hoito' });
  const o = await om.rpc('public_get_order', { p_token: TOKEN });
  const r = o.reservations.find((x) => x.option_choices?.length);
  if (r) { assert.equal(r.option_label, 'Valitse hoito'); assert.equal(r.option_label_en, 'Choose your treatment'); assert.equal(r.option_label_fi, 'Valitse hoito'); }
  const c = await createOrderMock({ scenario: 'mp' }).rpc('public_checkout_payment_options', {});
  assert.equal(c.ok, true); assert.equal(c.mobilepay_enabled, true); assert.equal(c.gift_card_redeem_enabled, true);
  assert.deepEqual(c.methods.map((m) => m.code), ['mobilepay', 'gift_card']); assert.equal(c.methods[0].test, true);
  const prod = await createOrderMock({ scenario: 'mp-prod' }).rpc('public_checkout_payment_options', {}); assert.equal(prod.methods[0].test, false);
  const off = await createOrderMock({ scenario: 'mp-off' }).rpc('public_checkout_payment_options', {}); assert.equal(off.mobilepay_enabled, false); assert.deepEqual(off.methods.map((m) => m.code), ['gift_card']);
  const s = createShopMock({ storage: null });
  assert.deepEqual(await s.rpc('public_checkout_payment_options', {}), { ok: true, mobilepay_enabled: false, gift_card_redeem_enabled: false, methods: [] });
  const sp = createShopMock({ storage: null, scenario: 'pay' });
  assert.deepEqual((await sp.rpc('public_checkout_payment_options', {})).methods.map((m) => m.code), ['mobilepay', 'gift_card']);
});

test('order-api normOrder säilyttää option_label(_fi/_en); puuttuessa null → fallback oletusotsikkoon', async () => {
  const raw = await createOrderMock({ scenario: 'hoito' }).rpc('public_get_order', { p_token: TOKEN });
  const r = normOrder(raw).reservations.find((x) => x.option_choices.length);
  assert.equal(r.option_label, 'Valitse hoito'); assert.equal(r.option_label_en, 'Choose your treatment'); assert.equal(rowLabel(r, 'en'), 'Choose your treatment');
  const old = normOrder({ ...raw, reservations: raw.reservations.map(({ option_label, option_label_fi, option_label_en, ...x }) => x) }).reservations[0];
  assert.equal(old.option_label, null); assert.equal(rowLabel(old, 'fi'), null);
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

test('booking_52: migraatio, rollback ja SQL-testi repossa (vastaa tuotantoa); public_payment_mode:n semantiikkaa ei kosketa', () => {
  const mig = src('../supabase/migrations/20261018063202_booking_52_checkout_options.sql'), rb = src('../supabase/rollbacks/20261018063202_booking_52_ROLLBACK.sql'), t = src('../supabase/tests/checkout/t52_checkout_options.sql');
  for (const f of ['public_checkout_payment_options', '_option_label', 'public_get_booking', 'public_get_order']) assert.ok(new RegExp(`function booking\\.${f}\\(`, 'i').test(mig), `migraatio: ${f}`);
  assert.ok(/grant execute on function booking\.public_checkout_payment_options\(\) to anon, authenticated, service_role/i.test(mig), 'anon-oikeus kassan RPC:lle');
  assert.ok(/revoke all on function booking\._option_label\(bigint, text\) from public, anon, authenticated/i.test(mig), '_option_label sisäinen');
  assert.ok(/'option_label_fi'/.test(mig) && /'option_label_en'/.test(mig));
  assert.ok(/drop function if exists booking\.public_checkout_payment_options\(\)/i.test(rb) && /drop function if exists booking\._option_label\(bigint, text\)/i.test(rb), 'rollback poistaa uudet funktiot');
  assert.ok(!/option_label/.test(rb.replace(/--.*$/gm, '').replace(/drop function[^;]*;/gi, '')), 'rollback palauttaa public_get_booking/-order ilman option_label-kenttää');
  assert.ok(/T1a/.test(t) && /public_checkout_payment_options/.test(t));
  assert.ok(!/update booking\.settings|insert into booking\.settings/i.test(mig.replace(/--.*$/gm, '')), 'migraatio ei kirjoita asetuksia (public_payment_mode ennallaan)');
});
