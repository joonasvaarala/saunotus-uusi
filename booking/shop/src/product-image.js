// Tuotekuvien responsiiviset osoitteet. IMAGE_TRANSFORMS on oletuksena päällä:
// julkinen Supabase-objekti saa muunnetut leveydet (AVIF/WebP ja JPEG-varakuva format=origin).
// resize=contain pitää kuvasuhteen. Paikallinen demo ja IMAGE_TRANSFORMS=off käyttävät
// alkuperäistä object-osoitetta, ilman srcsetiä. Selain lukee window.BOOKING_CONFIG.imageTransforms
// (false vain kun buildissa asetus on pois). Artikkelien varapolku käyttää publicImageUrl().
// Muunnospolku kootaan osista, jotta pois kytketyn buildin tarkistus näkee vain valmiit osoitteet.

export const CARD_WIDTHS = Object.freeze([600, 900]);
export const HERO_WIDTHS = Object.freeze([900, 1600]);
export const THUMB_WIDTHS = Object.freeze([320]);

export const SIZES = Object.freeze({
  shop: '(min-width: 900px) 350px, 92vw',
  home: '(min-width: 1100px) 220px, 280px',
  hero: '100vw',
  thumb: '(max-width: 400px) 72px, 88px',
  upsell: '280px',
  sheet: '(min-width: 720px) 680px, 100vw',
});

const QUALITY = { avif: 50, webp: 75, origin: 75 };
const OBJECT_PUBLIC = '/storage/v1/object/public/';
const RENDER_PUBLIC = '/storage/v1/' + 'render' + '/image/public/';
const RENDER_MARK = '/storage/v1/' + 'render' + '/image/';
const OFF = /^(0|off|false|no)$/i;

const esc = (s = '') => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

function flagOn(value) {
  if (value === false || value === 0) return false;
  if (typeof value === 'string' && OFF.test(value.trim())) return false;
  return true;
}

/** Oletus päällä. Selain: BOOKING_CONFIG.imageTransforms. Node: IMAGE_TRANSFORMS. Testi voi antaa env/config. */
export function imageTransformsOn({ env, config } = {}) {
  const cfg = config !== undefined ? config : globalThis.window?.BOOKING_CONFIG;
  if (cfg && Object.prototype.hasOwnProperty.call(cfg, 'imageTransforms')) return flagOn(cfg.imageTransforms);
  const raw = (env !== undefined ? env : globalThis.process?.env)?.IMAGE_TRANSFORMS;
  if (raw == null || String(raw).trim() === '') return true;
  return flagOn(raw);
}

function useTransforms(opts) {
  if (opts && Object.prototype.hasOwnProperty.call(opts, 'transforms')) return flagOn(opts.transforms);
  return imageTransformsOn();
}

/** render-osoite → object/public. Muut osoitteet palautuvat samana merkkijonona. Transform-parametrit poistetaan, v säilyy. */
export function toPublicObjectUrl(url) {
  const s = String(url ?? '');
  if (!s.includes(RENDER_MARK)) return url;
  try {
    const u = new URL(s);
    u.pathname = u.pathname.replace(RENDER_MARK, '/storage/v1/object/');
    for (const k of ['width', 'height', 'resize', 'quality', 'format']) u.searchParams.delete(k);
    return u.toString();
  } catch {
    return s.split(RENDER_MARK).join('/storage/v1/object/');
  }
}

/** Sivulle kirjoitettava osoite. Muunnokset päällä: sama merkkijono. Pois: ei muunnettuja osoitteita. */
export function publicImageUrl(url, opts) {
  if (url == null || url === '') return url;
  return useTransforms(opts) ? url : toPublicObjectUrl(url);
}

function isTransformableUrl(objectUrl) {
  try {
    const u = new URL(objectUrl);
    return u.protocol === 'https:' && /(^|\.)supabase\.co$/.test(u.hostname) && u.pathname.includes(OBJECT_PUBLIC);
  } catch { return false; }
}

export function canTransform(objectUrl, opts) {
  return useTransforms(opts) && isTransformableUrl(objectUrl);
}

function cleanWidths(widths) {
  return [...new Set((widths || []).map((n) => Math.round(+n)).filter((n) => n >= 1 && n <= 2500))].sort((a, b) => a - b);
}

function renderUrl(objectUrl, { width, format = 'origin' } = {}) {
  const u = new URL(String(objectUrl).replace(OBJECT_PUBLIC, RENDER_PUBLIC));
  u.searchParams.set('width', String(width));
  u.searchParams.set('resize', 'contain');
  u.searchParams.set('quality', String(QUALITY[format] ?? 75));
  u.searchParams.set('format', format === 'avif' || format === 'webp' ? format : 'origin');
  return u.toString();
}

/** object-URL → muunnettu URL. format: avif | webp | origin (JPEG-varakuva). Pois päältä: object-osoite. */
export function transformUrl(objectUrl, spec = {}) {
  if (!canTransform(objectUrl, spec)) return useTransforms(spec) ? objectUrl : toPublicObjectUrl(objectUrl);
  const { width, format = 'origin' } = spec;
  return renderUrl(objectUrl, { width, format });
}

function srcsetFor(objectUrl, format, widths) {
  return cleanWidths(widths).map((w) => `${renderUrl(objectUrl, { width: w, format })} ${w}w`).join(', ');
}

/** { sources: [{type,srcset,sizes}], img: {src,srcset,sizes,alt,width,height,decoding,loading|fetchpriority} } */
export function productImageSpec(objectUrl, opts = {}) {
  const { widths = CARD_WIDTHS, sizes = SIZES.shop, alt = '', width = 600, height = 400, lazy = true } = opts;
  const on = useTransforms(opts);
  const ws = cleanWidths(widths);
  const use = on && isTransformableUrl(objectUrl) && ws.length > 0;
  // src on alkuperäinen tiedosto, kun muunnos on päällä: selain, joka ei ymmärrä srcsetiä, näyttää saman kuvan.
  // picture/srcset-selain ei lataa src:iä. Kun muunnos on pois, src on object-osoite eikä srcsetiä ole.
  const img = {
    src: on ? objectUrl : toPublicObjectUrl(objectUrl),
    alt: alt || '',
    width,
    height,
    decoding: 'async',
  };
  if (lazy) img.loading = 'lazy';
  else img.fetchpriority = 'high';
  const sources = [];
  if (use) {
    img.srcset = srcsetFor(objectUrl, 'origin', ws);
    img.sizes = sizes;
    for (const fmt of ['avif', 'webp']) sources.push({ type: `image/${fmt}`, srcset: srcsetFor(objectUrl, fmt, ws), sizes });
  }
  return { sources, img };
}

const ORDER = ['type', 'src', 'srcset', 'sizes', 'width', 'height', 'alt', 'loading', 'fetchpriority', 'decoding'];
const attr = (o) => ORDER.filter((k) => o[k] != null && o[k] !== false).map((k) => `${k}="${esc(o[k])}"`).join(' ');

export function productImageHtml(objectUrl, opts = {}) {
  const { sources, img } = productImageSpec(objectUrl, opts);
  const im = `<img ${attr(img)}>`;
  if (!sources.length) return im;
  return `<picture>${sources.map((s) => `<source ${attr(s)}>`).join('')}${im}</picture>`;
}

/** Selain: h() luo elementin. Aina <picture>, jotta hero- ja korttityylit osuvat. */
export function productImageElement(h, objectUrl, opts = {}) {
  const { sources, img } = productImageSpec(objectUrl, opts);
  const im = h('img', img);
  return h('picture', opts.pictureClass ? { class: opts.pictureClass } : {}, ...sources.map((s) => h('source', s)), im);
}

// Tiedostonimi on products/<tuote-id>-<tunnus>. Sama polku voi silti jäädä välimuistiin
// (muunnos-URL tai päällekirjoitus), joten osoitteeseen tulee versio: updated_at, tai polku jos sitä ei ole.
const IMAGE_PATH_RE = /^products\/[0-9]{1,18}-[a-z0-9]{6,32}\.(jpg|jpeg|png|webp)$/;

export function imageVersionOf(row) {
  if (!row) return '';
  const stamp = row.updated_at ?? row.image_updated_at;
  if (stamp != null && String(stamp).trim()) return String(stamp).trim();
  return row.path ? String(row.path) : '';
}

export function withImageVersion(objectUrl, version) {
  const v = version == null ? '' : String(version).trim();
  if (!objectUrl || !v) return objectUrl || '';
  try {
    const u = new URL(objectUrl);
    u.searchParams.set('v', v);
    return u.toString();
  } catch {
    const sep = String(objectUrl).includes('?') ? '&' : '?';
    return `${objectUrl}${sep}v=${encodeURIComponent(v)}`;
  }
}

/** Julkinen object-URL tuotekuvalle. Tyhjä, jos polku ei ole hallinnan sallimaa muotoa. */
export function liveImageUrl(imageBase, row) {
  const path = String(row?.path || '').replace(/^\//, '');
  if (!IMAGE_PATH_RE.test(path)) return '';
  const base = String(imageBase || '').replace(/\/$/, '');
  if (!base) return '';
  return withImageVersion(`${base}/${path.split('/').map(encodeURIComponent).join('/')}`, imageVersionOf(row) || path);
}

/** storageUrl()-osoite + versio. Tyhjä osoite pysyy tyhjänä. */
export function catalogImageUrl(objectUrl, row) {
  if (!objectUrl) return '';
  return withImageVersion(objectUrl, imageVersionOf(row) || row?.path || '');
}
