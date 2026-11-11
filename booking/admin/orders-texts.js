// Talous-tilauslistan maksusuodattimen tekstit (FI + EN). Avaimet: ui.admin.orders.* .
// public_get_site_texts peittää sanakirjan. Haku epäonnistuu tai rivi puuttuu → ORDER_TEXTS.
// Tuonti: content/site-texts.pending-import-8.json (ei ylikirjoita olemassa olevia).
import { getLang } from './talous-i18n.js';
import { getSiteTexts, clearSiteTextsCache } from './site-texts-cache.js';

export const PREFIX = 'ui.admin.orders.';

export const ORDER_TEXTS = {
  fi: {
    'ui.admin.res.order_no': 'Tilaus #{{var:no}}',
    'ui.admin.res.summary_label': 'Varauksen yhteenveto',
    'ui.admin.res.persons_shared': '{{var:n}} hlö · yleinen vuoro',
    'ui.admin.res.persons_private': '{{var:n}} hlö · yksityisvuoro',
    'ui.admin.res.hold_until': 'Pito päättyy klo {{var:time}}',
    'ui.admin.res.customer': 'Asiakas',
    'ui.admin.res.call': 'Soita asiakkaalle: {{var:phone}}',
    'ui.admin.res.email': 'Lähetä sähköpostia: {{var:email}}',
    'ui.admin.res.customer_message': 'Asiakkaan viesti',
    'ui.admin.res.payment_title': 'Tilaus ja maksu',
    'ui.admin.res.contents_title': 'Varauksen sisältö',
    'ui.admin.res.more_details': 'Lisätiedot',
    'ui.admin.res.move_title': 'Siirrä toiseen tilaan',
    'ui.admin.res.move_reason': 'Siirron syy (valinnainen)',
    'ui.admin.res.move_button': 'Siirrä tilaan {{var:space}}',
    'ui.admin.res.move_help': 'Siirto onnistuu, jos kohdetila on vapaa ja tuotteella on sille sääntö.',
    'ui.admin.res.other_actions': 'Muut toiminnot',
    'ui.admin.res.no_show_title': 'Merkitäänkö varaus tilaan Ei saapunut?',
    'ui.admin.res.no_show_text': 'Asiakas ei saapunut varaukseen. Maksuja ei hyvitetä automaattisesti.',
    'ui.admin.res.no_show_submit': 'Merkitse: ei saapunut',
    'ui.admin.orders.link_set_deadline': 'Aseta takaraja',
    'ui.admin.orders.link_deadline_help': 'Ilman takarajaa linkki on voimassa, kunnes tilaus on maksettu tai linkki korvataan uudella.',
    'ui.admin.orders.link_deadline_days': 'Takaraja (päivää)',
    'ui.admin.orders.link_deadline_bad': 'Takarajan on oltava {{var:min}}–{{var:max}} päivää.',
    'ui.admin.orders.link_no_deadline': 'Linkillä ei ole takarajaa.',
    'ui.admin.orders.link_valid_until': 'Linkki on voimassa {{var:date}} asti.',
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
    'ui.admin.res.pay_unpaid_amount': 'Maksamatta {{var:amount}}',
    'ui.admin.res.pay_paid_amount': 'Maksettu {{var:amount}}',
    'ui.admin.res.pay_invoiced_amount': 'Laskutettu {{var:amount}}',
    'ui.admin.res.pay_refunded_amount': 'Palautettu {{var:amount}}',
    'ui.admin.res.pay_pending_amount': 'Maksu kesken {{var:amount}}',
    'ui.admin.res.arrived': 'Saapunut',
    'ui.admin.res.take_payment': 'Ota maksu',
    'ui.admin.res.send_pay_link': 'Lähetä maksulinkki',
    'ui.admin.res.section_addons': 'Lisäostot',
    'ui.admin.res.section_items': 'Ostokset',
    'ui.admin.res.section_payments': 'Maksut ja laskut',
    'ui.admin.res.section_messages': 'Viestit',
    'ui.admin.res.section_history': 'Historia',
    'ui.admin.res.section_notes': 'Muistiinpanot',
    'ui.admin.res.sum_no_addons': 'ei lisäostoksia',
    'ui.admin.res.sum_addons': '{{var:n}} tuotetta, {{var:amount}}',
    'ui.admin.res.sum_items': '{{var:n}} riviä, {{var:amount}}',
    'ui.admin.res.sum_unpaid': 'maksamatta {{var:amount}}',
    'ui.admin.res.sum_paid': 'maksettu {{var:amount}}',
    'ui.admin.res.sum_invoiced': 'laskutettu {{var:amount}}',
    'ui.admin.res.sum_no_messages': 'ei viestejä',
    'ui.admin.res.sum_messages': '{{var:n}} viestiä',
    'ui.admin.res.sum_add_note': 'lisää muistiinpano',
    'ui.admin.res.no_booking': 'ei ajanvarausta',
    'ui.admin.res.ordered_at': 'Tilattu {{var:when}}',
    'ui.admin.res.gift_title': 'Lahjakortti',
    'ui.admin.res.order_title': 'Tilaus',
    'ui.admin.res.webshop': 'Verkkokauppa',
    'ui.admin.res.option_missing': 'Hoito valitsematta',
    'ui.admin.res.no_open_invoices': 'Ei avoimia laskuja.',
    'ui.admin.res.refund_order': 'Hyvitä tilaus',
    'ui.admin.res.incl_vat': 'sis. alv',
    'ui.admin.res.section_breakdown': 'Tilauserittely',
    'ui.admin.res.sum_breakdown': 'Yhteensä {{var:amount}}',
    'ui.admin.res.addons_line_label': 'Lisäostot',
    'ui.admin.res.breakdown_empty': 'Tilauksella ei ole rivejä.',
    'ui.admin.res.breakdown_qty': '{{var:n}} × {{var:price}}',
    'ui.admin.res.breakdown_vat': 'ALV {{var:rate}} · {{var:amount}}',
    'ui.admin.res.breakdown_vat_missing': 'ALV-kanta puuttuu',
    'ui.admin.res.breakdown_cancelled': 'peruttu',
    'ui.admin.res.breakdown_total': 'Yhteensä',
    'ui.admin.res.breakdown_vat_rate': 'ALV-kanta',
    'ui.admin.res.breakdown_net': 'Veroton',
    'ui.admin.res.breakdown_vat_eur': 'ALV',
    'ui.admin.res.breakdown_gross': 'Verollinen',
    'ui.admin.res.breakdown_vat_unknown_note': 'Osalta riveistä puuttuu ALV-kanta, joten ne eivät näy ALV-erittelyssä.',
    'ui.admin.res.breakdown_rows_total': 'Rivien summa {{var:amount}} poikkeaa tilauksen summasta.',
    'ui.admin.res.history_created': 'Luotu {{var:when}}',
    'ui.admin.res.resend_card': 'Lähetä lahjakortti uudelleen',
    'ui.admin.res.copy_code': 'Kopioi koodi',
  },
  en: {
    'ui.admin.res.order_no': 'Order #{{var:no}}',
    'ui.admin.res.summary_label': 'Booking summary',
    'ui.admin.res.persons_shared': '{{var:n}} people · shared session',
    'ui.admin.res.persons_private': '{{var:n}} people · private session',
    'ui.admin.res.hold_until': 'Hold expires at {{var:time}}',
    'ui.admin.res.customer': 'Customer',
    'ui.admin.res.call': 'Call the customer: {{var:phone}}',
    'ui.admin.res.email': 'Email the customer: {{var:email}}',
    'ui.admin.res.customer_message': 'Message from the customer',
    'ui.admin.res.payment_title': 'Order and payment',
    'ui.admin.res.contents_title': 'Booking contents',
    'ui.admin.res.more_details': 'More details',
    'ui.admin.res.move_title': 'Move to another space',
    'ui.admin.res.move_reason': 'Reason for the move (optional)',
    'ui.admin.res.move_button': 'Move to {{var:space}}',
    'ui.admin.res.move_help': 'The move works if the target space is free and the product has a rule for it.',
    'ui.admin.res.other_actions': 'Other actions',
    'ui.admin.res.no_show_title': 'Mark the booking as no-show?',
    'ui.admin.res.no_show_text': 'The customer did not arrive. Payments are not refunded automatically.',
    'ui.admin.res.no_show_submit': 'Mark as no-show',
    'ui.admin.orders.link_set_deadline': 'Set a deadline',
    'ui.admin.orders.link_deadline_help': 'Without a deadline the link stays valid until the order is paid or the link is replaced.',
    'ui.admin.orders.link_deadline_days': 'Deadline (days)',
    'ui.admin.orders.link_deadline_bad': 'The deadline must be {{var:min}}–{{var:max}} days.',
    'ui.admin.orders.link_no_deadline': 'The link has no deadline.',
    'ui.admin.orders.link_valid_until': 'The link is valid until {{var:date}}.',
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
    'ui.admin.res.pay_unpaid_amount': 'Unpaid {{var:amount}}',
    'ui.admin.res.pay_paid_amount': 'Paid {{var:amount}}',
    'ui.admin.res.pay_invoiced_amount': 'Invoiced {{var:amount}}',
    'ui.admin.res.pay_refunded_amount': 'Refunded {{var:amount}}',
    'ui.admin.res.pay_pending_amount': 'Payment pending {{var:amount}}',
    'ui.admin.res.arrived': 'Arrived',
    'ui.admin.res.take_payment': 'Take payment',
    'ui.admin.res.send_pay_link': 'Send payment link',
    'ui.admin.res.section_addons': 'Add-ons',
    'ui.admin.res.section_items': 'Items',
    'ui.admin.res.section_payments': 'Payments and invoices',
    'ui.admin.res.section_messages': 'Messages',
    'ui.admin.res.section_history': 'History',
    'ui.admin.res.section_notes': 'Notes',
    'ui.admin.res.sum_no_addons': 'no add-ons',
    'ui.admin.res.sum_addons': '{{var:n}} items, {{var:amount}}',
    'ui.admin.res.sum_items': '{{var:n}} lines, {{var:amount}}',
    'ui.admin.res.sum_unpaid': 'unpaid {{var:amount}}',
    'ui.admin.res.sum_paid': 'paid {{var:amount}}',
    'ui.admin.res.sum_invoiced': 'invoiced {{var:amount}}',
    'ui.admin.res.sum_no_messages': 'no messages',
    'ui.admin.res.sum_messages': '{{var:n}} messages',
    'ui.admin.res.sum_add_note': 'add a note',
    'ui.admin.res.no_booking': 'no booking time',
    'ui.admin.res.ordered_at': 'Ordered {{var:when}}',
    'ui.admin.res.gift_title': 'Gift card',
    'ui.admin.res.order_title': 'Order',
    'ui.admin.res.webshop': 'Web shop',
    'ui.admin.res.option_missing': 'Treatment not selected',
    'ui.admin.res.no_open_invoices': 'No open invoices.',
    'ui.admin.res.refund_order': 'Refund order',
    'ui.admin.res.incl_vat': 'incl. VAT',
    'ui.admin.res.section_breakdown': 'Order breakdown',
    'ui.admin.res.sum_breakdown': 'Total {{var:amount}}',
    'ui.admin.res.addons_line_label': 'Add-ons',
    'ui.admin.res.breakdown_empty': 'The order has no lines.',
    'ui.admin.res.breakdown_qty': '{{var:n}} × {{var:price}}',
    'ui.admin.res.breakdown_vat': 'VAT {{var:rate}} · {{var:amount}}',
    'ui.admin.res.breakdown_vat_missing': 'VAT rate missing',
    'ui.admin.res.breakdown_cancelled': 'cancelled',
    'ui.admin.res.breakdown_total': 'Total',
    'ui.admin.res.breakdown_vat_rate': 'VAT rate',
    'ui.admin.res.breakdown_net': 'Net',
    'ui.admin.res.breakdown_vat_eur': 'VAT',
    'ui.admin.res.breakdown_gross': 'Gross',
    'ui.admin.res.breakdown_vat_unknown_note': 'Some lines have no VAT rate, so they are not in the VAT summary.',
    'ui.admin.res.breakdown_rows_total': 'Lines add up to {{var:amount}}, which differs from the order total.',
    'ui.admin.res.history_created': 'Created {{var:when}}',
    'ui.admin.res.resend_card': 'Resend gift card',
    'ui.admin.res.copy_code': 'Copy code',
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
    const t = await getSiteTexts(rpcFn);
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
  clearSiteTextsCache();
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
