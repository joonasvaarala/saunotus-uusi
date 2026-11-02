// booking_222–224: raporttivalitsin, lahjakortin arvoseteli ja lasku ilman K-kuittia.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { inflateSync } from 'node:zlib';
import { createTalousApi } from '../admin/talous-api.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const src = (p) => readFileSync(join(root, p), 'utf8');
const { REPORT_TEXTS } = await import(pathToFileURL(join(root, 'admin/reports-texts.js')));

const ORDER = ['sales', 'service', 'giftcards', 'invoices', 'methods', 'fees', 'transactions', 'refunds', 'stats'];

test('valitsin, oletus ja kolme toimintoa', () => {
  const ui = src('admin/views/talous-reports.js');
  assert.match(ui, /const REPORTS = \['sales', 'service', 'giftcards', 'invoices', 'methods', 'fees', 'transactions', 'refunds', 'stats'\]/);
  assert.match(ui, /let report0 = REPORTS\.includes\(q0\.get\('r'\)\) \? q0\.get\('r'\) : 'sales'/);
  assert.match(ui, /data-testid': 'r-report'/);
  assert.match(ui, /r-report-\$\{id\}/);
  for (const id of ORDER) assert.match(ui, new RegExp(`'${id}'`));
  assert.match(ui, /export_pdf/);
  assert.match(ui, /export_csv/);
  assert.match(ui, /data-testid': 'r-pdf'/);
  assert.match(ui, /Laskutettu, kirjataan Procountorissa|invoiced_line/);
  assert.equal(ui.includes('r-basis-${'), false);
  const sales = ui.slice(ui.indexOf('function salesView'), ui.indexOf('function methodsView'));
  assert.equal(/johku/i.test(sales), false);
  assert.equal(sales.includes('r-by-method'), false);
});

test('pending-import-108 vastaa sanakirjaa, FI+EN, ei päällekkäin', () => {
  const rows = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-108.json'), 'utf8'));
  const taken = new Set();
  for (const f of readdirSync(join(repo, 'content'))) {
    if (f === 'site-texts.pending-import-108.json' || !/^site-texts\.(pending-import-|imported|fallback)/.test(f) || !f.endsWith('.json')) continue;
    const j = JSON.parse(readFileSync(join(repo, 'content', f), 'utf8'));
    for (const r of Array.isArray(j) ? j : (j.texts || [])) if (r?.key) taken.add(`${r.key}|${r.lang}`);
  }
  const seen = new Set();
  assert.equal(rows.length % 2, 0);
  for (const r of rows) {
    assert.equal(seen.has(`${r.key}|${r.lang}`), false, r.key);
    seen.add(`${r.key}|${r.lang}`);
    assert.equal(taken.has(`${r.key}|${r.lang}`), false, r.key);
    assert.equal(REPORT_TEXTS[r.lang][r.key], r.text, r.key);
    assert.equal(r.class, 'normal');
    assert.equal(r.kind, 'plain');
    assert.equal(r.reason, 'booking_222: raporttirakenne');
    assert.ok(r.max_len >= r.text.length, r.key);
    assert.doesNotMatch(r.text, /</);
    assert.deepEqual(r.placeholders, [...r.text.matchAll(/\{\{(?:var|setting):[a-z0-9_]+\}\}/g)].map((m) => m[0]));
  }
  assert.equal(rows.find((r) => r.key === 'ui.admin.reports.invoiced_line' && r.lang === 'fi').text, 'Laskutettu, kirjataan Procountorissa');
  assert.equal(rows.find((r) => r.key === 'ui.admin.reports.r_invoices' && r.lang === 'fi').text, 'Laskuraportti');
  const pdf = src('supabase/functions/report-pdf/texts.ts');
  for (const r of rows) assert.match(pdf, new RegExp(r.text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});

test('myynti-CSV ja laskuraportti mockissa, PDF-lajit', async () => {
  const api = createTalousApi({ mock: true });
  const csv = await api.reportCsv({ period: { from: '2026-10-01', to: '2026-10-31' } }, 'summary');
  assert.match(csv.filename, /^myynti_2026-10-01_2026-10-31\.csv$/);
  assert.equal(csv.content.includes('\r\nmaksutapa;'), false);
  assert.equal(/johku/i.test(csv.content), false);
  const inv = await api.reportInvoices('2026-04-01', '2026-04-30');
  assert.equal(inv.invoices[0].invoice_no, 'L000001');
  assert.equal(inv.invoices[0].gross, 303.5);
  assert.equal(inv.invoices[0].vat, 61.67);
  assert.equal(inv.credits[0].invoice_no, 'L000002');
  const invCsv = await api.reportInvoices('2026-04-01', '2026-04-30', 'csv');
  assert.match(invCsv.filename, /^laskut_2026-04-01_2026-04-30\.csv$/);
  assert.match(invCsv.content, /lasku;L000001/);
  assert.match(invCsv.content, /hyvitys;L000002/);
  const pdf = src('supabase/functions/report-pdf/index.ts');
  for (const kind of ['methods', 'accrual', 'invoices']) assert.match(pdf, new RegExp(`"${kind}"`));
  assert.match(pdf, /admin_report_invoices/);
  assert.match(pdf, /myynti_/);
  assert.match(pdf, /laskut_/);
  const sql = src('supabase/migrations/20261031123733_booking_224_invoice_not_receipt.sql');
  assert.match(sql, /procountor_invoice_id/);
  assert.match(sql, /procountor_export_status/);
  assert.match(sql, /INVOICE_MARK_PAID/);
  assert.doesNotMatch(sql, /_issue_receipt/);
  assert.match(src('supabase/migrations/20261031123728_booking_223_multipurpose_giftcard.sql'), /if new\.method = 'invoice' then/);
  assert.match(src('supabase/migrations/20261031123723_booking_222_report_structure.sql'), /is distinct from 'invoice'/);
  assert.match(readFileSync(join(repo, '.github/workflows/pages.yml'), 'utf8'), /raporttirakenne\.test\.mjs/);
});

function pdfStrings(bytes) {
  const raw = Buffer.from(bytes);
  const parts = [];
  let i = 0;
  while (i < raw.length) {
    const s = raw.indexOf('stream', i);
    if (s < 0) break;
    let start = s + 6;
    if (raw[start] === 13) start++;
    if (raw[start] === 10) start++;
    const end = raw.indexOf('endstream', start);
    if (end < 0) break;
    const slice = raw.subarray(start, end);
    try { parts.push(inflateSync(slice).toString('latin1')); } catch { parts.push(slice.toString('latin1')); }
    i = end + 9;
  }
  // pdf-lib kirjoittaa tekstit heksana (<...> Tj): puretaan ne luettaviksi.
  return parts.join('\n').replace(/<([0-9A-Fa-f\s]+)>/g, (_, h) => Buffer.from(h.replace(/\s+/g, ''), 'hex').toString('latin1'));
}

test('myynti-PDF ei sisällä maksutapoja eikä Johkua', () => {
  const deno = spawnSync('deno', ['eval', '--no-lock', '--node-modules-dir=none', `
    import { buildReportPdf } from ${JSON.stringify(join(root, 'supabase/functions/report-pdf/render.ts'))};
    const rep = { period: { from: '2026-04-01', to: '2026-04-30' }, totals: { receipts: 1, refund_receipts: 0, gross: 100, refunds_gross: 0, gross_after_refunds: 100, vat_after_refunds: 20.32, net_ex_vat_after_refunds: 79.68 }, by_product: [{ product: 'Sauna', quantity: 1, net: 79.68, gross: 100, vat: 20.32, rate: 25.5 }], refunds_by_product: [], by_vat_sales: [{ rate: 25.5, net: 79.68, vat: 20.32, gross: 100 }], by_vat_refunds: [], by_vat: [{ rate: 25.5, net: 79.68, vat: 20.32, gross: 100 }], gift_card_period: { sold: { lines: [] } }, reconciliation: { sales_gross: 100, refunds_gross: 0, product_gross: 100, vat_rounding: 0 }, by_method: [{ method: 'card', label: 'Kortti', gross: 100, refunds: 0 }] };
    const bytes = await buildReportPdf(rep, 'daily', 'fi');
    await Deno.writeFile('/tmp/myynti-report.pdf', bytes);
  `], { encoding: 'utf8' });
  if (deno.error && deno.error.code === 'ENOENT') {
    assert.equal(process.env.GITHUB_ACTIONS, undefined);
    const summary = src('supabase/functions/report-pdf/render.ts');
    const tail = summary.slice(summary.lastIndexOf('const gcp = rep.gift_card_period'));
    assert.equal(tail.includes('ui.admin.reports.payments'), false);
    assert.equal(tail.includes('gc_bucket_johku'), false);
    return;
  }
  assert.equal(deno.status, 0, deno.stderr || deno.stdout);
  const text = pdfStrings(readFileSync('/tmp/myynti-report.pdf'));
  assert.equal(text.includes('Maksutavat'), false);
  assert.equal(/Johku/i.test(text), false);
  assert.match(text, /Myyntiraportti/);
});

function installReportDom() {
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
    this.value = '';
  }
  El.prototype = Object.create(Node.prototype);
  Object.defineProperty(El.prototype, 'textContent', {
    get() { return textOf(this); },
    set(v) { const t = new Text(v); t.parent = this; this.children = [t]; },
  });
  El.prototype.setAttribute = function (k, v) { this.attrs[k] = String(v); if (k === 'class') this.className = String(v); };
  El.prototype.getAttribute = function (k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; };
  El.prototype.addEventListener = function (type, fn) { (this.listeners[type] ||= []).push(fn); };
  El.prototype.append = function (...items) {
    for (const item of items) {
      const n = item && item.nodeType ? item : new Text(item);
      if (n.parent) n.parent.children = n.parent.children.filter((c) => c !== n);
      n.parent = this;
      this.children.push(n);
    }
  };
  El.prototype.replaceChildren = function (...items) {
    this.children = [];
    for (const item of items) this.append(item);
  };
  const create = (tag) => new El(tag);
  globalThis.document = { createElement: create, createElementNS: (_ns, tag) => create(tag), createTextNode: (t) => new Text(t), body: create('body') };
  function walk(node, visit, acc = []) {
    if (node?.nodeType === 1) visit(node, acc);
    for (const c of node?.children || []) if (c.nodeType === 1) walk(c, visit, acc);
    return acc;
  }
  return { walk };
}

test('tapahtumaraportti: huomautus on taulukon sisar divissä ja nettosumma sulkeutuu', async () => {
  const { walk } = installReportDom();
  globalThis.location = { hash: '#/talous?r=transactions&from=2026-10-01&to=2026-10-01', search: '' };
  globalThis.history = { replaceState(_a, _b, url) { if (typeof url === 'string') location.hash = url; } };
  const { createReportsTab } = await import(pathToFileURL(join(root, 'admin/views/talous-reports.js')).href);
  const tab = createReportsTab({
    api: {
      reportTransactions: async () => ({
        rows: [
          { voucher: 'K1', date: '2026-10-01', customer: 'Aino', product: 'Löyly', quantity: 1, net: 80, vat_rate: 25.5, vat: 20.4, gross: 100.4, method: 'cash', method_label: 'Käteinen', status: 'paid', kind: 'sale' },
          { voucher: 'H1', date: '2026-10-01', customer: 'Aino', product: 'Löyly', quantity: 1, net: -40, vat_rate: 25.5, vat: -10.2, gross: -50.2, method: 'cash', method_label: 'Käteinen', status: 'paid', kind: 'refund' },
          { voucher: 'A1', date: '2026-10-01', customer: 'B', product: 'Avoin', quantity: 1, net: 10, vat_rate: 25.5, vat: 2.55, gross: 12.55, method: 'card_terminal', status: 'open', kind: 'sale' },
          { voucher: 'L1', date: '2026-10-01', customer: 'C', product: 'Kortti', quantity: 1, net: 20, vat_rate: 0, vat: 0, gross: 20, method: 'gift_card', status: 'paid', kind: 'redemption' },
        ],
      }),
    },
    canFull: true,
    ctx: { role: 'admin', can: () => true },
  });
  await tab.load();
  const byId = (id) => walk(tab.node, (el, acc) => { if (el.getAttribute('data-testid') === id) acc.push(el); });
  const table = byId('r-tx-table')[0];
  const note = walk(tab.node, (el, acc) => {
    if (el.tagName === 'P' && el.textContent.includes('eivät ole myynnin tai hyvitysten')) acc.push(el);
  })[0];
  assert.ok(table);
  assert.ok(note);
  assert.equal(note.parent, table.parent);
  assert.equal(note.parent.tagName, 'DIV');
  assert.equal(table.parent.children.includes(note), true);
  let up = note;
  while (up) { assert.notEqual(up, table); up = up.parent; }
  const net = byId('r-tx-net')[0];
  assert.match(net.textContent, /50,20/);
  const rows = walk(table, (el, acc) => { if (el.tagName === 'TR' && el.parent?.tagName === 'TBODY') acc.push(el); });
  assert.equal(rows.filter((tr) => tr.getAttribute('data-excluded') === 'true').length, 2);
  assert.equal(rows.filter((tr) => tr.getAttribute('data-excluded') == null).length, 2);
});

function flatMoney(s) { return String(s || '').replace(/[\s\u00a0\u202f]/g, ''); }

test('lahjakorttiraportti: Johku erillään tiedoksi, omat nollana näyttää selitteen', async () => {
  const { walk } = installReportDom();
  globalThis.location = { hash: '#/talous?r=giftcards&from=2026-11-01&to=2026-11-01', search: '' };
  globalThis.history = { replaceState(_a, _b, url) { if (typeof url === 'string') location.hash = url; } };
  const { createReportsTab } = await import(pathToFileURL(join(root, 'admin/views/talous-reports.js')).href);
  const johku = { opening: 15392, sold: 0, redeemed: 156, other: 0, expired: 58, closing: 15178, accounting: false };
  const mount = async (native) => {
    const tab = createReportsTab({
      api: { reportGiftCards: async () => ({ balance: { native_paid: native }, statistics: { johku: { balance: johku } }, own: { rows: [] } }) },
      canFull: true,
      ctx: { role: 'admin', can: () => true },
    });
    await tab.load();
    return tab;
  };
  const cell = (rootNode, id, label) => walk(walk(rootNode, (el, acc) => { if (el.getAttribute('data-testid') === id) acc.push(el); })[0], (el, acc) => { if (el.getAttribute('data-label') === label) acc.push(el); })[0];
  const zero = await mount({ opening: 0, sold: 0, redeemed: 0, other: 0, expired: 0, closing: 0 });
  const ownUsed = cell(zero.node, 'r-gc-balance', 'Käytetty jaksolla');
  const johkuUsed = cell(zero.node, 'r-gc-johku', 'Käytetty jaksolla');
  const johkuOpen = cell(zero.node, 'r-gc-johku', 'Alkusaldo');
  const johkuExp = cell(zero.node, 'r-gc-johku', 'Vanhentunut jaksolla');
  const johkuClose = cell(zero.node, 'r-gc-johku', 'Saldo jakson lopussa');
  assert.match(flatMoney(ownUsed.textContent), /^0,00/);
  assert.equal(flatMoney(walk(zero.node, (el, acc) => { if (el.getAttribute('data-testid') === 'r-gc-balance') acc.push(el); })[0].textContent).includes('156'), false);
  assert.match(flatMoney(johkuUsed.textContent), /156,00/);
  assert.match(flatMoney(johkuOpen.textContent), /15392,00/);
  assert.match(flatMoney(johkuExp.textContent), /58,00/);
  assert.match(flatMoney(johkuClose.textContent), /15178,00/);
  const johkuBox = walk(zero.node, (el, acc) => { if (el.getAttribute('data-testid') === 'r-gc-johku') acc.push(el); })[0];
  assert.match(johkuBox.textContent, /Johku-lahjakorttien saldo on vain tilasto/);
  assert.match(johkuBox.className, /tl-johku-block/);
  const note = walk(zero.node, (el, acc) => { if (el.getAttribute('data-testid') === 'r-gc-only-johku') acc.push(el); })[0];
  assert.equal(note.textContent, REPORT_TEXTS.fi['ui.admin.reports.gc_only_johku']);
  assert.equal(note.parent, johkuBox.parent);
  const withOwn = await mount({ opening: 0, sold: 50, redeemed: 0, other: 0, expired: 0, closing: 50 });
  assert.equal(walk(withOwn.node, (el, acc) => { if (el.getAttribute('data-testid') === 'r-gc-only-johku') acc.push(el); }).length, 0);
  assert.match(flatMoney(cell(withOwn.node, 'r-gc-johku', 'Käytetty jaksolla').textContent), /156,00/);
  const ui = src('admin/views/talous-reports.js');
  const sales = ui.slice(ui.indexOf('function salesView'), ui.indexOf('function methodsView'));
  assert.equal(/johku/i.test(sales), false);
});

test('pending-import-119 on uusi selite, FI+EN, ei päällekkäin', () => {
  const rows = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-119.json'), 'utf8'));
  const taken = new Set();
  for (const f of readdirSync(join(repo, 'content'))) {
    if (f === 'site-texts.pending-import-119.json' || !/^site-texts\.(pending-import-|imported|fallback)/.test(f) || !f.endsWith('.json')) continue;
    const j = JSON.parse(readFileSync(join(repo, 'content', f), 'utf8'));
    for (const r of Array.isArray(j) ? j : (j.texts || [])) if (r?.key) taken.add(`${r.key}|${r.lang}`);
  }
  assert.equal(rows.length, 2);
  for (const r of rows) {
    assert.equal(taken.has(`${r.key}|${r.lang}`), false, r.key);
    assert.equal(r.key, 'ui.admin.reports.gc_only_johku');
    assert.equal(REPORT_TEXTS[r.lang][r.key], r.text);
    assert.equal(r.class, 'normal');
    assert.equal(r.kind, 'plain');
    assert.ok(r.max_len >= r.text.length);
    assert.doesNotMatch(r.text, /</);
    assert.equal(/\d+[.,]\d+/.test(r.text), false);
  }
  const pdf = src('supabase/functions/report-pdf/texts.ts');
  for (const r of rows) assert.match(pdf, new RegExp(r.text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});

test('mockin lahjakorttiraportti tuo Johku-saldon, CSV ja myynti eivät', async () => {
  const api = createTalousApi({ mock: true });
  const rep = await api.reportGiftCards('all', 'json', '2026-11-01', '2026-11-01');
  assert.equal(rep.statistics.johku.balance.redeemed, 156);
  assert.equal(rep.statistics.johku.balance.expired, 58);
  assert.equal(rep.statistics.johku.balance.accounting, false);
  assert.equal(rep.balance.native_paid.accounting, true);
  const csv = await api.reportGiftCards('all', 'csv', '2026-11-01', '2026-11-01');
  assert.equal(/johku/i.test(csv.content), false);
  assert.equal(csv.content.includes('156'), false);
  const sales = await api.reportCsv({ period: { from: '2026-11-01', to: '2026-11-01' } }, 'summary');
  assert.equal(/johku/i.test(sales.content), false);
});

test('lahjakortti-PDF näyttää Johku-osion, myynti-PDF ei', () => {
  const render = src('supabase/functions/report-pdf/render.ts');
  const gift = render.slice(render.indexOf('if (kind === "giftcards")'), render.indexOf('if (kind === "invoices")'));
  assert.match(gift, /gc_johku_liability/);
  assert.match(gift, /gc_bucket_johku/);
  assert.match(gift, /gc_only_johku/);
  const salesTail = render.slice(render.lastIndexOf('const gcp = rep.gift_card_period'));
  assert.equal(salesTail.includes('gc_bucket_johku'), false);
  assert.equal(salesTail.includes('gc_johku_liability'), false);
  assert.equal(salesTail.includes('Johku'), false);
  const deno = spawnSync('deno', ['eval', '--no-lock', '--node-modules-dir=none', `
    import { buildReportPdf } from ${JSON.stringify(join(root, 'supabase/functions/report-pdf/render.ts'))};
    const rep = { period: { from: '2026-11-01', to: '2026-11-01' }, balance: { native_paid: { opening: 0, sold: 0, redeemed: 0, expired: 0, closing: 0 } }, statistics: { johku: { balance: { opening: 15392, sold: 0, redeemed: 156, expired: 58, closing: 15178 } } }, own: { rows: [] } };
    const bytes = await buildReportPdf(rep, 'giftcards', 'fi');
    await Deno.writeFile('/tmp/lahjakortit-report.pdf', bytes);
  `], { encoding: 'utf8' });
  if (deno.error && deno.error.code === 'ENOENT') {
    assert.equal(process.env.GITHUB_ACTIONS, undefined);
    return;
  }
  assert.equal(deno.status, 0, deno.stderr || deno.stdout);
  const text = pdfStrings(readFileSync('/tmp/lahjakortit-report.pdf'));
  assert.match(text, /Johku-lahjakortit/);
  assert.match(text, /156,00/);
  assert.match(text, /vain tilasto/);
  assert.match(text, /Omia maksettuja lahjakortteja ei ole/);
});
