// Lahjakortin toimitusvalinnan tarkistus hallinnan myynti-/myöntölomakkeelle (sopimus KOODARI_talous_A_D_fi.md §13.11, migraatio booking_46).
// Peilaa palvelimen booking._gc_delivery_resolve:n (sama tarkistusjärjestys ja virhekoodit) ja on tarkoituksella kopio kaupan shop/src/gift-logic.js:n toimitusosasta
// (hallinta ja kauppa julkaistaan erikseen); yhtäpitävyys testataan (booking/tests/giftcards.test.mjs). Palvelin tarkistaa aina uudelleen.
export const COVER_MAX = 1000;
export const DELIVER_TIME_DEFAULT = '09:00';
export const DELIVER_MAX_MONTHS = 12;
const TZ = 'Europe/Helsinki';
const p2 = (n) => String(n).padStart(2, '0');
// Helsingin kellonaika annetusta hetkestä: { date: 'YYYY-MM-DD', time: 'HH:MM' }
export function helsinkiNow(now = new Date()) {
  const f = new Intl.DateTimeFormat('en-GB', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(now);
  const g = (t) => f.find((x) => x.type === t).value;
  return { date: `${g('year')}-${g('month')}-${g('day')}`, time: `${g('hour')}:${g('minute')}` };
}
const validYmd = (s) => { const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s); if (!m) return false; const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])); return d.getUTCFullYear() === +m[1] && d.getUTCMonth() === +m[2] - 1 && d.getUTCDate() === +m[3]; };
// Helsingin paikallinen päivä+aika → UTC-millisekunnit (kesäaika huomioiden)
export function helsinkiToMs(ymd, hm) {
  const [y, mo, d] = ymd.split('-').map(Number), [h, mi] = hm.split(':').map(Number);
  const guess = Date.UTC(y, mo - 1, d, h, mi);
  const off = (ms) => { const t = helsinkiNow(new Date(ms)); const [yy, mm, dd] = t.date.split('-').map(Number), [hh, nn] = t.time.split(':').map(Number); return Date.UTC(yy, mm - 1, dd, hh, nn) - ms; };
  let ms = guess - off(guess); ms = guess - off(ms); return ms;
}
// date + n kuukautta (kuten Postgres: päivä rajataan kuukauden loppuun)
export function addMonths(ymd, n) {
  const [y, m, d] = ymd.split('-').map(Number), t = (m - 1) + n, yy = y + Math.floor(t / 12), mm = ((t % 12) + 12) % 12;
  const last = new Date(Date.UTC(yy, mm + 1, 0)).getUTCDate();
  return `${yy}-${p2(mm + 1)}-${p2(Math.min(d, last))}`;
}
export const deliverMaxDate = (today, months) => addMonths(today, Math.min(DELIVER_MAX_MONTHS, Math.max(1, Number(months) || 6)));
export const cleanCover = (s) => String(s ?? '').replace(/\r\n/g, '\n').replace(/[\x00-\x09\x0b-\x1f\x7f]/g, '').trim();
export const coverState = (s) => { const n = [...cleanCover(s)].length; return { n, left: COVER_MAX - n, over: n > COVER_MAX }; };
// Palauttaa { ok: true, value: { delivery_to, cover_message, deliver_on, deliver_time } } tai { ok: false, code } (palvelimen virhekoodi)
export function resolveDelivery({ to, recipientEmail, cover, on, time, months = 6, now = new Date() } = {}) {
  const bad = (code) => ({ ok: false, code });
  const re = String(recipientEmail ?? '').trim() || null;
  let v = String(to ?? '').trim().toLowerCase() || (re ? 'recipient' : 'buyer');
  if (v !== 'buyer' && v !== 'recipient') return bad('invalid_delivery_to');
  if (v === 'buyer') return { ok: true, value: { delivery_to: 'buyer', cover_message: null, deliver_on: null, deliver_time: null } };
  if (!re) return bad('recipient_email_required');
  const c = cleanCover(cover) || null;
  if (c && [...c].length > COVER_MAX) return bad('invalid_cover_message');
  const t0 = helsinkiNow(now), today = t0.date;
  let onTxt = String(on ?? '').trim() || null, timeTxt = String(time ?? '').trim() || null, d = null, t = null;
  if (onTxt) {
    const m = /^(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2}))?$/.exec(onTxt);
    if (!m || !validYmd(m[1])) return bad('invalid_deliver_on');
    d = m[1]; if (m[2]) timeTxt = timeTxt || m[2];
  } else if (timeTxt) return bad('invalid_deliver_on');
  if (timeTxt) { if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(timeTxt)) return bad('invalid_deliver_time'); t = timeTxt; }
  if (d) {
    if (d < today) return bad('deliver_on_past');
    if (t && helsinkiToMs(d, t) < now.getTime() - 5 * 60 * 1000) return bad('deliver_on_past');
    if (d > deliverMaxDate(today, months)) return bad('deliver_on_too_far');
    if (d === today && !t) d = null;   // tänään ilman kellonaikaa = heti
  }
  return { ok: true, value: { delivery_to: 'recipient', cover_message: c, deliver_on: d, deliver_time: t } };
}

// Hallinnan lomake → kenttäkohtaiset virheet { recipientEmail?, cover?, deliverOn?, deliverTime?, greeting? } (arvo = virhekoodi, teksti err.<koodi>); {} = kunnossa
export function deliveryErrors({ to, recipientEmail, cover, later, on, time, months = 6, now = new Date() } = {}) {
  const err = {};
  if (to !== 'recipient') return err;
  const re = String(recipientEmail ?? '').trim();
  if (!re) err.recipientEmail = 'recipient_email_required'; else if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(re)) err.recipientEmail = 'invalid_email';
  if (coverState(cover).over) err.cover = 'invalid_cover_message';
  if (later) {
    if (!String(on ?? '').trim()) err.deliverOn = 'invalid_deliver_on';
    else {
      const r = resolveDelivery({ to, recipientEmail: re || 'x@x.fi', cover: '', on, time, months, now });
      if (!r.ok) { if (r.code === 'invalid_deliver_time') err.deliverTime = r.code; else if (['invalid_deliver_on', 'deliver_on_past', 'deliver_on_too_far'].includes(r.code)) err.deliverOn = r.code; }
    }
  }
  return err;
}
// Palvelimen virhekoodi → lomakkeen kenttä
export const SERVER_FIELD = { deliver_on_past: 'deliverOn', deliver_on_too_far: 'deliverOn', invalid_deliver_on: 'deliverOn', invalid_deliver_time: 'deliverTime', invalid_cover_message: 'cover', invalid_greeting: 'greeting', recipient_email_required: 'recipientEmail', invalid_email: 'recipientEmail', invalid_delivery_to: 'deliveryTo' };
