// Yrityksen puhelinnumero: näkyvä muoto kielen mukaan (fi "010 299 2866", en "+358 10 299 2866"), linkki aina tel:+358102992866; kaikki koodi lukee numeron yhdestä vakiosta (booking/shop/src/phone.js).
// node --test booking/tests/puhelin.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const imp = (p) => import(pathToFileURL(join(root, p)).href);
const P = await imp('booking/shop/src/phone.js');

test('vakio: kielikohtainen näkyvä muoto ja tel-linkki', () => {
  assert.equal(P.PHONE_DISPLAY_FI, '010 299 2866');
  assert.equal(P.PHONE_DISPLAY_EN, '+358 10 299 2866');
  assert.equal(P.PHONE_TEL, '+358102992866');
  assert.equal(P.phoneHref(), 'tel:+358102992866');
  assert.equal(P.phoneDisplay('fi'), '010 299 2866'); assert.equal(P.phoneDisplay('en'), '+358 10 299 2866');
  assert.equal(P.phoneDisplay(undefined), '010 299 2866', 'tuntematon kieli → suomalainen muoto');
});

test('sivusto: site.contact.phone/phoneEn/phoneTel tulevat vakiosta (ei site.json:sta)', async () => {
  const j = JSON.parse(readFileSync(join(root, 'content/site.json'), 'utf8'));
  assert.ok(!('phone' in j.contact) && !('phoneEn' in j.contact) && !('phoneTel' in j.contact), 'site.json ei saa sisältää numeroa');
  const { site, phoneDisplay } = await imp('src/lib.mjs');
  assert.equal(site.contact.phone, '010 299 2866'); assert.equal(site.contact.phoneEn, '+358 10 299 2866'); assert.equal(site.contact.phoneTel, '+358102992866');
  assert.equal(phoneDisplay('en'), '+358 10 299 2866');
});

test('sivupohjat: alatunnisteen ja jatkamisosion numero kielen mukaan, linkki aina tel:+358102992866', async () => {
  const R = await imp('src/render.mjs');
  for (const [lang, shown, other] of [['fi', '010 299 2866', '+358 10 299 2866'], ['en', '+358 10 299 2866', '010 299 2866']]) {
    const html = R.gift(lang);
    const links = [...html.matchAll(/<a [^>]*href="tel:([^"]*)"[^>]*>([^<]*)<\/a>/g)].map((m) => [m[1], m[2]]);
    assert.ok(links.length >= 2, `${lang}: tel-linkkejä ${links.length}`);
    for (const [tel, text] of links) { assert.equal(tel, '+358102992866', `${lang}: tel-linkki`); assert.equal(text, shown, `${lang}: näkyvä teksti`); }
    assert.ok(!html.includes(other), `${lang}: ei toisen kielen muotoa`);
  }
});

test('kaupan sanakirjat: fi "010 299 2866", en "+358 10 299 2866" samoilla riveillä', async () => {
  const { T } = await imp('booking/shop/src/i18n.js');
  const leaves = [];
  const walk = (o, path) => { for (const [k, v] of Object.entries(o)) { if (typeof v === 'string') leaves.push([path.concat(k).join('.'), v]); else if (v && typeof v === 'object') walk(v, path.concat(k)); } };
  walk(T.fi, ['fi']); walk(T.en, ['en']);
  const withPhone = leaves.filter(([, v]) => /299 ?2866/.test(v));
  assert.equal(withPhone.length, 10, 'numeron sisältävät rivit (5 fi + 5 en)');
  for (const [k, v] of withPhone) {
    if (k.startsWith('fi.')) assert.ok(v.includes('010 299 2866') && !v.includes('+358'), `${k}: ${v}`);
    else assert.ok(v.includes('+358 10 299 2866') && !v.includes('010 299 2866'), `${k}: ${v}`);
  }
  assert.deepEqual(withPhone.filter(([k]) => k.startsWith('fi.')).map(([k]) => k.slice(3)), withPhone.filter(([k]) => k.startsWith('en.')).map(([k]) => k.slice(3)), 'sama rivijoukko fi/en');
});

test('kauppa: {{var:phone}} täytetään kielen mukaan (build asettaa S.phone = phoneDisplay(lang))', () => {
  const b = readFileSync(join(root, 'booking/shop/build.mjs'), 'utf8');
  assert.equal((b.match(/phone: L\.phoneDisplay\(lang\)/g) || []).length, 5, 'kauppa-, tilaus-, lahjakortti-, yritys- ja maksulinkkisivun S.phone');
  assert.equal((b.match(/\$\{e\(L\.phoneDisplay\(lang\)\)\}/g) || []).length, 3, 'noscript-numerot');
  assert.ok(!/site\.contact\.phone\b/.test(b));
});

// Asiakkaalle näkyvä koodi ei saa kirjoittaa numeroa käsin missään muussa muodossa kuin vakiossa (+358 10 299 2866, 010 299 2866, +358102992866, 0102992866, 010-299-2866 …).
// Tietokantakopiot (content/site-texts.*.json, tests/fixtures/site-texts, kb.json) ovat tietokannan sisältöä, eivät koodia: ne päivitetään tietokannassa (Bottiavustus).
test('lähdekoodissa ei kovakoodattuja numeromuotoja vakion ulkopuolella', () => {
  const SKIP = /(^|\/)(node_modules|\.git|dist|\.cache)(\/|$)|^content\/(site-texts\.|kb\/)|^tests\/fixtures\/|^booking\/shop\/src\/phone\.js$|^booking\/tests\/puhelin\.test\.mjs$|^booking\/supabase\/(migrations|rollbacks)\/|^booking\/docs\/|^docs\/|\.md$|package-lock\.json$|deno\.lock$/;
  const files = execFileSync('git', ['ls-files'], { cwd: root, encoding: 'utf8' }).split('\n').filter((r) => r && !SKIP.test(r) && /\.(m?js|ts|json|html|css|sql|yml)$/.test(r));   // vain versionhallinnassa olevat tiedostot
  const bad = [];
  const isTest = (f) => /(^|\/)(tests?|_tests)\/|\.test\.(m?js|ts)$|^booking\/scripts\/|^booking\/supabase\/functions\/(pdf-golden-cases\.mjs|gift-card-pdf\/test_render\.ts)$/.test(f);
  for (const f of files) {
    if (isTest(f)) continue;
    readFileSync(join(root, f), 'utf8').split('\n').forEach((line, i) => {
      if (/^\s*(\/\/|\*|<!--)/.test(line)) return;   // kommentit
      if (/\+358[ -]*\(?0?\)?[ -]*10[ -]*299|010[ -]?299|0102992866|358102992866/.test(line) && f !== 'booking/supabase/functions/send-emails/templates.ts') bad.push(`${f}:${i + 1} (numero kirjoitettu käsin vakion ulkopuolelle)`);
    });
  }
  assert.deepEqual(bad, []);
});
