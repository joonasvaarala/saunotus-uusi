// Hallinnan vuosikorttien hallinnan tekstit (FI + EN): koodin arvonta, Peru- ja Poista-napit (booking_152). Avaimet: ui.admin.annual_manage.*.
// Sama mekanismi kuin annual-card-texts.js: public_get_site_texts (rpc), kieli talous-i18n (?lang= / localStorage booking.admin.lang).
// Sanakirja ANNUAL_MANAGE_TEXTS on vain varalla: rivi puuttuu, haku epäonnistuu tai paikkamerkki ei täyty. Tuonti: content/site-texts.pending-import-52.json.
import { getLang } from './talous-i18n.js';
import { getSiteTexts, clearSiteTextsCache } from './site-texts-cache.js';

export const ANNUAL_MANAGE_TEXTS = {
  fi: {
    'ui.admin.annual_manage.code_label': 'Oma koodi',
    'ui.admin.annual_manage.code_label_optional': 'Oma koodi (valinnainen)',
    'ui.admin.annual_manage.code_hint': 'Tyhjä = palvelin arpoo 10 merkin satunnaiskoodin (esim. TS5DSYAH2X). Sallitut merkit A–Z, 0–9 ja väliviiva.',
    'ui.admin.annual_manage.generate': 'Arvo koodi',
    'ui.admin.annual_manage.section_note': 'Vuosikortilla saa yhden maksuttoman yleisen saunavuoron kerrallaan yhdelle hengelle ilman lisäpalveluita. Peru-nappi poistaa kortin käytöstä. Poista-nappi näkyy vain käyttämättömällä hallinnasta myönnetyllä kortilla.',
    'ui.admin.annual_manage.revoke': 'Peru',
    'ui.admin.annual_manage.revoke_confirm': 'Perutaanko vuosikortti?',
    'ui.admin.annual_manage.revoke_future_confirm': 'Perutaanko myös kortin tulevat varaukset? (OK = peru, Peruuta = säilytä)',
    'ui.admin.annual_manage.revoked': 'Vuosikortti peruttu',
    'ui.admin.annual_manage.revoked_with_bookings': 'Vuosikortti peruttu, {{var:count}} varausta peruttu',
    'ui.admin.annual_manage.delete': 'Poista',
    'ui.admin.annual_manage.delete_confirm': 'Poistetaanko vuosikortti {{var:code}} pysyvästi? Korttia ei ole käytetty. Poisto kirjataan muutoslokiin.',
    'ui.admin.annual_manage.deleted': 'Vuosikortti poistettu',
  },
  en: {
    'ui.admin.annual_manage.code_label': 'Own code',
    'ui.admin.annual_manage.code_label_optional': 'Own code (optional)',
    'ui.admin.annual_manage.code_hint': 'Empty = the server generates a random 10-character code (e.g. TS5DSYAH2X). Allowed characters A–Z, 0–9 and hyphen.',
    'ui.admin.annual_manage.generate': 'Generate code',
    'ui.admin.annual_manage.section_note': 'An annual card gives one free public sauna session at a time for one person without extras. The Revoke button takes the card out of use. The Delete button is shown only for an unused card granted in admin.',
    'ui.admin.annual_manage.revoke': 'Revoke',
    'ui.admin.annual_manage.revoke_confirm': 'Revoke the annual card?',
    'ui.admin.annual_manage.revoke_future_confirm': 'Also cancel the card’s future bookings? (OK = cancel them, Cancel = keep them)',
    'ui.admin.annual_manage.revoked': 'Annual card revoked',
    'ui.admin.annual_manage.revoked_with_bookings': 'Annual card revoked, {{var:count}} bookings cancelled',
    'ui.admin.annual_manage.delete': 'Delete',
    'ui.admin.annual_manage.delete_confirm': 'Delete annual card {{var:code}} permanently? The card has not been used. The deletion is recorded in the audit log.',
    'ui.admin.annual_manage.deleted': 'Annual card deleted',
  },
};

const PREFIX = 'ui.admin.annual_manage.';
let db = new Map();
let loaded = false;

export function fillAmText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

/** Täyttää {{var:nimi}}. Tuntematon paikkamerkki tai puuttuva arvo → null (kutsuja käyttää sanakirjaa). */
function applyLive(raw, vars) {
  for (const m of String(raw).matchAll(/\{\{([^{}]*)\}\}/g)) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  const out = fillAmText(raw, vars);
  return /\{\{|\}\}/.test(out) ? null : out;
}

export function primeAmTexts(rows) {
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

/** Hakee ui.admin.annual_manage.*-rivit kerran sivulatauksessa. Virhe ei kaada näkymää: amText käyttää sanakirjaa. */
export async function loadAmTexts(rpcFn, rows = null) {
  if (primeAmTexts(rows)) return true;
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await getSiteTexts(rpcFn);
    if (!t || t.ok !== true || !Array.isArray(t.texts)) return false;
    return primeAmTexts(t.texts);
  } catch {
    return false;
  }
}

export function clearAmTextCache() {
  db = new Map();
  loaded = false;
  clearSiteTextsCache();
}

export function amText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = ANNUAL_MANAGE_TEXTS[lang]?.[key] ?? ANNUAL_MANAGE_TEXTS.fi[key] ?? key;
  return vars ? fillAmText(raw, vars) : raw;
}
