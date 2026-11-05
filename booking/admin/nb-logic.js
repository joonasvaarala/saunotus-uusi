// Uusi varaus -lomakkeen puhdas logiikka (ei DOMia, ei sb.js:ää) → node --test. Näkymä: views/newbooking.js.

// Lisäpalvelun enimmäismäärä: henkilömäärä × enintään/hlö (oletus 99), korkeintaan 99
export const addonLimit = (a, persons) => Math.min((a.max_per_person ?? 99) * Math.max(0, persons || 0), 99);

// Vuoron hinta henkilömäärälle (sama laskenta kuin palvelimella; näytetään vain arviona, palvelin laskee lopullisen)
export const priceFor = (s, n) => (s.price_mode === 'per_person' ? s.unit_price * n : s.price_mode === 'fixed' ? s.base_price : s.base_price + Math.max(0, n - (s.included_persons || 0)) * (s.extra_person_price || 0));

// Normaali henkilömäärä ilman ylibuukkausta: vähintään min_persons, enintään max_persons (oletus 50) ja vapaat paikat.
export function personsRange(s) {
  const min = Math.max(1, +s.min_persons || 1);
  return { min, max: Math.min(+s.max_persons || 50, +s.remaining) };
}

// Henkilökunta saa syöttää yli kapasiteetin. Stepperin katto on korkea; varoitus ja vahvistus tulevat erikseen.
export const STAFF_PERSONS_MAX = 99;
export const staffPersonsMax = (s) => Math.max(Math.max(1, +s?.min_persons || 1), STAFF_PERSONS_MAX);

// Välitön kapasiteettivaroitus. pool_capacity + pool_peak tulevat admin_day_viewsta (käytetty/kapasiteetti).
export function capacityNotice(session, persons) {
  if (!session) return null;
  const n = Math.max(0, Number(persons) || 0);
  const max = session.max_persons == null || session.max_persons === '' ? null : Number(session.max_persons);
  const cap = session.pool_capacity == null || session.pool_capacity === '' ? null : Number(session.pool_capacity);
  const peak = session.pool_peak == null || session.pool_peak === '' ? null : Number(session.pool_peak);
  const free = session.remaining == null || session.remaining === '' ? null : Number(session.remaining);
  if (cap != null && peak != null && Number.isFinite(cap) && peak + n > cap) {
    return { kind: 'overbook', code: 'capacity_exceeded', used: peak + n, capacity: cap };
  }
  if (cap == null && free != null && session.mode !== 'exclusive' && n > free) {
    return { kind: 'overbook', code: 'capacity_soft', persons: n, free: Math.max(0, free) };
  }
  if (max != null && n > max) return { kind: 'overbook', code: 'persons_max', persons: n, max };
  if (session.status === 'full' && session.mode !== 'exclusive') {
    return { kind: 'overbook', code: 'capacity_exceeded', used: n, capacity: Math.max(0, free ?? 0) };
  }
  return null;
}

// Yksityinen päällekkäisyys: palvelin merkitsee private_conflict. Ilman kenttää unavailable ilman sulkua on sama tilanne.
export function isPrivateConflict(session) {
  if (!session) return false;
  if (session.private_conflict === true) return true;
  if (session.private_conflict === false) return false;
  return session.status === 'unavailable' && !session.blocked;
}

export function slotKind(session) {
  if (!session) return 'na';
  if (isPrivateConflict(session)) return 'private';
  if (session.status === 'available') return 'free';
  if (session.status === 'full') return 'full';
  if (session.status === 'unavailable' || session.blocked) return 'closed';
  if (session.status === 'off_schedule' || session.off_schedule) return 'off';
  return 'na';
}

export function slotBookable(session) {
  const k = slotKind(session);
  return k === 'free' || k === 'full' || k === 'closed' || k === 'off';
}

export function conflictNotice(session) {
  if (!isPrivateConflict(session)) return null;
  return { kind: 'conflict', code: session.mode === 'exclusive' ? 'public_shift_booked' : 'private_booked' };
}

// Aikataulun ulkopuolinen syy: ei vuoroa, sulku, aikaikkuna tai muu kuin vuoron kellonaika.
export function scheduleNotice(session) {
  if (!session) return null;
  if (isPrivateConflict(session)) return null;
  if (session.blocked || session.off_code === 'closure' || session.status === 'unavailable' && session.blocked) {
    return { kind: 'off', code: 'closure' };
  }
  if (session.off_schedule || session.status === 'off_schedule') {
    return { kind: 'off', code: session.off_code || 'no_session' };
  }
  if (session.status === 'unavailable' && session.mode !== 'exclusive') return { kind: 'off', code: 'closure' };
  return null;
}

export function bookingNotices(session, persons) {
  return [conflictNotice(session), capacityNotice(session, persons), scheduleNotice(session)].filter(Boolean);
}

// Ei-admin: kapasiteetin ja henkilömäärän ylitys on kova esto. Aikataulun ulkopuolinen varaus säilyy.
export function presentNotices(notices, isAdmin) {
  const list = notices || [];
  if (isAdmin) return list;
  return list.map((n) => (n && n.kind === 'overbook' ? { ...n, kind: 'admin_only' } : n));
}

export function bookingAction(notices, isAdmin) {
  const shown = presentNotices(notices, isAdmin);
  const blocked = shown.filter((n) => n && (n.kind === 'conflict' || n.kind === 'admin_only'));
  return {
    shown,
    blocked,
    allowOverbook: !!isAdmin && shown.some((n) => n && n.kind === 'overbook'),
    allowOff: shown.some((n) => n && n.kind === 'off'),
  };
}

export const applyDiscount = (total, discount) => {
  const d = Math.max(0, Number(discount) || 0);
  return Math.round(((Number(total) || 0) - d) * 100) / 100;
};

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

// Maksulinkki (payment_link): ei merkitä maksetuksi; sähköposti pakollinen.
export const isPaymentLinkMethod = (code) => code === 'payment_link';
export const paidDefaultFor = (code) => (isPaymentLinkMethod(code) ? false : paidDefault(code));

// Asiakkaan sähköposti: valittu asiakas tai lomakkeen arvo. Maksulinkki vaatii kelvollisen osoitteen.
export function emailForBooking({ customer, formEmail } = {}) {
  const raw = customer?.email != null ? customer.email : formEmail;
  const email = String(raw ?? '').trim().toLowerCase();
  return email || null;
}
export function looksLikeEmail(email) {
  if (!email) return false;
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(email).trim());
}

// Tallennusvalidaatio (UI): maksulinkki → email pakollinen, paid kielletty.
export function validatePaymentLink({ method, customer, formEmail } = {}) {
  if (!isPaymentLinkMethod(method)) return { ok: true, errors: [] };
  const email = emailForBooking({ customer, formEmail });
  const errors = [];
  if (!looksLikeEmail(email)) errors.push({ code: 'email_required', field: 'email' });
  return { ok: errors.length === 0, errors, email };
}

// RPC-payload admin_create_bookingille. payment_link → p_paid aina false.
export function buildCreateBookingPayload({
  ruleId, date, persons, customerId = null, customer = null,
  method = 'pay_later', paid = false, note = null, price = null,
  addons = null, invoiceReference = null, discountCode = null,
  giftCardCode = null, remainderMethod = null,
  allowOverbook = false, allowOffSchedule = false, start = null, end = null,
} = {}) {
  const link = isPaymentLinkMethod(method);
  const gift = method === 'gift_card';
  const payload = {
    p_rule_id: ruleId,
    p_date: date,
    p_persons: persons,
    p_payment_method: gift ? 'gift_card' : method,
    p_paid: link ? false : (gift ? !!remainderMethod && !!paid : !!paid),
    p_note: note || null,
    p_price: price,
    p_addons: addons && addons.length ? addons : null,
    p_invoice_reference: invoiceReference || null,
    p_discount_code: discountCode || null,
    p_gift_card_code: gift ? (giftCardCode || null) : null,
    p_remainder_method: gift ? (remainderMethod || null) : null,
    p_allow_overbook: !!allowOverbook,
    p_allow_off_schedule: !!allowOffSchedule,
    p_start: start || null,
    p_end: end || null,
  };
  if (customerId != null) payload.p_customer_id = customerId;
  else if (customer != null) payload.p_customer = customer;
  return payload;
}

// Onnistumisviesti: maksulinkki → "varaus + linkki lähetetty".
export function createdMessageKind(result) {
  if (result && (result.payment_link === true || result.payment_link === 'true')) return 'link';
  return 'plain';
}
