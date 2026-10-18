// MOCK: hoito- ja rituaalivarausten rajapinta paikalliseen demoon ja testeihin (dev/server.mjs). EI tuotantoon eikä oikeaa tietokantaa vasten.
// Vastaa rajapintadokumenttia /workspace/johku/import/KOODARI_public_treatment_fi.md (booking_25) ja kaupan adapteria (shop/src/treatments.js); päivitä ne yhdessä. Pois päältä: TREATMENT_MOCK=0 (silloin funktioita ei ole → kauppa palaa "ota yhteyttä" -tilaan, kuten tuotannossa ennen rajapintaa).
// Säännöt (Joonas): hoidot yleisten saunavuorojen päivinä (ei perjantaisin), ei suljettuina päivinä; arkisin (ma–to) alku ≥ 16:00, la–su ≥ 13:00, loppu ≤ 20:30;
// rituaali (kb 8) vain la–su, alkuajat 16:00 / 16:30 / 17:00; saatavuus 14 pv, väli ≤ 14 pv, vähimmäisetumatka 120 min; yksi hoitohuone (Rauni) → hoidot eivät mene päällekkäin (15 min väli); rituaali max 6 hlö samaan aikaan.
// Demoa varten: päivän mod 11 = 0 on suljettu, osa päivistä on (deterministisesti) täynnä tai osittain varattu. Erikoistapaukset testeille:
// sähköposti taken@test.fi → slot_unavailable luotaessa; time_window@test.fi → time_window; locked@test.fi → varaus on jo alle 48 h päässä (can_change=false).
// Virhekäytäntö kuten oikeassa: saatavuus heittää BK001 (HTTP 400, koodi details-kentässä), varaus-/muutosfunktiot palauttavat HTTP 200 + {ok:false, code, message}.
// randomUUID: globalThis.crypto (Node 20+ ja selain; tätä moduulia käyttää myös kaupan ?mock=1-tila selaimessa, ks. shop/src/shop-mock.js)
const randomUUID = () => globalThis.crypto.randomUUID();

const TZ = 'Europe/Helsinki';
export const PRODUCTS = {
  10: { name: 'Saunahoito', minutes: 60, min: 1, max: 4, base: 99, extra: 35, included: 1, type: 'plus' },
  11: { name: 'Saunotus', minutes: 120, min: 1, max: 2, base: 210, extra: 60, included: 1, type: 'plus' },
  12: { name: 'Syväsaunotus', minutes: 180, min: 1, max: 2, base: 290, extra: 70, included: 1, type: 'plus' },
  8: { name: 'Saunotusrituaali', minutes: 20, min: 1, max: 6, base: 20, extra: 0, included: 0, type: 'person' },
};
// Tuotevalinta (booking_50, sopimus §15): Saunahoito (kb 10) vaatii hoidon valinnan; hinta ei muutu. Rivit kuten tuotannon seed (ei kuvauksia).
export const OPTIONS = {
  10: { required: true, label: 'Valitse hoito', label_en: 'Choose your treatment', options: [
    { id: 1, code: 'hunajahoito', name: 'Hunajahoito', name_en: 'Honey treatment', sort_order: 10, description: null, description_en: null, active: true },
    { id: 2, code: 'vihtahoito', name: 'Vihtahoito', name_en: 'Birch whisk treatment', sort_order: 20, description: null, description_en: null, active: true },
    { id: 3, code: 'suolahoito', name: 'Suolahoito', name_en: 'Salt treatment', sort_order: 30, description: null, description_en: null, active: true },
    { id: 4, code: 'turvehoito', name: 'Turvehoito', name_en: 'Peat treatment', sort_order: 40, description: null, description_en: null, active: true }] },
};
const activeOptions = (id) => (OPTIONS[id]?.options || []).filter((o) => o.active);
const optJson = (o) => (o ? { id: o.id, code: o.code, name: o.name, name_en: o.name_en } : null);
// → { ok:true, option: {…}|null } | { ok:false, code, message } ; code käsitellään lower(btrim()); required = pakollinen jos option_required JA aktiivisia vaihtoehtoja
function resolveOption(id, raw, { allowEmpty = false } = {}) {
  const code = String(raw ?? '').trim().toLowerCase(), act = activeOptions(id), required = !!OPTIONS[id]?.required && act.length > 0;
  if (!code) return required && !allowEmpty ? { ok: false, code: 'option_required', message: OPTIONS[id].label || 'Tee valinta' } : { ok: true, option: null };
  const o = act.find((x) => x.code === code);
  return o ? { ok: true, option: o } : { ok: false, code: 'invalid_option', message: 'Valittu hoito ei kelpaa' };
}
export const IMAGES = [[10, 'products/10-demo10xx.webp'], [11, 'products/11-demo11xx.webp'], [12, 'products/12-demo12xx.webp'], [8, 'products/8-demo08xx.webp']];
const RITUAL_STARTS = ['16:00', '16:30', '17:00'];
const GAP = 15 * 60e3, HOURS = 36e5, LEAD_MS = 120 * 60e3, HORIZON = 14, CHANGE_H = 48;
const bookings = new Map();   // token → varaus
let orderNo = 9000;

const pad = (n) => String(n).padStart(2, '0');
const helFmt = new Intl.DateTimeFormat('en-GB', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const helParts = (ms) => Object.fromEntries(helFmt.formatToParts(new Date(ms)).map((p) => [p.type, p.value]));
// Helsingin paikallinen aika (pvm + HH:MM) → UTC-millisekunnit
function helToMs(ds, hm) {
  const [y, m, d] = ds.split('-').map(Number), [H, M] = hm.split(':').map(Number);
  for (const off of [3, 2]) { const ms = Date.UTC(y, m - 1, d, H - off, M); const p = helParts(ms); if (+p.hour === H && +p.minute === M && +p.day === d) return ms; }
  return Date.UTC(y, m - 1, d, H - 2, M);
}
const dayOf = (ms) => { const p = helParts(ms); return `${p.year}-${p.month}-${p.day}`; };
const dow = (ds) => new Date(`${ds}T12:00:00Z`).getUTCDay();   // 0 = su
const hash = (s) => { let x = 7; for (const ch of s) x = (x * 31 + ch.charCodeAt(0)) >>> 0; return x; };
const toMin = (hm) => { const [H, M] = hm.split(':').map(Number); return H * 60 + M; };
const fromMin = (m) => `${pad(Math.floor(m / 60))}:${pad(m % 60)}`;
const addDays = (ds, n) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const price = (pr, n) => (pr.type === 'person' ? pr.base * n : pr.base + Math.max(0, n - pr.included) * pr.extra);

const dayOpen = (ds) => dow(ds) !== 5 && +ds.slice(8) % 11 !== 0;   // ei perjantaisin; suljetut päivät
// deterministiset osittaiset varaukset (muut asiakkaat / työvuorot): [alku, loppu] minuutteina
function busyBlocks(ds) {
  const k = hash(ds) % 6, we = [0, 6].includes(dow(ds));
  return k === 1 ? [[16 * 60, 18 * 60 + 15]] : k === 2 ? (we ? [[13 * 60, 16 * 60]] : [[18 * 60, 20 * 60 + 30]]) : k === 3 ? [[12 * 60, 21 * 60]] : k === 4 ? [[17 * 60, 19 * 60]] : [];
}
function windowOf(ds) { return dow(ds) === 0 || dow(ds) === 6 ? ['13:00', '20:30'] : ['16:00', '20:30']; }

// vapaat alkuajat yhdelle päivälle (skipToken: ohitetaan tämä varaus, kun sitä muutetaan)
function freeStarts(id, n, ds, now, skipToken) {
  const pr = PRODUCTS[id]; if (!pr || !dayOpen(ds)) return [];
  if (id === 8 && ![0, 6].includes(dow(ds))) return [];   // rituaali vain la–su
  const [from, to] = windowOf(ds);
  const starts = id === 8 ? RITUAL_STARTS : Array.from({ length: Math.floor((toMin(to) - pr.minutes - toMin(from)) / 30) + 1 }, (_, i) => fromMin(toMin(from) + i * 30));
  const mine = (b) => b.token !== skipToken && dayOf(b.start) === ds;
  const taken = [...bookings.values()].filter(mine);
  return starts.filter((hm) => {
    const s = helToMs(ds, hm), e = s + pr.minutes * 60e3;
    if (hm < from || toMin(hm) + pr.minutes > toMin(to)) return false;
    if (s < now + LEAD_MS) return false;
    for (const [a, b] of busyBlocks(ds)) if (s < helToMs(ds, fromMin(b)) + GAP && e + GAP > helToMs(ds, fromMin(a))) return false;
    let ritualPersons = 0;
    for (const b of taken) {
      const overlap = s < b.end + GAP && e + GAP > b.start;
      if (id === 8 && b.product_id === 8) { if (s < b.end && e > b.start) ritualPersons += b.persons; continue; }
      if (overlap) return false;
    }
    return !(id === 8 && ritualPersons + n > PRODUCTS[8].max);
  }).map((hm) => ({ hm, s: helToMs(ds, hm) }));
}

const err = (code, message, status = 400) => ({ status, body: { code: 'BK001', message, details: code, hint: null } });   // heitetty virhe (saatavuus)
const fail = (code, message) => ({ status: 200, body: { ok: false, code, message } });                                  // varausfunktiot
const ok = (body) => ({ status: 200, body });

function availability(a, now) {
  const id = +a.p_product_id, n = +a.p_persons, pr = PRODUCTS[id];
  if (!pr) return ok([]);
  if (!a.p_from || !a.p_to || a.p_to < a.p_from || (new Date(a.p_to) - new Date(a.p_from)) / 864e5 > 14) return err('bad_range', 'Virheellinen päiväväli (enintään 14 päivää)');
  if (!(n >= pr.min && n <= pr.max)) return ok([]);
  const rows = [], today = dayOf(now);
  for (let d = a.p_from; d <= a.p_to; d = addDays(d, 1)) {
    if (d < today || d > addDays(today, HORIZON)) continue;
    for (const { hm, s } of freeStarts(id, n, d, now)) rows.push({ product_id: id, session_date: d, starts_at: new Date(s).toISOString(), ends_at: new Date(s + pr.minutes * 60e3).toISOString(), duration_minutes: pr.minutes, status: 'available', persons: n, total: price(pr, n) });
  }
  return ok(rows);
}
function create(a, now) {
  const id = +a.p_product_id, n = +a.p_persons, pr = PRODUCTS[id];
  if (!pr) return fail('not_bookable', 'Tuote ei ole varattavissa');
  if (String(a.p_name || '').trim().length < 2) return fail('invalid_name', 'Anna nimi');
  if (!/^\S+@\S+\.\S+$/.test(String(a.p_email || ''))) return fail('invalid_email', 'Tarkista sähköpostiosoite');
  if (!/^[0-9+()\- ]{6,30}$/.test(String(a.p_phone || ''))) return fail('invalid_phone', 'Tarkista puhelinnumero');
  if (!(n >= pr.min && n <= pr.max)) return fail('invalid_persons', 'Virheellinen henkilömäärä');
  if (a.p_email === 'time_window@test.fi') return fail('time_window', 'Aika on hoitoikkunan ulkopuolella');
  const s = Date.parse(a.p_start); if (!Number.isFinite(s)) return fail('bad_slot', 'Virheellinen alkuaika');
  const ds = dayOf(s), p = helParts(s), hm = `${p.hour}:${p.minute}`;
  if (a.p_email === 'taken@test.fi' || !freeStarts(id, n, ds, now).some((x) => x.hm === hm)) return fail('slot_unavailable', 'Aika ei ole enää vapaana');
  const opt = resolveOption(id, a.p_option_code); if (!opt.ok) return fail(opt.code, opt.message);   // ennen luontia: ei sivuvaikutuksia virheessä
  const token = randomUUID(), total = price(pr, n);
  bookings.set(token, { token, option: opt.option, order_no: ++orderNo, product_id: id, start: s, end: s + pr.minutes * 60e3, persons: n, total, kind: a.p_customer_kind || 'private', name: a.p_name, email: a.p_email, note: a.p_note, locked: a.p_email === 'locked@test.fi' });
  return ok({ ok: true, order_no: orderNo, token, status: 'confirmed', starts_at: new Date(s).toISOString(), ends_at: new Date(s + pr.minutes * 60e3).toISOString(), persons: n, total,
    payment_mode: a.p_customer_kind === 'company' ? 'invoice' : 'pay_later', payment_url: null, hold_expires_at: null, product_name: pr.name, option: optJson(opt.option), customer_kind: a.p_customer_kind || 'private', booking_kind: 'slots' });
}
// booking_52: valitsimen otsikko vastauksessa (items[].option_label tilauksen kielellä = fi, option_label_fi / option_label_en); tuote ilman otsikkoa → null
const optLabels = (id) => { const o = OPTIONS[id]; return { option_label: o?.label || null, option_label_fi: o?.label || null, option_label_en: o?.label_en || o?.label || null }; };
function getBooking(a, now) {
  const b = bookings.get(a.p_token); if (!b) return null;   // ei mock-varaus → oikea funktio
  const deadline = b.start - CHANGE_H * HOURS;
  return ok({ ok: true, order_no: b.order_no, status: 'confirmed', payment_status: 'unpaid', total: b.total, currency: 'EUR', created_at: new Date(now).toISOString(), first_name: String(b.name).split(' ')[0],
    customer_kind: b.kind, items: [{ product_name: PRODUCTS[b.product_id].name, quantity: 1, line_total: b.total, vat_rate: 25.5, product_id: b.product_id, rule_id: null, starts_at: new Date(b.start).toISOString(),
      ends_at: new Date(b.end).toISOString(), persons: b.persons, mode: 'treatment', status: 'confirmed', hold_expires_at: null, option: optJson(b.option), ...optLabels(b.product_id) }], addons: [], payment_methods: [],
    booking_kind: 'slots', change_via: 'public_change_treatment_booking', can_change: !b.locked && deadline >= now, change_deadline: new Date(deadline).toISOString(), change_hours_before: CHANGE_H });
}
function change(a, now) {
  const b = bookings.get(a.p_token); if (!b) return null;
  if (b.locked || b.start - CHANGE_H * HOURS < now) return fail('change_too_late', 'Muutos vähintään 48 h ennen alkua');
  const n = a.p_persons == null ? b.persons : +a.p_persons, pr = PRODUCTS[b.product_id];
  const optChange = a.p_option_code != null && String(a.p_option_code).trim() !== '';
  if (a.p_start == null && a.p_persons == null && !optChange) return fail('invalid_change', 'Ei muutettavaa');
  let newOpt = b.option;
  if (optChange) { const o = resolveOption(b.product_id, a.p_option_code); if (!o.ok) return fail(o.code, o.message); newOpt = o.option; }
  if (!(n >= pr.min && n <= pr.max)) return fail('invalid_persons', 'Virheellinen henkilömäärä');
  const s = a.p_start ? Date.parse(a.p_start) : b.start, ds = dayOf(s), p = helParts(s);
  const timeChange = a.p_start != null || a.p_persons != null;
  if (timeChange && s - CHANGE_H * HOURS < now) return fail('change_too_late', 'Uuden ajan pitää alkaa vähintään 48 h päästä');
  if (timeChange && !freeStarts(b.product_id, n, ds, now, b.token).some((x) => x.hm === `${p.hour}:${p.minute}`)) return fail('slot_unavailable', 'Aika ei ole enää vapaana');
  Object.assign(b, { option: newOpt }, timeChange ? { start: s, end: s + pr.minutes * 60e3, persons: n, total: price(pr, n) } : {});   // pelkkä hoidon vaihto: aika ja hinta ennallaan
  return ok({ ok: true, order_no: b.order_no, starts_at: new Date(b.start).toISOString(), ends_at: new Date(b.end).toISOString(), persons: b.persons, total: b.total, option: optJson(b.option) });
}

// → { status, body } tai null (= ei mockattu, välitä PostgRESTille)
export function treatmentRpc(name, args, now = Date.now()) {
  switch (name) {
    case 'public_treatment_availability': return availability(args, now);
    case 'public_create_treatment_booking': return create(args, now);
    case 'public_get_booking': return getBooking(args, now);
    case 'public_change_treatment_booking': return change(args, now);
    default: return null;
  }
}
export const resetBookings = () => bookings.clear();
// kaupan ?mock=1-tila säilyttää mock-varaukset sivunavigoinnin yli (sessionStorage)
export const snapshotBookings = () => ({ orderNo, bookings: [...bookings.values()] });
export const restoreBookings = (snap) => { bookings.clear(); for (const b of snap?.bookings || []) bookings.set(b.token, b); if (snap?.orderNo > orderNo) orderNo = snap.orderNo; };
// public_catalog()-lisäys: hoito-/rituaalituotteet (booking_kind 'slots'); vain kun liput olisi päällä → demossa aina. Kuvaus ja lisähenkilön hinta tulevat kaupan staattisesta kb-datasta.
export const catalogEntries = () => Object.entries(PRODUCTS).map(([id, p]) => ({ id: +id, slug: ({ 8: 'saunotusrituaali', 10: 'saunahoito-2', 11: 'saunotus-2', 12: 'syvasaunotus' })[id], name: p.name,
  price: p.base, price_type: p.type === 'person' ? 'per_person' : 'base_plus_extra_person', duration_minutes: p.minutes, min_persons: p.min, max_persons: p.max, sale_kind: 'other', booking_kind: 'slots', slot_grid_minutes: 30,
  ...(OPTIONS[id] ? { options: activeOptions(+id), option_required: OPTIONS[id].required, option_label: OPTIONS[id].label, option_label_en: OPTIONS[id].label_en } : { options: [], option_required: false, option_label: null, option_label_en: null }) }));
