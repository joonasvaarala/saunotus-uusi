// Hallinnan hoitomuistutuksen ja "Hoito valitsematta" -suodattimen tekstit (FI + EN). Avaimet: ui.admin.options.* (§18).
// Sama mekanismi kuin päivänäkymässä (day-texts.js): public_get_site_texts, kieli talous-i18n (?lang= / localStorage).
// Sanakirja OPTION_TEXTS on vain varalla: rivi puuttuu, haku epäonnistuu tai paikkamerkki ei täyty.
// Tuonti: content/site-texts.pending-import-4.json (Bottiavustus ajaa admin_texts_importin; ei vielä fallbackissa).
import { getLang } from './talous-i18n.js';

export const OPTION_TEXTS = {
  fi: {
    'ui.admin.options.not_chosen': 'valitsematta',
    'ui.admin.options.reminder': '{{var:n}} tulevaa hoitovarausta ilman valittua hoitoa.',
    'ui.admin.options.reminder_link': 'Avaa varaukset',
    'ui.admin.options.filter_legend': 'Hoito',
    'ui.admin.options.filter_all': 'Kaikki',
    'ui.admin.options.filter_unassigned': 'Hoito valitsematta',
    'ui.admin.options.filter_clear': 'Poista',
  },
  en: {
    'ui.admin.options.not_chosen': 'not chosen',
    'ui.admin.options.reminder': '{{var:n}} upcoming treatment bookings have no treatment chosen.',
    'ui.admin.options.reminder_link': 'Open bookings',
    'ui.admin.options.filter_legend': 'Treatment',
    'ui.admin.options.filter_all': 'All',
    'ui.admin.options.filter_unassigned': 'Treatment not chosen',
    'ui.admin.options.filter_clear': 'Remove',
  },
};

const PREFIX = 'ui.admin.options.';
let db = new Map();
let loaded = false;

export function fillOptionText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

function applyLive(raw, vars) {
  const tokens = [...String(raw).matchAll(/\{\{([^{}]*)\}\}/g)];
  for (const m of tokens) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  if (/\{\{|\}\}/.test(fillOptionText(raw, vars))) return null;
  return fillOptionText(raw, vars);
}

/** Lukee ui.admin.options.*-rivit. Virhe ei kaada näkymää: optionText käyttää silloin sanakirjaa. */
export async function loadOptionTexts(rpcFn) {
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await rpcFn('public_get_site_texts', { p_lang: null });
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

export function clearOptionTextCache() {
  db = new Map();
  loaded = false;
}

export function optionText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = OPTION_TEXTS[lang]?.[key] ?? OPTION_TEXTS.fi[key] ?? key;
  return vars ? fillOptionText(raw, vars) : raw;
}
