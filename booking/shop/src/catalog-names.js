// Julkisen sivun tuotenimi = sama lähde kuin kaupalla: public_catalog().name / name_en
// (kb.products, hallinnan tuotelomake). Tyhjä tai puuttuva rivi → kutsujan staattinen teksti jää.
// Nimi kirjoitetaan textContentilla.
import { softenSpaces } from './text-spaces.js';

/** Sama valinta kuin shop.js pname: englanniksi name_en, muuten name. Sitova väli pehmenee. */
export function catalogDisplayName(row, lang) {
  if (!row || typeof row !== 'object') return '';
  const raw = lang === 'en' && row.name_en ? row.name_en : row.name;
  return softenSpaces(raw == null ? '' : String(raw)).trim();
}

/**
 * Korvaa [data-catalog-name]-elementtien tekstin katalogin nimellä.
 * Kohde tunnistetaan data-catalog-slug tai data-pid. Tuntematon tuote tai tyhjä nimi ei muuta tekstiä.
 * @returns {number} vaihdettujen nimien määrä
 */
export function applyCatalogNames(root, catalog, lang) {
  if (!root?.querySelectorAll || !Array.isArray(catalog)) return 0;
  const byId = new Map();
  const bySlug = new Map();
  for (const row of catalog) {
    if (!row || typeof row !== 'object') continue;
    if (row.id != null && row.id !== '') byId.set(String(row.id), row);
    if (typeof row.slug === 'string' && row.slug) bySlug.set(row.slug, row);
  }
  let n = 0;
  for (const el of root.querySelectorAll('[data-catalog-name]')) {
    const slug = el.getAttribute('data-catalog-slug') || '';
    const pid = el.getAttribute('data-pid') || '';
    const row = (slug && bySlug.get(slug)) || (pid && byId.get(pid)) || null;
    const name = catalogDisplayName(row, lang);
    if (!name || el.textContent === name) continue;
    el.textContent = name;
    n++;
  }
  return n;
}
