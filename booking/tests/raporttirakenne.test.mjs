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
  const sql = src('supabase/migrations/20261031122000_booking_224_invoice_not_receipt.sql');
  assert.match(sql, /procountor_invoice_id/);
  assert.match(sql, /procountor_export_status/);
  assert.match(sql, /INVOICE_MARK_PAID/);
  assert.doesNotMatch(sql, /_issue_receipt/);
  assert.match(src('supabase/migrations/20261031121000_booking_223_multipurpose_giftcard.sql'), /if new\.method = 'invoice' then/);
  assert.match(src('supabase/migrations/20261031120000_booking_222_report_structure.sql'), /is distinct from 'invoice'/);
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
  return parts.join('\n');
}

test('myynti-PDF ei sisällä maksutapoja eikä Johkua', () => {
  const deno = spawnSync('deno', ['eval', '--no-lock', `
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
