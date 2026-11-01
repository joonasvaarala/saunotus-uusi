// Selainmoduulit (hallinta, kauppa, juomat, vuoro, jaettu, julkinen js) eivät kaikki ole minkään
// node-testin importteja. node --check jäsentää tiedoston ajamatta sitä, joten puuttuva sulku ei pääse CI:stä.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = join(dirname(fileURLToPath(import.meta.url)), '../..');
const DIRS = [
  'booking/admin',
  'booking/shop/src',
  'booking/drinks',
  'booking/vuoro',
  'booking/shared',
  'public/js',
];

function jsFiles(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) jsFiles(p, out);
    else if (/\.(?:js|mjs)$/.test(name)) out.push(p);
  }
  return out;
}

test('jokainen selainmoduuli jäsentyy (node --check)', () => {
  const files = [];
  for (const rel of DIRS) {
    const abs = join(repo, rel);
    const found = jsFiles(abs);
    assert.ok(found.length > 0, rel);
    files.push(...found);
  }
  assert.ok(files.some((p) => p.endsWith('/booking/admin/views/talous-reports.js')));
  assert.ok(files.some((p) => p.endsWith('/booking/admin/sw.js')));
  assert.ok(files.some((p) => p.endsWith('/booking/shop/src/discount-code-logic.js')));
  const bad = [];
  for (const file of files) {
    const r = spawnSync(process.execPath, ['--check', file], { encoding: 'utf8' });
    if (r.status !== 0) bad.push(`${relative(repo, file)}\n${(r.stderr || r.stdout || '').trim()}`);
  }
  assert.deepEqual(bad, []);
});
