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

// Kutsu-/palautuslinkki palauttaa käyttäjän osoitteeseen #access_token=…&refresh_token=…&type=invite. Otetaan istunto käyttöön ja siivotaan osoite.
// Palauttaa 'invite' | 'recovery' jos linkistä saatiin istunto, muuten null.
export function adoptSessionFromHash() {
  const p = new URLSearchParams(location.hash.replace(/^#/, ''));
  const at = p.get('access_token'), type = p.get('type');
  if (!at || !['invite', 'recovery'].includes(type)) return null;
  let user = null;
  try { const c = JSON.parse(atob(at.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))); user = { id: c.sub, email: c.email }; } catch { return null; }
  history.replaceState(null, '', location.pathname + location.search);
  save({ access_token: at, refresh_token: p.get('refresh_token') || '', expires_at: Math.floor(Date.now() / 1000) + (+p.get('expires_in') || 3600), user });
  return type;
}
// Asettaa kirjautuneen käyttäjän salasanan (kutsun hyväksyntä). Vähintään 8 merkkiä; Supabase Auth voi vaatia enemmän.
export async function setPassword(password) {
  const tk = await token();
  const r = await fetch(base(`${cfg().auth || '/auth/v1'}/user`), { method: 'PUT', headers: { apikey: cfg().anonKey, Authorization: `Bearer ${tk}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ password }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new ApiError(j.msg || j.message || j.error_description || 'Salasanan asetus epäonnistui', { status: r.status, code: j.error_code });
  return true;
}
// Edge Function -kutsu: fn('admin-users', { action: 'invite', ... }) → JSON. Kutsuja tunnistetaan käyttäjän omalla JWT:llä; palvelinavainta ei käytetä selaimessa.
export async function fn(name, body) {
  const tk = await token();
  const bearer = tk && tk.split('.').length === 3 ? { Authorization: `Bearer ${tk}` } : {};
  const r = await fetch(base(`${cfg().functions ?? '/functions/v1'}/${name}`), { method: 'POST', headers: { apikey: cfg().anonKey, ...bearer, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const text = await r.text();
  let j; try { j = text ? JSON.parse(text) : {}; } catch { j = { message: text }; }
  if (!r.ok || j.ok === false) throw new ApiError(j.message || j.msg || r.statusText || 'Pyyntö epäonnistui', { code: j.code, status: r.status, details: j });
  return j;
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

// ---- Storage (tuotekuvat) ----
// Julkinen URL (bucket on julkinen): <url>/storage/v1/object/public/<bucket>/<polku>. cfg.storage voi ylikirjoittaa polun (esim. CDN).
export const storageUrl = (bucket, path) => `${base(cfg().storage ?? '/storage/v1')}/object/public/${bucket}/${String(path).split('/').map(encodeURIComponent).join('/')}`;
async function storageReq(method, bucket, path, body, contentType) {
  const tk = await token();
  const bearer = tk && tk.split('.').length === 3 ? { Authorization: `Bearer ${tk}` } : {};
  const r = await fetch(base(`${cfg().storage ?? '/storage/v1'}/object/${bucket}/${path}`), {
    method, headers: { apikey: cfg().anonKey, ...bearer, ...(contentType ? { 'Content-Type': contentType, 'Cache-Control': 'max-age=3600' } : {}) }, body,
  });
  const text = await r.text();
  let j; try { j = text ? JSON.parse(text) : null; } catch { j = { message: text }; }
  if (!r.ok) {
    if (r.status === 401) { if (session) save(null); }
    const msg = r.status === 403 || r.status === 401 ? 'Ei oikeutta kuvien hallintaan' : r.status === 413 ? 'Kuva on liian suuri (enintään 2 MB)' : (j?.message || j?.error || r.statusText);
    throw new ApiError(msg, { status: r.status, details: j });
  }
  return j;
}
// Lataa tiedoston kirjautuneen käyttäjän istunnolla (RLS: catalog.edit). Ei ylikirjoita olemassa olevaa (uusi polku joka latauksella).
export const uploadObject = (bucket, path, blob) => storageReq('POST', bucket, path, blob, blob.type || 'application/octet-stream');
export const removeObject = (bucket, path) => storageReq('DELETE', bucket, path);

export const sb = { rpc, select, fn, storageUrl, uploadObject, removeObject, signIn, signOut, getSession, onAuthChange, adoptSessionFromHash, setPassword };
export default sb;
