// HALL-ASIAKKAAT-01: asiakasnäkymän paikallaan muokkauksen logiikka (puhdas moduuli, ei DOMia; node --test booking/tests/asiakasnakyma-muokkaus-161.test.mjs).
// Lomakkeen arvoista tehdään admin_update_customer-kutsun p_patch: mukaan vain muuttuneet kentät, jotta vanha epätäydellinen tieto ei estä muun tallennusta.
// Säännöt peilaavat palvelinta (booking_11: admin_update_customer, constraint customers_company_data).
import { validBusinessId, normBusinessId } from '../shop/src/invoice-validate.js';

const validEmail = (v) => /^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(String(v).trim());   // sama sääntö kuin customerform.js
export const LANG_CODES = ['fi', 'en', 'sv'];
export const customerHref = (id) => `#/asiakkaat/${Number(id)}`;
export const newBookingHref = (id) => `#/uusi?c=${Number(id)}`;
const s = (v) => String(v ?? '').trim();

/** Lomakkeen alkuarvot asiakasrivistä (admin_get_customer). */
export function contactValues(c) {
  return {
    kind: c?.customer_kind === 'company' ? 'company' : 'private',
    name: s(c?.name), email: s(c?.email), phone: s(c?.phone), language: LANG_CODES.includes(c?.language) ? c.language : 'fi',
    company: s(c?.company), business_id: s(c?.business_id), address: s(c?.address), zip: s(c?.zip), city: s(c?.city),
    einvoice_address: s(c?.einvoice_address), einvoice_operator: s(c?.einvoice_operator), invoice_reference: s(c?.invoice_reference),
  };
}

/** Virheet { field, key } (key = tekstiavain ilman ui.admin.customer_view.-etuliitettä). Tyhjä lista = kelpaa. */
export function contactProblems(v) {
  const out = []; const add = (field, key) => out.push({ field, key });
  if (!s(v.name)) add('name', 'err_name');
  if (s(v.email) && !validEmail(v.email)) add('email', 'err_email');
  if (s(v.phone) && !/^[0-9+()\- ]{6,30}$/.test(s(v.phone))) add('phone', 'err_phone');
  if (v.kind === 'company') {
    if (!s(v.company)) add('company', 'err_company');
    if (!validBusinessId(v.business_id)) add('business_id', 'err_bid');
    if (!s(v.address)) add('address', 'err_street');
  }
  if (s(v.zip) && !/^\d{5}$/.test(s(v.zip))) add('zip', 'err_zip');
  if (v.kind === 'company' && !s(v.city)) add('city', 'err_city');
  if (!!s(v.einvoice_address) !== !!s(v.einvoice_operator)) add(s(v.einvoice_address) ? 'einvoice_operator' : 'einvoice_address', 'err_einvoice');
  return out;
}

const norm = (k, v) => (k === 'business_id' && s(v) ? normBusinessId(v) : s(v));
/** p_patch: vain muuttuneet kentät. Yksityisasiakkaalla y-tunnus-, verkkolasku- ja viitekenttiä ei lähetetä. Tyhjä merkkijono → null. */
export function contactPatch(orig, next) {
  const o = contactValues(orig); const kind = next.kind === 'company' ? 'company' : 'private';
  const keys = ['name', 'email', 'phone', 'language', 'company', 'address', 'zip', 'city'];
  const companyOnly = ['business_id', 'einvoice_address', 'einvoice_operator', 'invoice_reference'];
  const patch = {};
  if (kind !== o.kind) patch.customer_kind = kind;
  for (const k of [...keys, ...(kind === 'company' ? companyOnly : [])]) {
    const a = norm(k, next[k]);
    if (a !== norm(k, o[k])) patch[k] = k === 'name' || k === 'language' ? a : (a || null);
  }
  return patch;
}

/** Muistiinpano: tallennetaan vain jos teksti muuttui (trim). Tyhjä → null. */
export function notePatch(orig, text) {
  const a = s(text);
  return a === s(orig) ? null : { notes: a || null };
}

export const consentPatch = (on) => ({ marketing_consent: !!on });

/** Vuosikortin peruutus: p_cancel_future vain kun käyttäjä vahvisti sen erikseen. */
export const revokeArgs = (id, cancelFuture) => ({ p_id: id, p_cancel_future: !!cancelFuture });
