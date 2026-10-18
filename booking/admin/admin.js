// Hallinnan kuori: kirjautuminen (Supabase Auth), reititys (hash), roolien mukainen valikko. Näkymät ovat tiedostoissa views/*.js.
import { signIn, signOut, getSession, onAuthChange, rpc, select, adoptSessionFromHash, setPassword, setRpcOverride, setMockSession } from './sb.js';
import { h, toast, errMsg } from './ui.js';
import { icon } from './icons.js';
import { t as tl } from './talous-i18n.js';
import { createAdminMock } from './options-mock.js';
import { loadFilterTexts } from './filter-texts.js';
import { needsManualRoute, parseAdminHash } from './reservation-query.js';
import { posText } from './pos-texts.js';

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
  { path: 'varaukset', label: 'Varaukset', icon: 'list', mod: () => loadView('reservations') },
  { path: 'talous', label: 'Talous', labelFn: () => tl('nav'), icon: 'euro', any: ['payments.manage', 'giftcards.manage'], mod: () => loadView('talous') },
  { path: 'pikakassa', label: 'Pikakassa', labelFn: () => posText('nav', 'fi'), icon: 'till', any: ['pos.use'], mod: () => loadView('pos') },
  { path: 'laskut', label: 'Laskut', icon: 'receipt', any: ['invoices.manage'], mod: () => loadView('invoices') },
  { path: 'kalenteri', label: 'Kalenteri', icon: 'calendar', mod: () => loadView('calendar') },
  { path: 'tarkista', label: 'Tarkista', icon: 'check', mod: () => loadView('review') },
  { path: 'uusi', label: 'Uusi varaus', icon: 'plus', mod: () => loadView('newbooking') },
  { path: 'asiakkaat', label: 'Asiakkaat', icon: 'users', mod: () => loadView('customers') },
  { path: 'tuotteet', label: 'Tuotteet', icon: 'tag', mod: () => loadView('products') },
  { path: 'resurssit', label: 'Resurssit', icon: 'cabin', mod: () => loadView('resources') },
  { path: 'sulkukalenterit', label: 'Kalenterisulut', icon: 'lock', any: ['blocks.manage'], mod: () => loadView('closures') },
  { path: 'asetukset', label: 'Asetukset', icon: 'sliders', any: ['settings.edit'], mod: () => loadView('settings') },
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
  $('nav').replaceChildren(...ROUTES.filter(allowed).map((r) => h('a', { href: `#/${r.path}`, 'aria-current': r.path === current ? 'page' : null }, h('span', { class: 'ico', 'aria-hidden': 'true' }, icon(r.icon)), h('span', { class: 'lbl', text: r.labelFn ? r.labelFn() : r.label }))));
  // Mobiilin vaakavieritettävä alapalkki: aktiivinen kohta vieritetään näkyviin (keskelle), koska palkki piirretään joka reitillä uudelleen
  const nav = $('nav'), cur = nav.querySelector('[aria-current]');
  if (cur && nav.scrollWidth > nav.clientWidth + 1 && nav.scrollHeight <= nav.clientHeight + 1) nav.scrollLeft = Math.max(0, cur.offsetLeft - (nav.clientWidth - cur.offsetWidth) / 2);
}
let routeSeq = 0;   // nopea navigointi: vain viimeisin reitti saa piirtää näkymän (vanhentuneet vastaukset hylätään)
async function route() {
  if (!getSession()) return;
  const seq = ++routeSeq;
  const { path, query } = parseAdminHash(location.hash);
  const r = ROUTES.find((x) => x.path === path && allowed(x)) || ROUTES[0];
  drawNav(r.path);
  const view = $('view');
  view.replaceChildren(h('p', { class: 'muted pad', text: 'Ladataan…' }));
  try {
    const m = await r.mod();
    await refs();
    const out = await m.render({ ctx, refs: ctx.refs, reload: route, query });
    if (seq !== routeSeq) return;
    view.replaceChildren(...[].concat(out).filter(Boolean));
    document.title = `${r.labelFn ? r.labelFn() : r.label} – hallinta`;
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
    const role = await rpc('current_staff_role');
    if (!role) { signOut(); showLogin('Tällä tunnuksella ei ole oikeutta hallintaan (ei henkilökuntaa).'); return; }
    const me = await rpc('admin_my_permissions');
    ctx.role = role; ctx.name = s.user?.email || ''; ctx.perms = me?.permissions || []; ctx.roleLabel = me?.role_label || role;
    $('who').textContent = MOCK ? 'Kokeilutila: esimerkkidata, mikään ei tallennu' : `${ctx.name} · ${ctx.roleLabel}`;
    document.body.dataset.role = role;
    await loadFilterTexts(rpc);
    route();
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
$('logout').addEventListener('click', () => { if (MOCK) { location.href = location.pathname; return; }
   signOut(); ctx.refs = null; ctx.role = null; ctx.perms = []; showLogin(''); });
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
onAuthChange((s) => { if (!s) showLogin(''); });
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
