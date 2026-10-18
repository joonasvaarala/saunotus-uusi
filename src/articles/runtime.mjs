// Rakennuksen aikainen tila: onko kielellä julkaistuja artikkeleita (ohjaa navigaatiolinkkiä).
// build.mjs asettaa tilan ja kirjoittaa tilatiedoston; varauskaupan rakennus (oma prosessi) lukee sen tiedostosta.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { cfg, label, listHref } from './config.mjs';

let state = null;
export const stateFile = () => process.env.ARTICLES_STATE_FILE || new URL('../../.cache/articles/state.json', import.meta.url).pathname;
export function setArticlesState(s) {
  state = s;
  try { mkdirSync(dirname(stateFile()), { recursive: true }); writeFileSync(stateFile(), JSON.stringify(s)); } catch { /* tila on vain apu: ei kaada rakennusta */ }
}
function load() {
  if (state) return state;
  try { state = JSON.parse(readFileSync(stateFile(), 'utf8')); } catch { state = { count: { fi: 0, en: 0 } }; }
  return state;
}
// Navigaatiolinkki ({href,label}) tai null kun linkkiä ei näytetä (ei artikkeleita eikä nav.showWhenEmpty)
export function articlesNav(lang) {
  const n = load().count?.[lang] || 0;
  if (!n && !cfg.nav.showWhenEmpty) return null;
  return { href: listHref(lang), label: label(lang) };
}

// Etusivun artikkeliosio (esirenderöity HTML kielittäin). Vain muistissa: asetetaan renderForBuild:ssa (kun kuvaversiot on valmistettu) ja luetaan R.home():ssa.
// Tyhjä merkkijono = osio piilossa (ei artikkeleita, haku epäonnistui tai renderöinti epäonnistui).
let homeSections = { fi: '', en: '' };
export const setHomeSections = (s) => { homeSections = { fi: s?.fi || '', en: s?.en || '' }; };
export const homeSection = (lang) => homeSections[lang] || '';
