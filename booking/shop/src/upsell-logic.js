// Pure helpers: same-day matching, duplicates, adjacency-first ranking. No visible copy in this file.
export const visitDate = (iso) => {
  if (!iso || !Number.isFinite(Date.parse(iso))) return '';
  return new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Helsinki', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(iso));
};
export function rankSlots(slots, reservations, visitDay, limit = 20) {
  const visits = (reservations || []).filter(x => !['cancelled', 'expired'].includes(x.status) && x.starts_at && x.ends_at);
  return (slots || []).filter(x => x?.start && x.end && visitDate(x.start) === visitDay)
    .map(x => {
      let best = Number.POSITIVE_INFINITY, fit = '';
      for (const r of visits) {
        const before = Date.parse(r.starts_at) - Date.parse(x.end);
        const after = Date.parse(x.start) - Date.parse(r.ends_at);
        if (before >= 0 && before < best) { best = before; fit = 'before'; }
        if (after >= 0 && after < best) { best = after; fit = 'after'; }
      }
      return { ...x, fit: best <= 90 * 60000 ? fit : '', distance: best };
    }).sort((a, b) => Number(!!b.fit) - Number(!!a.fit) || a.distance - b.distance || Date.parse(a.start) - Date.parse(b.start))
    .slice(0, Math.max(0, limit));
}
export function candidates(data, existingIds = [], max = 9) {
  const have = new Set(existingIds.map(Number));
  const seen = new Set();
  return (data?.products || []).filter(p => {
    const id = Number(p.product_id);
    if (!id || have.has(id) || seen.has(id) || !Array.isArray(p.slots) || !p.slots.length) return false;
    seen.add(id); return true;
  }).sort((a,b) => Number(!!b.suggested) - Number(!!a.suggested)).slice(0,max);
}
export const shortPlain = (value, max = 160) => String(value ?? '').replace(/<[^>]*>/g,' ').replace(/&nbsp;/g,' ').replace(/\s+/g,' ').trim().slice(0,max);
export const safeSlug = value => /^[a-z0-9][a-z0-9-]{0,90}$/.test(String(value || '')) ? String(value) : '';
