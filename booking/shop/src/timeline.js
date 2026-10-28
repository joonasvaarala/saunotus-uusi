// Pakettituotteen aikajana (booking_61, §18.11). Puhdas: ei verkkoa eikä sb.js:ää,
// jotta staattinen sivu voi käyttää samaa kestosääntöä kuin kaupan kortti.
const num0 = (v) => (v == null || v === '' || !Number.isFinite(+v) ? null : +v);

// kaikki jaksot alkuaikajärjestyksessä (customer_visible=false mukana, merkittynä); virheellinen aikajana → null.
// Yhtenäisyys (§18.11): jaksot ovat tuotteen keston sisällä ja aikajana päättyy tuotteen kestoon (summa voi olla pienempi: näkymättömät välit).
export function allSegments(p) {
  const tl = Array.isArray(p?.timeline) ? p.timeline : null; if (!tl?.length) return null;
  const segs = tl.map((x, i) => ({ seq: num0(x?.seq) ?? i + 1, key: String(x?.kind || `seg${i + 1}`), label: x?.label || '', label_en: x?.label_en || '', min: num0(x?.minutes), start: num0(x?.start_min), end: num0(x?.end_min), hidden: x?.customer_visible === false }));
  if (segs.some((x) => !(x.min > 0) || x.start == null || x.start < 0)) return null;
  segs.sort((a, b) => a.seq - b.seq || a.start - b.start);
  const dur = num0(p?.duration_minutes), last = segs.reduce((m, x) => Math.max(m, x.end ?? x.start + x.min), 0);
  if (dur != null && (last !== dur || segs.some((x, i) => i && x.start < (segs[i - 1].end ?? segs[i - 1].start + segs[i - 1].min)))) return null;   // ei päällekkäisiä jaksoja, päättyy kestoon
  return segs;
}

// asiakkaalle näkyvät jaksot: [{ key (= kind), label, label_en, start, min, end }] tai null
export function timelineOf(p) {
  const v = (allSegments(p) || []).filter((x) => !x.hidden);
  return v.length ? v : null;
}
export const isPackage = (p) => !!timelineOf(p);
export const timelineLabel = (x, lang) => (lang === 'en' && x.label_en) || x.label;
// Kokonaiskesto: tuotteen kesto, muuten viimeisen jakson loppu (sisäinen väli mukana)
export const timelineMinutes = (p) => num0(p?.duration_minutes) ?? (allSegments(p) || []).reduce((end, x) => Math.max(end, x.end ?? x.start + x.min), 0);
