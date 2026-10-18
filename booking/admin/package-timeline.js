// Pakettituotteen aikajana hallinnan Vapaat ajat -paneelissa (kb 7 Saunarituaali ja savusaunavuoro: rituaali 20 min, tauko 10 min, savusauna 90 min = 120 min).
// Palvelin (admin_treatment_availability) palauttaa vain alku- ja loppuajan (kesto 120 min), ei jaksoja → jaksot ovat tässä yhdessä paikassa, samat kuin kaupassa
// (shop/src/treatments.js PACKAGE_TIMELINES; tests/admin-vapaat-ajat.test.mjs varmistaa ettei taulukot eriydy). Vain hallinnan tekstit (suomi); asiakasnäkymän tekstit ovat kaupan i18n:ssä.
import { fmtTime } from './ui.js';

export const PACKAGE_TIMELINES = {
  7: [{ key: 'ritual', min: 20 }, { key: 'break', min: 10 }, { key: 'smoke', min: 90 }],
};
export const SEGMENT_FI = { ritual: 'Rituaali', break: 'Tauko', smoke: 'Savusauna' };
export const timelineOf = (productId) => PACKAGE_TIMELINES[productId] || null;
export const timelineMinutes = (productId) => (timelineOf(productId) || []).reduce((a, x) => a + x.min, 0);
// Jaksot kellonaikoina alkuajasta (Helsingin aika): [{ key, min, from: 'HH:MM', to: 'HH:MM' }]. Tyhjä, jos tuotteella ei ole aikajanaa tai alkuaika puuttuu.
export function timelineSlots(productId, startIso) {
  const tl = timelineOf(productId); if (!tl || !startIso) return [];
  let at = new Date(startIso).getTime();
  return tl.map((x) => { const from = fmtTime(new Date(at).toISOString()); at += x.min * 60e3; return { ...x, from, to: fmtTime(new Date(at).toISOString()) }; });
}
export const fmtDuration = (m) => (m == null || !(m > 0) ? '' : m < 60 ? `${m} min` : m % 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m / 60} h`);
