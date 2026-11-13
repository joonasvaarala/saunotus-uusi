// HALL-TALOUS-01 (UX-analyysi #345): Maksutavoittain-taulukon "Veroton"-sarake näytti bruttosumman (gross + refunds).
// Veroton = maksutavan kuittien brutto hyvitysten jälkeen − saman maksutavan ALV (by_method_vat, samat kuitit kuin by_method).
// Lahjakortin myynti on velkaa (ei ALV:tä), joten se jää verottomaan osuuteen kokonaan. Hintoja tai ALV-kantoja ei lasketa uudelleen.
const r2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

export function methodVat(byMethodVat, method) {
  return r2((byMethodVat || []).filter((x) => x.method === method).reduce((s, x) => s + (Number(x.vat) || 0), 0));
}

/** { method, gross, refunds } + by_method_vat → veroton summa hyvitysten jälkeen. */
export function methodNet(m, byMethodVat) {
  return r2((Number(m?.gross) || 0) + (Number(m?.refunds) || 0) - methodVat(byMethodVat, m?.method));
}

/** Yhteensä-rivi: kaikkien listattujen maksutapojen veroton summa. */
export function methodsNetTotal(methods, byMethodVat) {
  return r2((methods || []).reduce((s, m) => s + methodNet(m, byMethodVat), 0));
}
