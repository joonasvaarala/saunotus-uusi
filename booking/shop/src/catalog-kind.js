// Kaupan kategoriachipit ja päivänäkymän ryhmät.
// Tapahtuma on kb.products.category = 'event' (sale_kind yleensä 'other'). Se saa oman chipin
// eikä näy Yleisissä vuoroissa, Yksityisvuoroissa, Hoidoissa ja rituaaleissa eikä Muissa.
// Kaikki-chippi näyttää edelleen kaiken. Tyhjä kategoria ei saa chippiä eikä päivänäkymän otsikkoa.
// Järjestys on kiinteä: chipin paikka ei riipu katalogin sort_orderista.

export const CHIP_ORDER = ['yleinen', 'yksityinen', 'tapahtuma', 'muut', 'hoito'];
// Päivänäkymä: yksityisvuorot ensin, sitten yleiset, sitten tapahtumat. Hoidot lisätään näiden jälkeen.
export const DAY_KIND_ORDER = ['yksityinen', 'yleinen', 'tapahtuma', 'muut'];

export const kindOf = (p) => (p?.category === 'event' ? 'tapahtuma'
  : p?.treatment ? 'hoito'
  : p?.sale_kind === 'public_shift' ? 'yleinen'
  : p?.sale_kind === 'private_shift' ? 'yksityinen'
  : 'muut');

/** ['all', …vain ne chipit, joilla on vähintään yksi tuote], CHIP_ORDER-järjestyksessä. */
export const chipsFor = (products) => {
  const present = new Set((products || []).map(kindOf));
  return ['all', ...CHIP_ORDER.filter((k) => present.has(k))];
};

/**
 * Yrityskalenteri (audience business) ei näytä julkisia tapahtumia (category event).
 * Muu yleisö palauttaa saman taulukon, jotta katalogiin voi yhä työntää tapahtumia.
 */
export function productsForAudience(products, audience) {
  const list = Array.isArray(products) ? products : [];
  if (audience !== 'business') return list;
  return list.filter((p) => kindOf(p) !== 'tapahtuma');
}
