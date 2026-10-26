// booking_182: puhdas oikeus-, tila- ja syvälinkkilogiikka. Ei DOM-riippuvuuksia.
export const reservationDeepLink = (id) => `#/tilaukset?tab=reservations&id=${encodeURIComponent(id)}&period=all`;
export const orderDeepLink = (no) => `#/tilaukset?order=${encodeURIComponent(no)}`;

export function canAddPurchase(order, ctx = {}, enabled = true) {
  if (!enabled) return { allowed: false, reason: 'flag_off' };
  if (!ctx?.can?.('bookings.manage')) return { allowed: false, reason: 'no_permission' };
  if (!order?.is_native || order?.external_source) return { allowed: false, reason: 'johku' };
  if (!order?.staff_can_add) return { allowed: false, reason: 'closed' };
  return { allowed: true, reason: null };
}

export function afterAddChoices(balance, can = () => false) {
  const unpaid = Math.max(0, Number(balance?.unpaid ?? 0) || 0);
  return {
    unpaid,
    link: unpaid > 0 && !!can('payments.manage'),
    record: unpaid > 0 && !!can('payments.manage'),
    leave: true,
  };
}

export function newPurchaseItem(type, data) {
  const qty = Number(data.quantity);
  if (!Number.isSafeInteger(qty) || qty < 1 || qty > 99) throw new Error('invalid_quantity');
  if (type === 'addon') {
    if (!Number.isSafeInteger(Number(data.reservation_id)) || !data.code) throw new Error('invalid_addon');
    return { type, reservation_id: Number(data.reservation_id), code: String(data.code), quantity: qty };
  }
  if (type === 'product') {
    if (!Number.isSafeInteger(Number(data.product_id))) throw new Error('invalid_product');
    return { type, product_id: Number(data.product_id), quantity: qty };
  }
  if (type === 'reservation') {
    const persons = Number(data.persons);
    if (!Number.isSafeInteger(persons) || persons < 1 || persons > 99) throw new Error('invalid_persons');
    if (data.rule_id && data.date) return { type, rule_id: Number(data.rule_id), date: data.date, persons };
    if (data.product_id && data.start && data.end) return { type, product_id: Number(data.product_id), start: data.start, end: data.end, persons };
    throw new Error('invalid_slot');
  }
  if (type === 'custom') {
    const amount = Number(data.amount);
    if (!Number.isFinite(amount) || amount === 0 || !String(data.description || '').trim()) throw new Error('invalid_custom');
    return { type, description: String(data.description).trim(), amount, vat_rate: Number(data.vat_rate), quantity: qty };
  }
  throw new Error('invalid_type');
}

export const isFlowEnabledValue = (rows) => rows?.[0]?.value === true;
