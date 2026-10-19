// Hallinnan "Lisää tuote": mock, lomake ja tekstit. Ei verkkoa eikä tietokantaa.
// SQL-testi t111 ajetaan psql:llä, ei tässä.
import assert from 'node:assert/strict';
import { copyFileSync, existsSync, readFileSync, unlinkSync } from 'node:fs';
import test from 'node:test';

const href = (rel) => new URL(rel, import.meta.url);
const read = (rel) => readFileSync(href(rel), 'utf8');

const pending = JSON.parse(read('../../content/site-texts.pending-import-19.json'));
const migration = read('../supabase/migrations/20261019081000_booking_111_admin_product_create.sql');
const rollback = read('../supabase/rollbacks/20261019081000_booking_111_ROLLBACK.sql');
const sqlTest = read('../supabase/tests/products/t111_admin_product_create.sql');
const productsSrc = read('../admin/views/products.js');
const css = read('../admin/admin.css');
const pages = read('../../.github/workflows/pages.yml');

function installDom() {
  function textOf(node) {
    if (!node) return '';
    if (node.nodeType === 3) return node.data;
    return (node.children || []).map(textOf).join('');
  }
  function ClassList(el) { this.el = el; }
  ClassList.prototype.contains = function (name) { return this.el.className.split(/\s+/).filter(Boolean).includes(name); };
  ClassList.prototype.toggle = function (name, force) {
    const has = this.contains(name);
    const on = force === undefined ? !has : !!force;
    const parts = new Set(this.el.className.split(/\s+/).filter(Boolean));
    if (on) parts.add(name); else parts.delete(name);
    this.el.className = [...parts].join(' ');
    return on;
  };
  ClassList.prototype.add = function (...names) { for (const n of names) this.toggle(n, true); };
  ClassList.prototype.remove = function (...names) { for (const n of names) this.toggle(n, false); };
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
    this.style = {};
    this.dataset = {};
    this.id = '';
    this.disabled = false;
    this.hidden = false;
    this.checked = false;
    this.value = '';
    this.files = [];
    this.open = false;
  }
  El.prototype = Object.create(Node.prototype);
  Object.defineProperty(El.prototype, 'textContent', {
    get() { return textOf(this); },
    set(v) { this.children = [new Text(v)]; this.children[0].parent = this; },
  });
  Object.defineProperty(El.prototype, 'options', {
    get() { return this.tagName === 'SELECT' ? this.children.filter((c) => c.tagName === 'OPTION') : undefined; },
  });
  El.prototype.setAttribute = function (k, v) {
    this.attrs[k] = String(v);
    if (k === 'id') this.id = String(v);
    if (k === 'class') this.className = String(v);
    if (k === 'value') this.value = String(v);
    if (k === 'hidden') this.hidden = true;
    if (k === 'disabled') this.disabled = true;
    if (k === 'checked') this.checked = true;
  };
  El.prototype.getAttribute = function (k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; };
  El.prototype.hasAttribute = function (k) { return Object.prototype.hasOwnProperty.call(this.attrs, k); };
  El.prototype.addEventListener = function (type, fn) { (this.listeners[type] ||= []).push(fn); };
  El.prototype.removeEventListener = function (type, fn) { this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn); };
  El.prototype.append = function (...items) {
    for (const item of items) {
      if (item == null || item === false) continue;
      const n = item.nodeType ? item : new Text(item);
      if (n.parent && n.parent.children) n.parent.children = n.parent.children.filter((c) => c !== n);
      n.parent = this;
      this.children.push(n);
    }
  };
  El.prototype.replaceChildren = function (...items) {
    for (const c of this.children) c.parent = null;
    this.children = [];
    this.append(...items);
  };
  El.prototype.remove = function () {
    if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this);
    this.parent = null;
  };
  El.prototype.focus = function () {};
  El.prototype.click = function () {
    const ev = { type: 'click', target: this, preventDefault() {} };
    for (const fn of this.listeners.click || []) fn(ev);
  };
  El.prototype.showModal = function () { this.open = true; };
  El.prototype.close = function () {
    this.open = false;
    const ev = { type: 'close', target: this };
    for (const fn of this.listeners.close || []) fn(ev);
    this.remove();
  };
  function matchSel(el, sel) {
    const m = sel.match(/^([a-zA-Z0-9]*)(\[[^\]]+\])?$/);
    if (!m) return false;
    if (m[1] && el.tagName !== m[1].toUpperCase()) return false;
    if (!m[1] && !m[2]) return false;
    if (!m[2]) return true;
    const attr = m[2].match(/^\[([^\]=~]+)(?:="?([^"\]]*)"?)?\]$/);
    if (!attr) return false;
    if (!el.hasAttribute(attr[1])) return false;
    if (attr[2] != null) return el.getAttribute(attr[1]) === attr[2];
    return true;
  }
  function queryAll(root, selector) {
    const parts = String(selector).split(',').map((s) => s.trim()).filter(Boolean);
    const out = [];
    const walk = (n) => {
      if (!n || n.nodeType !== 1) return;
      if (parts.some((p) => matchSel(n, p))) out.push(n);
      for (const c of n.children || []) walk(c);
    };
    for (const c of root.children || []) walk(c);
    return out;
  }
  El.prototype.querySelectorAll = function (sel) { return queryAll(this, sel); };
  El.prototype.querySelector = function (sel) { return queryAll(this, sel)[0] || null; };
  function named(root, name) {
    const walk = (n) => {
      if (!n || n.nodeType !== 1) return null;
      if (n.getAttribute && n.getAttribute('name') === name) return n;
      for (const c of n.children || []) {
        const hit = walk(c);
        if (hit) return hit;
      }
      return null;
    };
    for (const c of root.children || []) {
      const hit = walk(c);
      if (hit) return hit;
    }
    return null;
  }
  function create(tag) {
    const el = new El(tag);
    if (String(tag).toUpperCase() !== 'FORM') return el;
    return new Proxy(el, {
      get(target, prop, recv) {
        if (typeof prop === 'string' && prop !== 'then' && !(prop in target)) {
          const hit = named(target, prop);
          if (hit) return hit;
        }
        const v = Reflect.get(target, prop, recv);
        return typeof v === 'function' ? v.bind(target) : v;
      },
      set(target, prop, value) { return Reflect.set(target, prop, value); },
    });
  }
  const html = create('html');
  const body = create('body');
  html.append(body);
  const document = {
    documentElement: html,
    body,
    activeElement: body,
    createElement: create,
    createElementNS: (_ns, tag) => create(tag),
    createTextNode: (t) => new Text(t),
    getElementById(id) {
      let found = null;
      const walk = (n) => {
        if (found || !n || n.nodeType !== 1) return;
        if (n.id === id) { found = n; return; }
        for (const c of n.children || []) walk(c);
      };
      walk(html);
      return found;
    },
  };
  globalThis.document = document;
  globalThis.Element = El;
  globalThis.FormData = class {
    constructor(form) {
      this.map = new Map();
      const walk = (n) => {
        if (!n || n.nodeType !== 1) return;
        const name = n.getAttribute?.('name');
        if (name && ['INPUT', 'SELECT', 'TEXTAREA'].includes(n.tagName)) {
          const type = (n.getAttribute('type') || '').toLowerCase();
          if (type !== 'checkbox') this.map.set(name, n.value == null ? '' : String(n.value));
        }
        for (const c of n.children || []) walk(c);
      };
      walk(form);
    }
    get(k) { return this.map.has(k) ? this.map.get(k) : null; }
  };
}

function all(node, acc = []) {
  if (node?.nodeType === 1) {
    acc.push(node);
    for (const c of node.children || []) all(c, acc);
  }
  return acc;
}
function q(node, id) { return all(node).find((n) => n.getAttribute('data-testid') === id) || null; }
async function flush() {
  for (let i = 0; i < 20; i++) await new Promise((r) => setTimeout(r, 0));
}

test('pending-import-19 vastaa sanakirjaa, FI+EN, normal, ilman hintoja', async () => {
  const { PRODUCT_TEXTS } = await import(href('../admin/product-texts.js'));
  const keys = new Set();
  for (const row of pending) {
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.deepEqual(row.placeholders, []);
    assert.match(row.key, /^ui\.admin\.product\./);
    assert.ok(row.lang === 'fi' || row.lang === 'en');
    assert.equal(row.text, PRODUCT_TEXTS[row.lang][row.key]);
    assert.doesNotMatch(row.text, /\d|€|@|https?:|www\./);
    keys.add(`${row.key}|${row.lang}`);
  }
  for (const lang of ['fi', 'en']) {
    for (const key of Object.keys(PRODUCT_TEXTS[lang])) assert.ok(keys.has(`${key}|${lang}`), key);
  }
  assert.equal(keys.size, Object.keys(PRODUCT_TEXTS.fi).length * 2);
});

test('migraatio, rollback ja sivutesti on paikallaan', () => {
  assert.match(migration, /create function booking\.admin_product_create\(p_data jsonb\)/);
  assert.match(migration, /security definer/i);
  assert.match(migration, /set search_path = ''/);
  assert.match(migration, /booking\._require_permission\('catalog\.edit'\)/);
  assert.match(migration, /grant execute on function booking\.admin_product_create\(jsonb\) to authenticated, service_role/);
  assert.match(migration, /revoke all on function booking\.admin_product_create\(jsonb\) from public, anon/);
  assert.match(migration, /ADMIN_CREATE/);
  assert.match(migration, /booking\._texts_register_sources\(\)/);
  assert.match(migration, /resource_class/);
  assert.match(migration, /select b\.id into v_biz from kb\.businesses/);
  assert.match(migration, /no_business/);
  assert.doesNotMatch(migration, /setval/);
  assert.match(migration, /20261019081000_booking_111_ROLLBACK/);
  assert.match(rollback, /drop function if exists booking\.admin_product_create\(jsonb\)/);
  assert.match(sqlTest, /duplicate_name/);
  assert.match(sqlTest, /T111 testijuoma/);
  assert.match(sqlTest, /t111_logout\(\)/);
  assert.doesNotMatch(sqlTest, /900000/);
  assert.doesNotMatch(sqlTest, /Virvoitusjuoma/);
  assert.doesNotMatch(sqlTest, /setval/);
  assert.match(sqlTest, /TESTRESULT/);
  assert.match(productsSrc, /productText\('sell_hint'\)/);
  assert.doesNotMatch(productsSrc, /shop_visible: f\.shop_visible/);
  assert.match(pages, /tuote-luonti\.test\.mjs/);
  assert.match(pages, /t111_admin_product_create\.sql/);
  assert.match(productsSrc, /filterDrawer\(/);
  assert.match(productsSrc, /products-search/);
  assert.ok(productsSrc.indexOf('search:') < productsSrc.indexOf('filters:'));
  assert.match(productsSrc, /'audience' in c/);
  assert.match(productsSrc, /data-testid': 'product-add'/);
  assert.match(css, /@media\(max-width:699px\)/);
  assert.match(css, /\.prod-add,\.prod-next \.btn\{width:100%\}/);
});

test('mock luo tuotteen ja hylkää virheet', async () => {
  const { createAdminMock } = await import(href('../admin/options-mock.js'));
  const mock = createAdminMock({ role: 'manager' });
  const created = await mock.rpc('admin_product_create', { p_data: { name: '  T111 testijuoma ', price: '3,50', vat_rate: '13.5', active: true } });
  assert.equal(created.ok, true);
  assert.equal(created.product.name, 'T111 testijuoma');
  assert.equal(created.product.name_en, 'T111 testijuoma');
  assert.equal(created.product.business_id, 1);
  assert.equal(created.product.category, 'product_rental');
  assert.equal(created.product.price_text, '3,50 €');
  assert.equal(created.product.price_type, 'per_unit');
  assert.equal(created.product.config.resource_class, 'none');
  assert.equal(created.product.config.sale_kind, 'other');
  assert.equal(created.product.config.shop_visible, false);
  assert.equal(created.product.config.bookable, false);
  assert.equal(created.product.config.pos_enabled, false);
  assert.equal(created.product.config.age_restricted, false);
  assert.equal(created.product.config.audience, 'consumer');
  assert.equal(created.id, 107);
  await assert.rejects(() => mock.rpc('admin_product_create', { p_data: { name: 't111 testijuoma', price: 1, vat_rate: 25.5 } }), (e) => e.code === 'duplicate_name');
  await assert.rejects(() => mock.rpc('admin_product_create', { p_data: { name: ' ', price: 1, vat_rate: 25.5 } }), (e) => e.code === 'invalid_name');
  await assert.rejects(() => mock.rpc('admin_product_create', { p_data: { name: 'T111 miinus', price: -1, vat_rate: 25.5 } }), (e) => e.code === 'invalid_price');
  await assert.rejects(() => mock.rpc('admin_product_create', { p_data: { name: 'T111 vanha', price: 1, vat_rate: 14 } }), (e) => e.code === 'invalid_vat');
  await assert.rejects(() => mock.rpc('admin_product_create', { p_data: { name: 'T111 outo', price: 1, vat_rate: 17 } }), (e) => e.code === 'invalid_vat');
  await assert.rejects(() => mock.rpc('admin_product_create', { p_data: { name: 'T111 kauppa', price: 1, vat_rate: 25.5, shop_visible: true } }), (e) => e.code === 'unknown_field');
  const hidden = await mock.rpc('admin_product_create', { p_data: { name: 'T111 testijuoma', price: 0, vat_rate: 0, active: false } });
  assert.equal(hidden.product.active, false);
  assert.equal(hidden.product.business_id, 1);
  assert.equal(hidden.product.config.bookable, false);
  assert.equal(hidden.product.config.shop_visible, false);
  const noBiz = createAdminMock({ role: 'manager' });
  noBiz.state.businessId = null;
  await assert.rejects(() => noBiz.rpc('admin_product_create', { p_data: { name: 'T111 ei yritysta', price: 1, vat_rate: 25.5 } }), (e) => e.code === 'no_business');
  const staff = createAdminMock({ role: 'staff', perms: ['bookings.manage', 'pos.use'] });
  await assert.rejects(() => staff.rpc('admin_product_create', { p_data: { name: 'Ei', price: 1, vat_rate: 25.5 } }), (e) => e.code === 'forbidden');
});

test('lisää tuote avaa tyhjän lomakkeen ja luonnin jälkeen muokkauksen', async () => {
  installDom();
  globalThis.location = { search: '', hash: '#/tuotteet', pathname: '/hallinta/' };
  globalThis.history = { replaceState(_s, _t, url) { if (url) globalThis.location.hash = url; } };
  globalThis.window = globalThis;
  globalThis.localStorage = { getItem: () => null, setItem() {}, removeItem() {} };
  globalThis.confirm = () => false;
  const dest = href('../admin/sb.js');
  const createdSb = !existsSync(dest);
  if (createdSb) copyFileSync(href('../shared/sb.js'), dest);
  try {
    const SB = await import(href('../admin/sb.js'));
    const { render } = await import(href('../admin/views/products.js'));
    const { createAdminMock } = await import(href('../admin/options-mock.js'));
    const { ERR_FI } = await import(href('../admin/ui.js'));
    const { PRODUCT_TEXTS } = await import(href('../admin/product-texts.js'));
    assert.equal(ERR_FI.duplicate_name, PRODUCT_TEXTS.fi['ui.admin.product.duplicate']);
    const mock = createAdminMock({ role: 'manager', delay: 0 });
    const products = await mock.rpc('admin_list_products');
    SB.setRpcOverride(mock.rpc);
    const ctx = { can: (p) => p === 'catalog.edit' || p === 'pos.use' || p === 'settings.edit', refs: null };
    let reloaded = 0;
    document.body.replaceChildren();
    const nodes = await render({ ctx, refs: { products }, reload: () => { reloaded += 1; }, query: new URLSearchParams() });
    document.body.append(...nodes);
    const add = q(document.body, 'product-add');
    assert.equal(add.textContent, 'Lisää tuote');
    add.click();
    const form = q(document.body, 'product-create-form');
    assert.ok(form);
    assert.equal(form.name.value, '');
    assert.equal(form.name_en.value, '');
    assert.equal(form.category.value, 'product_rental');
    assert.equal(form.vat_rate.value, '25.5');
    assert.equal(form.active.checked, true);
    assert.equal(form.shop_visible, undefined);
    assert.equal(form.age_restricted.checked, false);
    assert.match(document.body.textContent, /Tuotteet ja vuokrat/);
    assert.match(document.body.textContent, /pikakassassa ja QR-koodilla/);
    assert.match(document.body.textContent, /lisätä pikakassaan/);
    form.name.value = 'T111 testijuoma';
    form.price.value = '3.50';
    form.vat_rate.value = '13.5';
    form.age_restricted.checked = false;
    const ev = { type: 'submit', target: form, preventDefault() {} };
    for (const fn of form.listeners?.submit || []) fn(ev);
    await flush();
    const call = mock.state.calls.find((c) => c.name === 'admin_product_create');
    assert.ok(call);
    assert.equal(call.args.p_data.name, 'T111 testijuoma');
    assert.equal(call.args.p_data.price, '3.50');
    assert.equal(call.args.p_data.vat_rate, '13.5');
    assert.equal(call.args.p_data.category, 'product_rental');
    assert.equal(call.args.p_data.active, true);
    assert.equal(call.args.p_data.shop_visible, undefined);
    assert.equal(Object.hasOwn(call.args.p_data, 'shop_visible'), false);
    assert.equal(q(document.body, 'product-create-form'), null);
    assert.equal(q(document.body, 'product-open-pos').getAttribute('href'), '#/pikakassa');
    assert.equal(q(document.body, 'product-open-qr').getAttribute('href'), '#/asetukset/qr');
    assert.match(document.body.textContent, /Näytä pikakassassa/);
    assert.match(document.getElementById('toast').textContent, /Tuote luotu/);
    assert.equal(reloaded, 1);
    SB.setRpcOverride(null);

    document.body.replaceChildren();
    const staffMock = createAdminMock({ role: 'staff', perms: ['bookings.manage'] });
    const staffProducts = await staffMock.rpc('admin_list_products');
    SB.setRpcOverride(staffMock.rpc);
    const staffNodes = await render({
      ctx: { can: () => false, refs: null },
      refs: { products: staffProducts },
      reload() {},
      query: new URLSearchParams(),
    });
    document.body.append(...staffNodes);
    assert.equal(q(document.body, 'product-add'), null);
    SB.setRpcOverride(null);
  } finally {
    if (createdSb) unlinkSync(dest);
  }
});
