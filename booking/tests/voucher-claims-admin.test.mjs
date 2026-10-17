// Hallinta: lunastuspyynnöt (§13.12) – datakerros + mock (RPC-nimet, parametrit, vastausmuodot, tilasiirtymät, tekstit). node --test booking/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { createVoucherApi, rpcBackend, VC_RPC, fmtAge, normClaim, VC_PROBLEM_CODES } from '../admin/vouchers-api.js';
import { createVoucherMock, guess } from '../admin/vouchers-mock.js';
import { createGiftApi, giftCodeValid } from '../admin/giftcards-api.js';
import { createGiftMock } from '../admin/giftcards-mock.js';
import { VC_FI, VC_EN } from '../admin/vouchers-texts.js';
import { TEXTS } from '../admin/talous-texts.js';

const NOW = new Date('2026-10-17T12:00:00Z');
const mk = () => { const m = createVoucherMock({ now: NOW }); const calls = []; const rpc = async (n, a) => { calls.push([n, a]); return m.rpc(n, a); }; return { m, calls, api: createVoucherApi({ rpc, mock: false }) }; };

test('RPC-nimet ja parametrit sopimuksen mukaan', async () => {
  assert.deepEqual(VC_RPC, { list: 'admin_list_voucher_claims', get: 'admin_get_voucher_claim', resolve: 'admin_resolve_voucher_claim', summary: 'admin_voucher_claim_summary' });
  const { api, calls } = mk();
  await api.list({ status: 'active', search: 'aino', limit: 9999, offset: -4 });
  assert.deepEqual(calls[0], ['admin_list_voucher_claims', { p_status: 'active', p_search: 'aino', p_limit: 500, p_offset: 0, p_sort: 'oldest_open' }]);
  await api.get({ id: 41 }); assert.deepEqual(calls[1], ['admin_get_voucher_claim', { p_id: 41 }]);
  await api.resolve({ id: 41, status: 'problem', problemCode: 'other', note: 'x', amount: 5 });
  assert.deepEqual(calls[2], ['admin_resolve_voucher_claim', { p_id: 41, p_status: 'problem', p_problem_code: 'other', p_note: 'x' }], 'amount/ref vain lunastuksessa');
  await api.resolve({ id: 42, status: 'redeemed', amount: 12.5, partnerRef: 'R1' });
  assert.deepEqual(calls[3][1], { p_id: 42, p_status: 'redeemed', p_amount: 12.5, p_partner_ref: 'R1' });
});

test('lista: vain maskattu koodi, ei aikarajoja, vanhin avoin ensin, tilasuodattimet', async () => {
  const { api } = mk();
  const r = await api.list({ status: 'active' });
  assert.equal(r.total, 5); assert.equal(r.claims[0].id, 42, 'vanhin aktiivinen ensin');
  for (const c of r.claims) { assert.equal(c.code, null); assert.match(c.code_masked, /^…[A-Z0-9]{4}$/); assert.ok(c.active); }
  assert.ok(!JSON.stringify(r).match(/hold_until|hours_left/));
  assert.equal((await api.list({ status: 'redeemed' })).total, 2);
  assert.equal((await api.list({ status: 'needs_review' })).total, 2);
  assert.equal((await api.list({})).total, 8, 'ei p_status = kaikki');
  assert.equal((await api.list({ search: 'kaisa' })).total, 1);
  assert.equal((await api.list({ search: 'ABCDEF' })).total, 1, 'koodin osa (≥4 merkkiä)');
  assert.equal((await api.list({ search: 'ABC' })).total, 0, 'alle 4 merkkiä ei hae koodista');
  await assert.rejects(() => rpcBackend(createVoucherMock({ now: NOW }).rpc).list({ status: 'x' }), /status|Tuntematon/i);
});

test('tiedot: koko koodi vain admin_get_voucher_claim:ssa; arvaus muodosta', async () => {
  const { api } = mk();
  const d = await api.get({ id: 42 });
  assert.equal(d.claim.code, 'KK12345ABCDEF'); assert.equal(d.source_guess.source, 'kokemuskauppa');
  assert.equal(d.order.balance.unpaid, 62); assert.equal(d.reservations.length, 1); assert.equal(d.payment, null);
  const p = await api.get({ id: 46 }); assert.equal(p.payment.method, 'partner_voucher'); assert.match(p.payment.note, /…[A-Z0-9]{4}/); assert.ok(!p.payment.note.includes('OK19456DEF'), 'maksumuistiinpanossa vain maskattu');
  assert.deepEqual(guess('KK12345ABCDEF'), { source: 'kokemuskauppa', confidence: 'high' });
  assert.deepEqual(guess('OK19123ABC'), { source: 'offerilla', confidence: 'high' });
  assert.deepEqual(guess('ZXQW98765432'), { source: 'elamyslahjat', confidence: 'medium' });
  assert.deepEqual(guess('KIITOS2026ABC'), { source: null, confidence: null });
  await assert.rejects(() => api.get({ id: 999 }), (e) => e.code === 'not_found');
});

test('ratkaisu: lunastettu kirjaa maksun, ongelma/peruttu/avaus, päätetyn tilan suojaus, validoinnit', async () => {
  const { api } = mk();
  const r = await api.resolve({ id: 41, status: 'redeemed', amount: 40 });
  assert.equal(r.claim.status, 'redeemed'); assert.equal(r.amount, 40); assert.ok(r.payment_id); assert.equal(r.balance.unpaid, 22);
  await assert.rejects(() => api.resolve({ id: 41, status: 'cancelled' }), (e) => e.code === 'invalid_state', 'päätettyä ei muuteta');
  assert.equal((await api.resolve({ id: 42, status: 'redeemed' })).amount, 62, 'tyhjä summa = koko maksamaton');
  assert.equal((await api.resolve({ id: 43, status: 'problem', problemCode: 'already_used' })).claim.problem_code, 'already_used');
  await assert.rejects(() => api.resolve({ id: 45, status: 'problem' }), (e) => e.code === 'invalid_problem_code');
  assert.equal((await api.resolve({ id: 44, status: 'open' })).claim.status, 'open', 'ongelma → uudelleen jonoon');
  assert.equal((await api.resolve({ id: 44, status: 'cancelled' })).claim.status, 'cancelled');
  await assert.rejects(() => api.resolve({ id: 45, status: 'bogus' }), (e) => e.code === 'invalid_status');
  await assert.rejects(() => api.resolve({ id: 45, status: 'cancelled', note: 'x'.repeat(1001) }), (e) => e.code === 'invalid_note');
  await assert.rejects(() => api.resolve({ id: 45, status: 'redeemed', amount: -1 }), (e) => e.code === 'invalid_amount');
  assert.deepEqual(VC_PROBLEM_CODES, ['invalid_code', 'expired_code', 'already_used', 'other']);
});

test('yhteenveto: aktiiviset, ongelmat, vanhat (≥ remind_after_hours), vanhin', async () => {
  const s = await mk().api.summary();
  assert.equal(s.active, 5); assert.equal(s.problem, 2); assert.equal(s.stale, 3); assert.equal(s.remind_after_hours, 24); assert.equal(s.oldest.id, 42);
});

test('puuttuva RPC → FeatureNotReady (rauhallinen ilmoitus), mock-tila toimii ilman rpc:tä', async () => {
  const missing = async () => { throw Object.assign(new Error('Could not find the function booking.admin_list_voucher_claims'), { status: 404, code: 'PGRST202' }); };
  await assert.rejects(() => createVoucherApi({ rpc: missing, mock: false }).list({}), (e) => e.name === 'FeatureNotReady' && /admin_list_voucher_claims/.test(e.rpc));
  const mock = createVoucherApi({ rpc: null, mock: true }); assert.equal(mock.mode, 'mock'); assert.equal((await mock.list({})).total, 8);
});

test('fmtAge ja normClaim', () => {
  const o = { lt: '<1', day: 'pv', hour: 'h' };
  assert.equal(fmtAge(0.4, o), '<1'); assert.equal(fmtAge(5, o), '5 h'); assert.equal(fmtAge(24, o), '1 pv'); assert.equal(fmtAge(75, o), '3 pv 3 h');
  assert.equal(normClaim({ id: 1, status: 'redeemed', created_at: 'x' }).active, false); assert.equal(normClaim({ id: 1, status: 'problem', created_at: 'x' }).active, true);
});

test('yksi koodikenttä hallinnassa: public_resolve_gift_code luokittelee (own / unknown + ehdotus)', async () => {
  const gm = createGiftMock({ delay: 0 }); const api = createGiftApi({ rpc: (n, a) => gm.rpc(n, a), io: {} });
  const own = gm.state.cards.find((c) => c.status === 'active');
  assert.equal((await api.resolve({ code: own.code.toLowerCase() })).kind, 'own');
  const u = await api.resolve({ code: 'zxqw-9876-5432' });
  assert.deepEqual([u.kind, u.suggested_source, u.partner_claims_enabled], ['unknown', 'elamyslahjat', true]);
  await assert.rejects(() => api.resolve({ code: 'ab1' }), (e) => e.code === 'invalid_code');
  assert.ok(giftCodeValid('abc-123') && !giftCodeValid('abc12') && !giftCodeValid('A'.repeat(25)));
});

test('tekstit: FI/EN-pariteetti, ei emojeita, ei aikarajoja, kaikki avaimet käytettävissä TEXTS:ssä', () => {
  assert.deepEqual(Object.keys(VC_FI).sort(), Object.keys(VC_EN).sort());
  for (const [lang, o] of [['fi', VC_FI], ['en', VC_EN]]) for (const [k, v] of Object.entries(o)) {
    assert.ok(v && String(v).trim(), `${lang}.${k} tyhjä`);
    assert.ok(!/\p{Extended_Pictographic}/u.test(v), `${lang}.${k}: emoji`);
    assert.ok(!/\bhold|\bvaraus pidet|hours left|tuntia jäljellä/i.test(v), `${lang}.${k}: aikaraja`);
    assert.ok(k in TEXTS[lang], `${lang}.${k} puuttuu TEXTS:stä`);
  }
  assert.deepEqual(Object.keys(TEXTS.fi).sort(), Object.keys(TEXTS.en).sort(), 'koko TEXTS FI/EN-pariteetti');
  for (const c of VC_PROBLEM_CODES) assert.ok(VC_FI[`vcl.pc.${c}`] && VC_EN[`vcl.pc.${c}`]);
});
