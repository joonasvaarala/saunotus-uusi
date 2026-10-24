// Kumppanilahjakortit (sopimus §13.12, migraatiot booking_47/48) – kauppa: yksi koodikenttä, lähdevalinta, lunastuspyyntö, tilaussivun tila ja koodin korjaus.
// Kaikki RPC:t ovat mockattuja (order-mock.js / gift-mock.js peilaavat palvelimen vastausmuodot ja virhekoodit); mikään ei puhu tuotantokantaan.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as G from '../shop/src/gift-logic.js';
import { GT } from '../shop/src/gift-texts.js';
import { createGiftApi, GRPC } from '../shop/src/gift-api.js';
import { createOrderMock } from '../shop/src/order-mock.js';
import { createGiftMock } from '../shop/src/gift-mock.js';

const TOKEN = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';
// api + kutsuloki: mock-RPC käärittynä, jotta nähdään tarkat RPC-nimet ja p_-parametrit
function setup({ scenario = 'gift', settings = {} } = {}) {
  const m = createOrderMock({ scenario, giftSettings: settings });
  const calls = [];
  const rpc = async (name, args) => { calls.push({ name, args }); return m.rpc(name, args); };
  return { m, calls, api: createGiftApi({ rpc, mock: false }), last: (n) => calls.filter((c) => c.name === n).at(-1) };
}

test('koodin kelpoisuus: 6–24 merkkiä normalisoituna (viivat, välilyönnit, pienet kirjaimet sallittu)', () => {
  assert.ok(G.codeValid('ok19-123abc') && G.codeValid('KK12345ABCDEF') && G.codeValid('hh7m rtuv wxy3') && G.codeValid('A'.repeat(24)) && G.codeValid('ABCDEF'));
  assert.ok(!G.codeValid('ABCDE') && !G.codeValid('A'.repeat(25)) && !G.codeValid('--- ---') && !G.codeValid(''));
});

test('lähde koodin muodosta (peilaa palvelimen _vc_guess, booking_173): KK-alku → Kokemuskauppa, muu → Offerilla ehdotuksena', () => {
  assert.deepEqual(G.guessSource('KK12 345 ABC DEF'), { source: 'kokemuskauppa', confidence: 'high' });
  assert.deepEqual(G.guessSource('KK534536G5'), { source: 'kokemuskauppa', confidence: 'high' }, 'omistajan esimerkki KK534536G5');
  assert.deepEqual(G.guessSource('  kk-534 536g5 '), { source: 'kokemuskauppa', confidence: 'high' }, 'pienet kirjaimet, välit ja viivat');
  assert.deepEqual(G.guessSource('kk1'), { source: 'kokemuskauppa', confidence: 'high' }, 'mikä tahansa KK-alku');
  assert.deepEqual(G.guessSource('OK19-123ABC'), { source: 'offerilla', confidence: 'high' });
  assert.deepEqual(G.guessSource('ZXQW98765432'), { source: 'elamyslahjat', confidence: 'medium' });
  assert.deepEqual(G.guessSource('HH3A7CEFHJKL'), { source: 'offerilla', confidence: 'low' }, 'muu muoto → Offerilla vain ehdotuksena');
  assert.deepEqual(G.guessSource('ABCDEFGHIJ'), { source: 'offerilla', confidence: 'low' });
  assert.deepEqual(G.guessSource(''), { source: null, confidence: null }); assert.deepEqual(G.guessSource(null), { source: null, confidence: null });
  assert.equal(G.isMismatch('ABCDEFGHIJ', 'elamyslahjat'), false, 'heikko ehdotus ei varoita'); assert.equal(G.isMismatch('KK534536G5', 'offerilla'), true);
  assert.deepEqual(G.CLAIM_SOURCES, ['kokemuskauppa', 'offerilla', 'elamyslahjat'], 'Kiitoskauppa ei valinnoissa');
  assert.equal(G.SOURCE_LABELS.kiitoskauppa, 'Kiitoskauppa', 'vanhat rivit näkyvät nimellä');
  assert.deepEqual(['kokemuskauppa', 'offerilla', 'elamyslahjat', 'kiitoskauppa'].map(G.claimMethod), ['partner_voucher_kokemuskauppa', 'partner_voucher_offerilla', 'partner_voucher_elamyslahjat', 'partner_voucher']);
});

test('RPC-nimet ja p_-parametrit ovat sopimuksen mukaiset (voucher_claims: resolve, submit, get, update)', async () => {
  const { api, last } = setup();
  assert.deepEqual([GRPC.resolve, GRPC.submitClaim, GRPC.orderClaims, GRPC.updateClaim], ['public_resolve_gift_code', 'public_submit_voucher_claim', 'public_get_order_voucher_claims', 'public_update_voucher_claim_code']);
  await api.resolve('kk12 345 abcdef');
  assert.deepEqual(last('public_resolve_gift_code').args, { p_code: 'KK12345ABCDEF' });
  const sub = await api.submitClaim({ token: TOKEN, code: 'kk12 345 abcdef', source: 'kokemuskauppa' });
  assert.deepEqual(last('public_submit_voucher_claim').args, { p_token: TOKEN, p_code: 'KK12345ABCDEF', p_source: 'kokemuskauppa' }, 'p_order_item_id jätetään pois = koko tilaus');
  await api.orderClaims(TOKEN);
  assert.deepEqual(last('public_get_order_voucher_claims').args, { p_token: TOKEN });
  await api.updateClaimCode({ token: TOKEN, claimNo: sub.claim_no, code: 'KK98765ZYXWVU', source: 'offerilla' });
  assert.deepEqual(last('public_update_voucher_claim_code').args, { p_token: TOKEN, p_claim_id: sub.claim_no, p_code: 'KK98765ZYXWVU', p_source: 'offerilla' });
  await api.updateClaimCode({ token: TOKEN, claimNo: sub.claim_no, code: 'KK11111AAAAAA' });
  assert.ok(!('p_source' in last('public_update_voucher_claim_code').args), 'ilman lähdettä p_source puuttuu (= nykyinen myyjä)');
});

test('oma kortti (resolve → own): nykyinen lunastus public_apply_gift_card, summa valinnainen', async () => {
  const { api, last } = setup();
  const out = await G.resolveCode({ api, token: TOKEN, code: 'hh7m-rtuv-wxy3' });
  assert.equal(out.type, 'applied');
  assert.deepEqual(last('public_apply_gift_card').args, { p_token: TOKEN, p_code: 'HH7MRTUVWXY3' });
  assert.equal(out.result.amount, 58);
  const { api: api2, last: last2 } = setup();
  const o2 = await G.resolveCode({ api: api2, token: TOKEN, code: 'HH3A7CEFHJKL', amount: 25 });
  assert.equal(o2.type, 'applied'); assert.equal(last2('public_apply_gift_card').args.p_amount, 25);
});

test('oma kortti ei lunastettavissa: selite ennen lunastusta (Johku-kortti, vanhentunut, tyhjä); public_apply_gift_card ei kutsuta', async () => {
  const { api, calls } = setup();
  for (const [code, reason] of [['JK1234567890', 'johku_cards_closed'], ['HHAAAAAAAAAA', 'expired'], ['HHCCCCCCCCCC', 'empty']]) {
    const out = await G.resolveCode({ api, token: TOKEN, code });
    assert.equal(out.type, 'blocked'); assert.equal(out.reason, reason);
    for (const lang of ['fi', 'en']) assert.ok(GT[lang][`nr.${reason}`], `nr.${reason} ${lang}`);
  }
  assert.ok(!calls.some((c) => c.name === 'public_apply_gift_card'));
  const off = setup({ settings: { redeem_enabled: false } });
  assert.equal((await G.resolveCode({ api: off.api, token: TOKEN, code: 'HH7MRTUVWXY3' })).reason, 'redeem_disabled');
});

test('tuntematon koodi: myyjän vahvistus kolmella myyjällä ja esivalinta suggested_source', async () => {
  const { api, calls } = setup();
  const out = await G.resolveCode({ api, token: TOKEN, code: 'ok19-123abc' });
  assert.equal(out.type, 'choose_source');
  assert.deepEqual(out.sources.map((s) => s.code), ['kokemuskauppa', 'offerilla', 'elamyslahjat']);
  assert.deepEqual(out.sources.map((s) => s.label), ['Kokemuskauppa', 'Offerilla', 'Elämyslahjat']);
  assert.equal(out.suggested, 'offerilla'); assert.equal(out.confidence, 'high');
  assert.ok(!calls.some((c) => c.name === 'public_apply_gift_card' || c.name === 'public_submit_voucher_claim'), 'valinta ei lähetä mitään ennen vahvistusta');
  const none = await G.resolveCode({ api, token: TOKEN, code: 'ABCDEFGHIJ' });
  assert.equal(none.type, 'choose_source'); assert.deepEqual([none.suggested, none.confidence], ['offerilla', 'low'], 'muu muoto → Offerilla esivalittuna ehdotuksena');
  const kk = await G.resolveCode({ api, token: TOKEN, code: 'KK534536G5' });
  assert.deepEqual([kk.suggested, kk.confidence], ['kokemuskauppa', 'high']);
});

test('kumppanilunastus pois (voucher_claims.enabled=false): tuntematon koodi = "Koodia ei löytynyt"; submit palauttaa voucher_claims_disabled', async () => {
  const { api } = setup({ settings: { claims_enabled: false } });
  assert.equal((await G.resolveCode({ api, token: TOKEN, code: 'OK19123ABC' })).type, 'not_found');
  const r = await G.submitClaim({ api, token: TOKEN, code: 'OK19123ABC', source: 'offerilla' });
  assert.deepEqual([r.type, r.code], ['error', 'voucher_claims_disabled']);
});

test('lunastuspyyntö: vahvistus, idempotentti toisto, tila tilaussivulla, ei kaksoisriviä', async () => {
  const { api } = setup();
  const r = await G.submitClaim({ api, token: TOKEN, code: 'kk12345abcdef', source: 'kokemuskauppa' });
  assert.equal(r.type, 'claimed'); assert.equal(r.already, false); assert.equal(r.sourceLabel, 'Kokemuskauppa'); assert.equal(r.codeMasked, '…CDEF'); assert.equal(r.mismatch, false);
  assert.equal(r.method, 'partner_voucher_kokemuskauppa'); assert.equal(r.methodLabel, 'Lahjakortti – Kokemuskauppa');
  const again = await G.submitClaim({ api, token: TOKEN, code: 'KK12345ABCDEF', source: 'kokemuskauppa' });
  assert.equal(again.type, 'claimed'); assert.equal(again.already, true); assert.equal(again.claimNo, r.claimNo);
  const list = await api.orderClaims(TOKEN);
  assert.equal(list.claims.length, 1);
  const v = G.claimView(list.claims[0]);
  assert.equal(v.state, 'received'); assert.equal(v.textKey, 'vc.st.received'); assert.equal(v.canUpdate, true); assert.equal(v.codeMasked, '…CDEF');
  assert.ok(!JSON.stringify(list).includes('KK12345ABCDEF'), 'koko koodi ei koskaan julkisessa vastauksessa');
  const mism = await G.submitClaim({ api, token: TOKEN, code: 'OK19-123ABC', source: 'elamyslahjat' });
  assert.equal(mism.mismatch, true, 'source_mismatch kun valinta poikkeaa ehdotuksesta');
  const low = await G.submitClaim({ api, token: TOKEN, code: 'ABCD1234EF', source: 'elamyslahjat' });
  assert.equal(low.mismatch, false, 'heikko Offerilla-ehdotus ei varoita');
  assert.equal((await G.submitClaim({ api, token: TOKEN, code: 'ABCD1234XY', source: 'kiitoskauppa' })).code, 'invalid_source', 'Kiitoskauppa ei enää valittavissa');
});

test('lunastuspyynnön virheet: invalid_source, use_own_card, code_already_claimed, nothing_to_pay, too_many_claims, rate_limited', async () => {
  const { api } = setup({ scenario: 'claims' });
  assert.equal((await G.submitClaim({ api, token: TOKEN, code: 'ABCDEFGH', source: '' })).code, 'invalid_source');
  assert.equal((await G.submitClaim({ api, token: TOKEN, code: 'ABCDEFGH', source: 'partner_other' })).code, 'invalid_source', 'partner_other ei julkisesti');
  assert.equal((await G.submitClaim({ api, token: TOKEN, code: 'HH7MRTUVWXY3', source: 'elamyslahjat' })).code, 'use_own_card');
  assert.equal((await G.submitClaim({ api, token: TOKEN, code: 'OK19123ABC', source: 'offerilla' })).code, 'code_already_claimed', 'koodi on jo lunastettu');
  assert.equal((await api.submitClaim({ token: TOKEN, code: 'AB1', source: 'offerilla' })).code, 'invalid_code');
  const full = setup({ scenario: 'gift' });
  for (let i = 0; i < 10; i++) assert.equal((await G.submitClaim({ api: full.api, token: TOKEN, code: `CODE${String(i).padStart(4, '0')}XY`, source: 'offerilla' })).type, 'claimed');
  assert.equal((await G.submitClaim({ api: full.api, token: TOKEN, code: 'CODE9999XY', source: 'offerilla' })).code, 'too_many_claims');
  const rl = setup({ scenario: 'gift' });
  for (let i = 0; i < 10; i++) await rl.api.resolve(`ZZ${i}ZZZZZZZ`);   // tuntemattomat koodit kasvattavat yhteistä virhelaskuria (kuten palvelimella)
  const lim = await G.resolveCode({ api: rl.api, token: TOKEN, code: 'ZZZZZZZZ' });
  assert.deepEqual([lim.type, lim.code], ['error', 'rate_limited']);
});

test('tilaussivun tilat: vastaanotettu / lunastettu (summa) / ongelma (invalid_code …) ja koodin korjaus', async () => {
  const { api } = setup({ scenario: 'claims' });
  const claims = (await api.orderClaims(TOKEN)).claims.map(G.claimView);
  assert.deepEqual(claims.map((c) => c.state), ['received', 'problem', 'redeemed']);
  assert.deepEqual(claims.map((c) => c.textKey), ['vc.st.received', 'vc.problem.invalid_code', 'vc.st.redeemed']);
  assert.deepEqual(claims.map((c) => c.canUpdate), [true, true, false], 'korjaus vain open/problem-tilassa');
  assert.equal(claims[2].amount, 40);
  // ongelma → uusi koodi ja myyjä → takaisin vastaanotetuksi
  const fix = await G.updateClaimCode({ api, token: TOKEN, claimNo: claims[1].claimNo, code: 'zxqw-9876-5432', source: 'elamyslahjat' });
  assert.deepEqual([fix.type, fix.codeMasked], ['error', undefined], 'sama koodi ja myyjä → unchanged'); assert.equal(fix.code, 'unchanged');
  const ok = await G.updateClaimCode({ api, token: TOKEN, claimNo: claims[1].claimNo, code: 'qqww-1111-2222', source: 'offerilla' });
  assert.equal(ok.type, 'updated'); assert.equal(ok.sourceLabel, 'Offerilla'); assert.equal(ok.codeMasked, '…2222'); assert.equal(ok.methodLabel, 'Lahjakortti – Offerilla');
  const only = await G.updateClaimCode({ api, token: TOKEN, claimNo: claims[1].claimNo, code: '', source: 'kokemuskauppa', current: 'offerilla' });
  assert.equal(only.type, 'updated', 'tyhjä koodi = vain myyjän vaihto'); assert.equal(only.sourceLabel, 'Kokemuskauppa'); assert.equal(only.codeMasked, '…2222', 'koodi ennallaan');
  assert.equal((await G.updateClaimCode({ api, token: TOKEN, claimNo: claims[1].claimNo, code: '', source: 'kokemuskauppa', current: 'kokemuskauppa' })).code, 'invalid_code', 'tyhjä koodi ja sama myyjä → ei lähetetä');
  assert.equal((await G.updateClaimCode({ api, token: TOKEN, claimNo: claims[1].claimNo, code: 'QQWW11113333', source: 'kiitoskauppa', current: 'kokemuskauppa' })).code, 'invalid_source', 'vaihto Kiitoskauppaan estetty');
  const after = (await api.orderClaims(TOKEN)).claims.map(G.claimView).find((c) => c.claimNo === claims[1].claimNo);
  assert.equal(after.state, 'received'); assert.equal(after.problemCode, null);
  assert.equal((await G.updateClaimCode({ api, token: TOKEN, claimNo: claims[2].claimNo, code: 'NEWCODE123', source: 'offerilla' })).code, 'claim_not_editable');
  assert.equal((await G.updateClaimCode({ api, token: TOKEN, claimNo: 99999, code: 'NEWCODE123', source: 'offerilla' })).code, 'not_found');
  assert.equal((await G.updateClaimCode({ api, token: TOKEN, claimNo: claims[0].claimNo, code: 'HH7MRTUVWXY3', source: 'offerilla' })).code, 'use_own_card');
  assert.equal((await G.updateClaimCode({ api, token: TOKEN, claimNo: claims[0].claimNo, code: 'ab', source: 'offerilla' })).code, 'invalid_code', 'liian lyhyt koodi estetään jo selaimessa');
  assert.equal((await G.updateClaimCode({ api, token: TOKEN, claimNo: claims[0].claimNo, code: 'NEWCODE123', source: 'kiitos' })).code, 'invalid_source');
});

test('claimView: tuntemattomat arvot putoavat turvallisiin oletuksiin; hold_until/hours_left eivät vaikuta (booking_48: ei aikarajaa)', () => {
  assert.equal(G.claimView({ claim_no: 1, public_status: 'whatever', can_update_code: true }).state, 'received');
  assert.equal(G.claimView({ claim_no: 1, public_status: 'problem', problem_code: 'x_new', can_update_code: true }).textKey, 'vc.problem.other');
  assert.equal(G.claimView({ claim_no: 1, public_status: 'cancelled', can_update_code: true }).canUpdate, false, 'päätetilassa ei korjausta vaikka lippu olisi true');
  assert.equal(G.claimView({ claim_no: 1, public_status: 'received', can_update_code: false }).canUpdate, false);
  const v = G.claimView({ claim_no: 1, public_status: 'received', can_update_code: true, hold_until: '2030-01-01T00:00:00Z', hours_left: 3 });
  assert.ok(!('hold_until' in v) && !('hoursLeft' in v));
});

test('puuttuva RPC (404/PGRST202) → notReady, ei kaatumista', async () => {
  const rpc = async (name) => { throw Object.assign(new Error(`Could not find the function booking.${name} in the schema cache`), { status: 404, code: 'PGRST202' }); };
  const api = createGiftApi({ rpc, mock: false });
  assert.deepEqual(await G.resolveCode({ api, token: TOKEN, code: 'ABCDEFGH' }), { type: 'error', code: 'notReady' });
  assert.deepEqual(await G.submitClaim({ api, token: TOKEN, code: 'ABCDEFGH', source: 'offerilla' }), { type: 'error', code: 'notReady' });
  assert.equal((await api.orderClaims(TOKEN)).notReady, true);
});

test('virhekoodit: jokaiselle sopimuksen koodille on FI+EN-teksti (kumppanipolun vc.err.* tai yleinen err.*)', () => {
  const has = (lang) => (k) => GT[lang][k] != null;
  const codes = ['rate_limited', 'voucher_claims_disabled', 'not_found', 'invalid_source', 'invalid_code', 'order_not_editable', 'order_expired', 'gift_card_not_allowed', 'use_own_card', 'invalid_item', 'nothing_to_pay', 'code_already_claimed', 'too_many_claims', 'busy', 'claim_not_editable', 'unchanged'];
  for (const lang of ['fi', 'en']) for (const c of codes) { const k = G.errorKey(c, has(lang)); assert.notEqual(k, 'err.generic', `${lang}: ${c} puuttuu`); assert.ok(GT[lang][k], `${lang}: ${k}`); }
  assert.equal(G.errorKey('mystery', has('fi')), 'err.generic'); assert.equal(G.errorKey('', has('fi')), 'err.generic');
});

test('tekstit: FI/EN-pariteetti, sopimuksen vahvistusteksti sanasta sanaan, ei aikarajoja, ei emojeita', () => {
  const vc = (lang) => Object.keys(GT[lang]).filter((k) => k.startsWith('vc.') || k === 'o.codeHint').sort();
  assert.deepEqual(vc('fi'), vc('en')); assert.ok(vc('fi').length > 40);
  assert.equal(GT.fi['vc.done'], 'Kiitos lahjakorttivarauksesta! Aikasi on varattu. Lunastamme lahjakortin pian ja olemme yhteydessä, jos lunastuksessa on ongelmia.');
  assert.equal(GT.en['vc.done'], 'Thank you for your gift card booking! Your time is reserved. We will redeem the gift card shortly and contact you if there are any problems.');
  assert.equal(GT.fi['vc.chooseLead'], 'Emme löytäneet koodia omista lahjakorteistamme – valitse mistä lahjakortti on ostettu.');
  assert.equal(GT.fi['vc.submit'], 'Lähetä lahjakortti lunastettavaksi');
  assert.equal(GT.fi['vc.st.received'], 'Lahjakortti vastaanotettu – lunastus käsittelyssä');
  assert.equal(GT.fi['vc.problem.invalid_code'], 'Koodia ei löytynyt – tarkista koodi'); assert.equal(GT.fi['vc.problem.expired_code'], 'Lahjakortin voimassaolo on päättynyt');
  assert.equal(GT.fi['vc.problem.already_used'], 'Koodi on jo käytetty'); assert.equal(GT.fi['vc.problem.other'], 'Selvitämme lahjakortin lunastusta, olemme yhteydessä');
  assert.equal(GT.fi['vc.fixLabel'], 'Syötä oikea lahjakortin koodi');
  for (const lang of ['fi', 'en']) for (const k of vc(lang)) {
    const v = GT[lang][k];
    assert.ok(!/maksettu|\bpaid\b|kuitti|receipt/i.test(v), `${lang} ${k}: ei "maksettu/kuitti" (maksu kirjautuu vasta lunastuksessa)`);
    assert.ok(!/\d+\s*(h|tunti|hours?|pv|päiv|days?)\b|asti|until|vanhene|expire[sd]? (in|after)/i.test(v.replace(/Lahjakortin voimassaolo on päättynyt|The gift card has expired/, '')), `${lang} ${k}: ei aikarajoja (${v})`);
    assert.ok(!/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u.test(v), `${lang} ${k}: ei emojeita`);
  }
  for (const c of G.PROBLEM_CODES) for (const lang of ['fi', 'en']) assert.ok(GT[lang][`vc.problem.${c}`]);
  for (const st of ['received', 'redeemed', 'cancelled', 'expired']) for (const lang of ['fi', 'en']) assert.ok(GT[lang][`vc.st.${st}`] && GT[lang][`vc.b.${st}`]);
});

test('mock vastaa sopimuksen vastausmuotoja (avaimet)', async () => {
  const { api } = setup({ scenario: 'claims' });
  const r = await api.resolve('KK12345ABCDEF');
  assert.deepEqual(Object.keys(r).sort(), ['kind', 'ok', 'partner_claims_enabled', 'sources', 'suggested_source', 'suggestion_confidence'].sort());
  assert.deepEqual(Object.keys(r.sources[0]).sort(), ['code', 'label', 'label_en']);
  const s = await api.submitClaim({ token: TOKEN, code: 'NEWCODE12345', source: 'offerilla' });
  assert.deepEqual(Object.keys(s).sort(), ['claim_no', 'code_masked', 'hold_until', 'ok', 'payment_method', 'payment_method_label', 'source', 'source_label', 'source_mismatch', 'status'].sort());
  assert.equal(s.hold_until, null);
  const g = await api.orderClaims(TOKEN);
  assert.deepEqual(Object.keys(g.claims[0]).sort(), ['amount', 'can_update_code', 'claim_no', 'code_masked', 'created_at', 'hold_until', 'problem_code', 'public_status', 'source', 'source_label', 'status'].sort());
  const u = await api.updateClaimCode({ token: TOKEN, claimNo: s.claim_no, code: 'OTHERCODE999', source: 'offerilla' });
  assert.deepEqual(Object.keys(u).sort(), ['claim_no', 'code_masked', 'ok', 'payment_method', 'payment_method_label', 'public_status', 'source', 'source_label', 'source_mismatch', 'status'].sort());
});

test('gift-mock yksinään (ilman tilausta): lunastuspyyntö vaatii tilauksen → not_found', async () => {
  const gm = createGiftMock({});
  assert.equal((await gm.rpc('public_submit_voucher_claim', { p_token: TOKEN, p_code: 'ABCDEFGH', p_source: 'offerilla' })).code, 'not_found');
});
