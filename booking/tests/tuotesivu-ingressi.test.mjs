// Joonas 28.10.2026: tuotesivun "paraatipaikalla" (kalenterin vieressä) näkyy hinta + tuotteen lyhyt kuvaus (leadShort).
// Joonas 29.10.2026: pitkä kuvaus on heti lyhyen kuvauksen jälkeen, suljettuna (Lue lisää / Read more). Uima-asuohje on
// pitkässä kuvauksessa ja peruutusehto saman osion lopussa sekä kassalla (legalFields showCancel). Lyhyt kuvaus ei toistu yläbannerissa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { T } from '../shop/src/i18n.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const read = (rel) => readFileSync(join(root, rel), 'utf8');
const S = await import(pathToFileURL(join(root, 'shop/src/short-desc.js')).href);
const h = (tag, attrs = {}) => ({ tag, cls: attrs.class ?? null, text: attrs.text, attrs: {}, setAttribute(k, v) { this.attrs[k] = v; } });

test('leadShort: lyhyt kuvaus kielen mukaan, EN puuttuu → FI', () => {
  const p = { short_description: 'Lämmin savusauna.', short_description_en: 'A warm smoke sauna.' };
  assert.equal(S.leadShort(h, p, 'fi', '').text, 'Lämmin savusauna.');
  assert.equal(S.leadShort(h, p, 'en', '').text, 'A warm smoke sauna.');
  assert.equal(S.leadShort(h, { short_description: 'Vain suomeksi.' }, 'en', '').text, 'Vain suomeksi.');
  const el = S.leadShort(h, p, 'fi', '');
  assert.equal(el.cls, 'bk-lead'); assert.equal(el.attrs['data-testid'], 'lead');
});

test('leadShort: tyhjä lyhyt kuvaus → ensimmäinen virke pitkästä kuvauksesta; ei kumpaakaan → null', () => {
  const desc = 'Savusauna lämpiää koko päivän. Viikonloppuisin saunomme uima-asussa.';
  assert.equal(S.leadShort(h, { short_description: '<p><br></p>' }, 'fi', desc).text, 'Savusauna lämpiää koko päivän.');
  assert.equal(S.leadShort(h, {}, 'fi', ''), null);
});

for (const [file, fn] of [['shop/src/shop.js', 'viewProduct'], ['shop/src/treatment-ui.js', 'viewTreatment']]) {
  test(`${file}: ${fn} näyttää ingressin, ei uima-asu- tai peruutustekstiä kalenterin vieressä`, () => {
    const src = read(file);
    const start = src.indexOf(`function ${fn}(`); assert.ok(start > 0);
    const body = src.slice(start, src.indexOf('\n  }\n', start) > 0 && fn === 'viewTreatment' ? src.indexOf('\n  }\n', start) : src.indexOf('\n}\n', start));
    const facts = body.slice(body.indexOf("'bk-facts'"), body.indexOf("'bk-prod-cal'"));
    assert.match(facts, /leadShort\(h, p, S\.lang, desc\)/);
    assert.doesNotMatch(facts, /swimwear|S\.cancelRule|includedPlain/);
    const leadAt = facts.indexOf('leadShort(h, p, S.lang, desc)');
    const moreAt = facts.indexOf('moreInfo(desc)');
    const jumpAt = facts.indexOf("'bk-jump'");
    assert.ok(leadAt >= 0 && moreAt > leadAt && jumpAt > moreAt, 'pitkä kuvaus heti lyhyen kuvauksen jälkeen, ennen Valitse aika -linkkiä');
    assert.equal(body.slice(body.indexOf("'bk-prod-cal'")).includes('moreInfo(desc)'), false, 'vanha alaosio ei jää kalenterin alle');
    assert.match(body, /setHero\(p( \|\| null)?, \{ short: false \}\)/);
  });
}

test('moreInfo: painike Lue lisää, pitkä kuvaus ja peruutusehto samassa osiossa; kassa näyttää peruutusehdon edelleen', () => {
  const src = read('shop/src/shop.js');
  const start = src.indexOf('function moreInfo(');
  const m = src.slice(start, src.indexOf('\n// ---- näkymä', start));
  assert.match(m, /'bk-more'/); assert.match(m, /richHost\(h, desc, 'bk-desc'\)/); assert.match(m, /'product-cancel'/);
  assert.match(m, /type: 'button'/); assert.match(m, /'aria-expanded': 'false'/); assert.match(m, /'aria-controls': 'bk-read-more'/);
  assert.match(m, /text: t\.readMore/); assert.match(m, /t\.showLess/);
  assert.doesNotMatch(m, /h\('details'|h\('summary'|t\.moreInfo/);
  assert.match(read('shop/src/shop.css'), /\.bk-more-toggle:focus\{outline:none\}/);
  assert.match(read('shop/src/shop.css'), /\.bk-more-toggle:focus-visible\{outline:3px solid var\(--ink\)/);
  assert.match(src, /showCancel && S\.cancelRule/);
  assert.equal((src.match(/legalFields\(\{ showCancel: true \}\)/g) || []).length, 1);
  assert.match(read('shop/src/treatment-ui.js'), /legalFields\(\{ showCancel: true \}\)/);
});

test('Lue lisää / Read more ja Näytä vähemmän / Show less: pending-import-100, ei kovakoodattu tuotantoon vielä', () => {
  const rows = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-100.json'), 'utf8'));
  const fallback = JSON.parse(readFileSync(join(repo, 'content/site-texts.fallback.json'), 'utf8'));
  const have = new Set(fallback.texts.map((r) => `${r.key}|${r.lang}`));
  assert.equal(T.fi.readMore, 'Lue lisää'); assert.equal(T.en.readMore, 'Read more');
  assert.equal(T.fi.showLess, 'Näytä vähemmän'); assert.equal(T.en.showLess, 'Show less');
  assert.equal(T.fi.moreInfo, 'Lisätietoja', 'vanha Lisätietoja-avain ennallaan');
  const want = { 'ui.shop.read_more': { fi: T.fi.readMore, en: T.en.readMore }, 'ui.shop.show_less': { fi: T.fi.showLess, en: T.en.showLess } };
  assert.equal(rows.length, 4);
  for (const r of rows) {
    assert.equal(r.text, want[r.key][r.lang], `${r.key} ${r.lang}`);
    assert.equal(r.class, 'normal'); assert.equal(r.kind, 'plain');
    assert.ok(r.max_len >= r.text.length);
    assert.deepEqual(r.placeholders, []);
    assert.equal(have.has(`${r.key}|${r.lang}`), false, `${r.key} on jo varatekstissä`);
  }
});

test('setHero: short=false tyhjentää yläbannerin alaotsikon, kassalla (oletus) lyhyt kuvaus säilyy', () => {
  const src = read('shop/src/shop.js');
  assert.match(src, /function setHero\(p, \{ short = true \} = \{\}\)/);
  assert.match(src, /short \? heroShort\(h, p, S\.lang, pdesc\(p\)\) : \{ node: null, text: '' \}/);
});
