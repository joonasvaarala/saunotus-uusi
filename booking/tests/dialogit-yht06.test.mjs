// YHT-06: hallinnassa ei selaimen confirm()-ikkunoita; dialogin otsikko-id uniikki; Esc/rasti kysyy tallentamattomista muutoksista;
// reitinvaihto sulkee auki jääneet dialogit.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (p) => readFileSync(join(root, p), 'utf8');

test('hallinta: ei window.confirm()-kutsuja näkymissä', () => {
  const files = ['booking/admin', 'booking/admin/views'].flatMap((d) => readdirSync(join(root, d)).filter((f) => f.endsWith('.js')).map((f) => `${d}/${f}`));
  const bad = files.filter((f) => /(^|[^.\w])confirm\(/m.test(read(f).replace(/async confirm\(/g, '')));
  assert.deepEqual(bad, []);
  assert.match(read('booking/admin/confirm.js'), /export const confirmAsk = /);
});

test('dialog(): uniikki aria-labelledby, Esc/rasti suojaa muutokset, reitinvaihto sulkee', () => {
  const ui = read('booking/admin/ui.js');
  assert.doesNotMatch(ui, /id: 'dlg-title'/);
  assert.match(ui, /const tid = `dlg-title-\$\{\+\+dlgSeq\}`/);
  assert.match(ui, /'aria-labelledby': tid/);
  assert.match(ui, /addEventListener\('cancel', \(e\) => \{ if \(dirty\) \{ e\.preventDefault\(\); ask\(\); \} \}\)/);
  assert.match(ui, /'data-testid': 'dlg-discard'/);
  assert.match(ui, /export const closeDialogs = /);
  assert.match(read('booking/admin/admin.js'), /if \(r\.path !== lastPath\) closeDialogs\(\);/);
  assert.match(read('booking/admin/admin.css'), /\.dlg-unsaved\[hidden\]\{display:none\}/);
});
