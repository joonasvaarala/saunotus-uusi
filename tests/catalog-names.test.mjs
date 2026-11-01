// Tuotenimet etusivulla ja saunavuoroissa tulevat public_catalogista (kb.products.name / name_en).
// Staattinen teksti jää, jos katalogia ei ole. Hinta, URL ja viikonpäivämerkki eivät muutu.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

delete process.env.SITE_ENV;
process.env.SITE_URL = 'https://saunotus.fi';

const { catalogDisplayName, applyCatalogNames } = await import('../booking/shop/src/catalog-names.js');
const { setLiveCatalog, clearLiveCatalog } = await import('../src/catalog-live.mjs');
const R = await import('../src/render.mjs');

const NAMES = [
  { id: 1, slug: 'yleinensauna', name: 'Yleinen vuoro', name_en: 'Public Sauna Session', price: 999 },
  { id: 2, slug: 'miestensauna-2', name: 'Miesten sauna', name_en: "Men's Sauna", price: 999 },
  { id: 3, slug: 'naistensauna', name: 'Naisten sauna', name_en: "Women's Sauna", price: 999 },
  { id: 4, slug: 'hiljainen-sauna', name: 'Hiljainen sauna', name_en: 'Silent Sauna', price: 999 },
  { id: 5, slug: 'turvetorstai', name: 'Turvetorstai', name_en: 'Peat Thursday (Turvetorstai)', price: 999 },
  { id: 6, slug: 'tunnin-vuoro', name: 'Tunnin saunavuoro', name_en: 'One-Hour Sauna Session', price: 999 },
];

function el(attrs, text) {
  const node = { attrs, _t: text, getAttribute: (k) => (k in attrs ? attrs[k] : null) };
  Object.defineProperty(node, 'textContent', { get() { return this._t; }, set(v) { this._t = String(v); } });
  return node;
}

test('nimi valitaan kuten kaupassa: EN name_en, tyhjä EN → suomi, sitova väli pehmenee', () => {
  assert.equal(catalogDisplayName({ name: 'Miesten sauna', name_en: "Men's Sauna" }, 'fi'), 'Miesten sauna');
  assert.equal(catalogDisplayName({ name: 'Miesten sauna', name_en: "Men's Sauna" }, 'en'), "Men's Sauna");
  assert.equal(catalogDisplayName({ name: 'Hiljainen sauna', name_en: '' }, 'en'), 'Hiljainen sauna');
  assert.equal(catalogDisplayName({ name: 'Turve\u00a0torstai' }, 'fi'), 'Turve torstai');
  assert.equal(catalogDisplayName({ name: '  Yleinen vuoro  ' }, 'fi'), 'Yleinen vuoro');
  assert.equal(catalogDisplayName(null, 'fi'), '');
  assert.equal(catalogDisplayName({ name_en: 'Only English' }, 'fi'), '');
});

test('selain vaihtaa vain merkityn nimen; hinta ja tuntematon tuote jäävät', () => {
  const price = el({}, '35 €');
  const title = el({ 'data-catalog-slug': 'turvetorstai' }, 'Turvetorstai (to)');
  const week = el({ 'data-pid': '2' }, 'Miesten sauna (ma)');
  const unknown = el({ 'data-catalog-slug': 'ei-katalogissa' }, 'Oma savusaunavuoro');
  const root = { querySelectorAll: () => [title, week, unknown] };
  const n = applyCatalogNames(root, [{ id: 2, slug: 'miestensauna-2', name: 'Miesten sauna', name_en: "Men's Sauna" }, { id: 5, slug: 'turvetorstai', name: 'Turvetorstai<img>', name_en: 'Peat Thursday (Turvetorstai)' }], 'fi');
  assert.equal(n, 2);
  assert.equal(title.textContent, 'Turvetorstai<img>');
  assert.equal(week.textContent, 'Miesten sauna');
  assert.equal(unknown.textContent, 'Oma savusaunavuoro');
  assert.equal(price.textContent, '35 €');
  assert.equal(applyCatalogNames(root, null, 'fi'), 0);
  assert.equal(title.textContent, 'Turvetorstai<img>');
  const src = readFileSync(new URL('../booking/shop/src/catalog-names.js', import.meta.url), 'utf8').replace(/^\s*\/\/.*$/gm, '');
  assert.match(src, /textContent = name/);
  assert.doesNotMatch(src, /innerHTML|outerHTML|insertAdjacentHTML/);
});

test('ilman katalogia viikko ja kortit näyttävät staattisen nimen', () => {
  clearLiveCatalog();
  const fi = R.sauna('fi');
  const en = R.sauna('en');
  assert.match(fi, /data-catalog-slug="turvetorstai">Turvetorstai \(to\)</);
  assert.match(fi, /data-catalog-slug="miestensauna-2">Miesten sauna \(ma\)</);
  assert.match(fi, /data-pid="1"[^>]*>[\s\S]*?data-catalog-name data-pid="1" data-catalog-slug="yleinensauna">Yleinen vuoro \(to, la-su\)</);
  assert.match(en, /data-catalog-slug="miestensauna-2">Men's Sauna \(Mon\)</);
  assert.match(en, /Peat Thursday \(Turvetorstai, Thu\)</);
  assert.match(fi, /<span class="pill">Maanantaisin<\/span>/);
  assert.match(fi, /<span class="pill">Tiistaisin<\/span>/);
  assert.match(fi, /<span class="pill">Keskiviikkoisin<\/span>/);
});

function cardSlice(html, slug) {
  const mark = `data-catalog-slug="${slug}">`;
  let from = 0;
  while (from < html.length) {
    const i = html.indexOf(mark, from);
    if (i < 0) return '';
    const back = html.slice(Math.max(0, i - 280), i);
    if (back.includes('<h3><a ')) return back + html.slice(i, i + 900);
    from = i + mark.length;
  }
  return '';
}
function cardHref(slice) {
  const h3 = slice.lastIndexOf('<h3>');
  return /href="([^"]+)"/.exec(slice.slice(h3))[1];
}

test('public_catalog peittää nimen FI ja EN; hinta, URL ja viikonpäivämerkki pysyvät', () => {
  clearLiveCatalog();
  const beforeHref = cardHref(cardSlice(R.sauna('fi'), 'turvetorstai'));
  setLiveCatalog(NAMES);
  try {
    const fi = R.sauna('fi');
    const en = R.sauna('en');
    const home = R.home('fi');
    const homeEn = R.home('en');
    for (const name of ['Yleinen vuoro', 'Miesten sauna', 'Naisten sauna', 'Hiljainen sauna', 'Turvetorstai']) {
      assert.match(fi, new RegExp(`data-catalog-name data-catalog-slug="[^"]+">${name}<`));
      assert.match(home, new RegExp(`>${name}<`));
    }
    assert.doesNotMatch(fi, /Turvetorstai \(to\)|Miesten sauna \(ma\)|Naisten sauna \(ti\)|Hiljainen sauna \(ke\)|Yleinen vuoro \(to, la-su\)/);
    assert.doesNotMatch(home, /Turvetorstai \(to\)|Miesten sauna \(ma\)|Yleinen vuoro \(to, la-su\)/);
    assert.match(en, /data-catalog-slug="miestensauna-2">Men's Sauna</);
    assert.match(en, /data-catalog-slug="turvetorstai">Peat Thursday \(Turvetorstai\)</);
    assert.doesNotMatch(en, /Men's Sauna \(Mon\)|Women's Sauna \(Tue\)|Silent Sauna \(Wed\)|Public Sauna Session \(Thu, Sat–Sun\)|Peat Thursday \(Turvetorstai, Thu\)/);
    assert.match(homeEn, />Public Sauna Session</);
    assert.doesNotMatch(homeEn, /Public Sauna Session \(Thu/);
    assert.match(fi, /<span class="pill">Maanantaisin<\/span>/);
    assert.match(en, /<span class="pill">Mondays<\/span>/);
    assert.match(fi, /<li>ma<\/li>/);
    assert.match(fi, /<li>to<\/li>/);
    const peat = cardSlice(fi, 'turvetorstai');
    assert.match(peat, /35 €/);
    assert.doesNotMatch(peat, /999/);
    assert.equal(cardHref(peat), beforeHref);
    assert.match(home, /data-pid="5"[^>]*>[\s\S]*?data-catalog-name data-pid="5" data-catalog-slug="turvetorstai">Turvetorstai</);
    assert.match(home, /data-pid="2"[^>]*>[\s\S]*?data-catalog-name data-pid="2" data-catalog-slug="miestensauna-2">Miesten sauna</);
  } finally {
    clearLiveCatalog();
  }
});

test('viikkosivu hakee katalogin ja kirjoittaa nimet haun jälkeen', () => {
  const src = readFileSync(new URL('../booking/shop/src/quiet-week.js', import.meta.url), 'utf8');
  assert.match(src, /rpc\('public_catalog'/);
  assert.match(src, /applyCatalogNames\(document, catalog, namesLang\)/);
  assert.doesNotMatch(src.replace(/^\s*\/\/.*$/gm, ''), /innerHTML|outerHTML|insertAdjacentHTML/);
  const boot = readFileSync(new URL('../booking/shop/src/catalog-names-boot.js', import.meta.url), 'utf8');
  assert.match(boot, /rpc\('public_catalog'/);
  assert.match(readFileSync(new URL('../booking/shop/build.mjs', import.meta.url), 'utf8'), /catalog-names-boot\.js/);
});
