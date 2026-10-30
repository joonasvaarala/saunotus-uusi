// Talous › Raportit: päivä, tämä/edellinen kuukausi, kuukausivalinta ja vapaa jakso.
// Kassaperuste (kuitin antopäivä). Myynti tuotteittain, ALV-kannat, maksutavat, täsmäytys, hyvitykset, tapahtuma- ja lahjakorttivienti.
import { h, toast, errMsg, todayHel } from '../ui.js';
import { icon } from '../icons.js';
import { t, fmt, has } from '../talous-i18n.js';
import { toCsv, downloadCsv } from '../csv.js';
import { methodLabel, loading, emptyBox, errorBox } from './talous-ui.js';
import { TEXTS } from '../talous-texts.js';
import { reportText as rt } from '../reports-texts.js';

const fiMethod = (c) => TEXTS.fi[`method.${c}`] || c;
const KINDS = ['daily', 'this', 'prev', 'monthly', 'range'];

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
function saveBlob(filename, blob) {
  const url = URL.createObjectURL(blob);
  const a = h('a', { href: url, download: filename });
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30000);
}

// Oikeudet: päivä = reports.daily TAI reports.view; muu jakso, CSV ja lahjakorttiraportti = reports.view.
export function createReportsTab({ api, canFull = true }) {
  const today = todayHel();
  const st = { kind: 'daily', date: today, year: +today.slice(0, 4), month: +today.slice(5, 7), from: `${today.slice(0, 8)}01`, to: today, gc: 'open', section: 'sales' };
  const out = h('div', { class: 'tl-report', 'data-testid': 'report-out' });
  const gcOut = h('div', { 'data-testid': 'r-gc-out' });
  let seq = 0, gseq = 0, current = null;
  const ym = () => `${st.year}-${String(st.month).padStart(2, '0')}`;
  const spanOf = () => (st.kind === 'this' ? monthBounds(today.slice(0, 7)) : st.kind === 'prev' ? monthBounds(shiftMonth(today.slice(0, 7), -1)) : { from: st.from, to: st.to });
  async function loadSales() {
    const my = ++seq; current = null;
    csvBtn.disabled = true; sumCsvBtn.disabled = true; methodsCsvBtn.disabled = true; txPdfBtn.disabled = true; pdfSrvBtn.disabled = true;
    out.replaceChildren(loading());
    try {
      const r = st.kind === 'daily' ? await api.reportDaily(st.date) : st.kind === 'monthly' ? await api.reportMonthly(ym()) : await api.reportRange(spanOf().from, spanOf().to);
      if (my !== seq) return;
      current = r;
      csvBtn.disabled = !canFull; sumCsvBtn.disabled = !canFull; methodsCsvBtn.disabled = !canFull; txPdfBtn.disabled = !canFull; pdfSrvBtn.disabled = false;
      out.replaceChildren(view(r));
    } catch (e) { if (my === seq) out.replaceChildren(errorBox(e, loadSales)); }
  }
  async function loadGc() {
    const my = ++gseq;
    gcCsvBtn.disabled = true; gcPdfBtn.disabled = true;
    gcOut.replaceChildren(loading());
    try {
      const r = await api.reportGiftCards(st.gc, 'json');
      if (my !== gseq) return;
      gcCsvBtn.disabled = !canFull; gcPdfBtn.disabled = !canFull;
      gcOut.replaceChildren(gcView(r));
    } catch (e) { if (my === gseq) gcOut.replaceChildren(errorBox(e, loadGc)); }
  }
  const periodLabel = (r) => (r.period.kind === 'day' ? fmt.date(r.period.from) : `${r.period.kind === 'month' ? fmt.month(r.period.from.slice(0, 7)) : rt('ui.admin.reports.range')} (${fmt.date(r.period.from)} – ${fmt.date(r.period.to)})`);
  function view(r) {
    const M = fmt.money, T = r.totals;
    const title = r.period.kind === 'day' ? t('r.daily') : r.period.kind === 'month' ? t('r.monthly') : rt('ui.admin.reports.range');
    const head = h('header', { class: 'tl-report-head' }, h('h2', { 'data-testid': 'report-title', text: `${title}: ${periodLabel(r)}` }), h('p', { class: 'muted', text: rt('ui.admin.reports.basis') }));
    const open = h('p', { class: 'muted', 'data-testid': 'r-open', text: `${t('r.open')}: ${t('r.openVal', { n: fmt.int(r.open.orders), sum: M(r.open.unpaid) })}` });
    const openNote = h('p', { class: 'muted', 'data-testid': 'r-open-note', text: rt('ui.admin.reports.open_note') });
    const johku = johkuBlock(r.statistics?.johku);
    const card = (label, value, tid) => h('div', { class: 'tl-stat' }, h('dt', { text: label }), h('dd', { 'data-testid': tid, text: value }));
    const stats = h('dl', { class: 'tl-stats' }, card(t('r.gross'), M(T.gross), 'r-gross'), card(t('r.refunds'), M(T.refunds_gross), 'r-refunds'), card(t('r.grossAfter'), M(T.gross_after_refunds), 'r-gross-after'), card(t('r.vatAfter'), M(T.vat_after_refunds), 'r-vat'), card(t('r.netExVat'), M(T.net_ex_vat_after_refunds), 'r-net-ex-vat'),
      card(rt('ui.admin.reports.sales_count'), fmt.int(T.receipts), 'r-receipts'), card(rt('ui.admin.reports.refund_count'), fmt.int(T.refund_receipts), 'r-refund-receipts'), ...(Math.abs(T.rounding) >= 0.005 ? [card(t('r.rounding'), M(T.rounding), 'r-rounding')] : []));
    const table = (testid, caption, cols, rows, foot) => h('section', { class: 'tl-sec' }, h('h3', { text: caption }), h('table', { class: 'tl-table', 'data-testid': testid },
      h('thead', {}, h('tr', {}, cols.map((c, i) => h('th', { scope: 'col', class: i ? 'r' : '', text: c })))),
      h('tbody', {}, rows.map((row) => h('tr', {}, row.map((c, i) => h(i ? 'td' : 'th', i ? { class: 'r', 'data-label': cols[i], text: c } : { scope: 'row', text: c }))))),
      foot ? h('tfoot', {}, h('tr', {}, foot.map((c, i) => h(i ? 'td' : 'th', i ? { class: 'r', 'data-label': cols[i], text: c } : { scope: 'row', text: c })))) : null));
    const sum = (rows, k) => rows.reduce((s, x) => s + x[k], 0);
    const qtyTxt = (n) => Math.abs(n - Math.round(n)) < 0.001 ? fmt.int(n) : String(Math.round(n * 100) / 100).replace('.', ',');
    const daily = r.period.kind === 'day';
    const vatCols = [rt('ui.admin.reports.col_vat_pct'), rt('ui.admin.reports.col_net'), rt('ui.admin.reports.col_gross'), rt('ui.admin.reports.col_vat_eur')];
    const vatTable = (id, title, rows) => { const rates = [...(rows || [])].sort((a, b) => a.rate - b.rate); return table(id, title, vatCols, rates.map((v) => [fmt.pct(v.rate), M(v.net), M(v.gross), M(v.vat)]), [rt('ui.admin.reports.total'), M(sum(rates, 'net')), M(sum(rates, 'gross')), M(sum(rates, 'vat'))]); };
    const byVat = h('div', { 'data-testid': 'r-vat-breakdown' }, vatTable('r-vat-sales', rt('ui.admin.reports.vat_sales'), r.by_vat_sales || []), vatTable('r-vat-refunds', rt('ui.admin.reports.vat_refunds'), r.by_vat_refunds || []), vatTable('r-by-vat', rt('ui.admin.reports.vat_net'), r.by_vat), h('p', { class: 'muted', text: rt('ui.admin.reports.vat_breakdown_note') }));
    const cell = (m, rate) => (r.by_method_vat || []).find((x) => x.method === m && x.rate === rate);
    const methods = r.by_method || [];
    const methodRates = [...(r.by_vat || [])].sort((a, b) => a.rate - b.rate);
    const matrixRows = methods.map((m) => [methodLabel(m.method, m.label), ...methodRates.map((v) => { const c = cell(m.method, v.rate); return c ? M(c.gross) : '–'; }), M((r.by_method_vat || []).filter((x) => x.method === m.method).reduce((s, x) => s + x.gross, 0))]);
    const matrix = table('r-matrix', t('r.matrix'), [t('col.method'), ...methodRates.map((x) => `${t('r.vatShort')} ${fmt.pct(x.rate)}`), t('line.total')], matrixRows, [t('line.total'), ...methodRates.map((v) => M(v.gross)), M(sum(methodRates, 'gross'))]);
    const byMethod = table('r-by-method', t('r.byMethod'), [t('col.method'), t('r.payments'), t('r.gross'), t('r.refunds'), rt('ui.admin.reports.col_net')], methods.map((m) => [methodLabel(m.method, m.label), fmt.int(m.payments), M(m.gross), M(m.refunds), M((m.gross || 0) + (m.refunds || 0))]), [t('line.total'), fmt.int(sum(methods, 'payments')), M(sum(methods, 'gross')), M(sum(methods, 'refunds')), M(sum(methods, 'gross') + sum(methods, 'refunds'))]);
    const methodsNet = r.reconciliation?.methods_net ?? (sum(methods, 'gross') + sum(methods, 'refunds'));
    const salesNet = r.reconciliation?.payments_gross ?? T.net_after_refunds;
    const methodsDiff = r.reconciliation?.methods_difference ?? (methodsNet - salesNet);
    const methodsBlock = h('div', { 'data-testid': 'r-methods' }, matrix, byMethod, table('r-methods-reconcile', rt('ui.admin.reports.reconcile'), [rt('ui.admin.reports.reconcile'), rt('ui.admin.reports.col_gross')], [
      [rt('ui.admin.reports.pay_net'), M(methodsNet)],
      [rt('ui.admin.reports.pdf_after'), M(salesNet)],
      [rt('ui.admin.reports.reconcile_diff'), Math.abs(methodsDiff) < 0.005 ? `${M(methodsDiff)} · ${rt('ui.admin.reports.reconcile_ok')}` : M(methodsDiff)],
    ]), h('p', { class: 'muted', text: rt('ui.admin.reports.methods_reconcile') }));
    const cols = [rt('ui.admin.reports.col_product'), rt('ui.admin.reports.col_count'), rt('ui.admin.reports.col_net'), rt('ui.admin.reports.col_gross'), rt('ui.admin.reports.col_vat_eur'), rt('ui.admin.reports.col_vat_pct')];
    const moneyRow = (p) => [p.product, qtyTxt(p.quantity), M(p.net), M(p.gross), M(p.vat), fmt.pct(p.rate)];
    const moneyFoot = (rows) => [rt('ui.admin.reports.total'), qtyTxt(sum(rows, 'quantity')), M(sum(rows, 'net')), M(sum(rows, 'gross')), M(sum(rows, 'vat')), ''];
    const byProduct = r.by_product?.length ? table('r-by-product', rt('ui.admin.reports.by_product'), cols, r.by_product.map(moneyRow), moneyFoot(r.by_product)) : h('section', { class: 'tl-sec', 'data-testid': 'r-by-product' }, h('h3', { text: rt('ui.admin.reports.by_product') }), emptyBox(t('r.empty')));
    const refunds = r.refunds_by_product?.length ? table('r-refunds-product', rt('ui.admin.reports.refunds_by_product'), cols, r.refunds_by_product.map(moneyRow), moneyFoot(r.refunds_by_product)) : h('section', { class: 'tl-sec', 'data-testid': 'r-refunds-product' }, h('h3', { text: rt('ui.admin.reports.refunds_by_product') }), h('p', { class: 'muted', text: rt('ui.admin.reports.no_refunds') }));
    const rec = r.reconciliation;
    const recRows = rec ? [
      [rt('ui.admin.reports.reconcile_sales'), M(rec.sales_gross)],
      [rt('ui.admin.reports.reconcile_refunds'), M(rec.refunds_gross)],
      [rt('ui.admin.reports.reconcile_products'), M(rec.product_gross)],
      ...(daily ? [] : [
        [rt('ui.admin.reports.reconcile_payments'), M(rec.payments_gross)],
        [rt('ui.admin.reports.reconcile_diff'), Math.abs(rec.difference) < 0.005 ? `${M(rec.difference)} · ${rt('ui.admin.reports.reconcile_ok')}` : M(rec.difference)],
      ]),
      ...(Math.abs(rec.vat_rounding) >= 0.005 || rec.rounding_code ? [[`${rt('ui.admin.reports.rounding_row')}${rec.rounding_code ? ` (${rec.rounding_code})` : ''}`, M(rec.vat_rounding)]] : []),
      ...(Math.abs(rec.cash_rounding) >= 0.005 ? [[rt('ui.admin.reports.cash_rounding'), M(rec.cash_rounding)]] : []),
    ] : null;
    const recBlock = recRows ? h('div', {}, table('r-reconcile', rt('ui.admin.reports.reconcile'), [rt('ui.admin.reports.reconcile'), rt('ui.admin.reports.col_gross')], recRows), rec?.rounding_code ? h('p', { class: 'muted', 'data-testid': 'r-rounding-note', text: rt('ui.admin.reports.vat_rounding_note') }) : null) : null;
    const pre = r.prepaid_redemptions;
    const gcp = r.gift_card_period || {};
    const sold = gcp.sold || { count: 0, net: 0, vat: 0, gross: 0, lines: [], by_vat: [] };
    const comp = gcp.complimentary || { issued_count: 0, issued_gross: 0, redeemed_count: 0, redeemed_gross: 0 };
    const gcSummary = h('section', { class: 'tl-sec', 'data-testid': 'r-gc-summary' }, h('h3', { text: rt('ui.admin.reports.gc_summary_title') }),
      table('r-gc-sold', rt('ui.admin.reports.gc_sold'), cols, (sold.lines || []).map(moneyRow), (sold.lines || []).length ? moneyFoot(sold.lines) : [rt('ui.admin.reports.total'), qtyTxt(sold.count || 0), M(sold.net || 0), M(sold.gross || 0), M(sold.vat || 0), '']),
      h('p', { class: 'muted', text: rt('ui.admin.reports.gc_sold_note') }),
      table('r-gc-redeemed', rt('ui.admin.reports.gc_redeemed'), cols, (pre?.lines || []).map(moneyRow), (pre?.lines || []).length ? moneyFoot(pre.lines) : [rt('ui.admin.reports.total'), qtyTxt(pre?.payments || 0), M(pre?.net || 0), M(pre?.gross || 0), M(pre?.vat || 0), '']),
      h('p', { class: 'muted', 'data-testid': 'r-prepaid', text: rt('ui.admin.reports.prepaid_note') }),
      table('r-gc-complimentary', rt('ui.admin.reports.gc_complimentary_title'), [rt('ui.admin.reports.col_product'), rt('ui.admin.reports.col_count'), rt('ui.admin.reports.col_gross')], [
        [rt('ui.admin.reports.gc_comp_issued'), qtyTxt(comp.issued_count || 0), M(comp.issued_gross || 0)],
        [rt('ui.admin.reports.gc_comp_redeemed'), qtyTxt(comp.redeemed_count || 0), M(comp.redeemed_gross || 0)],
      ]),
      h('p', { class: 'muted', text: rt('ui.admin.reports.gc_comp_note') }),
      table('r-gc-open', rt('ui.admin.reports.gc_open_title'), [rt('ui.admin.reports.col_product'), rt('ui.admin.reports.gc_opening'), rt('ui.admin.reports.gc_sold_period'), rt('ui.admin.reports.gc_redeemed_period'), rt('ui.admin.reports.gc_expired'), rt('ui.admin.reports.gc_closing')], ['native_paid', 'native_complimentary', 'johku'].map((key) => {
        const b = gcp.open?.[key] || {};
        const label = key === 'native_paid' ? rt('ui.admin.reports.gc_bucket_own') : key === 'native_complimentary' ? rt('ui.admin.reports.gc_bucket_free') : rt('ui.admin.reports.gc_bucket_johku');
        return [label, M(b.opening || 0), M(b.sold || 0), M(b.redeemed || 0), M(b.expired || 0), M(b.closing || 0)];
      })),
      h('p', { class: 'muted', 'data-testid': 'r-gc-johku-note', text: rt('ui.admin.reports.gc_johku_liability') }));
    const cats = new Map(); for (const c of r.by_category) { const x = cats.get(c.category) || { label: c.label || c.category, quantity: 0, gross: 0 }; x.quantity += c.quantity; x.gross += c.gross; cats.set(c.category, x); }
    const byCat = table('r-by-group', t('r.byGroup'), [t('r.group'), t('r.qty'), t('r.gross')], [...cats.entries()].sort((a, b) => b[1].gross - a[1].gross).map(([k, x]) => [has(`group.${k}`) ? t(`group.${k}`) : x.label, fmt.int(x.quantity), M(x.gross)]));
    const byDay = r.by_day?.length ? table('r-daily', t('r.dailyBreakdown'), [t('r.date'), rt('ui.admin.reports.sales_count'), t('r.gross'), t('r.refunds')], r.by_day.map((d) => [fmt.date(d.date), fmt.int(d.receipts), M(d.gross), M(d.refunds)])) : null;
    const receipts = r.receipts?.length ? table('r-receipts-list', rt('ui.admin.reports.sales_list'), [rt('ui.admin.reports.col_voucher'), t('col.time'), t('col.order'), t('r.gross')], r.receipts.map((x) => [x.receipt_no, fmt.dt(x.issued_at), x.order_no != null ? `#${x.order_no}` : '–', M(x.gross)])) : null;
    if (st.section === 'methods') return h('div', {}, head, methodsBlock);
    return h('div', {}, head, stats, byProduct, refunds, byVat, gcSummary, daily ? methodsBlock : null, recBlock, byCat, byDay, receipts, open, openNote, johku);
  }
  function johkuBlock(j) {
    if (!j) return null;
    const M = fmt.money, jm = (c) => (has(`jm.${c}`) ? t(`jm.${c}`) : methodLabel(c));
    const card = (label, value, sub, tid) => h('div', { class: 'tl-stat' }, h('dt', { text: label }), h('dd', { 'data-testid': tid, text: value }), sub ? h('small', { class: 'muted', 'data-testid': `${tid}-n`, text: sub }) : null);
    const none = !j.orders && !j.refunded_orders;
    const body = none ? [emptyBox(t('r.johku.none'))] : [
      h('dl', { class: 'tl-stats' }, card(t('r.johku.sales'), M(j.gross), t('r.johku.perOrders', { n: fmt.int(j.orders) }), 'rj-gross'),
        card(t('r.johku.refunded'), M(j.refunded_gross), t('r.johku.perOrders', { n: fmt.int(j.refunded_orders) }), 'rj-refunded')),
      j.by_method.length ? h('table', { class: 'tl-table', 'data-testid': 'rj-by-method' },
        h('thead', {}, h('tr', {}, [t('col.method'), t('r.johku.orders'), t('r.gross')].map((c, i) => h('th', { scope: 'col', class: i ? 'r' : '', text: c })))),
        h('tbody', {}, j.by_method.map((m) => h('tr', {}, h('th', { scope: 'row', text: jm(m.method) }), h('td', { class: 'r', 'data-label': t('r.johku.orders'), text: fmt.int(m.orders) }), h('td', { class: 'r', 'data-label': t('r.gross'), text: M(m.gross) }))))) : null];
    return h('section', { class: 'tl-johku-block tl-noprint', 'data-testid': 'r-johku', 'aria-labelledby': 'r-johku-h' }, h('h3', { id: 'r-johku-h', text: t('r.johku.title') }), h('p', { class: 'muted tl-johku-note', text: t('r.johku.note') }), ...body);
  }
  function gcView(r) {
    const M = fmt.money;
    const cols = [rt('ui.admin.reports.gc_col_code'), rt('ui.admin.reports.gc_col_buyer'), rt('ui.admin.reports.gc_col_package'), rt('ui.admin.reports.gc_col_initial'), rt('ui.admin.reports.gc_col_balance'), rt('ui.admin.reports.col_net'), rt('ui.admin.reports.col_vat_pct'), rt('ui.admin.reports.col_vat_eur'), rt('ui.admin.reports.col_gross'), rt('ui.admin.reports.gc_col_sold'), rt('ui.admin.reports.gc_col_valid'), rt('ui.admin.reports.gc_col_status'), rt('ui.admin.reports.gc_col_vat')];
    const status = (s) => (has(`gcst.${s}`) ? t(`gcst.${s}`) : s);
    const vat = (x) => (x.complimentary ? rt('ui.admin.reports.gc_mark_complimentary') : has(`gc.vat.${x.vat_treatment}`) ? t(`gc.vat.${x.vat_treatment}`) : x.vat_treatment);
    const row = (x) => [x.code_masked, x.buyer || '–', x.package || '–', M(x.initial), M(x.balance), M(x.net), fmt.pct(x.vat_rate), M(x.vat), M(x.gross), x.sold_on ? fmt.date(x.sold_on) : '–', x.valid_to ? fmt.date(x.valid_to) : '–', status(x.status), vat(x)];
    const section = (title, rows, totals, testid, note) => h('section', { class: 'tl-sec', 'data-testid': testid }, h('h3', { text: title }), note ? h('p', { class: 'muted', text: note }) : null,
      h('p', { class: 'muted', text: `${rt('ui.admin.reports.gc_count', { n: fmt.int(totals.count) })} · ${rt('ui.admin.reports.gc_sum', { balance: M(totals.balance), initial: M(totals.initial) })}` }),
      rows.length ? h('table', { class: 'tl-table' }, h('thead', {}, h('tr', {}, cols.map((c, i) => h('th', { scope: 'col', class: i ? 'r' : '', text: c })))), h('tbody', {}, rows.map((x) => h('tr', {}, row(x).map((c, i) => h(i ? 'td' : 'th', i ? { class: 'r', text: c } : { scope: 'row', text: c })))))) : emptyBox(t('r.empty')));
    const comp = r.own.complimentary || { count: 0, balance: 0, initial: 0 };
    const ownNote = [rt('ui.admin.reports.gc_paid_note'), comp.count ? rt('ui.admin.reports.gc_complimentary') : ''].filter(Boolean).join(' ');
    return h('div', {}, section(rt('ui.admin.reports.gc_own'), r.own.rows, { count: r.own.at_redemption.count + r.own.at_sale.count + comp.count, balance: r.own.at_redemption.balance + r.own.at_sale.balance + comp.balance, initial: r.own.at_redemption.initial + r.own.at_sale.initial + comp.initial }, 'r-gc-own', ownNote),
      section(rt('ui.admin.reports.gc_johku'), r.johku.rows, r.johku.totals, 'r-gc-johku', rt('ui.admin.reports.gc_note')));
  }

  const sectionLabel = { sales: rt('ui.admin.reports.sales_tab'), methods: rt('ui.admin.reports.methods_tab') };
  const sectionBtn = (id) => h('button', { type: 'button', role: 'radio', class: 'tl-seg', 'aria-checked': String(st.section === id), 'data-testid': `r-section-${id}`, onclick: () => { st.section = id; syncSection(); if (current) out.replaceChildren(view(current)); } }, sectionLabel[id]);
  const sectionBtns = { sales: sectionBtn('sales'), methods: sectionBtn('methods') };
  const syncSection = () => { for (const id of ['sales', 'methods']) sectionBtns[id].setAttribute('aria-checked', String(st.section === id)); };
  const kindLabel = { daily: rt('ui.admin.reports.day'), this: rt('ui.admin.reports.this_month'), prev: rt('ui.admin.reports.prev_month'), monthly: rt('ui.admin.reports.pick_month'), range: rt('ui.admin.reports.range') };
  const kindBtn = (k) => { const off = k !== 'daily' && !canFull; return h('button', { type: 'button', role: 'radio', class: 'tl-seg', 'aria-checked': String(st.kind === k), 'data-testid': `r-kind-${k}`, disabled: off || null, title: off ? t('r.monthlyNoPerm') : null, onclick: () => { st.kind = k; syncKind(); loadSales(); } }, kindLabel[k]); };
  const kindBtns = Object.fromEntries(KINDS.map((k) => [k, kindBtn(k)]));
  const dateIn = h('input', { type: 'date', value: st.date, max: today, 'data-testid': 'r-date', 'aria-label': t('r.date'), onchange: (e) => { if (e.target.value) { st.date = e.target.value; loadSales(); } } });
  const monthSel = h('select', { 'data-testid': 'r-month', 'aria-label': t('r.month'), onchange: (e) => { st.month = +e.target.value; loadSales(); } }, Array.from({ length: 12 }, (_, i) => h('option', { value: i + 1, text: fmt.month(`2026-${String(i + 1).padStart(2, '0')}`).replace(/\s*\d{4}$/, '').replace(/^./, (c) => c.toUpperCase()) })));
  monthSel.value = st.month;
  const years = [st.year - 2, st.year - 1, st.year].filter((y) => y >= 2024);
  const yearSel = h('select', { 'data-testid': 'r-year', 'aria-label': t('r.year'), onchange: (e) => { st.year = +e.target.value; loadSales(); } }, years.map((y) => h('option', { value: y, text: String(y) })));
  yearSel.value = st.year;
  const fromIn = h('input', { type: 'date', value: st.from, 'data-testid': 'r-from', 'aria-label': rt('ui.admin.reports.from'), onchange: (e) => { if (e.target.value) { st.from = e.target.value; if (st.to < st.from) st.to = st.from; toIn.value = st.to; loadSales(); } } });
  const toIn = h('input', { type: 'date', value: st.to, 'data-testid': 'r-to', 'aria-label': rt('ui.admin.reports.to'), onchange: (e) => { if (e.target.value) { st.to = e.target.value; if (st.from > st.to) st.from = st.to; fromIn.value = st.from; loadSales(); } } });
  const dayFld = h('label', { class: 'fld tl-r-day' }, h('span', { text: t('r.date') }), dateIn);
  const monFld = h('div', { class: 'fld tl-r-mon' }, h('span', { text: t('r.month') }), h('div', { class: 'tl-sortrow' }, monthSel, yearSel));
  const rangeFld = h('div', { class: 'fld tl-r-range' }, h('span', { text: rt('ui.admin.reports.range') }), h('div', { class: 'tl-sortrow' }, fromIn, toIn));
  const syncKind = () => { for (const k of KINDS) kindBtns[k].setAttribute('aria-checked', String(st.kind === k)); dayFld.hidden = st.kind !== 'daily'; monFld.hidden = st.kind !== 'monthly'; rangeFld.hidden = st.kind !== 'range'; };
  const btn = (tid, label, fn, disabled = false) => h('button', { type: 'button', class: 'btn tl-btn', 'data-testid': tid, disabled: disabled || null, title: disabled ? t('r.monthlyNoPerm') : null, onclick: fn }, h('span', { class: 'tl-ico', 'aria-hidden': 'true' }, icon('download', 20)), h('span', { text: label }));
  async function grabCsv(kind) {
    if (!current) return;
    const res = await api.reportCsv(current, kind);
    if (res.source === 'server') downloadCsv(res.filename, res.content);
    else if (current.lines) downloadCsv(`tapahtumat_${current.period.from}_${current.period.to}.csv`, toCsv(current.lines, { methodLabel: fiMethod }));
  }
  const csvBtn = btn('r-csv', t('r.csv'), async () => { csvBtn.disabled = true; try { await grabCsv('lines'); } catch (e) { toast(errMsg(e), 'err'); } finally { csvBtn.disabled = !current || !canFull; } }, !canFull);
  const sumCsvBtn = btn('r-summary-csv', rt('ui.admin.reports.summary_csv'), async () => { sumCsvBtn.disabled = true; try { await grabCsv('summary'); } catch (e) { toast(errMsg(e), 'err'); } finally { sumCsvBtn.disabled = !current || !canFull; } }, !canFull);
  const methodsCsvBtn = btn('r-methods-csv', rt('ui.admin.reports.methods_csv'), async () => { methodsCsvBtn.disabled = true; try { await grabCsv('methods'); } catch (e) { toast(errMsg(e), 'err'); } finally { methodsCsvBtn.disabled = !current || !canFull; } }, !canFull);
  function pdfName(mode) {
    const p = current?.period;
    if (mode === 'giftcards') return `lahjakortit_${st.gc}.pdf`;
    if (!p) return 'raportti.pdf';
    if (mode === 'transactions') return `tapahtumat_${p.from}_${p.to}.pdf`;
    if (p.kind === 'day') return `raportti_paiva_${p.from}.pdf`;
    if (p.kind === 'month') return `raportti_kuukausi_${p.from.slice(0, 7)}.pdf`;
    return `raportti_jakso_${p.from}_${p.to}.pdf`;
  }
  async function grabPdf(mode, button) {
    button.disabled = true;
    try {
      const res = await api.reportPdf(mode === 'giftcards' ? { pdf: 'giftcards', filter: st.gc, period: current?.period || { from: st.from, to: st.to, kind: 'range' } } : { ...current, pdf: mode });
      if (!res) { document.title = `${t('nav')} – ${current ? periodLabel(current) : rt('ui.admin.reports.gc_title')}`; window.print(); return; }
      saveBlob(pdfName(mode), new Blob([res.blob], { type: 'application/pdf' }));
    } catch (e) { toast(`${t('r.pdfFailed')} ${errMsg(e)}`, 'err'); } finally { button.disabled = mode === 'giftcards' ? !canFull : !current; }
  }
  const pdfSrvBtn = btn('r-pdf-server', t('r.pdfServer'), () => grabPdf('summary', pdfSrvBtn), true);
  const txPdfBtn = btn('r-tx-pdf', rt('ui.admin.reports.tx_pdf'), () => grabPdf('transactions', txPdfBtn), !canFull);
  const pdfBtn = h('button', { type: 'button', class: 'btn tl-btn', 'data-testid': 'r-pdf', onclick: () => { document.title = `${t('nav')} – ${current ? periodLabel(current) : ''}`; window.print(); } },
    h('span', { class: 'tl-ico', 'aria-hidden': 'true' }, icon('print', 20)), h('span', { text: t('r.pdf') }));
  const gcFilter = h('select', { 'data-testid': 'r-gc-filter', 'aria-label': rt('ui.admin.reports.gc_filter'), onchange: (e) => { st.gc = e.target.value; loadGc(); } }, [['open', 'gc_open'], ['used', 'gc_used'], ['all', 'gc_all']].map(([v, k]) => h('option', { value: v, text: rt(`ui.admin.reports.${k}`) })));
  const gcCsvBtn = btn('r-gc-csv', rt('ui.admin.reports.gc_csv'), async () => {
    gcCsvBtn.disabled = true;
    try { const res = await api.reportGiftCards(st.gc, 'csv'); downloadCsv(res.filename, res.content); } catch (e) { toast(errMsg(e), 'err'); } finally { gcCsvBtn.disabled = !canFull; }
  }, !canFull);
  const gcPdfBtn = btn('r-gc-pdf', rt('ui.admin.reports.gc_pdf'), () => grabPdf('giftcards', gcPdfBtn), !canFull);
  syncKind();
  const controls = h('div', { class: 'tl-toolbar tl-r-controls tl-noprint' }, h('div', { class: 'fld' }, h('span', { text: t('r.type') }), h('div', { role: 'radiogroup', 'aria-label': t('r.type'), class: 'tl-segs' }, ...KINDS.map((k) => kindBtns[k]))), h('div', { class: 'fld' }, h('span', { text: rt('ui.admin.reports.sales_tab') }), h('div', { role: 'radiogroup', 'aria-label': rt('ui.admin.reports.sales_tab'), class: 'tl-segs', 'data-testid': 'r-sections' }, sectionBtns.sales, sectionBtns.methods)), dayFld, monFld, rangeFld,
    h('div', { class: 'tl-actions' }, csvBtn, sumCsvBtn, methodsCsvBtn, pdfSrvBtn, txPdfBtn, pdfBtn), h('p', { class: 'muted tl-hint', text: t('r.pdfNote') }), canFull ? null : h('p', { class: 'tl-hint', role: 'note', 'data-testid': 'r-limited', text: t('r.limited') }));
  const gcPanel = h('section', { class: 'tl-sec tl-noprint', 'data-testid': 'r-gc' }, h('h3', { text: rt('ui.admin.reports.gc_title') }), h('div', { class: 'tl-toolbar' }, h('label', { class: 'fld' }, h('span', { text: rt('ui.admin.reports.gc_filter') }), gcFilter), gcCsvBtn, gcPdfBtn), gcOut);
  const node = h('div', { class: 'tl-tab', 'data-testid': 'tab-reports' }, controls, out, gcPanel);
  return { node, load: () => Promise.all([loadSales(), loadGc()]) };
}
