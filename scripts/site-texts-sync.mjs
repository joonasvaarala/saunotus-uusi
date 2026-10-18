// Päivittää repossa olevan varatekstin content/site-texts.fallback.json tietokannan julkaistuista teksteistä (vain luku: public_get_site_texts, public_catalog, public_settings; anon-avain).
// Käyttö: BOOKING_SUPABASE_URL=https://<ref>.supabase.co BOOKING_ANON_KEY=<publishable> node scripts/site-texts-sync.mjs
// Varateksti sisältää VAIN tietokannassa julkaistut tekstit (§18.9 kohta 5): uusia tekstejä, joita ei ole tuotu kantaan, ei lisätä tänne.
import { writeFileSync } from 'node:fs';
import { loadSiteTexts, FALLBACK_FILE } from '../src/site-texts.mjs';
const url = process.env.BOOKING_SUPABASE_URL, key = process.env.BOOKING_ANON_KEY;
if (!url || !key) { console.error('käyttö: BOOKING_SUPABASE_URL=… BOOKING_ANON_KEY=… node scripts/site-texts-sync.mjs'); process.exit(2); }
const s = await loadSiteTexts({ env: { ...process.env, SITE_TEXTS_STRICT: '1', SITE_TEXTS_FIXTURE: '' }, cacheDir: '/tmp/site-texts-sync-cache' });
if (s.source !== 'rpc') { console.error('haku ei onnistunut'); process.exit(1); }
const doc = { _doc: 'Varateksti: tietokannan julkaistut sivutekstit (public_get_site_texts) + paikkamerkkien data (hinta/kesto/julkiset asetukset). Käytetään vain jos haku epäonnistuu eikä .cache-välimuistia ole. Päivitys: node scripts/site-texts-sync.mjs',
  generated_at: s.generatedAt, texts: s.rows, context: { catalog: s.catalog, settings: s.settings } };
writeFileSync(FALLBACK_FILE, JSON.stringify(doc, null, 1) + '\n');
console.log(`kirjoitettu ${FALLBACK_FILE}: ${s.rows.length} riviä`);
