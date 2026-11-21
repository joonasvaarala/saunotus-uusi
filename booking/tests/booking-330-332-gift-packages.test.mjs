// booking_330–332: musta viikko -lahjakorttipaketit ja gift_cover / gift_covers.
// Migraatiot = PRODin schema_migrations-teksti tavu-identtisenä; ei ajeta uudelleen.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const root = new URL('../supabase/', import.meta.url);
const md5 = (b) => createHash('md5').update(b).digest('hex');
const files = [
  ['20261121171506', 'booking_330_bf_jalkiloylyt_gift_card', '4b653f3e0e3dbed3612e6e0837691058', '4c79891b22a96cdfa2c034bb0f996b48'],
  ['20261121171511', 'booking_331_gift_cover_cap', '49d0019b886c05bb8bb61da7b21b2c20', 'c637e27bb3ef87d396df40350f43d463'],
  ['20261121172907', 'booking_332_mv_yleiset_mato', '2771c9eb23a0f4ed57423035daf22425', 'd919fd954c6af933a75379dde52e1dea'],
  ['20261121173537', 'booking_333_mv_exclusions_sale_end', 'dd7aa9ac5e38519e120dcd8c425648f8', '35cc2567cc1809e6ce99561ce5a12fc7'],
];

for (const [ver, name, migMd5, rbMd5] of files) {
  const migRaw = readFileSync(new URL(`migrations/${ver}_${name}.sql`, root));
  const rbRaw = readFileSync(new URL(`rollbacks/${ver}_${name.split('_').slice(0, 2).join('_')}_ROLLBACK.sql`, root));
  test(`migraatio = PRODin ${name} (md5)`, () => {
    assert.equal(md5(migRaw), migMd5);
    assert.doesNotMatch(migRaw.toString('utf8'), /\bpublic\./, 'ei koske public-skeemaan');
  });
  test(`rollback ${name} md5-vahti`, () => {
    assert.equal(md5(rbRaw), rbMd5);
    const rb = rbRaw.toString('utf8');
    assert.match(rb, /ROLLBACK/i);
    assert.doesNotMatch(rb, /\bpublic\./);
  });
}

test('330 lisää piilotetun jälkilöylypaketin, 332 yleisten vuorojen paketin', () => {
  const m330 = readFileSync(new URL('migrations/20261121171506_booking_330_bf_jalkiloylyt_gift_card.sql', root), 'utf8');
  const m332 = readFileSync(new URL('migrations/20261121172907_booking_332_mv_yleiset_mato.sql', root), 'utf8');
  assert.match(m330, /bf_jalkiloylyt_mato/);
  assert.match(m330, /listed/);
  assert.match(m332, /mv_yleiset_mato/);
  assert.match(m332, /redeem_unit_value/);
  assert.match(m332, /gift_covers/);
  assert.match(m332, /Yleisten vuorojen lahjakortti 2 hengelle/);
  assert.match(m332, /50\.00/);
  const m333 = readFileSync(new URL('migrations/20261121173537_booking_333_mv_exclusions_sale_end.sql', root), 'utf8');
  assert.match(m333, /sale_ends_at/);
  assert.match(m333, /sale_ended/);
  assert.match(m333, /redeem_excluded_ranges/);
  assert.match(m333, /2026-11-30 10:00:00 Europe\/Helsinki/);
  assert.match(m333, /Ei voimassa 24\.–30\.12\./);
  assert.match(m333, /Turvetorstaina maksetaan erotus/);
});
