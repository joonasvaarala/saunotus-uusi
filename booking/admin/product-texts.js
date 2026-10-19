// Hallinnan tuotelistan "Lisää tuote" -tekstit (FI+EN). Tuotannossa sama sisältö tuodaan site_texts-tauluun
// (content/site-texts.pending-import-19.json). Sanakirja on varalla, kunnes tuonti on ajettu.
// public_get_site_texts peittää ui.admin.product.*-avaimet. Haku epäonnistuu tai rivi puuttuu → sanakirja.
// Hintoja ja ALV-kantoja ei ole näissä teksteissä.
import { getLang } from './talous-i18n.js';

export const PREFIX = 'ui.admin.product.';

export const PRODUCT_TEXTS = {
  fi: {
    'ui.admin.product.add': 'Lisää tuote',
    'ui.admin.product.new_title': 'Uusi tuote',
    'ui.admin.product.create': 'Luo tuote',
    'ui.admin.product.created': 'Tuote luotu',
    'ui.admin.product.name_fi': 'Nimi (suomi)',
    'ui.admin.product.name_en': 'Nimi (englanti)',
    'ui.admin.product.name_en_hint': 'Valinnainen. Tyhjä kenttä tallentaa saman nimen kuin suomeksi.',
    'ui.admin.product.price': 'Hinta euroina (sis. alv)',
    'ui.admin.product.price_text': 'Hintateksti',
    'ui.admin.product.price_text_hint': 'Vapaaehtoinen. Tyhjä kenttä täytetään hinnasta.',
    'ui.admin.product.vat': 'Alv-prosentti',
    'ui.admin.product.category': 'Kategoria',
    'ui.admin.product.cat_rental': 'Tuotteet ja vuokrat',
    'ui.admin.product.cat_other': 'Muu',
    'ui.admin.product.active': 'Aktiivinen',
    'ui.admin.product.shop': 'Näkyy verkkokaupassa',
    'ui.admin.product.age': 'Ikärajallinen',
    'ui.admin.product.next': 'Tallennuksen jälkeen tuotteen voi lisätä pikakassaan ja sille voi tehdä QR-koodin.',
    'ui.admin.product.link_pos': 'Avaa pikakassa',
    'ui.admin.product.link_qr': 'Avaa QR-koodin tulostus',
    'ui.admin.product.pos_hint': 'Rastita pikakassa ja tallenna asetukset.',
    'ui.admin.product.qr_hint': 'QR-koodi tehdään asetusten tulostusnäkymässä.',
    'ui.admin.product.duplicate': 'Samanniminen aktiivinen tuote on jo olemassa',
  },
  en: {
    'ui.admin.product.add': 'Add product',
    'ui.admin.product.new_title': 'New product',
    'ui.admin.product.create': 'Create product',
    'ui.admin.product.created': 'Product created',
    'ui.admin.product.name_fi': 'Name in Finnish',
    'ui.admin.product.name_en': 'Name in English',
    'ui.admin.product.name_en_hint': 'Optional. An empty field saves the same name as in Finnish.',
    'ui.admin.product.price': 'Price in euros, including VAT',
    'ui.admin.product.price_text': 'Price text',
    'ui.admin.product.price_text_hint': 'Optional. An empty field is filled from the price.',
    'ui.admin.product.vat': 'VAT rate',
    'ui.admin.product.category': 'Category',
    'ui.admin.product.cat_rental': 'Products and rentals',
    'ui.admin.product.cat_other': 'Other',
    'ui.admin.product.active': 'Active',
    'ui.admin.product.shop': 'Visible in the web shop',
    'ui.admin.product.age': 'Age-restricted',
    'ui.admin.product.next': 'After saving, the product can be added to the quick till and a QR code can be printed for it.',
    'ui.admin.product.link_pos': 'Open quick till',
    'ui.admin.product.link_qr': 'Open QR printing',
    'ui.admin.product.pos_hint': 'Tick the quick till box and save the settings.',
    'ui.admin.product.qr_hint': 'The QR code is created in settings, under QR printing.',
    'ui.admin.product.duplicate': 'An active product with this name already exists',
  },
};

let db = new Map();
let loaded = false;

export async function loadProductTexts(rpcFn) {
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

export function clearProductTextCache() {
  db = new Map();
  loaded = false;
}

export function productText(key, lang = getLang()) {
  const full = key.startsWith(PREFIX) ? key : PREFIX + key;
  const live = db.get(`${full}|${lang}`);
  if (live) return live;
  return PRODUCT_TEXTS[lang]?.[full] || PRODUCT_TEXTS.fi[full] || key;
}
