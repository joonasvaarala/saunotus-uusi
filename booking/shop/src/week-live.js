// Tapahtumien ja kellonaikojen apufunktiot: viikko-ohjelma (week-grid-logic.js) ja tapahtumakortit (quiet-week.js, src/event-cards.mjs).
// Lähde public_events. Tapahtumakortti: booking_210 (himmennetty, Täynnä, jonotus).
import { dayLabel } from './event-date.js';
import { formatWhenRange, spansDays } from './when-range.js';

const TZ = 'Europe/Helsinki';

const clock = (iso) => {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return null;
  const s = new Intl.DateTimeFormat('fi-FI', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(t));
  const m = /(\d{1,2})\D(\d{2})/.exec(s);
  return m ? `${m[1].padStart(2, '0')}:${m[2]}` : null;
};
const shown = (iso, lang = 'fi') => {
  const c = clock(iso);
  if (!c) return '';
  const [hh, mm] = c.split(':');
  return `${Number(hh)}${lang === 'en' ? ':' : '.'}${mm}`;
};

/** Kellonaika ilman päivämäärää, minuutit aina mukana (16.00–19.00 / 16:30–18:30). Monipäiväinen: koko väli. */
export function rangeLabel(startIso, endIso, lang = 'fi', now = Date.now()) {
  if (spansDays(startIso, endIso)) return formatWhenRange(startIso, endIso, lang, now);
  const a = shown(startIso, lang);
  if (!a) return '';
  if (!endIso || ymdHel(startIso) !== ymdHel(endIso)) return a;
  const b = shown(endIso, lang);
  return b ? `${a}–${b}` : a;
}

export const ymdHel = (iso) => {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return '';
  return new Date(t).toLocaleDateString('sv-SE', { timeZone: TZ });
};

export function asEventList(raw) {
  if (Array.isArray(raw)) return raw;
  if (typeof raw === 'string') { try { const j = JSON.parse(raw); return Array.isArray(j) ? j : []; } catch { return []; } }
  return [];
}

/** Kortin päivä(t). Kuluva vuosi ilman vuotta, muu vuosi vuoden kanssa. Monipäiväinen: alku–loppu. */
export function cardDates(o, lang = 'fi', now = Date.now()) {
  if (!o?.starts_at) return '';
  const a = dayLabel(o.starts_at, lang, now);
  if (!a) return '';
  if (o.ends_at && ymdHel(o.ends_at) !== ymdHel(o.starts_at)) return `${a}–${dayLabel(o.ends_at, lang, now)}`;
  return a;
}
/** Kortin kellonaika ilman päivämäärää. EN 16:00–19:00, FI klo 16.00–19.00. Vain yksipäiväiselle. */
export function cardTime(o, lang = 'fi') {
  if (!o?.starts_at || !o?.ends_at || ymdHel(o.starts_at) !== ymdHel(o.ends_at)) return '';
  const a = clock(o.starts_at), b = clock(o.ends_at);
  if (!a || !b) return '';
  const t = `${a}–${b}`;
  return lang === 'en' ? t : `klo ${t.replace(/:/g, '.')}`;
}

/** Tulevat tapahtumat, joilla on vapaa tai täysi kerta. closed ja menneet pois. Järjestys ensimmäisen kerran mukaan. */
export function freeShopEvents(events, now = Date.now()) {
  if (!Number.isFinite(+now)) return [];
  return asEventList(events).filter((ev) => ev && ev.category === 'event' && typeof ev.slug === 'string' && ev.slug && ev.name)
    .map((ev) => ({ ...ev, occurrences: (Array.isArray(ev.occurrences) ? ev.occurrences : [])
      .filter((o) => o && (o.status === 'available' || o.status === 'full') && o.starts_at && Date.parse(o.ends_at || o.starts_at) > +now)
      .sort((a, b) => String(a.starts_at).localeCompare(String(b.starts_at))) }))
    .filter((ev) => ev.occurrences.length)
    .sort((a, b) => String(a.occurrences[0].starts_at).localeCompare(String(b.occurrences[0].starts_at)) || String(a.slug).localeCompare(String(b.slug)));
}

/** Näitä ei nosteta etusivun tapahtumakortteihin; kaupassa (/varaa) ne pysyvät varattavina. */
export const HOME_UNFEATURED_EVENT_SLUGS = new Set(['naisten-joulusauna']);

export function homeEventCards(rows) {
  return (Array.isArray(rows) ? rows : []).filter((ev) => ev && !HOME_UNFEATURED_EVENT_SLUGS.has(ev.slug));
}

/** Kortti on täynnä, kun jokainen tuleva kerta on full (ei yhtään available). */
export function eventIsFull(ev) {
  const occ = ev?.occurrences;
  return Array.isArray(occ) && occ.length > 0 && occ.every((o) => o && o.status === 'full');
}

/** Yhden täyden kerran jonopolku. Useampi täysi kerta → tyhjä (tuotesivu, jossa jokainen kerta erikseen). */
export function eventWaitlistPath(ev) {
  if (!eventIsFull(ev) || ev.occurrences.length !== 1) return '';
  const o = ev.occurrences[0];
  const date = ymdHel(o.starts_at);
  if (!date || !/^\d+$/.test(String(o.rule_id ?? '')) || !/^\d+$/.test(String(ev.product_id ?? ''))) return '';
  return `/jono/${o.rule_id}/${date}/${ev.product_id}`;
}

/** Nimi katalogista, jos tuote on siinä; muuten public_events-nimi. */
export function eventDisplayName(ev, catalog, lang) {
  const c = (catalog || []).find((p) => p && (p.slug === ev.slug || (ev.productId != null && +p.id === +ev.productId)));
  const name = (lang === 'en' && (c?.name_en || ev.nameEn)) || c?.name || (lang === 'en' ? ev.nameEn : '') || ev.name;
  return String(name || '').replace(/\s+/g, ' ').trim();
}
