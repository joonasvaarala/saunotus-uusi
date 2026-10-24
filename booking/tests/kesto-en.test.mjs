// booking_147: tuotteen kesto englanniksi kauppaan. public_catalog() / admin_list_products() palauttavat 'duration_text_en'
// (kb.products.duration_text_en, Bottiavustuksen tuotantomigraatio kb_products_duration_text_en 24.10.2026). Kauppa näyttää EN-sivulla
// duration_text_en, jos se on täytetty, muuten suomenkielisen duration_text (sama malli kuin pname/pdesc). Hallinta jää suomeksi.
// Ei verkkoa eikä tietokantaa. SQL-käytös: booking/supabase/tests/kesto/t147_catalog_duration_text_en.sql + r147_rollback_check.sql (paikallinen PG17).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync, cpSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(root, '..');
const read = (rel) => readFileSync(join(repo, rel), 'utf8');
const MIG = 'booking/supabase/migrations/20261024230000_booking_147_catalog_duration_text_en.sql';
const RB = 'booking/supabase/rollbacks/20261024230000_booking_147_ROLLBACK.sql';
const M64 = 'booking/supabase/migrations/20261018112116_booking_64_catalog_texts_admin.sql';
const M06 = 'booking/supabase/migrations/20261016150006_booking_06_admin_api.sql';
const fnNames = (sql) => [...sql.matchAll(/create or replace function\s+booking\.(\w+)/gi)].map((m) => m[1]).sort();
// funktion runko ($$ … $$ tai $function$ … $function$), välilyönnit normalisoitu
const body = (sql, fn) => {
  const i = sql.search(new RegExp(`create or replace function\\s+booking\\.${fn}\\(\\)`, 'i'));
  assert.ok(i >= 0, `${fn} löytyy`);
  const m = /(\$(?:function)?\$)([\s\S]*?)\1/.exec(sql.slice(i));
  return m[2].replace(/\s+/g, ' ').trim();
};
const ADD = /,\s*'duration_text_en',\s*p\.duration_text_en/;
// treatments.js tuo ./sb.js:n (kopioidaan buildissa booking/shared:sta) → väliaikainen kopio kuten sivutekstit.test.mjs
const tmp = join(mkdtempSync(join(tmpdir(), 'kesto-en-')), 'shop');
cpSync(join(root, 'shop/src'), tmp, { recursive: true });
cpSync(join(root, 'shared/sb.js'), join(tmp, 'sb.js'));
const { splitCatalog } = await import(pathToFileURL(join(tmp, 'treatments.js')));

test('migraatio: vain public_catalog ja admin_list_products, lisäys = duration_text_en, muuten booking_64/06 sellaisenaan', () => {
  assert.deepEqual(readdirSync(join(repo, 'booking/supabase/migrations')).filter((n) => /booking_147_/.test(n)), ['20261024230000_booking_147_catalog_duration_text_en.sql']);
  const sql = read(MIG);
  assert.deepEqual(fnNames(sql), ['admin_list_products', 'public_catalog']);
  assert.doesNotMatch(sql, /\bpublic\.\w+/i, 'ei public-skeemaa');
  assert.doesNotMatch(sql, /\b(alter table|insert into|update\s+kb\.|delete from|drop )/i, 'ei skeema- eikä datamuutoksia');
  assert.match(sql, /kb\.products\.duration_text_en puuttuu/, 'puuttuva sarake → selkeä virhe');
  for (const [fn, base] of [['public_catalog', M64], ['admin_list_products', M06]]) {
    const b = body(sql, fn);
    assert.match(b, ADD, `${fn}: 'duration_text_en', p.duration_text_en`);
    assert.equal(b.replace(ADD, ''), body(read(base), fn), `${fn}: ei muita muutoksia (hinnat, ALV, rivijoukko, järjestys)`);
  }
  assert.equal((sql.match(/security definer set search_path = ''/gi) || []).length, 2, 'security definer + tyhjä search_path molemmissa');
  assert.match(sql, /language sql stable security definer/i);
  assert.match(sql, /language plpgsql stable security definer/i);
  assert.match(body(sql, 'admin_list_products'), /perform booking\._require_staff\(\)/, 'hallinnan oikeustarkistus ennallaan');
  assert.doesNotMatch(sql, /\b(grant|revoke)\b/i, 'CREATE OR REPLACE säilyttää oikeudet; ei uusia grantteja');
});

test('rollback: palauttaa booking_64/06-määritelmät täsmälleen, ei koske kb-sarakkeeseen', () => {
  const rb = read(RB);
  assert.deepEqual(fnNames(rb), ['admin_list_products', 'public_catalog']);
  assert.doesNotMatch(rb.replace(/^--.*$/gm, ''), /duration_text_en/);
  assert.equal(body(rb, 'public_catalog'), body(read(M64), 'public_catalog'));
  assert.equal(body(rb, 'admin_list_products'), body(read(M06), 'admin_list_products'));
  assert.doesNotMatch(rb, /\b(alter table|drop |delete from)/i);
  assert.match(rb, /0cd7d46e6d9bb24499e1b2ab6e334587/);
});

test('SQL-testit ja kb-mock: sarake on mockissa (tuotanto), t147 + paluun tarkistus olemassa', () => {
  assert.match(read('booking/supabase/tests/fixtures/kb_mock.sql'), /alter table kb\.products add column if not exists duration_text_en text/);
  for (const f of ['pre147.sql', 't147_catalog_duration_text_en.sql', 'r147_rollback_check.sql']) assert.ok(existsSync(join(repo, 'booking/supabase/tests/kesto', f)), f);
});

test('treatments.splitCatalog: duration_text_en katalogista; puuttuva/tyhjä ei ylikirjoita', () => {
  const st = new Map([[10, { id: 10, slug: 'saunahoito-2', duration_text: 'noin 1 h', duration_text_en: 'about 1 h (static)' }]]);
  const row = { id: 10, slug: 'saunahoito-2', name: 'Saunahoito', booking_kind: 'slots', duration_text: 'noin 1 h', duration_text_en: 'approx. 1 h' };
  assert.equal(splitCatalog([row], st).treatments[0].duration_text_en, 'approx. 1 h');
  assert.equal(splitCatalog([{ ...row, duration_text_en: null }], st).treatments[0].duration_text_en, 'about 1 h (static)', 'null → staattinen kb-data');
  assert.equal(splitCatalog([{ ...row, duration_text_en: '' }], new Map()).treatments[0].duration_text_en, undefined);
  assert.equal(splitCatalog([{ ...row, duration_text_en: null }], new Map()).treatments[0].duration_text, 'noin 1 h');
});

test('kauppa: EN-sivu näyttää duration_text_en, puuttuessa duration_text; FI aina duration_text', () => {
  const shop = read('booking/shop/src/shop.js');
  const line = /const pdur = \(p\) => .*;/.exec(shop)?.[0];
  assert.ok(line, 'shop.js: pdur-apuri');
  assert.equal(line, "const pdur = (p) => (S.lang === 'en' && p.duration_text_en) || p.duration_text;", 'sama malli kuin pname/pdesc');
  const pdur = (S) => new Function('S', `${line} return pdur;`)(S);
  const p = { duration_text: 'noin 1 h', duration_text_en: 'approx. 1 h' };
  assert.equal(pdur({ lang: 'en' })(p), 'approx. 1 h');
  assert.equal(pdur({ lang: 'fi' })(p), 'noin 1 h');
  assert.equal(pdur({ lang: 'en' })({ duration_text: 'noin 1 h', duration_text_en: null }), 'noin 1 h');
  assert.equal(pdur({ lang: 'en' })({ duration_text: 'noin 1 h', duration_text_en: '' }), 'noin 1 h');
  assert.equal((shop.match(/pdur\(p\) \? ` · \$\{pdur\(p\)\}` : ''/g) || []).length, 2, 'listakortti + tuotesivu');
  assert.doesNotMatch(shop, /p\.duration_text \?/, 'ei suoraa duration_text-näyttöä');
  const tui = read('booking/shop/src/treatment-ui.js');
  assert.match(tui, /const durText = \(p\) => \(A\.isPackage\(p\) \? fmtMin\(totalMin\(p\)\) : \(S\.lang === 'en' && p\.duration_text_en\) \|\| p\.duration_text \|\| ''\);/);
});

test('build: static-products.json saa duration_text_en (STATIC_KEYS) ja kb-snapshot sallii kentän', () => {
  const keys = JSON.parse(/const STATIC_KEYS = (\[[^\]]*\]);/.exec(read('booking/shop/build.mjs'))[1].replace(/'/g, '"'));
  assert.ok(keys.includes('duration_text_en') && keys.includes('duration_text'));
  assert.ok(!keys.some((k) => /url|vat/.test(k)), 'ei URL- eikä ALV-kenttiä');
  assert.match(read('scripts/kb-snapshot.mjs'), /'duration_text','duration_text_en'/);
});

test('CI: kesto-en.test.mjs ajetaan pages.yml:ssä', () => {
  assert.match(read('.github/workflows/pages.yml'), /node --test booking\/tests\/kesto-en\.test\.mjs/);
});
