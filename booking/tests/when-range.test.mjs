// Aikavälin muotoilu (FI+EN). Sama päivä, eri päivät samana vuonna, vuodenvaihde, puuttuva loppu.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { formatWhenRange, formatLocalRange, formatWhenList, spansDays } from '../shop/src/when-range.js';

const NOW = Date.parse('2026-11-02T08:00:00Z');
const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const read = (rel) => readFileSync(join(root, rel), 'utf8');

test('sama päivä: kellonaika ilman toista päivämäärää, kuluva vuosi pois', () => {
  assert.equal(formatWhenRange('2026-11-14T14:00:00Z', '2026-11-14T17:00:00Z', 'fi', NOW), 'la 14.11. klo 16.00–19.00');
  assert.equal(formatWhenRange('2026-11-14T14:00:00Z', '2026-11-14T17:00:00Z', 'en', NOW), 'Sat 14 Nov 16:00–19:00');
  assert.equal(spansDays('2026-11-14T14:00:00Z', '2026-11-14T17:00:00Z'), false);
});

test('eri päivät samana vuonna: vuosi vain lopussa', () => {
  assert.equal(formatWhenRange('2026-11-30T10:30:00+00:00', '2026-12-04T14:00:00+00:00', 'fi', NOW), 'ma 30.11. klo 12.30 – pe 4.12.2026 klo 16.00');
  assert.equal(formatWhenRange('2026-11-30T10:30:00+00:00', '2026-12-04T14:00:00+00:00', 'en', NOW), 'Mon 30 Nov 12:30 – Fri 4 Dec 2026 16:00');
  assert.equal(formatLocalRange({ startDate: '2026-11-30', startTime: '12:30', endDate: '2026-12-04', endTime: '16:00' }, 'en', NOW), 'Mon 30 Nov 12:30 – Fri 4 Dec 2026 16:00');
});

test('vuodenvaihde: vuosi molemmissa, muu vuosi myös alussa', () => {
  assert.equal(formatWhenRange('2026-12-30T10:30:00Z', '2027-01-02T14:00:00Z', 'fi', NOW), 'ke 30.12.2026 klo 12.30 – la 2.1.2027 klo 16.00');
  assert.equal(formatWhenRange('2026-12-30T10:30:00Z', '2027-01-02T14:00:00Z', 'en', NOW), 'Wed 30 Dec 2026 12:30 – Sat 2 Jan 2027 16:00');
  assert.equal(formatWhenRange('2027-11-30T10:30:00Z', '2027-12-04T14:00:00Z', 'fi', NOW), 'ti 30.11.2027 klo 12.30 – la 4.12.2027 klo 16.00');
});

test('puuttuva loppu ja virheellinen alku', () => {
  assert.equal(formatWhenRange('2026-11-30T10:30:00Z', null, 'fi', NOW), 'ma 30.11. klo 12.30');
  assert.equal(formatWhenRange('2026-11-30T10:30:00Z', '', 'en', NOW), 'Mon 30 Nov 12:30');
  assert.equal(formatWhenRange('2027-02-06T09:00:00Z', null, 'fi', NOW), 'la 6.2.2027 klo 11.00');
  assert.equal(formatWhenRange('ei-aika', '2026-12-04T14:00:00Z', 'fi', NOW), '');
  assert.equal(spansDays('2026-11-30T10:30:00Z', null), false);
  assert.equal(formatWhenList([{ starts_at: '2026-11-30T10:30:00Z', ends_at: '2026-12-04T14:00:00Z' }, { starts_at: '2027-02-08T10:30:00Z', ends_at: '2027-02-12T14:00:00Z' }], 'fi', NOW),
    'ma 30.11. klo 12.30 – pe 4.12.2026 klo 16.00 · ma 8.2.2027 klo 12.30 – pe 12.2.2027 klo 16.00');
});

test('kolme kopiota on sama tiedosto', () => {
  const a = read('booking/shop/src/when-range.js');
  assert.equal(read('booking/admin/when-range.js'), a);
  assert.equal(read('booking/supabase/functions/_shared/when-range.js'), a);
  assert.match(a, /Uudet tekstiavaimet: ei ole/);
});
