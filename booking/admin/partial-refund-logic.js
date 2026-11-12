// Tilausnäkymä v3 PR 3 (booking_282–284): osahyvityksen puhdas logiikka (ei DOM:ia, testattavissa node --test). Palvelin päättää summat ja oikeudet
// (admin_order_refund_info, admin_change_booking_preview); tämä vain muotoilee vastaukset dialogeille ja jakaa koko tilauksen peruutuksen hyvityksen maksuille.
const EPS = 0.004;
const MIN_REFUND = 0.05;
const num = (x) => { const n = Number(x); return Number.isFinite(n) ? n : 0; };
export const round2 = (x) => Math.round((num(x) + Number.EPSILON) * 100) / 100;

/** Onko osahyvitys käytössä (palvelimen lippu partial_refunds_enabled, tieto tulee info- tai esikatselu-RPC:stä). Puuttuva tieto = ei käytössä. */
export function partialEnabled(x) { return !!x && x.partial_refunds_enabled === true; }

/**
 * Ylisuorituksen hyvityksen näkymä (admin_order_refund_info):
 *  show=false + reason: 'disabled' | 'no_permission' | 'invoice_locked' | 'nothing' | 'cancelled' | 'gift_sale'
 */
export function overpaymentView(info) {
  const base = { show: false, reason: null, max: 0, nonRefundable: 0, payments: [] };
  if (!info || info.ok === false) return { ...base, reason: 'missing' };
  if (!partialEnabled(info)) return { ...base, reason: 'disabled' };
  if (info.order_status === 'cancelled') return { ...base, reason: 'cancelled' };
  if (info.gift_card_sale) return { ...base, reason: 'gift_sale' };
  if (info.invoice_locked) return { ...base, reason: 'invoice_locked' };
  if (!info.can_refund) return { ...base, reason: 'no_permission' };
  const max = round2(info.refundable_max);
  const payments = (info.payments || []).filter((p) => p.kind === 'refundable').map((p) => ({ payment_id: p.payment_id, provider: p.provider, method: p.method, cap: round2(p.cap), online: !!p.online }));
  if (max < MIN_REFUND - EPS || !payments.length) return { ...base, reason: 'nothing', nonRefundable: round2(info.non_refundable_amount), overpaid: round2(info.overpaid) };
  return { show: true, reason: null, max, nonRefundable: round2(info.non_refundable_amount), overpaid: round2(info.overpaid), payments };
}

/** Syötetyn summan tarkistus: 0,05 € … max, kaksi desimaalia. Palauttaa { ok, amount, error } (error: 'invalid' | 'too_small' | 'too_big'). */
export function checkAmount(raw, max) {
  const s = String(raw ?? '').trim().replace(',', '.');
  if (!/^\d{1,6}(\.\d{1,2})?$/.test(s)) return { ok: false, amount: null, error: 'invalid' };
  const amount = round2(s);
  if (amount < MIN_REFUND - EPS) return { ok: false, amount, error: 'too_small' };
  if (amount > round2(max) + EPS) return { ok: false, amount, error: 'too_big' };
  return { ok: true, amount, error: null };
}

/**
 * Muutoksen hyvitysvaihe (admin_change_booking_preview):
 *  show=false + reason: 'disabled' | 'no_permission' | 'invoice_locked' | 'none' (ei ylisuoritusta) | 'price_up' | 'missing'
 */
export function changeRefundView(prev) {
  const base = { show: false, reason: null, max: 0, diff: 0, oldTotal: 0, newTotal: 0, plan: [], nonRefundable: 0 };
  if (!prev || prev.ok === false) return { ...base, reason: 'missing' };
  const o = { ...base, diff: round2(prev.diff), oldTotal: round2(prev.old_total), newTotal: round2(prev.new_total), nonRefundable: round2(prev.non_refundable_amount) };
  if (o.diff > EPS) return { ...o, reason: 'price_up' };
  if (prev.invoice_locked) return { ...o, reason: 'invoice_locked' };
  if (!partialEnabled(prev)) return { ...o, reason: o.diff < -EPS ? 'disabled' : 'none' };
  if (!prev.can_refund) return { ...o, reason: o.diff < -EPS ? 'no_permission' : 'none' };
  const max = round2(prev.refundable_max);
  if (max < MIN_REFUND - EPS) return { ...o, reason: 'none', overpaid: round2(prev.overpaid_after) };
  return { ...o, show: true, max, overpaid: round2(prev.overpaid_after), plan: prev.refund_plan || [] };
}

/** admin_change_booking -argumentit hyvitysvalinnasta. choice: { refund: 'diff'|'partial'|'none', amount, notify: 'yes'|'no'|null, reason }. */
export function changeArgs(choice, view) {
  if (!choice || !view?.show || choice.refund === 'none') return { p_notify: choice?.notify === 'yes' };
  const amount = choice.refund === 'diff' ? view.max : round2(choice.amount);
  return { p_refund_amount: amount, p_refund_reason: choice.reason || null, p_notify: choice.notify === 'yes' };
}

/**
 * Koko tilauksen peruutus (admin_cancel_order): jakaa hyvityksen maksuille, yksi rivi / maksu, verkkomaksut ensin.
 * info.payments: [{payment_id, provider, kind, cap, online}], vain kind 'refundable' käy. mode: 'full' (kaikki) | 'partial' (amount) | 'none'.
 */
export function allocateCancelRefund(info, mode, amount = 0) {
  if (mode === 'none') return [];
  const pays = (info?.payments || []).filter((p) => p.kind === 'refundable' && num(p.cap) > EPS)
    .sort((a, b) => (b.online ? 1 : 0) - (a.online ? 1 : 0) || num(a.payment_id) - num(b.payment_id));
  let left = mode === 'full' ? pays.reduce((s, p) => s + round2(p.cap), 0) : round2(amount);
  const out = [];
  for (const p of pays) {
    if (left < EPS) break;
    const take = round2(Math.min(left, round2(p.cap)));
    if (take < EPS) continue;
    if (p.online && take < MIN_REFUND - EPS) continue;   // Montonion minimi 0,05 €
    out.push({ payment_id: p.payment_id, amount: take });
    left = round2(left - take);
  }
  return out;
}

/** Koko tilauksen peruutuksen hyvitysnäkymä (info: admin_order_refund_info). */
export function cancelAllRefundView(info, { used = false } = {}) {
  const base = { show: false, reason: null, max: 0, payments: [] };
  if (!info || info.ok === false) return { ...base, reason: 'missing' };
  if (!partialEnabled(info)) return { ...base, reason: 'disabled' };
  if (info.invoice_locked) return { ...base, reason: 'invoice_locked' };
  if (!info.can_refund) return { ...base, reason: 'no_permission' };
  if (info.gift_card_sale) return { ...base, reason: 'gift_sale' };
  if (used) return { ...base, reason: 'partly_used' };
  const payments = (info.payments || []).filter((p) => p.kind === 'refundable' && num(p.cap) > EPS);
  const max = round2(payments.reduce((s, p) => s + num(p.cap), 0));
  if (max < MIN_REFUND - EPS) return { ...base, reason: 'nothing' };
  return { show: true, reason: null, max, payments };
}

/** Synteettinen "options"-olio cancelFlowExtras:lle koko tilauksen atomisessa peruutuksessa (lahjakortti-, kumppani- ja viestikysymykset). */
export function syntheticCancelOptions(info, { firstReservationId, hasEmail = false, moneyShare = null } = {}) {
  const gcs = (info?.gift_cards || []).map((g) => ({ amount: num(g.amount), code_last4: g.code_last4, valid_to: g.valid_to, keep_allowed: g.keep_allowed }));
  const partner = round2((info?.payments || []).filter((p) => p.kind === 'partner_voucher').reduce((s, p) => s + num(p.cap), 0));
  return {
    ok: true, reservation_id: firstReservationId, gift_card_choice_required: gcs.length > 0, gift_cards: gcs,
    gift_card_total: round2(gcs.reduce((s, g) => s + g.amount, 0)), partner_share: partner, voucher_redeemed: !!info?.voucher_redeemed, order_stays: !!info?.voucher_redeemed,
    money_share: moneyShare, customer_email: !!hasEmail,
  };
}

/** admin_cancel_order -argumentit. */
export function cancelOrderArgs({ orderId, reason = null, refund = [], notify = null, giftKeep = null }) {
  return { p_order_id: orderId, p_reason: reason || 'henkilökunta', p_refund: refund.length ? refund : null, p_notify: notify, p_gift_card_keep: giftKeep };
}

/** Virhekoodi → tekstiavain (ui.admin.order_flow.errors.*), muuten null. */
export const ERROR_KEYS = ['partial_refunds_disabled', 'nothing_to_refund', 'amount_exceeds_refundable', 'order_invoiced', 'forbidden', 'invalid_amount'];
export function errorKey(e) {
  const code = e?.details?.code || e?.code || e?.detail || e?.hint || null;
  const fromMsg = ERROR_KEYS.find((k) => String(e?.message || '').includes(k));
  const c = ERROR_KEYS.includes(code) ? code : fromMsg;
  return c ? `errors.${c}` : null;
}
