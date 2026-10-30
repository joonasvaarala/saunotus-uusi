// Kassa ja talous › Hyvitysten seuranta (booking_218). Oikeus bookings.manage tai admin.
import { h, toast, errMsg, badge } from '../ui.js';
import { fmt, getLang } from '../talous-i18n.js';
import { formDialog } from './talous-ui.js';
import { createRefundWatchApi } from '../refund-watch-api.js';
import { rw } from '../refund-watch-texts.js';
import { rpc, fn } from '../sb.js';

const fld = (label, input) => h('label', { class: 'fld' }, h('span', { text: label }), input);

export async function render({ ctx }) {
  const lang = getLang();
  const api = createRefundWatchApi({ rpc, fn });
  const can = !!ctx?.can?.('bookings.manage') || ctx?.role === 'admin';
  const root = h('section', { class: 'tl refund-watch', 'data-testid': 'refund-watch', lang });
  if (!can) {
    root.append(h('h1', { text: rw('ui.admin.refund_watch.title') }), h('p', { class: 'err', role: 'alert', text: rw('ui.admin.refund_watch.no_perm') }));
    return root;
  }
  const banner = h('p', { class: 'tl-banner', role: 'status', 'data-testid': 'refund-aging', hidden: true });
  const count = h('p', { class: 'muted', 'data-testid': 'refund-watch-count' });
  const body = h('tbody');
  const table = h('table', { class: 'tl-table', 'data-testid': 'refund-watch-table' },
    h('thead', {}, h('tr', {}, ['amount', 'customer', 'order', 'status', 'age', 'provider', 'actions'].map((k) => h('th', { scope: 'col', text: rw(`ui.admin.refund_watch.col.${k}`) })))),
    body);
  const search = h('input', { type: 'search', 'data-testid': 'refund-watch-search', placeholder: rw('ui.admin.refund_watch.search'), 'aria-label': rw('ui.admin.refund_watch.search') });
  let rows = [];

  function statusText(row) {
    return rw(`ui.admin.refund_watch.status.${row.status}`) || row.status;
  }
  function paint() {
    const q = search.value.trim().toLowerCase();
    const list = rows.filter((r) => !q || String(r.order_no).includes(q) || String(r.customer_name || '').toLowerCase().includes(q) || String(r.provider_refund_id || '').toLowerCase().includes(q));
    const aging = list.filter((r) => r.aging).length;
    banner.hidden = aging < 1;
    banner.textContent = rw('ui.admin.refund_watch.aging_banner', { n: aging });
    count.textContent = String(list.length);
    body.replaceChildren(...(list.length ? list.map(rowView) : [h('tr', {}, h('td', { colspan: '7' }, h('p', { class: 'empty', text: rw('ui.admin.refund_watch.empty') })))]));
  }
  function rowView(row) {
    const tr = h('tr', { 'data-testid': 'refund-watch-row', 'data-refund-id': String(row.refund_id), 'data-status': row.status, 'data-aging': row.aging ? 'true' : 'false' });
    const actions = h('div', { class: 'tl-actions' });
    if (row.can_retry) {
      actions.append(h('button', { type: 'button', class: 'btn', 'data-testid': 'refund-watch-retry', onclick: () => retry(row) }, rw('ui.admin.refund_watch.retry')));
    }
    actions.append(h('button', { type: 'button', class: 'btn', 'data-testid': 'refund-watch-manual', onclick: () => manual(row) }, rw('ui.admin.refund_watch.manual')));
    tr.append(
      h('td', { text: fmt.money(row.amount) }),
      h('td', { text: row.customer_name || '–' }),
      h('td', { text: row.order_no != null ? `#${row.order_no}` : '–' }),
      h('td', {}, badge(row.status === 'failed' ? 'st-cancelled' : 'st-pending', statusText(row)), row.aging ? badge('pay-failed', rw('ui.admin.refund_watch.aging')) : null),
      h('td', { text: rw('ui.admin.refund_watch.age_hours', { hours: row.age_hours ?? '' }) }),
      h('td', { text: row.provider || '–' }),
      h('td', {}, actions),
    );
    return tr;
  }
  async function load() {
    const res = await api.list(search.value.trim());
    rows = res.rows || [];
    paint();
  }
  async function retry(row) {
    try {
      await api.retry(row.refund_id);
      const sent = await api.providerRefund(row.provider, row.refund_id);
      toast(sent?.result && sent.result !== 'done' && sent.result !== 'pending' ? `${rw('ui.admin.refund_watch.retry_done')} (${sent.result})` : rw('ui.admin.refund_watch.retry_done'));
      await load();
    } catch (e) { toast(errMsg(e), 'err'); }
  }
  function manual(row) {
    const amount = h('input', { name: 'amount', type: 'number', step: '0.01', min: '0.01', max: String(row.amount), value: String(row.amount), required: true, 'data-testid': 'refund-manual-amount' });
    const date = h('input', { name: 'date', type: 'date', required: true, value: new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' }), 'data-testid': 'refund-manual-date' });
    const ref = h('input', { name: 'provider_ref', required: true, maxlength: '120', 'data-testid': 'refund-manual-ref' });
    const note = h('input', { name: 'note', required: true, maxlength: '500', 'data-testid': 'refund-manual-note' });
    formDialog(rw('ui.admin.refund_watch.manual_title'), [
      h('p', { class: 'muted', text: rw('ui.admin.refund_watch.manual_hint') }),
      fld(rw('ui.admin.refund_watch.amount'), amount),
      fld(rw('ui.admin.refund_watch.date'), date),
      fld(rw('ui.admin.refund_watch.provider_ref'), ref),
      fld(rw('ui.admin.refund_watch.note'), note),
    ], rw('ui.admin.refund_watch.submit'), async (fd) => {
      await api.manual({
        refundId: row.refund_id,
        amount: Number(fd.get('amount')),
        date: String(fd.get('date')),
        providerRef: String(fd.get('provider_ref') || '').trim(),
        note: String(fd.get('note') || '').trim(),
      });
      toast(rw('ui.admin.refund_watch.done'));
      await load();
    });
  }
  search.addEventListener('input', paint);
  root.append(
    h('h1', { text: rw('ui.admin.refund_watch.title') }),
    h('p', { class: 'muted', text: rw('ui.admin.refund_watch.intro') }),
    banner,
    h('form', { class: 'tl-toolbar', onsubmit: (e) => e.preventDefault() }, search),
    count,
    table,
  );
  try { await load(); } catch (e) { root.append(h('p', { class: 'err', role: 'alert', text: errMsg(e) })); }
  return root;
}
