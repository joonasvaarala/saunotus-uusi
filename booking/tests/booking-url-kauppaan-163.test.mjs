// booking_163_booking_url_kauppaan: kb.products.booking_url (Johku) → uuden kaupan tuotesivu (Joonas 24.10.2026: ei Johku-linkkejä).
// Rakennetesti: vartijat ja md5:t, kohteet = /varaa/#/tuote/<oma slug>, rollback peilikuvana, kb.json-snapshot ja sivuston EN-muunnos.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { shopTarget } from '../shop/src/johku-links.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const MIG = read('supabase/migrations/20261024185115_booking_163_booking_url_kauppaan.sql');
const RB = read('supabase/rollbacks/20261024185115_booking_163_ROLLBACK.sql');
const T = read('supabase/tests/kb/t163_booking_url_kauppaan.sql');
const md5 = (s) => createHash('md5').update(s, 'utf8').digest('hex');
const rows = (sql) => [...sql.matchAll(/^\s+\((\d+), '([a-z0-9-]+)', '([^']+)', '([^']+)', '([0-9a-f]{32})', '([0-9a-f]{32})'\)/gm)]
  .map((m) => ({ id: +m[1], slug: m[2], from: m[3], to: m[4], fromMd5: m[5], toMd5: m[6] }));
const kb = JSON.parse(readFileSync(join(root, '../content/kb/kb.json'), 'utf8'));
const IDS = [1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 25, 26, 43, 48, 49];
const JOHKU = 'https://sipoonjoenperinnesauna.johku.com/fi_FI/';

test('migraatio: 16 tuotetta, Johku → /varaa/#/tuote/<oma slug> (vuosikortti #/vuosikortti), md5:t täsmäävät', () => {
  const r = rows(MIG);
  assert.deepEqual(r.map((x) => x.id), IDS);
  for (const x of r) {
    assert.equal(md5(x.from), x.fromMd5, `${x.id} alkuperäinen`);
    assert.equal(md5(x.to), x.toMd5, `${x.id} uusi`);
    assert.ok(x.from.startsWith(JOHKU), `${x.id} alkuperäinen on Johku-osoite`);
    assert.ok(x.from.endsWith('/' + x.slug), `${x.id} Johku-polku päättyy slugiin`);
    assert.equal(x.to, 'https://saunotus.fi/varaa/#/' + (x.slug === 'vuosikortti' ? 'vuosikortti' : 'tuote/' + x.slug));
    assert.match(MIG, new RegExp(`--\\s+${x.id} ${x.fromMd5} → ${x.toMd5}`));
  }
});

test('vartijat: slug + tarkka arvo ennen muutoksia, uudelleenajettava, row_count, ei muita sarakkeita', () => {
  for (const sql of [MIG, RB]) {
    assert.match(sql, /cur_slug is distinct from r\.slug then\s+raise exception/);
    assert.match(sql, /if cur is not distinct from r\.to_url then skip := skip \+ 1; continue; end if;/);
    assert.match(sql, /if cur is distinct from r\.from_url then\s+raise exception/);
    assert.match(sql, /update kb\.products set booking_url = tos\[k\] where id = ids\[k\] and booking_url = froms\[k\];/);
    assert.match(sql, /get diagnostics rc = row_count;\s+if rc <> 1 then raise exception/);
    assert.equal((sql.match(/\bupdate\b/gi) || []).length, 1);
    assert.doesNotMatch(sql, /\bpublic\./);
    assert.doesNotMatch(sql, /set\s+(price|vat|slug)\b/i);
  }
  assert.match(MIG, /Tuotannon versio 20261024185115/);
});

test('rollback on migraation peilikuva', () => {
  const m = rows(MIG), r = rows(RB);
  assert.equal(r.length, m.length);
  m.forEach((x, i) => assert.deepEqual(r[i], { id: x.id, slug: x.slug, from: x.to, to: x.from, fromMd5: x.toMd5, toMd5: x.fromMd5 }));
});

test('kb.json-snapshot vastaa ajon jälkeistä tilaa; tuotteet olemassa ja muut ennallaan', () => {
  const m = new Map(rows(MIG).map((x) => [x.id, x]));
  for (const id of IDS) {
    const p = kb.products.find((x) => x.id === id);
    assert.ok(p, `kb.json tuote ${id}`);
    assert.equal(p.slug, m.get(id).slug);
    assert.equal(p.booking_url, m.get(id).to);
  }
  const p47 = kb.products.find((x) => x.id === 47);
  if (p47) assert.ok(p47.booking_url.startsWith(JOHKU), '47 ei kaupan tuote: ennallaan');
});

test('sivusto: kanoninen kauppaosoite → EN /en/book/, build ohjaa BASE-polkuun', async () => {
  const L = await import('../../src/lib.mjs');
  const u = 'https://saunotus.fi/varaa/#/tuote/naistensauna';
  assert.equal(L.bookingUrl(u, 'fi'), u);
  assert.equal(L.bookingUrl(u, 'en'), 'https://saunotus.fi/en/book/#/tuote/naistensauna');
  assert.equal(L.bookingUrl('https://saunotus.fi/varaa/#/vuosikortti', 'en'), 'https://saunotus.fi/en/book/#/vuosikortti');
  assert.equal(L.bookingUrl(JOHKU + 'hoidot/x', 'en'), 'https://sipoonjoenperinnesauna.johku.com/en_US/hoidot/x');
  assert.equal(shopTarget('https://saunotus.fi/en/book/#/tuote/naistensauna', { shop: '/b/en/book/', base: '/b' }), '/b/en/book/#/tuote/naistensauna');
});

test('SQL-testi t163 kattaa vartijat, synkan, rollbackin ja uudelleenajon', () => {
  for (const l of ['A1', 'B1', 'B2', 'C1', 'C2', 'C3', 'C4', 'C5', 'D1', 'E1', 'F1', 'G1', 'H1']) assert.match(T, new RegExp(`'${l}: `));
  assert.match(T, /TESTRESULT pass=% fail=%/);
});

test('pending-import-60: faq.4.answer EN ilman Johkua, ei <', () => {
  const pi = JSON.parse(readFileSync(join(root, '../content/site-texts.pending-import-60.json'), 'utf8'));
  assert.equal(pi.length, 1);
  assert.equal(pi[0].key, 'faq.4.answer');
  assert.equal(pi[0].lang, 'en');
  assert.doesNotMatch(pi[0].text, /johku|</i);
  assert.match(pi[0].text, /online shop \(Book page\)/);
  assert.ok(pi[0].text.length <= pi[0].max_len);
});
