// Kauppa (/varaa/, /en/book/): 1) tuotekortin ajankohta (päivät + kellonajat / kesto) omalla rivillään hinnan YLÄPUOLELLA, hinta omalla rivillään;
// 2) "Selaa päivän mukaan": yksityisvuorot → yleiset vuorot → hoidot ja rituaalit. FI ja EN (sama koodi, tekstit kielen mukaan). Ei verkkoa eikä tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { cardMeta, keepTimes } from '../shop/src/card-meta.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (rel) => readFileSync(join(root, rel), 'utf8');
// kevyt h-korvike: { tag, attrs, kids } (null-lapset pois kuten shop.js:n h)
const h = (tag, attrs, ...kids) => ({ tag, attrs: attrs || {}, kids: kids.flat().filter((k) => k != null && k !== false) });
const plain = (s) => s.replace(/\u2060/g, '').replace(/\u00a0/g, ' ');
const text = (n) => plain(typeof n === 'string' ? n : `${n.attrs.text ?? ''}${n.kids.map(text).join('')}`);

test('cardMeta: ajankohta omana rivinään ennen hintaa, hinta omana rivinään (FI)', () => {
  const n = cardMeta(h, '29 € / hlö', 'la–su klo 14–19 (saunomisaika 2 h); to klo 17–19');
  assert.equal(n.tag, 'div'); assert.equal(n.attrs.class, 'bk-card-meta');
  assert.equal(n.kids.length, 2);
  const [when, price] = n.kids;
  assert.equal(when.tag, 'p'); assert.match(when.attrs.class, /\bbk-card-when\b/);
  assert.equal(text(when), 'la–su klo 14–19 (saunomisaika 2 h); to klo 17–19');
  assert.equal(price.tag, 'p'); assert.match(price.attrs.class, /\bbk-card-price\b/);
  assert.equal(price.kids[0].tag, 'strong'); assert.equal(text(price), '29 € / hlö');
  assert.doesNotMatch(text(n), / · /, 'ei enää "hinta · ajankohta" samalla rivillä');
});

test('cardMeta: EN ja puuttuva ajankohta → vain hintarivi', () => {
  const en = cardMeta(h, '€29 / person', 'Sat–Sun 14–19 (2 h); Thu 17–19');
  assert.deepEqual(en.kids.map(text), ['Sat–Sun 14–19 (2 h); Thu 17–19', '€29 / person']);
  for (const w of ['', '   ', null, undefined]) {
    const n = cardMeta(h, '18 €', w);
    assert.equal(n.kids.length, 1); assert.match(n.kids[0].attrs.class, /bk-card-price/);
  }
});

test('tuotelistan kortit (vuoro + hoito) käyttävät cardMeta-riviä; CSS kohdistaa hinnan alas', () => {
  const shop = read('shop/src/shop.js'), tui = read('shop/src/treatment-ui.js'), css = read('shop/src/shop.css');
  assert.match(shop, /import \{ cardMeta \} from '\.\/card-meta\.js';/);
  assert.match(shop, /cardExcerpt\(p\),\s*\n\s*cardMeta\(h, priceText\(p\), pdur\(p\)\)/);
  assert.match(tui, /import \{ cardMeta \} from '\.\/card-meta\.js';/);
  assert.match(tui, /cardShort\(h, p, S\.lang, pdesc\(p\)\),[^\n]*\n\s*cardMeta\(h, priceText\(p\), durText\(p\)\)/);
  assert.match(css, /\.bk-card-meta\{margin-top:auto;display:flex;flex-direction:column/);
  assert.doesNotMatch(css.match(/\.bk-card-meta[^}]*\}/g).join(''), /blue|#00f|#0000ff/i);
});

test('päivänäkymä: yksityisvuorot → yleiset vuorot → tapahtumat → muut, hoidot viimeisenä', () => {
  const shop = read('shop/src/shop.js');
  assert.match(shop, /import \{ kindOf, chipsFor, DAY_KIND_ORDER \} from '\.\/catalog-kind\.js';/);
  assert.match(shop, /const groups = DAY_KIND_ORDER\.map\(/);
  assert.doesNotMatch(shop, /\['yleinen', 'yksityinen'/);
  const v = shop.slice(shop.indexOf('async function viewDay('), shop.indexOf('if (treatBox) fillTreatments('));
  assert.ok(v.indexOf('const groups = DAY_KIND_ORDER') < v.indexOf('if (treatBox) results.append(treatBox)'), 'hoidot-osio lisätään ryhmien jälkeen');
  const i18n = read('shop/src/i18n.js');
  for (const k of ['k_yksityinen', 'k_yleinen', 'k_tapahtuma', 'k_hoito']) assert.ok((i18n.match(new RegExp(`\\b${k}\\b`, 'g')) || []).length >= 2, `${k} FI + EN`);
});

test('keepTimes: kellonaikaväli ei katkea viivasta, "klo 17" pysyy yhdessä; teksti muuten ennallaan', () => {
  const x = keepTimes('la–su klo 14–19 (saunomisaika 2 h); to klo 17–19');
  assert.equal(plain(x), 'la–su klo 14–19 (saunomisaika 2 h); to klo 17–19');
  assert.match(x, /17\u2060–\u206019/); assert.match(x, /klo\u00a017/);
  assert.match(x, /la–su/, 'viikonpäiväväli saa katketa normaalisti');
  assert.equal(plain(keepTimes('Sat–Sun at 14 or 18')), 'Sat–Sun at 14 or 18');
  assert.equal(keepTimes(null), '');
});
