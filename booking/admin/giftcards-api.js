// Lahjakortit (hallinta): DATAKERROS. Sopimus: KOODARI_talous_A_D_fi.md §13 (migraatiot booking_43/44). Näkymä ei tunne RPC-nimiä eikä p_-parametreja.
// Sama `rpc(nimi, parametrit)` -rajapinta kuin talous-api.js:ssä: oikea = sb.js:n rpc, mock = giftcards-mock.js (osoitteessa ?mock=1).
// Kirjoittavat toiminnot menevät oikeassa tilassa aina palvelimelle (ei mock-varakutsua); puuttuva RPC → FeatureNotReady.
import { createGiftMock } from './giftcards-mock.js';
import { FeatureNotReady, RpcError, isMissingRpc, wantsMock } from './talous-api.js';

export const GC_RPC = {
  packages: 'admin_list_gift_card_packages', list: 'admin_list_gift_cards', get: 'admin_get_gift_card', create: 'admin_create_gift_card',
  setExpiry: 'admin_set_gift_card_expiry', adjust: 'admin_adjust_gift_card', deactivate: 'admin_deactivate_gift_card', reactivate: 'admin_reactivate_gift_card', redeem: 'admin_redeem_gift_card',
};
export const GC_STATUSES = ['active', 'used', 'expired', 'cancelled', 'pending_verification', 'pending_payment'];
export const GC_SORTS = ['created_desc', 'created_asc', 'valid_to_asc', 'valid_to_desc', 'balance_desc', 'balance_asc', 'initial_desc', 'initial_asc'];
export const GC_PAY_METHODS = ['cash', 'card_terminal', 'mobilepay', 'bank_transfer', 'invoice', 'pay_later', 'other'];   // admin_create_gift_card: p_payment_method (muu kuin gift_card)
export const GC_GREETING_MAX = 300;

const num = (v, d = 0) => (v == null || v === '' || !Number.isFinite(+v) ? d : +v);
const L = (x) => (Array.isArray(x) ? x : []);
const compact = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined && v !== null && v !== ''));
const lim = (n) => Math.min(200, Math.max(1, Math.trunc(+n) || 50));   // sopimus: max 200

// Koodin normalisointi (sama kuin booking.gift_code_norm): isot kirjaimet, vain A–Z0–9. Näyttömuoto XXXX-XXXX-XXXX (12 merkkiä).
export const normalizeGiftCode = (s) => String(s ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
export const formatGiftCode = (s) => { const n = normalizeGiftCode(s); return n.length === 12 ? `${n.slice(0, 4)}-${n.slice(4, 8)}-${n.slice(8)}` : n; };

export function normCard(c) {
  if (!c) return null;
  return { ...c, id: c.id, code: c.code || '', initial_amount: num(c.initial_amount), balance: num(c.balance), status: c.status, effective_status: c.effective_status || c.status,
    balance_verified: c.balance_verified !== false, single_order: !!c.single_order, source: c.source || 'native', greeting: c.greeting || '' };
}
export const normList = (r) => ({ total: num(r.total), sum_balance: num(r.sum_balance), sum_initial: num(r.sum_initial), sum_balance_redeemable: num(r.sum_balance_redeemable), rows: L(r.rows).map(normCard) });
export const normDetail = (r) => ({ card: normCard(r.card), ledger: L(r.ledger).map((x) => ({ ...x, delta: num(x.delta), balance_after: num(x.balance_after) })), payments: L(r.payments), expiry_log: L(r.expiry_log),
  purchase_order: r.purchase_order || null, ledger_consistent: r.ledger_consistent !== false });
export const normSettings = (s) => ({ sale_enabled: !!s?.sale_enabled, redeem_enabled: !!s?.redeem_enabled, johku_cards_redeemable: !!s?.johku_cards_redeemable });
export const normPackages = (r) => ({ settings: normSettings(r?.settings), packages: L(r?.packages).map((p) => ({ ...p, price: p.price == null ? null : num(p.price), min_amount: p.min_amount == null ? null : num(p.min_amount), max_amount: p.max_amount == null ? null : num(p.max_amount) })) });

export function rpcBackend(rpc) {
  const call = async (key, params = {}) => {
    const res = await rpc(GC_RPC[key], params);
    if (res && res.ok === false) throw new RpcError(res.message || res.code || 'Pyyntö epäonnistui', { code: res.code, status: 400, details: res });
    return res;
  };
  return {
    packages: () => call('packages'),
    list: (a = {}) => call('list', compact({ p_search: a.search, p_status: a.status, p_source: a.source, p_kind: a.kind, p_package: a.package, p_vat_treatment: a.vatTreatment,
      p_unverified: a.unverified ? true : undefined, p_expiring_days: a.expiringDays ? +a.expiringDays : undefined, p_has_balance: typeof a.hasBalance === 'boolean' ? a.hasBalance : undefined,
      p_sort: a.sort || 'created_desc', p_limit: lim(a.limit), p_offset: Math.max(0, Math.trunc(+a.offset) || 0) })),
    get: (a) => call('get', a.code ? { p_code: normalizeGiftCode(a.code) } : { p_id: a.id }),
    create: (a) => call('create', compact({ p_package: a.package, p_amount: a.amount, p_quantity: a.quantity || 1, p_buyer: a.buyer && Object.keys(compact(a.buyer)).length ? compact(a.buyer) : undefined,
      p_recipient_name: a.recipientName, p_recipient_email: a.recipientEmail, p_greeting: a.greeting, p_payment_method: a.paymentMethod, p_vat_treatment: a.vatTreatment,
      p_valid_months: a.validMonths, p_locale: a.locale || 'fi', p_note: a.note, p_channel: a.channel || 'admin' })),
    setExpiry: (a) => call('setExpiry', compact({ p_id: a.id, p_valid_to: a.validTo, p_note: a.note })),
    adjust: (a) => call('adjust', compact({ p_id: a.id, p_delta: a.delta, p_reason: a.reason, p_mark_verified: a.markVerified ? true : undefined })),
    deactivate: (a) => call('deactivate', { p_id: a.id, p_reason: a.reason }),
    reactivate: (a) => call('reactivate', { p_id: a.id, p_reason: a.reason }),
    redeem: (a) => call('redeem', compact({ p_order_id: a.orderId, p_code: normalizeGiftCode(a.code), p_amount: a.amount, p_note: a.note })),
  };
}

export function createGiftApi({ rpc, mock = wantsMock(), mockFactory = () => createGiftMock({ delay: 80 }) } = {}) {
  const forced = !!mock, real = rpc && !forced ? rpcBackend(rpc) : null;
  let mb = null, cache = null;
  const backend = () => real || (mb ||= rpcBackend(mockFactory().rpc));
  const run = async (key, args, post = (x) => x) => {
    try { return post(await backend()[key](args)); } catch (e) {
      if (real && isMissingRpc(e)) throw new FeatureNotReady(GC_RPC[key]);
      throw e;
    }
  };
  const api = {
    get mode() { return real ? 'real' : 'mock'; }, get reason() { return real ? null : 'param'; }, isMock: () => !real,
    packages: () => run('packages', undefined, normPackages),
    // kytkimet (gift_cards.*) välimuistissa 30 s: lunastus-/myyntinäppäimet tarkistavat ne ilman jokaista kutsua; virhe → null (ei estä toimintaa, palvelin tarkistaa joka tapauksessa)
    async settings({ fresh = false } = {}) {
      if (!fresh && cache && Date.now() - cache.at < 30000) return cache.v;
      let v = null; try { v = (await run('packages', undefined, normPackages)).settings; } catch { v = null; }
      cache = { at: Date.now(), v }; return v;
    },
    list: (a) => run('list', a, normList),
    get: (a) => run('get', typeof a === 'object' ? a : { id: a }, normDetail),
    create: (a) => run('create', a, (r) => ({ ...r, cards: L(r.cards).map(normCard) })),
    setExpiry: (a) => run('setExpiry', a), adjust: (a) => run('adjust', a), deactivate: (a) => run('deactivate', a), reactivate: (a) => run('reactivate', a),
    redeem: (a) => run('redeem', a),
  };
  return api;
}
