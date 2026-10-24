// Tuotesivun/kaupan vaakaylivuoto (Joonas 24.10.2026, puhelin ~390 px): kb.products-kuvauksissa joka sanaväli on &nbsp; (U+00A0),
// jolloin kappale, otsikko ja yläbannerin lyhyt kuvaus eivät rivity ja koko sivu venyy sivusuunnassa.
// Korjaus: text-spaces.js normalisoi sitovat välit näyttöhetkellä (rich-view.js: richHost + visibleText, shop.js: pname);
// tietokannan tekstiä ei muuteta. shop.css: overflow-wrap + max-width-varmistukset (ei overflow-x:hidden-piilotusta).
// Selaintarkistus (playwright 320/360/390 px, kaikki näkymät) tehtiin PR:ssä erikseen; tämä testi ei käytä verkkoa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const read = (rel) => readFileSync(join(repo, rel), 'utf8');
const { softenSpaces } = await import(pathToFileURL(join(root, 'shop/src/text-spaces.js')).href);
const { visibleText, richHost } = await import(pathToFileURL(join(root, 'shop/src/rich-view.js')).href);
const { derivedShort, derivedExcerpt, heroShort } = await import(pathToFileURL(join(root, 'shop/src/short-desc.js')).href);
const NB = '\u00a0';
const nbspText = (s) => s.replace(/ /g, NB);

test('softenSpaces: sanavälien &nbsp; → välilyönti, luku + yksikkö säilyy sitovana', () => {
  assert.equal(softenSpaces(nbspText('Tule nauttimaan yhteisöllisestä saunaelämyksestä')), 'Tule nauttimaan yhteisöllisestä saunaelämyksestä');
  assert.equal(softenSpaces(`kylmä-${NB}ja${NB}lämminvesialtaisiin`), 'kylmä- ja lämminvesialtaisiin');
  assert.equal(softenSpaces(`vuokra:${NB}5${NB}€`), `vuokra: 5${NB}€`);
  assert.equal(softenSpaces(`1${NB}000${NB}euroa`), `1${NB}000 euroa`);
  assert.equal(softenSpaces(`2${NB}h ja 60${NB}min, 30${NB}%`), `2${NB}h ja 60${NB}min, 30${NB}%`);
  assert.equal(softenSpaces(`2${NB}henkeä`), '2 henkeä');
  assert.equal(softenSpaces(`a\u202fb\u2007c`), 'a b c');
  assert.equal(softenSpaces('ei muutosta'), 'ei muutosta');
  assert.equal(softenSpaces(null), '');
});

test('tuotannon kuvaus (kb 1 Yleinen vuoro, repon kb-snapshot): näkyvässä tekstissä ei sitovia sanavälejä', () => {
  const kb = JSON.parse(read('content/kb/kb.json'));
  const p = kb.products.find((x) => x.slug === 'yleinensauna');
  assert.ok(p && p.description.includes(NB), 'fixture: kuvauksessa on &nbsp; (juurisyy)');
  const vis = visibleText(p.description);
  assert.ok(!/[\p{L}]\u00a0[\p{L}]/u.test(vis), 'kirjainten välissä ei &nbsp;');
  assert.match(vis, /kylmä- ja lämminvesialtaisiin/);
  for (const raw of [p.description, nbspText('Ota ystävät tai perhe mukaan ja tule nauttimaan yhteisöllisestä saunaelämyksestä. Toinen virke.')]) {
    assert.ok(!derivedShort(raw).includes(NB));
    assert.ok(!derivedExcerpt(raw).includes(NB));
  }
});

test('richHost (pelkkä teksti) ja heroShort normalisoivat; kaikki kaupan kuvausnäkymät kulkevat rich-view.js:n kautta', () => {
  const h = (tag, attrs) => ({ tag, ...attrs });
  assert.equal(richHost(h, nbspText('Pelkkä teksti ilman HTML:ää'), 'bk-desc').text, 'Pelkkä teksti ilman HTML:ää');
  const hs = heroShort(h, { short_description: nbspText('Ota ystävät tai perhe mukaan') }, 'fi', '');
  assert.equal(hs.text, 'Ota ystävät tai perhe mukaan');
  const rv = read('booking/shop/src/rich-view.js');
  assert.match(rv, /softenSpacesIn\(el\)/, 'rikas HTML: tekstisolmut normalisoidaan sanitizeRichin jälkeen (&nbsp;-entiteetit)');
  assert.match(read('booking/shop/src/shop.js'), /const pname = \(p\) => softenSpaces\(/);
});

test('shop.css: rivitys- ja leveysvarmistukset, ei overflow-x:hidden-piilotusta', () => {
  const css = read('booking/shop/src/shop.css');
  assert.match(css, /\.bk-rich,\.bk-desc,\.bk-hero-short,\.hero\.page \.in p[^{]*\{overflow-wrap:anywhere\}/);
  assert.match(css, /\.hero\.page \.in>p\{max-width:min\(30em,100%\)\}/);
  assert.match(css, /#booking-app :is\(img,video,iframe,embed,object,svg,table\)[^{]*\{max-width:100%\}/);
  assert.match(css, /\.bk-grid\{grid-template-columns:repeat\(7,minmax\(0,1fr\)\)\}/, 'kalenteri mahtuu 320 px:iin');
  assert.doesNotMatch(css + read('src/styles.css'), /(?:html|body)\s*\{[^}]*overflow-x\s*:\s*hidden/);
});
