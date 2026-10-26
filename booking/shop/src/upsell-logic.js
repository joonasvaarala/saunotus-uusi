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

const filled = (v) => v != null && v !== '';
const normSpace = (value) => String(value ?? '').replace(/[\u00a0\u202f\u2007]/g, ' ').replace(/\s+/g, ' ').trim();
const fold = (value) => normSpace(value).toLocaleLowerCase('fi-FI');

/** Localized product name. EN falls back to FI when the English name is empty. */
export function productName(p, lang) {
  if (lang === 'en' && normSpace(p?.name_en)) return normSpace(p.name_en);
  return normSpace(p?.name);
}

/**
 * Drop a leading copy of the product name when the description already starts with it.
 * "<h3>Saunotus</h3><p>Saunotus on …" flattens to "Saunotus Saunotus on …" → "Saunotus on …".
 * A single leading name ("Saunotus yhdistää …") stays, because the sentence needs it.
 */
const nameAt = (text, name) => {
  const n = normSpace(name);
  if (!n || fold(text).slice(0, n.length) !== fold(n)) return -1;
  const after = text.slice(n.length);
  return after === '' || /^[^\p{L}\p{N}]/u.test(after) ? n.length : -1;
};
export function dropRepeatedName(name, text) {
  const n = normSpace(name);
  let s = normSpace(text);
  if (!n || !s) return s;
  while (nameAt(s, n) === n.length) {
    const rest = s.slice(n.length);
    const after = rest.replace(/^[^\p{L}\p{N}]+/u, '');
    if (after === rest || nameAt(after, n) !== n.length) break;
    s = after;
  }
  // A heading that is only the name ("Guided Sauna Session (Saunotus) A guided…") is not the sentence.
  // A sentence that starts with the name ("Saunotus yhdistää…", "Saunotusrituaali") stays.
  if (nameAt(s, n) === n.length) {
    const after = s.slice(n.length).replace(/^[^\p{L}\p{N}]+/u, '');
    if (after && /^\p{Lu}/u.test(after) && !fold(after).startsWith(fold(n))) s = after;
  }
  return s;
}

function localized(p, lang, fiKey, enKey) {
  if (lang === 'en' && filled(p?.[enKey])) return p[enKey];
  return filled(p?.[fiKey]) ? p[fiKey] : '';
}

/** Plain excerpt. preferShort: card blurb. Otherwise the longer description shown above the time buttons. Never prefixes the name. */
export function excerpt(p, lang, max = 180, preferShort = false) {
  const raw = preferShort
    ? (localized(p, lang, 'short_description', 'short_description_en') || localized(p, lang, 'description', 'description_en'))
    : (localized(p, lang, 'description', 'description_en') || localized(p, lang, 'short_description', 'short_description_en'));
  const full = dropRepeatedName(productName(p, lang), shortPlain(raw, 20000));
  return max > 0 && full.length > max ? full.slice(0, max) : full;
}

/** Remove a leading heading or paragraph whose whole text is the product name, so the dialog title is not repeated. */
export function stripNameHeading(html, name) {
  const n = fold(name);
  let s = String(html ?? '').trim();
  if (!n || !s) return s;
  const re = /^<(h[1-6]|p)(\s[^>]*)?>\s*(?:<(?:strong|b)>\s*)?([\s\S]*?)\s*(?:<\/(?:strong|b)>\s*)?<\/\1>\s*/i;
  const m = re.exec(s);
  if (!m) return s;
  const inner = fold(m[3].replace(/<[^>]*>/g, ' ').replace(/&nbsp;|&#160;/gi, ' '));
  if (inner !== n) return s;
  return s.slice(m[0].length);
}

export function durationText(p, lang) {
  const text = normSpace(lang === 'en' ? (p?.duration_text_en || p?.duration_text) : p?.duration_text);
  if (text) return text;
  const m = Math.round(+p?.duration_minutes);
  if (!Number.isFinite(m) || m <= 0) return '';
  return m < 60 ? `${m} min` : m % 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m / 60} h`;
}

export function personsText(p) {
  const n = (v) => (v == null || v === '' || !Number.isFinite(+v) || +v <= 0 ? 0 : Math.round(+v));
  const min = n(p?.min_persons ?? p?.capacity_min);
  const max = n(p?.max_persons ?? p?.capacity_max);
  if (min && max) return min === max ? String(min) : `${Math.min(min, max)}–${Math.max(min, max)}`;
  return min ? String(min) : max ? String(max) : '';
}

/** Fill gaps in an upsell row from catalog / static product data. The upsell row wins when it already has a value. */
export function mergeFacts(p, extra) {
  const a = p || {}, b = extra || {};
  const pick = (k) => filled(a[k]) ? a[k] : b[k];
  return {
    ...b, ...a,
    description: pick('description'), description_en: pick('description_en'),
    short_description: pick('short_description'), short_description_en: pick('short_description_en'),
    duration_text: pick('duration_text'), duration_text_en: pick('duration_text_en'),
    name: pick('name'), name_en: pick('name_en'), slug: pick('slug'),
    image_path: pick('image_path'), image_url: pick('image_url'), image_alt: pick('image_alt'),
    duration_minutes: filled(a.duration_minutes) ? a.duration_minutes : (b.duration_minutes ?? null),
    min_persons: filled(a.min_persons) ? a.min_persons : (filled(b.min_persons) ? b.min_persons : (b.capacity_min ?? null)),
    max_persons: filled(a.max_persons) ? a.max_persons : (filled(b.max_persons) ? b.max_persons : (b.capacity_max ?? null)),
    price_from: filled(a.price_from) ? a.price_from : (filled(a.price) ? a.price : (filled(b.price_from) ? b.price_from : (b.price ?? null))),
    product_id: a.product_id ?? b.product_id ?? b.id ?? null,
  };
}
