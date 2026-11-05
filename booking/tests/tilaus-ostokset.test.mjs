// Hallinnan tilausnäkymä: osio näyttää kaiken ostetun (Joonas 5.11.2026, tilaus #15070: pelkkä lahjakortti näkyi "Ei varauksia.").
// Keinotekoinen DOM, ei verkkoa eikä tietokantaa. Data samassa muodossa kuin admin_get_order → normOrder.
import test from 'node:test';
import assert from 'node:assert/strict';

function installDom() {
  class Node { constructor(type) { this.nodeType = type; this.children = []; } }
  class Text extends Node { constructor(d) { super(3); this.data = String(d); } get textContent() { return this.data; } }
  class El extends Node {
    constructor(tag) { super(1); this.tagName = tag.toUpperCase(); this.attrs = {}; this.className = ''; this.dataset = {}; }
    setAttribute(k, v) { this.attrs[k] = String(v); }
    getAttribute(k) { return this.attrs[k] ?? null; }
    addEventListener() {}
    append(...c) { this.children.push(...c); }
    set textContent(v) { this.children = [new Text(v)]; }
    get textContent() { return this.children.map((c) => c.textContent).join(''); }
    all(pred, out = []) { for (const c of this.children) if (c.nodeType === 1) { if (pred(c)) out.push(c); c.all(pred, out); } return out; }
    byTestId(id) { return this.all((e) => e.attrs['data-testid'] === id); }
  }
  globalThis.document = { createElement: (t) => new El(t), createTextNode: (d) => new Text(d) };
}
installDom();
const { normOrder } = await import('../admin/talous-api.js');
const { orderContentsSection } = await import('../admin/views/order-contents.js');
const { orderContents, orderExtraLines } = await import('../admin/order-lines-logic.js');
const { setLang } = await import('../admin/talous-i18n.js');
const { TEXTS } = await import('../admin/talous-texts.js');

const sec = (title, ...kids) => { const s = document.createElement('section'); const h3 = document.createElement('h3'); h3.textContent = title; s.append(h3, ...kids.filter(Boolean)); return s; };
const render = (raw, lang = 'fi') => { setLang(lang); const el = orderContentsSection(normOrder(raw), sec); setLang('fi'); return el; };
const title = (el) => el.children[0].textContent;
const rows = (el, id) => (el.byTestId(id)[0]?.children || []);
const nbsp = (s) => s.replace(/[\u00a0\u202f]/g, ' ');
const base = { order_id: 1, order_no: 1, balance: {}, payments: [], receipts: [], requests: [] };

// #15070 sellaisenaan (prod order_items id 16526, ei varauksia)
const GIFT = { ...base, order_no: 15070, items: [{ id: 16526, parent_item_id: null, kind: 'gift_card', name: 'Lahjakortti (monikäyttöinen arvoseteli, ei ALV)', quantity: 1, unit_price: 50, line_total: 50, vat_rate: 0 }], reservations: [] };
const RES = { ...base, items: [{ id: 10, kind: 'reservation', name: 'Yleinen vuoro', quantity: 2, unit_price: 25, line_total: 50, vat_rate: 13.5 }, { id: 11, parent_item_id: 10, kind: 'addon', name: 'Pyyhe', quantity: 2, unit_price: 5, line_total: 10, vat_rate: 25.5 }],
  reservations: [{ id: 900, item_id: 10, product_name: 'Yleinen vuoro', starts_at: '2026-11-07T15:00:00Z', ends_at: '2026-11-07T17:00:00Z', persons: 2, status: 'confirmed', item_total: 50, addons: [{ name: 'Pyyhe', quantity: 2, line_total: 10 }] }] };
const MIXED = { ...RES, items: [...RES.items, { id: 12, kind: 'product', name: 'Saunahattu', quantity: 2, unit_price: 19.9, line_total: 39.8, vat_rate: 25.5 }, { id: 13, kind: 'gift_card', name: 'Lahjakortti', quantity: 1, unit_price: 40, line_total: 40, vat_rate: 0 }, { id: 14, kind: 'discount', name: 'KOODI10', quantity: 1, unit_price: -10, line_total: -10, vat_rate: 0 }] };
const CUSTOM = { ...base, items: [{ id: 20, kind: 'custom', name: 'Vihta (vapaa rivi)', quantity: 3, unit_price: 12, line_total: 36, vat_rate: 25.5 }, { id: 21, kind: 'fee', name: 'Johku-tasaus (erittelemätön summa)', quantity: 1, unit_price: 2.5, line_total: 2.5, vat_rate: 0 }], reservations: [] };

test('#15070 pelkkä lahjakortti: otsikko Ostokset, rivi nimellä, määrällä ja summalla, ei "Ei varauksia"', () => {
  const el = render(GIFT);
  assert.equal(title(el), 'Ostokset');
  assert.equal(el.byTestId('order-reservations').length, 0);
  const li = rows(el, 'order-items');
  assert.equal(li.length, 1);
  assert.equal(li[0].attrs['data-kind'], 'gift_card');
  assert.equal(li[0].children[0].textContent, 'Lahjakortti (monikäyttöinen arvoseteli, ei ALV)');
  assert.equal(li[0].children[1].textContent, 'Lahjakortti · 1 kpl');
  assert.equal(nbsp(li[0].children[2].textContent), '50,00 €');
  assert.doesNotMatch(el.textContent, /Ei varauksia/);
  const en = render(GIFT, 'en');
  assert.equal(title(en), 'Purchases');
  assert.equal(rows(en, 'order-items')[0].children[1].textContent, 'Gift card · qty 1');
});

test('pelkkä varaus: otsikko Varaukset, varauksen lisäpalvelu ei toistu ostoksena', () => {
  const el = render(RES);
  assert.equal(title(el), 'Varaukset');
  assert.equal(rows(el, 'order-reservations').length, 1);
  assert.equal(el.byTestId('order-items').length, 0);
  assert.match(el.textContent, /Pyyhe ×2/);
  assert.equal(title(render(RES, 'en')), 'Bookings');
});

test('sekatilaus: varaus + tuote + lahjakortti + alennus; määrä × yksikköhinta kun määrä > 1', () => {
  const el = render(MIXED);
  assert.equal(title(el), 'Varaukset ja ostokset');
  assert.equal(title(render(MIXED, 'en')), 'Bookings and purchases');
  assert.equal(rows(el, 'order-reservations').length, 1);
  const li = rows(el, 'order-items');
  assert.deepEqual(li.map((x) => x.attrs['data-kind']), ['product', 'gift_card', 'discount']);
  assert.equal(nbsp(li[0].children[1].textContent), 'Tuote · 2 × 19,90 €');
  assert.equal(nbsp(li[0].children[2].textContent), '39,80 €');
  assert.equal(li[2].children[1].textContent, 'Alennus · 1 kpl');
  assert.match(nbsp(li[2].children[2].textContent), /^[−-]10,00 €$/);
  // osion summat täsmäävät tilausrivien summaan
  const shown = 50 + 10 + orderExtraLines(normOrder(MIXED)).reduce((s, l) => s + l.line_total, 0);
  assert.equal(Math.round(shown * 100), Math.round(normOrder(MIXED).items.reduce((s, x) => s + x.line_total, 0) * 100));
});

test('vapaa rivi (booking_242 kind=custom) ja kulu näkyvät', () => {
  const el = render(CUSTOM);
  assert.equal(title(el), 'Ostokset');
  const li = rows(el, 'order-items');
  assert.equal(li[0].children[0].textContent, 'Vihta (vapaa rivi)');
  assert.equal(nbsp(li[0].children[1].textContent), 'Vapaa rivi · 3 × 12,00 €');
  assert.equal(li[1].children[1].textContent, 'Muu veloitus · 1 kpl');
  const en = rows(render(CUSTOM, 'en'), 'order-items');
  assert.equal(en[0].children[1].textContent.startsWith('Custom line · '), true);
  assert.equal(en[1].children[1].textContent, 'Other charge · qty 1');
});

test('tyhjä tilaus: yksi tyhjätila, ei listoja', () => {
  const el = render({ ...base, items: [], reservations: [] });
  assert.equal(title(el), 'Varaukset');
  assert.equal(el.byTestId('order-items').length + el.byTestId('order-reservations').length, 0);
  assert.match(el.textContent, /Tilauksella ei ole varauksia eikä ostoksia\./);
  assert.match(render({ ...base }, 'en').textContent, /This order has no bookings or purchases\./);
});

test('lisäpalvelu ilman näkyvää varausta ja varausrivi ilman varausta näkyvät ostoksina; tuntematon kind → Muu rivi', () => {
  const o = normOrder({ ...base, reservations: [], items: [{ id: 1, kind: 'reservation', name: 'Tuotu vuoro', quantity: 1, line_total: 30 }, { id: 2, parent_item_id: 1, kind: 'addon', name: 'Pyyhe', quantity: 1, line_total: 5 }, { id: 3, kind: 'outo', name: 'X', quantity: 1, line_total: 1 }] });
  assert.deepEqual(orderExtraLines(o).map((l) => l.kind), ['reservation', 'addon', 'other']);
  assert.equal(orderContents(o).titleKey, 'order.purchases');
});

test('lisäys tilaukseen näkyy: uusi custom-rivi items[]:ssa ilmestyy osioon', () => {
  const after = { ...RES, items: [...RES.items, { id: 30, kind: 'custom', name: 'Lisätty rivi', quantity: 1, unit_price: 15, line_total: 15, vat_rate: 25.5 }] };
  const li = rows(render(after), 'order-items');
  assert.equal(li.length, 1);
  assert.equal(li[0].children[0].textContent, 'Lisätty rivi');
});

test('uudet tekstit löytyvät FI ja EN, eivät sisällä <-merkkiä', () => {
  const keys = ['order.purchases', 'order.contentsBoth', 'order.noContents', 'order.qty', 'order.qtyUnit', ...['reservation', 'gift_card', 'product', 'addon', 'custom', 'fee', 'discount', 'other'].map((k) => `lineKind.${k}`)];
  for (const l of ['fi', 'en']) for (const k of keys) { assert.ok(TEXTS[l][k], `${l} ${k}`); assert.doesNotMatch(TEXTS[l][k], /</); }
});
