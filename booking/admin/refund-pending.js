// Keskeneräiset hyvitykset (booking.refunds.status 'requested' | 'processing'): raha on jo pyydetty takaisin, mutta
// payments.refunded_amount kasvaa vasta, kun hyvitys on valmis (done). Hyvitettävissä = maksettu − hyvitetty − keskeneräiset,
// sama sääntö kuin admin_refund (v_cap) ja admin_get_order.refundable_by_payment (#15149, 12.11.2026). Ei DOM- eikä verkkoriippuvuuksia.
export const PENDING_REFUND_STATUSES = ['requested', 'processing'];
const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
const round2 = (v) => Math.round((num(v) + Number.EPSILON) * 100) / 100;

export const isPendingRefund = (f) => PENDING_REFUND_STATUSES.includes(f?.status);

/** Keskeneräisten hyvitysten summa listasta (admin_get_order.refunds tai payments[].refunds). */
export function pendingRefundTotal(refunds) {
  return round2((refunds || []).filter(isPendingRefund).reduce((s, f) => s + num(f.amount), 0));
}

/**
 * Maksun hyvitettävissä oleva summa. p.refundable (palvelimen refundable_by_payment) voittaa; muuten
 * amount − refunded_amount − maksun keskeneräiset hyvitykset (p.refunds). Ei koskaan negatiivinen.
 */
export function paymentRefundLeft(p) {
  if (!p) return 0;
  if (p.refundable != null) return Math.max(0, round2(p.refundable));
  return Math.max(0, round2(num(p.amount) - num(p.refunded_amount) - pendingRefundTotal(p.refunds)));
}
