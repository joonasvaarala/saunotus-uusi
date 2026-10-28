// Lahjakorttipaketin henkilövalinta (booking_196): vähintään 768 px kortti on kapea.
// Askellin ei saa venyä kortin reunan yli (plus-painike jäi naapurikortin alle). Alle 768 px asettelu ennallaan.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const css = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../shop/src/shop.css'), 'utf8');
const rule = css.match(/@media\(min-width:768px\)\{\s*\.gc-pkgs>\.gc-tile\{min-width:0\}\s*\.gc-persons\{[^}]+\}\s*\.gc-persons \.bk-stepper\{[^}]+\}\s*\.gc-persons \.bk-step\{[^}]+\}\s*\.gc-persons \.bk-stepper input\{[^}]+\}\s*\}/);

test('henkilövalinta rivityy kortin sisään vähintään 768 px:ssä, eikä korttia leikata', () => {
  assert.ok(rule, '768 px:n sääntö puuttuu');
  assert.match(rule[0], /\.gc-persons\{[^}]*flex-wrap:wrap/);
  assert.match(rule[0], /\.gc-persons \.bk-stepper\{[^}]*max-width:100%/);
  assert.match(rule[0], /\.gc-persons \.bk-stepper input\{[^}]*min-width:44px/);
  assert.doesNotMatch(rule[0], /overflow:\s*hidden/);
});

test('kapea näkymä pitää henkilövalinnan yhdellä rivillä', () => {
  const base = css.match(/\.gc-persons\{display:flex;align-items:center;gap:10px;margin:2px 0 0\}/);
  assert.ok(base, 'perusasettelu puuttuu');
  assert.doesNotMatch(base[0], /flex-wrap/);
});
