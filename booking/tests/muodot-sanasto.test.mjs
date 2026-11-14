// YHT-04/05: hallinnan kellonajat samassa muodossa kuin kaupassa (FI 16.00, EN 16:00), ALV 25,5 %, monikot (1 varaus / 2 varausta),
// tilasanasto (Hyvitetty kuten tilausnäkymässä). Lomakkeen <input type="time"> -arvo pysyy muodossa HH:MM (timeValue).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fmtTime, timeValue, vatText, countText, PAY } from '../admin/ui.js';
import { fmt, setLang } from '../admin/talous-i18n.js';
import { clockFromIso } from '../shop/src/clock.js';

const ISO = ['2026-11-14T14:00:00Z', '2026-11-14T07:30:00Z', '2026-07-01T21:05:00Z', '2026-03-29T00:15:00Z', '2026-10-25T00:59:00Z'];

test('fmtTime = kaupan clockFromIso (fi); timeValue = HH:MM lomakkeelle', () => {
  for (const iso of ISO) assert.equal(fmtTime(iso), clockFromIso(iso, 'fi'), iso);
  assert.equal(fmtTime('2026-11-14T14:00:00Z'), '16.00');
  assert.equal(fmtTime('2026-11-14T07:30:00Z'), '9.30');
  assert.equal(timeValue('2026-11-14T07:30:00Z'), '09:30');
  assert.equal(timeValue('2026-07-01T21:05:00Z'), '00:05');
  assert.match(timeValue('2026-11-14T14:00:00Z'), /^\d\d:\d\d$/);
});

test('Talouden fmt.time: FI 16.00, EN 16:00 (sama kuin kaupassa)', () => {
  try {
    setLang('fi'); for (const iso of ISO) assert.equal(fmt.time(iso), clockFromIso(iso, 'fi'));
    setLang('en'); for (const iso of ISO) assert.equal(fmt.time(iso), clockFromIso(iso, 'en'));
    assert.equal(fmt.time('2026-11-14T14:00:00Z'), '16:00');
  } finally { setLang('fi'); }
});

test('ALV ja monikot', () => {
  assert.equal(vatText(25.5), '25,5 %'); assert.equal(vatText('13.5'), '13,5 %'); assert.equal(vatText(0), '0 %'); assert.equal(vatText(null), '–');
  assert.equal(countText(1, 'varaus', 'varausta'), '1 varaus'); assert.equal(countText(0, 'varaus', 'varausta'), '0 varausta'); assert.equal(countText(2, 'varaus', 'varausta'), '2 varausta');
});

test('tilasanasto: hyvitys on Hyvitetty kaikkialla; näkymät käyttävät apureita', () => {
  assert.equal(PAY.refunded, 'Hyvitetty'); assert.equal(PAY.partially_refunded, 'Osittain hyvitetty');
  const read = (p) => readFileSync(new URL(`../admin/${p}`, import.meta.url), 'utf8');
  assert.doesNotMatch(read('ui.js'), /Palautettu/);
  assert.match(read('views/products.js'), /ALV \$\{vatText\(p\.vat_rate\)\}/);
  assert.match(read('views/addons.js'), /ALV \$\{vatText\(a\.vat_rate\)\}/);
  for (const f of ['views/order-card.js', 'views/resbooking.js']) assert.doesNotMatch(read(f), /value: fmtTime|\.value = fmtTime|fmtTime\([^)]*\) !== (time|timeIn)\.value|(time|timeIn)\.value !== fmtTime/, f);
  for (const f of ['views/day.js', 'views/customers.js', 'views/reservations.js', 'views/calendar.js', 'views/products.js']) assert.match(read(f), /countText\(/, f);
});
