// Jaettu, DOM-riippumaton jonotuslistan näkyvyys- ja järjestyslogiikka.
// 'unavailable' = blokattu/suljettu, ei jonotettavissa eikä esitetä vuororivinä.
export const visibleWaitlistSlots = (rows) => (rows || []).filter((x) => ['available', 'full'].includes((x.r || x).status))
  .sort((a, b) => (+( (a.r || a).status === 'full') - +( (b.r || b).status === 'full')) ||
    String((a.r || a).starts_at || '').localeCompare(String((b.r || b).starts_at || '')));
export const hasWaitlistSlots = (rows) => visibleWaitlistSlots(rows).length > 0;
export const fullyBooked = (rows) => hasWaitlistSlots(rows) && !visibleWaitlistSlots(rows).some((x) => (x.r || x).status === 'available');
