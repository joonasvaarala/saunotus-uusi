// Kassan paikanpito (§17): tilojen normalisointi, palvelinkellosta johdettu laskuri (ei laitteen kelloa), ilmoitusportaat ja kyselyaikataulu. Ei DOMia.
// Palvelin on totuus: checkout_state, hold_expires_at, seconds_left, server_now, remaining_amount, payment_in_progress, hold_kind (public_get_order / public_get_booking / luonti-RPC:t).
export const STATES = ['awaiting_payment', 'processing_payment', 'preliminary', 'confirmed', 'confirmed_unpaid', 'expired', 'cancelled'];
export const HOLD_VIEWS = ['awaiting_payment', 'processing_payment', 'preliminary', 'expired'];   // tilat, joissa pitonäkymä korvaa/täydentää vanhan
const ms = (v) => { const t = Date.parse(v); return Number.isFinite(t) ? t : null; };

// RPC-vastaus → { state, awaiting, processing, preliminary, expired, cancelled, confirmed, holdKind, expiresAt (ms|null), serverNow (ms|null), secondsLeft (number|null), remaining (number|null), inProgress } | null (vanha backend: ei tilakenttää → vanha käytös)
export function normCheckout(r) {
  if (!r || typeof r !== 'object' || !STATES.includes(r.checkout_state)) return null;
  const s = r.checkout_state, num = (v) => (v == null || v === '' || !Number.isFinite(+v) ? null : +v);
  return { state: s, awaiting: s === 'awaiting_payment' || s === 'processing_payment', processing: s === 'processing_payment', preliminary: s === 'preliminary', expired: s === 'expired', cancelled: s === 'cancelled',
    confirmed: s === 'confirmed' || s === 'confirmed_unpaid', holdKind: r.hold_kind ?? null, expiresAt: ms(r.hold_expires_at), serverNow: ms(r.server_now), secondsLeft: num(r.seconds_left), remaining: num(r.remaining_amount ?? r.unpaid),
    inProgress: r.payment_in_progress === true || s === 'processing_payment', cancelReason: typeof r.cancel_reason === 'string' && r.cancel_reason ? r.cancel_reason : null };
}
export const isHoldView = (co) => !!co && HOLD_VIEWS.includes(co.state);
// Pitotila (kassa): palvelimen public_checkout_payment_options().hold_until_paid; jos RPC ei vastaa, vanha asetus public_payment_mode (vain lukeminen)
export function holdModeOf(checkout, settings) {
  const fromSettings = settings?.public_payment_mode === 'hold_until_paid', sm = +settings?.hold_minutes || 15;
  if (checkout && checkout.ok && checkout.holdKnown) return { on: checkout.hold === true, minutes: checkout.holdMinutes || 15, legacy: false };   // booking_53: palvelin päättää
  // vanha backend (RPC ei kerro hold_until_paid) tai RPC-virhe: uutta pitonäkymää ei oteta käyttöön; legacy = vanha asetuspohjainen ohjeteksti säilyy ennallaan
  return { on: false, minutes: checkout && checkout.ok ? checkout.holdMinutes || sm : sm, legacy: fromSettings };
}
// Lahjakortti oli käytössä ennen vanhenemista: public_get_booking.payment_methods sisältää myös perutut maksut (pidon vapautus perui lahjakorttiosuuden)
export const giftWasUsed = (b, remembered = false) => (Array.isArray(b?.payment_methods) && b.payment_methods.includes('gift_card')) || remembered === true;

// ---- laskuri: palvelimen aika + selaimen monotoninen kello (performance.now) → ei laitteen kellon virheitä; sync() korjaa ryöminnän ----
export const leftFromServer = (co) => (co.expiresAt != null && co.serverNow != null ? Math.max(0, co.expiresAt - co.serverNow) : co.secondsLeft != null ? Math.max(0, co.secondsLeft * 1000) : null);
export function createHoldClock(co, mono = () => (typeof performance !== 'undefined' ? performance.now() : Date.now())) {
  let left0 = leftFromServer(co) ?? 0, t0 = mono();
  const clock = {
    left: () => Math.max(0, left0 - (mono() - t0)),
    // palvelimen tuore luku: yli 1,5 s ero → hyväksytään palvelimen arvo (muuten pidetään oma, ettei sekunti hypi edestakaisin)
    sync(next) { const l = leftFromServer(next); if (l == null) return false; const mine = clock.left(); if (Math.abs(mine - l) > 1500) { left0 = l; t0 = mono(); return true; } return false; },
    reset(next) { left0 = leftFromServer(next) ?? 0; t0 = mono(); },
  };
  return clock;
}
// mm:ss (pyöristys ylöspäin: 00:00 vasta kun aika on oikeasti loppu)
export function clockText(leftMs) { const s = Math.ceil(Math.max(0, leftMs) / 1000), m = Math.floor(s / 60), r = s % 60; return `${String(m).padStart(2, '0')}:${String(r).padStart(2, '0')}`; }
// Ruudunlukijailmoitus vain portailla (ei joka sekunti): 5 min, 2 min, 1 min, 30 s. Palauttaa seuraavan ylitetyn portaan millisekunteina tai null; kukin vain kerran.
export const ANNOUNCE_STEPS = [300000, 120000, 60000, 30000];
export function createAnnouncer(steps = ANNOUNCE_STEPS) {
  const said = new Set();
  return { next(leftMs) { const s = steps.filter((x) => leftMs <= x).sort((a, b) => a - b)[0]; if (s == null || leftMs <= 0 || said.has(s)) return null; for (const x of steps) if (x >= s) said.add(x); return s; }, reset() { said.clear(); } };   // pienin ylitetty porras (sivu avattu 45 s kohdalla → "30 s"-porras ei vielä, "1 min" kyllä; ei vanhoja portaita)
}
export const spoken = (lang, stepMs, ht) => (stepMs >= 120000 ? ht(lang, 'spoken_min', { n: Math.round(stepMs / 60000) }) : stepMs === 60000 ? ht(lang, 'spoken_min1') : ht(lang, 'spoken_sec', { n: Math.round(stepMs / 1000) }));

// ---- kyselyaikataulu: milloin haetaan tila palvelimelta ----
export const POLL = { awaitingMs: 30000, processingMs: 3000, processingLongAfterMs: 120000, processingSlowMs: 15000, zeroRetryMs: 3000 };
// → seuraavan kyselyn väli ms | null (ei kyselyä). elapsed = aikaa pitosivun avaamisesta processing-tilassa
export function nextPollIn(co, { leftMs = 0, processingElapsed = 0 } = {}) {
  if (!co) return null;
  if (co.processing) return processingElapsed >= POLL.processingLongAfterMs ? POLL.processingSlowMs : POLL.processingMs;
  if (co.state === 'awaiting_payment') return leftMs <= 0 ? POLL.zeroRetryMs : Math.min(POLL.awaitingMs, Math.max(500, leftMs));
  return null;
}
// Näkymä pitää piirtää uudelleen kun tila vaihtuu (tai maksu/loppusumma muuttuu)
export const changed = (a, b) => !a || !b || a.state !== b.state || a.remaining !== b.remaining || a.inProgress !== b.inProgress;
