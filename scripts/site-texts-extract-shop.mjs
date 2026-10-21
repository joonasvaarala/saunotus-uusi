// Luo tuontitiedoston content/site-texts.pending-import.json kaupan kovakoodatuista asiakasnäkyvistä teksteistä (sopimus §18, osa 3 PR 1).
// Lähde = koodi itse (booking/shop/src/text-registry.js + shop-page-texts.js): tiedosto ei voi poiketa koodin oletuksista (testi vertaa).
// EI ylikirjoita tuotannon tekstejä: mukaan tulevat vain avaimet (avain+kieli), joita ei ole tuotannon public_get_site_texts-vastauksessa.
// Käyttö:  curl -s -X POST "$URL/rest/v1/rpc/public_get_site_texts" -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Profile: booking" -H 'Content-Type: application/json' -d '{}' > /tmp/prod-texts.json
//          node scripts/site-texts-extract-shop.mjs --prod /tmp/prod-texts.json [--out content/site-texts.pending-import.json]
// Tuonti: admin_texts_import(p_items) enintään 500 riviä kerrallaan (Bottiavustus ajaa): jq -c '[.[range(0;500)]]' …  /  '[.[range(500;1000)]]' …  jne.
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { collectDefaults, classFor } from '../booking/shop/src/text-registry.js';
import { SHOP_PAGE_TEXTS } from '../booking/shop/src/shop-page-texts.js';
import { tokensOf } from '../booking/shop/src/site-texts-logic.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const arg = (n) => { const i = process.argv.indexOf(n); return i > 0 ? process.argv[i + 1] : null; };
const prodFile = arg('--prod'), outFile = resolve(arg('--out') || `${root}/content/site-texts.pending-import.json`);
if (!prodFile) { console.error('käyttö: node scripts/site-texts-extract-shop.mjs --prod <public_get_site_texts-vastaus.json> [--out tiedosto]'); process.exit(2); }
const prod = JSON.parse(readFileSync(prodFile, 'utf8'));
if (!prod?.ok || !Array.isArray(prod.texts)) { console.error('tuotannon vastaus ei ole {ok:true, texts:[…]}'); process.exit(1); }
const have = new Set(prod.texts.map((r) => `${r.key}|${r.lang}`));

const FILES = { T: 'i18n.js', OT: 'order-texts.js', GT: 'gift-texts.js', HT: 'hold-texts.js', PT: 'pay-choices-texts.js', MT: 'mobilepay-texts.js', VT: 'vismapay-texts.js', OPT: 'options-texts.js' };
const entries = collectDefaults().map((r) => ({ key: r.key, lang: r.lang, text: r.text, src: `booking/shop/src/${FILES[r.id]}` }));
for (const p of SHOP_PAGE_TEXTS) for (const lang of ['fi', 'en']) entries.push({ key: p.key, lang, text: p[lang], src: 'booking/shop/build.mjs' });
const fiText = new Map(entries.filter((e) => e.lang === 'fi').map((e) => [e.key, e.text]));
const maxLen = (t) => Math.max(200, Math.ceil((t.length * 2.5) / 50) * 50);
const rows = [];
const order = [...new Set(entries.map((e) => e.key))];
for (const key of order) for (const lang of ['fi', 'en']) {
  const e = entries.find((x) => x.key === key && x.lang === lang);
  if (!e) throw new Error(`${key}: kieli ${lang} puuttuu`);
  if (have.has(`${key}|${lang}`)) continue;                      // olemassa tuotannossa → ei kosketa
  rows.push({ key, lang, text: e.text, class: classFor(key, fiText.get(key)), kind: 'plain', max_len: Math.max(maxLen(fiText.get(key)), maxLen(e.text)), placeholders: tokensOf(e.text),
    reason: `Osa 3 PR 1: kovakoodattu asiakasnäkyvä teksti (${e.src}); sisältö ennallaan, ei uusia sanamuotoja` });
}
writeFileSync(outFile, JSON.stringify(rows, null, 1) + '\n');
const skipped = entries.length - rows.length;
console.log(`kirjoitettu ${outFile}: ${rows.length} riviä (${new Set(rows.map((r) => r.key)).size} avainta); tuotannossa jo olevia ohitettu ${skipped}; protected ${new Set(rows.filter((r) => r.class === 'protected').map((r) => r.key)).size} avainta`);
