// Hallinnan Laskut-näkymän tekstit (FI + EN). Avaimet ui.admin.invoices.* .
// Tuonti: content/site-texts.pending-import-13.json. Maksuehto ja tietosuoja ovat protected.
import { getLang } from './talous-i18n.js';

export const PREFIX = 'ui.admin.invoices.';

export const INVOICE_TEXTS = {
  fi: {
    'ui.admin.invoices.title': 'Laskut',
    'ui.admin.invoices.search': 'Haku',
    'ui.admin.invoices.search_ph': 'Numero, asiakas, y-tunnus tai viite',
    'ui.admin.invoices.status': 'Tila',
    'ui.admin.invoices.kind': 'Laji',
    'ui.admin.invoices.from': 'Alkaen',
    'ui.admin.invoices.to': 'Asti',
    'ui.admin.invoices.new': 'Uusi lasku',
    'ui.admin.invoices.from_order': 'Tilauksesta',
    'ui.admin.invoices.send_einvoice': 'Lähetä verkkolasku',
    'ui.admin.invoices.send_email': 'Lähetä PDF sähköpostilla',
    'ui.admin.invoices.mark_paid': 'Merkitse maksetuksi',
    'ui.admin.invoices.credit': 'Hyvityslasku',
    'ui.admin.invoices.void': 'Mitätöi luonnos',
    'ui.admin.invoices.preview': 'Laskuennakko',
    'ui.admin.invoices.empty': 'Ei laskuja',
    'ui.admin.invoices.customer': 'Asiakas',
    'ui.admin.invoices.company': 'Yritys',
    'ui.admin.invoices.business_id': 'Y-tunnus',
    'ui.admin.invoices.vat_id': 'ALV-tunnus',
    'ui.admin.invoices.ovt': 'Verkkolaskuosoite (OVT)',
    'ui.admin.invoices.operator': 'Välittäjätunnus',
    'ui.admin.invoices.email': 'Sähköposti',
    'ui.admin.invoices.contact': 'Yhteyshenkilö',
    'ui.admin.invoices.buyer_ref': 'Viitteenne',
    'ui.admin.invoices.street': 'Katuosoite',
    'ui.admin.invoices.zip': 'Postinumero',
    'ui.admin.invoices.city': 'Postitoimipaikka',
    'ui.admin.invoices.due': 'Eräpäivä',
    'ui.admin.invoices.date': 'Laskun päivä',
    'ui.admin.invoices.notes': 'Lisätiedot',
    'ui.admin.invoices.desc': 'Kuvaus',
    'ui.admin.invoices.qty': 'Määrä',
    'ui.admin.invoices.unit': 'Yksikkö',
    'ui.admin.invoices.price': 'Yksikköhinta, alv 0 €',
    'ui.admin.invoices.vat': 'ALV',
    'ui.admin.invoices.add_line': 'Lisää rivi',
    'ui.admin.invoices.save': 'Tallenna luonnos',
    'ui.admin.invoices.number': 'Laskunumero',
    'ui.admin.invoices.reference': 'Viitenumero',
    'ui.admin.invoices.total': 'Yhteensä',
    'ui.admin.invoices.dispatch': 'Verkkolaskun lähetys',
    'ui.admin.invoices.retry': 'Yritä uudelleen',
    'ui.admin.invoices.st_draft': 'Luonnos',
    'ui.admin.invoices.st_sent': 'Lähetetty',
    'ui.admin.invoices.st_paid': 'Maksettu',
    'ui.admin.invoices.st_overdue': 'Erääntynyt',
    'ui.admin.invoices.st_credited': 'Hyvitetty',
    'ui.admin.invoices.st_voided': 'Mitätöity',
    'ui.admin.invoices.kind_debit': 'Veloitus',
    'ui.admin.invoices.kind_credit': 'Hyvitys',
    'ui.admin.invoices.all': 'Kaikki',
    'ui.admin.invoices.order': 'Tilausnumero',
    'ui.admin.invoices.terms': 'Maksuehto 14 päivää netto. Viivästyskorko korkolain mukaan.',
    'ui.admin.invoices.privacy': 'Laskun henkilötietoja käsitellään vain laskutusta varten.',
    'ui.admin.invoices.locked': 'Rivit on lukittu lähetyksen jälkeen. Korjaus tehdään hyvityslaskulla.',
    'ui.admin.invoices.saved': 'Luonnos tallennettu',
    'ui.admin.invoices.pdf': 'Avaa PDF',
    'ui.admin.invoices.log': 'Lähetysloki',
  },
  en: {
    'ui.admin.invoices.title': 'Invoices',
    'ui.admin.invoices.search': 'Search',
    'ui.admin.invoices.search_ph': 'Number, customer, business ID or reference',
    'ui.admin.invoices.status': 'Status',
    'ui.admin.invoices.kind': 'Kind',
    'ui.admin.invoices.from': 'From',
    'ui.admin.invoices.to': 'To',
    'ui.admin.invoices.new': 'New invoice',
    'ui.admin.invoices.from_order': 'From order',
    'ui.admin.invoices.send_einvoice': 'Send e-invoice',
    'ui.admin.invoices.send_email': 'Email the PDF',
    'ui.admin.invoices.mark_paid': 'Mark paid',
    'ui.admin.invoices.credit': 'Credit invoice',
    'ui.admin.invoices.void': 'Void draft',
    'ui.admin.invoices.preview': 'Invoice preview',
    'ui.admin.invoices.empty': 'No invoices',
    'ui.admin.invoices.customer': 'Customer',
    'ui.admin.invoices.company': 'Company',
    'ui.admin.invoices.business_id': 'Business ID',
    'ui.admin.invoices.vat_id': 'VAT ID',
    'ui.admin.invoices.ovt': 'E-invoice address (OVT)',
    'ui.admin.invoices.operator': 'Operator ID',
    'ui.admin.invoices.email': 'Email',
    'ui.admin.invoices.contact': 'Contact',
    'ui.admin.invoices.buyer_ref': 'Your reference',
    'ui.admin.invoices.street': 'Street address',
    'ui.admin.invoices.zip': 'Postal code',
    'ui.admin.invoices.city': 'City',
    'ui.admin.invoices.due': 'Due date',
    'ui.admin.invoices.date': 'Invoice date',
    'ui.admin.invoices.notes': 'Notes',
    'ui.admin.invoices.desc': 'Description',
    'ui.admin.invoices.qty': 'Qty',
    'ui.admin.invoices.unit': 'Unit',
    'ui.admin.invoices.price': 'Unit price excl. VAT',
    'ui.admin.invoices.vat': 'VAT',
    'ui.admin.invoices.add_line': 'Add line',
    'ui.admin.invoices.save': 'Save draft',
    'ui.admin.invoices.number': 'Invoice number',
    'ui.admin.invoices.reference': 'Reference number',
    'ui.admin.invoices.total': 'Total',
    'ui.admin.invoices.dispatch': 'E-invoice dispatch',
    'ui.admin.invoices.retry': 'Retry',
    'ui.admin.invoices.st_draft': 'Draft',
    'ui.admin.invoices.st_sent': 'Sent',
    'ui.admin.invoices.st_paid': 'Paid',
    'ui.admin.invoices.st_overdue': 'Overdue',
    'ui.admin.invoices.st_credited': 'Credited',
    'ui.admin.invoices.st_voided': 'Voided',
    'ui.admin.invoices.kind_debit': 'Debit',
    'ui.admin.invoices.kind_credit': 'Credit',
    'ui.admin.invoices.all': 'All',
    'ui.admin.invoices.order': 'Order number',
    'ui.admin.invoices.terms': 'Payment terms: 14 days net. Late interest according to the Interest Act.',
    'ui.admin.invoices.privacy': 'Personal data on the invoice is used only for invoicing.',
    'ui.admin.invoices.locked': 'Lines are locked after sending. Corrections are made with a credit invoice.',
    'ui.admin.invoices.saved': 'Draft saved',
    'ui.admin.invoices.pdf': 'Open PDF',
    'ui.admin.invoices.log': 'Dispatch log',
  },
};

let db = new Map();
let loaded = false;

function fill(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

export async function loadInvoiceTexts(rpcFn) {
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

export function clearInvoiceTextCache() {
  db = new Map();
  loaded = false;
}

export function invoiceText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const raw = live ?? INVOICE_TEXTS[lang]?.[key] ?? INVOICE_TEXTS.fi[key] ?? key;
  return vars ? fill(raw, vars) : raw;
}
