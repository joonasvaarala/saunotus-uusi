// Procountor-asetuskortin tekstit: sanakirja ja pending-import täsmäävät, näkymä ei kovakoodaa uusia lauseita.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const texts = await import(pathToFileURL(join(root, 'admin/procountor-texts.js')));
const pending = JSON.parse(readFileSync(join(repo, 'content/site-texts.pending-import-11.json'), 'utf8'));
const settings = readFileSync(join(root, 'admin/views/settings.js'), 'utf8');

test('sanakirjan avaimet ovat pending-importissa molemmilla kielillä', () => {
  for (const lang of ['fi', 'en']) {
    for (const [key, text] of Object.entries(texts.PROCOUNTOR_TEXTS[lang])) {
      const row = pending.find((r) => r.key === key && r.lang === lang);
      assert.ok(row, key + ' ' + lang);
      assert.equal(row.text, text);
      assert.equal(row.class, 'normal');
      assert.deepEqual(row.placeholders, []);
      assert.equal(row.text.includes('http'), false);
    }
  }
  assert.equal(new Set(pending.map((r) => r.key + '|' + r.lang)).size, pending.length);
});

test('asetusnäkymä käyttää tekstifunktiota eikä upota Procountor-lauseita', () => {
  assert.match(settings, /loadProcountorTexts/);
  assert.match(settings, /procountorText/);
  assert.match(settings, /data-testid": "procountor-status"|'data-testid': 'procountor-status'/);
  assert.equal(settings.includes('Harjoitusajo'), false);
  assert.equal(settings.includes('Tilit puuttuvat'), false);
});
