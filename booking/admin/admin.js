// Hallinnan kuori: kirjautuminen (Supabase Auth), reititys (hash), roolien mukainen valikko. Näkymät ovat tiedostoissa views/*.js.
import { signIn, signOut, getSession, onAuthChange, rpc, select, adoptSessionFromHash, setPassword, setRpcOverride, setMockSession } from './sb.js';
import { h, toast, errMsg, todayHel } from './ui.js';
import { icon } from './icons.js';
import { t as tl } from './talous-i18n.js';
import { createAdminMock } from './options-mock.js';
import { loadFilterTexts } from './filter-texts.js';
import { primeSiteTexts, clearSiteTextsCache } from './site-texts-cache.js';
import { needsManualRoute, parseAdminHash } from './reservation-query.js';
import { posText } from './pos-texts.js';
import { resolveAdminPath, compactIdentity, toggleMobileNav } from './admin-navigation.js';
import { setupQuickSearch } from './quick-search.js';
import { loadNavTexts, navText } from './nav-texts.js';
import { evText } from './events-texts.js';

const $ = (id) => document.getElementById(id);
// Kokeilutila: osoite /hallinta/?mock=1 → keinoistunto + selaimen oma mock-data (options-mock.js). EI verkkokutsuja eikä kirjautumista; mikään ei tallennu. Ilman parametria ennallaan.
const MOCK = new URLSearchParams(location.search).get('mock') === '1';
if (MOCK) {
  const mockRole = new URLSearchParams(location.search).get('role');
  const role = ['admin', 'manager', 'staff'].includes(mockRole) ? mockRole : 'manager';
  const staffPerms = ['blocks.manage', 'bookings.manage', 'customers.manage', 'giftcards.manage', 'payments.manage', 'pos.use', 'reports.daily', 'shifts.view'];
  const mock = createAdminMock({ delay: 60, role, perms: role === 'staff' ? staffPerms : undefined });
  setRpcOverride((fn, args) => mock.rpc(fn, args));
  setMockSession({ access_token: 'mock', refresh_token: 'mock', expires_at: 4102444800, user: { email: 'kokeilu@example.com' } });
  window.__adminMock = mock;
  if (new URLSearchParams(location.search).get('shot') === '1') document.body.classList.add('shot');
}
// perms: roolin oikeudet (booking.role_permissions) palvelimelta; can(oikeus) piilottaa/lukitsee kenttiä. Oikeudet pakotetaan silti tietokannassa.
export const ctx = { role: null, roleLabel: '', name: '', perms: [], can: (p) => ctx.perms.includes(p), refs: null };

// Versiotunnus: scripts/build-pages.mjs korvaa tämän rivin (esim. '?v=ab12cd34ef') ja lisää saman tunnuksen kaikkiin importteihin ja index.html:n
// resursseihin, jolloin selaimen välimuistissa oleva vanha moduuli ei sekoitu uuteen julkaisuun. Kehityksessä tyhjä.
const ASSET_VER = '';
const viewUrl = (name, bust) => `./views/${name}.js${ASSET_VER}${bust ? `${ASSET_VER ? '&' : '?'}r=${Date.now()}` : ''}`;
// Näkymämoduulin lataus: epäonnistunut dynaaminen import jää selaimessa muistiin samalle osoitteelle, joten yksi uusinta tehdään
// cache-bust-parametrilla. Jos sekin epäonnistuu, näytetään selkeä virhe ja "Lataa uudelleen" -painike (ks. route()).
async function loadView(name) {
  try { return await import(viewUrl(name)); } catch (e1) {
    console.warn(`Näkymän ${name} lataus epäonnistui, yritetään uudelleen`, e1);
    try { return await import(viewUrl(name, true)); } catch (e2) { throw Object.assign(new Error(`Näkymän ${name} lataus epäonnistui`), { loadFailed: true, cause: e2 }); }
  }
}
const loadErrorView = () => h('div', { class: 'pad', role: 'alert' },
  h('p', { class: 'err', text: 'Näkymän lataus epäonnistui. Syynä on yleensä hetkellinen verkkovirhe tai selaimen välimuistissa oleva vanha versio. Tarkista yhteys ja lataa sivu uudelleen.' }),
  h('button', { class: 'btn primary', type: 'button', onclick: () => location.reload() }, 'Lataa uudelleen'));

const ROUTES = [
  { path: '', label: 'Päivä', icon: 'day', mod: () => loadView('day') },
  { path: 'tilaukset', label: 'Tilaukset', labelFn: () => navText('ui.admin.nav.orders'), icon: 'list', mod: () => loadView('orders') },
  { path: 'talous', label: 'Talous', labelFn: () => tl('nav'), icon: 'euro', any: ['payments.manage', 'giftcards.manage'], mod: () => loadView('talous') },
  { path: 'pikakassa', label: 'Pikakassa', labelFn: () => posText('nav', 'fi'), icon: 'till', any: ['pos.use'], mod: () => loadView('pos') },
  { path: 'laskut', label: 'Laskut', icon: 'receipt', any: ['invoices.manage'], mod: () => loadView('invoices') },
  { path: 'kalenteri', label: 'Kalenteri', icon: 'calendar', mod: () => loadView('calendar') },
  { path: 'tarkista', label: 'Tarkista', icon: 'check', mod: () => loadView('review') },
  { path: 'uusi', label: 'Uusi varaus', icon: 'plus', mod: () => loadView('newbooking') },
  { path: 'asiakkaat', label: 'Asiakkaat', icon: 'users', mod: () => loadView('customers') },
  { path: 'alennuskoodit', label: 'Alennuskoodit', icon: 'percent', any: ['catalog.edit', 'annual_cards.manage'], mod: () => loadView('discounts') },
  { path: 'hiljaiset-ajat', label: 'Hiljaiset ajat', icon: 'leaf', any: ['catalog.edit', 'settings.edit'], mod: () => loadView('quiet') },   // booking_162
  { path: 'tuotteet', label: 'Tuotteet', icon: 'tag', mod: () => loadView('products') },
  { path: 'tapahtumat', label: 'Tapahtumat', labelFn: () => evText('nav'), icon: 'leaf', mod: () => loadView('events') },   // booking_158: tapahtumat ja koulutukset (henkilökunta lukee, catalog.edit muokkaa)
  { path: 'viestit', label: 'Viestit', icon: 'mail', any: ['messages.edit'], mod: () => loadView('messages') },
  { path: 'resurssit', label: 'Resurssit', icon: 'cabin', mod: () => loadView('resources') },
  { path: 'sulkukalenterit', label: 'Kalenterisulut', icon: 'lock', any: ['blocks.manage'], mod: () => loadView('closures') },
  { path: 'asetukset', label: 'Asetukset', icon: 'sliders', any: ['settings.edit', 'pos.use'], mod: () => loadView('settings') },
  { path: 'kayttajat', label: 'Käyttäjät', icon: 'key', any: ['staff.manage'], mod: () => loadView('users') },
];

// Viitedata (tuotteet, maksutavat, resurssit), ladataan kerran istuntoa kohti
export async function refs(force = false) {
  if (ctx.refs && !force) return ctx.refs;
  const [products, methods, resources] = await Promise.all([rpc('admin_list_products'), select('payment_methods', { select: 'code,label,is_manual,active', order: 'sort_order.asc' }), select('resources', { select: '*', order: 'id.asc' })]);
  ctx.refs = { products, methods, resources, productById: new Map(products.map((p) => [p.id, p])) };
  return ctx.refs;
}

const allowed = (r) => !r.any || r.any.some((p) => ctx.can(p));
function drawNav(current) {
  $('nav').replaceChildren(...ROUTES.filter(allowed).map((r) => h('a', { href: `#/${r.path}`, 'aria-label': r.labelFn ? r.labelFn() : r.label, title: r.labelFn ? r.labelFn() : r.label, 'aria-current': r.path === current ? 'page' : null }, h('span', { class: 'ico', 'aria-hidden': 'true' }, icon(r.icon)), h('span', { class: 'lbl', text: r.labelFn ? r.labelFn() : r.label }))));
  // Pystypalkissa aktiivinen navigaatiolinkki pysyy näkyvillä ilman vaakavieritystä.
  const nav = $('nav'), cur = nav.querySelector('[aria-current]');
  if (cur && !nav.contains(document.activeElement)) cur.scrollIntoView?.({ block: 'nearest' });
}
let dayModule = null;
let lastPath = null;   // toisesta näkymästä Päivään palattaessa päivänippu haetaan aina tuoreena (muutokset muissa näkymissä)
let routeSeq = 0;   // nopea navigointi: vain viimeisin reitti saa piirtää näkymän (vanhentuneet vastaukset hylätään)
async function route() {
  if (!getSession()) return;
  const seq = ++routeSeq;
  const { path, rest, query } = parseAdminHash(location.hash);
  const resolved = resolveAdminPath(path);
  const r = ROUTES.find((x) => x.path === resolved.path && allowed(x)) || ROUTES[0];
  drawNav(r.path);
  const view = $('view');
  view.replaceChildren(h('p', { class: 'muted pad', text: 'Ladataan…' }));
  try {
    const m = await r.mod();
    if (r.path === '') { dayModule = m; if (lastPath !== null && lastPath !== '') m.clearDayBundleCache?.(); }
    lastPath = r.path;
    await refs();
    const out = await m.render({ ctx, refs: ctx.refs, reload: () => { dayModule?.clearDayBundleCache?.(); route(); }, query, rest, legacyReservations: resolved.legacyReservations });
    if (seq !== routeSeq) return;
    view.replaceChildren(...[].concat(out).filter(Boolean));
    document.title = `${r.labelFn ? r.labelFn() : r.label} – hallinta`;
    if (r.path === '') setTimeout(() => m.prefetchAdjacentDay?.(query.get('d') || todayHel()), 0);
  } catch (e) {
    if (seq !== routeSeq) return;
    console.warn(e);
    view.replaceChildren(e?.loadFailed ? loadErrorView() : h('p', { class: 'err pad', role: 'alert', text: errMsg(e) }));
  }
}
async function enter() {
  const s = getSession();
  $('login-screen').hidden = !!s; $('shell').hidden = !s;
  if (!s) return;
  try {
    const { query } = parseAdminHash(location.hash);
    const date = /^\d{4}-\d\d-\d\d$/.test(query.get('d') || '') ? query.get('d') : todayHel();
    // Yksi SQL-RPC hakee myös roolin, käyttöoikeudet, tuotteet, maksutavat ja resurssit.
    // Import ja tietokantakutsu käynnistyvät samaan aikaan, eivät peräkkäin.
    const viewJob = loadView('day').then((m) => { dayModule = m; return m; }).catch(() => null);
    const bootstrapJob = rpc('admin_day_bundle', { p_date: date }).then((bundle) => ({ bundle }), (error) => ({ error }));
    const [dm, boot] = await Promise.all([viewJob, bootstrapJob]);
    const bundle = boot.bundle;
    if (boot.error) dm?.rememberDayBundleError?.(boot.error);
    let role, me;
    if (bundle && bundle.role && Array.isArray(bundle.products) && Array.isArray(bundle.resources)
        && Array.isArray(bundle.payment_methods) && bundle.permissions) {
      role = bundle.role;
      me = bundle.permissions;
      const products = bundle.products;
      ctx.refs = { products, methods: bundle.payment_methods, resources: bundle.resources,
        productById: new Map(products.map((p) => [p.id, p])) };
      dm?.primeDayBundle?.(date, bundle);
      primeSiteTexts(bundle.site_texts);
      await Promise.all([loadFilterTexts(rpc), loadNavTexts(rpc)]);  // muistissa oleva vastaus: ei verkkokutsua
    } else {
      // Vanha kanta tai mock ilman bootstrappia: kolme vanhaa hakua yhtä aikaa.
      [role, me] = await Promise.all([rpc('current_staff_role'), rpc('admin_my_permissions'),
        refs(), loadFilterTexts(rpc), loadNavTexts(rpc)]);
      if (bundle) dm?.primeDayBundle?.(date, bundle);
    }
    if (!role) { signOut(); showLogin('Tällä tunnuksella ei ole oikeutta hallintaan (ei henkilökuntaa).'); return; }
    ctx.role = role; ctx.name = s.user?.email || ''; ctx.perms = me?.permissions || []; ctx.roleLabel = me?.role_label || role;
    const identity = compactIdentity(ctx.name, ctx.roleLabel);
    $('who').textContent = MOCK ? 'Kokeilutila: esimerkkidata, mikään ei tallennu' : `${ctx.name} · ${ctx.roleLabel}`;
    $('who').classList.toggle('is-mock', MOCK);
    $('user-short').textContent = identity.name;
    $('user-initial').textContent = identity.initial;
    $('user-role').textContent = identity.role;
    $('user-email').textContent = ctx.name;
    $('user-role-full').textContent = navText('ui.admin.nav.role', { role: ctx.roleLabel });
    paintTopBarTexts();
    document.body.dataset.role = role;
    void route();
  } catch (e) { signOut(); showLogin(errMsg(e)); }
}
function showLogin(msg) {
  $('login-screen').hidden = false; $('shell').hidden = true;
  const el = $('login-err'); el.hidden = !msg; el.textContent = msg || '';
}
$('login').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const btn = ev.target.querySelector('button'); btn.disabled = true; showLogin('');
  try { await signIn($('email').value.trim(), $('password').value); await enter(); } catch (e) { showLogin(errMsg(e)); } finally { btn.disabled = false; }
});
// Yläpalkin ja sivupalkin painikkeiden ikonit (icons.js, currentColor) ja tekstit (nav-texts.js, ui.admin.nav.*).
for (const el of document.querySelectorAll('#shell [data-icon]')) el.replaceChildren(icon(el.dataset.icon, el.closest('.nav-toggle') ? 26 : 20));
function paintTopBarTexts() {
  const tn = (k) => navText(`ui.admin.nav.${k}`);
  const attr = (id, a, k) => $(id)?.setAttribute(a, tn(k));
  attr('quick-search-toggle', 'aria-label', 'search_open');
  attr('quick-search-input', 'placeholder', 'search_placeholder'); attr('quick-search-input', 'aria-label', 'search_label');
  attr('quick-search-results', 'aria-label', 'search_results');
  document.querySelector('label[for=quick-search-input]').textContent = tn('search_label');
  for (const [id, k] of [['quick-new', 'new_reservation'], ['quick-review', 'review']]) { attr(id, 'aria-label', k); $(id).querySelector('.action-label').textContent = tn(k); }
  attr('user-menu-toggle', 'aria-label', 'user_menu');
  $('open-shop-label').textContent = tn('open_shop'); $('open-shop-hint').textContent = tn('new_tab');
  const nt = $('nav-toggle'); nt.setAttribute('aria-label', tn(nt.getAttribute('aria-expanded') === 'true' ? 'collapse' : 'expand'));
}
const mobileToggle = $('nav-toggle');
mobileToggle.addEventListener('click', () => toggleMobileNav($('shell'), mobileToggle));
const userToggle = $('user-menu-toggle'), userDropdown = $('user-dropdown');
function setUserOpen(open) {
  userToggle.setAttribute('aria-expanded', String(open));
  userDropdown.hidden = !open;
}
userToggle.addEventListener('click', () => setUserOpen(userDropdown.hidden));
document.addEventListener('click', (e) => {
  if (!e.target?.closest?.('.user-menu')) setUserOpen(false);
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') { setUserOpen(false); }
});
setupQuickSearch({ input: $('quick-search-input'), panel: $('quick-search-results'),
  toggle: $('quick-search-toggle'), box: $('quick-search-box'), ctx, rpc });
$('logout').addEventListener('click', () => { if (MOCK) { location.href = location.pathname; return; }
   signOut(); ctx.refs = null; ctx.role = null; ctx.perms = []; dayModule?.clearDayBundleCache?.(); clearSiteTextsCache(); showLogin(''); });
window.addEventListener('hashchange', route);
// Sama fragmentti (esim. muistutuslinkki kun lista on jo auki samalla suodattimella) ei laukaise hashchangea,
// jolloin näkymä jäisi piirtämättä ("ei avaa mitään"). Eri fragmentti vaihtuu selaimen hashchange-tapahtumalla.
document.addEventListener('click', (ev) => {
  if (ev.defaultPrevented || ev.button !== 0 || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return;
  const el = ev.target instanceof Element ? ev.target : ev.target?.parentElement;
  const a = el?.closest?.('a[href^="#"]');
  if (!a) return;
  const href = a.getAttribute('href');
  if (!href || href === '#') return;
  if (needsManualRoute(location.hash, href)) { ev.preventDefault(); route(); }
});
onAuthChange((s) => { if (!s) { dayModule?.clearDayBundleCache?.(); clearSiteTextsCache(); showLogin(''); } });
// Kutsulinkki (#access_token=…&type=invite): istunto otetaan käyttöön ja käyttäjä asettaa salasanan ennen hallintaan siirtymistä
if (adoptSessionFromHash()) {
  $('login-screen').hidden = true; $('shell').hidden = true; $('setpw-screen').hidden = false;
  $('setpw').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const a = $('pw1').value, b = $('pw2').value, err = $('setpw-err'); err.hidden = true;
    if (a.length < 8) { err.textContent = 'Salasanassa pitää olla vähintään 8 merkkiä.'; err.hidden = false; return; }
    if (a !== b) { err.textContent = 'Salasanat eivät täsmää.'; err.hidden = false; return; }
    const btn = ev.target.querySelector('button'); btn.disabled = true;
    try { await setPassword(a); $('setpw-screen').hidden = true; location.hash = '#/'; await enter(); } catch (e) { err.textContent = errMsg(e); err.hidden = false; } finally { btn.disabled = false; }
  });
} else enter();
