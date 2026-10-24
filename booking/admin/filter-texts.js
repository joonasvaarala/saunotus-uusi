// Hallinnan listojen suodatinpainikkeen tekstit (FI + EN). Avaimet: ui.admin.filters.* (§18).
// public_get_site_texts peittää sanakirjan. Haku epäonnistuu, rivi puuttuu tai paikkamerkki ei täyty → FILTER_TEXTS.
// Tuonti: content/site-texts.pending-import-4.json (sama tiedosto kuin myyntikäyrä; ei ylikirjoita olemassa olevia).
import { getLang } from './talous-i18n.js';
import { getSiteTexts, clearSiteTextsCache } from './site-texts-cache.js';

export const PREFIX = 'ui.admin.filters.';

export const FILTER_TEXTS = {
  fi: {
    'ui.admin.filters.show': 'Näytä suodattimet',
    'ui.admin.filters.hide': 'Piilota suodattimet',
    'ui.admin.filters.active': 'Suodattimia: {{var:n}}',
  },
  en: {
    'ui.admin.filters.show': 'Show filters',
    'ui.admin.filters.hide': 'Hide filters',
    'ui.admin.filters.active': 'Filters: {{var:n}}',
  },
};

let db = new Map();
let loaded = false;

export function fillFilterText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

function applyLive(raw, vars) {
  const tokens = [...String(raw).matchAll(/\{\{([^{}]*)\}\}/g)];
  for (const m of tokens) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  if (/\{\{|\}\}/.test(fillFilterText(raw, vars))) return null;
  return fillFilterText(raw, vars);
}

/** Lukee ui.admin.filters.*-rivit. Virhe tai väärä vastaus ei kaada näkymää. */
export async function loadFilterTexts(rpcFn) {
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await getSiteTexts(rpcFn);
    if (!t || t.ok !== true || !Array.isArray(t.texts)) return false;
    const next = new Map();
    for (const r of t.texts) {
      if (!r || typeof r.key !== 'string' || !r.key.startsWith(PREFIX)) continue;
      if (r.lang !== 'fi' && r.lang !== 'en') continue;
      if (typeof r.text !== 'string' || !r.text.trim()) continue;
      next.set(`${r.key}|${r.lang}`, r.text);
    }
    db = next;
    loaded = true;
    return true;
  } catch {
    return false;
  }
}

export function clearFilterTextCache() {
  db = new Map();
  loaded = false;
  clearSiteTextsCache(); // tyhjennys hakee seuraavalla kerralla uudelleen (jaettu lupaus ei saa jäädä voimaan)
}

export function filterText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = FILTER_TEXTS[lang]?.[key] ?? FILTER_TEXTS.fi[key] ?? key;
  return vars ? fillFilterText(raw, vars) : raw;
}
