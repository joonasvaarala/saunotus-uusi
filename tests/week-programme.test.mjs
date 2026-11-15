// Viikko-ohjelman tapahtuma- ja kellonaika-apurit (week-live.js): tapahtumakortit ja kellonajat ilman päivämäärää.
// Viikon malli ja näkymä: tests/week-grid.test.mjs.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { freeShopEvents, eventIsFull, cardDates, cardTime, rangeLabel } from '../booking/shop/src/week-live.js';
import { openingSummary } from '../src/opening.mjs';

const kb = JSON.parse(readFileSync(new URL('../content/kb/kb.json', import.meta.url), 'utf8'));
const NOW = Date.parse('2026-10-28T08:00:00Z');

test('aukiolo tulee viikko-ohjelman kellonajoista, perjantai ilman yleistä vuoroa jää pois', () => {
  const fi = openingSummary(kb.hours, ['Ma', 'Ti', 'Ke', 'To', 'Pe', 'La', 'Su']);
  const en = openingSummary(kb.hours, ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']);
  assert.equal(fi, 'Ma–To 16–19, La–Su 14–19');
  assert.equal(en, 'Mon–Thu 16–19, Sat–Sun 14–19');
  assert.equal(openingSummary([], ['Ma']), '');
});

test('kellonaika ilman päivämäärää: minuutit aina mukana, FI piste ja EN kaksoispiste', () => {
  assert.equal(rangeLabel('2026-10-31T14:30:00Z', '2026-10-31T16:30:00Z', 'en'), '16:30–18:30');
  assert.equal(rangeLabel('2026-10-31T14:00:00Z', '2026-10-31T17:00:00Z', 'fi'), '16.00–19.00');
  assert.equal(rangeLabel('2026-10-31T14:00:00Z', null, 'fi'), '16.00');
});

test('tapahtumakortit: täydet tulevat mukana aikajärjestyksessä, menneet ja closed pois', () => {
  const free = freeShopEvents(kb.events_shop, NOW);
  assert.deepEqual(free.map((e) => e.slug), ['sipoonjoen-kekri', 'perinnesaunotusilta', 'naisten-joulusauna', 'sipoonjoen-joulusauna', 'saunottajien-yhteisopaiva-2']);
  assert.equal(eventIsFull(free[0]), true);
  assert.equal(eventIsFull(free[1]), true);
  assert.equal(eventIsFull(free[2]), false);
  assert.equal(eventIsFull(free[3]), false);
  assert.equal(cardDates(free[2].occurrences[0], 'fi', NOW), '18.12.');
  assert.equal(cardDates(free[3].occurrences[0], 'fi', NOW), '19.12.');
  assert.equal(cardDates(free[4].occurrences[0], 'fi', NOW), '20.2.2027');
  assert.equal(cardTime(free[2].occurrences[0], 'fi'), 'klo 16.00–19.00');
  assert.equal(cardTime(free[2].occurrences[0], 'en'), '16:00–19:00');
  assert.equal(cardTime(free[3].occurrences[0], 'fi'), 'klo 14.00–16.00');
  assert.equal(freeShopEvents(null, NOW).length, 0);
  const fullOnly = freeShopEvents([{ category: 'event', slug: 'x', name: 'X', product_id: 9, occurrences: [{ rule_id: 3, status: 'full', starts_at: '2026-12-01T14:00:00Z', ends_at: '2026-12-01T17:00:00Z' }] }], NOW);
  assert.equal(fullOnly.length, 1);
  assert.equal(eventIsFull(fullOnly[0]), true);
});
