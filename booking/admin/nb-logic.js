// Uusi varaus -lomakkeen puhdas logiikka (ei DOMia, ei sb.js:ää) → node --test. Näkymä: views/newbooking.js.

// Lisäpalvelun enimmäismäärä: henkilömäärä × enintään/hlö (oletus 99), korkeintaan 99
export const addonLimit = (a, persons) => Math.min((a.max_per_person ?? 99) * Math.max(0, persons || 0), 99);

// Vuoron hinta henkilömäärälle (sama laskenta kuin palvelimella; näytetään vain arviona, palvelin laskee lopullisen)
export const priceFor = (s, n) => (s.price_mode === 'per_person' ? s.unit_price * n : s.price_mode === 'fixed' ? s.base_price : s.base_price + Math.max(0, n - (s.included_persons || 0)) * (s.extra_person_price || 0));

// Sallittu henkilömäärä: vähintään min_persons, enintään max_persons (oletus 50) ja vapaiden paikkojen määrä
export function personsRange(s) {
  const min = Math.max(1, +s.min_persons || 1);
  return { min, max: Math.min(+s.max_persons || 50, +s.remaining) };
}

// Asiakastyyppi, jonka mukaan laskun viite näytetään: valittu olemassa oleva asiakas ensin, muuten lomakkeen valinta
export const effectiveKind = (customer, formKind) => ((customer ? customer.customer_kind : formKind) === 'company' ? 'company' : 'private');

// Laskun viite (p_invoice_reference): VAIN yritysasiakkaalle; yksityisasiakkaalle aina null (kenttä piilossa ja tyhjennetty)
export const invoiceRefFor = (kind, raw) => (kind === 'company' ? String(raw ?? '').trim() || null : null);

// Maksutapa → oletus "maksettu jo": heti paikan päällä maksettavat tavat = maksettu; maksu myöhemmin / lasku / tilisiirto = ei
export const PAID_METHODS = ['cash', 'card_terminal', 'mobilepay'];
export const paidDefault = (code) => PAID_METHODS.includes(code);

// Oma hinta (€): tyhjä → automaattinen (null); muuten luku ≥ 0 (pilkku sallitaan), pyöristys senttiin
export function parsePrice(raw) {
  const t = String(raw ?? '').trim().replace(',', '.');
  if (!t) return { ok: true, value: null };
  if (!/^(\d+(\.\d{0,2})?|\.\d{1,2})$/.test(t)) return { ok: false, value: null };
  const n = Number(t);
  return Number.isFinite(n) && n >= 0 ? { ok: true, value: Math.round(n * 100) / 100 } : { ok: false, value: null };
}

// Hintayhteenveto: vuoro (automaattinen tai oma hinta) + lisäpalvelut = yhteensä; vuosikortti = 0
export function summary({ session, persons, override = { ok: true, value: null }, addons = 0, annualCard = false }) {
  if (annualCard) return { slot: 0, addons: 0, total: 0, overridden: false };
  const overridden = !!(override.ok && override.value != null);
  const slot = overridden ? override.value : priceFor(session, persons);
  return { slot, addons, total: Math.round((slot + addons) * 100) / 100, overridden };
}
