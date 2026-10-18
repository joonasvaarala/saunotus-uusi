// Sivutekstit tietokannasta rakennusvaiheessa (sopimus §18, booking_60/62): public_get_site_texts → build.
//  1) live-haku (anon-avain, vain luku; sama RPC-asiakas ja avaintarkistus kuin artikkeleissa)
//  2) epäonnistuu → edellisen onnistuneen haun välimuisti (.cache/site-texts/snapshot.json, actions/cache)
//  3) ei välimuistia → repossa oleva varateksti content/site-texts.fallback.json (päivitys: node scripts/site-texts-sync.mjs)
//  Haun epäonnistuminen EI kaada rakennusta (SITE_TEXTS_STRICT=1 kaataa). Sen sijaan TUNTEMATON PAIKKAMERKKI ({{…}}) tai puuttuva paikkamerkin arvo kaataa
//  rakennuksen aina (§18.3): raakaa {{…}} ei koskaan päädy sivulle. Paikkamerkit täytetään tässä (staattiset sivut: tx()); kauppa saa tekstit
//  sellaisenaan (booking/site-texts.json) ja täyttää paikkamerkit ajoajan katalogista (hinta/kesto pysyvät oikein vaikka sivu olisi välimuistissa), mutta build
//  tarkistaa että KAIKKI paikkamerkit ovat täytettävissä. Puuttuva avain ei tuota tyhjää eikä raakaa avainta: tx() käyttää fi-tekstiä, kutsujan varatekstiä tai heittää.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { makeRpc } from './articles/source.mjs';
import { LANGS, indexTexts, textFor, validateTexts, makeContext, tokensOf, PlaceholderError } from '../booking/shop/src/site-texts-logic.js';
import { kb, money, dur } from './lib.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const FALLBACK_FILE = join(root, 'content/site-texts.fallback.json');
export const FIXTURE_DEFAULT = join(root, 'tests/fixtures/site-texts/rpc.json');
export const SHOP_PREFIXES = ['ui.'];                 // kaupan tarvitsemat avainalueet (§18.2: ui.<alue>.<nimi>)
export const SHOP_EXCLUDE = ['ui.site.', 'ui.footer.', 'ui.reviews.', 'ui.training_banner.', 'ui.articles.', 'ui.card.', 'ui.alt.', 'ui.session.', 'ui.mobilepay.start_error_'];   // staattisen sivuston ui-alueet (osa 3 PR 2) ja edge-funktion (mobilepay-start) virhesivun tekstit (PR 3): eivät kuulu kaupan datakuormaan
const readJson = (f) => { try { return JSON.parse(readFileSync(f, 'utf8')); } catch { return null; } };

const cleanRows = (rows) => (Array.isArray(rows) ? rows : []).filter((r) => r && typeof r.key === 'string' && typeof r.lang === 'string' && typeof r.text === 'string' && r.text.trim())
  .map((r) => ({ key: r.key, lang: r.lang, text: r.text, version: r.version ?? null, placeholders: Array.isArray(r.placeholders) ? r.placeholders : tokensOf(r.text) }));
// Konteksti tallennetaan vain tarvittavin kentin (id, hinta, kesto) + julkiset asetukset
const slimCatalog = (rows) => (Array.isArray(rows) ? rows : []).filter((p) => p && p.id != null).map((p) => ({ id: p.id, price: p.price ?? null, duration_minutes: p.duration_minutes ?? null }));
const slimSettings = (s) => Object.fromEntries(Object.entries(s && typeof s === 'object' ? s : {}).filter(([, v]) => v != null && typeof v !== 'object'));
const kbCatalog = () => kb.products.map((p) => ({ id: p.id, price: p.price ?? null, duration_minutes: p.duration_minutes ?? null }));

/** Build-kontekstin muotoilu: hinta "49 €"/"€49", kesto "2 h" (lib.mjs money/dur). */
export const buildFormat = { price: (n, lang) => money(n, lang), duration: (m, lang) => dur(m, lang) };

/**
 * @returns {Promise<{source:'rpc'|'cache'|'fallback'|'fixture'|'none', rows:object[], idx:Map, ctx:object, generatedAt:string|null, warnings:string[], catalog:object[], settings:object}>}
 * Heittää vain jos: SITE_TEXTS_STRICT=1 ja haku epäonnistui, tai paikkamerkkivirhe (aina).
 */
export async function loadSiteTexts({ env = process.env, log = console, rpc = null, cacheDir = null, fallbackFile = FALLBACK_FILE } = {}) {
  const warnings = [], warn = (m) => { warnings.push(m); log.warn?.(`site-texts: VAROITUS: ${m}`); };
  const fx = env.SITE_TEXTS_FIXTURE && env.SITE_TEXTS_FIXTURE !== '0' ? (env.SITE_TEXTS_FIXTURE === '1' ? FIXTURE_DEFAULT : resolve(env.SITE_TEXTS_FIXTURE)) : null;
  const url = (env.BOOKING_SUPABASE_URL || '').trim(), key = (env.BOOKING_ANON_KEY || '').trim();
  const dir = cacheDir || (env.SITE_TEXTS_CACHE_DIR ? resolve(env.SITE_TEXTS_CACHE_DIR) : join(root, '.cache/site-texts'));
  const snapFile = join(dir, fx ? 'snapshot-fixture.json' : 'snapshot.json');
  let source = 'none', rows = [], generatedAt = null, catalog = null, settings = null;

  try {
    if (fx) {
      const j = JSON.parse(readFileSync(fx, 'utf8'));
      rows = cleanRows(j.texts); generatedAt = j.generated_at || null; catalog = j.context?.catalog || null; settings = j.context?.settings || null; source = 'fixture';
    } else {
      if (!rpc) {
        if (!url || !key) throw new Error('Supabase-asetuksia ei ole (BOOKING_SUPABASE_URL / BOOKING_ANON_KEY): tekstejä ei haeta');
        if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url) && !/^http:\/\/localhost(:\d+)?$/.test(url)) throw new Error('BOOKING_SUPABASE_URL: odotetaan https://<ref>.supabase.co');
        rpc = makeRpc({ url, key });
      }
      const r = await rpc('public_get_site_texts', { p_lang: null });
      if (!r || r.ok !== true || !Array.isArray(r.texts)) throw new Error(`public_get_site_texts: ${r?.code || 'virheellinen vastaus'}`);
      rows = cleanRows(r.texts); generatedAt = r.generated_at || null; source = 'rpc';
      // paikkamerkkien data: katalogi + julkiset asetukset (virhe → välimuisti/varateksti, ei kaadu)
      try { const c = await rpc('public_catalog', {}); if (Array.isArray(c)) catalog = slimCatalog(c); } catch (e) { warn(`public_catalog epäonnistui (${e.message}); paikkamerkkien hinnat/kestot välimuistista tai kb-snapshotista`); }
      try { const s = await rpc('public_settings', {}); if (s && typeof s === 'object') settings = slimSettings(s); } catch (e) { warn(`public_settings epäonnistui (${e.message}); {{setting:…}} välimuistista`); }
    }
  } catch (err) {
    if (env.SITE_TEXTS_STRICT === '1') throw new Error(`site-texts: haku epäonnistui (SITE_TEXTS_STRICT=1): ${err.message}`);
    const snap = readJson(snapFile), fb = readJson(fallbackFile);
    const pick = snap?.texts?.length ? ['cache', snap] : fb?.texts?.length ? ['fallback', fb] : null;
    if (pick) { warn(`haku epäonnistui (${err.message}); käytetään ${pick[0] === 'cache' ? 'edellisen haun välimuistia' : 'repon varatekstiä content/site-texts.fallback.json'}`); source = pick[0]; rows = cleanRows(pick[1].texts); generatedAt = pick[1].generated_at || null; catalog = pick[1].context?.catalog || null; settings = pick[1].context?.settings || null; }
    else { warn(`haku epäonnistui (${err.message}) eikä välimuistia tai varatekstiä ole: tekstit puuttuvat (tx() käyttää kutsujan varatekstiä)`); source = 'none'; rows = []; }
  }
  // paikkamerkkien lähteet puuttuessa: edellinen välimuisti → varateksti → kb-snapshot (hinta/kesto)
  if (!catalog || !settings) {
    const snap = readJson(snapFile), fb = readJson(fallbackFile);
    catalog ||= snap?.context?.catalog || fb?.context?.catalog || kbCatalog();
    settings ||= snap?.context?.settings || fb?.context?.settings || {};
  }
  const ctx = makeContext({ catalog, settings, format: buildFormat });
  const problems = validateTexts(rows, makeContext({ catalog, settings, format: buildFormat, vars: true }));   // {{var:…}} tarkistetaan vain muodoltaan; arvo tulee kutsuhetkellä
  if (problems.length) throw new Error(`site-texts: PAIKKAMERKKIVIRHE – rakennus keskeytetty (§18.3):\n${problems.map((p) => `  ${p.key} [${p.lang}]: ${p.problem}`).join('\n')}`);
  const out = { source, rows, idx: indexTexts(rows), ctx, generatedAt, warnings, catalog, settings };
  if (source === 'rpc') { try { mkdirSync(dir, { recursive: true }); writeFileSync(snapFile, JSON.stringify({ generated_at: generatedAt, texts: rows, context: { catalog, settings } })); } catch (e) { warn(`välimuistin kirjoitus epäonnistui (${e.message})`); } }
  log.log?.(`site-texts: ${source}; ${rows.length} riviä (${new Set(rows.map((r) => r.key)).size} avainta${generatedAt ? `, ${generatedAt}` : ''})`);
  return out;
}

// ---- globaali tila staattisten sivujen renderöintiin (render.mjs voi kutsua tx()) ----
let STATE = null;
export const setSiteTexts = (s) => { STATE = s; };
export const getSiteTexts = () => STATE;

export class MissingTextError extends Error { constructor(key, lang) { super(`sivuteksti puuttuu: ${key} [${lang}] (ei fi-tekstiä eikä varatekstiä)`); this.name = 'MissingTextError'; this.key = key; this.lang = lang; } }
/**
 * Teksti sivulle: paikkamerkit täytetty. en puuttuu → fi (lokitetaan). Avainta ei ole: `fallback` (siirtymäajan vanha kovakoodattu teksti, lokitetaan) tai MissingTextError.
 * Ei koskaan tyhjää eikä raakaa avainta/{{…}}-merkintää.
 */
export function tx(key, lang, { fallback = null, state = STATE, log = console, vars = null } = {}) {
  const r = state ? textFor(state.idx, key, lang, vars ? { ...state.ctx, var: (n) => vars[n] ?? null } : state.ctx, { strict: true }) : null;
  if (r) { if (r.fallback) log.warn?.(`site-texts: ${key} puuttuu kielellä ${lang}; käytetään fi-tekstiä`); return r.text; }
  if (fallback != null && String(fallback).trim()) { log.warn?.(`site-texts: avain ${key} puuttuu tietokannasta; käytetään siirtymäajan varatekstiä`); return String(fallback); }
  throw new MissingTextError(key, lang);
}

/** Kaupalle: vain tarvittavat avainalueet, paikkamerkit täyttämättä (kauppa täyttää ajoajan datasta). */
export function shopPayload(state, prefixes = SHOP_PREFIXES) {
  const texts = state.rows.filter((r) => prefixes.some((p) => r.key.startsWith(p)) && !SHOP_EXCLUDE.some((x) => r.key.startsWith(x))).map((r) => ({ key: r.key, lang: r.lang, text: r.text, placeholders: r.placeholders }));
  return { generated_at: state.generatedAt, source: state.source, langs: LANGS, texts };
}
export { PlaceholderError };
