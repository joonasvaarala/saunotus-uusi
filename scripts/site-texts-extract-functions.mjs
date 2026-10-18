// Luo tuontitiedoston content/site-texts.imported-pr66.json edge-funktioiden (sähköpostit, PDF:t, MobilePay-virhesivu) asiakasnäkyvistä teksteistä (sopimus §18, osa 3 PR 3).
// Lähde = booking/supabase/functions/*/texts.ts (repon oletukset): tiedosto ei voi poiketa oletuksista (testi vertaa).
// EI ylikirjoita tuotannon tekstejä: mukaan tulevat vain avaimet (avain+kieli), joita ei ole tuotannon public_get_site_texts-vastauksessa.
// Vaatii Noden tyyppien poiston (22.18+).
// Käyttö:  node scripts/site-texts-extract-functions.mjs --prod /tmp/prod-texts.json [--out content/site-texts.imported-pr66.json]
// Tuonti: admin_texts_import(p_items) enintään 500 riviä kerrallaan (Bottiavustus ajaa).
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { collectFunctionDefaults, tokensOf, maxLenFor } from '../src/function-texts.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const arg = (n) => { const i = process.argv.indexOf(n); return i > 0 ? process.argv[i + 1] : null; };
const prodFile = arg('--prod'), outFile = resolve(arg('--out') || `${root}/content/site-texts.imported-pr66.json`);
if (!prodFile) { console.error('käyttö: node scripts/site-texts-extract-functions.mjs --prod <public_get_site_texts-vastaus.json> [--out tiedosto]'); process.exit(2); }
const prod = JSON.parse(readFileSync(prodFile, 'utf8'));
if (!prod?.ok || !Array.isArray(prod.texts)) { console.error('tuotannon vastaus ei ole {ok:true, texts:[…]}'); process.exit(1); }
const have = new Set(prod.texts.map((r) => `${r.key}|${r.lang}`));

const entries = collectFunctionDefaults();
const fi = new Map(entries.filter((e) => e.lang === 'fi').map((e) => [e.key, e.text])), en = new Map(entries.filter((e) => e.lang === 'en').map((e) => [e.key, e.text]));
const rows = [];
for (const e of entries) {
  if (have.has(`${e.key}|${e.lang}`)) continue;
  rows.push({ key: e.key, lang: e.lang, text: e.text, class: e.class, kind: 'plain', max_len: e.max ?? maxLenFor(fi.get(e.key), en.get(e.key) || ''), placeholders: tokensOf(e.text),
    reason: `Osa 3 PR 3: kovakoodattu asiakasnäkyvä teksti (${e.src}); sisältö ennallaan, ei uusia sanamuotoja` });
}
writeFileSync(outFile, JSON.stringify(rows, null, 1) + '\n');
const keys = new Set(rows.map((r) => r.key));
console.log(`kirjoitettu ${outFile}: ${rows.length} riviä (${keys.size} avainta); tuotannossa jo olevia ohitettu ${entries.length - rows.length}; protected ${new Set(rows.filter((r) => r.class === 'protected').map((r) => r.key)).size} avainta; paikkamerkillisiä rivejä ${rows.filter((r) => r.placeholders.length).length}`);
