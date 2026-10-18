// Staattisten sivujen asiakasnäkyvät tekstit avaimiksi (sopimus §18, osa 3 PR 2): etusivu, sivupohjat, kortit, kuvien alt-tekstit, navigaatio, alatunniste,
// SEO/meta, Saunatietoa-osion kiinteät tekstit. Lähteet ovat edelleen repon JSON-tiedostot (content/site.json, pages/*.json, cards.json, alts.json, articles.json):
// ne ovat varateksti. Tämä moduuli (1) listaa jokaisen lehtitekstin avaimena (collectContentDefaults → tuontitiedosto) ja (2) peittää tietokannan tekstit
// samojen olioiden päälle rakennuksessa (applyContentTexts), jolloin sivupohjat (render.mjs, articles/*) toimivat sellaisinaan ja HTML pysyy samana.
// Puuttuva/virheellinen DB-teksti → repon oletus. Raakaa HTML:ää ei saa tuoda kantaan (booking_60 html_not_allowed): lihavointi = **teksti** (kind lite),
// muunnetaan sivulla <strong>-merkinnäksi vain kentissä, jotka tulostetaan sellaisenaan (info: p, note).
import { readFileSync, readdirSync } from 'node:fs';
import { site } from './lib.mjs';
import { cfg as articlesCfg } from './articles/config.mjs';
import { textFor, tokensOf } from '../booking/shop/src/site-texts-logic.js';
import { classFor } from '../booking/shop/src/text-registry.js';

const root = new URL('../', import.meta.url);
const readJson = (p) => JSON.parse(readFileSync(new URL(p, root), 'utf8'));
const clone = (o) => JSON.parse(JSON.stringify(o));

// ---- elävät oliot (render.mjs lukee nämä) ----
const PAGE_NAMES = readdirSync(new URL('content/pages/', root)).filter((f) => f.endsWith('.json')).map((f) => f.slice(0, -5)).sort();
export const cards = readJson('content/cards.json');
export const alts = readJson('content/alts.json');
const pages = Object.fromEntries(PAGE_NAMES.map((n) => [n, readJson(`content/pages/${n}.json`)]));
export const pageDoc = (name) => { if (!pages[name]) throw new Error(`tuntematon sivudokumentti: ${name}`); return pages[name]; };
const LIVE = { site: site.ui, art: articlesCfg.ui, cards, alts, ...Object.fromEntries(PAGE_NAMES.map((n) => [`p:${n}`, pages[n]])) };
// puhtaat oletukset (ennen peittoa): avainlista ja tuontitiedosto johdetaan näistä, ei peitetyistä olioista
const ORIG = clone(LIVE);

const snake = (s) => String(s).replace(/([a-z0-9])([A-Z])/g, '$1_$2').replace(/[^A-Za-z0-9_]+/g, '_').toLowerCase().replace(/^_+|_+$/g, '');
const LANGS = ['fi', 'en'];
// Kentät, jotka eivät ole asiakkaalle näkyvää tekstiä: tunnisteet, kuvat, osoitteet, viittaukset, rakenne
const TECH = new Set(['img', 'og', 'url', 'to', 'kb', 'card', 'icon', 'id', 'policies', 'show', 'exact', 'extra', 'johku', 'johkuEn', 'lang', 'locale', 'johkuLoc', '_doc']);
// Käyttämättömät (koodissa ei viittauksia; ei tuoda): site.ui.*
const DEAD_SITE = new Set(['brandKicker', 'rights', 'externalNote', 'privateAndEvents', 'termsTitle', 'privacyTitle', 'privatePrompt']);
const DEAD_ART = new Set(['pageTitle', 'readArticleAbout']);
const KEY_RE = /^[a-z0-9_]+(\.[a-z0-9_-]+)+$/;

function* leaves(o, path = []) {
  if (Array.isArray(o)) { for (let i = 0; i < o.length; i++) yield* leaves(o[i], [...path, i]); return; }
  if (o && typeof o === 'object') { for (const [k, v] of Object.entries(o)) { if (TECH.has(k)) continue; yield* leaves(v, [...path, k]); } return; }
  if (typeof o === 'string') yield [path, o];
}
const seg = (p) => (typeof p === 'number' ? String(p + 1) : snake(p));
const j = (ps) => ps.map(seg).join('.');

// ---- avainkartta: lähde + polku → { key, lang } tai null ----
const PAGE_KEY = { home: 'front', book: 'booking_info' };     // static book ≠ kaupan page.book.* (tuotannossa jo kaupan teksteillä)
function mapSite(path) {                                      // content/site.json ui: [lang, ...]
  const [lang, ...r] = path;
  if (!LANGS.includes(lang)) return null;
  const top = r[0];
  if (DEAD_SITE.has(top)) return null;
  if (top === 'nav' || top === 'infoLinks') { if (r[2] !== 1) return null; const id = ORIG.site[lang][top][r[1]][0]; return { lang, key: `nav.${top === 'nav' ? 'main' : 'info'}.${snake(id)}` }; }
  if (top === 'reviews') return { lang, key: `ui.reviews.${j(r.slice(1))}` };
  if (top === 'trainingBanner') return { lang, key: `ui.training_banner.${j(r.slice(1))}` };
  if (/^footer[A-Z]/.test(top)) return { lang, key: `ui.footer.${snake(top.slice(6))}` };
  if (top === 'legal' || top === 'privacy') return { lang, key: `ui.footer.${top}` };
  return { lang, key: `ui.site.${j(r)}` };
}
function mapArt(path) { const [lang, ...r] = path; return !LANGS.includes(lang) || DEAD_ART.has(r[0]) ? null : { lang, key: `ui.articles.${j(r)}` }; }
function mapPage(name) {
  const p = PAGE_KEY[name] || snake(name);
  return (path) => {
    const [lang, ...r] = path;
    if (!LANGS.includes(lang)) return null;
    if (r[0] === 'meta') return r[1] === 'title' || r[1] === 'description' ? { lang, key: `seo.${p}.${r[1]}` } : null;
    return { lang, key: `page.${p}.${j(r)}` };
  };
}
function mapCards(path) {                                     // [group, id, fi|en, ...rest]  tai  [group, id, over, field, fi|en]
  const [g, id, ...r] = path;
  let lang, rest;
  if (LANGS.includes(r[0])) { lang = r[0]; rest = r.slice(1); } else if (r[0] === 'over' && LANGS.includes(r[2])) { lang = r[2]; rest = ['over', r[1]]; } else return null;
  return { lang, key: `ui.card.${snake(g)}.${snake(id)}.${j(rest)}` };
}
const mapAlts = (path) => (path.length === 2 && LANGS.includes(path[1]) ? { lang: path[1], key: `ui.alt.${snake(path[0])}` } : null);

const SOURCES = [
  { id: 'site', file: 'content/site.json (ui)', map: mapSite },
  { id: 'art', file: 'content/articles.json (ui)', map: mapArt },
  { id: 'cards', file: 'content/cards.json', map: mapCards },
  { id: 'alts', file: 'content/alts.json', map: mapAlts },
  ...PAGE_NAMES.map((n) => ({ id: `p:${n}`, file: `content/pages/${n}.json`, map: mapPage(n) })),
];
// sessionLabels (site.json, ei ui-alipuussa) ja render.mjs:n sisäiset sanat: erilliset lisäkohteet
const EXTRA = [];

// Raakana tulostettavat kentät (info-sivun p/note): HTML <strong> ↔ **lihavointi** (kantaan ei saa tuoda HTML:ää)
const isRaw = (srcId, path) => srcId === 'p:info' && ['p', 'note'].includes(path[path.length - 1]);
export const htmlToLite = (s) => s.replace(/<strong>([\s\S]*?)<\/strong>/g, '**$1**');
export const liteToHtml = (s) => s.replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
// yksittäinen {n}-muuttuja (artikkeli- ja arvostelutekstit) ↔ {{var:n}} (kanta sallii vain {{…}}-paikkamerkit)
export const braceToVar = (s) => s.replace(/\{([a-z_]+)\}/g, '{{var:$1}}');

// Hintaviitteet: kovakoodattu summa → {{price:ID}} / {{duration:ID}} (arvo katalogista; sama muoto kuin lib.mjs money/dur). Vain selvät, tuotteeseen sidotut kohdat.
const money = (n, lang) => (lang === 'fi' ? `${n} €` : `€${n}`);
const BINDINGS = {
  'seo.companies.description': (l) => [[money(350, l), '{{price:48}}'], [money(250, l), '{{price:49}}']],
  'ui.card.corporate.vuoro.list.1': (l) => [[money(350, l), '{{price:48}}']],
  'ui.card.corporate.jalkiloylyt.list.1': (l) => [[money(250, l), '{{price:49}}']],
  'seo.treatments.description': (l) => (l === 'fi' ? [['Saunahoito 1 h, saunotus 2 h ja syväsaunotus 3 h', 'Saunahoito {{duration:10}}, saunotus {{duration:11}} ja syväsaunotus {{duration:12}}']] : []),
};
export const importText = (key, lang, def, raw) => {
  let t = raw ? htmlToLite(def) : def;
  for (const [from, to] of (BINDINGS[key]?.(lang) || [])) { if (!t.includes(from)) throw new Error(`${key} [${lang}]: sidonnan kohta "${from}" puuttuu`); t = t.replace(from, to); }
  return braceToVar(t);
};

/** Kaikki asiakasnäkyvät lehtitekstit: [{ key, lang, def, text (tuontiteksti), raw, src, set(live, value) }] */
export function collectContentDefaults() {
  const out = [], seen = new Set();
  const push = (srcId, file, map, path, value, extra = {}) => {
    const m = map(path); if (!m) return;
    if (!/[A-Za-zÄÖäö]/.test(value)) return;                  // pelkkiä numeroita/merkkejä (esim. vuosiluku, "/ 5") ei tuoda tekstiksi
    if (!KEY_RE.test(m.key) || m.key.length > 120) throw new Error(`virheellinen avain ${m.key}`);
    const id = `${m.key}|${m.lang}`; if (seen.has(id)) throw new Error(`kaksoisavain ${id}`); seen.add(id);
    const raw = isRaw(srcId, path);
    out.push({ key: m.key, lang: m.lang, def: value, raw, text: importText(m.key, m.lang, value, raw), src: file, srcId, path, ...extra });
  };
  for (const s of SOURCES) for (const [path, v] of leaves(ORIG[s.id])) push(s.id, s.file, s.map, path, v);
  for (const x of EXTRA) push(x.srcId, x.file, () => ({ key: x.key, lang: x.lang }), [], x.text, { path: x.path });
  return out;
}

// sessionLabels (site.json:n ylätasolla) → ui.session.<id>
const sessionLabels = () => Object.entries(ORIG.siteTop.sessionLabels).flatMap(([id, v]) => LANGS.map((lang) => ({ srcId: 'siteTop', file: 'content/site.json (sessionLabels)', key: `ui.session.${snake(id)}`, lang, text: v[lang], path: ['sessionLabels', id, lang] })));
ORIG.siteTop = { sessionLabels: clone(site.sessionLabels) }; LIVE.siteTop = { sessionLabels: site.sessionLabels };
EXTRA.push(...sessionLabels());

const setAt = (obj, path, v) => { let o = obj; for (let i = 0; i < path.length - 1; i++) o = o[path[i]]; o[path[path.length - 1]] = v; };

/** Luokka (§18.6): protected = ehdot/tietosuoja, hinnat/euromäärät, kellonajat, peruutus/voimassaolo, osoite/reitti, terveysväitteet, yhteystiedot. */
export function classForContent(key, fi = '') {
  if (/^(page|seo)\.(terms|privacy)\./.test(key)) return 'protected';
  if (/€|\{\{price:/.test(fi)) return 'protected';
  if (/klo\s*\d|\d\s*[–-]\s*\d{1,2}\s*(pm|am)?\b|\b\d{1,2}\s*(pm|am)\b/i.test(fi)) return 'protected';
  if (/perua|peruut|voimassa|hyvit|maksuton|maksutta|ei-maksu/i.test(fi)) return 'protected';
  if (/Hindsbyntie|\bbussi|\b841\b|Broböle|Itäkeskus/i.test(fi)) return 'protected';
  return classFor(key, fi);
}
export const maxLenFor = (fi, en = '') => Math.max(200, Math.ceil((Math.max(fi.length, en.length) * 2.5) / 50) * 50);

/**
 * Peittää tietokannan tekstit elävien olioiden päälle. state = loadSiteTexts()-tulos (idx, ctx). Palauttaa { used, fallback, failed }.
 * Teksti puuttuu → repon oletus (fallback++). Paikkamerkki ei täyty → oletus ja varoitus. {{var:n}} → {n} (sivupohja täyttää myöhemmin).
 */
export function applyContentTexts(state, { log = console } = {}) {
  const res = { used: 0, fallback: 0, failed: 0 };
  const ctx = state ? { ...state.ctx, var: (n) => `{${n}}` } : null;
  for (const r of collectContentDefaults()) {
    let t = null;
    if (state) { try { const x = textFor(state.idx, r.key, r.lang, ctx, { strict: true }); t = x && !x.fallback ? x.text : null; } catch (e) { res.failed++; log.warn?.(`site-texts: ${r.key} [${r.lang}] ohitettu (${e.message}); käytetään repon oletusta`); } }
    if (t == null || !String(t).trim()) { setAt(LIVE[r.srcId], r.path, r.def); if (t == null) res.fallback++; continue; }
    setAt(LIVE[r.srcId], r.path, r.raw ? liteToHtml(t) : t);
    res.used++;
  }
  return res;
}
/** Palauttaa oliot repon oletuksiin (testit). */
export const resetContentTexts = () => applyContentTexts(null);
export { tokensOf };
