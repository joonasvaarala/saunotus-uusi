// Kaupan lisäpalvelukortti ei näytä asiakkaalle "enintään N kpl" / "max N" -tekstiä (ylärajan hoitaa vain plus-painikkeen disabled-tila).
// Yläraja tulee edelleen max_per_person-arvosta (addonLimit) – tämä testi vain varmistaa, ettei rajaa näytetä tekstinä.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
const src = join(dirname(fileURLToPath(import.meta.url)), '../shop/src');
const { T } = await import(join(src, 'i18n.js'));

test('i18n: ei addonMax-tekstiä FI/EN-kielissä', () => {
  for (const lang of Object.keys(T)) assert.equal('addonMax' in T[lang], false, `${lang}: addonMax poistettu`);
});
test('shop.js: lisäpalvelukortti ei renderöi enimmäismäärätekstiä, mutta plus-painike disabloituu rajalla', () => {
  const s = readFileSync(join(src, 'shop.js'), 'utf8');
  assert.equal(/addonMax/.test(s), false);
  assert.match(s, /inc\.disabled = qty\.get\(a\.id\) >= lim/);
  assert.match(s, /\(a\.max_per_person \?\? 99\)/);
});
