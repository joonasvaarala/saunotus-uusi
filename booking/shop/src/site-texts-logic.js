// Sivutekstit tietokannasta (sopimus §18, booking_60/62): puhdas logiikka ilman riippuvuuksia. Sama moduuli toimii selaimessa (kauppa) ja Node-buildissa
// (src/site-texts.mjs). Teksti on aina avain + kieli (fi pakollinen, en voi puuttua → näytetään fi, ei tyhjää eikä raakaa avainta).
// Paikkamerkit (§18.3): {{price:7}} (tuotteen hinta), {{duration:7}} (tuotteen kesto), {{setting:<avain>}} (vain public_settings()-avaimet).
// Tuntematon paikkamerkki tai puuttuva arvo = PlaceholderError: build kaatuu (strict) tai teksti jätetään pois (lenient, selaimessa: kutsuja valitsee varatekstin).
export const LANGS = ['fi', 'en'];
export const KEY_RE = /^[a-z0-9_]+(\.[a-z0-9_-]+)+$/;                    // sama kuin admin_texts_import (booking_62)
export const TOKEN_RE = /^\{\{[a-z_]+(:[A-Za-z0-9_]+)?\}\}$/;           // sama kuin _text_validate (booking_60)
export const KINDS = ['price', 'duration', 'setting'];                  // tunnetut paikkamerkkilajit (§18.3)

export class PlaceholderError extends Error {
  constructor(message, { key = null, lang = null, token = null } = {}) { super(message); this.name = 'PlaceholderError'; Object.assign(this, { key, lang, token }); }
}

/** Kesto luettavaksi: 20 → "20 min", 120 → "2 h", 90 → "1 h 30 min" (numeroformaatti, ei kielikohtaista tekstiä). */
export const fmtMinutes = (m) => { m = Math.round(+m); return m < 60 ? `${m} min` : m % 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m / 60} h`; };
/** Hinta tekstiin kuten sopimus §18.3: "49 €" (fi) / "€49" (en); sentit vain jos tarpeen. */
export const fmtPrice = (n, lang = 'fi') => {
  const v = +n, s = Number.isInteger(v) ? String(v) : v.toFixed(2);
  return lang === 'en' ? `€${s}` : `${s.replace('.', ',')} €`;
};

/** Kaikki {{…}}-merkinnät tekstistä (uniikit, järjestyksessä) – myös virheelliset, jotta ne voidaan raportoida. */
export const tokensOf = (text) => [...new Set(String(text ?? '').match(/\{\{[^{}]*\}\}/g) || [])];

/** rivit [{key, lang, text, placeholders?}] → Map<key, {fi?: rivi, en?: rivi}>; tyhjät tekstit ja virheelliset avaimet jätetään pois. */
export function indexTexts(rows) {
  const idx = new Map();
  for (const r of Array.isArray(rows) ? rows : []) {
    if (!r || typeof r.key !== 'string' || typeof r.text !== 'string' || !r.text.trim() || !LANGS.includes(r.lang) || !KEY_RE.test(r.key)) continue;
    (idx.get(r.key) || idx.set(r.key, {}).get(r.key))[r.lang] = r;
  }
  return idx;
}

/**
 * Paikkamerkkien arvot. ctx = { price(id, lang), duration(id, lang), setting(key, lang) } – jokainen palauttaa merkkijonon tai null (= tuntematon).
 * Heittää PlaceholderErrorin tuntemattomasta lajista / puuttuvasta arvosta / jäännös-{{ }}-merkinnästä; EI koskaan jätä raakaa {{…}}-merkintää tekstiin.
 */
export function fillPlaceholders(text, ctx, lang = 'fi', where = {}) {
  const out = String(text).replace(/\{\{[^{}]*\}\}/g, (tok) => {
    if (!TOKEN_RE.test(tok)) throw new PlaceholderError(`virheellinen paikkamerkki ${tok}`, { ...where, lang, token: tok });
    const [kind, arg] = tok.slice(2, -2).split(':');
    if (!KINDS.includes(kind)) throw new PlaceholderError(`tuntematon paikkamerkki ${tok}`, { ...where, lang, token: tok });
    if (arg == null) throw new PlaceholderError(`paikkamerkistä puuttuu tunniste ${tok}`, { ...where, lang, token: tok });
    const v = ctx?.[kind]?.(arg, lang);
    if (v == null || v === '') throw new PlaceholderError(`paikkamerkin ${tok} arvoa ei löydy`, { ...where, lang, token: tok });
    return String(v);
  });
  if (/\{\{|\}\}/.test(out)) throw new PlaceholderError('tekstiin jäi {{ tai }}', { ...where, lang });
  return out;
}

/** Teksti kielellä: en puuttuu → fi (fallback=true); ei kumpaakaan → null. Paikkamerkit täytetään ctx:llä (jos annettu). strict=false: virheestä null. */
export function textFor(idx, key, lang, ctx = null, { strict = false } = {}) {
  const e = idx.get(key); if (!e) return null;
  const order = lang === 'en' ? ['en', 'fi'] : ['fi'];
  for (const l of order) {
    const r = e[l]; if (!r) continue;
    try { return { text: ctx ? fillPlaceholders(r.text, ctx, l, { key }) : r.text, lang: l, fallback: l !== lang, version: r.version ?? null }; }
    catch (err) { if (strict || !(err instanceof PlaceholderError)) throw err; return null; }
  }
  return null;
}

/** Tarkistaa kaikki tekstit: virheelliset/tuntemattomat paikkamerkit, ilmoitetun `placeholders`-joukon ristiriita. → [{key, lang, problem}] (tyhjä = kunnossa). */
export function validateTexts(rows, ctx) {
  const problems = [];
  for (const r of Array.isArray(rows) ? rows : []) {
    if (!r || typeof r.text !== 'string') { problems.push({ key: r?.key ?? '?', lang: r?.lang ?? '?', problem: 'virheellinen rivi' }); continue; }
    const toks = tokensOf(r.text);
    if (Array.isArray(r.placeholders) && [...r.placeholders].sort().join('|') !== [...toks].sort().join('|')) problems.push({ key: r.key, lang: r.lang, problem: `placeholders-kenttä ei vastaa tekstiä (${r.placeholders.join(',') || '-'} vs ${toks.join(',') || '-'})` });
    try { fillPlaceholders(r.text, ctx, r.lang, { key: r.key }); } catch (err) { if (!(err instanceof PlaceholderError)) throw err; problems.push({ key: r.key, lang: r.lang, problem: err.message }); }
  }
  return problems;
}

/**
 * Paikkamerkkikonteksti katalogista ja asetuksista. catalog = public_catalog()-rivit tai [{id, price, duration_minutes}]; settings = public_settings()-objekti.
 * format: { price(n, lang), duration(min, lang) } (oletus: fmtPrice / fmtMinutes). setting: vain merkkijono/luku/boolean-arvot, ei objekteja.
 */
export function makeContext({ catalog = [], settings = {}, format = {} } = {}) {
  const byId = new Map((Array.isArray(catalog) ? catalog : []).map((p) => [String(p.id), p]));
  const fp = format.price || fmtPrice, fd = format.duration || ((m) => fmtMinutes(m));
  const num = (v) => (v == null || v === '' || !Number.isFinite(+v) ? null : +v);
  return {
    price: (id, lang) => { const v = num(byId.get(String(id))?.price); return v == null ? null : fp(v, lang); },
    duration: (id, lang) => { const v = num(byId.get(String(id))?.duration_minutes); return v == null || v <= 0 ? null : fd(v, lang); },
    setting: (key) => { const v = settings?.[key]; return v != null && typeof v !== 'object' ? String(v) : null; },
  };
}
