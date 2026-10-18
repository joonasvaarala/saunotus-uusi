// Talous: myyntikäyrä välilehtien yläpuolella. Data: api.salesChart → admin_sales_chart (vain reports.view).
// SVG (ei uutta kirjastokirjastoa). Kuukausien nimet Intlistä (talous-i18n-kieli). Tekstit: sales-chart-texts.js.
import { h, todayHel } from '../ui.js';
import { fmt, getLang } from '../talous-i18n.js';
import { FeatureNotReady } from '../talous-api.js';
import { chartText, loadSalesChartTexts } from '../sales-chart-texts.js';
const NS = 'http://www.w3.org/2000/svg';
const NET = '#2B3A30', VAT = '#C4A574', UNSPLIT = '#8A8175', AXIS = '#6B5E52', ZERO = 'rgba(63,53,44,.35)';

function svg(tag, attrs, ...kids) {
  const el = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'text') el.textContent = v;
    else el.setAttribute(k, v === true ? '' : String(v));
  }
  for (const c of kids.flat()) if (c) el.append(c);
  return el;
}

const monthName = (year, month, style) => new Intl.DateTimeFormat(getLang() === 'en' ? 'en-GB' : 'fi-FI', { month: style, timeZone: 'Europe/Helsinki' }).format(new Date(Date.UTC(year, month - 1, 15)));
const helMonth = () => +todayHel().slice(5, 7);
const helYear = () => +todayHel().slice(0, 4);

function bars(data) {
  const W = 720, H = 228, padL = 8, padR = 8, padT = 12, padB = 32;
  const innerW = W - padL - padR, innerH = H - padT - padB, slot = innerW / 12, bw = Math.min(36, slot * 0.62);
  const pos = data.months.map((m) => Math.max(0, m.net) + Math.max(0, m.vat) + Math.max(0, m.unsplit_gross));
  const neg = data.months.map((m) => Math.min(0, m.net) + Math.min(0, m.vat) + Math.min(0, m.unsplit_gross));
  const maxP = Math.max(1, ...pos), maxN = Math.min(0, ...neg), span = maxP - maxN || 1;
  const y0 = padT + innerH * (maxP / span);
  const future = (m) => data.year > helYear() || (data.year === helYear() && m > helMonth());
  const label = chartText('ui.admin.sales_chart.chart_label');
  const root = svg('svg', { viewBox: `0 0 ${W} ${H}`, class: 'tl-sales-svg', role: 'img', 'aria-label': label, 'data-testid': 'sales-chart-svg' }, svg('title', { text: label }));
  root.append(svg('line', { x1: padL, x2: W - padR, y1: y0, y2: y0, stroke: ZERO, 'stroke-width': 1 }));
  data.months.forEach((m, i) => {
    const x = padL + i * slot + (slot - bw) / 2;
    const isFuture = future(m.month);
    const g = svg('g', { 'data-testid': `sales-chart-bar-${m.month}`, 'data-month': m.month, 'data-gross': m.gross, 'data-future': isFuture && !m.gross ? '1' : '0' });
    let yUp = y0, yDown = y0;
    for (const [value, color] of [[m.net, NET], [m.vat, VAT], [m.unsplit_gross, UNSPLIT]]) {
      if (!value) continue;
      const hgt = Math.abs(value) / span * innerH;
      const y = value > 0 ? (yUp - hgt) : yDown;
      if (value > 0) yUp -= hgt; else yDown += hgt;
      g.append(svg('rect', { x, y, width: bw, height: Math.max(hgt, 0.5), fill: color, rx: 2 }));
    }
    const name = monthName(data.year, m.month, 'short');
    const long = monthName(data.year, m.month, 'long');
    const shown = isFuture ? `${long} (${chartText('ui.admin.sales_chart.future')})` : long;
    g.append(svg('title', { text: chartText('ui.admin.sales_chart.bar_label', { month: shown, net: fmt.money(m.net), vat: fmt.money(m.vat), unsplit: fmt.money(m.unsplit_gross), gross: fmt.money(m.gross) }) }));
    g.append(svg('text', { x: x + bw / 2, y: H - 10, 'text-anchor': 'middle', fill: AXIS, 'font-size': 11, 'font-family': 'inherit', opacity: isFuture && !m.gross ? 0.55 : 1, text: name.replace(/\.$/, '') }));
    root.append(g);
  });
  return root;
}

function table(data) {
  const future = (m) => data.year > helYear() || (data.year === helYear() && m > helMonth());
  const head = [chartText('ui.admin.sales_chart.year'), chartText('ui.admin.sales_chart.legend_net'), chartText('ui.admin.sales_chart.legend_vat'), chartText('ui.admin.sales_chart.legend_unsplit'), chartText('ui.admin.sales_chart.total_gross')];
  return h('table', { class: 'sr', 'data-testid': 'sales-chart-table' },
    h('caption', { text: chartText('ui.admin.sales_chart.chart_label') }),
    h('thead', {}, h('tr', {}, ...head.map((t) => h('th', { scope: 'col', text: t })))),
    h('tbody', {}, ...data.months.map((m) => h('tr', {},
      h('th', { scope: 'row', text: monthName(data.year, m.month, 'long') + (future(m.month) ? ` (${chartText('ui.admin.sales_chart.future')})` : '') }),
      h('td', { text: fmt.money(m.net) }), h('td', { text: fmt.money(m.vat) }), h('td', { text: fmt.money(m.unsplit_gross) }), h('td', { text: fmt.money(m.gross) })))));
}

export function createSalesChart({ api, rpc }) {
  let year = helYear();
  let data = null;
  let seq = 0;
  const body = h('div', { 'data-testid': 'sales-chart-body' });
  const node = h('section', { class: 'tl-sales', 'data-testid': 'sales-chart', 'aria-labelledby': 'tl-sales-title' },
    h('h2', { id: 'tl-sales-title', text: chartText('ui.admin.sales_chart.title') }), body);

  function legend() {
    const item = (key, color, testid) => h('span', { class: 'tl-sales-key', 'data-testid': testid }, h('i', { class: 'tl-swatch', style: `background:${color}`, 'aria-hidden': 'true' }), chartText(key));
    return h('div', { class: 'tl-sales-legend' },
      item('ui.admin.sales_chart.legend_net', NET, 'sales-chart-legend-net'),
      item('ui.admin.sales_chart.legend_vat', VAT, 'sales-chart-legend-vat'),
      item('ui.admin.sales_chart.legend_unsplit', UNSPLIT, 'sales-chart-legend-unsplit'));
  }
  function yearsOf(d) {
    const ys = new Set(d?.years || []);
    ys.add(year);
    return [...ys].filter((y) => y >= 2000 && y <= 2100).sort((a, b) => a - b);
  }
  function controls() {
    const ys = yearsOf(data);
    const sel = h('select', { class: 'tl-sales-year', 'data-testid': 'sales-chart-year', 'aria-label': chartText('ui.admin.sales_chart.year'), onchange: (e) => { year = +e.target.value; load(); } },
      ...ys.map((y) => h('option', { value: String(y), selected: y === year ? true : null, text: String(y) })));
    return h('div', { class: 'tl-sales-bar' },
      h('button', { type: 'button', class: 'btn tl-sales-nav', 'data-testid': 'sales-chart-prev', 'aria-label': chartText('ui.admin.sales_chart.prev_year'), disabled: year <= 2000, onclick: () => { year -= 1; load(); } }, '‹'),
      sel,
      h('button', { type: 'button', class: 'btn tl-sales-nav', 'data-testid': 'sales-chart-next', 'aria-label': chartText('ui.admin.sales_chart.next_year'), disabled: year >= 2100, onclick: () => { year += 1; load(); } }, '›'));
  }
  function paint() {
    node.querySelector('h2').textContent = chartText('ui.admin.sales_chart.title');
    if (!data) { body.replaceChildren(controls(), h('p', { class: 'muted', 'data-testid': 'sales-chart-loading', text: chartText('ui.admin.sales_chart.loading') })); return; }
    const T = data.totals;
    body.replaceChildren(
      controls(),
      legend(),
      bars(data),
      table(data),
      h('dl', { class: 'tl-sales-totals' },
        h('div', {}, h('dt', { text: chartText('ui.admin.sales_chart.total_gross') }), h('dd', { 'data-testid': 'sales-chart-total-gross', text: fmt.money(T.gross) })),
        h('div', {}, h('dt', { text: chartText('ui.admin.sales_chart.total_net') }), h('dd', { 'data-testid': 'sales-chart-total-net', text: fmt.money(T.net) })),
        h('div', {}, h('dt', { text: chartText('ui.admin.sales_chart.total_vat') }), h('dd', { 'data-testid': 'sales-chart-total-vat', text: fmt.money(T.vat) }))),
      T.gross ? null : h('p', { class: 'muted', 'data-testid': 'sales-chart-empty', text: chartText('ui.admin.sales_chart.empty') }),
      h('p', { class: 'tl-sales-note', 'data-testid': 'sales-chart-basis', text: chartText('ui.admin.sales_chart.basis') }),
      h('p', { class: 'tl-sales-note', 'data-testid': 'sales-chart-johku', text: chartText('ui.admin.sales_chart.includes_johku') }));
  }
  function fail(e) {
    const key = e instanceof FeatureNotReady || e?.code === 'feature_not_ready' || e?.code === 'forbidden' ? 'ui.admin.sales_chart.unavailable' : 'ui.admin.sales_chart.load_failed';
    body.replaceChildren(h('p', { class: 'err', role: 'alert', 'data-testid': 'sales-chart-error', text: chartText(key) }));
  }
  async function load() {
    const my = ++seq;
    paint();
    try {
      await loadSalesChartTexts(rpc);
      const r = await api.salesChart(year);
      if (my !== seq) return;
      data = r;
      if (!r.years.includes(year)) r.years = [...r.years, year].sort((a, b) => a - b);
      paint();
    } catch (e) { if (my === seq) fail(e); }
  }
  paint();
  return { node, load };
}
