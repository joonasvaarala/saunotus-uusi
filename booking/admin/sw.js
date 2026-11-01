// Hallinnan service worker. Scope on tämän tiedoston kansio (/hallinta/ tai testisivun /saunotus-uusi/hallinta/).
// Ei koske julkista sivustoa eikä kauppaa (/varaa/): rekisteröinti ja scope rajaavat sen, ja fetch ohittaa kaiken scopen ulkopuolisen.
// Ei välimuistita Supabasea, rajapintoja, edge-funktioita eikä tunnistautunutta dataa. HTML haetaan verkosta (ei välimuistiin),
// jotta kutsulinkki (#access_token) ja päivitykset toimivat myös erillisessä ikkunassa. Versioidut staattiset tiedostot (?v=) saa välimuistittaa.
// version.json haetaan aina verkosta (cache: 'no-store'): sitä ei saa laittaa välimuistiin, jotta avoin sivu huomaa uuden julkaisun.
// Välimuistin nimi: scripts/build-pages.mjs korvaa hallinta-__VER__. Vanhat hallinta-välimuistit poistetaan aktivoinnissa.
// Asennus kutsuu skipWaitingia ja aktivointi clients.claimia, jotta uusi worker ottaa avoimen ikkunan. Eri ?v=-tunnuksella
// tallennettua moduulia ei palauteta toiselle tunnukselle (cache-first ei käytä ignoreSearchia).
const CACHE = 'hallinta-__VER__';
const CACHE_PREFIX = 'hallinta-';
const PRECACHE = ['./offline.html', './icon-192.png', './icon-512.png', './icon-maskable-512.png', './apple-touch-icon.png'];
const TOKEN_QUERY = ['access_token', 'refresh_token', 'code', 'token', 'provider_token', 'id_token'];
const SENSITIVE_PATH = /\/(?:auth|rest|functions|storage|realtime)\/v1(?:\/|$)/;
const STATIC_EXT = /\.(?:js|mjs|css|svg|png|webp|avif|gif|jpg|jpeg|ico|woff2?)$/i;

function scopePathname() {
  const path = new URL(self.registration.scope).pathname;
  return path.endsWith('/') ? path : path + '/';
}

function classify(request) {
  let url;
  try { url = new URL(request.url); } catch { return 'bypass'; }
  if (request.method !== 'GET') return 'bypass';
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return 'bypass';
  if (request.headers && request.headers.has('authorization')) return 'bypass';
  if (url.origin !== self.location.origin) return 'bypass';
  if (/(^|\.)supabase\.(co|in)$/.test(url.hostname)) return 'bypass';
  if (SENSITIVE_PATH.test(url.pathname)) return 'bypass';
  for (const key of TOKEN_QUERY) if (url.searchParams.has(key)) return 'bypass';
  if (!url.pathname.startsWith(scopePathname())) return 'bypass';
  if (isVersionFile(url)) return 'bypass';
  if (request.mode === 'navigate' || request.destination === 'document') return 'navigate';
  const accept = (request.headers && request.headers.get('accept')) || '';
  if (accept.includes('text/html')) return 'navigate';
  if (url.searchParams.has('v') && STATIC_EXT.test(url.pathname)) return 'static';
  return 'bypass';
}

async function networkDocument(request) {
  try {
    // Uusi pyyntö (redirect: follow, ei HTTP-välimuistia). Selain pitää osoiterivin fragmentin (#access_token), sitä ei lähetetä palvelimelle.
    const res = await fetch(request.url, { redirect: 'follow', cache: 'no-store', credentials: 'same-origin', headers: { Accept: 'text/html' } });
    if (res && res.type !== 'opaqueredirect' && res.type !== 'error' && res.status !== 0) return res;
  } catch { /* verkko poikki */ }
  try {
    const cache = await caches.open(CACHE);
    const offline = await cache.match('./offline.html');
    if (offline) return offline;
  } catch { /* välimuisti ei käytettävissä */ }
  return new Response('<!doctype html><html lang="fi"><meta charset="utf-8"><title>Ei yhteyttä</title><p>Ei verkkoyhteyttä.</p>', {
    status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}

function isVersionFile(input) {
  try {
    const base = (typeof self !== 'undefined' && self.location && self.location.href) || 'https://local.invalid/hallinta/';
    const url = input instanceof URL ? input : new URL(input, base);
    return /\/version\.json$/i.test(url.pathname);
  } catch { return false; }
}

// Pyynnön ?v= ja välimuistimerkinnän ?v= pitää olla samat. Vanhaa moduulia ei palauteta uudella tunnuksella
// (eikä toisinpäin). Puuttuva vastaus-URL tarkoittaa täsmäosumaa, jonka cache.match jo rajasi.
function sameCachedAsset(requestUrl, cachedUrl) {
  if (!cachedUrl) return true;
  let req, hit;
  try {
    const base = (typeof self !== 'undefined' && self.location && self.location.href) || 'https://local.invalid/hallinta/';
    req = new URL(requestUrl, base);
    hit = new URL(cachedUrl, base);
  } catch { return false; }
  if (req.origin !== hit.origin || req.pathname !== hit.pathname) return false;
  return (req.searchParams.get('v') || '') === (hit.searchParams.get('v') || '');
}

function authClientUrl(url) {
  return /(?:access_token|refresh_token|provider_token|id_token|type=invite)(?:[=&#]|$)|[?#&](?:code|token)=/.test(String(url || ''));
}

async function cacheFirst(request) {
  const url = request.url;
  if (isVersionFile(url)) return fetch(url, { cache: 'no-store', credentials: 'same-origin' });
  const cache = await caches.open(CACHE);
  let hit = await cache.match(request, { ignoreSearch: false });
  if (hit && !sameCachedAsset(url, hit.url)) {
    hit = null;
    try { await cache.delete(request); } catch { /* välimerkintä ei saa estää verkkolatausta */ }
  }
  if (hit) return hit;
  const res = await fetch(request);
  if (res && res.status === 200 && res.type === 'basic' && !res.headers.get('set-cookie')) {
    const cc = (res.headers.get('cache-control') || '').toLowerCase();
    const type = (res.headers.get('content-type') || '').toLowerCase();
    if (!cc.includes('no-store') && !cc.includes('private') && !type.includes('text/html') && !type.includes('json')) {
      try { await cache.put(request, res.clone()); } catch { /* täysi välimuisti ei saa rikkoa latausta */ }
    }
  }
  return res;
}

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    await cache.addAll(PRECACHE);
    await self.skipWaiting();
  })());
});

// Uusi worker pyytää avointa sivua latautumaan. Sivu, jossa on uusi koodi, vastaa HALLINTA_ACK.
// Vastausta ei tule (sivu on vielä edellisestä julkaisusta) → navigate, jotta puhelin ei jää vanhaan muistiin.
function askClientToReload(client) {
  const ackMs = typeof self.UPDATE_ACK_MS === 'number' ? self.UPDATE_ACK_MS : 800;
  return new Promise((resolve) => {
    let settled = false;
    let timer = 0;
    const finish = async (held) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { self.removeEventListener('message', onMsg); } catch { /* testiympäristö */ }
      if (held === true || held === false) { resolve(held); return; }
      if (authClientUrl(client.url)) { resolve('auth'); return; }
      if (typeof client.navigate === 'function') {
        try { await client.navigate(client.url); resolve('navigate'); return; } catch { /* vanha selain */ }
      }
      resolve('stale');
    };
    const onMsg = (event) => {
      if (!event.data || event.data.type !== 'HALLINTA_ACK') return;
      if (event.source && client.id && event.source.id !== client.id) return;
      void finish(event.data.hold === true);
    };
    self.addEventListener('message', onMsg);
    timer = setTimeout(() => { void finish(null); }, ackMs);
    try { client.postMessage({ type: 'HALLINTA_UPDATED' }); }
    catch { void finish(null); }
  });
}

async function notifyOpenClients() {
  let windows = [];
  try { windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true }); }
  catch { return; }
  await Promise.all(windows.map((client) => askClientToReload(client)));
}

self.addEventListener('activate', (event) => {
  const ready = (async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((key) => key.startsWith(CACHE_PREFIX) && key !== CACHE).map((key) => caches.delete(key)));
    await self.clients.claim();
  })();
  event.waitUntil(ready);
  // Not inside waitUntil: client.navigate() during activation waits for activation itself → deadlock.
  ready.then(() => notifyOpenClients()).catch(() => {});
});

self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') self.skipWaiting();
});

self.addEventListener('fetch', (event) => {
  const kind = classify(event.request);
  if (kind === 'navigate') event.respondWith(networkDocument(event.request));
  else if (kind === 'static') event.respondWith(cacheFirst(event.request));
});

self.hallintaSw = { CACHE, CACHE_PREFIX, PRECACHE, classify, scopePathname, networkDocument, cacheFirst, isVersionFile, sameCachedAsset, authClientUrl };
