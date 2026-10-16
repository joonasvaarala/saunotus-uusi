// Päivittää content/reviews.json Google Places API (New) -datalla.
// Käyttö: GOOGLE_PLACES_API_KEY=... GOOGLE_PLACE_ID=... npm run reviews:update   (--dry-run: ei kirjoita)
// Rajoite: API palauttaa korkeintaan 5 arvostelua / kutsu, joten osio kasvaa ajan myötä (uudet lisätään, vanhoja ei poisteta).
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const FILE = process.env.REVIEWS_FILE || new URL('../content/reviews.json', import.meta.url);
const LANGS = ['fi', 'en'];
const key = (r) => `${r.author}|${r.text.replace(/\s+/g, ' ').trim().slice(0, 60).toLowerCase()}`;

// Places-vastauksen arvostelut → meidän muoto (stars>=4, teksti, alkuperäinen kieli fi/en)
export function fromApi(places) {
  const out = [];
  for (const rv of places.reviews || []) {
    const text = rv.originalText?.text;
    const lang = String(rv.originalText?.languageCode || '').split('-')[0].toLowerCase();
    if (!(rv.rating >= 4) || !text || !text.trim() || !LANGS.includes(lang)) continue;
    out.push({ author: rv.authorAttribution?.displayName || '', stars: rv.rating, lang, text, _t: rv.publishTime || '' });
  }
  return out;
}

// Lisää uudet (ei duplikaatteja) tiedoston alkuun, uusin ensin. Ei koskaan poista vanhoja.
export function merge(data, found) {
  const seen = new Set(data.reviews.map(key));
  const fresh = [];
  for (const r of found.sort((a, b) => b._t.localeCompare(a._t))) {
    if (!r.author || seen.has(key(r))) continue;
    seen.add(key(r));
    const { _t, ...clean } = r;
    fresh.push(clean);
  }
  data.reviews = [...fresh, ...data.reviews];
  return fresh;
}

async function main() {
  const apiKey = process.env.GOOGLE_PLACES_API_KEY, placeId = process.env.GOOGLE_PLACE_ID;
  if (!apiKey || !placeId) {
    console.error('reviews:update: GOOGLE_PLACES_API_KEY ja GOOGLE_PLACE_ID puuttuvat. Mitään ei muutettu.\n'
      + 'Aseta ne ympäristömuuttujiksi (Places API (New) -avain, paikan Place ID) ja aja uudelleen.');
    process.exit(1);
  }
  const data = JSON.parse(readFileSync(FILE, 'utf8'));
  const found = [];
  let rating, count;
  for (const lang of LANGS) {
    const res = await fetch(`https://places.googleapis.com/v1/places/${encodeURIComponent(placeId)}?languageCode=${lang}`, {
      headers: { 'X-Goog-Api-Key': apiKey, 'X-Goog-FieldMask': 'rating,userRatingCount,reviews' },
    });
    if (!res.ok) throw new Error(`Places API ${lang}: HTTP ${res.status} ${(await res.text()).slice(0, 300)}`);
    const j = await res.json();
    rating ??= j.rating; count ??= j.userRatingCount;
    found.push(...fromApi(j));
  }
  const fresh = merge(data, found.filter((r, i, a) => a.findIndex((x) => key(x) === key(r)) === i));
  if (rating) data.place.rating = rating;
  if (count) data.place.count = count;
  data.place.captured_at = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
  if (process.argv.includes('--dry-run')) return console.log(`dry-run: uusia ${fresh.length}, arvosana ${data.place.rating}, määrä ${data.place.count}`);
  writeFileSync(FILE, JSON.stringify(data, null, 1) + '\n');
  console.log(`reviews:update ok: uusia ${fresh.length}, yhteensä ${data.reviews.length}, arvosana ${data.place.rating}, määrä ${data.place.count}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main().catch((err) => { console.error('reviews:update epäonnistui:', err.message); process.exit(1); });
