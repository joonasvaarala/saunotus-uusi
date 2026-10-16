// Päivittää content/reviews.json Google Places API (New) -datalla.
// Käyttö: GOOGLE_PLACES_API_KEY=... [GOOGLE_PLACE_ID=...] npm run reviews:update   (--dry-run: ei kirjoita)
// Jos GOOGLE_PLACE_ID puuttuu, paikka haetaan Text Searchilla ("Sipoonjoen perinnesauna Sipoo").
// Jokaiselle arvostelulle tallennetaan `published` (ISO, Places publishTime); koko lista lajitellaan aina uusin ensin.
// Viimeinen rivi onnistuneen ajon jälkeen: REVIEWS_CHANGED=<uusien arvostelujen määrä> (0 = reviews.json ei muutu tästä).
// Rajoite: API palauttaa korkeintaan 5 arvostelua / kutsu, joten osio kasvaa ajan myötä (uudet lisätään, vanhoja ei poisteta).
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { sortReviews } from '../src/reviews-sort.mjs';

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
    const pub = Date.parse(rv.publishTime || '');
    out.push({ author: rv.authorAttribution?.displayName || '', stars: rv.rating, lang, published: Number.isNaN(pub) ? undefined : new Date(pub).toISOString(), text });
  }
  return out;
}

// Yhdistää API-arvostelut: olemassa olevat säilyvät, niiden puuttuva/arvioitu `published` täsmennetään API:n ajasta,
// uudet (ei duplikaatteja) lisätään ja koko lista lajitellaan uusin ensin. Palauttaa {added, refined}.
export function merge(data, found) {
  const byKey = new Map(data.reviews.map((r) => [key(r), r]));
  let added = 0, refined = 0;
  for (const r of found) {
    if (!r.author) continue;
    const old = byKey.get(key(r));
    if (old) {
      if (r.published && (!old.published || old.published_approx)) {
        old.published = r.published;
        delete old.published_approx;
        refined++;
      }
      continue;
    }
    const n = { author: r.author, stars: r.stars, lang: r.lang, ...(r.published && { published: r.published }), text: r.text };
    data.reviews.push(n);
    byKey.set(key(n), n);
    added++;
  }
  data.reviews = sortReviews(data.reviews);
  return { added, refined };
}

// Place ID:n haku Text Searchilla (Places API (New)); valitaan tulos, jonka nimi sisältää 'Sipoonjoen perinnesauna'.
export async function findPlaceId(apiKey) {
  const res = await fetch('https://places.googleapis.com/v1/places:searchText', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Goog-Api-Key': apiKey, 'X-Goog-FieldMask': 'places.id,places.displayName,places.formattedAddress' },
    body: JSON.stringify({ textQuery: 'Sipoonjoen perinnesauna Sipoo', languageCode: 'fi' }),
  });
  if (!res.ok) throw new Error(`Places Text Search: HTTP ${res.status} ${(await res.text()).slice(0, 300)}`);
  const hit = ((await res.json()).places || []).find((p) => /sipoonjoen perinnesauna/i.test(p.displayName?.text || ''));
  if (!hit) return null;
  console.log(`Paikka löytyi: ${hit.id} | ${hit.displayName.text} | ${hit.formattedAddress || ''}`);
  return hit.id;
}

async function main() {
  const apiKey = process.env.GOOGLE_PLACES_API_KEY;
  let placeId = process.env.GOOGLE_PLACE_ID;
  if (!apiKey) {
    console.error('reviews:update: GOOGLE_PLACES_API_KEY puuttuu. Mitään ei muutettu.\n'
      + 'Aseta se ympäristömuuttujaksi (Places API (New) -avain). GOOGLE_PLACE_ID on valinnainen: ilman sitä paikka haetaan nimellä.');
    process.exit(1);
  }
  if (!placeId) {
    placeId = await findPlaceId(apiKey);
    if (!placeId) {
      console.error("reviews:update: Text Search ei löytänyt paikkaa, jonka nimi sisältää 'Sipoonjoen perinnesauna'. Mitään ei muutettu. Aseta GOOGLE_PLACE_ID käsin.");
      process.exit(1);
    }
  }
  const raw = readFileSync(FILE, 'utf8');
  const data = JSON.parse(raw);
  const before = JSON.stringify(data.reviews);
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
  const { added, refined } = merge(data, found.filter((r, i, a) => a.findIndex((x) => key(x) === key(r)) === i));
  const placeChanged = (rating && rating !== data.place.rating) || (count && count !== data.place.count);
  if (rating) data.place.rating = rating;
  if (count) data.place.count = count;
  const changed = JSON.stringify(data.reviews) !== before || placeChanged; // uudet, täsmennetyt ajat tai uudelleenjärjestys, tai arvosana/määrä
  const info = `uusia ${added}, täsmennettyjä aikoja ${refined}, arvosana ${data.place.rating}, määrä ${data.place.count}, yhteensä ${data.reviews.length}`;
  if (process.argv.includes('--dry-run')) return console.log(`dry-run: ${info}${changed ? '' : ' (ei muutoksia)'}`);
  if (changed) {
    if (added) data.place.captured_at = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
    writeFileSync(FILE, JSON.stringify(data, null, 1) + '\n');
    console.log(`reviews:update: tiedosto päivitetty: ${info}${!added ? ' (vain arvosana/määrä/aikaleimat/järjestys muuttui)' : ''}`);
  } else console.log(`reviews:update: ei muutoksia (${info}); tiedostoon ei koskettu`);
  console.log(`REVIEWS_CHANGED=${added}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main().catch((err) => { console.error('reviews:update epäonnistui:', err.message); process.exit(1); });
