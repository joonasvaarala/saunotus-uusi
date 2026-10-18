// Talous: myyntikäyrä välilehtien yläpuolella. Data: api.salesChart → admin_sales_chart (vain reports.view).
// SVG (ei uutta kirjastokirjastoa). Kuukausien nimet Intlistä (talous-i18n-kieli). Tekstit: sales-chart-texts.js.
// Pystyakseli: euromäärät CSS-pikseleinä (luettavat 390 ja 1280 px), pylväät chartScale-maksimiin.
import { h, todayHel } from '../ui.js';
import { fmt, getLang } from '../talous-i18n.js';
import { FeatureNotReady } from '../talous-api.js';
import { chartText, loadSalesChartTexts } from '../sales-chart-texts.js';
import { chartScale, formatAxisEuro, visibleNodes } from '../sales-chart-logic.js';
const NS = 'http://www.w3.org/2000/svg';
const NET = '#2B3A30', VAT = '#C4A574', UNSPLIT = '#8A8175', AXIS = '#6B5E52';

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

// Kuukausinimet ovat SVG:n alareunassa (padB). Akselin luku on CSS-pikseleitä, joten padL mitataan tekstin leveydestä.
const W = 720, H = 240, padR = 8, padT = 18, padB = 16;

function tickFontPx() {
  const vw = typeof window !== 'undefined' && typeof window.innerWidth === 'number' ? window.innerWidth : 0;
  return vw > 0 && vw <= 420 ? 11 : 12;
}

function labelWidthPx(text, fontPx) {
  if (typeof document === 'undefined' || !document.body || typeof document.body.append !== 'function') return 0;
  const probe = document.createElement('span');
  probe.setAttribute('style', `position:absolute;left:0;top:-1000px;visibility:hidden;white-space:nowrap;font:${fontPx}px/1 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;font-variant-numeric:tabular-nums`);
  probe.textContent = text;
  let w = 0;
  try {
    document.body.append(probe);
    w = probe.getBoundingClientRect ? probe.getBoundingClientRect().width : 0;
  } catch { w = 0; } finally { probe.remove?.(); }
  return w || 0;
}

function axisPad(ticks, hostW) {
  const fontPx = tickFontPx();
  const longest = ticks.reduce((a, t) => (formatAxisEuro(t).length > a.length ? formatAxisEuro(t) : a), '');
  const measured = hostW > 0 ? labelWidthPx(longest, fontPx) : 0;
  const textPx = measured > 0 ? measured : Math.ceil(longest.length * fontPx * 0.58);
  const width = hostW > 0 ? hostW : 330;
  const pad = Math.ceil((textPx + 10) / (width / W));
  return Math.max(56, Math.min(Math.round(W * 0.46), pad));
}

function plot(data, hostW, pin) {
  const scale = chartScale(data.months);
  const padL = axisPad(scale.ticks, hostW);
  const plotH = H - padB, innerW = W - padL - padR, innerH = H - padT - padB;
  const slot = innerW / 12, bw = Math.min(36, slot * 0.62);
  const span = (scale.max - scale.min) || 1;
  const yOf = (v) => padT + (scale.max - v) / span * innerH;
  const future = (m) => data.year > helYear() || (data.year === helYear() && m > helMonth());
  const label = chartText('ui.admin.sales_chart.chart_label');
  const axisName = chartText('ui.admin.sales_chart.axis_label');
  const aria = axisName ? `${label}, ${axisName}` : label;
  const root = svg('svg', {
    viewBox: `0 0 ${W} ${H}`, class: 'tl-sales-svg', role: 'img', 'aria-label': aria, overflow: 'visible',
    'data-testid': 'sales-chart-svg', 'data-axis-max': scale.max, 'data-axis-min': scale.min,
    'data-inner': innerH, 'data-ticks': scale.ticks.join(','), 'data-pad': padL,
  }, svg('title', { text: aria }));
  if (axisName) root.append(svg('desc', { text: axisName }));

  for (const t of scale.ticks) {
    const y = yOf(t);
    const zero = Math.abs(t) < 1e-9;
    root.append(svg('line', {
      class: zero ? 'tl-sales-zero' : 'tl-sales-grid',
      x1: padL, x2: W - padR, y1: y, y2: y,
      stroke: zero ? 'rgba(63,53,44,.45)' : 'rgba(63,53,44,.2)',
      'vector-effect': 'non-scaling-stroke',
      'data-testid': zero ? 'sales-chart-zero' : 'sales-chart-grid',
    }));
    root.append(svg('text', {
      class: 'tl-sales-ytick', 'data-testid': 'sales-chart-tick', x: padL - 8, y,
      'text-anchor': 'end', 'dominant-baseline': 'middle', fill: AXIS, text: formatAxisEuro(t),
    }));
  }

  const tip = h('p', { class: 'tl-sales-tip', 'data-testid': 'sales-chart-tip', role: 'status', hidden: true });
  function tipText(m) {
    const isFuture = future(m.month);
    const long = monthName(data.year, m.month, 'long');
    const shown = isFuture ? `${long} (${chartText('ui.admin.sales_chart.future')})` : long;
    const text = chartText('ui.admin.sales_chart.bar_label', {
      month: shown, net: fmt.money(m.net), vat: fmt.money(m.vat), unsplit: fmt.money(m.unsplit_gross), gross: fmt.money(m.gross),
    });
    return text == null || text === 'null' || text === 'undefined' ? '' : text;
  }
  function showTip(m, stick) {
    const text = tipText(m);
    if (!text) { tip.hidden = true; tip.textContent = ''; if (stick) pin.set(null); return; }
    tip.hidden = false;
    tip.textContent = text;
    if (stick) pin.set(m.month);
  }
  function hideTip(month) {
    if (pin.get() === month) return;
    if (pin.get() == null) { tip.hidden = true; tip.textContent = ''; }
  }

  data.months.forEach((m, i) => {
    const x = padL + i * slot + (slot - bw) / 2;
    const isFuture = future(m.month);
    const g = svg('g', {
      'data-testid': `sales-chart-bar-${m.month}`, 'data-month': m.month, 'data-gross': m.gross,
      'data-future': isFuture && !m.gross ? '1' : '0', tabindex: '0',
    });
    g.append(svg('rect', { class: 'tl-sales-hit', x: padL + i * slot, y: 0, width: slot, height: plotH, fill: 'transparent' }));
    let yUp = yOf(0), yDown = yOf(0);
    for (const [value, color] of [[m.net, NET], [m.vat, VAT], [m.unsplit_gross, UNSPLIT]]) {
      if (!value) continue;
      const hgt = Math.abs(value) / span * innerH;
      const y = value > 0 ? (yUp - hgt) : yDown;
      if (value > 0) yUp -= hgt; else yDown += hgt;
      g.append(svg('rect', { class: 'tl-sales-seg', x, y, width: bw, height: hgt, fill: color, rx: 2 }));
    }
    g.append(svg('title', { text: tipText(m) }));
    g.addEventListener('pointerenter', () => showTip(m, false));
    g.addEventListener('focus', () => showTip(m, false));
    g.addEventListener('pointerleave', () => hideTip(m.month));
    g.addEventListener('click', () => {
      if (pin.get() === m.month) { pin.set(null); tip.hidden = true; tip.textContent = ''; return; }
      showTip(m, true);
    });
    root.append(g);
  });

  const pinned = data.months.find((m) => m.month === pin.get());
  if (pinned) showTip(pinned, true);
  const months = h('div', { class: 'tl-sales-months', style: `padding-left:${(padL / W) * 100}%;padding-right:${(padR / W) * 100}%` },
    ...data.months.map((m) => {
      const isFuture = future(m.month);
      const name = monthName(data.year, m.month, 'short').replace(/\.$/, '');
      return h('button', {
        type: 'button', class: 'tl-sales-m', 'data-testid': `sales-chart-month-${m.month}`,
        style: isFuture && !m.gross ? 'opacity:.55' : null,
        onclick: () => {
          if (pin.get() === m.month) { pin.set(null); tip.hidden = true; tip.textContent = ''; return; }
          showTip(m, true);
        },
      }, name);
    }));
  return h('div', { class: 'tl-sales-figure' }, root, months, tip);
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
  let pinnedMonth = null;
  let layoutW = -1;
  let painting = false;
  let ro = null;
  const body = h('div', { 'data-testid': 'sales-chart-body' });
  const node = h('section', { class: 'tl-sales', 'data-testid': 'sales-chart', 'aria-labelledby': 'tl-sales-title' },
    h('h2', { id: 'tl-sales-title', text: chartText('ui.admin.sales_chart.title') }), body);

  function hostWidth() {
    const w = body?.clientWidth;
    return typeof w === 'number' && w > 0 ? w : 0;
  }
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
    if (painting) return;
    painting = true;
    try {
      layoutW = hostWidth();
      node.querySelector('h2').textContent = chartText('ui.admin.sales_chart.title');
      if (!data) {
        body.replaceChildren(...visibleNodes([controls(), h('p', { class: 'muted', 'data-testid': 'sales-chart-loading', text: chartText('ui.admin.sales_chart.loading') })]));
        return;
      }
      const T = data.totals || {};
      const kids = [
        controls(),
        legend(),
        plot(data, layoutW, { get: () => pinnedMonth, set: (m) => { pinnedMonth = m; } }),
        table(data),
        h('dl', { class: 'tl-sales-totals' },
          h('div', {}, h('dt', { text: chartText('ui.admin.sales_chart.total_gross') }), h('dd', { 'data-testid': 'sales-chart-total-gross', text: fmt.money(T.gross) })),
          h('div', {}, h('dt', { text: chartText('ui.admin.sales_chart.total_net') }), h('dd', { 'data-testid': 'sales-chart-total-net', text: fmt.money(T.net) })),
          h('div', {}, h('dt', { text: chartText('ui.admin.sales_chart.total_vat') }), h('dd', { 'data-testid': 'sales-chart-total-vat', text: fmt.money(T.vat) }))),
      ];
      // Tyhjä ilmoitus vain ilman myyntiä. null-lasta ei saa antaa replaceChildrenille: selain tekee siitä tekstin "null".
      if (!T.gross) kids.push(h('p', { class: 'muted', 'data-testid': 'sales-chart-empty', text: chartText('ui.admin.sales_chart.empty') }));
      kids.push(
        h('p', { class: 'tl-sales-note', 'data-testid': 'sales-chart-basis', text: chartText('ui.admin.sales_chart.basis') }),
        h('p', { class: 'tl-sales-note', 'data-testid': 'sales-chart-johku', text: chartText('ui.admin.sales_chart.includes_johku') }));
      body.replaceChildren(...visibleNodes(kids));
    } finally {
      painting = false;
      if (!(hostWidth() > 0) && typeof requestAnimationFrame === 'function') {
        requestAnimationFrame(() => { if (hostWidth() > 0 && Math.abs(hostWidth() - layoutW) > 1) paint(); });
      }
    }
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
  if (typeof ResizeObserver !== 'undefined') {
    ro = new ResizeObserver(() => {
      const w = hostWidth();
      if (w > 0 && Math.abs(w - layoutW) > 1) paint();
    });
    ro.observe(body);
  }
  paint();
  return { node, load };
}
