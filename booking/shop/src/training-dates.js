// Kurssin ilmoittautuminen tuotesivulla (Joonas 6.11.2026, t1366u): vain "Valitse päivä".
// Ehto on AINOA: kb.products.category = 'training'. Ei kind = 'event' -ehtoa (tapahtumilla voi olla useita
// kellonaikoja samana päivänä) eikä "päivällä vain yksi vuoro" -ehtoa: muut tuotteet pitävät päivä + kellonaika -valinnan.
// Päivänappi = yksi kurssikerta (ilmoittautumiskerta). Napissa vain päivämäärät, ei kellonaikoja.
// Kellonajat ja kertojen nimet (vuorosääntöjen label / label_en, koulutuksen jaksot) näytetään Lue lisää -osiossa.
// Puhdas moduuli (testit: booking/tests/kurssi-paivanapit.test.mjs).
import { formatWhenRange } from './when-range.js';
import { ymdHel } from './event-date.js';

const TZ = 'Europe/Helsinki';
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// Tekstit FI+EN: ui.shop.training.schedule (content/site-texts.pending-import-126.json). Tietokannan rivi peittää oletuksen.
export const TRAINING_DATE_TEXTS = {
  fi: { schedule: 'Ajankohdat ja aikataulu' },
  en: { schedule: 'Dates and schedule' },
};
export const trainingDateText = (key, lang, tx = null) =>
  (tx && tx(`ui.shop.training.${key}`)) || TRAINING_DATE_TEXTS[lang === 'en' ? 'en' : 'fi'][key] || TRAINING_DATE_TEXTS.fi[key] || '';

/** Kurssinäkymä vain koulutuksille (kb.products.category = 'training'). */
export const isTrainingCategory = (p) => p?.category === 'training';

function parts(iso) {
  const ymd = ymdHel(iso, TZ);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(ymd)) return null;
  const [y, m, d] = ymd.split('-').map(Number);
  const wd = new Intl.DateTimeFormat('en-GB', { weekday: 'short', timeZone: 'UTC' }).format(new Date(Date.UTC(y, m - 1, d, 12)));
  return { y, m, d, ymd, wd };
}

/**
 * Päiväväli ilman kellonaikoja, Helsingin aika, vuosi aina mukana.
 * FI: '19.–21.4.2027', '30.11.–4.12.2026', '28.12.2026–2.1.2027', yksi päivä '19.4.2027'.
 * EN: 'Mon 19 Apr – Wed 21 Apr 2027', 'Mon 28 Dec 2026 – Sat 2 Jan 2027', yksi päivä 'Mon 19 Apr 2027'.
 */
export function formatDateSpan(startIso, endIso, lang = 'fi') {
  const a = parts(startIso);
  if (!a) return '';
  let b = endIso ? parts(endIso) : null;
  if (b && b.ymd < a.ymd) b = null;
  if (lang === 'en') {
    const one = (p, withYear) => `${p.wd} ${p.d} ${MON[p.m - 1]}${withYear ? ` ${p.y}` : ''}`;
    if (!b || b.ymd === a.ymd) return one(a, true);
    return `${one(a, a.y !== b.y)} – ${one(b, true)}`;
  }
  if (!b || b.ymd === a.ymd) return `${a.d}.${a.m}.${a.y}`;
  if (a.y !== b.y) return `${a.d}.${a.m}.${a.y}–${b.d}.${b.m}.${b.y}`;
  if (a.m !== b.m) return `${a.d}.${a.m}.–${b.d}.${b.m}.${b.y}`;
  return `${a.d}.–${b.d}.${b.m}.${b.y}`;
}

const validSegs = (segs) => (Array.isArray(segs) ? segs.filter((g) => g?.starts_at && g?.ends_at) : []);

/** Päivänapin teksti: kerran päiväväli; monijaksoinen kurssi → jaksojen päivävälit ' · ' -erotettuna. Ei kellonaikoja. */
export function sessionDateText(r, segs, lang = 'fi') {
  const g = validSegs(segs);
  if (g.length > 1) return g.map((x) => formatDateSpan(x.starts_at, x.ends_at, lang)).filter(Boolean).join(' · ');
  return formatDateSpan(r?.starts_at, r?.ends_at, lang);
}

/**
 * groupEventDays-päivät → kurssikerrat (yksi nappi per kerta, myös jos samana päivänä alkaisi kaksi kertaa).
 * → [{ date, r, segs, full, remaining }]
 */
export function trainingSessions(days, segByRule = new Map()) {
  const out = [];
  for (const day of Array.isArray(days) ? days : []) {
    for (const r of Array.isArray(day?.slots) ? day.slots : []) {
      const full = r.status !== 'available';
      const remaining = !full && r.remaining != null && r.remaining !== '' && Number.isFinite(+r.remaining) ? +r.remaining : null;
      out.push({ date: day.date, r, segs: segByRule?.get?.(r.rule_id) || null, full, remaining });
    }
  }
  return out;
}

const labelOf = (o, lang) => String((lang === 'en' && o?.label_en) || o?.label || '').trim();

/**
 * Lue lisää -osion aikataulu: kerran nimi (vuorosäännön label / label_en) ja alku- ja loppuaika kellonaikoineen.
 * Monijaksoinen kurssi: jaksot (public_training_checkout.segments: label / label_en, starts_at, ends_at).
 * → [{ date, title, when, full, parts: [{ title, when }] }]
 */
export function scheduleRows(sessions, lang = 'fi', now = Date.now()) {
  return (Array.isArray(sessions) ? sessions : []).map((s) => {
    const segs = validSegs(s.segs);
    return {
      date: s.date,
      title: labelOf(s.r, lang),
      when: formatWhenRange(s.r?.starts_at, s.r?.ends_at, lang, now),
      full: !!s.full,
      parts: segs.length > 1 ? segs.map((g) => ({ title: labelOf(g, lang), when: formatWhenRange(g.starts_at, g.ends_at, lang, now) })) : [],
    };
  });
}
