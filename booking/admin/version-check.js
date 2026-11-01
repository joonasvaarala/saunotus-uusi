// Julkaisun tunnistus. scripts/build-pages.mjs kirjoittaa dist/hallinta/version.jsoniin saman ASSET_VER-tunnuksen
// kuin admin.js:ään. Sivu hakee tiedoston verkosta (cache: 'no-store', aikaleima kyselyssä). sw.js ei välimuistita sitä.
// Kehityksessä ASSET_VER on tyhjä: tarkistusta ei tehdä, jotta paikallinen työ ei lataudu uudelleen.
//
// Jos tunnus vaihtuu eikä tallentamatonta lomaketta ole kesken, sivu ladataan uudelleen. Lomakkeen keskellä näytetään
// palkki ja uudelleenlataus tehdään seuraavassa siirtymässä. Kun näkymämoduuli epäonnistuu kahdesti, vaihto ladataan
// heti, koska virhenäkymä johtuu yleensä vanhan muistissa olevan version ja uusien tiedostojen sekoituksesta.

export const VERSION_FILE = 'version.json';
export const ROUTE_CHECK_INTERVAL_MS = 3 * 60 * 1000;
export const VERSION_FETCH_TIMEOUT_MS = 2500;
export const RELOAD_SUPPRESS_MS = 10000;
export const SW_EVENT_DEDUPE_MS = 1500;
const RELOAD_KEY = 'hallinta.versionReload';

export const VERSION_TEXT = {
  fi: { banner: 'Uusi versio saatavilla – päivitä', button: 'Päivitä' },
  en: { banner: 'A new version is available – update', button: 'Update' },
};

export function versionText(lang) {
  return lang === 'en' ? VERSION_TEXT.en : VERSION_TEXT.fi;
}

export function versionRequest(now = Date.now()) {
  return {
    url: `./${VERSION_FILE}?ts=${now}`,
    init: { cache: 'no-store', credentials: 'same-origin', headers: { Accept: 'application/json' } },
  };
}

/** '?v=abc', 'v=abc' ja pelkkä 'abc' samaan vertailtavaan tunnukseen. Tyhjä tai kelvoton → ''. */
export function normalizeAssetVer(value) {
  if (value == null) return '';
  const raw = String(value).trim();
  if (!raw) return '';
  const q = raw.replace(/^[?&]/, '');
  if (q.includes('=')) {
    try {
      const v = new URLSearchParams(q).get('v');
      if (v) return v;
    } catch { /* kelvoton kysely */ }
    return '';
  }
  return /^[A-Za-z0-9._~:-]+$/.test(q) ? q : '';
}

export function parseVersionPayload(body) {
  if (body == null || body === '') return '';
  let data = body;
  if (typeof body === 'string') {
    try { data = JSON.parse(body); } catch { return ''; }
  }
  if (!data || typeof data !== 'object') return '';
  return normalizeAssetVer(data.assetVer ?? data.version ?? '');
}

export function versionsDiffer(running, remote) {
  const a = normalizeAssetVer(running);
  const b = normalizeAssetVer(remote);
  if (!a || !b) return false;
  return a !== b;
}

export function shouldFetchVersion({ reason, now, lastCheckedAt = null, intervalMs = ROUTE_CHECK_INTERVAL_MS, running } = {}) {
  if (!normalizeAssetVer(running)) return false;
  if (reason === 'focus' || reason === 'visibility' || reason === 'load-fail') return true;
  if (reason === 'route') return lastCheckedAt == null || (now - lastCheckedAt) >= intervalMs;
  return false;
}

export function reasonForVisibility(state) {
  return state === 'visible' ? 'visibility' : null;
}

/**
 * @returns {'reload'|'banner'|'none'}
 * load-fail pakottaa uudelleenlatauksen, jos tunnus vaihtui: näkymä on jo rikki.
 * Muuten tallentamaton lomake → palkki, muuten heti uudelleen.
 */
export function decideUpdate({ running, remote, unsaved = false, reason = 'focus' } = {}) {
  if (!versionsDiffer(running, remote)) return 'none';
  if (reason === 'load-fail') return 'reload';
  if (unsaved) return 'banner';
  return 'reload';
}

const AUTH_RE = /(?:^|[?#&])(?:access_token|refresh_token|provider_token|id_token|code|token)=/;
export function hasAuthFragment(hash = '') {
  return AUTH_RE.test(String(hash || ''));
}

const EDITABLE_SELECTOR = 'input, textarea, select, [contenteditable="true"]';
const IGNORE_SELECTOR = '#pwa-notices, #quick-search, form[role="search"], .tl-toolbar';
const FORM_SELECTOR = 'form, dialog, [role="dialog"], [contenteditable="true"]';

export function editableField(target) {
  if (!target || typeof target.closest !== 'function') return null;
  try {
    if (typeof target.matches === 'function' && target.matches(EDITABLE_SELECTOR)) return target;
  } catch { /* kelvoton valitsin */ }
  try { return target.closest(EDITABLE_SELECTOR) || null; } catch { return null; }
}

/** Käyttäjän muokkaus lomakkeessa, dialogissa tai muokattavassa kentässä. Haku- ja suodatinkentät eivät ole keskeneräinen lomake. */
export function eventMarksUnsaved(target) {
  const el = editableField(target);
  if (!el || el.disabled || el.readOnly) return false;
  const type = String(el.type || '').toLowerCase();
  if (type === 'hidden' || type === 'button' || type === 'submit' || type === 'reset' || type === 'search') return false;
  try { if (typeof el.closest === 'function' && el.closest(IGNORE_SELECTOR)) return false; } catch { /* ei lähintä */ }
  try { return !!(typeof el.closest === 'function' && el.closest(FORM_SELECTOR)); } catch { return false; }
}

export function markUnsavedTarget(target) {
  if (!eventMarksUnsaved(target)) return false;
  const el = editableField(target);
  if (typeof el.setAttribute === 'function') el.setAttribute('data-user-edited', '1');
  el.userEdited = true;
  return true;
}

export function isUnsavedForm(doc) {
  if (!doc || typeof doc.querySelectorAll !== 'function') return false;
  let nodes = [];
  try { nodes = doc.querySelectorAll('[data-user-edited="1"], [data-unsaved="1"]'); } catch { return false; }
  for (const el of nodes) {
    if (el && el.isConnected === false) continue;
    try { if (typeof el.closest === 'function' && el.closest(IGNORE_SELECTOR)) continue; } catch { /* pidä kenttä */ }
    return true;
  }
  return false;
}

export function passwordSetupOpen(doc) {
  const el = doc?.getElementById?.('setpw-screen');
  return !!el && el.hidden === false;
}

export function pageHasUnsavedWork(doc, hash = '') {
  return isUnsavedForm(doc) || passwordSetupOpen(doc) || hasAuthFragment(hash);
}

export async function fetchDeployedVersion(fetchImpl = globalThis.fetch, now = Date.now()) {
  const req = versionRequest(now);
  const res = await fetchImpl(req.url, req.init);
  if (!res || !res.ok) return '';
  const text = typeof res.text === 'function' ? await res.text() : '';
  return parseVersionPayload(text);
}

function withTimeout(promise, ms) {
  return new Promise((resolve) => {
    let done = false;
    const timer = setTimeout(() => { if (!done) { done = true; resolve(''); } }, ms);
    Promise.resolve(promise).then(
      (value) => { if (!done) { done = true; clearTimeout(timer); resolve(value); } },
      () => { if (!done) { done = true; clearTimeout(timer); resolve(''); } },
    );
  });
}

let storageOverride = null;
function store() {
  if (storageOverride) return storageOverride;
  try { if (typeof sessionStorage !== 'undefined') return sessionStorage; } catch { /* yksityinen tila */ }
  return null;
}
export function setVersionStorage(storage) { storageOverride = storage; }

export function noteReload(now = Date.now()) {
  const s = store();
  if (!s) return;
  try { s.setItem(RELOAD_KEY, String(now)); } catch { /* täysi tallennustila */ }
}

export function recentReload(now = Date.now(), windowMs = RELOAD_SUPPRESS_MS) {
  const s = store();
  if (!s) return false;
  try {
    const t = Number(s.getItem(RELOAD_KEY) || 0);
    return t > 0 && now - t < windowMs;
  } catch { return false; }
}

export function currentUiLang() {
  try {
    const l = localStorage.getItem('booking.admin.lang');
    return l === 'en' ? 'en' : 'fi';
  } catch { return 'fi'; }
}

function noticeRoot(doc) {
  let root = doc.getElementById('pwa-notices');
  if (!root) {
    root = doc.createElement('div');
    root.id = 'pwa-notices';
    root.className = 'pwa-notices';
    doc.body?.append(root);
  }
  return root;
}

/** Pieni ei-estävä palkki. Toinen kutsu ei tee toista palkkia. */
export function showVersionBanner(doc, { lang = 'fi', onUpdate } = {}) {
  if (!doc || typeof doc.getElementById !== 'function' || doc.getElementById('version-banner')) return false;
  const text = versionText(lang);
  const bar = doc.createElement('div');
  bar.id = 'version-banner';
  bar.className = 'pwa-update version-banner';
  bar.setAttribute('role', 'status');
  const p = doc.createElement('p');
  p.textContent = text.banner;
  const btn = doc.createElement('button');
  btn.type = 'button';
  btn.className = 'btn primary';
  btn.textContent = text.button;
  btn.addEventListener('click', () => { onUpdate?.(); });
  bar.append(p, btn);
  noticeRoot(doc).prepend(bar);
  return true;
}

const state = {
  armed: false,
  reloading: false,
  handledUntil: 0,
  lastCheckedAt: null,
  flight: null,
  flightReason: null,
};
let controller = null;

export function resetVersionState() {
  state.armed = false;
  state.reloading = false;
  state.handledUntil = 0;
  state.lastCheckedAt = null;
  state.flight = null;
  state.flightReason = null;
  controller = null;
  storageOverride = null;
}

export function getVersionController() { return controller; }

export function createVersionController({
  running,
  fetchRemote,
  unsaved = () => false,
  now = () => Date.now(),
  onReload = () => {},
  onBanner = () => {},
  intervalMs = ROUTE_CHECK_INTERVAL_MS,
  timeoutMs = VERSION_FETCH_TIMEOUT_MS,
  install = true,
} = {}) {
  async function check(reason) {
    if (state.reloading) return 'reload';
    const t = now();
    if (!shouldFetchVersion({ reason, now: t, lastCheckedAt: state.lastCheckedAt, intervalMs, running })) return 'skipped';
    if (state.flight) {
      if (reason === 'load-fail') state.flightReason = 'load-fail';
      return state.flight;
    }
    state.flightReason = reason;
    state.flight = (async () => {
      let remote = '';
      try { remote = await withTimeout(Promise.resolve().then(() => fetchRemote()), timeoutMs); } catch { remote = ''; }
      if (remote == null) remote = '';
      state.lastCheckedAt = now();
      const action = decideUpdate({ running, remote, unsaved: !!unsaved(), reason: state.flightReason });
      if (action === 'reload') reload();
      else if (action === 'banner') { state.armed = true; onBanner(); }
      return action;
    })().finally(() => { state.flight = null; state.flightReason = null; });
    return state.flight;
  }

  function reload() {
    if (state.reloading) return false;
    state.reloading = true;
    noteReload(now());
    onReload();
    return true;
  }

  function onNavigate() {
    if (!state.armed) return false;
    if (state.reloading) return true;
    reload();
    return true;
  }

  function arm() { state.armed = true; }

  const api = {
    check, onNavigate, reload, arm,
    get reloading() { return state.reloading; },
    get armed() { return state.armed; },
  };
  if (install) controller = api;
  return api;
}

/**
 * Uusi service worker otti ohjat (controllerchange tai HALLINTA_UPDATED).
 * Ensimmäinen asennus ei lataa sivua uudelleen. Saman päivityksen toinen tapahtuma ohitetaan.
 * Juuri tehty uudelleenlataus ei tee toista. Tallentamaton työ → palkki.
 */
export function planControllerChange({ hadController = false, unsaved = false } = {}) {
  if (!hadController) return { action: 'ack', hold: false };
  if (unsaved) return { action: 'banner', hold: true };
  return { action: 'reload', hold: false };
}

export function applyServiceWorkerUpdate({ hadController = false, unsaved = () => false, ack, showBanner, now = Date.now() } = {}) {
  if (now < state.handledUntil) return 'ignore';
  state.handledUntil = now + SW_EVENT_DEDUPE_MS;
  if (controller?.reloading) return 'ignore';
  if (recentReload(now)) {
    ack?.({ hold: false, fresh: true });
    return 'ignore';
  }
  const plan = planControllerChange({ hadController, unsaved: !!unsaved() });
  if (plan.action === 'ack') {
    ack?.({ hold: false });
    return 'ack';
  }
  if (plan.action === 'banner') {
    controller?.arm();
    showBanner?.();
    ack?.({ hold: true });
    return 'banner';
  }
  ack?.({ hold: false });
  if (controller) controller.reload();
  else {
    state.reloading = true;
    noteReload(now);
  }
  return 'reload';
}

export function startHallintaVersionWatch({
  running,
  document: doc = globalThis.document,
  window: win = globalThis.window,
  fetchImpl = globalThis.fetch,
  now = () => Date.now(),
  unsaved,
  onReload,
} = {}) {
  if (!doc || !win) return null;
  if (controller) return controller;
  const hash = () => win.location?.hash || '';
  const ctrl = createVersionController({
    running,
    now,
    fetchRemote: () => fetchDeployedVersion(fetchImpl, now()),
    unsaved: unsaved || (() => pageHasUnsavedWork(doc, hash())),
    onReload: onReload || (() => { try { win.location.reload(); } catch { /* testi */ } }),
    onBanner: () => showVersionBanner(doc, { lang: currentUiLang(), onUpdate: () => ctrl.reload() }),
  });
  doc.addEventListener('visibilitychange', () => {
    const reason = reasonForVisibility(doc.visibilityState);
    if (reason) void ctrl.check(reason);
  });
  win.addEventListener('focus', () => { void ctrl.check('focus'); });
  const mark = (ev) => { markUnsavedTarget(ev.target); };
  doc.addEventListener('input', mark, true);
  doc.addEventListener('change', mark, true);
  return ctrl;
}
