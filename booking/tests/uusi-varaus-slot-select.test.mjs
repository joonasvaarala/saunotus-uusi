// P0 hotfix 6.11.2026 (t1372u): Uusi varaus (#/uusi) ei avannut lomaketta vuoron valinnan jälkeen.
// #306 (payment_link) lisäsi syncPaidForMethod → paidRow. customerForm kutsuu onKind→setKind heti
// konstruktorissa; paidRow oli vielä TDZ:ssä → ReferenceError ennen formBox.replaceChildren.
// Tämä testi renderöi exclusive-jälkilöylyvuoron (rule 23 / product 26) maksulinkki-metodeilla
// ja varmistaa, että lomake aukeaa eikä nb.pickSlot jää näkyviin.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const read = (rel) => readFileSync(join(repo, rel), 'utf8');

test('paidRow on ennen customerFormia (ei TDZ:ää onKind-kutsussa)', () => {
  const src = read('booking/admin/views/newbooking.js');
  const paid = src.indexOf("const paidRow = h('label'");
  const sync = src.indexOf('function syncPaidForMethod()');
  const cf = src.indexOf('const cf = customerForm(');
  assert.ok(paid > 0 && sync > 0 && cf > 0, 'paidRow / syncPaidForMethod / customerForm löytyvät');
  assert.ok(paid < sync && sync < cf, `järjestys: paidRow@${paid} < sync@${sync} < cf@${cf}`);
  assert.equal((src.match(/const paidRow = h\('label'/g) || []).length, 1);
  assert.match(src, /syncPaidForMethod\(\)/);
  assert.match(src, /isPaymentLinkMethod/);
});

function installDom() {
  class Text {
    constructor(d) { this.nodeType = 3; this.data = String(d); this.parent = null; }
    get textContent() { return this.data; }
    set textContent(v) { this.data = String(v); }
  }
  class ClassList {
    constructor(el) { this.el = el; }
    contains(n) { return this.el.className.split(/\s+/).filter(Boolean).includes(n); }
    toggle(n, force) {
      const on = force === undefined ? !this.contains(n) : !!force;
      const parts = new Set(this.el.className.split(/\s+/).filter(Boolean));
      if (on) parts.add(n); else parts.delete(n);
      this.el.className = [...parts].join(' ');
      return on;
    }
    add(...ns) { for (const n of ns) this.toggle(n, true); }
    remove(...ns) { for (const n of ns) this.toggle(n, false); }
  }
  class El {
    constructor(tag) {
      this.nodeType = 1;
      this.tagName = String(tag).toUpperCase();
      this.attrs = {};
      this.children = [];
      this.listeners = {};
      this.style = {};
      this.dataset = {};
      this.className = '';
      this.classList = new ClassList(this);
      this.value = '';
      this.parent = null;
      this.hidden = false;
      this.disabled = false;
      this.checked = false;
      this.isConnected = true;
      this.ownerDocument = null;
      this.validity = { valid: true };
      this.validationMessage = '';
    }
    setCustomValidity(msg) { this.validationMessage = String(msg || ''); this.validity = { valid: !msg }; }
    checkValidity() { return !this.validationMessage; }
    reportValidity() { return this.checkValidity(); }
    select() {}
    setAttribute(k, v) {
      this.attrs[k] = String(v);
      if (k === 'class') this.className = String(v);
      if (k === 'value') this.value = String(v);
      if (k === 'hidden') this.hidden = true;
      if (k === 'disabled') this.disabled = true;
      if (k === 'checked') this.checked = true;
      if (k === 'id') this.id = String(v);
    }
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; }
    hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k); }
    removeAttribute(k) {
      delete this.attrs[k];
      if (k === 'hidden') this.hidden = false;
      if (k === 'disabled') this.disabled = false;
      if (k === 'aria-invalid') { /* */ }
    }
    addEventListener(t, f) { (this.listeners[t] ||= []).push(f); }
    removeEventListener() {}
    dispatchEvent(ev) {
      const type = ev?.type || ev;
      for (const f of this.listeners[type] || []) f(ev && typeof ev === 'object' ? ev : { type, preventDefault() {}, target: this });
      return true;
    }
    append(...xs) {
      for (const x of xs) {
        if (x == null || x === false) continue;
        const n = x.nodeType ? x : new Text(x);
        n.parent = this;
        this.children.push(n);
      }
    }
    prepend(...xs) { this.children.unshift(...xs.map((x) => (x?.nodeType ? x : new Text(x)))); }
    replaceChildren(...xs) { this.children = []; this.append(...xs); }
    remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); }
    appendChild(n) { this.append(n); return n; }
    focus() {}
    scrollIntoView() {}
    closest() { return null; }
    querySelectorAll(sel) {
      const all = this.all();
      if (sel === '.slotbtn') return all.filter((e) => this.classNameOf(e).includes('slotbtn'));
      if (sel.startsWith('[data-testid=')) {
        const id = sel.match(/data-testid="?([^"\]]+)"?/)[1];
        return all.filter((e) => e.attrs['data-testid'] === id);
      }
      if (sel.startsWith('.')) {
        const cls = sel.slice(1).split('.')[0];
        return all.filter((e) => this.classNameOf(e).includes(cls));
      }
      return all.filter((e) => e.tagName === sel.toUpperCase());
    }
    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
    classNameOf(e) { return `${e.className || ''} ${e.attrs?.class || ''}`.trim(); }
    all() { return this.children.filter((c) => c.nodeType === 1).flatMap((c) => [c, ...c.all()]); }
    get textContent() { return this.children.map((c) => c.textContent).join(''); }
    set textContent(v) { this.children = [new Text(v)]; }
    get options() { return this.tagName === 'SELECT' ? this.children.filter((c) => c.tagName === 'OPTION') : undefined; }
  }
  Object.defineProperty(El.prototype, 'id', {
    get() { return this.attrs?.id || this._id || ''; },
    set(v) { this._id = String(v); this.attrs = this.attrs || {}; this.attrs.id = String(v); },
  });
  const body = new El('body');
  const doc = {
    body,
    documentElement: new El('html'),
    createElement: (t) => { const e = new El(t); e.ownerDocument = doc; return e; },
    createElementNS: (_n, t) => { const e = new El(t); e.ownerDocument = doc; return e; },
    createTextNode: (t) => new Text(t),
    addEventListener() {},
    querySelector: () => null,
    querySelectorAll: () => [],
    getElementById: (id) => body.all().find((e) => e.id === id || e.attrs?.id === id) || null,
  };
  globalThis.document = doc;
  globalThis.window = globalThis;
  globalThis.HTMLElement = El;
  globalThis.Node = { TEXT_NODE: 3, ELEMENT_NODE: 1 };
  globalThis.CustomEvent = class { constructor(type, init) { this.type = type; Object.assign(this, init || {}); } };
  globalThis.Event = class { constructor(type) { this.type = type; } };
  globalThis.location = { hash: '#/uusi', search: '', pathname: '/hallinta/', href: 'https://saunotus.fi/hallinta/#/uusi' };
  globalThis.localStorage ??= { getItem: () => null, setItem() {}, removeItem() {} };
  globalThis.matchMedia = () => ({ matches: false, addEventListener() {}, addListener() {} });
  globalThis.requestAnimationFrame = (f) => setTimeout(f, 0);
  globalThis.scrollTo = () => {};
  return { body, El, Text };
}

const FRIDAY = '2026-11-06';
const SLOT = {
  rule_id: 23,
  product_id: 26,
  label: 'Savusaunan jälkilöylyt',
  mode: 'exclusive',
  status: 'available',
  remaining: 1,
  min_persons: 1,
  max_persons: 16,
  price_mode: 'fixed',
  base_price: 280,
  unit_price: 280,
  included_persons: 0,
  extra_person_price: 0,
  starts_at: '2026-11-06T17:00:00.000Z', // 19:00 Europe/Helsinki (UTC+2)
  ends_at: '2026-11-06T20:00:00.000Z',   // 22:00
  private_conflict: false,
  blocked: false,
};
const METHODS = [
  { code: 'pay_later', label: 'Maksu myöhemmin', is_manual: true, active: true },
  { code: 'cash', label: 'Käteinen', is_manual: true, active: true },
  { code: 'card_terminal', label: 'Kortti', is_manual: true, active: true },
  { code: 'mobilepay', label: 'MobilePay', is_manual: true, active: true },
  { code: 'invoice', label: 'Lasku', is_manual: true, active: true },
  { code: 'gift_card', label: 'Lahjakortti', is_manual: true, active: true },
  { code: 'payment_link', label: 'Payment link', is_manual: true, active: true },
  { code: 'montonio', label: 'Verkkomaksu', is_manual: false, active: true },
];
const PRODUCT = { id: 26, name: 'Savusaunan jälkilöylyt', slug: 'jalkiloylyt', price: 280, category: 'private_sauna' };

// Kopio kerran tiedoston latauksessa (kuten koulutukset-hallinta), ei testin sisällä — vähemmän /tmp-kilpailua.
const tmpAdmin = join(mkdtempSync(join(tmpdir(), 'nb-slot-')), 'admin');
mkdirSync(tmpAdmin, { recursive: true });
cpSync(join(root, 'admin'), tmpAdmin, { recursive: true });
cpSync(join(root, 'shared/sb.js'), join(tmpAdmin, 'sb.js'));
const dom = installDom();
const sbMod = await import(pathToFileURL(join(tmpAdmin, 'sb.js')).href);
const { render: renderNewBooking } = await import(pathToFileURL(join(tmpAdmin, 'views/newbooking.js')).href);

test('exclusive jälkilöylyt + payment_link: vuoron valinta avaa lomakkeen (ei nb.pickSlot)', async () => {
  const sb = sbMod;
  sb.setRpcOverride(async (fn, args) => {
    if (fn === 'admin_list_addons') return [];
    if (fn === 'select:schedule_rules') return [];
    if (fn === 'public_get_site_texts' || fn === 'admin_get_booking_texts') return { ok: true, texts: [] };
    if (fn === 'admin_day_view') {
      assert.equal(args.p_date, FRIDAY);
      return { sessions: [SLOT], blocks: [], waitlist_holds: [] };
    }
    if (fn === 'admin_preview_booking_limits') return { overbook: [], off_schedule: [], conflict: [] };
    return {};
  });
  const render = renderNewBooking;
  const refs = {
    methods: METHODS,
    products: [PRODUCT],
    productById: new Map([[26, PRODUCT]]),
    resources: [],
  };
  const ctx = { role: 'admin', can: () => true, refs };
  const query = new URLSearchParams(`d=${FRIDAY}`);
  let nodes;
  try {
    nodes = await render({ ctx, refs, query, reload: () => {} });
  } catch (e) {
    assert.fail(`render kaatui ennen vuoron valintaa: ${e && e.stack || e}`);
  }
  const host = new (dom.body.constructor)('div');
  host.isConnected = true;
  const flat = (x) => {
    if (Array.isArray(x)) return x.flatMap(flat);
    return x == null || x === false ? [] : [x];
  };
  host.append(...flat(nodes));
  dom.body.replaceChildren(host);

  assert.match(host.textContent, /Valitse vuoro|Pick a slot|Pick a shift|nb\.pickSlot|lomakkeen muut tiedot|varauksen muut tiedot/i);
  const pickHintBefore = host.textContent;

  const slotBtn = host.all().find((e) => e.tagName === 'BUTTON' && (e.className.includes('slotbtn') || e.attrs?.role === 'radio'));
  assert.ok(slotBtn, 'vuoronappi löytyy');
  assert.match(slotBtn.textContent, /jälkilöylyt|19:00|22:00/i);

  // Klikkaa: sama polku kuin onclick → st.session = s; drawForm(true)
  const clicks = slotBtn.listeners.click || [];
  assert.ok(clicks.length, 'slotbtn:lla on click-kuuntelija');
  try {
    for (const fn of clicks) fn({ type: 'click', preventDefault() {}, target: slotBtn, currentTarget: slotBtn });
  } catch (e) {
    assert.fail(`drawForm kaatui vuoron valinnassa (TDZ/paidRow?): ${e && e.stack || e}`);
  }

  const forms = host.all().filter((e) => e.attrs?.['data-testid'] === 'booking-form');
  assert.equal(forms.length, 1, 'booking-form renderöityy vuoron valinnan jälkeen');
  assert.doesNotMatch(host.textContent, /Valitse vuoro, niin varauksen muut tiedot avautuvat/);
  assert.match(host.textContent, /Henkilömäärä|Asiakas|Maksu|Persons|Customer|Payment/i);
  const methodOpts = forms[0].all().filter((e) => e.tagName === 'OPTION').map((e) => e.attrs.value || e.value);
  assert.ok(methodOpts.includes('payment_link'), `payment_link mukana metodeissa: ${methodOpts}`);
  assert.ok(methodOpts.includes('pay_later'));
  // paid-row piilotetaan vain kun payment_link valittuna; oletus pay_later → näkyvissä
  const paidRow = forms[0].all().find((e) => e.attrs?.['data-testid'] === 'paid-row');
  assert.ok(paidRow, 'paid-row olemassa');
  void pickHintBefore;
});
