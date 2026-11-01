// Viikko-ohjelma (etusivu + saunavuorot). <ol class="week" data-quiet-week> saa tekstit ja tuotenimet
// rakennusvaiheessa (src/quiet-week.mjs). Selain hakee:
//   public_availability(26) — vapaat Savusaunan jälkilöylyt näkyville päiville (tänään + 6)
//   public_quiet_offers — hiljaisen ajan ale samalle vuorolle, jos palvelin sellaisen antaa
// Varattu, mennyt tai virheellinen vuoro ei näy. Jos kumpikaan haku ei onnistu, ohjelma jää ennalleen.
// Ei innerHTML:ää: kaikki solmut createElement + textContent.
import { rpc } from './sb.js';
import { liveImageUrl, publicImageUrl } from './product-image.js';
import { quietByWeekday, addDaysIso, fillText, pctText, validOffer, bookablePrivateSlots, offerForSlot, weekdayIso, JALKIL_ID } from './quiet-offers-logic.js';
import { dateForWeekday, shiftIsFull, weekEvents, eventDisplayName, freeShopEvents, cardDates, cardTime, eventIsFull, eventWaitlistPath } from './week-live.js';
import { applyCatalogNames } from './catalog-names.js';

const TZ = 'Europe/Helsinki';
export function decorateWeek(list, offers, { lang = 'fi', shopHref = '', today, slots, now } = {}) {
  const d = list.dataset;
  let products = {};
  try { products = JSON.parse(d.quietProducts || '{}'); } catch { products = {}; }
  const money = (n) => new Intl.NumberFormat(lang === 'fi' ? 'fi-FI' : 'en-FI', { style: 'currency', currency: 'EUR', minimumFractionDigits: Number.isInteger(+n) ? 0 : 2 }).format(+n);
  const time = (iso) => new Intl.DateTimeFormat(lang === 'fi' ? 'fi-FI' : 'en-GB', { timeZone: TZ, hour: 'numeric', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso)).replace('.', ':').replace(/:00$/, '');
  const el = (tag, cls, text) => { const n = list.ownerDocument.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
  const named = (cls, text, productId) => {
    const n = el('span', cls, text);
    n.dataset.catalogName = '';
    if (productId != null) n.dataset.pid = String(productId);
    return n;
  };
  const srFor = (productId, label, detail) => {
    const sr = el('span', 'sr');
    sr.append(' – ', named('', label, productId), detail ? `, ${detail}` : '');
    return sr;
  };
  const startMin = (txt) => { const m = /^(\d{1,2})(?:[:.](\d\d))?/.exec(String(txt || '').trim()); return m ? +m[1] * 60 + +(m[2] || 0) : null; };
  const place = (ul, li, label) => {
    const mine = startMin(label);
    const next = mine == null ? null : [...ul.children].find((x) => { const v = startMin(x.querySelector('.t')?.textContent); return v != null && v > mine; });
    if (next) ul.insertBefore(li, next); else ul.append(li);
  };
  const dayList = (wd) => {
    const day = list.querySelector(`:scope > li[data-wd="${wd}"]`);
    if (!day) return null;
    let ul = day.querySelector(':scope > ul.sl');
    if (!ul) { ul = el('ul', 'sl'); day.querySelector(':scope > h3')?.after(ul); }
    return { day, ul };
  };
  let added = 0;
  const useSlots = Array.isArray(slots);
  const byDay = quietByWeekday((offers || []).filter((o) => validOffer(o) && products[o.product_id] && !(useSlots && +o.product_id === JALKIL_ID)), today);
  for (const [wd, rows] of byDay) {
    const host = dayList(wd);
    if (!host) continue;
    for (const o of rows) {
      const key = `${o.product_id}|${o.rule_id}|${o.session_date}`;
      if (host.day.querySelector(`:scope li[data-slot-key="${key}"]`)) continue;
      const p = products[o.product_id], vars = { pct: pctText(o.percent, lang), was: money(o.base_price), now: money(o.discounted_price) };
      const li = el('li', 'sess quiet');
      li.dataset.testid = 'site-quiet-session';
      li.dataset.slotKey = key;
      const price = el('span', 'qp');
      price.setAttribute('aria-hidden', 'true');
      price.append(el('span', 'qb', fillText(d.quietBadge, vars)), ' ', el('del', '', vars.was), ' ', el('strong', '', vars.now));
      const a = el('a', 'bk');
      a.href = `${shopHref}#/tuote/${encodeURIComponent(p.s)}/${o.session_date}`;
      a.append(el('span', 'bk-l', d.quietReserve || ''), srFor(o.product_id, p.n, fillText(d.quietSr, vars)));
      li.append(el('span', 't', `${time(o.starts_at)}–${time(o.ends_at)}`), named('n', p.n, o.product_id), price, a);
      place(host.ul, li, time(o.starts_at));
      added++;
    }
    host.day.classList.remove('off');
  }
  if (useSlots) {
    for (const slot of bookablePrivateSlots(slots, { today, now: now ?? Date.now(), productId: JALKIL_ID })) {
      const p = products[slot.product_id];
      const wd = weekdayIso(slot.session_date);
      const host = p && wd ? dayList(wd) : null;
      if (!host) continue;
      const key = `${slot.product_id}|${slot.rule_id}|${slot.session_date}`;
      if (host.day.querySelector(`:scope li[data-slot-key="${key}"]`)) continue;
      const offer = offerForSlot(offers, slot);
      const was = money(offer ? offer.base_price : slot.base_price);
      const nowPrice = money(offer ? offer.discounted_price : slot.base_price);
      const vars = offer ? { pct: pctText(offer.percent, lang), was, now: nowPrice } : { now: nowPrice };
      const li = el('li', 'sess quiet');
      li.dataset.testid = offer ? 'site-quiet-session' : 'site-jalkiloyly';
      if (offer) li.dataset.quiet = '1';
      li.dataset.slotKey = key;
      const price = el('span', 'qp');
      price.setAttribute('aria-hidden', 'true');
      if (offer) price.append(el('span', 'qb', fillText(d.quietBadge, vars)), ' ', el('del', '', vars.was), ' ', el('strong', '', vars.now));
      else price.append(el('strong', '', nowPrice));
      const a = el('a', 'bk');
      a.href = `${shopHref}#/varaa/${encodeURIComponent(slot.rule_id)}/${slot.session_date}/${JALKIL_ID}`;
      const sr = offer ? fillText(d.quietSr, vars) : nowPrice;
      a.append(el('span', 'bk-l', d.quietReserve || ''), srFor(slot.product_id, p.n, sr));
      li.append(el('span', 't', `${time(slot.starts_at)}–${time(slot.ends_at)}`), named('n', p.n, slot.product_id), price, a);
      place(host.ul, li, time(slot.starts_at));
      added++;
      host.day.classList.remove('off');
    }
  }
  // Huomiolaatikkoa ei lisätä. Alennetut vuororivit ja hinnat jäävät.
  return added;
}

// Täydet vuorot pois ja vapaat tapahtumat viikonpäivälleen. availability tai events === null → sitä osaa ei kosketa.
export function applyLiveWeek(list, { availability = null, events = null, catalog = null, lang = 'fi', shopHref = '', today, now } = {}) {
  const d = list.dataset;
  const el = (tag, cls, text) => { const n = list.ownerDocument.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
  const startMin = (txt) => { const m = /^(\d{1,2})(?:[:.](\d\d))?/.exec(String(txt || '').trim()); return m ? +m[1] * 60 + +(m[2] || 0) : null; };
  const place = (ul, li, label) => {
    const mine = startMin(label);
    const next = mine == null ? null : [...ul.children].find((x) => { const v = startMin(x.querySelector('.t')?.textContent); return v != null && v > mine; });
    if (next) ul.insertBefore(li, next); else ul.append(li);
  };
  let hidden = 0, added = 0;
  if (Array.isArray(availability)) {
    for (const day of list.querySelectorAll(':scope > li[data-wd]')) {
      const date = dateForWeekday(today, +day.dataset.wd);
      if (!date) continue;
      for (const row of day.querySelectorAll(':scope > ul.sl > li.sess[data-pid]')) {
        if (row.dataset.testid === 'site-week-event' || row.dataset.testid === 'site-jalkiloyly' || row.dataset.testid === 'site-quiet-session') continue;
        if (!shiftIsFull(availability, { productId: row.dataset.pid, date, open: row.dataset.open || '', close: row.dataset.close || '' })) continue;
        row.hidden = true;
        hidden++;
      }
    }
  }
  if (events != null) {
    for (const ev of weekEvents(events, { today, now })) {
      const day = list.querySelector(`:scope > li[data-wd="${ev.weekday}"]`);
      if (!day) continue;
      const name = eventDisplayName(ev, catalog, lang);
      if (!name) continue;
      let ul = day.querySelector(':scope > ul.sl');
      if (!ul) { ul = el('ul', 'sl'); day.querySelector(':scope > h3')?.after(ul); }
      if ([...day.querySelectorAll(':scope li[data-slot-key]')].some((n) => n.dataset.slotKey === ev.key)) continue;
      const li = el('li', ev.time ? 'sess' : 'sess nt');
      li.dataset.testid = 'site-week-event';
      li.dataset.slotKey = ev.key;
      const a = el('a', 'bk');
      a.href = `${shopHref}#/tuote/${encodeURIComponent(ev.slug)}/${ev.date}`;
      a.append(el('span', 'bk-l', d.quietReserve || ''), el('span', 'sr', ` – ${name}`));
      if (ev.time) li.append(el('span', 't', ev.time));
      li.append(el('span', 'n', name), a);
      place(ul, li, ev.time);
      day.classList.remove('off');
      added++;
    }
  }
  return { hidden, added };
}

const plain = (s) => String(s ?? '').replace(/<[^>]*>/g, ' ').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();

/** Etusivun tapahtumakortit public_eventsistä. events === null → lista jää ennalleen. Vapaat ja täydet tulevat kerrat. */
export function applyEventCards(list, events, { lang = 'fi', shopHref = '', now = Date.now(), reserve = '', imageBase = '' } = {}) {
  if (events == null || !list) return 0;
  const rows = freeShopEvents(events, now);
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
    const dates = [...new Set(ev.occurrences.slice(0, 6).map((o) => cardDates(o, lang, now)))].filter(Boolean).join(' · ');
    const time = cardTime(ev.occurrences[0], lang);
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
  const lists = [...document.querySelectorAll('ol.week[data-quiet-week]')];
  const eventLists = [...document.querySelectorAll('ul.events[data-live-events]')];
  if (lists.length || eventLists.length) {
    const today = new Date().toLocaleDateString('sv-SE', { timeZone: TZ });
    const from = today, to = addDaysIso(today, 6);
    const listOrNull = (rows) => (Array.isArray(rows) ? rows : null);
    Promise.all([
      rpc('public_quiet_offers', { p_from: from, p_to: to, p_audience: 'consumer' }).then((rows) => (Array.isArray(rows) ? rows : [])).catch(() => null),
      rpc('public_availability', { p_product_id: JALKIL_ID, p_from: from, p_to: to }).then((rows) => (Array.isArray(rows) ? rows : [])).catch(() => null),
      rpc('public_availability_all', { p_from: from, p_to: to, p_audience: 'consumer' }).then(listOrNull).catch(() => null),
      rpc('public_events', { p_from: from, p_channel: 'shop' }).then((rows) => rows).catch(() => null),
      rpc('public_catalog', {}).then((rows) => (Array.isArray(rows) ? rows : [])).catch(() => null),
    ]).then(([offers, slots, availability, events, catalog]) => {
      const namesLang = cfg.lang === 'en' ? 'en' : 'fi';
      if (!(offers == null && slots == null && availability == null && events == null)) {
        const opt = { lang: cfg.lang, shopHref: cfg.shopHref, today, now: Date.now() };
        if (slots != null) opt.slots = slots;
        for (const l of lists) {
          if (offers != null || slots != null) decorateWeek(l, offers || [], opt);
          if (availability != null || events != null) applyLiveWeek(l, { availability, events, catalog, lang: cfg.lang, shopHref: cfg.shopHref, today, now: Date.now() });
        }
        if (events != null && (Array.isArray(events) || typeof events === 'string')) {
          const reserve = lists[0]?.dataset.quietReserve || '';
          const imageBase = `${String(window.BOOKING_CONFIG.url).replace(/\/$/, '')}/storage/v1/object/public/product-images/`;
          for (const ul of eventLists) applyEventCards(ul, events, { lang: cfg.lang, shopHref: cfg.shopHref, now: Date.now(), reserve, imageBase });
        }
      }
      // Nimet vasta kun vuororivit on lisätty. Katalogihaku yksin riittää: muut haut saavat epäonnistua.
      if (Array.isArray(catalog)) applyCatalogNames(document, catalog, namesLang);
    }).catch(() => { /* viikko-ohjelma, tapahtumakortit ja nimet ennallaan */ });
  }
}
