// Build-tarkistus: rakentaa sivuston fixture-datalla (testi- ja tuotantotila), ajaa scripts/check-articles.mjs-logiikan
// (JSON-LD, canonicalit, hreflangit, sitemap, robots, kuvat, ohjaus, navigaatio) ja varmistaa mutaatioilla että tarkistus oikeasti havaitsee virheet.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, cpSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const root = resolve(new URL('../..', import.meta.url).pathname);
const work = mkdtempSync(join(tmpdir(), 'art-build-'));
const SECTIONS = { fi: '/saunatietoa/', en: '/en/sauna-knowledge/' };
const T_URL = 'https://joonasvaarala.github.io/saunotus-uusi', P_URL = 'https://saunotus.fi';
const { checkDist } = await import('../../scripts/check-articles.mjs');

function build(name, env) {
  const dist = join(work, name);
  const r = spawnSync('node', ['scripts/build.mjs'], { cwd: root, encoding: 'utf8', env: { PATH: process.env.PATH, HOME: process.env.HOME, DIST: dist, ARTICLES_CACHE_DIR: join(work, 'cache-' + name), ARTICLES_STATE_FILE: join(work, name + '-state.json'), ...env } });
  assert.equal(r.status, 0, `build ${name} kaatui:\n${r.stdout}\n${r.stderr}`);
  return { dist, out: r.stdout + r.stderr };
}
const LEGACY = { fi: [], en: ['/en/sauna-guide/'] };
const check = (dist, isTest) => checkDist({ dist, siteUrl: isTest ? T_URL : P_URL, isTest, sections: SECTIONS, legacy: LEGACY });
const read = (dist, p) => readFileSync(join(dist, p), 'utf8');
const mutate = (dist, p, fn) => { const f = join(dist, p); writeFileSync(f, fn(readFileSync(f, 'utf8'))); };

let testDist, prodDist;
before(() => {
  testDist = build('fx-test', { ARTICLES_FIXTURE: '1', SITE_ENV: 'test' }).dist;
  prodDist = build('fx-prod', { ARTICLES_FIXTURE: '1', ARTICLES_IMAGES: '0' }).dist;
});
after(() => rmSync(work, { recursive: true, force: true }));

test('testiympäristö (fixture): tarkistus läpi; kaikki sivut noindex; robots.txt estää', () => {
  const r = check(testDist, true);
  assert.deepEqual(r.errors, []);
  assert.deepEqual(r.stats, { pages: 23, articles: 4, redirects: 5, lists: 14 });   // redirects: 2 siirrettyä slugia (RPC) + vanha EN-listaus + 2 vanhan EN-polun artikkelia
  assert.match(read(testDist, 'robots.txt'), /Disallow: \//);
});
test('tuotanto (fixture): tarkistus läpi; canonicalit tuotantoon, indeksoitavat sitemapissa, noindex-artikkeli ei', () => {
  const r = check(prodDist, false);
  assert.deepEqual(r.errors, []);
  const sm = read(prodDist, 'sitemap.xml');
  assert.match(sm, /<loc>https:\/\/saunotus\.fi\/saunatietoa\/miten-saunotaan-oikein\/<\/loc>/);
  assert.match(sm, /<xhtml:link rel="alternate" hreflang="en" href="https:\/\/saunotus\.fi\/en\/sauna-knowledge\/how-to-sauna\/"\/>/);
  assert.doesNotMatch(sm, /noindex-testiartikkeli|vanha-nimi|\/tagi\//);
  assert.match(read(prodDist, 'robots.txt'), /Allow: \/\n[\s\S]*Sitemap: https:\/\/saunotus\.fi\/sitemap\.xml/);
  assert.doesNotMatch(read(prodDist, 'saunatietoa/miten-saunotaan-oikein/index.html'), /<meta name="robots" content="noindex/);
  assert.match(read(prodDist, 'saunatietoa/noindex-testiartikkeli/index.html'), /<meta name="robots" content="noindex,follow">/);
});
test('testiympäristössä jokaisella sivulla noindex,nofollow (SITE_ENV=test), tuotannossa ei', () => {
  assert.match(read(testDist, 'saunatietoa/miten-saunotaan-oikein/index.html'), /<meta name="robots" content="noindex,nofollow">/);
  assert.doesNotMatch(read(prodDist, 'index.html'), /noindex/);
});
test('responsiiviset kuvat tuotettu (avif+webp, usea leveys) ja viitataan srcsetillä', () => {
  const html = read(testDist, 'saunatietoa/miten-saunotaan-oikein/index.html');
  const m = /srcset="([^"]*\.avif[^"]*)"/.exec(html);
  assert.ok(m);
  const parts = m[1].split(',').map((x) => x.trim().split(' ')[0]);
  assert.ok(parts.length >= 3);
  for (const p of parts) assert.ok(existsSync(join(testDist, p.replace(/^\/saunotus-uusi/, ''))), p);
  assert.match(html, /sizes="\(min-width:1000px\) 960px, 100vw"/);
});
test('navigaatio: Saunatietoa-linkki header, mobiilivalikko ja footer (FI+EN) kun artikkeleita on; aria-current osiossa', () => {
  const fi = read(prodDist, 'index.html'), en = read(prodDist, 'en/index.html');
  assert.equal((fi.match(/href="\/saunatietoa\/">Saunatietoa<\/a>/g) || []).length, 3);
  assert.equal((en.match(/href="\/en\/sauna-knowledge\/">Sauna knowledge<\/a>/g) || []).length, 3);
  assert.match(read(prodDist, 'saunatietoa/index.html'), /<a href="\/saunatietoa\/" aria-current="page">Saunatietoa<\/a>/);
  assert.match(read(prodDist, 'varaa/index.html'), /href="\/saunatietoa\/">Saunatietoa<\/a>/, 'myös varauskaupan sivut (oma prosessi) saavat linkin');
});

// ---- mutaatiot: tarkistuksen pitää havaita virheet ----
const mutated = (name, base, edits) => { const d = join(work, name); cpSync(base, d, { recursive: true }); for (const [p, fn] of edits) mutate(d, p, fn); return d; };
const ART = 'saunatietoa/miten-saunotaan-oikein/index.html', ART_EN = 'en/sauna-knowledge/how-to-sauna/index.html';
const caught = (name, base, isTest, edits, re) => test(`tarkistus havaitsee: ${name}`, () => {
  const r = check(mutated(name.replace(/\W+/g, '_'), base, edits), isTest);
  assert.ok(r.errors.some((e) => re.test(e)), `odotettiin ${re}, saatiin:\n${r.errors.join('\n')}`);
});
const P = () => prodDist;
caught('puuttuva canonical', P(), false, [[ART, (h) => h.replace(/<link rel="canonical"[^>]*>/, '')]], /canonical-linkkejä 0/);
caught('canonical ≠ mainEntityOfPage', P(), false, [[ART, (h) => h.replace(/<link rel="canonical" href="[^"]*"/, '<link rel="canonical" href="https://saunotus.fi/muu/"')]], /mainEntityOfPage/);
caught('rikkinäinen JSON-LD', P(), false, [[ART, (h) => h.replace('"@type":"Article"', '"@type":"Article",')]], /ei ole kelvollista JSONia/);
caught('Article.image puuttuu', P(), false, [[ART, (h) => h.replace(/"image":\["[^"]*"\],?/, '')]], /Article\.image/);
caught('Article.datePublished virheellinen', P(), false, [[ART, (h) => h.replace(/"datePublished":"[^"]*"/, '"datePublished":"eilen"')]], /datePublished ei ole ISO/);
caught('BreadcrumbList puuttuu', P(), false, [[ART, (h) => h.replace(/<script type="application\/ld\+json">\{"@context":"https:\/\/schema\.org","@type":"BreadcrumbList".*?<\/script>/, '')]], /BreadcrumbList puuttuu/);
caught('hreflang ei molemminpuolinen', P(), false, [[ART_EN, (h) => h.replace(/<link rel="alternate" hreflang="fi"[^>]*>/, '')]], /hreflang/);
caught('hreflang ilman x-default', P(), false, [[ART, (h) => h.replace(/<link rel="alternate" hreflang="x-default"[^>]*>/, '')]], /x-default/);
caught('hreflang viittaa olemattomaan sivuun', P(), false, [[ART, (h) => h.replace('/en/sauna-knowledge/how-to-sauna/"', '/en/sauna-knowledge/ei-ole/"')]], /ei löydy dististä/);
caught('sitemapissa noindex-sivu', P(), false, [['sitemap.xml', (x) => x.replace('</urlset>', '<url><loc>https://saunotus.fi/saunatietoa/noindex-testiartikkeli/</loc><lastmod>2026-10-18</lastmod></url></urlset>')]], /noindex/);
caught('sitemapista puuttuu indeksoitava artikkeli', P(), false, [['sitemap.xml', (x) => x.replace(/<url><loc>https:\/\/saunotus\.fi\/saunatietoa\/savusauna-lampiaminen\/<\/loc>.*?<\/url>\n?/, '')]], /puuttuu sitemapista/);
caught('sitemap-loc ei vastaa sivua', P(), false, [['sitemap.xml', (x) => x.replace('</urlset>', '<url><loc>https://saunotus.fi/saunatietoa/haamu/</loc><lastmod>2026-10-18</lastmod></url></urlset>')]], /ei vastaa dististä sivua/);
caught('sitemap rikki', P(), false, [['sitemap.xml', (x) => x.replace('</urlset>', '')]], /urlset ei sulkeudu/);
caught('tuotannossa noindex-meta artikkelilla joka on sitemapissa', P(), false, [[ART, (h) => h.replace('<meta name="robots" content="index,follow">', '<meta name="robots" content="noindex,follow">')]], /on noindex/);
caught('testiympäristössä noindex puuttuu', testDist, true, [[ART, (h) => h.replace('<meta name="robots" content="noindex,nofollow">', '')]], /noindex/);
caught('img ilman width/height', P(), false, [[ART, (h) => h.replace(/ width="1200" height="800"/, '')]], /ilman width\/height/);
caught('img ilman alt', P(), false, [[ART, (h) => h.replace(/ alt="Vihta ja vesisanko lauteilla"/, '')]], /ilman alt/);
caught('ohjaussivun kohde puuttuu', P(), false, [['saunatietoa/savusauna-vanha-nimi/index.html', (h) => h.replace('url=/saunatietoa/savusauna-lampiaminen/', 'url=/saunatietoa/ei-ole/')]], /ohjauksen kohdetta ei löydy/);
caught('ohjaussivun canonical väärin', P(), false, [['saunatietoa/savusauna-vanha-nimi/index.html', (h) => h.replace(/<link rel="canonical" href="[^"]*"/, '<link rel="canonical" href="https://saunotus.fi/saunatietoa/savusauna-vanha-nimi/"')]], /canonical/);
caught('tagisivu ilman noindexia', P(), false, [['saunatietoa/tagi/loyly/index.html', (h) => h.replace('<meta name="robots" content="noindex,follow">', '<meta name="robots" content="index,follow">')]], /tagisivun pitää olla noindex/);
caught('og:url ≠ canonical', P(), false, [[ART, (h) => h.replace(/<meta property="og:url" content="[^"]*"/, '<meta property="og:url" content="https://saunotus.fi/x/"')]], /og:url/);
caught('vanhan EN-polun ohjaus osoittaa olemattomaan sivuun', P(), false, [['en/sauna-guide/index.html', (h) => h.replace('url=/en/sauna-knowledge/', 'url=/en/sauna-knowledge/ei-ole/')]], /ohjauksen kohdetta ei löydy/);
caught('vanha EN-polku ei ole ohjaus vaan sivu', P(), false, [['en/sauna-guide/index.html', (h) => h.replace(/<meta http-equiv="refresh"[^>]*>/, '')]], /vanha osion polku/);
caught('CTA puuttuu', P(), false, [[ART, (h) => h.replace(/<aside class="article-cta">.*?<\/aside>/s, '')]], /CTA/);
caught('navigaatiolinkki puuttuu', P(), false, [['index.html', (h) => h.replace(/<a href="\/saunatietoa\/">Saunatietoa<\/a>/g, '')]], /navigaatiosta puuttuu/);

// ---- vikasietoisuus ja tyhjä tila (koko rakennus) ----
test('tyhjä lista: rakennus onnistuu, siisti tyhjä tila, noindex, ei navigaatiolinkkiä, ei sitemap-rivejä; tarkistus läpi', () => {
  const { dist } = build('empty', { ARTICLES_FIXTURE: join(root, 'tests/articles/fixtures/rpc-empty.json') });
  const r = check(dist, false);
  assert.deepEqual(r.errors, []);
  assert.deepEqual(r.stats, { pages: 3, articles: 0, redirects: 1, lists: 2 });
  assert.doesNotMatch(read(dist, 'index.html'), /saunatietoa/);
  assert.doesNotMatch(read(dist, 'sitemap.xml'), /saunatietoa|sauna-knowledge|sauna-guide/);
  assert.match(read(dist, 'saunatietoa/index.html'), /Artikkeleita ei ole vielä julkaistu/);
});
test('RPC ei vastaa (yhteys evätty): rakennus EI kaadu, varoitus, tuontitiedoston artikkelit mukana', () => {
  const { dist, out } = build('down', { BOOKING_SUPABASE_URL: 'http://localhost:9', BOOKING_ANON_KEY: 'sb_publishable_testi', SITE_ENV: 'test' });
  assert.match(out, /VAROITUS[\s\S]*RPC public_list_articles/);
  assert.deepEqual(check(dist, true).errors, []);
});
test('ARTICLES_STRICT=1: RPC-vika kaataa rakennuksen', () => {
  const r = spawnSync('node', ['scripts/build.mjs'], { cwd: root, encoding: 'utf8', env: { PATH: process.env.PATH, DIST: join(work, 'strict'), ARTICLES_CACHE_DIR: join(work, 'c-strict'), ARTICLES_STATE_FILE: join(work, 'st.json'), BOOKING_SUPABASE_URL: 'http://localhost:9', BOOKING_ANON_KEY: 'sb_publishable_testi', ARTICLES_STRICT: '1' } });
  assert.notEqual(r.status, 0);
});
test('service_role/sb_secret-avain hylätään rakennuksessa (ei salaisuuksia)', () => {
  const r = spawnSync('node', ['scripts/build.mjs'], { cwd: root, encoding: 'utf8', env: { PATH: process.env.PATH, DIST: join(work, 'secret'), ARTICLES_CACHE_DIR: join(work, 'c-secret'), ARTICLES_STATE_FILE: join(work, 'st2.json'), BOOKING_SUPABASE_URL: 'https://abc.supabase.co', BOOKING_ANON_KEY: 'sb_secret_xyz' } });
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /sb_secret/);
});
test('rakennetuissa tiedostoissa ei salaisuuksia', () => {
  for (const d of [testDist, prodDist]) for (const f of ['saunatietoa/index.html', ART, 'sitemap.xml']) assert.doesNotMatch(read(d, f), /sb_secret_|service_role/);
});
