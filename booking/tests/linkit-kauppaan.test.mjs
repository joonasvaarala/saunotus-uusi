// Linkit kaupan sisälle (Joonas 24.10.2026): Johku-tuotelinkit → /varaa/#/tuote/<slug> (EN /en/book/#/tuote/<slug>), kun tuote on uudessa
// kaupassa. booking/shop/src/johku-links.js + booking/shop/build.mjs (perussivusto, static-products.json) + rich-view.js (tietokannan kuvaukset).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const JL = await import(pathToFileURL(join(root, 'shop/src/johku-links.js')).href);
const J = 'https://sipoonjoenperinnesauna.johku.com';
const FI = { shop: '/saunotus-uusi/varaa/', companies: '/saunotus-uusi/yritykset/', slugs: ['saunahoito-2', 'jalkiloylyt', 'naistensauna', 'perinnesaunotusilta', 'vuosikortti', 'lahjakortti', 'saunavuoro-yrityksille'] };
const EN = { ...FI, shop: '/saunotus-uusi/en/book/', companies: '/saunotus-uusi/en/companies/' };

test('shopTarget: tuote → kaupan tuotesivu FI/EN, kategoriat → kaupan suodatin, tuntematon → kaupan etusivu', () => {
  assert.equal(JL.shopTarget(`${J}/fi_FI/hoidot/saunahoito-2`, FI), '/saunotus-uusi/varaa/#/tuote/saunahoito-2');
  assert.equal(JL.shopTarget(`${J}/en_US/yleinen-sauna/naistensauna`, EN), '/saunotus-uusi/en/book/#/tuote/naistensauna');
  assert.equal(JL.shopTarget(`${J}/fi_FI/tapahtumat/perinnesaunotusilta/`, FI), '/saunotus-uusi/varaa/#/tuote/perinnesaunotusilta');
  assert.equal(JL.shopTarget(`${J}/fi_FI/yleinen-sauna`, FI), '/saunotus-uusi/varaa/#/?k=yleinen');
  assert.equal(JL.shopTarget(`${J}/fi_FI/yksityisvuorot`, FI), '/saunotus-uusi/varaa/#/?k=yksityinen');
  assert.equal(JL.shopTarget(`${J}/fi_FI/hoidot/tuntematon`, FI), '/saunotus-uusi/varaa/#/');
  assert.equal(JL.shopTarget(`${J}/fi_FI/`, FI), '/saunotus-uusi/varaa/#/');
  assert.equal(JL.shopTarget(`${J}/fi_FI/yrityksille`, FI), '/saunotus-uusi/yritykset/');
  assert.equal(JL.shopTarget(`${J}/en_US/yrityksille/saunavuoro-yrityksille`, EN), '/saunotus-uusi/en/companies/#/tuote/saunavuoro-yrityksille');
  assert.equal(JL.shopTarget(`${J}/fi_FI/sarja-ja-lahjakortit/vuosikortti`, FI), '/saunotus-uusi/varaa/#/vuosikortti');
});

test('shopTarget: jää Johkuun vain KEEP-lista (lahjakorttivaraus, lahja-/sarjakortit, Johkun info); muut osoitteet ennallaan', () => {
  for (const p of ['yleinen-lahjakorttivaraus', 'sarja-ja-lahjakortit', 'sarja-ja-lahjakortit/lahjakortti', 'info/ehdot', 'info']) assert.equal(JL.shopTarget(`${J}/fi_FI/${p}`, FI), null, p);
  for (const u of ['https://example.com/fi_FI/hoidot/saunahoito-2', 'https://johku.com/customer', '', null, 'javascript:alert(1)']) assert.equal(JL.shopTarget(u, FI), null);
  assert.equal(JL.shopTarget(`${J}/fi_FI/hoidot/saunahoito-2`, {}), null, 'ilman kaupan polkua ei muutosta');
});

test('rewriteHtml: href vaihtuu, target/rel ja uuteen välilehteen -merkintä pois, muut linkit ennallaan', () => {
  const html = `<p><a class="btn" href="${J}/fi_FI/hoidot/saunahoito-2" target="_blank" rel="noopener">Varaa<span class="sr"> (avautuu uuteen välilehteen)</span></a> <a href="${J}/fi_FI/yleinen-lahjakorttivaraus" target="_blank" rel="noopener">Lahjakortti</a> <a href="https://example.com/">x</a></p>`;
  const out = JL.rewriteHtml(html, FI);
  assert.match(out, /<a class="btn" href="\/saunotus-uusi\/varaa\/#\/tuote\/saunahoito-2">Varaa<\/a>/);
  assert.ok(out.includes(`href="${J}/fi_FI/yleinen-lahjakorttivaraus" target="_blank"`));
  assert.ok(out.includes('<a href="https://example.com/">x</a>'));
  assert.equal(JL.rewriteHtml(null, FI), '');
});

test('rewriteAnchors (rich-view.js): DOM-linkit kauppaan, KEEP ja muut ennallaan; ilman linkkitietoja ei muutoksia', () => {
  const mk = (href) => { const at = { href, target: '_blank' }; return { at, getAttribute: (k) => at[k], setAttribute: (k, v) => { at[k] = v; }, removeAttribute: (k) => { delete at[k]; } }; };
  const as = [mk(`${J}/en_US/hoidot/saunahoito-2`), mk(`${J}/en_US/yleinen-lahjakorttivaraus`), mk('https://example.com/')];
  const rootEl = { querySelectorAll: () => as };
  assert.equal(JL.rewriteAnchors(rootEl, EN), 1);
  assert.deepEqual(as[0].at, { href: '/saunotus-uusi/en/book/#/tuote/saunahoito-2' });
  assert.equal(as[1].at.href, `${J}/en_US/yleinen-lahjakorttivaraus`);
  assert.equal(JL.rewriteAnchors(rootEl, null), 0);
  const rv = readFileSync(join(root, 'shop/src/rich-view.js'), 'utf8');
  assert.match(rv, /import \{ rewriteAnchors \} from '\.\/johku-links\.js'/);
  assert.match(rv, /el\.innerHTML = sanitizeRich\(s\);\s*rewriteAnchors\(el, linkCtx\(\)\);/);
});

test('build.mjs: yksi linkkilogiikka (johku-links.js), linkkitiedot kaikille kauppasivuille, static-products.json kuvaukset, moduuli distiin', () => {
  const b = readFileSync(join(root, 'shop/build.mjs'), 'utf8');
  assert.match(b, /import\(resolve\(here, 'src\/johku-links\.js'\)\)/);
  assert.match(b, /const rewrite = \(html, lang\) => JL\.rewriteHtml\(html, LINKS\(lang\)\)/);
  assert.doesNotMatch(b, /GIFT_KEEP/);
  assert.ok((b.match(/links: LINKS\(lang\)/g) || []).length >= 4, 'kauppa/vahvistus, tilaus, lahjakortti, yritykset');
  assert.match(b, /'johku-links\.js'\]\) cpSync/);
  assert.match(b, /linkVal\(k, p\[k\]\)/);
  assert.ok(readFileSync(join(root, '../.github/workflows/pages.yml'), 'utf8').includes('booking/tests/linkit-kauppaan.test.mjs'));
});
