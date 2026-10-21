// Tuoteviestien puhdas logiikka (hallinnan lomake, esikatselu, testit).
// Lähetyspäätös tehdään tietokannassa (booking._message_decision). Tämä peilaa samat syykoodit.
// Päivä = 24 tuntia. Ennen saapumista -hetki, joka on jo ohi tilausta luotaessa, ohitetaan (missed_at_booking).
// Ajastettu lähetys, jonka hetki on yli 36 tuntia myöhässä, ohitetaan (too_late), jotta kytkimen avaaminen ei lähetä vanhoja viestejä.

export const CATEGORIES = [
  { id: 'instruction', label: 'Ohje' },
  { id: 'after_marketing', label: 'Jälkimarkkinointi' },
  { id: 'feedback', label: 'Palautepyyntö' },
];
export const UNITS = [
  { id: 'minutes', label: 'minuuttia' },
  { id: 'hours', label: 'tuntia' },
  { id: 'days', label: 'päivää' },
];
export const DIRECTIONS = [
  { id: 'before', label: 'ennen' },
  { id: 'after', label: 'jälkeen' },
];
export const ANCHORS = [
  { id: 'booking', label: 'varausta (tilaus luotu)' },
  { id: 'arrival', label: 'saapumista (varaus alkaa)' },
];
export const PLACEHOLDERS = [
  { key: 'asiakas_nimi', help: 'Asiakkaan koko nimi' },
  { key: 'tilaus_linkki', help: 'Linkki tilaussivulle (sama osoite kuin tilausvahvistuksessa)' },
  { key: 'tuote', help: 'Ne tilauksen tuotteet, joihin tämä viesti on kytketty' },
  { key: 'saapumisaika', help: 'Näiden tuotteiden saapumisajat, Helsinki, muodossa pp.kk.vvvv tt:mm' },
  { key: 'linkki', help: 'Viestin linkkikenttä (esim. Google-arvostelu). Tyhjä, jos kenttä on tyhjä.' },
];
export const GRACE_MS = 36 * 60 * 60 * 1000;
const UNIT_MS = { minutes: 60 * 1000, hours: 60 * 60 * 1000, days: 24 * 60 * 60 * 1000 };
const KEYS = PLACEHOLDERS.map((p) => p.key);

export function fillMessage(template, vars = {}) {
  return String(template ?? '').replace(/\{([a-z_]+)\}/g, (raw, key) => (KEYS.includes(key) ? String(vars[key] ?? '') : raw));
}

export function timingLabel(row) {
  if (row?.send_amount == null || !row.send_unit || !row.send_direction || !row.send_anchor) return 'Ei ajastettua lähetystä';
  const unit = UNITS.find((u) => u.id === row.send_unit)?.label || row.send_unit;
  const dir = DIRECTIONS.find((d) => d.id === row.send_direction)?.label || row.send_direction;
  const anchor = ANCHORS.find((a) => a.id === row.send_anchor)?.label || row.send_anchor;
  return `${row.send_amount} ${unit} ${dir} ${anchor}`;
}

/** @returns {{action:'wait'|'send'|'skip', reason:string, sendAt?:string}} */
export function messageDecision({ createdAt, arrivals = [], amount, unit, direction, anchor, now, orderStatus, paymentStatus, external = false }) {
  if (external) return { action: 'skip', reason: 'external_import' };
  if (!['confirmed', 'completed'].includes(orderStatus)) return { action: 'skip', reason: 'order_status' };
  if (paymentStatus === 'refunded') return { action: 'skip', reason: 'refunded' };
  if (amount == null || amount === '' || !unit || !direction || !anchor) return { action: 'skip', reason: 'no_timing' };
  const n = Number(amount);
  if (!Number.isInteger(n) || n < 1 || n > 3650 || !UNIT_MS[unit] || !['before', 'after'].includes(direction) || !['booking', 'arrival'].includes(anchor)) {
    return { action: 'skip', reason: 'invalid_timing' };
  }
  const created = new Date(createdAt);
  if (Number.isNaN(created.getTime())) return { action: 'skip', reason: 'invalid_timing' };
  let anchorTime = created;
  if (anchor === 'arrival') {
    const times = (arrivals || []).map((a) => new Date(a)).filter((d) => !Number.isNaN(d.getTime())).sort((a, b) => a - b);
    if (!times.length) return { action: 'skip', reason: 'no_arrival' };
    anchorTime = direction === 'before' ? times[0] : times[times.length - 1];
  }
  const sendAt = new Date(anchorTime.getTime() + (direction === 'before' ? -1 : 1) * n * UNIT_MS[unit]);
  const sendIso = sendAt.toISOString();
  if (sendAt.getTime() <= created.getTime()) return { action: 'skip', reason: 'missed_at_booking', sendAt: sendIso };
  const clock = new Date(now);
  if (sendAt.getTime() > clock.getTime()) return { action: 'wait', reason: 'not_due', sendAt: sendIso };
  if (clock.getTime() - sendAt.getTime() > GRACE_MS) return { action: 'skip', reason: 'too_late', sendAt: sendIso };
  return { action: 'send', reason: 'due', sendAt: sendIso };
}

const trim = (v, max) => {
  const s = String(v ?? '').trim();
  return s ? s.slice(0, max) : '';
};
const emptyToNull = (s) => (s ? s : null);

/** Lomakkeen tarkistus. Palauttaa {ok:false, code} tai {ok:true, value}. */
export function validateMessage(raw = {}) {
  const name = trim(raw.name, 200);
  if (!name || name.length > 120) return { ok: false, code: 'invalid_name' };
  if (!CATEGORIES.some((c) => c.id === raw.category)) return { ok: false, code: 'invalid_category' };
  const subjectFi = trim(raw.subject_fi, 400);
  const subjectEn = trim(raw.subject_en, 400);
  const shortFi = trim(raw.short_fi, 4000);
  const shortEn = trim(raw.short_en, 4000);
  const bodyFi = trim(raw.body_fi, 12000);
  const bodyEn = trim(raw.body_en, 12000);
  if (subjectFi.length > 200 || subjectEn.length > 200) return { ok: false, code: 'invalid_text' };
  if (shortFi.length > 2000 || shortEn.length > 2000 || bodyFi.length > 8000 || bodyEn.length > 8000) return { ok: false, code: 'invalid_text' };
  const link = trim(raw.link_url, 600);
  if (link && (link.length > 500 || !/^https:\/\/\S+$/.test(link))) return { ok: false, code: 'invalid_link' };
  const active = raw.active === true;
  const timingTouched = [raw.send_amount, raw.send_unit, raw.send_direction, raw.send_anchor].some((v) => v != null && v !== '');
  let sendAmount = null; let sendUnit = null; let sendDirection = null; let sendAnchor = null;
  if (timingTouched) {
    const n = Number(raw.send_amount);
    if (!Number.isInteger(n) || n < 1 || n > 3650 || !UNIT_MS[raw.send_unit] || !['before', 'after'].includes(raw.send_direction) || !['booking', 'arrival'].includes(raw.send_anchor)) {
      return { ok: false, code: 'invalid_timing' };
    }
    sendAmount = n; sendUnit = raw.send_unit; sendDirection = raw.send_direction; sendAnchor = raw.send_anchor;
  }
  if (active) {
    if (!subjectFi) return { ok: false, code: 'invalid_text' };
    if (raw.category === 'instruction' && (!shortFi || !bodyFi)) return { ok: false, code: 'invalid_text' };
    if (raw.category !== 'instruction' && !bodyFi) return { ok: false, code: 'invalid_text' };
    if (raw.category !== 'instruction' && !timingTouched) return { ok: false, code: 'invalid_timing' };
    if (raw.category === 'instruction' && timingTouched && !bodyFi) return { ok: false, code: 'invalid_text' };
  }
  const ids = [];
  for (const id of raw.product_ids || []) {
    const n = Number(id);
    if (!Number.isInteger(n) || n < 1) return { ok: false, code: 'invalid_product' };
    if (!ids.includes(n)) ids.push(n);
  }
  const instruction = raw.category === 'instruction';
  return {
    ok: true,
    value: {
      name, category: raw.category, active,
      subject_fi: emptyToNull(subjectFi), subject_en: emptyToNull(subjectEn),
      short_fi: instruction ? emptyToNull(shortFi) : null,
      short_en: instruction ? emptyToNull(shortEn) : null,
      body_fi: emptyToNull(bodyFi), body_en: emptyToNull(bodyEn),
      link_url: link || null,
      send_amount: sendAmount, send_unit: sendUnit, send_direction: sendDirection, send_anchor: sendAnchor,
      product_ids: ids,
    },
  };
}

export function emptyMessage() {
  return {
    id: null, name: '', category: 'instruction', active: false,
    subject_fi: '', subject_en: '', short_fi: '', short_en: '', body_fi: '', body_en: '', link_url: '',
    send_amount: '', send_unit: '', send_direction: '', send_anchor: '', product_ids: [],
  };
}
