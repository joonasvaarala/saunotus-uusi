// SIVU-JUOMAT-01 (UX-analyysi #345): /juomat/ ja /en/drinks/ saavat moduulinsa vain scripts/build-pages.mjs:n listoista
// DRINK_JS (booking/drinks) ja DRINK_PAY_UI (booking/shop/src). Tuotannossa plural.js ja hold-texts.js puuttuivat (404),
// jolloin koko moduulipuu kaatui ja kylmälaitteen QR-maksusivu jäi tyhjäksi. Testi kaatuu, jos juomasivun importtipuusta
// puuttuu tiedosto listalta tai koonnin tuotoksesta. Lisäksi HALL-TILAUS-02: dynaamiset importit saavat versiotunnuksen.
import test from 'node:test';
import assert from 'node:assert/strict';
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { missingImportTargets, moduleGraph, relativeImports, unversionedImports, versionImports } from '../../scripts/module-imports.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const build = readFileSync(join(root, 'scripts/build-pages.mjs'), 'utf8');
const list = (name) => {
  const m = build.match(new RegExp(`const ${name} = \\[([^\\]]*)\\]`));
  assert.ok(m, `${name} puuttuu build-pages.mjs:stä`);
  return [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]);
};
const DRINK_JS = list('DRINK_JS');
const DRINK_PAY_UI = list('DRINK_PAY_UI');

function drinkEntries() {
  const out = new Set();
  for (const html of ['index.html', 'index.en.html']) {
    const t = readFileSync(join(root, 'booking/drinks', html), 'utf8');
    for (const m of t.matchAll(/<script[^>]*type="module"[^>]*src="\.\/([^"?]+\.js)"/g)) out.add(`booking/drinks/${m[1]}`);
  }
  return [...out];
}

test('juomasivun koko importtipuu on build-listoilla (DRINK_JS / DRINK_PAY_UI)', () => {
  const entries = drinkEntries();
  assert.ok(entries.includes('booking/drinks/drinks.js'), 'index.html lataa drinks.js:n');
  const graph = new Set(entries.flatMap((e) => [...moduleGraph(root, e)]));
  const missing = [];
  for (const f of graph) {
    if (f.startsWith('booking/drinks/')) { if (!DRINK_JS.includes(f.slice('booking/drinks/'.length))) missing.push(`${f} → DRINK_JS`); }
    else if (f.startsWith('booking/shop/src/')) { if (!DRINK_PAY_UI.includes(f.slice('booking/shop/src/'.length))) missing.push(`${f} → DRINK_PAY_UI`); }
    else missing.push(`${f} (kansio, jota juomasivun julkaisu ei kopioi)`);
  }
  assert.deepEqual(missing, [], `puuttuu build-listalta: ${missing.join(', ')}`);
  // regressio: tuotannon 404:t
  for (const f of ['plural.js', 'hold-texts.js']) assert.ok(DRINK_PAY_UI.includes(f), f);
});

test('listalla ei ole tiedostoa, jota ei ole olemassa', () => {
  for (const f of DRINK_JS) assert.ok(existsSync(join(root, 'booking/drinks', f)), `booking/drinks/${f}`);
  for (const f of DRINK_PAY_UI) assert.ok(existsSync(join(root, 'booking/shop/src', f)), `booking/shop/src/${f}`);
});

test('koonnin tuotos: litistetty juomakansio (kuten publishDrinks) ei viittaa puuttuvaan tiedostoon', () => {
  const dir = mkdtempSync(join(tmpdir(), 'juomat-'));
  try {
    for (const f of [...DRINK_JS, 'qrcode-generator.js']) cpSync(join(root, 'booking/drinks', f), join(dir, f));
    for (const f of DRINK_PAY_UI) cpSync(join(root, 'booking/shop/src', f), join(dir, f));
    for (const f of [...DRINK_JS, ...DRINK_PAY_UI]) {
      const p = join(dir, f);
      let t = readFileSync(p, 'utf8');
      t = t.replace(/(\b(?:from|import)\s*)(['"])\.\.\/shop\/src\/([^'"?]+\.js)\2/g, (_, a, q, u) => `${a}${q}./${u}${q}`);
      writeFileSync(p, versionImports(t, '?v=test').text);
    }
    assert.deepEqual(missingImportTargets(dir, { recursive: false }), []);
    // ilman korjausta (vanha lista) tuotos viittaisi puuttuviin tiedostoihin
    rmSync(join(dir, 'plural.js')); rmSync(join(dir, 'hold-texts.js'));
    assert.deepEqual(missingImportTargets(dir, { recursive: false }).sort(), ['gift-texts.js: ./hold-texts.js', 'gift-texts.js: ./plural.js']);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('jos valmis dist/juomat on olemassa, sen importit osuvat tiedostoihin', (t) => {
  const out = resolve(process.env.DIST || join(root, 'dist'));
  const dirs = ['juomat', 'en/drinks'].map((d) => join(out, d)).filter((d) => existsSync(join(d, 'index.html')));
  if (!dirs.length) { t.skip('ei dist/juomat-kansiota (aja build ensin)'); return; }
  for (const d of dirs) assert.deepEqual(missingImportTargets(d, { recursive: false }), [], d);
});

test('build-pages tarkistaa juomakansion ja hallinnan importit (build kaatuu)', () => {
  assert.match(build, /missingImportTargets\(dir, \{ recursive: false \}\)/);
  assert.match(build, /versioimaton relatiivinen import/);
});

test('HALL-TILAUS-02: versionImports kattaa staattiset ja dynaamiset importit, ei kahdesti', () => {
  const src = [
    "import { a } from './a.js';",
    "import './side.js';",
    "export { b } from '../b.js';",
    "const [{ x }, { y }] = await Promise.all([import('./order-view.js'), import( \"../order-open.js\" )]);",
    "import('formats/link'); import(viewUrl(name)); import('./done.js?v=1');",
  ].join('\n');
  const { text, count } = versionImports(src, '?v=abc');
  assert.equal(count, 5);
  assert.match(text, /from '\.\/a\.js\?v=abc'/);
  assert.match(text, /import '\.\/side\.js\?v=abc'/);
  assert.match(text, /from '\.\.\/b\.js\?v=abc'/);
  assert.match(text, /import\('\.\/order-view\.js\?v=abc'\)/);
  assert.match(text, /import\( "\.\.\/order-open\.js\?v=abc" \)/);
  assert.match(text, /import\('\.\/done\.js\?v=1'\)/);
  assert.deepEqual(unversionedImports(text), []);
  assert.deepEqual(unversionedImports(src), ['./a.js', './side.js', '../b.js', './order-view.js', '../order-open.js']);
  assert.equal(versionImports(text, '?v=abc').count, 0, 'idempotentti');
});

test('HALL-TILAUS-02: hallinnan lähdekoodin jokainen suhteellinen import versioituu (myös views/orders.js)', () => {
  const orders = readFileSync(join(root, 'booking/admin/views/orders.js'), 'utf8');
  assert.ok(relativeImports(orders).some((x) => x.spec === './order-view.js'));
  assert.deepEqual(unversionedImports(versionImports(orders, '?v=t').text), []);
});
