// Lahjakorttien kauppalogiikka: koodin normalisointi, kenttien tarkistukset, p_items-muoto, tekstit (FI/EN-pariteetti), mock vs. sopimus §13.2.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as G from '../shop/src/gift-logic.js';
import { GT, gtText } from '../shop/src/gift-texts.js';
import { createGiftMock, MOCK_PACKAGES, validateBuy } from '../shop/src/gift-mock.js';
import { createOrderMock } from '../shop/src/order-mock.js';
import { normPackages, pdfEnabled, pdfHref } from '../shop/src/gift-api.js';
import { itemLabels } from '../shop/src/gift-logic.js';
import { MOCK_PACKAGES as ADMIN_PACKAGES } from '../admin/giftcards-mock.js';

test('koodin normalisointi: isot kirjaimet, viivat ja välilyönnit pois', () => {
  assert.equal(G.normalizeCode('hh4a-bcde-fghj'), 'HH4ABCDEFGHJ');
  assert.equal(G.normalizeCode(' hh4a bcde  fghj '), 'HH4ABCDEFGHJ');
  assert.equal(G.normalizeCode('HH4A_BCDE.FGHJ'), 'HH4ABCDEFGHJ');
  assert.equal(G.normalizeCode(null), '');
  assert.equal(G.formatCode('hh4abcdefghj'), 'HH4A-BCDE-FGHJ');
  assert.equal(G.formatCode('hh4a'), 'HH4A');
  assert.equal(G.formatCodeTyping('hh4abcdefghjxx'), 'HH4A-BCDE-FGHJ');
  assert.equal(G.formatCodeTyping('hh4a b'), 'HH4A-B');
  assert.equal(G.formatCodeTyping('hh4a'), 'HH4A');       // ei roikkuvaa viivaa
  assert.ok(G.codeComplete('hh4a-bcde-fghj') && !G.codeComplete('hh4a-bcde-fgh'));
});
test('tervehdys: 300 merkkiä sallittu, 301 ei; emoji = 1 merkki; ohjausmerkit pois', () => {
  assert.equal(G.greetingState('Ä'.repeat(300)).over, false);
  assert.equal(G.greetingState('Ä'.repeat(301)).over, true);
  assert.equal(G.greetingState('Ä'.repeat(301)).left, -1);
  assert.equal(G.charCount('😀'.repeat(300)), 300);
  assert.equal(G.cleanGreeting('  moi\u0000\u0007 hei\nnäkemiin  '), 'moi hei\nnäkemiin');
  assert.equal(G.charCount('  '), 0);
  assert.equal(G.GREETING_MAX, 300);
});
test('summan jäsennys: pilkku/piste, enintään 2 desimaalia', () => {
  assert.equal(G.parseAmount('75'), 75); assert.equal(G.parseAmount('75,5'), 75.5); assert.equal(G.parseAmount(' 29.99 '), 29.99);
  for (const bad of ['', 'abc', '12.345', '-5', '1e3', '1,2,3', '50 €', null]) assert.equal(G.parseAmount(bad), null, String(bad));
});
const pkgs = normPackages({ ok: true, sale_enabled: true, redeem_enabled: true, max_cards_per_order: 10, packages: MOCK_PACKAGES }).packages;
test('rivin tarkistus: avoin 29–500, määrä, saajan sähköposti, tervehdys', () => {
  const open = pkgs.find((p) => p.is_open), base = { pkg: 'open', amount: '50', qty: 1, recipientName: '', recipientEmail: '', greeting: '' };
  assert.deepEqual(G.validateLine(base, open), {});
  assert.equal(G.validateLine({ ...base, amount: '28.99' }, open).amount, 'amount');
  assert.equal(G.validateLine({ ...base, amount: '500' }, open).amount, undefined);
  assert.equal(G.validateLine({ ...base, amount: '500.01' }, open).amount, 'amount');
  assert.equal(G.validateLine({ ...base, qty: 0 }, open).qty, 'qty');
  assert.equal(G.validateLine({ ...base, deliveryTo: 'recipient', recipientName: 'Sanna', recipientEmail: 'ei-sähköposti' }, open).recipientEmail, 'invalid_email');
  assert.equal(G.validateLine({ ...base, recipientEmail: 'ei-sähköposti' }, open).recipientEmail, undefined, 'minulle-valinnalla saajan sähköpostia ei tarkisteta (ei lähetetä)');
  assert.equal(G.validateLine({ ...base, greeting: 'x'.repeat(301) }, open).greeting, 'invalid_greeting');
  assert.deepEqual(G.validateLine({ pkg: 'entry_2', qty: 2, amount: '' }, pkgs.find((p) => p.code === 'entry_2')), {});   // paketilla summaa ei tarkisteta
});
test('ostajan tarkistus', () => {
  assert.deepEqual(G.validateBuyer({ name: 'Olli Ostaja', email: 'olli@example.fi', phone: '+358 40 123 4567', terms: true }), {});
  const e = G.validateBuyer({ name: ' ', email: 'x@y', phone: '12', terms: false });
  assert.deepEqual(Object.keys(e).sort(), ['email', 'name', 'phone', 'terms']);
});
test('p_items ja kutsun parametrit täsmälleen sopimuksen §13.2 mukaan', () => {
  const lines = [{ pkg: 'open', amount: '75,5', qty: 1, recipientName: ' Mikko ', recipientEmail: 'Mikko@Example.FI', greeting: ' Hei\u0000! ' }, { pkg: 'entry_2', amount: '', qty: 2, recipientName: '', recipientEmail: '', greeting: '' }];
  assert.deepEqual(G.itemsPayload(lines, pkgs), [{ package: 'open', quantity: 1, amount: 75.5, delivery_to: 'buyer', recipient_name: 'Mikko', greeting: 'Hei!' }, { package: 'entry_2', quantity: 2, persons: 2, amount: 58, delivery_to: 'buyer' }], 'oletus = minulle; saajan sähköposti ei lähde kun toimitus ostajalle');
  const a = G.buyArgs({ lines, pkgs, buyer: { name: ' Olli ', email: ' Olli@X.fi ', phone: ' 040 1 ', marketing: 0 }, locale: 'en' });
  assert.deepEqual(Object.keys(a).sort(), ['p_email', 'p_items', 'p_locale', 'p_marketing_consent', 'p_name', 'p_phone']);
  assert.equal(a.p_locale, 'en'); assert.equal(a.p_marketing_consent, false); assert.equal(a.p_email, 'olli@x.fi');
  assert.equal(G.buyArgs({ lines, pkgs, buyer: { name: 'a', email: 'a', phone: 'a' }, locale: 'sv' }).p_locale, 'fi');
});
test('summat ja korttimäärä; enimmäismäärä', () => {
  const lines = [{ pkg: 'open', amount: '75,5', qty: 1 }, { pkg: 'entry_2', qty: 2 }, { pkg: 'saunotus_2', qty: 1 }];
  assert.deepEqual(G.totals(lines, pkgs), { cards: 4, total: 519.5 });
  assert.equal(G.cardsLeft(lines, 10), 6); assert.equal(G.cardsLeft(lines, 3), 0);
});
test('hinnat ja nimet vastaavat tuotantoa (kauppa-mock = hallinnan mock)', () => {
  assert.deepEqual(MOCK_PACKAGES.map((p) => [p.code, p.price, p.min_amount]).map(([c, p, m]) => [c, p, c === 'open' ? m : null]), [['open', null, 29], ['entry_2', 58, null], ['peat_mask_2', 88, null], ['saunarituaali_2', 98, null], ['sauna_treatment_2', 192, null], ['saunotus_2', 328, null]]);
  assert.deepEqual(MOCK_PACKAGES.map((p) => [p.code, p.name]), ADMIN_PACKAGES.map((p) => [p.code, p.name]));
});
test('tekstit: FI/EN-avaimet samat, paikkamerkit samat, ei tyhjiä', () => {
  const fi = Object.keys(GT.fi), en = Object.keys(GT.en);
  assert.deepEqual(fi.filter((k) => !en.includes(k)), []); assert.deepEqual(en.filter((k) => !fi.includes(k)), []);
  const ph = (s) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join();
  for (const k of fi) { assert.ok(GT.fi[k].trim() && GT.en[k].trim(), k); assert.equal(ph(GT.fi[k]), ph(GT.en[k]), `paikkamerkit: ${k}`); }
  assert.equal(gtText('fi', 'counter', { n: 5, max: 300 }), '5 / 300');
});
test('kaikilla sopimuksen virhekoodeilla on selkeä FI- ja EN-teksti', () => {
  const codes = ['sale_disabled', 'rate_limited', 'invalid_name', 'invalid_email', 'invalid_phone', 'invalid_items', 'invalid_package', 'package_inactive', 'invalid_quantity', 'too_many_cards', 'invalid_amount', 'invalid_greeting', 'invalid_code',
    'redeem_disabled', 'johku_cards_closed', 'gift_card_not_found', 'gift_card_inactive', 'gift_card_expired', 'gift_card_empty', 'insufficient_balance', 'amount_exceeds_unpaid', 'nothing_to_pay', 'invalid_amount', 'order_not_editable', 'gift_card_not_allowed', 'not_found', 'forbidden'];
  for (const c of codes) for (const l of ['fi', 'en']) assert.ok(GT[l][`err.${c}`], `${l} err.${c}`);
  for (const r of ['redeem_disabled', 'johku_cards_closed', 'expired', 'empty', 'verification_pending']) for (const l of ['fi', 'en']) assert.ok(GT[l][`nr.${r}`], `${l} nr.${r}`);
  for (const st of ['active', 'used', 'expired', 'pending_verification']) assert.ok(GT.fi[`bst.${st}`]);
  for (const st of ['pending_payment', 'active', 'used', 'expired', 'cancelled', 'pending_verification']) assert.ok(GT.fi[`cst.${st}`] && GT.en[`cst.${st}`]);
});
test('mock: osto-validoinnit vastaavat sopimusta', () => {
  const ok = { p_name: 'Olli', p_email: 'o@x.fi', p_phone: '0401234567', p_items: [{ package: 'open', amount: 50, quantity: 1 }] };
  assert.equal(validateBuy(ok), null);
  const code = (patch) => validateBuy({ ...ok, ...patch })?.code;
  assert.equal(code({ p_name: '' }), 'invalid_name'); assert.equal(code({ p_email: 'x' }), 'invalid_email'); assert.equal(code({ p_phone: '1' }), 'invalid_phone');
  assert.equal(code({ p_items: [] }), 'invalid_items'); assert.equal(code({ p_items: [{ package: 'zzz' }] }), 'invalid_package');
  assert.equal(code({ p_items: [{ package: 'open', amount: 28, quantity: 1 }] }), 'invalid_amount'); assert.equal(code({ p_items: [{ package: 'open', amount: 50.123, quantity: 1 }] }), 'invalid_amount');
  assert.equal(code({ p_items: [{ package: 'entry_2', quantity: 0 }] }), 'invalid_quantity'); assert.equal(code({ p_items: [{ package: 'entry_2', quantity: 11 }] }), 'too_many_cards');
  assert.equal(code({ p_items: [{ package: 'entry_2', quantity: 1, greeting: 'x'.repeat(301) }] }), 'invalid_greeting');
});
test('mock: saldotarkistus ja rate limit', async () => {
  const gm = createGiftMock({});
  const r = await gm.rpc('public_check_gift_card', { p_code: 'HH3A7CEFHJKL' });
  assert.ok(r.ok && r.code === 'HH3A-7CEF-HJKL' && r.balance === 100 && r.redeemable === true);
  assert.equal((await gm.rpc('public_check_gift_card', { p_code: 'HHPPPPPPPPPP' })).code, 'invalid_code');     // maksamaton = sama virhe
  assert.equal((await gm.rpc('public_check_gift_card', { p_code: 'JK1234567890' })).not_redeemable_reason, 'johku_cards_closed');
  for (let i = 0; i < 10; i++) await gm.rpc('public_check_gift_card', { p_code: `ZZ${i}` });
  assert.equal((await gm.rpc('public_check_gift_card', { p_code: 'HH3A7CEFHJKL' })).code, 'rate_limited');
});
test('mock: osittainen lunastus tilaukselle, kortin saldo ja maksamaton osa', async () => {
  const om = createOrderMock({ scenario: 'gift' }), T = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';
  const o0 = await om.rpc('public_get_order', { p_token: T }); assert.equal(o0.unpaid, 62);
  const r = await om.rpc('public_apply_gift_card', { p_token: T, p_code: 'hh7m-rtuv-wxy3' });
  assert.ok(r.ok); assert.equal(r.amount, 58); assert.equal(r.balance.unpaid, 4); assert.equal(r.gift_card.balance, 0); assert.equal(r.gift_card.code_last4, 'WXY3');
  assert.equal((await om.rpc('public_apply_gift_card', { p_token: T, p_code: 'HH7MRTUVWXY3' })).code, 'gift_card_empty');
  assert.equal((await om.rpc('public_apply_gift_card', { p_token: T, p_code: 'HH3A7CEFHJKL', p_amount: 5 })).code, 'amount_exceeds_unpaid');
  const r2 = await om.rpc('public_apply_gift_card', { p_token: T, p_code: 'HH3A7CEFHJKL' }); assert.ok(r2.ok && r2.amount === 4 && r2.gift_card.balance === 96 && r2.balance.unpaid === 0);
  assert.equal((await om.rpc('public_apply_gift_card', { p_token: T, p_code: 'HH3A7CEFHJKL' })).code, 'nothing_to_pay');
  const cards = createOrderMock({ scenario: 'cards' });
  assert.equal((await cards.rpc('public_apply_gift_card', { p_token: T, p_code: 'HH3A7CEFHJKL' })).code, 'gift_card_not_allowed');
  const gs = createOrderMock({ scenario: 'gift', giftSettings: { redeem_enabled: false } });
  assert.equal((await gs.rpc('public_apply_gift_card', { p_token: T, p_code: 'HH3A7CEFHJKL' })).code, 'redeem_disabled');
});
test('PDF-nappi: oletus config.js (päällä), lang sivun kielen mukaan, false piilottaa', () => {
  const fu = (n, q) => `/functions/v1/${n}?${new URLSearchParams(q)}`;
  globalThis.window = {};
  assert.equal(pdfEnabled({}), false); assert.equal(pdfHref({}, 'tok', fu, 'fi'), '');
  assert.equal(pdfHref({ giftCardPdf: true }, 'tok', fu, 'fi'), '/functions/v1/gift-card-pdf?t=tok&lang=fi');
  assert.equal(pdfHref({ giftCardPdf: true }, 'tok', fu, 'en'), '/functions/v1/gift-card-pdf?t=tok&lang=en');
  assert.equal(pdfHref({ giftCardPdf: true }, 'tok', fu), '/functions/v1/gift-card-pdf?t=tok&lang=fi', 'tuntematon/puuttuva kieli → fi');
  assert.equal(pdfHref({ giftCardPdf: 'oma-pdf' }, 'tok', fu, 'en'), '/functions/v1/oma-pdf?t=tok&lang=en');
  window.BOOKING_CONFIG = { giftCardPdf: true }; assert.equal(pdfEnabled({}), true);
  window.BOOKING_CONFIG = { giftCardPdf: false }; assert.equal(pdfEnabled({ giftCardPdf: true }), false);       // config.js voittaa
  assert.equal(pdfHref({ giftCardPdf: true }, '', fu, 'fi'), '');
  delete globalThis.window;
});
test('Paketin sisältölista: FI = label, EN = label_en (vain rivit joilla nimi kyseisellä kielellä)', () => {
  const p = pkgs.find((x) => x.code === 'peat_mask_2');
  assert.deepEqual(itemLabels(p, 'fi'), ['Yleinen vuoro', 'Turvenaamio ja jalkakylpy']);
  assert.deepEqual(itemLabels(p, 'en'), ['General session', 'Peat mask and foot bath']);
  assert.deepEqual(itemLabels({ items: [{ label: 'Yleinen vuoro', persons: 2 }, { persons: 2, addon_code: 'x' }] }, 'en'), [], 'ei label_en → ei listaa EN-sivulle');
  assert.deepEqual(itemLabels({ items: [{ label: 'Yleinen vuoro' }, { addon_code: 'x' }] }, 'fi'), ['Yleinen vuoro']);
  assert.deepEqual(itemLabels(pkgs.find((x) => x.is_open), 'en'), []); assert.deepEqual(itemLabels(null, 'fi'), []);
  const entry = pkgs.find((x) => x.code === 'entry_2');
  assert.deepEqual(G.itemLines(entry, 'fi', '/varaa/'), [{ label: 'Yleinen vuoro', href: '/varaa/#/tuote/yleinensauna' }]);
  assert.equal(G.itemLines(pkgs.find((x) => x.code === 'peat_mask_2'), 'fi', '/varaa/').find((x) => x.label.startsWith('Turve')).href, null);
  assert.equal(G.itemLines(pkgs.find((x) => x.code === 'saunarituaali_2'), 'fi', '/en/book').find((x) => x.label.startsWith('Sauna')).href, '/en/book/#/tuote/saunarituaali-ja-savusaunavuoro');
  assert.equal(G.packageAmount(entry, 1), 29);
  assert.equal(G.packageAmount(entry, 2), 58);
  assert.equal(G.packageAmount(entry, 3), 87);
  assert.equal(G.packageAmount(entry, 7), null);
  assert.equal(G.packageAmount(pkgs.find((x) => x.code === 'peat_mask_2'), 1), 44);
  assert.equal(G.packageAmount(pkgs.find((x) => x.code === 'peat_mask_2'), 2), 88);
  assert.equal(G.packageAmount(pkgs.find((x) => x.code === 'saunarituaali_2'), 2), 98);
  assert.equal(G.packageAmount(pkgs.find((x) => x.code === 'saunarituaali_2'), 6), 294);
  assert.equal(G.packageAmount(pkgs.find((x) => x.code === 'sauna_treatment_2'), 1), 128);
  assert.equal(G.packageAmount(pkgs.find((x) => x.code === 'sauna_treatment_2'), 2), 192);
  assert.equal(G.packageAmount(pkgs.find((x) => x.code === 'sauna_treatment_2'), 4), 320);
  assert.equal(G.packageAmount(pkgs.find((x) => x.code === 'saunotus_2'), 2), 328);
  assert.equal(G.packageAmount(pkgs.find((x) => x.code === 'saunotus_2'), 1), 239);
});

// ---------- Toimitusvalinta (sopimus §13.11, booking_46) ----------
const NOW = new Date('2026-10-17T12:00:00Z');   // 17.10.2026 klo 15.00 Helsingin aikaa (kesäaika päättyy 25.10.)
const R = (o) => G.resolveDelivery({ to: 'recipient', recipientEmail: 'saaja@example.fi', now: NOW, months: 6, ...o });
test('toimitusvalinta: oletus minulle; buyer ohittaa saate- ja ajastuskentät ilman virhettä', () => {
  assert.deepEqual(G.resolveDelivery({ now: NOW }).value, { delivery_to: 'buyer', cover_message: null, deliver_on: null, deliver_time: null });
  assert.equal(G.resolveDelivery({ recipientEmail: 'a@b.fi', now: NOW }).value.delivery_to, 'recipient', 'ei annettu + saajan sähköposti → recipient (kuten palvelin)');
  assert.deepEqual(G.resolveDelivery({ to: 'buyer', cover: 'x', on: 'roskaa', time: '99:99', now: NOW }).value, { delivery_to: 'buyer', cover_message: null, deliver_on: null, deliver_time: null });
});
test('toimitusvalinta: kaikki 8 virhekoodia (palvelimen koodit §13.11)', () => {
  assert.equal(G.resolveDelivery({ to: 'muu', now: NOW }).code, 'invalid_delivery_to');
  assert.equal(R({ recipientEmail: '' }).code, 'recipient_email_required');
  assert.equal(R({ cover: 'x'.repeat(1001) }).code, 'invalid_cover_message');
  assert.equal(R({ cover: 'x'.repeat(1000) }).ok, true);
  assert.equal(R({ on: '2026-10-16' }).code, 'deliver_on_past');
  assert.equal(R({ on: '2026-10-17', time: '14:54' }).code, 'deliver_on_past', 'tänään yli 5 min sitten oleva kellonaika');
  assert.equal(R({ on: '2026-10-17', time: '14:55' }).ok, true, 'rajalla 5 min');
  assert.equal(R({ on: '2027-04-18' }).code, 'deliver_on_too_far');
  assert.equal(R({ on: '2027-04-17' }).ok, true, 'tänään + 6 kk sallittu');
  assert.equal(R({ on: '2027-04-17', months: 3 }).code, 'deliver_on_too_far', 'ei yli kortin voimassaolon');
  assert.equal(R({ on: '2028-10-17', months: 36 }).code, 'deliver_on_too_far', 'enintään 12 kk');
  for (const on of ['17.10.2026', '2026-13-01', '2026-02-30', 'huomenna', '2026-11-01T9:00']) assert.equal(R({ on }).code, 'invalid_deliver_on', on);
  assert.equal(R({ time: '10:00' }).code, 'invalid_deliver_on', 'kellonaika ilman päivää');
  for (const time of ['24:00', '9:00', '10:60', 'aamu']) assert.equal(R({ on: '2026-12-01', time }).code, 'invalid_deliver_time', time);
});
test('toimitusvalinta: normalisointi (tänään ilman kellonaikaa = heti, pelkkä päivä, T-muoto, saateteksti siivotaan)', () => {
  assert.deepEqual(R({ on: '2026-10-17' }).value, { delivery_to: 'recipient', cover_message: null, deliver_on: null, deliver_time: null });
  assert.deepEqual(R({ on: '2026-12-24' }).value, { delivery_to: 'recipient', cover_message: null, deliver_on: '2026-12-24', deliver_time: null });
  assert.deepEqual(R({ on: '2026-12-24T18:30' }).value.deliver_time, '18:30');
  assert.equal(R({ cover: '  Hei\r\nMoi\u0000  ' }).value.cover_message, 'Hei\nMoi');
  assert.equal(G.helsinkiNow(new Date('2026-12-31T22:30:00Z')).date, '2027-01-01', 'Helsingin päivä (talviaika UTC+2)');
  assert.equal(G.addMonths('2026-08-31', 6), '2027-02-28'); assert.equal(G.deliverMaxDate('2026-10-17', 6), '2027-04-17');
});
test('lomakkeen kenttäkohtaiset virheet: saajalle valittaessa nimi + sähköposti pakollisia; ajankohta vain kun valittu', () => {
  const open = pkgs.find((p) => p.is_open), l = { pkg: 'open', amount: '50', qty: 1, recipientName: '', recipientEmail: '', greeting: '', deliveryTo: 'recipient', coverMessage: '', sendMode: 'now', deliverOn: '', deliverTime: '' };
  const v = (o) => G.validateLine({ ...l, ...o }, open, NOW);
  assert.deepEqual(v({}), { recipientName: 'recipient_name_required', recipientEmail: 'recipient_email_required' });
  assert.deepEqual(v({ recipientName: 'Sanna', recipientEmail: 'saaja@example.fi' }), {});
  assert.equal(v({ recipientName: 'S', recipientEmail: 'ei' }).recipientEmail, 'invalid_email');
  assert.equal(v({ recipientName: 'S', recipientEmail: 'a@b.fi', coverMessage: 'x'.repeat(1001) }).cover, 'invalid_cover_message');
  const ok = { recipientName: 'S', recipientEmail: 'a@b.fi' };
  assert.deepEqual(v({ ...ok, sendMode: 'now', deliverOn: '2020-01-01' }), {}, 'heti: päivää ei tarkisteta (ei lähetetä)');
  assert.equal(v({ ...ok, sendMode: 'later', deliverOn: '' }).deliverOn, 'invalid_deliver_on');
  assert.equal(v({ ...ok, sendMode: 'later', deliverOn: '2026-10-16' }).deliverOn, 'deliver_on_past');
  assert.equal(v({ ...ok, sendMode: 'later', deliverOn: '2027-05-01' }).deliverOn, 'deliver_on_too_far');
  assert.equal(v({ ...ok, sendMode: 'later', deliverOn: '2026-12-01', deliverTime: '25:00' }).deliverTime, 'invalid_deliver_time');
  assert.deepEqual(v({ ...ok, sendMode: 'later', deliverOn: '2026-12-01', deliverTime: '18:30' }), {});
  assert.equal(G.validateLine({ ...l, deliveryTo: 'buyer', greeting: 'x'.repeat(301) }, open, NOW).greeting, 'invalid_greeting');
  assert.deepEqual(Object.keys(G.SERVER_FIELD).sort(), ['deliver_on_past', 'deliver_on_too_far', 'invalid_cover_message', 'invalid_deliver_on', 'invalid_deliver_time', 'invalid_email', 'invalid_greeting', 'recipient_email_required']);
});
test('p_items: delivery_to aina; saaja-valinnalla email/saate/ajankohta; ajankohta vain kun "Valitse ajankohta"', () => {
  const base = { qty: 1, recipientName: ' Sanna ', recipientEmail: ' Saaja@Example.FI ', greeting: 'Hei', deliveryTo: 'recipient', coverMessage: ' Terveiset\r\nMoi ', sendMode: 'now', deliverOn: '2026-12-24', deliverTime: '18:30' };
  const lines = [{ pkg: 'entry_2', ...base }, { pkg: 'entry_2', ...base, sendMode: 'later' }, { pkg: 'entry_2', ...base, sendMode: 'later', deliverTime: '' }, { pkg: 'entry_2', ...base, deliveryTo: 'buyer', sendMode: 'later' }];
  const it = G.itemsPayload(lines, pkgs);
  assert.deepEqual(it[0], { package: 'entry_2', quantity: 1, persons: 2, amount: 58, delivery_to: 'recipient', recipient_name: 'Sanna', greeting: 'Hei', recipient_email: 'saaja@example.fi', cover_message: 'Terveiset\nMoi' }, 'heti → ei deliver_on/deliver_time');
  assert.deepEqual([it[1].deliver_on, it[1].deliver_time], ['2026-12-24', '18:30']);
  assert.deepEqual([it[2].deliver_on, 'deliver_time' in it[2]], ['2026-12-24', false], 'kellonaika valinnainen');
  assert.deepEqual(it[3], { package: 'entry_2', quantity: 1, persons: 2, amount: 58, delivery_to: 'buyer', recipient_name: 'Sanna', greeting: 'Hei' }, 'minulle → ei saajan sähköpostia, saatetta eikä ajankohtaa');
});
test('mock-palvelin: public_buy_gift_card palauttaa jokaisen virhekoodin {ok:false, code} ja toimituskentät kortilla', async () => {
  const m = createGiftMock({ delay: 0 });
  const buy = (it, extra = {}) => m.rpc('public_buy_gift_card', { p_items: [{ package: 'entry_2', quantity: 1, ...it }], p_name: 'Olli Ostaja', p_email: 'olli@example.fi', p_phone: '+358401234567', p_marketing_consent: false, p_locale: 'fi', ...extra });
  const fut = G.addMonths(G.helsinkiNow().date, 1);
  const cases = [[{ delivery_to: 'x' }, 'invalid_delivery_to'], [{ delivery_to: 'recipient' }, 'recipient_email_required'], [{ delivery_to: 'recipient', recipient_email: 'ei' }, 'invalid_email'],
    [{ greeting: 'x'.repeat(301) }, 'invalid_greeting'], [{ delivery_to: 'recipient', recipient_email: 'a@b.fi', cover_message: 'x'.repeat(1001) }, 'invalid_cover_message'],
    [{ delivery_to: 'recipient', recipient_email: 'a@b.fi', deliver_on: '2020-01-01' }, 'deliver_on_past'], [{ delivery_to: 'recipient', recipient_email: 'a@b.fi', deliver_on: G.addMonths(G.helsinkiNow().date, 7) }, 'deliver_on_too_far'],
    [{ delivery_to: 'recipient', recipient_email: 'a@b.fi', deliver_on: 'ei-pvm' }, 'invalid_deliver_on'], [{ delivery_to: 'recipient', recipient_email: 'a@b.fi', deliver_on: fut, deliver_time: '99:00' }, 'invalid_deliver_time']];
  for (const [it, code] of cases) { const r = await buy(it); assert.equal(r.ok, false, code); assert.equal(r.code, code); assert.ok(r.message); }
  const ok = await buy({ delivery_to: 'recipient', recipient_email: 'a@b.fi', recipient_name: 'Sanna', deliver_on: fut, deliver_time: '18:30', cover_message: 'Hei' });
  assert.equal(ok.ok, true); assert.deepEqual([ok.cards[0].delivery_to, ok.cards[0].deliver_on, ok.cards[0].deliver_time], ['recipient', fut, '18:30']);
  const b = await buy({ delivery_to: 'buyer', cover_message: 'x', deliver_on: 'roskaa' }); assert.equal(b.ok, true); assert.equal(b.cards[0].delivery_to, 'buyer'); assert.equal(b.cards[0].deliver_on, null);
  const top = await buy({}, { p_delivery_to: 'recipient', p_recipient_email: 'a@b.fi', p_deliver_on: '2020-01-01' }); assert.equal(top.code, 'deliver_on_past', 'p_-oletukset toimivat kuten rivikohtaiset');
});
test('virheteksti FI ja EN jokaiselle toimitusvirhekoodille (kenttäkohtainen)', () => {
  for (const code of [...G.DELIVERY_ERROR_CODES, 'invalid_delivery_to', 'recipient_name_required']) for (const lang of ['fi', 'en']) assert.ok(GT[lang][`err.${code}`] && gtText(lang, `err.${code}`, { months: 6, max: 300 }).length > 10, `${lang} err.${code}`);
  assert.match(gtText('fi', 'err.deliver_on_too_far', { months: 6 }), /6 kk/); assert.match(gtText('en', 'err.deliver_on_too_far', { months: 6 }), /6 months/);
});
