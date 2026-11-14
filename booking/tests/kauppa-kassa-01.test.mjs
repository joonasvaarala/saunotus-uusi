// KAUPPA-KASSA-01: kassan alapalkki (summa + maksuohje + lähetysnappi samassa näkymässä alle 900 px).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createPayBar, barText } from '../shop/src/pay-bar.js';

// Minimaalinen elementtirakentaja (h-yhteensopiva): ei DOMia tarvita.
function h(tag, attrs = {}, ...kids) {
  const el = { tag, attrs, hidden: !!attrs.hidden, textContent: attrs.text ?? '', children: [] };
  const add = (k) => { if (k == null) return; if (Array.isArray(k)) k.forEach(add); else el.children.push(k); };
  kids.forEach(add);
  return el;
}
const money = (n) => `${n.toFixed(2).replace('.', ',')} €`;
const t = { total: 'Yhteensä', vatIncl: 'sis. ALV' };
const find = (el, id) => (el.attrs?.['data-testid'] === id ? el : (el.children || []).map((c) => find(c, id)).find(Boolean));

test('palkki sisältää summan, ohjeen ja saman lähetysnapin', () => {
  const submit = h('button', { type: 'submit', 'data-testid': 'checkout-submit' });
  const bar = createPayBar({ h, t, money, submit });
  assert.ok(find(bar.node, 'checkout-submit') === submit);
  assert.ok(find(bar.node, 'paybar-total') && find(bar.node, 'paybar-note'));
});

test('summa päivittyy luvusta ja tekstistä', () => {
  const bar = createPayBar({ h, t, money, submit: h('button') });
  bar.setTotal(58);
  assert.equal(find(bar.node, 'paybar-total').textContent, '58,00 €');
  bar.setTotal('116,00 €');
  assert.equal(find(bar.node, 'paybar-total').textContent, '116,00 €');
});

test('maksuohje näkyy vain kun on tekstiä eikä ole piilotettu', () => {
  const bar = createPayBar({ h, t, money, submit: h('button') });
  const note = find(bar.node, 'paybar-note');
  assert.equal(note.hidden, true);
  bar.setNote('Paikka varataan 15 minuutiksi, kun jatkat maksamaan.');
  assert.equal(note.hidden, false);
  assert.match(note.textContent, /15 minuutiksi/);
  bar.setNote('x', true); assert.equal(note.hidden, true);
  bar.setNote('   '); assert.equal(note.hidden, true);
  assert.equal(barText(null), '');
});

test('shop.js ja treatment-ui.js käyttävät palkkia; maksuohje kopioidaan sivupalkista', () => {
  const shop = readFileSync(new URL('../shop/src/shop.js', import.meta.url), 'utf8');
  const tr = readFileSync(new URL('../shop/src/treatment-ui.js', import.meta.url), 'utf8');
  assert.match(shop, /createPayBar\(\{ h, t, money, submit \}\)/);
  assert.match(shop, /payBar\.setNote\(payNote\.textContent, payNote\.hidden\)/);
  assert.match(shop, /payBar\?\.setTotal\(total\.textContent\)/);
  assert.match(shop, /msg, payBar\.node\)/);
  assert.match(tr, /createPayBar\(\{ h, t, money, submit: next \}\)/);
  assert.match(tr, /payBar\.setTotal\(totalNow\(\)\)/);
});

test('CSS: alapalkki sticky alle 900 px, sivupalkin kaksi saraketta ennallaan', () => {
  const css = readFileSync(new URL('../shop/src/shop.css', import.meta.url), 'utf8');
  assert.match(css, /@media\(max-width:899px\)\{\s*\.bk-form \.bk-paybar\{position:sticky;bottom:0/);
  assert.match(css, /@media\(min-width:900px\)\{\.bk-checkout\{grid-template-columns:minmax\(0,1\.4fr\) minmax\(280px,1fr\)\}/);
  assert.match(css, /\.bk-bar-note,\.bk-bar-sum\{display:none\}/);
});
