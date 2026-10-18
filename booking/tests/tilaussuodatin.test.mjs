// Tilauslistan maksusuodatin: oletus paid (ja partially_refunded, netto > 0, ei peruttu/vanhentunut),
// haku oletuksesta käy kaikista, mock ja palvelinparametri, tekstit FI+EN, siru kun suodattimet on kiinni.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const F = await import(pathToFileURL(join(root, 'admin/orders-filter.js')));
const { createMock } = await import(pathToFileURL(join(root, 'admin/talous-mock.js')));
const A = await import(pathToFileURL(join(root, 'admin/talous-api.js')));

const order = (over) => ({ status: 'confirmed', payment_status: 'paid', paid_amount: 10, refunded_amount: 0, total_gross: 10, payments: [{ status: 'paid', amount: 10 }], ...over });

test('oletus: paid ja partially_refunded, netto > 0, ei peruttu eikä vanhentunut', () => {
  assert.equal(F.DEFAULT_PAYMENT_FILTER, 'paid');
  assert.equal(F.normalizePaymentFilter(undefined), 'paid');
  assert.equal(F.normalizePaymentFilter(''), 'paid');
  assert.equal(F.matchesPaymentFilter(order({}), 'paid'), true);
  assert.equal(F.matchesPaymentFilter(order({ payment_status: 'partially_refunded', paid_amount: 80, refunded_amount: 30, payments: [{ status: 'partially_refunded' }] }), 'paid'), true);
  assert.equal(F.matchesPaymentFilter(order({ payment_status: 'refunded', paid_amount: 40, refunded_amount: 40, payments: [{ status: 'refunded' }] }), 'paid'), false);
  assert.equal(F.matchesPaymentFilter(order({ payment_status: 'unpaid', paid_amount: 0, payments: [] }), 'paid'), false);
  assert.equal(F.matchesPaymentFilter(order({ payment_status: 'pending', payments: [] }), 'paid'), false);
  assert.equal(F.matchesPaymentFilter(order({ payment_status: 'failed', payments: [] }), 'paid'), false);
  assert.equal(F.matchesPaymentFilter(order({ payment_status: 'partially_paid', paid_amount: 40, payments: [{ status: 'paid' }] }), 'paid'), false);
  assert.equal(F.matchesPaymentFilter(order({ status: 'cancelled' }), 'paid'), false);
  assert.equal(F.matchesPaymentFilter(order({ status: 'expired' }), 'paid'), false);
  assert.equal(F.matchesPaymentFilter(order({ payment_status: 'partially_refunded', paid_amount: 20, refunded_amount: 20, payments: [{ status: 'partially_refunded' }] }), 'paid'), false);
  assert.equal(F.matchesPaymentFilter(order({ status: 'completed' }), 'paid'), true);
});

test('Johku ilman maksurivejä: total_gross on nettomaksu', () => {
  const johku = { status: 'confirmed', payment_status: 'paid', paid_amount: 0, refunded_amount: 0, total_gross: 50, payments: [] };
  assert.equal(F.netSettled(johku), 50);
  assert.equal(F.matchesPaymentFilter(johku, 'paid'), true);
  const part = { ...johku, payment_status: 'partially_refunded', total_gross: 15 };
  assert.equal(F.matchesPaymentFilter(part, 'paid'), true);
  const ref = { ...johku, status: 'cancelled', payment_status: 'refunded', total_gross: 12 };
  assert.equal(F.matchesPaymentFilter(ref, 'paid'), false);
  assert.equal(F.matchesPaymentFilter(ref, 'refunded'), true);
  assert.equal(F.matchesPaymentFilter(ref, 'cancelled'), true);
});

test('valikot: maksamattomat, hyvitetyt, peruttu, kaikki', () => {
  const unpaid = order({ payment_status: 'unpaid', paid_amount: 0, payments: [] });
  const pending = order({ status: 'pending', payment_status: 'pending', payments: [] });
  const failed = order({ payment_status: 'failed', payments: [] });
  const partial = order({ payment_status: 'partially_paid', paid_amount: 40, payments: [{ status: 'paid' }] });
  const cancelledPaid = order({ status: 'cancelled' });
  for (const o of [unpaid, pending, failed, partial]) assert.equal(F.matchesPaymentFilter(o, 'unpaid'), true, o.payment_status);
  assert.equal(F.matchesPaymentFilter(cancelledPaid, 'unpaid'), false);
  assert.equal(F.matchesPaymentFilter(order({ payment_status: 'refunded', payments: [{ status: 'refunded' }] }), 'refunded'), true);
  assert.equal(F.matchesPaymentFilter(order({ payment_status: 'partially_refunded', payments: [{ status: 'partially_refunded' }] }), 'refunded'), true);
  assert.equal(F.matchesPaymentFilter(order({}), 'refunded'), false);
  assert.equal(F.matchesPaymentFilter(order({ status: 'expired', payment_status: 'unpaid', payments: [] }), 'cancelled'), true);
  assert.equal(F.matchesPaymentFilter(unpaid, 'all'), true);
  assert.equal(F.matchesPaymentFilter(order({ status: 'cancelled' }), 'all'), true);
  assert.equal(F.matchesPaymentFilter(order({}), 'nope'), false);
});

test('haku ohittaa vain oletuksen paid', () => {
  assert.equal(F.effectivePaymentFilter({ search: '', paymentFilter: 'paid' }), 'paid');
  assert.equal(F.effectivePaymentFilter({ search: '  ', paymentFilter: undefined }), 'paid');
  assert.equal(F.effectivePaymentFilter({ search: '15001', paymentFilter: 'paid' }), 'all');
  assert.equal(F.effectivePaymentFilter({ search: 'Mäkelä', paymentFilter: 'paid' }), 'all');
  assert.equal(F.effectivePaymentFilter({ search: '15001', paymentFilter: 'unpaid' }), 'unpaid');
  assert.equal(F.effectivePaymentFilter({ search: '15001', paymentFilter: 'refunded' }), 'refunded');
  assert.equal(F.effectivePaymentFilter({ search: '15001', paymentFilter: 'cancelled' }), 'cancelled');
  assert.equal(F.effectivePaymentFilter({ search: '15001', paymentFilter: 'all' }), 'all');
});

test('mock: oletus on maksetut, all ja haku löytävät maksamattoman', async () => {
  const mock = createMock({ n: 400, today: '2026-10-18', delay: 0 });
  const expectPaid = mock.orders.filter((o) => F.matchesPaymentFilter(o, 'paid')).length;
  const def = await mock.rpc('admin_list_orders', { p_limit: 50 });
  assert.equal(def.total, expectPaid);
  assert.ok(def.total > 0 && def.total < 400);
  assert.ok(def.rows.every((row) => row.payment_status === 'paid' || row.payment_status === 'partially_refunded'));
  assert.ok(def.rows.every((row) => row.status !== 'cancelled' && row.status !== 'expired'));
  const unpaid = mock.orders.find((o) => o.payment_status === 'unpaid');
  assert.ok(unpaid);
  assert.equal((await mock.rpc('admin_list_orders', { p_search: String(unpaid.order_no) })).total, 0);
  assert.equal((await mock.rpc('admin_list_orders', { p_search: String(unpaid.order_no), p_payment_filter: 'all' })).rows[0].order_id, unpaid.order_id);
  const onlyUnpaid = await mock.rpc('admin_list_orders', { p_payment_filter: 'unpaid', p_limit: 100 });
  assert.ok(onlyUnpaid.total > 0);
  assert.ok(onlyUnpaid.rows.every((row) => ['unpaid', 'pending', 'failed', 'partially_paid'].includes(row.payment_status)));
  await assert.rejects(() => mock.rpc('admin_list_orders', { p_payment_filter: 'nope' }), (e) => e.code === 'invalid_param');
});

test('datakerros lähettää p_payment_filter vain kun näkymä antaa sen', async () => {
  const calls = [];
  const api = A.createTalousApi({ rpc: async (n, a) => { calls.push([n, a]); return { total: 0, rows: [] }; }, mock: false });
  await api.listOrders({ paymentFilter: 'paid', sortBy: 'created', sortDir: 'desc', limit: 25, offset: 0 });
  assert.equal(calls[0][1].p_payment_filter, 'paid');
  await api.listOrders({ search: '42', paymentFilter: 'all', sortBy: 'created', sortDir: 'desc', limit: 25, offset: 0 });
  assert.equal(calls[1][1].p_search, '42');
  assert.equal(calls[1][1].p_payment_filter, 'all');
  await api.listOrders({ sortBy: 'created', sortDir: 'desc', limit: 25, offset: 0 });
  assert.equal(calls[2][1].p_payment_filter, undefined);
});

test('migraatio booking_76, rollback ja tuontitekstit', () => {
  const sql = readFileSync(join(root, 'supabase/migrations/20261018210000_booking_76_orders_payment_filter.sql'), 'utf8');
  const rb = readFileSync(join(root, 'supabase/rollbacks/20261018210000_booking_76_ROLLBACK.sql'), 'utf8');
  assert.match(sql, /p_payment_filter text default 'paid'/);
  assert.match(sql, /drop function if exists booking\.admin_list_orders\(text, text, text, text, boolean, text, date, date, text, integer, integer\)/);
  assert.match(sql, /when 'paid' then o\.payment_status in \('paid','partially_refunded'\)/);
  assert.match(sql, /o\.status not in \('cancelled','expired'\)/);
  assert.match(sql, /when 'unpaid' then o\.payment_status in \('unpaid','pending','failed','partially_paid'\)/);
  assert.match(sql, /grant execute on function booking\.admin_list_orders\(text, text, text, text, boolean, text, date, date, text, integer, integer, text\) to authenticated/);
  assert.match(rb, /drop function if exists booking\.admin_list_orders\(text, text, text, text, boolean, text, date, date, text, integer, integer, text\)/);
  assert.match(rb, /CREATE OR REPLACE FUNCTION booking\.admin_list_orders\(p_search text/);
  assert.doesNotMatch(rb, /p_payment_filter text/);
  const doc = readFileSync(join(root, 'docs/talous-tilaussuodatin.md'), 'utf8');
  assert.match(doc, /partially_refunded/);
  assert.match(doc, /Johku/);
  assert.match(doc, /booking_76/);

  const rows = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-8.json'), 'utf8'));
  assert.equal(rows.length, 16);
  const keys = [...new Set(rows.map((r) => r.key))].sort();
  assert.deepEqual(keys, ['ui.admin.orders.pay_all', 'ui.admin.orders.pay_cancelled', 'ui.admin.orders.pay_filter', 'ui.admin.orders.pay_paid', 'ui.admin.orders.pay_refunded', 'ui.admin.orders.pay_showing', 'ui.admin.orders.pay_unpaid', 'ui.admin.orders.search_all']);
});

function installDom() {
  function textOf(node) {
    if (!node) return '';
    if (node.nodeType === 3) return node.data;
    return (node.children || []).map(textOf).join('');
  }
  function ClassList(el) {
    this.el = el;
  }
  ClassList.prototype.contains = function (name) { return this.el.className.split(/\s+/).includes(name); };
  ClassList.prototype.toggle = function (name, force) {
    const has = this.contains(name);
    const on = force === undefined ? !has : !!force;
    const parts = new Set(this.el.className.split(/\s+/).filter(Boolean));
    if (on) parts.add(name); else parts.delete(name);
    this.el.className = [...parts].join(' ');
    return on;
  };
  function Node(type) { this.nodeType = type; this.parent = null; this.children = []; }
  function Text(data) { Node.call(this, 3); this.data = String(data); }
  Text.prototype = Object.create(Node.prototype);
  function El(tag) {
    Node.call(this, 1);
    this.tagName = String(tag).toUpperCase();
    this.attrs = {};
    this.className = '';
    this.classList = new ClassList(this);
    this.listeners = {};
    this._hidden = false;
    this.value = '';
    this.id = '';
    this.style = {};
    const el = this;
    this.dataset = new Proxy({}, {
      set(_o, k, v) { el.setAttribute('data-' + String(k).replace(/[A-Z]/g, (c) => '-' + c.toLowerCase()), v); return true; },
    });
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
  Object.defineProperty(El.prototype, 'parentNode', { get() { return this.parent; } });
  Object.defineProperty(El.prototype, 'firstElementChild', {
    get() { return this.children.find((c) => c.nodeType === 1) || null; },
  });
  El.prototype.setAttribute = function (k, v) {
    this.attrs[k] = String(v);
    if (k === 'id') this.id = String(v);
    if (k === 'class') this.className = String(v);
    if (k === 'hidden') this._hidden = true;
  };
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
  El.prototype.replaceChildren = function (...items) { this.children = []; this.append(...items); };
  El.prototype.replaceWith = function (next) {
    const p = this.parent; if (!p) return;
    const i = p.children.indexOf(this);
    this.parent = null; next.parent = p; p.children.splice(i, 1, next);
  };
  El.prototype.contains = function (node) {
    if (node === this) return true;
    return this.children.some((c) => c === node || (c.contains && c.contains(node)));
  };
  El.prototype.dispatch = function (type) {
    const ev = { type, target: this };
    const chain = [];
    for (let n = this; n; n = n.parent) chain.push(n);
    for (const n of chain) for (const fn of n.listeners[type] || []) fn(ev);
  };
  function create(tag) { return new El(tag); }
  const body = create('body');
  globalThis.document = {
    createElement: create, createElementNS: (_ns, tag) => create(tag), createTextNode: (t) => new Text(t),
    getElementById: () => null, querySelector: () => null, body,
  };
}

function walk(n, acc = []) {
  acc.push(n);
  for (const c of n.children || []) walk(c, acc);
  return acc;
}
const byTest = (root, id) => walk(root).find((n) => n.getAttribute && n.getAttribute('data-testid') === id);

installDom();
const { createOrdersTab } = await import(pathToFileURL(join(root, 'admin/views/talous-orders.js')));
const { ORDER_TEXTS, clearOrderTextCache, loadOrderTexts, orderText } = await import(pathToFileURL(join(root, 'admin/orders-texts.js')));
const { setLang } = await import(pathToFileURL(join(root, 'admin/talous-i18n.js')));

test('tuontitiedoston tekstit täsmäävät varatekstiin', async () => {
  const rows = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-8.json'), 'utf8'));
  const fi = Object.keys(ORDER_TEXTS.fi).sort();
  const en = Object.keys(ORDER_TEXTS.en).sort();
  assert.deepEqual(fi, en);
  assert.equal(rows.length, 16);
  assert.ok(fi.includes('ui.admin.orders.pay_invoiced'));
  assert.equal(rows.some((r) => r.key === 'ui.admin.orders.pay_invoiced'), false);
  for (const row of rows) {
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.equal(row.text, ORDER_TEXTS[row.lang][row.key]);
    assert.ok(row.text.length <= row.max_len);
    assert.equal(/[€]|<\w|https?:/.test(row.text), false);
    const ph = [...row.text.matchAll(/\{\{var:[a-z0-9_]+\}\}/g)].map((m) => m[0]);
    assert.deepEqual(row.placeholders, ph);
  }
  clearOrderTextCache();
  const ok = await loadOrderTexts(async () => ({ ok: true, texts: [{ key: 'ui.admin.orders.pay_paid', lang: 'fi', text: 'Maksetut tilaukset' }] }));
  assert.equal(ok, true);
  assert.equal(orderText('ui.admin.orders.pay_paid', null, 'fi'), 'Maksetut tilaukset');
  assert.equal(orderText('ui.admin.orders.pay_all', null, 'fi'), 'Kaikki');
  clearOrderTextCache();
  assert.equal(await loadOrderTexts(async () => { throw new Error('verkko'); }), false);
  assert.equal(orderText('ui.admin.orders.pay_paid', null, 'fi'), 'Maksetut');
});

test('siru näyttää Maksetut kun suodattimet on kiinni, Kaikki vaihtaa sen, haku katsoo kaikki', async () => {
  setLang('fi');
  clearOrderTextCache();
  const calls = [];
  const api = {
    listOrders: async (a) => { calls.push({ ...a }); return { total: 0, rows: [] }; },
    changed() {},
    isMock() { return true; },
  };
  const tab = createOrdersTab({ api, ctx: { can: () => false } });
  const chip = byTest(tab.node, 'orders-pay-chip');
  const toggle = byTest(tab.node, 'orders-filters-toggle');
  const panel = byTest(tab.node, 'orders-filters-panel');
  assert.equal(toggle.getAttribute('aria-expanded'), 'false');
  assert.equal(panel.hidden, true);
  assert.equal(panel.contains(chip), false);
  assert.equal(chip.textContent, 'Maksetut');
  assert.equal(chip.getAttribute('data-filter'), 'paid');
  assert.equal(chip.getAttribute('aria-label'), 'Maksutila: Maksetut');
  assert.equal(byTest(tab.node, 'orders-filters-count').hidden, true);

  await tab.load();
  assert.equal(calls.at(-1).paymentFilter, 'paid');
  assert.equal(calls.at(-1).search, '');

  toggle.dispatch('click');
  const sel = byTest(tab.node, 'orders-f-pay');
  assert.equal(panel.hidden, false);
  assert.equal(panel.contains(sel), true);
  assert.equal(sel.value, 'paid');
  sel.value = 'all';
  sel.dispatch('change');
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(chip.textContent, 'Kaikki');
  assert.equal(chip.getAttribute('data-filter'), 'all');
  assert.equal(byTest(tab.node, 'orders-filters-count').hidden, false);
  assert.equal(calls.at(-1).paymentFilter, 'all');
  toggle.dispatch('click');
  assert.equal(panel.hidden, true);
  assert.equal(chip.textContent, 'Kaikki');

  tab.setSearch('15042');
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(calls.at(-1).search, '15042');
  assert.equal(calls.at(-1).paymentFilter, 'all');
  assert.equal(byTest(tab.node, 'orders-search-scope').hidden, true);

  const reset = byTest(tab.node, 'orders-reset');
  reset.dispatch('click');
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(byTest(tab.node, 'orders-pay-chip').textContent, 'Maksetut');
  tab.setSearch('99');
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(calls.at(-1).paymentFilter, 'all');
  assert.equal(byTest(tab.node, 'orders-search-scope').hidden, false);
  assert.match(byTest(tab.node, 'orders-search-scope').textContent, /Haku kaikista tilauksista/);
  assert.equal(byTest(tab.node, 'orders-pay-chip').getAttribute('data-filter'), 'paid');

  setLang('en');
  byTest(tab.node, 'orders-reset').dispatch('click');
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(byTest(tab.node, 'orders-pay-chip').textContent, 'Paid');
  setLang('fi');
});
