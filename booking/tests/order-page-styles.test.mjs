// Tilaussivun ja maksutapojen yhteinen kortti-, otsikko- ja painiketyyli.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const src = (name) => readFileSync(new URL(`../shop/src/${name}`, import.meta.url), 'utf8');
const css = src('shop.css');

test('tilaussivun kortit käyttävät samaa otsikkoluokkaa ja semanttisia otsikoita', () => {
  const order = src('order.js');
  for (const id of ['ord-g', 'ord-h', 'ord-rv', 'ord-l', 'ord-p', 'ord-r', 'ord-a', 'ord-c', 'ord-o']) {
    assert.match(order, new RegExp(`h\\('h[23]', \\{ id: '${id}', class: 'ord-card-title'`), `${id}: yhteinen otsikkoluokka`);
  }
  assert.match(order, /class: 'ord-card ord-pay', 'aria-labelledby': 'ord-p', 'data-testid': 'order-pay'/);
  assert.match(order, /h\('h3', \{ id: 'ord-p', class: 'ord-card-title', text: t\.paymentTitle \}/);
  assert.doesNotMatch(order, /id: 'ord-p', class: 'mp-title'/);
});

test('lahjakortti ja vahvistussivun maksuvalinta noudattavat samaa kortti- ja otsikkorakennetta', () => {
  const gift = src('order-gift.js');
  for (const id of ['ord-gc', 'ord-vc', 'ord-gcs']) {
    assert.match(gift, new RegExp(`h\\('h3', \\{ id: '${id}', class: 'ord-card-title'`));
  }
  assert.match(gift, /class: 'ord-card', 'aria-labelledby': 'ord-gc', 'data-testid': 'gc-redeem'/);
  const choices = src('pay-choices.js');
  assert.match(choices, /class: 'bk-paychoices ord-card', 'aria-labelledby': `\$\{id\}-t`, 'data-testid': 'pay-choices'/);
  assert.match(choices, /h\('h3', \{ id: `\$\{id\}-t`, class: 'ord-card-title', text: tx\('title'\) \}/);
});

test('MobilePay ja Visma Pay käyttävät samaa alaotsikkoa ja niiden painikkeiden testitunnisteet säilyvät', () => {
  for (const [file, id] of [['mobilepay-ui.js', 'mp-button'], ['vismapay-ui.js', 'vp-button']]) {
    const code = src(file);
    assert.match(code, /h\('h4', \{ class: 'mp-title ord-method-title'/);
    assert.ok(code.includes(`'data-testid': '${id}'`));
  }
  assert.match(css, /\.ord \.ord-method-title,\.bk-paychoices \.ord-method-title\{/);
});

test('kortin laatikko ja otsikko tulevat yhteisestä CSS:stä, eivät maksuosion erikoistyyleistä', () => {
  const box = css.match(/\.ord-card\{([^}]*)\}/)?.[1] || '';
  for (const prop of ['background:var(--card)', 'border:1px solid var(--line)', 'border-radius:var(--r)', 'padding:20px']) {
    assert.ok(box.includes(prop), `ord-card: ${prop}`);
  }
  assert.match(css, /\.ord-card>\.ord-card-title\{/);
  assert.match(css, /\.ord-card>h2\.ord-card-title\{/);
  assert.match(css, /\.ord,\.bk-paychoices\{font:400 16px\/1\.55 var\(--body\)/);
  assert.match(css, /\.ord \.btn:not\(\.mp-fallback\),\.bk-paychoices \.btn:not\(\.mp-fallback\)/);
  const payBox = css.match(/\.ord-pay\{([^}]*)\}/)?.[1] || '';
  assert.doesNotMatch(payBox, /(?:padding|border(?:-radius)?|background)\s*:/, 'ei erillistä maksukortin laatikkotyyliä');
  assert.doesNotMatch(css, /\.ord-pay>h3\.mp-title\{/);
  assert.match(css, /\.bk-paychoices \.gc-redeem-bare\{padding:0;border:0;/);
});
