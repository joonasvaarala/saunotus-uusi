// Puhtaat reitti- ja käyttöliittymäapufunktiot: node --test ilman DOM:ia. Tekstit: nav-texts.js (ui.admin.nav.*).
import { navText } from './nav-texts.js';
export function resolveAdminPath(path) {
  return path === 'varaukset' ? { path: 'tilaukset', legacyReservations: true } : { path, legacyReservations: false };
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
