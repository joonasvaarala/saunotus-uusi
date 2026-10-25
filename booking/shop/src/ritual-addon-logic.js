// Saunarituaali yleisen vuoron lisäpalveluna (booking_166): DOM-riippumaton kaupan logiikka. Palvelin on ainoa totuus:
// tarjolla olevat ajat, vapaat paikat ja hinta tulevat funktiosta booking.public_ritual_addon(p_rule_id, p_date, p_persons),
// ja varaus lukitaan palvelimella (_ritual_addon_attach: aika, kapasiteetti ja hinta tarkistetaan uudelleen).
//
// AIKASÄÄNTÖ – yksi paikka: tietokannan asetus booking.settings.ritual_addon (oletus migraatiossa
// 20261024202015_booking_166_ritual_addon.sql) ja sen lukeva funktio booking._ritual_addon_starts(alku, loppu).
// Muutos: päivitä asetusta, esim. { "before_min": 30, "at_start": true, "first_after_min": 30, "step_min": 60, "at_end": true }.
// RITUAL_RULE_DEFAULTS + ritualStarts() alla ovat saman säännön peili mockia ja testejä varten (testi vertaa migraation oletukseen).
// booking_181 (20261025230602): rituaali alkaa vain klo 16.00, 16.30 tai 17.00 (time_window_rules 'ritual'.allowed_starts, sama kuin paketilla kb 7):
// ajat ovat näistä ne, jotka osuvat ikkunaan [alku − before_min, loppu) (+ loppu, jos at_end). Ilman listaa (allowed = null) vanha sääntö.
// Esimerkki: vuoro 16.00–18.00 → 16.00, 16.30, 17.00; vuoro 14.00–16.00 → 16.00; vuoro 17.00–19.00 → 16.30, 17.00.
export const RITUAL_ALLOWED_STARTS = Object.freeze(['16:00', '16:30', '17:00']);
export const RITUAL_RULE_DEFAULTS = Object.freeze({ enabled: true, product_id: 8, before_min: 30, at_start: true, first_after_min: 30, step_min: 60, at_end: true });
export const RITUAL_ERROR_CODES = Object.freeze(['ritual_addon_full', 'ritual_addon_time', 'ritual_addon_persons', 'ritual_addon_unavailable', 'ritual_addon_not_allowed', 'ritual_addon_invalid', 'ritual_addon_move']);
const MIN = 60e3;
const ms = (v) => (v instanceof Date ? v.getTime() : typeof v === 'number' ? v : Date.parse(v));

// Helsingin seinäkelloaika (päivä vuoron alusta + HH:MI) → ms
const helParts = (t) => Object.fromEntries(new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/Helsinki', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
  .formatToParts(new Date(t)).filter((p) => p.type !== 'literal').map((p) => [p.type, +p.value]));
function helAt(day, hm) {
  const [h, mi] = hm.split(':').map(Number), want = Date.UTC(day.year, day.month - 1, day.day, h, mi);
  let t = want;
  for (let i = 0; i < 2; i++) { const p = helParts(t); t += want - Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute); }
  return t;
}
/** Alkuajat (ms, nousevassa järjestyksessä, ei kaksoiskappaleita) vuorolle start–end; sama kuin booking._ritual_addon_starts. */
export function ritualStarts(start, end, rule = RITUAL_RULE_DEFAULTS, allowed = RITUAL_ALLOWED_STARTS) {
  const s = ms(start), e = ms(end), c = { ...RITUAL_RULE_DEFAULTS, ...(rule || {}) };
  if (!Number.isFinite(s) || !Number.isFinite(e) || e <= s) return [];
  if (Array.isArray(allowed) && allowed.length) {
    const day = helParts(s), lo = s - Math.max(+c.before_min || 0, 0) * MIN;
    return [...new Set(allowed.map((hm) => helAt(day, hm)))].filter((t) => t >= lo && (t < e || (t === e && !!c.at_end))).sort((a, b) => a - b);
  }
  const out = [];
  if (+c.before_min > 0) out.push(s - c.before_min * MIN);
  if (c.at_start) out.push(s);
  if (c.first_after_min != null && +c.first_after_min >= 0) {
    for (let t = s + c.first_after_min * MIN; t < e && out.length < 48; t += c.step_min * MIN) { out.push(t); if (!(+c.step_min > 0)) break; }
  }
  if (c.at_end) out.push(e);
  return [...new Set(out)].sort((a, b) => a - b);
}
/** Ajan sijainti vuoroon nähden (sama kuin palvelimen 'position'). */
export function positionOf(t, start, end) {
  const x = ms(t), s = ms(start), e = ms(end);
  return x < s ? 'before' : x === s ? 'start' : x >= e ? 'end' : 'during';
}
const int = (v) => (Number.isInteger(+v) && v !== null && v !== '' ? +v : null);

/**
 * Palvelimen vastaus → kaupan malli. Puuttuva funktio / virhe / ei aikoja → null (kauppa piilottaa lisäpalvelun).
 * Aika kelpaa vain, jos siihen mahtuu vähintään min_persons; ajat järjestetään. prices: { "1": 20, … } (palvelimen hinnat).
 */
export function normalizeOffer(r) {
  if (!r || r.ok !== true || r.available !== true || !Array.isArray(r.times)) return null;
  const min = Math.max(1, int(r.min_persons) ?? 1);
  const times = r.times.map((x) => ({ starts_at: x?.starts_at, ends_at: x?.ends_at, max: int(x?.max_persons) ?? 0, position: x?.position || null, key: Number.isFinite(ms(x?.starts_at)) ? new Date(ms(x.starts_at)).toISOString() : null }))
    .filter((x) => x.key && x.max >= min).sort((a, b) => ms(a.starts_at) - ms(b.starts_at));
  if (!times.length) return null;
  const prices = {};
  for (const [k, v] of Object.entries(r.prices && typeof r.prices === 'object' ? r.prices : {})) if (int(k) != null && Number.isFinite(+v)) prices[+k] = +v;
  const unit = Number.isFinite(+r.unit_price) ? +r.unit_price : null;
  return { product_id: int(r.product_id), name: r.name || '', name_en: r.name_en || '', unit_price: unit, prices, vat_rate: r.vat_rate ?? null, duration_minutes: int(r.duration_minutes),
    min_persons: min, max_persons: int(r.max_persons) ?? min, session_starts_at: r.session_starts_at || null, session_ends_at: r.session_ends_at || null, times };
}
/** Hinta q hengelle: palvelimen prices-taulukosta (ei omaa laskentaa); puuttuu → unit_price × q (vain näyttö, palvelin päättää). */
export function ritualPrice(offer, q) {
  if (!offer || !(q > 0)) return 0;
  if (offer.prices[q] != null) return offer.prices[q];
  return offer.unit_price != null ? Math.round(offer.unit_price * q * 100) / 100 : 0;
}
export const findTime = (offer, key) => (offer && key ? offer.times.find((x) => x.key === key) || null : null);
/** Osallistujat: 1 … min(vuoron henkilömäärä, ajan vapaat paikat); oletus = vuoron henkilömäärä (rajattuna). */
export function clampQty(q, offer, key, persons) {
  const t = findTime(offer, key); if (!t) return 0;
  const hi = Math.min(t.max, Math.max(1, +persons || 1)), lo = offer.min_persons;
  if (hi < lo) return 0;
  return Math.min(Math.max(int(q) ?? hi, lo), hi);
}
/**
 * Valinnan sovitus uuteen vastaukseen (henkilömäärä muuttui / haettiin uudelleen): sama aika jos yhä tarjolla, osallistujat rajataan.
 * → { key, qty, lost } ; lost = valittu aika ei ole enää tarjolla (kauppa näyttää ilmoituksen ja palaa "ei rituaalia" -tilaan).
 */
export function reconcile(sel, offer, persons) {
  if (!sel?.key) return { key: null, qty: 0, lost: false };
  const t = findTime(offer, sel.key);
  if (!t) return { key: null, qty: 0, lost: true };
  const qty = clampQty(sel.qty, offer, sel.key, persons);
  return qty > 0 ? { key: sel.key, qty, lost: false } : { key: null, qty: 0, lost: true };
}
/**
 * Kassan lisäpalvelukortti (Joonas 24.10.2026): määrävalitsin 0 … yläraja, aika valitaan alasvetovalikosta vasta kun määrä ≥ 1.
 * Yläraja = min(vuoron henkilömäärä, rituaalin max_persons, valitun ajan vapaat paikat); ennen ajan valintaa suurin yli tarjolla olevien aikojen.
 */
export function ritualMax(offer, key, persons) {
  if (!offer?.times?.length) return 0;
  const tm = key ? findTime(offer, key) : null;
  if (key && !tm) return 0;
  const cap = tm ? tm.max : Math.max(...offer.times.map((x) => x.max));
  const hi = Math.min(cap, Math.max(1, +persons || 1), offer.max_persons ?? cap);
  return hi < (offer.min_persons || 1) ? 0 : hi;
}
/** Kortin määrä: 0 = ei rituaalia; muuten min_persons … ritualMax (aika voi olla vielä valitsematta → key null). */
export function cardQty(q, offer, key, persons) {
  const v = int(q) ?? 0;
  if (v <= 0) return 0;
  const hi = ritualMax(offer, key, persons);
  return hi ? Math.min(Math.max(v, offer.min_persons || 1), hi) : 0;
}
/** Kortin valinnan sovitus uuteen vastaukseen: määrä säilyy (rajattuna); aika säilyy jos yhä tarjolla, muuten key = null ja lost. */
export function reconcileCard(sel, offer, persons) {
  const want = int(sel?.qty) ?? 0;
  if (want <= 0) return { key: null, qty: 0, lost: false };
  if (!offer) return { key: null, qty: 0, lost: true };
  const key = sel?.key && ritualMax(offer, sel.key, persons) > 0 ? sel.key : null;
  return { key, qty: cardQty(want, offer, key, persons), lost: !!sel?.key && !key };
}
/** p_addons-alkio palvelimelle: aika aikavyöhykkeen kanssa (UTC 'Z'), ei hintaa (palvelin hinnoittelee). */
export const ritualAddonArg = (sel) => (sel?.key && sel.qty > 0 ? { ritual_start: sel.key, quantity: sel.qty } : null);
/** Kassan koodin allekirjoitukseen: valinta mukaan → muutos tarkistaa koodin uudelleen. */
export const ritualSig = (sel) => (sel?.key && sel.qty > 0 ? `${sel.key}x${sel.qty}` : '-');
/** Vahvistussivu: vuoron rivi ja rituaalirivi(t) tilauksen riveistä (palvelin: items[].ritual_addon). */
export function splitItems(items) {
  const list = Array.isArray(items) ? items : [];
  const ritual = list.filter((i) => i && i.ritual_addon === true);
  const main = list.find((i) => i && i.ritual_addon !== true) || list[0] || null;
  return { main, ritual };
}
export const isRitualError = (code) => RITUAL_ERROR_CODES.includes(code);
