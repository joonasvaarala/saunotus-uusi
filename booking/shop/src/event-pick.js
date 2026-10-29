// Tapahtumatuotteen varaus: tulevat kerrat päivänapeiksi (ei kuukausikalenteria).
// Päivä on täynnä vain, kun jokainen tuleva kerta on full. Jonotus jää kellonajan napille.
import { dayLabel } from './event-date.js';

const DATE_RE = /^\d{4}-\d\d-\d\d$/;

const upcoming = (r, now) => {
  const t = Date.parse(r.ends_at || r.starts_at || '');
  return Number.isFinite(t) && t >= now;
};

/**
 * byDay = public_availability-rivit päivän mukaan (session_date → rivit).
 * today = YYYY-MM-DD (Helsinki). Menneet, closed ja unavailable jäävät pois.
 * → [{ date, slots, full }] aikajärjestyksessä. Yksi kerta päivässä on silti yksi alkio.
 */
export function groupEventDays(byDay, { now = Date.now(), today = '' } = {}) {
  const days = [];
  for (const [date, rows] of Object.entries(byDay || {})) {
    if (!DATE_RE.test(date) || (today && date < today)) continue;
    const slots = (Array.isArray(rows) ? rows : [])
      .filter((r) => r && (r.status === 'available' || r.status === 'full') && Number.isFinite(+r.rule_id) && upcoming(r, now))
      .slice()
      .sort((a, b) => String(a.starts_at).localeCompare(String(b.starts_at)) || (+a.rule_id - +b.rule_id));
    if (!slots.length) continue;
    days.push({ date, slots, full: slots.every((r) => r.status === 'full') });
  }
  days.sort((a, b) => a.date.localeCompare(b.date));
  return days;
}

/** Napin teksti: 'pe 13.11.' / 'Fri 13 Nov'. Muu vuosi: 'la 6.2.2027' / 'Sat 6 Feb 2027'. */
export function eventDayLabel(date, lang = 'fi', now = Date.now()) {
  if (!DATE_RE.test(date || '')) return '';
  const iso = `${date}T12:00:00Z`;
  const loc = lang === 'en' ? 'en-GB' : 'fi-FI';
  let wd = new Intl.DateTimeFormat(loc, { weekday: 'short', timeZone: 'UTC' }).format(new Date(iso)).replace(/\.$/, '');
  if (lang !== 'en') wd = wd.toLowerCase();
  const day = dayLabel(iso, lang, now);
  return day ? `${wd} ${day}` : '';
}
