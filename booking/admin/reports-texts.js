// Kirjanpitoraporttien ja lahjakortin ALV-ohjeiden tekstit (FI + EN). Avaimet: ui.admin.reports.* ja ui.admin.giftcards.vat_*.
// public_get_site_texts peittää sanakirjan. Haku epäonnistuu tai paikkamerkki ei täyty → REPORT_TEXTS.
// Tuonti: content/site-texts.pending-import-27.json. Luokka normal. Hinnat, ALV-kannat ja osoitteet eivät ole tekstejä.
import { getLang } from './talous-i18n.js';
import { FEE_TEXTS } from './fee-report-texts.js';

export const PREFIXES = ['ui.admin.reports.', 'ui.admin.giftcards.vat_'];

export const REPORT_TEXTS = {
  fi: {
    'ui.admin.reports.day': 'Päivä',
    'ui.admin.reports.this_month': 'Tämä kuukausi',
    'ui.admin.reports.prev_month': 'Edellinen kuukausi',
    'ui.admin.reports.pick_month': 'Kuukausi',
    'ui.admin.reports.range': 'Aikaväli',
    'ui.admin.reports.from': 'Alkaen',
    'ui.admin.reports.to': 'Asti',
    'ui.admin.reports.basis': 'Kassaperuste: jakso on kuitin antopäivä (Helsinki). Hyvitys kuuluu hyvityskuitin jaksoon.',
    'ui.admin.reports.by_product': 'Myynti tuotteittain',
    'ui.admin.reports.refunds_by_product': 'Hyvitykset tuotteittain',
    'ui.admin.reports.no_refunds': 'Ei hyvityksiä tällä jaksolla.',
    'ui.admin.reports.sales_count': 'Myynti, kpl',
    'ui.admin.reports.refund_count': 'Hyvitykset, kpl',
    'ui.admin.reports.sales_list': 'Myynti',
    'ui.admin.reports.col_product': 'Tuote',
    'ui.admin.reports.col_qty': 'Määrä',
    'ui.admin.reports.col_count': 'kpl',
    'ui.admin.reports.col_net': 'Veroton',
    'ui.admin.reports.col_vat_pct': 'ALV %',
    'ui.admin.reports.col_vat_eur': 'ALV €',
    'ui.admin.reports.col_gross': 'Brutto',
    'ui.admin.reports.total': 'Yhteensä',
    'ui.admin.reports.payments': 'Maksutavat',
    'ui.admin.reports.pay_net': 'Maksutavat yhteensä',
    'ui.admin.reports.by_vat': 'ALV-kannat',
    'ui.admin.reports.vat_breakdown': 'ALV-erittely',
    'ui.admin.reports.vat_breakdown_note': 'Myynti vähennettynä hyvityksillä vastaa tätä erittelyä. Luvut on laskettu kuittien riveistä.',
    'ui.admin.reports.reconcile': 'Täsmäytys',
    'ui.admin.reports.reconcile_sales': 'Myynti brutto',
    'ui.admin.reports.reconcile_refunds': 'Hyvitykset brutto',
    'ui.admin.reports.reconcile_products': 'Tuotteet yhteensä',
    'ui.admin.reports.reconcile_payments': 'Maksutavat yhteensä',
    'ui.admin.reports.reconcile_diff': 'Erotus',
    'ui.admin.reports.reconcile_ok': 'Täsmää',
    'ui.admin.reports.vat_rounding': 'ALV-pyöristys',
    'ui.admin.reports.vat_rounding_note': 'Tuoterivien arvonlisävero on laskettu riveittäin. Kuitin verokantaryhmä pyöristetään ryhmänä, joten erotus voi olla senttejä. Erotus näytetään pyöristysrivinä.',
    'ui.admin.reports.rounding_row': 'Pyöristys, rivi vastaan kuitti',
    'ui.admin.reports.cash_rounding': 'Käteispyöristys',
    'ui.admin.reports.tx_csv': 'Tapahtumat CSV',
    'ui.admin.reports.tx_pdf': 'Tapahtumat PDF',
    'ui.admin.reports.summary_csv': 'Yhteenveto CSV',
    'ui.admin.reports.summary_pdf': 'Yhteenveto PDF',
    'ui.admin.reports.open_note': 'Avoin tarkoittaa vahvistettua tilausta, jota ei ole vielä maksettu. Tapahtumaraportin avoin rivi käyttää vahvistuspäivää eikä sisälly myynnin yhteissummiin.',
    'ui.admin.reports.col_voucher': 'Tosite',
    'ui.admin.reports.col_date': 'Päivä',
    'ui.admin.reports.col_customer': 'Asiakas',
    'ui.admin.reports.col_method': 'Maksutapa',
    'ui.admin.reports.col_status': 'Tila',
    'ui.admin.reports.col_kind': 'Laji',
    'ui.admin.reports.status_open': 'Avoin',
    'ui.admin.reports.status_paid': 'Maksettu',
    'ui.admin.reports.kind_sale': 'Myynti',
    'ui.admin.reports.kind_refund': 'Hyvitys',
    'ui.admin.reports.kind_redemption': 'Lunastus',
    'ui.admin.reports.prepaid_title': 'Ennakkoon maksetun lahjakortin lunastus',
    'ui.admin.reports.prepaid_note': 'Nämä lunastukset eivät ole myyntiä. Arvonlisävero on kirjattu kortin myynnissä, eikä sitä kirjata uudelleen. Erittely on vain tiedoksi.',
    'ui.admin.reports.gc_summary_title': 'Lahjakortit',
    'ui.admin.reports.gc_sold': 'Myydyt lahjakortit',
    'ui.admin.reports.gc_sold_note': 'Myydyt lahjakortit sisältyvät yllä olevaan myyntiin ja ALV-erittelyyn. Arvonlisävero on kirjattu kortin myynnissä.',
    'ui.admin.reports.gc_redeemed': 'Käytetyt lahjakortit',
    'ui.admin.reports.gc_complimentary_title': 'Maksuttomat lahjakortit',
    'ui.admin.reports.gc_comp_issued': 'Myönnetyt',
    'ui.admin.reports.gc_comp_redeemed': 'Käytetyt',
    'ui.admin.reports.gc_comp_note': 'Maksuttomasta kortista ei ole veloitettu arvonlisäveroa. Sen myöntö ja käyttö eivät ole myyntiä.',
    'ui.admin.reports.gc_title': 'Lahjakorttien varasto',
    'ui.admin.reports.gc_filter': 'Lahjakortin tila',
    'ui.admin.reports.gc_open': 'Avoimet',
    'ui.admin.reports.gc_used': 'Käytetyt',
    'ui.admin.reports.gc_all': 'Kaikki',
    'ui.admin.reports.gc_csv': 'Lahjakortit CSV',
    'ui.admin.reports.gc_pdf': 'Lahjakortit PDF',
    'ui.admin.reports.gc_own': 'Omat lahjakortit',
    'ui.admin.reports.gc_johku': 'Johku-lahjakortit',
    'ui.admin.reports.gc_count': '{{var:n}} korttia',
    'ui.admin.reports.gc_sum': 'Saldo {{var:balance}}, alkuarvo {{var:initial}}',
    'ui.admin.reports.gc_note': 'Johku-osio on erillään. Sen luvut eivät sisälly uuden järjestelmän yhteissummiin, koska arvonlisävero on kirjattu Johkussa.',
    'ui.admin.reports.gc_paid_note': 'Maksetun oman kortin arvonlisävero on kirjattu myynnissä.',
    'ui.admin.reports.gc_complimentary': 'Maksuton kortti on merkitty erikseen. Siitä ei ole kirjattu arvonlisäveroa, eikä sen lunastus ole myyntiä.',
    'ui.admin.reports.gc_mark_complimentary': 'Maksuton',
    'ui.admin.reports.gc_col_code': 'Koodi',
    'ui.admin.reports.gc_col_buyer': 'Ostaja',
    'ui.admin.reports.gc_col_package': 'Paketti',
    'ui.admin.reports.gc_col_initial': 'Alkuarvo',
    'ui.admin.reports.gc_col_balance': 'Saldo',
    'ui.admin.reports.gc_col_sold': 'Myyntipäivä',
    'ui.admin.reports.gc_col_valid': 'Voimassa',
    'ui.admin.reports.gc_col_status': 'Tila',
    'ui.admin.reports.gc_col_vat': 'ALV-käsittely',
    'ui.admin.reports.pdf_summary': 'Myyntiyhteenveto',
    'ui.admin.reports.pdf_transactions': 'Tapahtumaraportti',
    'ui.admin.reports.pdf_giftcards': 'Lahjakorttiraportti',
    'ui.admin.reports.pdf_period': '{{var:from}} – {{var:to}}',
    'ui.admin.reports.pdf_heading': '{{setting:business_name}}',
    'ui.admin.reports.pdf_receipts': 'Myynti',
    'ui.admin.reports.pdf_refund_receipts': 'Hyvitykset',
    'ui.admin.reports.pdf_sales': 'Myynti yhteensä',
    'ui.admin.reports.pdf_refunds': 'Hyvitykset',
    'ui.admin.reports.pdf_after': 'Myynti hyvitysten jälkeen',
    'ui.admin.reports.pdf_of_which_vat': 'josta ALV',
    'ui.admin.reports.pdf_ex_vat': 'Veroton',
    'ui.admin.giftcards.vat_paid': 'Myydyn lahjakortin arvonlisävero kirjataan myyntihetkellä. Lunastus ei kirjaa veroa uudelleen. Kortilla voi maksaa vain saman verokannan tuotteita.',
    'ui.admin.giftcards.vat_free': 'Maksuttomasta kortista ei veloiteta arvonlisäveroa myönnettäessä eikä lunastettaessa. Lunastus ei näy myyntinä.',
    'ui.admin.giftcards.vat_rate_error': 'Lahjakortilla voi maksaa vain tuotteita, joiden arvonlisävero on 25,5 %.',
  },
  en: {
    'ui.admin.reports.day': 'Day',
    'ui.admin.reports.this_month': 'This month',
    'ui.admin.reports.prev_month': 'Previous month',
    'ui.admin.reports.pick_month': 'Month',
    'ui.admin.reports.range': 'Date range',
    'ui.admin.reports.from': 'From',
    'ui.admin.reports.to': 'To',
    'ui.admin.reports.basis': 'Cash basis: the period is the receipt issue date (Helsinki). A refund belongs to the refund receipt period.',
    'ui.admin.reports.by_product': 'Sales by product',
    'ui.admin.reports.refunds_by_product': 'Refunds by product',
    'ui.admin.reports.no_refunds': 'No refunds in this period.',
    'ui.admin.reports.sales_count': 'Sales, pcs',
    'ui.admin.reports.refund_count': 'Refunds, pcs',
    'ui.admin.reports.sales_list': 'Sales',
    'ui.admin.reports.col_product': 'Product',
    'ui.admin.reports.col_qty': 'Qty',
    'ui.admin.reports.col_count': 'pcs',
    'ui.admin.reports.col_net': 'Excl. VAT',
    'ui.admin.reports.col_vat_pct': 'VAT %',
    'ui.admin.reports.col_vat_eur': 'VAT €',
    'ui.admin.reports.col_gross': 'Gross',
    'ui.admin.reports.total': 'Total',
    'ui.admin.reports.payments': 'Payment methods',
    'ui.admin.reports.pay_net': 'Payment methods total',
    'ui.admin.reports.by_vat': 'VAT rates',
    'ui.admin.reports.vat_breakdown': 'VAT breakdown',
    'ui.admin.reports.vat_breakdown_note': 'Sales minus refunds match this breakdown. The figures are calculated from the receipt lines.',
    'ui.admin.reports.reconcile': 'Reconciliation',
    'ui.admin.reports.reconcile_sales': 'Sales gross',
    'ui.admin.reports.reconcile_refunds': 'Refunds gross',
    'ui.admin.reports.reconcile_products': 'Products total',
    'ui.admin.reports.reconcile_payments': 'Payment methods total',
    'ui.admin.reports.reconcile_diff': 'Difference',
    'ui.admin.reports.reconcile_ok': 'Balances',
    'ui.admin.reports.vat_rounding': 'VAT rounding',
    'ui.admin.reports.vat_rounding_note': 'Product-line VAT is calculated per line. A receipt rounds each VAT rate as a group, so the difference can be cents. The difference is shown as a rounding row.',
    'ui.admin.reports.rounding_row': 'Rounding, line versus receipt',
    'ui.admin.reports.cash_rounding': 'Cash rounding',
    'ui.admin.reports.tx_csv': 'Transactions CSV',
    'ui.admin.reports.tx_pdf': 'Transactions PDF',
    'ui.admin.reports.summary_csv': 'Summary CSV',
    'ui.admin.reports.summary_pdf': 'Summary PDF',
    'ui.admin.reports.open_note': 'Open means a confirmed order that is not yet paid. An open row in the transaction report uses the confirmation date and is not included in the sales totals.',
    'ui.admin.reports.col_voucher': 'Voucher',
    'ui.admin.reports.col_date': 'Date',
    'ui.admin.reports.col_customer': 'Customer',
    'ui.admin.reports.col_method': 'Payment method',
    'ui.admin.reports.col_status': 'Status',
    'ui.admin.reports.col_kind': 'Type',
    'ui.admin.reports.status_open': 'Open',
    'ui.admin.reports.status_paid': 'Paid',
    'ui.admin.reports.kind_sale': 'Sale',
    'ui.admin.reports.kind_refund': 'Refund',
    'ui.admin.reports.kind_redemption': 'Redemption',
    'ui.admin.reports.prepaid_title': 'Redemption of a prepaid gift card',
    'ui.admin.reports.prepaid_note': 'These redemptions are not sales. VAT was recorded when the card was sold and is not recorded again. The breakdown is for information only.',
    'ui.admin.reports.gc_summary_title': 'Gift cards',
    'ui.admin.reports.gc_sold': 'Gift cards sold',
    'ui.admin.reports.gc_sold_note': 'Sold gift cards are included in the sales and the VAT breakdown above. VAT was recorded when the card was sold.',
    'ui.admin.reports.gc_redeemed': 'Gift cards redeemed',
    'ui.admin.reports.gc_complimentary_title': 'Complimentary gift cards',
    'ui.admin.reports.gc_comp_issued': 'Issued',
    'ui.admin.reports.gc_comp_redeemed': 'Redeemed',
    'ui.admin.reports.gc_comp_note': 'No VAT was charged on a complimentary card. Issuing or redeeming it is not a sale.',
    'ui.admin.reports.gc_title': 'Gift card stock',
    'ui.admin.reports.gc_filter': 'Gift card status',
    'ui.admin.reports.gc_open': 'Open',
    'ui.admin.reports.gc_used': 'Used',
    'ui.admin.reports.gc_all': 'All',
    'ui.admin.reports.gc_csv': 'Gift cards CSV',
    'ui.admin.reports.gc_pdf': 'Gift cards PDF',
    'ui.admin.reports.gc_own': 'Own gift cards',
    'ui.admin.reports.gc_johku': 'Johku gift cards',
    'ui.admin.reports.gc_count': '{{var:n}} cards',
    'ui.admin.reports.gc_sum': 'Balance {{var:balance}}, original value {{var:initial}}',
    'ui.admin.reports.gc_note': 'The Johku section is separate. Its figures are not included in the new system totals, because the VAT was recorded in Johku.',
    'ui.admin.reports.gc_paid_note': 'VAT on a paid own card was recorded when the card was sold.',
    'ui.admin.reports.gc_complimentary': 'A complimentary card is marked separately. No VAT was recorded on it, and redeeming it is not a sale.',
    'ui.admin.reports.gc_mark_complimentary': 'Complimentary',
    'ui.admin.reports.gc_col_code': 'Code',
    'ui.admin.reports.gc_col_buyer': 'Buyer',
    'ui.admin.reports.gc_col_package': 'Package',
    'ui.admin.reports.gc_col_initial': 'Original value',
    'ui.admin.reports.gc_col_balance': 'Balance',
    'ui.admin.reports.gc_col_sold': 'Sale date',
    'ui.admin.reports.gc_col_valid': 'Valid until',
    'ui.admin.reports.gc_col_status': 'Status',
    'ui.admin.reports.gc_col_vat': 'VAT treatment',
    'ui.admin.reports.pdf_summary': 'Sales summary',
    'ui.admin.reports.pdf_transactions': 'Transaction report',
    'ui.admin.reports.pdf_giftcards': 'Gift card report',
    'ui.admin.reports.pdf_period': '{{var:from}} – {{var:to}}',
    'ui.admin.reports.pdf_heading': '{{setting:business_name}}',
    'ui.admin.reports.pdf_receipts': 'Sales',
    'ui.admin.reports.pdf_refund_receipts': 'Refunds',
    'ui.admin.reports.pdf_sales': 'Sales total',
    'ui.admin.reports.pdf_refunds': 'Refunds',
    'ui.admin.reports.pdf_after': 'Sales after refunds',
    'ui.admin.reports.pdf_of_which_vat': 'of which VAT',
    'ui.admin.reports.pdf_ex_vat': 'Excl. VAT',
    'ui.admin.giftcards.vat_paid': 'VAT on a sold gift card is recorded when the card is sold. Redemption does not record the VAT again. The card can pay only for products with that same VAT rate.',
    'ui.admin.giftcards.vat_free': 'A complimentary card is never charged VAT, neither when it is issued nor when it is redeemed. The redemption is not a sale.',
    'ui.admin.giftcards.vat_rate_error': 'A gift card can pay only for products with 25.5% VAT.',
  },
};

let db = new Map();
let loaded = false;

export function fillReportText(text, vars) {
  return String(text ?? '').replace(/\{\{var:([a-z0-9_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ''));
}

function applyLive(raw, vars) {
  const tokens = [...String(raw).matchAll(/\{\{([^{}]*)\}\}/g)];
  for (const m of tokens) {
    const name = /^var:([a-z0-9_]+)$/.exec(m[1]);
    if (!name || vars?.[name[1]] == null) return null;
  }
  if (/\{\{|\}\}/.test(fillReportText(raw, vars))) return null;
  return fillReportText(raw, vars);
}

export async function loadReportTexts(rpcFn) {
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

export function clearReportTextCache() {
  db = new Map();
  loaded = false;
}

export function reportText(key, vars, lang = getLang()) {
  const live = db.get(`${key}|${lang}`);
  const filled = live != null ? applyLive(live, vars) : null;
  if (filled != null) return String(filled);
  const raw = REPORT_TEXTS[lang]?.[key] ?? FEE_TEXTS[lang]?.[key] ?? REPORT_TEXTS.fi[key] ?? FEE_TEXTS.fi[key] ?? key;
  const out = vars ? fillReportText(raw, vars) : raw;
  return out == null ? '' : String(out);
}
