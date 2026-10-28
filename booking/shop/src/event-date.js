// Tapahtumakortin päivä. Kuluva vuosi ilman vuotta (14.11.), muu vuosi vuoden kanssa (6.2.2027).
const TZ = 'Europe/Helsinki';
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export const ymdHel = (iso, timeZone = TZ) => {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return '';
  return new Date(t).toLocaleDateString('sv-SE', { timeZone });
};

export function currentYear(now = Date.now(), timeZone = TZ) {
  const y = new Date(now).toLocaleDateString('sv-SE', { timeZone }).slice(0, 4);
  return /^\d{4}$/.test(y) ? y : '';
}

/** Yksittäinen päivä. showYear kun päivän vuosi ei ole now-hetken vuosi. */
export function dayLabel(iso, lang = 'fi', now = Date.now()) {
  const ymd = ymdHel(iso);
  if (!ymd) return '';
  const [y, m, d] = ymd.split('-').map(Number);
  const show = String(y) !== currentYear(now);
  if (lang === 'en') return show ? `${d} ${MON[m - 1]} ${y}` : `${d} ${MON[m - 1]}`;
  return show ? `${d}.${m}.${y}` : `${d}.${m}.`;
}
