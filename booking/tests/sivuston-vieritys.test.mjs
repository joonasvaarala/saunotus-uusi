// Siirtymävieritysten regressiotestit: jaetut apurit + tapahtumakäsittelijöiden kytkennät.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { revealForm, revealIfHidden, prefersReducedMotion } from '../shop/src/gift-ui.js';
import { revealSection, revealIfHidden as adminRevealIfHidden } from '../admin/ui.js';

const source = (relative) => readFileSync(new URL(relative, import.meta.url), 'utf8');
const element = (rect = { top: 1100, bottom: 1200 }) => {
  const calls = { scroll: [], focus: [], attrs: [] };
  return {
    calls,
    scrollIntoView: (opts) => calls.scroll.push(opts),
    focus: (opts) => calls.focus.push(opts),
    setAttribute: (...args) => calls.attrs.push(args),
    matches: (sel) => false,
    getBoundingClientRect: () => rect,
  };
};
const win = (reduced, innerHeight = 800) => ({
  innerHeight,
  matchMedia: (query) => ({ matches: reduced && query.includes('reduce') }),
});

test('revealForm vierittää lomakkeen alkuun kerran, fokus ei tee uutta vieritystä', () => {
  const cart = element(), title = element();
  assert.equal(revealForm(cart, title, win(false)), true);
  assert.deepEqual(cart.calls.scroll, [{ block: 'start', behavior: 'smooth' }]);
  assert.deepEqual(title.calls.focus, [{ preventScroll: true }]);
  assert.deepEqual(title.calls.attrs, [['tabindex', '-1']]);
  assert.equal(title.calls.scroll.length, 0);
});

test('reduced-motion → auto, myös hallinnan revealSection', () => {
  assert.equal(prefersReducedMotion(win(true)), true);
  const shop = element(), admin = element(), head = element();
  revealForm(shop, null, win(true)); revealSection(admin, head, win(true));
  assert.deepEqual(shop.calls.scroll, [{ block: 'start', behavior: 'auto' }]);
  assert.deepEqual(admin.calls.scroll, [{ block: 'start', behavior: 'auto' }]);
  assert.deepEqual(head.calls.focus, [{ preventScroll: true }]);
});

test('revealIfHidden ei vieritä näkyvissä olevaa ilmoitusta eikä ensilatausta', () => {
  const visible = element({ top: 200, bottom: 240 });
  const below = element(), above = element({ top: 10, bottom: 30 });
  assert.equal(revealIfHidden(visible, win(false)), false);
  assert.equal(adminRevealIfHidden(visible, win(false)), false);
  assert.equal(visible.calls.scroll.length, 0);
  assert.equal(revealIfHidden(below, win(false)), true);
  assert.deepEqual(below.calls.scroll, [{ block: 'nearest', behavior: 'smooth' }]);
  assert.equal(adminRevealIfHidden(above, win(true)), true);
  assert.deepEqual(above.calls.scroll, [{ block: 'nearest', behavior: 'auto' }]);
});

test('lahjakortin lisääminen vierittää renderCart-kutsun jälkeen #gc-cart-lomakkeeseen', () => {
  const text = source('../shop/src/gift.js');
  const addLine = text.slice(text.indexOf('const addLine ='), text.indexOf('const tile ='));
  assert.match(addLine, /lines\.push\([\s\S]*?renderCart\(\); revealForm\(cartHost, cartHost\.querySelector\('legend'\)\)/);
  assert.match(text, /revealIfHidden\(out\);/);
  assert.match(text, /revealIfHidden\(firstBad\)/);
  const qty = text.slice(text.indexOf('const setQty ='), text.indexOf('const stepper ='));
  assert.doesNotMatch(qty, /revealForm|revealIfHidden|scrollIntoView/);
});

test('vuorokaupan kalenteripäivä vie .bk-slots-osioon ja päivänäkymä säilyttää kontekstin', () => {
  const text = source('../shop/src/shop.js');
  assert.match(text, /drawSlots\(\); markSel\(\); revealForm\(slotBox, slotBox\.querySelector\('h3'\)\)/);
  assert.match(text, /if \(keep\) \{[^\n]*revealIfHidden\(el\)/);
  assert.match(text, /revealForm\(li, li\.querySelector\('\.bk-pc-head'\)\)/);
  assert.match(text, /await loadSessions\(\); revealForm\(sessionsBox, sessionsBox\.querySelector\('h3'\) \|\| sessionsBox\)/);
  assert.match(text, /k === 'company'\) revealIfHidden\(companyBox\)/);
});

test('hoidon päivän ja ajan valinnat vievät kellonaikoihin ja Jatka-osioon', () => {
  const text = source('../shop/src/treatment-ui.js');
  assert.match(text, /const choose = \(ds\) =>[^\n]*revealForm\(timeBox, timeBox\.querySelector\('#tr-h3'\)\)/);
  assert.match(text, /onclick: \(\) => \{ st\.time = s\.time;[^\n]*revealIfHidden\(timeBox\.closest\('\.bk-picker'\)\?\.parentElement\?\.querySelector\('\.bk-continue'\)\)/);
  assert.match(text, /revealForm\(holder, head\)/);
  assert.match(text, /revealForm\(formView, form\.querySelector\('input,textarea'\)\)/);
});

test('tilauksen ja hallinnan tulosviestit vierittävät vain siirtymistä, eivät kirjoittaessa', () => {
  const order = source('../shop/src/order.js'), gift = source('../shop/src/order-gift.js');
  const newBooking = source('../admin/views/newbooking.js'), resource = source('../admin/views/resbooking.js');
  assert.match(order, /revealIfHidden\(m\)/);
  assert.match(gift, /finally \{ btn\.disabled = false; if \(!panel\.hidden\) revealIfHidden\(panel\)/);
  assert.match(newBooking, /if \(reveal\) revealForm\(f\)/);
  assert.match(newBooking, /revealSection\(f, f\.querySelector\('h3'\)\)/);
  assert.match(newBooking, /revealSection\(result, title\)/);
  assert.match(resource, /revealSection\(result, result\.querySelector\('h3'\)\)/);
  assert.match(resource, /revealIfHidden\(errBox\)/);
  assert.doesNotMatch(gift.split("code.addEventListener('input'")[1].split('\n')[0], /reveal/);
});

test('lähdevalinnan nykyinen yksittäinen revealForm-kutsupaikka säilyy ennallaan', () => {
  const text = source('../shop/src/order-gift.js');
  assert.equal((text.match(/revealForm\(/g) || []).length, 1);
  assert.match(text, /choose\.hidden = false; revealForm\(choose, title\)/);
});
