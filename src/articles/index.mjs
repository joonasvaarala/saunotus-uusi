// Sisältöosion rakennusvaiheen sisäänkäynti: hakee artikkelit (RPC / fixture / välimuisti), valmistelee kuvat, renderöi sivut.
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';
import { cfg, LANGS } from './config.mjs';
import { loadArticles, makeRpc, makeFixtureRpc, readCommittedSlugs } from './source.mjs';
import { prepareImages, makeFetchImage } from './images.mjs';
import { buildArticleSite } from './pages.mjs';
import { setArticlesState } from './runtime.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export const FIXTURE_DEFAULT = join(root, 'tests/articles/fixtures/rpc.json');
export const FIXTURE_IMAGES = join(root, 'tests/articles/fixtures/images');

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
  for (const p of r.pages) write(p.path, p.html);
  log.log?.(`articles: ${data.source}; FI ${r.counts.fi}, EN ${r.counts.en} artikkelia, ${r.counts.redirects} ohjaussivua, ${r.counts.pages} sivua, kuvaversiot ${variants.size}`);
  return { ...r, variants };
}
