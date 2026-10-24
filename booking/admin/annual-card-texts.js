// Hallinnan vuosikorttikoodin näytön tekstit (FI + EN). Avaimet: ui.admin.annual_card.* (§18, booking_146).
// Sama mekanismi kuin refund-cancel-texts.js: public_get_site_texts (rpc), kieli talous-i18n (?lang= / localStorage booking.admin.lang).
// Sanakirja ANNUAL_CARD_TEXTS on vain varalla: rivi puuttuu, haku epäonnistuu tai paikkamerkki ei täyty. Tuonti: content/site-texts.pending-import-46.json.
import { getLang } from './talous-i18n.js';
import { getSiteTexts, clearSiteTextsCache } from './site-texts-cache.js';

export const ANNUAL_CARD_TEXTS = {
  fi: {
    'ui.admin.annual_card.title': 'Vuosikortti',
    'ui.admin.annual_card.created': 'Vuosikortti on luotu',
    'ui.admin.annual_card.code_label': 'Vuosikorttikoodi',
    'ui.admin.annual_card.copy': 'Kopioi koodi',
    'ui.admin.annual_card.copied': 'Koodi kopioitu.',
    'ui.admin.annual_card.copy_failed': 'Kopiointi ei onnistunut. Valitse koodi ja kopioi se käsin.',
    'ui.admin.annual_card.valid': 'Voimassa {{var:from}}–{{var:to}}',
    'ui.admin.annual_card.revoked': 'Kortti on peruttu.',
    'ui.admin.annual_card.inactive': 'Kortti ei ole käytössä.',
    'ui.admin.annual_card.email_sent': 'Koodi lähetetty sähköpostiin {{var:to}}.',
    'ui.admin.annual_card.email_pending': 'Koodi lähtee sähköpostiin {{var:to}} hetken kuluttua.',
    'ui.admin.annual_card.email_dry_run': 'Sähköposti on testitilassa, joten koodia ei lähetetty asiakkaalle. Anna koodi asiakkaalle.',
    'ui.admin.annual_card.email_skipped': 'Sähköpostien lähetys on pois päältä, joten koodia ei lähetetty. Anna koodi asiakkaalle.',
    'ui.admin.annual_card.email_failed': 'Koodin lähetys sähköpostiin {{var:to}} epäonnistui. Anna koodi asiakkaalle.',
    'ui.admin.annual_card.email_no_email': 'Asiakkaalla ei ole sähköpostiosoitetta, joten koodia ei lähetetty. Anna koodi asiakkaalle.',
    'ui.admin.annual_card.email_not_queued': 'Koodia ei ole lähetetty sähköpostilla. Anna koodi asiakkaalle.',
    'ui.admin.annual_card.tell': 'Kerro asiakkaalle: varaus tehdään verkossa yhdelle hengelle, ja koodi kirjoitetaan kassalla kohtaan Alennus- tai vuosikorttikoodi.',
    'ui.admin.annual_card.waiting_payment': 'Vuosikortti ja koodi luodaan, kun tilaus on maksettu kokonaan.',
    'ui.admin.annual_card.no_customer': 'Tilauksella ei ole asiakasta, joten vuosikorttia ei luotu. Luo kortti Alennuskoodit ja vuosikortit -näkymässä.',
    'ui.admin.annual_card.missing': 'Vuosikorttia ei löytynyt. Tarkista Alennuskoodit ja vuosikortit -näkymä.',
    'ui.admin.annual_card.load_error': 'Vuosikortin tietoja ei saatu haettua. Tarkista kortti Alennuskoodit ja vuosikortit -näkymästä.',
    'ui.admin.annual_card.close': 'Valmis',
  },
  en: {
    'ui.admin.annual_card.title': 'Annual card',
    'ui.admin.annual_card.created': 'Annual card created',
    'ui.admin.annual_card.code_label': 'Annual card code',
    'ui.admin.annual_card.copy': 'Copy code',
    'ui.admin.annual_card.copied': 'Code copied.',
    'ui.admin.annual_card.copy_failed': 'Copying failed. Select the code and copy it manually.',
    'ui.admin.annual_card.valid': 'Valid {{var:from}}–{{var:to}}',
    'ui.admin.annual_card.revoked': 'The card has been revoked.',
    'ui.admin.annual_card.inactive': 'The card is not active.',
    'ui.admin.annual_card.email_sent': 'The code was sent to {{var:to}}.',
    'ui.admin.annual_card.email_pending': 'The code will be sent to {{var:to}} shortly.',
    'ui.admin.annual_card.email_dry_run': 'Email is in test mode, so the code was not sent to the customer. Give the code to the customer.',
    'ui.admin.annual_card.email_skipped': 'Email sending is turned off, so the code was not sent. Give the code to the customer.',
    'ui.admin.annual_card.email_failed': 'Sending the code to {{var:to}} failed. Give the code to the customer.',
    'ui.admin.annual_card.email_no_email': 'The customer has no email address, so the code was not sent. Give the code to the customer.',
    'ui.admin.annual_card.email_not_queued': 'The code has not been sent by email. Give the code to the customer.',
    'ui.admin.annual_card.tell': 'Tell the customer: book online for one person and enter the code at checkout in the Discount or annual card code field.',
    'ui.admin.annual_card.waiting_payment': 'The annual card and its code are created when the order is fully paid.',
    'ui.admin.annual_card.no_customer': 'The order has no customer, so no annual card was created. Create the card in the Discount codes and annual cards view.',
    'ui.admin.annual_card.missing': 'No annual card was found. Check the Discount codes and annual cards view.',
    'ui.admin.annual_card.load_error': 'The annual card details could not be loaded. Check the card in the Discount codes and annual cards view.',
    'ui.admin.annual_card.close': 'Done',
  },
};

const PREFIX = 'ui.admin.annual_card.';
let db = new Map();
let loaded = false;

export function fillAcText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

/** Täyttää {{var:nimi}}. Tuntematon paikkamerkki tai puuttuva arvo → null (kutsuja käyttää sanakirjaa). */
function applyLive(raw, vars) {
  for (const m of String(raw).matchAll(/\{\{([^{}]*)\}\}/g)) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  const out = fillAcText(raw, vars);
  return /\{\{|\}\}/.test(out) ? null : out;
}

function primeAcTexts(rows) {
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

/** Hakee ui.admin.annual_card.*-rivit kerran sivulatauksessa. Virhe ei kaada näkymää: acText käyttää sanakirjaa. */
export async function loadAcTexts(rpcFn, rows = null) {
  if (primeAcTexts(rows)) return true;
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await getSiteTexts(rpcFn);
    if (!t || t.ok !== true || !Array.isArray(t.texts)) return false;
    return primeAcTexts(t.texts);
  } catch {
    return false;
  }
}

export function clearAcTextCache() {
  db = new Map();
  loaded = false;
  clearSiteTextsCache();
}

export function acText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = ANNUAL_CARD_TEXTS[lang]?.[key] ?? ANNUAL_CARD_TEXTS.fi[key] ?? key;
  return vars ? fillAcText(raw, vars) : raw;
}
