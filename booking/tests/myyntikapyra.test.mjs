// Myyntikäyrä: Johku vain käyrässä, ei myyntiraportissa eikä CSV:ssä. Ei verkkoa, ei tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const imp = (p) => import(pathToFileURL(join(root, p)));
const { createMock } = await imp('admin/talous-mock.js');
const A = await imp('admin/talous-api.js');
const L = await imp('admin/sales-chart-logic.js');
const T = await imp('admin/sales-chart-texts.js');

const round2 = (n) => Math.round((n + Number.EPSILON) * 100) / 100;

test('ALV-jako: rivien kanta, ei keksittyä kantaa, päällekkäinen kuitti ohitetaan', () => {
  assert.equal(L.lineVat(100, 25.5), 20.32);
  assert.equal(L.lineVat(50, 13.5), 5.95);
  assert.equal(L.lineVat(20, 25.5), 4.06);
  const acc = L.createAccumulator(2031);
  acc.addNative(3, 79.68, 20.32, 100);
  acc.addJohku(3, { signed: 50, lineGross: 50, lineVat: L.lineVat(50, 13.5), accounted: false });
  acc.addJohku(3, { signed: 10, lineGross: 0, lineVat: 0, accounted: false });
  acc.addJohku(3, { signed: 999, lineGross: 999, lineVat: 50, accounted: true });
  const m = acc.finish().months[2];
  assert.equal(m.native_gross, 100);
  assert.equal(m.native_vat, 20.32);
  assert.equal(m.native_net, 79.68);
  assert.equal(m.johku_gross, 50);
  assert.equal(m.johku_vat, 5.95);
  assert.equal(m.johku_net, 44.05);
  assert.equal(m.unsplit_gross, 10);
  assert.equal(m.gross, 160);
  assert.equal(round2(m.net + m.vat + m.unsplit_gross), m.gross);
  assert.equal(m.johku_gross + m.unsplit_gross, 60);
});

test('Mock: käyrän natiivi = raportin gross_after_refunds, Johku ei ole CSV:ssä eikä raportin totalsissa', async () => {
  const mock = createMock({ n: 800, seed: 11, today: '2026-10-17' });
  // Johku-tuonti on mockissa jakson alussa (2025); 2026 on pääosin uutta järjestelmää. Molemmat tarkistetaan.
  for (const year of [2025, 2026]) {
  const chart = await mock.rpc('admin_sales_chart', { p_year: year });
  assert.equal(chart.months.length, 12);
  assert.equal(chart.basis, 'cash_receipt_issued_at');
  assert.equal(chart.johku_basis, 'johku_paid_at');
  let johkuSeen = 0;
  let refundedSeen = 0;
  for (let m = 1; m <= 12; m++) {
    const ym = `${year}-${String(m).padStart(2, '0')}`;
    const rep = await mock.rpc('admin_report_month', { p_ym: ym });
    const row = chart.months[m - 1];
    assert.equal(row.native_gross, rep.totals.gross_after_refunds, `${ym} native brutto`);
    assert.equal(row.native_vat, rep.totals.vat_after_refunds, `${ym} native ALV`);
    assert.equal(row.native_net, rep.totals.net_ex_vat_after_refunds, `${ym} native netto`);
    const j = rep.statistics.johku;
    assert.equal(round2(row.johku_gross + row.unsplit_gross), round2(j.gross), `${ym} Johku = statistics.johku.gross`);
    assert.equal(round2(row.net + row.vat + row.unsplit_gross), row.gross, `${ym} pino`);
    johkuSeen += j.gross;
    refundedSeen += j.refunded_gross;
    const csv = await mock.rpc('admin_report_csv', { p_from: `${ym}-01`, p_to: `${ym}-28` });
    assert.equal(/johku/i.test(csv.content), false, `${ym} CSV`);
    const johkuNos = mock.orders.filter((o) => o.johku && o.johku.paid_date.startsWith(ym)).map((o) => o.order_no);
    for (const no of johkuNos) assert.equal(csv.content.includes(`;${no};`), false, `tilaus ${no}`);
  }
  if (year === 2025) {
    assert.ok(johkuSeen > 0, '2025:ssä on Johku-myyntiä');
    assert.ok(refundedSeen > 0, '2025:ssä on kokonaan hyvitetty Johku-tilaus, eikä se vähennä käyrää');
  }
  assert.ok(chart.months.some((row) => row.native_gross !== 0), `${year}: natiivia myyntiä`);
  }
  const gift = (await mock.rpc('admin_report_month', { p_ym: '2026-06' })).lines.some((l) => l.group === 'giftcard');
  assert.equal(typeof gift, 'boolean');
});

test('Lahjakorttirivi (ALV 0) on sekä raportissa että käyrän natiivissa, ei kahdesti käyrässä', async () => {
  const mock = createMock({ n: 800, seed: 11, today: '2026-10-17' });
  let found = false;
  for (let m = 1; m <= 12 && !found; m++) {
    const ym = `2026-${String(m).padStart(2, '0')}`;
    const rep = await mock.rpc('admin_report_month', { p_ym: ym });
    if (!rep.lines.some((l) => l.group === 'giftcard')) continue;
    found = true;
    const chart = await mock.rpc('admin_sales_chart', { p_year: 2026 });
    assert.equal(chart.months[m - 1].native_gross, rep.totals.gross_after_refunds);
  }
  assert.equal(found, true);
});

test('Puuttuva RPC ei vaihda käyrää mock-lukuihin; kielto ei sekään', async () => {
  let mockCalled = false;
  const missing = A.createTalousApi({
    rpc: async (name) => {
      if (name === 'admin_sales_chart') {
        const e = new Error('Could not find the function booking.admin_sales_chart in the schema cache');
        e.status = 404; e.code = 'PGRST202'; throw e;
      }
      return { totals: {}, period: {} };
    },
    mock: false,
    mockFactory: () => { mockCalled = true; return createMock({ n: 10, today: '2026-10-17' }); },
  });
  await assert.rejects(() => missing.salesChart(2026), (e) => e instanceof A.FeatureNotReady);
  assert.equal(mockCalled, false);
  assert.equal(missing.reason, null);

  const denied = A.createTalousApi({
    rpc: async () => { const e = new Error('Ei oikeuksia'); e.status = 403; e.details = { code: 'BK001' }; throw e; },
    mock: false,
    mockFactory: () => { mockCalled = true; return createMock({ n: 10, today: '2026-10-17' }); },
  });
  await assert.rejects(() => denied.salesChart(2026), (e) => e.details?.code === 'BK001');
  assert.equal(mockCalled, false);
});

test('Migraatio ei korvaa raporttifunktioita ja vaatii reports.view', () => {
  const sql = readFileSync(join(root, 'supabase/migrations/20261018190000_booking_71_sales_chart.sql'), 'utf8');
  const rb = readFileSync(join(root, 'supabase/rollbacks/20261018190000_booking_71_ROLLBACK.sql'), 'utf8');
  assert.match(sql, /admin_sales_chart\(p_year integer\)/);
  assert.match(sql, /_require_permission\('reports\.view'\)/);
  assert.match(sql, /revoke all on function booking\.admin_sales_chart\(integer\) from public, anon, authenticated/);
  assert.match(sql, /grant execute on function booking\.admin_sales_chart\(integer\) to authenticated/);
  assert.match(sql, /payment_status in \('paid', 'partially_refunded'\)/);
  assert.doesNotMatch(sql, /payment_status in \('paid', 'partially_refunded', 'refunded'\)/);
  assert.doesNotMatch(sql, /then -j\.amt/);
  assert.match(sql, /not exists/);
  assert.match(sql, /_acct_excluded/);
  assert.match(sql, /cash_receipt_issued_at/);
  assert.doesNotMatch(sql, /create\s+(or\s+replace\s+)?function\s+booking\.(admin_report_|_report_json)/i);
  assert.match(rb, /drop function if exists booking\.admin_sales_chart\(integer\)/);
  assert.doesNotMatch(rb, /create\s+(or\s+replace\s+)?function/i);
  const ui = readFileSync(join(root, 'admin/views/talous.js'), 'utf8');
  assert.match(ui, /canFull \? createSalesChart/);
  assert.match(ui, /chart\?\.node, list/);
  const view = readFileSync(join(root, 'admin/views/talous-sales-chart.js'), 'utf8');
  assert.match(view, /createElementNS/);
  assert.doesNotMatch(view, /createElement\(\s*['"]svg['"]\s*\)/);
  assert.match(view, /chartScale/);
  assert.match(view, /visibleNodes/);
  assert.doesNotMatch(view, /\? null :/);
});

test('Tekstit FI+EN ja tuontitiedostot 4 ja 7 vastaavat sanakirjaa', () => {
  const fi = Object.keys(T.SALES_CHART_TEXTS.fi).sort();
  const en = Object.keys(T.SALES_CHART_TEXTS.en).sort();
  assert.deepEqual(fi, en);
  assert.ok(fi.every((k) => k.startsWith('ui.admin.sales_chart.')));
  const rows4 = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-4.json'), 'utf8')).filter((r) => r.key.startsWith('ui.admin.sales_chart.'));
  const rows7 = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-7.json'), 'utf8'));
  assert.ok(rows7.length > 0 && rows7.length % 2 === 0);
  assert.ok(rows7.every((r) => r.key.startsWith('ui.admin.sales_chart.')));
  const keys4 = new Set(rows4.map((r) => r.key));
  const keys7 = new Set(rows7.map((r) => r.key));
  for (const k of keys7) assert.equal(keys4.has(k), false, `${k} on jo tiedostossa 4`);
  assert.deepEqual([...new Set([...keys4, ...keys7])].sort(), fi);
  for (const row of [...rows4, ...rows7]) {
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.equal(row.text, T.SALES_CHART_TEXTS[row.lang][row.key]);
    assert.ok(row.text.length <= row.max_len);
    assert.equal(/[€]|<\w|https?:/.test(row.text), false);
    const ph = [...row.text.matchAll(/\{\{var:[a-z0-9_]+\}\}/g)].map((m) => m[0]);
    assert.deepEqual(row.placeholders, ph);
  }
  T.clearSalesChartTextCache();
  assert.equal(T.chartText('ui.admin.sales_chart.title', null, 'en'), 'Sales and VAT');
  assert.equal(T.chartText('ui.admin.sales_chart.axis_label', null, 'fi'), 'Euroa');
  assert.equal(T.chartText('ui.admin.sales_chart.axis_label', null, 'en'), 'Euros');
  assert.equal(T.chartText('ui.admin.sales_chart.missing', null, 'fi'), 'ui.admin.sales_chart.missing');
});

test('Tekstihaku: peitto onnistuu, virhe käyttää sanakirjaa', async () => {
  T.clearSalesChartTextCache();
  const ok = await T.loadSalesChartTexts(async () => ({ ok: true, texts: [{ key: 'ui.admin.sales_chart.title', lang: 'fi', text: 'Vuoden pylväs' }, { key: 'ui.other.x', lang: 'fi', text: 'ei' }] }));
  assert.equal(ok, true);
  assert.equal(T.chartText('ui.admin.sales_chart.title', null, 'fi'), 'Vuoden pylväs');
  assert.equal(T.chartText('ui.admin.sales_chart.legend_net', null, 'fi'), 'Myynti ilman ALV');
  T.clearSalesChartTextCache();
  const bad = await T.loadSalesChartTexts(async () => { throw new Error('verkko'); });
  assert.equal(bad, false);
  assert.equal(T.chartText('ui.admin.sales_chart.title', null, 'fi'), 'Myynti ja ALV');
  const filled = T.chartText('ui.admin.sales_chart.bar_label', { month: 'maaliskuu', net: '1 €', vat: '2 €', unsplit: '0 €', gross: '3 €' }, 'fi');
  assert.match(filled, /maaliskuu/);
  assert.doesNotMatch(filled, /\{\{/);
});

const space = (s) => String(s).replace(/\s/g, ' ').trim();

test('Akseli: siisti maksimi ja 3–5 tasajakoa, suomalainen euro', () => {
  assert.deepEqual(L.salesAxis(10000), { max: 10000, step: 5000, ticks: [0, 5000, 10000] });
  assert.deepEqual(L.salesAxis(0).ticks, [0, 500, 1000]);
  assert.equal(L.salesAxis(0).max, 1000);
  const seven = L.salesAxis(7200);
  assert.equal(seven.max, 7500);
  assert.deepEqual(seven.ticks, [0, 2500, 5000, 7500]);
  assert.ok(seven.max >= 7200 && seven.max < 7200 * 1.2);
  for (const peak of [0.4, 1, 3, 7, 9, 20, 50, 99, 100, 640, 1234, 4999, 5000, 7200, 9999, 10000, 12345, 100000, 123456.78]) {
    const ax = L.salesAxis(peak);
    assert.ok(ax.max + 1e-8 >= peak, `${peak} max ${ax.max}`);
    assert.ok(ax.ticks.length >= 3 && ax.ticks.length <= 5, `${peak} ${ax.ticks}`);
    assert.equal(ax.ticks[0], 0);
    assert.equal(ax.ticks.at(-1), ax.max);
    const step = ax.ticks[1] - ax.ticks[0];
    ax.ticks.forEach((t, i) => assert.ok(Math.abs(t - step * i) < 1e-6, `${peak} ${ax.ticks}`));
    const exp = Math.floor(Math.log10(step));
    const frac = step / 10 ** exp;
    assert.ok([1, 2, 2.5, 5, 10].some((n) => Math.abs(frac - n) < 1e-6), `${peak} step ${step}`);
    assert.ok(ax.max <= peak * 2 + 1e-6, `${peak} max ${ax.max}`);
  }
  assert.equal(space(L.formatAxisEuro(0)), '0 €');
  assert.equal(space(L.formatAxisEuro(5000)), '5 000 €');
  assert.equal(space(L.formatAxisEuro(10000)), '10 000 €');
  assert.equal(space(L.formatAxisEuro(2.5)), '2,5 €');
  const neg = L.chartScale([
    { net: -400, vat: -100, unsplit_gross: 0, gross: -500 },
    { net: 2400, vat: 600, unsplit_gross: 0, gross: 3000 },
  ]);
  assert.equal(neg.max, 3000);
  assert.equal(neg.min, -500);
  assert.ok(neg.ticks.includes(0));
  assert.equal(neg.ticks[0], -500);
  assert.equal(neg.ticks.at(-1), 3000);
  const span = neg.max - neg.min;
  assert.equal(3000 / span / (500 / span), 6);
});

test('visibleNodes poistaa nullin, jonka replaceChildren piirtäisi sanaksi null', () => {
  assert.deepEqual(L.visibleNodes([null, false, undefined, 0, 'a', [null, 'b']]), [0, 'a', 'b']);
  assert.equal(L.visibleNodes([null]).length, 0);
});

function installDom() {
  function textOf(node) {
    if (!node) return '';
    if (node.nodeType === 3) return node.data;
    return (node.children || []).map(textOf).join('');
  }
  function Node(type) { this.nodeType = type; this.parent = null; this.children = []; }
  function Text(data) { Node.call(this, 3); this.data = String(data); }
  Text.prototype = Object.create(Node.prototype);
  function El(tag) {
    Node.call(this, 1);
    this.tagName = String(tag).toUpperCase();
    this.attrs = {};
    this.className = '';
    this.listeners = {};
    this._hidden = false;
    this.value = '';
    this.id = '';
  }
  El.prototype = Object.create(Node.prototype);
  Object.defineProperty(El.prototype, 'textContent', {
    get() { return textOf(this); },
    set(v) { this.children = [new Text(v)]; this.children[0].parent = this; },
  });
  Object.defineProperty(El.prototype, 'hidden', {
    get() { return this._hidden; },
    set(v) { this._hidden = !!v; if (this._hidden) this.attrs.hidden = ''; else delete this.attrs.hidden; },
  });
  El.prototype.setAttribute = function (k, v) {
    this.attrs[k] = String(v);
    if (k === 'id') this.id = String(v);
    if (k === 'class') this.className = String(v);
    if (k === 'hidden') this._hidden = true;
  };
  El.prototype.getAttribute = function (k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; };
  El.prototype.addEventListener = function (type, fn) { (this.listeners[type] ||= []).push(fn); };
  El.prototype.dispatchEvent = function (ev) { for (const fn of this.listeners[ev.type] || []) fn({ ...ev, target: this, currentTarget: this }); };
  El.prototype.append = function (...items) {
    for (const item of items) {
      const n = item && item.nodeType ? item : new Text(item);
      if (n.parent) n.parent.children = n.parent.children.filter((c) => c !== n);
      n.parent = this;
      this.children.push(n);
    }
  };
  // Kuten selain: replaceChildren(null) lisää tekstisolmun "null".
  El.prototype.replaceChildren = function (...items) {
    this.children = [];
    for (const item of items) this.append(item == null ? String(item) : item);
  };
  El.prototype.querySelector = function (sel) {
    const match = (el) => {
      if (!el || el.nodeType !== 1) return false;
      if (sel.startsWith('[data-testid="') && sel.endsWith('"]')) return el.getAttribute('data-testid') === sel.slice(14, -2);
      if (sel.startsWith('.')) return (el.className || '').split(/\s+/).includes(sel.slice(1));
      if (sel.startsWith('#')) return el.id === sel.slice(1);
      return el.tagName === sel.toUpperCase();
    };
    const walk = (n) => {
      for (const c of n.children || []) {
        if (c.nodeType !== 1) continue;
        if (match(c)) return c;
        const f = walk(c);
        if (f) return f;
      }
      return null;
    };
    return walk(this);
  };
  globalThis.document = { createElement: (tag) => new El(tag), createElementNS: (_ns, tag) => new El(tag), createTextNode: (t) => new Text(t) };
}

function byClass(root, name, out = []) {
  if (root?.nodeType === 1 && (root.className || '').split(/\s+/).includes(name)) out.push(root);
  for (const c of root?.children || []) byClass(c, name, out);
  return out;
}
function byTest(root, id, out = []) {
  if (root?.nodeType === 1 && root.getAttribute?.('data-testid') === id) out.push(root);
  for (const c of root?.children || []) byTest(c, id, out);
  return out;
}
function textNodes(root, out = []) {
  if (root?.nodeType === 3) out.push(root.data);
  for (const c of root?.children || []) textNodes(c, out);
  return out;
}

function yearSample(peak) {
  const months = Array.from({ length: 12 }, (_, i) => {
    const gross = i === 5 ? peak : 1000;
    const vat = Math.round(gross * 0.2);
    const net = gross - vat;
    return { month: i + 1, net, vat, unsplit_gross: 0, gross, native_net: net, native_vat: vat, native_gross: gross, johku_net: 0, johku_vat: 0, johku_gross: 0 };
  });
  const totals = months.reduce((t, m) => ({ gross: t.gross + m.gross, net: t.net + m.net, vat: t.vat + m.vat }), { gross: 0, net: 0, vat: 0 });
  return { year: 2026, years: [2025, 2026], months, totals };
}

test('Käyrä ei piirrä sanaa null, akseli on euroina ja pylväs pysyy asteikossa', async () => {
  installDom();
  const I18 = await imp('admin/talous-i18n.js');
  I18.setLang('fi');
  T.clearSalesChartTextCache();
  const View = await imp('admin/views/talous-sales-chart.js');
  const sample = yearSample(7200);
  const chart = View.createSalesChart({
    api: { salesChart: async () => sample },
    rpc: async () => ({ ok: false }),
  });
  await chart.load();
  assert.equal(textNodes(chart.node).some((t) => t.trim() === 'null' || t.trim() === 'undefined'), false);
  const body = byTest(chart.node, 'sales-chart-body')[0];
  const totals = body.children.find((n) => (n.className || '').includes('tl-sales-totals'));
  const basis = byTest(body, 'sales-chart-basis')[0];
  const between = body.children.slice(body.children.indexOf(totals) + 1, body.children.indexOf(basis));
  assert.deepEqual(between, []);
  assert.match(basis.textContent, /Kassaperuste/);
  const svg = byTest(chart.node, 'sales-chart-svg')[0];
  const scale = L.chartScale(sample.months);
  assert.equal(svg.getAttribute('data-axis-max'), String(scale.max));
  assert.equal(svg.getAttribute('data-ticks'), scale.ticks.join(','));
  assert.deepEqual(byClass(svg, 'tl-sales-ytick').map((n) => space(n.textContent)), scale.ticks.map((t) => space(L.formatAxisEuro(t))));
  assert.equal(byClass(svg, 'tl-sales-grid').length + byClass(svg, 'tl-sales-zero').length, scale.ticks.length);
  const inner = +svg.getAttribute('data-inner');
  const span = scale.max - scale.min;
  const heightOf = (month) => byClass(byTest(svg, `sales-chart-bar-${month}`)[0], 'tl-sales-seg').reduce((s, r) => s + Number(r.getAttribute('height')), 0);
  const big = heightOf(6), small = heightOf(1);
  assert.ok(Math.abs(big - 7200 / span * inner) < 0.02, `iso ${big}`);
  assert.ok(Math.abs(small - 1000 / span * inner) < 0.02, `pieni ${small}`);
  assert.ok(big < inner, 'pylväs ei veny raakahuippuun, kun siisti maksimi on suurempi');
  assert.ok(Math.abs(big / small - 7.2) < 0.001);
  const bar = byTest(svg, 'sales-chart-bar-6')[0];
  const tip = byTest(chart.node, 'sales-chart-tip')[0];
  assert.equal(tip.hidden, true);
  bar.dispatchEvent({ type: 'pointerenter' });
  assert.equal(tip.hidden, false);
  assert.ok(space(tip.textContent).includes(space(I18.fmt.money(7200))));
  assert.ok(space(tip.textContent).includes(space(I18.fmt.money(5760))));
  assert.ok(space(tip.textContent).includes(space(I18.fmt.money(1440))));
  assert.doesNotMatch(tip.textContent, /\bnull\b/);
  bar.dispatchEvent({ type: 'pointerleave' });
  assert.equal(tip.hidden, true);
  bar.dispatchEvent({ type: 'click' });
  assert.equal(tip.hidden, false);
  bar.dispatchEvent({ type: 'pointerleave' });
  assert.equal(tip.hidden, false);

  const empty = View.createSalesChart({
    api: { salesChart: async () => ({ year: 2026, years: [2026], totals: { gross: 0, net: 0, vat: 0 }, months: yearSample(0).months.map((m) => ({ ...m, net: 0, vat: 0, gross: 0 })) }) },
    rpc: async () => ({ ok: false }),
  });
  await empty.load();
  assert.equal(textNodes(empty.node).some((t) => t.trim() === 'null' || t.trim() === 'undefined'), false);
  const emptyNote = byTest(empty.node, 'sales-chart-empty')[0];
  assert.ok(emptyNote);
  assert.match(emptyNote.textContent, /ei ole myyntiä/);
  assert.notEqual(emptyNote.textContent.trim(), 'null');
});
