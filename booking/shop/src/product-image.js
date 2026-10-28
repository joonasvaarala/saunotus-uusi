// Tuotekuvien responsiiviset osoitteet. Julkinen Supabase Storage -muunnos
// (storage/v1/render/image) on käytössä tällä projektilla: 600 ja 900 px AVIF/WebP,
// JPEG-varakuva format=origin. resize=contain pitää kuvasuhteen (ei rajausta eikä venytystä).
// Paikallinen demo (ei *.supabase.co) käyttää alkuperäistä object-URL:ia.
// Artikkelikuvat eivät kulje tätä kautta (src/articles/images.mjs).

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

const esc = (s = '') => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

export function canTransform(objectUrl) {
  try {
    const u = new URL(objectUrl);
    return u.protocol === 'https:' && /(^|\.)supabase\.co$/.test(u.hostname) && u.pathname.includes('/storage/v1/object/public/');
  } catch { return false; }
}

function cleanWidths(widths) {
  return [...new Set((widths || []).map((n) => Math.round(+n)).filter((n) => n >= 1 && n <= 2500))].sort((a, b) => a - b);
}

/** object-URL → muunnettu URL. format: avif | webp | origin (JPEG-varakuva). */
export function transformUrl(objectUrl, { width, format = 'origin' } = {}) {
  if (!canTransform(objectUrl)) return objectUrl;
  const u = new URL(String(objectUrl).replace('/storage/v1/object/public/', '/storage/v1/render/image/public/'));
  u.searchParams.set('width', String(width));
  u.searchParams.set('resize', 'contain');
  u.searchParams.set('quality', String(QUALITY[format] ?? 75));
  u.searchParams.set('format', format === 'avif' || format === 'webp' ? format : 'origin');
  return u.toString();
}

export function srcsetFor(objectUrl, format, widths) {
  return cleanWidths(widths).map((w) => `${transformUrl(objectUrl, { width: w, format })} ${w}w`).join(', ');
}

/** { sources: [{type,srcset,sizes}], img: {src,srcset,sizes,alt,width,height,decoding,loading|fetchpriority} } */
export function productImageSpec(objectUrl, { widths = CARD_WIDTHS, sizes = SIZES.shop, alt = '', width = 600, height = 400, lazy = true } = {}) {
  const ws = cleanWidths(widths);
  const use = canTransform(objectUrl) && ws.length > 0;
  // src on alkuperäinen tiedosto: selain, joka ei ymmärrä srcsetiä, ja muunnosten vikaantuminen
  // (render/image pois käytöstä) näyttävät saman kuvan. picture/srcset-selain ei lataa src:iä.
  const img = {
    src: objectUrl,
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
