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

export function byEventStart(index) {
  return (a, b) => String(index.get(+a.id)?.occurrences?.[0]?.starts_at || '9999').localeCompare(String(index.get(+b.id)?.occurrences?.[0]?.starts_at || '9999'))
    || (+a.id - +b.id);
}
