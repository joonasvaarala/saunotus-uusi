// Etusivun tuotekortit: sama lähde kuin kauppa (booking.public_catalog), buildissa.
// Haku epäonnistuu tai ympäristössä ei ole avainta → kb-snapshot (content/kb/kb.json). Build ei kaadu.
// Viikko-ohjelman ja tuotekortin nimi käyttää vain haettua riviä (liveCatalogName): ilman hakua jää staattinen teksti.
import { kb } from './lib.mjs';
import { makeRpc } from './articles/source.mjs';
import { catalogDisplayName } from '../booking/shop/src/catalog-names.js';

const FIELDS = ['name', 'name_en', 'description', 'description_en', 'short_description', 'short_description_en', 'price', 'price_type', 'price_text', 'duration_minutes', 'duration_text', 'duration_text_en'];
let bySlug = new Map();

export function setLiveCatalog(rows) {
  bySlug = new Map();
  if (!Array.isArray(rows)) return;
  for (const r of rows) if (r && typeof r.slug === 'string' && r.slug) bySlug.set(r.slug, r);
}
export const clearLiveCatalog = () => { bySlug = new Map(); };

/** public_catalog-nimi tälle slugille. Tyhjä, jos riviä ei haettu tai nimikenttä on tyhjä. */
export function liveCatalogName(slug, lang) {
  return catalogDisplayName(bySlug.get(slug), lang);
}

/** Tuote korteille: katalogin kentät peittävät kb-snapshotin, kun build haki public_catalogin. */
export function liveProduct(slug) {
  const base = kb.products.find((p) => p.slug === slug) || null;
  const live = bySlug.get(slug);
  if (!live) return base;
  const out = { ...(base || {}), slug };
  for (const k of FIELDS) if (live[k] != null && live[k] !== '') out[k] = live[k];
  if (out.price != null && out.price !== '') out.price = Number(out.price);
  if (out.duration_minutes != null && out.duration_minutes !== '') out.duration_minutes = Number(out.duration_minutes);
  return out;
}

export async function refreshLiveCatalog({ env = process.env, log = console, rpc = null } = {}) {
  const url = (env.BOOKING_SUPABASE_URL || '').trim(), key = (env.BOOKING_ANON_KEY || '').trim();
  if (!url || !key) return { source: 'kb', n: 0 };
  try {
    if (!rpc) {
      if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url) && !/^http:\/\/localhost(:\d+)?$/.test(url)) throw new Error('BOOKING_SUPABASE_URL ei ole sallittu');
      rpc = makeRpc({ url, key });
    }
    const rows = await rpc('public_catalog', {});
    if (!Array.isArray(rows)) throw new Error('public_catalog ei palauttanut listaa');
    setLiveCatalog(rows);
    log.log?.(`catalog: public_catalog; ${rows.length} tuotetta (etusivun kortit)`);
    return { source: 'rpc', n: rows.length };
  } catch (err) {
    clearLiveCatalog();
    log.warn?.(`catalog: VAROITUS: public_catalog epäonnistui (${err.message}); etusivun kortit käyttävät kb-snapshotia`);
    return { source: 'kb', n: 0 };
  }
}
