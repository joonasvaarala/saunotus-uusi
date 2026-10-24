// booking_173: kumppanilahjakorttien lunastus hallinnassa (FI + EN). Avaimet ui.admin.vcr.* (§18).
// Sama mekanismi kuin Tarkista-sivu (review-texts.js): public_get_site_texts, kieli talous-i18n. Sanakirja on varalla.
// Tuonti: content/site-texts.pending-import-68.json. Arvoissa ei '<'-merkkiä.
import { getLang } from './talous-i18n.js';

export const VCR_TEXTS = {
  fi: {
    'ui.admin.vcr.box_title': 'Kumppanin lahjakortti',
    'ui.admin.vcr.code': 'Asiakkaan antama koodi',
    'ui.admin.vcr.copy': 'Kopioi',
    'ui.admin.vcr.copied': 'Koodi kopioitu',
    'ui.admin.vcr.copy_failed': 'Kopiointi ei onnistunut – valitse koodi ja kopioi käsin.',
    'ui.admin.vcr.guess': 'Järjestelmän arvaus',
    'ui.admin.vcr.choice': 'Asiakkaan valinta',
    'ui.admin.vcr.seller': 'Myyjä',
    'ui.admin.vcr.no_guess': 'ei arvausta',
    'ui.admin.vcr.conf_high': 'varma',
    'ui.admin.vcr.conf_medium': 'todennäköinen',
    'ui.admin.vcr.conf_low': 'arvaus',
    'ui.admin.vcr.differs': 'Asiakkaan valinta eroaa järjestelmän arvauksesta. Tarkista myyjä ennen lunastusta.',
    'ui.admin.vcr.method': 'Maksutapa',
    'ui.admin.vcr.amount': 'Summa',
    'ui.admin.vcr.unpaid': 'Maksamatta {{var:amount}}',
    'ui.admin.vcr.change_seller': 'Vaihda myyjä',
    'ui.admin.vcr.seller_saved': 'Myyjä vaihdettu: {{var:source}}. Maksutapa ja Procountor-tili seuraavat valintaa.',
    'ui.admin.vcr.redeem': 'Lunasta ({{var:source}})',
    'ui.admin.vcr.redeem_title': 'Avaa myyjän lunastussivu uuteen välilehteen',
    'ui.admin.vcr.no_url': 'Lunastussivua ei ole asetettu (Asetukset › Lahjakortit › Lunastussivut).',
    'ui.admin.vcr.mark': 'Merkitse lunastetuksi',
    'ui.admin.vcr.mark_confirm': 'Lunastitko koodin myyjän sivulla? Kirjataan maksu {{var:amount}} maksutavalla {{var:method}}.',
    'ui.admin.vcr.mark_yes': 'Kyllä, merkitse lunastetuksi',
    'ui.admin.vcr.cancel': 'Peru',
    'ui.admin.vcr.marked': 'Merkitty lunastetuksi: {{var:method}} {{var:amount}}.',
    'ui.admin.vcr.already': 'Oli jo merkitty lunastetuksi.',
    'ui.admin.vcr.redeemed': 'Lunastettu {{var:when}}',
    'ui.admin.vcr.by_staff': 'henkilökunta',
    'ui.admin.vcr.by_bot': 'botti',
    'ui.admin.vcr.order': 'Tilaus #{{var:no}}',
    'ui.admin.vcr.reservation': 'Varaus {{var:when}}',
    'ui.admin.vcr.no_right': 'Muutokset vaativat oikeuden giftcards.manage.',
    'ui.admin.vcr.section_title': 'Lunastamattomat kumppanilahjakortit',
    'ui.admin.vcr.section_hint': 'Asiakkaiden antamat Kokemuskauppa-, Offerilla- ja Elämyslahjat-koodit, joita ei ole vielä lunastettu myyjän sivulla. Kopioi koodi, avaa lunastussivu, lunasta ja merkitse lunastetuksi.',
    'ui.admin.vcr.filter_all': 'Kaikki',
    'ui.admin.vcr.filter_label': 'Näytä myyjä',
    'ui.admin.vcr.empty': 'Ei lunastamattomia kumppanilahjakortteja.',
    'ui.admin.vcr.load_failed': 'Lunastamattomia lahjakortteja ei saatu haettua: {{var:error}}',
    'ui.admin.vcr.urls_title': 'Lunastussivut',
    'ui.admin.vcr.urls_lead': 'Kumppanin sivu, jolla koodi lunastetaan. Lunasta-nappi avaa osoitteen uuteen välilehteen. Vain https-osoitteet; tyhjä kenttä poistaa linkin.',
    'ui.admin.vcr.urls_save': 'Tallenna lunastussivut',
    'ui.admin.vcr.urls_saved': 'Lunastussivut tallennettu',
    'ui.admin.vcr.urls_bad': 'Tarkista osoite: {{var:sources}}. Osoitteen pitää olla https-osoite.',
    'ui.admin.vcr.err_invalid_state': 'Lahjakortti on jo käsitelty – päivitä näkymä.',
    'ui.admin.vcr.err_forbidden': 'Ei oikeutta tähän toimintoon.',
    'ui.admin.vcr.err_unchanged': 'Myyjä on jo sama.',
    'ui.admin.vcr.legacy': 'Vanha myyjä',
  },
  en: {
    'ui.admin.vcr.box_title': 'Partner gift card',
    'ui.admin.vcr.code': 'Code entered by the customer',
    'ui.admin.vcr.copy': 'Copy',
    'ui.admin.vcr.copied': 'Code copied',
    'ui.admin.vcr.copy_failed': 'Copying failed – select the code and copy it manually.',
    'ui.admin.vcr.guess': 'System guess',
    'ui.admin.vcr.choice': 'Customer’s choice',
    'ui.admin.vcr.seller': 'Seller',
    'ui.admin.vcr.no_guess': 'no guess',
    'ui.admin.vcr.conf_high': 'certain',
    'ui.admin.vcr.conf_medium': 'likely',
    'ui.admin.vcr.conf_low': 'guess',
    'ui.admin.vcr.differs': 'The customer’s choice differs from the system guess. Check the seller before redeeming.',
    'ui.admin.vcr.method': 'Payment method',
    'ui.admin.vcr.amount': 'Amount',
    'ui.admin.vcr.unpaid': 'Unpaid {{var:amount}}',
    'ui.admin.vcr.change_seller': 'Change seller',
    'ui.admin.vcr.seller_saved': 'Seller changed: {{var:source}}. The payment method and Procountor account follow the choice.',
    'ui.admin.vcr.redeem': 'Redeem ({{var:source}})',
    'ui.admin.vcr.redeem_title': 'Open the seller’s redemption page in a new tab',
    'ui.admin.vcr.no_url': 'No redemption page set (Settings › Gift cards › Redemption pages).',
    'ui.admin.vcr.mark': 'Mark as redeemed',
    'ui.admin.vcr.mark_confirm': 'Did you redeem the code on the seller’s page? A payment of {{var:amount}} is recorded with the method {{var:method}}.',
    'ui.admin.vcr.mark_yes': 'Yes, mark as redeemed',
    'ui.admin.vcr.cancel': 'Cancel',
    'ui.admin.vcr.marked': 'Marked as redeemed: {{var:method}} {{var:amount}}.',
    'ui.admin.vcr.already': 'It was already marked as redeemed.',
    'ui.admin.vcr.redeemed': 'Redeemed {{var:when}}',
    'ui.admin.vcr.by_staff': 'staff',
    'ui.admin.vcr.by_bot': 'bot',
    'ui.admin.vcr.order': 'Order #{{var:no}}',
    'ui.admin.vcr.reservation': 'Booking {{var:when}}',
    'ui.admin.vcr.no_right': 'Changes require the giftcards.manage permission.',
    'ui.admin.vcr.section_title': 'Unredeemed partner gift cards',
    'ui.admin.vcr.section_hint': 'Kokemuskauppa, Offerilla and Elämyslahjat codes entered by customers that have not yet been redeemed on the seller’s page. Copy the code, open the redemption page, redeem it and mark it as redeemed.',
    'ui.admin.vcr.filter_all': 'All',
    'ui.admin.vcr.filter_label': 'Show seller',
    'ui.admin.vcr.empty': 'No unredeemed partner gift cards.',
    'ui.admin.vcr.load_failed': 'Could not load the unredeemed gift cards: {{var:error}}',
    'ui.admin.vcr.urls_title': 'Redemption pages',
    'ui.admin.vcr.urls_lead': 'The partner page where the code is redeemed. The Redeem button opens the address in a new tab. Only https addresses; an empty field removes the link.',
    'ui.admin.vcr.urls_save': 'Save redemption pages',
    'ui.admin.vcr.urls_saved': 'Redemption pages saved',
    'ui.admin.vcr.urls_bad': 'Check the address: {{var:sources}}. It must be an https address.',
    'ui.admin.vcr.err_invalid_state': 'The gift card has already been handled – refresh the view.',
    'ui.admin.vcr.err_forbidden': 'You do not have permission for this action.',
    'ui.admin.vcr.err_unchanged': 'The seller is already the same.',
    'ui.admin.vcr.legacy': 'Former seller',
  },
};

const PREFIX = 'ui.admin.vcr.';
let db = new Map();
let loaded = false;

export function fillVcrText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

function applyLive(raw, vars) {
  for (const m of String(raw).matchAll(/\{\{([^{}]*)\}\}/g)) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  const out = fillVcrText(raw, vars);
  return /\{\{|\}\}/.test(out) ? null : out;
}

/** Lukee ui.admin.vcr.*-rivit. Virhe ei kaada näkymää: vcrText käyttää sanakirjaa. */
export async function loadVcrTexts(rpcFn) {
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
    db = next; loaded = true;
    return true;
  } catch { return false; }
}

export function clearVcrTextCache() { db = new Map(); loaded = false; }

/** Teksti: tuotannon teksti, muuten sanakirja (FI varalla). Puuttuva muuttuja → tyhjä, ei koskaan "null"/"undefined". */
export function vcrText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = VCR_TEXTS[lang]?.[key] ?? VCR_TEXTS.fi[key] ?? key;
  return vars ? fillVcrText(raw, vars) : raw;
}
