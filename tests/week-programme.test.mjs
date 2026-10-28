// Viikko-ohjelma ja tapahtumakortit: vapaat tapahtumat näkyviin, täydet piiloon, ei päivämäärää viikkorivillä.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { shiftIsFull, weekEvents, freeShopEvents, dateForWeekday, cardDates, cardTime, parseClock, rangeLabel } from '../booking/shop/src/week-live.js';
import { openingSummary } from '../src/opening.mjs';

const kb = JSON.parse(readFileSync(new URL('../content/kb/kb.json', import.meta.url), 'utf8'));
const TODAY = '2026-10-28';
const NOW = Date.parse('2026-10-28T08:00:00Z');

test('aukiolo tulee viikko-ohjelman kellonajoista, perjantai ilman yleistä vuoroa jää pois', () => {
  const fi = openingSummary(kb.hours, ['Ma', 'Ti', 'Ke', 'To', 'Pe', 'La', 'Su']);
  const en = openingSummary(kb.hours, ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']);
  assert.equal(fi, 'Ma–To 16–19, La–Su 14–19');
  assert.equal(en, 'Mon–Thu 16–19, Sat–Sun 14–19');
  assert.equal(openingSummary([], ['Ma']), '');
});

test('täysi vuoro piilotetaan vain kun tiedetään, että vapaita paikkoja ei ole', () => {
  const rows = [
    { product_id: 1, session_date: '2026-10-31', starts_at: '2026-10-31T12:00:00Z', ends_at: '2026-10-31T14:00:00Z', status: 'full' },
    { product_id: 1, session_date: '2026-10-31', starts_at: '2026-10-31T14:00:00Z', ends_at: '2026-10-31T16:00:00Z', status: 'available' },
  ];
  assert.equal(shiftIsFull(rows, { productId: 1, date: '2026-10-31', open: '14:00', close: '19:00' }), false);
  assert.equal(shiftIsFull([{ ...rows[0] }], { productId: 1, date: '2026-10-31', open: '14:00', close: '19:00' }), true);
  assert.equal(shiftIsFull([{ ...rows[0], starts_at: '2026-10-31T13:00:00Z', ends_at: '2026-10-31T16:00:00Z' }], { productId: 1, date: '2026-10-31', open: '16.00', close: '19.00' }), true);
  assert.equal(parseClock('16.30'), 16 * 60 + 30);
  assert.equal(parseClock('16:30'), 16 * 60 + 30);
  assert.equal(parseClock('9.05'), 9 * 60 + 5);
  assert.equal(shiftIsFull([], { productId: 1, date: '2026-10-31', open: '14:00', close: '19:00' }), false);
  assert.equal(shiftIsFull(null, { productId: 1, date: '2026-10-31' }), false);
});

test('viikon tapahtuma: vain vapaa kerta omalle viikonpäivälle, ei päivämäärää kellonajassa', () => {
  const events = kb.events_shop;
  const rows = weekEvents(events, { today: TODAY, now: NOW });
  assert.deepEqual(rows.map((r) => r.slug), []);
  const christmas = events.find((e) => e.slug === 'naisten-joulusauna');
  const near = weekEvents([{ ...christmas, occurrences: [{ ...christmas.occurrences[0], starts_at: '2026-10-31T14:00:00Z', ends_at: '2026-10-31T17:00:00Z', status: 'available' }] }], { today: TODAY, now: NOW });
  assert.equal(near.length, 1);
  assert.equal(near[0].weekday, 6);
  assert.equal(near[0].time, '16.00–19.00');
  assert.equal(rangeLabel('2026-10-31T14:30:00Z', '2026-10-31T16:30:00Z', 'en'), '16:30–18:30');
  assert.doesNotMatch(near[0].time, /\d{1,2}\.\d{1,2}\./);
  assert.equal(dateForWeekday(TODAY, 6), '2026-10-31');
});

test('tapahtumakortit: snapshotista vain vapaat kerrat (18.12. ja 20.2.), täydet pois', () => {
  const free = freeShopEvents(kb.events_shop, NOW);
  assert.deepEqual(free.map((e) => e.slug), ['naisten-joulusauna', 'saunottajien-yhteisopaiva-2']);
  assert.equal(cardDates(free[0].occurrences[0], 'fi', NOW), '18.12.');
  assert.equal(cardDates(free[1].occurrences[0], 'fi', NOW), '20.2.2027');
  assert.equal(cardTime(free[0].occurrences[0], 'fi'), 'klo 16.00–19.00');
  assert.equal(cardTime(free[0].occurrences[0], 'en'), '16:00–19:00');
  assert.equal(freeShopEvents(null, NOW).length, 0);
  assert.equal(freeShopEvents([{ category: 'event', slug: 'x', name: 'X', occurrences: [{ status: 'full', starts_at: '2026-12-01T14:00:00Z', ends_at: '2026-12-01T17:00:00Z' }] }], NOW).length, 0);
});
