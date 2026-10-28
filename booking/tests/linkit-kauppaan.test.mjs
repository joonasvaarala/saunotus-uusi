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
const FI = { shop: '/saunotus-uusi/varaa/', companies: '/saunotus-uusi/yritykset/', gift: '/saunotus-uusi/lahjakortti/', info: '/saunotus-uusi/info/', terms: '/saunotus-uusi/ehdot/', privacy: '/saunotus-uusi/tietosuoja/', base: '/saunotus-uusi', slugs: ['saunahoito-2', 'jalkiloylyt', 'naistensauna', 'perinnesaunotusilta', 'vuosikortti', 'lahjakortti', 'saunavuoro-yrityksille'] };
const EN = { ...FI, shop: '/saunotus-uusi/en/book/', companies: '/saunotus-uusi/en/companies/', gift: '/saunotus-uusi/en/gift-card/', info: '/saunotus-uusi/en/info/', terms: '/saunotus-uusi/en/terms/' };

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

test('shopTarget: ei yhtään Johku-linkkiä – lahjakortit, lahjakorttivaraus ja info omille sivuille; kanoniset osoitteet BASEen; muut ennallaan', () => {
  assert.equal(JL.shopTarget(`${J}/fi_FI/yleinen-lahjakorttivaraus`, FI), '/saunotus-uusi/varaa/#/');
  assert.equal(JL.shopTarget(`${J}/en_US/yleinen-lahjakorttivaraus`, EN), '/saunotus-uusi/en/book/#/');
  assert.equal(JL.shopTarget(`${J}/fi_FI/sarja-ja-lahjakortit`, FI), '/saunotus-uusi/lahjakortti/');
  assert.equal(JL.shopTarget(`${J}/fi_FI/sarja-ja-lahjakortit/lahjakortti`, FI), '/saunotus-uusi/lahjakortti/#avoin');
  assert.equal(JL.shopTarget(`${J}/en_US/sarja-ja-lahjakortit/savusaunaelamys-ja-koivuvihta`, EN), '/saunotus-uusi/en/gift-card/#paketit');
  assert.equal(JL.shopTarget(`${J}/fi_FI/info/deliveryTerms`, FI), '/saunotus-uusi/ehdot/');
  assert.equal(JL.shopTarget(`${J}/en_US/info/privacyPolicy`, EN), '/saunotus-uusi/tietosuoja/');
  assert.equal(JL.shopTarget(`${J}/fi_FI/info/`, FI), '/saunotus-uusi/info/');
  assert.equal(JL.shopTarget(J, FI), '/saunotus-uusi/varaa/#/');
  assert.equal(JL.shopTarget('https://saunotus.fi/varaa/#/tuote/jalkiloylyt', FI), '/saunotus-uusi/varaa/#/tuote/jalkiloylyt');
  assert.equal(JL.shopTarget('https://saunotus.fi/en/book/#/?k=yleinen', { ...EN, base: '' }), '/en/book/#/?k=yleinen');
  assert.equal(JL.shopTarget('https://saunotus.fi.evil.example/varaa/', FI), null);
  assert.equal(JL.shopTarget('https://saunotus.fi/varaa/', { ...FI, base: undefined }), null, 'ilman base-tietoa kanoninen jää');
  for (const u of ['https://example.com/fi_FI/hoidot/saunahoito-2', 'https://johku.com/customer', '', null, 'javascript:alert(1)']) assert.equal(JL.shopTarget(u, FI), null);
  assert.equal(JL.shopTarget(`${J}/fi_FI/hoidot/saunahoito-2`, {}), null, 'ilman kaupan polkua ei muutosta');
  assert.equal('KEEP' in JL, false, 'KEEP-listaa ei enää ole');
});

test('johkuHrefs (build-vartija): löytää hrefit HTML:stä ja JSON-merkkijonoista, ei tekstimainintoja', () => {
  assert.deepEqual(JL.johkuHrefs(`<a href="${J}/fi_FI/">x</a> sipoonjoenperinnesauna.johku.com`), [`${J}/fi_FI/`]);
  assert.deepEqual(JL.johkuHrefs(JSON.stringify({ d: `<a href="${J}/fi_FI/yleinen-lahjakorttivaraus">x</a>` })), [`${J}/fi_FI/yleinen-lahjakorttivaraus`]);
  assert.deepEqual(JL.johkuHrefs('<a href="https://saunotus.fi/varaa/">x</a>'), []);
  const b = readFileSync(join(root, 'shop/build.mjs'), 'utf8');
  assert.match(b, /JL\.johkuHrefs\(readFileSync\(p, 'utf8'\)\)/);
  assert.match(b, /Johku-linkkejä jäi/);
});

test('rewriteHtml: href vaihtuu, target/rel ja uuteen välilehteen -merkintä pois, muut linkit ennallaan', () => {
  const html = `<p><a class="btn" href="${J}/fi_FI/hoidot/saunahoito-2" target="_blank" rel="noopener">Varaa<span class="sr"> (avautuu uuteen välilehteen)</span></a> <a href="${J}/fi_FI/yleinen-lahjakorttivaraus" target="_blank" rel="noopener">Lahjakortti</a> <a href="https://saunotus.fi/en/book/#/tuote/naistensauna">N</a> <a href="https://example.com/">x</a></p>`;
  const out = JL.rewriteHtml(html, FI);
  assert.match(out, /<a class="btn" href="\/saunotus-uusi\/varaa\/#\/tuote\/saunahoito-2">Varaa<\/a>/);
  assert.ok(out.includes('<a href="/saunotus-uusi/varaa/#/">Lahjakortti</a>'));
  assert.ok(out.includes('<a href="/saunotus-uusi/en/book/#/tuote/naistensauna">N</a>'));
  assert.doesNotMatch(out, /johku\.com/);
  assert.ok(out.includes('<a href="https://example.com/">x</a>'));
  assert.equal(JL.rewriteHtml(null, FI), '');
});

test('rewriteAnchors (rich-view.js): DOM-linkit kauppaan, muut ennallaan; ilman linkkitietoja ei muutoksia', () => {
  const mk = (href) => { const at = { href, target: '_blank' }; return { at, getAttribute: (k) => at[k], setAttribute: (k, v) => { at[k] = v; }, removeAttribute: (k) => { delete at[k]; } }; };
  const as = [mk(`${J}/en_US/hoidot/saunahoito-2`), mk(`${J}/en_US/yleinen-lahjakorttivaraus`), mk('https://example.com/')];
  const rootEl = { querySelectorAll: () => as };
  assert.equal(JL.rewriteAnchors(rootEl, EN), 2);
  assert.deepEqual(as[0].at, { href: '/saunotus-uusi/en/book/#/tuote/saunahoito-2' });
  assert.deepEqual(as[1].at, { href: '/saunotus-uusi/en/book/#/' });
  assert.equal(as[2].at.href, 'https://example.com/');
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

test('kaupan tuoteosio: jokainen uuden kaupan varattava tuote (15) on shopProductsHtml-listassa kaupan linkillä; etusivu ei upota osiota (pending-import-58)', async () => {
  const SP = await import(pathToFileURL(join(root, '../src/shop-products.mjs')).href);
  const kb = JSON.parse(readFileSync(join(root, '../content/kb/kb.json'), 'utf8'));
  const prod = (s) => kb.products.find((p) => p.slug === s) || null;
  assert.equal(SP.SHOP_PRODUCT_SLUGS.length, 15);
  assert.equal(new Set(SP.SHOP_PRODUCT_SLUGS).size, 15);
  for (const s of SP.SHOP_PRODUCT_SLUGS) assert.ok(prod(s), `${s} kb-snapshotissa`);
  const ph = (k, lang, h = '') => ({ book: { fi: '/varaa/', en: '/en/book/' }, companies: { fi: '/yritykset/', en: '/en/companies/' } })[k][lang] + (h ? '#' + h : '');
  const head = (k, t, l) => `<h2>${t}</h2><p>${l}</p>`;
  const esc = (x) => String(x).replace(/&/g, '&amp;').replace(/</g, '&lt;');
  for (const lang of ['fi', 'en']) {
    const html = SP.shopProductsHtml(lang, { esc, pageHref: ph, head, product: prod });
    for (const g of SP.SHOP_PRODUCT_GROUPS) for (const s of g.slugs) {
      const want = g.key === 'corporate' ? `${ph('companies', lang)}#/tuote/${s}` : `${ph('book', lang)}#/tuote/${s}`;
      assert.ok(html.includes(`href="${want}"`), `${lang} ${s}`);
    }
    assert.doesNotMatch(html, /johku/i);
  }
  const xss = SP.shopProductsHtml('fi', { esc, pageHref: ph, head, product: (s) => ({ slug: s, name: '<img src=x onerror=alert(1)>' }) });
  assert.doesNotMatch(xss, /<img/);
  const rows = JSON.parse(readFileSync(join(root, '../content/site-texts.pending-import-58.json'), 'utf8'));
  for (const [k, v] of Object.entries(SP.SHOP_PRODUCT_TEXTS)) for (const lang of ['fi', 'en']) {
    const r = rows.find((x) => x.key === k && x.lang === lang);
    assert.ok(r, `${k} ${lang}`); assert.equal(r.text, v[lang]);
  }
  for (const r of rows) assert.ok(!r.text.includes('<') && !/johku/i.test(r.text), r.key);
  const render = readFileSync(join(root, '../src/render.mjs'), 'utf8');
  assert.match(render, /experienceHtml\(lang\)/);
  assert.doesNotMatch(render, /shopList|id="varaa-verkosta"/);
  assert.match(render, /eventsHtml\(lang, d\.events\.empty\)/);
  assert.doesNotMatch(render, /eventsHtml\([^)]*limit:\s*2/);
  assert.match(render, /href="\$\{pageHref\('book', lang, '\/\?k=tapahtuma'\)\}">\$\{e\(u\.allEvents\)\}/);
});
