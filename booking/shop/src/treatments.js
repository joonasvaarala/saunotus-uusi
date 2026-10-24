// Hoito- ja rituaalivaraukset (resurssituotteet kb 10, 11, 12 ja rituaali kb 8): OHUT ADAPTERI palvelinrajapinnan ja käyttöliittymän välillä.
// Kaikki RPC-nimet, parametrit ja vastausmuodot on KERÄTTY TÄHÄN: kun Bottiavustuksen rajapintadokumentti (KOODARI_public_treatment_fi.md)
// muuttaa nimiä/kenttiä, muutos tehdään vain tähän tiedostoon (RPC-taulukko, args-funktiot ja normalisoijat). UI (treatment-ui.js) ei tunne RPC:itä.
// Rajapinnan puuttuminen ei ole virhe: tuotelista palauttaa [] ja kauppa näyttää hoitotuotteille "ota yhteyttä" (ks. loadProducts).
//
// Rajapinta: /workspace/johku/import/KOODARI_public_treatment_fi.md (booking_25). Hoitotuotteet tulevat public_catalog():sta (booking_kind = 'slots'); ne näkyvät vasta kun
// Tapio/Joonas asettaa tuotteille bookable + shop_visible -liput (lippuja ei muuteta tässä). Paikallinen mock: booking/shop/src/treatment-mock.js (vastaa dokumenttia).
import { rpc } from './sb.js';
import { normOptions, withOption, isOptionError } from './options-logic.js';
import { fmtMinutes } from './site-texts-logic.js';

const TZ = 'Europe/Helsinki';

export const RPC = {
  catalog: 'public_catalog',                      // booking_kind 'slots' = hoito/rituaali (valitaan aika), 'rules' = vanha vuoropohjainen
  availability: 'public_treatment_availability',  // (tuote, väli ≤ 14 pv, henkilömäärä) → vain vapaat alkuajat + total
  create: 'public_create_treatment_booking',
  get: 'public_get_booking',
  addons: 'public_addons',                         // lisäpalvelut (booking_61: pyyhe resurssivaraukselle)
  change: 'public_change_treatment_booking',      // vahvistussivu valitsee tämän get_bookingin change_via-kentästä
};
export const args = {
  availability: (p, persons, from, to) => ({ p_product_id: p.id, p_from: from, p_to: to, p_persons: persons }),
  // option (booking_50, sopimus §15): hoitovalinta p_option_code; lähetetään vain kun annettu (tuotteet ilman valitsinta toimivat ennallaan)
  // addons (booking_61, sopimus §18.11): p_addons = [{ id, quantity }]; lähetetään vain kun valittu (muuten vanha 12-parametrinen kutsu ennallaan)
  create: (p, { start, persons, name, email, phone, marketing, locale, note, kind, company, option, addons }) => ({
    ...withOption({ p_product_id: p.id, p_start: start, p_persons: persons, p_name: name, p_email: email, p_phone: phone, p_marketing_consent: !!marketing,
      p_locale: locale, p_note: note || null, p_customer_kind: kind, p_company: company || null }, option),
    ...(Array.isArray(addons) && addons.length ? { p_addons: addons.map((a) => ({ id: a.id, quantity: a.quantity })) } : {}) }),
  change: (token, { start, persons, option }) => withOption({ p_token: token, p_start: start ?? null, p_persons: persons ?? null }, option),
};
// Päätökset (Joonas), näytetään asiakkaalle vihjeenä; palvelin päättää viime kädessä (suljetut päivät, vapaat resurssit).
export const POLICY = {
  noFriday: true,
  weekday: { from: '16:00', to: '20:30' },     // ma–to (alkuaika ≥, loppu ≤)
  weekend: { from: '13:00', to: '20:30' },      // la–su
  ritualStarts: ['16:00', '16:30', '17:00'],    // rituaali kb 8: vain la–su, nämä alkuajat
  changeHoursBefore: 48,
  horizonDays: 14,                              // public_treatment_horizon_days (oletus; public_settings voi antaa tarkemman)
  maxRangeDays: 14,                             // yksi saatavuushaku: p_to − p_from enintään 14 pv (= 15 kalenteripäivää; oikea kanta hyväksyy tämän)
  cacheMs: 3 * 60e3,                            // saatavuuden välimuisti (haku 0,3–1,7 s; ei pollausta)
};
export const KB_IDS = [10, 11, 12, 8, 7];        // näytetään tässä järjestyksessä (tuntematon id → loppuun, ks. splitCatalog)
// Pakettituote kb 7 "Saunarituaali ja savusaunavuoro (la & su)" (booking_58, sopimus §17.11): sama aikavarauspolku kuin hoidoilla (slots, ruudukko 30 min), EI hoitovalitsinta.
// Aikajana tulee KANNASTA (booking_61, §18.11): public_catalog().timeline = [{ seq, kind, label, label_en, minutes, start_min, end_min }] sekä timeline_text(_en).
// Ei kovakoodattua aikajanaa: jos kenttää ei ole (vanha kanta / mock ilman kenttiä) tuote on tavallinen aikavaraustuote (ei aikajanaa eikä aikataulurivejä).
// Palvelin palauttaa timeline[]:ssä vain asiakkaalle näkyvät jaksot (booking_64: sisäinen tauko customer_visible=false jää pois); rituaali 0–20 ja savusauna 30–120, väliin jää 10 min ilman jaksoa.
// Varmuuden vuoksi jakso, jolla customer_visible === false, jätetään pois asiakkaalta. Taukojaksoa ei oleteta eikä suodateta nimellä.
// Kokonaiskesto ja loppuaika (alku + duration_minutes) tulevat palvelimelta. Jakson nimi = kannan label / label_en (ei kovakoodattuja nimiä).
const num0 = (v) => (v == null || v === '' || !Number.isFinite(+v) ? null : +v);
// kaikki jaksot alkuaikajärjestyksessä (customer_visible=false mukana, merkittynä); virheellinen aikajana → null.
// Yhtenäisyys (§18.11): jaksot ovat tuotteen keston sisällä ja aikajana päättyy tuotteen kestoon (summa voi olla pienempi: näkymättömät välit).
function allSegments(p) {
  const tl = Array.isArray(p?.timeline) ? p.timeline : null; if (!tl?.length) return null;
  const segs = tl.map((x, i) => ({ seq: num0(x?.seq) ?? i + 1, key: String(x?.kind || `seg${i + 1}`), label: x?.label || '', label_en: x?.label_en || '', min: num0(x?.minutes), start: num0(x?.start_min), end: num0(x?.end_min), hidden: x?.customer_visible === false }));
  if (segs.some((x) => !(x.min > 0) || x.start == null || x.start < 0)) return null;
  segs.sort((a, b) => a.seq - b.seq || a.start - b.start);
  const dur = num0(p?.duration_minutes), last = segs.reduce((m, x) => Math.max(m, x.end ?? x.start + x.min), 0);
  if (dur != null && (last !== dur || segs.some((x, i) => i && x.start < (segs[i - 1].end ?? segs[i - 1].start + segs[i - 1].min)))) return null;   // ei päällekkäisiä jaksoja, päättyy kestoon
  return segs;
}
// asiakkaalle näkyvät jaksot: [{ key (= kind), label, label_en, start, min, end }] tai null
export function timelineOf(p) {
  const v = (allSegments(p) || []).filter((x) => !x.hidden);
  return v.length ? v : null;
}
export const isPackage = (p) => !!timelineOf(p);
export const timelineLabel = (x, lang) => (lang === 'en' && x.label_en) || x.label;
// Kokonaiskesto: tuotteen kesto, muuten viimeisen jakson loppu (sisäinen väli mukana)
export const timelineMinutes = (p) => num0(p?.duration_minutes) ?? (allSegments(p) || []).reduce((end, x) => Math.max(end, x.end ?? x.start + x.min), 0);
// Aikajanan jaksot kellonaikoina alkuajasta: [{ key, label, label_en, start, min, end, from: 'HH:MM', to: 'HH:MM' }] (Helsingin aika)
export function timelineSlots(p, startIso) {
  const tl = timelineOf(p); if (!tl || !startIso) return [];
  const t0 = new Date(startIso).getTime();
  return tl.map((x) => ({ ...x, from: hmKey(new Date(t0 + x.start * 60e3).toISOString()), to: hmKey(new Date(t0 + (x.start + x.min) * 60e3).toISOString()) }));
}
// Aikajanateksti kielellä: kannan timeline_text(_en) sellaisenaan ("rituaali 20 min · savusauna 1 h 30 min"); puuttuu (tai aikajanassa on asiakkaalta piilotettuja jaksoja) → näkyvien jaksojen nimet + kestot.
// Tuote ilman aikajanaa → ''.
export function timelineText(p, lang) {
  const vis = timelineOf(p); if (!vis) return '';
  const raw = String((lang === 'en' ? p.timeline_text_en : p.timeline_text) || '').trim();
  const nb = (x) => x.replace(/ /g, '\u00a0');
  if (raw && !(allSegments(p) || []).some((x) => x.hidden)) return raw.split('·').map((x) => x.trim()).filter(Boolean).map(nb).join(' · ');
  return vis.map((x) => nb(`${timelineLabel(x, lang)} ${fmtMinutes(x.min)}`)).join(' · ');
}
// Varausikkuna (päiviä): public_settings().public_treatment_horizon_days (§18.11; nyt 14). POLICY.horizonDays on vain varalla vanhalle kannalle, jolla asetusta ei ole.
export const horizonDays = (settings) => +settings?.public_treatment_horizon_days || POLICY.horizonDays;
export const isRitual = (p) => p?.id === 8 || p?.category === 'ritual';

// Virhekoodit → i18n-avain (treatment-ui.js: tr.errors[avain]). Tuntematon koodi → yleisviesti. therapist_* koodeja ei koskaan näytetä asiakkaalle.
const ERR = {
  time_window: 'time_window', ritual_start: 'ritual_start', not_offered_day: 'not_offered_day',
  slot_unavailable: 'taken', bad_slot: 'taken', too_soon: 'too_soon', too_far: 'too_far', invalid_date: 'taken',
  rate_limited: 'rate_limited', busy: 'busy', booking_disabled: 'disabled', not_bookable: 'disabled',
  invalid_persons: 'persons', too_many_open: 'too_many_open', not_found: 'not_found',
  change_too_late: 'too_late', not_changeable: 'too_late', price_change_requires_staff: 'staff', invalid_change: 'nochange', use_treatment_change: 'too_late',
  option_required: 'option_required', invalid_option: 'invalid_option',
  invalid_email: 'contact', invalid_phone: 'contact', invalid_name: 'contact', invalid_note: 'contact', invalid_customer_kind: 'contact', vat_missing: 'contact',
};
export const errorKey = (code) => ERR[code] || 'generic';
export { isOptionError };
export const isSlotLost = (code) => ['taken', 'time_window', 'ritual_start', 'not_offered_day', 'too_soon'].includes(errorKey(code));
export const isRetryable = (code) => ['rate_limited', 'busy'].includes(code);

// ---- apurit ----
const hmKey = (iso) => new Intl.DateTimeFormat('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso));   // "17:00"
const dayKey = (iso) => new Date(iso).toLocaleDateString('sv-SE', { timeZone: TZ });
export const timeToken = (hhmm) => hhmm.replace(':', '');          // URL: 1700
export const timeFromToken = (tok) => (/^\d{4}$/.test(tok || '') ? `${tok.slice(0, 2)}:${tok.slice(2)}` : null);
const apiCode = (e) => e?.code || e?.details?.code || null;
const num = (v) => (v == null || v === '' ? null : +v);

// ---- lisäpalvelut (booking_61/64, §18.11): public_catalog().addons_enabled + allowed_addons[] (koodit), public_addons() + p_addons ----
// Tuotteen sallitut lisäpalvelut kertoo palvelin katalogissa (tuote 7: addons_enabled=true, allowed_addons=['pyyhe']); ei kovakoodattua tuotelistaa. Hinta, nimi ja enimmäismäärä
// haetaan AINA palvelimelta (public_addons). Kenttiä ei ole (vanha kanta) → ei lisäpalveluita.
export const allowedAddonCodes = (p) => (p?.addons_enabled === true && Array.isArray(p.allowed_addons) ? p.allowed_addons.map(String) : []);
export const addonsAllowed = (p) => allowedAddonCodes(p).length > 0;
export const ADDON_ERRORS = ['invalid_addons', 'addon_not_found', 'addon_inactive', 'addon_not_allowed', 'addon_quantity'];
export const isAddonError = (code) => ADDON_ERRORS.includes(code);
// virheen tekstiavain (§18.2: ui.<alue>.error_<RPC-koodi>)
export const errorTextKey = (code) => `ui.checkout.error_${code}`;
export const addonLimit = (a, n) => Math.min((a.max_per_person ?? 99) * Math.max(1, n), 99);   // sama kuin booking._addon_limit
export function normAddons(rows, allowed = null) {   // allowed: sallitut koodit (tuotteen allowed_addons); null = ei rajausta
  return (Array.isArray(rows) ? rows : []).filter((a) => a && a.id != null && (!allowed || allowed.includes(String(a.code))) && a.active !== false && num(a.price) != null)
    .map((a) => ({ id: +a.id, code: a.code, name: a.name, name_en: a.name_en, description: a.description, description_en: a.description_en, price: +a.price, max_per_person: num(a.max_per_person) }));
}
// Tuotteen lisäpalvelut; virhe / puuttuva funktio / ei sallittu tuote → [] (kassa toimii ilman lisäpalveluita)
export async function loadAddons(p) {
  if (!addonsAllowed(p)) return [];
  try { return normAddons(await rpc(RPC.addons, {}), allowedAddonCodes(p)); } catch { return []; }
}
// qty: Map<id, määrä> → [{ id, quantity }] (vain > 0) ja summa
export const addonsPayload = (addons, qty) => addons.filter((a) => (qty.get(a.id) || 0) > 0).map((a) => ({ id: a.id, quantity: qty.get(a.id) }));
export const addonsSum = (addons, qty) => addons.reduce((x, a) => x + (qty.get(a.id) || 0) * a.price, 0);

// ---- tuotteet ----
// Hoitotuotteet = public_catalog()-rivit, joilla booking_kind === 'slots' (piilotetut tuotteet eivät näy katalogissa). Katalogirivi täydennetään build-aikaisella
// kb-datalla (static-products.json: lisähenkilön hinta, kuvaus), jotta kortit ja hinta-arvio toimivat myös jos katalogi ei anna kaikkea.
// splitCatalog: jakaa jo haetun katalogin → { rules: vuoropohjaiset, treatments }. Ei booking_kind-kenttää (vanha kanta) → kaikki 'rules'.
export function splitCatalog(catalog, staticById) {
  const rules = [], treatments = [];
  for (const r of Array.isArray(catalog) ? catalog : []) {
    if (r?.booking_kind !== 'slots') { rules.push(r); continue; }
    const id = +r.id, st = staticById.get(id) || {};
    // booking_61 (§18.11): voucher_note(_en) = lahjakorttihuomautus (erillinen huomautus, ei kuvauksessa), timeline / timeline_text(_en) = aikajana kannasta, description_en = EN-kuvaus
    const o = Object.fromEntries(Object.entries({ name: r.name, name_en: r.name_en, description: r.description, description_en: r.description_en, price: num(r.price), price_type: r.price_type,
      duration_minutes: num(r.duration_minutes), duration_text: r.duration_text, capacity_min: num(r.min_persons), capacity_max: num(r.max_persons), category: r.category, slug: r.slug,
      voucher_note: r.voucher_note, voucher_note_en: r.voucher_note_en, addons_enabled: r.addons_enabled === true ? true : null, allowed_addons: Array.isArray(r.allowed_addons) && r.allowed_addons.length ? r.allowed_addons : null, timeline: Array.isArray(r.timeline) && r.timeline.length ? r.timeline : null, timeline_text: r.timeline_text, timeline_text_en: r.timeline_text_en })
      .filter(([, v]) => v != null && v !== ''));
    const no = normOptions(r);   // booking_50: options (aktiiviset), option_required, option_label(_en)
    treatments.push({ ...st, ...o, id, treatment: true, sale_kind: r.sale_kind, options: no.options, option_required: no.required, option_label: no.label, option_label_en: no.label_en });
  }
  const ord = (id) => { const i = KB_IDS.indexOf(id); return i < 0 ? KB_IDS.length : i; };   // tuntematon slots-tuote (uusi paketti) → listan loppuun, ei alkuun
  treatments.sort((a, b) => ord(a.id) - ord(b.id));
  return { rules, treatments };
}
// Vahvistussivu (ei kauppaa ladattuna): hae katalogi erikseen. Virhe → [] (muutos sähköpostilla).
export async function loadProducts(staticById) {
  try { return splitCatalog(await rpc(RPC.catalog, {}), staticById).treatments; } catch { return []; }
}
export const maxPersons = (p) => p.capacity_max || 1;
export const minPersons = (p) => p.capacity_min || 1;
// Hinta henkilömäärälle (palvelin laskee lopullisen; vastauksen total/price ohittaa tämän jos annettu)
export const priceFor = (p, n) => (p.price_type === 'per_person' ? p.price * n : p.price + Math.max(0, n - (p.included_persons || 1)) * (p.extra_person_price || 0));

// ---- vapaus ----
// → Map<'YYYY-MM-DD', [{ start: ISO, end: ISO, time: 'HH:MM', total }]> (järjestetty). Rivit: { session_date, starts_at, ends_at, status:'available', total, … } (vain vapaat alkuajat).
// Haku on raskas (0,3–1,7 s / 14 pv) → välimuisti (lupaus + TTL) tuote + henkilömäärä + väli -avaimella, väli pilkotaan ≤ 14 pv:n osiin, ei pollausta.
// Virhe (rate_limited, busy, bad_range) heitetään ApiErrorina (code = BK001-detail).
const cache = new Map();
export const clearCache = () => cache.clear();
const addDay = (ds, n) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
// Palvelin sallii vain yhden raskaan haun kerrallaan (rinnakkaiset haut → 'busy'): kaikki haut jonotetaan, 'busy' yritetään kerran uudelleen.
let activeRequests = 0;
const requestWaiters = [];
const concurrent = async (fn) => {
  if (activeRequests >= 2) await new Promise((resolve) => requestWaiters.push(resolve));
  activeRequests++;
  try { return await fn(); }
  finally { activeRequests--; requestWaiters.shift()?.(); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const callAvailability = (p, persons, from, to) => concurrent(async () => {
  for (let tries = 0; ; tries++) {
    try { return await rpc(RPC.availability, args.availability(p, persons, from, to)); }
    catch (e) { if (apiCode(e) !== 'busy' || tries >= 3) throw e; await sleep(750 * (tries + 1)); }
  }
});
function fetchChunk(p, persons, from, to) {
  const k = `${p.id}|${persons}|${from}|${to}`, hit = cache.get(k);
  if (hit && Date.now() - hit.at < POLICY.cacheMs) return hit.p;
  // jo haettu laajempi väli (esim. päivänäkymän koko ikkuna) kattaa tämän → ei uutta hakua
  for (const [ck, c] of cache) { if (ck.startsWith(`${p.id}|${persons}|`) && c.from <= from && c.to >= to && Date.now() - c.at < POLICY.cacheMs) return c.p.then((rows) => rows.filter((r) => (r.session_date || dayKey(r.starts_at)) >= from && (r.session_date || dayKey(r.starts_at)) <= to)); }
  const pr = callAvailability(p, persons, from, to).then((rows) => (Array.isArray(rows) ? rows : []));
  cache.set(k, { at: Date.now(), p: pr, from, to });
  pr.catch(() => cache.delete(k));
  return pr;
}
export async function loadAvailability(p, persons, from, to) {
  const rows = [];
  for (let a = from; a <= to; a = addDay(a, POLICY.maxRangeDays + 1)) rows.push(...await fetchChunk(p, persons, a, [addDay(a, POLICY.maxRangeDays), to].sort()[0]));
  const byDay = new Map();
  for (const r of rows) {
    const start = r.starts_at; if (!start) continue;
    if (r.status && r.status !== 'available') continue;
    const day = r.session_date || dayKey(start);
    // loppuaika: palvelimen ends_at; puuttuessa alku + kesto (rivin duration_minutes tai tuotteen kesto), ei arvata jos kestoa ei tiedetä
    const dur = num(r.duration_minutes) ?? num(p?.duration_minutes), end = r.ends_at || (dur ? new Date(new Date(start).getTime() + dur * 60e3).toISOString() : null);
    (byDay.get(day) || byDay.set(day, []).get(day)).push({ start, end, time: hmKey(start), total: num(r.total) });
  }
  for (const list of byDay.values()) list.sort((a, b) => a.start.localeCompare(b.start));
  return byDay;
}

// ---- varaus ----
const wrap = async (fn) => {
  try { const r = await fn(); if (r && r.ok === false) return { ok: false, code: r.code || 'generic', message: r.message }; return { ok: true, ...(r || {}) }; }
  catch (e) { return { ok: false, code: apiCode(e) || 'generic', message: e?.message, status: e?.status }; }
};
// → { ok:true, token, order_no } | { ok:false, code, message }
export const createBooking = (p, data) => wrap(async () => {
  const r = await rpc(RPC.create, args.create(p, data));
  clearCache();   // uusi varaus muuttaa saatavuutta
  return r;       // { ok:true, token, order_no, … } | { ok:false, code, message } (wrap)
});
export const changeBooking = (token, data) => wrap(async () => { const r = await rpc(RPC.change, args.change(token, data)); clearCache(); return r; });
// Vahvistussivun varaus (public_get_booking) on hoitovaraus, kun booking_kind = 'slots' tai change_via = 'public_change_treatment_booking'.
export const isTreatmentBooking = (b) => !!b?.items?.length && (b.booking_kind === 'slots' || b.change_via === RPC.change);
