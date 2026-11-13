// booking_210: täydet tulevat tapahtumat kaupassa. Yleiset vuorot eivät kuulu tähän.
import { freeShopEvents, eventIsFull, eventWaitlistPath } from './week-live.js';

export { freeShopEvents, eventIsFull, eventWaitlistPath };

export function indexShopEvents(events, now = Date.now()) {
  const map = new Map();
  for (const ev of freeShopEvents(events, now)) map.set(+ev.product_id, ev);
  return map;
}

/** Katalogista puuttuva tuleva tapahtuma (vapaa tai täynnä) mukaan, jotta Tapahtumat-chippi näyttää sen. Hintaa ei keksitä. */
export function missingEventProducts(catalog, events, now = Date.now()) {
  const have = new Set((catalog || []).map((p) => +p.id));
  const out = [];
  for (const ev of freeShopEvents(events, now)) {
    if (have.has(+ev.product_id) || !ev.slug) continue;
    have.add(+ev.product_id);
    out.push({
      id: +ev.product_id,
      slug: ev.slug,
      name: ev.name,
      name_en: ev.name_en || '',
      category: 'event',
      sale_kind: 'other',
      price: ev.price,
      description: ev.description_short || '',
      description_en: ev.description_short_en || '',
      short_description: ev.description_short || '',
      short_description_en: ev.description_short_en || '',
      booking_kind: 'rules',
      min_persons: 1,
      max_persons: 50,
    });
  }
  return out;
}

/**
 * KAUPPA-JONO-01 (UX-analyysi #345): #/jono/<sääntö>/<pvm>/<tuote> suoraan (päivitys, sähköpostin linkki) antoi "Vuoroa ei löytynyt",
 * koska public_catalogista puuttuva tapahtumatuote lisättiin state.catalogiin vain listanäkymässä (viewList). Sama lisäys tehdään
 * nyt ennen jonotusnäkymää. Yrityskalenteri ei hae julkisia tapahtumia (kuten viewList). Palauttaa true, jos tuote on katalogissa.
 */
export async function ensureEventProduct(catalog, productId, loadEvents, { business = false, now = Date.now() } = {}) {
  if (!Array.isArray(catalog)) return false;
  if (catalog.some((p) => +p.id === +productId)) return true;
  if (business || typeof loadEvents !== 'function') return false;
  const events = await Promise.resolve().then(loadEvents).catch(() => []);
  for (const p of missingEventProducts(catalog, Array.isArray(events) ? events : [], now)) catalog.push(p);
  return catalog.some((p) => +p.id === +productId);
}

export function byEventStart(index) {
  return (a, b) => String(index.get(+a.id)?.occurrences?.[0]?.starts_at || '9999').localeCompare(String(index.get(+b.id)?.occurrences?.[0]?.starts_at || '9999'))
    || (+a.id - +b.id);
}
