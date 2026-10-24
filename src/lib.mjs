// Apufunktiot: HTML-escape, hinnat, kuvat, linkit, kb-haku.
import { readFileSync } from 'node:fs';

export const read = (p) => JSON.parse(readFileSync(new URL('../' + p, import.meta.url), 'utf8'));

import { PHONE_DISPLAY_FI, PHONE_DISPLAY_EN, PHONE_TEL, phoneDisplay } from '../booking/shop/src/phone.js';
export { phoneDisplay };
import { resolvePrivacyPages } from './policy-lang.mjs';

// Puhelinnumero tulee yhdestä vakiosta (booking/shop/src/phone.js), ei site.json:sta: näkyvä muoto kielen mukaan (phoneDisplay(lang): fi "010 299 2866", en "+358 10 299 2866"), linkki tel:+358102992866.
// contact.phone = suomenkielinen muoto (oletus), contact.phoneEn = englanninkielinen; sivupohjat käyttävät phoneDisplay(lang).
const siteJson = read('content/site.json');
export const site = { ...siteJson, contact: { ...siteJson.contact, phone: PHONE_DISPLAY_FI, phoneEn: PHONE_DISPLAY_EN, phoneTel: PHONE_TEL } };
export const kb = read('content/kb/kb.json');
// /en/privacy/ vain kun kb.policies-kohdilla on title_en + body_en (src/policy-lang.mjs); muuten privacy.en = null.
site.pages = resolvePrivacyPages(site.pages, kb.policies, read('content/pages/privacy.json').fi.policies);
export const images = read('content/images.json');
export const hero = read('content/hero.json');
// Google-arvostelut (content/reviews.json); REVIEWS_FILE ohittaa tiedoston (testaukseen). Puuttuva tiedosto = ei arvosteluja.
export const reviewsData = (() => {
  const f = process.env.REVIEWS_FILE;
  try { return f ? JSON.parse(readFileSync(f, 'utf8')) : read('content/reviews.json'); } catch (err) { if (err.code === 'ENOENT') return null; throw err; }
})();

const env = process.env;
export const isTest = env.SITE_ENV === 'test';
// Julkinen osoite (canonical/hreflang/sitemap). Testissä GitHub Pages -osoite.
export const SITE_URL = (env.SITE_URL || (isTest ? site.testBase : site.canonicalBase)).replace(/\/$/, '');
// Polun etuliite (GitHub Pages -projektisivulla /saunotus-uusi)
export const BASE = new URL(SITE_URL).pathname.replace(/\/$/, '');
export const chatbotOn = env.SAUNABOT === 'on' || site.chatbot.enabled === true;

export const e = (s = '') => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
export const href = (p) => (/^(https?:|mailto:|tel:|#)/.test(p) ? p : BASE + p);
export const pagePath = (key, lang) => site.pages[key]?.[lang];
export const pageHref = (key, lang, hash = '') => href(pagePath(key, lang) + (hash ? '#' + hash : ''));
export const abs = (p) => SITE_URL + p;

export const johku = (key, lang) => site.booking.base + (site.booking[key] || '').replace('{loc}', site.ui[lang].johkuLoc);
// Johku-tuotelinkki kielen mukaan (kb:n booking_url on fi_FI)
export const bookingUrl = (url, lang) => (url ? url.replace('/fi_FI/', `/${site.ui[lang].johkuLoc}/`) : johku('home', lang));

// ---- kb ----
export const product = (slug) => {
  const p = kb.products.find((x) => x.slug === slug);
  if (!p) throw new Error('kb-tuotetta ei löydy: ' + slug);
  return p;
};
export const nf = (n) => (Number.isInteger(+n) ? String(+n) : String(+n).replace('.', ','));
export const money = (n, lang) => (lang === 'fi' ? `${nf(n)} €` : `€${String(+n)}`);
export const hm = (t) => t.slice(0, 5).replace(/^0/, '').replace(':00', '');
export const fiTime = (t) => hm(t);
export function dur(min, lang) {
  if (!min) return '';
  const h = Math.floor(min / 60), m = min % 60;
  const parts = [];
  if (h) parts.push(`${h} h`);
  if (m) parts.push(`${m} min`);
  return parts.join(' ');
}
export function priceOf(p) {
  if (p.price_type === 'variable') {
    const m = /(\d+)[,.]?\d*\s*[–-]/.exec(p.price_text || '');
    return m ? +m[1] : p.price;
  }
  return p.price;
}
export const fromMode = (p) => p.price_type === 'from' || p.price_type === 'variable';
export function priceLabel(p, lang, opts = {}) {
  const from = opts.from ?? fromMode(p);
  const val = money(opts.price ?? priceOf(p), lang);
  return from ? (lang === 'fi' ? `${site.ui.fi.fromWord} ${val}` : `${site.ui.en.fromWord} ${val}`) : val;
}
export const persons = (min, max, lang) => {
  if (!max) return '';
  const u = site.ui[lang].persons;
  return min && min !== max ? `${min}–${max} ${u}` : `${max} ${u}`;
};

// ---- kuvat ----
export function picture(id, { alt = '', sizes = '100vw', cls = '', eager = false, fetchpriority, width, height } = {}) {
  const m = images[id];
  if (!m) throw new Error('kuvaa ei löydy: ' + id);
  const set = (ext) => m.widths.map((w) => `${href(`/img/${id}-${w}.${ext}`)} ${w}w`).join(', ');
  const last = m.widths[m.widths.length - 1];
  return `<picture><source type="image/avif" srcset="${set('avif')}" sizes="${sizes}"><source type="image/webp" srcset="${set('webp')}" sizes="${sizes}"><img src="${href(`/img/${id}-${last}.webp`)}" width="${width || m.w}" height="${height || m.h}" alt="${e(alt)}"${cls ? ` class="${cls}"` : ''}${eager ? ' fetchpriority="' + (fetchpriority || 'high') + '"' : ' loading="lazy" decoding="async"'}></picture>`;
}
// Etusivun herokuva: <picture> mobiili (<720 px, 4:5) / desktop (leveä kaista). Mitat content/hero.json (scripts/optimize-hero.mjs).
export const HERO = { mobile: 'hero-ovi-uusi-mobiili', desktop: 'hero-ovi-uusi', bp: 719 };
const heroSet = (id, ext) => hero[id][ext].map((w) => `${href(`/img/${id}-${w}.${ext}`)} ${w}w`).join(', ');
export function heroPicture({ alt = '' } = {}) {
  const m = hero[HERO.mobile], d = hero[HERO.desktop];
  const mq = `(max-width:${HERO.bp}px)`, fmt = { avif: 'image/avif', webp: 'image/webp', jpg: 'image/jpeg' };
  const src = (id, x, o, media) => `<source${media ? ` media="${media}"` : ''} type="${fmt[x]}" srcset="${heroSet(id, x)}" sizes="100vw" width="${o.w}" height="${o.h}">`;
  const fb = d.jpg[d.jpg.length - 1];   // varakuva (JPEG) = img; mobiili-JPEG on oma <source media>, joten desktop-JPEG ei lataudu mobiilille
  return `<picture>${['avif', 'webp', 'jpg'].map((x) => src(HERO.mobile, x, m, mq)).join('')}${['avif', 'webp'].map((x) => src(HERO.desktop, x, d)).join('')}<img src="${href(`/img/${HERO.desktop}-${fb}.jpg`)}" srcset="${heroSet(HERO.desktop, 'jpg')}" sizes="100vw" width="${d.w}" height="${d.h}" alt="${e(alt)}" fetchpriority="high" decoding="async"></picture>`;
}
// preload oikealle kuvalle media-ehdolla (vain avif; webp-selaimet latautuvat <picture>-elementistä)
export const heroPreload = () => [[HERO.mobile, `(max-width:${HERO.bp}px)`], [HERO.desktop, `(min-width:${HERO.bp + 1}px)`]]
  .map(([id, mq]) => `<link rel="preload" as="image" type="image/avif" media="${mq}" imagesrcset="${heroSet(id, 'avif')}" imagesizes="100vw" fetchpriority="high">`).join('');
export const icon = (id, size = 48, alt = '') => {
  const m = images[id];
  const src = m ? href(`/img/${id}.webp`) : href(`/img/${id}.svg`);
  return `<img src="${src}" width="${size}" height="${size}" alt="${e(alt)}" loading="lazy" decoding="async" class="ico">`;
};
export const ext = (url, text, lang, cls = '') => `<a href="${e(url)}"${cls ? ` class="${cls}"` : ''} rel="noopener">${text}<span class="sr"> ${site.ui[lang].openNewTab}</span></a>`;
