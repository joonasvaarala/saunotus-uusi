// Puhtaat reitti- ja käyttöliittymäapufunktiot: node --test ilman DOM:ia. Tekstit: nav-texts.js (ui.admin.nav.*).
import { navText } from './nav-texts.js';

// Päänavigaation ryhmät. Polku on ryhmän kanoninen osoite; välilehden oma polku (esim. #/pikakassa) ohjautuu ryhmään.
// any: sama oikeuslista kuin entisellä nav-kohdalla. Puuttuva any = kaikille henkilökunnalle.
export const NAV_GROUPS = [
  { id: 'cash', path: 'kassa', labelKey: 'ui.admin.nav.cash_finance', tabs: [
    { id: 'pikakassa', path: 'pikakassa', labelKey: 'ui.admin.nav.pos', view: 'pos', any: ['pos.use'] },
    { id: 'talous', path: 'talous', labelKey: 'ui.admin.nav.finance', view: 'talous', any: ['payments.manage', 'giftcards.manage'] },
    { id: 'seurattavat', path: 'seurattavat-maksut', labelKey: 'ui.admin.nav.paylink_watch', view: 'paylink-watch', any: ['payments.manage'] },
    { id: 'hyvitykset', path: 'hyvitysten-seuranta', labelKey: 'ui.admin.nav.refund_watch', view: 'refund-watch', any: ['bookings.manage'] },
    { id: 'laskut', path: 'laskut', labelKey: 'ui.admin.nav.invoices', view: 'invoices', any: ['invoices.manage'] },
  ] },
  { id: 'products', path: 'tuotteet', labelKey: 'ui.admin.nav.products', tabs: [
    { id: 'tuotteet', path: 'tuotteet', labelKey: 'ui.admin.nav.products', view: 'products' },
    { id: 'tapahtumat', path: 'tapahtumat', labelKey: 'ui.admin.nav.events', view: 'events' },
    { id: 'alennuskoodit', path: 'alennuskoodit', labelKey: 'ui.admin.nav.discounts', view: 'discounts', any: ['catalog.edit', 'annual_cards.manage'] },
    { id: 'hiljaiset-ajat', path: 'hiljaiset-ajat', labelKey: 'ui.admin.nav.quiet_hours', view: 'quiet', any: ['catalog.edit', 'settings.edit'] },
  ] },
  { id: 'spaces', path: 'tilat', labelKey: 'ui.admin.nav.spaces_blocks', tabs: [
    { id: 'resurssit', path: 'resurssit', labelKey: 'ui.admin.nav.resources', view: 'resources' },
    { id: 'sulkukalenterit', path: 'sulkukalenterit', labelKey: 'ui.admin.nav.closures', view: 'closures', any: ['blocks.manage'] },
  ] },
  { id: 'settings', path: 'asetukset', labelKey: 'ui.admin.nav.settings', tabs: [
    { id: 'asetukset', path: 'asetukset', labelKey: 'ui.admin.nav.settings', view: 'settings', any: ['settings.edit', 'pos.use'] },
    { id: 'kayttajat', path: 'kayttajat', labelKey: 'ui.admin.nav.users', view: 'users', any: ['staff.manage'] },
  ] },
];
const GROUP_BY_ID = new Map(NAV_GROUPS.map((g) => [g.id, g]));
const GROUP_BY_CHILD = new Map(NAV_GROUPS.flatMap((g) => g.tabs.map((t) => [t.path, { group: g, tab: t }])));
const GROUP_BY_PATH = new Map(NAV_GROUPS.map((g) => [g.path, g]));

const resolved = (path, legacyReservations, groupId, tabId) => ({ path, legacyReservations, groupId, tabId });
export function resolveAdminPath(path) {
  if (path === 'varaukset') return resolved('tilaukset', true, null, null);
  const child = GROUP_BY_CHILD.get(path);
  if (child) return resolved(child.group.path, false, child.group.id, child.tab.id);
  const group = GROUP_BY_PATH.get(path);
  if (group) return resolved(group.path, false, group.id, null);
  return resolved(path, false, null, null);
}
export function navGroupById(id) { return GROUP_BY_ID.get(id) || null; }
export function tabAllowed(tab, can) { return !tab.any || tab.any.some((p) => can(p)); }
export function visibleGroupTabs(group, can) { return group ? group.tabs.filter((t) => tabAllowed(t, can)) : []; }
export function groupAllowed(group, can) { return visibleGroupTabs(group, can).length > 0; }
export function selectGroupTab(group, tabId, can) {
  const tabs = visibleGroupTabs(group, can);
  return tabs.find((t) => t.id === tabId) || tabs[0] || null;
}
function eventElement(target) {
  if (!target) return null;
  return target.nodeType === 1 ? target : target.parentElement || null;
}
// Laajennettu mobiilipalkki sulkeutuu, kun napautus osuu sisältöön. Itse palkki ja nuoli eivät sulje tästä.
export function shouldCollapseMobileNav(target, { expanded = false, mobile = false, nav = null, toggle = null } = {}) {
  if (!mobile || !expanded) return false;
  const el = eventElement(target);
  if (!el) return true;
  if (nav && (el === nav || nav.contains?.(el))) return false;
  if (toggle && (el === toggle || toggle.contains?.(el))) return false;
  return true;
}
// Nav-linkin napautus sulkee laajennetun palkin (työpöydällä ei).
export function shouldCollapseOnNavLink(target, { expanded = false, mobile = false, nav = null } = {}) {
  if (!mobile || !expanded) return false;
  const el = eventElement(target);
  if (!el || !nav?.contains?.(el)) return false;
  return typeof el.closest === 'function' && !!el.closest('a[href]');
}
export function initialOrdersTab({ legacyReservations = false, query = new URLSearchParams(), canOrders = true } = {}) {
  if (legacyReservations || query.get('tab') === 'reservations' || !canOrders) return 'reservations';
  return 'orders';
}
export function compactIdentity(email = '', role = '', fallback = navText('ui.admin.nav.user_fallback')) {
  const local = String(email).split('@')[0] || fallback;
  const name = local.replace(/[._-]+/g, ' ').trim().split(/\s+/)[0];
  const initial = Array.from(name)[0]?.toUpperCase() || Array.from(fallback)[0] || '?';
  return { name: name[0]?.toUpperCase() + name.slice(1), initial, role: String(role || '') };
}
export function toggleMobileNav(shell, button, force) {
  const expanded = force === undefined ? button.getAttribute('aria-expanded') !== 'true' : !!force;
  shell.classList.toggle('nav-expanded', expanded);
  button.setAttribute('aria-expanded', String(expanded));
  button.setAttribute('aria-label', navText(expanded ? 'ui.admin.nav.collapse' : 'ui.admin.nav.expand'));
  return expanded;
}
