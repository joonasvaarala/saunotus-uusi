// Paketti 11 / booking_144: evästeetön mittaus. Ei cookie-, localStorage- eikä sessionStorage-käyttöä.
// Yksi satunnainen istunto VAIN tämän dokumentin muistissa; sivun vaihtuessa syntyy uusi.
// Seuranta on best-effort, eikä koskaan estä varaamista tai maksamista.
// OLETUKSENA POIS: skripti latautuu sivuille vain, jos julkaisussa SITE_ANALYTICS=on ja SITE_ENV != test (scripts/build-pages.mjs),
// ja silloinkin vain kun konfiguraatiossa enabled === true. Selaimen Do Not Track / Global Privacy Control estää mittauksen.
// booking_150: EI fetch-käärettä. Sivun fetch jää koskemattomaksi; ostotapahtuma lähetetään eksplisiittisesti tilaus- ja
// vahvistussivulla URL:n tilaustunnisteella, ja palvelin tarkistaa maksun itse (not_paid → yritetään muutaman kerran uudelleen).
const cfg = typeof window === 'undefined' ? null : window.SAUNA_ANALYTICS_CONFIG;
const optedOut = () => navigator.globalPrivacyControl === true || navigator.doNotTrack === '1' || window.doNotTrack === '1';
const blocked = () => typeof window === 'undefined' || cfg?.enabled !== true || optedOut() || navigator.webdriver === true ||
  /(^|\/)(hallinta|admin)(\/|$)/.test(location.pathname) ||
  new URLSearchParams(location.search).get('mock') === '1' ||
  new URLSearchParams(location.hash.split('?')[1] || '').get('mock') === '1';
// UTM: samat säännöt kuin palvelimella (booking._analytics_utm_ok). Kelvoton arvo jätetään pois, jotta käynti kirjautuu silti.
export function normUtm(x, max) {
  const v = String(x ?? '').trim().toLowerCase();
  if (!v || v.length > max || !/^[a-z0-9][a-z0-9_.-]*$/.test(v) || /[0-9]{5,}/.test(v) || v.replace(/[^0-9]/g, '').length >= 9) return undefined;
  return v;
}
// Polku ilman julkaisun BASE-etuliitettä (GitHub Pages -alipolku) ja ilman queryä/fragmenttia.
export function sitePath(pathname, basePath = '') {
  let p = String(pathname || '/').replace(/\/+/g, '/');
  if (basePath && (p === basePath || p.startsWith(basePath + '/'))) p = p.slice(basePath.length) || '/';
  return p.slice(0, 160);
}
const BASE_PATH = (() => { try { return new URL(import.meta.url).pathname.replace(/\/js\/analytics\.js$/, '').replace(/\/$/, ''); } catch { return ''; } })();
export function classifySource({ referrer_domain = '', utm_source, utm_campaign } = {}) {
  const d = String(referrer_domain).toLowerCase();
  if (utm_source || utm_campaign) return 'campaign';
  if (/^maps\.google\./.test(d)) return 'google_maps';
  if (/(^|\.)google\.[a-z.]+$|(^|\.)bing\.com$|(^|\.)duckduckgo\.com$/.test(d)) return 'google_search';
  if (/(^|\.)(instagram\.com|facebook\.com|fb\.com|tiktok\.com|t\.co)$/.test(d)) return 'social';
  if (!d || /(^|\.)(saunotus\.fi|saunotus\.com|github\.io)$/.test(d) || d === 'localhost') return 'direct';
  return 'referral';
}
export function deviceType(width) { return width < 700 ? 'mobile' : width < 1024 ? 'tablet' : 'desktop'; }
let sessionKey = null, lastProduct = '', lastCheckout = '';
const purchaseTried = new Set();
function uuid() {
  if (typeof crypto === 'undefined') return null;
  if (crypto.randomUUID) return crypto.randomUUID();
  if (!crypto.getRandomValues) return null;
  const a = crypto.getRandomValues(new Uint8Array(16));
  a[6] = (a[6] & 15) | 64; a[8] = (a[8] & 63) | 128;
  const h = Array.from(a, v => v.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`;
}
function base() {
  const query = new URLSearchParams(location.search);
  let referrer_domain = '';
  try { referrer_domain = document.referrer ? new URL(document.referrer).hostname.toLowerCase() : ''; } catch {}
  // URL-polku ja referrer query eivät koskaan lähde palvelimelle.
  return {
    session_key: sessionKey,
    path: sitePath(location.pathname, BASE_PATH),
    locale: document.documentElement.lang?.startsWith('en') ? 'en' : 'fi',
    device_type: deviceType(window.innerWidth),
    referrer_domain: referrer_domain || undefined,
    utm_source: normUtm(query.get('utm_source'), 40),
    utm_medium: normUtm(query.get('utm_medium'), 40),
    utm_campaign: normUtm(query.get('utm_campaign'), 60),
  };
}
export function track(event_type, detail = {}) {
  if (blocked() || !cfg?.url || !cfg?.anonKey || !sessionKey) return;
  const allowed = ['page_view', 'product_view', 'checkout_start', 'purchase'];
  if (!allowed.includes(event_type)) return;
  const payload = { ...base(), event_type };
  if (Number.isSafeInteger(+detail.product_id) && +detail.product_id > 0) payload.product_id = +detail.product_id;
  if (/^[a-z0-9-]{1,100}$/.test(detail.product_slug || '')) payload.product_slug = detail.product_slug;
  if (event_type === 'purchase' && /^[0-9a-f-]{36}$/i.test(detail.order_token || '')) payload.order_token = detail.order_token;
  if (event_type === 'purchase' && !payload.order_token) return;
  return send(payload);
}
// Nimenomaan credentials: omit, jotta muut palvelut eivät saa selaimen evästeitä. Palauttaa vastauksen JSONin tai null; ei koskaan heitä.
function send(payload) {
  try {
    return fetch(cfg.url.replace(/\/$/, '') + '/rest/v1/rpc/public_track_event', {
      method: 'POST', credentials: 'omit', keepalive: true,
      headers: { apikey: cfg.anonKey, 'Content-Type':'application/json', 'Content-Profile':'booking','Accept-Profile':'booking' },
      body: JSON.stringify({ p_payload: payload })
    }).then(r => r.json()).catch(() => null);
  } catch { return Promise.resolve(null); } // analytics ei saa koskaan vaikuttaa kauppaan
}
function route() {
  const m = /^#\/(tuote|hoito|varaa)\/([a-z0-9-]+)/i.exec(location.hash);
  if (m) {
    const slug = m[2].toLowerCase();
    if (slug !== lastProduct) { lastProduct = slug; track('product_view', { product_slug: slug }); }
    if (m[1] === 'varaa' || m[1] === 'hoito') {
      const k = `${m[1]}:${slug}`;
      if (lastCheckout !== k) { lastCheckout = k; track('checkout_start', { product_slug: slug }); }
    }
  }
}
// Ostotapahtuma: tilaussivun ?t=<token> tai vahvistussivun #<token>. Palvelin hyväksyy vain maksetun tilauksen (muuten not_paid)
// ja tallentaa saman tilauksen vain kerran. Maksu voi vahvistua hetken viiveellä (MobilePay-paluu), joten not_paid → uusi yritys.
export const PURCHASE_RETRY_MS = [15000, 45000, 120000];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function orderTokenFrom(loc, basePath = BASE_PATH) {
  const path = sitePath(loc.pathname, basePath);
  const q = new URLSearchParams(loc.search || '').get('t') || '';
  if (/^\/(tilaus|en\/order)\/?$/.test(path) && UUID_RE.test(q)) return q.toLowerCase();
  const h = /^#([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:[/?]|$)/i.exec(loc.hash || '');
  return h ? h[1].toLowerCase() : null;
}
function watchPurchase() {
  const token = orderTokenFrom(location);
  if (!token || purchaseTried.has(token)) return;
  purchaseTried.add(token);
  let i = 0;
  const attempt = () => {
    const p = track('purchase', { order_token: token, product_slug: lastProduct || undefined });
    if (!p) return;
    p.then(j => { if (j?.code === 'not_paid' && i < PURCHASE_RETRY_MS.length) setTimeout(attempt, PURCHASE_RETRY_MS[i++]); });
  };
  attempt();
}
if (!blocked() && cfg?.url && cfg?.anonKey) {
  sessionKey = uuid();
  if (sessionKey) {
    track('page_view'); route(); watchPurchase();
    window.addEventListener('hashchange', () => { route(); watchPurchase(); });
    // Shop/gift-sivut: checkout_start vain oikealle kassalle siirtymisestä tai lähetyksestä.
    document.addEventListener('submit', (event) => {
      if (event.target?.closest('#gift-app') || event.target?.closest('#booking-app')) {
        const m = /^#\/(?:tuote|varaa|hoito)\/([a-z0-9-]+)/i.exec(location.hash);
        const slug = m?.[1];
        const key = `submit:${slug || location.pathname}`;
        if (lastCheckout !== key) { lastCheckout = key; track('checkout_start', { product_slug: slug }); }
      }
    }, true);
    // Lahjakortin tuotteen avaus tapahtuu kortin Lisää-painikkeestä, ei hash-reitityksessä.
    document.addEventListener('click', (event) => {
      const tile = event.target?.closest?.('#gift-app .gc-tile');
      if (tile && event.target.closest('button')) {
        const name = tile.querySelector('h3')?.textContent || '';
        // Ei välitetä käyttäjän syöttämiä tietoja tuotenimenä. Vain vakioitu slug.
        const slug = name.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g,'')
          .replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'').slice(0,100) || 'lahjakortti';
        if (lastProduct !== slug) { lastProduct = slug; track('product_view',{product_slug:slug}); }
      }
    }, true);
    document.addEventListener('focusin', event => {
      if (event.target?.closest?.('#gift-app .gc-cartsec input, #booking-app .bk-checkout input')) {
        const key = 'contact:'+location.hash+location.pathname;
        if (lastCheckout!==key) { lastCheckout=key; track('checkout_start',{product_slug:lastProduct||undefined}); }
      }
    });
  }
}
