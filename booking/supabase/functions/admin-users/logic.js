// Edge Function admin-users: puhdas, riippuvuudeton validointilogiikka (testattavissa Denolla ja Node.js:llä, ks. logic.test.js).
// Tietokantasäännöt (viimeinen admin, itsensä deaktivointi, rooli, audit) ovat booking.svc_*-funktioissa; tämä on ensimmäinen suodatin.

// Kutsuttavat roolit: kovakoodattu sallittulista. Asiakasroolit (customer, annual_card) eivät koskaan kelpaa; tietokanta tarkistaa roolin vielä booking.roles-taulusta.
export const ROLE_WHITELIST = Object.freeze(['admin', 'manager', 'staff']);
export const ACTIONS = Object.freeze(['invite', 'deactivate', 'reactivate']);

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_RE = /^[^\s@<>()[\]\\,;:"]+@[^\s@<>()[\]\\,;:"]+\.[^\s@<>()[\]\\,;:"]{2,}$/;

export const isUuid = (v) => typeof v === 'string' && UUID_RE.test(v);
export const normalizeEmail = (v) => (typeof v === 'string' ? v.trim().toLowerCase() : '');
export const isEmail = (v) => typeof v === 'string' && v.length <= 254 && EMAIL_RE.test(v);

const fail = (code, message, status = 400) => ({ ok: false, status, code, message });

// Palauttaa { ok: true, action, ... } tai { ok: false, status, code, message }. Tuntemattomat kentät hylätään (ei läpivientiä tietokantaan).
export function validateRequest(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) return fail('invalid_body', 'Pyynnön runko puuttuu tai on virheellinen');
  const { action } = body;
  if (!ACTIONS.includes(action)) return fail('invalid_action', 'Tuntematon toiminto');
  const allowed = action === 'invite' ? ['action', 'email', 'name', 'role'] : ['action', 'user_id'];
  const extra = Object.keys(body).filter((k) => !allowed.includes(k));
  if (extra.length) return fail('unknown_field', `Tuntematon kenttä: ${extra[0].slice(0, 30)}`);
  if (action === 'invite') {
    const email = normalizeEmail(body.email);
    if (!isEmail(email)) return fail('invalid_email', 'Sähköpostiosoite on virheellinen');
    const name = typeof body.name === 'string' ? body.name.trim().replace(/\s+/g, ' ') : '';
    if (name.length < 1 || name.length > 100) return fail('invalid_name', 'Nimi on pakollinen (enintään 100 merkkiä)');
    if (/[\u0000-\u001f<>]/.test(name)) return fail('invalid_name', 'Nimessä on kiellettyjä merkkejä');
    if (typeof body.role !== 'string' || !ROLE_WHITELIST.includes(body.role)) return fail('invalid_role', 'Rooli ei kelpaa (sallitut: admin, manager, staff)');
    return { ok: true, action, email, name, role: body.role };
  }
  if (!isUuid(body.user_id)) return fail('invalid_user_id', 'Käyttäjätunnus (UUID) on virheellinen');
  return { ok: true, action, user_id: body.user_id.toLowerCase() };
}

// ALLOWED_ORIGINS = pilkuilla eroteltu lista origineja, esim. "https://hallinta.example.fi,http://localhost:4180". Ei jokerimerkkiä.
export function parseAllowedOrigins(str) {
  return String(str || '').split(',').map((s) => s.trim().replace(/\/$/, '')).filter((s) => s && s !== '*');
}
export const isOriginAllowed = (origin, allowed) => typeof origin === 'string' && allowed.includes(origin.replace(/\/$/, ''));
// CORS-otsikot vain sallitulle originille; muille null (kutsuja vastaa 403).
export function corsHeaders(origin, allowed) {
  if (!isOriginAllowed(origin, allowed)) return null;
  return { 'Access-Control-Allow-Origin': origin, 'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Max-Age': '600', Vary: 'Origin' };
}

// Kutsulinkin kohde: INVITE_REDIRECT_URL (ensisijainen, käytetään sellaisenaan) tai varakohde SITE_URL + '/hallinta/'. Pitää olla https (tai http://localhost kehityksessä). Muuten null.
export function resolveRedirect(env) {
  const explicit = String(env.INVITE_REDIRECT_URL || '').trim(), site = String(env.SITE_URL || '').trim().replace(/\/$/, '');
  const raw = explicit || (site ? `${site}/hallinta/` : '');
  if (!raw) return null;
  try {
    const u = new URL(raw);
    const local = u.protocol === 'http:' && (u.hostname === 'localhost' || u.hostname === '127.0.0.1');
    return u.protocol === 'https:' || local ? u.toString() : null;
  } catch { return null; }
}

// Tietokannan BK001-virhekoodit (DETAIL) → HTTP-tila ja suomenkielinen viesti. Tuntematon virhe → 500 ilman sisäisiä yksityiskohtia.
const DB_ERRORS = {
  forbidden: [403, 'Ei oikeutta tähän toimintoon'], cannot_change_self: [409, 'Et voi poistaa omaa tunnustasi käytöstä'], last_admin: [409, 'Viimeistä aktiivista adminia ei voi poistaa käytöstä tai alentaa'],
  no_such_staff: [404, 'Käyttäjää ei löydy henkilökunnasta'], no_such_user: [404, 'Käyttäjää ei löydy'], invalid_role: [400, 'Rooli ei kelpaa'],
};
export function mapDbError(err) {
  const code = String(err?.details || err?.detail || '').trim();
  if (DB_ERRORS[code]) return { status: DB_ERRORS[code][0], code, message: DB_ERRORS[code][1] };
  return { status: 500, code: 'internal', message: 'Palvelinvirhe' };
}
