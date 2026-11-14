// HALL-PAIVA-04: päivänäkymän hiljainen automaattinen päivitys (vastaanoton tabletti).
// Puhdas päätöslogiikka (testattava ilman selainta) + ohut ajastin. Ei tietokantamuutoksia: käyttää samaa päivänippua kuin muukin näkymä.

export const DAY_REFRESH_MS = 60000;

/** Kello Helsingin ajassa muodossa "14.05" (ei riipu laitteen aikavyöhykkeestä). */
export function clockLabel(date = new Date()) {
  const parts = new Intl.DateTimeFormat('fi-FI', { timeZone: 'Europe/Helsinki', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(date);
  const get = (t) => parts.find((p) => p.type === t)?.value || '00';
  return `${get('hour')}.${get('minute')}`;
}

/**
 * Saako päivän hiljaisen päivityksen tehdä nyt? Ei, jos välilehti on piilossa, näkymä ei ole Päivä,
 * päivitys tai reitin vaihto on kesken, dialogi on auki, kentässä on kohdistus (kirjoitus kesken),
 * saapumisen kirjaus on kesken tai tulostus on käynnissä.
 */
export function canAutoRefresh(s) {
  if (!s || s.hidden) return false;
  if (!s.onDayRoute) return false;
  if (s.busy || s.printing) return false;
  if (s.dialogOpen || s.editing || s.pendingAction) return false;
  return true;
}

/** Onko kohdistettu elementti kenttä, johon käyttäjä voi olla kirjoittamassa (päivävalitsin ei lasketa: sen muutos navigoi). */
export function isEditingElement(el) {
  if (!el || !el.tagName) return false;
  const tag = String(el.tagName).toLowerCase();
  if (tag === 'textarea' || tag === 'select') return true;
  if (tag === 'input') return !['button', 'submit', 'checkbox', 'radio'].includes(String(el.type || '').toLowerCase());
  return !!el.isContentEditable;
}

/** Tarvitseeko näkyviin palannut välilehti päivityksen (vanhempi kuin intervalli)? */
export const isStale = (lastAt, now, ms = DAY_REFRESH_MS) => !Number.isFinite(lastAt) || now - lastAt >= ms;

/**
 * Käynnistää ajastimen. `state()` palauttaa canAutoRefresh-tilan (ilman hidden-kenttää), `refresh()` tekee hiljaisen
 * päivityksen ja palauttaa lupauksen. Päivitykset eivät mene päällekkäin. Palauttaa pysäytysfunktion.
 */
export function startDayAutoRefresh({ doc = globalThis.document, win = globalThis, state, refresh, ms = DAY_REFRESH_MS, now = () => Date.now() }) {
  let last = now();
  let running = false;
  const tick = async (force) => {
    if (running) return;
    if (!force && !isStale(last, now(), ms * 0.9)) return;
    if (!canAutoRefresh({ ...state(), hidden: !!doc?.hidden })) return;
    running = true;
    try { await refresh(); last = now(); } catch { /* seuraava yritys minuutin päästä; vanha näkymä jää */ } finally { running = false; }
  };
  const timer = setInterval(() => { void tick(false); }, ms);
  const onVis = () => { if (!doc.hidden) void tick(false); };
  doc?.addEventListener?.('visibilitychange', onVis);
  return { stop() { clearInterval(timer); doc?.removeEventListener?.('visibilitychange', onVis); }, markFresh() { last = now(); }, tick };
}
