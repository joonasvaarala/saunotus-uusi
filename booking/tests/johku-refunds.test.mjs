import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { normReport, normJohkuRefunds, createTalousApi } from '../admin/talous-api.js';
import { createMock } from '../admin/talous-mock.js';
import { renderJohkuRefunds } from '../admin/views/johku-refunds.js';
import { setLang } from '../admin/talous-i18n.js';
import { TEXTS } from '../admin/talous-texts.js';

class El {
  constructor(tag) { this.tag = tag; this.nodeType = 1; this.attrs = {}; this.children = []; this.events = {}; }
  append(x) { this.children.push(x); }
  setAttribute(k, v) { this.attrs[k] = v; }
  addEventListener(k, fn) { this.events[k] = fn; }
  set textContent(v) { this.children = [{ textContent: String(v) }]; }
  get textContent() { return this.children.map((c) => c.textContent).join(' '); }
  all() { return [this, ...this.children.flatMap((c) => c.all ? c.all() : [])]; }
}
globalThis.document = { createElement: (t) => new El(t), createTextNode: (s) => ({ textContent: String(s) }) };
const find = (node, id) => node.all().find((x) => x.attrs['data-testid'] === id);
const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const mock = createMock({ today: '2026-11-22', n: 100 });
const call = (name, args) => mock.rpc(name, args);

test('booking_336: missing, null and empty Johku refunds are safe; totals and methods never change', () => {
  const base = { totals: { gross: 100, refunds_gross: -10 }, by_method: [{ method: 'card', gross: 100, refunds: -10 }] };
  const before = normReport(base);
  assert.equal(before.johku_refunds, null);
  for (const j of [null, [], {}, { total: '174', count: '2', rows: null, by_refund_method: null, accounting: true }]) {
    const after = normReport({ ...base, johku_refunds: j });
    assert.deepEqual(after.totals, before.totals); assert.deepEqual(after.by_method, before.by_method);
    if (after.johku_refunds) { assert.equal(after.johku_refunds.accounting, false); assert.equal(after.johku_refunds.basis, 'refund_date'); }
  }
  assert.equal(renderJohkuRefunds(null), null);
  assert.match(renderJohkuRefunds(normJohkuRefunds({})).textContent, /Ei Johku-hyvityksiä/);
});

test('daily/month/range preserve Johku block; refund date drives filtering, not created_at', async () => {
  const daily = await call('admin_report_daily', { p_date: '2026-11-21' });
  const monthly = await call('admin_report_month', { p_ym: '2026-11' });
  const range = await call('admin_report_range', { p_from: '2026-11-01', p_to: '2026-11-30' });
  assert.equal(normReport(daily).johku_refunds.total, 116);
  assert.equal(normReport(monthly).johku_refunds.total, 174);
  assert.deepEqual(normReport(monthly).johku_refunds, normReport(range).johku_refunds);
  assert.equal((await call('admin_report_daily', { p_date: '2026-11-22' })).johku_refunds.count, 0);
});

test('renderer: all row columns, separate totals, method breakdown, Helsinki time, safe text and export', async () => {
  setLang('fi');
  const r = normReport(await call('admin_report_month', { p_ym: '2026-11' }));
  r.johku_refunds.rows[0].note = '<img src=x onerror=alert(1)>';
  let exported = 0;
  const view = renderJohkuRefunds(r.johku_refunds, { canExport: true, onCsv: async () => { exported++; } });
  assert.equal(view.attrs['data-accounting'], 'false');
  assert.match(view.textContent, /Johkun kautta tulleiden varausten hyvitykset/);
  assert.match(view.textContent, /MobilePay \(Johku\)/); assert.match(view.textContent, /Pankkisiirto/);
  assert.match(view.textContent, /<img src=x onerror=alert\(1\)>/);
  assert.equal(view.all().some((x) => x.tag === 'img'), false);
  assert.match(view.textContent, /11\.15/); // 09:15Z → Helsinki 11:15
  const table = find(view, 'r-johku-refunds-rows');
  for (const x of Object.keys(r.johku_refunds.rows[0])) assert.match(table.textContent, new RegExp(TEXTS.fi[`r.johkuRefunds.${x}`].replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.match(find(view, 'r-johku-refunds-total').textContent, /174,00/);
  assert.ok(find(view, 'r-johku-refunds-methods'));
  await find(view, 'r-johku-refunds-csv').events.click(); assert.equal(exported, 1);
  assert.equal(find(renderJohkuRefunds(r.johku_refunds), 'r-johku-refunds-csv'), undefined);
  setLang('en');
  assert.match(renderJohkuRefunds(r.johku_refunds).textContent, /Refunds for bookings paid through Johku/);
  for (const k of Object.keys(TEXTS.fi).filter((k) => k.startsWith('r.johkuRefunds.'))) assert.ok(TEXTS.en[k], k);
  setLang('fi');
});

test('CSV calls the server with johku_refunds and the report period; mock has matching contract', async () => {
  const calls = [];
  const api = createTalousApi({ mock: false, rpc: async (name, args) => { calls.push([name, args]); return { filename: 'johku.csv', content: '\uFEFFtest\r\n' }; } });
  const csv = await api.reportCsv({ period: { from: '2026-11-01', to: '2026-11-30' } }, 'johku_refunds');
  assert.equal(csv.filename, 'johku.csv');
  assert.deepEqual(calls[0], ['admin_report_csv', { p_from: '2026-11-01', p_to: '2026-11-30', p_kind: 'johku_refunds' }]);
  const example = await call('admin_report_csv', calls[0][1]);
  assert.match(example.content, /hyvityspvm;johku_tilaus;tilaus;asiakas;summa;alkuperainen_maksutapa;hyvitystapa;selite/);
  assert.match(example.content, /yhteensa;;;;174,00/);
  const ui = read('../admin/views/talous-reports.js');
  assert.match(ui, /renderJohkuRefunds\(data\.johku_refunds/);
  assert.match(ui, /api\.reportCsv\(\{ period: span \}, 'johku_refunds'\)/);
  assert.match(ui, /downloadCsv as saveCsv/); // no recursive shadowing of the file downloader
});

test('335/336 are byte-identical deployed migrations; rollbacks outside migration discovery', () => {
  for (const [path, md5] of [
    ['migrations/20261122090422_booking_336_johku_refunds.sql', '4f262fb657843e88578f44ce324064de'],
    ['rollbacks/20261122090422_booking_336_ROLLBACK.sql', 'add74ad7e546b47cc58e0a2185dcdc31'],
    ['migrations/20261121192641_booking_335_voucher_claims_webhook.sql', '28a3373114dbd9c7c3354e974844df80'],
    ['rollbacks/20261121192641_booking_335_ROLLBACK.sql', 'd85b3ee509dcbaf068baf90c70032b91'],
  ]) assert.equal(createHash('md5').update(read(`../supabase/${path}`)).digest('hex'), md5, path);
});
