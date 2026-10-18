// Lahjakoodin lähdevalinta (§13.12): lomake vieritetään näkyviin kerran kun se avautuu + fokus otsikkoon; prefers-reduced-motion → behavior 'auto'.
// Ei DOMia: apurit saavat kevyet valeolio-elementit ja valeikkunan. Selaintesti (oikea vieritys 360/390/430/1280): booking/scripts/e2e-lahjakoodi-vieritys.mjs.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { revealForm, revealIfHidden, prefersReducedMotion } from '../shop/src/gift-ui.js';

const el = (rect = { top: 300, bottom: 400 }) => { const calls = { scroll: [], focus: [] }; return { calls, scrollIntoView: (o) => calls.scroll.push(o), focus: (o) => calls.focus.push(o), getBoundingClientRect: () => rect }; };
const win = (reduce, innerHeight = 800) => ({ innerHeight, matchMedia: (q) => ({ matches: reduce && /reduce/.test(q) }) });

test('revealForm: scrollIntoView kutsutaan tasan kerran (block start, smooth) ja fokus otsikkoon ilman toista vieritystä', () => {
  const form = el(), title = el();
  assert.equal(revealForm(form, title, win(false)), true);
  assert.deepEqual(form.calls.scroll, [{ block: 'start', behavior: 'smooth' }]);
  assert.deepEqual(title.calls.focus, [{ preventScroll: true }], 'focus({ preventScroll: true }) → vain yksi vieritys');
  assert.equal(title.calls.scroll.length, 0);
});

test('revealForm: prefers-reduced-motion → behavior auto (ei animaatiota); puuttuva matchMedia ei kaada', () => {
  const form = el(); revealForm(form, form, win(true));
  assert.deepEqual(form.calls.scroll, [{ block: 'start', behavior: 'auto' }]);
  assert.equal(prefersReducedMotion(win(true)), true); assert.equal(prefersReducedMotion(win(false)), false); assert.equal(prefersReducedMotion({}), false);
  const f2 = el(); assert.equal(revealForm(f2, f2, {}), true); assert.equal(f2.calls.scroll[0].behavior, 'smooth');
  assert.equal(revealForm(null), false);
});

test('revealIfHidden: virheviesti vieritetään vain jos se ei ole kokonaan ruudulla (nearest)', () => {
  const below = el({ top: 780, bottom: 840 }); assert.equal(revealIfHidden(below, win(false)), true); assert.deepEqual(below.calls.scroll, [{ block: 'nearest', behavior: 'smooth' }]);
  const above = el({ top: 20, bottom: 60 }); assert.equal(revealIfHidden(above, win(true)), true); assert.equal(above.calls.scroll[0].behavior, 'auto');
  const seen = el({ top: 300, bottom: 360 }); assert.equal(revealIfHidden(seen, win(false)), false); assert.equal(seen.calls.scroll.length, 0, 'jo näkyvissä → ei vieritystä');
});

test('lähdevalinta käyttää revealFormia kerran lomakkeen avautuessa (ei input-/renderöintikuuntelijassa); kaikki paikat jakavat redeemSectionin', () => {
  const src = readFileSync(new URL('../shop/src/order-gift.js', import.meta.url), 'utf8');
  assert.equal((src.match(/revealForm\(/g) || []).length, 1, 'yksi kutsupaikka: showChoose');
  assert.match(src, /choose\.hidden = false; revealForm\(choose, title\)/);
  assert.ok(!/preventScroll: false/.test(src), 'otsikon focus ei vieritä itse (minimivieritys jätti lomakkeen ruudun alareunaan)');
  const inputLine = src.split('\n').find((l) => /code\.addEventListener\('input'/.test(l));
  assert.ok(inputLine && !/reveal/.test(inputLine), 'kirjoittaminen ei vieritä');
  // kassan vahvistussivu (pay-choices.js) ja tilaussivu (order.js) rakentavat kyselyn samasta redeemSectionista
  for (const f of ['pay-choices.js', 'order.js']) assert.match(readFileSync(new URL(`../shop/src/${f}`, import.meta.url), 'utf8'), /redeemSection\(/);
  const css = readFileSync(new URL('../shop/src/shop.css', import.meta.url), 'utf8');
  assert.match(css, /\.vc-choose\{scroll-margin-top:\d+px\}/, 'sticky-yläpalkki huomioitu');
});
