// booking_158: kaupan tapahtumasivu, kun tapahtuman myynti on suljettu (events.sale_enabled = false → public_catalog ei näytä tapahtumia,
// public_availability piilottaa kerrat ja public_create_booking palauttaa sale_closed). Tuotesivu (#/tuote/<slug>) näyttää silloin tapahtuman
// tiedot ja tulevat kerrat public_events-RPC:stä ilman ostopainiketta. Puhdas moduuli (testit: booking/tests/tapahtumat.test.mjs).
// Tekstit FI+EN: ui.shop.event.* (content/site-texts.pending-import-57.json); tietokannan rivi peittää oletuksen (texts.tx), puuttuu → tämä sanakirja.
export const EVENT_SHOP_TEXTS = {
  fi: {
    'ui.shop.event.sale_closed_title': 'Myynti avautuu pian',
    'ui.shop.event.sale_closed_text': 'Tämän tapahtuman liput tulevat myyntiin verkkokauppaamme pian. Kysy lisätietoja tai varaa paikka ottamalla yhteyttä.',
    'ui.shop.event.dates': 'Tulevat ajankohdat',
    'ui.shop.event.no_dates': 'Uusia ajankohtia julkaistaan pian.',
    'ui.shop.event.status_closed': 'Ei vielä myynnissä',
    'ui.shop.event.status_full': 'Täynnä',
    'ui.shop.event.status_available': 'Paikkoja vapaana',
  },
  en: {
    'ui.shop.event.sale_closed_title': 'Tickets on sale soon',
    'ui.shop.event.sale_closed_text': 'Tickets for this event will be available in our online shop soon. Contact us for more information or to reserve a place.',
    'ui.shop.event.dates': 'Upcoming dates',
    'ui.shop.event.no_dates': 'New dates will be published soon.',
    'ui.shop.event.status_closed': 'Not on sale yet',
    'ui.shop.event.status_full': 'Full',
    'ui.shop.event.status_available': 'Places available',
  },
};
export const eventText = (key, lang, tx = null) => (tx && tx(key)) || EVENT_SHOP_TEXTS[lang === 'en' ? 'en' : 'fi'][key] || EVENT_SHOP_TEXTS.fi[key] || '';

const TZ = 'Europe/Helsinki';
const fmt = (iso, lang, o) => new Intl.DateTimeFormat(lang === 'en' ? 'en-GB' : 'fi-FI', { timeZone: TZ, ...o }).format(new Date(iso));
const day = (iso, lang) => fmt(iso, lang, { weekday: 'short', day: 'numeric', month: 'numeric', year: 'numeric' });
const clock = (iso, lang) => fmt(iso, lang, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).replace('.', ':');
const ymd = (iso) => new Date(iso).toLocaleDateString('sv-SE', { timeZone: TZ });

/** Kerran aika tekstinä: sama päivä → 'la 14.11.2026 16:00–19:00'; monipäiväinen → 'pe 13.11.2026 09:00 – su 15.11.2026 16:00'. */
export function occurrenceText(o, lang = 'fi') {
  if (!o?.starts_at) return '';
  if (!o.ends_at) return `${day(o.starts_at, lang)} ${clock(o.starts_at, lang)}`;
  return ymd(o.starts_at) === ymd(o.ends_at) ? `${day(o.starts_at, lang)} ${clock(o.starts_at, lang)}–${clock(o.ends_at, lang)}`
    : `${day(o.starts_at, lang)} ${clock(o.starts_at, lang)} – ${day(o.ends_at, lang)} ${clock(o.ends_at, lang)}`;
}
export const isMultiDay = (o) => !!(o?.starts_at && o?.ends_at && ymd(o.starts_at) !== ymd(o.ends_at));
/** Kerran nimi kielellä (label_en → label). */
export const occurrenceLabel = (o, lang = 'fi') => (lang === 'en' && o?.label_en) || o?.label || '';
/** public_events-rivit → slugin tapahtuma tai null (virheellinen data → null). */
export function findEvent(list, slug) { return (Array.isArray(list) ? list : []).find((e) => e && e.slug === slug) || null; }
/** Myynti auki vain, kun palvelin sanoo sale_open = true ja jokin kerta on available. Muuten tuotesivu näyttää suljetun tilan (ei ostoa). */
export function saleState(ev) {
  if (!ev) return 'none';
  const occ = Array.isArray(ev.occurrences) ? ev.occurrences : [];
  if (ev.sale_open !== true) return 'closed';
  if (!occ.some((o) => o.status === 'available')) return occ.some((o) => o.status === 'full') ? 'full' : 'closed';
  return 'open';
}
/** Tulevat kerrat aikajärjestyksessä (menneet pois). */
export function upcoming(ev, now = Date.now()) {
  return (Array.isArray(ev?.occurrences) ? ev.occurrences : []).filter((o) => o && Date.parse(o.ends_at || o.starts_at) >= now).sort((a, b) => String(a.starts_at).localeCompare(String(b.starts_at)));
}
