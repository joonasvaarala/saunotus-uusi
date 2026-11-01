// Hallinnan PWA: manifesti ja service worker vain /hallinta/-polussa (myös testisivun etuliite).
// Ei välimuistita Supabasea, rajapintoja eikä tunnistautunutta dataa. Kutsulinkki osuu samaan scopeen.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import { resolveRedirect } from '../supabase/functions/admin-users/logic.js';
import { PWA_TEXT, isIosDevice, isStandaloneDisplay, shouldRegisterSw, installHintKind, hallintaSwScope, hallintaSwScript, startHallintaPwa } from '../admin/pwa.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const manifest = JSON.parse(read('booking/admin/manifest.json'));
const html = read('booking/admin/index.html');
const swSrc = read('booking/admin/sw.js');

function pngInfo(buf) {
  assert.equal(buf.subarray(1, 4).toString('ascii'), 'PNG');
  assert.equal(buf.subarray(12, 16).toString('ascii'), 'IHDR');
  return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20), color: buf[25] };
}

function loadSw(scope) {
  const listeners = {};
  const sandbox = {
    URL, Response, console, setTimeout, clearTimeout,
    fetch: async () => { throw new Error('fetch puuttuu'); },
    caches: { open: async () => { throw new Error('caches.open puuttuu'); }, keys: async () => [], delete: async () => false },
  };
  sandbox.self = {
    location: new URL(new URL('sw.js', scope).href),
    registration: { scope },
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
    removeEventListener(type, fn) {
      const list = listeners[type];
      if (!list) return;
      const i = list.indexOf(fn);
      if (i >= 0) list.splice(i, 1);
    },
    skipWaiting() { sandbox.self.skipped = (sandbox.self.skipped || 0) + 1; },
    clients: { claim: async () => { sandbox.self.claimed = true; }, matchAll: async () => [] },
  };
  vm.createContext(sandbox);
  vm.runInContext(swSrc, sandbox, { filename: 'sw.js' });
  return { sandbox, listeners, api: sandbox.self.hallintaSw };
}

function req(url, opt = {}) {
  const headers = new Map(Object.entries(opt.headers || {}).map(([k, v]) => [k.toLowerCase(), v]));
  return {
    method: opt.method || 'GET', url, mode: opt.mode || '', destination: opt.destination || '',
    headers: { get: (k) => headers.get(String(k).toLowerCase()) ?? null, has: (k) => headers.has(String(k).toLowerCase()) },
  };
}

test('manifesti on suhteellinen, suomeksi, standalone ja vain hallinnan polussa', () => {
  assert.equal(manifest.name, 'Saunotus hallinta');
  assert.equal(manifest.short_name, 'Hallinta');
  assert.equal(manifest.lang, 'fi');
  assert.equal(manifest.display, 'standalone');
  assert.equal(manifest.orientation, 'portrait');
  assert.equal(manifest.scope, './');
  assert.equal(manifest.start_url, './');
  assert.equal(manifest.id, './');
  assert.equal(manifest.background_color, '#F4EFE7');
  assert.equal(manifest.theme_color, '#2B3A30');
  assert.equal(manifest.handle_links, 'preferred');
  assert.equal(manifest.launch_handler.client_mode, 'navigate-existing');
  assert.match(read('booking/admin/admin.css'), /--green:#2B3A30/);
  assert.match(read('booking/admin/admin.css'), /--bg:#F4EFE7/);
  assert.deepEqual(manifest.icons.map((i) => i.purpose), ['any', 'any', 'maskable']);
  for (const [site, shop] of [['https://saunotus.fi', '/varaa/'], ['https://joonasvaarala.github.io/saunotus-uusi', '/saunotus-uusi/varaa/']]) {
    const redirect = resolveRedirect({ SITE_URL: site });
    assert.equal(redirect, site + '/hallinta/');
    const manifestUrl = new URL('manifest.json', redirect);
    assert.equal(new URL(manifest.start_url, manifestUrl).href, redirect);
    assert.equal(new URL(manifest.scope, manifestUrl).href, redirect);
    assert.equal(hallintaSwScope(new URL('pwa.js', redirect).href), redirect);
    assert.equal(hallintaSwScript(new URL('pwa.js?v=old', redirect).href, '?v=abc'), new URL('sw.js?v=abc', redirect).href);
    const shopUrl = new URL(shop, site + '/');
    assert.equal(shopUrl.pathname.startsWith(new URL(redirect).pathname), false, shop);
    assert.equal(new URL('/', site + '/').pathname.startsWith(new URL(redirect).pathname), false);
  }
});

test('kuvakkeet tulevat sivuston logosta ja ovat oikean kokoisia ilman läpinäkyvyyttä', () => {
  const gen = read('scripts/hallinta-pwa-icons.mjs');
  assert.match(gen, /public\/img\/favicon\.svg/);
  const expect = { 'icon-192.png': 192, 'icon-512.png': 512, 'icon-maskable-512.png': 512, 'apple-touch-icon.png': 180 };
  for (const [name, size] of Object.entries(expect)) {
    assert.match(gen, new RegExp(name.replace('.', '\\.')));
    const info = pngInfo(readFileSync(join(root, 'booking/admin', name)));
    assert.equal(info.w, size, name);
    assert.equal(info.h, size, name);
    assert.equal(info.color, 2, `${name}: ei alfakanavaa`);
  }
  assert.equal(manifest.icons[0].sizes, '192x192');
  assert.equal(manifest.icons[1].sizes, '512x512');
  assert.equal(manifest.icons[2].src, 'icon-maskable-512.png');
  assert.equal(manifest.icons[2].purpose, 'maskable');
});

test('index.html: iOS-metat ja suhteelliset kuvake- ja manifestilinkit', () => {
  assert.match(html, /rel="manifest" href="manifest\.json"/);
  assert.match(html, /rel="apple-touch-icon" href="apple-touch-icon\.png"/);
  assert.match(html, /name="apple-mobile-web-app-capable" content="yes"/);
  assert.match(html, /name="mobile-web-app-capable" content="yes"/);
  assert.match(html, /name="apple-mobile-web-app-status-bar-style" content="black"/);
  assert.match(html, /name="apple-mobile-web-app-title" content="Hallinta"/);
  assert.match(html, /name="theme-color" content="#2B3A30"/);
  assert.doesNotMatch(html, /href="\/hallinta\/|href="\/manifest|src="\/sw\.js/);
  assert.match(read('booking/admin/admin.js'), /startHallintaPwa\(\)/);
  assert.match(read('booking/admin/admin.css'), /\.pwa-hint \.btn,\.pwa-update \.btn\{min-height:44px\}/);
});

test('asennusvihje: Androidin kehote, iPhonen Jaa-ohje, ei erillisessä ikkunassa eikä sulkemisen jälkeen', () => {
  assert.equal(PWA_TEXT.installButton, 'Asenna sovellukseksi');
  assert.match(PWA_TEXT.installIos, /Jaa → Lisää Koti-valikkoon/);
  assert.match(PWA_TEXT.update, /Uusi versio on saatavilla/);
  assert.equal(PWA_TEXT.reload, 'Lataa uudelleen');
  assert.equal(installHintKind({ standalone: false, dismissed: false, ios: false, canPrompt: true }), 'android');
  assert.equal(installHintKind({ standalone: false, dismissed: false, ios: true, canPrompt: false }), 'ios');
  assert.equal(installHintKind({ standalone: true, dismissed: false, ios: true, canPrompt: true }), null);
  assert.equal(installHintKind({ standalone: false, dismissed: true, ios: true, canPrompt: true }), null);
  assert.equal(installHintKind({ standalone: false, dismissed: false, ios: false, canPrompt: false }), null);
  assert.equal(isIosDevice({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)' }), true);
  assert.equal(isIosDevice({ userAgent: 'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)' }), true);
  assert.equal(isIosDevice({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X)', platform: 'MacIntel', maxTouchPoints: 5 }), true);
  assert.equal(isIosDevice({ userAgent: 'Mozilla/5.0 (Linux; Android 14)', platform: 'Linux', maxTouchPoints: 5 }), false);
  assert.equal(isIosDevice({ userAgent: 'Mozilla/5.0 (X11; Linux x86_64)', platform: 'Linux', maxTouchPoints: 0 }), false);
  assert.equal(isStandaloneDisplay({ standalone: true }, () => ({ matches: false })), true);
  assert.equal(isStandaloneDisplay({}, (q) => ({ matches: q === '(display-mode: standalone)' })), true);
  assert.equal(isStandaloneDisplay({}, () => ({ matches: false })), false);
  assert.equal(shouldRegisterSw('/hallinta/'), true);
  assert.equal(shouldRegisterSw('/hallinta'), true);
  assert.equal(shouldRegisterSw('/hallinta/index.html'), true);
  assert.equal(shouldRegisterSw('/saunotus-uusi/hallinta/'), true);
  assert.equal(shouldRegisterSw('/saunotus-uusi/hallinta/index.html'), true);
  assert.equal(shouldRegisterSw('/varaa/'), false);
  assert.equal(shouldRegisterSw('/saunotus-uusi/varaa/'), false);
  assert.equal(shouldRegisterSw('/'), false);
  assert.equal(shouldRegisterSw('/saunotus-uusi/'), false);
  assert.equal(shouldRegisterSw('/hallinta/offline.html'), false);
  assert.match(read('booking/admin/pwa.js'), /addEventListener\('controllerchange'/);
  assert.match(read('booking/admin/pwa.js'), /applyServiceWorkerUpdate/);
  assert.match(read('booking/admin/sw.js'), /await self\.skipWaiting\(\)/);
  assert.match(read('booking/admin/sw.js'), /self\.clients\.claim\(\)/);
  assert.equal(startHallintaPwa(), undefined);
});

test('service worker: ei Supabasea, ei kauppaa, HTML verkosta, vanha välimuisti pois', async () => {
  const prod = 'https://saunotus.fi/hallinta/';
  const { sandbox, listeners, api } = loadSw(prod);
  const kind = (url, opt) => api.classify(req(url, opt));
  assert.equal(kind('https://abc.supabase.co/auth/v1/token?grant_type=password', { method: 'POST' }), 'bypass');
  assert.equal(kind('https://abc.supabase.co/rest/v1/rpc/admin_day_bundle'), 'bypass');
  assert.equal(kind('https://abc.supabase.co/functions/v1/admin-users'), 'bypass');
  assert.equal(kind('https://abc.supabase.co/storage/v1/object/public/x'), 'bypass');
  assert.equal(kind('https://abc.supabase.co/realtime/v1/websocket'), 'bypass');
  assert.equal(kind('https://saunotus.fi/auth/v1/user'), 'bypass');
  assert.equal(kind('https://saunotus.fi/rest/v1/rpc/x'), 'bypass');
  assert.equal(kind('https://saunotus.fi/functions/v1/receipt-pdf'), 'bypass');
  assert.equal(kind('https://saunotus.fi/varaa/', { mode: 'navigate', headers: { accept: 'text/html' } }), 'bypass');
  assert.equal(kind('https://saunotus.fi/', { mode: 'navigate', headers: { accept: 'text/html' } }), 'bypass');
  assert.equal(kind('https://saunotus.fi/img/favicon.svg'), 'bypass');
  assert.equal(kind('https://saunotus.fi/hallinta/?code=pkce', { mode: 'navigate', headers: { accept: 'text/html' } }), 'bypass');
  assert.equal(kind('https://saunotus.fi/hallinta/?access_token=secret', { mode: 'navigate' }), 'bypass');
  assert.equal(kind('https://saunotus.fi/hallinta/admin.js?v=abc', { headers: { authorization: 'Bearer jwt' } }), 'bypass');
  assert.equal(kind('https://saunotus.fi/hallinta/', { mode: 'navigate', headers: { accept: 'text/html' } }), 'navigate');
  assert.equal(kind('https://saunotus.fi/hallinta/index.html', { destination: 'document' }), 'navigate');
  assert.equal(kind('https://saunotus.fi/hallinta/admin.js?v=abc'), 'static');
  assert.equal(kind('https://saunotus.fi/hallinta/admin.css?v=abc'), 'static');
  assert.equal(kind('https://saunotus.fi/hallinta/logo-haalea.svg'), 'bypass');
  assert.equal(kind('https://saunotus.fi/hallinta/config.js?v=abc'), 'static');

  sandbox.self.location = new URL('https://joonasvaarala.github.io/saunotus-uusi/hallinta/sw.js');
  sandbox.self.registration.scope = 'https://joonasvaarala.github.io/saunotus-uusi/hallinta/';
  const gh = 'https://joonasvaarala.github.io';
  assert.equal(kind(gh + '/saunotus-uusi/varaa/', { mode: 'navigate', headers: { accept: 'text/html' } }), 'bypass');
  assert.equal(kind(gh + '/saunotus-uusi/', { mode: 'navigate', headers: { accept: 'text/html' } }), 'bypass');
  assert.equal(kind(gh + '/', { mode: 'navigate' }), 'bypass');
  assert.equal(kind(gh + '/saunotus-uusi/hallinta/', { mode: 'navigate', headers: { accept: 'text/html' } }), 'navigate');
  assert.equal(kind(gh + '/saunotus-uusi/hallinta/views/day.js?v=abc'), 'static');
  assert.equal(kind('https://abc.supabase.co/functions/v1/admin-users', { method: 'POST' }), 'bypass');

  const responded = async (request) => {
    let job = null;
    listeners.fetch[0]({ request, respondWith(p) { job = p; } });
    if (job) await job.catch(() => {});
    return job ? 1 : 0;
  };
  sandbox.self.location = new URL(prod + 'sw.js');
  sandbox.self.registration.scope = prod;
  assert.equal(await responded(req('https://abc.supabase.co/rest/v1/rpc/x', { method: 'POST' })), 0);
  assert.equal(await responded(req('https://abc.supabase.co/auth/v1/token?grant_type=password')), 0);
  assert.equal(await responded(req('https://saunotus.fi/varaa/index.html', { mode: 'navigate', headers: { accept: 'text/html' } })), 0);
  assert.equal(await responded(req(prod, { mode: 'navigate', headers: { accept: 'text/html' } })), 1);

  const calls = [];
  sandbox.fetch = async (url, init) => { calls.push({ url, init }); return new Response('<html>hallinta</html>', { status: 200, headers: { 'content-type': 'text/html' } }); };
  let opened = false;
  sandbox.caches.open = async () => { opened = true; return { match: async () => null, put: async () => { throw new Error('html välimuistiin'); } }; };
  const page = await api.networkDocument(req(prod));
  assert.equal(await page.text(), '<html>hallinta</html>');
  assert.equal(opened, false);
  assert.equal(calls[0].url, prod);
  assert.doesNotMatch(calls[0].url, /access_token|code=/);
  assert.equal(calls[0].init.cache, 'no-store');
  assert.equal(calls[0].init.redirect, 'follow');

  sandbox.fetch = async () => { throw new Error('offline'); };
  sandbox.caches.open = async () => ({ match: async (u) => (u === './offline.html' ? new Response('Ei verkkoyhteyttä') : null) });
  const off = await api.networkDocument(req(prod, { mode: 'navigate' }));
  assert.equal(await off.text(), 'Ei verkkoyhteyttä');

  sandbox.fetch = async () => new Response('missing', { status: 404, headers: { 'content-type': 'text/html' } });
  const missing = await api.networkDocument(req(prod));
  assert.equal(missing.status, 404);

  const puts = [];
  sandbox.caches.open = async () => ({ match: async () => undefined, put: async (r) => { puts.push(r.url || r); } });
  const jsReq = req(prod + 'admin.js?v=1');
  sandbox.fetch = async () => ({ status: 200, type: 'basic', headers: { get: (k) => (k === 'content-type' ? 'application/json' : null) }, clone() { return this; } });
  await api.cacheFirst(jsReq);
  sandbox.fetch = async () => ({ status: 200, type: 'basic', headers: { get: (k) => (k === 'content-type' ? 'text/javascript' : k === 'set-cookie' ? 'a=b' : null) }, clone() { return this; } });
  await api.cacheFirst(jsReq);
  sandbox.fetch = async () => ({ status: 200, type: 'basic', headers: { get: (k) => (k === 'content-type' ? 'text/javascript' : k === 'cache-control' ? 'private, no-store' : null) }, clone() { return this; } });
  await api.cacheFirst(jsReq);
  sandbox.fetch = async () => ({ status: 200, type: 'basic', headers: { get: (k) => (k === 'content-type' ? 'text/html' : null) }, clone() { return this; } });
  await api.cacheFirst(jsReq);
  sandbox.fetch = async () => ({ status: 200, type: 'cors', headers: { get: () => 'text/javascript' }, clone() { return this; } });
  await api.cacheFirst(jsReq);
  assert.equal(puts.length, 0);
  sandbox.fetch = async () => ({ status: 200, type: 'basic', headers: { get: (k) => (k === 'content-type' ? 'text/javascript' : null) }, clone() { return this; } });
  await api.cacheFirst(jsReq);
  assert.deepEqual(puts, [prod + 'admin.js?v=1']);

  const precache = [...api.PRECACHE];
  assert.deepEqual(precache, ['./offline.html', './icon-192.png', './icon-512.png', './icon-maskable-512.png', './apple-touch-icon.png']);
  assert.equal(precache.some((u) => /index|admin\.js|sb\.js|config|supabase/.test(u)), false);
  const added = [];
  sandbox.caches.open = async () => ({ addAll: async (urls) => added.push(...urls) });
  let installing;
  listeners.install[0]({ waitUntil(p) { installing = p; } });
  await installing;
  assert.deepEqual(added, precache);
  assert.equal(sandbox.self.skipped, 1);

  const deleted = [];
  sandbox.caches.keys = async () => ['hallinta-old', api.CACHE, 'varaa-v1', 'pages'];
  sandbox.caches.delete = async (key) => { deleted.push(key); return true; };
  const act = [];
  listeners.activate[0]({ waitUntil(p) { act.push(p); } });
  await Promise.all(act);
  assert.deepEqual(deleted, ['hallinta-old']);
  assert.equal(sandbox.self.claimed, true);

  sandbox.self.skipped = 0;
  listeners.message[0]({ data: { type: 'OTHER' } });
  listeners.message[0]({ data: { type: 'SKIP_WAITING' } });
  assert.equal(sandbox.self.skipped, 1);

  const navFn = swSrc.slice(swSrc.indexOf('async function networkDocument'), swSrc.indexOf('async function cacheFirst'));
  assert.doesNotMatch(navFn, /cache\.put/);
  assert.match(read('booking/admin/offline.html'), /Ei verkkoyhteyttä/);
  assert.match(read('booking/admin/offline.html'), /lang="fi"/);
  assert.match(read('booking/admin/offline.html'), /noindex/);
});

test('service worker: version.json ohitetaan eikä vanhaa moduulia anneta uudella tunnuksella', async () => {
  const prod = 'https://saunotus.fi/hallinta/';
  const { sandbox, listeners, api } = loadSw(prod);
  const kind = (url, opt) => api.classify(req(url, opt));
  assert.equal(kind(prod + 'version.json'), 'bypass');
  assert.equal(kind(prod + 'version.json?ts=1'), 'bypass');
  assert.equal(kind(prod + 'version.json?v=abc'), 'bypass');
  assert.equal(kind(prod + 'admin.js?v=abc'), 'static');
  assert.equal(api.sameCachedAsset(prod + 'views/talous.js?v=new', prod + 'views/talous.js?v=old'), false);
  assert.equal(api.sameCachedAsset(prod + 'views/talous.js?v=new', prod + 'views/talous.js?v=new'), true);
  assert.equal(api.sameCachedAsset(prod + 'views/talous.js?v=new', prod + 'views/day.js?v=new'), false);
  assert.equal(api.sameCachedAsset(prod + 'admin.js?v=new', ''), true);
  assert.equal(api.authClientUrl(prod + '#access_token=secret&type=invite'), true);
  assert.equal(api.authClientUrl(prod + '?code=pkce'), true);
  assert.equal(api.authClientUrl(prod + '#/talous'), false);
  assert.equal(api.PRECACHE.includes('./version.json'), false);

  let matchOpts = null;
  const cached = { url: prod + 'views/talous.js?v=old', from: 'cache' };
  const network = { status: 200, type: 'basic', from: 'net', headers: { get: (k) => (k === 'content-type' ? 'text/javascript' : null) }, clone() { return this; } };
  const deleted = [];
  let fetches = 0;
  sandbox.fetch = async () => { fetches++; return network; };
  sandbox.caches.open = async () => ({
    match: async (_r, opts) => { matchOpts = opts; return cached; },
    delete: async () => { deleted.push('gone'); },
    put: async () => { throw new Error('eri tunnusta ei saa tallentaa osumana'); },
  });
  const mixed = await api.cacheFirst(req(prod + 'views/talous.js?v=new'));
  assert.equal(mixed, network);
  assert.equal(fetches, 1);
  assert.deepEqual(deleted, ['gone']);
  assert.equal(matchOpts.ignoreSearch, false);

  fetches = 0;
  sandbox.caches.open = async () => ({
    match: async () => ({ url: prod + 'views/talous.js?v=new', from: 'cache' }),
    put: async () => { throw new Error('osuma ei lähde verkkoon'); },
  });
  const hit = await api.cacheFirst(req(prod + 'views/talous.js?v=new'));
  assert.equal(hit.from, 'cache');
  assert.equal(fetches, 0);

  const puts = [];
  sandbox.fetch = async (url, init) => { fetches++; return { url, init, status: 200, type: 'basic', headers: { get: () => 'application/json' }, clone() { return this; } }; };
  sandbox.caches.open = async () => ({ match: async () => undefined, put: async () => { puts.push('put'); } });
  fetches = 0;
  const ver = await api.cacheFirst(req(prod + 'version.json?ts=9'));
  assert.equal(ver.init.cache, 'no-store');
  assert.equal(fetches, 1);
  assert.deepEqual(puts, []);

  const navigated = [];
  sandbox.self.UPDATE_ACK_MS = 0;
  sandbox.self.clients.matchAll = async () => [{
    id: 'old',
    url: prod + '#/kassa',
    postMessage() {},
    navigate: async (url) => { navigated.push(url); },
  }];
  sandbox.caches.keys = async () => ['hallinta-old', api.CACHE];
  const removed = [];
  sandbox.caches.delete = async (key) => { removed.push(key); return true; };
  let act;
  listeners.activate[0]({ waitUntil(p) { act = p; } });
  await act;
  assert.deepEqual(navigated, []);
  await new Promise((r) => setTimeout(r, 0));
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(navigated, [prod + '#/kassa']);
  assert.deepEqual(removed, ['hallinta-old']);
  assert.equal(sandbox.self.claimed, true);

  const { sandbox: ackBox, listeners: ackListeners } = loadSw(prod);
  const ackNav = [];
  ackBox.self.UPDATE_ACK_MS = 30_000;
  ackBox.self.clients.matchAll = async () => [{
    id: 'held',
    url: prod + '#/',
    postMessage(data) {
      if (data?.type === 'HALLINTA_UPDATED') {
        for (const fn of [...ackListeners.message]) fn({ source: { id: 'held' }, data: { type: 'HALLINTA_ACK', hold: true } });
      }
    },
    navigate: async () => { ackNav.push('nav'); },
  }];
  ackBox.caches.keys = async () => [];
  let ackAct;
  ackListeners.activate[0]({ waitUntil(p) { ackAct = p; } });
  await ackAct;
  await new Promise((r) => setTimeout(r, 0));
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(ackNav, []);

  const { sandbox: authBox, listeners: authListeners } = loadSw(prod);
  const authNav = [];
  authBox.self.UPDATE_ACK_MS = 0;
  authBox.self.clients.matchAll = async () => [{
    id: 'invite',
    url: prod + '#access_token=secret&type=invite',
    postMessage() {},
    navigate: async () => { authNav.push('nav'); },
  }];
  authBox.caches.keys = async () => [];
  let authAct;
  authListeners.activate[0]({ waitUntil(p) { authAct = p; } });
  await authAct;
  await new Promise((r) => setTimeout(r, 0));
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(authNav, []);
});

function callArg(src, fnName) {
  const marker = fnName + '(';
  const i = src.indexOf(marker);
  assert.notEqual(i, -1, fnName);
  let depth = 0;
  for (let j = i + fnName.length; j < src.length; j++) {
    if (src[j] === '(') depth++;
    else if (src[j] === ')') {
      depth--;
      if (depth === 0) return src.slice(i + marker.length, j);
    }
  }
  assert.fail('sulkematon ' + fnName);
}

test('aktivointi ei odota notifyOpenClientsia waitUntilissa', async () => {
  const prod = 'https://saunotus.fi/hallinta/';
  const activateAt = swSrc.indexOf("self.addEventListener('activate'");
  const activate = swSrc.slice(activateAt, swSrc.indexOf("self.addEventListener('fetch'", activateAt));
  const waited = callArg(activate, 'event.waitUntil');
  assert.equal(waited.includes('notifyOpenClients'), false);
  assert.doesNotMatch(waited, /navigate\s*\(/);
  assert.doesNotMatch(activate, /await\s+notifyOpenClients\s*\(/);
  assert.match(activate, /event\.waitUntil\(ready\)/);
  assert.match(activate, /ready\.then\(\(\) => notifyOpenClients\(\)\)/);

  const { sandbox, listeners } = loadSw(prod);
  const navigated = [];
  sandbox.self.UPDATE_ACK_MS = 0;
  sandbox.self.clients.matchAll = async () => [{
    id: 'old',
    url: prod + '#/talous',
    postMessage() {},
    navigate: async (url) => { navigated.push(url); },
  }];
  sandbox.caches.keys = async () => ['hallinta-stale', sandbox.self.hallintaSw.CACHE];
  const deleted = [];
  sandbox.caches.delete = async (key) => { deleted.push(key); return true; };
  let act;
  listeners.activate[0]({ waitUntil(p) { act = p; } });
  await act;
  assert.deepEqual(navigated, []);
  assert.equal(sandbox.self.claimed, true);
  assert.deepEqual(deleted, ['hallinta-stale']);
  await new Promise((r) => setTimeout(r, 0));
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(navigated, [prod + '#/talous']);
});

test('build kopioi PWA-tiedostot ja versioi välimuistin; kauppa ja julkinen sivusto eivät rekisteröi workeria', () => {
  const build = read('scripts/build-pages.mjs');
  for (const f of ['manifest.json', 'sw.js', 'offline.html', 'pwa.js', 'icon-192.png', 'icon-512.png', 'icon-maskable-512.png', 'apple-touch-icon.png']) {
    assert.match(build, new RegExp("'" + f.replace('.', '\\.') + "'"));
  }
  assert.match(build, /const SW_VER = '\$\{VER\}';/);
  assert.match(build, /hallinta-' \+ VER\.slice\(3\)/);
  assert.match(build, /version\.json/);
  assert.match(build, /assetVer: VER/);
  assert.match(build, /manifest\.scope !== '\.\/'/);
  assert.match(read('.github/workflows/pages.yml'), /node --test booking\/tests\/hallinta-pwa\.test\.mjs/);
  assert.doesNotMatch(read('src/render.mjs'), /serviceWorker|manifest\.json/);
  assert.doesNotMatch(read('booking/shop/build.mjs'), /serviceWorker\.register/);
  const regs = ['booking/admin/pwa.js'];
  for (const file of ['booking/admin/admin.js', 'booking/admin/sw.js', 'booking/shop/build.mjs', 'src/render.mjs']) {
    assert.equal(/serviceWorker\.register/.test(read(file)), regs.includes(file), file);
  }
});
