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
  // Pakettituote (booking_58, sopimus §17.11 + booking_61 §18.11): rituaali 0–20 min (Rauni, jaettu rituaalipooli kuten kb 8), sisäinen väli 20–30 (kind 'break', ei näy asiakkaalle), savusauna 30–120 (ei mallinneta mockissa);
  // la–su, alkuajat 16:00/16:30/17:00; EI hoitovalitsinta. Kentät = tuotannon public_catalog()-rivi 18.10.2026 (booking_61: voucher_note, timeline, timeline_text, description_en); tests/saunarituaali.test.mjs vertaa fixtureen.
  7: { name: 'Saunarituaali ja savusaunavuoro (la & su)', name_en: 'Sauna Ritual & Smoke Sauna Session', minutes: 120, ritualMinutes: 20, min: 1, max: 6, base: 49, extra: 0, included: 0, type: 'person', category: 'ritual',
    duration_text: 'rituaali 20 min + tauko 10 min + savusauna 1 h 30 min (yhteensä 2 h)',
    description: 'Avoin saunarituaali lauantaisin ja sunnuntaisin: vuoro alkaa 20 minuutin saunotusrituaalilla hoitosauna Raunissa (pienryhmä, enintään 6 osallistujaa), josta siirrytään savusaunaan. Sisältää löylyntervehdyksen, kevyttä lämmittelyvihdontaa ja vuodenkierron mukaisen minihoidon sekä pääsyn sauna-alueelle, altaisiin ja laavulle. Rituaaliin voi tulla alasti, mutta savusaunassa ja paljuissa käytetään uima-asua. Ohjelma vaihtuu vuodenaikojen mukaan.',
    description_en: 'Open sauna ritual on Saturdays and Sundays: the session starts with a 20-minute sauna ritual in the healing sauna Rauni (small group, max. 6 participants), after which you move on to the smoke sauna. Includes a löyly greeting, light warming vihta whisking and a seasonal mini treatment, plus access to the sauna area, the pools and the lean-to (laavu). You are welcome to join the ritual naked, but swimwear is worn in the smoke sauna and the hot tubs. The programme changes with the seasons.',
    voucher_note: 'Elämyslahjojen lahjakortilla: varaa ensin yleinen vuoro ja osta rituaali erikseen.', voucher_note_en: 'With an Elämyslahjat gift card: first book a regular session and buy the ritual separately.',
    timeline: [{ seq: 1, kind: 'ritual', label: 'rituaali', label_en: 'ritual', minutes: 20, start_min: 0, end_min: 20 }, { seq: 2, kind: 'break', label: 'tauko', label_en: 'break', minutes: 10, start_min: 20, end_min: 30 },
      { seq: 3, kind: 'smoke_sauna', label: 'savusauna', label_en: 'smoke sauna', minutes: 90, start_min: 30, end_min: 120 }],
    timeline_text: 'rituaali 20 min · tauko 10 min · savusauna 1 h 30 min', timeline_text_en: 'ritual 20 min · break 10 min · smoke sauna 1 h 30 min' },
};
const isRit = (id) => id === 7 || id === 8;   // rituaalipooli (Rauni, yht. max 6 hlö samaan aikaan)
// Rauni-ikkuna (ms): rituaali ja paketin rituaaliosa 20 min, hoidot ja saunotus koko kesto
const winOf = (id, s) => [s, s + (PRODUCTS[id].ritualMinutes || PRODUCTS[id].minutes) * 60e3];
// Tuotevalinta (booking_50, sopimus §15): Saunahoito (kb 10) vaatii hoidon valinnan; hinta ei muutu. Rivit kuten tuotannon seed (ei kuvauksia).
export const OPTIONS = {
  10: { required: true, label: 'Valitse hoito', label_en: 'Choose your treatment', options: [
    { id: 1, code: 'hunajahoito', name: 'Hunajahoito', name_en: 'Honey treatment', sort_order: 10, description: null, description_en: null, active: true },
    { id: 2, code: 'vihtahoito', name: 'Vihtahoito', name_en: 'Birch whisk treatment', sort_order: 20, description: null, description_en: null, active: true },
    { id: 3, code: 'suolahoito', name: 'Suolahoito', name_en: 'Salt treatment', sort_order: 30, description: null, description_en: null, active: true },
    { id: 4, code: 'turvehoito', name: 'Turvehoito', name_en: 'Peat treatment', sort_order: 40, description: null, description_en: null, active: true }] },
};
// Lisäpalvelut (booking_27/61): public_addons() = tuotannon rivit 18.10.2026 (vain aktiiviset); pyyhe (id 5) sallittu resurssivaraukselle (applies_modes ∋ 'resource'), turvenaamio/saunavihta eivät.
// ADDON_INACTIVE (id 99) ei ole listassa: vastaa kilpatilannetta jossa lisäpalvelu ehti passivoitua (addon_inactive).
export const ADDONS = [
  { id: 1, code: 'turvenaamio_jalkakylpy', name: 'Turvenaamio ja jalkakylpy', price: 15, name_en: 'Peat mask and foot bath', vat_rate: 25.5, description: 'Lisäpalvelu varaukseen: turvenaamio ja jalkakylpy.', applies_modes: ['shared', 'exclusive'], description_en: 'Add-on for your booking: peat mask and foot bath.', max_per_person: 20 },
  { id: 2, code: 'saunavihta', name: 'Saunavihta', price: 13, name_en: 'Sauna whisk (vihta)', vat_rate: 25.5, description: 'Lisäpalvelu varaukseen: saunavihta.', applies_modes: ['shared', 'exclusive'], description_en: 'Add-on for your booking: sauna whisk (vihta).', max_per_person: 20 },
  { id: 5, code: 'pyyhe', name: 'Pyyhe', price: 5, name_en: 'Towel', vat_rate: 25.5, description: 'Lisäpalvelu varaukseen: pyyhe.', applies_modes: ['shared', 'exclusive', 'resource'], description_en: 'Add-on for your booking: towel.', max_per_person: 20 },
];
const ADDON_INACTIVE = { id: 99, code: 'poistunut', name: 'Poistunut lisäpalvelu', name_en: 'Removed add-on', price: 9, applies_modes: ['resource'], active: false, max_per_person: 5 };
const addonLimit = (a, n) => Math.min((a.max_per_person ?? 99) * Math.max(1, n), 99);   // booking._addon_limit
// p_addons: null | [{ id|code, quantity }] → { ok:true, items:[{ addon, quantity }], total } | { ok:false, code, message } (booking._attach_addons: virheet BK001 → ok:false + code)
function resolveAddons(raw, persons) {
  if (raw == null) return { ok: true, items: [], total: 0 };
  if (!Array.isArray(raw) || raw.some((x) => !x || typeof x !== 'object' || (x.id == null && !x.code))) return { ok: false, code: 'invalid_addons', message: 'Virheelliset lisäpalvelut' };
  const items = new Map();
  for (const x of raw) {
    const addon = [...ADDONS, ADDON_INACTIVE].find((a) => (x.id != null ? a.id === +x.id : a.code === String(x.code)));
    if (!addon) return { ok: false, code: 'addon_not_found', message: 'Lisäpalvelua ei löydy' };
    if (addon.active === false) return { ok: false, code: 'addon_inactive', message: 'Lisäpalvelu ei ole käytössä' };
    if (!addon.applies_modes.includes('resource')) return { ok: false, code: 'addon_not_allowed', message: 'Lisäpalvelu ei ole sallittu tälle varaukselle' };
    const q = Number(x.quantity);
    if (!Number.isInteger(q) || q < 1) return { ok: false, code: 'addon_quantity', message: 'Virheellinen määrä' };
    items.set(addon.id, { addon, quantity: (items.get(addon.id)?.quantity || 0) + q });
  }
  for (const it of items.values()) if (it.quantity > addonLimit(it.addon, persons)) return { ok: false, code: 'addon_quantity', message: 'Liian suuri määrä' };
  const list = [...items.values()];
  return { ok: true, items: list, total: list.reduce((x, it) => x + it.quantity * it.addon.price, 0) };
}
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
  if (isRit(id) && ![0, 6].includes(dow(ds))) return [];   // rituaali ja paketti vain la–su
  const [from, to] = windowOf(ds);
  const starts = isRit(id) ? RITUAL_STARTS : Array.from({ length: Math.floor((toMin(to) - pr.minutes - toMin(from)) / 30) + 1 }, (_, i) => fromMin(toMin(from) + i * 30));
  const mine = (b) => b.token !== skipToken && dayOf(b.start) === ds;
  const taken = [...bookings.values()].filter(mine);
  return starts.filter((hm) => {
    const s = helToMs(ds, hm), [, e] = winOf(id, s);   // e = Rauni-ikkunan loppu
    if (hm < from || toMin(hm) + pr.minutes > toMin(to)) return false;
    if (s < now + LEAD_MS) return false;
    for (const [a, b] of busyBlocks(ds)) if (s < helToMs(ds, fromMin(b)) + GAP && e + GAP > helToMs(ds, fromMin(a))) return false;
    let ritualPersons = 0;
    for (const b of taken) {
      const [bs, be] = winOf(b.product_id, b.start);
      if (isRit(id) && isRit(b.product_id)) { if (s < be && e > bs) ritualPersons += b.persons; continue; }   // yhteinen rituaalipooli: yht. max 6 hlö
      if (s < be + GAP && e + GAP > bs) return false;   // Rauni: 15 min puskuri hoitoihin/saunotukseen
    }
    return !(isRit(id) && ritualPersons + n > PRODUCTS[8].max);
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
  const ad = resolveAddons(a.p_addons, n); if (!ad.ok) return fail(ad.code, ad.message);
  const forced = /^(invalid_addons|addon_not_found|addon_inactive|addon_not_allowed|addon_quantity)@test\.fi$/.exec(String(a.p_email || ''));   // e2e-laukaisin (kuten taken@test.fi): palvelin hylkää lisäpalvelut tällä koodilla, kun niitä on valittu
  if (forced && ad.items.length) return fail(forced[1], 'Lisäpalvelut hylättiin');   // slot- ja valintavirheet ensin (kuten palvelimella: lisäpalvelut liitetään varauksen jälkeen, virhe perii koko luonnin)
  const token = randomUUID(), total = price(pr, n) + ad.total;
  bookings.set(token, { token, option: opt.option, addons: ad.items, addonsTotal: ad.total, order_no: ++orderNo, product_id: id, start: s, end: s + pr.minutes * 60e3, persons: n, total, kind: a.p_customer_kind || 'private', name: a.p_name, email: a.p_email, note: a.p_note, locked: a.p_email === 'locked@test.fi' });
  return ok({ ok: true, order_no: orderNo, token, status: 'confirmed', starts_at: new Date(s).toISOString(), ends_at: new Date(s + pr.minutes * 60e3).toISOString(), persons: n, total, addons_total: ad.total,
    payment_mode: a.p_customer_kind === 'company' ? 'invoice' : 'pay_later', payment_url: null, hold_expires_at: null, product_name: pr.name, option: optJson(opt.option), customer_kind: a.p_customer_kind || 'private', booking_kind: 'slots' });
}
// booking_52: valitsimen otsikko vastauksessa (items[].option_label tilauksen kielellä = fi, option_label_fi / option_label_en); tuote ilman otsikkoa → null
const optLabels = (id) => { const o = OPTIONS[id]; return { option_label: o?.label || null, option_label_fi: o?.label || null, option_label_en: o?.label_en || o?.label || null }; };
function getBooking(a, now) {
  const b = bookings.get(a.p_token); if (!b) return null;   // ei mock-varaus → oikea funktio
  const deadline = b.start - CHANGE_H * HOURS;
  return ok({ ok: true, order_no: b.order_no, status: 'confirmed', payment_status: 'unpaid', total: b.total, currency: 'EUR', created_at: new Date(now).toISOString(), first_name: String(b.name).split(' ')[0],
    customer_kind: b.kind, items: [{ product_name: PRODUCTS[b.product_id].name, quantity: 1, line_total: b.total, vat_rate: 25.5, product_id: b.product_id, rule_id: null, starts_at: new Date(b.start).toISOString(),
      ends_at: new Date(b.end).toISOString(), persons: b.persons, mode: 'treatment', status: 'confirmed', hold_expires_at: null, option: optJson(b.option), ...optLabels(b.product_id) }],
    addons: (b.addons || []).map((x) => ({ id: x.addon.id, name: x.addon.name, name_en: x.addon.name_en, quantity: x.quantity, unit_price: x.addon.price, max_per_person: x.addon.max_per_person })), payment_methods: [],
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
  Object.assign(b, { option: newOpt }, timeChange ? { start: s, end: s + pr.minutes * 60e3, persons: n, total: price(pr, n) + (b.addonsTotal || 0) } : {});   // pelkkä hoidon vaihto: aika ja hinta ennallaan
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
export const catalogEntries = () => Object.entries(PRODUCTS).map(([id, p]) => ({ id: +id, slug: ({ 7: 'saunarituaali-ja-savusaunavuoro', 8: 'saunotusrituaali', 10: 'saunahoito-2', 11: 'saunotus-2', 12: 'syvasaunotus' })[id], name: p.name,
  ...(p.name_en ? { name_en: p.name_en } : {}), ...(p.category ? { category: p.category } : {}), ...(p.duration_text ? { duration_text: p.duration_text } : {}),
  ...(p.description ? { description: p.description } : {}), ...(p.description_en ? { description_en: p.description_en } : {}), ...(p.voucher_note ? { voucher_note: p.voucher_note, voucher_note_en: p.voucher_note_en } : {}),
  ...(p.timeline ? { timeline: p.timeline, timeline_text: p.timeline_text, timeline_text_en: p.timeline_text_en } : {}),
  price: p.base, price_type: p.type === 'person' ? 'per_person' : 'base_plus_extra_person', duration_minutes: p.minutes, min_persons: p.min, max_persons: p.max, sale_kind: 'other', booking_kind: 'slots', slot_grid_minutes: 30,
  ...(OPTIONS[id] ? { options: activeOptions(+id), option_required: OPTIONS[id].required, option_label: OPTIONS[id].label, option_label_en: OPTIONS[id].label_en } : { options: [], option_required: false, option_label: null, option_label_en: null }) }));
