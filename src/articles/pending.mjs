// Tuontitiedosto content/articles.pending-import-blogisarja.json: artikkelit, joita ei vielä ole julkisessa RPC:ssä.
// Rakennus näyttää ne, kunnes slug löytyy tietokannasta. Sen jälkeen tietokannan teksti voittaa.
// Paikkakuvat: content/article-images/<tiedosto>. Tiedosto korvaa RPC:n pääkuvan niin kauan kuin se on olemassa.
// Tietokantaan ei kirjoiteta täältä. Tuonnin tekee ylläpitäjä (ks. tiedoston _doc ja docs/SAUNATIETOA.md).
import { readFileSync, existsSync, readdirSync, mkdirSync, copyFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export const PENDING_FILE = join(root, 'content/articles.pending-import-blogisarja.json');
export const IMAGE_DIR = join(root, 'content/article-images');

export function readPending(file = PENDING_FILE) {
  if (!existsSync(file)) return { articles: [] };
  const j = JSON.parse(readFileSync(file, 'utf8'));
  return { ...j, articles: Array.isArray(j.articles) ? j.articles : [] };
}

function jpegSize(buf) {
  if (buf.length < 4 || buf[0] !== 0xff || buf[1] !== 0xd8) return null;
  let i = 2;
  while (i + 8 < buf.length) {
    if (buf[i] !== 0xff) { i++; continue; }
    const marker = buf[i + 1];
    if (marker === 0xd8 || marker === 0x01) { i += 2; continue; }
    if (marker === 0xd9 || marker === 0xda) break;
    const len = buf.readUInt16BE(i + 2);
    const sof = (marker >= 0xc0 && marker <= 0xc3) || (marker >= 0xc5 && marker <= 0xc7) || (marker >= 0xc9 && marker <= 0xcb) || (marker >= 0xcd && marker <= 0xcf);
    if (sof) return { height: buf.readUInt16BE(i + 5), width: buf.readUInt16BE(i + 7) };
    i += 2 + len;
  }
  return null;
}

const safeName = (s) => typeof s === 'string' && s && !/[\\/]/.test(s) && !s.includes('..');

function imageRecord(spec) {
  if (!safeName(spec?.file)) return null;
  const path = join(IMAGE_DIR, spec.file);
  if (!existsSync(path)) return null;
  const dim = jpegSize(readFileSync(path));
  const width = dim?.width || spec.width;
  const height = dim?.height || spec.height;
  if (!(width > 0) || !(height > 0)) return null;
  const webp = safeName(spec.webp) && existsSync(join(IMAGE_DIR, spec.webp)) ? spec.webp : null;
  return {
    url: `https://fixture.example/article-images/${spec.file}`,
    alt: spec.alt_fi || '',
    width, height, caption: null,
    pair: webp ? { jpg: spec.file, webp } : null,
  };
}

/** Kopioi content/article-images/*.jpg|*.webp → <out>/img/articles/ (sama nimi). Sharpin muunnelmat käyttävät eri tiedostonimeä. */
export function copyLocalArticleImages(outDir, dir = IMAGE_DIR) {
  if (!existsSync(dir)) return [];
  const dest = join(outDir, 'img', 'articles');
  mkdirSync(dest, { recursive: true });
  const copied = [];
  for (const name of readdirSync(dir)) {
    if (!safeName(name) || !/\.(jpe?g|webp)$/i.test(name)) continue;
    copyFileSync(join(dir, name), join(dest, name));
    copied.push(name);
  }
  return copied;
}

function specsFor(slug, pending) {
  const a = pending.articles.find((x) => x?.upsert?.slug_fi === slug);
  const images = a?.images || [];
  return { hero: images.find((i) => i.role === 'hero') || null, inline: images.find((i) => i.role === 'inline') || null };
}

/** Korvaa kortin, pääkuvan ja og-kuvan paikallisella tiedostolla. Asettaa it.localInline, jos välikuva (<slug>-2) on kuvattu. */
export function applyLocalImages(data, pending = readPending()) {
  for (const it of data.lang?.fi?.items || []) {
    const { hero, inline } = specsFor(it.slug, pending);
    const heroIm = imageRecord(hero);
    const inlineIm = imageRecord(inline);
    if (heroIm) {
      it.card.image = heroIm;
      it.article.image = heroIm;
      if (it.seo) it.seo.og_image = heroIm;
    }
    if (inlineIm) it.localInline = inlineIm;
  }
  return data;
}

function readingMinutes(md) {
  const n = String(md || '').trim() ? String(md).trim().split(/\s+/).length : 0;
  return Math.max(1, Math.ceil(n / 200));
}

function toItem(a) {
  const u = a.upsert;
  const published = a.publish_at;
  const card = {
    lang: 'fi', slug: u.slug_fi, tags: u.tags || [], image: null,
    title: u.title_fi, author: u.author_name || null, noindex: !!u.noindex,
    summary: u.summary_fi || '', category: u.category ?? null, featured: !!u.featured,
    alternates: [{ lang: 'fi', slug: u.slug_fi }],
    updated_at: published, published_at: published, reading_minutes: readingMinutes(u.content_fi),
  };
  const article = { ...card, images: [], content_md: u.content_fi };
  const seo = {
    title: u.meta_title_fi || u.title_fi,
    description: u.meta_description_fi || u.summary_fi || '',
    robots: u.noindex ? 'noindex,follow' : 'index,follow',
    og_type: 'article',
    og_image: null,
    canonical: null,
    json_ld: {
      '@context': 'https://schema.org',
      '@type': 'Article',
      headline: String(u.title_fi).slice(0, 110),
      description: u.meta_description_fi || '',
      image: [],
      author: { '@type': 'Person', name: u.author_name || '' },
      publisher: { '@type': 'Organization', name: 'Sipoonjoen perinnesauna' },
      keywords: (u.tags || []).join(', '),
      datePublished: published,
      dateModified: published,
      inLanguage: 'fi',
    },
  };
  return { lang: 'fi', slug: u.slug_fi, card, article, seo };
}

function insertByDate(items, extras) {
  const featured = items.filter((it) => it.card.featured);
  const pool = items.filter((it) => !it.card.featured);
  const sorted = [...extras].sort((a, b) => (Date.parse(b.card.published_at) || 0) - (Date.parse(a.card.published_at) || 0));
  for (const it of sorted) {
    const ts = Date.parse(it.card.published_at) || 0;
    let i = 0;
    while (i < pool.length && (Date.parse(pool[i].card.published_at) || 0) >= ts) i++;
    pool.splice(i, 0, it);
  }
  return [...featured, ...pool];
}

/**
 * Lisää tuontitiedoston artikkelit, joiden slugia ei ole datassa. Kutsu vain kun ARTICLES_FIXTURE ei ole käytössä.
 * @returns {typeof data}
 */
export function mergePendingArticles(data, log = console, pending = readPending()) {
  const have = new Set((data.lang?.fi?.items || []).map((it) => it.slug));
  const extras = [];
  data.sitemap ||= [];
  for (const a of pending.articles) {
    const slug = a?.upsert?.slug_fi;
    if (!slug || have.has(slug)) continue;
    extras.push(toItem(a));
    if (!data.sitemap.some((s) => s.lang === 'fi' && s.slug === slug)) data.sitemap.push({ lang: 'fi', slug, updated_at: a.publish_at, published_at: a.publish_at, alternates: [] });
  }
  if (extras.length) {
    data.lang.fi.items = insertByDate(data.lang.fi.items, extras);
    log.warn?.(`articles: VAROITUS: ${extras.length} artikkelia tiedostosta content/articles.pending-import-blogisarja.json (ei vielä julkisessa RPC:ssä). Tuo tietokantaan ja julkaise; sen jälkeen tietokannan teksti korvaa tiedoston. Paikkakuvat pysyvät, kunnes tiedosto poistetaan kansiosta content/article-images/.`);
  }
  applyLocalImages(data, pending);
  return data;
}
