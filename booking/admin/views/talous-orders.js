// Talous › Tilaukset: uusin ensin, haku, lajittelu, suodattimet ja PALVELINPUOLEN sivutus (12 000+ tilausta) – rivi aukeaa maksuiksi ja varauksiksi.
// Datan muoto: ../talous-api.js (admin_list_orders / admin_get_order). Napit (lisää, maksulinkki, hyvitys) kutsuvat api:a; oikeassa tilassa ne ovat pois käytöstä (LIVE_ACTIONS).
import { h, dialog } from '../ui.js';
import { icon } from '../icons.js';
import { t, fmt, getLang } from '../talous-i18n.js';
import { RPC, absLink } from '../talous-api.js';
import { PAY, SOURCES, payLabel, sourceLabel, payBadge, sourceBadge, loading, emptyBox, errorBox, pager, pageSizeSelect, selectFld, dateFld, searchFld, expandRow, actionBtn, doneToast, formDialog, methodLabel, pstatBadge } from './talous-ui.js';

export const ORDER_SORTS = ['created', 'order_no', 'total', 'payment_status', 'first_reservation'];
const VAT_CHOICES = [25.5, 13.5, 0];

export function createOrdersTab({ api, ctx }) {
  const st = { search: '', paymentStatus: '', source: '', native: '', dateField: '', from: '', to: '', sortBy: 'created', sortDir: 'desc', limit: 25, offset: 0 };
  const list = h('ul', { class: 'tl-list', 'data-testid': 'orders-list' }), count = h('p', { class: 'muted tl-count', role: 'status', 'data-testid': 'orders-count' }), pagers = [h('div'), h('div')];
  let seq = 0, reopen = null, autoOpen = false;
  async function load() {
    const my = ++seq;
    list.replaceChildren(loading()); list.setAttribute('aria-busy', 'true');
    try {
      const r = await api.listOrders({ ...st });
      if (my !== seq) return;
      list.setAttribute('aria-busy', 'false');
      if (st.offset >= r.total && r.total > 0) { st.offset = Math.max(0, Math.floor((r.total - 1) / st.limit) * st.limit); return load(); }
      count.textContent = r.total ? t('orders.count', { from: fmt.int(st.offset + 1), to: fmt.int(Math.min(st.offset + st.limit, r.total)), total: fmt.int(r.total) }) : '';
      list.replaceChildren(...(r.rows.length ? r.rows.map(orderRow) : [emptyBox(t('orders.none'))]));
      if (reopen != null) { list.querySelector(`[data-order-id="${reopen}"] .tl-head`)?.click(); reopen = null; }
      if (autoOpen) { autoOpen = false; if (r.rows.length === 1) { const row = list.firstElementChild; row.style.scrollMarginTop = '70px'; row.querySelector('.tl-head')?.click(); row.scrollIntoView({ block: 'start' }); } }   // syvälinkki (#/talous?order=<tilausnro>): ainoa osuma avataan
      const mk = () => (r.total > st.limit ? pager({ total: r.total, offset: st.offset, limit: st.limit, onPage: (o) => { st.offset = o; load(); document.querySelector('[data-testid=orders-count]')?.scrollIntoView({ block: 'nearest' }); } }) : h('span'));
      pagers[0].replaceChildren(mk()); pagers[1].replaceChildren(mk());
    } catch (e) { if (my === seq) { list.replaceChildren(errorBox(e, load)); count.textContent = ''; pagers.forEach((p) => p.replaceChildren()); } }
  }
  const change = (patch) => { Object.assign(st, patch, { offset: 0 }); load(); };
  // Oikea (ei mock) kirjoitus onnistui → lista + avoin tilaus haetaan uudelleen; Maksut/Raportit-välilehdet merkitään vanhentuneiksi (api.changed)
  const afterChange = (res, orderId) => { if (res?.mock) return; reopen = orderId; api.changed(); load(); };

  // ---- rivi ----
  function orderRow(o) {
    const head = [
      h('span', { class: 'tl-c tl-main' }, h('strong', { text: `#${o.order_no}` }), ' ', h('span', { class: 'tl-name', text: [o.customer_name || '–', o.customer_company].filter(Boolean).join(' · ') }),
        o.johku_order_no ? h('small', { class: 'tl-johku', text: ` Johku #${o.johku_order_no}` }) : null),
      h('span', { class: 'tl-c tl-date' }, h('small', { class: 'tl-lab', text: t('col.created') }), h('span', { text: fmt.dt(o.created_at) })),
      h('span', { class: 'tl-c tl-first' }, h('small', { class: 'tl-lab', text: t('col.first') }), h('span', { text: o.first_reservation_at ? fmt.date(o.first_reservation_at) : '–' })),
      h('span', { class: 'tl-c tl-sum' }, h('strong', { text: fmt.money(o.total_gross) })),
      h('span', { class: 'tl-c tl-badges' }, payBadge(o.payment_status), sourceBadge(o.source_channel)),
    ];
    const row = expandRow({ id: `o${o.order_id}`, head, testid: 'order', build: () => orderDetail(o.order_id) });
    row.dataset.orderId = o.order_id;
    return row;
  }
  async function orderDetail(id) {
    const o = await api.getOrder(id);
    const b = o.balance, unpaid = b.unpaid;
    const sec = (title, ...kids) => h('section', { class: 'tl-sec' }, h('h3', { text: title }), ...kids);
    const payments = o.payments.length
      ? h('ul', { class: 'tl-sub', 'data-testid': 'order-payments' }, o.payments.map((p) => h('li', {},
        h('span', { class: 'tl-sub-main' }, h('strong', { text: methodLabel(p.method, p.method_label) }), ' ', pstatBadge(p.status)),
        h('span', { class: 'tl-sub-meta', text: [fmt.dt(p.paid_at || p.created_at), p.receipt_no ? `${t('receipt')} ${p.receipt_no}` : null, p.link_token && p.status === 'pending' ? t('payment.linkOpen') : null].filter(Boolean).join(' · ') }),
        h('span', { class: 'tl-sub-sum' }, h('strong', { text: fmt.money(p.amount) }), p.refunded_amount ? h('small', { text: ` ${t('refunded')} ${fmt.money(p.refunded_amount)}` }) : null))))
      : emptyBox(t('order.noPayments'));
    const reservations = o.reservations.length
      ? h('ul', { class: 'tl-sub', 'data-testid': 'order-reservations' }, o.reservations.map((r) => h('li', {},
        h('span', { class: 'tl-sub-main' }, h('strong', { text: r.product_name || '–' }), r.status === 'cancelled' ? h('span', { class: 'badge st-cancelled', text: t('cancelled') }) : null),
        h('span', { class: 'tl-sub-meta', text: `${fmt.dt(r.starts_at)} · ${t('persons', { n: r.persons ?? 1 })}${r.addons?.length ? ' · ' + r.addons.map((a) => `${a.name} ×${a.quantity}`).join(', ') : ''}` }),
        h('span', { class: 'tl-sub-sum' }, h('strong', { text: fmt.money(r.item_total) })))))
      : emptyBox(t('order.noReservations'));
    const sum = (label, value, cls = '', tid) => h('div', { class: cls }, h('dt', { text: label }), h('dd', { 'data-testid': tid, text: value }));
    const sums = h('dl', { class: 'tl-sums' }, sum(t('order.total'), fmt.money(b.total), '', 'order-total'), sum(t('order.paid'), fmt.money(b.paid)), b.refunded ? sum(t('order.refunded'), fmt.money(b.refunded)) : null,
      b.pending_link ? sum(t('order.pendingLink'), fmt.money(b.pending_link)) : null, sum(t('order.unpaid'), fmt.money(unpaid), unpaid > 0 ? 'due' : '', 'order-unpaid'));
    const meta = h('p', { class: 'muted tl-meta', text: [o.customer.email, o.customer.phone, o.customer.business_id ? `${t('order.bid')} ${o.customer.business_id}` : null, sourceLabel(o.source_channel)].filter(Boolean).join(' · ') });
    const notes = [o.internal_note ? h('p', { class: 'tl-note', 'data-testid': 'order-note', text: `${t('order.note')}: ${o.internal_note}` }) : null,
      o.requests.some((x) => x.status === 'open') ? h('p', { class: 'tl-note', 'data-testid': 'order-cancel-request', text: t('order.cancelRequest') }) : null];

    const canRefund = api.isMock('refund') || ctx.can('payments.refund');
    const refundable = o.payments.filter((p) => ['paid', 'partially_refunded'].includes(p.status) && p.amount > p.refunded_amount);
    const addOff = !o.is_native ? t('btn.addJohku') : !o.staff_can_add ? t('btn.addClosed') : null;
    const actions = h('div', { class: 'tl-actions', 'data-testid': 'order-actions' },
      actionBtn({ api, key: 'addToOrder', label: t('btn.addToOrder'), ico: 'plus', testid: 'btn-add', extraDisabled: addOff, onClick: () => addDialog(o) }),
      actionBtn({ api, key: 'createPaymentLink', label: unpaid > 0 ? t('btn.link', { sum: fmt.money(unpaid) }) : t('btn.linkNone'), ico: 'link', testid: 'btn-link', extraDisabled: unpaid > 0 && o.is_native ? null : t('btn.linkNoneWhy'), onClick: () => linkDialog(o) }),
      actionBtn({ api, key: 'recordPayment', label: t('btn.record'), ico: 'plus', testid: 'btn-record', extraDisabled: !o.is_native ? t('btn.addJohku') : unpaid > 0 ? null : t('btn.recordNone'), onClick: () => recordDialog(o) }),
      h('button', { type: 'button', class: `btn tl-btn${o.receipts.length ? '' : ' is-off'}`, 'data-testid': 'btn-receipts', disabled: o.receipts.length ? null : true, title: o.receipts.length ? null : t('btn.noReceipts'), onclick: () => receiptsDialog(o) },
        h('span', { class: 'tl-ico', 'aria-hidden': 'true' }, icon('receipt', 20)), h('span', { text: `${t('btn.receipts')} (${o.receipts.length})` })),
      actionBtn({ api, key: 'refund', label: t('btn.refund'), ico: 'undo', testid: 'btn-refund', extraDisabled: !canRefund ? t('btn.refundNoPerm') : refundable.length ? null : t('btn.refundNone'), onClick: () => refundDialog(o, refundable) }));
    const hint = ['addToOrder', 'createPaymentLink', 'refund', 'recordPayment'].some((k) => !api.isMock(k) && !api.actionLive(k)) ? h('p', { class: 'muted tl-hint', text: t('btn.hint') }) : null;
    return h('div', { class: 'tl-detail' }, meta, ...notes, sums, sec(t('order.payments'), payments), sec(t('order.reservations'), reservations), actions, hint);
  }

  // ---- dialogit ----
  const fld = (label, ...kids) => h('label', { class: 'fld' }, h('span', { text: label }), ...kids);
  async function addDialog(o) {
    let addons = []; try { addons = await api.listAddons(); } catch { /* lisäpalveluluettelo puuttuu → vain mukautettu rivi */ }
    const en = getLang() === 'en';
    const type = h('select', { name: 'type', 'data-testid': 'add-type' }, ...(o.reservations.length && addons.length ? [h('option', { value: 'addon', text: t('add.addon') })] : []),
      h('option', { value: 'custom', text: t('add.custom'), disabled: api.isMock('addToOrder') || ctx.can('bookings.override') ? null : true }));
    const resSel = h('select', { name: 'reservation' }, o.reservations.map((r) => h('option', { value: r.reservation_id, text: `${r.product_name} · ${fmt.dt(r.starts_at)}` })));
    const addonSel = h('select', { name: 'addon' }, addons.map((a) => h('option', { value: a.code, text: `${en ? a.name_en : a.name} · ${fmt.money(a.price)}` })));
    const addonBox = h('div', { class: 'stack', 'data-testid': 'add-addon-box' }, fld(t('add.reservation'), resSel), fld(t('add.addonName'), addonSel));
    const customBox = h('div', { class: 'stack', 'data-testid': 'add-custom-box', hidden: true }, fld(t('add.desc'), h('input', { name: 'desc', maxlength: 120 })),
      fld(t('add.amount'), h('input', { name: 'amount', type: 'number', step: '0.01', inputmode: 'decimal' })),
      fld(t('add.vat'), h('select', { name: 'vat' }, VAT_CHOICES.map((v) => h('option', { value: v, text: fmt.pct(v) })))));
    const sync = () => { addonBox.hidden = type.value !== 'addon'; customBox.hidden = type.value !== 'custom'; };
    type.onchange = sync; sync();
    formDialog(t('btn.addToOrder'), [h('p', { class: 'muted', text: api.isMock('addToOrder') ? t('mock.note') : t('live.note') }), fld(t('add.what'), type), addonBox, customBox,
      fld(t('add.qty'), h('input', { name: 'qty', type: 'number', min: 1, max: 99, value: 1, inputmode: 'numeric' })),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'link' }), ` ${t('add.link')}`), h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'email' }), ` ${t('add.email')}`),
      fld(t('add.note'), h('input', { name: 'note', maxlength: 200 }))], t('add.submit'),
    async (fd) => {
      const qty = Math.max(1, Math.trunc(+fd.get('qty')) || 1);
      let item;
      if (fd.get('type') === 'custom') { const amount = +fd.get('amount'); if (!fd.get('desc')?.trim() || !Number.isFinite(amount) || amount === 0) throw new Error(t('add.badCustom')); item = { type: 'custom', description: fd.get('desc').trim(), amount, vat_rate: +fd.get('vat'), quantity: qty }; }
      else item = { type: 'addon', reservation_id: +fd.get('reservation'), code: fd.get('addon'), quantity: qty };
      const res = await api.addToOrder({ orderId: o.order_id, items: [item], createLink: fd.get('link') === 'on', sendEmail: fd.get('email') === 'on', note: fd.get('note') || null });
      doneToast(res, RPC.addToOrder); afterChange(res, o.order_id);
    });
  }
  function linkDialog(o) {
    formDialog(t('btn.linkTitle'), [h('p', { class: 'muted', text: api.isMock('createPaymentLink') ? t('mock.note') : t('live.note') }), h('p', { text: t('link.amount', { sum: fmt.money(o.balance.unpaid) }), 'data-testid': 'link-amount' }),
      fld(t('link.days'), h('input', { name: 'days', type: 'number', min: 1, max: 90, value: 14, inputmode: 'numeric' })), h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'email' }), ` ${t('link.email')}`)], t('link.submit'),
    async (fd) => {
      const res = await api.createPaymentLink({ orderId: o.order_id, sendEmail: fd.get('email') === 'on', expiresDays: Math.max(1, Math.trunc(+fd.get('days')) || 14) });
      doneToast(res, RPC.createPaymentLink); afterChange(res, o.order_id);
      const url = absLink(res.link_path, o);
      if (url) dialog(t('link.created'), h('div', { class: 'stack' }, res.mock ? h('p', { class: 'muted', text: t('mock.note') }) : null, h('input', { readonly: true, value: url, 'aria-label': t('link.created'), 'data-testid': 'link-url', onfocus: (e) => e.target.select() }),
        h('p', { class: 'muted', text: res.online_payment_enabled ? t('link.online') : t('link.onsite') })));
    });
  }
  const MANUAL = ['cash', 'card_terminal', 'mobilepay', 'bank_transfer', 'invoice', 'other'];
  function recordDialog(o) {
    const fromRefs = (ctx.refs?.methods || []).filter((m) => m.is_manual && m.active && m.code !== 'pay_later');
    const methods = fromRefs.length ? fromRefs.map((m) => ({ code: m.code, label: m.label })) : MANUAL.map((c) => ({ code: c, label: null }));
    const amount = h('input', { name: 'amount', type: 'number', step: '0.01', min: '0.01', max: o.balance.unpaid, value: o.balance.unpaid, inputmode: 'decimal', required: true, 'data-testid': 'record-amount' });
    formDialog(t('btn.recordTitle'), [h('p', { class: 'muted', text: api.isMock('recordPayment') ? t('mock.note') : t('live.note') }),
      fld(t('record.method'), h('select', { name: 'method', 'data-testid': 'record-method' }, methods.map((m) => h('option', { value: m.code, text: methodLabel(m.code, m.label) })))), fld(t('record.amount'), amount),
      fld(t('record.note'), h('input', { name: 'note', maxlength: 200 })), h('p', { class: 'muted tl-hint', text: t('record.hint') })], t('record.submit'),
    async (fd) => {
      const amt = Math.round(+fd.get('amount') * 100) / 100;
      if (!(amt > 0) || amt > o.balance.unpaid + 0.005) throw new Error(t('refund.badAmount'));
      const res = await api.recordPayment({ orderId: o.order_id, method: fd.get('method'), amount: amt, note: String(fd.get('note') || '').trim() || null });
      doneToast(res, RPC.recordPayment); afterChange(res, o.order_id);
    });
  }
  function refundDialog(o, refundable) {
    const left = (p) => Math.round((p.amount - p.refunded_amount) * 100) / 100;
    const sel = h('select', { name: 'payment', onchange: () => { amount.value = left(refundable.find((p) => String(p.payment_id) === sel.value)); amount.max = amount.value; } },
      refundable.map((p) => h('option', { value: p.payment_id, text: `${methodLabel(p.method, p.method_label)} · ${fmt.money(left(p))}` })));
    const amount = h('input', { name: 'amount', type: 'number', step: '0.01', min: '0.01', max: left(refundable[0]), value: left(refundable[0]), inputmode: 'decimal', required: true });
    formDialog(t('btn.refund'), [h('p', { class: 'muted', text: api.isMock('refund') ? t('mock.note') : t('live.note') }), fld(t('refund.payment'), sel), fld(t('refund.amount'), amount),
      fld(t('refund.reason'), h('input', { name: 'reason', required: true, maxlength: 200 })), h('p', { class: 'muted tl-hint', text: t('refund.visma') })], t('refund.submit'),
    async (fd) => {
      const amt = +fd.get('amount'), p = refundable.find((x) => String(x.payment_id) === fd.get('payment'));
      if (!(amt > 0) || amt > left(p)) throw new Error(t('refund.badAmount'));
      if (String(fd.get('reason') || '').trim().length < 3) throw new Error(t('refund.noReason'));
      const res = await api.refund({ paymentId: p.payment_id, amount: amt, reason: String(fd.get('reason')).trim() });
      doneToast(res, RPC.refund); afterChange(res, o.order_id);
    });
  }
  function receiptsDialog(o) {
    dialog(t('btn.receipts'), h('div', { class: 'stack' }, h('p', { class: 'muted', text: t('receipts.note') }), h('ul', { class: 'tl-sub', 'data-testid': 'receipts-list' }, o.receipts.map((r) => h('li', {},
      h('span', { class: 'tl-sub-main' }, h('strong', { text: r.receipt_no }), ' ', h('span', { class: 'badge', text: t(`receipt.${r.kind}`) })),
      h('span', { class: 'tl-sub-meta', text: [fmt.dt(r.issued_at), r.sent_at ? t('receipts.sent') : t('receipts.notSent')].join(' · ') }),
      h('span', { class: 'tl-sub-sum' }, h('button', { type: 'button', class: 'btn tl-btn is-off', disabled: true, title: t('receipts.pdfLater') }, h('span', { class: 'tl-ico', 'aria-hidden': 'true' }, icon('download', 20)), h('span', { text: 'PDF' }))))))));
  }

  // ---- työkalupalkki ----
  const sortSel = h('select', { 'data-testid': 'orders-sort', onchange: (e) => { st.sortBy = e.target.value; if (st.sortBy === 'payment_status') st.sortDir = 'desc'; syncDir(); change({}); } }, ORDER_SORTS.map((k) => h('option', { value: k, text: t(`sort.${k}`) })));
  const dirBtn = h('button', { type: 'button', class: 'btn ghost tl-dir', 'data-testid': 'orders-dir', onclick: () => { st.sortDir = st.sortDir === 'desc' ? 'asc' : 'desc'; syncDir(); change({}); } });
  // sopimuksessa ei ole maksutila-lajittelua: "Maksutila" = unpaid_desc (maksamattomat ensin), suunta lukittu
  const syncDir = () => { dirBtn.replaceChildren(h('span', { class: st.sortDir === 'desc' ? 'tl-down' : 'tl-up', 'aria-hidden': 'true' }, icon('chev', 20)), h('span', { class: 'tl-dirtxt', text: t(`dir.${st.sortDir}`) })); dirBtn.setAttribute('aria-label', `${t('sort.dir')}: ${t(`dir.${st.sortDir}`)}`); dirBtn.dataset.dir = st.sortDir; dirBtn.disabled = st.sortBy === 'payment_status'; };
  syncDir();
  const sortFld = h('div', { class: 'fld tl-sort' }, h('span', { text: t('sort.label') }), h('div', { class: 'tl-sortrow' }, sortSel, dirBtn));
  const reset = h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'orders-reset', onclick: () => { Object.assign(st, { search: '', paymentStatus: '', source: '', native: '', dateField: '', from: '', to: '' }); buildToolbar(); load(); } }, t('filters.reset'));
  let toolbar; buildToolbar();
  function buildToolbar() {
    const ss = searchFld(t('orders.searchPh'), 'orders-search', (v) => change({ search: v })); ss.input.value = st.search;
    const next = h('form', { class: 'tl-toolbar', role: 'search', onsubmit: (e) => e.preventDefault() }, ss.node, sortFld,
      selectFld(t('filters.pay'), 'orders-f-pay', PAY, payLabel, st.paymentStatus, (v) => change({ paymentStatus: v })),
      selectFld(t('filters.source'), 'orders-f-src', SOURCES, sourceLabel, st.source, (v) => change({ source: v })),
      selectFld(t('filters.native'), 'orders-f-native', ['native', 'imported'], (c) => t(`nat.${c}`), st.native, (v) => change({ native: v })),
      selectFld(t('filters.dateField'), 'orders-f-datefield', ['start'], (c) => t(`df.${c}`), st.dateField, (v) => change({ dateField: v }), t('df.created')),
      dateFld(t('filters.from'), 'orders-f-from', st.from, (v) => change({ from: v })), dateFld(t('filters.to'), 'orders-f-to', st.to, (v) => change({ to: v })),
      pageSizeSelect(st.limit, (n) => change({ limit: n })), reset);
    if (toolbar?.parentNode) toolbar.replaceWith(next);   // parentNode: myös ennen kuin välilehti on liitetty sivulle (syvälinkki)
    toolbar = next; return next;
  }
  sortSel.value = st.sortBy;
  const cols = h('div', { class: 'tl-cols', 'aria-hidden': 'true' }, h('span', { text: t('col.order') }), h('span', { text: t('col.created') }), h('span', { text: t('col.first') }), h('span', { class: 'r', text: t('col.sum') }), h('span', { text: t('col.status') }), h('span'));
  const node = h('div', { class: 'tl-tab', 'data-testid': 'tab-orders' }, toolbar, count, pagers[0], cols, list, pagers[1]);
  return { node, load, setSearch(q, { open = false } = {}) { st.search = q; st.offset = 0; autoOpen = open; buildToolbar(); load(); } };
}
