// HALL-AVOIMET-01: Avoimet maksut (maksulinkit + hyvitykset). Puhdas laskenta ja haku ilman DOM:ia.
// Määrät tulevat palvelimelta nykyisillä funktioilla (ei migraatiota):
//  - maksulinkit: admin_list_payment_link_watch(p_status, p_limit => 1).total on kaikkien rivien määrä, ei sivun 50 riviä
//  - hyvitykset: admin_list_open_refunds palauttaa kaikki avoimet rivit; toimenpidettä vaativa = needs_action (epäonnistunut tai yli 24 h)
export const PAYLINK_STATUSES = ['needs_action', 'watching', 'paused'];
export const OPEN_PAYMENTS_TAB = 'open-payments';
export const OPEN_PAYMENTS_EVENT = 'admin:open-payments-changed';

const num = (v) => { const n = Number(v); return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0; };

/** Hyvitysrivi vaatii toimenpidettä: epäonnistunut tai yli 24 h odottanut (palvelin merkitsee needs_action). */
export function refundNeedsAction(row) {
  if (!row) return false;
  if (typeof row.needs_action === 'boolean') return row.needs_action;
  return row.status === 'failed' || !!row.aging;
}
export function refundAttentionCount(res) {
  return Array.isArray(res?.rows) ? res.rows.filter(refundNeedsAction).length : 0;
}

/** Maksulinkkisirujen määrät palvelimen kokonaismääristä (ei haetuista riveistä). */
export function paylinkChipCounts(totals) {
  const c = { needs_action: num(totals?.needs_action), watching: num(totals?.watching), paused: num(totals?.paused) };
  return { '': c.needs_action + c.watching + c.paused, ...c };
}

/** Tarkista-merkkiin ja välilehden merkkiin menevä määrä. */
export function openPaymentsAttention(counts) {
  return num(counts?.links) + num(counts?.refunds);
}

export function canSeePaylinks(can) { return typeof can === 'function' && !!can('payments.manage'); }
export function canSeeRefunds(can, role) { return (typeof can === 'function' && !!can('bookings.manage')) || role === 'admin'; }
export function canSeeOpenPayments(can, role) { return canSeePaylinks(can) || canSeeRefunds(can, role); }

/** Sirun määrä palvelimelta: yksi rivi riittää, total kertoo koko määrän. */
export async function paylinkTotal(rpc, status, search = null) {
  const res = await rpc('admin_list_payment_link_watch', { p_search: search || null, p_status: status || null, p_limit: 1, p_offset: 0 });
  return num(res?.total);
}

/** Kaikki sirumäärät rinnakkain. */
export async function paylinkTotals(rpc, search = null) {
  const [needs, watching, paused] = await Promise.all(PAYLINK_STATUSES.map((s) => paylinkTotal(rpc, s, search)));
  return { needs_action: needs, watching, paused };
}

/**
 * Toimenpidettä vaativien määrät. Virhe tai puuttuva oikeus yhdessä osassa ei kaada toista (osa = null → 0).
 * Palauttaa { links, refunds, total }.
 */
export async function loadOpenPaymentCounts(rpc, can, role) {
  const [links, refunds] = await Promise.all([
    canSeePaylinks(can) ? paylinkTotal(rpc, 'needs_action').catch(() => null) : null,
    canSeeRefunds(can, role) ? rpc('admin_list_open_refunds', { p_search: null }).then(refundAttentionCount).catch(() => null) : null,
  ]);
  const out = { links: links ?? 0, refunds: refunds ?? 0 };
  return { ...out, total: openPaymentsAttention(out) };
}

/** Näkymät kutsuvat tätä toimenpiteen jälkeen: yläpalkin merkki ja välilehden luku päivittyvät. */
export function notifyOpenPaymentsChanged(win = globalThis.window) {
  try { win?.dispatchEvent?.(new win.CustomEvent(OPEN_PAYMENTS_EVENT)); } catch { /* ei selainta: ei mitään */ }
}
