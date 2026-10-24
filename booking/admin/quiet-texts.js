// Hallinnan Hiljaiset ajat -näkymän tekstit (FI + EN). Avaimet: ui.admin.quiet.* (booking_162). Sama mekanismi kuin annual-card-texts.js:
// public_get_site_texts (site-texts-cache.js), kieli talous-i18n (?lang= / localStorage booking.admin.lang). Sanakirja on varalla:
// rivi puuttuu, haku epäonnistuu tai paikkamerkki ei täyty. Tuonti: content/site-texts.pending-import-59.json.
import { getLang } from './talous-i18n.js';
import { getSiteTexts, clearSiteTextsCache } from './site-texts-cache.js';

export const QUIET_ADMIN_TEXTS = {
  fi: {
    'ui.admin.quiet.title': 'Hiljaiset ajat',
    'ui.admin.quiet.intro': 'Hiljaisten aikojen ale laskee vielä tyhjän vuoron hintaa, kun vuoron alkuun on vähän aikaa. Ale koskee vain verkkokaupan varauksia ja koko vuoron hintaa lisähenkilöineen. Sitä ei yhdistetä alennuskoodiin tai vuosikorttiin: edullisempi etu voittaa. Hinta lukitaan varaushetkellä, ja vuoron siirto poistaa alen.',
    'ui.admin.quiet.status_on': 'Käytössä: ale näkyy asiakkaille',
    'ui.admin.quiet.status_off': 'Pois päältä: ale ei näy asiakkaille',
    'ui.admin.quiet.enable': 'Ota käyttöön',
    'ui.admin.quiet.disable': 'Poista käytöstä',
    'ui.admin.quiet.enable_confirm': 'Otetaanko hiljaisten aikojen ale käyttöön? Ale alkaa näkyä verkkokaupassa, etusivulla ja viikko-ohjelmassa heti.',
    'ui.admin.quiet.disable_confirm': 'Poistetaanko hiljaisten aikojen ale käytöstä? Jo tehdyt varaukset säilyttävät lukitun hintansa.',
    'ui.admin.quiet.status_saved': 'Tila tallennettu.',
    'ui.admin.quiet.toggle_readonly': 'Alen kytkeminen päälle tai pois vaatii asetusten muokkausoikeuden.',
    'ui.admin.quiet.rules': 'Portaat',
    'ui.admin.quiet.new': 'Uusi porras',
    'ui.admin.quiet.edit': 'Muokkaa',
    'ui.admin.quiet.delete': 'Poista',
    'ui.admin.quiet.delete_confirm': 'Poistetaanko porras {{var:name}}?',
    'ui.admin.quiet.deleted': 'Porras poistettu.',
    'ui.admin.quiet.saved': 'Porras tallennettu.',
    'ui.admin.quiet.no_rules': 'Ei portaita.',
    'ui.admin.quiet.readonly': 'Portaiden muokkaus vaatii tuotteiden muokkausoikeuden.',
    'ui.admin.quiet.active': 'Aktiivinen',
    'ui.admin.quiet.inactive': 'Ei käytössä',
    'ui.admin.quiet.rule_line': '{{var:products}} · enintään {{var:hours}} h ennen alkua · −{{var:pct}} %',
    'ui.admin.quiet.condition': 'Vain kokonaan tyhjä vuoro (ei varauksia samassa tilassa eikä sulkua), vain verkkokauppa.',
    'ui.admin.quiet.valid_from': 'alkaa {{var:date}}',
    'ui.admin.quiet.valid_to': 'päättyy {{var:date}}',
    'ui.admin.quiet.name': 'Nimi (suomi)',
    'ui.admin.quiet.name_en': 'Nimi (englanti)',
    'ui.admin.quiet.products': 'Tuotteet',
    'ui.admin.quiet.hours': 'Tunteja ennen vuoron alkua (enintään)',
    'ui.admin.quiet.percent': 'Ale (%)',
    'ui.admin.quiet.from': 'Voimassa alkaen',
    'ui.admin.quiet.to': 'Voimassa asti',
    'ui.admin.quiet.save': 'Tallenna',
    'ui.admin.quiet.cancel': 'Peruuta',
    'ui.admin.quiet.v_name': 'Anna nimi (enintään 80 merkkiä).',
    'ui.admin.quiet.v_percent': 'Ale on 0,01–90 % (enintään kaksi desimaalia).',
    'ui.admin.quiet.v_hours': 'Tunnit ovat kokonaisluku 1–336.',
    'ui.admin.quiet.v_products': 'Valitse vähintään yksi tuote.',
    'ui.admin.quiet.v_dates': 'Voimassaolon loppu on ennen alkua.',
    'ui.admin.quiet.v_overlap': 'Samalle tuotteelle on jo aktiivinen porras samalla tuntimäärällä.',
    'ui.admin.quiet.preview': 'Esikatselu',
    'ui.admin.quiet.preview_intro': 'Vuorot, jotka saisivat alen nyt. Esikatselu näkyy myös, kun ale on pois päältä.',
    'ui.admin.quiet.days': 'Päiviä',
    'ui.admin.quiet.refresh': 'Päivitä',
    'ui.admin.quiet.no_preview': 'Ei alennettavia vuoroja valitulla aikavälillä.',
    'ui.admin.quiet.preview_line': 'Porras {{var:hours}} h · −{{var:pct}} %',
  },
  en: {
    'ui.admin.quiet.title': 'Quiet times',
    'ui.admin.quiet.intro': 'The quiet-time discount lowers the price of a session that is still empty when its start is near. It applies only to online shop bookings and to the whole session price including extra guests. It is not combined with a discount code or an annual card: the better benefit wins. The price is locked when booking, and moving the booking removes the discount.',
    'ui.admin.quiet.status_on': 'On: customers see the discount',
    'ui.admin.quiet.status_off': 'Off: customers do not see the discount',
    'ui.admin.quiet.enable': 'Turn on',
    'ui.admin.quiet.disable': 'Turn off',
    'ui.admin.quiet.enable_confirm': 'Turn on the quiet-time discount? It appears in the online shop, on the front page and in the weekly programme right away.',
    'ui.admin.quiet.disable_confirm': 'Turn off the quiet-time discount? Existing bookings keep their locked price.',
    'ui.admin.quiet.status_saved': 'Status saved.',
    'ui.admin.quiet.toggle_readonly': 'Turning the discount on or off requires permission to edit settings.',
    'ui.admin.quiet.rules': 'Tiers',
    'ui.admin.quiet.new': 'New tier',
    'ui.admin.quiet.edit': 'Edit',
    'ui.admin.quiet.delete': 'Delete',
    'ui.admin.quiet.delete_confirm': 'Delete tier {{var:name}}?',
    'ui.admin.quiet.deleted': 'Tier deleted.',
    'ui.admin.quiet.saved': 'Tier saved.',
    'ui.admin.quiet.no_rules': 'No tiers.',
    'ui.admin.quiet.readonly': 'Editing tiers requires permission to edit products.',
    'ui.admin.quiet.active': 'Active',
    'ui.admin.quiet.inactive': 'Not in use',
    'ui.admin.quiet.rule_line': '{{var:products}} · up to {{var:hours}} h before start · −{{var:pct}}%',
    'ui.admin.quiet.condition': 'Only a completely empty session (no bookings in the same space and no closure), online shop only.',
    'ui.admin.quiet.valid_from': 'starts {{var:date}}',
    'ui.admin.quiet.valid_to': 'ends {{var:date}}',
    'ui.admin.quiet.name': 'Name (Finnish)',
    'ui.admin.quiet.name_en': 'Name (English)',
    'ui.admin.quiet.products': 'Products',
    'ui.admin.quiet.hours': 'Hours before the session starts (at most)',
    'ui.admin.quiet.percent': 'Discount (%)',
    'ui.admin.quiet.from': 'Valid from',
    'ui.admin.quiet.to': 'Valid until',
    'ui.admin.quiet.save': 'Save',
    'ui.admin.quiet.cancel': 'Cancel',
    'ui.admin.quiet.v_name': 'Enter a name (at most 80 characters).',
    'ui.admin.quiet.v_percent': 'The discount is 0.01–90% (at most two decimals).',
    'ui.admin.quiet.v_hours': 'Hours must be a whole number 1–336.',
    'ui.admin.quiet.v_products': 'Select at least one product.',
    'ui.admin.quiet.v_dates': 'The end of validity is before the start.',
    'ui.admin.quiet.v_overlap': 'This product already has an active tier with the same number of hours.',
    'ui.admin.quiet.preview': 'Preview',
    'ui.admin.quiet.preview_intro': 'Sessions that would get the discount now. The preview works even when the discount is off.',
    'ui.admin.quiet.days': 'Days',
    'ui.admin.quiet.refresh': 'Refresh',
    'ui.admin.quiet.no_preview': 'No sessions to discount in the selected period.',
    'ui.admin.quiet.preview_line': 'Tier {{var:hours}} h · −{{var:pct}}%',
  },
};

const PREFIX = 'ui.admin.quiet.';
let db = new Map();
let loaded = false;
export const fillQuietText = (text, vars) => String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
function applyLive(raw, vars) {
  for (const m of String(raw).matchAll(/\{\{([^{}]*)\}\}/g)) { const n = /^var:([a-z0-9_]+)$/.exec(m[1]); if (!n || vars?.[n[1]] == null) return null; }
  const out = fillQuietText(raw, vars);
  return /\{\{|\}\}/.test(out) ? null : out;
}
function prime(rows) {
  if (!Array.isArray(rows)) return false;
  const next = new Map();
  for (const r of rows) {
    if (!r || typeof r.key !== 'string' || !r.key.startsWith(PREFIX) || (r.lang !== 'fi' && r.lang !== 'en') || typeof r.text !== 'string' || !r.text.trim()) continue;
    next.set(`${r.key}|${r.lang}`, r.text);
  }
  db = next; loaded = true; return true;
}
/** Hakee ui.admin.quiet.*-rivit kerran sivulatauksessa. Virhe ei kaada näkymää: quietText käyttää sanakirjaa. */
export async function loadQuietTexts(rpcFn, rows = null) {
  if (prime(rows)) return true;
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try { const t = await getSiteTexts(rpcFn); return !!(t && t.ok === true && Array.isArray(t.texts)) && prime(t.texts); } catch { return false; }
}
export function clearQuietTextCache() { db = new Map(); loaded = false; clearSiteTextsCache(); }
export function quietText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = QUIET_ADMIN_TEXTS[lang]?.[key] ?? QUIET_ADMIN_TEXTS.fi[key] ?? key;
  return vars ? fillQuietText(raw, vars) : raw;
}
