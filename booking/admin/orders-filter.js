// Talous-tilauslistan maksusuodatin. Sama sääntö on SQL:ssä (admin_list_orders, p_payment_filter, booking_76).
// Maksutilat (orders.payment_status): unpaid, pending, paid, partially_paid, refunded, partially_refunded, failed.
// Tilauksen tila: draft, pending, confirmed, cancelled, expired, completed.
//
// 'paid' (oletus): payment_status paid tai partially_refunded, nettomaksu > 0, tila ei cancelled eikä expired.
// Nettomaksu = maksurivien (paid/partially_refunded/refunded) summa − refunded_amount.
// Jos maksurivejä ei ole (Johku: maksu on vain tilassa ja external_metassa), nettomaksu on total_gross.
// partially_paid ei ole oletuksessa: rahaa on tullut, mutta tilaus ei ole kokonaan maksettu.
// Haku: kun valinta on oletus 'paid' ja hakukentässä on tekstiä, kutsu käyttää 'all' (maksamaton löytyy numerolla).

export const PAYMENT_FILTERS = ['paid', 'unpaid', 'all', 'refunded', 'cancelled'];
export const DEFAULT_PAYMENT_FILTER = 'paid';

const SETTLED = new Set(['paid', 'partially_refunded', 'refunded']);
const UNPAID_STATUS = new Set(['unpaid', 'pending', 'failed', 'partially_paid']);

export function normalizePaymentFilter(value) {
  const v = String(value ?? '').trim();
  return v || DEFAULT_PAYMENT_FILTER;
}

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

/** Kuinka monta oikeaa maksuriviä (paid / partially_refunded / refunded) tilauksella on. */
export function settledPaymentCount(order) {
  if (order.payment_count != null && !Array.isArray(order.payments)) return num(order.payment_count);
  if (Array.isArray(order.payments)) return order.payments.filter((p) => SETTLED.has(p.status)).length;
  if (order.payment_count != null) return num(order.payment_count);
  return 0;
}

/** Nettomaksu euroina. Johku ilman maksurivejä: tilaussumma, jos maksutila on paid tai partially_refunded. */
export function netSettled(order) {
  const paid = num(order.paid ?? order.paid_amount);
  const refunded = num(order.refunded ?? order.refunded_amount);
  const gross = num(order.total ?? order.total_gross);
  const ps = order.payment_status;
  if (settledPaymentCount(order) > 0) return paid - refunded;
  if (ps === 'paid' || ps === 'partially_refunded') return gross;
  return paid - refunded;
}

/** Mockilla ei ole orders.status-kenttää: sama johto kuin talous-mock.js orderStatus. */
export function orderStatusOf(order) {
  if (order.status) return order.status;
  if (order.payment_status === 'refunded') return 'cancelled';
  if (order.payment_status === 'pending' || order.payment_status === 'failed') return 'pending';
  return 'confirmed';
}

export function matchesPaymentFilter(order, filter) {
  const f = normalizePaymentFilter(filter);
  if (!PAYMENT_FILTERS.includes(f)) return false;
  if (f === 'all') return true;
  const ps = order.payment_status;
  const closed = orderStatusOf(order) === 'cancelled' || orderStatusOf(order) === 'expired';
  if (f === 'paid') return (ps === 'paid' || ps === 'partially_refunded') && !closed && netSettled(order) > 0.004;
  if (f === 'unpaid') return UNPAID_STATUS.has(ps) && !closed;
  if (f === 'refunded') return ps === 'refunded' || ps === 'partially_refunded';
  if (f === 'cancelled') return closed;
  return false;
}

/** Haku ohittaa oletuksen 'paid'. Muu valinta (myös Kaikki) pysyy haussa. */
export function effectivePaymentFilter({ search, paymentFilter } = {}) {
  const selected = normalizePaymentFilter(paymentFilter);
  if (String(search || '').trim() && selected === DEFAULT_PAYMENT_FILTER) return 'all';
  return selected;
}
