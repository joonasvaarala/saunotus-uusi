// Oman saunavuoron kaksivaiheinen valinta (alku → kesto): puhdas ryhmittelylogiikka ilman DOM:ia.
// Data ei muutu: jokainen kesto on oma schedule_rules-rivinsä ja hintavarianttinsa; tämä vain ryhmittelee olemassa olevat rivit alkuajan mukaan.
import { visibleWaitlistSlots } from './waitlist-logic.js';

const rowOf = (x) => x.r || x;   // päivänäkymän {r, p} tai pelkkä saatavuusrivi
export const durationMinutes = (x) => Math.round((Date.parse(rowOf(x).ends_at) - Date.parse(rowOf(x).starts_at)) / 60000);
const startKey = (x) => String(Date.parse(rowOf(x).starts_at));

/**
 * Ryhmittelee näkyvät vuorot (available + full) alkuajan mukaan, aikajärjestyksessä.
 * Ryhmä: { key, start (ISO), slots (kaikki kestot lyhyimmästä pisimpään), free (vain vapaat), hasFree }.
 */
export function groupSlotsByStart(rows) {
  const by = new Map();
  for (const x of visibleWaitlistSlots(rows).filter((y) => rowOf(y).starts_at && rowOf(y).ends_at)) {
    const k = startKey(x);
    if (!by.has(k)) by.set(k, { key: k, start: rowOf(x).starts_at, slots: [] });
    by.get(k).slots.push(x);
  }
  return [...by.values()].sort((a, b) => Number(a.key) - Number(b.key)).map((g) => {
    g.slots.sort((a, b) => durationMinutes(a) - durationMinutes(b) || String(rowOf(a).rule_id).localeCompare(String(rowOf(b).rule_id)));
    g.free = g.slots.filter((x) => rowOf(x).status === 'available');
    g.hasFree = g.free.length > 0;
    return g;
  });
}

/** Alut, joilla on vähintään yksi vapaa kesto (askel 1). */
export const startsWithFree = (groups) => groups.filter((g) => g.hasFree);

/**
 * Käytetäänkö kaksivaiheista valintaa: jollain alulla on useita kestoja. Yksi kesto per alku → entinen lista.
 * Tapahtumat, koulutukset ja monipäiväiset kerrat eivät ryhmity.
 */
export function usesStartPicker(rows, product) {
  if (product?.category === 'event' || product?.category === 'training') return false;
  const list = visibleWaitlistSlots(rows);
  if (list.some((x) => Date.parse(rowOf(x).ends_at) - Date.parse(rowOf(x).starts_at) >= 24 * 36e5)) return false;
  // useita ERI kestoja samalla alulla (pelkkä sama alku samalla kestolla, esim. kaksi eri sääntöä, ei riitä)
  return groupSlotsByStart(list).some((g) => new Set(g.slots.map(durationMinutes)).size > 1);
}

/** Yhteinen "sis. N hlö, lisähenkilö +X €" -tieto, jos kaikilla annetuilla riveillä sama; muuten null (silloin teksti riville). */
export function sharedIncluded(slots) {
  const rs = slots.map(rowOf);
  if (!rs.length || rs.some((r) => r.price_mode === 'per_person' || r.price_mode === 'fixed')) return null;
  const f = rs[0];
  if (f.included_persons == null || f.extra_person_price == null) return null;
  return rs.every((r) => r.included_persons === f.included_persons && r.extra_person_price === f.extra_person_price)
    ? { included: f.included_persons, extra: f.extra_person_price } : null;
}
