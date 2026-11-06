// Kassan osoite #/varaa/<rule_id>/<pvm>/<tuote_id>[?tuote=<slug>] (sama FI /varaa/ ja EN /en/book/).
// parts[1] on AINA vuorosäännön id (rule_id) ja parts[3] tuotteen id – ei törmäystä tuote- ja sääntö-id:iden välillä.
// Linkkikoulutus (category = 'training', channels ['link']) ei ole public_catalogissa: tuotesivu hakee sen public_product_by_slug-
// funktiolla muistiin. Refresh tyhjentää muistin, joten kassalinkkiin kulkee slug (?tuote=), jolla tuote haetaan uudelleen.
// Puhdas moduuli (testit: booking/tests/varaa-refresh-koulutus.test.mjs).
import { isTrainingCategory } from './training-dates.js';

/** Kassan hash-polku. Koulutuksille mukaan ?tuote=<slug>, muut ennallaan. */
export function checkoutPath(ruleId, ds, p) {
  const base = `/varaa/${ruleId}/${ds}/${p.id}`;
  return isTrainingCategory(p) && p.slug ? `${base}?tuote=${encodeURIComponent(p.slug)}` : base;
}

/**
 * Varmistaa, että kassan tuote on luettelossa. Puuttuva linkkikoulutus haetaan slugilla (fetchBySlug = public_product_by_slug)
 * ja lisätään luetteloon samoin kuin tuotesivulla. Vain jos haettu tuote on sama id ja category = 'training'. Palauttaa tuotteen tai null.
 */
export async function ensureCheckoutProduct(catalog, productId, slug, fetchBySlug) {
  const id = +productId;
  if (!Number.isFinite(id) || id <= 0) return null;
  const have = catalog.find((x) => +x.id === id);
  if (have || !slug || typeof fetchBySlug !== 'function') return have || null;
  const linked = await Promise.resolve().then(() => fetchBySlug(slug)).catch(() => null);
  if (!linked || +linked.id !== id || !isTrainingCategory(linked)) return null;
  const p = { ...linked, listed: false, deposit: true };
  catalog.push(p);
  return p;
}

/**
 * Kassan vuoro: haetaan tuotteen kuukausidatasta vuoro, jonka rule_id = ruleId päivänä ds. Linkin tuote-id käydään ensin;
 * kun se löytyy luettelosta, muita tuotteita ei käydä läpi (rule_id:tä ei tulkita tuote-id:ksi). Palauttaa { s, p } tai { s: null, p: null }.
 */
export async function findCheckoutSession(catalog, ruleId, ds, productId, loadMonth) {
  const order = [...catalog].sort((a, b) => (b.id === +productId) - (a.id === +productId));
  const [y, m] = String(ds).split('-').map(Number);
  for (const prod of order) {
    const byDay = await loadMonth(prod.id, y, m - 1).catch(() => ({}));
    const f = (byDay[ds] || []).find((r) => r.rule_id === +ruleId);
    if (f) return { s: f, p: prod };
    if (+productId === prod.id) break;
  }
  return { s: null, p: null };
}
