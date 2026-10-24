// Hallinnan hyvitys ↔ peruutus -kysymysten tekstit (FI + EN). Avaimet: ui.admin.refund_cancel.* (§18).
// Sama mekanismi kuin päivänäkymässä (day-texts.js): public_get_site_texts (rpc), kieli talous-i18n
// (?lang= / localStorage booking.admin.lang). Sanakirja REFUND_CANCEL_TEXTS on vain varalla: rivi puuttuu, haku
// epäonnistuu tai paikkamerkki ei täyty. Tuonti: content/site-texts.pending-import-37.json.
import { getLang } from './talous-i18n.js';
import { getSiteTexts, clearSiteTextsCache } from './site-texts-cache.js';

export const REFUND_CANCEL_TEXTS = {
  fi: {
    'ui.admin.refund_cancel.order_question': 'Perutaanko myös tilauksen varaukset?',
    'ui.admin.refund_cancel.order_count': 'Tilauksessa on voimassa olevia varauksia: {{var:count}}.',
    'ui.admin.refund_cancel.order_no': 'Ei, varaukset jäävät voimaan',
    'ui.admin.refund_cancel.order_yes': 'Kyllä, peru tilauksen varaukset',
    'ui.admin.refund_cancel.order_cancelled': 'Varauksia peruttu: {{var:count}}.',
    'ui.admin.refund_cancel.cancel_title': 'Peru varaus',
    'ui.admin.refund_cancel.cancel_confirm': 'Perutaanko varaus?',
    'ui.admin.refund_cancel.refund_question': 'Hyvitetäänkö varauksen maksut?',
    'ui.admin.refund_cancel.refund_share': 'Varauksen osuus maksuista: {{var:amount}}',
    'ui.admin.refund_cancel.refund_share_note': 'Summa on varauksen rivi ja sen lisäpalvelut. Aiemmat hyvitykset on vähennetty.',
    'ui.admin.refund_cancel.refund_no': 'Ei, peru ilman hyvitystä',
    'ui.admin.refund_cancel.refund_yes': 'Kyllä, hyvitä {{var:amount}}',
    'ui.admin.refund_cancel.refund_reason': 'Hyvityksen syy',
    'ui.admin.refund_cancel.refund_none': 'Varaukselle ei ole hyvitettävää maksua.',
    'ui.admin.refund_cancel.refund_online_off': 'Verkkomaksun hyvitys ei ole vielä käytössä. Peru ilman hyvitystä ja hyvitä maksu maksupalvelun kautta.',
    'ui.admin.refund_cancel.refund_unallocated': 'Osa maksuista on kirjattu ilman rivierittelyä. Hyvitä ne tarvittaessa Talous-näkymässä.',
    'ui.admin.refund_cancel.refund_unavailable': 'Hyvitystietoja ei saatu. Voit perua varauksen ilman hyvitystä.',
    'ui.admin.refund_cancel.submit': 'Peru varaus',
    'ui.admin.refund_cancel.back': 'Takaisin',
    'ui.admin.refund_cancel.done_cancelled': 'Varaus peruttu.',
    'ui.admin.refund_cancel.done_refunded': 'Varaus peruttu ja hyvitetty {{var:amount}}.',
  },
  en: {
    'ui.admin.refund_cancel.order_question': "Also cancel the order's bookings?",
    'ui.admin.refund_cancel.order_count': 'Active bookings on the order: {{var:count}}.',
    'ui.admin.refund_cancel.order_no': 'No, keep the bookings',
    'ui.admin.refund_cancel.order_yes': "Yes, cancel the order's bookings",
    'ui.admin.refund_cancel.order_cancelled': 'Bookings cancelled: {{var:count}}.',
    'ui.admin.refund_cancel.cancel_title': 'Cancel booking',
    'ui.admin.refund_cancel.cancel_confirm': 'Cancel this booking?',
    'ui.admin.refund_cancel.refund_question': "Refund this booking's payments?",
    'ui.admin.refund_cancel.refund_share': "This booking's share of the payments: {{var:amount}}",
    'ui.admin.refund_cancel.refund_share_note': 'The amount is the booking line and its add-ons. Earlier refunds have been deducted.',
    'ui.admin.refund_cancel.refund_no': 'No, cancel without a refund',
    'ui.admin.refund_cancel.refund_yes': 'Yes, refund {{var:amount}}',
    'ui.admin.refund_cancel.refund_reason': 'Refund reason',
    'ui.admin.refund_cancel.refund_none': 'There is no payment to refund for this booking.',
    'ui.admin.refund_cancel.refund_online_off': 'Online payment refunds are not in use yet. Cancel without a refund and refund the payment through the payment provider.',
    'ui.admin.refund_cancel.refund_unallocated': 'Some payments were recorded without line details. Refund them in the Finance view if needed.',
    'ui.admin.refund_cancel.refund_unavailable': 'Refund details could not be loaded. You can cancel the booking without a refund.',
    'ui.admin.refund_cancel.submit': 'Cancel booking',
    'ui.admin.refund_cancel.back': 'Back',
    'ui.admin.refund_cancel.done_cancelled': 'Booking cancelled.',
    'ui.admin.refund_cancel.done_refunded': 'Booking cancelled and {{var:amount}} refunded.',
  },
};

const PREFIX = 'ui.admin.refund_cancel.';
let db = new Map();
let loaded = false;

export function fillRcText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

/** Täyttää {{var:nimi}}. Tuntematon paikkamerkki tai puuttuva arvo → null (kutsuja käyttää sanakirjaa). */
function applyLive(raw, vars) {
  for (const m of String(raw).matchAll(/\{\{([^{}]*)\}\}/g)) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  const out = fillRcText(raw, vars);
  return /\{\{|\}\}/.test(out) ? null : out;
}

function primeRcTexts(rows) {
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

/** Hakee ui.admin.refund_cancel.*-rivit kerran sivulatauksessa. Virhe ei kaada dialogia: rcText käyttää sanakirjaa. */
export async function loadRcTexts(rpcFn, rows = null) {
  if (primeRcTexts(rows)) return true;
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await getSiteTexts(rpcFn);
    if (!t || t.ok !== true || !Array.isArray(t.texts)) return false;
    return primeRcTexts(t.texts);
  } catch {
    return false;
  }
}

export function clearRcTextCache() {
  db = new Map();
  loaded = false;
  clearSiteTextsCache();
}

export function rcText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = REFUND_CANCEL_TEXTS[lang]?.[key] ?? REFUND_CANCEL_TEXTS.fi[key] ?? key;
  return vars ? fillRcText(raw, vars) : raw;
}
