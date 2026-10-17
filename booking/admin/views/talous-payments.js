// Talous › Maksut: aikajärjestyksessä (uusin ensin), haku, suodattimet, palvelinpuolinen sivutus; rivi aukeaa maksun laskuriveiksi.
import { h } from '../ui.js';
import { pdfLink, receiptsList } from './talous-receipts.js';
import { t, fmt } from '../talous-i18n.js';
import { METHODS, PSTAT, methodLabel, pstatLabel, pstatBadge, loading, emptyBox, errorBox, pager, pageSizeSelect, selectFld, dateFld, searchFld, expandRow } from './talous-ui.js';

export function createPaymentsTab({ api, ctx, onOpenOrder }) {
  const st = { search: '', method: '', status: '', from: '', to: '', sortDir: 'desc', limit: 25, offset: 0 };
  const list = h('ul', { class: 'tl-list pay', 'data-testid': 'payments-list' }), count = h('p', { class: 'muted tl-count', role: 'status', 'data-testid': 'payments-count' }), pagers = [h('div'), h('div')];
  let seq = 0;
  async function load() {
    const my = ++seq;
    list.replaceChildren(loading()); list.setAttribute('aria-busy', 'true');
    try {
      const r = await api.listPayments({ ...st });
      if (my !== seq) return;
      list.setAttribute('aria-busy', 'false');
      if (st.offset >= r.total && r.total > 0) { st.offset = Math.max(0, Math.floor((r.total - 1) / st.limit) * st.limit); return load(); }
      count.textContent = r.total ? `${t('payments.count', { from: fmt.int(st.offset + 1), to: fmt.int(Math.min(st.offset + st.limit, r.total)), total: fmt.int(r.total) })} · ${t('payments.sums', { paid: fmt.money(r.sum_paid), refunded: fmt.money(r.sum_refunded) })}` : '';
      list.replaceChildren(...(r.rows.length ? r.rows.map(payRow) : [emptyBox(t('payments.none'))]));
      const mk = () => (r.total > st.limit ? pager({ total: r.total, offset: st.offset, limit: st.limit, onPage: (o) => { st.offset = o; load(); } }) : h('span'));
      pagers[0].replaceChildren(mk()); pagers[1].replaceChildren(mk());
    } catch (e) { if (my === seq) { list.replaceChildren(errorBox(e, load)); count.textContent = ''; pagers.forEach((p) => p.replaceChildren()); } }
  }
  const change = (patch) => { Object.assign(st, patch, { offset: 0 }); load(); };
  function payRow(p) {
    const head = [
      h('span', { class: 'tl-c tl-date' }, h('small', { class: 'tl-lab', text: t('col.time') }), h('span', { text: fmt.dt(p.paid_at || p.created_at) })),
      h('span', { class: 'tl-c tl-main' }, h('strong', { text: `#${p.order_no}` }), ' ', h('span', { class: 'tl-name', text: p.customer_name || '–' })),
      h('span', { class: 'tl-c tl-first' }, h('small', { class: 'tl-lab', text: t('col.method') }), h('span', { text: methodLabel(p.method, p.method_label) })),
      h('span', { class: 'tl-c tl-sum' }, h('strong', { text: fmt.money(p.amount) }), p.refunded_amount ? h('small', { class: 'tl-refund', text: `−${fmt.money(p.refunded_amount)}` }) : null),
      h('span', { class: 'tl-c tl-badges' }, pstatBadge(p.status)),
    ];
    // kuittinumero + PDF-lataus näkyvät aina rivin alla (ei napin sisällä); kuitin teksti ja uudelleenlähetys rivin avauksessa
    const bar = p.receipt_no ? h('div', { class: 'tl-rowbar', 'data-testid': 'payment-receipt-bar' }, h('span', { class: 'tl-rowbar-no' }, h('small', { text: `${t('receipt')} ` }), h('strong', { 'data-testid': 'payment-receipt-no', text: p.receipt_no })), pdfLink({ api, token: p.receipt_token, no: p.receipt_no, short: true, testid: 'payment-receipt-dl' })) : null;
    return expandRow({ id: `p${p.payment_id}`, head, testid: 'payment', bar, build: () => payDetail(p) });
  }
  // maksulistaus ei sisällä laskurivejä (sopimus: vain line_count) → rivit haetaan tilauksen tiedoista (admin_get_order → payments[].lines)
  async function payDetail(row) {
    const order = await api.getOrder(row.order_id);
    const p = { ...row, ...(order.payments.find((x) => x.payment_id === row.payment_id) || { lines: [], receipts: [], refunds: [] }) };
    const receipts = p.receipts.map((r) => ({ ...r, total: r.total ?? order.receipts.find((x) => x.id === r.id)?.total ?? null, payment_id: r.payment_id ?? p.payment_id }));
    const sumG = p.lines.reduce((s, l) => s + l.amount_gross, 0), sumV = p.lines.reduce((s, l) => s + l.line_vat, 0), sumN = p.lines.reduce((s, l) => s + l.line_net, 0);
    const table = p.lines.length ? h('table', { class: 'tl-table', 'data-testid': 'payment-lines' },
      h('thead', {}, h('tr', {}, ['line.desc', 'line.qty', 'line.gross', 'line.vatPct', 'line.vat', 'line.net'].map((k, i) => h('th', { scope: 'col', class: i ? 'r' : '', text: t(k) })))),
      h('tbody', {}, p.lines.map((l) => h('tr', {}, h('td', { 'data-label': t('line.desc'), text: l.description }), h('td', { class: 'r', 'data-label': t('line.qty'), text: fmt.int(l.quantity) }), h('td', { class: 'r', 'data-label': t('line.gross'), text: fmt.money(l.amount_gross) }),
        h('td', { class: 'r', 'data-label': t('line.vatPct'), text: fmt.pct(l.vat_rate) }), h('td', { class: 'r', 'data-label': t('line.vat'), text: fmt.money(l.line_vat) }), h('td', { class: 'r', 'data-label': t('line.net'), text: fmt.money(l.line_net) })))),
      h('tfoot', {}, h('tr', {}, h('th', { scope: 'row', text: t('line.total') }), h('td', { class: 'r', 'data-label': t('line.qty') }), h('td', { class: 'r', 'data-label': t('line.gross'), text: fmt.money(sumG) }), h('td', { class: 'r', 'data-label': t('line.vatPct') }),
        h('td', { class: 'r', 'data-label': t('line.vat'), text: fmt.money(sumV) }), h('td', { class: 'r', 'data-label': t('line.net'), text: fmt.money(sumN) })))) : emptyBox(t('payment.noLines'));
    return h('div', { class: 'tl-detail' },
      h('p', { class: 'muted tl-meta', text: [`${t('payment.id')} ${p.payment_id}`, p.receipt_no ? `${t('receipt')} ${p.receipt_no}` : null, p.provider ? `${t('payment.provider')} ${p.provider}` : null, p.rounding ? `${t('payment.rounding')} ${fmt.money(p.rounding)}` : null].filter(Boolean).join(' · ') }),
      h('section', { class: 'tl-sec' }, h('h3', { text: t('payment.lines') }), table),
      h('section', { class: 'tl-sec' }, h('h3', { text: t('receipts.title') }), receiptsList({ api, ctx, receipts, testid: 'payment-receipts' })),
      h('div', { class: 'tl-actions' }, h('button', { type: 'button', class: 'btn tl-btn', 'data-testid': 'btn-open-order', onclick: () => onOpenOrder(p.order_no) }, h('span', { text: t('payment.openOrder') }))));
  }
  const dirBtn = h('button', { type: 'button', class: 'btn ghost tl-dir', 'data-testid': 'payments-dir', onclick: () => { st.sortDir = st.sortDir === 'desc' ? 'asc' : 'desc'; syncDir(); change({}); } });
  const syncDir = () => { dirBtn.textContent = st.sortDir === 'desc' ? t('payments.newest') : t('payments.oldest'); dirBtn.dataset.dir = st.sortDir; };
  syncDir();
  let toolbar;
  function buildToolbar() {
    const ss = searchFld(t('payments.searchPh'), 'payments-search', (v) => change({ search: v })); ss.input.value = st.search;
    const next = h('form', { class: 'tl-toolbar', role: 'search', onsubmit: (e) => e.preventDefault() }, ss.node,
      h('div', { class: 'fld' }, h('span', { text: t('sort.label') }), dirBtn),
      selectFld(t('filters.method'), 'payments-f-method', METHODS, (c) => methodLabel(c), st.method, (v) => change({ method: v })),
      selectFld(t('filters.pstat'), 'payments-f-status', PSTAT, pstatLabel, st.status, (v) => change({ status: v })),
      dateFld(t('filters.from'), 'payments-f-from', st.from, (v) => change({ from: v })), dateFld(t('filters.to'), 'payments-f-to', st.to, (v) => change({ to: v })),
      pageSizeSelect(st.limit, (n) => change({ limit: n })),
      h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'payments-reset', onclick: () => { Object.assign(st, { search: '', method: '', status: '', from: '', to: '' }); buildToolbar(); load(); } }, t('filters.reset')));
    if (toolbar?.isConnected) toolbar.replaceWith(next);
    toolbar = next; return next;
  }
  buildToolbar();
  const cols = h('div', { class: 'tl-cols pay', 'aria-hidden': 'true' }, h('span', { text: t('col.time') }), h('span', { text: t('col.order') }), h('span', { text: t('col.method') }), h('span', { class: 'r', text: t('col.sum') }), h('span', { text: t('col.status') }), h('span'));
  const node = h('div', { class: 'tl-tab', 'data-testid': 'tab-payments' }, toolbar, count, pagers[0], cols, list, pagers[1]);
  return { node, load, setSearch(q) { st.search = q; st.offset = 0; buildToolbar(); load(); } };
}
