// Hallinnan kalenteri: koko päiväruutu avaa saman päivän kuin päivänumero. Ei verkkoa eikä tietokantaa.
// node --test booking/tests/kalenteri-paivasolu.test.mjs
import assert from 'node:assert/strict';
import { copyFileSync, existsSync, readFileSync, unlinkSync } from 'node:fs';
import test from 'node:test';

const href = (rel) => new URL(rel, import.meta.url);
const read = (rel) => readFileSync(href(rel), 'utf8');
const fmtLong = (ds) => new Intl.DateTimeFormat('fi-FI', { timeZone: 'UTC', weekday: 'long', day: 'numeric', month: 'long' }).format(new Date(`${ds}T12:00:00Z`));

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
  Object.defineProperty(Node.prototype, 'parentElement', {
    get() { return this.parent?.nodeType === 1 ? this.parent : null; },
  });
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
    this.id = '';
    this.disabled = false;
    this.hidden = false;
    this.value = '';
    this.open = false;
    this.tabIndex = 0;
  }
  El.prototype = Object.create(Node.prototype);
  Object.defineProperty(El.prototype, 'textContent', {
    get() { return textOf(this); },
    set(v) { this.children = [new Text(v)]; this.children[0].parent = this; },
  });
  Object.defineProperty(El.prototype, 'childNodes', { get() { return this.children; } });
  Object.defineProperty(El.prototype, 'dataset', {
    get() {
      const el = this;
      return new Proxy({}, {
        get(_, key) {
          const attr = 'data-' + String(key).replace(/[A-Z]/g, (ch) => '-' + ch.toLowerCase());
          const v = el.getAttribute(attr);
          return v == null ? undefined : v;
        },
      });
    },
  });
  El.prototype.setAttribute = function (k, v) {
    this.attrs[k] = String(v);
    if (k === 'id') this.id = String(v);
    if (k === 'class') this.className = String(v);
    if (k === 'value') this.value = String(v);
    if (k === 'hidden') this.hidden = true;
    if (k === 'disabled') this.disabled = true;
    if (k === 'tabindex') this.tabIndex = Number(v);
  };
  El.prototype.getAttribute = function (k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; };
  El.prototype.hasAttribute = function (k) { return Object.prototype.hasOwnProperty.call(this.attrs, k); };
  El.prototype.removeAttribute = function (k) { delete this.attrs[k]; };
  El.prototype.addEventListener = function (type, fn) { (this.listeners[type] ||= []).push(fn); };
  El.prototype.removeEventListener = function (type, fn) { this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn); };
  El.prototype.append = function (...items) {
    for (const item of items) {
      if (item == null || item === false) continue;
      const n = item.nodeType ? item : new Text(item);
      if (n.parent?.children) n.parent.children = n.parent.children.filter((c) => c !== n);
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
    if (this.parent?.children) this.parent.children = this.parent.children.filter((c) => c !== this);
    this.parent = null;
  };
  El.prototype.focus = function () { document.activeElement = this; };
  El.prototype.showModal = function () { this.open = true; this.setAttribute('open', ''); };
  El.prototype.close = function () {
    this.open = false;
    const ev = { type: 'close', target: this, preventDefault() {}, stopPropagation() {} };
    for (const fn of this.listeners.close || []) fn(ev);
  };
  function matchCompound(el, compound) {
    const re = /([#.]?)([a-zA-Z_][\w-]*)|\[([^\]=]+)(?:="([^"]*)")?\]/g;
    let m, saw = false;
    while ((m = re.exec(compound))) {
      saw = true;
      if (m[1] === '#') { if (el.id !== m[2]) return false; continue; }
      if (m[1] === '.') { if (!el.classList.contains(m[2])) return false; continue; }
      if (m[2]) { if (el.tagName !== m[2].toUpperCase()) return false; continue; }
      if (m[3]) {
        if (m[4] === undefined) { if (!el.hasAttribute(m[3])) return false; }
        else if (el.getAttribute(m[3]) !== m[4]) return false;
      }
    }
    return saw;
  }
  function queryAll(root, selector) {
    const groups = String(selector).split(',').map((s) => s.trim()).filter(Boolean);
    const all = [];
    const walk = (n) => {
      if (!n || n.nodeType !== 1) return;
      all.push(n);
      for (const c of n.children || []) walk(c);
    };
    walk(root);
    const hit = (el, sel) => {
      const parts = sel.split(/\s+/);
      if (!matchCompound(el, parts[parts.length - 1])) return false;
      let node = el.parent;
      for (let i = parts.length - 2; i >= 0; i--) {
        while (node && !matchCompound(node, parts[i])) node = node.parent;
        if (!node) return false;
        node = node.parent;
      }
      return true;
    };
    return all.filter((el) => el !== root && groups.some((g) => hit(el, g)));
  }
  El.prototype.querySelectorAll = function (sel) { return queryAll(this, sel); };
  El.prototype.querySelector = function (sel) { return queryAll(this, sel)[0] || null; };
  El.prototype.closest = function (sel) {
    const parts = String(sel).split(',').map((s) => s.trim());
    let n = this;
    while (n && n.nodeType === 1) {
      if (parts.some((p) => matchCompound(n, p))) return n;
      n = n.parent;
    }
    return null;
  };
  function fire(el, type, extra) {
    const ev = {
      type, target: el, currentTarget: null, ...extra,
      defaultPrevented: false, stopped: false,
      preventDefault() { this.defaultPrevented = true; },
      stopPropagation() { this.stopped = true; },
    };
    const chain = [];
    for (let n = el; n; n = n.parent) chain.push(n);
    for (const n of chain) {
      ev.currentTarget = n;
      for (const fn of [...(n.listeners?.[type] || [])]) fn(ev);
      if (ev.stopped) break;
    }
    return ev;
  }
  El.prototype.click = function () { return fire(this, 'click'); };
  El.prototype.dispatch = function (type, extra) { return fire(this, type, extra); };
  function create(tag) { return new El(tag); }
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
    getElementById(id) { return queryAll(html, `#${id}`)[0] || null; },
    querySelector(sel) { return queryAll(html, sel)[0] || null; },
    querySelectorAll(sel) { return queryAll(html, sel); },
  };
  globalThis.document = document;
  globalThis.Element = El;
  globalThis.Node = Node;
}

installDom();
globalThis.location = { search: '', hash: '#/kalenteri', pathname: '/hallinta/' };
globalThis.window = globalThis;
globalThis.localStorage = { getItem: () => null, setItem() {}, removeItem() {} };

const dest = href('../admin/sb.js');
const createdSb = !existsSync(dest);
if (createdSb) copyFileSync(href('../shared/sb.js'), dest);

const SB = await import(href('../admin/sb.js'));
const { render } = await import(href('../admin/views/calendar.js'));
const { todayHel, addDays, helsinkiIso } = await import(href('../admin/ui.js'));

function at(ds, hm) { return helsinkiIso(`${ds}T${hm}`); }
const today = todayHel();
const dow = (new Date(`${today}T12:00:00Z`).getUTCDay() + 6) % 7;
const other = dow === 0 ? addDays(today, 1) : addDays(today, -dow);
const shiftStart = at(other, '09:00');
const bookStart = at(other, '16:00');

function rpc(name) {
  if (name === 'admin_list_reservations') {
    return Promise.resolve([{
      reservation_id: 42, starts_at: bookStart, ends_at: at(other, '18:00'), persons: 2,
      customer_name: 'Aino Testaaja', product_name: 'Saunahoito', status: 'confirmed',
    }]);
  }
  if (name === 'admin_upcoming_shifts') {
    return Promise.resolve([{
      shift_id: 's1', starts_at: shiftStart, ends_at: at(other, '15:00'),
      role_type: 'heater', staff_name: 'Aino', calendar_name: 'Lämmitykset', staffing_status: 'assigned',
    }]);
  }
  if (name === 'public_get_site_texts') return Promise.resolve({ ok: true, texts: [] });
  if (String(name).startsWith('select:')) return Promise.resolve([]);
  if (name === 'admin_day_view') return Promise.resolve({ reservations: [] });
  return Promise.resolve([]);
}

async function flush() {
  for (let i = 0; i < 30; i++) await new Promise((r) => setTimeout(r, 0));
}
function day(root, ds) { return root.querySelector(`[data-date="${ds}"]`); }
function heading(root) { return root.querySelector('.cal-detail h2')?.textContent || ''; }
function opener(cell) { return cell.querySelector('button.cal-dnum'); }

async function mount(mode) {
  SB.setRpcOverride(rpc);
  document.body.replaceChildren();
  const ctx = { can: (p) => p === 'shifts.view' || p === 'shifts.view_all' };
  const root = await render({ ctx, refs: { methods: [] }, reload() {} });
  document.body.append(root);
  if (mode === 'week') {
    root.querySelector('button[data-mode="week"]').click();
    await flush();
  }
  return root;
}

test('tyylit: koko ruutu on osoitin, hover, fokus ja kosketus; sisäpainike jää päälle', () => {
  const css = read('../admin/calendar.css');
  assert.match(css, /\.cal-day\{[^}]*cursor:pointer/);
  assert.match(css, /\.cal-day\{[^}]*touch-action:manipulation/);
  assert.match(css, /\.cal-day:hover\{[^}]*background:#f7f3ec/);
  assert.match(css, /\.cal-day\.out:hover\{[^}]*background:#e6dfd2/);
  assert.match(css, /\.cal-dnum\{[^}]*position:absolute[^}]*inset:0/);
  assert.match(css, /\.cal-day:has\(\.cal-dnum:focus-visible\)\{[^}]*outline:3px solid var\(--gold\)/);
  assert.match(css, /\.cal-day-face\{[^}]*pointer-events:none/);
  assert.match(css, /\.cal-day-face :is\(a,button,input,select,textarea,summary\)\{pointer-events:auto\}/);
  assert.match(css, /\.cal-grid\.week \.cal-num \.wd\{display:inline\}/);
  assert.match(read('../../.github/workflows/pages.yml'), /node --test booking\/tests\/kalenteri-paivasolu\.test\.mjs/);
});

test('kuukausi: siru, ruutu ja näppäimistö avaavat päivän; harmaa päivä samoin', async () => {
  const root = await mount('month');
  assert.equal(heading(root), fmtLong(today));
  const cell = day(root, other);
  const btn = opener(cell);
  assert.equal(btn.tagName, 'BUTTON');
  assert.equal(btn.getAttribute('type'), 'button');
  assert.equal(btn.getAttribute('tabindex'), null);
  assert.equal(btn.disabled, false);
  assert.equal(btn.getAttribute('role'), null);
  assert.match(btn.getAttribute('aria-label'), new RegExp(fmtLong(other).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.match(btn.getAttribute('aria-label'), /1 työvuoroa, 1 varausta/);
  assert.equal(btn.getAttribute('aria-pressed'), 'false');
  assert.equal(cell.querySelector('.cal-num').getAttribute('aria-hidden'), 'true');
  assert.equal(cell.querySelector('.n').textContent, String(+other.slice(8)));

  cell.querySelector('.chip.booking').click();
  assert.match(root.textContent, /Ladataan/);
  await flush();
  assert.equal(heading(root), fmtLong(other));
  assert.equal(opener(day(root, other)).getAttribute('aria-pressed'), 'true');
  assert.match(root.querySelector('.cal-detail').textContent, /Aino Testaaja/);
  assert.match(root.querySelector('.cal-detail').textContent, /Lämmitykset/);

  const out = root.querySelector('.cal-day.out');
  const outDate = out.getAttribute('data-date');
  assert.notEqual(outDate.slice(0, 7), today.slice(0, 7));
  assert.match(opener(out).getAttribute('aria-label'), new RegExp(fmtLong(outDate).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  out.querySelector('.cal-num').click();
  await flush();
  assert.equal(heading(root), fmtLong(outDate));
  const opened = day(root, outDate);
  assert.equal(opened.classList.contains('out'), true);
  assert.equal(opened.classList.contains('sel'), true);

  const back = opener(day(root, today));
  const enter = back.dispatch('keydown', { key: 'Enter' });
  assert.equal(enter.defaultPrevented, true);
  await flush();
  assert.equal(heading(root), fmtLong(today));
  const space = opener(day(root, other)).dispatch('keydown', { key: ' ' });
  assert.equal(space.defaultPrevented, true);
  await flush();
  assert.equal(heading(root), fmtLong(other));
  SB.setRpcOverride(null);
});

test('viikko: otsikko ja tyhjä kohta avaavat päivän, varauslinkki ei', async () => {
  const root = await mount('week');
  assert.equal(root.querySelector('.cal-grid').classList.contains('week'), true);
  assert.equal(heading(root), fmtLong(today));
  const cell = day(root, other);
  assert.equal(cell.querySelector('.wd').textContent.length > 0, true);
  const book = cell.querySelector('.cal-item.booking button');
  assert.equal(book.tagName, 'BUTTON');
  let dialogError = null;
  try { book.click(); } catch (e) { dialogError = e; }
  assert.equal(heading(root), fmtLong(today));
  assert.equal(/Ladataan/.test(root.textContent), false);
  if (!dialogError) assert.ok(document.body.querySelector('dialog'), 'varauslinkki avaa varausdialogin');

  cell.querySelector('.cal-item.shift').click();
  await flush();
  assert.equal(heading(root), fmtLong(other));

  opener(day(root, today)).click();
  await flush();
  assert.equal(heading(root), fmtLong(today));
  day(root, other).querySelector('.wd').click();
  await flush();
  assert.equal(heading(root), fmtLong(other));
  assert.equal(day(root, other).classList.contains('sel'), true);
  SB.setRpcOverride(null);
});

if (createdSb) unlinkSync(dest);
