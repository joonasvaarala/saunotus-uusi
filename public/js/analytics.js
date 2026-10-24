// Paketti 11 / booking_144: evästeetön mittaus. Ei cookie-, localStorage- eikä sessionStorage-käyttöä.
// Yksi satunnainen istunto VAIN tämän dokumentin muistissa; sivun vaihtuessa syntyy uusi.
// Seuranta on best-effort, eikä koskaan estä varaamista tai maksamista.
// OLETUKSENA POIS: skripti latautuu sivuille vain, jos julkaisussa SITE_ANALYTICS=on ja SITE_ENV != test (scripts/build-pages.mjs),
// ja silloinkin vain kun konfiguraatiossa enabled === true. Selaimen Do Not Track / Global Privacy Control estää mittauksen.
const cfg = typeof window === 'undefined' ? null : window.SAUNA_ANALYTICS_CONFIG;
const optedOut = () => navigator.globalPrivacyControl === true || navigator.doNotTrack === '1' || window.doNotTrack === '1';
const blocked = () => typeof window === 'undefined' || cfg?.enabled !== true || optedOut() || navigator.webdriver === true ||
  /(^|\/)(hallinta|admin)(\/|$)/.test(location.pathname) ||
  new URLSearchParams(location.search).get('mock') === '1' ||
  new URLSearchParams(location.hash.split('?')[1] || '').get('mock') === '1';
const norm = (x, max) => /^[a-z0-9_.-]+$/.test(String(x || '').toLowerCase()) ? String(x).toLowerCase().slice(0, max) : undefined;
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
let sessionKey = null, lastProduct = '', lastCheckout = '', recordedPaid = new Set();
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
    path: location.pathname.replace(/\/+/g, '/').slice(0, 160),
    locale: document.documentElement.lang?.startsWith('en') ? 'en' : 'fi',
    device_type: deviceType(window.innerWidth),
    referrer_domain: referrer_domain || undefined,
    utm_source: norm(query.get('utm_source'), 80),
    utm_medium: norm(query.get('utm_medium'), 80),
    utm_campaign: norm(query.get('utm_campaign'), 100),
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
  // Nimenomaan credentials: omit, jotta muut palvelut eivät saa selaimen evästeitä.
  try { void fetch(cfg.url.replace(/\/$/, '') + '/rest/v1/rpc/public_track_event', {
    method: 'POST', credentials: 'omit', keepalive: true,
    headers: { apikey: cfg.anonKey, 'Content-Type':'application/json', 'Content-Profile':'booking','Accept-Profile':'booking' },
    body: JSON.stringify({ p_payload: payload })
  }).catch(() => {}); } catch {} // analytics ei saa koskaan vaikuttaa kauppaan
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
// Tilaussivulla tarkistetaan serverivahvistuksesta maksu, ei tilaussivun URL:stä tai tilaustapahtumasta.
function paidResponse(json, token) {
  if (!json || typeof json !== 'object') return;
  const paid = json.payment_status === 'paid' && json.ok !== false;
  if (paid && /^[0-9a-f-]{36}$/i.test(token || '') && !recordedPaid.has(token)) {
    recordedPaid.add(token); track('purchase', { order_token: token, product_slug: lastProduct || undefined });
  }
}
function installNetworkListener() {
  const original = window.fetch;
  if (typeof original !== 'function') return;
  window.fetch = function(input, init) {
    const request = original.apply(this, arguments);
    try {
      const url = new URL(typeof input === 'string' ? input : input.url, location.href);
      const fn = url.pathname.match(/\/rpc\/(public_get_booking|public_get_order|public_buy_gift_card|public_create_booking|public_create_treatment_booking)$/)?.[1];
      if (fn && !url.pathname.endsWith('public_track_event')) {
        const args = typeof init?.body === 'string' ? JSON.parse(init.body) : {};
        request.then(async res => {
          if (!res.ok) return;
          const j = await res.clone().json().catch(() => null);
          if (!j) return;
          // Varaus/vahvistus voi olla maksamaton; sen perusteella EI tehdä purchase-merkintää.
          if (fn === 'public_get_booking' || fn === 'public_get_order') paidResponse(j, args.p_token);
          if (fn === 'public_create_booking' || fn === 'public_create_treatment_booking') {
            if (j.ok !== false && j.token) paidResponse(j, j.token);
          }
          if (fn === 'public_buy_gift_card') paidResponse(j, j.token);
        }).catch(() => {});
      }
    } catch {} // Ei koskaan muuta alkuperäisen fetchin onnistumista/virhettä.
    return request;
  };
}
if (!blocked() && cfg?.url && cfg?.anonKey) {
  sessionKey = uuid();
  if (sessionKey) {
    track('page_view'); route();
    window.addEventListener('hashchange', route);
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
    installNetworkListener();
  }
}
