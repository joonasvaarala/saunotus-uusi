// Varausdialogi 04: toiminto-oikeudet ja näkyvyys ilman DOM-riippuvuuksia.
import { canAddPurchase } from './order-reservation-logic.js';
import { reservationAddonLocks } from './addon-lock-logic.js';

const inSet = (value, ...values) => values.includes(value);
const helDay = (value) => {
  const d = value instanceof Date ? value : new Date(value);
  return Number.isNaN(d.getTime()) ? null : d.toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki', year: 'numeric', month: '2-digit', day: '2-digit' });
};

/** Varauspäivä on Helsingissä alkanut; myös myöhemmät päivät kelpaavat. */
export function arrivalActionsAllowed(r, now = new Date()) {
  const start = helDay(r?.starts_at), today = helDay(now);
  return r?.status === 'confirmed' && !!start && !!today && today >= start;
}

/** Resurssisiirto vain vapaan kohdetilan sääntöjen mukaan. */
export function moveTarget(r, can = () => true) {
  if (!can('bookings.manage') || r?.status !== 'confirmed') return null;
  if (r.space_code === 'rauni') return Number(r.persons) > 1 ? null : 'lovi';
  if (r.space_code === 'lovi') return 'rauni';
  return null;
}

/** Korjauspolku sallitaan, jos lisäpalveluja on ja vähintään yhtä voi muuttaa. */
export function addonsEditable(rawOrder, reservationId) {
  const res = (rawOrder?.reservations || []).find((x) => String(x.id) === String(reservationId));
  const rows = Array.isArray(res?.addons) ? res.addons : [];
  if (!rows.length) return false;
  const state = reservationAddonLocks(rawOrder, reservationId);
  if (!state.complete) return true; // palvelin tekee lopullisen oikeus- ja lukitustarkistuksen
  const quantity = rows.reduce((sum, a) => sum + Math.max(0, Number(a.quantity) || 0), 0);
  const locked = [...state.locks.values()].reduce((sum, a) => sum + Math.max(0, Number(a.quantity) || 0), 0);
  return quantity > locked;
}

export function telHref(phone) {
  if (typeof phone !== 'string') return null;
  const cleaned = phone.trim().replace(/[^\d+]/g, '');
  if (!/^\+?\d{3,20}$/.test(cleaned)) return null;
  return `tel:${cleaned}`;
}

export function mailHref(email) {
  if (typeof email !== 'string') return null;
  const cleaned = email.trim();
  if (!/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(cleaned)) return null;
  return `mailto:${cleaned}`;
}

/**
 * Käyttöliittymän ainoa näkyvyyslähde. Ei palauteta disabled-toimintoja.
 * order = normOrder(admin_get_order(rawOrder)); rawOrder tarvitaan addon-lukkoihin.
 */
export function reservationActions(r, { can = () => true, order = null, rawOrder = null, flowEnabled = false, now = new Date() } = {}) {
  const booking = !!can('bookings.manage'), payments = !!can('payments.manage');
  const status = r?.status;
  const changing = booking && inSet(status, 'pending', 'confirmed');
  const confirmed = booking && status === 'confirmed';
  const arriving = confirmed && arrivalActionsAllowed(r, now);
  const reConfirm = booking && inSet(status, 'cancelled', 'expired');
  const unpaid = Number(order?.balance?.unpaid || 0);
  const orderReady = !!order;
  const native = !!order?.is_native;
  const link = payments && orderReady && native && unpaid > 0;
  const addPurchase = flowEnabled && inSet(status, 'pending', 'confirmed', 'completed') &&
    canAddPurchase(order, { can }).allowed;
  const primary = [];
  if (booking && status === 'pending') primary.push('confirm');
  if (addPurchase) primary.push('addPurchase');
  if (link) primary.push('createLink');
  if (arriving) primary.push('arrive');
  if (changing) primary.push('change');
  const secondary = [];
  if (arriving) secondary.push('noShow');
  if (reConfirm) secondary.push('confirm');
  if (changing) secondary.push('cancel');
  const moveTo = moveTarget(r, can);
  const ad = (rawOrder?.reservations || []).find((x) => String(x.id) === String(r?.reservation_id))?.addons || [];
  return {
    primary,
    secondary,
    payment: {
      show: orderReady,
      rows: orderReady ? order.balance : null,
      createLink: link,
      recordPayment: link,
      openOrder: payments,
    },
    editAddons: changing && orderReady && (!addPurchase || (ad.length > 0 && addonsEditable(rawOrder, r?.reservation_id))),
    note: booking ? 'edit' : r?.notes ? 'read' : null,
    move: moveTo ? { show: true, to: moveTo } : null,
  };
}
