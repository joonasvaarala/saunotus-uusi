// Kuluttajan ja yritysten kalenteri: yksi asetus (product_config.audience).
// Jos kanta ei vielä palauta audience-kenttää (migraatio 71 ajamatta), category = corporate tulkitaan yritysvuoroksi,
// jotta lista on korjattavissa heti ja myöhemmin pelkällä näkyvyydellä.

export function productAudience(row) {
  const a = row?.audience;
  if (a === 'consumer' || a === 'business') return a;
  if (row?.category === 'corporate') return 'business';
  return 'consumer';
}

/** Jätä vain pyydetyn yleisön tuotteet. Tuntematon audience → consumer. */
export function pickCatalog(rows, audience = 'consumer') {
  const want = audience === 'business' ? 'business' : 'consumer';
  return (Array.isArray(rows) ? rows : []).filter((r) => productAudience(r) === want);
}
