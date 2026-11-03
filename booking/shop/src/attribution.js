// booking_241: tilauksen lähde (p_attribution). Lähde tallentuu välilehden sessionStorageen vain sivuston mittausskriptissä
// (public/js/analytics.js, avain saunotus_analytics), ja vain kun mittaus on sallittu. Tämä moduuli VAIN lukee sen.
// Sopimus: booking_241 KOODARILLE.md. Kentät: session_key, referrer_domain, utm_source, utm_medium, utm_campaign, landing_path,
// device_type, locale. source_category lasketaan palvelimella, eikä sitä lähetetä. Palvelin pudottaa kelvottomat kentät yksitellen.
// Lähde EI koskaan saa estää tilausta: kaikki virheet → parametri jätetään pois.
export const STORAGE_KEY = 'saunotus_analytics';
export const ATTRIBUTION_RPCS = Object.freeze(['public_create_booking', 'public_create_booking_code', 'public_create_treatment_booking',
  'public_buy_gift_card', 'public_buy_annual_card', 'public_create_training_signup']);
const SESSION_RE = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const utm = (v, max) => {
  const s = typeof v === 'string' ? v.trim().toLowerCase() : '';
  if (!s || s.length > max || !/^[a-z0-9][a-z0-9_.-]*$/.test(s) || /[0-9]{5,}/.test(s) || s.replace(/[^0-9]/g, '').length >= 9 || s.includes('@')) return undefined;
  return s;
};
/** Tallennetusta tietueesta lähetettävä p_attribution tai null. Puhdas funktio. */
export function cleanAttribution(rec) {
  if (!rec || typeof rec !== 'object') return null;
  const key = typeof rec.session_key === 'string' ? rec.session_key : '';
  if (!SESSION_RE.test(key)) return null;
  const out = { session_key: key };
  const d = typeof rec.referrer_domain === 'string' ? rec.referrer_domain.trim().toLowerCase() : '';
  if (d && d.length <= 180 && d.includes('.') && /^[a-z0-9.-]+$/.test(d)) out.referrer_domain = d;
  for (const [k, max] of [['utm_source', 40], ['utm_medium', 40], ['utm_campaign', 60]]) { const v = utm(rec[k], max); if (v) out[k] = v; }
  const p = typeof rec.landing_path === 'string' ? rec.landing_path : '';
  if (p.startsWith('/') && p.length <= 160 && !/[?#\s]/.test(p)) out.landing_path = p;
  if (['mobile', 'desktop', 'tablet'].includes(rec.device_type)) out.device_type = rec.device_type;
  if (['fi', 'en'].includes(rec.locale)) out.locale = rec.locale;
  return out;
}
const optedOut = (nav, win) => nav?.globalPrivacyControl === true || nav?.doNotTrack === '1' || win?.doNotTrack === '1';
const isMock = (loc) => {
  try {
    return new URLSearchParams(loc?.search || '').get('mock') === '1' || new URLSearchParams(String(loc?.hash || '').split('?')[1] || '').get('mock') === '1';
  } catch { return false; }
};
/** Lukee välilehden lähteen. Ei koskaan heitä. DNT/GPC, webdriver tai mock=1 → null (samat poissulut kuin mittauksessa). */
export function readAttribution(env = typeof window === 'undefined' ? null : window) {
  try {
    if (!env) return null;
    const nav = env.navigator;
    if (optedOut(nav, env) || nav?.webdriver === true || isMock(env.location)) return null;
    let storage = null;
    try { storage = env.sessionStorage; } catch { return null; }
    const raw = storage?.getItem(STORAGE_KEY);
    return raw ? cleanAttribution(JSON.parse(raw)) : null;
  } catch { return null; }
}
/** args + p_attribution, kun funktio on jokin kuudesta ja lähde on tallessa; muuten args sellaisenaan (parametri jätetään pois). */
export function withAttribution(fn, args, read = readAttribution) {
  try {
    if (!ATTRIBUTION_RPCS.includes(fn)) return args;
    const a = read();
    return a ? { ...(args || {}), p_attribution: a } : args;
  } catch { return args; }
}
