// Kaupan kategoriachippi tapahtumille. category 'event' ei jää Muut-ryhmään eikä toistu muissa chipeissä.
// Tyhjä kategoria ei saa chippiä. Tekstit: content/site-texts.pending-import-91.json (FI+EN). Ei verkkoa eikä tietokantaa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { kindOf, chipsFor, CHIP_ORDER, DAY_KIND_ORDER } from '../shop/src/catalog-kind.js';
import { T } from '../shop/src/i18n.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (rel) => readFileSync(join(root, rel), 'utf8');
const pending = JSON.parse(read('content/site-texts.pending-import-91.json'));

const pub = (over = {}) => ({ category: 'public_sauna', sale_kind: 'public_shift', ...over });
const priv = (over = {}) => ({ category: 'private_sauna', sale_kind: 'private_shift', ...over });
const event = (over = {}) => ({ category: 'event', sale_kind: 'other', booking_kind: 'rules', ...over });
const treat = (over = {}) => ({ category: 'treatment', sale_kind: 'other', treatment: true, ...over });
const other = (over = {}) => ({ category: 'ceremony', sale_kind: 'other', ...over });

test('tapahtuma on oma laji eikä päädy yleiseen, yksityiseen, hoitoon tai muihin', () => {
  assert.equal(kindOf(event()), 'tapahtuma');
  assert.equal(kindOf(event({ treatment: true, sale_kind: 'public_shift' })), 'tapahtuma');
  assert.equal(kindOf(pub()), 'yleinen');
  assert.equal(kindOf(priv()), 'yksityinen');
  assert.equal(kindOf({ category: 'corporate', sale_kind: 'private_shift' }), 'yksityinen');
  assert.equal(kindOf(treat()), 'hoito');
  assert.equal(kindOf(other()), 'muut');
  assert.equal(kindOf({ category: 'training', sale_kind: 'other' }), 'muut');
  assert.deepEqual(CHIP_ORDER, ['yleinen', 'yksityinen', 'tapahtuma', 'muut', 'hoito']);
  assert.deepEqual(DAY_KIND_ORDER, ['yksityinen', 'yleinen', 'tapahtuma', 'muut']);
});

test('chippi näkyy vain kun kategoriassa on tuotteita, tapahtumat omassa paikassaan', () => {
  const live = [pub(), priv(), event({ slug: 'perinnesaunotusilta' }), event({ slug: 'naisten-joulusauna' }), treat()];
  assert.deepEqual(chipsFor(live), ['all', 'yleinen', 'yksityinen', 'tapahtuma', 'hoito']);
  assert.deepEqual(chipsFor([pub(), treat()]), ['all', 'yleinen', 'hoito']);
  assert.deepEqual(chipsFor([event(), other()]), ['all', 'tapahtuma', 'muut']);
  assert.deepEqual(chipsFor([]), ['all']);
  const only = chipsFor(live);
  for (const p of live.filter((x) => x.category === 'event')) {
    const hits = only.filter((k) => k === 'all' || kindOf(p) === k);
    assert.deepEqual(hits, ['all', 'tapahtuma']);
  }
});

test('päivänäkymä ryhmittelee tapahtuman omaan osioonsa ja jättää tyhjän Muut-osion pois', () => {
  const rows = [
    [priv({ id: 25 }), []],
    [pub({ id: 1 }), []],
    [event({ id: 32 }), []],
    [event({ id: 9 }), []],
  ];
  const groups = DAY_KIND_ORDER.map((k) => [k, rows.filter(([p]) => kindOf(p) === k)]).filter(([, g]) => g.length);
  assert.deepEqual(groups.map(([k]) => k), ['yksityinen', 'yleinen', 'tapahtuma']);
  assert.deepEqual(groups.find(([k]) => k === 'tapahtuma')[1].map(([p]) => p.id), [32, 9]);
  assert.equal(groups.some(([k]) => k === 'muut'), false);
});

test('tekstit: Tapahtumat / Events, pending-import-91, ei vielä varatekstissä eikä toisessa tuonnissa', () => {
  assert.equal(T.fi.k_tapahtuma, 'Tapahtumat');
  assert.equal(T.en.k_tapahtuma, 'Events');
  assert.equal(pending.length, 2);
  const seen = new Set();
  for (const r of pending) {
    assert.equal(r.key, 'ui.shop.k_tapahtuma');
    assert.ok(['fi', 'en'].includes(r.lang));
    assert.equal(r.text, r.lang === 'fi' ? T.fi.k_tapahtuma : T.en.k_tapahtuma);
    assert.equal(r.class, 'normal');
    assert.equal(r.kind, 'plain');
    assert.deepEqual(r.placeholders, []);
    assert.ok(r.max_len >= r.text.length);
    assert.ok(r.reason && r.reason.length <= 300);
    assert.doesNotMatch(r.text, /[<>]/);
    seen.add(r.lang);
  }
  assert.deepEqual([...seen].sort(), ['en', 'fi']);
  const fb = JSON.parse(read('content/site-texts.fallback.json'));
  assert.equal(fb.texts.some((r) => r.key === 'ui.shop.k_tapahtuma'), false);
  for (const f of readdirSync(join(root, 'content')).filter((n) => /^site-texts\.pending-import-\d+\.json$/.test(n) && n !== 'site-texts.pending-import-91.json')) {
    const rows = JSON.parse(read(`content/${f}`));
    assert.equal(rows.some((r) => r.key === 'ui.shop.k_tapahtuma'), false, f);
  }
  const shop = read('booking/shop/src/shop.js');
  assert.match(shop, /chipsFor\(cat\)/);
  assert.match(read('booking/shop/src/shop.css'), /\.bk-tabs\{display:flex;flex-wrap:wrap/);
  assert.doesNotMatch(read('booking/shop/src/week-live.js'), /chipsFor|k_tapahtuma/);
});
