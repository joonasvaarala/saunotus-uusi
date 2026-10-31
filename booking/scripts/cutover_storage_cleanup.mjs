#!/usr/bin/env node
// Käyttöönoton nollauksen jälkeen: poistaa yksityisistä bucketeista (receipts, invoices, …)
// PDF-tiedostot, joihin mikään säilynyt rivi ei enää viittaa. SQL ei voi poistaa niitä
// (storage.protect_delete), joten poisto tehdään Storage-rajapinnan kautta.
//
// 1) Hae lista SQL:llä (tietokannan omistajana, nollauksen jälkeen):
//      \copy (select coalesce(json_agg(json_build_object('bucket', bucket, 'path', path)), '[]') from booking._cutover_storage_orphans()) to 'orphans.json'
//    tai kopioi cutover_reset(false)-tuloksen kenttä "storage_objects" tiedostoon orphans.json.
// 2) Kuivaharjoitus (oletus, ei poista mitään):
//      SUPABASE_URL=https://<ref>.supabase.co SUPABASE_SERVICE_ROLE_KEY=... node booking/scripts/cutover_storage_cleanup.mjs orphans.json
// 3) Poisto:
//      ... node booking/scripts/cutover_storage_cleanup.mjs orphans.json --apply
// 4) Tarkista: select booking.cutover_reset_verify() ->> 'storage_ok';  -- true
//
// Avainta ei tulosteta. Vain yksityiset bucketit hyväksytään.
import { readFileSync } from 'node:fs';

const PRIVATE_BUCKETS = new Set(['receipts', 'invoices', 'gift-cards', 'gift_cards']);
const args = process.argv.slice(2);
const apply = args.includes('--apply');
const file = args.find((a) => !a.startsWith('--'));
if (!file) {
  console.error('Käyttö: node cutover_storage_cleanup.mjs orphans.json [--apply]');
  process.exit(2);
}

let items = JSON.parse(readFileSync(file, 'utf8'));
if (items && !Array.isArray(items) && Array.isArray(items.storage_objects)) items = items.storage_objects;
if (!Array.isArray(items)) throw new Error('Odotettiin taulukkoa [{bucket, path}]');

const byBucket = new Map();
for (const it of items) {
  const bucket = String(it?.bucket ?? '');
  const path = String(it?.path ?? '');
  if (!bucket || !path) throw new Error('Rivi ilman bucket/path-kenttää');
  if (!PRIVATE_BUCKETS.has(bucket)) throw new Error(`Bucket ${bucket} ei ole sallittu (vain yksityiset PDF-bucketit)`);
  if (path.includes('..') || path.startsWith('/')) throw new Error(`Epäkelpo polku: ${path}`);
  if (!byBucket.has(bucket)) byBucket.set(bucket, []);
  byBucket.get(bucket).push(path);
}

for (const [bucket, paths] of byBucket) console.log(`${bucket}: ${paths.length} tiedostoa`);
if (!apply) {
  for (const [bucket, paths] of byBucket) for (const p of paths) console.log(`  ${bucket}/${p}`);
  console.log('Kuivaharjoitus. Poista lisäämällä --apply.');
  process.exit(0);
}

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) {
  console.error('Aseta SUPABASE_URL ja SUPABASE_SERVICE_ROLE_KEY.');
  process.exit(2);
}

let failed = 0;
for (const [bucket, paths] of byBucket) {
  for (let i = 0; i < paths.length; i += 100) {
    const chunk = paths.slice(i, i + 100);
    const res = await fetch(`${url.replace(/\/$/, '')}/storage/v1/object/${encodeURIComponent(bucket)}`, {
      method: 'DELETE',
      headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ prefixes: chunk }),
    });
    const body = await res.text();
    if (!res.ok) {
      failed += chunk.length;
      console.error(`${bucket}: virhe ${res.status} ${body.slice(0, 200)}`);
      continue;
    }
    let removed = [];
    try { removed = JSON.parse(body); } catch { /* ignore */ }
    console.log(`${bucket}: poistettu ${Array.isArray(removed) ? removed.length : '?'} / ${chunk.length}`);
  }
}
process.exit(failed ? 1 : 0);
