// booking_161_kb_johku_linkit: tuotekuvausten Johku-linkit → uuden kaupan osoitteet (Joonas 24.10.2026: sivustolla ei Johku-linkkejä).
// Rakennetesti: migraation ja rollbackin upotetut tekstit, md5-vartijat, linkkikohteet ja pgTAP-tyylinen SQL-testi t161.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const MIG = read('supabase/migrations/20261024182650_booking_161_kb_johku_linkit.sql');
const RB = read('supabase/rollbacks/20261024182650_booking_161_ROLLBACK.sql');
const md5 = (s) => createHash('md5').update(s, 'utf8').digest('hex');
const rows = (sql) => [...sql.matchAll(/\((\d+), '(description(?:_en)?)', '([0-9a-f]{32})', '([0-9a-f]{32})',\n\s+\$k161\$([\s\S]*?)\$k161\$,\n\s+\$k161\$([\s\S]*?)\$k161\$\)/g)]
  .map((m) => ({ id: +m[1], col: m[2], fromMd5: m[3], toMd5: m[4], from: m[5], to: m[6] }));
const kb = JSON.parse(readFileSync(join(root, '../content/kb/kb.json'), 'utf8'));
const slugs = new Set(kb.products.map((p) => p.slug));

test('migraatio: 9 kenttää 8 tuotteessa, upotetut tekstit vastaavat md5:iä (tuotanto 24.10.2026), 25 Johku-linkkiä pois', () => {
  const r = rows(MIG);
  assert.equal(r.length, 9);
  assert.deepEqual([...new Set(r.map((x) => x.id))], [1, 2, 3, 4, 7, 25, 26, 38]);
  let n = 0;
  for (const x of r) {
    assert.equal(md5(x.from), x.fromMd5, `${x.id} ${x.col} alkuperäinen`);
    assert.equal(md5(x.to), x.toMd5, `${x.id} ${x.col} uusi`);
    assert.match(MIG, new RegExp(`--\\s+${x.id} ${x.col}\\s+${x.fromMd5} → ${x.toMd5}`));
    n += (x.from.match(/href="https:\/\/sipoonjoenperinnesauna\.johku\.com/g) || []).length;
    assert.doesNotMatch(x.to, /johku/i);
    // vain linkkien href vaihtuu: muu teksti täsmälleen sama
    const strip = (s) => s.replace(/href="[^"]*"/g, 'href=""');
    assert.equal(strip(x.to), strip(x.from), `${x.id} ${x.col}: vain hrefit muuttuvat`);
  }
  assert.equal(n, 25);
});

test('linkkikohteet: kanoninen uusi.saunotus.com, tuotelinkit olemassa olevaan slugiin (FI /varaa/, EN /en/book/), muut sallitulla listalla', () => {
  for (const x of rows(MIG)) {
    const before = new Set([...x.from.matchAll(/href="(https:\/\/uusi\.saunotus\.com[^"]*)"/g)].map((m) => m[1]));
    for (const [, h] of x.to.matchAll(/href="(https:\/\/uusi\.saunotus\.com[^"]*)"/g)) {
      if (before.has(h)) continue;
      const m = /^https:\/\/uusi\.saunotus\.com\/(varaa|en\/book)\/#\/tuote\/([a-z0-9-]+)$/.exec(h);
      if (m) { assert.ok(slugs.has(m[2]), h); assert.equal(m[1] === 'en/book', x.col === 'description_en', `${h}: kieli = kenttä`); continue; }
      assert.ok(['https://uusi.saunotus.com/varaa/#/', 'https://uusi.saunotus.com/varaa/#/?k=yleinen', 'https://uusi.saunotus.com/yritykset/'].includes(h), h);
    }
  }
});

test('vartijat: tarkka tekstivertailu ennen muutoksia, uudelleenajettava, rollback on peilikuva', () => {
  for (const sql of [MIG, RB]) {
    assert.match(sql, /if cur is not distinct from r\.to_text then skip := skip \+ 1; continue; end if;/);
    assert.match(sql, /if cur is distinct from r\.from_text then\s+raise exception/);
    assert.match(sql, /update kb\.products set %I = \$1 where id = \$2 and %I = \$3/);
    assert.match(sql, /if r\.col not in \('description', 'description_en'\)/);
    assert.doesNotMatch(sql, /\bpublic\./);
  }
  const m = rows(MIG), r = rows(RB);
  assert.equal(r.length, m.length);
  for (const x of m) {
    const y = r.find((z) => z.id === x.id && z.col === x.col);
    assert.ok(y);
    assert.equal(y.from, x.to); assert.equal(y.to, x.from);
    assert.equal(y.fromMd5, x.toMd5); assert.equal(y.toMd5, x.fromMd5);
  }
});

test('SQL-testi t161 kattaa vartijan, migraation, uudelleenajon, rollbackin ja sivutekstien synkan', () => {
  const t = read('supabase/tests/kb/t161_kb_johku_linkit.sql');
  for (const l of ['A1', 'A2', 'B1', 'B2', 'C1', 'C2', 'C3', 'C4', 'C5', 'D1', 'E1', 'F1', 'G1', 'H1']) assert.match(t, new RegExp(`'${l}: `), l);
  assert.match(t, /TESTRESULT/);
  assert.ok(read('../.github/workflows/pages.yml').includes('booking/tests/kb-johku-linkit-161.test.mjs'));
});
