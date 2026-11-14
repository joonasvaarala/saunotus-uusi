// HALL-LAHJAKORTIT-01: lahjakortin puhelinmyynti (maksulinkki sähköpostiin, kortin kieli, kaksivaiheinen dialogi) – yksikkötestit.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const imp = (p) => import(pathToFileURL(join(root, p)));
const S = await imp('admin/giftcards-sale-logic.js');
const G = await imp('admin/giftcards-api.js');
const { createGiftMock } = await imp('admin/giftcards-mock.js');
const { TEXTS } = await imp('admin/talous-texts.js');
const src = (p) => readFileSync(join(root, p), 'utf8');

test('saleMode: maksulinkki = pay_later + heti linkki; muut tavat sellaisenaan', () => {
  assert.deepEqual(S.saleMode(S.GC_MODE_LINK), { paymentMethod: 'pay_later', sendLink: true });
  assert.deepEqual(S.saleMode('pay_later'), { paymentMethod: 'pay_later', sendLink: false });
  assert.deepEqual(S.saleMode('mobilepay'), { paymentMethod: 'mobilepay', sendLink: false });
  assert.deepEqual(S.saleMode('free'), { paymentMethod: undefined, sendLink: false });
});

test('gcLocale: vain fi/en, muuten fi', () => {
  assert.equal(S.gcLocale('en'), 'en'); assert.equal(S.gcLocale('sv'), 'fi'); assert.equal(S.gcLocale(undefined), 'fi');
});

test('createCardAndLink: kaksi kutsua järjestyksessä, linkki saa tilauksen tunnuksen', async () => {
  const calls = [];
  const out = await S.createCardAndLink({ mode: S.GC_MODE_LINK,
    create: async (pm) => { calls.push(['create', pm]); return { order_id: 77, order_no: 15300, cards: [{}] }; },
    createLink: async (id) => { calls.push(['link', id]); return { email_queued: true, link_path: '/maksa/?p=x' }; } });
  assert.deepEqual(calls, [['create', 'pay_later'], ['link', 77]]);
  assert.equal(S.linkState(out), 'sent');
});

test('createCardAndLink: linkin virhe ei hävitä korttia eikä luo uutta (retry vain linkille)', async () => {
  let creates = 0, links = 0;
  const create = async () => { creates++; return { order_id: 5, order_no: 1, cards: [{ code: 'X' }] }; };
  const createLink = async () => { links++; if (links === 1) throw Object.assign(new Error('boom'), { code: 'rate_limited' }); return { email_queued: true }; };
  const out = await S.createCardAndLink({ mode: S.GC_MODE_LINK, create, createLink });
  assert.equal(creates, 1); assert.equal(out.res.cards.length, 1);
  assert.equal(S.linkState(out), 'failed'); assert.equal(out.linkError.code, 'rate_limited'); assert.equal(out.orderId, 5);
  const again = await S.tryLink(out.orderId, createLink);
  assert.equal(creates, 1, 'uudelleenyritys ei luo korttia');
  assert.equal(S.linkState({ wantsLink: true, ...again }), 'sent');
});

test('createCardAndLink: luonnin virhe menee kutsujalle eikä yritä linkkiä; muut tavat eivät luo linkkiä', async () => {
  let links = 0;
  await assert.rejects(S.createCardAndLink({ mode: S.GC_MODE_LINK, create: async () => { throw new Error('ei'); }, createLink: async () => { links++; } }), /ei/);
  assert.equal(links, 0);
  const out = await S.createCardAndLink({ mode: 'mobilepay', create: async () => ({ order_id: 1, paid: true }), createLink: async () => { links++; } });
  assert.equal(links, 0); assert.equal(S.linkState(out), 'none');
});

test('tryLink: tilauksen tunnus puuttuu → virhe ilman kutsua; linkState mock = created', async () => {
  const out = await S.tryLink(null, async () => { throw new Error('ei pitäisi kutsua'); });
  assert.equal(out.linkError.code, 'no_order');
  assert.equal(S.linkState({ wantsLink: true, link: { mock: true, email_queued: false }, linkError: null }), 'created');
  assert.equal(S.linkState({ wantsLink: true, link: { email_queued: false }, linkError: null }), 'created');
});

test('step1Error: summa ja ostaja', () => {
  const open = { is_open: true, min_amount: 20, max_amount: 500 };
  assert.equal(S.step1Error({ pkg: open, amount: 10, centsOk: true, free: false, buyerName: 'A', buyerEmail: 'a@example.invalid' }), 'amount');
  assert.equal(S.step1Error({ pkg: open, amount: 50, centsOk: true, free: false, buyerName: '', buyerEmail: '' }), 'buyer');
  assert.equal(S.step1Error({ pkg: open, amount: 50, centsOk: true, free: true }), null);
  assert.equal(S.step1Error({ pkg: { is_open: false }, amount: NaN, centsOk: false, free: false, buyerName: 'A', buyerEmail: 'b' }), null);
});

test('datakerros: englanninkielinen kortti lähtee p_locale=en ja pay_later; mock tallentaa kielen', async () => {
  const calls = [];
  const be = G.rpcBackend(async (n, a) => { calls.push({ n, a }); return { ok: true }; });
  await be.create({ package: 'open', amount: 50, paymentMethod: 'pay_later', locale: 'en', buyer: { name: 'B', email: 'b@example.invalid' } });
  assert.equal(calls.at(-1).a.p_locale, 'en'); assert.equal(calls.at(-1).a.p_payment_method, 'pay_later');
  const gift = G.createGiftApi({ rpc: null, mock: true, mockFactory: () => ({ rpc: createGiftMock({ today: '2026-10-17' }).rpc }) });
  const res = await gift.create({ package: 'open', amount: 50, paymentMethod: 'pay_later', locale: 'en', buyer: { name: 'B', email: 'b@example.invalid' } });
  assert.equal(res.paid, false); assert.ok(res.order_id); assert.equal(res.cards[0].locale, 'en'); assert.equal(res.cards[0].status, 'pending_payment');
});

test('näkymä: kaksi vaihetta, kieli valittavissa, ei kovakoodattua fi-kieltä, linkki tilaukseen', () => {
  const v = src('admin/views/talous-giftcards.js');
  assert.ok(!/locale: 'fi'/.test(v), 'kieli ei ole kovakoodattu');
  assert.match(v, /gcLocale\(fd\.get\('locale'\)\)/);
  assert.match(v, /gc-new-step1/); assert.match(v, /gc-new-step2/); assert.match(v, /gc-result-order/); assert.match(v, /gc-result-link-retry/);
  assert.match(src('admin/views/lahjakortit.js'), /createGiftcardsTab\(\{ api: null, gift, pay,/);
});

test('tekstit: uudet avaimet FI+EN', () => {
  for (const k of ['gc.n.mode.link', 'gc.n.locale', 'gc.n.next', 'gc.n.back', 'gc.n.stepNo', 'gc.n.step1', 'gc.n.step2', 'gc.r.link.failed', 'gc.r.link.retry', 'gc.r.link.sent', 'gc.r.openOrder']) {
    assert.ok(TEXTS.fi[k], `fi ${k}`); assert.ok(TEXTS.en[k], `en ${k}`);
  }
});
