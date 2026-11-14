// Etusivun ja saunavuorot-sivun viikko-ohjelma sekä tapahtumakortit (selaimessa). Viikko-ohjelma: week-grid.js (viikkonavigointi, vapaat ajat,
// hinnat, hoidot, tapahtumat ja hiljaisen ajan ale jälkilöylyille / omalle vuorolle). Tämä tiedosto käynnistää sen ja täyttää tapahtumakortit
// (public_events) sekä tuotenimet (public_catalog). Hakuvirhe ei riko sivua. Ei innerHTML:ää: kaikki solmut createElement + textContent.
import { rpc } from './sb.js';
import { liveImageUrl, publicImageUrl } from './product-image.js';
import { addDaysIso } from './quiet-offers-logic.js';
import { freeShopEvents, cardDates, cardTime, eventIsFull, eventWaitlistPath, homeEventCards } from './week-live.js';
import { formatWhenRange, spansDays } from './when-range.js';
import { applyCatalogNames } from './catalog-names.js';
import { mountWeekGrid } from './week-grid.js';

const TZ = 'Europe/Helsinki';

const plain = (s) => String(s ?? '').replace(/<[^>]*>/g, ' ').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();

/** Etusivun tapahtumakortit public_eventsistä. events === null → lista jää ennalleen. Vapaat ja täydet tulevat kerrat. */
export function applyEventCards(list, events, { lang = 'fi', shopHref = '', now = Date.now(), reserve = '', imageBase = '' } = {}) {
  if (events == null || !list) return 0;
  const hide = new Set(String(list.dataset.hideEvents || '').split(',').map((s) => s.trim()).filter(Boolean));
  const rows = homeEventCards(freeShopEvents(events, now)).filter((ev) => !hide.has(ev.slug));
  const doc = list.ownerDocument;
  const el = (tag, cls, text) => { const n = doc.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
  const money = (n) => new Intl.NumberFormat(lang === 'fi' ? 'fi-FI' : 'en-FI', { style: 'currency', currency: 'EUR', minimumFractionDigits: Number.isInteger(+n) ? 0 : 2 }).format(+n);
  const fullLabel = list.dataset.fullLabel || (lang === 'en' ? 'Full' : 'Täynnä');
  const fullCta = list.dataset.fullCta || (lang === 'en' ? 'Join the waitlist →' : 'Liity jonoon →');
  if (!rows.length) {
    const p = el('p', 'center', list.dataset.empty || '');
    list.replaceWith(p);
    return 0;
  }
  const fallbackPic = new Map();
  for (const host of list.querySelectorAll('[data-product-image]')) {
    const pic = host.querySelector('picture, img');
    if (host.dataset.slug && pic) fallbackPic.set(host.dataset.slug, pic);
  }
  list.replaceChildren();
  for (const ev of rows) {
    const name = (lang === 'en' && ev.name_en) || ev.name;
    const text = plain((lang === 'en' && ev.description_short_en) || ev.description_short);
    const shown = ev.occurrences.slice(0, 6);
    const multi = shown.filter((o) => spansDays(o?.starts_at, o?.ends_at));
    const dates = (multi.length
      ? multi.map((o) => formatWhenRange(o.starts_at, o.ends_at, lang, now))
      : [...new Set(shown.map((o) => cardDates(o, lang, now)))]).filter(Boolean).join(' · ');
    const time = multi.length ? '' : cardTime(shown[0], lang);
    const full = eventIsFull(ev);
    const li = el('li', full ? 'card ev is-full' : 'card ev');
    li.dataset.testid = 'site-event-card';
    if (full) li.dataset.full = '1';
    const im = el('div', 'im');
    im.dataset.productImage = '';
    if (ev.slug) im.dataset.slug = ev.slug;
    im.dataset.sizes = '(min-width:1100px) 280px, 90vw';
    const prev = ev.slug ? fallbackPic.get(ev.slug) : null;
    const path = String(ev.image_path || '');
    const direct = /^https?:\/\//.test(path) || path.startsWith('/img/');
    const url = !path ? '' : direct ? publicImageUrl(path) : (imageBase ? liveImageUrl(String(imageBase).replace(/\/$/, ''), { path, updated_at: ev.image_updated_at, alt: ev.image_alt }) : '');
    if (url) {
      const img = doc.createElement('img');
      img.src = url;
      img.alt = ev.image_alt || '';
      img.loading = 'lazy';
      img.decoding = 'async';
      img.width = 900; img.height = 600;
      img.addEventListener('error', () => { if (prev) img.replaceWith(prev.cloneNode(true)); else img.remove(); }, { once: true });
      im.append(img);
    } else if (prev) im.append(prev.cloneNode(true));
    if (full) im.append(el('span', 'pill full', fullLabel));
    if (ev.price != null && Number.isFinite(+ev.price)) im.append(el('span', 'badge', money(ev.price)));
    const bd = el('div', 'bd');
    const h3 = el('h3');
    const a = el('a', '', name);
    const queue = full ? eventWaitlistPath(ev) : '';
    a.href = queue ? `${shopHref}#${queue}` : `${shopHref}#/tuote/${encodeURIComponent(ev.slug)}`;
    if (full) a.append(el('span', 'sr', `, ${fullLabel}`));
    h3.append(a);
    const when = el('p', 'dates', time ? `${dates} · ${time}` : dates);
    bd.append(h3, when);
    if (text) bd.append(el('p', '', text));
    const label = full ? fullCta : (reserve ? (String(reserve).includes('→') ? reserve : `${reserve} →`) : '');
    const cta = el('div', 'cta', label);
    cta.setAttribute('aria-hidden', 'true');
    li.append(im, bd, cta);
    list.append(li);
  }
  return rows.length;
}

const cfg = globalThis.window?.BOOKING_QUIET;
if (cfg && globalThis.document && window.BOOKING_CONFIG?.url) {
  const grids = [...document.querySelectorAll('.vk[data-vk]')];
  const eventLists = [...document.querySelectorAll('ul.events[data-live-events]')];
  const lang = cfg.lang === 'en' ? 'en' : 'fi';
  for (const g of grids) mountWeekGrid(g, { rpc, lang, shopHref: cfg.shopHref });
  if (eventLists.length) {
    const today = new Date().toLocaleDateString('sv-SE', { timeZone: TZ });
    Promise.all([
      rpc('public_events', { p_from: today, p_channel: 'shop' }).catch(() => null),
      rpc('public_catalog', {}).then((rows) => (Array.isArray(rows) ? rows : [])).catch(() => null),
    ]).then(([events, catalog]) => {
      if (events != null && (Array.isArray(events) || typeof events === 'string')) {
        const imageBase = `${String(window.BOOKING_CONFIG.url).replace(/\/$/, '')}/storage/v1/object/public/product-images/`;
        for (const ul of eventLists) applyEventCards(ul, events, { lang: cfg.lang, shopHref: cfg.shopHref, now: Date.now(), reserve: ul.dataset.reserve || '', imageBase });
      }
      if (Array.isArray(catalog)) applyCatalogNames(document, catalog, lang);
    }).catch(() => { /* tapahtumakortit ja nimet ennallaan */ });
  } else if (document.querySelector('[data-catalog-name]')) {
    rpc('public_catalog', {}).then((rows) => { if (Array.isArray(rows)) applyCatalogNames(document, rows, lang); }).catch(() => {});
  }
}
