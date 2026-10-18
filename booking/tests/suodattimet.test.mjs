// Suodatinlaatikko: haku näkyy, muut suodattimet ovat kiinni, painike avaa, aktiivinen valinta säilyy.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');

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
  El.prototype.append = function (...items) {
    for (const item of items) {
      const n = item && item.nodeType ? item : new Text(item);
      if (n.parent) n.parent.children = n.parent.children.filter((c) => c !== n);
      n.parent = this;
      this.children.push(n);
    }
  };
  El.prototype.contains = function (node) {
    if (node === this) return true;
    return this.children.some((c) => c === node || (c.contains && c.contains(node)));
  };
  El.prototype.click = function () {
    const ev = { type: 'click', target: this };
    const chain = [];
    for (let n = this; n; n = n.parent) chain.push(n);
    for (const n of chain) for (const fn of n.listeners.click || []) fn(ev);
  };
  El.prototype.dispatch = function (type) {
    const ev = { type, target: this };
    const chain = [];
    for (let n = this; n; n = n.parent) chain.push(n);
    for (const n of chain) for (const fn of n.listeners[type] || []) fn(ev);
  };
  function create(tag) { return new El(tag); }
  globalThis.document = { createElement: create, createElementNS: (_ns, tag) => create(tag), createTextNode: (t) => new Text(t) };
}

installDom();
const D = await import(pathToFileURL(join(root, 'admin/filter-drawer.js')));
const T = await import(pathToFileURL(join(root, 'admin/filter-texts.js')));
const I = await import(pathToFileURL(join(root, 'admin/talous-i18n.js')));

function badge(btn) {
  const walk = (n) => {
    if (n.className && n.className.split(/\s+/).includes('filter-badge')) return n;
    for (const c of n.children || []) { const f = walk(c); if (f) return f; }
    return null;
  };
  return walk(btn);
}

test('countActive laskee vain oletuksesta poikkeavat suodattimet, ei hakua', () => {
  assert.equal(D.countActive({ search: 'mäki', paymentStatus: '', limit: 25 }, { paymentStatus: '', limit: 25 }), 0);
  assert.equal(D.countActive({ search: 'mäki', paymentStatus: 'paid', source: 'web', limit: 50 }, { paymentStatus: '', source: '', limit: 25 }), 3);
  assert.equal(D.countActive({ status: 'active', sort: 'oldest_open', limit: 25 }, { status: 'active', sort: 'oldest_open', limit: 25 }), 0);
  assert.equal(D.countActive({ status: '', sort: 'newest', limit: 25 }, { status: 'active', sort: 'oldest_open', limit: 25 }), 2);
});

test('suodattimet piilossa oletuksena, haku näkyy, painike avaa ja aktiivinen valinta säilyy', () => {
  I.setLang('fi');
  const state = { paymentStatus: '' };
  const search = document.createElement('input');
  search.setAttribute('type', 'search');
  search.setAttribute('placeholder', 'Hae tilausnumerolla tai nimellä');
  const sel = document.createElement('select');
  sel.addEventListener('change', () => { state.paymentStatus = sel.value; });
  const d = D.filterDrawer({
    search, filters: [sel], testid: 'orders-filters',
    activeCount: () => D.countActive(state, { paymentStatus: '' }),
  });
  assert.equal(d.button.tagName, 'BUTTON');
  assert.equal(d.button.getAttribute('type'), 'button');
  assert.equal(d.button.getAttribute('aria-expanded'), 'false');
  assert.equal(d.button.getAttribute('aria-controls'), d.panel.id);
  assert.equal(d.panel.hidden, true);
  assert.equal(d.node.contains(search), true);
  assert.equal(d.panel.contains(search), false);
  assert.equal(d.panel.contains(sel), true);
  assert.match(d.button.textContent, /Näytä suodattimet/);
  assert.equal(badge(d.button).hidden, true);
  assert.equal(d.node.classList.contains('is-open'), false);

  d.button.click();
  assert.equal(d.button.getAttribute('aria-expanded'), 'true');
  assert.equal(d.panel.hidden, false);
  assert.match(d.button.textContent, /Piilota suodattimet/);
  assert.equal(d.node.classList.contains('is-open'), true);

  sel.value = 'paid';
  sel.dispatch('change');
  assert.equal(state.paymentStatus, 'paid');
  assert.equal(badge(d.button).hidden, false);
  assert.match(d.button.textContent, /Suodattimia: 1/);

  d.button.click();
  assert.equal(d.panel.hidden, true);
  assert.equal(d.button.getAttribute('aria-expanded'), 'false');
  assert.equal(sel.value, 'paid');
  assert.match(d.button.textContent, /Näytä suodattimet/);
  assert.match(d.button.textContent, /Suodattimia: 1/);
  assert.equal(d.node.classList.contains('is-open'), false);
});

test('englanninkielinen painike ja tuontitiedoston avaimet', async () => {
  I.setLang('en');
  const d = D.filterDrawer({
    search: document.createElement('input'),
    filters: [document.createElement('select')],
    activeCount: () => 2,
    testid: 'en-filters',
  });
  assert.match(d.button.textContent, /Show filters/);
  assert.match(d.button.textContent, /Filters: 2/);
  I.setLang('fi');

  const fi = Object.keys(T.FILTER_TEXTS.fi).sort();
  const en = Object.keys(T.FILTER_TEXTS.en).sort();
  assert.deepEqual(fi, en);
  assert.deepEqual(fi, ['ui.admin.filters.active', 'ui.admin.filters.hide', 'ui.admin.filters.show']);
  const rows = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-4.json'), 'utf8')).filter((r) => r.key.startsWith('ui.admin.filters.'));
  assert.equal(rows.length, 6);
  for (const row of rows) {
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.equal(row.text, T.FILTER_TEXTS[row.lang][row.key]);
    assert.ok(row.text.length <= row.max_len);
    assert.equal(/[€]|<\w|https?:/.test(row.text), false);
    const ph = [...row.text.matchAll(/\{\{var:[a-z0-9_]+\}\}/g)].map((m) => m[0]);
    assert.deepEqual(row.placeholders, ph);
  }
  const drawerSrc = readFileSync(join(root, 'admin/filter-drawer.js'), 'utf8');
  assert.match(drawerSrc, /h\('button'/);
  assert.doesNotMatch(drawerSrc, /Näytä suodattimet|Piilota suodattimet|Suodattimia/);

  T.clearFilterTextCache();
  const ok = await T.loadFilterTexts(async () => ({ ok: true, texts: [{ key: 'ui.admin.filters.show', lang: 'fi', text: 'Avaa suodatus' }] }));
  assert.equal(ok, true);
  assert.equal(T.filterText('ui.admin.filters.show', null, 'fi'), 'Avaa suodatus');
  assert.equal(T.filterText('ui.admin.filters.hide', null, 'fi'), 'Piilota suodattimet');
  T.clearFilterTextCache();
  assert.equal(await T.loadFilterTexts(async () => { throw new Error('verkko'); }), false);
  assert.equal(T.filterText('ui.admin.filters.show', null, 'fi'), 'Näytä suodattimet');
});

test('sama laatikko on käytössä listoilla, joilla on haku ja useita suodattimia', () => {
  const lists = [
    ['admin/views/talous-orders.js', 'orders-search'],
    ['admin/views/talous-payments.js', 'payments-search'],
    ['admin/views/talous-giftcards.js', 'gc-search'],
    ['admin/views/talous-vouchers.js', 'vcl-search'],
    ['admin/views/reservations.js', 'reservations-search'],
    ['admin/views/products.js', 'products-search'],
    ['admin/views/invoices.js', 'invoices-search'],
  ];
  for (const [file, mark] of lists) {
    const src = readFileSync(join(root, file), 'utf8');
    assert.match(src, /filterDrawer\(/, file);
    assert.match(src, new RegExp(mark), file);
    const call = src.slice(src.indexOf('filterDrawer('));
    const searchAt = call.indexOf('search:');
    const filtersAt = call.indexOf('filters:');
    assert.ok(searchAt > 0 && searchAt < filtersAt, file);
  }
  for (const file of ['admin/views/customers.js', 'admin/views/talous-reports.js', 'admin/views/day.js']) {
    assert.doesNotMatch(readFileSync(join(root, file), 'utf8'), /filterDrawer\(/, file);
  }
});
