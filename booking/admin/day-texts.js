// Hallinnan päivänäkymän tekstit (FI + EN). Avaimet: ui.admin.day.* (§18).
// Sama mekanismi kuin muu hallinta, joka lukee site_texts: public_get_site_texts (rpc), kieli talous-i18n
// (?lang= / localStorage booking.admin.lang). Sanakirja DAY_TEXTS on vain varalla: rivi puuttuu, haku
// epäonnistuu tai paikkamerkki ei täyty. Tuonti: content/site-texts.imported-pr68.json (gift_card_badge: pending-import-32).
import { getLang } from './talous-i18n.js';
import { getSiteTexts, clearSiteTextsCache } from './site-texts-cache.js';

export const DAY_TEXTS = {
  fi: {
    'ui.admin.day.revenue_title': 'Päivän tuotto',
    'ui.admin.day.revenue_vat': 'sis. alv',
    'ui.admin.day.revenue_pending': 'Vahvistamatta {{var:amount}}',
    'ui.admin.day.revenue_unpaid': 'Josta maksamatta {{var:amount}}',
    'ui.admin.day.revenue_unavailable': 'Päivän tuotto ja tapahtumat eivät ole vielä käytettävissä.',
    'ui.admin.day.event_badge': 'Tapahtuma',
    'ui.admin.day.event_all_day': 'Koko päivä',
    'ui.admin.day.gift_card_badge': 'Lahjakortti',
  },
  en: {
    'ui.admin.day.revenue_title': "Day's revenue",
    'ui.admin.day.revenue_vat': 'incl. VAT',
    'ui.admin.day.revenue_pending': 'Unconfirmed {{var:amount}}',
    'ui.admin.day.revenue_unpaid': 'Of which unpaid {{var:amount}}',
    'ui.admin.day.revenue_unavailable': "The day's revenue and events are not available yet.",
    'ui.admin.day.event_badge': 'Event',
    'ui.admin.day.event_all_day': 'All day',
    'ui.admin.day.gift_card_badge': 'Gift card',
  },
};

const PREFIX = 'ui.admin.day.';
let db = new Map();
let loaded = false;

export const dayLang = () => getLang();

export function fillDayText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

/** Täyttää {{var:nimi}}. Tuntematon paikkamerkki tai puuttuva arvo → null (kutsuja käyttää sanakirjaa). */
function applyLive(raw, vars) {
  const tokens = [...String(raw).matchAll(/\{\{([^{}]*)\}\}/g)];
  for (const m of tokens) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  if (/\{\{|\}\}/.test(fillDayText(raw, vars))) return null;
  return fillDayText(raw, vars);
}

/**
 * Lukee ui.admin.day.*-rivit public_get_site_texts-vastauksesta. Virhe tai väärä vastaus ei kaada näkymää:
 * dayText käyttää silloin sanakirjaa. Onnistunut haku pysyy muistissa sivulatauksen ajan.
 */
function primeDayTexts(rows) {
  if (!Array.isArray(rows)) return false;
  const next = new Map();
  for (const r of rows) {
    if (!r || typeof r.key !== 'string' || !r.key.startsWith(PREFIX)) continue;
    if (r.lang !== 'fi' && r.lang !== 'en') continue;
    if (typeof r.text !== 'string' || !r.text.trim()) continue;
    next.set(`${r.key}|${r.lang}`, r.text);
  }
  db = next;
  loaded = true;
  return true;
}

export async function loadDayTexts(rpcFn, rows = null) {
  if (primeDayTexts(rows)) return true;
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await getSiteTexts(rpcFn);
    if (!t || t.ok !== true || !Array.isArray(t.texts)) return false;
    if (!t.texts.length) { db = new Map(); loaded = true; return true; }
    return primeDayTexts(t.texts);
  } catch {
    return false;
  }
}

export function clearDayTextCache() {
  db = new Map();
  loaded = false;
  clearSiteTextsCache(); // tyhjennys hakee seuraavalla kerralla uudelleen (jaettu lupaus ei saa jäädä voimaan)
}

export function dayText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = DAY_TEXTS[lang]?.[key] ?? DAY_TEXTS.fi[key] ?? key;
  return vars ? fillDayText(raw, vars) : raw;
}
