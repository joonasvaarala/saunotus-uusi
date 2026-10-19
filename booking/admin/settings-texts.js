// Asetusten välilehdet ja QR-tulostus (FI+EN). Avaimet ui.admin.settings.* ja ui.admin.qr.*
// public_get_site_texts peittää sanakirjan. Tuonti: content/site-texts.pending-import-16.json.
// Sijaintikentän nimi: content/site-texts.pending-import-24.json (ui.admin.qr.location).
import { getLang } from './talous-i18n.js';

export const SETTINGS_TEXTS = {
  fi: {
    'ui.admin.settings.title': 'Asetukset',
    'ui.admin.settings.readonly': 'Näet asetukset. Muokkaus vaatii ylläpitäjän oikeudet.',
    'ui.admin.settings.tabs': 'Asetusten osiot',
    'ui.admin.settings.tab_yleiset': 'Yleiset',
    'ui.admin.settings.tab_varaukset': 'Varaukset',
    'ui.admin.settings.tab_maksut': 'Maksut',
    'ui.admin.settings.tab_sahkoposti': 'Sähköposti',
    'ui.admin.settings.tab_laskutus': 'Laskutus',
    'ui.admin.settings.tab_kirjanpito': 'Kirjanpito ja Procountor',
    'ui.admin.settings.tab_lahjakortit': 'Lahjakortit',
    'ui.admin.settings.tab_rajat': 'Rajoitukset',
    'ui.admin.settings.tab_qr': 'QR-koodin tulostus',
    'ui.admin.settings.save': 'Tallenna',
    'ui.admin.settings.saved': 'Tallennettu',
    'ui.admin.qr.lead': 'Valitse tuote, johon koodi johtaa. Tuotteen ei tarvitse näkyä verkkokaupassa.',
    'ui.admin.qr.search': 'Hae tuotetta',
    'ui.admin.qr.add': 'Lisää tuote',
    'ui.admin.qr.label': 'Tarra',
    'ui.admin.qr.location': 'Sijainti (näkyy tarrassa, valinnainen)',
    'ui.admin.qr.label_ph': 'Esimerkiksi pukuhuoneen jääkaappi',
    'ui.admin.qr.empty': 'QR-koodeja ei ole vielä. Lisää tuote, niin saat tulostettavan koodin.',
    'ui.admin.qr.print': 'Tulosta',
    'ui.admin.qr.download_png': 'Lataa PNG',
    'ui.admin.qr.download_svg': 'Lataa SVG',
    'ui.admin.qr.scan': 'Skannaa ja osta',
    'ui.admin.qr.remove': 'Poista',
    'ui.admin.qr.preview': 'Esikatselu',
    'ui.admin.qr.include': 'Arkille',
    'ui.admin.qr.age': 'Ikärajallista tuotetta ei voi myydä QR-linkillä',
    'ui.admin.qr.hidden': 'Ei verkkokaupassa',
    'ui.admin.qr.create': 'Luo QR-koodi',
    'ui.admin.qr.product': 'Tuote',
    'ui.admin.qr.sheet': 'Tulostusarkki',
    'ui.admin.qr.saved': 'QR-koodi luotu',
    'ui.admin.qr.removed': 'QR-koodi poistettu',
    'ui.admin.qr.pick': 'Valitse tuote listasta',
    'ui.admin.qr.price': 'Hinta',
  },
  en: {
    'ui.admin.settings.title': 'Settings',
    'ui.admin.settings.readonly': 'You can view settings. Editing requires an administrator.',
    'ui.admin.settings.tabs': 'Settings sections',
    'ui.admin.settings.tab_yleiset': 'General',
    'ui.admin.settings.tab_varaukset': 'Bookings',
    'ui.admin.settings.tab_maksut': 'Payments',
    'ui.admin.settings.tab_sahkoposti': 'Email',
    'ui.admin.settings.tab_laskutus': 'Invoicing',
    'ui.admin.settings.tab_kirjanpito': 'Accounting and Procountor',
    'ui.admin.settings.tab_lahjakortit': 'Gift cards',
    'ui.admin.settings.tab_rajat': 'Limits',
    'ui.admin.settings.tab_qr': 'Print QR codes',
    'ui.admin.settings.save': 'Save',
    'ui.admin.settings.saved': 'Saved',
    'ui.admin.qr.lead': 'Choose the product the code opens. The product does not have to appear in the shop.',
    'ui.admin.qr.search': 'Search for a product',
    'ui.admin.qr.add': 'Add product',
    'ui.admin.qr.label': 'Label',
    'ui.admin.qr.location': 'Location (shown on the sticker, optional)',
    'ui.admin.qr.label_ph': 'For example a changing-room fridge',
    'ui.admin.qr.empty': 'There are no QR codes yet. Add a product to get a code you can print.',
    'ui.admin.qr.print': 'Print',
    'ui.admin.qr.download_png': 'Download PNG',
    'ui.admin.qr.download_svg': 'Download SVG',
    'ui.admin.qr.scan': 'Scan and buy',
    'ui.admin.qr.remove': 'Remove',
    'ui.admin.qr.preview': 'Preview',
    'ui.admin.qr.include': 'On the sheet',
    'ui.admin.qr.age': 'An age-restricted product cannot be sold with a QR link',
    'ui.admin.qr.hidden': 'Not in the shop',
    'ui.admin.qr.create': 'Create QR code',
    'ui.admin.qr.product': 'Product',
    'ui.admin.qr.sheet': 'Print sheet',
    'ui.admin.qr.saved': 'QR code created',
    'ui.admin.qr.removed': 'QR code removed',
    'ui.admin.qr.pick': 'Choose a product from the list',
    'ui.admin.qr.price': 'Price',
  },
};

const PREFIXES = ['ui.admin.settings.', 'ui.admin.qr.'];
let db = new Map();
let loaded = false;

export async function loadSettingsTexts(rpcFn) {
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await rpcFn('public_get_site_texts', { p_lang: null });
    if (!t || t.ok !== true || !Array.isArray(t.texts)) return false;
    const next = new Map();
    for (const r of t.texts) {
      if (!r || typeof r.key !== 'string' || !PREFIXES.some((p) => r.key.startsWith(p))) continue;
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

export function clearSettingsTextCache() {
  db = new Map();
  loaded = false;
}

export function settingsText(key, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  if (live) return live;
  return SETTINGS_TEXTS[lang]?.[key] ?? SETTINGS_TEXTS.fi[key] ?? key;
}
