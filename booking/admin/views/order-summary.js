// Tilausnäkymä v3 (PR 1): työpöydän sivupaneelin yhteenveto tilauslistan vieressä (~430 px, luonnos desktop-lista-yhteenveto).
// Näyttää asiakkaan, #nro, kanavan, merkit (varaus, maksu, Ongelma), ensimmäisen varauksen ja "+N varausta", lisäostot, yhteensä /
// maksettu / AVOINNA (tai ylisuoritus), ensimmäisen varauksen muistiinpanon, 2 tilan mukaista toimintoa, Soita/Sähköposti ja
// "Avaa koko tilaus →". Näppäimet (↑/↓, Esc) ja sulkeminen suodattimen/sivun vaihtuessa: ./talous-orders.js.
import { rpc as sbRpc } from '../sb.js';
import { h, errMsg } from '../ui.js';
import { icon } from '../icons.js';
import { fmt } from '../talous-i18n.js';
import { createLatestGate } from '../reservation-dialog-logic.js';
import { ov, loadOvTexts } from '../order-view-texts.js';
import { orderModel, summaryModel } from '../order-view-logic.js';
import { badgeNodes, whenText, createActionRunner, actionButton, contactButtons, channelText } from './order-view.js';

export function createSummaryPanel({ ctx, rpc = sbRpc, api, dialogs = null, onOpenFull, onClose, now = null }) {
  const node = h('aside', { class: 'ov-summary', 'data-testid': 'order-summary', 'aria-label': ov('order_view.summary_label'), hidden: true, tabindex: '-1' });
  const gate = createLatestGate();
  let current = null;
  const env = { ctx, rpc, api, dialogs, refs: ctx.refs, reload: () => current && show(current, { keepFocus: true }) };
  const runner = createActionRunner(env);
  loadOvTexts(rpc).catch(() => {});

  async function show(row, { keepFocus = false } = {}) {
    current = row;
    const token = gate.next();
    node.hidden = false;
    node.dataset.orderId = row.order_id;
    node.replaceChildren(head(row.customer_name || '–', `#${row.order_no}`), h('p', { class: 'muted', role: 'status', text: ov('order_view.loading') }));
    try {
      const raw = await rpc('admin_get_order', { p_order_id: row.order_id });
      if (!gate.isCurrent(token)) return;
      paint(orderModel(raw));
      if (!keepFocus) node.focus({ preventScroll: true });
    } catch (e) {
      if (!gate.isCurrent(token)) return;
      node.replaceChildren(head(row.customer_name || '–', `#${row.order_no}`), h('p', { class: 'err', role: 'alert', text: ov('order_view.load_failed', { error: errMsg(e) }) }));
    }
  }
  function head(title, sub) {
    return h('div', { class: 'ov-sum-head' }, h('div', {}, h('h2', { class: 'ov-sum-name', 'data-testid': 'ov-sum-name', text: title }), h('p', { class: 'muted ov-small', text: sub })),
      h('button', { type: 'button', class: 'icon-btn', 'aria-label': ov('order_view.summary_close'), 'data-testid': 'ov-sum-close', onclick: () => close() }, icon('close', 20)));
  }
  function paint(m) {
    const at = now ? new Date(now) : new Date();
    const s = summaryModel(m, { can: ctx.can, now: at });
    const name = m.customer?.customer_kind === 'company' && m.customer?.company ? m.customer.company : (m.customer?.name || '–');
    const box = s.box;
    const amountKey = box.headline === 'overpaid' ? 'order_view.pay_overpaid' : (box.headline === 'settled' ? 'order_view.pay_settled' : 'order_view.pay_open');
    node.replaceChildren(...[
      head(name, ov('order_view.summary_channel', { no: m.order_no, channel: channelText(m) })),
      h('div', { class: 'ov-badges', 'data-testid': 'ov-sum-badges' }, badgeNodes(s.badges)),
      s.first ? h('div', { class: 'ov-sum-res', 'data-testid': 'ov-sum-res' },
        h('p', { class: 'ov-sum-when' }, h('strong', { text: whenText(s.first, at) })),
        h('p', { class: 'ov-small', text: [s.first.product_name, s.first.option?.name, ov('order_view.persons', { n: s.first.persons }), s.first.space_code ? (ctx.refs?.resources?.find((x) => x.code === s.first.space_code)?.name || s.first.space_code) : null].filter(Boolean).join(' · ') }),
        s.addons.length ? h('p', { class: 'muted ov-small', text: ov('order_view.summary_addons', { list: s.addons.map((a) => `${a.quantity} × ${a.name}`).join(', ') }) }) : null,
        s.more ? h('p', { class: 'muted ov-small', 'data-testid': 'ov-sum-more', text: ov('order_view.summary_more', { n: s.more }) }) : null) : null,
      h('div', { class: `ov-sum-pay ov-big-${box.headline}`, 'data-testid': 'ov-sum-pay' },
        h('span', { class: 'ov-small', text: ov('order_view.summary_totals', { total: fmt.money(box.total), paid: fmt.money(box.paid) }) }),
        h('span', { class: 'ov-sum-open' }, h('small', { text: ov(amountKey) }), ' ', h('strong', { 'data-testid': 'ov-sum-open', text: fmt.money(box.amount) }))),
      s.note ? h('div', { class: 'ov-sum-note', 'data-testid': 'ov-sum-note' }, h('strong', { text: ov('order_view.notes_summary') }), ' ', s.note.short) : null,
      s.actions.length ? h('div', { class: 'ov-sum-actions', 'data-testid': 'ov-sum-actions' }, s.actions.map((a, i) => actionButton(a, m, runner, { primary: i === 0, testPrefix: 'ov-sum' }))) : null,
      h('div', { class: 'ov-sum-contact' }, contactButtons(m.customer, { big: true })),
      h('a', { class: 'btn ov-wide', href: `#/tilaukset/${m.order_no}`, 'data-testid': 'ov-sum-open-full', text: ov('order_view.act.open_full'),
        onclick: (e) => { if (onOpenFull) { e.preventDefault(); onOpenFull(m); } } }),
      h('p', { class: 'muted ov-small ov-sum-hint', text: ov('order_view.summary_hint') })].filter(Boolean));
  }
  function close() {
    if (node.hidden) return;
    gate.next(); current = null; node.hidden = true; node.replaceChildren();
    onClose?.();
  }
  return { node, show, close, get current() { return current; }, isOpen: () => !node.hidden };
}
