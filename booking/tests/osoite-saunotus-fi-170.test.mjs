// booking_170 / Joonas 24.10.2026: uusi sivusto on saunotus.fi; vanha kehitysosoite ei saa esiintyä repossa
// (poikkeukset: booking_170-migraatio ja sen rollback, jotka korvaavat osoitteen tietokannassa, sekä siirron ajokirja, jossa sen poisto on vaihe C).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const OLD = ['uusi', 'saunotus', 'com'].join('.');
const MIG = 'booking/supabase/migrations/20261024194500_booking_170_osoite_saunotus_fi.sql';
const RB = 'booking/supabase/rollbacks/20261024194500_booking_170_ROLLBACK.sql';
const SELF = 'booking/tests/osoite-saunotus-fi-170.test.mjs', RUNBOOK = 'docs/siirto-saunotus-fi.md';

test('repossa ei viittauksia vanhaan kehitysosoitteeseen (paitsi booking_170)', () => {
  const files = execFileSync('git', ['ls-files'], { cwd: root, encoding: 'utf8' }).split('\n').filter(Boolean);
  const hits = files.filter((f) => ![MIG, RB, SELF, RUNBOOK].includes(f) && !/\.(png|jpe?g|webp|avif|gif|ico|woff2?|pdf)$/i.test(f))
    .filter((f) => { try { return readFileSync(join(root, f), 'utf8').includes(OLD); } catch { return false; } });
  assert.deepEqual(hits, []);
});

test('booking_170: vartija, uudelleenajettava, sama kenttälista rollbackissa, ei historiatauluja', () => {
  const m = readFileSync(join(root, MIG), 'utf8'), r = readFileSync(join(root, RB), 'utf8');
  const rows = (s) => [...s.matchAll(/\((\d+), '(\w+)', (\d+), '([0-9a-f]{32})', '([0-9a-f]{32})'\)/g)].map((x) => x.slice(1).join('|'));
  assert.equal(new Set(rows(m)).size, 11);
  assert.deepEqual([...new Set(rows(r))], [...new Set(rows(m))]);
  assert.equal(rows(m).reduce((a, x) => a + +x.split('|')[2], 0) / 2, 31);
  assert.match(m, /new_base constant text := 'https:\/\/saunotus\.fi'/);
  assert.match(m, /raise exception 'booking_170: tuote % % on muuttunut/);
  assert.match(m, /jäi % riviä vanhalla osoitteella/);
  for (const t of ['change_log', 'audit_log', 'site_text_versions', 'site_texts']) assert.ok(!m.toLowerCase().includes('update booking.' + t) && !m.toLowerCase().includes('update kb.' + t), t);
  assert.ok(!/\b(delete|drop|truncate|alter|grant)\b/i.test(m.replace(/--.*$/gm, '')));
});

test('kanoninen osoite: kauppa ja sivusto käyttävät https://saunotus.fi', async () => {
  const JL = await import(join(root, 'booking/shop/src/johku-links.js'));
  assert.equal(JL.CANONICAL, 'https://saunotus.fi');
  const site = JSON.parse(readFileSync(join(root, 'content/site.json'), 'utf8'));
  assert.equal(site.canonicalBase, 'https://saunotus.fi');
  assert.equal(JL.shopTarget('https://saunotus.fi/varaa/#/tuote/naistensauna', { shop: '/varaa/', base: '/saunotus-uusi' }), '/saunotus-uusi/varaa/#/tuote/naistensauna');
  assert.equal(JL.shopTarget('https://saunotus.fi.evil.example/varaa/', { shop: '/varaa/', base: '' }), null);
});
