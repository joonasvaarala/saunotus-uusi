// Uusi lasku: asiakas- ja päiväkenttien tarkistus ennen tallennusta sekä palvelimen virhekoodin kohdekenttä. Ei DOM:ia.
// Samat säännöt kuin palvelimella: booking._invoice_customer_clean (booking_112) ja booking.admin_save_invoice.
import { normBusinessId, normOvt, validBusinessId, validOperator, validOvt } from '../shop/src/invoice-validate.js';

// Lomakkeen järjestys ylhäältä alas: ensimmäinen virheellinen kenttä saa fokuksen.
export const HEADER_ORDER = ['company_name', 'business_id', 'contact_name', 'email', 'phone', 'einvoice_address', 'einvoice_operator', 'street', 'zip', 'city', 'buyer_reference', 'invoice_date', 'due_date', 'notes'];

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

/** Palauttaa virheet lomakkeen järjestyksessä: [{ key, code }]. code on tekstiavaimen loppuosa (ui.admin.invoices.<code>). */
export function validateInvoiceHeader(v = {}) {
  const s = (k) => String(v[k] ?? '').trim();
  const out = {};
  const name = s('company_name').replace(/\s+/g, ' ');
  if (name.length < 2 || name.length > 200) out.company_name = 'need_company';
  const bid = s('business_id');
  if (bid && !validBusinessId(bid)) out.business_id = 'err_business_id';
  const email = s('email');
  if (email && (email.length > 254 || !EMAIL.test(email))) out.email = 'err_email';
  const ei = normOvt(s('einvoice_address'));
  const op = normOvt(s('einvoice_operator'));
  if (ei && !validOvt(ei, bid && validBusinessId(bid) ? normBusinessId(bid) : '')) out.einvoice_address = 'err_ovt';
  else if (op && !ei) out.einvoice_address = 'err_ovt_missing';
  if (op && !validOperator(op)) out.einvoice_operator = 'err_operator';
  else if (ei && !op) out.einvoice_operator = 'err_operator_missing';
  if (s('buyer_reference').length > 100) out.buyer_reference = 'err_reference';
  const date = s('invoice_date');
  const due = s('due_date');
  if (date && !DATE.test(date)) out.invoice_date = 'err_date';
  if (due && !DATE.test(due)) out.due_date = 'err_date';
  else if (date && due && DATE.test(date) && due < date) out.due_date = 'err_due';
  if (s('notes').length > 2000) out.notes = 'err_notes';
  return HEADER_ORDER.filter((k) => out[k]).map((k) => ({ key: k, code: out[k] }));
}

// Palvelimen virhekoodi (ApiError.code) → lomakkeen kenttä. 'lines' = laskurivit. Tuntematon koodi → null (näytetään vain viesti).
const SERVER_FIELD = {
  invalid_company_name: 'company_name',
  invalid_business_id: 'business_id',
  customer_exists: 'business_id',
  invalid_vat_id: 'business_id',
  invalid_email: 'email',
  name_email_match: 'email',
  einvoice_incomplete: 'einvoice_address',
  invalid_einvoice_address: 'einvoice_address',
  invalid_einvoice_operator: 'einvoice_operator',
  invalid_reference: 'buyer_reference',
  invalid_customer: 'company_name',
  invalid_due: 'due_date',
  invalid_notes: 'notes',
  invalid_lines: 'lines',
  invalid_vat: 'lines',
};

export function serverErrorField(code) {
  return SERVER_FIELD[code] || null;
}
