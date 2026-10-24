// Jaettu, DOM-riippumaton jonotuslistan näkyvyys- ja järjestyslogiikka.
// 'unavailable' = blokattu/suljettu, ei jonotettavissa eikä esitetä vuororivinä.
export const visibleWaitlistSlots = (rows) => (rows || []).filter((x) => ['available', 'full'].includes((x.r || x).status))
  .sort((a, b) => (+( (a.r || a).status === 'full') - +( (b.r || b).status === 'full')) ||
    String((a.r || a).starts_at || '').localeCompare(String((b.r || b).starts_at || '')));
export const hasWaitlistSlots = (rows) => visibleWaitlistSlots(rows).length > 0;
export const fullyBooked = (rows) => hasWaitlistSlots(rows) && !visibleWaitlistSlots(rows).some((x) => (x.r || x).status === 'available');
// booking_148: jonovarauksen henkilömäärä palvelutyypin mukaan (sama tunnistus kuin palvelimen booking._waitlist_party):
// yksityisvuoro (vuoron mode 'exclusive') → ei henkilömäärää; tapahtuma (tuotteen category 'event') → 1..kapasiteetti
// (pienin vuoron ja tuotteen max_persons, enintään 50); muut yleiset vuorot → 1–6 ja vuoron oma min/max.
export function waitlistParty(s, p) {
  if (s?.mode === 'exclusive') return { kind: 'private', min: null, max: null };
  const min = Math.max(1, Math.trunc(+s?.min_persons) || 1);
  if (p?.category === 'event') {
    const caps = [s?.max_persons, p?.max_persons].map(Number).filter((x) => Number.isFinite(x) && x > 0);
    return { kind: 'event', min, max: Math.max(min, Math.min(50, ...caps)) };
  }
  return { kind: 'general', min, max: Math.max(min, Math.min(6, Math.trunc(+s?.max_persons) || 6)) };
}
