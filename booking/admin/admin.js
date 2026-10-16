// Hallinnan kuori: kirjautuminen (Supabase Auth), reititys (hash), roolien mukainen valikko. Näkymät ovat tiedostoissa views/*.js.
import { signIn, signOut, getSession, onAuthChange, rpc, select } from './sb.js';
import { h, toast, errMsg } from './ui.js';

const $ = (id) => document.getElementById(id);
// perms: roolin oikeudet (booking.role_permissions) palvelimelta; can(oikeus) piilottaa/lukitsee kenttiä. Oikeudet pakotetaan silti tietokannassa.
export const ctx = { role: null, roleLabel: '', name: '', perms: [], can: (p) => ctx.perms.includes(p), refs: null };

const ROUTES = [
  { path: '', label: 'Päivä', icon: '📅', mod: () => import('./views/day.js') },
  { path: 'varaukset', label: 'Varaukset', icon: '📋', mod: () => import('./views/reservations.js') },
  { path: 'uusi', label: 'Uusi varaus', icon: '➕', mod: () => import('./views/newbooking.js') },
  { path: 'asiakkaat', label: 'Asiakkaat', icon: '👥', mod: () => import('./views/customers.js') },
  { path: 'tuotteet', label: 'Tuotteet', icon: '🏷️', mod: () => import('./views/products.js') },
  { path: 'resurssit', label: 'Resurssit', icon: '🛖', mod: () => import('./views/resources.js') },
  { path: 'asetukset', label: 'Asetukset', icon: '⚙️', any: ['settings.edit', 'staff.manage'], mod: () => import('./views/settings.js') },
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
  $('nav').replaceChildren(...ROUTES.filter(allowed).map((r) => h('a', { href: `#/${r.path}`, 'aria-current': r.path === current ? 'page' : null }, h('span', { class: 'ico', 'aria-hidden': 'true', text: r.icon }), h('span', { class: 'lbl', text: r.label }))));
}
async function route() {
  if (!getSession()) return;
  const path = location.hash.replace(/^#\/?/, '').split('?')[0].split('/')[0];
  const r = ROUTES.find((x) => x.path === path && allowed(x)) || ROUTES[0];
  drawNav(r.path);
  const view = $('view');
  view.replaceChildren(h('p', { class: 'muted pad', text: 'Ladataan…' }));
  try {
    const m = await r.mod();
    await refs();
    const out = await m.render({ ctx, refs: ctx.refs, reload: route, query: new URLSearchParams(location.hash.split('?')[1] || '') });
    view.replaceChildren(...[].concat(out));
    document.title = `${r.label} – hallinta`;
  } catch (e) {
    console.warn(e);
    view.replaceChildren(h('p', { class: 'err pad', role: 'alert', text: errMsg(e) }));
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
    $('who').textContent = `${ctx.name} · ${ctx.roleLabel}`;
    document.body.dataset.role = role;
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
$('logout').addEventListener('click', () => { signOut(); ctx.refs = null; ctx.role = null; ctx.perms = []; showLogin(''); });
window.addEventListener('hashchange', route);
onAuthChange((s) => { if (!s) showLogin(''); });
enter();
