// Pikakassan mobiilijärjestys ja maksupopup. Keinotekoinen DOM, ei verkkoa eikä tietokantaa.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
const href = (rel) => new URL(rel, import.meta.url).href;

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
    this.style = { overflow: '' };
    this.dataset = {};
    this.id = '';
    this.disabled = false;
    this.hidden = false;
    this.value = '';
    this.tabIndex = 0;
  }
  El.prototype = Object.create(Node.prototype);
  Object.defineProperty(El.prototype, 'textContent', {
    get() { return textOf(this); },
    set(v) { this.children = [new Text(v)]; this.children[0].parent = this; },
  });
  Object.defineProperty(El.prototype, 'isConnected', {
    get() {
      let n = this;
      while (n) {
        if (n === document.body || n === document.documentElement) return true;
        n = n.parent;
      }
      return false;
    },
  });
  El.prototype.setAttribute = function (k, v) {
    this.attrs[k] = String(v);
    if (k === 'id') this.id = String(v);
    if (k === 'class') this.className = String(v);
    if (k === 'hidden') this.hidden = true;
    if (k === 'disabled') this.disabled = true;
    if (k === 'tabindex') this.tabIndex = Number(v);
  };
  El.prototype.getAttribute = function (k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; };
  El.prototype.hasAttribute = function (k) { return Object.prototype.hasOwnProperty.call(this.attrs, k); };
  El.prototype.addEventListener = function (type, fn) { (this.listeners[type] ||= []).push(fn); };
  El.prototype.removeEventListener = function (type, fn) { this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn); };
  El.prototype.append = function (...items) {
    for (const item of items) {
      if (item == null || item === false) continue;
      const n = item.nodeType ? item : new Text(item);
      if (n.parent) n.parent.children = n.parent.children.filter((c) => c !== n);
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
  El.prototype.contains = function (node) {
    if (node === this) return true;
    return (this.children || []).some((c) => c === node || (c.contains && c.contains(node)));
  };
  El.prototype.focus = function () { document.activeElement = this; };
  El.prototype.click = function () {
    if (this.tagName === 'BUTTON' || this.tagName === 'INPUT' || this.tagName === 'A') document.activeElement = this;
    const ev = { type: 'click', target: this, preventDefault() {} };
    const chain = [];
    for (let n = this; n; n = n.parent) chain.push(n);
    for (const n of chain) for (const fn of n.listeners?.click || []) fn(ev);
  };
  El.prototype.removeAttribute = function (k) {
    delete this.attrs[k];
    if (k === 'hidden') this.hidden = false;
    if (k === 'disabled') this.disabled = false;
    if (k === 'id') this.id = '';
    if (k === 'class') this.className = '';
  };
  El.prototype.closest = function (sel) {
    let n = this;
    while (n) {
      if (n.nodeType === 1 && matchSel(n, sel)) return n;
      n = n.parent;
    }
    return null;
  };
  El.prototype.scrollIntoView = function () {};
  El.prototype.dispatch = function (type, extra = {}) {
    const ev = {
      type, target: this, defaultPrevented: false, stopped: false, ...extra,
      preventDefault() { this.defaultPrevented = true; },
      stopPropagation() { this.stopped = true; },
    };
    const chain = [];
    for (let n = this; n; n = n.parent) chain.push(n);
    for (const n of chain) {
      if (ev.stopped) break;
      for (const fn of n.listeners?.[type] || []) {
        fn(ev);
        if (ev.stopped) break;
      }
    }
    return ev;
  };
  function matchSel(el, sel) {
    if (sel === 'button' || sel === 'input' || sel === 'select' || sel === 'textarea') return el.tagName === sel.toUpperCase();
    if (sel === '[href]') return el.getAttribute('href') != null;
    if (sel.startsWith('#')) return el.id === sel.slice(1);
    const eq = sel.match(/^\[([^=\]]+)="([^"]*)"\]$/);
    if (eq) return el.getAttribute(eq[1]) === eq[2];
    const has = sel.match(/^\[([^\]]+)\]$/);
    if (has) return el.hasAttribute(has[1]);
    return false;
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
  function create(tag) { return new El(tag); }
  const html = create('html');
  const body = create('body');
  html.append(body);
  const document = {
    documentElement: html,
    body,
    activeElement: body,
    listeners: {},
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
    addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); },
    removeEventListener(type, fn) { this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn); },
  };
  globalThis.document = document;
  globalThis.Element = El;
}

installDom();
globalThis.location = { search: '?mock=1', hash: '', pathname: '/hallinta/' };
globalThis.window = globalThis;
globalThis.localStorage = { getItem: () => null, setItem() {}, removeItem() {} };

const { renderPos } = await import(href('../admin/pos-screen.js'));
const { createAdminMock } = await import(href('../admin/options-mock.js'));
const texts = await import(href('../admin/pos-texts.js'));

const read = (rel) => readFileSync(new URL(rel, import.meta.url), 'utf8');
const pending17 = JSON.parse(read('../../content/site-texts.pending-import-17.json'));
const pending18 = JSON.parse(read('../../content/site-texts.pending-import-18.json'));
const pending113 = JSON.parse(read('../../content/site-texts.pending-import-113.json'));
const pending16 = JSON.parse(read('../../content/site-texts.pending-import-16.json'));
const pending12 = JSON.parse(read('../../content/site-texts.pending-import-12.json'));

function reset() {
  document.body.replaceChildren();
  document.body.className = '';
  document.body.style.overflow = '';
  document.body.dataset = {};
  document.documentElement.className = '';
  document.documentElement.style.overflow = '';
  document.documentElement.dataset = {};
  document.listeners = {};
  document.activeElement = document.body;
}
function all(node, acc = []) {
  if (node?.nodeType === 1) {
    acc.push(node);
    for (const c of node.children || []) all(c, acc);
  }
  return acc;
}
function ids(node) { return all(node).map((n) => n.getAttribute('data-testid')).filter(Boolean); }
function q(node, id) { return all(node).find((n) => n.getAttribute('data-testid') === id) || null; }
function keydown(key, extra = {}) {
  const ev = { type: 'keydown', key, target: document.activeElement, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, ...extra };
  for (const fn of document.listeners.keydown || []) fn(ev);
  return ev;
}
async function flush() {
  for (let i = 0; i < 12; i++) await new Promise((r) => setTimeout(r, 0));
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const ctx = { can: (p) => p === 'pos.use' || p === 'catalog.edit' || p === 'settings.edit' };

async function mount(rpc = createAdminMock({ delay: 0 }).rpc, fn) {
  reset();
  const root = await renderPos({ ctx, rpc, fn: fn || (async (name) => { throw new Error(`fn:${name}`); }) });
  document.body.append(root);
  return root;
}

test('pikapainikkeet ovat ylimpänä, muokkaus alhaalla ja kiinni', async () => {
  const root = await mount();
  const order = ids(root);
  assert.ok(order.indexOf('pos-product-101') >= 0);
  assert.ok(order.indexOf('pos-product-101') < order.indexOf('pos-lines'));
  assert.ok(order.indexOf('pos-lines') < order.indexOf('pos-total'));
  assert.ok(order.indexOf('pos-total') < order.indexOf('pos-pay'));
  assert.ok(order.indexOf('pos-pay') < order.indexOf('pos-edit'));
  assert.equal(order.includes('pos-editor'), false);
  assert.equal(order.includes('pos-pay-dialog'), false);
  assert.equal(all(root).some((n) => n.getAttribute('name') === 'tender'), false);
  assert.equal(ids(q(root, 'pos-grid')).includes('pos-lines'), false);
  const edit = q(root, 'pos-edit');
  assert.equal(edit.textContent, 'Muokkaa pikakassaa');
  assert.equal(edit.classList.contains('pos-edit-link'), true);
  assert.equal(edit.getAttribute('aria-expanded'), 'false');
  assert.match(q(root, 'pos-product-101').textContent, /Vichy/);
  assert.match(q(root, 'pos-total').textContent, /0/);
  edit.click();
  const open = ids(root);
  assert.ok(open.indexOf('pos-edit') < open.indexOf('pos-editor'));
  assert.ok(open.indexOf('pos-pay') < open.indexOf('pos-editor'));
  const tools = q(root, 'pos-tools');
  const last = tools.children.filter((c) => c.nodeType === 1).at(-1);
  assert.equal(last.getAttribute('data-testid'), 'pos-editor');
  assert.equal(q(root, 'pos-edit').getAttribute('aria-expanded'), 'true');
  assert.equal(q(root, 'pos-edit').textContent, 'Valmis');
  assert.ok(all(q(root, 'pos-editor')).some((n) => n.textContent === 'Lisää tuote pikakassaan'));
  assert.ok(all(q(root, 'pos-editor')).some((n) => n.getAttribute('aria-label') === 'Siirrä ylös'));
  assert.ok(all(q(root, 'pos-editor')).some((n) => n.getAttribute('aria-label') === 'Siirrä alas'));
  assert.ok(q(root, 'pos-remove-101'));
});

test('maksurivipalkki on matala rivi ja maara on samalla rivilla', async () => {
  const root = await mount();
  let btn = q(root, 'pos-lines');
  assert.equal(btn.tagName, 'BUTTON');
  assert.equal(btn.classList.contains('pos-lines-btn'), true);
  assert.equal(btn.classList.contains('pos-btn'), false);
  assert.equal(btn.getAttribute('aria-expanded'), 'false');
  assert.equal(btn.getAttribute('aria-label'), 'Ostoskori 0');
  const kids = btn.children.filter((c) => c.nodeType === 1);
  assert.equal(kids.length, 2);
  assert.equal(kids[0].className, 'pos-lines-label');
  assert.equal(kids[0].textContent, 'Ostoskori');
  assert.equal(kids[1].className, 'pos-lines-count');
  assert.equal(kids[1].classList.contains('pos-price'), false);
  assert.equal(kids[1].textContent, '0');
  assert.equal(q(root, 'pos-product-101').classList.contains('pos-btn'), true);
  q(root, 'pos-product-101').click();
  q(root, 'pos-product-101').click();
  btn = q(root, 'pos-lines');
  assert.equal(btn.getAttribute('aria-expanded'), 'false');
  assert.equal(btn.getAttribute('aria-label'), 'Ostoskori 2');
  assert.equal(btn.children.filter((c) => c.nodeType === 1)[1].textContent, '2');
  assert.equal(q(root, 'pos-panel').textContent.includes('Vichy'), false);
  btn.click();
  btn = q(root, 'pos-lines');
  assert.equal(btn.getAttribute('aria-expanded'), 'true');
  assert.match(q(root, 'pos-panel').textContent, /Vichy/);
  btn.click();
  assert.equal(q(root, 'pos-lines').getAttribute('aria-expanded'), 'false');
  const css = read('../admin/admin.css');
  const bar = css.match(/\.pos-lines-btn\{[^}]+\}/)[0];
  const prod = css.match(/\.pos-btn\{[^}]+\}/)[0];
  const pill = css.match(/\.pos-lines-count\{[^}]+\}/)[0];
  assert.match(bar, /flex-direction:row/);
  assert.match(bar, /justify-content:space-between/);
  assert.equal(bar.includes('88px'), false);
  assert.ok(Number(bar.match(/padding:(\d+)px/)[1]) <= 8);
  assert.ok(Number(bar.match(/min-height:(\d+)px/)[1]) <= 44);
  assert.match(prod, /flex-direction:column/);
  assert.match(prod, /min-height:88px/);
  assert.ok(Number(pill.match(/font-size:(\d+)px/)[1]) <= 15);
  assert.match(pill, /border-radius:999px/);
  const src = read('../admin/pos-screen.js');
  assert.match(src, /class: 'pos-lines-btn'/);
  assert.equal(src.includes('pos-btn pos-lines-btn'), false);
  assert.match(src, /aria-expanded/);
});

test('tyhjä kassa ei avaa muokkausosioita itsestään', async () => {
  const mock = createAdminMock({ delay: 0 });
  const root = await mount(async (name, args) => (name === 'admin_pos_catalog' ? [] : mock.rpc(name, args)));
  assert.equal(q(root, 'pos-editor'), null);
  assert.ok(q(root, 'pos-empty'));
  assert.ok(ids(root).indexOf('pos-pay') < ids(root).indexOf('pos-edit'));
  q(root, 'pos-edit').click();
  assert.ok(q(root, 'pos-editor'));
  assert.ok(ids(root).indexOf('pos-lines') < ids(root).indexOf('pos-editor'));
});

test('Maksa avaa popupin; Escape, tausta ja sulku palauttavat fokuksen ja scrollin', async () => {
  const root = await mount();
  q(root, 'pos-pay').click();
  assert.equal(document.getElementById('pos-pay-dialog'), null);
  assert.match(document.getElementById('toast').textContent, /Ostoskori on tyhjä/);
  q(root, 'pos-product-101').click();
  assert.match(q(root, 'pos-total').textContent, /3/);
  q(root, 'pos-pay').click();
  const dlg = document.getElementById('pos-pay-dialog');
  assert.ok(dlg);
  assert.equal(root.contains(dlg), false);
  assert.equal(dlg.getAttribute('role'), 'dialog');
  assert.equal(dlg.getAttribute('aria-modal'), 'true');
  assert.equal(dlg.getAttribute('aria-labelledby'), 'pos-pay-title');
  assert.equal(document.getElementById('pos-pay-title').textContent, 'Maksu');
  assert.equal(q(dlg, 'pos-amount').textContent.includes('Summa') || dlg.textContent.includes('Summa'), true);
  assert.match(q(dlg, 'pos-amount').textContent, /3/);
  assert.equal(document.body.style.overflow, 'hidden');
  assert.equal(document.documentElement.style.overflow, 'hidden');
  assert.equal(document.body.classList.contains('pos-modal-open'), true);
  assert.equal(document.activeElement, dlg);
  const radios = all(dlg).filter((n) => n.getAttribute('name') === 'tender');
  assert.deepEqual(radios.map((n) => n.value), ['payment_link', 'card_terminal']);
  assert.equal(radios.find((n) => n.value === 'card_terminal').hasAttribute('disabled'), true);
  assert.equal(radios.find((n) => n.value === 'payment_link').hasAttribute('disabled'), false);
  assert.equal(dlg.textContent.includes('MobilePay'), false);
  assert.equal(all(root).some((n) => n.getAttribute('name') === 'tender'), false);
  assert.equal(dlg.textContent.includes('Käteinen'), false);
  assert.match(dlg.textContent, /Tulossa/);
  assert.equal(q(dlg, 'pos-confirm').textContent, 'Vahvista maksu');
  dlg.click();
  assert.ok(document.getElementById('pos-pay-dialog'));
  const esc = keydown('Escape');
  assert.equal(esc.defaultPrevented, true);
  assert.equal(document.getElementById('pos-pay-dialog'), null);
  assert.equal(document.body.style.overflow, '');
  assert.equal(document.body.classList.contains('pos-modal-open'), false);
  assert.equal(document.activeElement, q(root, 'pos-pay'));
  q(root, 'pos-pay').click();
  document.getElementById('pos-pay-overlay').click();
  assert.equal(document.getElementById('pos-pay-dialog'), null);
  assert.equal(document.activeElement.getAttribute('data-testid'), 'pos-pay');
  q(root, 'pos-pay').click();
  q(document.getElementById('pos-pay-dialog'), 'pos-pay-close').click();
  assert.equal(document.getElementById('pos-pay-overlay'), null);
  assert.equal(q(document.body, 'pos-pay-close'), null);
});

test('maksutapa vahvistetaan popupissa; maksulinkki pysyy, MobilePayta ei ole', async () => {
  const mock = createAdminMock({ delay: 0 });
  const root = await mount(mock.rpc);
  q(root, 'pos-product-101').click();
  q(root, 'pos-pay').click();
  let dlg = document.getElementById('pos-pay-dialog');
  q(dlg, 'pos-confirm').click();
  await flush();
  assert.match(document.getElementById('toast').textContent, /Valitse maksutapa/);
  assert.equal(mock.state.calls.some((c) => c.name === 'admin_pos_checkout'), false);
  dlg = document.getElementById('pos-pay-dialog');
  assert.equal(all(dlg).some((n) => n.getAttribute('name') === 'tender' && n.value === 'mobilepay'), false);
  assert.equal(all(dlg).some((n) => n.getAttribute('name') === 'mpflow'), false);
  assert.equal(q(dlg, 'pos-phone'), null);
  assert.equal(dlg.textContent.includes('MobilePay'), false);
  const link = all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === 'payment_link');
  link.dispatch('change');
  const origSet = globalThis.setInterval;
  const origClear = globalThis.clearInterval;
  globalThis.setInterval = () => 1;
  globalThis.clearInterval = () => {};
  try {
    dlg = document.getElementById('pos-pay-dialog');
    const email = q(dlg, 'pos-email');
    assert.equal(email.getAttribute('type'), 'text');
    assert.equal(email.getAttribute('role'), 'combobox');
    assert.equal(email.getAttribute('aria-autocomplete'), 'list');
    assert.equal(email.getAttribute('autocomplete'), 'off');
    email.value = 'asiakas@example.test';
    email.dispatch('input');
    q(dlg, 'pos-confirm').click();
    await flush();
    const paid = document.getElementById('pos-pay-dialog');
    assert.match(paid.textContent, /Maksettu/);
    const checkout = mock.state.calls.find((c) => c.name === 'admin_pos_checkout');
    assert.deepEqual(checkout.args.p_items, [{ product_id: 101, quantity: 1 }]);
    assert.equal(checkout.args.p_email, 'asiakas@example.test');
    assert.equal(mock.state.calls.some((c) => c.name === 'admin_create_payment_link'), false);
    assert.equal(mock.state.calls.some((c) => c.name === 'admin_pos_send_link'), true);
    assert.equal(mock.state.calls.some((c) => c.name === 'admin_pos_mock_tender'), true);
    assert.equal(all(root).some((n) => n.getAttribute('name') === 'tender'), false);
  } finally {
    globalThis.setInterval = origSet;
    globalThis.clearInterval = origClear;
  }
});

test('kaksi peräkkäistä vahvistusta luo yhden kassatilauksen', async () => {
  const mock = createAdminMock({ delay: 0 });
  let pending = 0;
  let release;
  const gate = new Promise((r) => { release = r; });
  const rpc = async (name, args) => {
    if (name === 'admin_pos_checkout') { pending += 1; await gate; }
    return mock.rpc(name, args);
  };
  const root = await mount(rpc);
  q(root, 'pos-product-101').click();
  q(root, 'pos-pay').click();
  let dlg = document.getElementById('pos-pay-dialog');
  all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === 'payment_link').dispatch('change');
  dlg = document.getElementById('pos-pay-dialog');
  const email = q(dlg, 'pos-email');
  email.value = 'asiakas@example.test';
  email.dispatch('input');
  const first = q(dlg, 'pos-confirm');
  first.click();
  first.click();
  const again = q(document.getElementById('pos-pay-dialog'), 'pos-confirm');
  again.click();
  q(root, 'pos-pay').click();
  assert.equal(pending, 1);
  assert.equal(again.hasAttribute('disabled'), true);
  assert.equal(again.textContent, 'Odotetaan');
  assert.equal(q(root, 'pos-pay').hasAttribute('disabled'), true);
  assert.ok(document.getElementById('pos-pay-dialog'));
  release();
  await flush();
  assert.equal(mock.state.calls.filter((c) => c.name === 'admin_pos_checkout').length, 1);
  assert.equal(mock.state.calls.filter((c) => c.name === 'admin_pos_send_link').length, 1);
});

test('MobilePay-maksutapaa ei näytetä pikakassan maksuikkunassa', async () => {
  const prev = globalThis.location.search;
  globalThis.location.search = '';
  const mock = createAdminMock({ delay: 0 });
  try {
    const root = await mount(mock.rpc);
    q(root, 'pos-product-101').click();
    q(root, 'pos-pay').click();
    const dlg = document.getElementById('pos-pay-dialog');
    assert.equal(all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === 'mobilepay'), undefined);
    assert.match(dlg.textContent, /Maksulinkki/);
    assert.match(dlg.textContent, /Korttipääte/);
    assert.match(dlg.textContent, /Tulossa/);
    assert.equal(dlg.textContent.includes('MobilePay'), false);
    const src = read('../admin/pos-screen.js');
    assert.equal(src.includes('mobilepay-start'), false);
    assert.equal(src.includes('mobilepay-notify'), false);
    assert.equal(src.includes('pos-phone'), false);
    q(dlg, 'pos-confirm').click();
    await flush();
    assert.equal(mock.state.calls.some((c) => c.name === 'admin_pos_checkout'), false);
    assert.match(document.getElementById('toast').textContent, /Valitse maksutapa/);
  } finally {
    globalThis.location.search = prev;
  }
});

test('maksulinkki vaatii osoitteen, näyttää jonon ja uudelleenlähetys ei perua tilausta', async () => {
  const prev = globalThis.location.search;
  globalThis.location.search = '';
  const mock = createAdminMock({ delay: 0 });
  let tick = null;
  const origSet = globalThis.setInterval;
  const origClear = globalThis.clearInterval;
  globalThis.setInterval = (fn) => { tick = fn; return 1; };
  globalThis.clearInterval = () => {};
  try {
    const root = await mount(mock.rpc);
    q(root, 'pos-product-101').click();
    q(root, 'pos-pay').click();
    let dlg = document.getElementById('pos-pay-dialog');
    all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === 'payment_link').dispatch('change');
    dlg = document.getElementById('pos-pay-dialog');
    q(dlg, 'pos-confirm').click();
    await flush();
    dlg = document.getElementById('pos-pay-dialog');
    assert.match(q(dlg, 'pos-pay-error').textContent, /Anna sähköpostiosoite/);
    assert.equal(mock.state.calls.some((c) => c.name === 'admin_pos_checkout'), false);
    let inp = q(dlg, 'pos-email');
    inp.value = 'ei-kelpaa';
    inp.dispatch('input');
    q(dlg, 'pos-confirm').click();
    await flush();
    dlg = document.getElementById('pos-pay-dialog');
    assert.match(q(dlg, 'pos-pay-error').textContent, /Tarkista sähköpostiosoite/);
    assert.equal(mock.state.calls.some((c) => c.name === 'admin_pos_checkout'), false);
    inp = q(dlg, 'pos-email');
    inp.value = 'asiakas@example.test';
    inp.dispatch('input');
    q(dlg, 'pos-confirm').click();
    await flush();
    dlg = document.getElementById('pos-pay-dialog');
    assert.match(q(dlg, 'pos-mail').textContent, /jonossa/);
    assert.match(q(dlg, 'pos-mail-to').textContent, /a\*\*\*@e\*\*\*\.test/);
    assert.equal(dlg.textContent.includes('asiakas@example.test'), false);
    assert.match(dlg.textContent, /maksa/i);
    assert.equal(q(dlg, 'pos-mail-resend'), null);
    assert.equal(mock.state.calls.some((c) => c.name === 'admin_create_payment_link'), false);
    assert.equal(mock.state.posMail.length, 1);
    mock.state.posMail[0].status = 'dry_run';
    await tick();
    await flush();
    dlg = document.getElementById('pos-pay-dialog');
    assert.match(q(dlg, 'pos-mail').textContent, /ei lähde oikeasti/);
    mock.state.posMail[0].status = 'failed';
    await tick();
    await flush();
    dlg = document.getElementById('pos-pay-dialog');
    assert.equal(q(dlg, 'pos-mail-resend').textContent, 'Lähetä uudelleen');
    q(dlg, 'pos-mail-resend').click();
    await flush();
    dlg = document.getElementById('pos-pay-dialog');
    assert.match(q(dlg, 'pos-mail-error').textContent, /Liian monta/);
    assert.equal(mock.state.posOrders[0].status, 'pending');
    assert.equal(mock.state.calls.filter((c) => c.name === 'admin_pos_void').length, 0);
    assert.equal(mock.state.posMail.length, 1);
    mock.state.posMail[0].created = Date.now() - 120000;
    q(dlg, 'pos-mail-resend').click();
    await flush();
    assert.equal(mock.state.calls.filter((c) => c.name === 'admin_pos_send_link' && c.args.p_resend === true).length, 2);
    assert.equal(mock.state.posMail.length, 2);
    assert.equal(mock.state.posOrders[0].status, 'pending');
  } finally {
    globalThis.setInterval = origSet;
    globalThis.clearInterval = origClear;
    globalThis.location.search = prev;
  }
});

test('muuttumaton sähköpostitila ei rakenna popupia uudelleen', async () => {
  const prev = globalThis.location.search;
  globalThis.location.search = '';
  const mock = createAdminMock({ delay: 0 });
  let tick = null;
  const origSet = globalThis.setInterval;
  const origClear = globalThis.clearInterval;
  globalThis.setInterval = (fn) => { tick = fn; return 1; };
  globalThis.clearInterval = () => {};
  try {
    const root = await mount(mock.rpc);
    q(root, 'pos-product-101').click();
    q(root, 'pos-pay').click();
    let dlg = document.getElementById('pos-pay-dialog');
    all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === 'payment_link').dispatch('change');
    dlg = document.getElementById('pos-pay-dialog');
    const inp = q(dlg, 'pos-email');
    inp.value = 'asiakas@example.test';
    inp.dispatch('input');
    q(dlg, 'pos-confirm').click();
    await flush();
    await tick();
    await flush();
    const settled = document.getElementById('pos-pay-dialog');
    assert.match(q(settled, 'pos-mail').textContent, /jonossa/);
    await tick();
    await flush();
    assert.equal(document.getElementById('pos-pay-dialog'), settled);
    mock.state.posMail[0].status = 'sent';
    mock.state.posMail[0].sent_at = '2026-10-19T05:00:00.000Z';
    await tick();
    await flush();
    const next = document.getElementById('pos-pay-dialog');
    assert.notEqual(next, settled);
    assert.match(q(next, 'pos-mail').textContent, /lähetetty/);
  } finally {
    globalThis.setInterval = origSet;
    globalThis.clearInterval = origClear;
    globalThis.location.search = prev;
  }
});

test('maksulinkin virhe peruu tilauksen ja jättää popupin auki', async () => {
  const prev = globalThis.location.search;
  globalThis.location.search = '';
  const mock = createAdminMock({ delay: 0 });
  const rpc = async (name, args) => {
    if (name === 'admin_pos_send_link') throw Object.assign(new Error('linkki epaonnistui'), { code: 'link_down' });
    return mock.rpc(name, args);
  };
  try {
    const root = await mount(rpc);
    q(root, 'pos-product-101').click();
    q(root, 'pos-pay').click();
    let dlg = document.getElementById('pos-pay-dialog');
    all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === 'payment_link').dispatch('change');
    dlg = document.getElementById('pos-pay-dialog');
    const inp = q(dlg, 'pos-email');
    inp.value = 'asiakas@example.test';
    inp.dispatch('input');
    q(dlg, 'pos-confirm').click();
    await flush();
    dlg = document.getElementById('pos-pay-dialog');
    assert.match(q(dlg, 'pos-pay-error').textContent, /linkki epaonnistui/);
    assert.ok(q(dlg, 'pos-confirm'));
    assert.equal(q(dlg, 'pos-status'), null);
    assert.equal(mock.state.posOrders[0].status, 'cancelled');
    assert.equal(mock.state.calls.filter((c) => c.name === 'admin_pos_void').length, 1);
    assert.equal(mock.state.calls.some((c) => c.name === 'admin_create_payment_link'), false);
  } finally {
    globalThis.location.search = prev;
  }
});

test('verkkomaksu pois paalta estaa maksulinkin', async () => {
  const mock = createAdminMock({ delay: 0 });
  mock.state.posModes.vismapay_mode = 'off';
  const root = await mount(mock.rpc);
  q(root, 'pos-product-101').click();
  q(root, 'pos-pay').click();
  const dlg = document.getElementById('pos-pay-dialog');
  const link = all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === 'payment_link');
  assert.equal(link.hasAttribute('disabled'), true);
  assert.match(q(dlg, 'pos-vismapay-off').textContent, /maksulinkillä ei voi maksaa/);
  assert.equal(q(dlg, 'pos-email'), null);
});

test('pending-import-17: vain uudet ui.pos-avaimet, FI+EN, normal, ei numeroita', () => {
  const old = new Set([...pending12, ...pending16].map((r) => `${r.key}|${r.lang}`));
  const seen = new Set();
  assert.ok(pending17.length >= 2);
  for (const row of pending17) {
    assert.match(row.key, /^ui\.pos\.[a-z0-9_]+$/);
    assert.ok(['fi', 'en'].includes(row.lang));
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.ok(row.max_len >= row.text.length);
    assert.deepEqual(row.placeholders, []);
    assert.equal(/\d|€|@|https?:|www\./i.test(row.text), false);
    assert.equal(old.has(`${row.key}|${row.lang}`), false);
    assert.equal(seen.has(`${row.key}|${row.lang}`), false);
    seen.add(`${row.key}|${row.lang}`);
  }
  for (const key of Object.keys(texts.POS_PAY_TEXTS.fi)) {
    assert.equal(texts.POS_TEXTS.fi[key], undefined);
    assert.equal(texts.POS_EDIT_TEXTS.fi[key], undefined);
    for (const lang of ['fi', 'en']) {
      const row = pending17.find((r) => r.key === `ui.pos.${key}` && r.lang === lang);
      assert.ok(row, key + ' ' + lang);
      assert.equal(row.text, texts.POS_PAY_TEXTS[lang][key]);
      assert.equal(texts.posText(key, lang), texts.POS_PAY_TEXTS[lang][key]);
    }
  }
  const src = read('../admin/pos-screen.js');
  for (const key of Object.keys(texts.POS_PAY_TEXTS.fi)) assert.match(src, new RegExp(`t\\('${key}'\\)`));
  assert.ok(src.indexOf('await load()') < src.indexOf('new MutationObserver'));
  for (const m of src.matchAll(/'([^'\n]*)'/g)) assert.equal(/[äöåÄÖÅ]/.test(m[1]), false, m[1]);
  const css = read('../admin/admin.css');
  const layout = css.match(/\.pos-layout\{[^}]+\}/)[0];
  assert.equal(layout.includes('grid-template-columns'), false);
  assert.match(css, /@media\(min-width:800px\)\{\.pos-layout\{grid-template-columns/);
  assert.match(css, /\.pos-overlay\{position:fixed/);
  assert.match(css, /\.pos-edit-link\{/);
  assert.match(css, /html\.pos-modal-open,body\.pos-modal-open\{overflow:hidden/);
});

test('pending-import-18: maksulinkin tekstit FI+EN, normal, ei numeroita, kaytossa nakymassa', () => {
  const old = new Set([...pending12, ...pending16, ...pending17].map((r) => `${r.key}|${r.lang}`));
  const seen = new Set();
  const ui = pending18.filter((r) => r.key.startsWith('ui.pos.'));
  assert.equal(ui.length, Object.keys(texts.POS_LINK_TEXTS.fi).length * 2);
  for (const row of ui) {
    assert.match(row.key, /^ui\.pos\.[a-z0-9_]+$/);
    assert.ok(['fi', 'en'].includes(row.lang));
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.ok(row.max_len >= row.text.length);
    assert.deepEqual(row.placeholders, []);
    assert.equal(/\d|€|@|https?:|www\./i.test(row.text), false);
    assert.equal(old.has(`${row.key}|${row.lang}`), false);
    assert.equal(seen.has(`${row.key}|${row.lang}`), false);
    seen.add(`${row.key}|${row.lang}`);
  }
  for (const key of Object.keys(texts.POS_LINK_TEXTS.fi)) {
    assert.equal(texts.POS_TEXTS.fi[key], undefined);
    assert.equal(texts.POS_PAY_TEXTS.fi[key], undefined);
    for (const lang of ['fi', 'en']) {
      const row = ui.find((r) => r.key === `ui.pos.${key}` && r.lang === lang);
      assert.ok(row, key + ' ' + lang);
      assert.equal(row.text, texts.POS_LINK_TEXTS[lang][key]);
      assert.equal(texts.posText(key, lang), texts.POS_LINK_TEXTS[lang][key]);
    }
  }
  const src = read('../admin/pos-screen.js');
  const replaced = new Set(['email', 'email_help']);
  for (const key of Object.keys(texts.POS_LINK_TEXTS.fi)) {
    if (replaced.has(key)) assert.equal(src.includes(`t('${key}')`), false, key);
    else assert.match(src, new RegExp(`t\\('${key}'\\)`));
  }
  assert.equal(src.includes('admin_create_payment_link'), false);
  assert.match(src, /admin_pos_send_link/);
  assert.match(src, /admin_pos_email_status/);
  const pages = read('../../.github/workflows/pages.yml');
  assert.match(pages, /t110 \(booking\/supabase\/tests\/pos\/t110_pos_link_email\.sql\) ei ole tässä ajossa/);
  const sign = pending18.filter((r) => r.key === 'email.payment_link.sign_name');
  assert.deepEqual(sign.map((r) => r.text), ['Tapio', 'Tapio']);
  assert.ok(sign.every((r) => r.class === 'normal' && r.lang && r.max_len === 200));
});

test('asiakaskentta: nimi hakee rekisterista, nuoli ja Enter tayttavat sahkopostin, osoite ilman valintaa kay', async () => {
  const mock = createAdminMock({ delay: 0 });
  const root = await mount(mock.rpc);
  q(root, 'pos-product-101').click();
  q(root, 'pos-pay').click();
  let dlg = document.getElementById('pos-pay-dialog');
  all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === 'payment_link').dispatch('change');
  dlg = document.getElementById('pos-pay-dialog');
  assert.match(dlg.textContent, /Asiakas \(nimi tai sähköposti\)/);
  assert.match(dlg.textContent, /Hae asiakasrekisteristä tai kirjoita sähköposti/);
  const inp = q(dlg, 'pos-email');
  assert.equal(inp.getAttribute('aria-expanded'), 'false');
  assert.equal(inp.getAttribute('aria-controls'), 'pos-customer-list');
  inp.value = 'A';
  inp.dispatch('input');
  await wait(300);
  assert.equal(mock.state.calls.some((c) => c.name === 'admin_search_customers'), false);
  assert.equal(document.getElementById('pos-customer-list').getAttribute('hidden') != null, true);
  inp.value = 'Ai';
  inp.dispatch('input');
  await wait(300);
  await flush();
  const search = mock.state.calls.filter((c) => c.name === 'admin_search_customers');
  assert.equal(search.length, 1);
  assert.deepEqual(search[0].args, { p_search: 'Ai', p_limit: 8 });
  const list = document.getElementById('pos-customer-list');
  assert.equal(list.getAttribute('role'), 'listbox');
  assert.equal(list.hidden, false);
  assert.match(list.textContent, /Aino Testaaja/);
  assert.match(list.textContent, /aino@example.com/);
  const opts = all(list).filter((n) => n.getAttribute('role') === 'option');
  assert.ok(opts.length >= 1 && opts.length <= 8);
  inp.dispatch('keydown', { key: 'ArrowDown' });
  assert.equal(inp.getAttribute('aria-activedescendant'), opts[0].id);
  assert.equal(opts[0].getAttribute('aria-selected'), 'true');
  const esc = inp.dispatch('keydown', { key: 'Escape' });
  assert.equal(esc.defaultPrevented, true);
  assert.equal(document.getElementById('pos-pay-dialog') != null, true);
  assert.equal(document.getElementById('pos-customer-list').hidden, true);
  inp.value = '0401';
  inp.dispatch('input');
  await wait(300);
  await flush();
  const phoneList = document.getElementById('pos-customer-list');
  assert.match(phoneList.textContent, /Liisa Lasku/);
  assert.match(phoneList.textContent, /liisa@t112.test/);
  const phoneOpt = all(phoneList).find((n) => n.getAttribute('role') === 'option');
  phoneOpt.click();
  assert.equal(inp.value, 'liisa@t112.test');
  assert.equal(phoneList.hidden, true);
  inp.value = 'Saunaseura';
  inp.dispatch('input');
  await wait(300);
  await flush();
  assert.equal(document.getElementById('pos-customer-list').textContent.includes('Saunaseura'), false);
  inp.value = 'Ai';
  inp.dispatch('input');
  await wait(300);
  await flush();
  const again = document.getElementById('pos-customer-input');
  again.dispatch('keydown', { key: 'ArrowDown' });
  again.dispatch('keydown', { key: 'Enter' });
  assert.equal(again.value, 'aino@example.com');
  const origSet = globalThis.setInterval;
  const origClear = globalThis.clearInterval;
  globalThis.setInterval = () => 1;
  globalThis.clearInterval = () => {};
  try {
    q(document.getElementById('pos-pay-dialog'), 'pos-confirm').click();
    await flush();
    const checkout = mock.state.calls.find((c) => c.name === 'admin_pos_checkout');
    assert.equal(checkout.args.p_email, 'aino@example.com');
    assert.equal(mock.state.posOrders[0].customer_id, 1);
    assert.equal('p_customer_id' in checkout.args, false);
  } finally {
    globalThis.setInterval = origSet;
    globalThis.clearInterval = origClear;
  }
});

test('asiakashaku epaonnistuu hiljaa ja kirjoitettu osoite kelpaa', async () => {
  const mock = createAdminMock({ delay: 0 });
  const rpc = async (name, args) => {
    if (name === 'admin_search_customers' || name === 'admin_list_customers') throw Object.assign(new Error('forbidden'), { code: 'forbidden' });
    return mock.rpc(name, args);
  };
  const root = await mount(rpc);
  q(root, 'pos-product-101').click();
  q(root, 'pos-pay').click();
  let dlg = document.getElementById('pos-pay-dialog');
  all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === 'payment_link').dispatch('change');
  dlg = document.getElementById('pos-pay-dialog');
  const inp = q(dlg, 'pos-email');
  inp.value = 'Aino';
  inp.dispatch('input');
  await wait(300);
  await flush();
  assert.equal(document.getElementById('pos-customer-list').hidden, true);
  const toast = document.getElementById('toast');
  assert.equal(toast ? toast.textContent.includes('forbidden') : false, false);
  const origSet = globalThis.setInterval;
  const origClear = globalThis.clearInterval;
  globalThis.setInterval = () => 1;
  globalThis.clearInterval = () => {};
  try {
    inp.value = 'asiakas@example.test';
    inp.dispatch('input');
    q(dlg, 'pos-confirm').click();
    await flush();
    assert.equal(mock.state.calls.find((c) => c.name === 'admin_pos_checkout').args.p_email, 'asiakas@example.test');
  } finally {
    globalThis.setInterval = origSet;
    globalThis.clearInterval = origClear;
  }
});

test('pending-import-113: asiakaskentan uudet tekstit FI+EN, normal, ei numeroita, ei paallekkain', () => {
  const old = new Set([...pending12, ...pending16, ...pending17, ...pending18].map((r) => `${r.key}|${r.lang}`));
  const seen = new Set();
  assert.equal(pending113.length, Object.keys(texts.POS_CUSTOMER_TEXTS.fi).length * 2);
  for (const row of pending113) {
    assert.match(row.key, /^ui\.pos\.[a-z0-9_]+$/);
    assert.ok(['fi', 'en'].includes(row.lang));
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.ok(row.max_len >= row.text.length);
    assert.deepEqual(row.placeholders, []);
    assert.equal(/\d|€|@|https?:|www\./i.test(row.text), false);
    assert.equal(old.has(`${row.key}|${row.lang}`), false, row.key);
    assert.equal(seen.has(`${row.key}|${row.lang}`), false);
    seen.add(`${row.key}|${row.lang}`);
  }
  for (const key of Object.keys(texts.POS_CUSTOMER_TEXTS.fi)) {
    assert.equal(texts.POS_LINK_TEXTS.fi[key], undefined);
    for (const lang of ['fi', 'en']) {
      const row = pending113.find((r) => r.key === `ui.pos.${key}` && r.lang === lang);
      assert.equal(row.text, texts.POS_CUSTOMER_TEXTS[lang][key]);
      assert.equal(texts.posText(key, lang), texts.POS_CUSTOMER_TEXTS[lang][key]);
    }
  }
  const src = read('../admin/pos-screen.js');
  for (const key of Object.keys(texts.POS_CUSTOMER_TEXTS.fi)) assert.match(src, new RegExp(`t\\('${key}'\\)`));
  assert.match(read('../admin/admin.css'), /\.pos-suggest\{/);
  assert.match(read('../admin/admin.css'), /\.pos-hit\{[^}]*min-height:48px/);
});

// HALL-KASSA-01: kori sivupaneelina ≥ 800 px, selkeät painikenimet, aria-live ja kieli yhteisestä valinnasta
test('leveällä näytöllä kori on aina näkyvissä sivupaneelissa ilman avauspainiketta', async () => {
  globalThis.matchMedia = (q) => ({ matches: /800px/.test(q), addEventListener() {}, removeEventListener() {} });
  try {
    const root = await mount();
    assert.equal(q(root, 'pos-lines'), null, 'ei avauspainiketta');
    const side = q(root, 'pos-side');
    assert.ok(ids(side).includes('pos-panel'), 'kori on sivupaneelissa');
    assert.ok(side.children.some((c) => c.tagName === 'H2' && c.textContent === 'Ostoskori'));
    assert.match(side.textContent, /Ostoskori on tyhjä/);
    q(root, 'pos-product-101').click();
    assert.match(q(root, 'pos-side').textContent, /Vichy/);
    assert.ok(ids(q(root, 'pos-side')).includes('pos-product-line'));
    assert.equal(ids(q(root, 'pos-grid')).includes('pos-panel'), false);
    assert.ok(ids(root).includes('pos-custom-add'), 'vapaa rivi säilyy');
  } finally { delete globalThis.matchMedia; }
});

test('−/+ -painikkeilla on omat nimet ja summa ilmoitetaan ruudunlukijalle', async () => {
  const root = await mount();
  q(root, 'pos-product-101').click();
  q(root, 'pos-lines').click();
  const labels = all(q(root, 'pos-product-line')).filter((n) => n.tagName === 'BUTTON').map((n) => n.getAttribute('aria-label'));
  assert.deepEqual(labels.slice(0, 2), ['Vähennä', 'Lisää']);
  assert.equal(q(root, 'pos-total').getAttribute('aria-live'), 'polite');
});

test('pikakassan kieli tulee yhteisestä valinnasta', async () => {
  const i18n = await import(href('../admin/talous-i18n.js'));
  i18n.setLang('en');
  try {
    const root = await mount();
    assert.equal(q(root, 'pos-lines').getAttribute('aria-label'), 'Cart 0');
    assert.equal(q(root, 'pos-pay').textContent, 'Pay');
  } finally { i18n.setLang('fi'); }
  assert.equal(read('../admin/pos-screen.js').includes("const lang = 'fi'"), false);
});

test('pending-import-159: ostoskorin tekstit FI+EN vastaavat koodin sanakirjaa', () => {
  const rows = JSON.parse(read('../../content/site-texts.pending-import-159.json'));
  for (const key of Object.keys(texts.POS_CART_TEXTS.fi)) {
    for (const lang of ['fi', 'en']) {
      const row = rows.find((r) => r.key === `ui.pos.${key}` && r.lang === lang);
      assert.ok(row, `${key} ${lang}`);
      assert.equal(row.text, texts.POS_CART_TEXTS[lang][key]);
      assert.equal(row.class, 'normal');
    }
  }
  assert.equal(rows.length, Object.keys(texts.POS_CART_TEXTS.fi).length * 2);
  const css = read('../admin/admin.css');
  assert.match(css, /@media\(min-width:1000px\)\{\.pos-grid\{grid-template-columns:repeat\(4,1fr\)\}/);
  assert.match(css, /@media\(min-width:800px\)\{\.pos-layout\{grid-template-columns:minmax\(0,1fr\) 300px\}/);
});

// ---- HALL-KASSA-02: myynnin haku (t1808u) ja varattavan tuotteen paneeli (t1809u) ----
function typeSale(root, text) {
  const inp = q(root, 'pos-sale-input');
  inp.value = text;
  inp.dispatch('input');
  return inp;
}
const hits = (root) => all(root).filter((n) => n.getAttribute('data-testid') === 'pos-sale-hit');
function cartNames(root) {
  const toggle = q(root, 'pos-lines');
  if (toggle && toggle.getAttribute('aria-expanded') === 'false') toggle.click();
  return cartRows(root);
}
const cartRows = (root) => all(root).filter((n) => ['pos-product-line', 'pos-custom-line'].includes(n.getAttribute('data-testid'))).map((n) => n.children[0].textContent);

test('haku: nimi näyttää hinnan ja valinta lisää ei-varattavan tuotteen koriin', async () => {
  const root = await mount();
  const inp = q(root, 'pos-sale-input');
  assert.equal(inp.getAttribute('role'), 'combobox');
  assert.equal(inp.getAttribute('aria-expanded'), 'false');
  typeSale(root, 'vic');
  const list = q(root, 'pos-sale-list');
  assert.equal(list.hidden, false);
  assert.equal(inp.getAttribute('aria-expanded'), 'true');
  const hs = hits(root);
  assert.equal(hs.length, 1);
  assert.match(hs[0].textContent, /Vichy/);
  assert.match(hs[0].textContent, /3,00/);
  hs[0].click();
  assert.deepEqual(cartNames(root), ['Vichy']);
  assert.equal(q(root, 'pos-book'), null, 'ei-varattava ei avaa paneelia');
  assert.equal(q(root, 'pos-sale-input').value, '', 'haku tyhjenee valinnan jälkeen');
  assert.equal(q(root, 'pos-total').textContent.replace(/\s/g, ''), '3,00€');
});

test('haku: koodi ja alias löytävät tuotteen', async () => {
  const root = await mount();
  typeSale(root, 'sip01');
  assert.match(hits(root)[0].textContent, /Sipsit/);
  typeSale(root, 'kivennäis');
  assert.match(hits(root)[0].textContent, /Vichy/);
});

test('haku: pos-kanavan tuote löytyy kanavatiedosta, vaikka vanha pos_enabled on pois', async () => {
  const mock = createAdminMock({ delay: 0 });
  await mock.rpc('admin_set_product_sales_channels', { p_product_id: 105, p_codes: ['pos'] });
  const root = await mount(mock.rpc);
  typeSale(root, 'käsipyyhe');
  const hs = hits(root);
  assert.equal(hs.length, 1);
  hs[0].click();
  assert.deepEqual(cartNames(root), ['Käsipyyhe']);
  assert.equal(mock.state.calls.some((c) => c.name === 'admin_list_sales_channels'), true);
});

test('haku: ei osumaa → «Lisää oma rivi» avaa lomakkeen esitäytetyllä nimellä', async () => {
  const root = await mount();
  typeSale(root, 'Kahvi');
  assert.equal(hits(root).length, 0);
  const custom = q(root, 'pos-sale-custom');
  assert.ok(custom);
  assert.match(custom.textContent, /Lisää oma rivi:/);
  assert.match(custom.textContent, /Kahvi/);
  assert.match(q(root, 'pos-sale-list').textContent, /Ei osumia/);
  custom.click();
  assert.equal(q(root, 'pos-custom-description').value, 'Kahvi');
  assert.ok(q(root, 'pos-custom-price'));
  assert.equal(q(root, 'pos-sale-input').value, '');
  q(root, 'pos-custom-price').value = '4,50';
  q(root, 'pos-custom-price').dispatch('input');
  q(root, 'pos-custom-save').click();
  assert.deepEqual(cartNames(root), ['Kahvi']);
  assert.equal(q(root, 'pos-total').textContent.replace(/\s/g, ''), '4,50€');
});

test('haku: oma rivi on tarjolla myös osumien alla; vanha «Lisää vapaa rivi» -nappi säilyy', async () => {
  const root = await mount();
  assert.ok(q(root, 'pos-custom-add'));
  typeSale(root, 'vichy');
  const opts = all(q(root, 'pos-sale-list')).filter((n) => n.getAttribute('role') === 'option');
  assert.equal(opts.at(-1).getAttribute('data-testid'), 'pos-sale-custom');
  assert.ok(opts.length >= 2);
});

test('haku: nuolet, Enter ja Esc', async () => {
  const root = await mount();
  const inp = typeSale(root, 'vichy');
  const opts = () => all(q(root, 'pos-sale-list')).filter((n) => n.getAttribute('role') === 'option');
  assert.equal(opts().every((o) => o.getAttribute('aria-selected') === 'false'), true);
  const down = inp.dispatch('keydown', { key: 'ArrowDown' });
  assert.equal(down.defaultPrevented, true);
  assert.equal(opts()[0].getAttribute('aria-selected'), 'true');
  assert.equal(inp.getAttribute('aria-activedescendant'), opts()[0].id);
  inp.dispatch('keydown', { key: 'ArrowUp' });
  assert.equal(opts().at(-1).getAttribute('aria-selected'), 'true', 'ylös ensimmäisestä kiertää viimeiseen');
  inp.dispatch('keydown', { key: 'ArrowDown' });
  assert.equal(opts()[0].getAttribute('aria-selected'), 'true');
  const esc = inp.dispatch('keydown', { key: 'Escape' });
  assert.equal(esc.defaultPrevented, true);
  assert.equal(q(root, 'pos-sale-list').hidden, true);
  assert.equal(inp.value, '');
  // Enter ilman nuolta valitsee ensimmäisen osuman
  typeSale(root, 'sips');
  q(root, 'pos-sale-input').dispatch('keydown', { key: 'Enter' });
  assert.deepEqual(cartNames(root), ['Sipsit']);
  // Enter nuolella valittuun omaan riviin
  const inp2 = typeSale(root, 'Jäätelö');
  inp2.dispatch('keydown', { key: 'ArrowDown' });
  inp2.dispatch('keydown', { key: 'Enter' });
  assert.equal(q(root, 'pos-custom-description').value, 'Jäätelö');
});

test('haku: tyhjä haku ei näytä listaa; tyhjennä-painike tyhjentää', async () => {
  const root = await mount();
  assert.equal(q(root, 'pos-sale-list').hidden, true);
  assert.equal(q(root, 'pos-sale-clear').hidden, true);
  typeSale(root, 'vi');
  assert.equal(q(root, 'pos-sale-clear').hidden, false);
  q(root, 'pos-sale-clear').click();
  assert.equal(q(root, 'pos-sale-list').hidden, true);
});

// ---- t1812u: varattava tuote vain maksuksi (ei varausta) ----
async function openBookable(root, text = 'yleinen') {
  typeSale(root, text);
  hits(root)[0].click();
  await flush();
}
async function payByLink(root, mock) {
  q(root, 'pos-pay').click();
  const dlg = document.getElementById('pos-pay-dialog');
  all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === 'payment_link').dispatch('change');
  const origSet = globalThis.setInterval; const origClear = globalThis.clearInterval;
  globalThis.setInterval = () => 1; globalThis.clearInterval = () => {};
  try {
    const email = q(document.getElementById('pos-pay-dialog'), 'pos-email');
    email.value = 'asiakas@example.test'; email.dispatch('input');
    q(document.getElementById('pos-pay-dialog'), 'pos-confirm').click();
    await flush();
  } finally { globalThis.setInterval = origSet; globalThis.clearInterval = origClear; }
  return mock.state.calls.find((c) => c.name === 'admin_pos_checkout');
}
function setField(root, id, value) { const el = q(root, id); el.value = value; el.dispatch('input'); el.dispatch('change'); }

test('varattava tuote: haku avaa kevyen paneelin, ei aikavalintaa eikä siirtymää, kori ei tyhjene', async () => {
  const mock = createAdminMock({ delay: 0 });
  const root = await mount(mock.rpc);
  typeSale(root, 'vichy');
  hits(root)[0].click();
  assert.deepEqual(cartNames(root), ['Vichy']);
  const prevHash = globalThis.location.hash;
  typeSale(root, 'yleinen');
  const hs = hits(root);
  assert.equal(hs.length, 1);
  assert.match(hs[0].textContent, /Varattava/);
  assert.match(hs[0].textContent, /18,00/);
  hs[0].click();
  await flush();
  assert.deepEqual(cartNames(root), ['Vichy'], 'kori säilyy, ei suoraa lisäystä');
  const panel = q(root, 'pos-book');
  assert.ok(panel);
  assert.match(panel.textContent, /Yleinen saunavuoro/);
  assert.ok(q(root, 'pos-book-date'));
  assert.ok(q(root, 'pos-book-note'));
  assert.ok(q(root, 'pos-book-qty'));
  for (const gone of ['pos-book-continue', 'pos-book-slots', 'pos-book-slot', 'pos-book-none', 'pos-book-duration', 'pos-book-cart-note', 'pos-book-unbooked-off', 'pos-book-prev', 'pos-book-next', 'pos-book-persons']) assert.equal(q(root, gone), null, gone);
  assert.match(q(root, 'pos-book-add').textContent, /^Lisää koriin \(ei varausta\)$/);
  assert.doesNotMatch(panel.textContent, /Jatka varaukseen|tyhjenee|vapaa aika/);
  assert.equal(mock.state.calls.some((c) => c.name === 'admin_day_view' || c.name === 'admin_treatment_availability'), false, 'ei saatavuushakua');
  assert.equal(globalThis.location.hash, prevHash, 'ei siirtymää Uusi varaus -lomakkeelle');
});

test('varattava tuote: nappi lisää rivin koriin, kori säilyy ja checkoutItems on { product_id, quantity, unbooked, note }', async () => {
  const mock = createAdminMock({ delay: 0 });
  const root = await mount(mock.rpc);
  typeSale(root, 'sips');
  hits(root)[0].click();
  await openBookable(root);
  q(root, 'pos-book-add').click();
  assert.equal(q(root, 'pos-book'), null, 'paneeli sulkeutuu');
  assert.deepEqual(cartNames(root), ['Sipsit', 'Yleinen saunavuoro (ilman varausta)1 hlö']);
  assert.equal(q(root, 'pos-total').textContent.replace(/\s/g, ''), '21,00€');
  assert.equal(q(root, 'pos-line-note').textContent, '1 hlö', 'ilman päivää ja muistiinpanoa vain henkilömäärä');
  // sama tuote tavallisena rivinä ja uusi ilman varausta eivät yhdisty
  await openBookable(root);
  q(root, 'pos-book-add').click();
  assert.equal(cartNames(root).length, 3);
});

test('varattava tuote: määrä, vapaaehtoinen päivä ja muistiinpano kulkevat korin riviltä kassalle', async () => {
  const mock = createAdminMock({ delay: 0 });
  const root = await mount(mock.rpc);
  await openBookable(root);
  const qty = all(q(root, 'pos-book-qty')).find((n) => n.getAttribute('name') === 'pos-book-qty');
  qty.value = '3'; qty.dispatch('input');
  setField(root, 'pos-book-date', '2026-11-12');
  setField(root, 'pos-book-note', '  Hoito tehty ilman varausta  ');
  q(root, 'pos-book-add').click();
  assert.equal(q(root, 'pos-total').textContent.replace(/\s/g, ''), '54,00€', '3 × 18 €');
  assert.match(q(root, 'pos-line-note').textContent, /12\.11\.2026/);
  assert.match(q(root, 'pos-line-note').textContent, /Hoito tehty ilman varausta/);
  const checkout = await payByLink(root, mock);
  assert.deepEqual(checkout.args.p_items, [{ product_id: 3, quantity: 3, unbooked: true, note: '12.11.2026, 3 hlö, Hoito tehty ilman varausta' }]);
});

test('varattava tuote: määrän otsikko Määrä; per_person-tuotteella Henkilömäärä; peruutus ja Esc sulkevat', async () => {
  const root = await mount();
  await openBookable(root);
  assert.match(q(root, 'pos-book-qty').textContent, /Määrä/);
  q(root, 'pos-book-cancel').click();
  assert.equal(q(root, 'pos-book'), null);
  assert.deepEqual(cartNames(root), []);
  await openBookable(root, 'ritual');
  assert.match(q(root, 'pos-book-qty').textContent, /Henkilömäärä/);
  q(root, 'pos-book').dispatch('keydown', { key: 'Escape' });
  assert.equal(q(root, 'pos-book'), null);
});

test('varattava tuote: ruudukon painike avaa paneelin, peruutus sulkee sen', async () => {
  const root = await mount();
  q(root, 'pos-product-3').click();
  await flush();
  assert.ok(q(root, 'pos-book'));
  assert.deepEqual(cartNames(root), []);
  q(root, 'pos-book-cancel').click();
  assert.equal(q(root, 'pos-book'), null);
});

test('haku: varattava tuote ilman pos-kanavaa löytyy ja sen voi lisätä koriin (ei estoa)', async () => {
  const root = await mount();
  typeSale(root, 'hoito90');
  const hs = hits(root);
  assert.equal(hs.length, 1);
  assert.match(hs[0].textContent, /Saunahoito/);
  hs[0].click();
  await flush();
  assert.equal(q(root, 'pos-book-add').disabled, false);
  assert.equal(q(root, 'pos-book-unbooked-off'), null);
  q(root, 'pos-book-add').click();
  assert.deepEqual(cartNames(root), ['Saunahoito (ilman varausta)1 hlö']);
});

test('kassa: ilman varausta -rivi lähtee admin_pos_checkoutiin muodossa { product_id, quantity, unbooked, note } ja mock hyväksyy sen', async () => {
  const mock = createAdminMock({ delay: 0 });
  const root = await mount(mock.rpc);
  await openBookable(root, 'hoito90');
  setField(root, 'pos-book-date', '2026-11-12');
  setField(root, 'pos-book-note', 'Jälkilaskutus');
  q(root, 'pos-book-add').click();
  typeSale(root, 'vichy');
  hits(root)[0].click();
  assert.deepEqual(cartNames(root), ['Saunahoito (ilman varausta)12.11.2026, 1 hlö, Jälkilaskutus', 'Vichy']);
  const checkout = await payByLink(root, mock);
  assert.deepEqual(checkout.args.p_items, [{ product_id: 10, quantity: 1, unbooked: true, note: '12.11.2026, 1 hlö, Jälkilaskutus' }, { product_id: 101, quantity: 1 }]);
  const order = mock.state.posOrders.at(-1);
  assert.equal(order.total, 88);
  assert.deepEqual(order.lines[0], { product_id: 10, name: 'Saunahoito — 12.11.2026, 1 hlö, Jälkilaskutus', quantity: 1, unit_price: 85, vat_rate: 25.5, line_total: 85, unbooked: true, note: '12.11.2026, 1 hlö, Jälkilaskutus' });
});

test('mock: admin_pos_checkout – lopullinen sopimus (unbooked kaikille hinnoitelluille, hinta kannasta, virheet)', async () => {
  const mock = createAdminMock({ delay: 0 });
  const co = (items) => mock.rpc('admin_pos_checkout', { p_items: items, p_locale: 'fi', p_email: null });
  const r = await co([{ product_id: 10, quantity: 2, unbooked: true, note: '16.11.2026, 2 hlö' }]);
  assert.equal(r.ok, true); assert.equal(r.total, 170); assert.ok(r.order_id && r.order_no);
  assert.deepEqual(r.lines[0].unbooked, true); assert.equal(r.lines[0].note, '16.11.2026, 2 hlö'); assert.equal(r.lines[0].name, 'Saunahoito — 16.11.2026, 2 hlö');
  // ilman noteä nimi on tuotteen nimi; unbooked ilman pos-kanavaa ja ei-varattavalle hinnoitellulle tuotteelle kelpaa
  assert.equal((await co([{ product_id: 10, quantity: 1, unbooked: true }])).lines[0].name, 'Saunahoito');
  assert.equal((await co([{ product_id: 101, quantity: 1, unbooked: true }])).ok, true);
  // ilman unbooked: varattava → not_counter_product
  await assert.rejects(() => co([{ product_id: 10, quantity: 1 }]), /pikakassassa/);
  // lahjakortti evätään
  await assert.rejects(() => co([{ product_id: 104, quantity: 1, unbooked: true }]), /ei voi lisätä/);
  // ei unit_price- eikä date-kenttää
  await assert.rejects(() => co([{ product_id: 10, quantity: 1, unbooked: true, unit_price: 1 }]), /Hintaa/);
  await assert.rejects(() => co([{ product_id: 10, quantity: 1, unbooked: true, date: '2026-11-16' }]), /päivää/);
  // note: ≤ 200, ei <, vain unbooked-riville
  assert.equal((await co([{ product_id: 10, quantity: 1, unbooked: true, note: 'x'.repeat(200) }])).ok, true);
  await assert.rejects(() => co([{ product_id: 10, quantity: 1, unbooked: true, note: 'x'.repeat(201) }]), /Muistiinpano/);
  await assert.rejects(() => co([{ product_id: 10, quantity: 1, unbooked: true, note: 'a<b' }]), /Muistiinpano/);
  await assert.rejects(() => co([{ product_id: 3, quantity: 1, note: 'x' }]), /Muistiinpano/);
});

test('paneeli: <-merkki ja liian pitkä note näyttävät virheen eikä riviä lisätä', async () => {
  const mock = createAdminMock({ delay: 0 });
  const root = await mount(mock.rpc);
  await openBookable(root);
  setField(root, 'pos-book-note', 'a<b');
  q(root, 'pos-book-add').click();
  assert.ok(q(root, 'pos-book'), 'paneeli jää auki');
  assert.match(q(root, 'pos-book-error').textContent, /kulmasulku/);
  assert.deepEqual(cartNames(root), []);
  setField(root, 'pos-book-note', 'x'.repeat(200));
  q(root, 'pos-book-add').click();
  assert.match(q(root, 'pos-book-error').textContent, /liian pitkä/);
  assert.deepEqual(cartNames(root), []);
});

test('FI ja EN: hakukentän ja paneelin tekstit', async () => {
  const i18n = await import(href('../admin/talous-i18n.js'));
  const root0 = await mount();
  assert.equal(q(root0, 'pos-sale-input').getAttribute('placeholder'), 'Tuotteen nimi, koodi tai oma rivi');
  i18n.setLang('en');
  try {
    const root = await mount();
    assert.equal(q(root, 'pos-sale-input').getAttribute('placeholder'), 'Product name, code or custom line');
    typeSale(root, 'crisps');
    assert.match(hits(root)[0].textContent, /Crisps/);
    assert.match(q(root, 'pos-sale-custom').textContent, /Add custom line:/);
    typeSale(root, 'general');
    assert.equal(hits(root).length, 0);
    await openBookable(root);
    assert.match(q(root, 'pos-book').textContent, /Invoice without a booking/);
    assert.match(q(root, 'pos-book-qty').textContent, /Quantity/);
    assert.match(q(root, 'pos-book').textContent, /Date \(optional\)/);
    assert.match(q(root, 'pos-book').textContent, /Note for the receipt/);
    assert.match(q(root, 'pos-book-add').textContent, /^Add to cart \(no booking\)$/);
    q(root, 'pos-book-add').click();
    assert.match(cartNames(root)[0], /\(without booking\)/);
  } finally { i18n.setLang('fi'); }
});

test('pending-import-178: haun ja varauspaneelin tekstit FI+EN vastaavat koodin sanakirjaa', () => {
  const rows = JSON.parse(read('../../content/site-texts.pending-import-178.json'));
  const dict = texts.POS_SALE_TEXTS;
  assert.deepEqual(Object.keys(dict.fi), Object.keys(dict.en));
  for (const key of Object.keys(dict.fi)) {
    for (const lang of ['fi', 'en']) {
      const row = rows.find((r) => r.key === `ui.pos.${key}` && r.lang === lang);
      assert.ok(row, `${key} ${lang}`);
      assert.equal(row.text, dict[lang][key]);
      assert.equal(row.class, 'normal');
      assert.equal(row.kind, 'plain');
      assert.equal(/[<>{}]|https?:/.test(row.text), false);
    }
  }
  assert.equal(rows.length, Object.keys(dict.fi).length * 2);
  assert.equal(new Set(rows.map((r) => `${r.key}|${r.lang}`)).size, rows.length);
  assert.equal(Object.keys(dict.fi).some((k) => k in texts.POS_TEXTS.fi || k in texts.POS_CART_TEXTS.fi || k in texts.POS_CUSTOM_TEXTS.fi), false);
});
