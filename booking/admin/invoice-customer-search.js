// Uusi lasku: hakusanan siirto ja "muuttuiko asiakas" -vertailu. Ei DOM:ia.
import { normBusinessId, validBusinessId } from '../shop/src/invoice-validate.js';

export const CUSTOMER_FIELDS = ['company_name', 'business_id', 'contact_name', 'email', 'phone', 'einvoice_address', 'einvoice_operator', 'street', 'zip', 'city', 'buyer_reference'];

export function normCustomerField(key, value) {
  const s = String(value ?? '').trim();
  if (!s) return '';
  if (key === 'business_id') return validBusinessId(s) ? normBusinessId(s) : s.toUpperCase();
  if (key === 'email') return s.toLowerCase();
  if (key === 'einvoice_address' || key === 'einvoice_operator') return s.replace(/\s/g, '').toUpperCase();
  return s.replace(/\s+/g, ' ');
}

// Kirjoitettu nimi tai Y-tunnus siirtyy tyhjään kenttään. Jo täytettyä kenttää ei ylikirjoiteta.
export function routeSearchTerm(term, fields = {}) {
  const t = String(term ?? '').trim().replace(/\s+/g, ' ');
  if (t.length < 2) return { field: null, value: '', filled: false };
  const bid = normBusinessId(t);
  if (validBusinessId(bid)) {
    const filled = !normCustomerField('business_id', fields.business_id);
    return { field: 'business_id', value: bid, filled };
  }
  const filled = !normCustomerField('company_name', fields.company_name);
  return { field: 'company_name', value: t, filled };
}

export function customerDirty(next, prev) {
  return CUSTOMER_FIELDS.some((k) => normCustomerField(k, next?.[k]) !== normCustomerField(k, prev?.[k]));
}
