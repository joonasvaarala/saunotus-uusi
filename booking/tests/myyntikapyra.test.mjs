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
  acc.addJohku(3, { signed: -20, lineGross: 20, lineVat: L.lineVat(20, 25.5), accounted: false });
  acc.addJohku(3, { signed: 10, lineGross: 0, lineVat: 0, accounted: false });
  acc.addJohku(3, { signed: 999, lineGross: 999, lineVat: 50, accounted: true });
  const m = acc.finish().months[2];
  assert.equal(m.native_gross, 100);
  assert.equal(m.native_vat, 20.32);
  assert.equal(m.native_net, 79.68);
  assert.equal(m.johku_gross, 30);
  assert.equal(m.johku_vat, 1.89);
  assert.equal(m.johku_net, 28.11);
  assert.equal(m.unsplit_gross, 10);
  assert.equal(m.gross, 140);
  assert.equal(round2(m.net + m.vat + m.unsplit_gross), m.gross);
  assert.equal(m.johku_gross + m.unsplit_gross, 40);
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
  for (let m = 1; m <= 12; m++) {
    const ym = `${year}-${String(m).padStart(2, '0')}`;
    const rep = await mock.rpc('admin_report_month', { p_ym: ym });
    const row = chart.months[m - 1];
    assert.equal(row.native_gross, rep.totals.gross_after_refunds, `${ym} native brutto`);
    assert.equal(row.native_vat, rep.totals.vat_after_refunds, `${ym} native ALV`);
    assert.equal(row.native_net, rep.totals.net_ex_vat_after_refunds, `${ym} native netto`);
    const j = rep.statistics.johku;
    const signed = round2(j.gross - j.refunded_gross);
    assert.equal(round2(row.johku_gross + row.unsplit_gross), signed, `${ym} Johku`);
    assert.equal(round2(row.net + row.vat + row.unsplit_gross), row.gross, `${ym} pino`);
    johkuSeen += signed;
    const csv = await mock.rpc('admin_report_csv', { p_from: `${ym}-01`, p_to: `${ym}-28` });
    assert.equal(/johku/i.test(csv.content), false, `${ym} CSV`);
    const johkuNos = mock.orders.filter((o) => o.johku && o.johku.paid_date.startsWith(ym)).map((o) => o.order_no);
    for (const no of johkuNos) assert.equal(csv.content.includes(`;${no};`), false, `tilaus ${no}`);
  }
  if (year === 2025) assert.ok(johkuSeen > 0, '2025:ssä on Johku-myyntiä');
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
  const sql = readFileSync(join(root, 'supabase/migrations/20261018190000_booking_70_sales_chart.sql'), 'utf8');
  const rb = readFileSync(join(root, 'supabase/rollbacks/20261018190000_booking_70_ROLLBACK.sql'), 'utf8');
  assert.match(sql, /admin_sales_chart\(p_year integer\)/);
  assert.match(sql, /_require_permission\('reports\.view'\)/);
  assert.match(sql, /revoke all on function booking\.admin_sales_chart\(integer\) from public, anon, authenticated/);
  assert.match(sql, /grant execute on function booking\.admin_sales_chart\(integer\) to authenticated/);
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
});

test('Tekstit FI+EN ja tuontitiedosto 4 vastaavat sanakirjaa', () => {
  const fi = Object.keys(T.SALES_CHART_TEXTS.fi).sort();
  const en = Object.keys(T.SALES_CHART_TEXTS.en).sort();
  assert.deepEqual(fi, en);
  assert.ok(fi.every((k) => k.startsWith('ui.admin.sales_chart.')));
  const rows = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-4.json'), 'utf8')).filter((r) => r.key.startsWith('ui.admin.sales_chart.'));
  assert.equal(rows.length, fi.length * 2);
  for (const row of rows) {
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
