import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { daySlotsAvailableFirst } from '../shop/src/day-slot-order.js';

const slot = (id, time, status, remaining = 0) => ({ rule_id: id, starts_at: `2026-11-07T${time}:00+02:00`, status, remaining });
const ids = (rows) => daySlotsAvailableFirst(rows).map((x) => (x.r || x).rule_id);

test('mixed day slots: available first, chronological within both groups; input unchanged', () => {
  const rows = [slot(3, '15:00', 'full'), slot(4, '16:00', 'available'), slot(1, '14:00', 'full'), slot(2, '14:30', 'available', 6)];
  const before = structuredClone(rows);
  assert.deepEqual(ids(rows), [2, 4, 1, 3]);
  assert.deepEqual(rows, before);
  assert.deepEqual(ids(rows.map((r) => ({ r, p: { id: 7 } }))), [2, 4, 1, 3]);
});
for (const status of ['available', 'full']) test(`all ${status}: chronological order`, () => {
  assert.deepEqual(ids([slot(3, '15:00', status), slot(1, '14:00', status), slot(2, '14:30', status)]), [1, 2, 3]);
});
test('refresh uses latest availability, not remaining capacity or cached order', () => {
  const rows = [slot(1, '14:00', 'full', 6), slot(2, '14:30', 'available', 0)];
  assert.deepEqual(ids(rows), [2, 1]);
  // Upstream availability may change when party size/supply changes. Never
  // infer bookability here from remaining alone (exclusive/min/max rules).
  rows[0].status = 'available'; rows[1].status = 'full';
  assert.deepEqual(ids(rows), [1, 2]);
  rows[1].status = 'available';
  assert.deepEqual(ids(rows), [1, 2]);
});
test('closed rows stay hidden; empty list and ties are deterministic', () => {
  assert.deepEqual(ids([slot(1, '14:00', 'unavailable')]), []);
  assert.deepEqual(ids([]), []);
  assert.deepEqual(ids([slot(2, '14:00', 'available'), slot(1, '14:00', 'available')]), [1, 2]);
});
test('day accordion uses one ordered DOM list for mobile and desktop; product view keeps existing order', () => {
  const source = readFileSync(new URL('../shop/src/shop.js', import.meta.url), 'utf8');
  assert.match(source, /class: 'bk-slotlist'[^\n]*\(treat \? rs : daySlotsAvailableFirst\(rs\)\)\.map/);
  assert.equal(source.match(/daySlotsAvailableFirst\(rs\)/g)?.length, 1);
  assert.match(source, /const rows = visibleWaitlistSlots\(byDay\[sel\] \|\| \[\]\)/);
});
