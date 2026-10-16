// Kevyt Supabase/PostgREST-asiakas ilman riippuvuuksia (~120 riviä). Käytetään sekä kaupassa (anon) että hallinnassa (kirjautunut).
// Konfiguraatio: window.BOOKING_CONFIG = { url, anonKey, rest: '/rest/v1', auth: '/auth/v1', schema: 'booking' }
// Palvelurooliavainta EI koskaan käytetä selaimessa. anon/publishable-avain saa olla julkinen: oikeudet määrää RLS + funktioiden GRANTit.

const cfg = () => window.BOOKING_CONFIG || {};
const base = (path) => (cfg().url || '').replace(/\/$/, '') + path;
const SCHEMA = () => cfg().schema || 'booking';

export class ApiError extends Error {
  constructor(message, { code, status, details } = {}) { super(message); this.name = 'ApiError'; this.code = code; this.status = status; this.details = details; }
}

// ---- istunto (vain hallinta) ----
const KEY = 'booking.session';
let session = null;
try { session = JSON.parse(localStorage.getItem(KEY) || 'null'); } catch { session = null; }
const listeners = new Set();
const save = (s) => { session = s; try { s ? localStorage.setItem(KEY, JSON.stringify(s)) : localStorage.removeItem(KEY); } catch {} listeners.forEach((f) => f(s)); };
export const onAuthChange = (f) => { listeners.add(f); return () => listeners.delete(f); };
export const getSession = () => session;

async function authFetch(grant, body) {
  const r = await fetch(base(`${cfg().auth || '/auth/v1'}/token?grant_type=${grant}`), {
    method: 'POST', headers: { apikey: cfg().anonKey, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new ApiError(j.error_description || j.msg || j.message || 'Kirjautuminen epäonnistui', { status: r.status, code: j.error_code || j.error });
  return { access_token: j.access_token, refresh_token: j.refresh_token, expires_at: Math.floor(Date.now() / 1000) + (j.expires_in || 3600), user: j.user };
}
export async function signIn(email, password) { save(await authFetch('password', { email, password })); return session; }
export function signOut() { save(null); }
async function token() {
  if (!session) return cfg().anonKey;
  if (session.expires_at - 60 < Date.now() / 1000) {
    try { save(await authFetch('refresh_token', { refresh_token: session.refresh_token })); } catch { save(null); return cfg().anonKey; }
  }
  return session.access_token;
}

// ---- pyynnöt ----
async function request(path, { method = 'GET', body, query, headers = {} } = {}) {
  const qs = query ? '?' + new URLSearchParams(query).toString() : '';
  const tk = await token();
  // Uudet Supabase "publishable"-avaimet eivät ole JWT:itä: niiden kanssa Authorization-otsikkoa ei lähetetä (vain apikey).
  const bearer = tk && tk.split('.').length === 3 ? { Authorization: `Bearer ${tk}` } : {};
  const r = await fetch(base(`${cfg().rest ?? '/rest/v1'}${path}${qs}`), {
    method,
    headers: {
      apikey: cfg().anonKey, ...bearer, 'Content-Type': 'application/json',
      'Accept-Profile': SCHEMA(), 'Content-Profile': SCHEMA(), ...headers,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (r.status === 204) return null;
  const text = await r.text();
  let j; try { j = text ? JSON.parse(text) : null; } catch { j = { message: text }; }
  if (!r.ok) {
    if (r.status === 401) { if (session) save(null); }
    throw new ApiError(j?.message || r.statusText, { code: j?.details || j?.code, status: r.status, details: j });
  }
  return j;
}

// rpc('public_availability', { p_product_id: 1, ... }) -> data
export const rpc = (fn, args = {}) => request(`/rpc/${fn}`, { method: 'POST', body: args });
// select('customers', { select: 'id,name', order: 'name.asc', limit: 50, 'name': 'ilike.*abc*' })
export const select = (table, query = {}) => request(`/${table}`, { query });

export const sb = { rpc, select, signIn, signOut, getSession, onAuthChange };
export default sb;
