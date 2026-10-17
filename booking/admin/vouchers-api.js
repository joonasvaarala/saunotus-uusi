// Lunastuspyynnöt (hallinta): DATAKERROS. Sopimus: KOODARI_talous_A_D_fi.md §13.12 / §13.12.1 (migraatiot booking_47/48). Näkymä ei tunne RPC-nimiä eikä p_-parametreja.
// Sama `rpc(nimi, parametrit)` -rajapinta kuin giftcards-api.js:ssä: oikea = sb.js:n rpc, mock = vouchers-mock.js (osoitteessa ?mock=1). Kirjoittava toiminto (resolve) menee oikeassa tilassa aina palvelimelle.
import { createVoucherMock } from './vouchers-mock.js';
import { FeatureNotReady, RpcError, isMissingRpc, wantsMock } from './talous-api.js';

export const VC_RPC = { list: 'admin_list_voucher_claims', get: 'admin_get_voucher_claim', resolve: 'admin_resolve_voucher_claim', summary: 'admin_voucher_claim_summary' };
export const VC_STATUSES = ['active', 'open', 'processing', 'problem', 'redeemed', 'cancelled', 'expired', 'needs_review'];   // p_status: tilat + pseudot active (open+processing+problem) ja needs_review
export const VC_SORTS = ['oldest_open', 'newest'];
export const VC_PROBLEM_CODES = ['invalid_code', 'expired_code', 'already_used', 'other'];
export const VC_RESOLVE_STATUSES = ['redeemed', 'problem', 'cancelled', 'open'];   // admin_resolve_voucher_claim.p_status; lähtötila open/processing/problem
export const VC_ACTIVE = ['open', 'processing', 'problem'];
export const VC_SOURCES = ['elamyslahjat', 'kokemuskauppa', 'kiitoskauppa', 'offerilla', 'partner_other'];
export const VC_NOTE_MAX = 1000;

const num = (v, d = 0) => (v == null || v === '' || !Number.isFinite(+v) ? d : +v);
const L = (x) => (Array.isArray(x) ? x : []);
const compact = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined && v !== null && v !== ''));
const lim = (n) => Math.min(500, Math.max(1, Math.trunc(+n) || 100));   // palvelin: max 500

// Ikä tunteina → "2 pv 3 h" / "5 h" / "alle 1 h". fmtAge(h, {d:'pv'|'d'}) – kielikohtaiset tunnukset annetaan parametrina (ei riippuvuutta tekstitiedostoon)
export function fmtAge(hours, { lt = '< 1 h', day = 'pv', hour = 'h' } = {}) {
  const h = Math.max(0, Math.floor(+hours || 0));
  if (h < 1) return lt;
  const d = Math.floor(h / 24), r = h % 24;
  return d ? (r ? `${d} ${day} ${r} ${hour}` : `${d} ${day}`) : `${r} ${hour}`;
}
// Rivi/kortti: koodi on listassa aina maskattu (code=null); koko koodi vain admin_get_voucher_claim:ssa. hold_until/hours_left ovat aina null (booking_48) → ei välitetä käyttöliittymälle.
export function normClaim(c) {
  if (!c) return null;
  return { id: c.id, order_id: c.order_id ?? null, order_no: c.order_no ?? null, reservation_id: c.reservation_id ?? null, order_item_id: c.order_item_id ?? null,
    source: c.source || 'partner_other', source_label: c.source_label || '', source_suggested: c.source_suggested ?? null, code_masked: c.code_masked || '', code: c.code ?? null,
    status: c.status, problem_code: c.problem_code ?? null, customer_name: c.customer_name || '', customer_email: c.customer_email || '', customer_phone: c.customer_phone || '', locale: c.locale || 'fi',
    voucher_value: c.voucher_value == null ? null : num(c.voucher_value), amount: c.amount == null ? null : num(c.amount), payment_id: c.payment_id ?? null, partner_ref: c.partner_ref ?? null,
    attempts: num(c.attempts), last_checked_at: c.last_checked_at ?? null, problem_notified_at: c.problem_notified_at ?? null, needs_review: !!c.needs_review, notes: c.notes || '',
    resolved_at: c.resolved_at ?? null, resolved_by: c.resolved_by ?? null, created_at: c.created_at, updated_at: c.updated_at ?? c.created_at,
    age_hours: c.age_hours == null ? null : num(c.age_hours), stale: !!c.stale, active: c.active != null ? !!c.active : VC_ACTIVE.includes(c.status), status_since: c.status_since ?? c.updated_at ?? c.created_at };
}
export const normList = (r) => ({ total: num(r.total), sort: r.sort || 'oldest_open', claims: L(r.claims).map(normClaim) });
export const normDetail = (r) => ({ claim: normClaim(r.claim),
  order: r.order ? { order_no: r.order.order_no, status: r.order.status, payment_status: r.order.payment_status, total: num(r.order.total), balance: { total: num(r.order.balance?.total ?? r.order.total), paid: num(r.order.balance?.net_paid ?? r.order.balance?.paid), unpaid: num(r.order.balance?.unpaid) } } : null,
  reservations: L(r.reservations).map((x) => ({ id: x.id, starts_at: x.starts_at, ends_at: x.ends_at, persons: num(x.persons, 1), status: x.status, product_name: x.product_name || '' })),
  payment: r.payment ? { id: r.payment.id, method: r.payment.method, status: r.payment.status, amount: num(r.payment.amount), paid_at: r.payment.paid_at ?? null, note: r.payment.note || '' } : null,
  source_guess: { source: r.source_guess?.source ?? null, confidence: r.source_guess?.confidence ?? null } });
export const normSummary = (r) => ({ remind_after_hours: num(r.remind_after_hours, 24), active: num(r.active), open: num(r.open), problem: num(r.problem), needs_review: num(r.needs_review), stale: num(r.stale),
  oldest: r.oldest ? { id: r.oldest.id, order_no: r.oldest.order_no, status: r.oldest.status, source_label: r.oldest.source_label || '', code_masked: r.oldest.code_masked || '', created_at: r.oldest.created_at, age_hours: num(r.oldest.age_hours) } : null });

export function rpcBackend(rpc) {
  const call = async (key, params = {}) => {
    const res = await rpc(VC_RPC[key], params);
    if (res && res.ok === false) throw new RpcError(res.message || res.code || 'Pyyntö epäonnistui', { code: res.code, status: 400, details: res });
    return res;
  };
  return {
    list: (a = {}) => call('list', compact({ p_status: a.status, p_search: a.search, p_limit: lim(a.limit), p_offset: Math.max(0, Math.trunc(+a.offset) || 0), p_sort: a.sort || 'oldest_open' })),
    get: (a) => call('get', { p_id: a.id }),
    // status: redeemed | problem (+ problemCode) | cancelled | open (uudelleenavaus). amount = kumppanin lahjakortin arvo (valinnainen; tyhjä = koko maksamaton osuus)
    resolve: (a) => call('resolve', compact({ p_id: a.id, p_status: a.status, p_problem_code: a.status === 'problem' ? a.problemCode : undefined, p_note: a.note, p_amount: a.status === 'redeemed' ? a.amount : undefined, p_partner_ref: a.status === 'redeemed' ? a.partnerRef : undefined })),
    summary: () => call('summary'),
  };
}

export function createVoucherApi({ rpc, mock = wantsMock(), mockFactory = () => createVoucherMock({ delay: 80 }) } = {}) {
  const forced = !!mock, real = rpc && !forced ? rpcBackend(rpc) : null;
  let mb = null;
  const backend = () => real || (mb ||= rpcBackend(mockFactory().rpc));
  const run = async (key, args, post = (x) => x) => {
    try { return post(await backend()[key](args)); } catch (e) {
      if (real && isMissingRpc(e)) throw new FeatureNotReady(VC_RPC[key]);
      throw e;
    }
  };
  return {
    get mode() { return real ? 'real' : 'mock'; }, isMock: () => !real,
    list: (a) => run('list', a, normList), get: (a) => run('get', typeof a === 'object' ? a : { id: a }, normDetail),
    resolve: (a) => run('resolve', a, (r) => ({ ...r, claim: normClaim(r.claim) })), summary: () => run('summary', undefined, normSummary),
  };
}
