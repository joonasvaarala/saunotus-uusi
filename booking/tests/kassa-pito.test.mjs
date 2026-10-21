// Kassan 15 min paikanpito (§17): tekstit (FI/EN, Joonaksen vanhentunut-teksti, lahjakorttilause vain osuuden kanssa), tilanormalisointi, palvelinaikaan perustuva laskuri (ryömintä), ilmoitusportaat, kyselyaikataulu,
// virhekoodit, pitotilan tunnistus (palvelin päättää, vanha käytös ennallaan), mock-moottori (kaikki tilat), migraatioiden 53/54 mukanaolo, ettei public_payment_mode:a kirjoiteta.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, cpSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { HT, ht, holdError, HOLD_ERROR_CODES, methodList } from '../shop/src/hold-texts.js';
import { OT } from '../shop/src/order-texts.js';
import { STATES, normCheckout, isHoldView, holdModeOf, giftWasUsed, leftFromServer, createHoldClock, clockText, createAnnouncer, ANNOUNCE_STEPS, spoken, POLL, nextPollIn, changed } from '../shop/src/hold-logic.js';
import { normCheckoutOptions } from '../shop/src/mobilepay-logic.js';
import { normOrder } from '../shop/src/order-api.js';
import { createOrderMock } from '../shop/src/order-mock.js';
import { createHoldEngine, isHoldScenario, holdMockParams } from '../shop/src/hold-mock.js';
import { GT } from '../shop/src/gift-texts.js';
import { MT } from '../shop/src/mobilepay-texts.js';

const tmp = mkdtempSync(join(tmpdir(), 'kassa-pito-'));
cpSync(new URL('../shop/src/', import.meta.url), tmp, { recursive: true });
cpSync(new URL('../shared/sb.js', import.meta.url), join(tmp, 'sb.js'));
writeFileSync(join(tmp, 'package.json'), '{"type":"module"}');
const { offers } = await import(pathToFileURL(join(tmp, 'pay-choices.js')).href);
const { createShopMock } = await import(pathToFileURL(join(tmp, 'shop-mock.js')).href);
const src = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const TOKEN = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';
const memStore = () => { const m = new Map(); return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)) }; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- tekstit ----------
test('tekstit: FI ja EN samat avaimet ja samat {muuttujat}; ei emojeita; ei tyhjiä', () => {
  assert.deepEqual(Object.keys(HT.fi).sort(), Object.keys(HT.en).sort());
  for (const k of Object.keys(HT.fi)) {
    assert.ok(String(HT.fi[k]).trim() && String(HT.en[k]).trim(), `tyhjä: ${k}`);
    assert.deepEqual([...String(HT.fi[k]).matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort(), [...String(HT.en[k]).matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort(), `muuttujat: ${k}`);
    assert.ok(!/\p{Extended_Pictographic}/u.test(HT.fi[k] + HT.en[k]), `emoji: ${k}`);
  }
});
test('tekstit: Joonaksen sanamuodot kirjaimellisesti (vanhentunut + lahjakorttilause)', () => {
  assert.ok(!('lead' in HT.fi) && !('lead' in HT.en), 'toistava "Paikkavaraus on voimassa…" -teksti (lead) on poistettu FI+EN');
  assert.equal(ht('fi', 'expired', { minutes: 15 }), 'Paikkavaraus vanheni, koska maksua ei saatu 15 minuutin kuluessa. Mitään ei ole veloitettu. Voit tehdä uuden varauksen.');
  assert.equal(ht('en', 'expired', { minutes: 15 }), 'Your spot hold expired because payment was not received within 15 minutes. You have not been charged. You can make a new booking.');
  assert.equal(ht('fi', 'expiredGift'), 'Lahjakortin käytetty osuus on palautettu kortille.');
  assert.equal(ht('en', 'expiredGift'), 'Any gift card amount you applied has been returned to the card.');
  assert.ok(!/lahjakort|gift/i.test(ht('fi', 'expired', { minutes: 15 }) + ht('en', 'expired', { minutes: 15 })), 'perusteksti ei mainitse lahjakorttia (lause on erillinen)');
  assert.ok(ht('fi', 'expired', { minutes: 20 }).includes('20 minuutin'), 'pidon pituus tulee asetuksesta');
});
test('tekstit: maksamattoman varauksen peruutusnappi "Peruuta varaus" / "Cancel booking" (ei "Vapauta paikka" -sanastoa), vahvistus/onnistuminen yhtenäisesti', async () => {
  const i = await import('../shop/src/i18n.js'); const T = i.T || i.default || i.TX; const fi = T.fi, en = T.en;
  assert.equal(fi.cancelBooking, 'Peruuta varaus'); assert.equal(en.cancelBooking, 'Cancel booking');
  assert.equal(fi.cancelConfirm, 'Perutaanko varaus?'); assert.equal(en.cancelConfirm, 'Cancel this booking?');
  assert.equal(fi.cancelled, 'Varaus peruttu.'); assert.equal(en.cancelled, 'Booking cancelled.');
  const all = (fi.cancelBooking + fi.cancelConfirm + fi.cancelled + fi.cancelFail + en.cancelBooking + en.cancelConfirm + en.cancelled + en.cancelFail);
  assert.ok(!/vapauta|release|peru maksamaton|unpaid hold/i.test(all), 'napin/dialogin/viestien sanasto: peruuta varaus');
});
test('järjestys + kompakti banneri: otsikko + tilabadge → pitopaneeli → tiivis tilausyhteenveto → maksuosio; yhteenveto vain kerran; awaiting-otsikko vain ruudunlukijalle', () => {
  const shop = src('../shop/src/shop.js'), ord = src('../shop/src/order.js'), ui = src('../shop/src/hold-ui.js'), css = src('../shop/src/shop.css');
  assert.ok(shop.includes('holdHost, mpHost, dl,'), 'vahvistussivu: pitopaneeli ennen yhteenvetoa');
  assert.ok(shop.includes('dl.after(secEl)'), 'vahvistussivu: maksuosio yhteenvedon alle');
  assert.equal((shop.match(/dl\.dataset\.testid = 'conf-summary'/g) || []).length, 1, 'vahvistussivun yhteenveto rakennetaan vain kerran (ei duplikaattia)');
  assert.ok(/head, holdEl, closedEl, resv, optSec, lines, giftCards, claimBox, pay,/.test(ord), 'tilaussivu: pitopaneeli → peruutusviesti → varaus + summat → maksuosio');
  assert.ok(ui.includes("class: kind === 'awaiting' ? 'sr-only' : ''"), 'awaiting: "Maksa varaus vahvistaaksesi" -otsikko vain ruudunlukijalle (toisto h2:n ja tilabadgen kanssa)');
  assert.ok(css.includes('.bk-hold-awaiting{display:flex'), 'kompakti banneri (lause + laskuri samalla rivillä)');
  assert.equal(ht('fi', 'summary.remaining'), 'Maksettavaa jäljellä'); assert.equal(ht('en', 'summary.remaining'), 'Amount left to pay');
});
test('tekstit: 15 min -maksuohje (Joonaksen teksti), otsikko "Varauksesi odottaa maksua", testivaihtoehto merkitty testiksi', () => {
  assert.equal(ht('fi', 'mustPay', { minutes: 15 }), 'Varaus täytyy maksaa 15 minuutin sisään, muuten se peruuntuu ja paikka vapautuu.');
  assert.equal(ht('en', 'mustPay', { minutes: 15 }), 'The booking must be paid within 15 minutes, otherwise it is cancelled and your spot is released.');
  assert.equal(ht('fi', 'h2.awaiting'), 'Varauksesi odottaa maksua'); assert.equal(ht('en', 'h2.awaiting'), 'Your booking is awaiting payment');
  assert.ok(/testi/i.test(ht('fi', 'payLater.btn')) && /test/i.test(ht('en', 'payLater.btn')));
  assert.ok(src('../shop/src/shop.js').includes("'h2.awaiting'"), 'otsikko pitotilassa');
});
test('tilaussivu: peruttu ja vanhentunut varaus kertoo peruutuksesta ja linkittää uuteen varaukseen (site_texts, ei kovakoodattua lausetta)', () => {
  const ord = src('../shop/src/order.js');
  assert.ok(ord.includes("data-testid': 'order-closed'"), 'peruutusviesti');
  assert.ok(ord.includes('t.closedHoldExpired') && ord.includes('t.closedCancelled') && ord.includes('t.closedNewBooking') && ord.includes('t.closedHoldExpiredGift'));
  assert.ok(ord.includes('holdV && !co.expired'), 'vanhentuneella tilaussivulla ei toista pitopaneelia');
  assert.ok(!ord.includes('Sipoonjoen Perinnesauna') && !ord.includes('Paikkavaraus vanheni'), 'lausetta ei ole kovakoodattu order.js:ään');
  for (const k of ['closedHoldExpired', 'closedCancelled']) {
    assert.ok(OT.fi[k].includes('Sipoonjoen Perinnesauna') && OT.en[k].includes('Sipoonjoen Perinnesauna'), k);
  }
  assert.ok(OT.fi.closedHoldExpired.includes('{minutes}') && OT.en.closedHoldExpired.includes('{minutes}'));
  assert.ok(!/lahjakort|gift card/i.test(OT.fi.closedHoldExpired + OT.en.closedHoldExpired), 'perusteksti ei mainitse lahjakorttia');
  assert.equal(OT.fi.closedHoldExpiredGift, 'Lahjakortin käytetty osuus on palautettu kortille.');
  assert.equal(OT.en.closedHoldExpiredGift, 'Any gift card amount you applied has been returned to the card.');
  assert.equal(OT.fi.closedNewBooking, 'Tee uusi varaus');
  assert.equal(OT.en.closedNewBooking, 'Make a new booking');
  assert.ok(!ord.includes(OT.fi.closedHoldExpired), 'viesti tulee avaimesta');
});
test('virhekoodit: online_payment_unavailable / order_expired / order_preliminary / payment_in_progress selkeinä FI+EN (myös lahjakortti- ja MobilePay-teksteissä)', () => {
  for (const c of ['online_payment_unavailable', 'order_expired', 'order_preliminary', 'payment_in_progress']) {
    assert.ok(HOLD_ERROR_CODES.includes(c), c);
    for (const l of ['fi', 'en']) { assert.ok(holdError(l, c).length > 20, `${l} ${c}`); assert.equal(MT[l][`err.${c}`], holdError(l, c), `MobilePay ${l} ${c}`); }
  }
  for (const c of ['order_expired', 'order_preliminary', 'payment_in_progress']) for (const l of ['fi', 'en']) assert.equal(GT[l][`err.${c}`], holdError(l, c), `lahjakortti ${l} ${c}`);
  assert.ok(!holdError('fi', 'foo'));
  assert.equal(methodList('fi', ['mobilepay', 'gift_card']), 'MobilePay ja lahjakortti');
  assert.equal(methodList('en', ['mobilepay', 'gift_card']), 'MobilePay and gift card');
});

// ---------- tilat ----------
test('normCheckout: kaikki 7 tilaa; vanha backend (ei checkout_state) → null', () => {
  assert.equal(STATES.length, 7);
  for (const s of STATES) assert.equal(normCheckout({ checkout_state: s }).state, s);
  assert.equal(normCheckout({ status: 'pending' }), null); assert.equal(normCheckout(null), null); assert.equal(normCheckout({ checkout_state: 'foo' }), null);
  const c = normCheckout({ checkout_state: 'awaiting_payment', hold_expires_at: '2026-10-18T10:15:00Z', seconds_left: 600, server_now: '2026-10-18T10:05:00Z', remaining_amount: '40.00', payment_in_progress: false, hold_kind: 'checkout' });
  assert.equal(c.awaiting, true); assert.equal(c.processing, false); assert.equal(c.remaining, 40); assert.equal(c.holdKind, 'checkout'); assert.equal(c.secondsLeft, 600);
  assert.equal(normCheckout({ checkout_state: 'processing_payment' }).processing, true); assert.equal(normCheckout({ checkout_state: 'processing_payment' }).inProgress, true);
  assert.equal(normCheckout({ checkout_state: 'preliminary' }).preliminary, true); assert.equal(normCheckout({ checkout_state: 'expired' }).expired, true); assert.equal(normCheckout({ checkout_state: 'confirmed_unpaid' }).confirmed, true);
  assert.deepEqual(STATES.filter((s) => isHoldView(normCheckout({ checkout_state: s }))), ['awaiting_payment', 'processing_payment', 'preliminary', 'expired']);
  assert.equal(normCheckout({ checkout_state: 'expired', seconds_left: null }).secondsLeft, null);
  assert.equal(normCheckout({ checkout_state: 'cancelled', cancel_reason: 'hold_expired' }).cancelReason, 'hold_expired');
  assert.equal(normCheckout({ checkout_state: 'cancelled' }).cancelReason, null);
  assert.equal(normCheckout({ checkout_state: 'expired', cancel_reason: '' }).cancelReason, null);
});
test('pitotila: palvelimen hold_until_paid ratkaisee; ei kenttää → vanha käytös; RPC puuttuu → vain vanha ohje', () => {
  const co = (r) => normCheckoutOptions(r);
  assert.deepEqual(holdModeOf(co({ ok: true, hold_until_paid: true, hold_minutes: 15, methods: [] }), { public_payment_mode: 'pay_at_venue' }), { on: true, minutes: 15, legacy: false });
  assert.equal(holdModeOf(co({ ok: true, hold_until_paid: false, methods: [] }), { public_payment_mode: 'hold_until_paid' }).on, false, 'palvelin voittaa asetuksen');
  assert.equal(holdModeOf(co({ ok: true, methods: [] }), {}).on, false, 'vanha vastaus ilman hold-kenttiä → vanha käytös');
  assert.deepEqual(holdModeOf(co({ ok: true, methods: [] }), { public_payment_mode: 'hold_until_paid' }), { on: false, minutes: 15, legacy: true }, 'vanha backend + asetus: uutta pitonäkymää ei oteta käyttöön, vanha ohjeteksti säilyy');
  assert.equal(holdModeOf(co({ ok: true, hold_until_paid: true, hold_minutes: 20, methods: [] }), {}).minutes, 20);
  assert.deepEqual(holdModeOf(null, { public_payment_mode: 'hold_until_paid', hold_minutes: 12 }), { on: false, minutes: 12, legacy: true });
  assert.equal(holdModeOf(co(null), { public_payment_mode: 'hold_until_paid' }).legacy, true, 'RPC-virhe → vanha asetuspohjainen ohje');
  assert.equal(holdModeOf(null, { public_payment_mode: 'pay_at_venue' }).on, false);
});
test('lahjakorttilause: näytetään vain kun lahjakorttiosuus oli käytössä (payment_methods tai muistettu osamaksu)', () => {
  assert.equal(giftWasUsed({ payment_methods: ['gift_card'] }), true, 'palvelimen peruttu lahjakorttimaksu näkyy payment_methods:ssa');
  assert.equal(giftWasUsed({ payment_methods: ['mobilepay'] }), false);
  assert.equal(giftWasUsed({ payment_methods: [] }), false);
  assert.equal(giftWasUsed({}), false); assert.equal(giftWasUsed(null), false);
  assert.equal(giftWasUsed({ payment_methods: [] }, true), true, 'istunnossa muistettu osamaksu');
  assert.equal(giftWasUsed({ payment_methods: [] }, 'yes'), false, 'vain tosi boolean');
});

// ---------- laskuri: palvelinaika, ryömintä ----------
test('laskuri: johdetaan palvelimen ajoista (hold_expires_at - server_now), ei laitteen kellosta', () => {
  const realNow = Date.now;
  try {
    Date.now = () => Date.parse('2031-01-01T00:00:00Z');   // laitteen kello 5 vuotta väärässä
    const co = normCheckout({ checkout_state: 'awaiting_payment', hold_expires_at: '2026-10-18T10:15:00Z', server_now: '2026-10-18T10:00:00Z', seconds_left: 900 });
    assert.equal(leftFromServer(co), 900000);
    let t = 5000; const clock = createHoldClock(co, () => t);
    assert.equal(clockText(clock.left()), '15:00'); t += 61000; assert.equal(clockText(clock.left()), '13:59');
    Date.now = () => 0; assert.equal(clockText(clock.left()), '13:59', 'laitteen kellon hyppy ei vaikuta');
  } finally { Date.now = realNow; }
  assert.equal(leftFromServer(normCheckout({ checkout_state: 'awaiting_payment', seconds_left: 90 })), 90000, 'varalla seconds_left');
  assert.equal(leftFromServer(normCheckout({ checkout_state: 'expired' })), null);
  assert.equal(leftFromServer(normCheckout({ checkout_state: 'awaiting_payment', hold_expires_at: '2026-10-18T10:00:00Z', server_now: '2026-10-18T10:05:00Z' })), 0, 'ei negatiivista');
});
test('laskuri: ryömintä korjataan synkronoinnilla (yli 1,5 s ero → palvelimen arvo; pieni ero ei hypi)', () => {
  let t = 0; const co0 = normCheckout({ checkout_state: 'awaiting_payment', seconds_left: 900 });
  const clock = createHoldClock(co0, () => t);
  t += 300000;   // 5 min kulunut
  assert.equal(clockText(clock.left()), '10:00');
  assert.equal(clock.sync(normCheckout({ checkout_state: 'awaiting_payment', seconds_left: 599 })), false, '1 s ero: ei hyppyä');
  assert.equal(clockText(clock.left()), '10:00');
  assert.equal(clock.sync(normCheckout({ checkout_state: 'awaiting_payment', seconds_left: 570 })), true, 'ryömintä 30 s → korjataan');
  assert.equal(clockText(clock.left()), '09:30');
  assert.equal(clock.sync(normCheckout({ checkout_state: 'processing_payment' })), false, 'ei arvoa → ei muutosta');
  t += 1e9; assert.equal(clock.left(), 0); assert.equal(clockText(0), '00:00'); assert.equal(clockText(500), '00:01', 'pyöristys ylöspäin: 00:00 vasta kun oikeasti loppu');
});
test('ilmoitusportaat: vain 5 min / 2 min / 1 min / 30 s, kukin kerran; ei joka sekunti', () => {
  const a = createAnnouncer(); const said = [];
  for (let left = 900000; left > 0; left -= 1000) { const s = a.next(left); if (s != null) said.push(s); }
  assert.deepEqual(said, ANNOUNCE_STEPS); assert.equal(a.next(0), null);
  const b = createAnnouncer(); assert.equal(b.next(45000), 60000, 'sivu avattu 45 s kohdalla: vain yksi (seuraava ylitetty) ilmoitus'); assert.equal(b.next(44000), null); assert.equal(b.next(29000), 30000);
  assert.equal(createAnnouncer().next(900000), null);
  assert.equal(spoken('fi', 300000, ht), '5 minuuttia'); assert.equal(spoken('en', 60000, ht), '1 minute'); assert.equal(spoken('fi', 30000, ht), '30 sekuntia');
});
test('kyselyaikataulu: käsittely 3 s (hidastuu 2 min jälkeen), odotus ≤30 s ja nollalla 3 s; muut tilat ei kyselyä', () => {
  const st = (s) => normCheckout({ checkout_state: s });
  assert.equal(nextPollIn(st('processing_payment'), { processingElapsed: 0 }), POLL.processingMs);
  assert.equal(nextPollIn(st('processing_payment'), { processingElapsed: 130000 }), POLL.processingSlowMs);
  assert.equal(nextPollIn(st('awaiting_payment'), { leftMs: 600000 }), POLL.awaitingMs);
  assert.equal(nextPollIn(st('awaiting_payment'), { leftMs: 4000 }), 4000, 'tarkistus heti nollan kohdalla');
  assert.equal(nextPollIn(st('awaiting_payment'), { leftMs: 0 }), POLL.zeroRetryMs);
  for (const s of ['preliminary', 'expired', 'confirmed', 'confirmed_unpaid', 'cancelled']) assert.equal(nextPollIn(st(s), {}), null, s);
  assert.equal(nextPollIn(null), null);
  const a = st('awaiting_payment'), b = normCheckout({ checkout_state: 'awaiting_payment', remaining_amount: 10 });
  assert.equal(changed(a, a), false); assert.equal(changed(a, st('expired')), true); assert.equal(changed(a, b), true, 'osamaksu muuttaa loppusummaa'); assert.equal(changed(null, a), true);
});

// ---------- datakerros ----------
test('normOrder / normCheckoutOptions: pitokentät läpi; vanha vastaus → null / ei pitotilaa', () => {
  const base = { ok: true, order_no: 1, status: 'pending', payment_status: 'unpaid', total: 40, paid: 0, unpaid: 40, items: [], reservations: [], payments: [], receipts: [] };
  assert.equal(normOrder(base).checkout, null);
  const n = normOrder({ ...base, checkout_state: 'awaiting_payment', hold_expires_at: '2026-10-18T10:15:00Z', server_now: '2026-10-18T10:00:00Z', seconds_left: 900, payment_in_progress: false });
  assert.equal(n.checkout.state, 'awaiting_payment'); assert.equal(n.checkout.secondsLeft, 900);
  const o = normCheckoutOptions({ ok: true, hold_until_paid: true, hold_minutes: 15, group_threshold_persons: 0, group_hold_days: 7, methods: [] });
  assert.equal(o.hold, true); assert.equal(o.holdMinutes, 15);
  assert.equal(normCheckoutOptions({ ok: true, methods: [] }).hold, false); assert.equal(normCheckoutOptions({ ok: false }).hold, false);
});
test('offers: alustavaa ja vanhentunutta ei makseta; odottava ja vahvistettu maksamatta saa maksutavat', () => {
  const model = { mpShow: true, redeem: true, claims: [] };
  const b = (s, over = {}) => ({ status: s === 'expired' ? 'expired' : s === 'confirmed_unpaid' ? 'confirmed' : 'pending', payment_status: 'unpaid', checkout_state: s, ...over });
  assert.deepEqual(offers(model, b('awaiting_payment')), { mobilepay: true, vismapay: false, gift: true, claims: false, payLater: false });
  assert.equal(offers(model, b('confirmed_unpaid')).mobilepay, true);
  assert.equal(offers(model, b('preliminary')).mobilepay, false); assert.equal(offers(model, b('preliminary')).gift, false);
  assert.equal(offers(model, b('expired')).mobilepay, false);
  assert.equal(offers(model, { status: 'pending', payment_status: 'unpaid' }).mobilepay, true, 'vanha backend: ennallaan');
});

// ---------- mock-moottori ----------
const om = (scenario, extra = {}) => createOrderMock({ scenario, storage: memStore(), ...extra });
test('mock: skenaarioiden tunnistus ja parametrit', () => {
  for (const s of ['hold', 'hold-partial', 'hold-processing', 'hold-preliminary', 'hold-confirmed', 'hold-unpaid', 'hold-expired', 'hold-expired-gift', 'hold-cancelled', 'hold-unavailable']) assert.ok(isHoldScenario(s), s);
  for (const s of ['', 'pay', 'mp', 'hold-foo', 'holdx']) assert.ok(!isHoldScenario(s), s);
  assert.deepEqual(holdMockParams('?mock=1&holdsec=20&serverskew=3600&procsec=3'), { holdSeconds: 20, serverSkew: 3600, procSeconds: 3, payLaterTest: true, payLaterFail: '' });
  assert.deepEqual(holdMockParams('?mock=1&holdsec=abc&holdsec=0'), { holdSeconds: 900, serverSkew: 0, procSeconds: 10, payLaterTest: true, payLaterFail: '' });
});
test('mock: tilat vastaavat palvelimen checkout_state-arvoja', async () => {
  const get = async (sc, extra) => (await om(sc, extra).rpc('public_get_order', { p_token: TOKEN }));
  const want = { hold: 'awaiting_payment', 'hold-partial': 'awaiting_payment', 'hold-processing': 'processing_payment', 'hold-preliminary': 'preliminary', 'hold-confirmed': 'confirmed', 'hold-unpaid': 'confirmed_unpaid', 'hold-expired': 'expired', 'hold-expired-gift': 'expired', 'hold-cancelled': 'cancelled' };
  for (const [sc, st] of Object.entries(want)) { const r = await get(sc, { procSeconds: 600 }); assert.equal(r.checkout_state, st, sc); assert.ok(STATES.includes(r.checkout_state)); assert.ok(r.server_now); }
  const h = await get('hold'); assert.ok(h.seconds_left >= 898 && h.seconds_left <= 900); assert.equal(new Date(h.hold_expires_at) - new Date(h.server_now) >= 898000, true); assert.equal(h.payment_in_progress, false); assert.equal(h.remaining_amount, 40);
  const p = await get('hold-processing', { procSeconds: 600 }); assert.equal(p.payment_in_progress, true); assert.equal(p.checkout_state, 'processing_payment');
  assert.equal((await get('hold-preliminary')).hold_kind, 'preliminary');
  assert.equal((await get('hold-expired')).remaining_amount, 0);
  const legacy = await get('pay'); assert.equal(legacy.checkout_state, undefined, 'vanha skenaario: ei pitokenttiä');
  assert.equal((await om('pay').rpc('public_checkout_payment_options')).hold_until_paid, undefined);
  const co = await om('hold').rpc('public_checkout_payment_options'); assert.equal(co.hold_until_paid, true); assert.equal(co.hold_minutes, 15);
  assert.equal((await om('hold-unavailable').rpc('public_checkout_payment_options')).methods.length, 0);
});
test('mock: palvelimen kello (serverskew) ei muuta jäljellä olevaa aikaa → laskuri ei voi perustua laitteen kelloon', async () => {
  const a = await om('hold', { serverSkew: 0 }).rpc('public_get_order', { p_token: TOKEN }), b = await om('hold', { serverSkew: 3600 }).rpc('public_get_order', { p_token: TOKEN });
  assert.ok(Math.abs(a.seconds_left - b.seconds_left) <= 1);
  assert.ok(Math.abs(Date.parse(b.server_now) - Date.parse(a.server_now) - 3600000) < 2000, 'palvelimen kello eroaa laitteesta tunnin');
  assert.ok(Math.abs(Math.round(leftFromServer(normCheckout(b)) / 1000) - b.seconds_left) <= 1);
});
test('mock: pito vanhenee → tilaus expired, lahjakorttiosuus palautetaan (maksu cancelled), payment_methods kertoo lahjakortin; ilman lahjakorttia ei', async () => {
  const m = om('hold-partial', { holdSeconds: 1 });
  const before = await m.rpc('public_get_order', { p_token: TOKEN }); assert.equal(before.checkout_state, 'awaiting_payment'); assert.equal(before.unpaid, 20);
  await sleep(1200);
  const after = await m.rpc('public_get_order', { p_token: TOKEN });
  assert.equal(after.checkout_state, 'expired'); assert.equal(after.status, 'expired'); assert.equal(after.paid, 0); assert.ok(after.payments.every((p) => p.status === 'cancelled'));
  assert.deepEqual((await m.rpc('public_get_booking', { p_token: TOKEN })).payment_methods, ['gift_card'], 'peruttu lahjakorttimaksu näkyy payment_methods:ssa');
  const n = om('hold', { holdSeconds: 1 }); await sleep(1200);
  assert.equal((await n.rpc('public_get_order', { p_token: TOKEN })).checkout_state, 'expired');
  assert.deepEqual((await n.rpc('public_get_booking', { p_token: TOKEN })).payment_methods, [], 'ei lahjakorttia → ei lausetta');
  assert.deepEqual((await om('hold-expired-gift').rpc('public_get_booking', { p_token: TOKEN })).payment_methods, ['gift_card']);
  assert.deepEqual((await om('hold-expired').rpc('public_get_booking', { p_token: TOKEN })).payment_methods, []);
});
test('mock: virheet order_expired / order_preliminary / payment_in_progress (lahjakortti + MobilePay)', async () => {
  const exp = om('hold-expired'), pre = om('hold-preliminary'), prog = om('hold-processing', { procSeconds: 600 });
  assert.equal((await exp.rpc('public_apply_gift_card', { p_token: TOKEN, p_code: 'HH3A7CEFHJKL' })).code, 'order_expired');
  assert.equal((await pre.rpc('public_apply_gift_card', { p_token: TOKEN, p_code: 'HH3A7CEFHJKL' })).code, 'order_preliminary');
  assert.equal((await prog.rpc('public_apply_gift_card', { p_token: TOKEN, p_code: 'HH3A7CEFHJKL' })).code, 'payment_in_progress');
  const start = async (m) => JSON.parse(await (await m.mpFetch('https://x/functions/v1/mobilepay-start', { method: 'POST', body: JSON.stringify({ order_token: TOKEN }) })).text()).code;
  assert.equal(await start(exp), 'order_expired'); assert.equal(await start(pre), 'order_preliminary'); assert.equal(await start(prog), 'payment_in_progress');
  const ok = om('hold'); assert.equal(await start(ok), undefined, 'odottava tilaus voi maksaa');
});
test('mock: käsittely valmistuu → vahvistettu; MobilePay-paluu = käsittelyssä kunnes maksu kirjautuu', async () => {
  const m = om('hold-processing', { procSeconds: 1 });
  assert.equal((await m.rpc('public_get_order', { p_token: TOKEN })).checkout_state, 'processing_payment');
  await sleep(1200);
  const r = await m.rpc('public_get_order', { p_token: TOKEN }); assert.equal(r.checkout_state, 'confirmed'); assert.equal(r.payment_status, 'paid');
  const hp = om('hold'); await hp.mpFetch('https://x/functions/v1/mobilepay-start', { method: 'POST', body: '{}' });
  assert.equal((await hp.rpc('public_get_order', { p_token: TOKEN })).checkout_state, 'processing_payment', 'maksu aloitettu → käsittelyssä');
});
test('mock: pidon alku säilyy (päivitys ei nollaa), restart() nollaa (kassa luo pidon)', async () => {
  const st = memStore(); const a = createOrderMock({ scenario: 'hold', storage: st, holdSeconds: 100 });
  await sleep(1100); const s1 = (await a.rpc('public_get_order', { p_token: TOKEN })).seconds_left;
  const b = createOrderMock({ scenario: 'hold', storage: st, holdSeconds: 100 }); const s2 = (await b.rpc('public_get_order', { p_token: TOKEN })).seconds_left;
  assert.ok(s2 <= s1 && s1 - s2 <= 2, `päivitys jatkaa samasta (${s1} → ${s2})`);
  b.hold.restart(); assert.ok((await b.rpc('public_get_order', { p_token: TOKEN })).seconds_left >= 99);
});
test('mock (kauppa): vahvistussivun public_get_booking sisältää pitokentät; kassan luonti-RPC käynnistää pidon; fail=online_payment_unavailable|too_many_pending', async () => {
  const sm = createShopMock({ storage: memStore(), scenario: 'hold' });
  const b = await sm.rpc('public_get_booking', { p_token: TOKEN });
  assert.equal(b.checkout_state, 'awaiting_payment'); assert.ok(b.seconds_left > 0); assert.deepEqual(b.payment_methods, []);
  assert.equal((await sm.rpc('public_checkout_payment_options')).hold_until_paid, true);
  assert.equal((await createShopMock({ storage: memStore(), scenario: 'pay' }).rpc('public_get_booking', { p_token: TOKEN })).checkout_state, undefined, 'pay-skenaario ennallaan');
  for (const fail of ['online_payment_unavailable', 'too_many_pending']) {
    const f = createShopMock({ storage: memStore(), scenario: 'hold', fail }); const r = await f.rpc('public_create_treatment_booking', {});
    assert.equal(r.ok, false); assert.equal(r.code, fail);
  }
});
test('hold-moottori: yksittäiset tilat ilman order-mockia (guard ja methods)', () => {
  const o = { status: 'pending', total: 40, paid: 0, unpaid: 40, payments: [], payment_status: 'unpaid' }; const sync = () => { o.unpaid = o.total - o.paid; };
  const e = createHoldEngine({ scenario: 'hold', holdSeconds: 100, storage: memStore(), ctx: { o, sync, mp: { started: false, returning: false, settled: false }, mpMarkPaid() {}, r2: (n) => n } });
  assert.equal(e.guard(), null); assert.equal(e.kind, 'awaiting'); assert.deepEqual(e.methods(), []);
});

// ---------- migraatiot, lähdekoodin ehdot ----------
test('migraatiot 53 + 54 (rollback + testit + sopimus §17) ovat repossa kuten 52', () => {
  const dir = new URL('../supabase/', import.meta.url);
  const mig = readdirSync(new URL('migrations/', dir)).filter((f) => /booking_5[34]_/.test(f)).sort();
  assert.equal(mig.length, 2); assert.match(mig[0], /^\d{14}_booking_53_checkout_hold\.sql$/); assert.match(mig[1], /^\d{14}_booking_54_checkout_cancel\.sql$/);
  const m53 = readFileSync(new URL(`migrations/${mig[0]}`, dir), 'utf8'), m54 = readFileSync(new URL(`migrations/${mig[1]}`, dir), 'utf8');
  for (const w of ['_checkout_state_json', 'public_checkout_payment_options', 'hold_kind', 'checkout_hold_minutes', 'order_expired', 'order_preliminary', 'payment_in_progress']) assert.ok(m53.includes(w), `53: ${w}`);
  assert.ok(m54.length > 200);
  assert.ok(!/^\s*(begin|commit)\s*;/im.test(m53 + m54), 'ei begin/commit-käärettä (kuten 52)');
  assert.ok(!/public_payment_mode['"]?\s*,?\s*['"]?hold_until_paid/i.test(m53 + m54.replace(/--.*$/gm, '')) || /insert|do nothing|on conflict/i.test(m53), 'migraatio ei vaihda public_payment_mode:a');
  for (const f of [`rollbacks/${mig[0].replace(/_booking_53_.*/, '_booking_53_ROLLBACK.sql')}`, `rollbacks/${mig[1].replace(/_booking_54_.*/, '_booking_54_ROLLBACK.sql')}`, 'tests/checkout/t53_checkout_hold.sql', 'tests/checkout/t54_checkout_cancel.sql']) assert.ok(existsSync(new URL(f, dir)), f);
  assert.ok(src('../docs/KOODARI_talous_A_D_fi.md').includes('17.'), 'sopimus §17 mukana');
  assert.ok(existsSync(new URL('../docs/KASSA_pito_asiakasteksti_fi.md', import.meta.url)));
});
test('ehdot: public_payment_mode ei kirjoiteta; pitoon liittyvät tiedostot mukana buildissa; tekstit vain hold-texts.js:ssä', () => {
  const files = ['hold-ui.js', 'hold-logic.js', 'hold-texts.js', 'hold-mock.js', 'shop.js', 'order.js', 'treatment-ui.js', 'order-api.js', 'pay-choices.js'];
  for (const f of files) { const s = src(`../shop/src/${f}`); assert.ok(!/update\s+booking\.settings|\.from\(['"]settings|public_payment_mode['"]?\s*[:=]\s*['"](hold|pay)/i.test(s.replace(/\/\/.*$/gm, '')), `${f}: ei kirjoita asetuksia`); }
  const build = src('../shop/build.mjs'); for (const f of ['hold-texts.js', 'hold-logic.js', 'hold-ui.js', 'hold-mock.js']) assert.ok(build.includes(`'${f}'`), `build kopioi ${f}`);
  for (const f of ['hold-ui.js', 'shop.js', 'order.js', 'treatment-ui.js', 'pay-choices.js']) { const s = src(`../shop/src/${f}`); assert.ok(!s.includes('Paikkavaraus on voimassa') && !s.includes('Paikkavaraus vanheni'), `${f}: tekstit eivät ole kovakoodattu`); }
  const ui = src('../shop/src/hold-ui.js');
  assert.ok(!ui.includes("tx('lead'") && !ui.includes('hold-lead') && ui.includes("tx('mustPay'") && ui.includes("tx('timerLabel')"), 'paneelissa vain mustPay-ohje + laskuri (ei lead-toistoa)');
  assert.ok(ui.includes("role: 'timer'") && ui.includes("'aria-live': 'off'") && ui.includes("role: 'status'"), 'laskuri role=timer aria-live=off + erillinen status-alue');
  assert.ok(!/animation|blink/i.test(src('../shop/src/shop.css').split('Kassan paikanpito')[1].replace(/prefers-reduced-motion[^}]*}[^}]*}/, '')), 'ei vilkkuvaa/animoitua');
});
