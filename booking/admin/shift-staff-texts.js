// Hallinnan vuorotarjousten omien sivujen tekstit (FI + EN, booking_153). Avaimet: ui.admin.shift_staff.*.
// Sama mekanismi kuin annual-manage-texts.js: public_get_site_texts (rpc), kieli talous-i18n (?lang= / localStorage booking.admin.lang).
// Sanakirja SHIFT_STAFF_TEXTS on vain varalla. Tuonti: content/site-texts.pending-import-53.json.
import { getLang } from './talous-i18n.js';
import { getSiteTexts, clearSiteTextsCache } from './site-texts-cache.js';

export const SHIFT_STAFF_TEXTS = {
  fi: {
    'ui.admin.shift_staff.title': "Vuorotarjousten omat sivut",
    'ui.admin.shift_staff.intro': "Jokaisella työntekijällä on pysyvä oma linkki, josta hän näkee omat avoimet ja vastatut vuorotarjouksensa ja voi muuttaa vastaustaan. Linkki ei vaadi kirjautumista, joten jaa se vain henkilölle itselleen. Uusi linkki mitätöi vanhan.",
    'ui.admin.shift_staff.link_none': "Ei linkkiä",
    'ui.admin.shift_staff.link_active': "Linkki käytössä",
    'ui.admin.shift_staff.link_revoked': "Linkki peruttu",
    'ui.admin.shift_staff.create': "Luo linkki",
    'ui.admin.shift_staff.renew': "Uusi linkki",
    'ui.admin.shift_staff.revoke': "Peru linkki",
    'ui.admin.shift_staff.revoke_confirm': "Perutaanko henkilön {{var:name}} oma linkki? Vanha linkki lakkaa toimimasta heti.",
    'ui.admin.shift_staff.renew_confirm': "Luodaanko henkilölle {{var:name}} uusi linkki? Vanha linkki lakkaa toimimasta heti.",
    'ui.admin.shift_staff.copied': "Linkki kopioitu",
    'ui.admin.shift_staff.link_label': "Oma linkki",
    'ui.admin.shift_staff.revoked': "Linkki peruttu",
    'ui.admin.shift_staff.last_used': "Käytetty viimeksi {{var:when}}",
    'ui.admin.shift_staff.suggest_whatsapp': "{{var:name}} lähetti viestin Tapion WhatsApp-numeroon {{var:when}}. Viesti on kirjattu suostumukseksi. Voit ottaa WhatsApp-viestit käyttöön hänelle Työvuoro-Tapiossa (whatsapp_enabled).",
    'ui.admin.shift_staff.dismiss': "Piilota ehdotus",
    'ui.admin.shift_staff.unavailable': "Omia sivuja ei voitu ladata. Muu käyttäjähallinta toimii.",
    'ui.admin.shift_staff.empty': "Ei työntekijöitä.",
  },
  en: {
    'ui.admin.shift_staff.title': "Personal shift offer pages",
    'ui.admin.shift_staff.intro': "Each staff member has a permanent personal link showing their own open and answered shift offers, where they can change their answer. The link needs no login, so share it only with the person themselves. A new link invalidates the old one.",
    'ui.admin.shift_staff.link_none': "No link",
    'ui.admin.shift_staff.link_active': "Link active",
    'ui.admin.shift_staff.link_revoked': "Link revoked",
    'ui.admin.shift_staff.create': "Create link",
    'ui.admin.shift_staff.renew': "New link",
    'ui.admin.shift_staff.revoke': "Revoke link",
    'ui.admin.shift_staff.revoke_confirm': "Revoke the personal link of {{var:name}}? The old link stops working immediately.",
    'ui.admin.shift_staff.renew_confirm': "Create a new link for {{var:name}}? The old link stops working immediately.",
    'ui.admin.shift_staff.copied': "Link copied",
    'ui.admin.shift_staff.link_label': "Personal link",
    'ui.admin.shift_staff.revoked': "Link revoked",
    'ui.admin.shift_staff.last_used': "Last used {{var:when}}",
    'ui.admin.shift_staff.suggest_whatsapp': "{{var:name}} sent a message to Tapio’s WhatsApp number on {{var:when}}. The message has been recorded as consent. You can enable WhatsApp messages for them in Työvuoro-Tapio (whatsapp_enabled).",
    'ui.admin.shift_staff.dismiss': "Hide suggestion",
    'ui.admin.shift_staff.unavailable': "Personal pages could not be loaded. The rest of user management works.",
    'ui.admin.shift_staff.empty': "No staff members.",
  },
};

const PREFIX = 'ui.admin.shift_staff.';
let db = new Map();
let loaded = false;

export function fillSsText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

/** Täyttää {{var:nimi}}. Tuntematon paikkamerkki tai puuttuva arvo → null (kutsuja käyttää sanakirjaa). */
function applyLive(raw, vars) {
  for (const m of String(raw).matchAll(/\{\{([^{}]*)\}\}/g)) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  const out = fillSsText(raw, vars);
  return /\{\{|\}\}/.test(out) ? null : out;
}

export function primeSsTexts(rows) {
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

/** Hakee ui.admin.shift_staff.*-rivit kerran sivulatauksessa. Virhe ei kaada näkymää: ssText käyttää sanakirjaa. */
export async function loadSsTexts(rpcFn, rows = null) {
  if (primeSsTexts(rows)) return true;
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await getSiteTexts(rpcFn);
    if (!t || t.ok !== true || !Array.isArray(t.texts)) return false;
    return primeSsTexts(t.texts);
  } catch {
    return false;
  }
}

export function clearSsTextCache() {
  db = new Map();
  loaded = false;
  clearSiteTextsCache();
}

export function ssText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = SHIFT_STAFF_TEXTS[lang]?.[key] ?? SHIFT_STAFF_TEXTS.fi[key] ?? key;
  return vars ? fillSsText(raw, vars) : raw;
}
