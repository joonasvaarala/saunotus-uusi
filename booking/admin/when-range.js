// Kurssin ja monipäiväisen tapahtuman aikaväli, Helsingin aika, FI + EN.
// Sama tiedosto tavulleen:
//   booking/shop/src/when-range.js
//   booking/admin/when-range.js
//   booking/supabase/functions/_shared/when-range.js
// Ei site-texts-avaimia: muoto rakennetaan, se ei ole lause.
// Uudet tekstiavaimet: ei ole. EN-viikonpäivät ja kuukaudet ovat lyhenteitä (Mon, Dec).
// Kääntäjä voi tarkistaa EN-muodon; suomeksi "klo" ja piste kellonajassa.
const TZ = 'Europe/Helsinki';
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

const ymdOf = (iso) => {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return '';
  const ymd = new Date(t).toLocaleDateString('sv-SE', { timeZone: TZ });
  return /^\d{4}-\d{2}-\d{2}$/.test(ymd) ? ymd : '';
};

function yearNow(now) {
  const y = new Date(now).toLocaleDateString('sv-SE', { timeZone: TZ }).slice(0, 4);
  return /^\d{4}$/.test(y) ? y : '';
}

function weekday(iso, lang) {
  const loc = lang === 'en' ? 'en-GB' : 'fi-FI';
  let wd = new Intl.DateTimeFormat(loc, { weekday: 'short', timeZone: TZ }).format(new Date(iso)).replace(/\.$/, '');
  return lang === 'en' ? wd : wd.toLowerCase();
}

function clock(iso) {
  const s = new Intl.DateTimeFormat('fi-FI', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso));
  const m = /(\d{1,2})\D(\d{2})/.exec(s);
  if (!m) return null;
  return { hh: m[1].padStart(2, '0'), mm: m[2] };
}

function fromIso(iso) {
  const ymd = ymdOf(iso);
  if (!ymd) return null;
  const hm = clock(iso);
  if (!hm) return null;
  const [y, m, d] = ymd.split('-').map(Number);
  return { y, m, d, ymd, hh: hm.hh, mm: hm.mm, wdFi: weekday(iso, 'fi'), wdEn: weekday(iso, 'en') };
}

function fromLocal(date, time) {
  const dm = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(date || ''));
  const tm = /^(\d{1,2})[:.](\d{2})$/.exec(String(time || '').trim());
  if (!dm || !tm) return null;
  const y = +dm[1];
  const m = +dm[2];
  const d = +dm[3];
  const noon = new Date(Date.UTC(y, m - 1, d, 12));
  const wd = (lang) => {
    const loc = lang === 'en' ? 'en-GB' : 'fi-FI';
    let w = new Intl.DateTimeFormat(loc, { weekday: 'short', timeZone: 'UTC' }).format(noon).replace(/\.$/, '');
    return lang === 'en' ? w : w.toLowerCase();
  };
  return {
    y, m, d, ymd: `${dm[1]}-${dm[2]}-${dm[3]}`,
    hh: tm[1].padStart(2, '0'), mm: tm[2], wdFi: wd('fi'), wdEn: wd('en'),
  };
}

function dateFi(p, withYear) {
  return withYear ? `${p.d}.${p.m}.${p.y}` : `${p.d}.${p.m}.`;
}
function dateEn(p, withYear) {
  return withYear ? `${p.d} ${MON[p.m - 1]} ${p.y}` : `${p.d} ${MON[p.m - 1]}`;
}

/** Eri kalenteripäivät Helsingissä → true. Sama päivä, puuttuva tai virheellinen pää → false. */
export function spansDays(startIso, endIso) {
  const a = ymdOf(startIso);
  const b = ymdOf(endIso);
  return !!(a && b && a !== b);
}

function compose(a, b, lang, now) {
  const en = lang === 'en';
  const cy = yearNow(now);
  const one = (p, withYear) => (en
    ? `${p.wdEn} ${dateEn(p, withYear)} ${p.hh}:${p.mm}`
    : `${p.wdFi} ${dateFi(p, withYear)} klo ${p.hh}.${p.mm}`);
  if (!b) return one(a, String(a.y) !== cy);
  if (a.ymd === b.ymd) {
    const withYear = String(a.y) !== cy;
    const date = en ? `${a.wdEn} ${dateEn(a, withYear)}` : `${a.wdFi} ${dateFi(a, withYear)}`;
    const times = en ? `${a.hh}:${a.mm}–${b.hh}:${b.mm}` : `klo ${a.hh}.${a.mm}–${b.hh}.${b.mm}`;
    return `${date} ${times}`;
  }
  const startYear = String(a.y) !== cy || a.y !== b.y;
  return `${one(a, startYear)} – ${one(b, true)}`;
}

/**
 * Aikaväli.
 * Sama päivä: "ma 30.11. klo 12.30–16.00" / "Mon 30 Nov 12:30–16:00" (vuosi, jos ei kuluva).
 * Eri päivät, sama vuosi: "ma 30.11. klo 12.30 – pe 4.12.2026 klo 16.00".
 * Vuodenvaihde: vuosi molemmissa, kun vuodet eroavat.
 * Puuttuva loppu: vain alku. Virheellinen alku: tyhjä.
 */
export function formatWhenRange(startIso, endIso, lang = 'fi', now = Date.now()) {
  const a = fromIso(startIso);
  if (!a) return '';
  const b = endIso ? fromIso(endIso) : null;
  return compose(a, b, lang === 'en' ? 'en' : 'fi', now);
}

/** Päivä ja kellonaika ovat jo Helsingin aikaa (maksulinkki: YYYY-MM-DD + HH:MM). */
export function formatLocalRange({ startDate, startTime, endDate, endTime } = {}, lang = 'fi', now = Date.now()) {
  const a = fromLocal(startDate, startTime);
  if (!a) return '';
  const b = endDate && endTime ? fromLocal(endDate, endTime) : null;
  return compose(a, b, lang === 'en' ? 'en' : 'fi', now);
}

/** Usean jakson ajat peräkkäin. Yksi jakso käyttää samaa muotoa kuin formatWhenRange. */
export function formatWhenList(rows, lang = 'fi', now = Date.now()) {
  return (Array.isArray(rows) ? rows : [])
    .map((r) => formatWhenRange(r?.starts_at, r?.ends_at, lang, now))
    .filter(Boolean)
    .join(' · ');
}
