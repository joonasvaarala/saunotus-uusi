// Hallinnan asennus: oma kuvake ja erillinen ikkuna. Service worker rekisteröidään vain /hallinta/-polussa,
// suhteellisella scopella, jotta sama build toimii osoitteessa saunotus.fi/hallinta/ ja testisivun /saunotus-uusi/hallinta/.
// Kutsulinkki (Supabase redirect → /hallinta/#access_token) osuu samaan scopeen kuin manifestin start_url.

// scripts/build-pages.mjs korvaa tämän (?v=…). Tyhjä kehityksessä. Kysely saa sw.js-pyynnön näyttämään versioidulta,
// ja tavumuutos julkaisee uuden workerin.
import { applyServiceWorkerUpdate, pageHasUnsavedWork, showVersionBanner, getVersionController } from './version-check.js';

const SW_VER = '';
const DISMISS_KEY = 'hallinta.pwa.installDismissed';

export const PWA_TEXT = {
  installAndroid: 'Hallinta voidaan lisätä aloitusnäyttöön.',
  installButton: 'Asenna sovellukseksi',
  installIos: 'Asenna sovellukseksi: Jaa → Lisää Koti-valikkoon.',
  dismiss: 'Sulje',
  dismissLabel: 'Sulje asennusvihje',
  update: 'Uusi versio on saatavilla.',
  reload: 'Lataa uudelleen',
  region: 'Asenna sovellus',
};

export function isIosDevice(nav = typeof navigator !== 'undefined' ? navigator : {}) {
  const ua = nav.userAgent || '';
  if (/iphone|ipad|ipod/i.test(ua)) return true;
  return nav.platform === 'MacIntel' && (nav.maxTouchPoints || 0) > 1;
}

export function isStandaloneDisplay(nav = typeof navigator !== 'undefined' ? navigator : {}, matchMedia) {
  if (nav.standalone === true) return true;
  const mq = matchMedia || (typeof window !== 'undefined' && window.matchMedia ? (q) => window.matchMedia(q) : null);
  if (!mq) return false;
  try {
    return !!(mq('(display-mode: standalone)')?.matches || mq('(display-mode: fullscreen)')?.matches);
  } catch { return false; }
}

export function shouldRegisterSw(pathname) {
  return /\/hallinta\/(?:index\.html)?$/.test(pathname) || /\/hallinta$/.test(pathname);
}

export function installHintKind({ standalone, dismissed, ios, canPrompt }) {
  if (standalone || dismissed) return null;
  if (canPrompt) return 'android';
  if (ios) return 'ios';
  return null;
}

export function hallintaSwScope(moduleUrl) {
  return new URL('./', moduleUrl).href;
}

export function hallintaSwScript(moduleUrl, ver = SW_VER) {
  return new URL(`sw.js${ver || ''}`, moduleUrl).href;
}

let deferredPrompt = null;

function hintDismissed() {
  try { return localStorage.getItem(DISMISS_KEY) === '1'; } catch { return false; }
}

function dismissHint() {
  try { localStorage.setItem(DISMISS_KEY, '1'); } catch { /* yksityinen tila */ }
  document.getElementById('pwa-hint')?.remove();
}

function noticeRoot() {
  let root = document.getElementById('pwa-notices');
  if (!root) {
    root = document.createElement('div');
    root.id = 'pwa-notices';
    root.className = 'pwa-notices';
    document.body.append(root);
  }
  return root;
}

function renderHint(kind) {
  if (!kind || document.getElementById('pwa-hint')) return;
  const bar = document.createElement('div');
  bar.id = 'pwa-hint';
  bar.className = 'pwa-hint';
  bar.setAttribute('role', 'region');
  bar.setAttribute('aria-label', PWA_TEXT.region);
  const p = document.createElement('p');
  if (kind === 'android') {
    p.textContent = PWA_TEXT.installAndroid;
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'btn primary';
    btn.id = 'pwa-install';
    btn.textContent = PWA_TEXT.installButton;
    btn.addEventListener('click', async () => {
      const prompt = deferredPrompt;
      deferredPrompt = null;
      if (!prompt) return;
      prompt.prompt();
      try { await prompt.userChoice; } catch { /* käyttäjä perui */ }
      dismissHint();
    });
    bar.append(p, btn);
  } else {
    p.textContent = PWA_TEXT.installIos;
    bar.append(p);
  }
  const close = document.createElement('button');
  close.type = 'button';
  close.className = 'btn ghost';
  close.id = 'pwa-dismiss';
  close.setAttribute('aria-label', PWA_TEXT.dismissLabel);
  close.textContent = PWA_TEXT.dismiss;
  close.addEventListener('click', dismissHint);
  bar.append(close);
  noticeRoot().append(bar);
}

function showUpdate(reg) {
  if (!navigator.serviceWorker.controller || document.getElementById('pwa-update')) return;
  const bar = document.createElement('div');
  bar.id = 'pwa-update';
  bar.className = 'pwa-update';
  bar.setAttribute('role', 'status');
  const p = document.createElement('p');
  p.textContent = PWA_TEXT.update;
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'btn primary';
  btn.textContent = PWA_TEXT.reload;
  btn.addEventListener('click', () => {
    const waiting = reg.waiting;
    if (waiting) waiting.postMessage({ type: 'SKIP_WAITING' });
    const ctrl = getVersionController();
    if (ctrl) ctrl.reload();
    else location.reload();
  });
  bar.append(p, btn);
  noticeRoot().prepend(bar);
}

export function startHallintaPwa() {
  if (typeof window === 'undefined' || typeof document === 'undefined') return;
  const standalone = isStandaloneDisplay();
  window.addEventListener('beforeinstallprompt', (event) => {
    if (standalone || hintDismissed()) return;
    event.preventDefault();
    deferredPrompt = event;
    renderHint('android');
  });
  window.addEventListener('appinstalled', () => { deferredPrompt = null; dismissHint(); });
  if (installHintKind({ standalone, dismissed: hintDismissed(), ios: isIosDevice(), canPrompt: false }) === 'ios') renderHint('ios');
  if (!('serviceWorker' in navigator) || !shouldRegisterSw(location.pathname)) return;
  const base = import.meta.url;
  // controllerchange kerran per päivitys: applyServiceWorkerUpdate ohittaa saman päivityksen toisen tapahtuman
  // ja juuri tehdyn uudelleenlatauksen. Ensimmäinen asennus (ei aiempaa controlleria) ei lataa sivua uudelleen.
  const hadController = !!navigator.serviceWorker.controller;
  const ack = (data) => {
    try { navigator.serviceWorker.controller?.postMessage({ type: 'HALLINTA_ACK', ...data }); } catch { /* worker ei ole vielä ohjaksissa */ }
  };
  const onSwUpdate = () => applyServiceWorkerUpdate({
    hadController,
    unsaved: () => pageHasUnsavedWork(document, location.hash),
    ack,
    showBanner: () => showVersionBanner(document, { onUpdate: () => getVersionController()?.reload() }),
  });
  navigator.serviceWorker.addEventListener('controllerchange', onSwUpdate);
  navigator.serviceWorker.addEventListener('message', (event) => {
    if (event.data && event.data.type === 'HALLINTA_UPDATED') onSwUpdate();
  });
  try { navigator.serviceWorker.controller?.postMessage({ type: 'HALLINTA_ACK', hold: false, fresh: true }); } catch { /* ei controlleria */ }
  navigator.serviceWorker.register(hallintaSwScript(base), { scope: hallintaSwScope(base) }).then((reg) => {
    const watch = () => { if (reg.waiting) showUpdate(reg); };
    watch();
    reg.addEventListener('updatefound', () => {
      const worker = reg.installing;
      worker?.addEventListener('statechange', () => { if (worker.state === 'installed') watch(); });
    });
    reg.update().catch(() => {});
  }).catch(() => {});
}
