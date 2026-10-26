// booking_182: jaettu tilausten lisäostojen ja maksulinkkien UI, ei viestien lähetystä.
// Palvelin laskee kaikkien muiden kuin custom-rivien hinnat.
import { rpc } from '../sb.js';
import { h, dialog, toast, errMsg, fmtTime, addDays } from '../ui.js';
import { t, fmt, getLang } from '../talous-i18n.js';
import { absLink, RPC } from '../talous-api.js';
import { formDialog, doneToast } from './talous-ui.js';
import { orderText as tx } from '../orders-texts.js';
import { newPurchaseItem, afterAddChoices } from '../order-reservation-logic.js';

const VAT_CHOICES = [25.5, 13.5, 0]; // Vanhan vapaan rivin valikoima; validointi palvelimella.
const fld = (name, ...nodes) => h('label', { class: 'fld' }, h('span', { text: name }), ...nodes);
const quantity = (name, value = 1) => h('input', { name, type: 'number', min: 1, max: 99, value, inputmode: 'numeric', required: true });
const helDay = () => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Helsinki', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());

export function showLinkResult({ result, order }) {
  const url = absLink(result?.link_path, order);
  if (!url) { toast(tx('ui.admin.orders.link_missing'), 'warn'); return; }
  const link = h('input', { type: 'text', readonly: true, value: url, 'aria-label': tx('ui.admin.orders.link_copy'), 'data-testid': 'order-flow-link-url', onfocus: (e) => e.target.select() });
  const copy = h('button', { type: 'button', class: 'btn', text: tx('ui.admin.orders.link_copy'), onclick: async () => {
    try { await navigator.clipboard.writeText(url); toast(tx('ui.admin.orders.link_copied')); }
    catch { link.focus(); link.select(); }
  } });
  dialog(tx('ui.admin.orders.link_created'), h('div', { class: 'stack' }, fld(tx('ui.admin.orders.link_copy'), link), copy,
    h('p', { class: 'muted', text: result?.online_payment_enabled ? t('link.online') : t('link.onsite') })));
}

export function openOrderPaymentLink({ api, ctx, order, onDone }) {
  if (!ctx.can('payments.manage') || !order?.is_native || !(Number(order?.balance?.unpaid) > 0)) return null;
  return formDialog(tx('ui.admin.orders.link_created'), [
    h('p', { class: 'muted', text: tx('ui.admin.orders.link_only_uncovered') }),
    h('p', { text: t('link.amount', { sum: fmt.money(order.balance.unpaid) }) }),
    fld(t('link.days'), h('input', { name: 'days', type: 'number', min: 1, max: 90, value: 14, required: true })),
  ], t('link.submit'), async (fd) => {
    const days = Number(fd.get('days'));
    if (!Number.isInteger(days) || days < 1 || days > 90) throw new Error(tx('ui.admin.orders.bad_days'));
    const result = await api.createPaymentLink({ orderId: order.order_id, sendEmail: false, expiresDays: days });
    doneToast(result, RPC.createPaymentLink);
    onDone?.(result);
    setTimeout(() => showLinkResult({ result, order }), 0);
  });
}

// Muiden kuin lahjakorttimaksujen kirjaus. Ei korvaa Talous-näkymän laajempaa recordDialogia.
export function openOrderRecordPayment({ api, ctx, order, onDone }) {
  if (!ctx.can('payments.manage') || !order.is_native || !(order.balance?.unpaid > 0)) return null;
  const methods = (ctx.refs?.methods || []).filter((m) => m.active && m.is_manual && !['gift_card', 'cash', 'pay_later'].includes(m.code));
  if (!methods.length) { toast(tx('ui.admin.orders.record_no_methods'), 'warn'); return null; }
  return formDialog(t('btn.recordTitle'), [
    fld(t('record.method'), h('select', { name: 'method', required: true }, methods.map((m) => h('option', { value: m.code, text: m.label || m.code })))),
    fld(t('record.amount'), h('input', { name: 'amount', type: 'number', min: '0.01', max: order.balance.unpaid, step: '0.01', value: order.balance.unpaid, required: true })),
    fld(t('record.note'), h('input', { name: 'note', maxlength: 200 })),
  ], t('record.submit'), async (fd) => {
    const amt = Math.round(Number(fd.get('amount')) * 100) / 100;
    if (!(amt > 0) || amt > order.balance.unpaid + 0.005) throw new Error(t('refund.badAmount'));
    const result = await api.recordPayment({ orderId: order.order_id, method: fd.get('method'), amount: amt, note: String(fd.get('note') || '').trim() || null });
    doneToast(result, RPC.recordPayment); onDone?.(result);
  });
}

function showAdded({ api, ctx, order, result, onDone, onRecordPayment, onRefund }) {
  const balance = afterAddChoices(order.balance, ctx.can);
  const list = (result?.added || []).map((x) => h('li', {}, h('span', { text: x.name || '' }), ' · ', h('strong', { text: fmt.money(x.line_total) })));
  const actions = h('div', { class: 'row wrap' },
    balance.link ? h('button', { type: 'button', class: 'btn primary', 'data-testid': 'purchase-create-link', text: tx('ui.admin.orders.purchase_link'), onclick: () => { d.close(); openOrderPaymentLink({ api, ctx, order, onDone }); } }) : null,
    balance.record ? h('button', { type: 'button', class: 'btn', 'data-testid': 'purchase-record', text: tx('ui.admin.orders.purchase_record'), onclick: () => { d.close(); if (onRecordPayment) onRecordPayment(order); else openOrderRecordPayment({ api, ctx, order, onDone }); } }) : null,
    h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'purchase-leave', text: tx('ui.admin.orders.purchase_leave'), onclick: () => d.close() }));
  const d = dialog(tx('ui.admin.orders.purchase_added'), h('div', { class: 'stack' },
    h('ul', { class: 'reslist' }, ...list),
    h('dl', { class: 'kv' }, h('dt', { text: t('order.total') }), h('dd', { text: fmt.money(order.balance.total) }),
      h('dt', { text: t('order.unpaid') }), h('dd', { text: fmt.money(order.balance.unpaid) })),
    h('p', { class: 'muted', text: tx('ui.admin.orders.purchase_no_email') }), actions));
  return d;
}

// Sama lomake palvelee Tilaukset- ja varausdialogia. reservationId lukitaan varausdialogissa.
export async function openAddToOrder({ api, ctx, order, reservationId = null, onDone, onRecordPayment, onRefund }) {
  if (!ctx.can('bookings.manage') || !order?.is_native || !order?.staff_can_add) return null;
  const en = getLang() === 'en';
  let addons = []; try { addons = await api.listAddons(); } catch { /* tuote- ja vapaa rivi vielä käytettävissä */ }
  const products = (ctx.refs?.products || []).filter((p) => p.active !== false);
  const rentals = products.filter((p) => p.category === 'product_rental');
  const services = products.filter((p) => p.config?.public_slots === true && p.config?.lifecycle === 'current');
  const labelProduct = (p) => (en && p.name_en) || p.name || String(p.id);
  const reservations = (order.reservations || []).filter((r) => !reservationId || Number(r.reservation_id) === Number(reservationId));
  const choices = [];
  if (reservations.length && addons.length) choices.push(['addon', tx('ui.admin.orders.add_type_addon')]);
  if (ctx.can('bookings.manage')) choices.push(['reservation', tx('ui.admin.orders.add_type_reservation')]);
  if (rentals.length) choices.push(['product', tx('ui.admin.orders.add_type_product')]);
  if (ctx.can('bookings.override')) choices.push(['custom', t('add.custom')]);
  if (!choices.length) return null;

  const type = h('select', { name: 'type', 'data-testid': 'add-type' }, choices.map(([id, label]) => h('option', { value: id, text: label })));
  const resSel = h('select', { name: 'reservation', disabled: !!reservationId }, reservations.map((r) => h('option', { value: r.reservation_id, text: `${r.product_name} · ${fmt.dt(r.starts_at)}` })));
  const addonSel = h('select', { name: 'addon' }, addons.map((a) => h('option', { value: a.code, text: `${en ? a.name_en : a.name} · ${fmt.money(a.price)}` })));
  const addonBox = h('div', { class: 'stack' }, fld(t('add.reservation'), resSel), fld(t('add.addonName'), addonSel));
  const rentSel = h('select', { name: 'rental' }, rentals.map((p) => h('option', { value: p.id, text: labelProduct(p) })));
  const productBox = h('div', { class: 'stack' }, fld(tx('ui.admin.orders.rental'), rentSel));
  const service = h('select', { name: 'service' }, services.map((p) => h('option', { value: p.id, text: labelProduct(p) })));
  const kind = h('select', { name: 'kind' }, h('option', { value: 'rule', text: tx('ui.admin.orders.add_session') }),
    h('option', { value: 'slot', text: tx('ui.admin.orders.add_treatment'), disabled: !services.length || null }));
  const date = h('input', { name: 'date', type: 'date', value: helDay(), required: true });
  const persons = quantity('persons');
  const slotSelect = h('select', { name: 'slot', required: true, 'aria-label': tx('ui.admin.orders.choose_time') });
  const slotNote = h('p', { class: 'muted', role: 'status', text: tx('ui.admin.orders.choose_day') });
  const sessionBox = h('div', { class: 'stack' }, fld(tx('ui.admin.orders.book_kind'), kind),
    fld(tx('ui.admin.orders.choose_service'), service), fld(tx('ui.admin.orders.choose_day'), date),
    fld(tx('ui.admin.orders.persons'), persons), fld(tx('ui.admin.orders.choose_time'), slotSelect), slotNote);
  const customBox = h('div', { class: 'stack' },
    fld(t('add.desc'), h('input', { name: 'desc', maxlength: 120 })),
    fld(t('add.amount'), h('input', { name: 'amount', type: 'number', step: '0.01' })),
    fld(t('add.vat'), h('select', { name: 'vat' }, VAT_CHOICES.map((v) => h('option', { value: v, text: fmt.pct(v) })))));
  const qty = quantity('qty');
  const qtyField = fld(t('add.qty'), qty);
  let currentSlots = [], selectedDate = null, seq = 0;
  const boxes = { addon: addonBox, reservation: sessionBox, product: productBox, custom: customBox };
  const syncType = () => { Object.entries(boxes).forEach(([k,box]) => { box.hidden = k !== type.value; }); qtyField.hidden = type.value === 'reservation'; };
  type.addEventListener('change', syncType); syncType();
  const syncKind = () => { service.closest('label').hidden = kind.value !== 'slot'; loadSlots(); };
  const loadSlots = async () => {
    const seqNow = ++seq;
    currentSlots = []; slotSelect.replaceChildren();
    slotNote.textContent = tx('ui.admin.orders.loading_slots');
    if (type.value !== 'reservation') return;
    try {
      let rows;
      if (kind.value === 'slot') {
        if (!service.value) { slotNote.textContent = tx('ui.admin.orders.no_slots'); return; }
        rows = await rpc('admin_treatment_availability', { p_product_id: Number(service.value), p_from: date.value, p_to: date.value,
          p_persons: Number(persons.value), p_override: false, p_override_reason: null });
        rows = (rows || []).filter((r) => r.status === 'available' || r.status == null).map((r) => ({ ...r, kind: 'slot' }));
      } else {
        const v = await rpc('admin_day_view', { p_date: date.value });
        rows = (v.sessions || []).filter((s) => s.status === 'available').map((r) => ({ ...r, kind: 'rule' }));
      }
      if (seqNow !== seq) return;
      currentSlots = rows.filter((s) => s.kind === 'slot' || (s.mode === 'exclusive' || (s.remaining || 0) >= Number(persons.value)));
      slotSelect.replaceChildren(...currentSlots.map((s, i) => h('option', { value: String(i), text: `${fmtTime(s.starts_at)} · ${labelProduct(products.find((p) => Number(p.id) === Number(s.product_id)) || { name: s.label || '' })}` })));
      slotNote.textContent = currentSlots.length ? tx('ui.admin.orders.slots_found', { n: currentSlots.length }) : tx('ui.admin.orders.no_slots');
    } catch (e) { if (seqNow === seq) slotNote.textContent = `${tx('ui.admin.orders.slots_error')}: ${errMsg(e)}`; }
  };
  kind.addEventListener('change', syncKind); date.addEventListener('change', loadSlots); service.addEventListener('change', loadSlots); persons.addEventListener('change', loadSlots);
  type.addEventListener('change', () => { if (type.value === 'reservation') loadSlots(); });

  const d = formDialog(tx('ui.admin.orders.add_purchase'), [
    h('p', { class: 'muted', text: tx('ui.admin.orders.purchase_no_email') }), fld(t('add.what'), type),
    addonBox, sessionBox, productBox, customBox, qtyField,
    fld(t('add.note'), h('input', { name: 'note', maxlength: 200 })),
  ], t('add.submit'), async (fd) => {
    let item; const name = fd.get('type');
    if (name === 'addon') item = newPurchaseItem(name, { reservation_id: reservationId || fd.get('reservation'), code: fd.get('addon'), quantity: fd.get('qty') });
    else if (name === 'product') item = newPurchaseItem(name, { product_id: fd.get('rental'), quantity: fd.get('qty') });
    else if (name === 'reservation') {
      const selected = currentSlots[Number(fd.get('slot'))];
      if (!selected) throw new Error(tx('ui.admin.orders.choose_time'));
      item = selected.kind === 'slot' ? newPurchaseItem(name, { product_id: selected.product_id || service.value, start: selected.starts_at,
        end: selected.ends_at, persons: fd.get('persons'), quantity: 1 }) :
        newPurchaseItem(name, { rule_id: selected.rule_id, date: fd.get('date'), persons: fd.get('persons'), quantity: 1 });
    } else if (name === 'custom' && ctx.can('bookings.override')) item = newPurchaseItem(name, {
      description: fd.get('desc'), amount: fd.get('amount'), vat_rate: fd.get('vat'), quantity: fd.get('qty'),
    }); else throw new Error(tx('ui.admin.orders.invalid_type'));
    const result = await api.addToOrder({ orderId: order.order_id, items: [item], createLink: false, sendEmail: false, note: fd.get('note') || null });
    doneToast(result, RPC.addToOrder);
    const refreshed = await api.getOrder(order.order_id);
    onDone?.(result);
    setTimeout(() => showAdded({ api, ctx, order: refreshed, result, onDone, onRecordPayment, onRefund }), 0);
  });
  syncKind();
  return d;
}
