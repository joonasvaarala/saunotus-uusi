// booking_221: hoitosivun hinta on valitun henkilömäärän summa (sama kaava kuin booking._treatment_price),
// jo ennen kellonaikaa, ja henkilömäärän vaihto ei tyhjennä aikaa jos se on yhä vapaa.
// public_catalog palauttaa included_persons ja extra_person_price kb.productsista (ei schedule_rules-coalescea).
// Ei verkkoa eikä tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, cpSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { T } from '../shop/src/i18n.js';

const root = dirname(fileURLToPath(import.meta.url));
const repo = join(root, '..', '..');
const read = (rel) => readFileSync(join(repo, rel), 'utf8');
const MIG = 'booking/supabase/migrations/20261030142927_booking_221_catalog_extra_person.sql';
const RB = 'booking/supabase/rollbacks/20261030142927_booking_221_ROLLBACK.sql';
const PREV = 'booking/supabase/migrations/20261024185009_booking_158_events.sql';

function fnBody(sql) {
  const i = sql.search(/CREATE OR REPLACE FUNCTION booking\.public_catalog\(\)/);
  assert.ok(i >= 0, 'public_catalog');
  const m = /\$function\$([\s\S]*?)\$function\$/.exec(sql.slice(i));
  assert.ok(m, 'funktion runko');
  return m[1].replace(/\s+/g, ' ').trim();
}

const ADDED = "'price_text', p.price_text, 'included_persons', p.included_persons, 'extra_person_price', p.extra_person_price,";

test('migraatio lisää vain katalogin lisähenkilökentät ja rollback palauttaa booking_158:n', () => {
  const sql = read(MIG), prev = fnBody(read(PREV));
  assert.match(sql, /booking\._treatment_price/);
  assert.match(sql, /schedule_rules/);
  assert.match(sql, /product_price_variants/);
  assert.doesNotMatch(sql, /\b(insert into|update\s+|delete from|alter table|drop )\b/i);
  assert.equal((sql.match(/CREATE OR REPLACE FUNCTION/g) || []).length, 1);
  const body = fnBody(sql);
  assert.ok(body.includes(ADDED), 'kentät heti price_textin jälkeen');
  assert.equal(body.replace(ADDED, "'price_text', p.price_text,"), prev, 'muuten booking_158: price = p.price, ei sääntö/variantti-coalescea');
  assert.match(body, /'price', p\.price,/);
  assert.doesNotMatch(body, /r\.included_persons|v\.included_persons|v\.extra_person_price/);
  assert.equal(fnBody(read(RB)), prev, 'rollback = booking_158');
  assert.match(read('.github/workflows/pages.yml'), /node --test booking\/tests\/hoito-hinta-henkilomaara\.test\.mjs/);
  const css = read('booking/shop/src/shop.css');
  const total = css.match(/\.bk-party-total\{[^}]+\}/)[0];
  assert.match(total, /font:700 32px/, 'mobiilissa iso lihavoitu hinta, ei vain työpöydän mediaqueryssa');
  assert.match(css, /@media\(min-width:700px\)\{\.bk-party-total\{font-size:40px\}/);
});

function installDom() {
  function ClassList(el) { this.el = el; }
  ClassList.prototype.contains = function (name) { return this.el.className.split(/\s+/).includes(name); };
  ClassList.prototype.toggle = function (name, force) {
    const on = force === undefined ? !this.contains(name) : !!force;
    const parts = new Set(this.el.className.split(/\s+/).filter(Boolean));
    if (on) parts.add(name); else parts.delete(name);
    this.el.className = [...parts].join(' ');
    return on;
  };
  ClassList.prototype.add = function (name) { this.toggle(name, true); };
  ClassList.prototype.remove = function (name) { this.toggle(name, false); };
  function Node(type) { this.nodeType = type; this.parent = null; this.children = []; }
  function Text(data) { Node.call(this, 3); this.data = String(data); }
  Text.prototype = Object.create(Node.prototype);
  const all = [];
  function El(tag) {
    Node.call(this, 1);
    this.tagName = String(tag).toUpperCase();
    this.attrs = {};
    this.className = '';
    this.id = '';
    this.classList = new ClassList(this);
    this.listeners = {};
    this.disabled = false;
    this.hidden = false;
    this.checked = false;
    this.value = '';
    this.ownerDocument = doc;
    all.push(this);
  }
  El.prototype = Object.create(Node.prototype);
  Object.defineProperty(El.prototype, 'textContent', {
    get() { return this.children.map((n) => (n.nodeType === 3 ? n.data : n.textContent)).join(''); },
    set(v) { this.children = [new Text(v)]; this.children[0].parent = this; },
  });
  Object.defineProperty(El.prototype, 'parentElement', { get() { return this.parent && this.parent.nodeType === 1 ? this.parent : null; } });
  El.prototype.setAttribute = function (name, value) {
    this.attrs[name] = String(value);
    if (name === 'id') this.id = String(value);
    if (name === 'class') this.className = String(value);
    if (name === 'disabled') this.disabled = true;
  };
  El.prototype.getAttribute = function (name) {
    if (name === 'class') return this.className || null;
    if (name === 'id') return this.id || null;
    return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null;
  };
  El.prototype.removeAttribute = function (name) {
    delete this.attrs[name];
    if (name === 'id') this.id = '';
    if (name === 'disabled') this.disabled = false;
  };
  El.prototype.addEventListener = function (type, fn) { (this.listeners[type] ||= []).push(fn); };
  El.prototype.append = function (...nodes) {
    for (const n of nodes) {
      if (n == null || n === false) continue;
      const node = n.nodeType ? n : new Text(n);
      node.parent = this;
      this.children.push(node);
    }
  };
  El.prototype.replaceChildren = function (...nodes) { this.children = []; this.append(...nodes); };
  function matchSimple(el, part) {
    if (!el || el.nodeType !== 1) return false;
    const attrs = [...part.matchAll(/\[([^\]=\s]+)(?:=["']?([^"'\]]+)["']?)?\]/g)];
    let rest = part.replace(/\[[^\]]*\]/g, '');
    const id = rest.match(/#([\w-]+)/);
    const classes = [...rest.matchAll(/\.([\w-]+)/g)].map((m) => m[1]);
    const tag = rest.replace(/#[\w-]+/g, '').replace(/\.[\w-]+/g, '');
    if (tag && el.tagName !== tag.toUpperCase()) return false;
    if (id && el.id !== id[1]) return false;
    if (classes.some((c) => !el.classList.contains(c))) return false;
    for (const a of attrs) {
      const val = el.getAttribute(a[1]);
      if (val == null) return false;
      if (a[2] != null && val !== a[2]) return false;
    }
    return true;
  }
  function walk(node, parts, idx, hit) {
    for (const c of node.children || []) {
      if (c.nodeType !== 1) continue;
      if (matchSimple(c, parts[idx])) {
        if (idx === parts.length - 1) { if (hit) return c; hit = c; }
        else { const inner = walk(c, parts, idx + 1, null); if (inner) return inner; }
      }
      const deeper = walk(c, parts, idx, hit);
      if (deeper) return deeper;
    }
    return hit;
  }
  function query(node, sel) {
    const parts = sel.trim().split(/\s+/);
    return walk(node, parts, 0, null);
  }
  function queryAll(node, sel, out = []) {
    const parts = sel.trim().split(/\s+/);
    const visit = (n, idx) => {
      for (const c of n.children || []) {
        if (c.nodeType !== 1) continue;
        if (matchSimple(c, parts[idx])) {
          if (idx === parts.length - 1) out.push(c);
          else visit(c, idx + 1);
        }
        visit(c, idx);
      }
    };
    visit(node, 0);
    return out;
  }
  El.prototype.querySelector = function (sel) { return query(this, sel); };
  El.prototype.querySelectorAll = function (sel) { return queryAll(this, sel); };
  El.prototype.closest = function (sel) {
    let n = this;
    while (n) { if (n.nodeType === 1 && matchSimple(n, sel)) return n; n = n.parent; }
    return null;
  };
  El.prototype.matches = function (sel) { return matchSimple(this, sel.split(',')[0].trim()); };
  El.prototype.focus = function () {};
  El.prototype.scrollIntoView = function () {};
  El.prototype.getBoundingClientRect = function () { return { top: 100, bottom: 140, left: 0, right: 40, width: 40, height: 40 }; };
  const doc = {
    createElement: (tag) => new El(tag),
    createTextNode: (t) => new Text(t),
    getElementById: (id) => all.find((e) => e.id === id) || null,
    querySelector: (sel) => query({ children: all.filter((e) => !e.parent) }, sel),
    documentElement: { classList: { add() {}, remove() {} } },
  };
  globalThis.document = doc;
  globalThis.history = { url: '', replaceState(_a, _b, url) { this.url = url; } };
  globalThis.location = { hash: '', search: '' };
  return { h(tag, attrs, ...kids) {
    const el = doc.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'text') el.textContent = v;
      else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v);
      else if (v === true) el.setAttribute(k, '');
      else el.setAttribute(k, v);
    }
    for (const c of kids.flat()) if (c != null && c !== false) el.append(c.nodeType ? c : doc.createTextNode(c));
    return el;
  }, click(el) {
    if (!el || el.disabled) return false;
    for (const fn of el.listeners.click || []) fn({ preventDefault() {} });
    return true;
  } };
}

installDom();
const tmp = join(mkdtempSync(join(tmpdir(), 'hoito-hinta-')), 'shop');
cpSync(join(root, '../shop/src'), tmp, { recursive: true });
cpSync(join(root, '../shared/sb.js'), join(tmp, 'sb.js'));
const A = await import(pathToFileURL(join(tmp, 'treatments.js')));
const SB = await import(pathToFileURL(join(tmp, 'sb.js')));
const { createTreatmentViews } = await import(pathToFileURL(join(tmp, 'treatment-ui.js')));
const { catalogEntries } = await import(pathToFileURL(join(tmp, 'treatment-mock.js')));
const dom = installDom();

const hoito = {
  id: 10, slug: 'saunahoito-2', name: 'Saunahoito', price: 99, price_type: 'base_plus_extra_person',
  included_persons: 1, extra_person_price: 35, duration_minutes: 60, duration_text: '1 h', capacity_min: 1, capacity_max: 2,
};
const money = (n) => `${+n} €`;
const pad2 = (n) => String(n).padStart(2, '0');
const addDays = (ds, n) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };

test('priceFor vastaa kassan _treatment_pricea eikä muuta perushintaa', () => {
  assert.equal(A.priceFor(hoito, 1), 99);
  assert.equal(A.priceFor(hoito, 2), 134);
  assert.equal(A.priceFor(hoito, 4), 204);
  assert.equal(A.priceFor({ price: 49, price_type: 'per_person' }, 2), 98);
  assert.equal(A.priceFor({ price: 99, price_type: 'base_plus_extra_person', included_persons: null, extra_person_price: 35 }, 2), 99, 'NULL included = ei lisäveloitusta');
  assert.equal(A.priceFor({ price: 99, price_type: 'base_plus_extra_person', extra_person_price: 35 }, 2), 99);
  assert.equal(A.priceFor({ price: 210, price_type: 'base_plus_extra_person', included_persons: 1, extra_person_price: 60 }, 2), 270);
  assert.equal(A.priceFor({ price: 290, price_type: 'base_plus_extra_person', included_persons: 1, extra_person_price: 70 }, 2), 360);
});

test('splitCatalog: katalogin lisähinta voittaa staattisen, puuttuva avain ei; hinta ei vaihdu', () => {
  const row = { id: 10, slug: 'saunahoito-2', name: 'Saunahoito', booking_kind: 'slots', price: 99, price_type: 'base_plus_extra_person', included_persons: 1, extra_person_price: 35, min_persons: 1, max_persons: 4 };
  const stale = new Map([[10, { id: 10, price: 50, included_persons: 6, extra_person_price: 1, description: 'kb' }]]);
  const p = A.splitCatalog([row], stale).treatments[0];
  assert.equal(p.price, 99);
  assert.equal(p.included_persons, 1);
  assert.equal(p.extra_person_price, 35);
  assert.equal(p.description, 'kb');
  assert.equal(A.priceFor(p, 2), 134);
  const old = { ...row }; delete old.included_persons; delete old.extra_person_price;
  const kept = A.splitCatalog([old], stale).treatments[0];
  assert.equal(kept.included_persons, 6);
  assert.equal(kept.extra_person_price, 1);
  const cleared = A.splitCatalog([{ ...row, included_persons: null, extra_person_price: null }], stale).treatments[0];
  assert.equal(cleared.included_persons, null);
  assert.equal(cleared.extra_person_price, null);
  assert.equal(A.priceFor(cleared, 2), 99);
});

test('mock-katalogi palauttaa lisähenkilökentät eikä muuta perushintaa', () => {
  const e = catalogEntries().find((x) => x.id === 10);
  assert.equal(e.price, 99);
  assert.equal(e.included_persons, 1);
  assert.equal(e.extra_person_price, 35);
  const ritual = catalogEntries().find((x) => x.id === 7);
  assert.equal(ritual.price, 49);
  assert.equal(ritual.included_persons, null);
  assert.equal(ritual.extra_person_price, null);
});

test('tuotesivu näyttää henkilömäärän hinnan heti ja säilyttää kelvollisen ajan', async () => {
  const calls = [];
  SB.setRpcOverride(async (name, args) => {
    if (name !== 'public_treatment_availability') return [];
    calls.push(args.p_persons);
    const n = +args.p_persons;
    const times = n >= 2 ? ['16:00'] : ['16:00', '17:00'];
    return times.map((hm) => ({
      session_date: '2026-11-14', starts_at: `2026-11-14T${hm}:00+02:00`, ends_at: `2026-11-14T${hm === '16:00' ? '17:00' : '18:00'}:00+02:00`,
      status: 'available', duration_minutes: 60, total: n >= 2 ? 134 : 99,
    }));
  });
  A.clearCache();
  const mounted = dom.h('div', { id: 'root' });
  const views = createTreatmentViews({
    h: dom.h, t: T.fi, S: { lang: 'fi' }, state: { settings: { public_treatment_horizon_days: 30 } },
    money, fmt: (iso, o) => new Intl.DateTimeFormat('fi-FI', { timeZone: 'Europe/Helsinki', ...o }).format(new Date(iso)),
    hm: (iso) => iso.slice(11, 16), dayLong: () => 'lauantai', pad2, todayHel: () => '2026-11-10', addDays,
    pname: (p) => p.name, pdesc: () => '', pimg: () => null, setHero() {}, moreInfo: () => null,
    mount: (...nodes) => mounted.replaceChildren(...nodes.flat().filter((n) => n != null && n !== false)),
    focusTop() {}, errorBox: (msg) => dom.h('p', { text: msg }), phoneBox: () => null, bk: (path) => `#${path}`,
    customerFields: () => ({ node: dom.h('div'), read: () => null }), legalFields: () => ({ nodes: [], terms: {}, consent: {} }),
    setLast() {},
  });
  assert.equal(views.priceText(hoito), '99 € (sis. 1 hlö, lisähenkilö +35 €)');
  assert.equal(views.priceText(hoito, 1), '99 €');
  assert.equal(views.priceText(hoito, 2), '134 €');
  await views.viewTreatment(hoito, new URLSearchParams(''));
  const price = () => mounted.querySelector('[data-testid=treatment-price]').textContent;
  const sum = () => mounted.querySelector('.bk-pick-sum').textContent;
  const step = mounted.querySelector('#tr-n').closest('section');
  assert.equal(step.querySelector('[data-testid=treatment-price]'), mounted.querySelector('[data-testid=treatment-price]'), 'hinta on henkilömäärän yhteydessä');
  assert.equal(price(), '1 hlö · 99 €');
  assert.equal(mounted.querySelector('[data-testid=treatment-price-note]').textContent, '99 € (sis. 1 hlö, lisähenkilö +35 €)');
  assert.equal(sum(), '1 hlö · 99 €');
  assert.doesNotMatch(sum(), /Valittu:/);
  const day = mounted.querySelector('button[data-date="2026-11-14"]');
  assert.ok(day, 'vapaa päivä');
  dom.click(day);
  const buttons = () => mounted.querySelectorAll('.bk-time-btn');
  const pressed = () => buttons().find((b) => b.getAttribute('aria-pressed') === 'true');
  const byStart = (label) => buttons().find((b) => b.querySelector('strong')?.textContent === label);
  dom.click(byStart('16.00'));
  assert.equal(pressed().textContent.includes('16.00'), true);
  assert.match(sum(), /Valittu:/);
  assert.match(sum(), /99 €/);
  const plus = mounted.querySelectorAll('.bk-step')[1];
  dom.click(plus);
  assert.equal(price(), '2 hlö · 134 €', 'hinta päivittyy ennen saatavuushakua');
  assert.equal(pressed().textContent.includes('16.00'), true, 'aikaa ei tyhjennetä heti');
  await new Promise((r) => setTimeout(r, 500));
  assert.equal(price(), '2 hlö · 134 €');
  assert.ok(pressed(), '16:00 käy kahdelle');
  assert.match(pressed().textContent, /16\.00/);
  assert.match(sum(), /Valittu:/);
  assert.match(sum(), /134 €/);
  assert.ok(calls.includes(2));
  const minus = mounted.querySelectorAll('.bk-step')[0];
  dom.click(minus);
  await new Promise((r) => setTimeout(r, 500));
  dom.click(byStart('17.00'));
  assert.equal(pressed().querySelector('strong').textContent, '17.00');
  dom.click(plus);
  await new Promise((r) => setTimeout(r, 500));
  assert.equal(pressed(), undefined, '17:00 ei käy kahdelle');
  assert.equal(price(), '2 hlö · 134 €');
  assert.equal(sum(), '2 hlö · 134 €');
  assert.doesNotMatch(sum(), /Valittu:/);
  SB.setRpcOverride(null);
});
