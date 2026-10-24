// Muuntaa kb-tietokannan viennin (docs/kb-export.sql) julkiseksi snapshotiksi content/kb/kb.json.
// Sallittujen kenttien lista (allowlist): sisäiset huomautukset (review_note, source_url, ym.) EIVÄT päädy repoon.
import { readFileSync, writeFileSync } from 'node:fs';
const file = process.argv[2];
if (!file) { console.error('käyttö: node scripts/kb-snapshot.mjs export.json'); process.exit(1); }
let raw = JSON.parse(readFileSync(file, 'utf8'));
if (Array.isArray(raw)) raw = raw[0].d ?? raw[0];
if (raw.d) raw = raw.d;
const pick = (o, keys) => Object.fromEntries(keys.filter((k) => o[k] !== null && o[k] !== undefined && o[k] !== '').map((k) => [k, o[k]]));
const out = {
  _doc: 'Snapshot kb-tietokannasta (vain julkiset kentät, active=true, internal=false). Päivitä: docs/kb-export.sql + scripts/kb-snapshot.mjs',
  snapshot_at: new Date().toISOString(),
  business: pick(raw.businesses[0], ['trade_name','legal_name','business_id','street_address','postal_code','city','phone','email','website','booking_url','social_links']),
  locations: raw.locations.filter((l) => l.active).map((l) => pick(l, ['id','name','location_type','description','accessibility','public_transport','parking','directions','amenities'])),
  products: raw.products.filter((p) => p.active).map((p) => pick(p, ['id','slug','name','name_en','category','price','price_type','price_text','included_persons','extra_person_price','duration_minutes','duration_text','duration_text_en','capacity_min','capacity_max','booking_url','includes_smoke_sauna','location_id','description'])),
  variants: raw.variants.filter((v) => v.active).map((v) => pick(v, ['id','product_id','label','price','duration_minutes','weekdays','time_start','time_end','included_persons','extra_person_price','valid_from','valid_to'])),
  hours: raw.hours.filter((h) => h.active).map((h) => pick(h, ['id','weekday','opens','closes','session_name','session_type','swimsuit_rule','product_id'])),
  events: raw.events.filter((e) => e.active).map((e) => pick(e, ['id','product_id','starts_on','ends_on','time_text'])),
  policies: raw.policies.filter((p) => p.status === 'active' && !p.internal).map((p) => pick(p, ['id','category','title','body','language'])),
  faq: raw.faq.filter((f) => f.active).map((f) => pick(f, ['id','question','answer','language','category','sort_order']))
};
writeFileSync('content/kb/kb.json', JSON.stringify(out, null, 1) + '\n');
console.log('kirjoitettu content/kb/kb.json', Object.fromEntries(Object.entries(out).filter(([, v]) => Array.isArray(v)).map(([k, v]) => [k, v.length])));
