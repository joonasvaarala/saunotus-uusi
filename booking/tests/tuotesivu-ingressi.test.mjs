// Joonas 28.10.2026: tuotesivun "paraatipaikalla" (kalenterin vieressä) näkyy hinta + tuotteen lyhyt kuvaus (leadShort).
// Uima-asu- ja peruutustekstit eivät enää ole siinä: uima-asuohje on pitkässä kuvauksessa ja peruutusehto Lisätietoja-osion
// lopussa (moreInfo) sekä kassalla (legalFields showCancel). Lyhyt kuvaus ei toistu yläbannerissa tuotesivulla (setHero short:false).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
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
    assert.match(body, /moreInfo\(desc\)/);
    assert.match(body, /setHero\(p( \|\| null)?, \{ short: false \}\)/);
  });
}

test('moreInfo: pitkä kuvaus + peruutusehto Lisätietoja-osiossa; kassa näyttää peruutusehdon edelleen', () => {
  const src = read('shop/src/shop.js');
  const m = src.slice(src.indexOf('function moreInfo('), src.indexOf('function moreInfo(') + 600);
  assert.match(m, /'bk-more'/); assert.match(m, /richHost\(h, desc, 'bk-desc'\)/); assert.match(m, /'product-cancel'/);
  assert.match(src, /showCancel && S\.cancelRule/);
  assert.equal((src.match(/legalFields\(\{ showCancel: true \}\)/g) || []).length, 1);
  assert.match(read('shop/src/treatment-ui.js'), /legalFields\(\{ showCancel: true \}\)/);
});

test('setHero: short=false tyhjentää yläbannerin alaotsikon, kassalla (oletus) lyhyt kuvaus säilyy', () => {
  const src = read('shop/src/shop.js');
  assert.match(src, /function setHero\(p, \{ short = true \} = \{\}\)/);
  assert.match(src, /short \? heroShort\(h, p, S\.lang, pdesc\(p\)\) : \{ node: null, text: '' \}/);
});
