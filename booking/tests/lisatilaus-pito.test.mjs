// booking_190: lisäyksen 15 min pito ja maksamattoman varauksen viesti. SQL ajetaan psql:llä (t190).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const rd = (p) => readFileSync(join(root, p), 'utf8');
const mig = rd('booking/supabase/migrations/20261028030913_booking_190_addon_hold_unpaid_email.sql');
const texts = JSON.parse(rd('content/site-texts.pending-import-86.json'));

test('migraatio käyttää kassan pitoa, expire_holdsia ja resend-kytkintä', () => {
  assert.match(mig, /booking\._checkout_hold_minutes\(\)/);
  assert.match(mig, /create or replace function booking\._expire_holds/);
  assert.match(mig, /booking\._enqueue_unpaid_booking_email/);
  assert.match(mig, /unpaid_booking_cancelled/);
  assert.match(mig, /public_cancel_addition/);
  assert.match(mig, /source_channel is distinct from 'web'/);
  assert.match(mig, /external_source is not null/);
  assert.match(mig, /invoice_method', ''\) in \('einvoice', 'pdf'\)/);
});

test('sivutekstit: Peru lisätilaus / Cancel add-on, FI+EN', () => {
  const fi = texts.find((r) => r.key === 'ui.order.cancel_addition' && r.lang === 'fi');
  const en = texts.find((r) => r.key === 'ui.shop.cancel_addition' && r.lang === 'en');
  assert.equal(fi.text, 'Peru lisätilaus');
  assert.equal(en.text, 'Cancel add-on');
  assert.equal(texts.find((r) => r.key === 'email.unpaid_booking.try_again' && r.lang === 'fi').text, 'Yritä uudelleen');
  assert.equal(texts.find((r) => r.key === 'email.unpaid_booking.try_again' && r.lang === 'en').text, 'Try again');
  assert.equal(texts.find((r) => r.key === 'email.unpaid_booking.sign_name' && r.lang === 'fi').text, 'Tapio');
});

test('tilaussivu ja vahvistussivu näyttävät peruutusnapin', () => {
  assert.match(rd('booking/shop/src/order.js'), /cancel-addition|additionHoldSection/);
  assert.match(rd('booking/shop/src/shop.js'), /additionHoldSection/);
  assert.match(rd('booking/shop/src/order-api.js'), /public_cancel_addition/);
  assert.match(rd('booking/shop/src/hold-ui.js'), /data-testid': 'cancel-addition'/);
});
