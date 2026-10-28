// Tuotekuvat: booking.public_product_images (hallinta). Polku bucketissa product-images.
// Build hakee listan; epäonnistuminen → content/kb/product-images.json. Ei kovakoodattuja markkinointikuvia.
import { readFileSync } from 'node:fs';
import { makeRpc } from './articles/source.mjs';

const FILE = new URL('../content/kb/product-images.json', import.meta.url);
const PATH_RE = /^products\/[0-9]{1,18}-[a-z0-9]{6,32}\.(jpg|jpeg|png|webp)$/;
const fileData = () => JSON.parse(readFileSync(FILE, 'utf8'));
let data = fileData();

const dimsOf = (path) => {
  const row = (fileData().images || []).find((x) => x.path === path);
  return row && row.width && row.height ? { width: row.width, height: row.height } : {};
};
const clean = (rows) => {
  if (!Array.isArray(rows)) return null;
  const images = [];
  for (const r of rows) {
    const path = String(r?.path || '');
    if (!r || typeof r.slug !== 'string' || !r.slug || !PATH_RE.test(path)) continue;
    images.push({ product_id: r.product_id ?? null, slug: r.slug, path, alt: r.alt ?? null, ...dimsOf(path) });
  }
  return images;
};

export const productImageFor = (slug) => (data.images || []).find((x) => x.slug === slug) || null;
export function productImageUrl(row) {
  if (!row?.path || !PATH_RE.test(row.path)) return '';
  const base = String(data.storage_base || '').replace(/\/$/, '');
  return base ? `${base}/${row.path}` : '';
}

export async function refreshProductImages({ env = process.env, log = console, rpc = null } = {}) {
  const url = (env.BOOKING_SUPABASE_URL || '').trim(), key = (env.BOOKING_ANON_KEY || '').trim();
  if (!url || !key) return { source: 'file', n: (data.images || []).length };
  try {
    if (!rpc) {
      if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url) && !/^http:\/\/localhost(:\d+)?$/.test(url)) throw new Error('BOOKING_SUPABASE_URL ei ole sallittu');
      rpc = makeRpc({ url, key });
    }
    const rows = await rpc('public_product_images', {});
    const images = clean(rows);
    if (!images) throw new Error('public_product_images ei palauttanut listaa');
    data = { ...fileData(), storage_base: `${url.replace(/\/$/, '')}/storage/v1/object/public/product-images`, images };
    log.log?.(`product-images: public_product_images; ${images.length} kuvaa`);
    return { source: 'rpc', n: images.length };
  } catch (err) {
    data = fileData();
    log.warn?.(`product-images: VAROITUS: haku epäonnistui (${err.message}); käytetään content/kb/product-images.json`);
    return { source: 'file', n: (data.images || []).length };
  }
}
