// Sisältöosion rakennusvaiheen sisäänkäynti: hakee artikkelit (RPC / fixture / välimuisti), valmistelee kuvat, renderöi sivut.
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';
import { cfg, LANGS, listPath } from './config.mjs';
import { abs, href, isTest } from '../lib.mjs';
import * as R from '../render.mjs';
import { loadArticles, makeRpc, makeFixtureRpc, readCommittedSlugs } from './source.mjs';
import { prepareImages, makeFetchImage } from './images.mjs';
import { buildArticleSite, homeSectionHtml } from './pages.mjs';
import { setArticlesState, setHomeSections } from './runtime.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export const FIXTURE_DEFAULT = join(root, 'tests/articles/fixtures/rpc.json');
export const FIXTURE_IMAGES = join(root, 'tests/articles/fixtures/images');
export const HOME_PREVIEW_FIXTURE = join(root, 'tests/articles/fixtures/home-preview.json');

/** Vaihe 1 (ennen perussivujen renderöintiä, koska navigaatiolinkki riippuu artikkeleista): hae data ja aseta tila. */
export async function loadForBuild(env = process.env, log = console) {
  const fx = env.ARTICLES_FIXTURE && env.ARTICLES_FIXTURE !== '0' ? (env.ARTICLES_FIXTURE === '1' ? FIXTURE_DEFAULT : resolve(env.ARTICLES_FIXTURE)) : null;
  const url = (env.BOOKING_SUPABASE_URL || '').trim(), key = (env.BOOKING_ANON_KEY || '').trim();
  let rpc = null;
  let fixtureKnown = [];
  if (fx) { const j = JSON.parse(readFileSync(fx, 'utf8')); rpc = makeFixtureRpc(j); fixtureKnown = j.known || []; }
  else if (url && key) {
    if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url) && !/^http:\/\/localhost(:\d+)?$/.test(url)) throw new Error('BOOKING_SUPABASE_URL: odotetaan https://<ref>.supabase.co');
    rpc = makeRpc({ url, key });
  }
  const baseCache = env.ARTICLES_CACHE_DIR ? resolve(env.ARTICLES_CACHE_DIR) : join(root, '.cache/articles');
  const cacheDir = fx ? join(baseCache, 'fixture') : baseCache;
  const data = await loadArticles({ rpc, cacheDir, committedSlugs: [...readCommittedSlugs(join(root, 'content/articles-slugs.json')), ...fixtureKnown], strict: env.ARTICLES_STRICT === '1', log });
  data.cacheDir = cacheDir; data.fixture = !!fx;
  if (fx && data.source === 'rpc') data.source = 'fixture';
  setArticlesState({ count: { fi: data.lang.fi.items.length, en: data.lang.en.items.length }, source: data.source });
  return data;
}

/** Vaihe 2: kuvat + sivut hakemistoon out. Palauttaa sitemap-rivit. */
export async function renderForBuild(data, out, { write, env = process.env, log = console }) {
  const images = [];
  for (const L of LANGS) for (const it of data.lang[L].items) { if (it.card.image) images.push(it.card.image); images.push(...(it.article.images || [])); if (it.seo?.og_image) images.push(it.seo.og_image); }
  const variants = env.ARTICLES_IMAGES === '0' ? new Map() : await prepareImages({ images, outDir: out, cacheDir: data.cacheDir, widths: cfg.widths, fetchImage: makeFetchImage({ fixtureDir: FIXTURE_IMAGES }), log });
  const r = buildArticleSite(data, variants);
  // Etusivun osio (esirenderöity, kieli sivun mukaan). Epäonnistuminen tai 0 artikkelia → osio pois; rakennus ei kaadu.
  const home = { fi: '', en: '' };
  for (const L of LANGS) {
    try { home[L] = homeSectionHtml(data.lang[L].items, L, variants); }
    catch (err) { log.warn?.(`articles: VAROITUS: etusivun artikkeliosion (${L}) renderöinti epäonnistui (${err.message}); osio jätetään pois`); }
  }
  setHomeSections(home);
  r.home = { fi: !!home.fi, en: !!home.en };
  for (const p of r.pages) write(p.path, p.html);
  log.log?.(`articles: etusivun osio FI ${home.fi ? 'näkyy' : 'piilossa'}, EN ${home.en ? 'näkyy' : 'piilossa'}`);
  log.log?.(`articles: ${data.source}; FI ${r.counts.fi}, EN ${r.counts.en} artikkelia, ${r.counts.redirects} ohjaussivua, ${r.counts.pages} sivua, kuvaversiot ${variants.size}`);
  return { ...r, variants };
}

/**
 * Esikatselusivut (vain testisivustolla, SITE_ENV=test): koko etusivu feikkiartikkeleilla (tests/articles/fixtures/home-preview.json), noindex, ei sitemapissa, ei linkitettyä.
 * Tuotantobuildissa (SITE_ENV != test) ei luoda mitään. Kortit linkittävät '#' (feikkiartikkeleilla ei ole sivuja).
 */
export async function renderHomePreview(out, { write, env = process.env, log = console, cacheDir = null } = {}) {
  if (!isTest || !cfg.home?.preview) return [];
  const fx = JSON.parse(readFileSync(HOME_PREVIEW_FIXTURE, 'utf8'));
  const images = LANGS.flatMap((L) => fx[L].map((c) => c.image).filter(Boolean));
  const variants = env.ARTICLES_IMAGES === '0' ? new Map() : await prepareImages({ images, outDir: out, cacheDir, widths: cfg.widths, fetchImage: makeFetchImage({ fixtureDir: FIXTURE_IMAGES }), log });
  const paths = [];
  for (const L of LANGS) {
    const o = L === 'fi' ? 'en' : 'fi';
    const html = homeSectionHtml(fx[L].map((card) => ({ lang: L, slug: card.slug, card })), L, variants, { linkFor: () => '#' });
    const p = cfg.home.preview[L];
    const page = R.home(L, {
      articlesHtml: html, previewNote: cfg.home.previewNote[L],
      meta: { ...R.homeMeta(L), title: `${cfg.home.previewNote[L].split(':')[0]}: ${R.homeMeta(L).title}`, description: cfg.home.previewNote[L] },
      seo: { url: abs(p), hreflangs: [], robots: 'noindex,nofollow', switchHref: href(cfg.home.preview[o]) },
    });
    write(p, page); paths.push(p);
  }
  log.log?.(`articles: esikatselusivut ${paths.join(', ')}`);
  return paths;
}
