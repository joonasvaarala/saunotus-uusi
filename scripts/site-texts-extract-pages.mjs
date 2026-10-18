// Luo tuontitiedoston content/site-texts.pending-import-2.json staattisten sivujen asiakasnäkyvistä teksteistä (sopimus §18, osa 3 PR 2).
// Lähde = koodi/repon JSON (src/content-texts.mjs): tiedosto ei voi poiketa repon oletuksista (testi vertaa).
// EI ylikirjoita tuotannon tekstejä: mukaan tulevat vain avaimet (avain+kieli), joita ei ole tuotannon public_get_site_texts-vastauksessa.
// Käyttö:  sh -c 'curl … public_get_site_texts … > /tmp/prod-texts.json'  (vain luku, anon-avain)
//          node scripts/site-texts-extract-pages.mjs --prod /tmp/prod-texts.json [--out content/site-texts.pending-import-2.json]
// Tuonti: admin_texts_import(p_items) enintään 500 riviä kerrallaan (Bottiavustus ajaa): jq -c '[.[range(0;500)]]' …  /  '[.[range(500;1000)]]'
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { collectContentDefaults, classForContent, maxLenFor } from '../src/content-texts.mjs';
import { tokensOf } from '../booking/shop/src/site-texts-logic.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const arg = (n) => { const i = process.argv.indexOf(n); return i > 0 ? process.argv[i + 1] : null; };
const prodFile = arg('--prod'), outFile = resolve(arg('--out') || `${root}/content/site-texts.pending-import-2.json`);
if (!prodFile) { console.error('käyttö: node scripts/site-texts-extract-pages.mjs --prod <public_get_site_texts-vastaus.json> [--out tiedosto]'); process.exit(2); }
const prod = JSON.parse(readFileSync(prodFile, 'utf8'));
if (!prod?.ok || !Array.isArray(prod.texts)) { console.error('tuotannon vastaus ei ole {ok:true, texts:[…]}'); process.exit(1); }
const have = new Set(prod.texts.map((r) => `${r.key}|${r.lang}`));

const entries = collectContentDefaults();
const fi = new Map(entries.filter((e) => e.lang === 'fi').map((e) => [e.key, e.text])), en = new Map(entries.filter((e) => e.lang === 'en').map((e) => [e.key, e.text]));
const rows = [];
for (const e of entries) {
  if (have.has(`${e.key}|${e.lang}`)) continue;                  // tuotannossa jo → ei kosketa
  const f = fi.get(e.key) ?? e.text;
  rows.push({ key: e.key, lang: e.lang, text: e.text, class: classForContent(e.key, f), kind: e.text.includes('**') ? 'lite' : 'plain', max_len: maxLenFor(f, en.get(e.key) || ''), placeholders: tokensOf(e.text),
    reason: `Osa 3 PR 2: kovakoodattu asiakasnäkyvä teksti (${e.src}); sisältö ennallaan, ei uusia sanamuotoja${e.text.includes('**') ? '; **lihavointi** vastaa sivun strong-merkintää' : ''}` });
}
writeFileSync(outFile, JSON.stringify(rows, null, 1) + '\n');
console.log(`kirjoitettu ${outFile}: ${rows.length} riviä (${new Set(rows.map((r) => r.key)).size} avainta); tuotannossa jo olevia ohitettu ${entries.length - rows.length}; protected ${new Set(rows.filter((r) => r.class === 'protected').map((r) => r.key)).size} avainta; lite (lihavointi) ${rows.filter((r) => r.kind === 'lite').length} riviä`);
