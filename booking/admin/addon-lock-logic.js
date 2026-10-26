// Puhdas hallinnan laskenta admin_get_order-vastauksesta, ilman verkko- tai DOM-riippuvuutta.
// reservations[].addons[] ja items[] ovat molemmat järjestetty order_items.id:n mukaan.
const isPaid = (p) => ['paid', 'partially_refunded', 'refunded'].includes(p?.status);
const isOpenLink = (p) => p?.status === 'pending' && p.provider != null && p.provider !== 'manual';

/**
 * @returns {{ locks: Map<number, {quantity: number, paid: number, linked: number}>,
 *             complete: boolean, reason: string }}
 * complete=false -> UI ei saa sallia turvattomia vähennyksiä.
 */
export function reservationAddonLocks(order, reservationId) {
  const reservation = (order?.reservations || []).find((r) => String(r.id) === String(reservationId));
  if (!reservation) return { locks: new Map(), complete: false, reason: 'reservation_missing' };
  const rows = (order?.items || []).filter((i) => i.kind === 'addon' && String(i.parent_item_id) === String(reservation.item_id));
  const addons = reservation.addons || [];
  // Molemmat listat tulevat samasta admin_get_order-kutsusta ja ovat id-järjestyksessä;
  // virheellisen tai keskeneräisen vastauksen tapauksessa älä arvioi alakanttiin.
  if (rows.length !== addons.length || !Array.isArray(order.payments)) {
    return { locks: new Map(), complete: false, reason: 'items_mismatch' };
  }
  // Sama sääntö kuin booking.admin_set_reservation_addons (booking_180): maksettu rivi on lukittu, jos sillä on nettokatetta
  // (amount_gross - refunded_gross > 0); kokonaan hyvitetty rivi ei lukitse. Puuttuva tai virheellinen summa -> lukitaan (ei arvioida alakanttiin).
  const paymentsByItem = new Map();
  for (const p of order.payments) {
    if (!isPaid(p) && !isOpenLink(p)) continue;
    for (const line of p.lines || []) {
      if (line.order_item_id == null) continue;
      const key = String(line.order_item_id);
      const state = paymentsByItem.get(key) || { net: 0, unknown: false, linked: false };
      if (isPaid(p)) {
        const gross = Number(line.amount_gross), refunded = Number(line.refunded_gross ?? 0);
        if (!Number.isFinite(gross) || !Number.isFinite(refunded)) state.unknown = true;
        else state.net += gross - refunded;
      }
      if (isOpenLink(p)) state.linked = true;
      paymentsByItem.set(key, state);
    }
  }
  for (const state of paymentsByItem.values()) state.paid = state.unknown || state.net > 0.004;
  const locks = new Map();
  for (let i = 0; i < rows.length; i++) {
    const line = rows[i], addon = addons[i];
    const id = Number(addon.addon_id);
    const qty = Number(line.quantity);
    if (!Number.isSafeInteger(id) || !Number.isSafeInteger(qty) || qty < 0 || Number(addon.quantity) !== qty) {
      return { locks: new Map(), complete: false, reason: 'items_mismatch' };
    }
    const p = paymentsByItem.get(String(line.id));
    if (!p?.paid && !p?.linked) continue;
    const acc = locks.get(id) || { quantity: 0, paid: 0, linked: 0 };
    acc.quantity += qty;
    if (p.paid) acc.paid += qty;
    if (p.linked) acc.linked += qty;
    locks.set(id, acc);
  }
  return { locks, complete: true, reason: '' };
}

export function addonMinimum(lockState, addonId) {
  return lockState?.locks?.get(Number(addonId))?.quantity || 0;
}

/** Lähetetty veloituslasku: tilaus on lukittu lisäyksiltä. Henkilökunnan siirto ja peruutus ilman hyvitystä jäävät auki. */
export function orderInvoiceLocked(order) {
  return order?.invoice_locked === true;
}

/** Henkilökunnan muutosdialogi: stepper ja siirto jäävät päälle, uusi hinta piilotetaan. */
export function staffInvoiceChange(order) {
  const locked = orderInvoiceLocked(order);
  return { locked, personsEnabled: true, moveEnabled: true, showNewPrice: !locked };
}

/** Peruutusdialogi: laskutetulla tilauksella ei kysytä rivihyvitystä. */
export function staffInvoiceCancel(order) {
  return { allowRefundChoice: !orderInvoiceLocked(order) };
}

/** Asiakkaan vahvistus- ja muutosnäkymä. */
export function customerInvoiceLock(booking) {
  const locked = orderInvoiceLocked(booking);
  return { locked, showPendingCancel: !locked, personsDisabled: locked, showPriceEstimate: !locked };
}

const openLinkPayment = (payment) => payment?.status === 'pending' && payment?.link_token
  && payment?.provider != null && payment.provider !== 'manual';

/** 'unpayable' kun lasku on lähetetty, 'stale' kun linkin summa ei täsmää, muuten tyhjä. */
export function linkStaleKind(payment, order) {
  if (orderInvoiceLocked(order) && (openLinkPayment(payment) || payment?.link_stale === true)) return 'unpayable';
  if (payment?.link_stale === true) return 'stale';
  return '';
}

export function invoiceLockReason(order, text = (key, vars) => key) {
  if (!orderInvoiceLocked(order)) return '';
  return text('invoiced', { no: order.invoice_no || '–' });
}

export function linkStaleNote(payment, order, text = (key) => key) {
  const kind = linkStaleKind(payment, order);
  if (kind === 'unpayable') return text('link_unpayable_invoiced');
  if (kind === 'stale') return text('link_stale');
  return '';
}

export function addonReductionError(lockState, proposed) {
  if (!lockState?.complete) return 'addon_lock_unknown';
  const wanted = new Map();
  for (const a of proposed || []) wanted.set(Number(a.id ?? a.addon_id), (wanted.get(Number(a.id ?? a.addon_id)) || 0) + Number(a.quantity || 0));
  for (const [id, lock] of lockState.locks) {
    if ((wanted.get(id) || 0) < lock.quantity) return lock.linked ? 'addon_link_open' : 'addon_paid';
  }
  return null;
}
