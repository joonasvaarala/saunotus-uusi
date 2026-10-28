// booking_158 / booking_210: etusivun tapahtumakortit (booking.public_events → kb.json events_shop).
// Puhdas moduuli (ei lib.mjs-riippuvuutta), testit: booking/tests/tapahtumakortit.test.mjs.
import { dayLabel, ymdHel } from '../booking/shop/src/event-date.js';
import { freeShopEvents, eventIsFull, eventWaitlistPath } from '../booking/shop/src/week-live.js';
export { eventIsFull, eventWaitlistPath };
// - Tulevat kerrat, joilla on paikkoja tai jotka ovat täynnä (available ja full). closed ja menneet eivät näy.
//   Täysi tapahtuma himmennetään ja linkki vie jonoon (yksi kerta) tai tuotesivulle (useampi kerta).
// - Linkki: kaupan sivu FI /varaa/#/…, EN /en/book/#/… (ei Johkua).
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
 * events_shop → kortit: category 'event' ja tulevat kerrat (available tai full).
 * closed ja menneet jäävät pois. Tapahtuma ilman tulevaa kertaa pois. Järjestys ensimmäisen kerran mukaan.
 * Virheellinen syöte → [] (vanha polku).
 */
export function selectShopEvents(list, now = Date.now()) {
  return freeShopEvents(list, now);
}
/**
 * Kortin HTML. deps: { e, money, link(ev) → href, img(ev) → <picture>-HTML, card(ev) → cards.json-kortti tai null, arrow, fullText }.
 * Kaupan linkki avautuu samaan välilehteen (oma sivusto).
 */
export function shopEventsHtml(events, lang, deps) {
  const { e, money, link, img, card = () => null, arrow = '', fullText = '', fullCta = '', empty = '' } = deps;
  return `<ul class="events" data-live-events data-empty="${e(empty)}" data-full-label="${e(fullText)}" data-full-cta="${e(fullCta || arrow)}">${events.map((ev) => {
    const c = card(ev)?.[lang];
    const title = c?.title || (lang === 'en' && ev.name_en) || ev.name;
    const text = c?.text || plainText((lang === 'en' && ev.description_short_en) || ev.description_short);
    const dl = [...new Set(ev.occurrences.slice(0, 6).map((o) => occDates(o, lang, Date.now())))].join(' · ');
    const t = occTime(ev.occurrences[0], lang);
    const price = ev.price != null ? money(ev.price, lang) : (ev.price_text || '');
    const full = eventIsFull(ev);
    const cta = full && fullCta ? fullCta : arrow;
    return `<li class="card ev${full ? ' is-full' : ''}" data-testid="site-event-card"${full ? ' data-full="1"' : ''}><div class="im">${img(ev)}${full && fullText ? `<span class="pill full">${e(fullText)}</span>` : ''}${price ? `<span class="badge">${e(price)}</span>` : ''}</div>
<div class="bd"><h3><a href="${e(link(ev))}">${e(title)}${full && fullText ? `<span class="sr">, ${e(fullText)}</span>` : ''}</a></h3>
<p class="dates">${e(dl)}${t ? ' · ' + e(t) : ''}</p>${text ? `<p>${e(text)}</p>` : ''}</div><div class="cta" aria-hidden="true">${e(cta)}</div></li>`;
  }).join('')}</ul>`;
}
