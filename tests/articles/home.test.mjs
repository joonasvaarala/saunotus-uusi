// Etusivun Saunatietoa-osio: valinta (3 uusinta, ei noindex), esirenderöity HTML (FI/EN), tyhjä/virhe → osio pois, kuvat, XSS, build-integraatio
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, existsSync, writeFileSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

delete process.env.SITE_ENV; process.env.SITE_URL = 'https://saunotus.fi';
const { pickHomeItems, homeSectionHtml } = await import('../../src/articles/pages.mjs');
const { loadArticles, makeFixtureRpc } = await import('../../src/articles/source.mjs');
const { setArticlesState, setHomeSections, homeSection } = await import('../../src/articles/runtime.mjs');
const R = await import('../../src/render.mjs');
const { cfg } = await import('../../src/articles/config.mjs');
const { checkDist } = await import('../../scripts/check-articles.mjs');

const root = resolve(new URL('../..', import.meta.url).pathname);
const fx = JSON.parse(readFileSync(new URL('./fixtures/home-preview.json', import.meta.url), 'utf8'));
const items = (L) => fx[L].map((card) => ({ lang: L, slug: card.slug, card }));
const variantsFor = (L) => new Map(fx[L].filter((c) => c.image).map((c) => [c.image.url, { id: 'v' + c.image.id, widths: [480, 800] }]));
const cards = (html) => html.split('<li class="card hart').slice(1);

test('asetus: etusivulla 3 artikkelia; linkkiteksti ja tekstit asetustiedostosta', () => {
  assert.equal(cfg.home.limit, 3);
  assert.equal(cfg.ui.fi.homeAll, 'Kaikki artikkelit'); assert.equal(cfg.ui.en.homeAll, 'All articles');
  assert.equal(cfg.ui.fi.readMore, 'Lue lisää'); assert.equal(cfg.ui.en.readMore, 'Read more');
});
test('valinta: uusin julkaisu ensin, enintään 3, noindex-artikkelia ei nosteta (vaikka uusin)', () => {
  const p = pickHomeItems(items('fi'));
  assert.deepEqual(p.map((x) => x.slug), ['miten-saunotaan-oikein', 'vihta-ja-vasta', 'savusauna-lampiaminen']);
  assert.ok(!p.some((x) => x.slug === 'noindex-testi' || x.slug === 'vanhempi-artikkeli'));
  // järjestys ei riipu RPC:n järjestyksestä (featured-first): sekoitettu syöte → sama tulos
  assert.deepEqual(pickHomeItems([...items('fi')].reverse()).map((x) => x.slug), p.map((x) => x.slug));
  assert.deepEqual(pickHomeItems(items('en')).map((x) => x.slug), ['how-to-sauna', 'whisk-or-vasta', 'heating-a-smoke-sauna']);
});
test('0 artikkelia → tyhjä merkkijono (osio piilossa kokonaan, ei tyhjää laatikkoa)', () => {
  assert.equal(homeSectionHtml([], 'fi', new Map()), '');
  assert.equal(homeSectionHtml([{ lang: 'fi', slug: 'a', card: { slug: 'a', title: 'A', noindex: true, published_at: '2026-01-01T00:00:00Z' } }], 'fi', new Map()), '');
  setHomeSections({}); assert.equal(homeSection('fi'), ''); assert.equal(homeSection('en'), '');
});
test('FI: otsikko Saunatietoa, linkki Kaikki artikkelit → /saunatietoa/, kortit → /saunatietoa/<slug>/, Lue lisää, päivämäärä', () => {
  const html = homeSectionHtml(items('fi'), 'fi', variantsFor('fi'));
  assert.match(html, /<h2 class="sec-title" id="home-art-fi">Saunatietoa<\/h2>/);
  assert.match(html, /<a class="btn light sm more-all" href="\/saunatietoa\/">Kaikki artikkelit<\/a>/);
  const cs = cards(html);
  assert.equal(cs.length, 3);
  assert.match(cs[0], /<h3><a href="\/saunatietoa\/miten-saunotaan-oikein\/">Miten saunotaan oikein\? Perinteinen opas<\/a><\/h3>/);
  for (const c of cs) { assert.equal((c.match(/<a /g) || []).length, 1, 'kortissa yksi linkki'); assert.match(c, /class="cta" aria-hidden="true">Lue lisää</); assert.match(c, /<time datetime="[^"]+">\d{1,2}\.\d{1,2}\.2026<\/time>/); }
  assert.doesNotMatch(html, /\/en\//);
});
test('EN: Sauna knowledge, All articles → /en/sauna-knowledge/, kortit → /en/sauna-knowledge/<slug>/, Read more', () => {
  const html = homeSectionHtml(items('en'), 'en', variantsFor('en'));
  assert.match(html, />Sauna knowledge<\/h2>/);
  assert.match(html, /href="\/en\/sauna-knowledge\/">All articles<\/a>/);
  const cs = cards(html);
  assert.equal(cs.length, 3);
  assert.match(cs[0], /href="\/en\/sauna-knowledge\/how-to-sauna\/"/);
  assert.match(cs[0], /Read more/);
  assert.match(cs[0], /17 Oct 2026/);
  assert.doesNotMatch(html, /Lue lisää|Kaikki artikkelit/);
});
test('kuva: width/height/alt, loading=lazy, srcset (480/800), kuvaton kortti merkitään noimg ilman paikkamerkkikuvaa', () => {
  const html = homeSectionHtml(items('fi'), 'fi', variantsFor('fi'));
  const cs = cards(html);
  const img = cs[0].match(/<img [^>]*>/)[0];
  assert.match(img, / width="1600" height="900" alt="" loading="lazy" decoding="async"/);
  assert.match(cs[0], /<source type="image\/avif" srcset="[^"]*-480\.avif 480w[^"]*" sizes="\(min-width:760px\) 380px, 100vw">/);
  assert.match(cs[2], /^ noimg"/); assert.doesNotMatch(cs[2], /<img|class="im"/);
});
test('kuva ilman valmistettua pientä versiota (sharp/lataus epäonnistui): kortti ilman kuvaa, alkuperäistä ei ladata', () => {
  const html = homeSectionHtml(items('fi'), 'fi', new Map());
  assert.doesNotMatch(html, /<img/); assert.equal(cards(html).length, 3);
});
test('XSS: otsikko ja summary escapataan; slug-polku ei riko attribuuttia', () => {
  const evil = [{ lang: 'fi', slug: 'x', card: { slug: 'x', title: '<script>alert(1)</script> & "q"', summary: '<img src=x onerror=alert(1)>', published_at: '2026-10-01T00:00:00Z', noindex: false } }];
  const html = homeSectionHtml(evil, 'fi', new Map());
  assert.doesNotMatch(html, /<script|<img src=x/);
  assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt; &amp; &quot;q&quot;/);
});
test('etusivu: Saunatietoa on nauha listauslinkillä, ei artikkelikortteja eikä home.css:ää; arvostelut jäävät ylemmäs; tyhjä lista piilottaa nauhan', () => {
  setArticlesState({ count: { fi: 3, en: 3 }, source: 'test' });
  setHomeSections({ fi: homeSectionHtml(items('fi'), 'fi', variantsFor('fi')), en: '' });
  const fi = R.home('fi'), en = R.home('en');
  assert.match(fi, /id="saunatietoa"/);
  assert.match(fi, /href="\/saunatietoa\/"/);
  assert.match(en, /id="saunatietoa"/);
  assert.match(en, /href="\/en\/sauna-knowledge\/"/);
  assert.doesNotMatch(fi, /class="section home-art"|hart-list|\.hart\{/);
  assert.doesNotMatch(en, /class="section home-art"|hart-list|\.hart\{/);
  assert.ok(fi.indexOf('id="arvostelut"') < fi.indexOf('id="saunatietoa"'));
  assert.equal((fi.match(/<h1/g) || []).length, 1);
  setHomeSections({});
  assert.doesNotMatch(R.home('fi'), /class="section home-art"|\.hart\{/);
  assert.match(R.home('fi'), /id="saunatietoa"/);
  setArticlesState({ count: { fi: 0, en: 0 }, source: 'test' });
  assert.doesNotMatch(R.home('fi'), /saunatietoa/);
  assert.doesNotMatch(R.home('en'), /sauna-knowledge/);
});
test('RPC-virhe tai tyhjä lista: loadArticles ei kaada, osio pois', async () => {
  const quiet = { warn() {}, log() {} };
  const bad = await loadArticles({ rpc: async () => { throw new Error('HTTP 500'); }, log: quiet });
  assert.equal(bad.lang.fi.items.length, 0);
  assert.equal(homeSectionHtml(bad.lang.fi.items, 'fi', new Map()), '');
  const empty = await loadArticles({ rpc: makeFixtureRpc(JSON.parse(readFileSync(new URL('./fixtures/rpc-empty.json', import.meta.url), 'utf8'))), log: quiet });
  assert.equal(homeSectionHtml(empty.lang.en.items, 'en', new Map()), '');
});

// ---- build-integraatio ----
const work = mkdtempSync(join(tmpdir(), 'home-art-'));
after(() => rmSync(work, { recursive: true, force: true }));
function build(name, env) {
  const dist = join(work, name);
  const r = spawnSync('node', ['scripts/build.mjs'], { cwd: root, encoding: 'utf8', env: { PATH: process.env.PATH, HOME: process.env.HOME, DIST: dist, ARTICLES_CACHE_DIR: join(work, 'c-' + name), ARTICLES_STATE_FILE: join(work, name + '-state.json'), ARTICLES_IMAGES: '0', SITE_URL: 'https://example.test', ...env } });
  assert.equal(r.status, 0, `build ${name} kaatui:\n${r.stdout}\n${r.stderr}`);
  return { dist, out: r.stdout + r.stderr };
}
const rd = (d, p) => readFileSync(join(d, p), 'utf8');
test('build (fixture, testi): etusivulla Saunatietoa-nauha, ei artikkelikortteja; esikatselusivut noindex, ei sitemapissa', () => {
  const b = build('t', { ARTICLES_FIXTURE: '1', SITE_ENV: 'test' });
  assert.match(rd(b.dist, 'index.html'), /id="saunatietoa"/);
  assert.doesNotMatch(rd(b.dist, 'index.html'), /class="section home-art"/);
  assert.match(rd(b.dist, 'en/index.html'), /id="saunatietoa"[\s\S]*href="\/en\/sauna-knowledge\/"/);
  assert.doesNotMatch(rd(b.dist, 'en/index.html'), /how-to-sauna/);
  for (const p of ['esikatselu/etusivu-artikkelit/index.html', 'en/preview/home-articles/index.html']) {
    const h = rd(b.dist, p);
    assert.equal(cards(h).length, 0); assert.match(h, /id="saunatietoa"/); assert.match(h, /<meta name="robots" content="noindex,nofollow">/); assert.match(h, /class="prev-note"/);
    assert.doesNotMatch(h, /noindex-testi|vanhempi-artikkeli|older-article|class="section home-art"/);
  }
  assert.doesNotMatch(rd(b.dist, 'sitemap.xml'), /esikatselu|preview/);
});
test('build (tuotanto): ei esikatselusivuja; tyhjä lista piilottaa nauhan, tuontitiedosto näyttää sen, build ei kaadu', () => {
  const e = build('pe', { ARTICLES_FIXTURE: join(root, 'tests/articles/fixtures/rpc-empty.json') });
  assert.doesNotMatch(rd(e.dist, 'index.html'), /home-art|saunatietoa/);
  assert.doesNotMatch(rd(e.dist, 'en/index.html'), /home-art|sauna-knowledge/);
  assert.ok(!existsSync(join(e.dist, 'esikatselu')) && !existsSync(join(e.dist, 'en/preview')));
  const f = build('pf', { BOOKING_SUPABASE_URL: 'http://localhost:9', BOOKING_ANON_KEY: 'sb_publishable_x' });
  // RPC ei vastaa eikä välimuistia ole: tuontitiedoston kuusi artikkelia lasketaan julkaistuiksi.
  // Etusivulle tulee Saunatietoa-nauha (publishedArticleCount > 0), ei vanhaa korttiosiota.
  assert.match(rd(f.dist, 'index.html'), /id="saunatietoa"/);
  assert.match(rd(f.dist, 'index.html'), /href="\/saunatietoa\/"/);
  assert.doesNotMatch(rd(f.dist, 'index.html'), /class="section home-art"/);
  assert.doesNotMatch(rd(f.dist, 'en/index.html'), /id="saunatietoa"/);
  assert.match(f.out, /pending-import-blogisarja/);
  assert.match(f.out, /etusivun osio FI näkyy/);
  const p = build('pp', { ARTICLES_FIXTURE: '1' });
  assert.match(rd(p.dist, 'index.html'), /id="saunatietoa"/);
  assert.doesNotMatch(rd(p.dist, 'index.html'), /class="section home-art"/);
  assert.ok(!existsSync(join(p.dist, 'esikatselu')));
});

// ---- check-articles.mjs: etusivun osion tarkistus havaitsee virheet ----
const chk = (dist) => checkDist({ dist, siteUrl: 'https://example.test', isTest: true, sections: { fi: '/saunatietoa/', en: '/en/sauna-knowledge/' }, legacy: { fi: [], en: ['/en/sauna-guide/'] } });
const mut = (name, fromName, fn) => { const d = join(work, name); cpSync(join(work, fromName), d, { recursive: true }); const f = join(d, 'index.html'); writeFileSync(f, fn(readFileSync(f, 'utf8'))); return d; };
test('check-articles: etusivun nauha läpi; havaitsee puuttuvan listauslinkin ja korttiosion tyhjässä tilassa', () => {
  assert.deepEqual(chk(join(work, 't')).errors, []);
  assert.ok(chk(mut('m1', 't', (h) => h.replace('id="saunatietoa"', 'id="ei-nauhaa"'))).errors.some((x) => /Saunatietoa-nauhasta puuttuu linkki/.test(x)));
  assert.ok(chk(mut('m3', 'pe', (h) => h.replace('<main id="main">', '<main id="main"><section class="section home-art"><div class="wrap"></div></section>'))).errors.some((x) => /näkyy vaikka artikkeleita ei ole/.test(x)));
});
