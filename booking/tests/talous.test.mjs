// Talous-kehyksen yksikkötestit (node --test): CSV (RFC 4180), yhteenvedot, mock-data (sivutus/haku/lajittelu/raportit), datakerroksen tilat, tekstien FI/EN-täsmäävyys.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const imp = (p) => import(pathToFileURL(join(root, p)));
const { toCsv, CSV_COLUMNS, fiMoney, fiNum, csvText } = await imp('admin/csv.js');
const { createMock, GROUPS } = await imp('admin/talous-mock.js');
const A = await imp('admin/talous-api.js');
const { TEXTS } = await imp('admin/talous-texts.js');
const UI = await imp('admin/views/talous-ui.js');
const { ICONS } = await imp('admin/icons.js');
const { OT } = await imp('shop/src/order-texts.js');
const OA = await imp('shop/src/order-api.js');
const { createOrderMock } = await imp('shop/src/order-mock.js');
const TODAY = '2026-10-17';
const mock = createMock({ today: TODAY });
const R = (name, args) => mock.rpc(name, args);

test('CSV: otsikko, BOM, CRLF, erotin ; ja desimaalipilkku', () => {
  assert.deepEqual(CSV_COLUMNS, ['tosite', 'pvm', 'asiakas', 'tuote', 'maara', 'netto', 'alv_%', 'alv_eur', 'brutto', 'maksutapa', 'tila', 'laji']);
  const out = toCsv([{ date: '2026-10-17', receipt_no: '2026-000001', customer: 'A', method: 'cash', product: 'Yleinen vuoro', quantity: 2, gross: 36, vat_rate: 25.5, vat: 7.31, net: 28.69 }], { methodLabel: () => 'Käteinen' });
  assert.equal(out.charCodeAt(0), 0xFEFF);
  const lines = out.slice(1).split('\r\n');
  assert.equal(lines[0], 'tosite;pvm;asiakas;tuote;maara;netto;alv_%;alv_eur;brutto;maksutapa;tila;laji');
  assert.equal(lines[1], '2026-000001;2026-10-17;A;Yleinen vuoro;2;28,69;25,5;7,31;36,00;Käteinen;maksettu;myynti');
  assert.equal(lines[2], ''); assert.equal(lines.length, 3);
  assert.ok(!/\n(?<!\r\n)/.test(out.replace(/\r\n/g, '')), 'vain CRLF-rivinvaihdot');
});
test('CSV: lainaus (RFC 4180) ja kaavainjektion esto', () => {
  assert.equal(csvText('a;b'), '"a;b"'); assert.equal(csvText('sano "hei"'), '"sano ""hei"""'); assert.equal(csvText('rivi\nuusi'), '"rivi\nuusi"');
  assert.equal(csvText('=1+1'), "'=1+1"); assert.equal(csvText('+358'), "'+358"); assert.equal(csvText('@x'), "'@x"); assert.equal(csvText('Kahvi'), 'Kahvi'); assert.equal(csvText(null), '');
  const out = toCsv([{ date: 'd', product: '=HYPERLINK("x";"y")', gross: -1, vat_rate: 0, vat: 0, net: -1, refund: 1 }]);
  assert.ok(out.includes(`"'=HYPERLINK(""x"";""y"")"`));
});
test('CSV: luvut', () => {
  assert.equal(fiMoney(1234.5), '1234,50'); assert.equal(fiMoney(-0.004), '0,00'); assert.equal(fiMoney('x'), '0,00'); assert.equal(fiMoney(0.1 + 0.2), '0,30');
  assert.equal(fiNum(25.5), '25,5'); assert.equal(fiNum(0), '0'); assert.equal(fiNum(13.5), '13,5'); assert.equal(fiNum(2), '2');
});
test('Mock-palvelin (sopimuksen muodot): 12 000 tilausta, uusin ensin, tilausnumero kasvaa ajan mukana', async () => {
  assert.equal(mock.orders.length, 12000);
  const r = await R('admin_list_orders', { p_limit: 100, p_payment_filter: 'all' });
  assert.equal(r.total, 12000); assert.equal(r.rows.length, 100);
  for (const k of ['order_id', 'order_no', 'johku_order_no', 'created_at', 'status', 'payment_status', 'source_channel', 'is_native', 'total', 'paid', 'refunded', 'unpaid', 'customer_name', 'customer_company', 'first_start', 'reservation_count', 'payment_count', 'receipt_count']) assert.ok(k in r.rows[0], k);
  for (let i = 1; i < r.rows.length; i++) { assert.ok(r.rows[i].created_at <= r.rows[i - 1].created_at); assert.ok(r.rows[i].order_no < r.rows[i - 1].order_no); }
  assert.equal((await R('admin_list_orders', { p_limit: 5000, p_payment_filter: 'all' })).rows.length, 200, 'sivukoon yläraja 200');
  assert.equal((await R('admin_list_orders', { p_payment_filter: 'all' })).rows.length, 50, 'sivukoko 50 kun koko kanta pyydetään');
});
test('Mock-palvelin: sivutus kattaa kaikki rivit kerran (25/50/100), viimeinen sivu', async () => {
  for (const limit of [25, 50, 100]) {
    const pages = Math.ceil(12000 / limit), last = await R('admin_list_orders', { p_payment_filter: 'all', p_limit: limit, p_offset: (pages - 1) * limit });
    assert.equal(last.rows.length, 12000 - (pages - 1) * limit);
    const p2 = await R('admin_list_orders', { p_payment_filter: 'all', p_limit: limit, p_offset: limit }), p1 = await R('admin_list_orders', { p_payment_filter: 'all', p_limit: limit });
    assert.ok(!p1.rows.some((a) => p2.rows.some((b) => b.order_id === a.order_id)));
  }
});
test('Mock-palvelin: haku (tilausnumero tarkka, nimi osittainen), suodattimet ja p_sort', async () => {
  const one = mock.orders[500], r = await R('admin_list_orders', { p_search: String(one.order_no), p_payment_filter: 'all', p_limit: 100 });
  assert.equal(r.total, 1); assert.equal(r.rows[0].order_id, one.order_id);
  const jo = mock.orders.find((o) => o.johku_order_no); assert.equal((await R('admin_list_orders', { p_search: `#${jo.johku_order_no}`, p_payment_filter: 'all' })).rows[0].order_id, jo.order_id);
  const last = one.customer_name.split(' ')[1].toLowerCase(), byName = await R('admin_list_orders', { p_search: last, p_payment_filter: 'all', p_limit: 100 }); assert.ok(byName.total > 10 && byName.rows.every((x) => `${x.customer_name} ${x.customer_company || ''}`.toLowerCase().includes(last)));
  const paid = await R('admin_list_orders', { p_payment_status: 'paid', p_payment_filter: 'all', p_source: 'web', p_limit: 100 }); assert.ok(paid.total > 1000 && paid.rows.every((x) => x.payment_status === 'paid' && x.source_channel === 'web'));
  const nat = await R('admin_list_orders', { p_native: false, p_payment_filter: 'all', p_limit: 100 }); assert.equal(nat.total, 3600); assert.ok(nat.rows.every((x) => !x.is_native && x.source_channel === 'johku_import'));
  const rng = await R('admin_list_orders', { p_from: '2026-09-01', p_to: '2026-09-30', p_payment_filter: 'all', p_limit: 100 }); assert.ok(rng.total > 100 && rng.total < 2000 && rng.rows.every((x) => x.created_at.slice(0, 7) === '2026-09'));
  const st = await R('admin_list_orders', { p_date_field: 'start', p_from: '2026-11-01', p_to: '2026-11-30', p_payment_filter: 'all', p_limit: 100 }); assert.ok(st.total > 50 && st.rows.every((x) => x.first_start.slice(0, 7) === '2026-11'));
  const sorts = { created: (x) => x.created_at, order_no: (x) => x.order_no, total: (x) => x.total, start: (x) => x.first_start || '', paid: (x) => x.paid };
  for (const [k, f] of Object.entries(sorts)) {
    const asc = (await R('admin_list_orders', { p_sort: `${k}_asc`, p_payment_filter: 'all', p_limit: 100 })).rows, desc = (await R('admin_list_orders', { p_sort: `${k}_desc`, p_payment_filter: 'all', p_limit: 100 })).rows;
    if (k !== 'start') { assert.ok(asc.every((x, i) => i === 0 || f(x) >= f(asc[i - 1])), `${k} asc`); assert.ok(desc.every((x, i) => i === 0 || f(x) <= f(desc[i - 1])), `${k} desc`); }
    else { assert.ok(asc.every((x, i) => i === 0 || f(x) >= f(asc[i - 1]) || !asc[i].first_start), 'start asc'); assert.ok(desc.every((x, i) => i === 0 || f(x) <= f(desc[i - 1]) || !x.first_start), 'start desc'); }
  }
  const un = (await R('admin_list_orders', { p_sort: 'unpaid_desc', p_payment_filter: 'all', p_limit: 100 })).rows; assert.ok(un.every((x, i) => i === 0 || x.unpaid <= un[i - 1].unpaid));
  await assert.rejects(() => R('admin_list_orders', { p_sort: 'unpaid_asc' }), (e) => e.code === 'invalid_sort');
  await assert.rejects(() => R('admin_list_orders', { p_sort: 'created' }), (e) => e.code === 'invalid_sort');
  await assert.rejects(() => R('admin_ei_ole_olemassa', {}), (e) => A.isMissingRpc(e));
});
test('Mock-palvelin: admin_get_order (balance, items, maksurivit) ja admin_list_payments (ei rivejä, sumat)', async () => {
  const o = await R('admin_get_order', { p_order_id: mock.payments[0].order_id });
  for (const k of ['public_token', 'order_page_path', 'is_native', 'balance', 'can_add', 'staff_can_add', 'items', 'payments', 'receipts', 'reservations', 'customer']) assert.ok(k in o, k);
  assert.deepEqual(Object.keys(o.balance).sort(), ['net_paid', 'paid', 'pending_link', 'refunded', 'total', 'unpaid', 'unpaid_unlinked']);
  assert.ok(o.payments[0].lines.length > 0 && 'amount_gross' in o.payments[0].lines[0] && !('line_vat' in o.payments[0].lines[0]));
  assert.match(o.payments[0].receipts[0].receipt_no, /^K-\d{4}-\d{6}$/);
  for (const p of mock.payments.slice(0, 400)) { const pl = (await R('admin_get_order', { p_order_id: p.order_id })).payments.find((x) => x.id === p.payment_id); assert.equal(Math.round(pl.lines.reduce((s, l) => s + l.amount_gross, 0) * 100), Math.round(p.amount * 100), `maksu ${p.payment_id}`); }
  const pr = await R('admin_list_payments', { p_limit: 25 });
  assert.ok(!('lines' in pr.rows[0]) && 'line_count' in pr.rows[0] && pr.total > 5000 && pr.sum_paid > 0 && 'sum_refunded' in pr);
  const asc = (await R('admin_list_payments', { p_sort: 'paid_asc', p_limit: 100 })).rows; assert.ok(asc.every((x, i) => i === 0 || (x.paid_at || x.created_at) >= (asc[i - 1].paid_at || asc[i - 1].created_at)));
  const am = (await R('admin_list_payments', { p_sort: 'amount_desc', p_limit: 100 })).rows; assert.ok(am.every((x, i) => i === 0 || x.amount <= am[i - 1].amount));
  const byRc = await R('admin_list_payments', { p_search: pr.rows[0].receipt_no }); assert.equal(byRc.total, 1);
  assert.ok((await R('admin_list_payments', { p_status: 'partially_refunded', p_limit: 100 })).rows.every((x) => x.status === 'partially_refunded' && x.refunded_amount > 0));
  await assert.rejects(() => R('admin_list_payments', { p_sort: 'x_desc' }), (e) => e.code === 'invalid_sort');
});
test('Mock-palvelin: raportit täsmäävät (päivä ↔ kuukausi, ALV, maksutavat, CSV-rivit)', async () => {
  const d = await R('admin_report_daily', { p_date: '2026-10-10' }), m = await R('admin_report_month', { p_ym: '2026-10' });
  for (const k of ['period', 'totals', 'by_method', 'by_vat', 'by_method_vat', 'by_category', 'open']) assert.ok(k in d, k);
  assert.ok(Array.isArray(d.receipts) && !d.by_day); assert.ok(Array.isArray(m.by_day) && !m.receipts);
  assert.ok(d.totals.receipts > 0 && d.lines.every((l) => l.date === '2026-10-10'));
  const c = (n) => Math.round(n * 100), S = (rows, k) => rows.reduce((s, x) => s + c(x[k]), 0);
  assert.equal(S(d.by_vat, 'gross'), c(d.totals.gross) + c(d.totals.refunds_gross)); assert.equal(c(d.totals.gross_after_refunds), c(d.totals.gross) + c(d.totals.refunds_gross)); assert.equal(c(d.totals.gross_after_refunds), c(d.totals.vat_after_refunds) + c(d.totals.net_ex_vat_after_refunds)); assert.equal(d.totals.net_after_refunds, d.totals.gross_after_refunds, 'deprecated-alias = sama arvo kuin palvelimella'); assert.equal(S(d.by_vat, 'vat'), c(d.totals.vat_after_refunds)); assert.equal(S(d.by_vat, 'net'), c(d.totals.net_ex_vat_after_refunds)); assert.equal(S(d.by_method_vat, 'gross'), S(d.by_vat, 'gross'));
  assert.equal(S(d.by_method, 'gross') + S(d.by_method, 'refunds'), S(d.by_vat, 'gross')); assert.equal(S(d.by_category, 'gross'), S(d.by_vat, 'gross'));
  assert.equal(S(d.receipts.filter((x) => x.kind === 'receipt'), 'gross'), c(d.totals.gross));
  assert.equal(d.totals.receipts, d.receipts.filter((x) => x.kind === 'receipt').length);
  assert.equal(m.by_day.reduce((s, x) => s + x.receipts, 0), m.totals.receipts); assert.equal(S(m.by_day, 'gross'), c(m.totals.gross)); assert.equal(m.by_day.find((x) => x.date === '2026-10-10').gross, d.totals.gross);
  const ag = await R('admin_report_month', { p_ym: '2026-08' }); assert.ok(ag.totals.refund_receipts > 0 && ag.totals.refunds_gross < 0 && ag.lines.some((l) => l.gross < 0 && l.refund > 0), 'hyvitykset negatiivisina');
  assert.ok(GROUPS.includes(ag.lines[0].group));
  await assert.rejects(() => R('admin_report_daily', { p_date: 'x' }), (e) => e.code === 'invalid_date');
  const csv = await R('admin_report_csv', { p_from: '2026-10-10', p_to: '2026-10-10' });
  assert.equal(csv.content.charCodeAt(0), 0xFEFF); assert.equal(csv.content.split('\r\n')[0].slice(1), 'tosite;pvm;asiakas;tuote;maara;netto;alv_%;alv_eur;brutto;maksutapa;tila;laji'); assert.equal(csv.content.trim().split('\r\n').length - 1, d.lines.length + d.open.rows.length);
  assert.equal(Math.round(d.reconciliation.difference * 100), 0);
  assert.ok(Array.isArray(d.by_product) && Array.isArray(d.refunds_by_product));
  assert.equal(S(d.vat_summary, 'gross'), c(d.reconciliation.product_gross));
  assert.ok(d.gift_card_period?.sold && Array.isArray(d.prepaid_redemptions.by_vat));
  const sumDay = await R('admin_report_csv', { p_from: '2026-10-10', p_to: '2026-10-10', p_kind: 'summary' });
  assert.equal(sumDay.content.includes('maksutapa;'), false);
  assert.equal(sumDay.content.includes('tasmaytys;tuotteet'), true);
  const sumMonth = await R('admin_report_csv', { p_from: '2026-10-01', p_to: '2026-10-31', p_kind: 'summary' });
  assert.equal(sumMonth.content.includes('\r\nmaksutapa;'), false);
  assert.equal(sumMonth.content.includes('johku_loppusaldo'), false);
  assert.equal(sumMonth.content.includes('tasmaytys;maksutavat'), false);
  assert.equal(sumMonth.content.includes('lahjakortti_maksuton;myonnetty'), false);
});
test('Mock-palvelin: kirjoittavat RPC:t palauttavat sopimuksen muodot ja tarkistavat summat', async () => {
  const un = mock.orders.find((o) => o.is_native && o.payment_status === 'unpaid' && o.unpaid_amount > 0), pd = mock.orders.find((o) => o.is_native && o.payment_status === 'paid' && o.payments.length);
  const a = await R('admin_add_to_order', { p_order_id: un.order_id, p_items: [{ type: 'custom', description: 'Alennus', amount: -5, vat_rate: 25.5, quantity: 1 }], p_create_link: true });
  assert.equal(a.ok, true); assert.ok(a.added[0].item_id && a.payment.link_token && a.balance.total === un.total_gross - 5);
  await assert.rejects(() => R('admin_add_to_order', { p_order_id: un.order_id, p_items: [] }), (e) => e.code === 'invalid_items');
  const l = await R('admin_create_payment_link', { p_order_id: un.order_id }); assert.equal(l.amount, un.unpaid_amount); assert.ok(l.link_token && l.link_path && 'online_payment_enabled' in l && Array.isArray(l.lines));
  await assert.rejects(() => R('admin_create_payment_link', { p_order_id: pd.order_id }), (e) => e.code === 'nothing_to_pay');
  const p = pd.payments[0], rf = await R('admin_refund', { p_payment_id: p.payment_id, p_amount: 1, p_reason: 'testi' }); assert.equal(rf.ok, true); assert.ok('refund_id' in rf && 'balance' in rf);
  await assert.rejects(() => R('admin_refund', { p_payment_id: p.payment_id, p_amount: p.amount + 1, p_reason: 'x' }), (e) => e.code === 'amount_exceeds_refundable');
  assert.ok((await R('admin_list_addons')).some((x) => x.code === 'saunavihta'));
});

test('Datakerros: lajitteluavaimet → p_sort (maksutila = unpaid_desc)', () => {
  const S = A.orderSortParam;
  assert.equal(S('created', 'desc'), 'created_desc'); assert.equal(S('created', 'asc'), 'created_asc'); assert.equal(S('order_no', 'asc'), 'order_no_asc'); assert.equal(S('total', 'desc'), 'total_desc');
  assert.equal(S('first_reservation', 'asc'), 'start_asc'); assert.equal(S('payment_status', 'asc'), 'unpaid_desc'); assert.equal(A.paymentSortParam('asc'), 'paid_asc'); assert.equal(A.paymentSortParam(), 'paid_desc');
});
test('Datakerros: ?mock=1 → mock; oikea tila lähettää sopimuksen nimet ja p_-parametrit (vain asetetut)', async () => {
  assert.equal(A.wantsMock({ search: '?mock=1', hash: '' }), true); assert.equal(A.wantsMock({ search: '', hash: '#/talous?tab=maksut&mock=1' }), true); assert.equal(A.wantsMock({ search: '', hash: '#/talous' }), false);
  const calls = [];
  const rpc = async (n, a) => { calls.push([n, a]); return n === 'admin_list_orders' || n === 'admin_list_payments' ? { total: 12000, rows: [{ order_id: 1, order_no: 5, total: 10, paid: 10, unpaid: 0, first_start: 'x', payment_status: 'paid' }] } : {}; };
  const api = A.createTalousApi({ rpc, mock: false });
  const r = await api.listOrders({ search: 'x', paymentStatus: 'paid', source: 'web', native: 'native', dateField: 'start', from: '2026-01-01', to: '2026-02-01', sortBy: 'total', sortDir: 'asc', limit: 50, offset: 100 });
  assert.equal(api.mode, 'real'); assert.equal(r.total, 12000); assert.equal(r.rows[0].total_gross, 10); assert.equal(r.rows[0].first_reservation_at, 'x');
  assert.deepEqual(calls[0], ['admin_list_orders', { p_search: 'x', p_payment_status: 'paid', p_source: 'web', p_native: true, p_date_field: 'start', p_from: '2026-01-01', p_to: '2026-02-01', p_sort: 'total_asc', p_limit: 50, p_offset: 100 }]);
  await api.listOrders({ sortBy: 'created', sortDir: 'desc', limit: 999, offset: 0 }); assert.deepEqual(calls[1], ['admin_list_orders', { p_sort: 'created_desc', p_limit: 200, p_offset: 0 }]);
  await api.listPayments({ search: 'K-1', method: 'cash', status: 'paid', sortDir: 'asc', limit: 25, offset: 0 });
  assert.deepEqual(calls[2], ['admin_list_payments', { p_search: 'K-1', p_method: 'cash', p_status: 'paid', p_sort: 'paid_asc', p_limit: 25, p_offset: 0 }]);
  await api.reportDaily('2026-10-01'); await api.reportMonthly('2026-10'); await api.getOrder(7); await api.listAddons();
  assert.deepEqual(calls.slice(3).map((c) => c[0]), ['admin_report_daily', 'admin_report_month', 'admin_get_order', 'admin_list_addons']);
  assert.deepEqual(calls[3][1], { p_date: '2026-10-01' }); assert.deepEqual(calls[4][1], { p_ym: '2026-10' }); assert.deepEqual(calls[5][1], { p_order_id: 7 });
});
test('Datakerros: kirjoittavat toiminnot – ei käyttöönottolippuja, parametrit, ei mock-varakutsua oikeassa tilassa', async () => {
  assert.equal(A.LIVE_ACTIONS, undefined, 'LIVE_ACTIONS-liput on poistettu');
  const real = A.createTalousApi({ rpc: async () => ({ ok: true }), mock: false });
  for (const k of ['addToOrder', 'createPaymentLink', 'refund', 'recordPayment', 'resendReceipt']) assert.equal(typeof real[k], 'function', k);
  assert.equal(real.actionLive, undefined);
  const calls = []; const be = A.rpcBackend(async (n, a) => { calls.push([n, a]); return { ok: true }; });
  await be.addToOrder({ orderId: 1, items: [{ type: 'addon' }], createLink: true, sendEmail: false, note: 'n' }); await be.createPaymentLink({ orderId: 1, sendEmail: true, expiresDays: 7 }); await be.refund({ paymentId: 3, amount: 4.5, reason: 'r' }); await be.reportCsv({ from: '2026-10-01', to: '2026-10-31' });
  await be.recordPayment({ orderId: 2, method: 'cash', amount: 12.5, note: 'n' }); await be.listVatRates();
  assert.deepEqual(calls, [['admin_add_to_order', { p_order_id: 1, p_items: [{ type: 'addon' }], p_create_link: true, p_note: 'n' }], ['admin_create_payment_link', { p_order_id: 1, p_send_email: true, p_expires_days: 7 }],
    ['admin_refund', { p_payment_id: 3, p_amount: 4.5, p_reason: 'r' }], ['admin_report_csv', { p_from: '2026-10-01', p_to: '2026-10-31', p_kind: 'lines' }],
    ['admin_record_payment', { p_order_id: 2, p_method: 'cash', p_amount: 12.5, p_note: 'n' }], ['admin_list_vat_rates', {}]]);
  // kirjoitus ei koskaan putoa mockiin oikeassa tilassa: puuttuva RPC → FeatureNotReady (ei näennäistä onnistumista); palvelinvirhe (BK001, status 400/404) välittyy sellaisenaan
  const miss = Object.assign(new Error('Could not find the function booking.admin_refund(p_amount, p_payment_id) in the schema cache'), { status: 404, code: 'long text', details: { code: 'PGRST202' } });
  const api1 = A.createTalousApi({ rpc: async () => { throw miss; }, mock: false });
  await assert.rejects(() => api1.refund({ paymentId: 1, amount: 1, reason: 'abc' }), (e) => e instanceof A.FeatureNotReady); assert.deepEqual(api1.missing, ['admin_refund']);
  const bk = Object.assign(new Error('Tilausta ei löydy'), { status: 404, code: 'not_found', details: { code: 'BK001', details: 'not_found' } });
  assert.ok(!A.isMissingRpc(bk), 'BK001 not_found ei ole puuttuva funktio');
  await assert.rejects(() => A.createTalousApi({ rpc: async () => { throw bk; }, mock: false }).recordPayment({ orderId: 1, method: 'cash', amount: 1 }), (e) => e.code === 'not_found');
  const m = A.createTalousApi({ mock: true, mockFactory: () => mock });
  const pd = mock.orders.find((o) => o.is_native && o.payments.some((p) => p.status === 'paid' && p.amount > 2));
  assert.equal((await m.refund({ paymentId: pd.payments.find((p) => p.status === 'paid').payment_id, amount: 1, reason: 'x' })).mock, true);
  const un = mock.orders.find((o) => o.is_native && o.unpaid_amount > 5);
  assert.equal((await m.recordPayment({ orderId: un.order_id, method: 'card_terminal', amount: 5 })).mock, true);
  await assert.rejects(() => m.recordPayment({ orderId: un.order_id, method: 'cash', amount: 5 }), (e) => e.code === 'cash_not_accepted');
  await assert.rejects(() => m.recordPayment({ orderId: un.order_id, method: 'visma_pay', amount: 5 }), (e) => e.code === 'invalid_payment_method');
  await assert.rejects(() => A.rpcBackend(async () => ({ ok: false, code: 'nothing_to_pay', message: 'Ei maksettavaa' })).createPaymentLink({ orderId: 1 }), (e) => e.code === 'nothing_to_pay' && /Ei maksettavaa/.test(e.message));
  // ALV-huomautus: normalisointi; virhe → null (ei mock-varaa); linkin isäntä order_page_path:sta (täysi osoite tai polku)
  assert.deepEqual((await m.listVatRates()).missing.map((x) => x.id), [47]);
  assert.equal(await A.createTalousApi({ rpc: async () => { throw bk; }, mock: false }).listVatRates(), null);
  assert.equal(A.siteOrigin({ order_page_path: 'https://saunotus.fi/tilaus/?t=abc' }, 'https://admin.x'), 'https://saunotus.fi');
  assert.equal(A.siteOrigin({ order_page_path: '/tilaus/?t=abc' }, 'https://admin.x'), 'https://admin.x');
  assert.equal(A.absLink('/maksa/?p=1', { order_page_path: 'https://saunotus.fi/tilaus/?t=abc' }), 'https://saunotus.fi/maksa/?p=1');
});
test('Datakerros: puuttuva RPC → vain se toiminto mockiin + ilmoitus; muu virhe ei piilotu', async () => {
  const miss = Object.assign(new Error('Could not find the function booking.admin_report_daily in the schema cache'), { status: 404, code: 'PGRST202' });
  assert.ok(A.isMissingRpc(miss)); assert.ok(!A.isMissingRpc(Object.assign(new Error('x'), { status: 400, code: 'forbidden' })));
  const mk = createMock({ today: TODAY, n: 300 }), seen = [];
  const api = A.createTalousApi({ rpc: async (n, a) => { if (n === 'admin_report_daily') throw miss; return mk.rpc(n, a); }, mock: false, mockFactory: () => mk });
  api.onMode((x) => seen.push(x.missingRpc));
  assert.equal((await api.listOrders({ limit: 25, offset: 0 })).rows.length, 25); assert.equal(api.reason, null); assert.equal(api.isMock('listOrders'), false);
  const rep = await api.reportDaily(TODAY); assert.ok(rep.totals && rep.period.from === TODAY);
  assert.equal(api.mode, 'mixed'); assert.equal(api.reason, 'missing'); assert.equal(api.missingRpc, 'admin_report_daily'); assert.deepEqual(seen, ['admin_report_daily']); assert.equal(api.isMock('reportDaily'), true); assert.equal(api.isMock('listOrders'), false);
  const bad = A.createTalousApi({ rpc: async () => { throw Object.assign(new Error('Ei oikeuksia'), { status: 403, code: 'forbidden' }); }, mock: false });
  await assert.rejects(() => bad.listOrders({}), /Ei oikeuksia/); assert.equal(bad.mode, 'real');
});
test('Datakerros: CSV = palvelimen admin_report_csv (12 saraketta, booking_34)', async () => {
  const api = A.createTalousApi({ mock: true, mockFactory: () => mock });
  const rep = await api.reportMonthly('2026-09'); const c = await api.reportCsv(rep);
  assert.equal(c.source, 'server'); assert.ok(c.content.slice(1).startsWith(CSV_COLUMNS.join(';'))); assert.equal(c.content.trim().split('\r\n').length - 1, rep.lines.length + (rep.open?.rows?.length || 0));
  const noLines = { ...rep, lines: null }; const s = await api.reportCsv(noLines);
  assert.equal(s.source, 'server'); assert.equal(s.filename, 'tapahtumat_2026-09-01_2026-09-30.csv'); assert.ok(s.content.startsWith('\uFEFFtosite;pvm;asiakas;tuote;maara'));
});
test('Datakerros: sopimuksen vastausten normalisointi (rivit, tilaus, raportti)', () => {
  const row = A.normOrderRow({ order_id: 1, order_no: 2, total: 100, paid: 40, refunded: 5, unpaid: 60, first_start: 'f', customer_company: 'X Oy', johku_order_no: 7 });
  assert.deepEqual([row.total_gross, row.paid_amount, row.refunded_amount, row.unpaid_amount, row.first_reservation_at, row.customer_company, row.johku_order_no], [100, 40, 5, 60, 'f', 'X Oy', 7]);
  const o = A.normOrder({ order_id: 9, order_no: 1, total: 100, balance: { total: 100, paid: 40, unpaid: 60 }, customer: { name: 'A' }, can_add: true,
    payments: [{ id: 4, method: 'cash', status: 'paid', amount: 40, lines: [{ id: 1, order_item_id: 2, description: 'D', quantity: 1, amount_gross: 125.5, vat_rate: 25.5 }], receipts: [{ id: 8, receipt_no: 'K-2026-000001', kind: 'receipt', issued_at: 'i', public_token: 'tk' }] }],
    reservations: [{ id: 3, product_name: 'P', starts_at: 'b', ends_at: 'e', persons: 2, item_total: 100, addons: [{ addon_id: 1, name: 'Pyyhe', quantity: 1, line_total: 5 }] }] });
  assert.equal(o.balance.unpaid, 60); assert.equal(o.payments[0].payment_id, 4); assert.equal(o.payments[0].receipt_no, 'K-2026-000001'); assert.equal(o.reservations[0].reservation_id, 3); assert.equal(o.first_reservation_at, 'b');
  assert.deepEqual([o.payments[0].lines[0].line_vat, o.payments[0].lines[0].line_net], [25.5, 100]);   // ALV/netto lasketaan bruttosta ja ALV-%:sta
  const r = A.normReport({ period: { from: 'a', to: 'a', kind: 'day' }, totals: { gross: 10 }, by_vat: [{ rate: '25.5', net: 1, vat: 1, gross: 2 }] });
  assert.equal(r.by_vat[0].rate, 25.5); assert.equal(A.normReport({ period: { from: '2026-10-17', to: '2026-10-17', tz: 'Europe/Helsinki' }, totals: {} }).period.kind, 'day'); assert.equal(A.normReport({ period: { from: '2026-10-01', to: '2026-10-31' }, totals: {} }).period.kind, 'month'); assert.equal(r.totals.gross_after_refunds, 10); assert.deepEqual(r.by_method, []); assert.equal(r.receipts, null); assert.equal(r.lines, null);
});

test('Tekstit: FI ja EN sisältävät samat avaimet', () => {
  const f = Object.keys(TEXTS.fi), e = Object.keys(TEXTS.en);
  assert.deepEqual(f.filter((k) => !e.includes(k)), []); assert.deepEqual(e.filter((k) => !f.includes(k)), []);
  for (const k of f) { assert.ok(String(TEXTS.fi[k]).length > 0 && String(TEXTS.en[k]).length > 0, k); assert.deepEqual([...String(TEXTS.fi[k]).matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort(), [...String(TEXTS.en[k]).matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort(), `muuttujat ${k}`); }
});
test('Tekstit: kaikki näkymissä käytetyt avaimet löytyvät', () => {
  const files = [...readdirSync(join(root, 'admin/views')).filter((f) => /^talous/.test(f)).map((f) => `admin/views/${f}`), 'admin/talous-api.js', 'admin/admin.js'];
  const prefixes = new Set(Object.keys(TEXTS.fi).filter((k) => k.includes('.')).map((k) => k.split('.')[0]));
  const used = new Set();
  for (const f of files) {
    const src = readFileSync(join(root, f), 'utf8');
    for (const m of src.matchAll(/\bt\(\s*['`]([^'`$]+)['`]/g)) used.add(m[1]);
    for (const m of src.matchAll(/'([a-z]+\.[a-zA-Z_]+)'/g)) if (prefixes.has(m[1].split('.')[0]) && !/\.(js|mjs|css|manage|refund|override)$/.test(m[1])) used.add(m[1]);
  }
  const missing = [...used].filter((k) => TEXTS.fi[k] == null);
  assert.deepEqual(missing, []);
  for (const [prefix, codes] of [['pay', UI.PAY], ['pstat', UI.PSTAT], ['src', UI.SOURCES], ['method', UI.METHODS]]) for (const c of codes) assert.ok(TEXTS.fi[`${prefix}.${c}`] && TEXTS.en[`${prefix}.${c}`], `${prefix}.${c}`);
  for (const g of GROUPS) assert.ok(TEXTS.fi[`group.${g}`] && TEXTS.en[`group.${g}`], `group.${g}`);
  for (const k of ['sort.created', 'sort.order_no', 'sort.total', 'sort.payment_status', 'sort.first_reservation', 'nat.native', 'nat.imported', 'df.created', 'df.start', 'receipt.receipt', 'receipt.refund_receipt']) assert.ok(TEXTS.fi[k] && TEXTS.en[k], k);
  for (const code of ['nothing_to_pay', 'order_not_editable', 'amount_exceeds_refundable', 'amount_exceeds_unpaid', 'refund_not_allowed', 'invalid_sort']) assert.ok(TEXTS.fi[`err.${code}`] && TEXTS.en[`err.${code}`], code);
});
test('Ikonit: näkymissä käytetyt ikonit on määritelty', () => {
  const used = new Set();
  for (const f of readdirSync(join(root, 'admin/views')).filter((x) => /^talous/.test(x))) for (const m of readFileSync(join(root, 'admin/views', f), 'utf8').matchAll(/icon\('([a-z]+)'/g)) used.add(m[1]);
  for (const m of readFileSync(join(root, 'admin/views/talous-ui.js'), 'utf8').matchAll(/(?:first|prev|next|last): '([a-z]+)'/g)) used.add(m[1]);
  for (const name of [...used, 'euro']) assert.ok(ICONS[name], `ikoni ${name}`);
});

test('Asiakkaan tilaussivu: tekstit, token, mock (sopimuksen muodot) ja puuttuva RPC', async () => {
  assert.deepEqual(Object.keys(OT.fi).sort(), Object.keys(OT.en).sort());
  assert.ok(OA.validToken('3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c')); assert.ok(!OA.validToken('abc')); assert.ok(!OA.validToken(''));
  assert.equal(OA.wantsMock({ search: '?t=x&mock=1' }), true); assert.equal(OA.wantsMock({ search: '?t=x' }), false);
  const miss = Object.assign(new Error('nf'), { status: 404, code: 'PGRST202' });
  const api = OA.createOrderApi({ rpc: async () => { throw miss; }, token: 't', mock: false });
  assert.deepEqual(await api.get(), { ok: false, notReady: true, rpc: 'public_get_order' });   // asiakkaalle ei esimerkkidataa
  const calls = []; const ok = OA.createOrderApi({ rpc: async (n, a) => { calls.push([n, a]); return { ok: true }; }, token: 'tok', mock: false });
  await ok.get(); await ok.addToOrder({ items: [{ type: 'addon', code: 'pyyhe', quantity: 1 }] }); await ok.requestCancel({ reason: 'x' }); await ok.requestCancel({}); await ok.getReceipt({ receiptNo: 'K-2026-000001' });
  assert.deepEqual(calls, [['public_get_order', { p_token: 'tok' }], ['public_add_to_order', { p_token: 'tok', p_items: [{ type: 'addon', code: 'pyyhe', quantity: 1 }] }], ['public_request_cancel', { p_token: 'tok', p_reason: 'x' }], ['public_request_cancel', { p_token: 'tok' }],
    ['public_get_receipt', { p_order_token: 'tok', p_receipt_no: 'K-2026-000001' }]]);   // HUOM: kuitissa p_order_token
  const om = createOrderMock({ today: TODAY }), mk = OA.createOrderApi({ rpc: om.rpc, token: om.token, mock: true, mockFactory: () => om });
  const o = await mk.get(); assert.equal(o.ok, true); assert.deepEqual([o.total, o.paid, o.unpaid], [131, 60, 71]); assert.equal(o.reservations.length, 2); assert.equal(o.upsell_addons.length, 3); assert.equal(o.cancel_request, null); assert.equal(o.receipts[0].receipt_no, 'K-2026-000321');
  const add = await mk.addToOrder({ items: [{ type: 'addon', code: 'pyyhe', quantity: 2, reservation_id: 501 }] }); assert.equal(add.ok, true); assert.equal(add.added_total, 10);
  const o2 = await mk.get(); assert.equal(o2.total, 141); assert.equal(o2.items.length, 4);
  assert.equal((await mk.addToOrder({ items: [{ type: 'addon', code: 'pyyhe', quantity: 99 }] })).ok, false);
  assert.equal((await mk.addToOrder({ items: [{ type: 'addon', code: 'ei-ole', quantity: 1 }] })).code, 'item_not_found');
  assert.equal((await mk.requestCancel({})).ok, true); assert.equal((await mk.requestCancel({})).code, 'request_exists'); assert.equal((await mk.get()).cancel_request.status, 'open');
  const rc = await mk.getReceipt({ receiptNo: 'K-2026-000321' }); assert.ok(rc.ok && /ESIMERKKIKUITTI/.test(rc.text_body)); assert.equal((await mk.getReceipt({ receiptNo: 'x' })).code, 'receipt_not_found');
});

test('Raportti (sopimus §11, booking_35): period.kind palvelimelta, gross_after_refunds, net_after_refunds ei käytössä', () => {
  const day = { from: '2026-10-17', to: '2026-10-17', tz: 'Europe/Helsinki' };
  assert.equal(A.normReport({ period: { ...day, kind: 'month' }, totals: {} }).period.kind, 'month', 'palvelimen kind voittaa päättelyn');
  assert.equal(A.normReport({ period: { ...day, kind: 'day' }, totals: {} }).period.kind, 'day');
  assert.equal(A.normReport({ period: { from: '2026-10-01', to: '2026-10-31' }, totals: {} }).period.kind, 'month', 'varapäättely kun kind puuttuu');
  assert.equal(A.normReport({ period: { ...day, kind: 'weird' }, totals: {} }).period.kind, 'day', 'tuntematon kind → varapäättely');
  const t = A.normReport({ period: { ...day, kind: 'day' }, totals: { gross: 100, refunds_gross: -30, gross_after_refunds: 70, net_after_refunds: 999, vat_after_refunds: 13.55, net_ex_vat_after_refunds: 56.45 } }).totals;
  assert.equal(t.gross_after_refunds, 70); assert.equal(t.vat_after_refunds, 13.55); assert.equal(t.net_ex_vat_after_refunds, 56.45); assert.ok(!('net_after_refunds' in t));
  assert.equal(A.normReport({ period: day, totals: { gross: 100, refunds_gross: -30, net_after_refunds: 999 } }).totals.gross_after_refunds, 70, 'puuttuessa gross + refunds_gross (ei deprecated-kenttää)');
});

test('Kuitit: admin_get_receipt / admin_resend_receipt -parametrit, normalisointi ja PDF-linkin muoto', async () => {
  const calls = []; const be = A.rpcBackend(async (n, a) => { calls.push([n, a]); return { ok: true }; });
  await be.getReceipt(19); await be.resendReceipt(19);
  assert.deepEqual(calls, [['admin_get_receipt', { p_receipt_id: 19 }], ['admin_resend_receipt', { p_receipt_id: 19 }]]);
  const rc = A.normReceipt({ id: 19, receipt_no: 'K-2026-000001', kind: 'receipt', issued_at: '2026-10-17T09:47:28Z', total_gross: '31.00', snapshot: { v: 1 }, text_body: 'KUITTI\n', public_token: '11111111-2222-4333-8444-555555555555', pdf_url: 'https://x/functions/v1/receipt-pdf?t=1', sent_at: null, order_id: 5, payment_id: 24, refund_id: null });
  assert.deepEqual([rc.id, rc.receipt_no, rc.total, rc.text_body, rc.payment_id, rc.sent_at], [19, 'K-2026-000001', 31, 'KUITTI\n', 24, null]);
  // tilauksen kuittiviite: top-level (total, payment_id) ja maksun alla (ilman summaa)
  const o = A.normOrder({ order_id: 1, order_no: 15001, payments: [{ id: 24, receipts: [{ id: 19, receipt_no: 'K-2026-000001', kind: 'receipt', issued_at: 'x', public_token: 't', sent_at: null }] }], receipts: [{ id: 19, receipt_no: 'K-2026-000001', kind: 'receipt', issued_at: 'x', total: 31, payment_id: 24, refund_id: null, public_token: 't', sent_at: null }] });
  assert.deepEqual([o.receipts[0].total, o.receipts[0].payment_id, o.payments[0].receipts[0].total, o.payments[0].receipt_no], [31, 24, null, 'K-2026-000001']);
  // PDF-linkki: <SUPABASE_URL>/functions/v1/receipt-pdf?t=<public_token> (URL io.functionUrl:stä = sb.js, sama muodostus kuin fn())
  const fu = (name, q) => `https://abc.supabase.co/functions/v1/${name}?${new URLSearchParams(q)}`;
  const api = A.createTalousApi({ rpc: async () => ({}), mock: false, io: { functionUrl: fu } });
  assert.equal(api.receiptPdfUrl('11111111-2222-4333-8444-555555555555'), 'https://abc.supabase.co/functions/v1/receipt-pdf?t=11111111-2222-4333-8444-555555555555');
  assert.equal(api.receiptPdfUrl(null), ''); assert.equal(A.createTalousApi({ mock: true, mockFactory: () => mock }).receiptPdfUrl('x'), '');
  // sähköpostin tila: integration_config.resend.mode (luku henkilökunnalle); virhe → null
  const sel = []; const ok = A.createTalousApi({ rpc: async () => ({}), mock: false, io: { select: async (t, q) => { sel.push([t, q]); return [{ mode: 'dry_run' }]; } } });
  assert.equal(await ok.resendMode(), 'dry_run'); assert.deepEqual(sel, [['integration_config', { select: 'mode', key: 'eq.resend' }]]);
  assert.equal(await A.createTalousApi({ rpc: async () => ({}), mock: false, io: { select: async () => { throw new Error('x'); } } }).resendMode(), null);
  // uudelleenlähetys: oikeassa tilassa vain palvelimelle; puuttuva RPC → FeatureNotReady, ei mock-varaa
  const res = await A.createTalousApi({ rpc: async () => ({ ok: true, email_queued: true }), mock: false }).resendReceipt(19); assert.equal(res.email_queued, true);
  const miss = Object.assign(new Error('Could not find the function booking.admin_resend_receipt'), { status: 404, code: 'PGRST202', details: { code: 'PGRST202' } });
  await assert.rejects(() => A.createTalousApi({ rpc: async () => { throw miss; }, mock: false }).resendReceipt(19), (e) => e instanceof A.FeatureNotReady);
});
test('Kuitit: mock vastaa admin_get_receipt / admin_resend_receipt sopimuksen muodossa (teksti + snapshot)', async () => {
  const o = mock.orders.find((x) => x.is_native && x.receipts.some((r) => r.kind === 'refund_receipt'));
  const full = await mock.rpc('admin_get_order', { p_order_id: o.order_id });
  assert.ok(full.receipts.every((r) => r.total != null && r.payment_id != null && r.public_token));
  for (const ref of full.receipts) {
    const r = await mock.rpc('admin_get_receipt', { p_receipt_id: ref.id });
    for (const k of ['id', 'receipt_no', 'kind', 'issued_at', 'total_gross', 'snapshot', 'text_body', 'public_token', 'pdf_url', 'sent_at']) assert.ok(k in r, k);
    assert.match(r.text_body, new RegExp(r.receipt_no)); assert.equal(r.snapshot.v, 1); assert.equal(r.snapshot.document, r.kind); assert.equal(Math.sign(r.total_gross), r.kind === 'refund_receipt' ? -1 : 1);
    assert.match(r.text_body, r.kind === 'refund_receipt' ? /HYVITYSKUITTI/ : /KUITTI/);
  }
  assert.deepEqual(await mock.rpc('admin_resend_receipt', { p_receipt_id: full.receipts[0].id }), { ok: true, mock: true, email_queued: true });
  await assert.rejects(() => mock.rpc('admin_get_receipt', { p_receipt_id: 1 }), (e) => e.code === 'receipt_not_found');
});
test('Talous: ei "tulee vaiheessa"-stubitekstejä eikä käyttöönottolippuja (FI/EN)', () => {
  for (const lang of ['fi', 'en']) for (const [k, v] of Object.entries(TEXTS[lang])) assert.ok(!/vaiheessa\s+[A-D]\b|phase\s+[A-D]\b|tulee (käyttöön|myöhemmin)|will (be available|come) (in|later)|ei vielä käytössä – odottaa/i.test(String(v)), `${lang}.${k}: ${v}`);
  for (const f of ['admin/talous-api.js', 'admin/talous-mock.js', 'admin/talous-i18n.js', ...readdirSync(join(root, 'admin/views')).filter((x) => /^talous/.test(x)).map((x) => `admin/views/${x}`)]) {
    const src = readFileSync(join(root, f), 'utf8');
    assert.ok(!/LIVE_ACTIONS|actionLive|vaiheessa [A-D]\b|\bphase [A-D]\b/.test(src), `${f}: stubi/lippu jäljellä`);
  }
  for (const k of ['receipts.title', 'receipts.none', 'receipt.download', 'receipt.view', 'receipt.resend', 'receipt.copy', 'receipt.copied', 'resend.confirm', 'resend.queued', 'resend.notQueued', 'resend.mode.live', 'resend.mode.dry_run', 'resend.mode.off', 'resend.mode.unknown', 'err.receipt_not_found', 'r.pdfServer']) assert.ok(TEXTS.fi[k] && TEXTS.en[k], k);
});

test('Johku ei kirjanpitoon (booking_41): statistics.johku normalisoituu eikä kosketa totals-lukuja', () => {
  const raw = { period: { from: '2026-10-01', to: '2026-10-31', kind: 'month' }, totals: { receipts: 2, refund_receipts: 0, gross: 100, net: 80, vat: 20, refunds_gross: 0 }, by_method: [], statistics: { johku: { label: 'Johku (ei kirjanpitoon)', accounting: false, basis: 'johku_paid_at', orders: '3', gross: '45.5', refunded_orders: 1, refunded_gross: 12, by_method: [{ method: 'mobilepay', orders: 2, gross: 30 }, { method: 'cash', orders: 1, gross: 15.5 }] } } };
  const n = A.normReport(raw);
  assert.deepEqual(n.statistics.johku, { label: 'Johku (ei kirjanpitoon)', accounting: false, basis: 'johku_paid_at', orders: 3, gross: 45.5, refunded_orders: 1, refunded_gross: 12, by_method: [{ method: 'mobilepay', orders: 2, gross: 30 }, { method: 'cash', orders: 1, gross: 15.5 }] });
  assert.equal(n.totals.gross, 100); assert.equal(n.totals.receipts, 2);   // Johku ei totals-lukuihin
  assert.equal(A.normReport({ ...raw, statistics: undefined }).statistics.johku, null);   // vanha palvelin → lohkoa ei näytetä
  assert.equal(A.normJohkuStats({}).orders, 0); assert.deepEqual(A.normJohkuStats({}).by_method, []);
});

test('Johku ei kirjanpitoon: maksurivin source/is_johku ja ex_johku-summat (palvelin + vanha palvelin)', async () => {
  assert.equal(A.normPaymentRow({ payment_id: 1, source: 'johku', is_johku: true }).is_johku, true);
  assert.equal(A.normPaymentRow({ payment_id: 1, source: 'native', is_johku: false }).source, 'native');
  assert.equal(A.normPaymentRow({ payment_id: 1 }).is_johku, false);   // vanha palvelin: ei kenttiä
  const api = A.createTalousApi({ rpc: async () => ({ total: 2, sum_paid: 100, sum_refunded: 10, sum_paid_ex_johku: 70, sum_refunded_ex_johku: 10, johku_rows: 1, rows: [{ payment_id: 1, source: 'johku', is_johku: true }, { payment_id: 2, source: 'native', is_johku: false }] }), mock: false, mockFactory: () => mock });
  const r = await api.listPayments({});
  assert.equal(r.sum_paid_ex_johku, 70); assert.equal(r.johku_rows, 1); assert.equal(r.sum_paid, 100); assert.deepEqual(r.rows.map((x) => x.is_johku), [true, false]);
  const old = A.createTalousApi({ rpc: async () => ({ total: 1, sum_paid: 50, sum_refunded: 5, rows: [{ payment_id: 3 }] }), mock: false, mockFactory: () => mock });
  const o = await old.listPayments({});
  assert.equal(o.sum_paid_ex_johku, 50); assert.equal(o.sum_refunded_ex_johku, 5); assert.equal(o.johku_rows, 0);
});

test('Johku ei kirjanpitoon: mock – statistics.johku erillään, ei kuitteja/CSV:tä/totalsia, ex_johku-summat täsmäävät', async () => {
  const all = await R('admin_list_payments', { p_limit: 200 });
  assert.ok(all.johku_rows > 0, 'mockissa on Johku-maksurivejä');
  const jr = mock.payments.filter((p) => p.is_johku).map((p) => ({ ...p, receipt_token: p.receipt?.public_token || null }));
  assert.ok(jr.every((p) => !p.receipt_no && !p.receipt_token && !p.receipt));
  assert.ok(all.rows.filter((p) => p.is_johku).every((p) => p.source === 'johku' && !p.receipt_no && !p.receipt_token));
  assert.ok(all.rows.filter((p) => !p.is_johku).every((p) => p.source === 'native'));
  const jAll = mock.payments.filter((p) => p.is_johku);
  assert.equal(all.johku_rows, jAll.length);
  assert.equal(all.sum_paid_ex_johku, Math.round((all.sum_paid - jAll.filter((p) => p.paid_at).reduce((s, p) => s + p.amount, 0)) * 100) / 100);
  assert.ok(all.sum_paid_ex_johku < all.sum_paid);
  // raportti: jakso, jolla on Johku-myyntiä
  const jDay = mock.orders.filter((o) => o.johku).map((o) => o.johku.paid_date).sort()[100], jYm = jDay.slice(0, 7);
  const m = await R('admin_report_month', { p_ym: jYm });
  const j = m.statistics.johku;
  assert.equal(j.label, 'Johku (ei kirjanpitoon)'); assert.equal(j.accounting, false); assert.equal(j.basis, 'johku_paid_at');
  assert.ok(j.orders > 0 && j.gross > 0 && j.by_method.length > 0);
  assert.equal(Math.round(j.by_method.reduce((s, x) => s + x.gross, 0) * 100) / 100, j.gross);
  assert.equal(j.by_method.reduce((s, x) => s + x.orders, 0), j.orders);
  assert.ok(!m.lines.some((l) => jr.some((p) => p.order_no === l.order_no)), 'Johku-maksu ei kirjanpidon riveissä');
  const csv = await R('admin_report_csv', { p_from: `${jYm}-01`, p_to: `${jYm}-28` });
  assert.ok(!/johku/i.test(csv.content));
  const d = await R('admin_report_daily', { p_date: TODAY }); assert.ok('johku' in d.statistics); assert.equal(typeof d.statistics.johku.orders, 'number');
});

test('Johku ei kirjanpitoon: FI/EN-tekstit löytyvät ja lohko on tulosteesta pois', () => {
  for (const k of ['johku.badge', 'johku.badgeTitle', 'johku.rowNote', 'payments.johkuRows', 'payments.sumsEx', 'order.noPaymentsJohku', 'r.johku.title', 'r.johku.note', 'r.johku.sales', 'r.johku.none', 'jm.paybywaychannel']) for (const l of ['fi', 'en']) assert.ok(TEXTS[l][k], `${l}:${k}`);
  assert.equal(TEXTS.fi['r.johku.title'], 'Johku (ei kirjanpitoon)');
  assert.match(readFileSync(join(root, 'admin/views/talous-reports.js'), 'utf8'), /tl-johku-block tl-noprint/);
});
