// Tarjouspyyntölomakkeen tarkistus. Samat rajat kuin booking.public_create_business_quote (migraatio 72).
// Ei DOM:ia, ei verkkoa. Palauttaa { ok:true, value } tai { ok:false, code }. Palvelimen viestiä ei näytetä.

export const OFFERINGS = ['ritual', 'forest_yoga', 'campfire_meal', 'sauna', 'vihta_workshop', 'other'];
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/;
const PHONE_RE = /^[0-9+()\- ]{6,30}$/;

const trim = (v) => String(v ?? '').trim();
const lenOk = (s, min, max) => s.length >= min && s.length <= max;

export function validateQuote(input = {}) {
  const company = trim(input.company_name);
  const contact = trim(input.contact_name);
  const email = trim(input.email).toLowerCase();
  const phone = trim(input.phone);
  const when = trim(input.preferred_when);
  const personsRaw = trim(input.persons);
  const offerings = [...new Set((Array.isArray(input.offerings) ? input.offerings : []).map((x) => String(x)))];
  const other = trim(input.offering_other);
  const messageRaw = trim(input.message);
  const locale = input.locale === 'en' ? 'en' : 'fi';

  if (!lenOk(company, 2, 160)) return { ok: false, code: 'invalid_company' };
  if (!lenOk(contact, 2, 120)) return { ok: false, code: 'invalid_contact' };
  if (email.length > 254 || !EMAIL_RE.test(email)) return { ok: false, code: 'invalid_email' };
  if (!PHONE_RE.test(phone)) return { ok: false, code: 'invalid_phone' };
  if (!lenOk(when, 2, 160)) return { ok: false, code: 'invalid_when' };
  if (!/^\d+$/.test(personsRaw)) return { ok: false, code: 'invalid_persons' };
  const persons = Number(personsRaw);
  if (persons < 1 || persons > 300) return { ok: false, code: 'invalid_persons' };
  if (!offerings.length || offerings.some((x) => !OFFERINGS.includes(x))) return { ok: false, code: 'invalid_offerings' };
  if (offerings.includes('other') && !lenOk(other, 2, 200)) return { ok: false, code: 'invalid_offering_other' };
  if (messageRaw.length > 2000) return { ok: false, code: 'invalid_message' };
  if (input.privacy !== true) return { ok: false, code: 'privacy_required' };

  return {
    ok: true,
    value: {
      company_name: company,
      contact_name: contact,
      email,
      phone,
      preferred_when: when,
      persons,
      offerings,
      offering_other: offerings.includes('other') ? other : null,
      message: messageRaw || null,
      locale,
      privacy: true,
    },
  };
}
