// Talous-tilauslistan maksusuodattimen tekstit (FI + EN). Avaimet: ui.admin.orders.* .
// public_get_site_texts peittää sanakirjan. Haku epäonnistuu tai rivi puuttuu → ORDER_TEXTS.
// Tuonti: content/site-texts.pending-import-8.json (ei ylikirjoita olemassa olevia).
import { getLang } from './talous-i18n.js';

export const PREFIX = 'ui.admin.orders.';

export const ORDER_TEXTS = {
  fi: {
    'ui.admin.orders.pay_filter': 'Maksutila',
    'ui.admin.orders.pay_paid': 'Maksetut',
    'ui.admin.orders.pay_unpaid': 'Maksamattomat',
    'ui.admin.orders.pay_invoiced': 'Laskutetut',
    'ui.admin.orders.pay_all': 'Kaikki',
    'ui.admin.orders.pay_refunded': 'Hyvitetyt',
    'ui.admin.orders.pay_cancelled': 'Peruttu',
    'ui.admin.orders.pay_showing': 'Maksutila: {{var:label}}',
    'ui.admin.orders.search_all': 'Haku kaikista tilauksista',
    'ui.admin.orders.open_reservation': 'Avaa varaus',
    'ui.admin.orders.open_reservation_label': 'Avaa varaus: {{var:product}}, {{var:time}}',
    'ui.admin.orders.reservation_open_failed': 'Varauksen avaaminen ei onnistunut. Avaa varausluettelo.',
    'ui.admin.orders.add_purchase': 'Lisäosto tähän tilaukseen',
    'ui.admin.orders.add_type_addon': 'Lisäpalvelu varaukselle',
    'ui.admin.orders.add_type_reservation': 'Lisähoito tai -vuoro',
    'ui.admin.orders.add_type_product': 'Vuokratuote',
    'ui.admin.orders.rental': 'Vuokratuote',
    'ui.admin.orders.add_session': 'Saunavuoro',
    'ui.admin.orders.add_treatment': 'Hoito tai rituaali',
    'ui.admin.orders.book_kind': 'Varaustyyppi',
    'ui.admin.orders.choose_service': 'Valitse hoito tai rituaali',
    'ui.admin.orders.choose_day': 'Valitse päivä',
    'ui.admin.orders.choose_time': 'Valitse vapaa aika',
    'ui.admin.orders.persons': 'Henkilömäärä',
    'ui.admin.orders.loading_slots': 'Haetaan saatavuutta…',
    'ui.admin.orders.no_slots': 'Ei vapaita aikoja valitulle päivälle.',
    'ui.admin.orders.slots_found': 'Vapaita aikoja: {{var:n}}',
    'ui.admin.orders.slots_error': 'Saatavuuden haku epäonnistui',
    'ui.admin.orders.invalid_type': 'Virheellinen tuotetyyppi',
    'ui.admin.orders.purchase_no_email': 'Maksulinkkiä tai lisäostoa ei lähetetä sähköpostilla.',
    'ui.admin.orders.purchase_added': 'Lisäosto lisätty tilaukseen',
    'ui.admin.orders.purchase_link': 'Luo maksulinkki lisäostolle',
    'ui.admin.orders.purchase_record': 'Kirjaa maksu',
    'ui.admin.orders.purchase_leave': 'Jätä maksamatta',
    'ui.admin.orders.link_only_uncovered': 'Linkki koskee vain vielä kattamattomia tilausrivejä. Linkkiä ei lähetetä sähköpostiin.',
    'ui.admin.orders.link_copy': 'Kopioi maksulinkki',
    'ui.admin.orders.link_copied': 'Maksulinkki kopioitu',
    'ui.admin.orders.link_missing': 'Maksulinkin osoitetta ei palautettu',
    'ui.admin.orders.link_created': 'Maksulinkki luotu',
    'ui.admin.orders.bad_days': 'Voimassaolon on oltava 1–90 päivää',
    'ui.admin.orders.record_no_methods': 'Sopivia manuaalisia maksutapoja ei löytynyt',
    'ui.admin.orders.flag_off': 'Toiminto ei ole käytössä',
    'ui.admin.orders.no_permission': 'Ei oikeutta lisäostoihin',
    'ui.admin.orders.johku': 'Johku-tilaukseen ei voi lisätä ostoja',
    'ui.admin.orders.closed': 'Tilausta ei voi enää muokata',
    'ui.admin.orders.add_new': 'Lisäosto tähän tilaukseen',
    'ui.admin.res.open_order': 'Avaa tilaus #{{var:no}}',
    'ui.admin.res.add_purchase': 'Lisäosto tähän tilaukseen',
    'ui.admin.res.paid_addon_purchase': 'Lisää uusi lisäpalvelu lisäoston kautta.',
    'ui.admin.res.paid_addon_refund': 'Vähennä jo maksettua lisäpalvelua tilauksen hyvityksen kautta.',
    'ui.admin.res.open_refund': 'Avaa tilaus hyvitystä varten',
    'ui.admin.res.payment_link': 'Luo maksulinkki',
  },
  en: {
    'ui.admin.orders.pay_filter': 'Payment status',
    'ui.admin.orders.pay_paid': 'Paid',
    'ui.admin.orders.pay_unpaid': 'Unpaid',
    'ui.admin.orders.pay_invoiced': 'Invoiced',
    'ui.admin.orders.pay_all': 'All',
    'ui.admin.orders.pay_refunded': 'Refunded',
    'ui.admin.orders.pay_cancelled': 'Cancelled',
    'ui.admin.orders.pay_showing': 'Payment status: {{var:label}}',
    'ui.admin.orders.search_all': 'Search covers all orders',
    'ui.admin.orders.open_reservation': 'Open booking',
    'ui.admin.orders.open_reservation_label': 'Open booking: {{var:product}}, {{var:time}}',
    'ui.admin.orders.reservation_open_failed': 'Could not open booking. Open the booking list.',
    'ui.admin.orders.add_purchase': 'Add purchase to this order',
    'ui.admin.orders.add_type_addon': 'Add-on for booking',
    'ui.admin.orders.add_type_reservation': 'Additional treatment or session',
    'ui.admin.orders.add_type_product': 'Rental product',
    'ui.admin.orders.rental': 'Rental product',
    'ui.admin.orders.add_session': 'Sauna session',
    'ui.admin.orders.add_treatment': 'Treatment or ritual',
    'ui.admin.orders.book_kind': 'Booking type',
    'ui.admin.orders.choose_service': 'Choose a treatment or ritual',
    'ui.admin.orders.choose_day': 'Choose date',
    'ui.admin.orders.choose_time': 'Choose available time',
    'ui.admin.orders.persons': 'Number of people',
    'ui.admin.orders.loading_slots': 'Loading availability…',
    'ui.admin.orders.no_slots': 'No availability on the selected date.',
    'ui.admin.orders.slots_found': 'Available times: {{var:n}}',
    'ui.admin.orders.slots_error': 'Failed to load availability',
    'ui.admin.orders.invalid_type': 'Invalid product type',
    'ui.admin.orders.purchase_no_email': 'No email will be sent for the purchase or payment link.',
    'ui.admin.orders.purchase_added': 'Purchase added to order',
    'ui.admin.orders.purchase_link': 'Create a payment link',
    'ui.admin.orders.purchase_record': 'Record payment',
    'ui.admin.orders.purchase_leave': 'Leave unpaid',
    'ui.admin.orders.link_only_uncovered': 'The link covers only outstanding order items. No email will be sent.',
    'ui.admin.orders.link_copy': 'Copy payment link',
    'ui.admin.orders.link_copied': 'Payment link copied',
    'ui.admin.orders.link_missing': 'No payment link URL returned',
    'ui.admin.orders.link_created': 'Payment link created',
    'ui.admin.orders.bad_days': 'Validity must be 1–90 days',
    'ui.admin.orders.record_no_methods': 'No suitable manual payment methods',
    'ui.admin.orders.flag_off': 'Feature disabled',
    'ui.admin.orders.no_permission': 'No permission to add purchases',
    'ui.admin.orders.johku': 'Johku orders cannot be edited',
    'ui.admin.orders.closed': 'This order can no longer be edited',
    'ui.admin.orders.add_new': 'Add purchase to this order',
    'ui.admin.res.open_order': 'Open order #{{var:no}}',
    'ui.admin.res.add_purchase': 'Add purchase to this order',
    'ui.admin.res.paid_addon_purchase': 'Use Add Purchase to add an additional add-on.',
    'ui.admin.res.paid_addon_refund': 'Use the order refund flow to remove a paid add-on.',
    'ui.admin.res.open_refund': 'Open order to refund',
    'ui.admin.res.payment_link': 'Create payment link',
  },
};

let db = new Map();
let loaded = false;

export function fillOrderText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

function applyLive(raw, vars) {
  const tokens = [...String(raw).matchAll(/\{\{([^{}]*)\}\}/g)];
  for (const m of tokens) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  if (/\{\{|\}\}/.test(fillOrderText(raw, vars))) return null;
  return fillOrderText(raw, vars);
}

/** Lukee ui.admin.orders.*-rivit. Virhe tai väärä vastaus ei kaada näkymää. */
export async function loadOrderTexts(rpcFn) {
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await rpcFn('public_get_site_texts', { p_lang: null });
    if (!t || t.ok !== true || !Array.isArray(t.texts)) return false;
    const next = new Map();
    for (const r of t.texts) {
      if (!r || typeof r.key !== 'string' || !(r.key.startsWith(PREFIX) || r.key.startsWith('ui.admin.res.'))) continue;
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

export function clearOrderTextCache() {
  db = new Map();
  loaded = false;
}

export function orderText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return filled;
  const raw = ORDER_TEXTS[lang]?.[key] ?? ORDER_TEXTS.fi[key] ?? key;
  return vars ? fillOrderText(raw, vars) : raw;
}
