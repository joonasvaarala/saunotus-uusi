// Yrityksen puhelinnumero: näkyvä muoto aina "010 299 2866", linkki aina tel:+358102992866; kaikki koodi lukee numeron yhdestä vakiosta (booking/shop/src/phone.js).
// node --test booking/tests/puhelin.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const imp = (p) => import(pathToFileURL(join(root, p)).href);
const P = await imp('booking/shop/src/phone.js');

test('vakio: näkyvä muoto ja tel-linkki', () => {
  assert.equal(P.PHONE_DISPLAY, '010 299 2866');
  assert.equal(P.PHONE_TEL, '+358102992866');
  assert.equal(P.phoneHref(), 'tel:+358102992866');
});

test('sivusto: site.contact.phone/phoneTel tulevat vakiosta (ei site.json:sta)', async () => {
  const j = JSON.parse(readFileSync(join(root, 'content/site.json'), 'utf8'));
  assert.ok(!('phone' in j.contact) && !('phoneTel' in j.contact), 'site.json ei saa sisältää numeroa');
  const { site } = await imp('src/lib.mjs');
  assert.equal(site.contact.phone, '010 299 2866'); assert.equal(site.contact.phoneTel, '+358102992866');
});

test('kaupan sanakirjat: numero näkyy molemmilla kielillä muodossa "010 299 2866" (ei +358 10 299 2866)', async () => {
  const { T } = await imp('booking/shop/src/i18n.js');
  const leaves = [];
  const walk = (o, path) => { for (const [k, v] of Object.entries(o)) { if (typeof v === 'string') leaves.push([path.concat(k).join('.'), v]); else if (v && typeof v === 'object') walk(v, path.concat(k)); } };
  walk(T.fi, ['fi']); walk(T.en, ['en']);
  const withPhone = leaves.filter(([, v]) => /299 ?2866/.test(v));
  assert.equal(withPhone.length, 10, 'numeron sisältävät rivit (5 fi + 5 en)');
  for (const [k, v] of withPhone) assert.ok(v.includes('010 299 2866') && !/\+358/.test(v), `${k}: ${v}`);
  assert.deepEqual(withPhone.filter(([k]) => k.startsWith('fi.')).map(([k]) => k.slice(3)), withPhone.filter(([k]) => k.startsWith('en.')).map(([k]) => k.slice(3)), 'sama rivijoukko fi/en');
});

// Asiakkaalle näkyvä koodi ei saa kirjoittaa numeroa käsin missään muussa muodossa kuin vakiossa (+358 10 299 2866, +358102992866, 0102992866, 010-299-2866 …).
// Tietokantakopiot (content/site-texts.*.json, tests/fixtures/site-texts, kb.json) ovat tietokannan sisältöä, eivät koodia: ne päivitetään tietokannassa (Bottiavustus).
test('lähdekoodissa ei kovakoodattuja numeromuotoja vakion ulkopuolella', () => {
  const SKIP = /(^|\/)(node_modules|\.git|dist|\.cache)(\/|$)|^content\/(site-texts\.|kb\/)|^tests\/fixtures\/|^booking\/shop\/src\/phone\.js$|^booking\/tests\/puhelin\.test\.mjs$|^booking\/supabase\/(migrations|rollbacks)\/|^booking\/docs\/|^docs\/|\.md$|package-lock\.json$|deno\.lock$/;
  const files = [];
  const walk = (d) => { for (const n of readdirSync(join(root, d))) { const r = d ? `${d}/${n}` : n; if (SKIP.test(r)) continue; const st = statSync(join(root, r)); if (st.isDirectory()) walk(r); else if (/\.(m?js|ts|json|html|css|sql|yml)$/.test(n)) files.push(r); } };
  walk('');
  const bad = [];
  const isTest = (f) => /(^|\/)(tests?|_tests)\/|\.test\.(m?js|ts)$|^booking\/scripts\/|^booking\/supabase\/functions\/(pdf-golden-cases\.mjs|gift-card-pdf\/test_render\.ts)$/.test(f);
  for (const f of files) {
    if (isTest(f)) continue;
    readFileSync(join(root, f), 'utf8').split('\n').forEach((line, i) => {
      if (/^\s*(\/\/|\*|<!--)/.test(line)) return;   // kommentit
      if (/\+358[ -]+10[ -]?299|\+358 ?\(0\)|tel:0|(?<![+\d])0102992866|010[ -]?2992866|010-299/.test(line)) bad.push(`${f}:${i + 1} (vanha numeromuoto)`);
      if (/010 299 2866|358102992866/.test(line) && f !== 'booking/supabase/functions/send-emails/templates.ts') bad.push(`${f}:${i + 1} (numero kirjoitettu käsin vakion ulkopuolelle)`);
    });
  }
  assert.deepEqual(bad, []);
});
