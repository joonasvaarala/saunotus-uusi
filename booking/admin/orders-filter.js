// Talous-tilauslistan maksusuodatin. Sama sääntö on SQL:ssä (admin_list_orders, p_payment_filter, booking_76).
// Maksutilat (orders.payment_status): unpaid, pending, paid, partially_paid, refunded, partially_refunded, failed, invoiced.
// Tilauksen tila: draft, pending, confirmed, cancelled, expired, completed.
//
// 'paid' (oletus): payment_status paid tai partially_refunded, nettomaksu > 0, tila ei cancelled eikä expired.
// Nettomaksu = maksurivien (paid/partially_refunded/refunded) summa − refunded_amount.
// Jos maksurivejä ei ole (Johku: maksu on vain tilassa ja external_metassa), nettomaksu on total_gross.
// partially_paid ei ole oletuksessa: rahaa on tullut, mutta tilaus ei ole kokonaan maksettu.
// Haku: kun valinta on oletus 'paid' ja hakukentässä on tekstiä, kutsu käyttää 'all' (maksamaton löytyy numerolla).

// booking_279: 'archived' = poistetut maksamattomat. Muut suodattimet piilottavat poistetun, ellei sille ole kirjattu maksua (myöhäinen maksu näkyy)
// tai haku ole tarkka tilausnumero.
export const PAYMENT_FILTERS = ['paid', 'unpaid', 'invoiced', 'all', 'refunded', 'cancelled', 'archived'];
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

export function matchesPaymentFilter(order, filter, { exactNumber = false } = {}) {
  const f = normalizePaymentFilter(filter);
  if (!PAYMENT_FILTERS.includes(f)) return false;
  const archived = !!order.archived_at;
  if (f === 'archived') return archived;
  if (archived && !exactNumber && !(settledPaymentCount(order) > 0)) return false;
  if (f === 'all') return true;
  const ps = order.payment_status;
  const closed = orderStatusOf(order) === 'cancelled' || orderStatusOf(order) === 'expired';
  if (f === 'paid') return (ps === 'paid' || ps === 'partially_refunded') && !closed && netSettled(order) > 0.004;
  if (f === 'unpaid') return UNPAID_STATUS.has(ps) && !closed;
  if (f === 'invoiced') return ps === 'invoiced' && !closed;
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

// ---- Monivalinta (maksutilanapit, booking_277 p_payment_filters) ----
// Valitut tilat yhdistetään OR-ehdolla. Kaikki ('all') on oma nappinsa ja kumoaa muut.
// Tyhjä valinta tarkoittaa kaikkia tilauksia (näkymä sytyttää silloin Kaikki-napin).
// Hallinnan Tilaukset-välilehden oletus (Joonas 11.11.2026): Maksetut ja Maksamattomat.
export const DEFAULT_PAYMENT_FILTERS = Object.freeze(['paid', 'unpaid']);

/** Siistii valinnan: vain tunnetut tilat, ei tuplia, valikon järjestys. 'all' tai tyhjä → ['all']. */
export function normalizePaymentFilters(list) {
  const want = new Set([].concat(list ?? []).map((v) => String(v ?? '').trim()).filter(Boolean));
  if (want.has('all')) return ['all'];
  const out = PAYMENT_FILTERS.filter((f) => f !== 'all' && want.has(f));
  return out.length ? out : ['all'];
}

export const isDefaultPaymentFilters = (list) => normalizePaymentFilters(list).join(',') === DEFAULT_PAYMENT_FILTERS.join(',');

/** Listarivin haalea punainen tausta: sama sääntö kuin Maksamattomat-napissa (unpaid/pending/failed/partially_paid, ei peruttu). */
export const isUnpaidRow = (order) => matchesPaymentFilter(order, 'unpaid');

/** Napin painallus: Kaikki valitsee vain itsensä; muu tila vaihtaa päälle/pois ja poistaa Kaikki-valinnan. */
export function togglePaymentFilter(list, code) {
  const cur = normalizePaymentFilters(list);
  if (code === 'all') return ['all'];
  if (!PAYMENT_FILTERS.includes(code)) return cur;
  const set = new Set(cur.filter((f) => f !== 'all'));
  if (set.has(code)) set.delete(code); else set.add(code);
  return normalizePaymentFilters([...set]);
}

export function matchesPaymentFilters(order, list, opts = {}) {
  return normalizePaymentFilters(list).some((f) => matchesPaymentFilter(order, f, opts));
}

/** Haku ohittaa vain oletuksen (Maksetut + Maksamattomat): haku käy kaikista. Muu valinta pysyy haussa. */
export function effectivePaymentFilters({ search, paymentFilters } = {}) {
  if (String(search || '').trim() && isDefaultPaymentFilters(paymentFilters ?? DEFAULT_PAYMENT_FILTERS)) return ['all'];
  return normalizePaymentFilters(paymentFilters ?? DEFAULT_PAYMENT_FILTERS);
}
