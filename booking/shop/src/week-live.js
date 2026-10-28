// Viikko-ohjelman ajonaikainen täydennys (etusivu + saunavuorot).
// Lähteet ovat samat kuin kaupalla: public_availability_all, public_events ja public_catalog.
// Päiviä ei näytetä. Täysi vuoro ja täysi tapahtuma piilotetaan. Hakuvirheessä kutsua ei tehdä, ja ohjelma jää ennalleen.
import { addDaysIso, weekdayIso } from './quiet-offers-logic.js';

const TZ = 'Europe/Helsinki';

const clock = (iso) => {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return null;
  const s = new Intl.DateTimeFormat('fi-FI', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(t));
  const m = /(\d{1,2})\D(\d{2})/.exec(s);
  return m ? `${m[1].padStart(2, '0')}:${m[2]}` : null;
};
/** 16:00, 16.00, 16.30 ja 9.05 → minuutit. data-open on HH:MM, näytetty aika FI 16.00 / EN 16:00. */
export function parseClock(txt) {
  const m = /^(\d{1,2})[:.](\d{2})$/.exec(String(txt || '').trim());
  return m ? +m[1] * 60 + +m[2] : null;
}
const mins = parseClock;
const shown = (iso, lang = 'fi') => {
  const c = clock(iso);
  if (!c) return '';
  const [hh, mm] = c.split(':');
  return `${Number(hh)}${lang === 'en' ? ':' : '.'}${mm}`;
};

/** Kellonaika ilman päivämäärää, minuutit aina mukana (16.00–19.00 / 16:30–18:30). Monipäiväisestä vain alku. */
export function rangeLabel(startIso, endIso, lang = 'fi') {
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

/** Viikonpäivän (1–7) päivä ikkunassa tänään…tänään+6. Sama viikonpäivä ei toistu. */
export function dateForWeekday(today, weekday) {
  if (!/^\d{4}-\d\d-\d\d$/.test(today || '') || weekday < 1 || weekday > 7) return null;
  const wd = weekdayIso(today);
  if (!wd) return null;
  return addDaysIso(today, (weekday - wd + 7) % 7);
}

const overlaps = (slot, open, close) => {
  const a = mins(clock(slot.starts_at)), b = mins(clock(slot.ends_at)), o = mins(open), c = mins(close);
  if (a == null || b == null || o == null || c == null) return false;
  return a < c && b > o;
};

/**
 * true vain kun tämän päivän vuoro on loppuunmyyty: vähintään yksi full eikä yhtään available.
 * Tyhjä tai tuntematon vastaus → false (rivi jää näkyviin).
 */
export function shiftIsFull(rows, { productId, date, open, close } = {}) {
  if (!/^\d{4}-\d\d-\d\d$/.test(date || '') || !Number.isFinite(+productId)) return false;
  const mine = (rows || []).filter((r) => r && +r.product_id === +productId && r.session_date === date && r.status);
  if (!mine.length) return false;
  const hit = open && close ? mine.filter((r) => overlaps(r, open, close)) : [];
  const set = hit.length ? hit : mine;
  if (set.some((r) => r.status === 'available')) return false;
  return set.some((r) => r.status === 'full');
}

export function asEventList(raw) {
  if (Array.isArray(raw)) return raw;
  if (typeof raw === 'string') { try { const j = JSON.parse(raw); return Array.isArray(j) ? j : []; } catch { return []; } }
  return [];
}

/**
 * Julkiset tapahtumat, joilla on vapaa paikka näkyvällä viikolla (tänään + 6).
 * status full ja closed jäävät pois. Menneet ja ikkunan ulkopuoliset jäävät pois.
 */
export function weekEvents(events, { today, now } = {}) {
  if (!/^\d{4}-\d\d-\d\d$/.test(today || '') || !Number.isFinite(+now)) return [];
  const last = addDaysIso(today, 6);
  const out = [];
  for (const ev of asEventList(events)) {
    if (!ev || ev.category !== 'event' || typeof ev.slug !== 'string' || !ev.slug || !ev.name) continue;
    for (const o of Array.isArray(ev.occurrences) ? ev.occurrences : []) {
      if (!o || o.status !== 'available' || !o.starts_at) continue;
      const start = Date.parse(o.starts_at);
      if (!Number.isFinite(start) || start <= +now) continue;
      const date = ymdHel(o.starts_at);
      if (!date || date < today || date > last) continue;
      const weekday = weekdayIso(date);
      if (!weekday) continue;
      out.push({
        weekday, date, slug: ev.slug, productId: ev.product_id, ruleId: o.rule_id,
        name: ev.name, nameEn: ev.name_en || '', time: rangeLabel(o.starts_at, o.ends_at),
        key: `${ev.product_id}|${o.rule_id}|${date}`,
      });
    }
  }
  return out.sort((a, b) => a.date.localeCompare(b.date) || a.time.localeCompare(b.time, 'fi') || String(a.key).localeCompare(String(b.key)));
}

const MON_EN = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const dm = (iso, lang) => {
  const [y, m, d] = ymdHel(iso).split('-').map(Number);
  if (!y) return '';
  return lang === 'en' ? `${d} ${MON_EN[m - 1]}` : `${d}.${m}.`;
};
/** Kortin päivä(t), ei vuotta. Monipäiväinen: alku–loppu. */
export function cardDates(o, lang = 'fi') {
  if (!o?.starts_at) return '';
  const a = dm(o.starts_at, lang);
  if (!a) return '';
  if (o.ends_at && ymdHel(o.ends_at) !== ymdHel(o.starts_at)) return `${a}–${dm(o.ends_at, lang)}`;
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

/** Kaikki tulevat tapahtumat, joilla on vapaa paikka. full ja closed pois. Sama sääntö kuin selectShopEvents. */
export function freeShopEvents(events, now = Date.now()) {
  if (!Number.isFinite(+now)) return [];
  return asEventList(events).filter((ev) => ev && ev.category === 'event' && typeof ev.slug === 'string' && ev.slug && ev.name)
    .map((ev) => ({ ...ev, occurrences: (Array.isArray(ev.occurrences) ? ev.occurrences : [])
      .filter((o) => o && o.status === 'available' && o.starts_at && Date.parse(o.ends_at || o.starts_at) > +now)
      .sort((a, b) => String(a.starts_at).localeCompare(String(b.starts_at))) }))
    .filter((ev) => ev.occurrences.length)
    .sort((a, b) => String(a.occurrences[0].starts_at).localeCompare(String(b.occurrences[0].starts_at)));
}

/** Nimi katalogista, jos tuote on siinä; muuten public_events-nimi. */
export function eventDisplayName(ev, catalog, lang) {
  const c = (catalog || []).find((p) => p && (p.slug === ev.slug || (ev.productId != null && +p.id === +ev.productId)));
  const name = (lang === 'en' && (c?.name_en || ev.nameEn)) || c?.name || (lang === 'en' ? ev.nameEn : '') || ev.name;
  return String(name || '').replace(/\s+/g, ' ').trim();
}
