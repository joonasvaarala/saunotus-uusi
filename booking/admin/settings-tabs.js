// Asetusten välilehdet (HALL-ASETUKSET-01). Puhdas moduuli: ei DOM:ia.
// Neljä välilehteä: Yleiset, Varaukset, Maksut ja laskutus, Järjestelmä (vain admin). Käyttäjät on oma välilehtensä asetusryhmässä (#/kayttajat).
// Vanhat välilehtiosoitteet (kirjanmerkit) ohjautuvat uuteen paikkaan: LEGACY_TABS.
import { parseAdminHash } from './reservation-query.js';

export const TAB_ORDER = ['yleiset', 'varaukset', 'maksut', 'jarjestelma'];

/** Vanha välilehti → uusi välilehti (tab) tai toinen näkymä (href). Vain luku: ei kirjoita mitään. */
export const LEGACY_TABS = {
  etusivu: { tab: 'yleiset' },
  yritys: { tab: 'yleiset' },
  laskut: { tab: 'maksut' },
  yhteydet: { tab: 'jarjestelma' },
  tekninen: { tab: 'jarjestelma' },
  sahkoposti: { href: '#/viestit' },
  lahjakortit: { href: '#/lahjakortit?tab=omat' },
  qr: { href: '#/tuotteet?qr=1' },
};

export function visibleSettingTabs({ can, role } = {}) {
  const allow = typeof can === 'function' ? can : () => false;
  if (!allow('settings.edit')) return [];
  return TAB_ORDER.filter((id) => id !== 'jarjestelma' || role === 'admin');
}

export function settingsHref(tab) {
  return `#/asetukset/${tab}`;
}

function idFromHash(hash) {
  const { path, rest } = parseAdminHash(hash);
  return path === 'asetukset' ? String(rest || '').split('/')[0] : '';
}

/** Vanhan välilehden uusi kohde tai null. */
export function legacyTarget(hash) {
  const id = idFromHash(hash);
  return Object.prototype.hasOwnProperty.call(LEGACY_TABS, id) ? LEGACY_TABS[id] : null;
}

export function tabFromHash(hash, tabs) {
  const list = tabs || [];
  const id = idFromHash(hash);
  if (list.includes(id)) return id;
  const legacy = Object.prototype.hasOwnProperty.call(LEGACY_TABS, id) ? LEGACY_TABS[id].tab : null;
  if (legacy && list.includes(legacy)) return legacy;
  return list[0] || '';
}
