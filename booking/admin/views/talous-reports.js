// Talous › Raportit: yksi raportti kerrallaan. Jakso on yhteinen.
import { h, toast, errMsg, todayHel, addDays } from '../ui.js';
import { icon } from '../icons.js';
import { t, fmt, has } from '../talous-i18n.js';
import { downloadCsv } from '../csv.js';
import { methodLabel, loading, emptyBox, errorBox } from './talous-ui.js';
import { TEXTS } from '../talous-texts.js';
import { reportText as rt } from '../reports-texts.js';
import { accrualText as at } from '../accrual-texts.js';

const REPORTS = ['sales', 'service', 'giftcards', 'invoices', 'methods', 'fees', 'transactions', 'refunds', 'stats'];
const DAY_ONLY = new Set(['sales', 'methods']);

function monthBounds(ym) {
  const [y, m] = ym.split('-').map(Number);
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  const mm = String(m).padStart(2, '0');
  return { from: `${y}-${mm}-01`, to: `${y}-${mm}-${String(last).padStart(2, '0')}` };
}
function shiftMonth(ym, delta) {
  const [y, m] = ym.split('-').map(Number);
  const d = new Date(Date.UTC(y, m - 1 + delta, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
}
function isFullMonth(from, to) {
  if (!from || from.slice(8) !== '01') return false;
  return monthBounds(from.slice(0, 7)).to === to;
}
function saveBlob(filename, blob) {
  const url = URL.createObjectURL(blob);
  const a = h('a', { href: url, download: filename });
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30000);
}
function hashQuery() {
  return new URLSearchParams((location.hash || '').split('?')[1] || '');
}

export function createReportsTab({ api, canFull = true, ctx = null }) {
  const today = todayHel();
  const q0 = hashQuery();
  let from0 = /^\d{4}-\d{2}-\d{2}$/.test(q0.get('from') || '') ? q0.get('from') : today;
  let to0 = /^\d{4}-\d{2}-\d{2}$/.test(q0.get('to') || '') ? q0.get('to') : from0;
  if (to0 < from0) to0 = from0;
  let report0 = REPORTS.includes(q0.get('r')) ? q0.get('r') : 'sales';
  if (!canFull && !DAY_ONLY.has(report0)) report0 = 'sales';
  if (!canFull) { from0 = to0 = from0 === to0 ? from0 : today; }
  const mode0 = from0 === to0 ? 'day' : isFullMonth(from0, to0) ? 'month' : 'range';
  const st = { report: report0, mode: canFull ? mode0 : 'day', date: from0 === to0 ? from0 : today, year: +from0.slice(0, 4), month: +from0.slice(5, 7), from: from0, to: to0, gc: 'open' };
  const out = h('div', { class: 'tl-report', 'data-testid': 'report-out' });
  let seq = 0, current = null;
  const canRefunds = !!ctx?.can?.('bookings.manage') || ctx?.role === 'admin';
  const spanOf = () => (st.mode === 'day' ? { from: st.date, to: st.date } : st.mode === 'month' ? monthBounds(`${st.year}-${String(st.month).padStart(2, '0')}`) : { from: st.from, to: st.to });
  const basisKey = () => (st.report === 'service' ? 'ui.admin.reports.basis_service' : st.report === 'giftcards' ? 'ui.admin.reports.basis_giftcards' : st.report === 'invoices' ? 'ui.admin.reports.basis_invoices' : 'ui.admin.reports.basis_document');
  const titleKey = () => `ui.admin.reports.r_${st.report === 'service' ? 'service' : st.report}`;
  function writeHash() {
    const span = spanOf();
    const q = hashQuery();
    q.set('tab', 'reports'); q.set('r', st.report); q.set('from', span.from); q.set('to', span.to);
    const next = `#/talous?${q.toString()}`;
    if (location.hash !== next) history.replaceState(null, '', next);
  }
  function fileStem() {
    const s = spanOf();
    const day = s.from === s.to;
    const range = day ? s.from : `${s.from}_${s.to}`;
    if (st.report === 'sales') return day ? `myynti_${s.from}` : `myynti_${s.from}_${s.to}`;
    if (st.report === 'methods') return `maksutavat_${range}`;
    if (st.report === 'service') return `palvelupaiva_${s.from}_${s.to}`;
    if (st.report === 'giftcards') return `lahjakortit_${s.to}_${st.gc}`;
    if (st.report === 'fees') return `palkkiot_${s.from}_${s.to}`;
    if (st.report === 'transactions') return `tapahtumat_${s.from}_${s.to}`;
    if (st.report === 'invoices') return `laskut_${s.from}_${s.to}`;
    return `tilastot_${s.from}_${s.to}`;
  }
  const sum = (rows, k) => rows.reduce((s, x) => s + Number(x[k] || 0), 0);
  const qtyTxt = (n) => Math.abs(n - Math.round(n)) < 0.001 ? fmt.int(n) : String(Math.round(n * 100) / 100).replace('.', ',');
  function table(testid, caption, cols, rows, foot) {
    return h('section', { class: 'tl-sec' }, h('h3', { text: caption }), h('table', { class: 'tl-table', 'data-testid': testid },
      h('thead', {}, h('tr', {}, cols.map((c, i) => h('th', { scope: 'col', class: i ? 'r' : '', text: c })))),
      h('tbody', {}, rows.map((row) => h('tr', {}, row.map((c, i) => h(i ? 'td' : 'th', i ? { class: 'r', 'data-label': cols[i], text: c } : { scope: 'row', text: c }))))),
      foot ? h('tfoot', {}, h('tr', {}, foot.map((c, i) => h(i ? 'td' : 'th', i ? { class: 'r', text: c } : { scope: 'row', text: c })))) : null));
  }
  function frame(body) {
    const s = spanOf();
    const when = st.mode === 'day' ? fmt.date(s.from) : st.mode === 'month' ? fmt.month(s.from.slice(0, 7)) : `${fmt.date(s.from)} – ${fmt.date(s.to)}`;
    return h('div', {}, h('header', { class: 'tl-report-head' }, h('h2', { 'data-testid': 'report-title', text: `${rt(titleKey())}: ${when}` }), h('p', { class: 'muted', 'data-testid': 'r-basis-line', text: rt(basisKey()) })), body);
  }
  function salesView(r) {
    const M = fmt.money, T = r.totals || {};
    const card = (label, value, tid) => h('div', { class: 'tl-stat' }, h('dt', { text: label }), h('dd', { 'data-testid': tid, text: value }));
    const stats = h('dl', { class: 'tl-stats' }, card(t('r.gross'), M(T.gross), 'r-gross'), card(t('r.refunds'), M(T.refunds_gross), 'r-refunds'), card(t('r.grossAfter'), M(T.gross_after_refunds), 'r-gross-after'), card(t('r.vatAfter'), M(T.vat_after_refunds), 'r-vat'), card(t('r.netExVat'), M(T.net_ex_vat_after_refunds), 'r-net-ex-vat'), card(rt('ui.admin.reports.sales_count'), fmt.int(T.receipts), 'r-receipts'), card(rt('ui.admin.reports.refund_count'), fmt.int(T.refund_receipts), 'r-refund-receipts'));
    const cols = [rt('ui.admin.reports.col_product'), rt('ui.admin.reports.col_count'), rt('ui.admin.reports.col_net'), rt('ui.admin.reports.col_gross'), rt('ui.admin.reports.col_vat_eur'), rt('ui.admin.reports.col_vat_pct')];
    const moneyRow = (p) => [p.product, qtyTxt(p.quantity), M(p.net), M(p.gross), M(p.vat), fmt.pct(p.rate)];
    const moneyFoot = (rows) => [rt('ui.admin.reports.total'), qtyTxt(sum(rows, 'quantity')), M(sum(rows, 'net')), M(sum(rows, 'gross')), M(sum(rows, 'vat')), ''];
    const products = r.by_product?.length ? table('r-by-product', rt('ui.admin.reports.by_product'), cols, r.by_product.map(moneyRow), moneyFoot(r.by_product)) : h('section', { class: 'tl-sec', 'data-testid': 'r-by-product' }, h('h3', { text: rt('ui.admin.reports.by_product') }), emptyBox(t('r.empty')));
    const refunds = r.refunds_by_product?.length ? table('r-refunds-product', rt('ui.admin.reports.refunds_by_product'), cols, r.refunds_by_product.map(moneyRow), moneyFoot(r.refunds_by_product)) : h('section', { class: 'tl-sec', 'data-testid': 'r-refunds-product' }, h('h3', { text: rt('ui.admin.reports.refunds_by_product') }), h('p', { class: 'muted', text: rt('ui.admin.reports.no_refunds') }));
    const vatCols = [rt('ui.admin.reports.col_vat_pct'), rt('ui.admin.reports.col_net'), rt('ui.admin.reports.col_gross'), rt('ui.admin.reports.col_vat_eur')];
    const vatTable = (id, title, rows) => table(id, title, vatCols, (rows || []).map((v) => [fmt.pct(v.rate), M(v.net), M(v.gross), M(v.vat)]), [rt('ui.admin.reports.total'), M(sum(rows || [], 'net')), M(sum(rows || [], 'gross')), M(sum(rows || [], 'vat'))]);
    const sold = r.gift_card_period?.sold || { lines: [], count: 0, net: 0, vat: 0, gross: 0 };
    const gc = h('section', { class: 'tl-sec', 'data-testid': 'r-gc-summary' }, h('h3', { text: rt('ui.admin.reports.gc_summary_title') }), table('r-gc-sold', rt('ui.admin.reports.gc_sold'), [rt('ui.admin.reports.col_product'), rt('ui.admin.reports.col_count'), rt('ui.admin.reports.col_gross')], (sold.lines || []).map((p) => [p.product, qtyTxt(p.quantity), M(p.gross)]), [rt('ui.admin.reports.total'), qtyTxt(sold.count || 0), M(sold.gross || 0)]), h('p', { class: 'muted', text: rt('ui.admin.reports.gc_multi_note') }));
    const rec = r.reconciliation;
    const recBlock = rec ? table('r-reconcile', rt('ui.admin.reports.reconcile'), [rt('ui.admin.reports.reconcile'), rt('ui.admin.reports.col_gross')], [[rt('ui.admin.reports.reconcile_sales'), M(rec.sales_gross)], [rt('ui.admin.reports.reconcile_refunds'), M(rec.refunds_gross)], [rt('ui.admin.reports.reconcile_products'), M(rec.product_gross)], ...(Math.abs(rec.vat_rounding) >= 0.005 ? [[rt('ui.admin.reports.rounding_row'), M(rec.vat_rounding)]] : [])]) : null;
    const byDay = r.by_day?.length ? table('r-daily', t('r.dailyBreakdown'), [t('r.date'), rt('ui.admin.reports.sales_count'), t('r.gross'), t('r.refunds')], r.by_day.map((d) => [fmt.date(d.date), fmt.int(d.receipts), M(d.gross), M(d.refunds)])) : null;
    return frame(h('div', {}, stats, products, refunds, h('div', { 'data-testid': 'r-vat-breakdown' }, vatTable('r-vat-sales', rt('ui.admin.reports.vat_sales'), r.by_vat_sales), vatTable('r-vat-refunds', rt('ui.admin.reports.vat_refunds'), r.by_vat_refunds), vatTable('r-by-vat', rt('ui.admin.reports.vat_net'), r.by_vat)), gc, recBlock, byDay));
  }
  function methodsView(r) {
    const M = fmt.money, T = r.totals || {};
    const methods = r.by_method || [];
    const rates = [...(r.by_vat || [])].sort((a, b) => a.rate - b.rate);
    const cell = (m, rate) => (r.by_method_vat || []).find((x) => x.method === m && x.rate === rate);
    const byMethod = table('r-by-method', t('r.byMethod'), [t('col.method'), t('r.payments'), t('r.gross'), t('r.refunds'), rt('ui.admin.reports.col_net')], methods.map((m) => [methodLabel(m.method, m.label), fmt.int(m.payments), M(m.gross), M(m.refunds), M((m.gross || 0) + (m.refunds || 0))]), [t('line.total'), fmt.int(sum(methods, 'payments')), M(sum(methods, 'gross')), M(sum(methods, 'refunds')), M(sum(methods, 'gross') + sum(methods, 'refunds'))]);
    const matrix = table('r-matrix', t('r.matrix'), [t('col.method'), ...rates.map((x) => `${t('r.vatShort')} ${fmt.pct(x.rate)}`), t('line.total')], methods.map((m) => [methodLabel(m.method, m.label), ...rates.map((v) => { const c = cell(m.method, v.rate); return c ? M(c.gross) : '–'; }), M((r.by_method_vat || []).filter((x) => x.method === m.method).reduce((s, x) => s + x.gross, 0))]), [t('line.total'), ...rates.map((v) => M(v.gross)), M(sum(rates, 'gross'))]);
    const rec = r.reconciliation || {};
    const gcRed = rec.gift_card_redemptions ?? methods.filter((m) => m.method === 'gift_card').reduce((s, m) => s + m.gross + m.refunds, 0);
    const gcSales = rec.gift_card_sales || 0;
    const invoiced = rec.invoiced || 0;
    const money = rec.money_received ?? (sum(methods, 'gross') + sum(methods, 'refunds') - gcRed);
    const expected = rec.expected ?? ((T.gross_after_refunds || 0) - gcRed + gcSales);
    const diff = rec.methods_difference ?? (money - expected);
    const ok = Math.abs(diff) < 0.005;
    const recon = table('r-methods-reconcile', rt('ui.admin.reports.reconcile'), [rt('ui.admin.reports.reconcile'), rt('ui.admin.reports.col_gross')], [
      [rt('ui.admin.reports.money_received'), M(money)],
      [rt('ui.admin.reports.pdf_after'), M(T.gross_after_refunds)],
      [rt('ui.admin.reports.gc_redemptions_row'), M(gcRed)],
      [rt('ui.admin.reports.gc_sales_row'), M(gcSales)],
      [rt('ui.admin.reports.invoiced_line'), M(invoiced)],
      [rt('ui.admin.reports.reconcile_diff'), ok ? `${M(diff)} · ${rt('ui.admin.reports.reconcile_ok')}` : M(diff)],
    ]);
    const opens = r.open?.rows || [];
    const openTable = opens.length ? table('r-open', rt('ui.admin.reports.open_title'), [rt('ui.admin.reports.col_voucher'), rt('ui.admin.reports.col_date'), rt('ui.admin.reports.col_customer'), rt('ui.admin.reports.col_product'), rt('ui.admin.reports.col_gross')], opens.map((x) => [x.voucher, x.date ? fmt.date(x.date) : '', x.customer || '', x.product || '', M(x.gross)])) : h('section', { class: 'tl-sec', 'data-testid': 'r-open' }, h('h3', { text: rt('ui.admin.reports.open_title') }), h('p', { class: 'muted', text: rt('ui.admin.reports.open_help') }));
    return frame(h('div', {}, matrix, byMethod, recon, ok ? null : h('p', { class: 'muted', 'data-testid': 'r-methods-diff-help', text: rt('ui.admin.reports.methods_diff_help') }), h('p', { class: 'muted', text: rt('ui.admin.reports.methods_formula') }), openTable));
  }
  function serviceView(r) {
    const M = fmt.money, T = r.totals || {};
    const cols = [at('ui.admin.accrual.col_product'), at('ui.admin.accrual.col_count'), at('ui.admin.accrual.col_net'), at('ui.admin.accrual.col_gross'), at('ui.admin.accrual.col_vat_eur'), at('ui.admin.accrual.col_vat_pct')];
    const moneyRow = (p) => [p.product, qtyTxt(p.quantity), M(p.net), M(p.gross), M(p.vat), fmt.pct(p.rate)];
    const sales = r.sales_by_product || [], refunds = r.refunds_by_product || [];
    const adv = r.advances || {}, svc = adv.services || {}, gc = adv.gift_cards_unused || {};
    return frame(h('div', { 'data-testid': 'accrual-report' },
      h('dl', { class: 'tl-stats' }, h('div', { class: 'tl-stat' }, h('dt', { text: at('ui.admin.accrual.col_gross') }), h('dd', { 'data-testid': 'accrual-gross', text: M(T.gross) })), h('div', { class: 'tl-stat' }, h('dt', { text: at('ui.admin.accrual.refunds') }), h('dd', { 'data-testid': 'accrual-refunds', text: M(T.refunds_gross) }))),
      sales.length ? table('accrual-sales', at('ui.admin.accrual.sales'), cols, sales.map(moneyRow)) : h('section', { 'data-testid': 'accrual-sales' }, emptyBox(at('ui.admin.accrual.empty'))),
      refunds.length ? table('accrual-refunds', at('ui.admin.accrual.refunds'), cols, refunds.map(moneyRow)) : h('p', { class: 'muted', 'data-testid': 'accrual-refunds', text: at('ui.admin.accrual.no_refunds') }),
      h('section', { class: 'tl-sec', 'data-testid': 'accrual-advances' }, h('h3', { text: at('ui.admin.accrual.advances') }), h('p', { 'data-testid': 'accrual-advance-gross', text: `${at('ui.admin.accrual.advances_services')}: ${M(svc.gross || 0)}` }), h('p', { 'data-testid': 'accrual-giftcards', text: `${qtyTxt(gc.count || 0)} · ${M(gc.gross || 0)}` }), h('p', { 'data-testid': 'accrual-advance-total', text: `${at('ui.admin.accrual.advances_total')}: ${M(adv.total_gross || 0)}` }))));
  }
  function giftView(r) {
    const M = fmt.money;
    const roll = r.balance || {};
    const keys = ['native_paid'];
    const rows = keys.map((key) => {
      const b = roll[key] || {};
      return [rt('ui.admin.reports.gc_bucket_own'), M(b.opening || 0), M(b.sold || 0), M(b.redeemed || 0), M(b.expired || 0), M(b.closing || 0)];
    });
    const own = r.own?.rows || [];
    return frame(h('div', {}, table('r-gc-balance', rt('ui.admin.reports.gc_open_title'), [rt('ui.admin.reports.col_product'), rt('ui.admin.reports.gc_opening'), rt('ui.admin.reports.gc_sold_period'), rt('ui.admin.reports.gc_redeemed_period'), rt('ui.admin.reports.gc_expired'), rt('ui.admin.reports.gc_closing')], rows), h('section', { class: 'tl-sec', 'data-testid': 'r-gc-own' }, h('h3', { text: rt('ui.admin.reports.gc_own') }), own.length ? h('p', { class: 'muted', text: rt('ui.admin.reports.gc_count', { n: fmt.int(own.length) }) }) : emptyBox(t('r.empty')))));
  }
  function invoiceView(r) {
    const M = fmt.money;
    const cols = [rt('ui.admin.reports.inv_no'), rt('ui.admin.reports.col_customer'), rt('ui.admin.reports.col_date'), rt('ui.admin.reports.inv_due'), rt('ui.admin.reports.col_net'), rt('ui.admin.reports.col_vat_pct'), rt('ui.admin.reports.col_vat_eur'), rt('ui.admin.reports.col_gross'), rt('ui.admin.reports.col_status'), rt('ui.admin.reports.inv_paid')];
    const status = (s) => rt(`ui.admin.reports.inv_status_${s}`);
    const vatRates = (x) => (x.vat_breakdown || []).map((v) => fmt.pct(v.rate)).join(', ');
    const paid = (x) => x.paid_at ? fmt.date(String(x.paid_at).slice(0, 10)) : '';
    const line = (x) => [x.invoice_no, x.customer, x.invoice_date ? fmt.date(x.invoice_date) : '', x.due_date ? fmt.date(x.due_date) : '', M(x.net), vatRates(x), M(x.vat), M(x.gross), status(x.status), paid(x)];
    return frame(h('div', { 'data-testid': 'r-invoices' }, table('r-inv-table', rt('ui.admin.reports.r_invoices'), cols, (r.invoices || []).map(line)), h('h3', { text: rt('ui.admin.reports.inv_credits') }), table('r-inv-credits', rt('ui.admin.reports.inv_credits'), cols, (r.credits || []).map(line))));
  }
  function txView(r) {
    const M = fmt.money;
    const rows = r.rows || [];
    const cols = [rt('ui.admin.reports.col_voucher'), rt('ui.admin.reports.col_date'), rt('ui.admin.reports.col_customer'), rt('ui.admin.reports.col_product'), rt('ui.admin.reports.col_qty'), rt('ui.admin.reports.col_net'), rt('ui.admin.reports.col_vat_pct'), rt('ui.admin.reports.col_vat_eur'), rt('ui.admin.reports.col_gross'), rt('ui.admin.reports.col_method'), rt('ui.admin.reports.col_status'), rt('ui.admin.reports.col_kind')];
    const kindLabel = (k) => k === 'refund' ? rt('ui.admin.reports.kind_refund') : k === 'redemption' ? rt('ui.admin.reports.kind_redemption') : rt('ui.admin.reports.kind_sale');
    const counted = rows.filter((x) => x.status !== 'open' && x.kind !== 'redemption');
    const sales = sum(counted.filter((x) => x.kind === 'sale'), 'gross');
    const refunds = sum(counted.filter((x) => x.kind === 'refund'), 'gross');
    const body = rows.map((x) => h('tr', { 'data-excluded': x.status === 'open' || x.kind === 'redemption' ? 'true' : null }, [x.voucher, x.date ? fmt.date(x.date) : '', x.customer, x.product, qtyTxt(x.quantity), M(x.net), fmt.pct(x.vat_rate), M(x.vat), M(x.gross), x.method_label || x.method, x.status === 'open' ? rt('ui.admin.reports.status_open') : rt('ui.admin.reports.status_paid'), kindLabel(x.kind)].map((c, i) => h(i ? 'td' : 'th', i ? { class: 'r', text: c } : { scope: 'row', text: c }))));
    return frame(h('div', {}, h('table', { class: 'tl-table', 'data-testid': 'r-tx-table' }, h('thead', {}, h('tr', {}, cols.map((c) => h('th', { scope: 'col', text: c })))), h('tbody', {}, body), h('tfoot', {}, h('tr', {}, h('th', { text: rt('ui.admin.reports.tx_sum_sales') }), h('td', { class: 'r', text: M(sales) })), h('tr', {}, h('th', { text: rt('ui.admin.reports.tx_sum_refunds') }), h('td', { class: 'r', text: M(refunds) })), h('tr', {}, h('th', { text: rt('ui.admin.reports.tx_sum_net') }), h('td', { class: 'r', 'data-testid': 'r-tx-net', text: M(sales + refunds) }))), h('p', { class: 'muted', text: rt('ui.admin.reports.tx_excluded_note') })));
  }
  function statsView(r) {
    const M = fmt.money, j = r.statistics?.johku;
    const block = j ? h('section', { class: 'tl-johku-block tl-noprint', 'data-testid': 'r-johku' }, h('h3', { text: t('r.johku.title') }), h('p', { class: 'muted tl-johku-note', text: t('r.johku.note') }), h('dl', { class: 'tl-stats' }, h('div', { class: 'tl-stat' }, h('dt', { text: t('r.johku.sales') }), h('dd', { 'data-testid': 'rj-gross', text: M(j.gross) }), h('small', { class: 'muted', 'data-testid': 'rj-gross-n', text: t('r.johku.perOrders', { n: fmt.int(j.orders) }) })), h('div', { class: 'tl-stat' }, h('dt', { text: t('r.johku.refunded') }), h('dd', { 'data-testid': 'rj-refunded', text: M(j.refunded_gross) }), h('small', { class: 'muted', 'data-testid': 'rj-refunded-n', text: t('r.johku.perOrders', { n: fmt.int(j.refunded_orders) }) })))) : null;
    const cats = new Map();
    for (const c of r.by_category || []) { const x = cats.get(c.category) || { label: c.label || c.category, quantity: 0, gross: 0 }; x.quantity += c.quantity; x.gross += c.gross; cats.set(c.category, x); }
    const johkuGc = r.gift_card_period?.open?.johku || {};
    const comp = r.gift_card_period?.complimentary || {};
    if (block && j.by_method?.length) block.append(h('table', { class: 'tl-table', 'data-testid': 'rj-by-method' }, h('tbody', {}, j.by_method.map((m) => h('tr', {}, h('td', { text: m.method || '' }), h('td', { class: 'r', text: M(m.gross) }))))));
    return frame(h('div', {}, h('p', { class: 'muted', 'data-testid': 'r-stats-note', text: rt('ui.admin.reports.stats_note') }), block, table('r-by-group', t('r.byGroup'), [t('r.group'), t('r.qty'), t('r.gross')], [...cats.values()].map((x) => [x.label, fmt.int(x.quantity), M(x.gross)])), h('p', { 'data-testid': 'r-gc-comp-stats', text: `${rt('ui.admin.reports.gc_comp_stats')}: ${fmt.int(comp.issued_count || 0)}` }), h('p', { text: `${rt('ui.admin.reports.gc_bucket_johku')}: ${M(johkuGc.closing || 0)}` })));
  }
  function feeView(r) {
    const M = fmt.money;
    const cols = [rt('ui.admin.reports.fee_col_provider'), rt('ui.admin.reports.fee_col_method'), rt('ui.admin.reports.fee_col_count'), rt('ui.admin.reports.fee_col_gross'), rt('ui.admin.reports.fee_col_fee')];
    const rowsOf = (dir) => (r.rows || []).filter((x) => x.direction === dir).map((x) => [x.provider_label || x.provider, x.method_label || x.method, fmt.int(x.count), M(x.gross), x.fee == null ? '–' : M(x.fee)]);
    return frame(h('div', { 'data-testid': 'r-fees' }, table('r-fees-sales', rt('ui.admin.reports.fee_sales'), cols, rowsOf('sale')), table('r-fees-refunds', rt('ui.admin.reports.fee_refunds'), cols, rowsOf('refund')), h('p', { 'data-testid': 'r-fees-body', text: r.totals?.settlement == null ? rt('ui.admin.reports.fee_missing_note') : `${rt('ui.admin.reports.fee_settlement')}: ${M(r.totals.settlement)}` })));
  }
  function render(data) {
    if (st.report === 'methods') return methodsView(data);
    if (st.report === 'service') return serviceView(data);
    if (st.report === 'giftcards') return giftView(data);
    if (st.report === 'invoices') return invoiceView(data);
    if (st.report === 'transactions') return txView(data);
    if (st.report === 'stats') return statsView(data);
    if (st.report === 'fees') return data ? feeView(data) : h('p', { class: 'muted', text: rt('ui.admin.reports.fee_unavailable') });
    return salesView(data);
  }
  async function load() {
    writeHash();
    const my = ++seq; current = null;
    pdfBtn.disabled = true; csvBtn.disabled = true;
    out.replaceChildren(loading());
    const span = spanOf();
    try {
      let data;
      if (st.report === 'service') data = await api.reportAccrual(span.from, span.to);
      else if (st.report === 'giftcards') data = await api.reportGiftCards(st.gc, 'json', span.from, span.to);
      else if (st.report === 'fees') data = canFull ? await api.reportProviderFees(span.from, span.to) : null;
      else if (st.report === 'transactions') data = await api.reportTransactions(span.from, span.to);
      else if (st.report === 'invoices') data = await api.reportInvoices(span.from, span.to);
      else if (st.mode === 'day') data = await api.reportDaily(span.from);
      else if (st.mode === 'month') data = await api.reportMonthly(`${st.year}-${String(st.month).padStart(2, '0')}`);
      else data = await api.reportRange(span.from, span.to);
      if (my !== seq) return;
      current = data;
      pdfBtn.disabled = !data && st.report === 'fees';
      csvBtn.disabled = !canFull || !data;
      out.replaceChildren(render(data));
    } catch (e) { if (my === seq) out.replaceChildren(errorBox(e, load)); }
  }
  function setReport(id) {
    if (!canFull && !DAY_ONLY.has(id)) return;
    st.report = id;
    for (const b of picker.querySelectorAll('[data-report]')) b.setAttribute('aria-checked', String(b.dataset.report === id));
    gcFilter.hidden = id !== 'giftcards';
    load();
  }
  function setMode(mode) {
    if (!canFull && mode !== 'day') return;
    st.mode = mode;
    for (const k of ['day', 'month', 'range']) kindBtns[k].setAttribute('aria-checked', String(st.mode === k));
    dayFld.hidden = mode !== 'day'; monFld.hidden = mode !== 'month'; rangeFld.hidden = mode !== 'range';
    quickDay.hidden = mode !== 'day'; quickMonth.hidden = mode !== 'month';
    load();
  }
  function shift(delta) {
    if (st.mode === 'day') { const next = addDays(st.date, delta); if (next > today) return; st.date = next; dateIn.value = next; }
    else if (st.mode === 'month') { const ym = shiftMonth(`${st.year}-${String(st.month).padStart(2, '0')}`, delta); st.year = +ym.slice(0, 4); st.month = +ym.slice(5); monthSel.value = String(st.month); yearSel.value = String(st.year); }
    else { const len = Math.round((new Date(st.to) - new Date(st.from)) / 864e5) + 1; st.from = addDays(st.from, delta * len); st.to = addDays(st.to, delta * len); fromIn.value = st.from; toIn.value = st.to; }
    load();
  }
  const help = h('p', { class: 'muted', 'data-testid': 'r-report-help', text: rt(`ui.admin.reports.r_${report0}_help`) });
  const picker = h('div', { role: 'radiogroup', class: 'tl-report-picker', 'data-testid': 'r-report', 'aria-label': rt('ui.admin.reports.picker') });
  const groups = [['accounting', ['sales', 'service', 'giftcards', 'invoices']], ['reconcile', ['methods', 'fees', 'transactions', 'refunds']], ['stats', ['stats']]];
  for (const [gid, ids] of groups) {
    const box = h('div', { class: 'tl-report-group' }, h('span', { text: rt(`ui.admin.reports.group_${gid}`) }));
    for (const id of ids) {
      if (id === 'refunds' && !canRefunds) continue;
      const off = !canFull && !DAY_ONLY.has(id) && id !== 'refunds';
      if (id === 'refunds') box.append(h('a', { class: 'tl-seg', href: '#/hyvitysten-seuranta', 'data-testid': 'r-report-refunds', text: rt('ui.admin.reports.r_refunds') }));
      else box.append(h('button', { type: 'button', role: 'radio', class: 'tl-seg', 'data-report': id, 'data-testid': `r-report-${id}`, 'aria-checked': String(st.report === id), disabled: off || null, title: off ? t('r.monthlyNoPerm') : null, onclick: () => { help.textContent = rt(`ui.admin.reports.r_${id}_help`); setReport(id); } }, rt(`ui.admin.reports.r_${id}`)));
    }
    picker.append(box);
  }
  const kindBtn = (k, label, tid) => h('button', { type: 'button', role: 'radio', class: 'tl-seg', 'data-testid': tid, 'aria-checked': String(st.mode === k), disabled: !canFull && k !== 'day' ? true : null, title: !canFull && k !== 'day' ? t('r.monthlyNoPerm') : null, onclick: () => setMode(k) }, label);
  const kindBtns = { day: kindBtn('day', rt('ui.admin.reports.day'), 'r-kind-daily'), month: kindBtn('month', rt('ui.admin.reports.pick_month'), 'r-kind-monthly'), range: kindBtn('range', rt('ui.admin.reports.range'), 'r-kind-range') };
  const dateIn = h('input', { type: 'date', value: st.date, max: today, 'data-testid': 'r-date', 'aria-label': t('r.date'), onchange: (e) => { if (e.target.value) { st.date = e.target.value; load(); } } });
  const monthSel = h('select', { 'data-testid': 'r-month', 'aria-label': t('r.month'), onchange: (e) => { st.month = +e.target.value; load(); } }, Array.from({ length: 12 }, (_, i) => h('option', { value: i + 1, text: fmt.month(`2026-${String(i + 1).padStart(2, '0')}`).replace(/\s*\d{4}$/, '') })));
  monthSel.value = String(st.month);
  const years = [st.year - 2, st.year - 1, st.year, st.year + 1].filter((y) => y >= 2024);
  const yearSel = h('select', { 'data-testid': 'r-year', 'aria-label': t('r.year'), onchange: (e) => { st.year = +e.target.value; load(); } }, years.map((y) => h('option', { value: y, text: String(y) })));
  yearSel.value = String(st.year);
  const fromIn = h('input', { type: 'date', value: st.from, 'data-testid': 'r-from', 'aria-label': rt('ui.admin.reports.from'), onchange: (e) => { if (e.target.value) { st.from = e.target.value; if (st.to < st.from) { st.to = st.from; toIn.value = st.to; } load(); } } });
  const toIn = h('input', { type: 'date', value: st.to, 'data-testid': 'r-to', 'aria-label': rt('ui.admin.reports.to'), onchange: (e) => { if (e.target.value) { st.to = e.target.value; if (st.from > st.to) { st.from = st.to; fromIn.value = st.from; } load(); } } });
  const dayFld = h('label', { class: 'fld tl-r-day', hidden: st.mode !== 'day' || null }, h('span', { text: t('r.date') }), dateIn);
  const monFld = h('div', { class: 'fld tl-r-mon', hidden: st.mode !== 'month' || null }, h('span', { text: t('r.month') }), h('div', { class: 'tl-sortrow' }, monthSel, yearSel));
  const rangeFld = h('div', { class: 'fld tl-r-range', hidden: st.mode !== 'range' || null }, h('span', { text: rt('ui.admin.reports.range') }), h('div', { class: 'tl-sortrow' }, fromIn, toIn));
  const quickDay = h('div', { class: 'tl-actions', hidden: st.mode !== 'day' || null }, h('button', { type: 'button', class: 'btn tl-btn', 'data-testid': 'r-today', onclick: () => { st.date = today; dateIn.value = today; load(); } }, rt('ui.admin.reports.today')), h('button', { type: 'button', class: 'btn tl-btn', 'data-testid': 'r-yesterday', onclick: () => { st.date = addDays(today, -1); dateIn.value = st.date; load(); } }, rt('ui.admin.reports.yesterday')));
  const quickMonth = h('div', { class: 'tl-actions', hidden: st.mode !== 'month' || null }, h('button', { type: 'button', class: 'btn tl-btn', 'data-testid': 'r-this-month', onclick: () => { st.year = +today.slice(0, 4); st.month = +today.slice(5, 7); monthSel.value = String(st.month); yearSel.value = String(st.year); load(); } }, rt('ui.admin.reports.this_month')), h('button', { type: 'button', class: 'btn tl-btn', 'data-testid': 'r-prev-month', onclick: () => { const ym = shiftMonth(today.slice(0, 7), -1); st.year = +ym.slice(0, 4); st.month = +ym.slice(5); monthSel.value = String(st.month); yearSel.value = String(st.year); load(); } }, rt('ui.admin.reports.prev_month')));
  const gcFilter = h('select', { 'data-testid': 'r-gc-filter', hidden: st.report !== 'giftcards' || null, 'aria-label': rt('ui.admin.reports.gc_filter'), onchange: (e) => { st.gc = e.target.value; load(); } }, [['open', 'gc_open'], ['used', 'gc_used'], ['all', 'gc_all']].map(([v, k]) => h('option', { value: v, text: rt(`ui.admin.reports.${k}`) })));
  const btn = (tid, label, fn, disabled = false) => h('button', { type: 'button', class: 'btn tl-btn', 'data-testid': tid, disabled: disabled || null, onclick: fn }, h('span', { text: label }));
  async function downloadPdf() {
    pdfBtn.disabled = true;
    try {
      const span = spanOf();
      const mode = { sales: 'summary', methods: 'methods', service: 'accrual', giftcards: 'giftcards', fees: 'fees', transactions: 'transactions', invoices: 'invoices', stats: 'stats' }[st.report];
      const res = await api.reportPdf({ pdf: mode, period: { ...span, kind: st.mode === 'day' ? 'day' : st.mode === 'month' ? 'month' : 'range' }, filter: st.gc });
      if (!res) { document.title = `${t('nav')} – ${rt(titleKey())}`; window.print(); return; }
      saveBlob(`${fileStem()}.pdf`, new Blob([res.blob], { type: 'application/pdf' }));
    } catch (e) { toast(`${t('r.pdfFailed')} ${errMsg(e)}`, 'err'); } finally { pdfBtn.disabled = false; }
  }
  async function downloadCsv() {
    if (!canFull || !current) return;
    csvBtn.disabled = true;
    try {
      const span = spanOf();
      if (st.report === 'service') { const res = await api.reportAccrualCsv(span.from, span.to); downloadCsv(res.filename, res.content); }
      else if (st.report === 'giftcards') { const res = await api.reportGiftCards(st.gc, 'csv', span.from, span.to); downloadCsv(res.filename, res.content); }
      else if (st.report === 'fees') { const res = await api.reportProviderFees(span.from, span.to, 'csv'); if (res?.content) downloadCsv(res.filename, res.content); }
      else if (st.report === 'invoices') { const res = await api.reportInvoices(span.from, span.to, 'csv'); downloadCsv(res.filename, res.content); }
      else if (st.report === 'transactions') { const res = await api.reportCsv({ period: span }, 'lines'); downloadCsv(res.filename, res.content); }
      else if (st.report === 'methods') { const res = await api.reportCsv({ period: span }, 'methods'); downloadCsv(res.filename, res.content); }
      else if (st.report === 'stats') { downloadCsv(`${fileStem()}.csv`, `\uFEFFosio;brutto\r\noma;${current.totals?.gross_after_refunds ?? 0}\r\njohku;${current.statistics?.johku?.gross ?? 0}\r\n`); }
      else { const res = await api.reportCsv({ period: span }, 'summary'); downloadCsv(res.filename, res.content); }
    } catch (e) { toast(errMsg(e), 'err'); } finally { csvBtn.disabled = !canFull; }
  }
  const pdfBtn = btn('r-pdf-server', rt('ui.admin.reports.export_pdf'), downloadPdf, true);
  const csvBtn = btn('r-csv', rt('ui.admin.reports.export_csv'), downloadCsv, !canFull);
  const printBtn = h('button', { type: 'button', class: 'btn tl-btn', 'data-testid': 'r-pdf', onclick: () => { document.title = `${t('nav')} – ${rt(titleKey())}`; window.print(); } }, h('span', { class: 'tl-ico', 'aria-hidden': 'true' }, icon('print', 20)), h('span', { text: t('r.pdf') }));
  const controls = h('div', { class: 'tl-toolbar tl-r-controls tl-noprint' },
    h('div', { class: 'fld' }, h('span', { text: rt('ui.admin.reports.picker') }), picker, help),
    h('div', { class: 'fld' }, h('span', { text: rt('ui.admin.reports.period') }), h('div', { role: 'radiogroup', class: 'tl-segs', 'aria-label': rt('ui.admin.reports.period') }, kindBtns.day, kindBtns.month, kindBtns.range)),
    h('button', { type: 'button', class: 'btn', 'data-testid': 'r-prev', 'aria-label': rt('ui.admin.reports.prev_period'), onclick: () => shift(-1) }, '←'),
    h('button', { type: 'button', class: 'btn', 'data-testid': 'r-next', 'aria-label': rt('ui.admin.reports.next_period'), onclick: () => shift(1) }, '→'),
    quickDay, quickMonth, dayFld, monFld, rangeFld, gcFilter,
    h('div', { class: 'tl-actions' }, pdfBtn, csvBtn, printBtn),
    canFull ? null : h('p', { class: 'tl-hint', role: 'note', 'data-testid': 'r-limited', text: t('r.limited') }));
  const node = h('div', { class: 'tl-tab', 'data-testid': 'tab-reports' }, controls, out);
  return { node, load };
}
