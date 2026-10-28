// Uusi varaus ja siirto: alennuskoodi, lahjakortti, ylibuukkaus, aikataulun ulkopuolella.
// Avaimet ui.admin.booking.*. public_get_site_texts peittää sanakirjan. Tuonti: content/site-texts.pending-import-89.json.
import { getLang } from './talous-i18n.js';

export const PREFIX = 'ui.admin.booking.';

export const BOOKING_TEXTS = {
  fi: {
    'ui.admin.booking.discount': 'Alennuskoodi',
    'ui.admin.booking.discount_ph': 'Esim. KIITOSKAUPPA',
    'ui.admin.booking.discount_apply': 'Käytä koodi',
    'ui.admin.booking.discount_remove': 'Poista koodi',
    'ui.admin.booking.discount_line': 'Alennus {code}',
    'ui.admin.booking.discount_ok': 'Koodi {code} käytössä, alennus {amount}.',
    'ui.admin.booking.discount_checking': 'Tarkistetaan koodia…',
    'ui.admin.booking.gift_code': 'Lahjakortin koodi',
    'ui.admin.booking.gift_ph': 'Koodi',
    'ui.admin.booking.gift_check': 'Tarkista',
    'ui.admin.booking.gift_ok': 'Saldo {balance}, voimassa {until}.',
    'ui.admin.booking.gift_ok_open': 'Saldo {balance}.',
    'ui.admin.booking.gift_rest': 'Lahjakortti kattaa {covered}. Jäljelle jää {rest}.',
    'ui.admin.booking.gift_rest_method': 'Loppusumman maksutapa',
    'ui.admin.booking.gift_rest_unpaid': 'Jätä maksamatta',
    'ui.admin.booking.gift_covers': 'Lahjakortti kattaa koko summan.',
    'ui.admin.booking.gift_need_code': 'Anna lahjakortin koodi.',
    'ui.admin.booking.gift_required': 'Lahjakorttimaksu tarvitsee lahjakortin koodin.',
    'ui.admin.booking.over_capacity': 'Vuoron kapasiteetti ylittyy: {used}/{capacity} henkilöä',
    'ui.admin.booking.over_soft': 'Henkilömäärä ylittää vapaat paikat: valittu {persons}, vapaana {free}.',
    'ui.admin.booking.over_max': 'Palvelun enimmäishenkilömäärä ylittyy: {persons}/{max}',
    'ui.admin.booking.over_conflict': 'Resurssi on jo varattu tälle ajalle (sama tila tai saunottaja).',
    'ui.admin.booking.over_title': 'Ylibuukkaus',
    'ui.admin.booking.over_ask': 'Haluatko varmasti ylibuukata?',
    'ui.admin.booking.off_title': 'Aikataulun ulkopuolella',
    'ui.admin.booking.off_ask': 'Haluatko varmasti jatkaa?',
    'ui.admin.booking.off_no_rule': 'Tälle päivälle ei ole vuoroa aikataulussa.',
    'ui.admin.booking.off_closed': 'Päivä on suljettu tai aukioloaikojen ulkopuolella.',
    'ui.admin.booking.off_hours': 'Aika on vuoron normaalin aikataulun ulkopuolella.',
    'ui.admin.booking.off_closure': 'Aika osuu sulkukalenteriin.',
    'ui.admin.booking.off_window': 'Aika on hoitojen ja saunotusten aikaikkunan ulkopuolella.',
    'ui.admin.booking.off_open': 'Varaa aikataulun ulkopuolelle',
    'ui.admin.booking.off_time': 'Alkuaika',
    'ui.admin.booking.off_rule': 'Vuoro, jota käytetään mallina',
    'ui.admin.booking.off_hint': 'Varaus tehdään, vaikka päivälle ei ole sääntöä, sauna on suljettu tai aika on aukioloaikojen ulkopuolella.',
    'ui.admin.booking.confirm_yes': 'Kyllä, jatka',
    'ui.admin.booking.confirm_no': 'Peruuta',
    'ui.admin.booking.both_title': 'Poikkeus aikataulusta',
    'ui.admin.booking.slot_full': 'täynnä – voi ylibuukata',
    'ui.admin.booking.slot_closed': 'suljettu – voi varata silti',
    'ui.admin.booking.change_need': 'Valitse uusi vuoro, aika tai henkilömäärä.',
  },
  en: {
    'ui.admin.booking.discount': 'Discount code',
    'ui.admin.booking.discount_ph': 'E.g. KIITOSKAUPPA',
    'ui.admin.booking.discount_apply': 'Apply code',
    'ui.admin.booking.discount_remove': 'Remove code',
    'ui.admin.booking.discount_line': 'Discount {code}',
    'ui.admin.booking.discount_ok': 'Code {code} applied, discount {amount}.',
    'ui.admin.booking.discount_checking': 'Checking the code…',
    'ui.admin.booking.gift_code': 'Gift card code',
    'ui.admin.booking.gift_ph': 'Code',
    'ui.admin.booking.gift_check': 'Check',
    'ui.admin.booking.gift_ok': 'Balance {balance}, valid until {until}.',
    'ui.admin.booking.gift_ok_open': 'Balance {balance}.',
    'ui.admin.booking.gift_rest': 'The gift card covers {covered}. {rest} remains.',
    'ui.admin.booking.gift_rest_method': 'Payment method for the rest',
    'ui.admin.booking.gift_rest_unpaid': 'Leave unpaid',
    'ui.admin.booking.gift_covers': 'The gift card covers the whole amount.',
    'ui.admin.booking.gift_need_code': 'Enter the gift card code.',
    'ui.admin.booking.gift_required': 'A gift card payment needs the gift card code.',
    'ui.admin.booking.over_capacity': 'Session capacity exceeded: {used}/{capacity} people',
    'ui.admin.booking.over_soft': 'The number of guests exceeds the free places: chosen {persons}, free {free}.',
    'ui.admin.booking.over_max': 'The service maximum is exceeded: {persons}/{max}',
    'ui.admin.booking.over_conflict': 'The resource is already booked at this time (same room or therapist).',
    'ui.admin.booking.over_title': 'Overbooking',
    'ui.admin.booking.over_ask': 'Do you really want to overbook?',
    'ui.admin.booking.off_title': 'Outside the schedule',
    'ui.admin.booking.off_ask': 'Do you really want to continue?',
    'ui.admin.booking.off_no_rule': 'There is no session on this day in the schedule.',
    'ui.admin.booking.off_closed': 'The day is closed or outside opening hours.',
    'ui.admin.booking.off_hours': 'The time is outside the session’s normal schedule.',
    'ui.admin.booking.off_closure': 'The time falls on a closure in the calendar.',
    'ui.admin.booking.off_window': 'The time is outside the treatment and ritual time window.',
    'ui.admin.booking.off_open': 'Book outside the schedule',
    'ui.admin.booking.off_time': 'Start time',
    'ui.admin.booking.off_rule': 'Session used as the template',
    'ui.admin.booking.off_hint': 'The booking is made even if there is no rule that day, the sauna is closed, or the time is outside opening hours.',
    'ui.admin.booking.confirm_yes': 'Yes, continue',
    'ui.admin.booking.confirm_no': 'Cancel',
    'ui.admin.booking.both_title': 'Schedule exception',
    'ui.admin.booking.slot_full': 'full – can overbook',
    'ui.admin.booking.slot_closed': 'closed – can book anyway',
    'ui.admin.booking.change_need': 'Pick a new session, time or number of guests.',
  },
};

const fill = (text, vars) => String(text).replace(/\{\{var:(\w+)\}\}|\{(\w+)\}/g, (_, a, b) => {
  const k = a || b;
  return vars && vars[k] != null ? String(vars[k]) : '';
});

let db = new Map();
let loaded = false;

export async function loadBookingTexts(rpcFn) {
  if (loaded) return true;
  if (typeof rpcFn !== 'function') return false;
  try {
    const t = await rpcFn('public_get_site_texts', { p_lang: null });
    if (!t || t.ok !== true || !Array.isArray(t.texts)) return false;
    const next = new Map();
    for (const r of t.texts) {
      if (!r || typeof r.key !== 'string' || !r.key.startsWith(PREFIX)) continue;
      if (r.lang !== 'fi' && r.lang !== 'en') continue;
      if (typeof r.text !== 'string' || !r.text.trim()) continue;
      next.set(`${r.key}|${r.lang}`, r.text);
    }
    db = next;
    loaded = true;
    return true;
  } catch {
    return false;
  }
}

export function clearBookingTextCache() { db = new Map(); loaded = false; }

export function bookingText(key, vars, lang = getLang()) {
  const full = key.startsWith(PREFIX) ? key : PREFIX + key;
  const live = db.get(`${full}|${lang}`) || db.get(`${full}|fi`);
  const fallback = BOOKING_TEXTS[lang]?.[full] ?? BOOKING_TEXTS.fi[full] ?? full;
  return fill(live || fallback, vars);
}

export function noticeText(notice) {
  if (!notice) return '';
  if (notice.code === 'capacity_exceeded') return bookingText('over_capacity', { used: notice.used, capacity: notice.capacity });
  if (notice.code === 'capacity_soft') return bookingText('over_soft', { persons: notice.persons, free: notice.free });
  if (notice.code === 'persons_max' || notice.code === 'persons_limit') return bookingText('over_max', { persons: notice.persons ?? notice.n, max: notice.max });
  if (['space_busy', 'private_booked', 'public_shift_booked', 'no_therapist'].includes(notice.code)) return bookingText('over_conflict');
  if (notice.code === 'closure' || notice.code === 'space_closed' || notice.code === 'therapist_closed') return bookingText('off_closure');
  if (notice.code === 'outside_hours') return bookingText('off_hours');
  if (notice.code === 'time_window' || notice.code === 'ritual_start') return bookingText('off_window');
  if (notice.code === 'no_session' || notice.code === 'not_offered_day') return bookingText('off_no_rule');
  return bookingText('off_closed');
}
