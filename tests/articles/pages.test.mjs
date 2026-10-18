// Sivujen muodostus (yksikkötesti, ilman tiedostoja): osoitteet, canonical, hreflang, JSON-LD, sitemap, tyhjä tila, ohjaus
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

delete process.env.SITE_ENV; process.env.SITE_URL = 'https://uusi.saunotus.com';
const { buildArticleSite } = await import('../../src/articles/pages.mjs');
const { loadArticles, makeFixtureRpc, emptyData } = await import('../../src/articles/source.mjs');
const { parsePage } = await import('../../scripts/check-articles.mjs');
const { tagSlug, cfg } = await import('../../src/articles/config.mjs');

const fx = JSON.parse(readFileSync(new URL('./fixtures/rpc.json', import.meta.url), 'utf8'));
const quiet = { warn() {}, log() {} };
const load = (f = fx) => loadArticles({ rpc: makeFixtureRpc(f), log: quiet, committedSlugs: f.known || [] });
const quietWarn = async (fn) => { const w = console.warn; console.warn = () => {}; try { return await fn(); } finally { console.warn = w; } };
const build = async (data, variants = new Map()) => quietWarn(() => buildArticleSite(data, variants));
const page = (r, path) => r.pages.find((p) => p.path === path);

test('asetukset: nimi ja polut yhdessä tiedostossa (FI Saunatietoa, EN Sauna guide)', () => {
  assert.equal(cfg.label.fi, 'Saunatietoa'); assert.equal(cfg.label.en, 'Sauna guide');
  assert.equal(cfg.path.fi, '/saunatietoa/'); assert.equal(cfg.path.en, '/en/sauna-guide/');
});
test('tagSlug: diakriitit pois, ASCII, ei tyhjää', () => {
  assert.equal(tagSlug('löyly'), 'loyly'); assert.equal(tagSlug('Åbo Äiti'), 'abo-aiti'); assert.equal(tagSlug('!!!'), 'x');
});

test('osoitteet lasketaan repon asetuksista, ei tietokannan polusta (/en/sauna-knowledge/ → /en/sauna-guide/)', async () => {
  const r = await build(await load());
  const paths = r.pages.map((p) => p.path);
  assert.ok(paths.includes('/en/sauna-guide/how-to-sauna/'));
  assert.ok(!paths.some((p) => p.includes('sauna-knowledge')));
  assert.ok(paths.includes('/saunatietoa/miten-saunotaan-oikein/'));
  const html = page(r, '/en/sauna-guide/how-to-sauna/').html;
  assert.doesNotMatch(html, /sauna-knowledge/);
  assert.match(html, /<link rel="canonical" href="https:\/\/uusi\.saunotus\.com\/en\/sauna-guide\/how-to-sauna\/">/);
});
test('hreflang: itseviittaus + toinen kieli + x-default (=fi) vain kun molemmat kielet; yksikielisellä ei hreflangeja', async () => {
  const r = await build(await load());
  const both = parsePage(page(r, '/saunatietoa/miten-saunotaan-oikein/').html).hreflangs;
  assert.deepEqual(both, [
    { hreflang: 'fi', href: 'https://uusi.saunotus.com/saunatietoa/miten-saunotaan-oikein/' },
    { hreflang: 'en', href: 'https://uusi.saunotus.com/en/sauna-guide/how-to-sauna/' },
    { hreflang: 'x-default', href: 'https://uusi.saunotus.com/saunatietoa/miten-saunotaan-oikein/' },
  ]);
  assert.deepEqual(parsePage(page(r, '/saunatietoa/savusauna-lampiaminen/').html).hreflangs, []);
});
test('hreflang jätetään pois jos toista kieliversiota ei ole julkaistu (EN-lista tyhjä)', async () => {
  const d = await load();
  d.lang.en.items = [];
  const r = await build(d);
  assert.deepEqual(parsePage(page(r, '/saunatietoa/miten-saunotaan-oikein/').html).hreflangs, []);
  assert.doesNotMatch(page(r, '/saunatietoa/miten-saunotaan-oikein/').html, /sauna-guide/);
});
test('JSON-LD: Article + BreadcrumbList, URL:t tämän ympäristön osoitteita, </script> ei pääse vuotamaan', async () => {
  const d = await load();
  const it = d.lang.fi.items.find((x) => x.slug === 'miten-saunotaan-oikein');
  it.seo.json_ld.headline = 'Otsikko </script><script>alert(1)</script>';
  const r = await build(d);
  const html = page(r, '/saunatietoa/miten-saunotaan-oikein/').html;
  assert.doesNotMatch(html, /<script>alert/);
  const p = parsePage(html);
  const lds = p.ld.map((j) => JSON.parse(j));
  const a = lds.find((x) => x['@type'] === 'Article');
  assert.equal(a.mainEntityOfPage['@id'], 'https://uusi.saunotus.com/saunatietoa/miten-saunotaan-oikein/');
  assert.equal(a.publisher.url, 'https://uusi.saunotus.com/');
  assert.equal(a.headline.startsWith('Otsikko </script>'), true);
  const b = lds.find((x) => x['@type'] === 'BreadcrumbList');
  assert.deepEqual(b.itemListElement.map((x) => x.position), [1, 2, 3]);
  assert.equal(b.itemListElement[1].item, 'https://uusi.saunotus.com/saunatietoa/');
});
test('canonical-ohitus (oma canonical_fi) säilyy, hreflang pois, ei sitemapissa', async () => {
  const d = await load();
  const it = d.lang.fi.items.find((x) => x.slug === 'miten-saunotaan-oikein');
  it.seo.canonical = 'https://muu.example/alkuperainen/';
  d.sitemap = d.sitemap.filter((s) => s.slug !== 'miten-saunotaan-oikein');
  const r = await build(d);
  const p = parsePage(page(r, '/saunatietoa/miten-saunotaan-oikein/').html);
  assert.deepEqual(p.canonicals, ['https://muu.example/alkuperainen/']);
  assert.deepEqual(p.hreflangs, []);
  assert.ok(!r.sitemap.some((s) => s.loc.includes('miten-saunotaan-oikein')));
});
test('sitemap: vain indeksoitavat (noindex pois), listaukset mukana, alternates vain kaksikielisille', async () => {
  const r = await build(await load());
  const locs = r.sitemap.map((s) => s.loc);
  assert.ok(locs.includes('https://uusi.saunotus.com/saunatietoa/'));
  assert.ok(locs.includes('https://uusi.saunotus.com/en/sauna-guide/'));
  assert.ok(!locs.some((l) => l.includes('noindex-testiartikkeli')));
  assert.ok(!locs.some((l) => l.includes('/tagi/') || l.includes('vanha-nimi')));
  assert.equal(r.sitemap.find((s) => s.loc.endsWith('savusauna-lampiaminen/')).alternates.length, 0);
  assert.equal(r.sitemap.find((s) => s.loc.endsWith('how-to-sauna/')).alternates.length, 3);
  for (const s of r.sitemap) assert.match(s.lastmod, /^\d{4}-\d{2}-\d{2}$/);
});
test('robots: noindex-artikkeli ja tagisivut noindex,follow; normaali artikkeli index,follow', async () => {
  const r = await build(await load());
  const rb = (path) => parsePage(page(r, path).html).robots;
  assert.deepEqual(rb('/saunatietoa/noindex-testiartikkeli/'), ['noindex,follow']);
  assert.deepEqual(rb('/saunatietoa/miten-saunotaan-oikein/'), ['index,follow']);
  assert.deepEqual(rb('/saunatietoa/tagi/loyly/'), ['noindex,follow']);
  assert.deepEqual(rb('/saunatietoa/'), ['index,follow']);
});
test('moved-slug: ohjaussivu meta refresh + canonical kohteeseen; kohde puuttuu → ei sivua', async () => {
  const r = await build(await load());
  const p = parsePage(page(r, '/saunatietoa/savusauna-vanha-nimi/').html);
  assert.deepEqual(p.refresh, ['0; url=/saunatietoa/savusauna-lampiaminen/']);
  assert.deepEqual(p.canonicals, ['https://uusi.saunotus.com/saunatietoa/savusauna-lampiaminen/']);
  const d = await load();
  d.lang.fi.items = d.lang.fi.items.filter((x) => x.slug !== 'savusauna-lampiaminen');
  const r2 = await build(d);
  assert.equal(page(r2, '/saunatietoa/savusauna-vanha-nimi/'), undefined);
});
test('tyhjä lista: FI/EN-listaus siisti tyhjä tila, noindex, ei sitemapissa, ei artikkelisivuja', async () => {
  const r = await build(emptyData());
  assert.deepEqual(r.pages.map((p) => p.path).sort(), ['/en/sauna-guide/', '/saunatietoa/']);
  assert.equal(r.sitemap.length, 0);
  for (const pg of r.pages) {
    const p = parsePage(pg.html);
    assert.deepEqual(p.robots, ['noindex,follow']);
    assert.match(pg.html, /class="art-empty"/);
    assert.equal(p.h1, 1);
  }
  assert.match(page(r, '/en/sauna-guide/').html, /No articles have been published yet/);
});
test('sivutus: pageSize ylittyessä /sivu/2/ canonical itseensä, ei sitemapissa; tagisivut omilla poluillaan', async () => {
  const d = await load();
  const base = d.lang.fi.items[0];
  d.lang.fi.items = Array.from({ length: cfg.pageSize + 3 }, (_, i) => ({ ...base, slug: `s-${i}`, card: { ...base.card, slug: `s-${i}`, tags: ['sauna'] }, article: { ...base.article, slug: `s-${i}`, alternates: [] } }));
  const r = await build(d);
  const p2 = page(r, '/saunatietoa/sivu/2/');
  assert.ok(p2);
  assert.deepEqual(parsePage(p2.html).canonicals, ['https://uusi.saunotus.com/saunatietoa/sivu/2/']);
  assert.match(page(r, '/saunatietoa/').html, /rel="next" href="\/saunatietoa\/sivu\/2\/"/);
  assert.ok(page(r, '/saunatietoa/tagi/sauna/sivu/2/'));
  assert.ok(!r.sitemap.some((s) => s.loc.includes('/sivu/')));
});
test('kuvat: width/height/alt aina, pääkuva eager + fetchpriority, muut lazy; srcset kun variantit olemassa, muuten alkuperäinen URL', async () => {
  const d = await load();
  const hero = d.lang.fi.items[0].article.image;
  const variants = new Map([[hero.url, { id: 'abc123', widths: [480, 800] }]]);
  const r = await build(d, variants);
  const html = page(r, '/saunatietoa/miten-saunotaan-oikein/').html;
  const imgs = parsePage(html).imgs;
  assert.ok(imgs.length >= 3);
  for (const im of imgs.filter((i) => !/favicon|ikoni/.test(i))) assert.match(im, /width="\d+" height="\d+" alt="[^"]+"|alt="" /);
  assert.match(html, /srcset="\/img\/articles\/abc123-480\.avif 480w, \/img\/articles\/abc123-800\.avif 800w"/);
  assert.match(imgs[imgs.findIndex((i) => /abc123/.test(i))] || '', /fetchpriority="high"/);
  assert.match(html, /<img src="https:\/\/fixture\.example\/[^"]+" width="1200" height="800" alt="Vihta ja vesisanko lauteilla" loading="lazy" decoding="async">/);
});
test('CTA: artikkelin oma :::cta renderöityy; oletus-CTA lisätään kun lohkoa ei ole', async () => {
  const r = await build(await load());
  assert.equal((page(r, '/saunatietoa/miten-saunotaan-oikein/').html.match(/class="article-cta"/g) || []).length, 1);
  assert.match(page(r, '/saunatietoa/miten-saunotaan-oikein/').html, /<a class="btn gold" href="\/varaa\/">Varaa aika<\/a>/);
  assert.match(page(r, '/saunatietoa/savusauna-lampiaminen/').html, /class="article-cta"[\s\S]*href="\/varaa\/"/);
  assert.match(page(r, '/en/sauna-guide/how-to-sauna/').html, /href="\/en\/book\/">Book now<\/a>/);
});
test('varoitus kun tietokannan polku/nimi poikkeaa repon asetuksesta', async () => {
  const r = await build(await load());
  assert.ok(r.warnings.some((w) => /articles_path_en/.test(w)));
  assert.ok(r.warnings.some((w) => /articles_label_en/.test(w)));
});
test('listaus: kortit linkittävät artikkeleihin kuvaavalla ankkuritekstillä; tagit ja luettelo ovat saavutettavia', async () => {
  const r = await build(await load());
  const html = page(r, '/saunatietoa/').html;
  assert.match(html, /<h2><a href="\/saunatietoa\/miten-saunotaan-oikein\/">Miten saunotaan oikein\? Perinteinen opas<\/a><\/h2>/);
  assert.match(html, /<nav class="tagbar" aria-label="Aiheet"><ul><li><a href="\/saunatietoa\/" aria-current="page">Kaikki<\/a>/);
  assert.match(html, /<nav class="crumbs" aria-label="Murupolku">/);
});
test('kielenvaihto: artikkelilla vastine → vastine; ilman vastinetta → toisen kielen listaus (jos artikkeleita) tai etusivu', async () => {
  const r = await build(await load());
  assert.match(page(r, '/saunatietoa/miten-saunotaan-oikein/').html, /<a href="\/en\/sauna-guide\/how-to-sauna\/" hreflang="en" lang="en">EN<\/a>/);
  assert.match(page(r, '/saunatietoa/savusauna-lampiaminen/').html, /<a href="\/en\/sauna-guide\/" hreflang="en" lang="en">EN<\/a>/);
});
