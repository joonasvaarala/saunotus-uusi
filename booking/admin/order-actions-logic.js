// Hallinnan Tilaukset-näkymän neljän toiminnon näkyvyys: palauta vain käytettävissä olevat.
// Oikeudet tarkistetaan myös palvelimella; käyttöliittymä ei näytä toimimattomia nappeja.
import { orderInvoiceLocked } from './addon-lock-logic.js';

export function visibleOrderActions(order, { canRefund = false, canAdd = false } = {}) {
  const native = order.is_native === true;
  const unpaid = Number(order.balance?.unpaid ?? 0);
  const locked = orderInvoiceLocked(order);
  const refundable = (order.payments || []).some((p) =>
    ['paid', 'partially_refunded'].includes(p.status) && Number(p.amount) > Number(p.refunded_amount ?? 0));
  const visible = [];
  if (native && order.staff_can_add && canAdd && !locked) visible.push('addToOrder');
  if (native && unpaid > 0 && !locked) visible.push('createPaymentLink', 'recordPayment');
  if (canRefund && refundable) visible.push('refund');
  return visible;
}
