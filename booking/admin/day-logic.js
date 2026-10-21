// Päivänäkymän puhdas logiikka (ei DOM:ia): päivän tuotto ja tapahtumien sijoittelu vuorolistaan.
// Sama sääntö kuin booking.admin_day_extras (migraatio booking_68). UI laskee näytettävän summan täällä
// revenue_rows-riveistä, jotta selain ja node --test käyttävät samaa koodia.
// Sääntö: docs/paivanakyma-tuotto.md

const TZ = 'Europe/Helsinki';
export const ACTIVE_STATUSES = ['pending', 'confirmed', 'completed'];
const INCLUDED = new Set(['confirmed', 'completed']);
const UNPAID = new Set(['unpaid', 'pending', 'failed']);

export function helsinkiDate(iso) {
  const d = new Date(iso);
  if (Number.isNaN(+d)) return null;
  return d.toLocaleDateString('sv-SE', { timeZone: TZ });
}

// 'YYYY-MM-DD' + kellonaika Helsingissä → UTC-ISO. Sama lasku kuin ui.helsinkiIso.
export function clockIso(date, hour, minute) {
  const hh = String(hour).padStart(2, '0');
  const mm = String(minute).padStart(2, '0');
  const base = new Date(`${date}T${hh}:${mm}:00Z`).getTime();
  const off = new Date(new Date(base).toLocaleString('en-US', { timeZone: TZ })) - new Date(new Date(base).toLocaleString('en-US', { timeZone: 'UTC' }));
  return new Date(base - off).toISOString();
}

function num(n) {
  const x = Number(n);
  return Number.isFinite(x) ? x : 0;
}
function cents(n) { return Math.round(num(n) * 100); }
function fromCents(c) { return c / 100; }

// pending + päättynyt tai puuttuva pito = vanhentunut (sama kuin admin_list_reservations). Piilotettu rivi ei kuulu mukaan.
export function effectiveStatus(row, now = new Date()) {
  if (!row || row.hidden) return 'hidden';
  if (row.status === 'pending') {
    const hold = row.hold_expires_at ? new Date(row.hold_expires_at) : null;
    if (!hold || Number.isNaN(+hold) || hold.getTime() <= now.getTime()) return 'expired';
  }
  return row.status || '';
}

export function summarizeRevenue(rows, date, now = new Date()) {
  const acc = { gross: 0, vat: 0, net: 0, count: 0, pending_gross: 0, pending_count: 0, unpaid_gross: 0, unpaid_count: 0 };
  for (const row of rows || []) {
    if (date && helsinkiDate(row.starts_at) !== date) continue;
    const st = effectiveStatus(row, now);
    if (st === 'hidden' || st === 'cancelled' || st === 'expired' || st === 'no_show') continue;
    const gross = cents(row.line_gross);
    const vat = cents(row.line_vat);
    const net = cents(row.line_net);
    if (st === 'pending') {
      acc.pending_gross += gross;
      acc.pending_count += 1;
      continue;
    }
    if (!INCLUDED.has(st)) continue;
    acc.gross += gross;
    acc.vat += vat;
    acc.net += net;
    acc.count += 1;
    if (UNPAID.has(row.payment_status)) {
      acc.unpaid_gross += gross;
      acc.unpaid_count += 1;
    }
  }
  return {
    basis: 'visit_start',
    vat_basis: 'gross_incl_vat',
    currency: 'EUR',
    gross: fromCents(acc.gross),
    vat: fromCents(acc.vat),
    net: fromCents(acc.net),
    count: acc.count,
    pending_gross: fromCents(acc.pending_gross),
    pending_count: acc.pending_count,
    unpaid_gross: fromCents(acc.unpaid_gross),
    unpaid_count: acc.unpaid_count,
  };
}

// Päivän tuotto näkyy vain ylläpitäjille. Muut päivänäkymän roolit näkevät vuorot ja tapahtumat.
export function canSeeDayRevenue(role) {
  return role === 'admin' || role === 'manager';
}

// extras = admin_day_revenue- tai admin_day_extras-vastaus tai null (funktiota ei vielä ole). Tyhjä revenue_rows = aito 0 €.
export function revenueView(extras, date, now = new Date()) {
  if (!extras || !Array.isArray(extras.revenue_rows)) return { available: false };
  const rev = summarizeRevenue(extras.revenue_rows, date, now);
  return { available: true, ...rev, showPending: rev.pending_count > 0, showUnpaid: rev.unpaid_count > 0 };
}

export function eventsOnDay(events, date) {
  return (events || []).filter((e) => {
    if (!e || e.active === false) return false;
    const start = e.starts_on;
    const end = e.ends_on || e.starts_on;
    return !!(start && end && start <= date && end >= date);
  });
}

export function eventTimeLabel(event) {
  const text = String(event?.time_text || '').trim();
  if (text) return { kind: 'text', text };
  const parts = event?.participants || [];
  const starts = parts.map((p) => p.starts_at).filter(Boolean).sort();
  const ends = parts.map((p) => p.ends_at).filter(Boolean).sort();
  if (starts.length && ends.length) return { kind: 'range', start: starts[0], end: ends[ends.length - 1] };
  return { kind: 'all_day' };
}

// Järjestys aikajanalla. Kelloteksti (time_text) on aikataulu; ilman kelloa tapahtuma menee päivän loppuun (null).
export function eventSortIso(event, date) {
  const label = eventTimeLabel(event);
  if (label.kind === 'range') return label.start;
  if (label.kind === 'text' && date) {
    const hm = label.text.match(/(\d{1,2})[.:](\d{2})/);
    if (hm) return clockIso(date, hm[1], hm[2]);
    const h = label.text.match(/(?:klo\s+)?(\d{1,2})\s*[–\-]/i);
    if (h) return clockIso(date, h[1], 0);
  }
  return null;
}

function sameId(a, b) {
  return a != null && b != null && String(a) === String(b);
}

function instantMs(v) {
  if (v == null || v === '') return null;
  const t = Date.parse(v);
  return Number.isNaN(t) ? null : t;
}

function sameInstant(a, b) {
  const x = instantMs(a);
  const y = instantMs(b);
  return x != null && y != null && x === y;
}

function shiftMs(session) {
  const a = instantMs(session.starts_at);
  const b = instantMs(session.ends_at);
  if (a == null || b == null) return Number.POSITIVE_INFINITY;
  return b - a;
}

function shortestSession(list) {
  return list.slice().sort((a, b) => {
    const d = shiftMs(a) - shiftMs(b);
    if (d) return d;
    return String(a.rule_id ?? '').localeCompare(String(b.rule_id ?? ''))
      || String(a.ends_at ?? '').localeCompare(String(b.ends_at ?? ''));
  })[0];
}

// Lahjakortilla tehty varaus (Johku-tuonti: tilausrivin nimi "Yleinen vuoro - Lahjakorttivaraus", Johku-tuote 119).
// Tuonti kirjasi rivin tuotteelle 1 (Yleinen vuoro) viikonpäivästä riippumatta ja usein 30 min saapumisikkunana.
// Varaus on silti samassa kapasiteettipoolissa kuin sen hetken tavallinen vuoro, joten se kuuluu sen vuoron alle.
const GIFT_SUFFIX = /\s*[-–—]\s*(?:lahjakorttivaraus|gift card (?:booking|reservation))\s*$/i;
export function isGiftCardReservation(r) {
  if (!r) return false;
  if (r.gift_card === true || r.is_gift_card === true) return true;
  return GIFT_SUFFIX.test(String(r.product_name || ''));
}

// Tuotteen nimi ilman "- Lahjakorttivaraus"-liitettä (tuotteen oikea nimi).
export function cleanProductName(name) {
  return String(name || '').replace(GIFT_SUFFIX, '').trim();
}

// Normalisoitu ryhmittelyavain: Helsingin päivä + alku + loppu (hetkinä, ei merkkijonoina) + tuote.
export function dayGroupKey(r) {
  const start = instantMs(r?.starts_at);
  const end = instantMs(r?.ends_at);
  return [start == null ? '' : helsinkiDate(r.starts_at), start ?? String(r?.starts_at ?? ''), end ?? String(r?.ends_at ?? ''), r?.product_id ?? ''].join('|');
}

// Samaan aikaan alkavat säännöt (eri ends_at) eivät jaa samaa varausta.
// rule_id jos se on, muuten tarkka alku+loppu, muuten yksi kortti: lyhin samaan aikaan alkava vuoro.
// Lahjakorttivaraus: jos saman tuotteen vuoroa ei ole, samaan aikaan alkava tavallinen yhteisvuoro (mode shared).
function sessionForReservation(reservation, sessions) {
  const sameProduct = sessions.filter((s) => sameId(s.product_id, reservation.product_id));
  if (reservation.rule_id != null && reservation.rule_id !== '') {
    const byRule = sameProduct.filter((s) => sameId(s.rule_id, reservation.rule_id));
    if (byRule.length) return shortestSession(byRule);
  }
  const bySpan = sameProduct.filter((s) => sameInstant(s.starts_at, reservation.starts_at) && sameInstant(s.ends_at, reservation.ends_at));
  if (bySpan.length) return shortestSession(bySpan);
  const byStart = sameProduct.filter((s) => sameInstant(s.starts_at, reservation.starts_at));
  if (byStart.length) return shortestSession(byStart);
  if (isGiftCardReservation(reservation)) {
    const shared = sessions.filter((s) => s.mode === 'shared' && sameInstant(s.starts_at, reservation.starts_at));
    const sharedSpan = shared.filter((s) => sameInstant(s.ends_at, reservation.ends_at));
    if (sharedSpan.length) return shortestSession(sharedSpan);
    if (shared.length) return shortestSession(shared);
  }
  return null;
}

// Vuorokortit, tapahtumakortit ja muut varaukset (slot). Tapahtuman osallistuja ei toistu slotissa.
// Varaus, jolla ei ole tapahtumapäivää, jää slotiksi (kuten ennen).
// Jokainen varaus kuuluu enintään yhteen vuorokorttiin. Tyhjä unavailable/closed -kortti pysyy piilossa.
export function assignDayCards({ sessions, reservations, events, date }) {
  const list = sessions || [];
  // Sama varaus kahdesti syötteessä (esim. lista + päivänäkymä) lasketaan vain kerran.
  const seen = new Set();
  const active = (reservations || []).filter((r) => {
    if (!r || !ACTIVE_STATUSES.includes(r.status)) return false;
    if (r.reservation_id == null) return true;
    const id = String(r.reservation_id);
    if (seen.has(id)) return false;
    seen.add(id);
    return true;
  });
  const eventCards = eventsOnDay(events, date).map((event) => ({
    event,
    participants: (event.participants || []).filter((p) => ACTIVE_STATUSES.includes(p.status)),
  }));
  const eventIds = new Set();
  for (const card of eventCards) for (const p of card.participants) if (p.reservation_id != null) eventIds.add(p.reservation_id);
  const used = new Set(eventIds);
  const mineBySession = new Map();
  for (const r of active) {
    if (eventIds.has(r.reservation_id)) continue;
    const session = sessionForReservation(r, list);
    if (!session) continue;
    if (!mineBySession.has(session)) mineBySession.set(session, []);
    mineBySession.get(session).push(r);
    used.add(r.reservation_id);
  }
  const sessionCards = list.map((session) => ({ session, reservations: mineBySession.get(session) || [] }))
    .filter(({ session, reservations: mine }) => mine.length || ['available', 'full'].includes(session.status));
  const slotMap = new Map();
  for (const r of active) {
    if (used.has(r.reservation_id)) continue;
    const k = dayGroupKey(r);   // lahjakorttivaraus samaan ryhmään kuin saman tuotteen tavallinen varaus
    if (!slotMap.has(k)) slotMap.set(k, []);
    slotMap.get(k).push(r);
  }
  const slots = [...slotMap.values()].map((g) => g.slice().sort((a, b) => Number(isGiftCardReservation(a)) - Number(isGiftCardReservation(b))));
  return {
    sessions: sessionCards,
    events: eventCards,
    slots,
    empty: sessionCards.length + eventCards.length + slots.length === 0,
  };
}

// Slot-ryhmän otsikko: tuotteen oikea nimi (kb), muuten tilausrivin nimi ilman "- Lahjakorttivaraus"-liitettä.
export function slotTitle(list, productName) {
  const own = String(productName || '').trim();
  if (own) return own;
  const plain = (list || []).find((r) => r && !isGiftCardReservation(r) && r.product_name);
  if (plain) return plain.product_name;
  const first = (list || []).find((r) => r && r.product_name);
  return first ? cleanProductName(first.product_name) : '';
}

// Vuoron henkilömäärä: kaikki kortin varaukset (myös lahjakorttivaraukset) kerran. Vapaana tulee palvelimelta (pooli), ei lasketa tässä.
export function sumPersons(list) {
  return (list || []).reduce((a, r) => a + Math.max(0, Number(r?.persons) || 0), 0);
}
