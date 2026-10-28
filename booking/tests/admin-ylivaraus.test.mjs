// booking_192: alennus, lahjakortti, ylibuukkaus ja aikataulun ulkopuolinen varaus.
// Logiikka ja tekstit ilman tietokantaa. SQL: booking/supabase/tests/hallinta/t192_admin_overbook_gift.sql
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const imp = (p) => import(pathToFileURL(join(root, p)));
const L = await imp('admin/nb-logic.js');
const { BOOKING_TEXTS, bookingText, noticeText } = await imp('admin/booking-texts.js');
const { errMsg } = await imp('admin/ui.js');
const sql = readFileSync(join(root, 'supabase/migrations/20261028120000_booking_192_admin_overbook_gift_discount.sql'), 'utf8');
const texts = JSON.parse(readFileSync(join(root, '../content/site-texts.pending-import-89.json'), 'utf8'));

test('Kapasiteettivaroitus heti: 12/10, enimmäismäärä ja resurssikonflikti', () => {
  const full = { mode: 'shared', remaining: 0, max_persons: 16, pool_capacity: 10, pool_peak: 10, status: 'full' };
  assert.deepEqual(L.capacityNotice(full, 2), { kind: 'overbook', code: 'capacity_exceeded', used: 12, capacity: 10 });
  assert.equal(L.capacityNotice({ mode: 'shared', remaining: 12, max_persons: 16, pool_capacity: 16, pool_peak: 4, status: 'available' }, 3), null);
  assert.equal(L.capacityNotice({ mode: 'shared', max_persons: 8, remaining: 20, status: 'available' }, 9).code, 'persons_max');
  assert.equal(L.capacityNotice({ mode: 'exclusive', status: 'unavailable', max_persons: 10, remaining: 10 }, 2).code, 'space_busy');
  assert.equal(L.scheduleNotice({ status: 'unavailable', blocked: true, mode: 'shared' }).code, 'closure');
  assert.equal(L.scheduleNotice({ status: 'off_schedule', off_schedule: true, off_code: 'no_session' }).code, 'no_session');
  assert.equal(noticeText(L.capacityNotice(full, 2)), 'Vuoron kapasiteetti ylittyy: 12/10 henkilöä');
});

test('Alennus vähennetään yhteenvedosta, sentti pyöristyy', () => {
  assert.equal(L.applyDiscount(46, 4.6), 41.4);
  assert.equal(L.applyDiscount(10, 0), 10);
  assert.equal(L.applyDiscount(10, 15), -5);
});

test('Tekstit FI ja EN, tuontitiedosto ja varalla oleva lause', () => {
  assert.deepEqual(Object.keys(BOOKING_TEXTS.en).sort(), Object.keys(BOOKING_TEXTS.fi).sort());
  for (const k of Object.keys(BOOKING_TEXTS.fi)) assert.ok(BOOKING_TEXTS.fi[k].trim() && BOOKING_TEXTS.en[k].trim(), k);
  for (const k of ['ui.admin.booking.discount', 'ui.admin.booking.gift_code', 'ui.admin.booking.gift_check', 'ui.admin.booking.over_capacity', 'ui.admin.booking.over_ask', 'ui.admin.booking.off_ask', 'ui.admin.booking.off_no_rule', 'ui.admin.booking.gift_need_code']) {
    assert.ok(texts.some((r) => r.key === k && r.lang === 'fi') && texts.some((r) => r.key === k && r.lang === 'en'), `tuonti ${k}`);
  }
  assert.equal(bookingText('over_ask'), 'Haluatko varmasti ylibuukata?');
  assert.equal(bookingText('off_ask'), 'Haluatko varmasti jatkaa?');
  assert.equal(bookingText('gift_need_code'), 'Anna lahjakortin koodi.');
});

test('Teknistä lahjakorttivirhettä ei näytetä', () => {
  const raw = 'Lahjakorttimaksu vaatii kortin (käytä admin_redeem_gift_card / public_apply_gift_card)';
  assert.equal(errMsg({ code: 'gift_card_required', message: raw }), 'Lahjakorttimaksu tarvitsee lahjakortin koodin.');
  assert.equal(errMsg(new Error(raw)), 'Lahjakorttimaksu tarvitsee lahjakortin koodin.');
  assert.doesNotMatch(errMsg(new Error(raw)), /admin_redeem_gift_card|public_apply_gift_card/);
});

test('Migraatio: liput vain hallinnan RPC:issä, julkinen kapasiteetti ei negatiivinen', () => {
  assert.match(sql, /p_allow_overbook boolean default false/);
  assert.match(sql, /p_allow_off_schedule boolean default false/);
  assert.match(sql, /admin_redeem_gift_card|booking\._gc_redeem/);
  assert.match(sql, /_discount_split/);
  assert.match(sql, /STAFF_OVERRIDE/);
  assert.match(sql, /greatest\(min\(res\.capacity - booking\._pool_peak/);
  assert.doesNotMatch(sql, /function booking\.public_create_booking\(/);
  assert.doesNotMatch(sql, /function booking\.public_create_treatment_booking\(/);
  assert.match(sql, /p_channel is distinct from 'admin'/);
  assert.match(sql, /_clear_staff_overrides\(\)/);
  const pub = readFileSync(join(root, 'admin/views/newbooking.js'), 'utf8');
  assert.match(pub, /data-testid': 'gift-card-field'/);
  assert.match(pub, /data-testid': 'discount-code'/);
  assert.match(pub, /p_allow_overbook/);
  assert.match(pub, /p_gift_card_code/);
  const move = readFileSync(join(root, 'admin/views/shared.js'), 'utf8');
  assert.match(move, /p_allow_off_schedule/);
  assert.match(move, /Haluatko varmasti|over_ask|bookingText\('over_ask'\)/);
});
