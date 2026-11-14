// Talous › Tilaukset: uusin ensin, haku, lajittelu, suodattimet ja PALVELINPUOLEN sivutus (12 000+ tilausta) – rivi aukeaa maksuiksi sekä varauksiksi ja ostoksiksi (./order-contents.js).
// Datan muoto: ../talous-api.js (admin_list_orders / admin_get_order). Napit (lisää, maksulinkki, maksun kirjaus, hyvitys) kutsuvat api:a; kuitit (lataus, näyttö, uudelleenlähetys): ./talous-receipts.js.
import { h, dialog, toast } from '../ui.js';
import { icon } from '../icons.js';
import { receiptsList } from './talous-receipts.js';
import { t, fmt, getLang } from '../talous-i18n.js';
import { formatWhenRange, spansDays } from '../when-range.js';
import { RPC, absLink } from '../talous-api.js';
import { redeemFields, redeemSubmit } from './talous-giftcards.js';
import { johkuBadge, SOURCES, sourceLabel, payBadge, sourceBadge, loading, emptyBox, errorBox, pager, pageSizeSelect, selectFld, dateFld, searchFld, expandRow, actionBtn, doneToast, formDialog, methodLabel, pstatBadge, linkEmailControl } from './talous-ui.js';
import { countActive, filterDrawer } from '../filter-drawer.js';
import { effectivePaymentFilters, isDefaultPaymentFilters, isUnpaidRow, normalizePaymentFilters, togglePaymentFilter, DEFAULT_PAYMENT_FILTERS, PAYMENT_FILTERS } from '../orders-filter.js';
import { orderText } from '../orders-texts.js';
import { rcText } from '../refund-cancel-texts.js';
import { yesNo, CX_KINDS } from './refund-cancel.js';
import { annualCardPanel, showAnnualCardDialog } from './annual-card-panel.js';
import { acText } from '../annual-card-texts.js';
import { orderVoucherBox } from './voucher-redeem.js';
import { visibleOrderActions } from '../order-actions-logic.js';
import { orderContentsSection } from './order-contents.js';
import { invoiceLockReason, linkStaleNote, orderInvoiceLocked } from '../addon-lock-logic.js';
import { alt } from '../addon-lock-texts.js';
import { linkDeadlineControl } from './link-deadline.js';
import { linkValidityText, linkSubmitOnce } from '../payment-link-logic.js';
import { billingMethodText } from '../billing-method-texts.js';
import { orderInvoiceCaption } from '../order-invoice-label.js';
import { isWide, stepIndex } from '../order-view-logic.js';
import { paymentRefundLeft } from '../refund-pending.js';
import { archivedBadge } from '../order-delete-logic.js';
import { deleteText } from '../order-delete-texts.js';

export const ORDER_SORTS = ['created', 'order_no', 'total', 'payment_status', 'first_reservation'];
const VAT_CHOICES = [25.5, 13.5, 0];

const annualSec = (info, sec) => { const panel = annualCardPanel(info); return panel ? h('div', { 'data-testid': 'order-annual-card' }, sec(acText('ui.admin.annual_card.title'), panel)) : null; };

// Tilausnäkymä v3 (PR 1): listan tila talteen, kun mobiilissa / "Avaa koko tilaus" siirrytään #/tilaukset/<nro>; paluussa palautetaan.
let resumeState = null;
export const takeOrdersResume = () => { const r = resumeState; resumeState = null; return r; };
export const hasOrdersResume = () => resumeState != null;

export function createOrdersTab({ api, ctx, gift = null, rpc = null, onAfterChange = null, orderView = true }) {
  let resume = onAfterChange ? null : takeOrdersResume();
  const st = { search: '', paymentFilters: [...DEFAULT_PAYMENT_FILTERS], source: '', native: '', dateField: '', from: '', to: '', sortBy: 'created', sortDir: 'desc', limit: 25, offset: 0, ...(resume?.st || {}) };
  const list = h('ul', { class: 'tl-list', 'data-testid': 'orders-list' }), count = h('p', { class: 'muted tl-count', role: 'status', 'data-testid': 'orders-count' }), pagers = [h('div'), h('div')];
  let seq = 0, reopen = null, autoOpen = false;
  // Työpöydän yhteenvetopaneeli (≥ 1200 px): rivi avaa yhteenvedon listan viereen; kapealla rivi avaa koko tilauksen.
  const viewOn = orderView && !onAfterChange && typeof document !== 'undefined' && typeof globalThis.matchMedia === 'function';
  let summary = null;
  const ensureSummary = async () => {
    if (summary) return summary;
    const { createSummaryPanel } = await import('./order-summary.js');
    summary = createSummaryPanel({ ctx, rpc: rpc || undefined, api, dialogs, onOpenFull: (m) => gotoFull(m), onClose: () => markRow(null) });
    listWrap.append(summary.node);
    return summary;
  };
  function markRow(id) {
    for (const li of list.children) { if (li.dataset) li.classList.toggle('is-selected', id != null && String(li.dataset.orderId) === String(id)); }
    listWrap.classList.toggle('has-summary', id != null);
  }
  function gotoFull(o) {
    resumeState = { st: { ...st }, scrollY: globalThis.scrollY || 0, orderId: o.order_id };
    location.hash = `#/tilaukset/${encodeURIComponent(o.order_no)}`;
  }
  async function openSummary(o) {
    const p = await ensureSummary();
    markRow(o.order_id);
    rowsNow = rowsNow.length ? rowsNow : [o];
    return p.show(o);
  }
  let rowsNow = [];
  if (viewOn) document.addEventListener('keydown', (e) => {
    if (!summary?.isOpen() || !node.isConnected || document.querySelector('dialog[open]')) return;
    if (/^(INPUT|TEXTAREA|SELECT)$/.test(e.target?.tagName || '') || e.target?.isContentEditable) return;
    if (e.key === 'Escape') { e.preventDefault(); summary.close(); return; }
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
    const i = rowsNow.findIndex((x) => String(x.order_id) === String(summary.current?.order_id));
    const j = stepIndex(i, e.key === 'ArrowDown' ? 1 : -1, rowsNow.length);
    if (j < 0 || j === i) return;
    e.preventDefault();
    openSummary(rowsNow[j]);
    list.querySelector(`[data-order-id="${rowsNow[j].order_id}"]`)?.scrollIntoView?.({ block: 'nearest' });
  });
  async function load() {
    const my = ++seq;
    if (reopen == null && summary?.isOpen()) summary.close();   // suodatin tai sivu vaihtui → yhteenveto kiinni
    list.replaceChildren(loading()); list.setAttribute('aria-busy', 'true');
    try {
      const r = await api.listOrders({ ...st, paymentFilters: effectivePaymentFilters(st) });
      if (my !== seq) return;
      list.setAttribute('aria-busy', 'false');
      if (st.offset >= r.total && r.total > 0) { st.offset = Math.max(0, Math.floor((r.total - 1) / st.limit) * st.limit); return load(); }
      count.textContent = r.total ? t('orders.count', { from: fmt.int(st.offset + 1), to: fmt.int(Math.min(st.offset + st.limit, r.total)), total: fmt.int(r.total) }) : '';
      list.replaceChildren(...(r.rows.length ? r.rows.map(orderRow) : [emptyBox(t('orders.none'))]));
      rowsNow = r.rows;
      if (summary?.isOpen()) markRow(summary.current?.order_id);
      if (resume) { const y = resume.scrollY; const back = resume.orderId; resume = null; if (y != null) globalThis.requestAnimationFrame?.(() => globalThis.scrollTo?.(0, y)); if (back != null) list.querySelector(`[data-order-id="${back}"] .tl-head`)?.focus?.({ preventScroll: true }); }
      if (reopen != null) { const hit = r.rows.find((x) => String(x.order_id) === String(reopen)); if (hit) openCard(hit); reopen = null; }
      if (autoOpen) { autoOpen = false; if (r.rows.length === 1) { const row = list.firstElementChild; if (row) { row.style.scrollMarginTop = '70px'; row.scrollIntoView({ block: 'start' }); } openCard(r.rows[0]); } }   // syvälinkki (#/talous?order=<tilausnro> tai #/tilaukset?order=): ainoa osuma avataan
      const mk = () => (r.total > st.limit ? pager({ total: r.total, offset: st.offset, limit: st.limit, onPage: (o) => { st.offset = o; load(); document.querySelector('[data-testid=orders-count]')?.scrollIntoView({ block: 'nearest' }); } }) : h('span'));
      pagers[0].replaceChildren(mk()); pagers[1].replaceChildren(mk());
    } catch (e) { if (my === seq) { list.replaceChildren(errorBox(e, load)); count.textContent = ''; pagers.forEach((p) => p.replaceChildren()); } }
  }
  // Maksutilanapit hakukentän alla (monivalinta, OR). Valittu = täysvihreä, valitsematon = valkoinen vihreällä reunuksella.
  // Kaikki valitsee vain itsensä. Kun viimeisenkin tilan ottaa pois, näytetään kaikki tilaukset ja Kaikki syttyy.
  const payBtns = PAYMENT_FILTERS.map((code) => h('button', { type: 'button', class: 'filter-chip pay-chip', 'data-testid': `orders-pay-btn-${code}`, 'data-filter': code, 'aria-pressed': 'false',
    onclick: () => change({ paymentFilters: togglePaymentFilter(st.paymentFilters, code) }) }));
  const payChips = h('div', { class: 'pay-chips', role: 'group', 'data-testid': 'orders-pay-chips' }, ...payBtns);
  const searchNote = h('p', { class: 'muted filter-search-note', 'data-testid': 'orders-search-scope', hidden: true });
  function paintPay() {
    const sel = new Set(normalizePaymentFilters(st.paymentFilters));
    payChips.setAttribute('aria-label', orderText('ui.admin.orders.pay_filter'));
    payChips.setAttribute('data-filters', [...sel].join(','));
    for (const b of payBtns) {
      const code = b.getAttribute('data-filter'), label = orderText(`ui.admin.orders.pay_${code}`);
      b.textContent = label;
      b.setAttribute('aria-pressed', sel.has(code) ? 'true' : 'false');
      b.setAttribute('aria-label', orderText('ui.admin.orders.pay_showing', { label }));
    }
    const widened = !!String(st.search || '').trim() && isDefaultPaymentFilters(st.paymentFilters);
    searchNote.hidden = !widened;
    searchNote.textContent = widened ? orderText('ui.admin.orders.search_all') : '';
  }
  const change = (patch) => { Object.assign(st, patch, { offset: 0 }); paintPay(); load(); };
  // Oikea (ei mock) kirjoitus onnistui → lista + avoin tilaus haetaan uudelleen; Maksut/Raportit-välilehdet merkitään vanhentuneiksi (api.changed)
  const afterChange = (res, orderId) => {
    if (res?.mock) return;
    if (onAfterChange) { api.changed(); onAfterChange(orderId); return; }   // koko tilausnäkymä (views/order-view.js) päivittää itse
    reopen = orderId; api.changed(); load();
  };

  // ---- rivi ----
  function orderRow(o) {
    const inv = orderInvoiceCaption(o);
    const head = [
      h('span', { class: 'tl-c tl-main' }, h('strong', { text: `#${o.order_no}` }), ' ', h('span', { class: 'tl-name', text: [o.customer_name || '–', o.customer_company].filter(Boolean).join(' · ') }),
        o.johku_order_no ? h('small', { class: 'tl-johku', text: ` Johku #${o.johku_order_no}` }) : null,
        inv ? h('small', { class: 'tl-invoice', 'data-testid': 'order-invoice', text: ` ${inv}` }) : null),
      h('span', { class: 'tl-c tl-date' }, h('small', { class: 'tl-lab', text: t('col.created') }), h('span', { text: fmt.dt(o.created_at) })),
      h('span', { class: 'tl-c tl-first' }, h('small', { class: 'tl-lab', text: t('col.first') }), h('span', { text: o.first_reservation_at ? fmt.date(o.first_reservation_at) : '–' })),
      h('span', { class: 'tl-c tl-sum' }, h('strong', { text: fmt.money(o.total_gross) })),
      h('span', { class: 'tl-c tl-badges' }, payBadge(o.payment_status), sourceBadge(o.source_channel), archivedRowBadge(o)),
    ];
    const btn = h('button', { type: 'button', class: 'tl-head', 'data-testid': 'order-head', onclick: () => openCard(o) }, head, h('span', { class: 'tl-chev', 'aria-hidden': 'true' }, icon('chev', 20)));
    const row = h('li', { class: isUnpaidRow(o) ? 'tl-row is-unpaid' : 'tl-row', 'data-testid': 'order' }, btn);
    row.dataset.orderId = o.order_id;
    return row;
  }
  function openCard(o) {
    // v3: leveällä näytöllä yhteenveto listan viereen, kapealla koko tilaus suoraan (Joonas t38u/t41u). Vanha kortti varalla.
    if (viewOn && o?.order_no != null) { if (isWide(globalThis.innerWidth || 0)) { openSummary(o).catch(() => legacyCard(o)); } else gotoFull(o); return; }
    legacyCard(o);
  }
  function legacyCard(o) {
    const canRefund = api.isMock('refund') || ctx.can('payments.refund');
    const canAdd = api.isMock('addToOrder') || ctx.can('bookings.manage');
    const flow = {
      addPurchase: (ord) => addDialog(ord || o),
      createLink: (ord) => linkDialog(ord || o),
      recordPayment: (ord) => recordDialog(ord || o),
      refund: (ord) => {
        const cur = ord || o;
        const refundable = (cur.payments || []).filter((p) => ['paid', 'partially_refunded'].includes(p.status) && paymentRefundLeft(p) > 0.004);   // keskeneräiset hyvitykset vähennetty
        if (refundable.length && canRefund) refundDialog(cur, refundable);
      },
    };
    void canAdd;
    import('./order-card.js').then(({ openOrderCard }) => openOrderCard({
      reservation: null,
      orderId: o.order_id,
      methods: ctx.refs?.methods || [],
      refs: ctx.refs,
      can: ctx.can,
      role: ctx.role,
      flow,
      onChange: () => afterChange(null, o.order_id),
    }));
  }
  // booking_279: poistettu (arkistoitu) maksamaton tilaus; myöhäinen maksu → varoitusmerkintä
  function archivedRowBadge(o) {
    const kind = archivedBadge(o);
    if (!kind) return null;
    return h('span', { class: `badge ${kind === 'late_paid' ? 'st-cancelled' : 'st-pending'}`, 'data-testid': 'order-archived-badge', 'data-kind': kind,
      text: kind === 'late_paid' ? deleteText('archived_late_paid') : deleteText('archived', { date: fmt.date(o.archived_at) }) });
  }
  // Keskeneräiset / epäonnistuneet hyvitykset (requested, processing, failed) maksun alla; MobilePay-hyvityksen voi käsitellä uudelleen (§14.4: retry_later → kutsu uudelleen, Idempotency-Key estää tuplahyvityksen)
  function openRefunds(o, p) {
    const rows = (p.refunds || []).filter((r) => ['requested', 'processing', 'failed'].includes(r.status));
    if (!rows.length) return null;
    const canRetry = (p.provider === 'mobilepay' || p.provider === 'visma_pay' || p.provider === 'montonio' || p.provider === 'checkoutx') && !api.isMock('refund') && ctx.can('payments.refund');
    return h('ul', { class: 'tl-refunds', 'data-testid': 'order-open-refunds' }, rows.map((r) => h('li', { 'data-testid': 'open-refund', 'data-status': r.status },
      h('span', { class: `badge ${r.status === 'failed' ? 'st-cancelled' : 'st-pending'}`, text: t(r.status === 'failed' ? 'refund.failed' : 'refund.pending') }), ' ', h('span', { text: `${fmt.money(r.amount)}${r.reason ? ' · ' + r.reason : ''}` }),
      canRetry && r.status !== 'failed' ? actionBtn({ key: 'refund-retry', label: t('refund.retry'), testid: 'btn-refund-retry', onClick: async () => { if (p.provider === 'visma_pay') await processVismaRefund(r.id); else if (p.provider === 'montonio') await processMontonioRefund(r.id); else if (p.provider === 'checkoutx') await processCheckoutxRefund(r.id); else await processMobilepayRefund(r.id); afterChange(null, o.order_id); } }) : null)));
  }
  async function orderDetail(id) {
    // booking_146: vuosikorttitilauksen koodi, voimassaolo ja sähköpostin tila (virhe tai puuttuva RPC → osio jää pois)
    // booking_173: kumppanin lahjakortti (koodi, arvaus vs. valinta, myyjän vaihto, Lunasta, Merkitse lunastetuksi); virhe tai puuttuva RPC → osio jää pois
    const [o, annual, vboxRaw] = await Promise.all([api.getOrder(id), api.annualCardForOrder ? api.annualCardForOrder(id).catch(() => null) : null,
      !rpc || api.isMock() ? null : orderVoucherBox({ rpc, orderId: id, onChanged: () => afterChange({}, id) }).catch(() => null)]);
    const vbox = orderInvoiceLocked(o) ? null : vboxRaw;
    const b = o.balance, unpaid = b.unpaid;
    const sec = (title, ...kids) => h('section', { class: 'tl-sec' }, h('h3', { text: title }), ...kids);
    const payments = o.payments.length
      ? h('ul', { class: 'tl-sub', 'data-testid': 'order-payments' }, o.payments.map((p) => h('li', {},
        h('span', { class: 'tl-sub-main' }, h('strong', { text: methodLabel(p.method, p.method_label) }), ' ', pstatBadge(p.status), !o.is_native ? johkuBadge() : null),   // Johku-tilauksen maksu: ei kirjanpitoon (booking_41)
        h('span', { class: 'tl-sub-meta', text: [fmt.dt(p.paid_at || p.created_at), p.receipt_no ? `${t('receipt')} ${p.receipt_no}` : null, p.link_token && p.status === 'pending' ? t('payment.linkOpen') : null].filter(Boolean).join(' · ') }),
        linkStaleNote(p, o, alt) ? h('p', { class: 'muted', 'data-testid': 'link-stale-note', text: linkStaleNote(p, o, alt) }) : null,
        h('span', { class: 'tl-sub-sum' }, h('strong', { text: fmt.money(p.amount) }), p.refunded_amount ? h('small', { text: ` ${t('refunded')} ${fmt.money(p.refunded_amount)}` }) : null),
        openRefunds(o, p))))
      : emptyBox(t(o.is_native ? 'order.noPayments' : 'order.noPaymentsJohku'));
    const sum = (label, value, cls = '', tid) => h('div', { class: cls }, h('dt', { text: label }), h('dd', { 'data-testid': tid, text: value }));
    const sums = h('dl', { class: 'tl-sums' }, sum(t('order.total'), fmt.money(b.total), '', 'order-total'), sum(t('order.paid'), fmt.money(b.paid)), b.refunded ? sum(t('order.refunded'), fmt.money(b.refunded)) : null,
      b.pending_link ? sum(t('order.pendingLink'), fmt.money(b.pending_link)) : null, sum(t('order.unpaid'), fmt.money(unpaid), unpaid > 0 ? 'due' : '', 'order-unpaid'));
    const metaBits = [o.customer.email, o.customer.phone, o.customer.business_id ? `${t('order.bid')} ${o.customer.business_id}` : null, sourceLabel(o.source_channel)].filter(Boolean).join(' · ');
    const billMethod = o.customer_kind === 'company' ? o.billing_method : null;
    const meta = h('p', { class: 'muted tl-meta', text: metaBits }, billMethod ? h('span', { 'data-testid': 'order-billing-method', text: `${metaBits ? ' · ' : ''}${billingMethodText('label')}: ${billingMethodText(billMethod)}` }) : null);
    const notes = [o.internal_note ? h('p', { class: 'tl-note', 'data-testid': 'order-note', text: `${t('order.note')}: ${o.internal_note}` }) : null,
      o.requests.some((x) => x.status === 'open') ? h('p', { class: 'tl-note', 'data-testid': 'order-cancel-request', text: t('order.cancelRequest') }) : null,
      orderInvoiceLocked(o) ? h('p', { class: 'tl-note', role: 'status', 'data-testid': 'order-invoice-lock', text: invoiceLockReason(o, alt) }) : null];

    const canRefund = api.isMock('refund') || ctx.can('payments.refund');
    const canAdd = api.isMock('addToOrder') || ctx.can('bookings.manage');
    const refundable = o.payments.filter((p) => ['paid', 'partially_refunded'].includes(p.status) && paymentRefundLeft(p) > 0.004);   // keskeneräiset hyvitykset vähennetty
    const visible = visibleOrderActions(o, { canRefund, canAdd });
    const actionFactories = {
      addToOrder: () => actionBtn({ key: 'addToOrder', label: t('btn.addToOrder'), ico: 'plus', testid: 'btn-add', onClick: () => addDialog(o) }),
      createPaymentLink: () => actionBtn({ key: 'createPaymentLink', label: t('btn.link', { sum: fmt.money(unpaid) }), ico: 'link', testid: 'btn-link', onClick: () => linkDialog(o) }),
      recordPayment: () => actionBtn({ key: 'recordPayment', label: t('btn.record'), ico: 'plus', testid: 'btn-record', onClick: () => recordDialog(o) }),
      refund: () => actionBtn({ key: 'refund', label: t('btn.refund'), ico: 'undo', testid: 'btn-refund', onClick: () => refundDialog(o, refundable) }),
    };
    const actions = visible.length
      ? h('div', { class: 'tl-actions', 'data-testid': 'order-actions' }, ...visible.map((key) => actionFactories[key]()))
      : null;
    const receipts = sec(`${t('receipts.title')} (${o.receipts.length})`, receiptsList({ api, ctx, receipts: o.receipts }));
    return h('div', { class: 'tl-detail' }, meta, ...notes, sums, annualSec(annual, sec),
      orderContentsSection(o, sec), actions, sec(t('order.payments'), payments), vbox,
      !o.is_native && !o.receipts.length ? null : receipts);   // Johku-tilaukselle ei synny kuittia (booking_41)
  }

  // booking_279: maksamattoman tilauksen poisto on yhteisessä kortissa (views/order-card-delete.js).

  // ---- dialogit ----
  const fld = (label, ...kids) => h('label', { class: 'fld' }, h('span', { text: label }), ...kids);
  async function addDialog(o) {
    if (orderInvoiceLocked(o)) { toast(invoiceLockReason(o, alt), 'warn'); return; }
    let addons = []; try { addons = await api.listAddons(); } catch { /* lisäpalveluluettelo puuttuu → vain mukautettu rivi */ }
    const vatChoices = VAT_CHOICES;
    const en = getLang() === 'en';
    const type = h('select', { name: 'type', 'data-testid': 'add-type' }, ...(o.reservations.length && addons.length ? [h('option', { value: 'addon', text: t('add.addon') })] : []),
      h('option', { value: 'custom', text: t('add.custom'), disabled: api.isMock('addToOrder') || ctx.can('bookings.override') ? null : true }));
    const resSel = h('select', { name: 'reservation' }, o.reservations.map((r) => h('option', { value: r.reservation_id, text: `${r.product_name} · ${spansDays(r.starts_at, r.ends_at) ? formatWhenRange(r.starts_at, r.ends_at, getLang()) : fmt.dt(r.starts_at)}` })));
    const addonSel = h('select', { name: 'addon' }, addons.map((a) => h('option', { value: a.code, text: `${en ? a.name_en : a.name} · ${fmt.money(a.price)}` })));
    const addonBox = h('div', { class: 'stack', 'data-testid': 'add-addon-box' }, fld(t('add.reservation'), resSel), fld(t('add.addonName'), addonSel));
    const customBox = h('div', { class: 'stack', 'data-testid': 'add-custom-box', hidden: true }, fld(t('add.desc'), h('input', { name: 'desc', maxlength: 120 })),
      fld(t('add.amount'), h('input', { name: 'amount', type: 'number', step: '0.01', inputmode: 'decimal' })),
      fld(t('add.vat'), h('select', { name: 'vat' }, vatChoices.map((v) => h('option', { value: v, text: fmt.pct(v) })))));
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
    if (orderInvoiceLocked(o)) { toast(invoiceLockReason(o, alt), 'warn'); return; }
    const deadline = linkDeadlineControl();
    const mail = linkEmailControl(o);
    formDialog(t('btn.linkTitle'), [
      h('p', { class: 'muted', text: api.isMock('createPaymentLink') ? t('mock.note') : t('live.note') }),
      h('p', { text: t('link.amount', { sum: fmt.money(o.balance.unpaid) }), 'data-testid': 'link-amount' }),
      deadline.nodes,
      mail.nodes,
    ], mail.submit, linkSubmitOnce((fd) => deadline.read(fd), async (expiresDays, sent) => {
      const sendEmail = mail.wants(sent);
      const res = await api.createPaymentLink({ orderId: o.order_id, sendEmail, expiresDays });
      mail.report(res, sendEmail, RPC.createPaymentLink); afterChange(res, o.order_id);
      const url = absLink(res.link_path, o);
      if (url) dialog(t('link.created'), h('div', { class: 'stack' },
        res.mock ? h('p', { class: 'muted', text: t('mock.note') }) : null,
        h('input', { readonly: true, value: url, 'aria-label': t('link.created'), 'data-testid': 'link-url', onfocus: (e) => e.target.select() }),
        h('p', { class: 'muted', text: linkValidityText(res, orderText, fmt.date) }),
        h('p', { class: 'muted', text: res.online_payment_enabled ? t('link.online') : t('link.onsite') })));
    }));
  }
  const MANUAL = ['card_terminal', 'mobilepay', 'bank_transfer', 'invoice', 'other'];
  function recordDialog(o) {
    if (orderInvoiceLocked(o)) { toast(invoiceLockReason(o, alt), 'warn'); return; }
    const fromRefs = (ctx.refs?.methods || []).filter((m) => m.is_manual && m.active && m.code !== 'pay_later' && m.code !== 'gift_card' && m.code !== 'cash');
    const methods = fromRefs.length ? fromRefs.map((m) => ({ code: m.code, label: m.label })) : MANUAL.map((c) => ({ code: c, label: null }));
    const amount = h('input', { name: 'amount', type: 'number', step: '0.01', min: '0.01', max: o.balance.unpaid, value: o.balance.unpaid, inputmode: 'decimal', required: true, 'data-testid': 'record-amount' });
    // Lahjakortti (sopimus §13.0): admin_record_payment hylkää gift_card-tavan → oma lunastus (admin_redeem_gift_card). Vaatii payments.manage; näkyy vain kun lahjakorttirajapinta on käytössä.
    const sel = h('select', { name: 'method', 'data-testid': 'record-method' }, methods.map((m) => h('option', { value: m.code, text: methodLabel(m.code, m.label) })), gift && ctx.can('payments.manage') ? h('option', { value: 'gift_card', text: methodLabel('gift_card') }) : null);
    const noteInput = h('input', { name: 'note', maxlength: 200 });
    // Tuntematon koodi (§13.12): oikotie maksutapaan Kumppanin lahjakortti (ei kuittia); muistiinpanoon maskattu koodi
    // booking_173: myyjäkohtainen maksutapa (Lahjakortti – Kokemuskauppa / Offerilla / Elämyslahjat), muuten vanha partner_voucher
    const usePartner = ({ note, source }) => {
      const want = [source ? `partner_voucher_${source}` : null, 'partner_voucher'].filter(Boolean);
      const opt = want.map((c) => [...sel.options].find((x) => x.value === c)).find(Boolean);
      if (!opt) { toast(t('gc.o.partnerOff'), 'warn'); return; }
      sel.value = opt.value; sync(); if (!noteInput.value) noteInput.value = note; amount.focus();
    };
    const rf = gift ? redeemFields({ gift, order: o, amountInput: amount, onPartner: usePartner }) : null;
    if (rf) rf.node.hidden = true;
    const submitBtn = () => dlg?.querySelector('button[type=submit]');
    const full = String(amount.value);
    const sync = () => {
      const g = sel.value === 'gift_card'; if (rf) rf.node.hidden = !g; hintP.hidden = g;
      amount.required = !g; if (g) { if (amount.value === full) amount.value = ''; } else if (amount.value === '') amount.value = full;   // lahjakortti: tyhjä summa = palvelin käyttää pienempää kortin saldosta ja maksamattomasta
      if (submitBtn()) submitBtn().disabled = g && (!!rf?.isOff() || !!rf?.isUnknown());
    };
    const hintP = h('p', { class: 'muted tl-hint', text: t('record.hint') });
    sel.addEventListener('change', sync); rf?.node.addEventListener('redeem-off', sync); rf?.node.addEventListener('redeem-unknown', sync);
    const dlg = formDialog(t('btn.recordTitle'), [h('p', { class: 'muted', text: api.isMock('recordPayment') ? t('mock.note') : t('live.note') }),
      fld(t('record.method'), sel), ...(rf ? [rf.node] : []), fld(t('record.amount'), amount),
      fld(t('record.note'), noteInput), hintP], t('record.submit'),
    async (fd) => {
      const amt = Math.round(+fd.get('amount') * 100) / 100;
      if (fd.get('method') === 'gift_card') {
        if (!(amt > 0) && fd.get('amount') !== '') throw new Error(t('gc.o.badAmount'));
        const res = await redeemSubmit({ gift, order: o, code: rf.code(), amount: amt > 0 ? amt : undefined, note: String(fd.get('note') || '').trim() || undefined });
        afterChange(res, o.order_id); return;
      }
      if (!(amt > 0) || amt > o.balance.unpaid + 0.005) throw new Error(t('refund.badAmount'));
      const res = await api.recordPayment({ orderId: o.order_id, method: fd.get('method'), amount: amt, note: String(fd.get('note') || '').trim() || null });
      doneToast(res, RPC.recordPayment); afterChange(res, o.order_id);
      // booking_146: maksu loi vuosikortin → koodi heti näkyviin (iso koodi, kopiointi, voimassaolo, sähköpostin tila)
      if (api.annualCardForOrder) api.annualCardForOrder(o.order_id).then((ac) => showAnnualCardDialog(ac)).catch(() => {});
    });
  }
  function refundDialog(o, refundable, { suggest = null } = {}) {
    const left = (p) => paymentRefundLeft(p);   // maksettu − hyvitetty − keskeneräiset (requested/processing); sama raja kuin admin_refund
    const initial = (p) => { const v = suggest ? suggest(p) : left(p); return v == null ? '' : v; };   // tilausnäkymä: ylisuorituksessa esitäytetään vain liikaa maksettu osuus
    const sel = h('select', { name: 'payment', onchange: () => { const p = refundable.find((x) => String(x.payment_id) === sel.value); amount.max = left(p); amount.value = initial(p); } },
      refundable.map((p) => h('option', { value: p.payment_id, text: `${methodLabel(p.method, p.method_label)} · ${fmt.money(left(p))}` })));
    const amount = h('input', { name: 'amount', type: 'number', step: '0.01', min: '0.01', max: left(refundable[0]), value: initial(refundable[0]), inputmode: 'decimal', required: true });
    // MobilePay-verkkomaksu (provider 'mobilepay'): hyvitys lähtee MobilePayhin heti (§14.4); vihje näkyy vain sille maksulle
    const mpHint = h('p', { class: 'muted tl-hint', 'data-testid': 'refund-mp-hint', text: t('refund.mobilepay') });
    const vpHint = h('p', { class: 'muted tl-hint', 'data-testid': 'refund-vp-hint', text: t('refund.visma') });
    const moHint = h('p', { class: 'muted tl-hint', 'data-testid': 'refund-mo-hint', text: t('refund.montonio') });
    const syncHint = () => {
      const prov = refundable.find((p) => String(p.payment_id) === sel.value)?.provider;
      mpHint.hidden = prov !== 'mobilepay';
      vpHint.hidden = prov !== 'visma_pay';
      moHint.hidden = prov !== 'montonio';
    };
    sel.addEventListener('change', syncHint); syncHint();
    // booking_136: perutaanko myös tilauksen varaukset? Näkyy vain, kun voimassa olevia varauksia on ja käyttäjällä on bookings.manage (palvelin tarkistaa saman). Oletus Ei.
    const active = o.reservations.filter((r) => ['pending', 'confirmed'].includes(r.status)).length;
    const cancelQ = o.is_native && active > 0 && (api.isMock('refundOrder') || ctx.can('bookings.manage'))
      ? yesNo({ name: 'cancel_reservations', testid: 'refund-cancel-res', legend: rcText('ui.admin.refund_cancel.order_question'), hint: rcText('ui.admin.refund_cancel.order_count', { count: active }),
        no: rcText('ui.admin.refund_cancel.order_no'), yes: rcText('ui.admin.refund_cancel.order_yes') }) : null;
    formDialog(t('btn.refund'), [h('p', { class: 'muted', text: api.isMock('refund') ? t('mock.note') : t('live.note') }), fld(t('refund.payment'), sel), fld(t('refund.amount'), amount),
      fld(t('refund.reason'), h('input', { name: 'reason', required: true, maxlength: 200 })), vpHint, mpHint, moHint, cancelQ ? cancelQ.node : null], t('refund.submit'),
    async (fd) => {
      const amt = +fd.get('amount'), p = refundable.find((x) => String(x.payment_id) === fd.get('payment'));
      if (!(amt > 0) || amt > left(p)) throw new Error(t('refund.badAmount'));
      if (String(fd.get('reason') || '').trim().length < 3) throw new Error(t('refund.noReason'));
      const cancelRes = fd.get('cancel_reservations') === 'yes';
      const args = { paymentId: p.payment_id, amount: amt, reason: String(fd.get('reason')).trim() };
      const res = cancelRes ? await api.refundOrder({ ...args, cancelReservations: true }) : await api.refund(args);
      doneToast(res, cancelRes ? RPC.refundOrder : RPC.refund);
      if (cancelRes && +res?.cancelled_reservations > 0) toast(rcText('ui.admin.refund_cancel.order_cancelled', { count: res.cancelled_reservations }));
      // Verkkomaksu: rivi on 'requested' → käsittely heti (käyttäjän JWT, payments.refund), tulos näkyviin
      if (res?.status === 'requested' && !res.mock && p.provider === 'mobilepay') await processMobilepayRefund(res.refund_id);
      if (res?.status === 'requested' && !res.mock && p.provider === 'visma_pay') await processVismaRefund(res.refund_id);
      if (res?.status === 'requested' && !res.mock && p.provider === 'montonio') await processMontonioRefund(res.refund_id);
      if (res?.status === 'requested' && !res.mock && p.provider === 'checkoutx') await processCheckoutxRefund(res.refund_id);
      afterChange(res, o.order_id);
    });
  }
  const MP_KINDS = { done: 'ok', failed: 'err', retry_later: 'warn', unverified: 'warn', db_error: 'warn', none: 'warn', off: 'warn', forbidden: 'err', error: 'warn' };
  const VP_KINDS = { done: 'ok', failed: 'err', retry_later: 'warn', awaiting_customer: 'warn', unverified: 'warn', db_error: 'warn', none: 'warn', off: 'warn', forbidden: 'err', error: 'warn', not_settled: 'err', not_configured: 'warn' };
  const MO_KINDS = { done: 'ok', pending: 'warn', awaiting_settlement: 'warn', failed: 'err', retry_later: 'warn', db_error: 'warn', not_configured: 'warn', none: 'warn', off: 'warn', forbidden: 'err', error: 'warn' };
  async function processMobilepayRefund(refundId) {
    const m = await api.mobilepayRefund(refundId);
    const key = `refund.mp.${m.result}`;
    toast(t(MP_KINDS[m.result] ? key : 'refund.mp.error'), MP_KINDS[m.result] || 'warn');
    return m;
  }
  async function processVismaRefund(refundId) {
    const m = await api.vismapayRefund(refundId);
    const key = VP_KINDS[m.result] ? `refund.vp.${m.result}` : 'refund.vp.error';
    toast(t(key), VP_KINDS[m.result] || 'warn');
    return m;
  }
  async function processCheckoutxRefund(refundId) {
    const m = api.checkoutxRefund ? await api.checkoutxRefund(refundId) : { result: 'none' };
    toast(t(CX_KINDS[m.result] ? `refund.cx.${m.result}` : 'refund.cx.error'), CX_KINDS[m.result] || 'warn');
    return m;
  }
  async function processMontonioRefund(refundId) {
    const m = await api.montonioRefund(refundId);
    const key = MO_KINDS[m.result] ? `refund.mo.${m.result}` : 'refund.mo.error';
    toast(t(key), MO_KINDS[m.result] || 'warn');
    return m;
  }
  // ---- työkalupalkki ----
  const sortSel = h('select', { 'data-testid': 'orders-sort', onchange: (e) => { st.sortBy = e.target.value; if (st.sortBy === 'payment_status') st.sortDir = 'desc'; syncDir(); change({}); } }, ORDER_SORTS.map((k) => h('option', { value: k, text: t(`sort.${k}`) })));
  const dirBtn = h('button', { type: 'button', class: 'btn ghost tl-dir', 'data-testid': 'orders-dir', onclick: () => { st.sortDir = st.sortDir === 'desc' ? 'asc' : 'desc'; syncDir(); change({}); } });
  // sopimuksessa ei ole maksutila-lajittelua: "Maksutila" = unpaid_desc (maksamattomat ensin), suunta lukittu
  const syncDir = () => { dirBtn.replaceChildren(h('span', { class: st.sortDir === 'desc' ? 'tl-down' : 'tl-up', 'aria-hidden': 'true' }, icon('chev', 20)), h('span', { class: 'tl-dirtxt', text: t(`dir.${st.sortDir}`) })); dirBtn.setAttribute('aria-label', `${t('sort.dir')}: ${t(`dir.${st.sortDir}`)}`); dirBtn.dataset.dir = st.sortDir; dirBtn.disabled = st.sortBy === 'payment_status'; };
  syncDir();
  const sortFld = h('div', { class: 'fld tl-sort' }, h('span', { text: t('sort.label') }), h('div', { class: 'tl-sortrow' }, sortSel, dirBtn));
  const reset = h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'orders-reset', onclick: () => { Object.assign(st, { search: '', paymentFilters: [...DEFAULT_PAYMENT_FILTERS], source: '', native: '', dateField: '', from: '', to: '' }); paintPay(); buildToolbar(); load(); } }, t('filters.reset'));
  let toolbar; buildToolbar();
  function buildToolbar() {
    const ss = searchFld(t('orders.searchPh'), 'orders-search', (v) => change({ search: v })); ss.input.value = st.search;
    const drawer = filterDrawer({
      search: ss.node,
      status: [payChips, searchNote],
      testid: 'orders-filters',
      className: 'orders-drawer',
      activeCount: () => countActive(st, { source: '', native: '', dateField: '', from: '', to: '', sortBy: 'created', sortDir: 'desc', limit: 25 }),
      filters: [sortFld,
        selectFld(t('filters.source'), 'orders-f-src', SOURCES, sourceLabel, st.source, (v) => change({ source: v })),
        selectFld(t('filters.native'), 'orders-f-native', ['native', 'imported'], (c) => t(`nat.${c}`), st.native, (v) => change({ native: v })),
        selectFld(t('filters.dateField'), 'orders-f-datefield', ['start'], (c) => t(`df.${c}`), st.dateField, (v) => change({ dateField: v }), t('df.created')),
        dateFld(t('filters.from'), 'orders-f-from', st.from, (v) => change({ from: v })), dateFld(t('filters.to'), 'orders-f-to', st.to, (v) => change({ to: v })),
        pageSizeSelect(st.limit, (n) => change({ limit: n })), reset],
    });
    const next = h('form', { class: 'tl-toolbar', role: 'search', onsubmit: (e) => e.preventDefault() }, drawer.node);
    if (toolbar?.parentNode) toolbar.replaceWith(next);   // parentNode: myös ennen kuin välilehti on liitetty sivulle (syvälinkki)
    toolbar = next; paintPay(); return next;
  }
  sortSel.value = st.sortBy;
  const cols = h('div', { class: 'tl-cols', 'aria-hidden': 'true' }, h('span', { text: t('col.order') }), h('span', { text: t('col.created') }), h('span', { text: t('col.first') }), h('span', { class: 'r', text: t('col.sum') }), h('span', { text: t('col.status') }), h('span'));
  const listWrap = h('div', { class: 'ov-listwrap' }, h('div', { class: 'ov-listcol' }, cols, list, pagers[1]));
  const node = h('div', { class: 'tl-tab', 'data-testid': 'tab-orders' }, toolbar, count, pagers[0], listWrap);
  // v3: koko tilausnäkymä käyttää samoja dialogeja (lisäosto, maksulinkki, maksun kirjaus lahjakortteineen, hyvitys).
  const dialogs = {
    add: (o) => addDialog(o), link: (o) => linkDialog(o), record: (o) => recordDialog(o),
    refund: (o, refundable, opts) => { if (refundable?.length && (api.isMock('refund') || ctx.can('payments.refund'))) refundDialog(o, refundable, opts); },
  };
  return { node, load, dialogs, setSearch(q, { open = false } = {}) { st.search = q; st.offset = 0; autoOpen = open; buildToolbar(); load(); } };
}
