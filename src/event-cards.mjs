// booking_158: etusivun tapahtumakortit uuden kaupan tapahtumista (booking.public_events(current_date, 'shop') → kb.json events_shop).
// Puhdas moduuli (ei lib.mjs-riippuvuutta), testit: booking/tests/tapahtumakortit.test.mjs.
import { dayLabel, ymdHel } from '../booking/shop/src/event-date.js';
// - Vain tulevat tapahtumakerrat, joilla on vapaita paikkoja (status available). full ja closed eivät näy.
//   Muuten render.mjs käyttää vanhaa dataa (kb.event_dates + cards.json), mutta linkki on silti kaupan tuotesivu.
// - Linkki: aina kaupan tuotesivu FI /varaa/#/tuote/<slug>, EN /en/book/#/tuote/<slug> (ei Johkua).
// - Nimet ja kuvaukset ovat tietokannasta: kaikki tulostetaan e():llä, kuvaus pelkkänä tekstinä (tagit pois).
const TZ = 'Europe/Helsinki';
/** Kaupan tuotesivun hash-polku: pageHref('book', lang, shopHash(slug)) → /varaa/#/tuote/<slug> tai /en/book/#/tuote/<slug>. */
export const shopHash = (slug) => `/tuote/${encodeURIComponent(String(slug || ''))}`;
const ymd = (iso) => ymdHel(iso, TZ);
const hm = (iso) => new Date(iso).toLocaleTimeString('fi-FI', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).replace(':', '.');
/** Kerran päivä(t): sama päivä '14.11.' / monipäiväinen '13.11.–15.11.' (EN '13 Nov–15 Nov'). Muu kuin kuluva vuosi: '6.2.2027'. */
export function occDates(o, lang = 'fi', now = Date.now()) {
  if (!o?.starts_at) return '';
  const a = dayLabel(o.starts_at, lang, now);
  if (!a) return '';
  return o.ends_at && ymd(o.ends_at) !== ymd(o.starts_at) ? `${a}–${dayLabel(o.ends_at, lang, now)}` : a;
}
/** Kellonaika 'klo 16.00–19.00' / '16:00–19:00' (vain yksipäiväisille). */
export function occTime(o, lang = 'fi') {
  if (!o?.starts_at || !o?.ends_at || ymd(o.ends_at) !== ymd(o.starts_at)) return '';
  const t = `${hm(o.starts_at)}–${hm(o.ends_at)}`;
  return lang === 'en' ? t.replace(/\./g, ':') : `klo ${t}`;
}
export const plainText = (s) => String(s ?? '').replace(/<[^>]*>/g, ' ').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();
/**
 * events_shop → kortit: vain category 'event' ja tulevat kerrat, joilla on vapaita paikkoja (status available).
 * full ja closed jäävät pois. Tapahtuma ilman vapaata kertaa pois. Järjestys ensimmäisen vapaan kerran mukaan.
 * Virheellinen syöte → [] (vanha polku).
 */
export function selectShopEvents(list, now = Date.now()) {
  if (!Array.isArray(list)) return [];
  return list.filter((ev) => ev && ev.category === 'event' && typeof ev.slug === 'string' && ev.slug && ev.name)
    .map((ev) => ({ ...ev, occurrences: (Array.isArray(ev.occurrences) ? ev.occurrences : [])
      .filter((o) => o && o.status === 'available' && o.starts_at && Date.parse(o.ends_at || o.starts_at) > now)
      .sort((a, b) => String(a.starts_at).localeCompare(String(b.starts_at))) }))
    .filter((ev) => ev.occurrences.length)
    .sort((a, b) => String(a.occurrences[0].starts_at).localeCompare(String(b.occurrences[0].starts_at)));
}
/**
 * Kortin HTML. deps: { e, money, link(ev) → href, img(ev) → <picture>-HTML, card(ev) → cards.json-kortti tai null, arrow, fullText }.
 * Kaupan linkki avautuu samaan välilehteen (oma sivusto).
 */
export function shopEventsHtml(events, lang, deps) {
  const { e, money, link, img, card = () => null, arrow = '', fullText = '', empty = '' } = deps;
  return `<ul class="events" data-live-events data-empty="${e(empty)}">${events.map((ev) => {
    const c = card(ev)?.[lang];
    const title = c?.title || (lang === 'en' && ev.name_en) || ev.name;
    const text = c?.text || plainText((lang === 'en' && ev.description_short_en) || ev.description_short);
    const dl = [...new Set(ev.occurrences.slice(0, 6).map((o) => occDates(o, lang, Date.now())))].join(' · ');
    const t = occTime(ev.occurrences[0], lang);
    const price = ev.price != null ? money(ev.price, lang) : (ev.price_text || '');
    const full = ev.occurrences.every((o) => o.status === 'full');
    return `<li class="card ev"><div class="im">${img(ev)}${price ? `<span class="badge">${e(price)}</span>` : ''}</div>
<div class="bd"><h3><a href="${e(link(ev))}">${e(title)}</a></h3>
<p class="dates">${e(dl)}${t ? ' · ' + e(t) : ''}${full && fullText ? ' · ' + e(fullText) : ''}</p>${text ? `<p>${e(text)}</p>` : ''}</div><div class="cta" aria-hidden="true">${e(arrow)}</div></li>`;
  }).join('')}</ul>`;
}
