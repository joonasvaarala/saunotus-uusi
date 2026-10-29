// booking_158 + booking_202: hallinnan Tapahtumat-näkymän puhdas logiikka (ei DOMia, ei verkkoa → testattavissa Nodessa).
// Sarjan luonti (päivät × alkuajat, viikkotoisto), resurssivarausten aikalaskenta, kerran tila, osallistuja-CSV ja viestin esikatselu.
// Aikavyöhyke aina Europe/Helsinki (sama kuin booking._tz()). Asiakasviestiin ei päädy maksuvälittäjän nimeä.
import { csvText } from './csv.js';
export const TZ = 'Europe/Helsinki';
export const CHANNELS = ['shop', 'widget'];               // booking._channels_effective: shop = verkkokauppa, widget = koulutussivun widget
export const MAX_SERIES = 60;                             // yhdellä tallennuksella enintään näin monta kertaa
export const MAX_BLOCKS = 50;                             // sama raja kuin admin_event_blocks_set
export const MODES = ['exclusive', 'shared'];

const pad = (n) => String(n).padStart(2, '0');
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

/** 'YYYY-MM-DD' tai 'D.M.YYYY' → 'YYYY-MM-DD' (todellinen päivä) tai null. */
export function parseDate(s) {
  const t = String(s ?? '').trim();
  let y, m, d, x;
  if ((x = DATE_RE.exec(t))) [y, m, d] = [+x[1], +x[2], +x[3]];
  else if ((x = /^(\d{1,2})\.(\d{1,2})\.(\d{4})$/.exec(t))) [d, m, y] = [+x[1], +x[2], +x[3]];
  else return null;
  const dt = new Date(Date.UTC(y, m - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) return null;
  return `${y}-${pad(m)}-${pad(d)}`;
}
/** 'HH:MM' / 'HH.MM' / 'H' → 'HH:MM' tai null. */
export function parseTime(s) {
  const x = /^(\d{1,2})(?:[:.](\d{2}))?$/.exec(String(s ?? '').trim());
  if (!x) return null;
  const hh = +x[1], mm = +(x[2] ?? 0);
  if (hh > 23 || mm > 59) return null;
  return `${pad(hh)}:${pad(mm)}`;
}
const splitList = (s) => (Array.isArray(s) ? s : String(s ?? '').split(/[\s,;]+/)).map((x) => String(x).trim()).filter(Boolean);
/** Lista (pilkku/välilyönti/rivinvaihto) → { values: lajiteltu uniikki, invalid: [kelpaamattomat] }. */
export function parseList(s, parse) {
  const values = new Set(), invalid = [];
  for (const raw of splitList(s)) { const v = parse(raw); if (v) values.add(v); else invalid.push(raw); }
  return { values: [...values].sort(), invalid };
}
export const addDays = (ds, n) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };

/** Oletusnimi kuten palvelin (admin_event_rule_upsert): 'DD.MM.YYYY klo HH.MI' (fi) / 'DD.MM.YYYY at HH:MI' (en). */
export function defaultLabel(date, time, lang = 'fi') {
  const [y, m, d] = date.split('-'), [hh, mi] = time.split(':');
  return lang === 'en' ? `${d}.${m}.${y} at ${hh}:${mi}` : `${d}.${m}.${y} klo ${hh}.${mi}`;
}

const intOr = (v, d = null) => (v === '' || v == null ? d : Number.isInteger(+v) ? +v : NaN);
/** ISO-viikonpäivä 1=ma … 7=su päivämäärälle YYYY-MM-DD (keskipäivä UTC, ei kesäaikasiirtymää). */
export function weekdayIso(date) {
  const d = new Date(`${date}T12:00:00Z`);
  const js = d.getUTCDay();
  return js === 0 ? 7 : js;
}
/**
 * Viikkotoisto: jokainen valittu viikonpäivä väliltä from…until (molemmat mukana).
 * → { ok, dates } tai { ok: false, error }.
 */
export function repeatDates({ from, until, weekdays } = {}) {
  const a = parseDate(from), b = parseDate(until);
  if (!a || !b) return { ok: false, error: 'bad_date', invalid: [from, until].filter((x) => String(x ?? '').trim() && !parseDate(x)) };
  if (b < a) return { ok: false, error: 'bad_range' };
  const days = [...new Set((weekdays || []).map((d) => +d).filter((d) => d >= 1 && d <= 7))];
  if (!days.length) return { ok: false, error: 'no_weekdays' };
  const out = [];
  for (let d = a; d <= b; d = addDays(d, 1)) {
    if (days.includes(weekdayIso(d))) out.push(d);
    if (out.length > 400) return { ok: false, error: 'too_many', count: out.length };
  }
  return { ok: true, dates: out };
}

/**
 * Sarja: jokainen päivä × jokainen alkuaika = yksi kerta. repeat {from, until, weekdays} lisää viikonpäivät,
 * ja ne yhdistetään dates-listaan. → { ok: true, patches } tai { ok: false, error }.
 */
export function buildSeries(input = {}) {
  let dateSource = input.dates;
  if (input.repeat) {
    const rep = repeatDates(input.repeat);
    if (!rep.ok) return rep;
    const extra = parseList(input.dates, parseDate);
    if (extra.invalid.length) return { ok: false, error: 'bad_date', invalid: extra.invalid };
    dateSource = [...new Set([...extra.values, ...rep.dates])].sort();
  }
  const ds = parseList(dateSource, parseDate), ts = parseList(input.times, parseTime);
  if (ds.invalid.length) return { ok: false, error: 'bad_date', invalid: ds.invalid };
  if (ts.invalid.length) return { ok: false, error: 'bad_time', invalid: ts.invalid };
  if (!ds.values.length) return { ok: false, error: 'no_dates' };
  if (!ts.values.length) return { ok: false, error: 'no_times' };
  const dur = intOr(input.duration_minutes), max = intOr(input.max_persons), min = intOr(input.min_persons), dl = intOr(input.deadline_minutes);
  if (!(dur >= 15 && dur <= 20160)) return { ok: false, error: 'bad_duration' };
  if (max !== null && !(max >= 1 && max <= 500)) return { ok: false, error: 'bad_max' };
  if (min !== null && !(min >= 1 && min <= 500)) return { ok: false, error: 'bad_min' };
  if (min !== null && max !== null && min > max) return { ok: false, error: 'min_over_max' };
  if (dl !== null && !(dl >= 0 && dl <= 20160)) return { ok: false, error: 'bad_deadline' };
  const n = ds.values.length * ts.values.length;
  if (n > MAX_SERIES) return { ok: false, error: 'too_many', count: n };
  const label = String(input.label ?? '').trim(), labelEn = String(input.label_en ?? '').trim();
  const patches = [];
  for (const date of ds.values) for (const time of ts.values) {
    const p = { date, start_time: time, duration_minutes: dur };
    if (max !== null) p.max_persons = max;
    if (min !== null) p.min_persons = min;
    if (dl !== null) p.deadline_minutes = dl;
    if (label) p.label = label;          // tyhjä → palvelin antaa oletusnimen (päivä + kellonaika)
    if (labelEn) p.label_en = labelEn;
    patches.push(p);
  }
  return { ok: true, patches };
}

/** Helsingin paikallinen aika 'YYYY-MM-DDTHH:MM' → UTC ISO (kesäaika huomioiden). */
export function helsinkiIso(local) {
  const [d, t] = String(local).split('T');
  const base = Date.parse(`${d}T${t || '00:00'}:00Z`);
  const off = (ms) => { const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: TZ, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' }).formatToParts(new Date(ms)).map((x) => [x.type, x.value]));
    return Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second) - ms; };
  let ms = base - off(base); ms = base - off(ms);
  return new Date(ms).toISOString();
}
/** ISO → Helsingin { date: 'YYYY-MM-DD', time: 'HH:MM' }. */
export function localParts(iso) {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: TZ, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }).formatToParts(new Date(iso)).map((x) => [x.type, x.value]));
  return { date: `${p.year}-${p.month}-${p.day}`, time: `${p.hour}:${p.minute}` };
}

/**
 * booking_202: siirto menneisyyteen estetään (palvelin tarkistaa saman). Vain jos päivä tai alkuaika muuttuu.
 * before/after = { date: 'YYYY-MM-DD', start_time: 'HH:MM' } Helsingin aikaa. now = Date (testejä varten).
 */
export function isPastMove(before, after, now = new Date()) {
  const t = (x) => String(x?.start_time || '').slice(0, 5);
  if (!after?.date || !t(after)) return false;
  if (before && before.date === after.date && t(before) === t(after)) return false;
  const n = localParts(now.toISOString());
  return `${after.date} ${t(after)}` <= `${n.date} ${n.time}`;
}

/**
 * Lohkon aikaväli (ms) kerran suhteen. occ = { starts_at, ends_at }.
 * block = { timing: 'relative', offset_min, minutes } tai { timing: 'clock', start: 'YYYY-MM-DDTHH:MM', end: 'YYYY-MM-DDTHH:MM' } (Helsingin aikaa)
 */
export function blockRange(occ, block) {
  const s0 = Date.parse(occ.starts_at);
  if (block.timing === 'clock') {
    const s = block.start ? Date.parse(helsinkiIso(block.start)) : NaN, e = block.end ? Date.parse(helsinkiIso(block.end)) : NaN;
    return { start: s, end: e };
  }
  const off = +block.offset_min, min = +block.minutes;
  return { start: s0 + off * 60000, end: s0 + (off + min) * 60000 };
}
/**
 * Validointi ennen tallennusta. → { ok, error?: 'no_resource'|'bad_mode'|'missing'|'end_before_start'|'too_far', warning?: 'outside_occurrence' }
 * Lohko saa olla kerran ulkopuolella (esim. lämmitys ennen alkua) → varoitus, ei virhe; palvelimen raja ±1 vrk.
 */
export function validateBlock(occ, block) {
  if (!(+block.resource_id > 0)) return { ok: false, error: 'no_resource' };
  if (block.mode && !MODES.includes(block.mode)) return { ok: false, error: 'bad_mode' };
  if (block.timing === 'relative') {
    if (block.offset_min === '' || block.offset_min == null || !Number.isInteger(+block.offset_min) || block.minutes === '' || block.minutes == null || !Number.isInteger(+block.minutes)) return { ok: false, error: 'missing' };
    if (+block.minutes <= 0) return { ok: false, error: 'end_before_start' };
  } else if (!block.start || !block.end) return { ok: false, error: 'missing' };
  const r = blockRange(occ, block);
  if (!Number.isFinite(r.start) || !Number.isFinite(r.end)) return { ok: false, error: 'missing' };
  if (r.end <= r.start) return { ok: false, error: 'end_before_start' };
  const s0 = Date.parse(occ.starts_at), e0 = Date.parse(occ.ends_at), day = 864e5;
  if (r.start < s0 - day || r.end > e0 + day) return { ok: false, error: 'too_far' };
  return { ok: true, warning: r.start < s0 || r.end > e0 ? 'outside_occurrence' : null };
}
/** Palvelimen lohko (_event_block_json) → muokattava rivi. */
export function blockToRow(b, occ) {
  if (b.timing === 'relative' || b.offset_min != null) return { resource_id: b.resource_id, mode: b.mode || 'exclusive', timing: 'relative', offset_min: b.offset_min, minutes: b.minutes, end_min: b.offset_min + b.minutes, note: b.note || '' };
  const s = localParts(b.starts_at), e = localParts(b.ends_at);
  return { resource_id: b.resource_id, mode: b.mode || 'exclusive', timing: 'clock', start: `${s.date}T${s.time}`, end: `${e.date}T${e.time}`, note: b.note || '', _occ: occ?.id };
}
/** Muokattavat rivit → admin_event_blocks_set p_blocks. Suhteellinen: offset_min + minutes; kellonaika: ISO-aikaleimat aikavyöhykkeineen. */
export function blocksPayload(rows) {
  return rows.map((r) => {
    const base = { resource_id: +r.resource_id, mode: r.mode || 'exclusive' };
    const note = String(r.note ?? '').trim(); if (note) base.note = note.slice(0, 500);
    return r.timing === 'relative' ? { ...base, offset_min: +r.offset_min, minutes: +r.minutes } : { ...base, starts_at: helsinkiIso(r.start), ends_at: helsinkiIso(r.end) };
  });
}
/** Aikajanan palkit: ikkuna = kerta + lohkot; left/width prosentteina (CSS). */
export function timeline(occ, rows) {
  const s0 = Date.parse(occ.starts_at), e0 = Date.parse(occ.ends_at);
  const rs = rows.map((r) => blockRange(occ, r)).filter((r) => Number.isFinite(r.start) && Number.isFinite(r.end) && r.end > r.start);
  const lo = Math.min(s0, ...rs.map((r) => r.start)), hi = Math.max(e0, ...rs.map((r) => r.end)), span = Math.max(1, hi - lo);
  const pct = (a, b) => ({ left: Math.round(((a - lo) / span) * 1000) / 10, width: Math.max(1, Math.round(((b - a) / span) * 1000) / 10) });
  return { occ: pct(s0, e0), bars: rows.map((r) => { const x = blockRange(occ, r); return Number.isFinite(x.start) && Number.isFinite(x.end) && x.end > x.start ? pct(x.start, x.end) : null; }), from: new Date(lo).toISOString(), to: new Date(hi).toISOString() };
}

/** Valittavat resurssit: aktiiviset tilat ja henkilöt (saunottajat). Kapasiteettipoolit ja kertojen automaattiset poolit (event_rule_<id>) piiloon. */
export function selectableResources(resources) {
  const ok = (r) => r && r.active !== false && r.kind !== 'capacity_pool' && !String(r.code || '').startsWith('event_rule_') && r.code !== 'ei_resurssia' && (r.kind == null || r.kind === 'space' || r.kind === 'person');
  const list = (resources || []).filter(ok);
  return { spaces: list.filter((r) => r.kind !== 'person'), persons: list.filter((r) => r.kind === 'person') };
}
/** Tuotteen kanavat: palvelimen tehollinen lista; puuttuu → oletus kategoriasta (training → widget, muut → shop). */
export function channelsOf(p) {
  if (Array.isArray(p?.channels)) return p.channels.filter((c) => CHANNELS.includes(c));
  return p?.category === 'training' ? ['widget'] : ['shop'];
}
export const normChannels = (list) => CHANNELS.filter((c) => (list || []).includes(c));

/** Kopion nimi kuten palvelin (admin_product_copy / admin_event_copy): 'Kopio: <nimi>' (enintään 200 merkkiä). */
export const copyName = (name) => `Kopio: ${String(name ?? '')}`.slice(0, 200);
/** Kopiointidialogin argumentit. Tuote: { p_product_id }; tapahtuma: + kerrat mukaan + siirto päivinä (−3650…3650). */
export function copyArgs({ product_id, event = false, include_rules = false, shift_days = 0 } = {}) {
  const id = +product_id;
  if (!(Number.isInteger(id) && id > 0)) return { ok: false, error: 'invalid_param' };
  if (!event) return { ok: true, fn: 'admin_product_copy', args: { p_product_id: id } };
  const sd = shift_days === '' || shift_days == null ? 0 : +shift_days;
  if (!Number.isInteger(sd) || sd < -3650 || sd > 3650) return { ok: false, error: 'bad_shift' };
  return { ok: true, fn: 'admin_event_copy', args: { p_product_id: id, p_include_rules: !!include_rules, p_shift_days: include_rules ? sd : 0 } };
}

/** Kerran tila listaan: myyty / max, jonossa, menneisyys. */
export function occSummary(r, now = Date.now()) {
  const sold = +r.sold_persons || 0, max = r.max_persons == null ? null : +r.max_persons;
  return { sold, max, remaining: max == null ? null : Math.max(0, max - sold), full: max != null && sold >= max, waitlist: +r.waitlist_count || 0, past: Date.parse(r.ends_at) < now, active: r.active !== false };
}
/**
 * Kaupallinen tila. saleEnabled=false (events.sale_enabled) → sales_closed, paitsi peruttu tai mennyt.
 * full jää lipuksi, jotta täysi kerta näkyy myös myynnin ollessa kiinni.
 * status: on_sale | full | cancelled | sales_closed | past
 */
export function occurrenceFlags(rule, { saleEnabled = true, now = Date.now() } = {}) {
  const s = occSummary(rule || {}, now);
  const cancelled = !!rule?.cancelled_at;
  const start = rule?.starts_at ? Date.parse(rule.starts_at) : NaN;
  const deadline = rule?.deadline_minutes == null || rule?.deadline_minutes === '' ? 0 : +rule.deadline_minutes;
  const deadlineClosed = !s.past && !cancelled && Number.isFinite(start) && deadline > 0 && now >= start - deadline * 60000;
  const inactive = rule?.active === false && !cancelled;
  let status = 'on_sale';
  if (cancelled) status = 'cancelled';
  else if (s.past) status = 'past';
  else if (inactive || deadlineClosed || saleEnabled === false) status = 'sales_closed';
  else if (s.full) status = 'full';
  return { ...s, status, cancelled, deadlineClosed, shopClosed: saleEnabled === false };
}
/** Varaukset, jotka estävät poiston (kaikki rivit, ei vain aktiiviset). Puuttuva luku → myyty määrä. */
export function bookingCount(rule) {
  if (rule?.reservation_count != null && rule.reservation_count !== '') return +rule.reservation_count || 0;
  return +rule?.sold_persons || 0;
}

const PROVIDER_RE = /montonio|visma|paybyway|mobilepay|vipps|paytrail|\bstripe\b|\bpaypal\b|\bnets\b/i;
/** Henkilökunnan viesti. Maksuvälittäjän nimeä ei hyväksytä. Allekirjoitusta ei tallenneta tähän — sen lisää lähetys. */
export function messageDraft({ subject, body } = {}) {
  const sub = String(subject ?? '').replace(/\s+/g, ' ').trim();
  const text = String(body ?? '').replace(/\u0000/g, '').trim();
  if (!sub) return { ok: false, error: 'no_subject' };
  if (sub.length > 200) return { ok: false, error: 'subject_long' };
  if (!text) return { ok: false, error: 'no_body' };
  if (text.length > 4000) return { ok: false, error: 'body_long' };
  if (PROVIDER_RE.test(sub) || PROVIDER_RE.test(text)) return { ok: false, error: 'provider_name' };
  return { ok: true, subject: sub, body: text };
}
/** Sama kuin send-emails/templates.ts: oma tervehdys tekstin alussa → pohjan tervehdys pois (ei kaksoistervehdystä). */
export const OWN_GREETING_RE = /^\s*(hei|heippa|moi|moikka|terve|tervehdys|hyvää (huomenta|päivää|iltaa)|hello|hi|dear|good (morning|afternoon|evening))(?=[\s,!.:]|$)[^\n]{0,60}(\n|$)/i;
/** Esikatselu samaan järjestykseen kuin sähköpostipohja: tervehdys, teksti, tapahtuma, aika. Ei automaattista allekirjoitusta (booking_213): henkilökunta kirjoittaa sen itse. */
export function customerMessageText({ subject, body, eventName, whenText, lang = 'fi' } = {}) {
  const d = messageDraft({ subject, body });
  if (!d.ok) return d;
  const en = lang === 'en';
  const hello = en ? 'Hello,' : 'Hei,';
  const what = String(eventName ?? '').trim();
  const when = String(whenText ?? '').trim();
  const about = [what && (en ? `Event: ${what}` : `Tapahtuma: ${what}`), when && (en ? `Time: ${when}` : `Aika: ${when}`)].filter(Boolean).join('\n');
  const own = OWN_GREETING_RE.test(d.body);
  const text = `${own ? '' : `${hello}\n\n`}${d.body}${about ? `\n\n${about}` : ''}\n`;
  return { ok: true, subject: d.subject, body: d.body, text, signature: null };
}

export const PARTICIPANT_CSV_FIELDS = ['occurrence', 'name', 'email', 'phone', 'persons', 'order_status', 'payment_status', 'booked_at', 'extra', 'note'];
/** Excel-ystävällinen CSV: UTF-8 BOM, puolipiste, CRLF, kaavainjektio estetty. */
export function participantsToCsv(rows, headers) {
  const cols = PARTICIPANT_CSV_FIELDS;
  const head = (headers || cols).map((h) => csvText(h));
  if (head.length !== cols.length) return '';
  const lines = [head.join(';')];
  for (const r of rows || []) lines.push(cols.map((c) => csvText(r?.[c] ?? '')).join(';'));
  return `\uFEFF${lines.join('\r\n')}\r\n`;
}
/** Konfliktilista virheestä (admin_event_blocks_set: details.hint = JSON-taulukko). Tuntematon muoto → []. */
export function conflictsOf(e) {
  let v = e?.details?.hint ?? e?.hint ?? null;
  if (typeof v === 'string') { try { v = JSON.parse(v); } catch { v = null; } }
  return Array.isArray(v) ? v.filter((x) => x && typeof x === 'object').map((x) => ({ resource_id: x.resource_id, resource_name: String(x.resource_name ?? ''), starts_at: x.starts_at, ends_at: x.ends_at, reason: String(x.reason ?? '') })) : [];
}
