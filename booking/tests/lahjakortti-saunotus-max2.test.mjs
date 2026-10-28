// Joonas 28.10.2026: Savusaunaelämys ja saunotus (saunotus_2) enintään 2 hengelle; + pois käytöstä enimmäismäärässä.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PUBLISHED_GIFT_PACKAGES as GIFT_OFFERS } from '../shop/src/gift-offers.js';

const here = new URL('.', import.meta.url);
test('gift-offers: saunotus_2 1–2 hlö, hinta 328 € kahdelle, muut rajat ennallaan', () => {
  const by = Object.fromEntries(GIFT_OFFERS.map((p) => [p.code, p]));
  assert.equal(by.saunotus_2.min_persons, 1);
  assert.equal(by.saunotus_2.max_persons, 2);
  assert.equal(by.saunotus_2.price, 328);
  assert.equal(by.sauna_treatment_2.max_persons, 4);
  assert.equal(by.entry_2.max_persons, 6);
});
test('gift.js: henkilömäärän +/− poistuu käytöstä rajoilla', () => {
  const src = readFileSync(new URL('../shop/src/gift.js', here), 'utf8');
  assert.match(src, /plus\.disabled = head >= hi/);
  assert.match(src, /minus\.disabled = head <= lo/);
  assert.match(src, /draw\(\); bounds\(\); \}/);
});
test('booking_211-migraatio: saunotus_2 max_persons = 2', () => {
  const sql = readFileSync(new URL('../supabase/migrations/20261028190534_booking_211_saunotus_gift_max2.sql', here), 'utf8');
  assert.match(sql, /set max_persons = 2/);
  assert.match(sql, /where code = 'saunotus_2'/);
});
