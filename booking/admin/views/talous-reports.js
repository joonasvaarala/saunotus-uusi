// Talous › Raportit: päivä- tai kuukausiraportti (kassaperuste: kuitin päivä), ALV-kannoittain ja maksutavoittain, CSV-lataus ja PDF (selaimen tulostus).
// Data: api.reportDaily/reportMonthly (sopimus: admin_report_daily/admin_report_month → totals, by_method, by_vat, by_method_vat, by_category, receipts|by_day, open). Raportit ovat vaihe D:tä → palvelimelta puuttuessaan mock + ilmoitus.
import { h, toast, errMsg, todayHel } from '../ui.js';
import { icon } from '../icons.js';
import { t, fmt, has } from '../talous-i18n.js';
import { toCsv, downloadCsv } from '../csv.js';
import { methodLabel, loading, emptyBox, errorBox } from './talous-ui.js';
import { TEXTS } from '../talous-texts.js';

const fiMethod = (c) => TEXTS.fi[`method.${c}`] || c;
const fiGroup = (c) => TEXTS.fi[`group.${c}`] || c;
export function createReportsTab({ api }) {
  const today = todayHel();
  const st = { kind: 'daily', date: today, year: +today.slice(0, 4), month: +today.slice(5, 7) };
  const out = h('div', { class: 'tl-report', 'data-testid': 'report-out' });
  let seq = 0, current = null;
  const ym = () => `${st.year}-${String(st.month).padStart(2, '0')}`;
  const isEmpty = (r) => !r.totals.receipts && !r.totals.refund_receipts;
  async function load() {
    const my = ++seq; current = null; csvBtn.disabled = true; out.replaceChildren(loading());
    try {
      const r = st.kind === 'daily' ? await api.reportDaily(st.date) : await api.reportMonthly(ym());
      if (my !== seq) return;
      current = r; csvBtn.disabled = isEmpty(r); out.replaceChildren(view(r));
    } catch (e) { if (my === seq) out.replaceChildren(errorBox(e, load)); }
  }
  const periodLabel = (r) => (r.period.kind === 'day' ? fmt.date(r.period.from) : `${fmt.month(r.period.from.slice(0, 7))} (${fmt.date(r.period.from)} – ${fmt.date(r.period.to)})`);
  function view(r) {
    const M = fmt.money, T = r.totals;
    const head = h('header', { class: 'tl-report-head' }, h('h2', { 'data-testid': 'report-title', text: `${t(r.period.kind === 'day' ? 'r.daily' : 'r.monthly')}: ${periodLabel(r)}` }), h('p', { class: 'muted', text: t('r.basis') }));
    const open = h('p', { class: 'muted', 'data-testid': 'r-open', text: `${t('r.open')}: ${t('r.openVal', { n: fmt.int(r.open.orders), sum: M(r.open.unpaid) })}` });
    if (isEmpty(r)) return h('div', {}, head, emptyBox(t('r.empty')), open);
    const card = (label, value, tid) => h('div', { class: 'tl-stat' }, h('dt', { text: label }), h('dd', { 'data-testid': tid, text: value }));
    const stats = h('dl', { class: 'tl-stats' }, card(t('r.gross'), M(T.gross), 'r-gross'), card(t('r.refunds'), M(T.refunds_gross), 'r-refunds'), card(t('r.netAfter'), M(T.net_after_refunds), 'r-net'), card(t('r.vatAfter'), M(T.vat_after_refunds), 'r-vat'), card(t('r.netExVat'), M(T.net_ex_vat_after_refunds), 'r-net-ex-vat'),
      card(t('r.receipts'), fmt.int(T.receipts), 'r-receipts'), card(t('r.refundReceipts'), fmt.int(T.refund_receipts), 'r-refund-receipts'), ...(T.rounding ? [card(t('r.rounding'), M(T.rounding), 'r-rounding')] : []));
    const table = (testid, caption, cols, rows, foot) => h('section', { class: 'tl-sec' }, h('h3', { text: caption }), h('table', { class: 'tl-table', 'data-testid': testid },
      h('thead', {}, h('tr', {}, cols.map((c, i) => h('th', { scope: 'col', class: i ? 'r' : '', text: c })))),
      h('tbody', {}, rows.map((row) => h('tr', {}, row.map((c, i) => h(i ? 'td' : 'th', i ? { class: 'r', 'data-label': cols[i], text: c } : { scope: 'row', text: c }))))),
      foot ? h('tfoot', {}, h('tr', {}, foot.map((c, i) => h(i ? 'td' : 'th', i ? { class: 'r', 'data-label': cols[i], text: c } : { scope: 'row', text: c })))) : null));
    const sum = (rows, k) => rows.reduce((s, x) => s + x[k], 0);
    const rates = [...r.by_vat].sort((a, b) => a.rate - b.rate);
    const byVat = table('r-by-vat', t('r.byVat'), [t('r.vatRate'), t('r.gross'), t('r.net'), t('r.vat')], rates.map((v) => [fmt.pct(v.rate), M(v.gross), M(v.net), M(v.vat)]), [t('line.total'), M(sum(rates, 'gross')), M(sum(rates, 'net')), M(sum(rates, 'vat'))]);
    const cell = (m, rate) => r.by_method_vat.find((x) => x.method === m && x.rate === rate);
    const methods = r.by_method;
    const matrixRows = methods.map((m) => [methodLabel(m.method, m.label), ...rates.map((v) => { const c = cell(m.method, v.rate); return c ? M(c.gross) : '–'; }), M(r.by_method_vat.filter((x) => x.method === m.method).reduce((s, x) => s + x.gross, 0))]);
    const matrix = table('r-matrix', t('r.matrix'), [t('col.method'), ...rates.map((x) => `${t('r.vatShort')} ${fmt.pct(x.rate)}`), t('line.total')], matrixRows, [t('line.total'), ...rates.map((v) => M(v.gross)), M(sum(rates, 'gross'))]);
    const byMethod = table('r-by-method', t('r.byMethod'), [t('col.method'), t('r.payments'), t('r.gross'), t('r.refunds')], methods.map((m) => [methodLabel(m.method, m.label), fmt.int(m.payments), M(m.gross), M(m.refunds)]), [t('line.total'), fmt.int(sum(methods, 'payments')), M(sum(methods, 'gross')), M(sum(methods, 'refunds'))]);
    const cats = new Map(); for (const c of r.by_category) { const x = cats.get(c.category) || { label: c.label || c.category, quantity: 0, gross: 0 }; x.quantity += c.quantity; x.gross += c.gross; cats.set(c.category, x); }
    const byCat = table('r-by-group', t('r.byGroup'), [t('r.group'), t('r.qty'), t('r.gross')], [...cats.entries()].sort((a, b) => b[1].gross - a[1].gross).map(([k, x]) => [has(`group.${k}`) ? t(`group.${k}`) : x.label, fmt.int(x.quantity), M(x.gross)]));
    const byDay = r.by_day?.length ? table('r-daily', t('r.dailyBreakdown'), [t('r.date'), t('r.receipts'), t('r.gross'), t('r.refunds')], r.by_day.map((d) => [fmt.date(d.date), fmt.int(d.receipts), M(d.gross), M(d.refunds)])) : null;
    const receipts = r.receipts?.length ? table('r-receipts-list', t('r.receiptsList'), [t('receipt'), t('col.time'), t('col.order'), t('col.method'), t('r.gross')], r.receipts.map((x) => [x.receipt_no, fmt.dt(x.issued_at), x.order_no != null ? `#${x.order_no}` : '–', methodLabel(x.method), M(x.gross)])) : null;
    return h('div', {}, head, stats, byVat, matrix, byMethod, byCat, byDay, receipts, open);
  }

  // ---- valitsimet ----
  const kindBtn = (k) => h('button', { type: 'button', role: 'radio', class: 'tl-seg', 'aria-checked': String(st.kind === k), 'data-testid': `r-kind-${k}`, onclick: () => { st.kind = k; syncKind(); load(); } }, t(k === 'daily' ? 'r.daily' : 'r.monthly'));
  const kindBtns = { daily: kindBtn('daily'), monthly: kindBtn('monthly') };
  const dateIn = h('input', { type: 'date', value: st.date, max: today, 'data-testid': 'r-date', 'aria-label': t('r.date'), onchange: (e) => { if (e.target.value) { st.date = e.target.value; load(); } } });
  const monthSel = h('select', { 'data-testid': 'r-month', 'aria-label': t('r.month'), onchange: (e) => { st.month = +e.target.value; load(); } }, Array.from({ length: 12 }, (_, i) => h('option', { value: i + 1, text: fmt.month(`2026-${String(i + 1).padStart(2, '0')}`).replace(/\s*\d{4}$/, '').replace(/^./, (c) => c.toUpperCase()) })));
  monthSel.value = st.month;
  const years = [st.year - 2, st.year - 1, st.year].filter((y) => y >= 2024);
  const yearSel = h('select', { 'data-testid': 'r-year', 'aria-label': t('r.year'), onchange: (e) => { st.year = +e.target.value; load(); } }, years.map((y) => h('option', { value: y, text: String(y) })));
  yearSel.value = st.year;
  const dayFld = h('label', { class: 'fld tl-r-day' }, h('span', { text: t('r.date') }), dateIn);
  const monFld = h('div', { class: 'fld tl-r-mon' }, h('span', { text: t('r.month') }), h('div', { class: 'tl-sortrow' }, monthSel, yearSel));
  const syncKind = () => { for (const k of ['daily', 'monthly']) kindBtns[k].setAttribute('aria-checked', String(st.kind === k)); dayFld.hidden = st.kind !== 'daily'; monFld.hidden = st.kind !== 'monthly'; };
  const csvBtn = h('button', { type: 'button', class: 'btn tl-btn', 'data-testid': 'r-csv', disabled: true, onclick: async () => {
    if (!current) return;
    csvBtn.disabled = true;
    try {
      const res = await api.reportCsv(current), p = current.period;
      if (res.source === 'server') downloadCsv(res.filename, res.content);   // palvelimen admin_report_csv: sen omat sarakkeet, BOM mukana
      else downloadCsv(`raportti_${p.kind === 'day' ? 'paiva' : 'kuukausi'}_${p.kind === 'day' ? p.from : p.from.slice(0, 7)}.csv`, toCsv(res.lines.map((l) => ({ ...l, group_label: fiGroup(l.group) })), { methodLabel: fiMethod }));
    } catch (e) { toast(errMsg(e), 'err'); } finally { csvBtn.disabled = false; }
  } }, h('span', { class: 'tl-ico', 'aria-hidden': 'true' }, icon('download', 20)), h('span', { text: t('r.csv') }));
  const pdfBtn = h('button', { type: 'button', class: 'btn tl-btn', 'data-testid': 'r-pdf', onclick: () => { document.title = `${t('nav')} – ${current ? periodLabel(current) : ''}`; window.print(); } },
    h('span', { class: 'tl-ico', 'aria-hidden': 'true' }, icon('print', 20)), h('span', { text: t('r.pdf') }));
  syncKind();
  const controls = h('div', { class: 'tl-toolbar tl-r-controls tl-noprint' }, h('div', { class: 'fld' }, h('span', { text: t('r.type') }), h('div', { role: 'radiogroup', 'aria-label': t('r.type'), class: 'tl-segs' }, kindBtns.daily, kindBtns.monthly)), dayFld, monFld,
    h('div', { class: 'tl-actions' }, csvBtn, pdfBtn), h('p', { class: 'muted tl-hint', text: t('r.pdfNote') }));
  const node = h('div', { class: 'tl-tab', 'data-testid': 'tab-reports' }, controls, out);
  return { node, load };
}
