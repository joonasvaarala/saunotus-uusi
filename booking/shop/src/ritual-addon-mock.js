// Kaupan KOKEILUTILA (?mock=1&ritual=1, booking_166): yleinen vuoro (kb 1, la–su) + saunarituaali lisäpalveluna selaimen muistissa.
// EI yhteyttä palvelimeen. Vastaa muodoltaan tuotannon funktioita public_availability (kb 1), public_ritual_addon, public_create_booking ja
// public_get_booking (items[].ritual_addon, has_ritual_addon). Aikasääntö = ritual-addon-logic.js (sama kuin booking._ritual_addon_starts).
// Demo: klo 16.30 alkavaan rituaaliin mahtuu enää 2, klo 17.30 on täynnä (ei näy). ?fail=noritual → ei vapaita rituaaliaikoja (osio piilossa);
// ?fail=ritualfull → seuraava varaus rituaalin kanssa palauttaa ritual_addon_full kerran.
import { ritualStarts, positionOf, RITUAL_RULE_DEFAULTS } from './ritual-addon-logic.js';
import { ADDONS } from './treatment-mock.js';

const TZ = 'Europe/Helsinki';
export const SHARED_PRODUCT = { id: 1, name: 'Yleinen vuoro (to, la-su)', name_en: 'Public sauna (Sat & Sun)', slug: 'yleinensauna', price: 29, price_text: '29,00 € / hlö', price_type: 'per_person', category: 'public_sauna', sale_kind: 'public_shift',
  booking_kind: 'rules', min_persons: 1, max_persons: null, duration_minutes: 120, duration_text: 'la–su klo 14–19 (saunomisaika 2 h); to klo 17–19', options: [], option_required: false, option_label: null, option_label_en: null,
  addons_enabled: true, allowed_addons: ['turvenaamio_jalkakylpy', 'saunavihta', 'pyyhe'], description: 'Sekavuoro, johon kaikki ovat tervetulleita.', description_en: null, timeline: null };
export const RITUAL = { product_id: 8, name: 'Saunotusrituaali', name_en: 'Sauna ritual', unit: 20, vat: 25.5, minutes: 20, min: 1, max: 6 };
const RULES = [[6, '14:00'], [7, '14:30'], [8, '15:00'], [9, '16:00'], [10, '16:30'], [11, '17:00']];
const USED = { '16:30': 4, '17:30': 6 };   // demo: muiden rituaalivaraukset (rituaalipooli max 6)
const helFmt = new Intl.DateTimeFormat('en-GB', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const parts = (ms) => Object.fromEntries(helFmt.formatToParts(new Date(ms)).map((p) => [p.type, p.value]));
const hmOf = (ms) => { const p = parts(ms); return `${p.hour}:${p.minute}`; };
const dayOf = (ms) => { const p = parts(ms); return `${p.year}-${p.month}-${p.day}`; };
function helToMs(ds, hm) {
  const [y, m, d] = ds.split('-').map(Number), [H, M] = hm.split(':').map(Number);
  for (const off of [3, 2]) { const ms = Date.UTC(y, m - 1, d, H - off, M); const p = parts(ms); if (+p.hour === H && +p.minute === M && +p.day === d) return ms; }
  return Date.UTC(y, m - 1, d, H - 2, M);
}
const dow = (ds) => new Date(`${ds}T12:00:00Z`).getUTCDay();
const addDays = (ds, n) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const offset = (ms) => { const p = parts(ms), local = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute); const o = Math.round((local - ms) / 60e3); return `+${String(Math.floor(o / 60)).padStart(2, '0')}:${String(o % 60).padStart(2, '0')}`; };
const iso = (ms) => { const p = parts(ms); return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}:00${offset(ms)}`; };   // kuten PostgREST (+02:00 / +03:00)

export function createRitualMock({ storage = globalThis.sessionStorage, now = () => Date.now(), fail = null } = {}) {
  const KEY = 'booking.shopmock.ritual.v1';
  const book = new Map();
  let orderNo = 9600, failOnce = fail === 'ritualfull';
  try { const s = JSON.parse(storage?.getItem(KEY) || 'null'); for (const b of s?.bookings || []) book.set(b.token, b); orderNo = Math.max(orderNo, s?.orderNo || 0); } catch { /* tyhjä alku */ }
  const save = () => { try { storage?.setItem(KEY, JSON.stringify({ orderNo, bookings: [...book.values()] })); } catch { /* ei säilytystä */ } };
  const session = (ruleId, ds) => {
    const r = RULES.find(([id]) => id === +ruleId); if (!r || ![0, 6].includes(dow(ds))) return null;
    const s = helToMs(ds, r[1]);
    const taken = [...book.values()].filter((b) => b.rule_id === r[0] && b.date === ds).reduce((x, b) => x + b.persons, 0);
    return { rule_id: r[0], start: s, end: s + 2 * 36e5, remaining: Math.max(0, 6 - taken - (ds.endsWith('5') ? 3 : 0)) };
  };
  const ritualUsed = (t) => (USED[hmOf(t)] || 0) + [...book.values()].filter((b) => b.ritual && b.ritual.start === t).reduce((x, b) => x + b.ritual.qty, 0);
  function availability(a) {
    const rows = [], today = dayOf(now());
    for (let d = a.p_from; d <= a.p_to; d = addDays(d, 1)) {
      if (d <= today) continue;
      for (const [id] of RULES) {
        const s = session(id, d); if (!s) continue;
        rows.push({ rule_id: id, label: `Yleinen vuoro la–su ${hmOf(s.start)} (2 h)`, label_en: null, mode: 'shared', session_date: d, starts_at: iso(s.start), ends_at: iso(s.end), status: s.remaining > 0 ? 'available' : 'full', remaining: s.remaining,
          min_persons: 1, max_persons: 6, price_mode: 'per_person', unit_price: 29, base_price: null, included_persons: null, extra_person_price: null });
      }
    }
    return rows;
  }
  function offer(a) {
    const s = session(a.p_rule_id, a.p_date);
    if (!s) return { ok: true, available: false, reason: 'no_session', times: [] };
    if (fail === 'noritual') return { ok: true, available: false, reason: 'full', times: [] };
    const n = Math.max(1, Math.min(+a.p_persons || 1, 50)), cap = Math.min(n, RITUAL.max), prices = {};
    for (let i = RITUAL.min; i <= cap; i++) prices[i] = RITUAL.unit * i;
    const times = ritualStarts(s.start, s.end, RITUAL_RULE_DEFAULTS).filter((t) => t > now() + 120 * 60e3)
      .map((t) => ({ starts_at: iso(t), ends_at: iso(t + RITUAL.minutes * 60e3), max_persons: Math.min(cap, RITUAL.max - ritualUsed(t)), label: hmOf(t), position: positionOf(t, s.start, s.end) }))
      .filter((x) => x.max_persons >= RITUAL.min);
    return { ok: true, available: times.length > 0, reason: times.length ? null : 'full', product_id: RITUAL.product_id, name: RITUAL.name, name_en: RITUAL.name_en, price_type: 'per_person', unit_price: RITUAL.unit,
      prices, vat_rate: RITUAL.vat, duration_minutes: RITUAL.minutes, min_persons: RITUAL.min, max_persons: cap, session_starts_at: iso(s.start), session_ends_at: iso(s.end), times };
  }
  const err = (code, message) => ({ ok: false, code, message });
  function create(a) {
    const s = session(a.p_rule_id, a.p_date), n = +a.p_persons;
    if (!s) return err('not_found', 'Vuoroa ei löytynyt');
    if (!(n >= 1 && n <= s.remaining)) return err('capacity_exceeded', 'Vuorolla ei ole tarpeeksi paikkoja');
    if (String(a.p_name || '').trim().length < 2) return err('invalid_name', 'Anna nimi');
    const list = Array.isArray(a.p_addons) ? a.p_addons : [];
    const rEls = list.filter((x) => x && x.ritual_start != null);
    if (rEls.length > 1) return err('ritual_addon_invalid', 'Vain yksi rituaali');
    let ritual = null;
    if (rEls.length) {
      if (failOnce) { failOnce = false; return err('ritual_addon_full', 'Valittu saunarituaalin aika ei ole enää vapaana'); }
      const t = Date.parse(rEls[0].ritual_start), q = +rEls[0].quantity, o = offer({ p_rule_id: a.p_rule_id, p_date: a.p_date, p_persons: n });
      if (!/(Z|[+-]\d\d(:?\d\d)?)$/.test(String(rEls[0].ritual_start))) return err('ritual_addon_time', 'Aika ilman aikavyöhykettä');
      if (!Number.isInteger(q) || q < 1 || q > Math.min(n, RITUAL.max)) return err('ritual_addon_persons', 'Virheellinen osallistujamäärä');
      const slot = (o.times || []).find((x) => Date.parse(x.starts_at) === t);
      if (!ritualStarts(s.start, s.end).includes(t)) return err('ritual_addon_time', 'Aika ei sovi vuorolle');
      if (!slot || slot.max_persons < q) return err('ritual_addon_full', 'Aika ei ole enää vapaana');
      ritual = { start: t, end: t + RITUAL.minutes * 60e3, qty: q, total: RITUAL.unit * q };   // hinta palvelimen säännöllä (ei asiakkaan lähettämää)
    }
    const addons = list.filter((x) => x && x.ritual_start == null).map((x) => ({ addon: ADDONS.find((ad) => ad.id === +x.id), quantity: +x.quantity })).filter((x) => x.addon && x.quantity > 0);
    const total = 29 * n + addons.reduce((x, y) => x + y.addon.price * y.quantity, 0) + (ritual?.total || 0);
    const token = globalThis.crypto.randomUUID();
    book.set(token, { token, order_no: ++orderNo, rule_id: s.rule_id, date: a.p_date, start: s.start, end: s.end, persons: n, ritual, addons, total, name: a.p_name, kind: a.p_customer_kind || 'private' });
    save();
    return { ok: true, order_no: orderNo, token, status: 'confirmed', total, payment_mode: 'pay_later' };
  }
  function getBooking(a) {
    const b = book.get(a.p_token); if (!b) return null;
    const item = (o) => ({ quantity: 1, vat_rate: 25.5, rule_id: null, status: 'confirmed', hold_expires_at: null, option: null, ...o });
    const items = [item({ product_name: SHARED_PRODUCT.name, product_id: 1, rule_id: b.rule_id, starts_at: iso(b.start), ends_at: iso(b.end), persons: b.persons, line_total: 29 * b.persons, mode: 'shared', ritual_addon: false })];
    if (b.ritual) items.push(item({ product_name: RITUAL.name, product_id: RITUAL.product_id, starts_at: iso(b.ritual.start), ends_at: iso(b.ritual.end), persons: b.ritual.qty, line_total: b.ritual.total, mode: 'shared', ritual_addon: true }));
    const deadline = b.start - 48 * 36e5;
    return { ok: true, order_no: b.order_no, status: 'confirmed', payment_status: 'unpaid', total: b.total, currency: 'EUR', created_at: new Date(now()).toISOString(), first_name: String(b.name).split(' ')[0], customer_kind: b.kind,
      items, addons: b.addons.map((x) => ({ id: x.addon.id, name: x.addon.name, name_en: x.addon.name_en, quantity: x.quantity, unit_price: x.addon.price })), payment_methods: [], booking_kind: 'rules',
      has_ritual_addon: !!b.ritual, can_change: !b.ritual && deadline > now(), change_deadline: new Date(deadline).toISOString(), change_hours_before: 48 };   // rituaalin kanssa ei verkkomuutosta (palvelin: not_changeable)
  }
  // → vastaus tai undefined (= ei tämän mockin funktio)
  return function rpc(name, args = {}) {
    switch (name) {
      case 'public_availability': return +args.p_product_id === 1 ? availability(args) : undefined;
      case 'public_ritual_addon': return offer(args);
      case 'public_create_booking': return create(args);
      case 'public_get_booking': return getBooking(args) ?? undefined;
      default: return undefined;
    }
  };
}
