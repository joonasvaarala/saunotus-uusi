// Sivutekstitiedostoissa ei saa olla alustan suodattimen jättämää paikkamerkkiä (13.11.2026: fallbackissa kaksi FI-tekstiä,
// joissa sana oli korvautunut paikkamerkillä synkronoinnissa). Merkkijono kootaan osista, jotta tämä tiedosto ei itse osu hakuun.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const MARK = '[' + 'REDA' + 'CTED' + ']';
const files = ['site-texts.fallback.json', ...readdirSync(join(root, 'content')).filter((f) => /^site-texts\.pending-import-\d+\.json$/.test(f))];

test('sivutekstit: fallback ja pending-import-tiedostot eivät sisällä suodattimen paikkamerkkiä', () => {
  assert.ok(files.length > 1);
  const hits = files.flatMap((f) => {
    const s = readFileSync(join(root, 'content', f), 'utf8');
    return s.includes(MARK) ? [`${f}: ${s.split(MARK).length - 1}`] : [];
  });
  assert.deepEqual(hits, []);
});

test('sivutekstit: koulutusnäkymän FI-tekstit fallbackissa ovat kokonaiset (versio 2)', () => {
  const W = 'koul' + 'utus';
  const fb = JSON.parse(readFileSync(join(root, 'content', 'site-texts.fallback.json'), 'utf8'));
  for (const key of ['admin.training.copy_hint', 'admin.training.hidden']) {
    const row = fb.texts.find((t) => t.key === key && t.lang === 'fi');
    assert.ok(row && row.text.includes(W), key);
    assert.equal(row.version, 2, key);
  }
});
