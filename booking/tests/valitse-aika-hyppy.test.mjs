// Mobiilin "Valitse aika" ei saa vaihtaa hash-reittiä. Tapahtumatuotteella linkkiä ei ole.
// Kalenterituotteella painike vierittää #valitse-aika -osioon (scrollIntoView).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const read = (rel) => readFileSync(join(repo, rel), 'utf8');
const { bookingJump } = await import(pathToFileURL(join(root, 'shop/src/gift-ui.js')).href);

test('bookingJump on painike ilman #-ankkuria ja vierittää varausosioon', () => {
  const made = [];
  const h = (tag, attrs, ...kids) => { made.push({ tag, attrs, kids }); return { tag }; };
  const node = bookingJump(h, 'Valitse aika');
  assert.equal(node.tag, 'button');
  assert.equal(made[0].attrs.type, 'button');
  assert.equal(made[0].attrs.class, 'bk-jump');
  assert.equal(made[0].attrs['data-testid'], 'jump-booking');
  assert.equal(made[0].attrs.href, undefined);
  assert.deepEqual(made[0].kids, ['Valitse aika']);
  const scrolled = [];
  const focused = [];
  const section = {
    querySelector: () => heading,
    scrollIntoView(o) { scrolled.push(o); },
    matches() { return false; },
    setAttribute() {},
    focus() { focused.push('section'); },
  };
  const heading = {
    matches() { return false; },
    setAttribute() {},
    focus() { focused.push('h3'); },
  };
  const prev = globalThis.document;
  globalThis.document = { getElementById: (id) => (id === 'valitse-aika' ? section : null) };
  const hash = globalThis.location?.hash;
  try {
    made[0].attrs.onclick();
    assert.equal(scrolled.length, 1);
    assert.equal(scrolled[0].block, 'start');
    assert.equal(focused.at(-1), 'h3');
    assert.equal(globalThis.location?.hash, hash);
  } finally {
    if (prev === undefined) delete globalThis.document;
    else globalThis.document = prev;
  }
});

test('tapahtumatuotteella ei hyppyä, kalenteri ja hoito käyttävät painiketta', () => {
  const shop = read('booking/shop/src/shop.js');
  const treat = read('booking/shop/src/treatment-ui.js');
  const css = read('booking/shop/src/shop.css');
  assert.match(shop, /eventProduct \? null : bookingJump\(h, t\.pickTime\)/);
  assert.match(treat, /bookingJump\(h, t\.pickTime\)/);
  assert.doesNotMatch(shop, /href:\s*'#valitse-aika'/);
  assert.doesNotMatch(treat, /href:\s*'#valitse-aika'/);
  assert.match(css, /#valitse-aika\{scroll-margin-top:84px\}/);
  assert.match(css, /\.bk-jump:focus-visible\{outline:3px solid var\(--ink\)/);
  assert.match(read('.github/workflows/pages.yml'), /node --test booking\/tests\/valitse-aika-hyppy\.test\.mjs/);
});
