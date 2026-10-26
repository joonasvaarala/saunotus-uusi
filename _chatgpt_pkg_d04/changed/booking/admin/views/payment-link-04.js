// Varausdialogi 04: jaettu maksulinkkidialogi, oletuksena ei takarajaa.
import { h, dialog, toast } from '../ui.js';
import { t, fmt } from '../talous-i18n.js';
import { absLink, RPC } from '../talous-api.js';
import { formDialog, doneToast } from './talous-ui.js';
import { reservationText as tx } from '../reservation-texts-04.js';
import { LINK_DEADLINE, linkExpiresDays, linkValidityText } from '../payment-link-logic.js';

const fld = (name, ...nodes) => h('label', { class: 'fld' }, h('span', { text: name }), ...nodes);
export function linkDeadlineControl() {
  const checked = h('input', { type: 'checkbox', name: 'deadline', 'data-testid': 'link-deadline-toggle' });
  const days = h('input', { type: 'number', name: 'days', 'data-testid': 'link-deadline-days',
    min: LINK_DEADLINE.min, max: LINK_DEADLINE.max, value: LINK_DEADLINE.initial, inputmode: 'numeric', disabled: true });
  const field = fld(tx('ui.admin.orders.link_deadline_days'), days);
  field.classList.add('pl-days'); field.hidden = true;
  checked.addEventListener('change', () => { field.hidden = !checked.checked; days.disabled = !checked.checked; });
  const nodes = h('div', { class: 'pl-deadline' },
    h('label', { class: 'pl-toggle' }, checked, h('span', { text: tx('ui.admin.orders.link_set_deadline') })),
    h('p', { class: 'muted', text: tx('ui.admin.orders.link_deadline_help') }), field);
  return {
    nodes,
    read(fd) {
      const result = linkExpiresDays({ enabled: fd.has('deadline'), days: fd.get('days') });
      if (!result.ok) throw new Error(tx('ui.admin.orders.link_deadline_bad', LINK_DEADLINE));
      return result.expiresDays;
    },
  };
}
const validUntil = (result) => linkValidityText(result, tx, fmt.date);
export function showLinkResult({ result, order }) {
  const url = absLink(result?.link_path, order);
  if (!url) { toast(tx('ui.admin.orders.link_missing'), 'warn'); return; }
  const link = h('input', { type: 'text', readonly: true, value: url, 'aria-label': tx('ui.admin.orders.link_copy'),
    'data-testid': 'order-flow-link-url', onfocus: (e) => e.target.select() });
  const copy = h('button', { type: 'button', class: 'btn', text: tx('ui.admin.orders.link_copy'), onclick: async () => {
    try { await navigator.clipboard.writeText(url); toast(tx('ui.admin.orders.link_copied')); }
    catch { link.focus(); link.select(); }
  } });
  return dialog(tx('ui.admin.orders.link_created'), h('div', { class: 'stack' },
    fld(tx('ui.admin.orders.link_copy'), link), copy,
    h('p', { class: 'muted', text: validUntil(result) }),
    h('p', { class: 'muted', text: result?.online_payment_enabled ? t('link.online') : t('link.onsite') })));
}
export function openOrderPaymentLink({ api, ctx, order, onDone }) {
  if (!ctx.can('payments.manage') || !order?.is_native || !(Number(order?.balance?.unpaid) > 0)) return null;
  const deadline = linkDeadlineControl();
  return formDialog(tx('ui.admin.orders.link_created'), [
    h('p', { class: 'muted', text: tx('ui.admin.orders.link_only_uncovered') }),
    h('p', { text: t('link.amount', { sum: fmt.money(order.balance.unpaid) }) }), deadline.nodes,
  ], t('link.submit'), async (fd) => {
    const expiresDays = deadline.read(fd);
    const result = await api.createPaymentLink({ orderId: order.order_id, sendEmail: false, expiresDays });
    doneToast(result, RPC.createPaymentLink); onDone?.(result);
    setTimeout(() => showLinkResult({ result, order }), 0);
  });
}
