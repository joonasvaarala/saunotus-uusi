// Asetusten välilehdet. Puhdas moduuli: ei DOM:ia.
// settings.edit näkee osiot. Tekninen vain roolille admin. pos.use tai settings.edit näkee QR-tulostuksen.
import { parseAdminHash } from './reservation-query.js';

export const TAB_ORDER = ['etusivu', 'yritys', 'varaukset', 'maksut', 'sahkoposti', 'lahjakortit', 'laskut', 'yhteydet', 'tekninen', 'qr'];

export function visibleSettingTabs({ can, role } = {}) {
  const allow = typeof can === 'function' ? can : () => false;
  const seeSettings = allow('settings.edit');
  const seeQr = allow('pos.use') || seeSettings;
  return TAB_ORDER.filter((id) => {
    if (id === 'qr') return seeQr;
    if (!seeSettings) return false;
    if (id === 'tekninen') return role === 'admin';
    return true;
  });
}

export function settingsHref(tab) {
  return `#/asetukset/${tab}`;
}

export function tabFromHash(hash, tabs) {
  const list = tabs || [];
  const { path, rest } = parseAdminHash(hash);
  const id = path === 'asetukset' ? String(rest || '').split('/')[0] : '';
  if (list.includes(id)) return id;
  return list[0] || '';
}
