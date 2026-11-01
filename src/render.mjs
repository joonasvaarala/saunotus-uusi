// Sivupohjat ja komponentit. Kaikki palauttavat HTML-merkkijonoja; ei ajonaikaista JS:ää (paitsi pieni "tänään"-korostus).
import { readFileSync } from 'node:fs';
import { sortReviews } from './reviews-sort.mjs';
import { cards, alts, pageDoc } from './content-texts.mjs';
import { articlesNav, publishedArticleCount, homeSection } from './articles/runtime.mjs';
import { openingSummary } from './opening.mjs';
import { tx } from './site-texts.mjs';
import { seoSchemaForPage, jsonLdScript } from './seo-enhance.mjs';
import { PUBLISHED_GIFT_PACKAGES, GIFT_PACKAGE_IMAGE, giftMetaDescription } from '../booking/shop/src/gift-offers.js';
import { itemLines } from '../booking/shop/src/gift-logic.js';
import { gtText } from '../booking/shop/src/gift-texts.js';
import { privacyAnalyticsHtml, policyHasAnalyticsSection } from './privacy-analytics.mjs';
import { policyText, privacyDocFor, linkContacts } from './policy-lang.mjs';
import { quietWeekAttrs } from './quiet-week.mjs';
import { experienceHtml, traditionHtml, infoStrip, companyStrip, homeText, homeBookCta } from './home-front.mjs';
import { treatmentsBody } from './treatments-page.mjs';
import { faqFor, policyFor, eventTimeFor } from './kb-en.mjs';
import { selectShopEvents, shopEventsHtml, shopHash, eventWaitlistPath } from './event-cards.mjs';
import { EVENT_CARD_TEXTS } from './event-full-texts.mjs';
import { productCardInner } from './product-card-image.mjs';
import { testBannerEnabled, testBannerHtml, testBannerStyleTag } from './test-env-banner.mjs';
import {
  read, site, kb, images, e, href, pageHref, pagePath, abs, SITE_URL, BASE, isTest, chatbotOn,
  johku, bookingUrl, phoneDisplay, heroPicture, heroPreload, reviewsData, product, money, dur, priceOf, fromMode, picture, icon, hm,
} from './lib.mjs';
import { liveCatalogName } from './catalog-live.mjs';

const minifyCss = (src) => src
  .replace(/__BASE__/g, BASE)
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/\s*\n\s*/g, '\n').replace(/\n(?=[^@.\w#:*\[>+~-])/g, '\n').replace(/\s*([{};,>])\s*/g, '$1').replace(/;}/g, '}');
const css = minifyCss(readFileSync(new URL('./styles.css', import.meta.url), 'utf8'));
// Sisältöosion tyylit: upotetaan vain artikkelisivuille (layout seo.extraCss), ei muille sivuille
export const articlesCss = minifyCss(readFileSync(new URL('./articles/articles.css', import.meta.url), 'utf8'));
// Etusivun artikkeliosion tyylit: upotetaan vain etusivulle ja vain kun osio näytetään (layout extraCss)
export const homeArticlesCss = minifyCss(readFileSync(new URL('./articles/home.css', import.meta.url), 'utf8'));

export const ui = (lang) => site.ui[lang];
const alt = (id, lang) => alts[id]?.[lang] ?? '';
export const pic = (id, lang, o = {}) => picture(id, { alt: o.alt ?? alt(id, lang), ...o });
// Yläpalkin alarivi ("Sipoonjoen Perinnesauna", §18): teksti tekstitaulusta (nav.brand_tagline = {{setting:business_name}}); siirtymäaikana (avainta ei vielä tuotu) site.json:n brandTitle.
// Alarivi on osa etusivulinkin nimeä ("Saunotus Sipoonjoen Perinnesauna"), joten sitä ei piilotettu (ei aria-hidden).
const taglineWarned = new Set();
const headerTagline = (lang, u) => tx('nav.brand_tagline', lang, { fallback: u.brandTitle, log: { warn: (m) => { if (!taglineWarned.has(m)) { taglineWarned.add(m); console.warn(m); } } } });
const NEW = (lang) => `<span class="sr"> ${e(ui(lang).openNewTab)}</span>`;
const mailto = (subject = '') => `mailto:${site.contact.email}${subject ? '?subject=' + encodeURIComponent(subject) : ''}`;
const other = (lang) => (lang === 'fi' ? 'en' : 'fi');

// ---- linkit ----
export function link(to, lang, here) {
  if (/^https?:|^mailto:/.test(to)) return to;
  const [key, hash] = to.split('#');
  if (!key) return '#' + hash;
  if (key === here && hash) return '#' + hash;
  return pageHref(key, lang, hash);
}
const jk = (key, lang) => johku(key, lang);

// ---- hinnat ja ajat ----
const enTime = (t) => t.replace(/klo\s*/g, '').replace('saunotus alkaa', 'ritual starts at').replace(/\bpe\b/g, 'Fri').replace(/\bla–su\b/g, 'Sat–Sun').replace(/\bla\b/g, 'Sat').replace(/\bsu\b/g, 'Sun');
const WD_FI = ['su', 'ma', 'ti', 'ke', 'to', 'pe', 'la'];
const WD_EN = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MON_EN = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
function fmtDate(iso, lang) {
  const d = new Date(iso + 'T12:00:00Z');
  return lang === 'fi'
    ? `${WD_FI[d.getUTCDay()]} ${d.getUTCDate()}.${d.getUTCMonth() + 1}.${d.getUTCFullYear()}`
    : `${WD_EN[d.getUTCDay()]} ${d.getUTCDate()} ${MON_EN[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
}
export const todayHelsinki = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });

// ---- kortti ----
const extraFrom = (p) => {
  const m = /lisähenkilö(?:t)?\s*(\d+)/i.exec(p.price_text || '');
  return m ? +m[1] : null;
};
function metaItems(c, p, lang) {
  const out = [];
  const o = c.over || {};
  for (const k of c.show || []) {
    if (k === 'price') {
      const from = c.exact ? false : fromMode(p);
      const val = money(priceOf(p), lang);
      const txt = from ? `${ui(lang).fromWord} ${val}` : val;
      const per = p.price_type === 'per_person' ? ` <small>${e(ui(lang).perPersonShort)}</small>` : '';
      out.push(`<li class="pr">${e(txt)}${per}</li>`);
      if (c.extra) {
        const x = extraFrom(p);
        if (x) out.push(`<li><small>+ ${e(money(x, lang))} / ${e(ui(lang).extraGuest)}</small></li>`);
      }
    } else if (k === 'duration') {
      let t = o.duration?.[lang];
      if (!t && p.duration_minutes) {
        t = dur(p.duration_minutes);
        if (/^noin/i.test(p.duration_text || '')) t = `${ui(lang).approx} ${t}`;
      }
      if (t) out.push(`<li>${e(t)}</li>`);
    } else if (o[k]?.[lang]) {
      out.push(`<li>${e(o[k][lang])}</li>`);
    }
  }
  return out;
}
export function card(c, lang, opt = {}) {
  const p = c.kb ? product(c.kb) : null;
  const t = { ...c[lang] };
  // Nimi: public_catalog (hallinnan kb.products.name / name_en). Hinta, URL ja kortin teksti jäävät ennalleen.
  // Katalogia ei ole → kortin oma otsikko (cards.json / sivuteksti). Selain päivittää nimen uudelleen (data-catalog-name).
  const title = (c.kb && liveCatalogName(c.kb, lang)) || opt.title || t.title || '';
  const url = opt.url || (c.johku ? jk(c.johku, lang) : lang === 'en' && c.johkuEn ? jk(c.johkuEn, lang) : p ? bookingUrl(p.booking_url, lang) : jk('home', lang));
  const items = p ? metaItems(c, p, lang) : [];
  const list = t.list ? `<ul class="list">${[].concat(t.list).map((x) => `<li>${e(x)}</li>`).join('')}</ul>` : '';
  const sizes = opt.sizes || '(min-width:1100px) 280px, (min-width:640px) 45vw, 100vw';
  const fallback = c.img ? pic(c.img, lang, { sizes, alt: '' }) : '';
  const im = c.kb ? productCardInner({ slug: c.kb, alt: title, fallbackHtml: fallback, sizes }) : { attrs: '', html: fallback };
  const name = c.kb ? `<span data-catalog-name data-catalog-slug="${e(c.kb)}">${e(title)}</span>` : e(title);
  return `<li class="card"><div class="im"${im.attrs}>${im.html}${t.kicker ? `<span class="pill">${e(t.kicker)}</span>` : ''}</div>
<div class="bd"><h3><a href="${e(url)}" target="_blank" rel="noopener">${name}${NEW(lang)}</a></h3>
<p>${e(t.text)}</p>${list}${t.more ? `<details class="more"><summary>${e(ui(lang).moreInfo)}</summary><p>${e(t.more)}</p></details>` : ''}
${c.note || t.note ? `<p class="note">${e(c.note || t.note)}</p>` : ''}
${items.length ? `<ul class="meta">${items.join('')}</ul>` : ''}</div>
<div class="cta" aria-hidden="true">${e(t.cta || ui(lang).reserveArrow)}</div></li>`;
}
export const cardList = (arr, lang, cls = '', opt) => `<ul class="cards ${cls}">${arr.map((c) => card(c, lang, opt)).join('')}</ul>`;
export const C = (path) => path.split('.').reduce((a, k) => a[k], cards);

// ---- viikko-ohjelma (kb.opening_hours) ----
export function week(lang, opt = {}) {
  const u = ui(lang);
  const lab = (type, day) => site.sessionLabels[day >= 6 && type === 'public' ? 'weekend' : type]?.[lang] || '';
  // Yksi vuororivi: aika · nimi · Varaa-painike. Koko rivi on klikattava (a::after), .sr-selite säilyy. Rituaalilla aika, jos aukiolo on tiedossa.
  // Nimi: public_catalog, jos build haki sen; muuten sessionLabels (sivuteksti). Viikonpäivä on sarakkeen otsikossa, ei nimessä.
  // data-pid/data-open/data-close: viikko-ohjelma piilottaa täyden vuoron selaimessa (week-live.js). Kellonaika aina minuutteineen.
  // data-catalog-name: selain vaihtaa nimen tuoreeseen public_catalog-nimeen (quiet-week.js). Hakuvirhe → tämä teksti jää.
  const row = (time, name, url, day, meta = {}) => {
    const nameAttr = meta.pid ? ` data-catalog-name data-pid="${meta.pid}"${meta.slug ? ` data-catalog-slug="${e(meta.slug)}"` : ''}` : '';
    return `<li class="sess${time ? '' : ' nt'}"${meta.pid ? ` data-pid="${meta.pid}"` : ''}${meta.open ? ` data-open="${e(meta.open)}" data-close="${e(meta.close)}"` : ''}>${time ? `<span class="t">${time}</span>` : ''}<span class="n"${nameAttr}>${e(name)}</span><a class="bk" href="${e(url)}" target="_blank" rel="noopener"><span class="bk-l">${e(u.reserve)}</span><span class="sr"> – <span${nameAttr}>${e(name)}</span>, ${e(u.daysLong[day - 1])}</span>${NEW(lang)}</a></li>`;
  };
  const li = [];
  for (let d = 1; d <= 7; d++) {
    const rows = kb.hours.filter((h) => h.weekday === d);
    const clock = (t) => { const [hh, mm] = String(t).slice(0, 5).split(':'); return `${Number(hh)}${lang === 'en' ? ':' : '.'}${mm}`; };
    const metaFor = (h) => {
      const pr = kb.products.find((x) => x.id === h.product_id);
      const meta = h.opens && h.closes ? { pid: h.product_id, open: String(h.opens).slice(0, 5), close: String(h.closes).slice(0, 5) } : { pid: h.product_id };
      if (pr?.slug) meta.slug = pr.slug;
      return { pr, meta, name: (pr && liveCatalogName(pr.slug, lang)) || '' };
    };
    const sess = rows.filter((h) => h.opens && h.session_type !== 'ritual').map((h) => {
      const { pr, meta, name } = metaFor(h);
      return row(`${clock(h.opens)}–${clock(h.closes)}`, name || lab(h.session_type, d), pr ? bookingUrl(pr.booking_url, lang) : jk('publicAll', lang), d, meta);
    });
    const ritual = rows.filter((h) => h.session_type === 'ritual').map((h) => {
      const { pr, meta, name } = metaFor(h);
      const time = h.opens && h.closes ? `${clock(h.opens)}–${clock(h.closes)}` : '';
      return row(time, name || site.sessionLabels.ritual[lang], pr ? bookingUrl(pr.booking_url, lang) : jk('ceremonies', lang), d, meta);
    });
    const none = rows.some((h) => h.session_type === 'private_only')
      ? `<p class="none">${e(u.noPublic)}</p><ul class="alt"><li><a href="${e(jk('private', lang))}" target="_blank" rel="noopener">${e(u.privateLink)}${NEW(lang)}</a></li><li><a href="${e(jk('events', lang))}" target="_blank" rel="noopener">${e(u.eventsLink)}${NEW(lang)}</a></li></ul>` : '';
    const cls = [d >= 6 ? 'we' : '', none && !sess.length && !ritual.length ? 'off' : ''].filter(Boolean).join(' ');
    li.push(`<li data-wd="${d}"${cls ? ` class="${cls}"` : ''}><h3>${e(u.daysLong[d - 1])}<span class="today">${e(u.today)}</span></h3>${sess.length + ritual.length ? `<ul class="sl">${sess.join('')}${ritual.join('')}</ul>` : ''}${none}</li>`);
  }
  // booking_162: data-quiet-* → hiljaisten aikojen ale lisätään selaimessa (booking/shop/src/quiet-week.js); ilman tarjouksia ei muutosta
  return `<ol class="week${opt.soon ? ' soon' : ''}" aria-label="${e(u.weekTitle)}"${quietWeekAttrs(lang, { esc: e, products: kb.products, reserve: u.reserve })}>${li.join('')}</ol>`;
}

// ---- tapahtumat (kb.event_dates) ----
export function upcomingEvents(lang) {
  const today = todayHelsinki();
  const out = [];
  for (const [id, c] of Object.entries(cards.events)) {
    if (id.startsWith('_')) continue;
    const p = kb.products.find((x) => x.slug === (c.kb || id));
    if (!p) continue;
    const dates = kb.events.filter((ev) => ev.product_id === p.id && (ev.ends_on || ev.starts_on) >= today).sort((a, b) => a.starts_on.localeCompare(b.starts_on));
    if (!dates.length) continue;
    out.push({ c, p, dates });
  }
  return out.sort((a, b) => a.dates[0].starts_on.localeCompare(b.dates[0].starts_on));
}
// booking_158 / booking_210: uuden kaupan tapahtumat (kb.json events_shop = booking.public_events).
// Tulevat vapaat ja täydet kerrat. Täysi tapahtuma himmennetään; yksi kerta vie jonoon, useampi tuotesivulle.
// Kortti linkittää kauppaan (FI /varaa/#/…, EN /en/book/#/…), ei Johkuun.
// Selain korvaa listan tuoreella public_events-vastauksella (data-live-events). Hakuvirhe → tämä snapshot jää.
// Muuten (ei events_shop-dataa) vanha data (kb.event_dates + cards.json), linkki silti kaupan tuotesivulle.
const eventCardText = (key, lang) => tx(key, lang, { fallback: EVENT_CARD_TEXTS[key][lang] ?? EVENT_CARD_TEXTS[key].fi, log: { warn() {} } });
function shopEventsSection(lang, limit, empty) {
  let list = selectShopEvents(kb.events_shop, Date.now());
  if (!list.length) return null;
  if (limit) list = list.slice(0, limit);
  const cardOf = (ev) => Object.entries(cards.events).find(([id, c]) => !id.startsWith('_') && (c.kb || id) === ev.slug)?.[1] || null;
  const fallbackImg = Object.entries(cards.events).find(([id, c]) => !id.startsWith('_') && c.img)?.[1]?.img;
  const fullText = eventCardText('ui.site.event_full', lang);
  const fullCta = eventCardText('ui.site.event_waitlist', lang);
  return shopEventsHtml(list, lang, {
    e, money, card: cardOf, arrow: ui(lang).reserveArrow, fullText, fullCta, empty,
    link: (ev) => pageHref('book', lang, eventWaitlistPath(ev) || shopHash(ev.slug)),
    img: (ev) => {
      const sizes = '(min-width:1100px) 280px, 90vw';
      const id = cardOf(ev)?.img || fallbackImg;
      const fallback = id ? pic(id, lang, { sizes, alt: '' }) : '';
      return productCardInner({ slug: ev.slug, alt: '', fallbackHtml: fallback, sizes }).html;
    },
  });
}
export function eventsHtml(lang, empty, opt = {}) {
  const shop = shopEventsSection(lang, opt.limit, empty);
  if (shop) return shop;
  let ev = upcomingEvents(lang);
  if (opt.limit) ev = ev.slice(0, opt.limit);
  if (!ev.length) return `<p class="center">${e(empty)}</p>`;
  return `<ul class="events" data-live-events data-empty="${e(empty)}">${ev.map(({ c, p, dates }) => {
    const t = c[lang];
    const times = [...new Set(dates.map((d) => eventTimeFor(d, lang, enTime)).filter(Boolean))];
    const dl = dates.slice(0, 6).map((d) => fmtDate(d.starts_on, lang)).join(' · ');
    const evSizes = '(min-width:1100px) 280px, 90vw';
    const evIm = productCardInner({ slug: p.slug, alt: t.title || '', fallbackHtml: c.img ? pic(c.img, lang, { sizes: evSizes, alt: '' }) : '', sizes: evSizes });
    return `<li class="card ev"><div class="im"${evIm.attrs}>${evIm.html}<span class="badge">${e(money(p.price, lang))}</span></div>
<div class="bd"><h3><a href="${e(p.slug ? pageHref('book', lang, shopHash(p.slug)) : bookingUrl(p.booking_url, lang))}"${p.slug ? '' : ' target="_blank" rel="noopener"'}>${e(t.title)}${p.slug ? '' : NEW(lang)}</a></h3>
<p class="dates">${e(dl)}${times.length ? ' · ' + e(times[0]) : ''}</p><p>${e(t.text)}</p></div><div class="cta" aria-hidden="true">${e(ui(lang).reserveArrow)}</div></li>`;
  }).join('')}</ul>`;
}

// ---- yhteiset palaset ----
const sec = (cls, inner, id) => `<section class="section ${cls || ''}"${id ? ` id="${id}"` : ''}><div class="wrap">${inner}</div></section>`;
const head = (kicker, title, lead, o = {}) => `<header class="${o.left ? '' : 'center'}">${kicker ? `<p class="kicker">${e(kicker)}</p>` : ''}<h2 class="sec-title">${e(title)}</h2>${o.orn ? `<div class="divider">${icon('ikoni-ornamentti', 34)}</div>` : ''}${lead ? `<p class="lead">${e(lead)}</p>` : ''}</header>`;
export function pageHero(h, lang, here, o = {}) {
  const btns = (h.buttons || []).map((b, i) => `<a class="btn ${i === 0 ? 'gold' : 'ghost'}" href="${e(link(b.to, lang, here))}">${e(b.label)}</a>`).join('');
  return `<section class="hero page">${pic(h.img, lang, { eager: true, sizes: '100vw' })}<div class="wrap in"><h1>${e(h.title)}</h1><p>${e(h.text)}</p>${btns ? `<div class="actions">${btns}</div>` : ''}</div></section>`;
}
// ---- Google-arvostelut (content/reviews.json) ----
// "Nyt" Helsingin ajassa; REVIEWS_NOW (esim. 2026-12-01 tai ISO-aika) ohittaa testausta varten.
const nowDate = () => {
  const v = process.env.REVIEWS_NOW;
  const d = v ? new Date(v) : new Date();
  if (Number.isNaN(+d)) throw new Error('REVIEWS_NOW ei ole kelvollinen päiväys: ' + v);
  return d;
};
const helDay = (d) => new Date(d).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' }); // YYYY-MM-DD
// Suhteellinen ikä rakennushetken päivästä: <7 pv → päiviä (tänään/eilen), <5 vk → viikkoja, <12 kk → kuukausia, muuten vuosia.
export function reviewAge(published, lang, now = nowDate()) {
  const t = Date.parse(published || '');
  if (Number.isNaN(t)) return null;
  const [py, pm, pd] = helDay(t).split('-').map(Number), [ny, nm, nd] = helDay(now).split('-').map(Number);
  const days = Math.max(0, Math.round((Date.UTC(ny, nm - 1, nd) - Date.UTC(py, pm - 1, pd)) / 864e5));
  const a = ui(lang).reviews.age, f = (o, n) => (n === 1 ? o.one : o.other).replace('{n}', n);
  const months = Math.max(1, (ny - py) * 12 + (nm - pm) - (nd < pd ? 1 : 0));
  const text = days === 0 ? a.today : days === 1 ? a.yesterday : days < 7 ? f(a.day, days) : days < 35 ? f(a.week, Math.floor(days / 7)) : months < 12 ? f(a.month, months) : f(a.year, Math.floor(months / 12));
  const exact = lang === 'fi' ? `${pd}.${pm}.${py}` : `${pd} ${MON_EN[pm - 1]} ${py}`;
  return { text, exact, iso: helDay(t) };
}

// Kielen mukaiset arvostelut (stars>=4, teksti, uusin ensin). Alle min_per_lang → ei osiota lainkaan.
export function reviewsSection(lang, { compact = false, id } = {}) {
  const R = reviewsData;
  if (!R?.place) return '';
  const u = ui(lang).reviews;
  const all = sortReviews(R.reviews || []).filter((r) => r.lang === lang && r.stars >= 4 && String(r.text || '').trim());
  if (all.length < (R.min_per_lang ?? 3)) return '';
  const list = all.slice(0, compact ? 2 : R.max_per_lang ?? 4);
  const rating = String(R.place.rating).replace('.', lang === 'fi' ? ',' : '.');
  const count = `${R.place.count} ${u.count}`;
  const now = nowDate();
  const cards = list.map((r) => {
    const age = reviewAge(r.published, lang, now);
    const n = Math.min(5, Math.max(0, Math.round(r.stars)));
    const long = r.text.length > 280;
    return `<li><figure class="rv${long ? ' long' : ''}"><div class="rv-stars" role="img" aria-label="${e(u.stars.replace('{n}', n))}"><span aria-hidden="true">${'★'.repeat(n)}<i>${'★'.repeat(5 - n)}</i></span></div>`
      + `<blockquote class="rv-q"><p>${e(r.text)}</p></blockquote>`
      + (long ? `<details class="rv-more"><summary><span class="o">${e(u.more)}</span><span class="c">${e(u.less)}</span></summary></details>` : '')
      + `<figcaption><b>${e(r.author)}</b> <small>Google</small>${age ? ` <time datetime="${e(age.iso)}" title="${e(age.exact)}">${e(age.text)}</time>` : ''}</figcaption></figure></li>`;
  }).join('');
  const inner = `${head('', u.title, '', { orn: !compact }).replace('<h2 class="sec-title">', '<h2 class="sec-title" id="rv-h">')}`
    + `<p class="rv-sum"><span class="rv-star" aria-hidden="true">★</span> <strong>${e(rating)}</strong><span class="sr"> ${e(u.of)}</span> <span class="rv-cnt">· ${e(count)}</span></p>`
    + `<ul class="rv-grid">${cards}</ul>`
    + `<p class="center"><a class="btn light sm" href="${e(R.place.url)}" target="_blank" rel="noopener">${e(u.all)}${NEW(lang)}</a></p>`;
  return `<section class="section rv-sec${compact ? ' compact' : ''}" id="${id || (lang === 'fi' ? 'arvostelut' : 'reviews')}" aria-labelledby="rv-h"><div class="wrap">${inner}</div></section>`;
}

const mailBtn = (label, subject, cls = 'btn') => `<a class="${cls}" href="${e(mailto(subject))}">${e(label)}</a>`;
const HOME_FAQ = [3, 10, 8, 6];
function footerHours(lang) {
  const summary = openingSummary(kb.hours, ui(lang).days);
  if (!summary) return '';
  return `<p class="fhours">${e(ui(lang).footerOpen)} ${e(summary)}</p>`;
}

// ---- layout ----
function jsonLd(lang) {
  const b = kb.business;
  const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  // Aukiolo = viikko-ohjelman kaikki kellonajat (myös Turvetorstai), aikaisin alku → myöhäisin loppu per viikonpäivä.
  const padHm = (t) => { const x = hm(t); return x.includes(':') ? x : x + ':00'; };
  const byDay = new Map();
  for (const h of kb.hours) {
    if (!h.opens || !h.closes) continue;
    const opens = padHm(h.opens), closes = padHm(h.closes);
    const prev = byDay.get(h.weekday);
    if (!prev) byDay.set(h.weekday, { opens, closes });
    else { if (opens < prev.opens) prev.opens = opens; if (closes > prev.closes) prev.closes = closes; }
  }
  const spec = [...byDay.entries()].sort((a, b) => a[0] - b[0]).map(([wd, t]) => ({ '@type': 'OpeningHoursSpecification', dayOfWeek: days[wd - 1], opens: t.opens, closes: t.closes }));
  return JSON.stringify({
    '@context': 'https://schema.org', '@type': ['DaySpa', 'HealthAndBeautyBusiness'], '@id': abs('/#business'), name: b.trade_name, legalName: b.legal_name,
    url: SITE_URL + '/', telephone: site.contact.phoneTel, email: site.contact.email, image: abs('/img/og-hero-ovi-uusi.jpg'),
    address: { '@type': 'PostalAddress', streetAddress: b.street_address, postalCode: b.postal_code, addressLocality: b.city, addressCountry: 'FI' },
    openingHoursSpecification: spec, sameAs: site.social.map((s) => s.url), priceRange: '€€', inLanguage: lang,
  });
}
export function layout({ lang, key, meta, body, preload = '', robotsOnly = false, seo = null, extraCss = '' }) {
  const u = ui(lang);
  const path = pagePath(key, lang);
  // seo (valinnainen, sisältöosio): { url, hreflangs:[{hreflang,href}], robots, ogType, ogImage:{url,width,height,alt}, ogExtra, extraHead, extraCss, jsonLd:[object], switchHref, navCurrent }
  const url = seo?.url ?? abs(path);
  const alt_ = site.pages[key] || {};
  const hl = seo ? (seo.hreflangs || []).map((x) => `<link rel="alternate" hreflang="${e(x.hreflang)}" href="${e(x.href)}">`).join('')
    : ['fi', 'en'].filter((l) => alt_[l]).map((l) => `<link rel="alternate" hreflang="${l}" href="${abs(alt_[l])}">`).join('');
  const xdef = seo ? '' : (alt_.fi ? `<link rel="alternate" hreflang="x-default" href="${abs(alt_.fi)}">` : '');
  const og = seo?.ogImage?.url ?? abs(`/img/og-${meta.og || 'hero-ovi-uusi'}.jpg`);
  const ogSize = seo?.ogImage ? `<meta property="og:image:width" content="${seo.ogImage.width}"><meta property="og:image:height" content="${seo.ogImage.height}">${seo.ogImage.alt ? `<meta property="og:image:alt" content="${e(seo.ogImage.alt)}">` : ''}` : '<meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">';
  const o = other(lang);
  const switchHref = seo?.switchHref ?? (alt_[o] ? href(alt_[o]) : pageHref('home', o));
  const an = articlesNav(lang);
  const nav = u.nav.map(([k, label]) => {
    const h = k === 'training' ? site.trainingUrl : pageHref(k, lang);
    return `<a href="${e(h)}"${k === 'training' ? ' rel="noopener"' : ''}${k === key ? ' aria-current="page"' : ''}>${e(label)}${k === 'training' ? NEW(lang) : ''}</a>`;
  }).join('') + (an ? `<a href="${e(an.href)}"${seo?.navCurrent === 'articles' ? ' aria-current="page"' : ''}>${e(an.label)}</a>` : '');
  const bookHref = pageHref('book', lang);
  const langSw = `<div class="lang" role="group" aria-label="${e(u.langLabel)}">${['fi', 'en'].map((l) => (l === lang ? `<span aria-current="true">${l.toUpperCase()}</span>` : `<a href="${e(switchHref)}" hreflang="${l}" lang="${l}">${l.toUpperCase()}</a>`)).join('')}</div>`;
  const chat = chatbotOn
    ? `<div data-saunabot-quiz></div>\n<script src="${e(site.chatbot.widgetSrc)}" defer></script>`
    : `<!-- Saunabot (POIS KÄYTÖSTÄ – ei tuotantoon ennen OpenAI-avainta). Ota käyttöön: content/site.json chatbot.enabled = true.\n<script src="${site.chatbot.widgetSrc}" defer></script>\n<div data-saunabot-quiz></div>\n-->`;
  const fl = (k, l) => pageHref(k, l);
  const showBanner = testBannerEnabled();
  const bannerStyle = showBanner ? testBannerStyleTag('public') : '';
  const bannerOpen = showBanner ? `<div class="site-sticky">${testBannerHtml(lang)}` : '';
  const bannerClose = showBanner ? '</div>' : '';
  return `<!doctype html>
<html lang="${lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1${showBanner ? ',viewport-fit=cover' : ''}">
<title>${e(meta.title)}</title><meta name="description" content="${e(meta.description)}">
${isTest ? '<meta name="robots" content="noindex,nofollow">' : (seo?.robots ? `<meta name="robots" content="${e(seo.robots)}">` : '')}
<link rel="canonical" href="${e(url)}">${hl}${xdef}${seo?.extraHead || ''}
<meta property="og:type" content="${seo?.ogType || 'website'}"><meta property="og:site_name" content="${e(u.siteName)}"><meta property="og:title" content="${e(meta.title)}"><meta property="og:description" content="${e(meta.description)}"><meta property="og:url" content="${e(url)}"><meta property="og:image" content="${e(og)}">${ogSize}<meta property="og:locale" content="${u.locale}">${seo?.ogExtra || ''}
${alt_[o] && !seo ? `<meta property="og:locale:alternate" content="${ui(o).locale}">` : ''}<meta name="twitter:card" content="summary_large_image"><meta name="theme-color" content="#2B3A30">
<link rel="icon" href="${href('/img/favicon.svg')}" type="image/svg+xml">
<link rel="preload" href="${href('/fonts/Lato-normal-400.woff2')}" as="font" type="font/woff2" crossorigin>${preload}
<style>${css}${seo?.extraCss || ''}${extraCss}</style>${bannerStyle}
<script type="application/ld+json">${jsonLd(lang)}</script>${(seo?.jsonLd || []).map((j) => `<script type="application/ld+json">${JSON.stringify(j).replace(/</g, '\\u003c')}</script>`).join('')}${seo ? '' : seoSchemaForPage({ lang, key, url, body }).map(jsonLdScript).join('')}
</head><body>
<a class="skip" href="#main">${e(u.skip)}</a>
${bannerOpen}<header class="site-header"><div class="wrap hdr">
<a class="brand" href="${pageHref('home', lang)}"><img src="${href('/img/favicon.svg')}" width="27" height="37" alt=""><span class="brand-txt"><b>SAUNOTUS</b> <small>${e(headerTagline(lang, u))}</small></span></a>
<nav class="nav-desk" aria-label="${e(u.menuLabel)}">${nav}</nav>
${langSw}
<a class="btn sm" href="${bookHref}">${e(u.book)}</a>
<details class="nav-mob"><summary>${e(u.menu)}</summary><nav aria-label="${e(u.menuLabel)}">${nav}<a class="btn gold nav-cta" href="${bookHref}">${e(u.bookFull)}</a></nav></details>
</div></header>${bannerClose}
<main id="main" tabindex="-1">
${body}
</main>
<footer class="site-footer"><div class="wrap">
<div class="fgrid">
<div class="fbrand"><img src="${href('/img/favicon.svg')}" width="34" height="47" alt="" loading="lazy"><div><b>SAUNOTUS</b><small>${e(u.brandTitle)}</small><p>${e(u.footerTag)}</p>${footerHours(lang)}</div></div>
<div><h2>${e(u.footerServices)}</h2><ul><li><a href="${fl('sauna', lang)}">${e(u.nav[0][1])}</a></li><li><a href="${fl('treatments', lang)}">${e(u.nav[1][1])}</a></li><li><a href="${fl('gift', lang)}">${e(u.nav[3][1])}</a></li>${an ? `<li><a href="${e(an.href)}">${e(an.label)}</a></li>` : ''}<li><a href="${fl('companies', lang)}">${e(u.companies)}</a></li><li><a href="${e(site.trainingUrl)}" rel="noopener">${e(u.nav[2][1])}${NEW(lang)}</a></li><li><a href="${fl('book', lang)}">${e(u.bookFull)}</a></li></ul></div>
<div><h2>${e(u.footerInfo)}</h2><ul>${u.infoLinks.map(([id, l]) => `<li><a href="${pageHref('info', lang, id)}">${e(l)}</a></li>`).join('')}</ul></div>
<div><h2>${e(u.footerContact)}</h2><ul><li><address style="all:unset">${e(site.contact.street)}<br>${e(site.contact.postal)} ${e(site.contact.city)}</address></li><li><a href="tel:${site.contact.phoneTel}">${e(phoneDisplay(lang))}</a></li><li><a href="mailto:${site.contact.email}">${e(site.contact.email)}</a></li><li><a href="${e(site.contact.mapsUrl)}" rel="noopener">${e(ui(lang).directions)}${NEW(lang)}</a></li>${site.social.map((s) => `<li><a href="${e(s.url)}" rel="noopener">${e(s.name)}${NEW(lang)}</a></li>`).join('')}</ul></div>
</div>
<div class="fbottom"><p class="fpay"><span>${e(u.footerPayOnline)}</span><span class="fpay-marks">${['bank', 'card', 'apple-pay', 'google-pay', 'mobilepay'].map((id) => `<img src="${href(`/img/pay/${id}.svg`)}" alt="" height="18" width="${id === 'bank' || id === 'card' ? 18 : 48}" loading="lazy" decoding="async">`).join('')}</span></p><span>© ${new Date().getFullYear()} ${e(kb.business.legal_name)} · ${e(ui(lang).businessId)} ${e(kb.business.business_id)}</span><ul><li><a href="${fl('terms', lang)}">${e(u.legal)}</a></li><li>${pagePath('privacy', lang) ? `<a href="${fl('privacy', lang)}">${e(lang === 'en' ? privacyDocFor(P('privacy').fi, kb.policies, 'en')?.hero.title || u.privacy : u.privacy)}` : `<a href="${pageHref('privacy', 'fi')}"${lang === 'en' ? ' hreflang="fi" lang="fi"' : ''}>${e(u.privacy)}`}</a></li></ul></div>
</div></footer>
${chat}
<script>(function(){var d=new Intl.DateTimeFormat('en-US',{weekday:'short',timeZone:'Europe/Helsinki'}).format(new Date()),i={Mon:0,Tue:1,Wed:2,Thu:3,Fri:4,Sat:5,Sun:6}[d],l=document.querySelectorAll('.week>li');if(l[i]){l[i].classList.add('is-today');l[i].setAttribute('aria-current','date')}var n=l[(i+1)%7];if(n)n.classList.add('is-next');document.querySelectorAll('.week.soon').forEach(function(w){w.classList.add('is-filtered')})})()</script>
</body></html>`;
}

// ---- sivut ----
const P = pageDoc;

export const homeMeta = (lang) => P('home')[lang].meta;
export function home(lang, opt = {}) {
  const d = P('home')[lang], u = ui(lang);
  const hero = `<section class="hero home">${heroPicture({ alt: alt('hero-ovi-uusi', lang) })}<div class="wrap in"><h1>${e(d.hero.title)}</h1><p>${e(d.hero.text)}</p><div class="actions"><a class="btn gold" href="${pageHref('book', lang)}">${e(d.hero.cta1)}</a><a class="btn ghost" href="${pageHref('gift', lang)}">${e(d.hero.cta2)}</a></div></div></section>`;
  // Yksi tuoterivi (src/home-front.mjs): nimi, kuvaus, hinta ja kuva tuotteesta. home.jsonin tiles/featured/about jäävät tiedostoon (sivutekstit) mutta eivät renderöidy.
  const choose = sec('home-tight', experienceHtml(lang), 'valitse-elamys');
  const wk = sec('home-tight', `<div class="week-head">${head(u.weekKicker, u.weekTitle, '', { left: true })}<a class="btn light sm" href="${pageHref('sauna', lang, 'yleiset')}">${e(u.allSessions)}</a></div><div class="week-wrap"><p class="week-soon">${e(homeText('ui.site.home_week_soon', lang))}</p>${week(lang, { soon: true })}<details class="week-more"><summary class="btn light sm"><span class="o">${e(homeText('ui.site.home_week_all', lang))}</span><span class="c">${e(homeText('ui.site.home_week_less', lang))}</span></summary></details></div>`);
  const r = d.ritual;
  const tradition = sec('home-tight', traditionHtml(lang, { kicker: r.kicker, title: r.title, cta: r.cta, perPerson: u.perPerson }));
  const ev = sec('home-tight', `${head('', d.events.title, '', { orn: true })}${eventsHtml(lang, d.events.empty)}<p class="center" style="margin-top:22px"><a class="btn light sm" href="${pageHref('book', lang, '/?k=tapahtuma')}">${e(u.allEvents)}</a></p>`, 'tapahtumat');
  // Nauha vain kun kielellä on julkaistuja artikkeleita. Tyhjä lista ei saa jättää /saunatietoa/-linkkiä etusivulle.
  const art = opt.articlesHtml != null ? opt.articlesHtml : homeSection(lang);
  const infoStripSec = art || (publishedArticleCount(lang) > 0 ? sec('strip', infoStrip(lang), 'saunatietoa') : '');
  const co = d.company;
  const comp = sec('strip tint', companyStrip(lang, { title: co.title, cta: co.cta2, href: pageHref('companies', lang) }), 'yrityksille');
  const faqs = HOME_FAQ.map((id) => faqFor(id, lang)).filter(Boolean).map((f) => `<details${f.lang !== lang ? ` lang="${e(f.lang)}"` : ''}><summary>${e(f.question)}</summary><p>${e(clean(f.answer))}</p></details>`).join('');
  const faq = sec('faq home-tight', `<header class="center"><h2 class="sec-title">${e(u.faqKicker)}</h2></header><div class="narrow faq">${faqs}</div>`);
  const pre = heroPreload();
  const body = (opt.previewNote ? `<p class="prev-note" role="note">${e(opt.previewNote)}</p>` : '') + hero + choose + wk + tradition + reviewsSection(lang) + homeBookCta(lang) + ev + infoStripSec + comp + faq;
  return layout({ lang, key: 'home', meta: opt.meta || d.meta, preload: pre, body, seo: opt.seo || null, extraCss: art && String(art).includes('home-art') ? homeArticlesCss : '' });
}

export function sauna(lang) {
  const d = P('sauna')[lang], u = ui(lang);
  const pub = ['yleinen', 'miehet', 'naiset', 'hiljainen'].map((k) => C('sauna.' + k)).concat([C('treatments.turvetorstai')]);
  const priv = ['oma-vuoro', 'jalkiloylyt'].map((k) => C('sauna.' + k));
  const body = pageHero(d.hero, lang, 'sauna')
    + sec('', `${head('', d.publicTitle, d.publicIntro, { orn: true })}${week(lang)}<div style="height:36px"></div>${cardList(pub, lang, 'three')}`, 'yleiset')
    + sec('tint', `${head('', d.privateTitle, d.privateIntro, { orn: true })}${cardList(priv, lang, 'two')}<p class="center" style="margin-top:26px"><a class="btn light sm" href="${pageHref('companies', lang)}">${e(d.companyLink)}</a></p>`, 'yksityisvuorot')
    + sec('', `<p class="center lead"><a href="${pageHref('treatments', lang)}">${e(d.bridge)}</a></p>`);
  return layout({ lang, key: 'sauna', meta: d.meta, body });
}

export function treatments(lang) {
  const d = P('treatments')[lang];
  // Tuotekortit, polut, eteneminen ja UKK: src/treatments-page.mjs. Saunotusrituaali (kb 8) ei ole listalla (booking_159).
  const body = treatmentsBody(lang, { reviews: reviewsSection(lang) });
  return layout({ lang, key: 'treatments', meta: d.meta, body });
}

// Paketti edustaa viimeistä tuoteriviään (pelkkä vuoro → se vuoro; vuoro + hoito → hoito).
const packageSlug = (pkg) => {
  const ids = (pkg.items || []).map((i) => i.kb_product_id).filter((id) => id != null);
  const id = ids.length ? ids[ids.length - 1] : null;
  return id == null ? '' : (kb.products.find((p) => p.id === id)?.slug || '');
};
function giftOfferCard(p, lang) {
  const title = lang === 'en' ? p.name_en : p.name;
  const text = lang === 'en' ? (p.description_en || '') : (p.description || '');
  const lines = itemLines(p, lang, pageHref('book', lang));
  const list = lines.length ? `<ul class="list">${lines.map((row) => `<li>${row.href ? `<a href="${e(row.href)}">${e(row.label)}</a>` : e(row.label)}</li>`).join('')}</ul>` : '';
  const price = `${money(p.price, lang)} · ${gtText(lang, 'persons', { n: p.persons })}`;
  const unit = p.unit_price != null ? `<li><small>${e(gtText(lang, 'perPerson', { price: money(p.unit_price, lang) }))}</small></li>` : '';
  const sizes = '(min-width:1100px) 230px, 90vw';
  const im = productCardInner({ slug: packageSlug(p), alt: title, fallbackHtml: pic(GIFT_PACKAGE_IMAGE[p.code] || 'j-yleinen', lang, { sizes, alt: '' }), sizes });
  return `<li class="card" data-gift-package="${e(p.code)}"><div class="im"${im.attrs}>${im.html}<span class="pill">${e(gtText(lang, 'pkgKicker'))}</span></div>
<div class="bd"><h3>${e(title)}</h3>
<p>${e(text)}</p>${list}
<ul class="meta"><li class="pr">${e(price)}</li>${unit}<li>${e(gtText(lang, 'valid', { months: p.valid_months }))}</li></ul></div></li>`;
}
export function gift(lang) {
  const d = P('gift')[lang], u = ui(lang);
  const openPkg = PUBLISHED_GIFT_PACKAGES.find((p) => p.is_open);
  const ap = product(C('gift.avoin').kb);
  const from = priceOf(ap);
  if (+from !== +openPkg.min_amount) throw new Error(`avoin lahjakortti: kb ${from} €, julkaistu minimi ${openPkg.min_amount} €`);
  const pack = PUBLISHED_GIFT_PACKAGES.filter((p) => !p.is_open).map((p) => giftOfferCard(p, lang)).join('');
  const ext = d.extend;
  const meta = { ...d.meta, description: giftMetaDescription(lang) };
  const openSizes = '(min-width:900px) 520px, 100vw';
  const openIm = productCardInner({ slug: ap.slug, alt: openPkg[lang === 'en' ? 'name_en' : 'name'], fallbackHtml: pic(C('gift.avoin').img, lang, { sizes: openSizes, alt: '' }), sizes: openSizes });
  const body = pageHero(d.hero, lang, 'gift')
    + sec('', `<div class="company"><div><p class="kicker">${e(d.openTitle)}</p><h2 class="sec-title">${e(openPkg[lang === 'en' ? 'name_en' : 'name'])}</h2><p>${e(d.openText)}</p><p class="price" style="color:var(--gold)">${e(`${u.fromWord} ${money(from, lang)}`)}</p><a class="btn" href="${e(bookingUrl(ap.booking_url, lang))}" target="_blank" rel="noopener">${e(C('gift.avoin')[lang].cta)}${NEW(lang)}</a></div><div class="im"${openIm.attrs}>${openIm.html}</div></div>`, 'avoin')
    + sec('tint', `${head('', d.packTitle, '', { orn: true })}<ul class="cards five">${pack}</ul><p class="center" style="margin-top:24px"><a class="btn light sm" href="${e(jk('giftAll', lang))}" target="_blank" rel="noopener">${e(d.allGift)}${NEW(lang)}</a></p>`, 'paketit')
    + sec('', `${head('', d.haveTitle, d.haveText, { orn: true })}<div class="cards two" style="display:grid;gap:22px">
<article class="card"><div class="bd"><p class="kicker">${e(d.own.kicker)}</p><h3 style="font-family:var(--head);font-size:26px">${e(d.own.title)}</h3><p>${e(d.own.how || d.own.text)}</p><p><a class="btn" href="${e(jk('giftReservation', lang))}" target="_blank" rel="noopener">${e(d.own.cta)}${NEW(lang)}</a></p></div></article>
<article class="card"><div class="bd"><p class="kicker">${e(d.third.kicker)}</p><h3 style="font-family:var(--head);font-size:26px">${e(d.third.title)}</h3><p>${e(d.third.text)} <a href="${e(site.giftCardSupportUrl)}" rel="noopener">${e(d.third.link)}${NEW(lang)}</a>.</p><p>${e(d.third.pay || d.third.text2)}</p><p><a class="btn" href="${e(jk('giftReservation', lang))}" target="_blank" rel="noopener">${e(d.third.cta)}${NEW(lang)}</a></p></div></article></div>`, 'on-jo-lahjakortti')
    + sec('tint', `<div class="narrow center"><h2 class="sec-title">${e(ext.title)}</h2><p>${e(ext.text)}</p><p>${mailBtn(site.contact.email, ext.title, 'btn light sm')} <a class="btn light sm" href="tel:${site.contact.phoneTel}">${e(phoneDisplay(lang))}</a></p><p>${e(ext.third)}</p></div>`, 'jatkaminen');
  return layout({ lang, key: 'gift', meta, body });
}

export function book(lang) {
  const d = P('book')[lang], u = ui(lang);
  const rec = d.rec.map((r) => card(C(r.card), lang, { title: r.title, sizes: '(min-width:1100px) 360px, 90vw' })).join('');
  const body = pageHero(d.hero, lang, 'book')
    + sec('', `<p class="center lead">${e(d.note)}</p><ul class="chips">${d.chips.map((c) => `<li><a class="btn" href="${e(jk(c.url, lang))}" target="_blank" rel="noopener">${e(c.label)}${NEW(lang)}</a></li>`).join('')}</ul>`)
    + reviewsSection(lang, { compact: true })
    + sec('tint', `${head('', d.recTitle, d.recText, { orn: true })}<ul class="cards three">${rec}</ul>`)
    + sec('', `${head('', d.eventsTitle, '', { orn: true })}${eventsHtml(lang, P('home')[lang].events.empty)}`, 'tapahtumat');
  return layout({ lang, key: 'book', meta: d.meta, body });
}

// "Vanhan sivuston mukaan…" on toimitusmerkintä, ei asiakastekstiä. "esim." ei katkaise virkettä.
const clean = (s) => s.replace(/lisählöt/g, 'lisähenkilöt').replace(/esim\./g, 'esim\u0001').replace(/\s*Vanhan sivuston mukaan[^.]*\./g, '').replace(/\u0001/g, '.').replace(/\s+$/g, '');
export function info(lang) {
  const d = P('info')[lang], u = ui(lang);
  const blocks = (b) => b.map((x) => {
    if (x.p !== undefined) return `<p>${x.p}</p>${x.link ? `<p><a href="${e(x.link.url === 'hsl' ? site.contact.hslUrl : x.link.url)}" rel="noopener">${e(x.link.label)}${NEW(lang)}</a></p>` : ''}${x.mail ? `<p><a href="${e(mailto())}">${e(site.contact.email)}</a></p>` : ''}`;
    if (x.ul) return `<ul>${x.ul.map((i) => `<li>${e(i)}</li>`).join('')}</ul>`;
    if (x.note) return `<p class="note-box">${x.note}</p>`;
    if (x.address) return `<div class="loc"><address><strong>${e(kb.business.trade_name)}</strong><br>${e(site.contact.street)}, ${e(site.contact.postal)} ${e(site.contact.city)}<br><a href="${e(site.contact.mapsUrl)}" rel="noopener">${e(ui(lang).openInMaps)}${NEW(lang)}</a></address><figure class="loc-map"><img src="${href('/img/sijainti-kartta.jpg')}" width="800" height="400" alt="${e(`${site.contact.street}, ${site.contact.postal} ${site.contact.city}`)}" loading="lazy" decoding="async"><figcaption>${e(ui(lang).mapCredit)}</figcaption></figure></div>`;
    return '';
  }).join('');
  const secs = d.sections.map((s) => `<div class="info-sec" id="${s.id}"><div>${icon(s.icon, 40)}<h2>${e(s.title)}</h2><p class="tag">${e(s.tag)}</p></div><div>${blocks(s.blocks)}</div></div>`).join('');
  const faqs = d.faq.map((id) => faqFor(id, lang)).filter(Boolean).map((f) => `<details${f.lang !== lang ? ` lang="${e(f.lang)}"` : ''}><summary>${e(f.question)}</summary><p>${e(clean(f.answer))}</p></details>`).join('');
  const body = pageHero(d.hero, lang, 'info')
    + `<div class="wrap"><nav class="quick" aria-label="${e(d.hero.title)}">${d.sections.map((s) => `<a href="#${s.id}">${e(s.title)}</a>`).join('')}</nav></div>`
    + sec('', `<div class="infogrid">${secs}</div>`)
    + sec('tint', `<div class="narrow faq">${head(u.faqKicker, d.faqTitle, '', {})}${faqs}<div class="note-box"><strong>${e(d.cancelTitle)}.</strong> ${e(d.cancelText)} <a href="${pageHref('terms', lang)}">${e(d.cancelLink)}</a></div></div>`, 'ukk');
  return layout({ lang, key: 'info', meta: d.meta, body });
}

export function companies(lang) {
  const d = P('companies')[lang], u = ui(lang), f = d.flow;
  const offs = [
    ['ritual', f.offering_ritual], ['forest_yoga', f.offering_forest_yoga], ['campfire_meal', f.offering_campfire],
    ['sauna', f.offering_sauna], ['vihta_workshop', f.offering_vihta], ['other', f.offering_other],
  ];
  const errs = ['invalid_company', 'invalid_contact', 'invalid_email', 'invalid_phone', 'invalid_when', 'invalid_persons', 'invalid_offerings', 'invalid_offering_other', 'invalid_message', 'privacy_required', 'rate_limited', 'error_generic'];
  const choice = sec('', `<div class="narrow">${head('', f.choice_title, f.lead, { orn: true })}<div class="co-choice" data-company-choice>
<a class="card co-pick" href="#yritysvuorot" data-mode="sauna"><span class="bd"><h3>${e(f.sauna_title)}</h3><p>${e(f.sauna_text)}</p><span class="btn sm">${e(f.sauna_cta)}</span></span></a>
<a class="card co-pick" href="#tarjous" data-mode="day"><span class="bd"><h3>${e(f.day_title)}</h3><p>${e(f.day_text)}</p><span class="btn sm light">${e(f.day_cta)}</span></span></a>
</div></div>`);
  const cal = sec('tint', `${head('', f.calendar_title, f.calendar_text, { orn: true })}<div id="booking-app" aria-busy="true"><noscript><p>${e(f.calendar_noscript)} <a href="tel:${site.contact.phoneTel}">${e(phoneDisplay(lang))}</a></p></noscript></div>`, 'yritysvuorot');
  const fields = offs.map(([code, label]) => `<label><input type="checkbox" name="offering" value="${e(code)}"> ${e(label)}</label>`).join('');
  const messages = errs.map((code) => `<p class="co-msg" role="alert" hidden data-code="${code}">${e(code === 'error_generic' ? f.error_generic : f['error_' + code])}</p>`).join('')
    + `<p class="co-msg ok" role="status" hidden data-code="ok">${e(f.success)}</p>`;
  const form = sec('', `<div class="narrow"><h2 class="sec-title" tabindex="-1">${e(f.form_title)}</h2><p class="lead">${e(f.form_lead)}</p>
<form id="company-quote" class="co-form" data-locale="${e(lang)}" novalidate>
<div data-quote-fields>
<label>${e(f.company)} <input name="company_name" autocomplete="organization" required maxlength="160"></label>
<label>${e(f.contact)} <input name="contact_name" autocomplete="name" required maxlength="120"></label>
<label>${e(f.email)} <input name="email" type="email" autocomplete="email" required maxlength="254"></label>
<label>${e(f.phone)} <input name="phone" type="tel" autocomplete="tel" required maxlength="30"></label>
<label>${e(f.when)} <input name="preferred_when" required maxlength="160"></label>
<label>${e(f.persons)} <input name="persons" inputmode="numeric" required maxlength="3"></label>
<fieldset><legend>${e(f.offerings_legend)}</legend><div class="checks">${fields}</div>
<label>${e(f.offering_other_label)} <input name="offering_other" maxlength="200"></label></fieldset>
<label>${e(f.message)} <textarea name="message" maxlength="2000" rows="4"></textarea></label>
<div class="co-consent"><label class="check"><input type="checkbox" name="privacy" value="1"> ${e(f.privacy)}</label><a href="${pageHref('privacy', 'fi')}"${lang === 'en' ? ' hreflang="fi" lang="fi"' : ''}>${e(f.notice_link)}</a></div>
<p class="sr" aria-hidden="true"><label>${e(f.honeypot)} <input name="company_website" tabindex="-1" autocomplete="off"></label></p>
<button class="btn" type="submit">${e(f.submit)}</button>
</div>
${messages}
</form></div>`, 'tarjous');
  const links = sec('tint', `<ul class="cards three">${d.links.map((l) => `<li class="card"><div class="bd"><h3><a href="${e(link(l.to, lang, 'companies'))}">${e(l.title)}</a></h3><p>${e(l.text)}</p></div><div class="cta" aria-hidden="true">${e(u.readMore)}</div></li>`).join('')}</ul>`);
  const boot = `<script>document.documentElement.classList.add('co-js');(function(){var h=location.hash;if(h==='#tarjous')document.documentElement.classList.add('co-show-day');else if(h==='#yritysvuorot'||h.indexOf('#/')===0)document.documentElement.classList.add('co-show-sauna');})();</script>`;
  const body = pageHero(d.hero, lang, 'companies') + boot + choice + cal + form + links
    + `<script type="module" src="${href('/js/companies-form.js')}"></script>`;
  return layout({ lang, key: 'companies', meta: { title: d.meta.title, description: f.seo_description, og: d.meta.og }, body });
}

export function policyPage(name, key, lang) {
  const d = name === 'privacy' ? privacyDocFor(P(name).fi, kb.policies, lang) : P(name)[lang];
  // Tietosuojaseloste: privacy.json-listan rivit, EN vain title_en+body_en (policy-lang.mjs; muuten EN-sivua ei rakenneta).
  // Muut (ehdot): suomenkieliset id:t + _en (kb-en.mjs).
  const items = name === 'privacy'
    ? d.policies.map((id) => kb.policies.find((p) => p.id === id)).filter((p) => p && !p.internal).map((p) => policyText(p, lang) ?? policyText(p, 'fi'))
    : d.policies.map((id) => policyFor(id, lang)).filter(Boolean);
  // Tietosuojasivulla puhelin (tel:) ja sähköposti (mailto:) linkeiksi escapoidusta tekstistä (policy-lang.mjs linkContacts).
  const para = (l) => (name === 'privacy' ? linkContacts(e(l), site.contact) : e(l));
  const txt = (s) => clean(s).split(/\n+/).map((l) => {
    const line = l.trim();
    const n = name === 'privacy' && /^(\d+)\.\s+\S/.exec(line);
    return n ? `<h3 id="privacy-${n[1]}">${para(line)}</h3>` : `<p>${para(line)}</p>`;
  }).join('');
  const body = pageHero(d.hero, lang, key)
    + sec('', `<div class="narrow prose">${d.note ? `<p class="note-box">${e(d.note)}</p>` : ''}${items.map((p) => p.lang && p.lang !== lang ? `<div lang="${e(p.lang)}"><h2>${e(p.title)}</h2>${txt(p.body)}</div>` : `<h2>${e(p.title)}</h2>${txt(p.body)}`).join('')}${name === 'privacy' && !items.some((p) => policyHasAnalyticsSection(p.body)) ? privacyAnalyticsHtml(lang, e, txt) : ''}</div>`);
  return layout({ lang, key, meta: d.meta, body });
}

export function notFound() {
  const f = ui('fi'), n = ui('en');
  const meta = { title: `${f.notFoundTitle} | ${f.siteName}`, description: f.notFoundText, og: 'ovi-kaiverrus' };
  const body = sec('', `<div class="narrow center" style="padding:60px 0"><h1 class="sec-title">${e(f.notFoundTitle)}</h1><p>${e(f.notFoundText)}</p><p><a class="btn" href="${pageHref('home', 'fi')}">${e(f.toHome)}</a></p><h2 class="sec-title" style="font-size:26px;margin-top:40px">${e(n.notFoundTitle)}</h2><p>${e(n.notFoundText)}</p><p><a class="btn light" href="${pageHref('home', 'en')}">${e(n.toHome)}</a></p></div>`);
  let html = layout({ lang: 'fi', key: 'home', meta, body });
  html = html.replace(/<link rel="canonical"[^>]*>(<link rel="alternate"[^>]*>)*/, '').replace('<meta name="robots" content="noindex,nofollow">', '').replace('<meta name="description"', '<meta name="robots" content="noindex"><meta name="description"');
  return html;
}
