// Hallinnan Kopioi linkki: julkinen ilmoittautumis- ja maksulinkki nykyisestä pohjaosoitteesta.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { publicShopLink } from '../admin/events-logic.js';
import { COURSE_TEXTS } from '../admin/events-texts.js';

const read = (p) => readFileSync(new URL('../../' + p, import.meta.url), 'utf8');
const KEYS = ['admin.events.copy_public_link', 'admin.events.copy_public_link_en', 'admin.events.copy_public_manual'];

test('linkki: tuotanto, testisivu, EN ja päivä; kelvoton slug tyhjä', () => {
  const slug = 'retreat-1-sauna-healing';
  assert.equal(publicShopLink({ href: 'https://saunotus.fi/hallinta/', slug }), 'https://saunotus.fi/varaa/#/tuote/retreat-1-sauna-healing');
  assert.equal(publicShopLink({ href: 'https://saunotus.fi/hallinta', slug }), 'https://saunotus.fi/varaa/#/tuote/retreat-1-sauna-healing');
  assert.equal(publicShopLink({ href: 'https://saunotus.fi/hallinta/index.html', slug }), 'https://saunotus.fi/varaa/#/tuote/retreat-1-sauna-healing');
  assert.equal(publicShopLink({ href: 'https://saunotus.fi/hallinta/#/tapahtumat?kategoria=training', slug }), 'https://saunotus.fi/varaa/#/tuote/retreat-1-sauna-healing');
  assert.equal(publicShopLink({ href: 'https://saunotus.fi/hallinta/?mock=1', slug, lang: 'en' }), 'https://saunotus.fi/en/book/#/tuote/retreat-1-sauna-healing');
  assert.equal(
    publicShopLink({ href: 'https://joonasvaarala.github.io/saunotus-uusi/hallinta/', slug }),
    'https://joonasvaarala.github.io/saunotus-uusi/varaa/#/tuote/retreat-1-sauna-healing',
  );
  assert.equal(
    publicShopLink({ href: 'https://joonasvaarala.github.io/saunotus-uusi/hallinta/index.html', slug, lang: 'en' }),
    'https://joonasvaarala.github.io/saunotus-uusi/en/book/#/tuote/retreat-1-sauna-healing',
  );
  assert.equal(
    publicShopLink({ href: 'https://saunotus.fi/hallinta/', slug, date: '2026-11-30' }),
    'https://saunotus.fi/varaa/#/tuote/retreat-1-sauna-healing/2026-11-30',
  );
  assert.equal(publicShopLink({ href: 'https://saunotus.fi/hallinta/', slug, date: '30.11.2026' }), 'https://saunotus.fi/varaa/#/tuote/retreat-1-sauna-healing');
  assert.equal(publicShopLink({ href: 'https://saunotus.fi/hallinta/', slug: '' }), '');
  assert.equal(publicShopLink({ href: 'https://saunotus.fi/hallinta/', slug: '../varaa' }), '');
  assert.equal(publicShopLink({ href: 'https://saunotus.fi/hallinta/', slug: 'Retreat' }), '');
});

test('näkymä: painike rivillä ja perusnäkymässä, leikepöydän varakeino, ei kovakoodattua testisivua', () => {
  const view = read('booking/admin/views/events.js');
  assert.match(view, /publicShopLink/);
  assert.match(view, /'event-copy-link'/);
  assert.match(view, /'event-public-links'/);
  assert.match(view, /'event-copy-link-page'/);
  assert.match(view, /'event-copy-link-en'/);
  assert.match(view, /navigator\.clipboard\?\.writeText/);
  assert.match(view, /execCommand\?\.\('copy'\)/);
  assert.match(view, /event-link-fallback/);
  assert.match(view, /prompt\?\.\(tx\('copy_public_manual'\)/);
  assert.doesNotMatch(view, /github\.io|saunotus\.fi/);
  assert.doesNotMatch(view, /\p{Extended_Pictographic}/u);
});

test('tekstit FI+EN pending-import-123, sama kuin koodin oletus, ei kulmasuljetta eikä päällekkäin', () => {
  const raw = read('content/site-texts.pending-import-123.json');
  assert.doesNotMatch(raw, /</);
  const rows = JSON.parse(raw);
  assert.equal(rows.length, KEYS.length * 2);
  for (const key of KEYS) for (const lang of ['fi', 'en']) {
    const row = rows.find((r) => r.key === key && r.lang === lang);
    assert.ok(row, `${key} ${lang}`);
    assert.equal(row.text, COURSE_TEXTS[lang][key]);
    assert.equal(row.class, 'normal');
    assert.equal(row.kind, 'plain');
    assert.deepEqual(row.placeholders, []);
    assert.ok(row.text.length <= row.max_len);
    assert.doesNotMatch(row.text, /</);
  }
  const content = new URL('../../content/', import.meta.url);
  for (const name of readdirSync(content)) {
    if (!/^site-texts\.(pending-import|imported).*\.json$/.test(name) || name === 'site-texts.pending-import-123.json') continue;
    const parsed = JSON.parse(readFileSync(new URL(name, content), 'utf8'));
    const other = Array.isArray(parsed) ? parsed : parsed?.texts;
    if (!Array.isArray(other)) continue;
    for (const row of other) assert.ok(!KEYS.includes(row.key), `${row.key} myös ${name}`);
  }
});
