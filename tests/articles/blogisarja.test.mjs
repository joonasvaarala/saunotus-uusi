// Blogisarjan kuusi artikkelia: tuontitiedosto, ei fixture-sekoitusta, SEO, FAQ, kuvat, CTA.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

delete process.env.SITE_ENV;
process.env.SITE_URL = 'https://saunotus.fi';

const { readPending, mergePendingArticles } = await import('../../src/articles/pending.mjs');
const { emptyData } = await import('../../src/articles/source.mjs');
const { buildArticleSite } = await import('../../src/articles/pages.mjs');
const { parsePage } = await import('../../scripts/check-articles.mjs');
const { loadForBuild } = await import('../../src/articles/index.mjs');

const pending = readPending();
const quiet = { warn() {}, log() {} };
const faqCount = {
  'saunavuoro-kun-aika-katoaa': 2,
  'savusaunan-noki': 2,
  'aito-savusauna': 2,
  'savusaunan-loyly': 3,
  'yleinen-savusauna-ja-tila-hiljaisuudelle': 3,
  'saunominen-ja-itsearvostus': 2,
};
const frontPageAuthor = new Set(['savusaunan-noki', 'aito-savusauna', 'savusaunan-loyly']);

function built() {
  const data = emptyData();
  mergePendingArticles(data, quiet, pending);
  const w = console.warn; console.warn = () => {};
  let r;
  try { r = buildArticleSite(data, new Map()); } finally { console.warn = w; }
  return { data, r };
}

test('tuontitiedossa on kuusi artikkelia rajoissa, ilman raakaa HTML:ää', () => {
  assert.equal(pending.articles.length, 6);
  for (const a of pending.articles) {
    const u = a.upsert;
    assert.match(u.slug_fi, /^[a-z0-9]+(?:-[a-z0-9]+)*$/);
    assert.ok(u.title_fi.length <= 120 && u.meta_title_fi.length <= 70 && u.meta_description_fi.length <= 170 && u.summary_fi.length <= 300);
    assert.equal(u.author_name, 'Otto Kronqvist');
    assert.equal(u.featured, false);
    assert.ok(u.tags.length <= 10 && u.tags.every((t) => t.length <= 40 && t === t.toLowerCase()));
    assert.doesNotMatch(u.content_fi, /<[A-Za-z/!?]|instagram\.com/i);
    assert.match(u.content_fi, /\[Varaa saunavuoro\]\(\/varaa\/\)/);
    assert.equal(a.source_url.startsWith('https://www.instagram.com/'), true);
    assert.equal(u.content_fi.includes(a.source_url), false);
    const hero = a.images.find((i) => i.role === 'hero');
    assert.equal(hero.file, `${u.slug_fi}-hero.jpg`);
    assert.equal(hero.webp, `${u.slug_fi}-hero.webp`);
    assert.equal(hero.width, 1600);
    assert.ok(hero.alt_fi.length > 20 && hero.alt_fi.length <= 200);
    const inline = a.images.find((i) => i.role === 'inline');
    if (u.slug_fi === 'savusaunan-loyly') assert.equal(inline, undefined);
    else {
      assert.equal(inline.file, `${u.slug_fi}-2.jpg`);
      assert.equal(inline.webp, `${u.slug_fi}-2.webp`);
    }
  }
});

test('sivut: SEO-otsikko, canonical, FAQ, kirjoittaja, CTA, kuvat ja sisäiset linkit', () => {
  const { r } = built();
  const list = r.pages.find((p) => p.path === '/saunatietoa/');
  assert.equal(list.kind, 'list');
  for (const a of pending.articles) {
    const slug = a.upsert.slug_fi;
    const page = r.pages.find((p) => p.path === `/saunatietoa/${slug}/`);
    assert.equal(page.kind, 'article');
    assert.equal(page.canonical, `https://saunotus.fi/saunatietoa/${slug}/`);
    const parsed = parsePage(page.html);
    assert.equal(parsed.title, a.upsert.meta_title_fi);
    assert.equal(parsed.description, a.upsert.meta_description_fi);
    assert.deepEqual(parsed.canonicals, [`https://saunotus.fi/saunatietoa/${slug}/`]);
    assert.equal(parsed.og['og:image'], `https://saunotus.fi/img/articles/${slug}-hero.webp`);
    assert.equal(parsed.og['og:image:width'], '1600');
    assert.equal(parsed.og['og:image:alt'], a.images[0].alt_fi);
    assert.equal(parsed.twitterCard, 'summary_large_image');
    const lds = parsed.ld.map((j) => JSON.parse(j));
    const article = lds.find((x) => x['@type'] === 'Article');
    const faq = lds.find((x) => x['@type'] === 'FAQPage');
    assert.equal(article.headline, a.upsert.title_fi);
    assert.deepEqual(article.author, { '@type': 'Person', name: 'Otto Kronqvist' });
    assert.equal(article.publisher.name, 'Sipoonjoen perinnesauna');
    assert.equal(article.publisher['@type'], 'Organization');
    assert.deepEqual(article.image, [`https://saunotus.fi/img/articles/${slug}-hero.webp`]);
    assert.equal(faq['@id'], `https://saunotus.fi/saunatietoa/${slug}/#usein-kysyttya`);
    assert.equal(faq.mainEntity.length, faqCount[slug]);
    assert.match(page.html, new RegExp(`<h1>${a.upsert.title_fi.replace(/[?]/g, '\\?')}</h1>`));
    assert.match(page.html, /<aside class="article-author">/);
    assert.match(page.html, /<h2 id="otto-kronqvist">Otto Kronqvist<\/h2>/);
    assert.match(page.html, /<a class="btn gold" href="\/varaa\/">Varaa saunavuoro<\/a>/);
    const articleHtml = page.html.slice(page.html.indexOf('<article'), page.html.indexOf('</article>'));
    assert.equal(articleHtml.includes('instagram.com'), false);
    assert.match(list.html, new RegExp(a.upsert.title_fi.replace(/[?]/g, '\\?')));
    const heroAlt = a.images[0].alt_fi.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    assert.match(page.html, new RegExp(`<figure class="art-hero"><picture><source type="image/webp" srcset="/img/articles/${slug}-hero\\.webp" sizes="[^"]*"><img src="/img/articles/${slug}-hero\\.jpg" width="1600" height="\\d+" alt="${heroAlt}" fetchpriority="high"`));
    const inline = a.images.find((i) => i.role === 'inline');
    if (!inline) {
      assert.doesNotMatch(page.html, /-2\.(jpg|webp)/);
    } else {
      const alt = inline.alt_fi.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      assert.match(page.html, new RegExp(`<figure class="art-fig"><picture><source type="image/webp" srcset="/img/articles/${slug}-2\\.webp" sizes="[^"]*"><img src="/img/articles/${slug}-2\\.jpg" width="1600" height="\\d+" alt="${alt}" loading="lazy"`));
      const imgAt = page.html.indexOf(`${slug}-2.jpg`);
      const faqAt = page.html.indexOf('id="usein-kysyttya"');
      const h2At = page.html.indexOf('<h2');
      assert.ok(h2At >= 0 && imgAt > h2At && imgAt < faqAt, slug);
    }
    assert.match(page.html, /href="\/saunatietoa\/[a-z0-9-]+\/"/);
    if (frontPageAuthor.has(slug)) assert.match(page.html, /<aside class="article-author">[\s\S]*href="\/"/);
    else assert.match(page.html, /href="\/varaa\/"/);
  }
  for (const slug of Object.keys(faqCount)) assert.ok(r.sitemap.some((u) => u.loc === `https://saunotus.fi/saunatietoa/${slug}/`));
});

test('tuonti ei kahdenna slugia, ja fixture-rakennus ei sisällä blogisarjaa', async () => {
  const data = emptyData();
  data.lang.fi.items.push({ lang: 'fi', slug: 'vanha', card: { slug: 'vanha', title: 'Vanha', featured: true, published_at: '2020-01-01T00:00:00.000Z', tags: [] }, article: { content_md: 'x', title: 'Vanha', images: [] }, seo: { title: 'Vanha', json_ld: {} } });
  mergePendingArticles(data, quiet, pending);
  assert.equal(data.lang.fi.items[0].slug, 'vanha');
  assert.equal(data.lang.fi.items.filter((it) => it.slug === 'saunavuoro-kun-aika-katoaa').length, 1);
  const n = data.lang.fi.items.length;
  mergePendingArticles(data, quiet, pending);
  assert.equal(data.lang.fi.items.length, n);
  const dir = mkdtempSync(join(tmpdir(), 'art-'));
  const fx = await loadForBuild({ ARTICLES_FIXTURE: '1', ARTICLES_CACHE_DIR: dir }, quiet);
  assert.equal(fx.lang.fi.items.some((it) => it.slug === 'saunavuoro-kun-aika-katoaa'), false);
});
