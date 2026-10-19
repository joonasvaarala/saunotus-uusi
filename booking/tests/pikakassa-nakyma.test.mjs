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
  El.prototype.dispatch = function (type) {
    const ev = { type, target: this, preventDefault() {} };
    const chain = [];
    for (let n = this; n; n = n.parent) chain.push(n);
    for (const n of chain) for (const fn of n.listeners?.[type] || []) fn(ev);
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
  assert.deepEqual(radios.map((n) => n.value), ['payment_link', 'mobilepay', 'card_terminal']);
  assert.equal(radios.find((n) => n.value === 'card_terminal').hasAttribute('disabled'), true);
  assert.equal(radios.find((n) => n.value === 'mobilepay').hasAttribute('disabled'), false);
  assert.equal(radios.find((n) => n.value === 'payment_link').hasAttribute('disabled'), false);
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

test('maksutapa vahvistetaan popupissa; MobilePayn puhelin ja maksulinkki pysyvät', async () => {
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
  const mp = all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === 'mobilepay');
  mp.dispatch('change');
  dlg = document.getElementById('pos-pay-dialog');
  const flows = all(dlg).filter((n) => n.getAttribute('name') === 'mpflow');
  assert.equal(flows.length, 2);
  assert.match(dlg.textContent, /QR-koodi/);
  assert.match(dlg.textContent, /Pyyntö puhelimeen/);
  flows[1].dispatch('change');
  dlg = document.getElementById('pos-pay-dialog');
  assert.ok(q(dlg, 'pos-phone'));
  const link = all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === 'payment_link');
  link.dispatch('change');
  const origSet = globalThis.setInterval;
  const origClear = globalThis.clearInterval;
  globalThis.setInterval = () => 1;
  globalThis.clearInterval = () => {};
  try {
    dlg = document.getElementById('pos-pay-dialog');
    const email = q(dlg, 'pos-email');
    assert.equal(email.getAttribute('type'), 'email');
    assert.equal(email.getAttribute('inputmode'), 'email');
    assert.equal(email.getAttribute('autocomplete'), 'email');
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

test('mobilepay-startin virhe peruu tilauksen ja näyttää virheen dialogissa', async () => {
  const prev = globalThis.location.search;
  globalThis.location.search = '';
  const mock = createAdminMock({ delay: 0 });
  try {
    const root = await mount(mock.rpc);
    q(root, 'pos-product-101').click();
    q(root, 'pos-pay').click();
    let dlg = document.getElementById('pos-pay-dialog');
    all(dlg).find((n) => n.getAttribute('name') === 'tender' && n.value === 'mobilepay').dispatch('change');
    dlg = document.getElementById('pos-pay-dialog');
    q(dlg, 'pos-confirm').click();
    await flush();
    dlg = document.getElementById('pos-pay-dialog');
    assert.ok(dlg);
    const err = q(dlg, 'pos-pay-error');
    assert.ok(err);
    assert.equal(err.getAttribute('role'), 'alert');
    assert.equal(err.className, 'err');
    assert.match(err.textContent, /mobilepay-start/);
    assert.ok(q(dlg, 'pos-confirm'));
    assert.equal(q(dlg, 'pos-confirm').textContent, 'Vahvista maksu');
    assert.equal(q(dlg, 'pos-status'), null);
    assert.equal(q(root, 'pos-pay').textContent, 'Maksa');
    const checkout = mock.state.calls.filter((c) => c.name === 'admin_pos_checkout');
    const voids = mock.state.calls.filter((c) => c.name === 'admin_pos_void');
    assert.equal(checkout.length, 1);
    assert.equal(voids.length, 1);
    assert.equal(voids[0].args.p_order_id, mock.state.posOrders[0].order_id);
    assert.equal(mock.state.posOrders[0].status, 'cancelled');
    const note = document.getElementById('toast');
    assert.match(note.textContent, /mobilepay-start/);
    assert.match(note.className, /\berr\b/);
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
  for (const key of Object.keys(texts.POS_LINK_TEXTS.fi)) assert.match(src, new RegExp(`t\\('${key}'\\)`));
  assert.equal(src.includes('admin_create_payment_link'), false);
  assert.match(src, /admin_pos_send_link/);
  assert.match(src, /admin_pos_email_status/);
  const pages = read('../../.github/workflows/pages.yml');
  assert.match(pages, /t110 \(booking\/supabase\/tests\/pos\/t110_pos_link_email\.sql\) ei ole tässä ajossa/);
  const sign = pending18.filter((r) => r.key === 'email.payment_link.sign_name');
  assert.deepEqual(sign.map((r) => r.text), ['Tapio', 'Tapio']);
  assert.ok(sign.every((r) => r.class === 'normal' && r.lang && r.max_len === 200));
});
