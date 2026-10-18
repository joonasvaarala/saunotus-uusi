// Artikkelien haku rakennusvaiheessa: Supabasen public_*-RPC:t (anon-avain) → sisäinen tietorakenne.
// Vikasietoisuus: jos RPC ei vastaa, käytetään edellisen onnistuneen haun välimuistia (.cache/articles/snapshot.json), muuten tyhjää listaa + varoitus.
// Rakennus EI kaadu (ellei ARTICLES_STRICT=1). Ei salaisuuksia: vain julkinen anon/publishable-avain; service_role/sb_secret hylätään.
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { LANGS } from './config.mjs';

export function assertPublicKey(k) {
  if (/^sb_secret_/.test(k)) throw new Error('BOOKING_ANON_KEY on sb_secret-avain: vain julkinen avain sallitaan');
  if (k.split('.').length === 3) {
    let role; try { role = JSON.parse(Buffer.from(k.split('.')[1], 'base64url').toString()).role; } catch { throw new Error('BOOKING_ANON_KEY: JWT ei ole luettavissa'); }
    if (role !== 'anon') throw new Error(`BOOKING_ANON_KEY: JWT:n rooli on "${role}", sallittu vain "anon"`);
  } else if (!/^sb_publishable_/.test(k)) throw new Error('BOOKING_ANON_KEY: tuntematon avaintyyppi (odotetaan sb_publishable_… tai anon-JWT)');
}

/** RPC-asiakas: POST {url}/rest/v1/rpc/<nimi>, skeema booking. Heittää vain verkko-/HTTP-virheestä; {ok:false,…} palautetaan sellaisenaan. */
export function makeRpc({ url, key, fetchImpl = fetch, timeoutMs = 15000, retries = 2 }) {
  assertPublicKey(key);
  const base = url.replace(/\/$/, '');
  return async (name, args = {}) => {
    let lastErr;
    for (let a = 0; a <= retries; a++) {
      try {
        const res = await fetchImpl(`${base}/rest/v1/rpc/${name}`, {
          method: 'POST', signal: AbortSignal.timeout(timeoutMs),
          headers: { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json', 'content-profile': 'booking', 'accept-profile': 'booking' },
          body: JSON.stringify(args),
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return await res.json();
      } catch (err) { lastErr = err; if (a < retries) await new Promise((r) => setTimeout(r, 400 * (a + 1))); }
    }
    throw new Error(`RPC ${name}: ${lastErr?.message || lastErr}`);
  };
}

/** Testaus/esikatselu: RPC-vastaukset tiedostosta (sama muoto kuin oikeat vastaukset). Kuvien url on https://fixture.example/… (ks. images.mjs). */
export function makeFixtureRpc(fx) {
  return async (name, args = {}) => {
    if (name === 'public_list_articles') {
      const lang = args.p_lang === 'en' ? 'en' : 'fi', l = fx.list[lang];
      const tag = args.p_tag ? String(args.p_tag).toLowerCase() : null;
      const all = l.items.filter((x) => !tag || x.tags.includes(tag) || (x.category || '').toLowerCase() === tag);
      const limit = Math.min(Math.max(args.p_limit ?? 20, 1), 50), offset = args.p_offset ?? 0;
      return { ...l, total: all.length, limit, offset, tag: args.p_tag ?? null, items: all.slice(offset, offset + limit) };
    }
    if (name === 'public_get_article') return fx.articles[`${args.p_lang || 'fi'}/${args.p_slug}`] || fx.moved?.[`${args.p_lang || 'fi'}/${args.p_slug}`] || { ok: false, code: 'not_found' };
    if (name === 'public_articles_sitemap') return fx.sitemap;
    throw new Error('tuntematon RPC ' + name);
  };
}

const readJson = (f) => { try { return JSON.parse(readFileSync(f, 'utf8')); } catch { return null; } };
const emptyLang = () => ({ items: [], dbPath: null, dbLabel: null });
export const emptyData = (source = 'none', warnings = []) => ({ source, warnings, lang: { fi: emptyLang(), en: emptyLang() }, sitemap: [], redirects: [] });

async function pool(list, n, fn) {
  const res = new Array(list.length); let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, list.length) }, async () => { while (i < list.length) { const k = i++; res[k] = await fn(list[k], k); } }));
  return res;
}

async function listAll(rpc, lang) {
  const items = []; let offset = 0, first = null;
  for (;;) {
    const r = await rpc('public_list_articles', { p_lang: lang, p_limit: 50, p_offset: offset });
    if (!r || r.ok !== true) throw new Error(`public_list_articles(${lang}): ${r?.code || 'virheellinen vastaus'}`);
    first ??= r;
    items.push(...(r.items || []));
    offset += (r.items || []).length;
    if (!r.items?.length || offset >= r.total) break;
  }
  return { items, dbPath: first.path ?? null, dbLabel: first.label ?? null };
}

/**
 * @param {object} o  rpc(name,args) | cacheDir | committedSlugs [{lang,slug}] | strict | log
 * @returns {Promise<ReturnType<typeof emptyData> & {lang:Record<string,{items:{lang:string,slug:string,card:object,article:object,seo:object}[],dbPath:string|null,dbLabel:string|null}>}>}
 */
export async function loadArticles({ rpc, cacheDir, committedSlugs = [], strict = false, log = console }) {
  const snapFile = cacheDir && join(cacheDir, 'snapshot.json');
  const snap = snapFile ? readJson(snapFile) : null;
  const warn = [];
  const w = (m) => { warn.push(m); log.warn?.(`articles: VAROITUS: ${m}`); };
  try {
    if (!rpc) throw new Error('Supabase-asetuksia ei ole (BOOKING_SUPABASE_URL / BOOKING_ANON_KEY): artikkeleita ei haeta');
    const lang = {};
    for (const L of LANGS) {
      const { items, dbPath, dbLabel } = await listAll(rpc, L);
      const entries = (await pool(items, 4, async (card) => {
        try {
          const r = await rpc('public_get_article', { p_slug: card.slug, p_lang: L });
          if (r?.ok !== true) throw new Error(r?.code || 'virheellinen vastaus');
          return { lang: L, slug: card.slug, card, article: r.article, seo: r.seo };
        } catch (err) {
          const old = snap?.lang?.[L]?.items?.find((x) => x.slug === card.slug);
          if (old) { w(`public_get_article(${L}/${card.slug}) epäonnistui (${err.message}); käytetään välimuistia`); return old; }
          w(`public_get_article(${L}/${card.slug}) epäonnistui (${err.message}); artikkeli jätetään pois tästä rakennuksesta`); return null;
        }
      })).filter(Boolean);
      lang[L] = { items: entries, dbPath, dbLabel };
    }
    const live = new Set(LANGS.flatMap((L) => lang[L].items.map((x) => `${L}/${x.slug}`)));

    let sitemap;
    try {
      const s = await rpc('public_articles_sitemap');
      if (s?.ok !== true) throw new Error(s?.code || 'virheellinen vastaus');
      sitemap = s.items || [];
    } catch (err) {
      w(`public_articles_sitemap epäonnistui (${err.message}); sitemap johdetaan artikkelilistasta`);
      sitemap = LANGS.flatMap((L) => lang[L].items.filter((x) => !x.card.noindex).map((x) => ({ lang: L, slug: x.slug, updated_at: x.card.updated_at, published_at: x.card.published_at, alternates: [] })));
    }

    // Uudelleenohjaukset: RPC:illä ei voi listata vanhoja slugeja, joten tunnetut slugit (edellisten rakennusten välimuisti + repon content/articles-slugs.json)
    // joita ei enää ole julkaistu kysytään yksitellen: moved → ohjaussivu, not_found → ei sivua (404).
    const known = new Map();
    for (const k of [...(snap?.known || []), ...committedSlugs]) known.set(`${k.lang}/${k.slug}`, k);
    for (const k of live) { const [l, s] = k.split('/'); known.set(k, { lang: l, slug: s }); }
    const redirects = [];
    await pool([...known.entries()].filter(([k]) => !live.has(k)), 4, async ([k, v]) => {
      try {
        const r = await rpc('public_get_article', { p_slug: v.slug, p_lang: v.lang });
        if (r?.ok === false && r.code === 'moved' && r.slug) redirects.push({ lang: v.lang, from: v.slug, toLang: r.lang || v.lang, toSlug: r.slug });
      } catch (err) {
        const old = snap?.redirects?.find((x) => x.lang === v.lang && x.from === v.slug);
        if (old) { redirects.push(old); w(`ohjaustarkistus ${k} epäonnistui (${err.message}); käytetään välimuistia`); } else w(`ohjaustarkistus ${k} epäonnistui (${err.message})`);
      }
    });
    const data = { source: 'rpc', warnings: warn, lang, sitemap, redirects, known: [...known.values()] };
    if (snapFile) { try { mkdirSync(cacheDir, { recursive: true }); writeFileSync(snapFile, JSON.stringify({ savedAt: new Date().toISOString(), ...data })); } catch (err) { w('välimuistin kirjoitus epäonnistui: ' + err.message); } }
    return data;
  } catch (err) {
    if (strict) throw err;
    w(`${err.message}. ${snap ? 'Käytetään edellisen onnistuneen haun välimuistia (' + snap.savedAt + ').' : 'Välimuistia ei ole: artikkelilista on tyhjä tässä rakennuksessa.'}`);
    if (snap) return { ...snap, source: 'cache', warnings: warn };
    return emptyData('none', warn);
  }
}

/** Repon mukana kulkeva tunnettujen slugien lista (content/articles-slugs.json: [{lang,slug}]); tyhjä jos tiedostoa ei ole. */
export function readCommittedSlugs(file) { const j = existsSync(file) ? readJson(file) : null; return Array.isArray(j) ? j.filter((x) => x?.lang && x?.slug) : []; }
