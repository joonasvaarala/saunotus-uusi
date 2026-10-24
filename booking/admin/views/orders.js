// Tilaukset ja Varaukset saman päänavigaation alla; Talous säilyy vanhoille maksu- ja lahjakorttilinkeille.
import { h } from '../ui.js';
import { rpc, select as dbSelect, functionUrl, fnBlob, fn } from '../sb.js';
import { createTalousApi } from '../talous-api.js';
import { createGiftApi } from '../giftcards-api.js';
import { createOrdersTab } from './talous-orders.js';
import { loadOrderTexts } from '../orders-texts.js';
import { initialOrdersTab } from '../admin-navigation.js';
import { navText } from '../nav-texts.js';

export async function render({ ctx, refs, reload, query, legacyReservations = false }) {
  const canOrders = ctx.can('payments.manage');
  const selected = initialOrdersTab({ legacyReservations, query, canOrders });
  const TAB_LABELS = [['orders', 'ui.admin.nav.orders'], ['reservations', 'ui.admin.nav.reservations']];
  const options = TAB_LABELS.filter(([k]) => canOrders || k === 'reservations').map(([k, key]) => [k, navText(key)]);
  const panels = new Map(), buttons = new Map();
  let active = null, sequence = 0;
  const heading = h('h1', { text: navText(canOrders ? 'ui.admin.nav.orders' : 'ui.admin.nav.reservations') });
  const tabs = h('div', { class: 'tl-tabs', role: 'tablist', 'aria-label': navText('ui.admin.nav.orders_tabs'), hidden: options.length < 2 });
  const host = h('div', { class: 'orders-workspace', 'data-testid': 'orders-workspace' }, heading, tabs);
  for (const [key, label] of options) {
    const b = h('button', { type: 'button', role: 'tab', class: 'tl-tabbtn', id: `orders-tab-${key}`, 'aria-controls': `orders-panel-${key}`,
      'data-testid': `orders-tab-${key}`, onclick: () => selectTab(key, true),
      onkeydown: (e) => {
        const i = options.findIndex(([k]) => k === key);
        const j = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: options.length - 1 }[e.key];
        if (j != null) { e.preventDefault(); selectTab(options[(j + options.length) % options.length][0], true, true); }
      } }, label);
    const panel = h('section', { class: 'orders-panel', role: 'tabpanel', id: `orders-panel-${key}`, 'aria-labelledby': b.id, hidden: true });
    buttons.set(key, b); panels.set(key, panel); tabs.append(b); host.append(panel);
  }
  async function selectTab(key, sync, focus = false) {
    if (!panels.has(key)) return;
    active = key;
    const seq = ++sequence;
    for (const [id, el] of panels) {
      el.hidden = id !== key;
      const b = buttons.get(id);
      b.setAttribute('aria-selected', String(id === key));
      b.tabIndex = id === key ? 0 : -1;
    }
    if (sync) {
      // Välilehden vaihto ei piirtäisi route()-näkymää uudelleen; säilytä vain kyseisen välilehden parametrit.
      const q = new URLSearchParams(); q.set('tab', key);
      history.replaceState(null, '', `#/tilaukset?${q}`);
    }
    if (focus) buttons.get(key).focus();
    const panel = panels.get(key);
    if (panel.dataset.ready === '1') return;
    panel.replaceChildren(h('p', { class: 'muted', text: navText('ui.admin.nav.loading') }));
    try {
      if (key === 'orders') {
        await loadOrderTexts(rpc);
        if (seq !== sequence) return;
        const api = createTalousApi({ rpc, io: { select: dbSelect, functionUrl, fnBlob, fn } });
        const gift = createGiftApi({ rpc, io: { functionUrl } });
        const view = createOrdersTab({ api, ctx, gift });
        panel.replaceChildren(view.node);
        panel.dataset.ready = '1';
        await view.load();
        const orderNo = (query.get('order') || '').replace(/^#/, '').trim();
        if (orderNo && !sync) view.setSearch(orderNo, { open: true });
      } else {
        const mod = await import('./reservations.js');
        if (seq !== sequence) return;
        const next = await mod.render({ ctx, refs, reload, query: sync ? new URLSearchParams() : query,
          routePath: legacyReservations && !sync ? 'varaukset' : 'tilaukset' });
        if (seq !== sequence) return;
        panel.replaceChildren(...[].concat(next).filter(Boolean));
        panel.dataset.ready = '1';
      }
    } catch (err) {
      if (seq !== sequence) return;
      panel.replaceChildren(h('p', { class: 'err', role: 'alert', text: navText('ui.admin.nav.load_failed', { error: err?.message || String(err) }) }));
    }
  }
  await selectTab(selected, false);
  return host;
}
