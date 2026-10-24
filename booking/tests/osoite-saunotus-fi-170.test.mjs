// booking_170 / Joonas 24.10.2026: uusi sivusto on saunotus.fi; vanha kehitysosoite ei saa esiintyä repossa. Poikkeukset (ALLOW):
// - booking_170-migraatio, sen rollback ja SQL-testi t170, jotka korvaavat osoitteen tietokannassa, sekä siirron ajokirja (poisto on vaihe C);
// - jo ajetut migraatiot booking_161 ja booking_163, niiden rollbackit ja testit: ajetut migraatiot ovat muuttumatonta historiaa
//   (ne kirjoittivat vanhan osoitteen tuotantoon; booking_170 korjaa tiedot, booking_163 on tuotannossa peruttu);
// - content/kb/kb.json: tuotannon tilannekuva (scripts/kb-snapshot.mjs), päivittyy booking_170:n ajon jälkeen seuraavassa tilannekuvassa;
// - booking/shop/src/johku-links.js (LEGACY_CANONICAL) ja src/lib.mjs (SHOP_CANON): tunnistavat vanhan osoitteen ja ohjaavat sen sivuston
//   omaan BASE-polkuun (tiedot ennen booking_170:tä tai sen rollbackin jälkeen), jotta sivustolle ei päädy linkkiä vanhalle kehityssivulle;
// - send-emails/golden-cases.mjs: sähköpostien kultaisten tiivisteiden (golden-email.json) syöte, otettu ennen siirtoa; ei muuteta.
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
const T170 = 'booking/supabase/tests/kb/t170_osoite_saunotus_fi.sql';
// ajetut migraatiot ovat muuttumatonta historiaa: booking_161/163 ja niiden rollbackit/testit pysyvät sellaisinaan (ei muokata tätä PR:ää varten)
const APPLIED = [
  'booking/supabase/migrations/20261024182650_booking_161_kb_johku_linkit.sql',
  'booking/supabase/rollbacks/20261024182650_booking_161_ROLLBACK.sql',
  'booking/supabase/tests/kb/t161_kb_johku_linkit.sql',
  'booking/tests/kb-johku-linkit-161.test.mjs',
  'booking/supabase/migrations/20261024185115_booking_163_booking_url_kauppaan.sql',
  'booking/supabase/rollbacks/20261024185115_booking_163_ROLLBACK.sql',
  'booking/supabase/tests/kb/t163_booking_url_kauppaan.sql',
  'booking/tests/booking-url-kauppaan-163.test.mjs',
];
const SNAPSHOT = 'content/kb/kb.json', LEGACY = ['booking/shop/src/johku-links.js', 'src/lib.mjs'];
// sähköpostien kultaiset tapaukset: syöte, jolla golden-email.json:n sha256-tiivisteet otettiin ennen tekstien siirtoa; osoitteen muutos rikkoisi vertailun
const GOLDEN = 'booking/supabase/functions/send-emails/golden-cases.mjs';
const ALLOW = [MIG, RB, T170, SELF, RUNBOOK, ...APPLIED, SNAPSHOT, ...LEGACY, GOLDEN];

test('repossa ei viittauksia vanhaan kehitysosoitteeseen (paitsi sallitut poikkeukset)', () => {
  const files = execFileSync('git', ['ls-files'], { cwd: root, encoding: 'utf8' }).split('\n').filter(Boolean);
  const hits = files.filter((f) => !ALLOW.includes(f) && !/\.(png|jpe?g|webp|avif|gif|ico|woff2?|pdf)$/i.test(f))
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
  for (const t of ['change_log', 'audit_log', 'site_text_versions']) assert.ok(!m.toLowerCase().includes('update booking.' + t) && !m.toLowerCase().includes('update kb.' + t), t);
  for (const s of [m, r]) {
    // site_texts: vain needs_translation-lipun palautus talteen otettuun arvoon (ei tekstejä, versioita tai tilaa)
    const st = [...s.matchAll(/update booking\.site_texts set ([^;]*);/gi)].map((x) => x[1]);
    assert.deepEqual(st, ["needs_translation = (nt_before ->> t.id::text)::boolean where id = t.id"]);
    assert.ok(!/\b(delete|drop|truncate|alter|grant|insert)\b/i.test(s.replace(/--.*$/gm, '')));
  }
});

test('booking_170: needs_translation palautetaan ennalleen (migraatio ja rollback), vartijat', () => {
  const m = readFileSync(join(root, MIG), 'utf8'), r = readFileSync(join(root, RB), 'utf8');
  for (const s of [m, r]) {
    assert.match(s, /select coalesce\(jsonb_object_agg\(x\.id::text, x\.needs_translation\), '\{\}'\) into nt_before/);
    assert.match(s, /st\.key = 'product\.' \|\| st\.source_pk \|\| '\.description' and st\.lang in \('fi', 'en'\)\s+for update/);
    assert.match(s, /st\.source_pk = any\(select p::text from unnest\(pids\) p\)/);
    assert.match(s, /needs_translation muuttui, mutta kumpaakaan kieliversiota ei/);
    assert.match(s, /julkaistu teksti ei ole/);
    // talteenotto ennen päivitystä, palautus sen jälkeen
    const snap = s.indexOf('into nt_before'), upd = s.indexOf('update kb.products set'), back = s.indexOf('set needs_translation = (nt_before');
    assert.ok(snap > 0 && snap < upd && upd < back, 'järjestys: talteen → päivitys → palautus');
  }
  const t = readFileSync(join(root, T170), 'utf8');
  for (const l of ['A1', 'A4', 'B1', 'C1', 'C3', 'C5', 'D1', 'E1', 'E3', 'F1', 'G1', 'H1', 'I2']) assert.match(t, new RegExp(`'${l}: `));
  assert.match(t, /TESTRESULT pass=% fail=%/);
  assert.match(t, /\\ir \.\.\/\.\.\/migrations\/20261024194500_booking_170_osoite_saunotus_fi\.sql/);
  assert.match(t, /\\ir \.\.\/\.\.\/rollbacks\/20261024194500_booking_170_ROLLBACK\.sql/);
});

test('ajetut migraatiot booking_161/163 ennallaan: kirjoittavat yhä vanhan osoitteen (historia), booking_170 korjaa', () => {
  for (const f of APPLIED.filter((f) => f.includes('/migrations/'))) assert.ok(readFileSync(join(root, f), 'utf8').includes(OLD), f);
});

test('kanoninen osoite: kauppa ja sivusto käyttävät https://saunotus.fi', async () => {
  const JL = await import(join(root, 'booking/shop/src/johku-links.js'));
  assert.equal(JL.CANONICAL, 'https://saunotus.fi');
  const site = JSON.parse(readFileSync(join(root, 'content/site.json'), 'utf8'));
  assert.equal(site.canonicalBase, 'https://saunotus.fi');
  assert.equal(JL.shopTarget('https://saunotus.fi/varaa/#/tuote/naistensauna', { shop: '/varaa/', base: '/saunotus-uusi' }), '/saunotus-uusi/varaa/#/tuote/naistensauna');
  assert.equal(JL.shopTarget('https://saunotus.fi.evil.example/varaa/', { shop: '/varaa/', base: '' }), null);
});

test('vanha kehitysosoite (tiedot ennen booking_170:tä / rollbackin jälkeen) ohjautuu sivuston omaan polkuun, ei vanhalle sivulle', async () => {
  const JL = await import(join(root, 'booking/shop/src/johku-links.js'));
  const L = await import(join(root, 'src/lib.mjs'));
  const old = 'https://' + OLD;
  assert.equal(JL.LEGACY_CANONICAL, old);
  const FI = { shop: '/saunotus-uusi/varaa/', base: '/saunotus-uusi' };
  assert.equal(JL.shopTarget(old + '/varaa/#/tuote/jalkiloylyt', FI), '/saunotus-uusi/varaa/#/tuote/jalkiloylyt');
  assert.equal(JL.shopTarget(old + '/en/book/#/?k=yleinen', { shop: '/en/book/', base: '' }), '/en/book/#/?k=yleinen');
  assert.equal(JL.shopTarget(old, FI), '/saunotus-uusi/');
  assert.equal(JL.shopTarget(old + '.evil.example/varaa/', FI), null);
  assert.equal(JL.shopTarget(old + '/varaa/', { ...FI, base: undefined }), null);
  const html = `<p><a href="${old}/yritykset/">B</a> <a href="https://saunotus.fi/varaa/#/">S</a></p>`;
  const out = JL.rewriteHtml(html, FI);
  assert.ok(!out.includes(OLD), out);
  assert.ok(out.includes('href="/saunotus-uusi/yritykset/"') && out.includes('href="/saunotus-uusi/varaa/#/"'), out);
  assert.equal(L.bookingUrl(old + '/varaa/#/tuote/naistensauna', 'en'), old + '/en/book/#/tuote/naistensauna');
  assert.equal(L.bookingUrl('https://saunotus.fi/varaa/#/vuosikortti', 'en'), 'https://saunotus.fi/en/book/#/vuosikortti');
  // kb.json-tilannekuvan kuvaukset (tuotanto ennen booking_170:tä): build ohjaa kaikki vanhat osoitteet BASE-polkuun
  const kb = JSON.parse(readFileSync(join(root, SNAPSHOT), 'utf8'));
  for (const p of kb.products) for (const c of ['description', 'description_en']) {
    if (!p[c]) continue;
    assert.ok(!JL.rewriteHtml(p[c], FI).includes(OLD), `${p.id} ${c}`);
  }
});
